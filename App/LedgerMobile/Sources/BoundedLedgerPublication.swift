import Foundation

/// App-owned immutable source generation. URLs are read-only capabilities by
/// contract, not OS-enforced immutability against arbitrary in-process code.
/// Workspace writers cannot mutate/reclaim it; no generation GC exists yet.
struct BoundedSourceLease: Sendable {
    let revisionID: UUID
    let identity: String
    let directory: URL
}

/// The sole authority for the opt-in bounded reader. Never combine this index
/// with LocalLedgerWorkspace.currentRevision(): that pointer may be newer.
/// Derived data is disposable and stays outside exported/synced source trees.
struct BoundedLedgerManifest: Codable, Equatable, Sendable {
    static let maximumBytes = 32 << 10
    let version: Int
    let generationID: UUID
    let sourceRevisionID: UUID
    /// Full workspace tree identity, distinct from parsed-source sourceDigest.
    let sourceIdentity: String
    let index: BoundedIndexManifest

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw BoundedReadIndexError.resourceLimit }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw BoundedReadIndexError.resourceLimit }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BoundedReadIndexError.corrupt }
        try value.validate()
        return value
    }

    private func validate() throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        // Bound even injected/fake manifests before encoding them. This is not
        // a replacement for the Go schema/integrity/count verification in open.
        var bytes = 0
        for value in [index.sourceDigest, index.streamDigest, index.runtime,
                      index.exporter, index.entrypoint, index.revision] {
            guard value.utf8.count <= BoundedIndexWire.manifestLimit - bytes else {
                throw BoundedReadIndexError.resourceLimit
            }
            bytes += value.utf8.count
        }
        guard version == 1, index.schemaVersion == 3, index.streamVersion == 1,
              digest(sourceIdentity), digest(index.sourceDigest), digest(index.streamDigest),
              !index.revision.isEmpty, !index.runtime.isEmpty, !index.exporter.isEmpty,
              index.records >= 0, index.directives >= 0, index.postings >= 0,
              index.options >= 0, index.commodities >= 0, index.metadata >= 0,
              index.transactions >= 0, index.transactions <= index.directives,
              index.directives <= index.records, index.postings <= index.records,
              index.options <= index.records, index.commodities <= index.records,
              index.metadata <= index.records, index.bytes > 0,
              (1...BoundedIndexWire.responseLimit).contains(index.maxRecordBytes) else {
            throw BoundedReadIndexError.corrupt
        }
        _ = try BoundedIndexWire.path(index.entrypoint)
        guard !index.entrypoint.hasPrefix("/"),
              !index.entrypoint.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." }) else {
            throw BoundedReadIndexError.corrupt
        }
    }
}

struct BoundedLedgerReadLease: Sendable {
    let manifest: BoundedLedgerManifest
    let source: BoundedSourceLease
    let derivedDirectory: URL
    /// Status at lease acquisition. A later source commit does not retarget it.
    let isStale: Bool
    var database: URL { derivedDirectory.appendingPathComponent("index.sqlite") }
}

/// Revision-bound query capability: cannot retarget/open/unlock the underlying
/// client. Escaping the scope does not extend its lifetime; scope exit closes it.
struct BoundedLedgerReader: Sendable {
    private let client: BoundedReadIndexClient
    private let revision: String
    private let check: @Sendable () throws -> Void

