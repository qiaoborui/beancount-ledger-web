import Foundation
#if canImport(LedgerCore) && LEDGER_BOUNDED_READ_INDEX
import LedgerCore
#endif

/// Opt-in transport only (native linkage requires LEDGER_BOUNDED_READ_INDEX). Owns no source publication, authentication, or legacy snapshot.
/// The caller must freeze source generations and protect the derived directory before use.
protocol BoundedReadIndexBackend: Sendable {
    func build(_ streamPath: String, destination: String) -> String
    func open(_ databasePath: String, manifestJSON: String) -> String
    func transactions(_ requestJSON: String) -> String
    func detail(_ id: Int64) -> String
    func unlock()
    func cancel()
    func lock()
    func close()
}

enum BoundedReadIndexError: String, Error, Sendable {
    case unavailable, canceled, busy, invalidRequest = "invalid_request"
    case invalidCursor = "invalid_cursor", revisionMismatch = "revision_mismatch"
    case notFound = "not_found", resourceLimit = "resource_limit", corrupt
    case invalidStream = "invalid_stream", exists
}

struct BoundedIndexManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let streamVersion: Int
    let sourceDigest: String
    let runtime: String
    let exporter: String
    let entrypoint: String
    let streamDigest: String
    let records: Int64
    let directives: Int64
    let postings: Int64
    let options: Int64
    let commodities: Int64
    let metadata: Int64
    let transactions: Int64
    let bytes: Int64
    let maxRecordBytes: Int
    let revision: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", streamVersion = "stream_version"
        case sourceDigest = "source_digest", streamDigest = "stream_digest"
        case maxRecordBytes = "max_record_bytes"
        case runtime, exporter, entrypoint, records, directives, postings, options
        case commodities, metadata, transactions, bytes, revision
    }
}

/// A deliberately scalar projection, not an editable/canonical record graph.
/// Tags, links, custom values and metadata values are NOT represented here.
/// Exact quantities remain strings; this client performs no accounting arithmetic.
struct BoundedIndexRecord: Decodable, Sendable {
    struct Amount: Decodable, Sendable, Equatable {
        let number: String
        let currency: String
        enum CodingKeys: String, CodingKey { case number = "Number", currency = "Currency" }
    }
    struct Directive: Decodable, Sendable {
        let kind: String
        let date: String
        let file: String
        let line: Int
        let flag: String?
        let payee: String?
        let narration: String?
        enum CodingKeys: String, CodingKey {
            case kind = "Kind", date = "Date", file = "File", line = "Line"
            case flag = "Flag", payee = "Payee", narration = "Narration"
        }
    }
    struct Posting: Decodable, Sendable {
        let account: String
        let quantity: Amount
        let cost: Amount?
        let price: Amount?
        let costDate: String?
        let costLabel: String?
        let flag: String?
        enum CodingKeys: String, CodingKey {
            case account, flag, quantity = "Quantity", cost = "Cost", price = "Price"
            case costDate = "CostDate", costLabel = "CostLabel"
        }
    }
    enum Value: Sendable {
        case directive(id: Int64, Directive)
        case posting(entryID: Int64, ordinal: Int, Posting)
        /// Only identity/type is exposed: arbitrary nested metadata is intentionally omitted.
        case metadata(entryID: Int64, posting: Int, key: String, valueType: String)
    }
    let value: Value
    private enum CodingKeys: String, CodingKey { case type, id, entryID = "entry_id", ordinal, posting, key, value }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "directive":
            value = .directive(id: try c.decode(Int64.self, forKey: .id), try c.decode(Directive.self, forKey: .value))
        case "posting":
            value = .posting(entryID: try c.decode(Int64.self, forKey: .entryID), ordinal: try c.decode(Int.self, forKey: .ordinal), try c.decode(Posting.self, forKey: .value))
        case "metadata":
            struct MetadataType: Decodable { let type: String }
            value = .metadata(entryID: try c.decode(Int64.self, forKey: .entryID), posting: try c.decode(Int.self, forKey: .posting), key: try c.decode(String.self, forKey: .key), valueType: try c.decode(MetadataType.self, forKey: .value).type)
        default: throw BoundedReadIndexError.corrupt
        }
    }
}

struct BoundedIndexPage: Decodable, Sendable {
    struct Transaction: Decodable, Sendable {
        let id: Int64
        let date: String
        let record: BoundedIndexRecord
    }
    let revision: String
    let transactions: [Transaction]
    let nextCursor: String?
    private enum CodingKeys: String, CodingKey { case revision, transactions, nextCursor = "next_cursor" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(String.self, forKey: .revision)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        // Go may encode an empty nil slice as null.
        if try c.decodeNil(forKey: .transactions) { transactions = []; return }
        var rows = try c.nestedUnkeyedContainer(forKey: .transactions)
        var result: [Transaction] = []
        while !rows.isAtEnd {
            guard result.count < 500 else { throw BoundedReadIndexError.resourceLimit }
            result.append(try rows.decode(Transaction.self))
        }
        transactions = result
    }
}

