import Foundation
import Combine

/// Only scalar capabilities cross into the shell. No repository, session or
/// canonical snapshot is reachable through this interface.
struct BoundedBrowserQueries: Sendable {
    let page: @Sendable (String?) throws -> BoundedIndexPage
    let detailRecords: @Sendable (Int64, String?) throws -> BoundedIndexDetailPage
    let accounts: @Sendable (String?) throws -> BoundedIndexAccountsPage
    let accountBalances: @Sendable (String, String?) throws -> BoundedIndexAccountBalancesPage

    let accountSummary: @Sendable (String, String, String?, String?) throws -> BoundedIndexAccountSummary
    let accountActivity: @Sendable (String, String, String?, String?, String?) throws -> BoundedIndexAccountActivityPage

    init(page: @escaping @Sendable (String?) throws -> BoundedIndexPage,
         detailRecords: @escaping @Sendable (Int64, String?) throws -> BoundedIndexDetailPage,
         accounts: @escaping @Sendable (String?) throws -> BoundedIndexAccountsPage = { _ in throw BoundedReadIndexError.unavailable },
         accountBalances: @escaping @Sendable (String, String?) throws -> BoundedIndexAccountBalancesPage = { _, _ in throw BoundedReadIndexError.unavailable },
         accountSummary: @escaping @Sendable (String, String, String?, String?) throws -> BoundedIndexAccountSummary = { _, _, _, _ in throw BoundedReadIndexError.unavailable },
         accountActivity: @escaping @Sendable (String, String, String?, String?, String?) throws -> BoundedIndexAccountActivityPage = { _, _, _, _, _ in throw BoundedReadIndexError.unavailable }) {
        self.page = page
        self.detailRecords = detailRecords
        self.accounts = accounts
        self.accountBalances = accountBalances
        self.accountSummary = accountSummary
        self.accountActivity = accountActivity
    }
}

struct BoundedBrowserLeaseInfo: Sendable {
    let revision: String
    let isStale: Bool
}

protocol BoundedBrowserWorkspace: Sendable {
    func revision() async throws -> UUID
    func rebuild(revision: UUID) async throws
    func read(_ body: @escaping @Sendable (BoundedBrowserLeaseInfo, BoundedBrowserQueries) async throws -> Void) async throws
    /// May drain a blocking native call. Always invoked off MainActor.
    func lock()
}

private struct PublishedBrowserWorkspace: BoundedBrowserWorkspace {
    let workspace: LocalLedgerWorkspace
    let publication: BoundedLedgerPublication
    let entrypoint: String

    func revision() async throws -> UUID {
        guard let revision = try await workspace.currentRevision() else { throw BoundedReadIndexError.unavailable }
        return revision.id
    }
    func rebuild(revision: UUID) async throws {
        _ = try await publication.rebuild(expectedRevisionID: revision, entryFile: entrypoint)
    }
    func read(_ body: @escaping @Sendable (BoundedBrowserLeaseInfo, BoundedBrowserQueries) async throws -> Void) async throws {
        try await publication.withReadLease { lease, reader in
            try await body(.init(revision: lease.manifest.index.revision, isStale: lease.isStale),
                           .init(page: { try reader.transactions(limit: 100, cursor: $0) },
                                 detailRecords: { try reader.detailRecords(id: $0, limit: 100, cursor: $1) },
                                 accounts: { try reader.accounts(limit: 100, cursor: $0) },
                                 accountBalances: { try reader.accountBalances(account: $0, limit: 100, cursor: $1) },
                                 accountSummary: { try reader.accountSummary(account: $0, currency: $1, start: $2, end: $3) },
                                 accountActivity: { try reader.accountActivity(account: $0, currency: $1, start: $2, end: $3, limit: 100, cursor: $4) }))
        }
    }
    func lock() { publication.lock() }
}

struct BoundedBrowserCatalog: Sendable {
    let root: URL
    let descriptors: [LocalLedgerDescriptor]
}

struct BoundedBrowserDependencies: Sendable {
    let available: Bool
    let list: @Sendable () async throws -> BoundedBrowserCatalog
    let workspace: @Sendable (URL, LocalLedgerDescriptor) throws -> any BoundedBrowserWorkspace

