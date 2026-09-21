import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedReadIndexClientTests: XCTestCase {
    private let directive = #"{"type":"directive","id":1,"value":{"Kind":"transaction","Date":"2026-09-21","File":"main.bean","Line":4,"Flag":"*","Payee":"Fixture","Narration":"Synthetic","Tags":[],"Links":[]}}"#
    private var page: String {
        #"{"revision":"r1","transactions":[{"id":1,"date":"2026-09-21","record":\#(directive)}],"next_cursor":"cursor"}"#
    }
    private var manifestJSON: String {
        #"{"schema_version":2,"stream_version":1,"source_digest":"source","runtime":"beancount","exporter":"bounded-v1","entrypoint":"main.bean","stream_digest":"stream","records":3,"directives":1,"postings":1,"options":0,"commodities":0,"metadata":0,"transactions":1,"bytes":1000,"max_record_bytes":500,"revision":"r1"}"#
    }
    func testLockedByDefaultAndExplicitCloseIsPermanent() throws {
        let backend = FakeBackend(response: page)
        let client = BoundedReadIndexClient(backend: backend)
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
        XCTAssertEqual(backend.calls, 0)
        client.unlock()
        XCTAssertEqual(try client.transactions().transactions.count, 1)
        client.lock()
        XCTAssertThrowsError(try client.detail(id: 1))
        client.unlock()
        XCTAssertEqual(try client.transactions().revision, "r1")
        client.close()
        client.unlock()
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
    }
    func testPageRequestIsSmallAndScalar() throws {
        let backend = FakeBackend(response: page)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let result = try client.transactions(limit: 2, cursor: "abc")
        struct Request: Decodable { let limit: Int; let cursor: String }
        let request = try JSONDecoder().decode(Request.self, from: Data(backend.lastRequest.utf8))
        XCTAssertEqual(request.limit, 2)
        XCTAssertEqual(request.cursor, "abc")
        guard case let .directive(id, value) = result.transactions[0].record.value else { return XCTFail("directive required") }
        XCTAssertEqual(id, 1)
        XCTAssertEqual(value.payee, "Fixture")
        XCTAssertEqual(result.nextCursor, "cursor")
        let calls = backend.calls
        for limit in [0, -1, 501] { XCTAssertThrowsError(try client.transactions(limit: limit)) }
        XCTAssertThrowsError(try client.transactions(cursor: String(repeating: "é", count: 257)))
        XCTAssertThrowsError(try client.detail(id: 0))
        XCTAssertEqual(backend.calls, calls)
    }
    func testExactPostingProjectionDoesNotDecodeArbitraryMetadataGraphs() throws {
        let posting = #"{"type":"posting","entry_id":1,"ordinal":0,"value":{"account":"Assets:Stock","Quantity":{"Number":"12345678901234567890.00000000000001","Currency":"XYZ"},"Cost":{"Number":"1E-999","Currency":"USD"},"CostDate":"2026-09-20","CostLabel":"lot"}}"#
        let metadata = #"{"type":"metadata","entry_id":1,"posting":0,"key":"nested","value":{"type":"list","value":[{"type":"str","value":"not exposed"}]}}"#
        let backend = FakeBackend(response: #"{"revision":"r1","id":1,"records":[\#(directive),\#(posting),\#(metadata)]}"#)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let detail = try client.detail(id: 1)
        XCTAssertEqual(detail.records.count, 3)
        guard case let .posting(entryID, ordinal, value) = detail.records[1].value else { return XCTFail("posting required") }
        XCTAssertEqual(entryID, 1)
        XCTAssertEqual(ordinal, 0)
        XCTAssertEqual(value.quantity.number, "12345678901234567890.00000000000001")
        XCTAssertEqual(value.cost?.number, "1E-999")
        guard case let .metadata(_, _, key, type) = detail.records[2].value else { return XCTFail("metadata identity required") }
        XCTAssertEqual(key, "nested")
        XCTAssertEqual(type, "list")
    }
    func testBuildAndOpenUseOnlyCappedManifest() throws {
        let backend = FakeBackend(response: manifestJSON)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let manifest = try client.build(streamPath: "spool.jsonl", destination: "index.sqlite")
        XCTAssertEqual(manifest.maxRecordBytes, 500)
        backend.response = #"{"revision":"r1"}"#
        XCTAssertEqual(try client.open(databasePath: "index.sqlite", manifest: manifest), "r1")
        let sent = try JSONDecoder().decode(BoundedIndexManifest.self, from: Data(backend.lastRequest.utf8))
        XCTAssertEqual(sent, manifest)
        backend.response = #"{"revision":"wrong"}"#
        XCTAssertThrowsError(try client.open(databasePath: "index.sqlite", manifest: manifest)) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .revisionMismatch)
        }
        XCTAssertThrowsError(try client.build(streamPath: "../source/main.bean", destination: "index.sqlite"))
        let oversized = try JSONDecoder().decode(BoundedIndexManifest.self, from: Data(manifestJSON.replacingOccurrences(of: "beancount", with: String(repeating: "x", count: (16 << 10) + 1)).utf8))
        let calls = backend.calls
        XCTAssertThrowsError(try client.open(databasePath: "index.sqlite", manifest: oversized)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        XCTAssertEqual(backend.calls, calls)
    }
    func testCapsMalformedResponsesAndSanitizedFailures() throws {
        let backend = FakeBackend(response: String(repeating: "é", count: (1 << 19) + 1))
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        backend.response = String(repeating: " ", count: (16 << 10) + 1)
        XCTAssertThrowsError(try client.build(streamPath: "spool", destination: "index")) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        for raw in ["null", "[]", "{}", "not json", page + page] {
            backend.response = raw
            XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
        }
        backend.response = #"{"error":{"code":"invalid_cursor","message":"private path"}}"#
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .invalidCursor) }
        backend.response = #"{"error":{"code":"private exception"}}"#
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
    }
    func testRowAndCursorCapsAndEmptyNilSlice() throws {
        let row = #"{"id":1,"date":"2026-09-21","record":\#(directive)}"#
        let backend = FakeBackend(response: #"{"revision":"r1","transactions":[\#(Array(repeating: row, count: 501).joined(separator: ","))]}"#)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        XCTAssertThrowsError(try client.transactions(limit: 500)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        backend.response = #"{"revision":"r1","transactions":null}"#
        XCTAssertTrue(try client.transactions().transactions.isEmpty)
        // Replace the value only, preserving next_cursor.
        backend.response = page.replacingOccurrences(of: #""cursor""#, with: "\"" + String(repeating: "x", count: 513) + "\"")
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
    }
    func testCancelCanInterruptBlockedCallAndSuppressAlreadyProducedResult() throws {
        let backend = FakeBackend(response: page, blocked: true)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let finished = expectation(description: "stale result rejected")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try client.transactions()
                XCTFail("Invalidated operation returned a page")
            } catch {
                XCTAssertEqual(error as? BoundedReadIndexError, .canceled)
            }
        }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
        client.cancel()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(try client.transactions().revision, "r1", "cancel does not permanently lock")
    }
    func testLockDrainsAndSuppressesStaleResultsBeforeUnlock() throws {
        let backend = FakeBackend(response: page, blocked: true)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let finished = expectation(description: "locked result rejected")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try client.transactions()
                XCTFail("Invalidated operation returned a page")
            } catch {
                XCTAssertEqual(error as? BoundedReadIndexError, .unavailable)
            }
        }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 2), .success)
        client.lock()
        wait(for: [finished], timeout: 2)
        XCTAssertThrowsError(try client.transactions())
        client.unlock()
        XCTAssertEqual(try client.transactions().revision, "r1")
    }
    func testCloseDuringPendingWorkCannotBeRevived() throws {
        let backend = FakeBackend(response: page, blocked: true)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        let finished = expectation(description: "closed result rejected")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                _ = try client.transactions()
                XCTFail("Invalidated operation returned a page")
            } catch {
                XCTAssertEqual(error as? BoundedReadIndexError, .unavailable)
            }
        }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 2), .success)
        client.close()
        wait(for: [finished], timeout: 2)
        client.unlock()
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
    }
    func testStreamSummaryCapAndPathAliases() throws {
        let digest = String(repeating: "a", count: 64)
        let json = #"{"ok":true,"summary":{"records":3,"directives":1,"postings":1,"source_digest":"\#(digest)","sha256":"\#(digest)"}}"#
        XCTAssertEqual(try EmbeddedBeancountValidator.decodeStreamSummary(json).records, 3)
        XCTAssertThrowsError(try EmbeddedBeancountValidator.decodeStreamSummary(String(repeating: " ", count: 1025)))
        XCTAssertThrowsError(try EmbeddedBeancountValidator.decodeStreamSummary(json.replacingOccurrences(of: digest, with: "bad")))
        XCTAssertThrowsError(try EmbeddedBeancountValidator.decodeStreamSummary(#"{"ok":false,"error":{"code":"export_failed","message":"private"}}"#))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("source")
        let derived = temp.appendingPathComponent("derived")
        let alias = temp.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temp)
        let paths = try EmbeddedBeancountValidator.streamPaths(workspace: alias.appendingPathComponent("source"), entryFile: "main.bean", derivedDirectory: alias.appendingPathComponent("derived"), spoolName: "fresh-1.jsonl")
        XCTAssertEqual(paths.workspace, source.resolvingSymlinksInPath().path)
        XCTAssertEqual(paths.derived, derived.resolvingSymlinksInPath().path)
        for name in ["../escape", ".hidden", "a/b", "中文", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try EmbeddedBeancountValidator.streamPaths(workspace: source, entryFile: "main.bean", derivedDirectory: derived, spoolName: name))
        }
        XCTAssertThrowsError(try EmbeddedBeancountValidator.streamPaths(workspace: source, entryFile: "../main.bean", derivedDirectory: derived, spoolName: "fresh"))
        XCTAssertThrowsError(try EmbeddedBeancountValidator.streamPaths(workspace: source, entryFile: "main.bean", derivedDirectory: source.appendingPathComponent("inside"), spoolName: "fresh"))
    }
    func testMissingExportRuntimeFailsExplicitly() async throws {
        #if !canImport(BeancountRuntime)
        do {
            _ = try await EmbeddedBeancountValidator.shared.exportStream(
                workspace: URL(fileURLWithPath: "/source"),
                derivedDirectory: URL(fileURLWithPath: "/derived"), spoolName: "fresh.jsonl")
            XCTFail("must not fall back to legacy validation")
        } catch { XCTAssertEqual(error as? BoundedReadIndexError, .unavailable) }
        #endif
    }
    func testDetailRejectsMixedEntryIdentity() throws {
        let backend = FakeBackend(response: #"{"revision":"r1","id":1,"records":[\#(directive),{"type":"metadata","entry_id":2,"posting":-1,"key":"other","value":{"type":"str","value":"ignored"}}]}"#)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        XCTAssertThrowsError(try client.detail(id: 1)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
    }
    func testMissingNativeBridgeFailsExplicitly() throws {
        #if !canImport(LedgerCore) || !LEDGER_BOUNDED_READ_INDEX
        let client = try BoundedReadIndexClient(derivedDirectory: FileManager.default.temporaryDirectory)
        client.unlock()
        XCTAssertThrowsError(try client.transactions()) { XCTAssertEqual($0 as? BoundedReadIndexError, .unavailable) }
        #endif
    }
}