struct BoundedIndexDetail: Decodable, Sendable {
    let revision: String
    let id: Int64
    let records: [BoundedIndexRecord]
    // The 1 MiB transport cap also bounds the number of detail records. No full ledger graph.
}

/// Byte caps apply BEFORE Data/JSONDecoder allocation, including on fake backends.
/// Errors never retain or surface backend JSON, paths, or decoder descriptions.
enum BoundedIndexWire {
    static let manifestLimit = 16 << 10
    static let responseLimit = 1 << 20
    static func decode<T: Decodable>(_ type: T.Type, json: String, limit: Int) throws -> T {
        guard json.utf8.count <= limit else { throw BoundedReadIndexError.resourceLimit }
        let data = Data(json.utf8)
        do {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
            if let error = envelope?.error {
                throw BoundedReadIndexError(rawValue: error.code) ?? .unavailable
            }
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch let error as BoundedReadIndexError { throw error }
        catch { throw BoundedReadIndexError.corrupt }
    }
    private struct ErrorEnvelope: Decodable {
        struct Failure: Decodable { let code: String }
        let error: Failure?
    }
    static func path(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw BoundedReadIndexError.invalidRequest }
        return path
    }
    static func resolvedDirectory(_ url: URL) throws -> String {
        guard url.isFileURL else { throw BoundedReadIndexError.invalidRequest }
        _ = try path(url.path)
        // iOS /var and host /tmp can be system aliases. Resolve the supplied root,
        // not untrusted child paths (the native bridge rejects child symlinks).
        return try path(url.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}

/// Synchronous calls may be scheduled off the main actor. Unlike an actor wrapping
/// blocking Go calls, cancel/lock remain reachable while a native operation runs.
/// `state` protects all mutable Swift state; `gate` serializes lock/unlock/close.
/// Backend implementations must support concurrent cancellation and privacy transitions.
/// Results delivered before lock/cancel must still be discarded by the caller;
/// this foundation does not clear UI state or manage revision leases.
final class BoundedReadIndexClient: @unchecked Sendable {
    private let backend: any BoundedReadIndexBackend
    private let state = NSCondition()
    private let gate = NSLock()
    private var epoch: UInt64 = 0
    private var locked = true
    private var closed = false
    private var busy = false

    init(backend: any BoundedReadIndexBackend) { self.backend = backend }
    convenience init(derivedDirectory: URL) throws {
        let path = try BoundedIndexWire.resolvedDirectory(derivedDirectory)
        #if canImport(LedgerCore) && LEDGER_BOUNDED_READ_INDEX
        self.init(backend: NativeBoundedReadIndexBackend(root: path))
        #else
        _ = path
        self.init(backend: UnavailableBoundedReadIndexBackend())
        #endif
    }
    deinit { backend.close() }

    /// Caller authenticates first. Does not reopen a reader or revive a closed client.
    func unlock() {
        gate.lock(); defer { gate.unlock() }
        state.lock(); defer { state.unlock() }
        guard !closed, locked else { return }
        backend.unlock()
        epoch &+= 1
        locked = false
    }
    func cancel() {
        state.lock(); defer { state.unlock() }
        epoch &+= 1
        backend.cancel()
    }
    func lock() { stop(permanently: false) }
    func close() { stop(permanently: true) }
    private func stop(permanently: Bool) {
        gate.lock(); defer { gate.unlock() }
        state.lock()
        locked = true
        closed = closed || permanently
        epoch &+= 1
        state.unlock()
        // Do not hold state while native Lock waits for in-flight work.
        if permanently { backend.close() } else { backend.lock() }
        // Also drain Swift decoding and calls admitted just before the native
        // privacy transition. Unlock cannot overtake a not-yet-entered Go call.
        state.lock()
        while busy { state.wait() }
        state.unlock()
    }
    private func run<T>(_ operation: () throws -> T) throws -> T {
        state.lock()
        guard !locked, !closed else { state.unlock(); throw BoundedReadIndexError.unavailable }
        guard !busy else { state.unlock(); throw BoundedReadIndexError.busy }
        busy = true
        let token = epoch
        state.unlock()
        let result = Result { try operation() }
        state.lock(); defer { state.unlock() }
        busy = false
        state.broadcast()
        guard !locked, !closed else { throw BoundedReadIndexError.unavailable }
        guard epoch == token else { throw BoundedReadIndexError.canceled }
        return try result.get()
    }
    func build(streamPath: String, destination: String) throws -> BoundedIndexManifest {
        try run {
            let json = backend.build(try BoundedIndexWire.path(streamPath), destination: try BoundedIndexWire.path(destination))
            return try BoundedIndexWire.decode(BoundedIndexManifest.self, json: json, limit: BoundedIndexWire.manifestLimit)
        }
    }
    @discardableResult
    func open(databasePath: String, manifest: BoundedIndexManifest) throws -> String {
        try run {
            // A manifest may be constructed by a caller rather than returned by
            // Build. Bound scalar inputs before allocating its encoded request.
            let strings = [manifest.sourceDigest, manifest.runtime, manifest.exporter,
                           manifest.entrypoint, manifest.streamDigest, manifest.revision]
            var bytes = 0
            for value in strings {
                let count = value.utf8.count
                guard count <= BoundedIndexWire.manifestLimit - bytes else { throw BoundedReadIndexError.resourceLimit }
                bytes += count
            }
            let data = try JSONEncoder().encode(manifest)
            guard data.count <= BoundedIndexWire.manifestLimit else { throw BoundedReadIndexError.resourceLimit }
            struct OpenResult: Decodable { let revision: String }
            let result = try BoundedIndexWire.decode(OpenResult.self, json: backend.open(try BoundedIndexWire.path(databasePath), manifestJSON: String(decoding: data, as: UTF8.self)), limit: BoundedIndexWire.manifestLimit)
            guard result.revision == manifest.revision else { throw BoundedReadIndexError.revisionMismatch }
            return result.revision
        }
    }
    func transactions(limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexPage {
        try run {
            guard (1...500).contains(limit), (cursor?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.invalidRequest }
            struct Request: Encodable { let limit: Int; let cursor: String? }
            let data = try JSONEncoder().encode(Request(limit: limit, cursor: cursor))
            guard data.count <= 4096 else { throw BoundedReadIndexError.resourceLimit }
            let page = try BoundedIndexWire.decode(BoundedIndexPage.self, json: backend.transactions(String(decoding: data, as: UTF8.self)), limit: BoundedIndexWire.responseLimit)
            guard page.transactions.count <= limit, (page.nextCursor?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.corrupt }
            for row in page.transactions {
                guard row.id > 0, case let .directive(id, directive) = row.record.value,
                      row.id == id, row.date == directive.date, directive.kind == "transaction" else { throw BoundedReadIndexError.corrupt }
            }
            return page
        }
    }
    func detail(id: Int64) throws -> BoundedIndexDetail {
        try run {
            guard id > 0 else { throw BoundedReadIndexError.invalidRequest }
            let result = try BoundedIndexWire.decode(BoundedIndexDetail.self, json: backend.detail(id), limit: BoundedIndexWire.responseLimit)
            guard result.id == id, let first = result.records.first,
                  case let .directive(firstID, _) = first.value, firstID == id else { throw BoundedReadIndexError.corrupt }
            for (offset, record) in result.records.enumerated() {
                switch record.value {
                case let .directive(recordID, _):
                    guard offset == 0, recordID == id else { throw BoundedReadIndexError.corrupt }
                case let .posting(entryID, ordinal, _):
                    guard entryID == id, ordinal >= 0 else { throw BoundedReadIndexError.corrupt }
                case let .metadata(entryID, posting, _, _):
                    guard entryID == id, posting >= -1 else { throw BoundedReadIndexError.corrupt }
                }
            }
            return result
        }
    }
}

#if canImport(LedgerCore) && LEDGER_BOUNDED_READ_INDEX
/// Selectors verified against gobind's Mobilereadindex.objc.h. Apple compilation
/// remains required: host Go tests cannot validate Swift import or SQLite linkage.
private final class NativeBoundedReadIndexBackend: BoundedReadIndexBackend, @unchecked Sendable {
    private let bridge: MobilereadindexBridge?
    init(root: String) { bridge = MobilereadindexNewBridge(root) }
    func build(_ streamPath: String, destination: String) -> String { bridge?.build(streamPath, destination: destination) ?? unavailable }
    func open(_ databasePath: String, manifestJSON: String) -> String { bridge?.open(databasePath, manifestJSON: manifestJSON) ?? unavailable }
    func transactions(_ requestJSON: String) -> String { bridge?.transactions(requestJSON) ?? unavailable }
    func detail(_ id: Int64) -> String { bridge?.detail(id) ?? unavailable }
    func unlock() { bridge?.unlock() }
    func cancel() { bridge?.cancel() }
    func lock() { bridge?.lock() }
    func close() { bridge?.close() }
    private var unavailable: String { #"{"error":{"code":"unavailable"}}"# }
}
#else
private struct UnavailableBoundedReadIndexBackend: BoundedReadIndexBackend {
    private var unavailable: String { #"{"error":{"code":"unavailable"}}"# }
    func build(_ streamPath: String, destination: String) -> String { unavailable }
    func open(_ databasePath: String, manifestJSON: String) -> String { unavailable }
    func transactions(_ requestJSON: String) -> String { unavailable }
    func detail(_ id: Int64) -> String { unavailable }
    func unlock() {}
    func cancel() {}
    func lock() {}
    func close() {}
}
#endif