    static var live: Self {
        #if LEDGER_BOUNDED_READ_INDEX && canImport(LedgerCore) && canImport(BeancountRuntime)
        let available = true
        #else
        let available = false
        #endif
        return Self(available: available, list: {
            // No appManaged(), repository(), migration, bootstrap or Git operation.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false)
            let root = support.appendingPathComponent("Ledgers", isDirectory: true)
            let catalog = LocalLedgerCatalog(rootDirectory: root)
            let descriptors = try await catalog.list()
            return BoundedBrowserCatalog(root: root, descriptors: descriptors)
        }, workspace: { root, descriptor in
            let workspace = LocalLedgerWorkspace(rootDirectory: root.appendingPathComponent(descriptor.id.uuidString))
            let publication = BoundedLedgerPublication(workspace: workspace)
            publication.unlock()
            return PublishedBrowserWorkspace(workspace: workspace, publication: publication, entrypoint: descriptor.entrypoint)
        })
    }
}

/// Nonblocking logical cancellation, independent of native lock/drain latency.
private final class BoundedBrowserLifetime: @unchecked Sendable {
    private let gate = NSLock()
    private var invalidated = false
    func invalidate() { gate.withLock { invalidated = true } }
    func check() throws {
        try gate.withLock { if invalidated { throw BoundedReadIndexError.canceled } }
        try Task.checkCancellation()
    }
}

/// A single worker holds one read scope open across all pages. The request queue
/// has ONE slot; the UI also permits only one outstanding request. No page or
/// cursor history, all-ledger result or unbounded task-per-row fanout is retained.
@MainActor
final class BoundedLedgerBrowserModel: ObservableObject {
    @Published private(set) var locked = true
    @Published private(set) var busy = false
    @Published private(set) var descriptors: [LocalLedgerDescriptor] = []
    @Published private(set) var selected: LocalLedgerDescriptor?
    enum Mode: String, Sendable { case transactions, accounts }
    @Published private(set) var mode: Mode = .transactions
    @Published private(set) var accountsPage: BoundedIndexAccountsPage?
    @Published private(set) var selectedAccount: BoundedIndexAccountsPage.Account?
    @Published private(set) var balances: BoundedIndexAccountBalancesPage?
    @Published private(set) var selectedCurrency: String?
    @Published private(set) var summary: BoundedIndexAccountSummary?
    @Published private(set) var activity: BoundedIndexAccountActivityPage?
    @Published private(set) var page: BoundedIndexPage?
    @Published private(set) var detail: BoundedIndexDetailPage?
    @Published private(set) var lease: BoundedBrowserLeaseInfo?
    @Published private(set) var confirmation: UUID?
    @Published private(set) var message: String?
    let runtimeAvailable: Bool

    private enum Request: Sendable { case page(String?), detail(Int64, String?), accounts(String?), balances(Int64, String, String?), activity(Int64, String, String, String?) }
    private let authenticator: any LocalLedgerAuthenticating
    private let dependencies: BoundedBrowserDependencies
    private var root: URL?
    private var workspace: (any BoundedBrowserWorkspace)?
    private var worker: Task<Void, Never>?
    private var revisionWorker: Task<Void, Never>?
    private var requests: AsyncStream<(UInt64, Request)>.Continuation?
    private var serial: UInt64 = 0
    private var epoch = UUID()
    private var lifetime = BoundedBrowserLifetime()

    init(authenticator: any LocalLedgerAuthenticating, dependencies: BoundedBrowserDependencies = .live) {
        self.authenticator = authenticator
        self.dependencies = dependencies
        runtimeAvailable = dependencies.available
    }

