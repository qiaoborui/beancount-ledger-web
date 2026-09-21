import Foundation
import Combine

/// Only scalar capabilities cross into the shell. No repository, session or
/// canonical snapshot is reachable through this interface.
struct BoundedBrowserQueries: Sendable {
    let page: @Sendable (String?) throws -> BoundedIndexPage
    let detail: @Sendable (Int64) throws -> BoundedIndexDetail
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
                                 detail: { try reader.detail(id: $0) }))
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
    @Published private(set) var page: BoundedIndexPage?
    @Published private(set) var detail: BoundedIndexDetail?
    @Published private(set) var lease: BoundedBrowserLeaseInfo?
    @Published private(set) var confirmation: UUID?
    @Published private(set) var message: String?
    let runtimeAvailable: Bool

    private enum Request: Sendable { case page(String?), detail(Int64) }
    private let authenticator: any LocalLedgerAuthenticating
    private let dependencies: BoundedBrowserDependencies
    private var root: URL?
    private var workspace: (any BoundedBrowserWorkspace)?
    private var worker: Task<Void, Never>?
    private var revisionWorker: Task<Void, Never>?
    private var requests: AsyncStream<Request>.Continuation?
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
        let token = epoch
        let lifetime = lifetime
        let (stream, continuation) = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingOldest(1))
        requests = continuation
        worker = Task.detached { [weak self] in
            defer { continuation.finish() }
            do {
                try lifetime.check()
                if let rebuild { try await workspace.rebuild(revision: rebuild) }
                try lifetime.check()
                try await workspace.read { [weak self] info, queries in
                    try lifetime.check()
                    let first = try queries.page(nil)
                    try Self.validate(first, revision: info.revision)
                    await self?.received(first, info: info, token: token)
                    for await request in stream {
                        try lifetime.check()
                        switch request {
                        case .page(let cursor):
                            let page = try queries.page(cursor)
                            try Self.validate(page, revision: info.revision)
                            await self?.received(page, info: info, token: token)
                        case .detail(let id):
                            let detail = try queries.detail(id)
                            guard detail.id == id, detail.revision == info.revision else {
                                throw BoundedReadIndexError.revisionMismatch
                            }
                            await self?.received(detail, token: token)
                        }
                    }
                }
            } catch { await self?.failed(error, token: token) }
        }
    }

    nonisolated private static func validate(_ page: BoundedIndexPage, revision: String) throws {
        guard page.transactions.count <= 100 else { throw BoundedReadIndexError.resourceLimit }
        guard page.revision == revision else { throw BoundedReadIndexError.revisionMismatch }
    }

    func nextPage() {
        guard let cursor = page?.nextCursor else { return }
        send(.page(cursor))
    }
    func firstPage() { send(.page(nil)) }
    func showDetail(_ id: Int64) {
        guard page?.transactions.contains(where: { $0.id == id }) == true else { return }
        send(.detail(id))
    }
    func dismissDetail() { if !busy { detail = nil } }

    private func send(_ request: Request) {
        guard !locked, !busy, let requests, lease != nil else { return }
        busy = true
        detail = nil
        if case .page = request { page = nil }
        if case .enqueued = requests.yield(request) { return }
        failed(BoundedReadIndexError.busy, token: epoch)
    }

    private func received(_ page: BoundedIndexPage, info: BoundedBrowserLeaseInfo, token: UUID) {
        guard epoch == token, !locked else { return }
        self.page = page // Replacement, never append.
        lease = info
        busy = false
    }
    private func received(_ detail: BoundedIndexDetail, token: UUID) {
        guard epoch == token, !locked else { return }
        self.detail = detail
        busy = false
    }
    private func failed(_ error: any Error, token: UUID) {
        guard epoch == token, !locked else { return }
        requests?.finish()
        requests = nil
        page = nil
        detail = nil
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
