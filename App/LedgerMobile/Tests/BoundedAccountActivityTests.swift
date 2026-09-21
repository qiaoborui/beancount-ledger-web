import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedAccountActivityTests: XCTestCase, @unchecked Sendable {
    private final class Backend: BoundedReadIndexBackend, @unchecked Sendable {
        var response = ""
        var request = ""
        var calls = 0
        var block = false
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func build(_ streamPath: String, destination: String) -> String { "" }
        func open(_ databasePath: String, manifestJSON: String) -> String { "" }
        func transactions(_ requestJSON: String) -> String { "" }
        func detail(_ id: Int64) -> String { "" }
        func accountSummary(_ requestJSON: String) -> String {
            request = requestJSON; calls += 1
            if block { entered.signal(); _ = release.wait(timeout: .now() + 5) }
            return response
        }
        func accountActivity(_ requestJSON: String) -> String { accountSummary(requestJSON) }
        func unlock() {}
        func cancel() {}
        func lock() { if block { release.signal() } }
        func close() { if block { release.signal() } }
    }
    private func summary(_ value: String = "0") -> String {
        #"{"revision":"r","basis":"native_nominal","account":"Assets:Stock","currency":"XYZ","current_balance":"\#(value)","opening_balance":"0","closing_balance":"\#(value)","period_change":"\#(value)"}"#
    }
    private func row(_ id: Int = 1, change: String = "0", balance: String = "0") -> String {
        #"{"id":\#(id),"date":"2026-01-01","change":"\#(change)","balance":"\#(balance)","record":{"type":"directive","id":\#(id),"value":{"Kind":"transaction","Date":"2026-01-01","File":"main.bean","Line":1,"Payee":"Synthetic","Narration":"Repeated postings aggregated by backend"}}}"#
    }
    private func page(_ rows: String = "null", next: String = "null") -> String {
        #"{"revision":"r","basis":"native_nominal","account":"Assets:Stock","currency":"XYZ","rows":\#(rows),"next_cursor":\#(next)}"#
    }
    private func client(_ response: String) -> (BoundedReadIndexClient, Backend) {
        let backend = Backend(); backend.response = response
        let client = BoundedReadIndexClient(backend: backend); client.unlock()
        return (client, backend)
    }
    func testExactLargeRepeatedDecimalsAndZeroRows() throws {
        let (client, backend) = client(summary())
        for value in ["0", "-1", "0.00000000000000000001", String(repeating: "9", count: 4096), "-0." + String(repeating: "0", count: 4095) + "1"] {
            backend.response = summary(value)
            let result = try client.accountSummary(account: "Assets:Stock", currency: "XYZ")
            XCTAssertEqual(result.currentBalance, value)
            XCTAssertEqual(result.openingBalance, "0")
            XCTAssertEqual(result.closingBalance, value)
            XCTAssertEqual(result.periodChange, value)
            backend.response = page("[\(row(1, change: value, balance: value)),\(row(2, change: "0", balance: value))]")
            let page = try client.accountActivity(account: "Assets:Stock", currency: "XYZ")
            XCTAssertEqual(page.rows.map(\.balance), [value, value])
            XCTAssertEqual(page.rows.map(\.change), [value, "0"])
        }
        for rows in ["null", "[]"] {
            backend.response = page(rows)
            XCTAssertTrue(try client.accountActivity(account: "Assets:Stock", currency: "XYZ").rows.isEmpty)
        }
    }
    func testRequiredFiltersRangeAndRequestLimitsBeforeBackend() throws {
        let (client, backend) = client(summary())
        for invalid in ["", " ", " XYZ", "XYZ\n", "X\u{0}", String(repeating: "é", count: 513)] {
            XCTAssertThrowsError(try client.accountSummary(account: invalid, currency: "XYZ"))
            XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: invalid))
            XCTAssertThrowsError(try client.accountActivity(account: invalid, currency: "XYZ"))
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: invalid))
        }
        for (start, end) in [("2026-01-01", nil), (nil, "2026-02-01"), ("2025-02-29", "2026-01-01"), ("2026-02-01", "2026-02-01"), ("2026-03-01", "2026-02-01")] as [(String?, String?)] {
            XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ", start: start, end: end))
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", start: start, end: end))
        }
        for limit in [0, -1, 501] {
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", limit: limit))
        }
        XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", cursor: String(repeating: "é", count: 257)))
        XCTAssertEqual(backend.calls, 0)
        for activity in [false, true] {
            backend.response = (activity ? page() : summary()).replacingOccurrences(of: "\"basis\":", with: "\"start\":\"2026-01-01\",\"end\":\"2026-02-01\",\"basis\":")
            if activity { _ = try client.accountActivity(account: "Assets:Stock", currency: "XYZ", start: "2026-01-01", end: "2026-02-01", limit: 500, cursor: String(repeating: "x", count: 512)) }
            else { _ = try client.accountSummary(account: "Assets:Stock", currency: "XYZ", start: "2026-01-01", end: "2026-02-01") }
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(backend.request.utf8)) as? [String: Any])
            XCTAssertEqual(request["account"] as? String, "Assets:Stock")
            XCTAssertEqual(request["currency"] as? String, "XYZ")
            XCTAssertEqual(request["start"] as? String, "2026-01-01")
            XCTAssertEqual(request["end"] as? String, "2026-02-01")
            XCTAssertEqual(request["limit"] as? Int, activity ? 500 : nil)
            XCTAssertEqual((request["cursor"] as? String)?.utf8.count, activity ? 512 : nil)
        }
    }
    func testMalformedIdentityBasisRangeAndDecimalFailClosed() throws {
        let (client, backend) = client("")
        for activity in [false, true] {
            let original = activity ? page("[\(row())]") : summary()
            var malformed = [original.replacingOccurrences(of: "native_nominal", with: "valuation"),
                original.replacingOccurrences(of: "Assets:Stock", with: "Assets:Other"),
                original.replacingOccurrences(of: "XYZ", with: "USD"),
                original.replacingOccurrences(of: "\"basis\":", with: "\"start\":\"2026-01-01\",\"basis\":"),
                original.replacingOccurrences(of: "\"basis\":", with: "\"start\":\"2026-01-01\",\"end\":\"2026-02-01\",\"basis\":")]
            for decimal in ["-0", "01", "1.0", "1e3", "NaN", "∞", "+1", "0.", ".1"] {
                malformed.append(original.replacingOccurrences(of: "\"0\"", with: "\"\(decimal)\""))
            }
            malformed.append(original.replacingOccurrences(of: "\"0\"", with: "0"))
            for bad in malformed {
                backend.response = bad
                if activity { XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ")) }
                else { XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ")) }
            }
            // Canonically equivalent Swift strings must not match wire identities.
            for field in ["Assets:Stock", "XYZ"] {
                backend.response = original.replacingOccurrences(of: field, with: "Café")
                if activity { XCTAssertThrowsError(try client.accountActivity(account: field == "Assets:Stock" ? "Cafe\u{0301}" : "Assets:Stock", currency: field == "XYZ" ? "Cafe\u{0301}" : "XYZ")) }
                else { XCTAssertThrowsError(try client.accountSummary(account: field == "Assets:Stock" ? "Cafe\u{0301}" : "Assets:Stock", currency: field == "XYZ" ? "Cafe\u{0301}" : "XYZ")) }
            }
        }
    }
    func testActivityRowIntegrityOrderingAndRange() throws {
        let (client, backend) = client("")
        let original = row()
        for rows in [row(0), original.replacingOccurrences(of: "\"id\":1,\"value\"", with: "\"id\":2,\"value\""),
                     original.replacingOccurrences(of: "transaction", with: "open"),
                     original.replacingOccurrences(of: "\"Date\":\"2026-01-01\"", with: "\"Date\":\"2026-01-02\""),
                     original.replacingOccurrences(of: "2026-01-01", with: "2026-02-30"),
                     "\(row(2)),\(row(1))", "\(row(1)),\(row(1))"] {
            backend.response = page("[\(rows)]")
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ"))
        }
        for date in ["2025-12-31", "2026-02-01"] {
            backend.response = page("[\(row())]").replacingOccurrences(of: "2026-01-01", with: date)
                .replacingOccurrences(of: "\"basis\":", with: "\"start\":\"2026-01-01\",\"end\":\"2026-02-01\",\"basis\":")
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", start: "2026-01-01", end: "2026-02-01"))
        }
    }
    func testWireRowByteAndCursorCaps() throws {
        let (client, backend) = client(page("[\((1...500).map { row($0) }.joined(separator: ","))]"))
        XCTAssertEqual(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", limit: 500).rows.count, 500)
        XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", limit: 100))
        backend.response = page("[\((1...501).map { row($0) }.joined(separator: ","))]")
        XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", limit: 500)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        for next in ["", "old", String(repeating: "é", count: 257)] {
            backend.response = page("[\(row())]", next: "\"\(next)\"")
            XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ", cursor: "old"))
        }
        backend.response = page("[]", next: "\"next\"")
        XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ"))
        backend.response = page("[\(row())]", next: "\"\(String(repeating: "x", count: 512))\"")
        XCTAssertEqual(try client.accountActivity(account: "Assets:Stock", currency: "XYZ").nextCursor?.utf8.count, 512)
        // The cap is UTF-8 bytes, inclusive, before decoding (not Swift character count).
        for activity in [false, true] {
            let json = activity ? page() : summary()
            backend.response = json + String(repeating: " ", count: (1 << 20) - json.utf8.count)
            if activity { XCTAssertNoThrow(try client.accountActivity(account: "Assets:Stock", currency: "XYZ")) }
            else { XCTAssertNoThrow(try client.accountSummary(account: "Assets:Stock", currency: "XYZ")) }
            backend.response += " "
            if activity { XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ")) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) } }
            else { XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ")) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) } }
        }
    }
    func testDelayedQueriesCancelLockCloseAndBusy() async throws {
        for activity in [false, true] {
            for action in ["cancel", "lock", "close"] {
                let (client, backend) = client(activity ? page() : summary())
                client.lock()
                XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ"))
                XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ"))
                XCTAssertEqual(backend.calls, 0)
                client.unlock(); backend.block = true
                let operation = Task.detached {
                    if activity { _ = try client.accountActivity(account: "Assets:Stock", currency: "XYZ") }
                    else { _ = try client.accountSummary(account: "Assets:Stock", currency: "XYZ") }
                }
                let started = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: backend.entered.wait(timeout: .now() + 5) == .success) }
                }
                XCTAssertTrue(started)
                XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ")) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
                XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ")) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
                if action == "cancel" { client.cancel(); backend.release.signal() }
                else if action == "lock" { await Task.detached { client.lock() }.value }
                else { await Task.detached { client.close() }.value }
                do { try await operation.value; XCTFail("late result") }
                catch { XCTAssertEqual(error as? BoundedReadIndexError, action == "cancel" ? .canceled : .unavailable) }
                client.close(); client.unlock()
                XCTAssertThrowsError(try client.accountSummary(account: "Assets:Stock", currency: "XYZ"))
                XCTAssertThrowsError(try client.accountActivity(account: "Assets:Stock", currency: "XYZ"))
            }
        }
    }
}