    func unlock() {
        guard locked, !busy else { return }
        guard runtimeAvailable else { message = "有界读取运行时不可用；不会回退到旧读取模式。"; return }
        guard authenticator.isAvailable else { message = "请先启用设备密码。"; return }
        busy = true
        message = nil
        let token = epoch
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await authenticator.authenticate()
                guard epoch == token, !Task.isCancelled else { return }
                // Authentication is the only main-actor work. Listing is detached.
                let list = dependencies.list
                let listing = Task.detached { try await list() }
                let result = try await withTaskCancellationHandler {
                    try await listing.value
                } onCancel: { listing.cancel() }
                guard epoch == token, !Task.isCancelled else { return }
                root = result.root
                descriptors = result.descriptors
                locked = false
                busy = false
            } catch {
                guard epoch == token else { return }
                busy = false
                message = "未能解锁或读取本地目录。没有打开任何账本。"
            }
        }
    }

    /// Synchronous privacy boundary, before any native cancellation can block.
    /// The native runtime may finish its current call; epoch checks suppress it.
    func lock() {
        retire()
        locked = true
        mode = .transactions
        busy = false
        descriptors = []
        root = nil
        selected = nil
        confirmation = nil
        message = nil
    }

    func select(_ descriptor: LocalLedgerDescriptor) {
        guard !locked, !busy, descriptors.contains(descriptor), let root else { return }
        retire()
        mode = .transactions
        selected = descriptor
        confirmation = nil
        message = nil
        do { workspace = try dependencies.workspace(root, descriptor) }
        catch { message = "本地工作区不可用。" }
        // Deliberately no implicit open or build on selection.
    }

    func open() {
        guard !locked, !busy, let workspace, lease == nil else { return }
        startReader(workspace, rebuild: nil)
    }

    func prepareBuild() {
        guard !locked, !busy, let workspace else { return }
        busy = true
        message = nil
        let token = epoch
        // Keep the existing scope alive while reading only the revision pointer.
        workerForRevision(workspace, token: token)
    }

    private func workerForRevision(_ workspace: any BoundedBrowserWorkspace, token: UUID) {
        // This bounded pointer lookup is independent of the reader worker. Its
        // result is invalidated by the same epoch on lock/selection/background.
        revisionWorker = Task.detached { [weak self] in
            do {
                try Task.checkCancellation()
                let revision = try await workspace.revision()
                await self?.prepared(revision, token: token)
            } catch { await self?.failed(error, token: token) }
        }
    }

    private func prepared(_ revision: UUID, token: UUID) {
        guard epoch == token, !locked else { return }
        confirmation = revision
        busy = false
    }

    func dismissConfirmation() { confirmation = nil }

    func confirmBuild() {
        guard !locked, !busy, let revision = confirmation, let oldWorkspace = workspace,
              let root, let selected else { return }
        confirmation = nil
        // Drain the existing read scope before attempting a rebuild. A new
        // publication prevents a canceled client's lock epoch being reused.
        let oldWorker = worker
        retire()
        busy = true
        let token = epoch
        let factory = dependencies.workspace
        worker = Task.detached { [weak self] in
            oldWorkspace.lock()
            await oldWorker?.value
            do {
                try Task.checkCancellation()
                let next = try factory(root, selected)
                await self?.beginConfirmedBuild(next, revision: revision, token: token)
            } catch { await self?.failed(error, token: token) }
        }
    }

    private func beginConfirmedBuild(_ next: any BoundedBrowserWorkspace, revision: UUID, token: UUID) {
        guard epoch == token, !locked else {
            Task.detached { next.lock() }
            return
        }
        workspace = next
        startReader(next, rebuild: revision)
    }

    private func startReader(_ workspace: any BoundedBrowserWorkspace, rebuild: UUID?) {
        busy = true
        message = nil
        page = nil
        detail = nil
        accountsPage = nil
        selectedAccount = nil
        balances = nil
        clearActivity()
        let token = epoch
        let lifetime = lifetime
        let initialMode = mode
        let initialSerial = serial
        let (stream, continuation) = AsyncStream<(UInt64, Request)>.makeStream(bufferingPolicy: .bufferingOldest(1))
        requests = continuation
        worker = Task.detached { [weak self] in
            defer { continuation.finish() }
            do {
                try lifetime.check()
                if let rebuild { try await workspace.rebuild(revision: rebuild) }
                try lifetime.check()
                try await workspace.read { [weak self] info, queries in
                    try lifetime.check()
                    switch initialMode {
                    case .transactions:
                        let first = try queries.page(nil)
                        try Self.validate(first, revision: info.revision)
                        await self?.received(first, info: info, token: token, serial: initialSerial)
                    case .accounts:
                        let first = try queries.accounts(nil)
                        try Self.validate(first, revision: info.revision, cursor: nil)
                        await self?.received(first, info: info, token: token, serial: initialSerial)
                    }
                    for await (serial, request) in stream {
                        try lifetime.check()
                        switch request {
                        case .page(let cursor):
                            let page = try queries.page(cursor)
                            try Self.validate(page, revision: info.revision)
                            await self?.received(page, info: info, token: token, serial: serial)
                        case .accounts(let cursor):
                            let page = try queries.accounts(cursor)
                            try Self.validate(page, revision: info.revision, cursor: cursor)
                            await self?.received(page, info: info, token: token, serial: serial)
                        case .balances(let openID, let account, let cursor):
                            let page = try queries.accountBalances(account, cursor)
                            guard page.balances.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
                            try page.validate(account: account, start: nil, end: nil, limit: 100, cursor: cursor)
                            guard BoundedAccountsValidation.bytes(page.revision, info.revision) else { throw BoundedReadIndexError.revisionMismatch }
                            await self?.received(page, openID: openID, token: token, serial: serial)
                        case .activity(let openID, let account, let currency, let cursor):
                            let summary = try queries.accountSummary(account, currency, nil, nil)
                            try lifetime.check()
                            try summary.validate(account: account, currency: currency, start: nil, end: nil)
                            guard BoundedAccountsValidation.bytes(summary.revision, info.revision) else { throw BoundedReadIndexError.revisionMismatch }
                            let page = try queries.accountActivity(account, currency, nil, nil, cursor)
                            try lifetime.check()
                            guard page.rows.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
                            try page.validate(account: account, currency: currency, start: nil, end: nil, limit: 100, cursor: cursor)
                            guard BoundedAccountsValidation.bytes(page.revision, info.revision) else { throw BoundedReadIndexError.revisionMismatch }
                            await self?.received(summary, activity: page, openID: openID, token: token, serial: serial)
                        case .detail(let id, let cursor):
                            let detail = try queries.detailRecords(id, cursor)
                            guard detail.records.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
                            try detail.validate(id: id, limit: 100, cursor: cursor)
                            guard detail.id == id, BoundedAccountsValidation.bytes(detail.revision, info.revision) else {
                                throw BoundedReadIndexError.revisionMismatch
                            }
                            await self?.received(detail, token: token, serial: serial)
                        }
                    }
                }
            } catch { await self?.failed(error, token: token) }
        }
    }

    nonisolated private static func validate(_ page: BoundedIndexPage, revision: String) throws {
        guard page.transactions.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
    }

    nonisolated private static func validate(_ page: BoundedIndexAccountsPage, revision: String, cursor: String?) throws {
        guard page.accounts.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
        try page.validate(limit: 100, cursor: cursor)
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
    }

    /// Mode changes keep the same scoped reader; no reopen or legacy fallback.
    func setMode(_ value: Mode) {
        guard !locked, !busy, mode != value else { return }
        mode = value
        page = nil
        detail = nil
        accountsPage = nil
        selectedAccount = nil
        balances = nil
        clearActivity()
        if lease != nil { send(value == .accounts ? .accounts(nil) : .page(nil)) }
    }
    func nextAccountsPage() {
        guard mode == .accounts, let cursor = accountsPage?.nextCursor else { return }
        send(.accounts(cursor))
    }
    func firstAccountsPage() { if mode == .accounts { send(.accounts(nil)) } }
    func selectAccount(_ openID: Int64) {
        guard !locked, !busy, mode == .accounts,
              let row = accountsPage?.accounts.first(where: { $0.openID == openID }),
              BoundedAccountsValidation.account(row.account) else { return }
        selectedAccount = row
        send(.balances(row.openID, row.account, nil))
    }
    func nextBalancesPage() {
        guard let account = selectedAccount, let cursor = balances?.nextCursor else { return }
        send(.balances(account.openID, account.account, cursor))
    }
    func firstBalancesPage() {
        guard let account = selectedAccount else { return }
        send(.balances(account.openID, account.account, nil))
    }
    func selectCurrency(_ currency: String) {
        guard !locked, !busy, mode == .accounts, let account = selectedAccount,
              BoundedAccountsValidation.account(currency),
              balances?.balances.contains(where: { BoundedAccountsValidation.bytes($0.currency, currency) }) == true else { return }
        clearActivity()
        selectedCurrency = currency
        send(.activity(account.openID, account.account, currency, nil))
    }
    func firstActivityPage() {
        guard let account = selectedAccount, let currency = selectedCurrency else { return }
        send(.activity(account.openID, account.account, currency, nil))
    }
    func nextActivityPage() {
        guard let account = selectedAccount, let currency = selectedCurrency, let cursor = activity?.nextCursor else { return }
        send(.activity(account.openID, account.account, currency, cursor))
    }
    func showActivityDetail(_ id: Int64) {
        guard mode == .accounts, selectedCurrency != nil, activity?.rows.contains(where: { $0.id == id }) == true else { return }
        send(.detail(id, nil))
    }
    private func clearActivity() {
        selectedCurrency = nil
        summary = nil
        activity = nil
    }

    func showAccountMetadata() {
        guard mode == .accounts, let selectedAccount else { return }
        send(.detail(selectedAccount.openID, nil))
    }

    func nextPage() {
        guard mode == .transactions, let cursor = page?.nextCursor else { return }
        send(.page(cursor))
    }
    func firstPage() { if mode == .transactions { send(.page(nil)) } }
    func showDetail(_ id: Int64) {
        guard mode == .transactions, page?.transactions.contains(where: { $0.id == id }) == true else { return }
        send(.detail(id, nil))
    }
    func nextDetailPage() {
        guard let detail, let cursor = detail.nextCursor else { return }
        send(.detail(detail.id, cursor))
    }
    func firstDetailPage() {
        guard let detail else { return }
        send(.detail(detail.id, nil))
    }
    func dismissDetail() { if !busy { detail = nil } }

    private func send(_ request: Request) {
        guard !locked, !busy, let requests, lease != nil else { return }
        busy = true
        message = nil
        serial &+= 1
        detail = nil
        switch request {
        case .page:
            page = nil
        case .accounts:
            accountsPage = nil
            selectedAccount = nil
            balances = nil
            clearActivity()
        case .balances:
            balances = nil
            clearActivity()
        case .activity:
            summary = nil
            activity = nil
        case .detail: break
        }
        if case .enqueued = requests.yield((serial, request)) { return }
        failed(BoundedReadIndexError.busy, token: epoch)
    }

    private func received(_ page: BoundedIndexPage, info: BoundedBrowserLeaseInfo, token: UUID, serial: UInt64) {
        guard epoch == token, self.serial == serial, !locked else { return }
        self.page = page // Replacement, never append.
        lease = info
        busy = false
    }
    private func received(_ page: BoundedIndexAccountsPage, info: BoundedBrowserLeaseInfo, token: UUID, serial: UInt64) {
        guard epoch == token, self.serial == serial, !locked, mode == .accounts else { return }
        accountsPage = page // Replacement, never append.
        lease = info
        busy = false
    }
    private func received(_ page: BoundedIndexAccountBalancesPage, openID: Int64, token: UUID, serial: UInt64) {
        guard epoch == token, self.serial == serial, !locked, mode == .accounts,
              selectedAccount?.openID == openID, let account = selectedAccount?.account, account.utf8.elementsEqual(page.account.utf8) else { return }
        balances = page // Only this account's current currency page is retained.
        busy = false
    }
    private func received(_ detail: BoundedIndexDetailPage, token: UUID, serial: UInt64) {
        guard epoch == token, self.serial == serial, !locked else { return }
        self.detail = detail // Replacement, never append or retain a previous detail page.
        busy = false
    }
    private func received(_ summary: BoundedIndexAccountSummary, activity: BoundedIndexAccountActivityPage,
                          openID: Int64, token: UUID, serial: UInt64) {
        guard epoch == token, self.serial == serial, !locked, mode == .accounts,
              selectedAccount?.openID == openID, let account = selectedAccount?.account,
              let currency = selectedCurrency, BoundedAccountsValidation.bytes(account, summary.account),
              BoundedAccountsValidation.bytes(currency, summary.currency) else { return }
        self.summary = summary
        self.activity = activity // Replace only, including terminal empty pages.
        busy = false
    }
    private func failed(_ error: any Error, token: UUID) {
        guard epoch == token, !locked else { return }
        requests?.finish()
        requests = nil
        page = nil
        detail = nil
        accountsPage = nil
        selectedAccount = nil
        balances = nil
        clearActivity()
        lease = nil
        confirmation = nil
        busy = false
        // Never expose runtime messages, paths, source data or decoder errors.
        switch error as? BoundedReadIndexError {
        case .resourceLimit: message = "超过读取上限（每页 100 条，单次响应 1 MiB）；不会截断或回退。"
        case .revisionMismatch: message = "版本不一致。请重新选择账本并确认重建索引。"
        case .corrupt, .invalidStream: message = "索引未通过校验。请确认重建；不会使用旧快照。"
        default: message = "索引或运行时不可用。可明确确认构建索引；不会自动回退。"
        }
    }

    private func retire() {
        lifetime.invalidate()
        lifetime = BoundedBrowserLifetime()
        epoch = UUID()
        requests?.finish()
        requests = nil
        let oldWorker = worker
        let oldRevisionWorker = revisionWorker
        revisionWorker = nil
        let oldWorkspace = workspace
        worker = nil
        workspace = nil
        page = nil
        detail = nil
        accountsPage = nil
        selectedAccount = nil
        balances = nil
        clearActivity()
        lease = nil
        Task.detached {
            // Task.cancel invokes publication cancellation handlers synchronously.
            // Keep both it and native lock/drain away from the UI thread.
            oldWorker?.cancel()
            oldRevisionWorker?.cancel()
            oldWorkspace?.lock()
        }
    }
}