/// Intentionally ignores cancellation when constructing its result, proving the
/// Swift epoch check independently suppresses stale native output.
private final class FakeBackend: BoundedReadIndexBackend, @unchecked Sendable {
    private let mutex = NSLock()
    private var raw: String
    private var request = ""
    private var count = 0
    private var blocked: Bool
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    init(response: String, blocked: Bool = false) { raw = response; self.blocked = blocked }
    var response: String {
        get { mutex.lock(); defer { mutex.unlock() }; return raw }
        set { mutex.lock(); defer { mutex.unlock() }; raw = newValue }
    }
    var calls: Int { mutex.lock(); defer { mutex.unlock() }; return count }
    var lastRequest: String { mutex.lock(); defer { mutex.unlock() }; return request }
    private func call(_ value: String) -> String {
        mutex.lock()
        count += 1; request = value
        let result = raw
        let shouldBlock = blocked
        blocked = false
        mutex.unlock()
        if shouldBlock {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        return result
    }
    func build(_ streamPath: String, destination: String) -> String { call(streamPath) }
    func open(_ databasePath: String, manifestJSON: String) -> String { call(manifestJSON) }
    func transactions(_ requestJSON: String) -> String { call(requestJSON) }
    func detail(_ id: Int64) -> String { call(String(id)) }
    func unlock() {}
    func cancel() { release.signal() }
    func lock() { release.signal() }
    func close() { release.signal() }
}
