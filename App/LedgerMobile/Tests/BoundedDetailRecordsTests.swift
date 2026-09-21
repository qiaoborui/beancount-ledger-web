import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedDetailRecordsTests: XCTestCase, @unchecked Sendable {
    private let directive = #"{"type":"directive","id":1,"value":{"Kind":"transaction","Date":"2026-09-21","File":"main.bean","Line":1}}"#
    private let posting = #"{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Test","Quantity":{"Number":"12345678901234567890.00000000001","Currency":"USD"}}}"#
    private let metadata = #"{"type":"metadata","entry_id":1,"posting":-1,"key":"nested","value":{"type":"list","value":[{"type":"str","value":"omitted"}]}}"#
    private func response(_ records: [String], next: String? = nil, id: Int = 1) -> String {
        #"{"revision":"r1","id":\#(id),"records":[\#(records.joined(separator: ","))]\#(next.map { ",\"next_cursor\":\"\($0)\"" } ?? "")}"#
    }

    func testRequestBoundsCursorRoundTripAndScalarProjection() throws {
        let backend = DetailTransport(response: response([directive, posting, metadata], next: "next"))
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let first = try client.detailRecords(id: 1)
        XCTAssertEqual(first.records.count, 3)
        XCTAssertEqual(first.nextCursor, "next")
        XCTAssertEqual(backend.lastRequest?.id, 1)
        XCTAssertEqual(backend.lastRequest?.limit, 100)
        XCTAssertNil(backend.lastRequest?.cursor)
        guard case let .posting(_, _, value) = first.records[1].value else { return XCTFail("posting") }
        XCTAssertEqual(value.quantity.number, "12345678901234567890.00000000001")
        guard case let .metadata(_, _, key, type) = first.records[2].value else { return XCTFail("metadata") }
        XCTAssertEqual(key, "nested")
        XCTAssertEqual(type, "list")
        backend.response = response([metadata])
        let continuation = try client.detailRecords(id: 1, limit: 1, cursor: first.nextCursor)
        XCTAssertEqual(continuation.records.count, 1)
        XCTAssertNil(continuation.nextCursor)
        XCTAssertEqual(backend.lastRequest?.cursor, "next")
        XCTAssertEqual(backend.lastRequest?.limit, 1)
        backend.response = response([])
        XCTAssertTrue(try client.detailRecords(id: 1, cursor: "terminal").records.isEmpty)
        backend.response = response([directive])
        _ = try client.detailRecords(id: 1, cursor: "") // Go treats empty as first.
        _ = try client.detailRecords(id: 1, limit: 500)
        let calls = backend.calls
        for id in [Int64(0), -1] { XCTAssertThrowsError(try client.detailRecords(id: id)) }
        for limit in [0, -1, 501] { XCTAssertThrowsError(try client.detailRecords(id: 1, limit: limit)) }
        XCTAssertThrowsError(try client.detailRecords(id: 1, cursor: String(repeating: "é", count: 257)))
        XCTAssertEqual(backend.calls, calls)
    }

    func testStrictFirstAndContinuationShapes() throws {
        let bad: [(String, String?)] = [
            (response([]), nil), (response([posting]), nil),
            (response([directive, directive]), nil), (response([directive]), "next"),
            (response([directive], id: 2), nil),
            (response([directive.replacingOccurrences(of: "\"id\":1", with: "\"id\":2")]), nil),
            (response([posting.replacingOccurrences(of: "\"entry_id\":1", with: "\"entry_id\":2")]), "next"),
            (response([posting.replacingOccurrences(of: "\"ordinal\":0", with: "\"ordinal\":-1")]), "next"),
            (response([metadata.replacingOccurrences(of: "\"entry_id\":1", with: "\"entry_id\":2")]), "next"),
            (response([metadata.replacingOccurrences(of: "\"posting\":-1", with: "\"posting\":-2")]), "next"),
            (response([], next: "next"), "previous"), (response([posting], next: "same"), "same"),
            (response([directive], next: ""), nil),
            (response([directive], next: String(repeating: "é", count: 257)), nil),
            (#"{"revision":"r1","id":1,"records":null}"#, "next"),
            (#"{"revision":"r1","id":1}"#, "next"),
            (response([#"{"type":"option"}"#]), "next"),
        ]
        for (json, cursor) in bad {
            let client = BoundedReadIndexClient(backend: DetailTransport(response: json))
            client.unlock()
            XCTAssertThrowsError(try client.detailRecords(id: 1, cursor: cursor)) {
                XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt)
            }
        }
    }

    func testByteAndRecordCapsAndErrorEnvelope() throws {
        let backend = DetailTransport(response: String(repeating: "x", count: BoundedIndexWire.responseLimit + 1))
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        backend.response = response(Array(repeating: posting, count: 501))
        XCTAssertThrowsError(try client.detailRecords(id: 1, limit: 500, cursor: "next")) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit)
        }
        backend.response = response([directive, posting])
        XCTAssertThrowsError(try client.detailRecords(id: 1, limit: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
        for code in ["invalid_cursor", "revision_mismatch", "not_found", "resource_limit", "canceled"] {
            backend.response = #"{"error":{"code":"\#(code)"}}"#
            XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, BoundedReadIndexError(rawValue: code)) }
        }
    }

    func testExistingBackendDefaultsToUnavailableWithoutWholeDetailFallback() throws {
        let client = BoundedReadIndexClient(backend: OldDetailTransport())
        client.unlock()
        XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
    }

    func testOversizedWholeDetailCanBeRetrievedInBoundedPages() throws {
        let backend = DetailTransport(response: "")
        let rows = [directive] + (0..<3000).map { ordinal in
            #"{"type":"posting","entry_id":1,"ordinal":\#(ordinal),"value":{"account":"Assets:\#(String(repeating: "x", count: 350))","Quantity":{"Number":"0.00000000000000000001","Currency":"USD"}}}"#
        }
        let whole = response(rows)
        XCTAssertGreaterThan(whole.utf8.count, BoundedIndexWire.responseLimit)
        backend.response = whole
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        XCTAssertThrowsError(try client.detail(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        // Transport-only fake follows Go's actual schema. No real ledger and
        // no claim to test Go/SQLite integration here.
        var cursor: String?
        var delivered = 0
        repeat {
            let end = min(delivered + 100, rows.count)
            backend.response = response(Array(rows[delivered..<end]), next: end < rows.count ? "cursor-\(end)" : nil)
            let page = try client.detailRecords(id: 1, limit: 100, cursor: cursor)
            XCTAssertLessThanOrEqual(page.records.count, 100)
            XCTAssertEqual(backend.lastRequest?.cursor, cursor)
            for record in page.records {
                if delivered == 0 {
                    guard case .directive = record.value else { return XCTFail("first directive") }
                } else {
                    guard case let .posting(_, ordinal, value) = record.value else { return XCTFail("posting") }
                    XCTAssertEqual(ordinal, delivered - 1)
                    XCTAssertEqual(value.quantity.number, "0.00000000000000000001")
                }
                delivered += 1
            }
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(delivered, 3001)
    }

    func testLockAndCancelSuppressLateDetailPage() async throws {
        for shouldLock in [false, true] {
            let backend = DetailTransport(response: response([directive]), blocked: true)
            let client = BoundedReadIndexClient(backend: backend)
            XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
            client.unlock()
            let work = Task.detached { try client.detailRecords(id: 1) }
            let started = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: backend.entered.wait(timeout: .now() + 5) == .success)
                }
            }
            XCTAssertTrue(started)
            XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
            if shouldLock { client.lock() } else { client.cancel() }
            do { _ = try await work.value; XCTFail("late result") }
            catch { XCTAssertEqual(error as? BoundedReadIndexError, shouldLock ? .unavailable : .canceled) }
            client.close()
            client.unlock()
            XCTAssertThrowsError(try client.detailRecords(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
        }
    }
}

private struct OldDetailTransport: BoundedReadIndexBackend {
    func build(_ streamPath: String, destination: String) -> String { "" }
    func open(_ databasePath: String, manifestJSON: String) -> String { "" }
    func transactions(_ requestJSON: String) -> String { "" }
    func detail(_ id: Int64) -> String { XCTFail("must not fall back to whole detail"); return "" }
    func unlock() {}
    func cancel() {}
    func lock() {}
    func close() {}
}

private final class DetailTransport: BoundedReadIndexBackend, @unchecked Sendable {
    struct Request: Decodable { let id: Int64; let limit: Int; let cursor: String? }
    private let gate = NSLock()
    private var raw: String
    private var request: Request?
    private var count = 0
    private var blocked: Bool
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    init(response: String, blocked: Bool = false) { raw = response; self.blocked = blocked }
    var response: String {
        get { gate.withLock { raw } }
        set { gate.withLock { raw = newValue } }
    }
    var lastRequest: Request? { gate.withLock { request } }
    var calls: Int { gate.withLock { count } }
    func detailRecords(_ requestJSON: String) -> String {
        let (result, wait) = gate.withLock {
            request = try? JSONDecoder().decode(Request.self, from: Data(requestJSON.utf8))
            count += 1
            let wait = blocked
            blocked = false
            return (raw, wait)
        }
        if wait { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return result
    }
    func build(_ streamPath: String, destination: String) -> String { "" }
    func open(_ databasePath: String, manifestJSON: String) -> String { "" }
    func transactions(_ requestJSON: String) -> String { "" }
    func detail(_ id: Int64) -> String { response }
    func unlock() {}
    func cancel() { release.signal() }
    func lock() { release.signal() }
    func close() { release.signal() }
}
