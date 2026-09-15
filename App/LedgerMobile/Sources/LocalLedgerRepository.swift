import Foundation

struct LocalLedgerFileDraft: Sendable {
    let path: String
    let text: String
    let revisionID: UUID
}

actor LocalLedgerRepository: LedgerRepository {
    nonisolated static let didSaveNotification = Notification.Name("LedgerLocalRevisionSaved")
    nonisolated let descriptor: LocalLedgerDescriptor
    nonisolated let workspace: LocalLedgerWorkspace
    nonisolated let storage: any LogicalLocalStorage
    private let engine: any LocalLedgerEngine
    private let validator: LocalLedgerCatalog.Validator
    private var presentedRevisionID: UUID?
    private var importRevisionIDs: [String: UUID] = [:]
    private var importPreviewDates: [String: Date] = [:]
    private var lastRuntimeMaintenance: Date?

    init(descriptor: LocalLedgerDescriptor, workspace: LocalLedgerWorkspace,
         engine: any LocalLedgerEngine = EmbeddedLocalLedgerEngine.shared,
         validator: @escaping LocalLedgerCatalog.Validator = { root, entry in
             try await EmbeddedBeancountValidator.shared.validate(workspace: root, entryFile: entry)
         }) {
        self.descriptor = descriptor
        self.workspace = workspace
        self.storage = DeviceLocalStorage(workspace: workspace)
        self.engine = engine
        self.validator = validator
    }

    init(descriptor: LocalLedgerDescriptor, storage: any LogicalLocalStorage,
         engine: any LocalLedgerEngine = EmbeddedLocalLedgerEngine.shared,
         validator: @escaping LocalLedgerCatalog.Validator) {
        self.descriptor = descriptor
        self.storage = storage
        self.workspace = storage.workspace
        self.engine = engine
        self.validator = validator
    }

    func storageStatus() async throws -> LocalStorageSyncStatus { try await storage.status() }
    func synchronize() async throws -> LocalStorageSyncStatus {
        let validate = validator, entry = descriptor.entrypoint
        return try await storage.synchronize { root in try await validate(root, entry) }
    }
    func resolveSyncConflicts(keepingLocal: Bool) async throws -> LocalStorageSyncStatus {
        let validate = validator, entry = descriptor.entrypoint
        return try await storage.resolveConflicts(keepingLocal: keepingLocal) { root in try await validate(root, entry) }
    }
    func exportSyncConflictVersions() async throws -> URL { try await storage.exportConflictVersions() }

    func bootstrap(start: String, end: String, today: String, valuationCurrency: String) async throws -> LedgerBootstrap {
        var query = range(start, end, valuationCurrency)
        query["today"] = today
        return try await read("/api/ledger/bootstrap", query: query)
    }
    func homeReport(start: String, end: String, valuationCurrency: String) async throws -> LedgerHomeReport {
        try await read("/api/ledger/home-report", query: range(start, end, valuationCurrency))
    }
    func globalTransactions() async throws -> LedgerGlobalTransactions {
        try await read("/api/ledger/transactions", query: ["start": "0001-01-01", "end": "9999-12-31"])
    }
    func importDocuments() async throws -> [LedgerImportDocument] {
        let result: LedgerImportDocumentsResponse = try await read("/api/ledger/imports/documents")
        return result.documents
    }
    func importProviders() async throws -> [LedgerImportProviderInfo] {
        struct Response: Decodable { let providers: [LedgerImportProviderInfo] }
        let result: Response = try await read("/api/ledger/imports/providers")
        return result.providers
    }
    func previewImport(file: LedgerImportSelectedFile, provider: String?, alipayFundRounding: Bool,
                       archivePassword: String) async throws -> LedgerImportPreview {
        let body: BQLCell = .object(["provider": .string(provider ?? ""),
            "alipayFundRounding": .bool(alipayFundRounding), "archivePassword": .string(archivePassword)])
        let (revision, data) = try await readSnapshot("/api/ledger/imports/preview", method: "POST", body: body,
            importFile: .init(name: file.name, data: file.data))
        let result = try JSONDecoder().decode(LedgerImportPreview.self, from: data)
        presentedRevisionID = revision
        importRevisionIDs[result.importID] = revision
        importPreviewDates[result.importID] = Date()
        return result
    }
    func commitImport(request: LedgerImportCommitRequest) async throws -> LedgerImportCommitResult {
        guard let expected = importRevisionIDs[request.importID] else { throw LocalLedgerError.previewRequired }
        guard let created = importPreviewDates[request.importID],
              Date().timeIntervalSince(created) < LocalLedgerWorkspace.importPreviewRetention else {
            importRevisionIDs.removeValue(forKey: request.importID)
            importPreviewDates.removeValue(forKey: request.importID)
            throw LocalLedgerError.previewRequired
        }
        let result: LedgerImportCommitResult = try await mutate("/api/ledger/imports/commit", method: "POST",
            body: json(request), expected: expected, consumingImportID: request.importID)
        importRevisionIDs.removeValue(forKey: request.importID)
        importPreviewDates.removeValue(forKey: request.importID)
        return result
    }
    func updateTransaction(source: TransactionSource, entry: LedgerTransactionEntry) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "PUT",
            body: json(LedgerTransactionUpdateRequest(source: source, entry: entry)))
    }
    func deleteTransaction(source: TransactionSource, reason: String) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions", method: "DELETE",
            body: json(LedgerTransactionDeleteRequest(source: source, reason: reason)))
    }
    func addTransactionTags(sources: [TransactionSource], tags: [String]) async throws {
        let _: BQLCell = try await mutate("/api/ledger/transactions/tags", method: "POST",
            body: json(LedgerTransactionTagsRequest(sources: sources, tags: tags)))
    }
    func addTransaction(entry: LedgerTransactionEntry) async throws {
        let _: BQLCell = try await mutate("/api/ledger/append", method: "POST", body: json(entry))
    }
    func indexInfo(targetGitSHA: String?) async throws -> LedgerIndexInfo {
        try await read("/api/ledger/index-info")
    }
    func accountDetail(account: String, currency: String, start: String, end: String) async throws -> LedgerAccountDetail {
        try await read("/api/ledger/accounts/detail", query: ["account": account, "currency": currency, "start": start, "end": end])
    }
    func dashboard(start: String, end: String, valuationCurrency: String) async throws -> LedgerDashboard {
        try await read("/api/ledger/dashboard", query: range(start, end, valuationCurrency))
    }
    func incomeStatement(start: String, end: String, valuationCurrency: String) async throws -> LedgerIncomeStatement {
        try await read("/api/ledger/income-statement", query: range(start, end, valuationCurrency))
    }
    func investments() async throws -> LedgerInvestmentSummary { try await read("/api/ledger/investments") }
    func runBQL(query: String, valuationCurrency: String) async throws -> BQLResult {
        try await read("/api/ledger/bql", method: "POST",
            body: .object(["query": .string(query), "valuationCurrency": .string(valuationCurrency)]))
    }

    func files() async throws -> [String] {
        try await workspace.withCurrentSnapshot { _, root in
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            var paths: [String] = []
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "bean" else { continue }
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let normalized = url.standardizedFileURL
                    guard normalized.path.hasPrefix(root.path + "/") else {
                        throw LocalLedgerError.invalidConfiguration("文件路径超出当前账本")
                    }
                    paths.append(String(normalized.path.dropFirst(root.path.count + 1)))
                }
            }
            return paths.sorted()
        }
    }
    func readFile(path: String) async throws -> LocalLedgerFileDraft {
        try validBeanPath(path)
        let snapshot = try await workspace.readFileSnapshot(at: path)
        guard let text = String(data: snapshot.data, encoding: .utf8) else {
            throw LocalLedgerError.invalidConfiguration("文件需要使用 UTF-8 编码")
        }
        return LocalLedgerFileDraft(path: path, text: text, revisionID: snapshot.revision.id)
    }
    func saveFile(_ draft: LocalLedgerFileDraft, text: String) async throws {
        try validBeanPath(draft.path)
        let validator = validator, entry = descriptor.entrypoint
        let revision = try await workspace.commit(expectedRevisionID: draft.revisionID,
            changes: [.write(Data(text.utf8), to: draft.path)]) { root in
                try await validator(root, entry)
            }
        presentedRevisionID = revision.id
        await storage.didCommit(revision)
        NotificationCenter.default.post(name: Self.didSaveNotification, object: descriptor.id)
    }
    func exportLedger() async throws -> URL {
        try await workspace.withCurrentSnapshot { _, root in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("LedgerExport-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.copyItem(at: root, to: destination)
                // A ledger share contains financial files. Imported Git config,
                // reflogs and object history stay in the original local workspace.
                guard let enumerator = FileManager.default.enumerator(at: destination,
                    includingPropertiesForKeys: nil) else {
                    throw LocalLedgerError.operationFailed("无法读取账本导出目录")
                }
                var metadata: [URL] = []
                while let url = enumerator.nextObject() as? URL {
                    if url.lastPathComponent.caseInsensitiveCompare(".git") == .orderedSame {
                        metadata.append(url)
                        enumerator.skipDescendants()
                        continue
                    }
                    #if os(iOS)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
                    #endif
                }
                for url in metadata { try FileManager.default.removeItem(at: url) }
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                #endif
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    // Query history is device-local UI state, kept outside immutable ledger generations.
    func bqlHistory() async throws -> [BQLHistoryRecord] {
        let url = historyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([BQLHistoryRecord].self, from: Data(contentsOf: url))
    }
    func saveBQLHistory(query: String) async throws -> BQLHistoryRecord {
        var records = try await bqlHistory()
        let now = ISO8601DateFormatter().string(from: Date())
        let old = records.first { $0.query == query }
        let record = BQLHistoryRecord(id: old?.id ?? UUID().uuidString, query: query,
            title: old?.title ?? String(query.prefix(60)), titleSource: old?.titleSource ?? "local",
            createdAt: old?.createdAt ?? now, lastRunAt: now, runCount: (old?.runCount ?? 0) + 1)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        try saveHistory(Array(records.prefix(200)))
        return record
    }
    func generateBQLHistoryTitle(id: String) async throws -> BQLHistoryRecord {
        guard let record = try await bqlHistory().first(where: { $0.id == id }) else {
            throw LocalLedgerError.operationFailed("查询记录已移除")
        }
        return try await renameBQLHistory(id: id, title: String(record.query.prefix(60)))
    }
    func renameBQLHistory(id: String, title: String) async throws -> BQLHistoryRecord {
        var records = try await bqlHistory()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw LocalLedgerError.operationFailed("查询记录已移除")
        }
        let old = records[index]
        let record = BQLHistoryRecord(id: old.id, query: old.query, title: title, titleSource: "manual",
            createdAt: old.createdAt, lastRunAt: old.lastRunAt, runCount: old.runCount)
        records[index] = record
        try saveHistory(records)
        return record
    }
    func deleteBQLHistory(id: String) async throws {
        try saveHistory(try await bqlHistory().filter { $0.id != id })
    }

    private var historyURL: URL { workspace.rootDirectory.appendingPathComponent("runtime/bql-history.json") }
    private func saveHistory(_ records: [BQLHistoryRecord]) throws {
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(records).write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(records).write(to: historyURL, options: .atomic)
        #endif
    }
    private func range(_ start: String, _ end: String, _ currency: String) -> [String: String] {
        ["start": start, "end": end, "valuationCurrency": currency]
    }
    private func json<T: Encodable>(_ value: T) throws -> BQLCell {
        try JSONDecoder().decode(BQLCell.self, from: JSONEncoder().encode(value))
    }
    private func validBeanPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasSuffix(".bean"), !path.contains("\\"), !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalLedgerError.invalidConfiguration("请选择账本内的 .bean 文件")
        }
    }
    private func read<T: Decodable>(_ path: String, method: String = "GET", query: [String: String] = [:],
        body: BQLCell? = nil, importFile: LocalLedgerEngineRequest.ImportFile? = nil) async throws -> T {
        let (revision, data) = try await readSnapshot(path, method: method, query: query, body: body, importFile: importFile)
        let result = try JSONDecoder().decode(T.self, from: data)
        presentedRevisionID = revision
        return result
    }
    private func readSnapshot(_ path: String, method: String = "GET", query: [String: String] = [:],
        body: BQLCell? = nil, importFile: LocalLedgerEngineRequest.ImportFile? = nil) async throws -> (UUID, Data) {
        let now = Date()
        if lastRuntimeMaintenance.map({ now.timeIntervalSince($0) >= 60 * 60 }) ?? true {
            // Opportunistic maintenance also runs for read-only app sessions.
            // An active write/preview owns the lock; ordinary reads still proceed.
            if (try? await workspace.maintainImportRuntime(now: now)) != nil {
                lastRuntimeMaintenance = now
            }
            for (id, created) in importPreviewDates where now.timeIntervalSince(created) >= LocalLedgerWorkspace.importPreviewRetention {
                importPreviewDates.removeValue(forKey: id)
                importRevisionIDs.removeValue(forKey: id)
            }
        }
        let engine = engine, entrypoint = descriptor.entrypoint
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        let operation: @Sendable (LocalLedgerWorkspace.Revision, URL) async throws -> (UUID, Data) = { revision, root in
            let data = try await engine.dispatch(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                entrypoint: entrypoint, method: method, path: path, query: query, body: body, importFile: importFile))
            return (revision.id, data)
        }
        if path == "/api/ledger/imports/preview" {
            return try await workspace.withImportPreviewSnapshot(operation)
        }
        return try await workspace.withCurrentSnapshot(operation)
    }
    private actor ResultBox {
        var data: Data?
        func set(_ value: Data) { data = value }
    }
    private func mutate<T: Decodable & Sendable>(_ path: String, method: String, body: BQLCell,
        expected: UUID? = nil, consumingImportID: String? = nil) async throws -> T {
        guard let revisionID = expected ?? presentedRevisionID else { throw LocalLedgerError.previewRequired }
        let engine = engine, validator = validator, entrypoint = descriptor.entrypoint
        let runtimeRoot = workspace.rootDirectory.appendingPathComponent("runtime").path
        let box = ResultBox()
        let revision = try await workspace.commit(expectedRevisionID: revisionID, changes: [],
            consumingImportID: consumingImportID, mutateStage: { root in
            let data = try await engine.dispatch(.init(workspaceRoot: root.path, runtimeRoot: runtimeRoot,
                entrypoint: entrypoint, method: method, path: path, body: body, staging: true))
            // Decode before publication; malformed replies cannot produce a successful financial write.
            _ = try JSONDecoder().decode(T.self, from: data)
            await box.set(data)
        }, validator: { root in try await validator(root, entrypoint) })
        guard let data = await box.data else { throw LocalLedgerError.operationFailed("本地修改缺少结果") }
        presentedRevisionID = revision.id
        await storage.didCommit(revision)
        NotificationCenter.default.post(name: Self.didSaveNotification, object: descriptor.id)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
