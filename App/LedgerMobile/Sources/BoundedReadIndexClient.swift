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
    func accounts(_ requestJSON: String) -> String
    func accountBalances(_ requestJSON: String) -> String
    func detail(_ id: Int64) -> String
    func detailRecords(_ requestJSON: String) -> String
    func unlock()
    func cancel()
    func lock()
    func close()
}

/// Existing backends/fakes remain source compatible; never fall back to the
/// whole-detail endpoint, which can exceed its all-or-error response cap.
extension BoundedReadIndexBackend {
    func accounts(_ requestJSON: String) -> String { #"{"error":{"code":"unavailable"}}"# }
    func accountBalances(_ requestJSON: String) -> String { #"{"error":{"code":"unavailable"}}"# }
    func detailRecords(_ requestJSON: String) -> String { #"{"error":{"code":"unavailable"}}"# }
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
        let account: String?
        let currencies: [String]?
        let booking: String?
        enum CodingKeys: String, CodingKey {
            case kind = "Kind", date = "Date", file = "File", line = "Line"
            case flag = "Flag", payee = "Payee", narration = "Narration"
            case account = "Account", currencies = "Currencies", booking = "Booking"
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

/// Explicit opens only; not inferred from postings, and not an active-as-of catalog.
/// Account keys use backend UTF-8 byte identity, not Swift Unicode equivalence.
struct BoundedIndexAccountsPage: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let account: String
        let openID: Int64
        let openDate: String
        let closeDate: String?
        let openRecord: BoundedIndexRecord
        enum CodingKeys: String, CodingKey {
            case account, openID = "open_id", openDate = "open_date"
            case closeDate = "close_date", openRecord = "open_record"
        }
    }
    let revision: String
    let accounts: [Account]
    let nextCursor: String?
    private enum CodingKeys: String, CodingKey { case revision, accounts, nextCursor = "next_cursor" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(String.self, forKey: .revision)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        accounts = try c.boundedRows(Account.self, forKey: .accounts)
    }
    func validate(limit: Int, cursor: String?) throws {
        try BoundedAccountsValidation.page(count: accounts.count, limit: limit, next: nextCursor, cursor: cursor)
        var previous: String?
        var openIDs = Set<Int64>() // Bounded by the decoded page cap (500).
        for row in accounts {
            guard row.openID > 0, openIDs.insert(row.openID).inserted,
                  BoundedAccountsValidation.date(row.openDate),
                  row.closeDate.map(BoundedAccountsValidation.date) ?? true,
                  case let .directive(id, value) = row.openRecord.value,
                  id == row.openID, value.kind == "open",
                  let account = value.account, account.utf8.elementsEqual(row.account.utf8),
                  value.date == row.openDate else { throw BoundedReadIndexError.corrupt }
            if let previous, !previous.utf8.lexicographicallyPrecedes(row.account.utf8) {
                throw BoundedReadIndexError.corrupt
            }
            previous = row.account
        }
    }
}

/// Exact native posting-unit sums. No valuation, lots, opening or running balance.
/// Deliberately never parsed as Double, Decimal, cents, or a money formatter input.
struct BoundedIndexAccountBalancesPage: Decodable, Sendable {
    struct Balance: Decodable, Sendable {
        let currency: String
        let quantity: String
    }
    let revision: String
    let basis: String
    let account: String
    let start: String?
    let end: String?
    let balances: [Balance]
    let nextCursor: String?
    private enum CodingKeys: String, CodingKey { case revision, basis, account, start, end, balances, nextCursor = "next_cursor" }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(String.self, forKey: .revision)
        basis = try c.decode(String.self, forKey: .basis)
        account = try c.decode(String.self, forKey: .account)
        start = try c.decodeIfPresent(String.self, forKey: .start)
        end = try c.decodeIfPresent(String.self, forKey: .end)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        balances = try c.boundedRows(Balance.self, forKey: .balances)
    }
    func validate(account expected: String, start: String?, end: String?, limit: Int, cursor: String?) throws {
        guard account.utf8.elementsEqual(expected.utf8), basis == "native_nominal",
              (self.start ?? "") == (start ?? ""), (self.end ?? "") == (end ?? ""),
              BoundedAccountsValidation.interval(self.start, self.end) else { throw BoundedReadIndexError.corrupt }
        try BoundedAccountsValidation.page(count: balances.count, limit: limit, next: nextCursor, cursor: cursor)
        var previous: String?
        for row in balances {
            guard BoundedAccountsValidation.decimal(row.quantity) else { throw BoundedReadIndexError.corrupt }
            if let previous, !previous.utf8.lexicographicallyPrecedes(row.currency.utf8) {
                throw BoundedReadIndexError.corrupt
            }
            previous = row.currency
        }
    }
}

private extension KeyedDecodingContainer {
    func boundedRows<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
        if try decodeNil(forKey: key) { return [] } // Go nil slice
        var rows = try nestedUnkeyedContainer(forKey: key)
        var result: [T] = []
        while !rows.isAtEnd {
            guard result.count < 500 else { throw BoundedReadIndexError.resourceLimit }
            result.append(try rows.decode(type))
        }
        return result
    }
}

enum BoundedAccountsValidation {
    static func page(count: Int, limit: Int, next: String?, cursor: String?) throws {
        guard count <= limit, (next?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.corrupt }
        if let next {
            guard !next.isEmpty, next != cursor, count > 0 else { throw BoundedReadIndexError.corrupt }
        }
    }
    static func account(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1024 &&
        value.trimmingCharacters(in: .whitespacesAndNewlines) == value &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func interval(_ start: String?, _ end: String?) -> Bool {
        let start = start ?? "", end = end ?? ""
        return start.isEmpty && end.isEmpty || date(start) && date(end) && start < end
    }
    static func date(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let b = Array(value.utf8)
        guard b[4] == 45, b[7] == 45,
              b.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }) else { return false }
        let year = Int(value.prefix(4))!, month = Int(value.dropFirst(5).prefix(2))!, day = Int(value.suffix(2))!
        guard year > 0, (1...12).contains(month) else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return (1...days[month - 1]).contains(day)
    }
    /// Go emits normalized plain ASCII decimals; reject alternate spellings,
    /// exponents, negative zero and non-finite values without numeric conversion.
    static func decimal(_ value: String) -> Bool {
        var b = value.utf8[...]
        let negative = b.first == 45
        if negative { b = b.dropFirst() }
        guard !b.isEmpty else { return false }
        let parts = b.split(separator: 46, omittingEmptySubsequences: false)
        guard parts.count <= 2, let integer = parts.first, !integer.isEmpty,
              integer.allSatisfy({ (48...57).contains($0) }),
              integer.count == 1 || integer.first != 48 else { return false }
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.last != 48,
                  fraction.allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        return !(negative && b.elementsEqual([48]))
    }
}

