import Foundation

struct LocalLedgerDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let entrypoint: String
    let createdAt: Date
    let git: LocalGitConfiguration?

    init(id: UUID, name: String, entrypoint: String, createdAt: Date, git: LocalGitConfiguration? = nil) {
        self.id = id
        self.name = name
        self.entrypoint = entrypoint
        self.createdAt = createdAt
        self.git = git
    }
}

actor LocalLedgerCatalog {
    typealias Validator = @Sendable (URL, String) async throws -> Void
    nonisolated let rootDirectory: URL
    private let validator: Validator
    private let engine: any LocalLedgerEngine
    private let gitTransport: any LocalGitTransport
    private let gitCredentials: any LocalGitCredentialStoring

    init(rootDirectory: URL, engine: any LocalLedgerEngine = EmbeddedLocalLedgerEngine.shared,
         gitTransport: any LocalGitTransport = EmbeddedLocalGitTransport(),
         gitCredentials: any LocalGitCredentialStoring = DeviceLocalGitCredentialStore(),
         validator: @escaping Validator = { root, entry in
             try await EmbeddedBeancountValidator.shared.validate(workspace: root, entryFile: entry)
         }) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.engine = engine
        self.validator = validator
        self.gitTransport = gitTransport
        self.gitCredentials = gitCredentials
    }

    static func appManaged() throws -> LocalLedgerCatalog {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return LocalLedgerCatalog(rootDirectory: support.appendingPathComponent("Ledgers", isDirectory: true))
    }

    func list() throws -> [LocalLedgerDescriptor] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: rootDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).compactMap { directory in
                guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
                let descriptorURL = directory.appendingPathComponent("ledger.json")
                guard FileManager.default.fileExists(atPath: descriptorURL.path) else { return nil }
                let descriptor = try JSONDecoder().decode(LocalLedgerDescriptor.self, from: Data(contentsOf: descriptorURL))
                guard descriptor.id.uuidString == directory.lastPathComponent else {
                    throw LocalLedgerError.invalidConfiguration("本地账本目录标识不一致")
                }
                return descriptor
            }.sorted { $0.createdAt < $1.createdAt }
    }

    nonisolated func repository(for descriptor: LocalLedgerDescriptor) -> LocalLedgerRepository {
        LocalLedgerRepository(descriptor: descriptor, storage: storage(for: descriptor),
            engine: engine, validator: publicationValidator(for: descriptor))
    }

    private nonisolated func storage(for descriptor: LocalLedgerDescriptor) -> any LogicalLocalStorage {
        let workspace = LocalLedgerWorkspace(rootDirectory: rootDirectory.appendingPathComponent(descriptor.id.uuidString))
        if let git = descriptor.git {
            return GitLocalStorage(workspace: workspace, configuration: git, transport: gitTransport, credentials: gitCredentials)
        }
        return DeviceLocalStorage(workspace: workspace)
    }

    /// Saves configuration; the session schedules synchronization after publication.
    func configureGit(ledgerID: UUID, repositoryURL: String, branch: String = "main",
                      credential: LocalGitCredential? = nil) throws -> LocalLedgerDescriptor {
        guard let old = try list().first(where: { $0.id == ledgerID }) else {
            throw LocalStorageError.invalidGitConfiguration("找不到要配置的本地账本")
        }
        let candidate = try LocalGitConfiguration(repositoryURL: repositoryURL, branch: branch)
        let git: LocalGitConfiguration
        if let current = old.git, current.repositoryURL == candidate.repositoryURL, current.branch == candidate.branch {
            git = current
        } else { git = candidate }
        if let credential { try gitCredentials.save(credential, for: git.id) }
        let updated = LocalLedgerDescriptor(id: old.id, name: old.name, entrypoint: old.entrypoint, createdAt: old.createdAt, git: git)
        try persist(updated)
        return updated
    }

    func disconnectGit(ledgerID: UUID) throws -> LocalLedgerDescriptor {
        guard let old = try list().first(where: { $0.id == ledgerID }) else {
            throw LocalStorageError.invalidGitConfiguration("找不到要配置的本地账本")
        }
        if let git = old.git { try gitCredentials.remove(for: git.id) }
        let updated = LocalLedgerDescriptor(id: old.id, name: old.name, entrypoint: old.entrypoint, createdAt: old.createdAt)
        try persist(updated)
        return updated
    }

    /// Importing a populated branch only downloads: the local and fetched trees
    /// are identical, so the provider has no commit to push.
    func importGit(repositoryURL: String, branch: String = "main", name: String,
                   entrypoint: String = "main.bean", credential: LocalGitCredential? = nil) async throws -> LocalLedgerDescriptor {
        let plain = try makeDescriptor(name: name, entrypoint: entrypoint)
        let git = try LocalGitConfiguration(repositoryURL: repositoryURL, branch: branch)
        let descriptor = LocalLedgerDescriptor(id: plain.id, name: plain.name, entrypoint: plain.entrypoint,
            createdAt: plain.createdAt, git: git)
        let provider = storage(for: descriptor)
        let validate = publicationValidator(for: descriptor)
        do {
            if let credential { try gitCredentials.save(credential, for: git.id) }
            _ = try await provider.synchronize { root in try await validate(root, descriptor.entrypoint) }
            try Task.checkCancellation()
            try persist(descriptor)
            return descriptor
        } catch {
            // This UUID was allocated for this import and has never been
            // published in the catalog. Existing ledger roots stay untouched.
            try? gitCredentials.remove(for: git.id)
            try? FileManager.default.removeItem(at: rootDirectory.appendingPathComponent(descriptor.id.uuidString))
            throw error
        }
    }

    func create(name: String, currency: String = "CNY") async throws -> LocalLedgerDescriptor {
        guard currency.range(of: "^[A-Z][A-Z0-9._-]{0,23}$", options: .regularExpression) != nil else {
            throw LocalLedgerError.invalidConfiguration("请输入有效的币种代码")
        }
        let descriptor = try makeDescriptor(name: name, entrypoint: "main.bean")
        let workspace = workspace(for: descriptor)
        let content = """
        option "title" "\(escape(descriptor.name))"
        option "operating_currency" "\(currency)"

        1970-01-01 commodity \(currency)
        1970-01-01 open Assets:Cash \(currency)
          alias: "现金"
        1970-01-01 open Assets:Bank \(currency)
          alias: "银行存款"
        1970-01-01 open Liabilities:CreditCard \(currency)
          alias: "信用卡"
        1970-01-01 open Equity:Opening-Balances
          alias: "期初余额"
        1970-01-01 open Income:Salary \(currency)
          alias: "工资收入"
        1970-01-01 open Expenses:Food \(currency)
          alias: "餐饮美食"
        1970-01-01 open Expenses:Transport \(currency)
          alias: "交通出行"
        1970-01-01 open Expenses:Other \(currency)
          alias: "其他支出"

        """
        let validate = publicationValidator(for: descriptor)
        try await workspace.commit(changes: [.write(Data(content.utf8), to: descriptor.entrypoint)]) { root in
            try await validate(root, descriptor.entrypoint)
        }
        try persist(descriptor)
        return descriptor
    }

    func importLedger(from directory: URL, name: String, entrypoint: String = "main.bean") async throws -> LocalLedgerDescriptor {
        let descriptor = try makeDescriptor(name: name, entrypoint: entrypoint)
        let validate = publicationValidator(for: descriptor)
        #if os(iOS) || os(macOS)
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        #endif
        try await workspace(for: descriptor).importLedger(from: directory) { root in
            try await validate(root, descriptor.entrypoint)
        }
        try persist(descriptor)
        return descriptor
    }

    private func workspace(for descriptor: LocalLedgerDescriptor) -> LocalLedgerWorkspace {
        LocalLedgerWorkspace(rootDirectory: rootDirectory.appendingPathComponent(descriptor.id.uuidString))
    }

    /// Canonical validity and the application's read limits must both hold
    /// before an immutable generation becomes the active ledger.
    private nonisolated func publicationValidator(for descriptor: LocalLedgerDescriptor) -> Validator {
        let canonical = validator, engine = engine
        // Use the workspace's exact normalized path for both sides of the
        // bridge. iOS temporary URLs can spell /var as /private/var.
        let workspace = LocalLedgerWorkspace(rootDirectory: rootDirectory.appendingPathComponent(descriptor.id.uuidString))
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        return { root, entry in
            try await canonical(root, entry)
            _ = try await engine.dispatch(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                entrypoint: entry, method: "GET", path: "/api/ledger/version"))
        }
    }

    private func makeDescriptor(name: String, entrypoint: String) throws -> LocalLedgerDescriptor {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains("\n"), !name.contains("\r") else {
            throw LocalLedgerError.invalidConfiguration("账本名称需要为 1–120 个字符")
        }
        let parts = entrypoint.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !entrypoint.contains("\\"), !entrypoint.contains("\0"), entrypoint.hasSuffix(".bean") else {
            throw LocalLedgerError.invalidConfiguration("请选择账本目录内的 .bean 入口文件")
        }
        return LocalLedgerDescriptor(id: UUID(), name: name, entrypoint: entrypoint, createdAt: Date())
    }

    private func persist(_ descriptor: LocalLedgerDescriptor) throws {
        let destination = rootDirectory.appendingPathComponent(descriptor.id.uuidString).appendingPathComponent("ledger.json")
        #if os(iOS)
        try JSONEncoder().encode(descriptor).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(descriptor).write(to: destination, options: .atomic)
        #endif
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