    fileprivate init(client: BoundedReadIndexClient, revision: String,
                     check: @escaping @Sendable () throws -> Void) {
        self.client = client
        self.revision = revision
        self.check = check
    }
    func priceLookup(base: String, quote: String, date: String? = nil) throws -> BoundedIndexPriceLookupResult {
        try check()
        let result = try client.priceLookup(base: base, quote: quote, date: date)
        try check()
        guard BoundedAccountsValidation.bytes(result.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return result
    }
    func valueLegacyCents(amount: Int64, base: String, quote: String, date: String? = nil) throws -> BoundedIndexLegacyCentsResult {
        try check()
        let result = try client.valueLegacyCents(amount: amount, base: base, quote: quote, date: date)
        try check()
        guard BoundedAccountsValidation.bytes(result.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return result
    }
    func transactions(limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexPage {
        try check()
        let page = try client.transactions(limit: limit, cursor: cursor)
        try check()
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return page
    }
    func accounts(limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexAccountsPage {
        try check()
        let page = try client.accounts(limit: limit, cursor: cursor)
        try check()
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return page
    }
    func accountBalances(account: String, start: String? = nil, end: String? = nil,
                         limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexAccountBalancesPage {
        try check()
        let page = try client.accountBalances(account: account, start: start, end: end, limit: limit, cursor: cursor)
        try check()
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return page
    }
    func accountSummary(account: String, currency: String, start: String? = nil, end: String? = nil) throws -> BoundedIndexAccountSummary {
        try check()
        let summary = try client.accountSummary(account: account, currency: currency, start: start, end: end)
        try check()
        guard BoundedAccountsValidation.bytes(summary.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return summary
    }
    func accountActivity(account: String, currency: String, start: String? = nil, end: String? = nil,
                         limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexAccountActivityPage {
        try check()
        let page = try client.accountActivity(account: account, currency: currency, start: start, end: end, limit: limit, cursor: cursor)
        try check()
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return page
    }
    func detailRecords(id: Int64, limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexDetailPage {
        try check()
        let page = try client.detailRecords(id: id, limit: limit, cursor: cursor)
        try check()
        guard BoundedAccountsValidation.bytes(page.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return page
    }
    func detail(id: Int64) throws -> BoundedIndexDetail {
        try check()
        let detail = try client.detail(id: id)
        try check()
        guard BoundedAccountsValidation.bytes(detail.revision, revision) else { throw BoundedReadIndexError.revisionMismatch }
        return detail
    }
}

/// Opt-in foundation, NOT a replacement for the workspace financial commit API.
/// Publishes only already-confirmed immutable source revisions. The bounded
/// manifest atomically selects BOTH source and index; legacy current.json is
/// untouched. A failed rebuild leaves the last matched manifest on disk. A
/// newer legacy source is represented by an explicit stale lease, never paired
/// with an old index or reconstructed through canonicalModel/legacy snapshots.
///
/// One operation/client per coordinator; the workspace lock also excludes other
/// instances and financial writers during preparation. No all-record arrays,
/// source copy, spool reads, or in-memory index. Source metadata remains bounded
/// by workspace TreeLimits; derived manifests cap at 32 KiB. Protection inherits
/// the existing completeUntilFirstUserAuthentication directory policy; lock is
/// logical invalidation, not an encryption/secure-erasure claim. No cleanup of
/// unreferenced crash artifacts is attempted in this foundation.
/// Reopen verifies source bytes and
/// native integrity once per scope. Keep scopes alive for paged reads, not one
/// reopen per page. Future GC must pin both directories for the entire scope.
final class BoundedLedgerPublication: @unchecked Sendable {
    typealias Exporter = @Sendable (BoundedSourceLease, String, URL, String) async throws -> EmbeddedBeancountValidator.StreamSummary
    typealias ClientFactory = @Sendable (URL) throws -> BoundedReadIndexClient

    private let workspace: LocalLedgerWorkspace
    private let exporter: Exporter
    private let makeClient: ClientFactory
    // All lifecycle state is guarded here. Never hold it across await. Final
    // publication runs under this gate, linearizing it with cancel/lock.
    private let gate = NSLock()
    private var epoch: UInt64 = 0
    private var locked = true
    private var busy = false
    private var client: BoundedReadIndexClient?

    init(workspace: LocalLedgerWorkspace,
         exporter: @escaping Exporter = { lease, entry, directory, name in
             try await EmbeddedBeancountValidator.shared.exportStream(workspace: lease.directory,
                 entryFile: entry, derivedDirectory: directory, spoolName: name)
         },
         makeClient: @escaping ClientFactory = { try BoundedReadIndexClient(derivedDirectory: $0) }) {
        self.workspace = workspace
        self.exporter = exporter
        self.makeClient = makeClient
    }

    /// Authentication belongs to the caller; no automatic unlock/fallback.
    func unlock() { gate.withLock { locked = false } }
    func lock() {
        gate.withLock {
            locked = true
            epoch &+= 1
            // Native lock drains active calls. A suspended exporter cannot be
            // interrupted, but its later result/publication is invalidated.
            client?.lock()
        }
    }
    func cancel() {
        gate.withLock {
            epoch &+= 1
            client?.cancel()
        }
    }

    /// Does not implicitly commit source. The exact revision the user confirmed
    /// is required; concurrent source changes fail rather than rebasing output.
    func rebuild(expectedRevisionID: UUID, entryFile: String = "main.bean") async throws -> BoundedLedgerManifest {
        try await run { token in
            try await self.workspace.prepareBoundedPublication(expectedRevisionID: expectedRevisionID,
                prepare: { lease, directory in
                    try self.check(token)
                    _ = try EmbeddedBeancountValidator.streamPaths(workspace: lease.directory,
                        entryFile: entryFile, derivedDirectory: directory, spoolName: "stream.jsonl")
                    let summary = try await self.exporter(lease, entryFile, directory, "stream.jsonl")
                    try self.check(token)
                    let client = try self.installClient(directory: directory, token: token)
                    // The client canonicalizes its root (e.g. /var -> /private/var).
                    // Resolve fixed artifacts relative to that root, not the workspace alias.
                    let manifest = try client.build(streamPath: "stream.jsonl", destination: "index.sqlite")
                    guard manifest.sourceDigest == summary.sourceDigest,
                          manifest.streamDigest == summary.sha256,
                          manifest.records == summary.records,
                          manifest.directives == summary.directives,
                          manifest.postings == summary.postings,
                          manifest.entrypoint == entryFile else { throw BoundedReadIndexError.revisionMismatch }
                    // Validate even injected manifests before native open encodes.
                    _ = try BoundedLedgerManifest(version: 1, generationID: UUID(),
                        sourceRevisionID: lease.revisionID, sourceIdentity: lease.identity, index: manifest).encoded()
                    try self.check(token)
                    try client.open(databasePath: "index.sqlite", manifest: manifest)
                    // Closed standalone database, never a WAL-dependent artifact.
                    client.close()
                    try self.check(token)
                    return manifest
                }, publish: { commit in
                    try self.gate.withLock {
                        try self.checkLocked(token)
                        try Task.checkCancellation()
                        try commit()
                    }
                })
        }
    }

    /// Clients/URLs must not escape this scope. Previously delivered pages are
    /// the caller's responsibility to clear on lock. Suppresses results produced
    /// by a canceled/locked scope, including a lock followed rapidly by unlock.
    func withReadLease<Value: Sendable>(
        _ operation: @Sendable (BoundedLedgerReadLease, BoundedLedgerReader) async throws -> Value
    ) async throws -> Value {
        try await run { token in
            let lease = try await self.workspace.boundedReadLease()
            try self.check(token)
            let client = try self.installClient(directory: lease.derivedDirectory, token: token)
            try client.open(databasePath: "index.sqlite", manifest: lease.manifest.index)
            try self.check(token)
            let reader = BoundedLedgerReader(client: client, revision: lease.manifest.index.revision,
                                            check: { try self.check(token) })
            return try await operation(lease, reader)
        }
    }

    private func installClient(directory: URL, token: UInt64) throws -> BoundedReadIndexClient {
        try gate.withLock {
            try checkLocked(token)
            let value = try makeClient(directory)
            value.unlock()
            client = value
            return value
        }
    }
    private func checkLocked(_ token: UInt64) throws {
        guard !locked else { throw BoundedReadIndexError.unavailable }
        guard token == epoch else { throw BoundedReadIndexError.canceled }
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        try gate.withLock { try checkLocked(token) }
    }
    private func begin() throws -> UInt64 {
        try gate.withLock {
            guard !locked else { throw BoundedReadIndexError.unavailable }
            guard !busy else { throw BoundedReadIndexError.busy }
            busy = true
            return epoch
        }
    }
    private func finish() {
        gate.withLock {
            client?.close()
            client = nil
            busy = false
        }
    }
    private func run<Value: Sendable>(
        _ operation: (UInt64) async throws -> Value
    ) async throws -> Value {
        let token = try begin()
        defer { finish() }
        return try await withTaskCancellationHandler {
            do {
                let value = try await operation(token)
                try check(token)
                return value
            } catch {
                // Never surface source paths, SQL/backend payloads, or exporter
                // diagnostics. Privacy/cancellation wins over a stale failure.
                try check(token)
                if let error = error as? BoundedReadIndexError { throw error }
                if error as? LocalLedgerWorkspace.WorkspaceError == .staleRevision {
                    throw BoundedReadIndexError.revisionMismatch
                }
                throw BoundedReadIndexError.unavailable
            }
        } onCancel: { self.cancel() }
    }
}