struct BoundedIndexDetail: Decodable, Sendable {
    let revision: String
    let id: Int64
    let records: [BoundedIndexRecord]
    // The 1 MiB transport cap also bounds the number of detail records. No full ledger graph.
}

/// One source-ordered chunk of scalar projections, NOT a complete directive.
/// Continuations omit the directive; even a terminal page remains a partial view.
struct BoundedIndexDetailPage: Decodable, Sendable {
    let revision: String
    let id: Int64
    let records: [BoundedIndexRecord]
    let nextCursor: String?
    private enum CodingKeys: String, CodingKey { case revision, id, records, nextCursor = "next_cursor" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decode(String.self, forKey: .revision)
        id = try c.decode(Int64.self, forKey: .id)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        // Unlike Transactions, Go DetailRecords always returns a non-nil array.
        var rows = try c.nestedUnkeyedContainer(forKey: .records)
        var result: [BoundedIndexRecord] = []
        while !rows.isAtEnd {
            guard result.count < 500 else { throw BoundedReadIndexError.resourceLimit }
            result.append(try rows.decode(BoundedIndexRecord.self))
        }
        records = result
    }

    func validate(id expectedID: Int64, limit: Int, cursor: String?) throws {
        guard id == expectedID, id > 0, records.count <= limit,
              (nextCursor?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.corrupt }
        let firstPage = cursor == nil || cursor == ""
        if let nextCursor {
            guard !nextCursor.isEmpty, nextCursor != cursor, !records.isEmpty else {
                throw BoundedReadIndexError.corrupt
            }
        }
        if firstPage {
            guard let first = records.first, case .directive = first.value else {
                throw BoundedReadIndexError.corrupt
            }
        }
        for (offset, record) in records.enumerated() {
            switch record.value {
            case let .directive(recordID, _):
                guard firstPage, offset == 0, recordID == id else { throw BoundedReadIndexError.corrupt }
            case let .posting(entryID, ordinal, _):
                guard entryID == id, ordinal >= 0 else { throw BoundedReadIndexError.corrupt }
            case let .metadata(entryID, posting, _, _):
                guard entryID == id, posting >= -1 else { throw BoundedReadIndexError.corrupt }
            }
        }
    }
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
            let manifest = try BoundedIndexWire.decode(BoundedIndexManifest.self, json: json, limit: BoundedIndexWire.manifestLimit)
            guard manifest.schemaVersion == 2, manifest.streamVersion == 1 else { throw BoundedReadIndexError.corrupt }
            return manifest
        }
    }
    @discardableResult
    func open(databasePath: String, manifest: BoundedIndexManifest) throws -> String {
        try run {
            guard manifest.schemaVersion == 2, manifest.streamVersion == 1 else { throw BoundedReadIndexError.corrupt }
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
    func accounts(limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexAccountsPage {
        try run {
            guard (1...500).contains(limit), (cursor?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.invalidRequest }
            struct Request: Encodable { let limit: Int; let cursor: String? }
            let data = try JSONEncoder().encode(Request(limit: limit, cursor: cursor))
            guard data.count <= 4096 else { throw BoundedReadIndexError.resourceLimit }
            let page = try BoundedIndexWire.decode(BoundedIndexAccountsPage.self,
                json: backend.accounts(String(decoding: data, as: UTF8.self)), limit: BoundedIndexWire.responseLimit)
            try page.validate(limit: limit, cursor: cursor)
            return page
        }
    }
    func accountBalances(account: String, start: String? = nil, end: String? = nil,
                         limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexAccountBalancesPage {
        try run {
            guard BoundedAccountsValidation.account(account), BoundedAccountsValidation.interval(start, end),
                  (1...500).contains(limit), (cursor?.utf8.count ?? 0) <= 512 else { throw BoundedReadIndexError.invalidRequest }
            struct Request: Encodable { let account: String; let start: String?; let end: String?; let limit: Int; let cursor: String? }
            let data = try JSONEncoder().encode(Request(account: account, start: start, end: end, limit: limit, cursor: cursor))
            guard data.count <= 4096 else { throw BoundedReadIndexError.resourceLimit }
            let page = try BoundedIndexWire.decode(BoundedIndexAccountBalancesPage.self,
                json: backend.accountBalances(String(decoding: data, as: UTF8.self)), limit: BoundedIndexWire.responseLimit)
            try page.validate(account: account, start: start, end: end, limit: limit, cursor: cursor)
            return page
        }
    }
    func detailRecords(id: Int64, limit: Int = 100, cursor: String? = nil) throws -> BoundedIndexDetailPage {
        try run {
            guard id > 0, (1...500).contains(limit), (cursor?.utf8.count ?? 0) <= 512 else {
                throw BoundedReadIndexError.invalidRequest
            }
            struct Request: Encodable { let id: Int64; let limit: Int; let cursor: String? }
            let data = try JSONEncoder().encode(Request(id: id, limit: limit, cursor: cursor))
            guard data.count <= 4096 else { throw BoundedReadIndexError.resourceLimit }
            let page = try BoundedIndexWire.decode(BoundedIndexDetailPage.self,
                json: backend.detailRecords(String(decoding: data, as: UTF8.self)), limit: BoundedIndexWire.responseLimit)
            try page.validate(id: id, limit: limit, cursor: cursor)
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
    func accounts(_ requestJSON: String) -> String { bridge?.accounts(requestJSON) ?? unavailable }
    func accountBalances(_ requestJSON: String) -> String { bridge?.accountBalances(requestJSON) ?? unavailable }
    func detail(_ id: Int64) -> String { bridge?.detail(id) ?? unavailable }
    func detailRecords(_ requestJSON: String) -> String { bridge?.detailRecords(requestJSON) ?? unavailable }
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
