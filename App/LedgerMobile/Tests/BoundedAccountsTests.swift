import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedAccountsTests: XCTestCase, @unchecked Sendable {
    private final class Backend: BoundedReadIndexBackend, @unchecked Sendable {
        var response = ""
        var calls = 0
        var request = ""
        var block = false
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func build(_ streamPath: String, destination: String) -> String { "" }
        func open(_ databasePath: String, manifestJSON: String) -> String { "" }
        func transactions(_ requestJSON: String) -> String { "" }
        func detail(_ id: Int64) -> String { "" }
        func accounts(_ requestJSON: String) -> String {
            calls += 1; request = requestJSON
            if block { started.signal(); _ = release.wait(timeout: .now() + 5) }
            return response
        }
        func accountBalances(_ requestJSON: String) -> String { accounts(requestJSON) }
        func unlock() {}
        func cancel() {}
        func lock() {}
        func close() {}
    }
    private let row = #"{"account":"Assets:Stock","open_id":7,"open_date":"2024-02-29","close_date":"2026-09-21","open_record":{"type":"directive","id":7,"value":{"Kind":"open","Date":"2024-02-29","File":"main.bean","Line":1,"Account":"Assets:Stock","Currencies":["XYZ","USD"],"Booking":"STRICT"}}}"#
    private func catalog(_ row: String? = nil) -> String {
        #"{"revision":"r","accounts":[\#(row ?? self.row)],"next_cursor":"next"}"#
    }
    private func balance(_ quantity: String = "123456789012345678901234567890.00000000000000000001") -> String {
        #"{"revision":"r","account":"Assets:Stock","basis":"native_nominal","balances":[{"currency":"XYZ","quantity":"\#(quantity)"}]}"#
    }
    private func client(_ response: String) -> (BoundedReadIndexClient, Backend) {
        let backend = Backend(); backend.response = response
        let client = BoundedReadIndexClient(backend: backend); client.unlock()
        return (client, backend)
    }
    func testScalarOpenAndExactDecimalStrings() throws {
        let (client, backend) = client(catalog())
        let page = try client.accounts(limit: 1, cursor: "old")
        XCTAssertEqual(page.accounts[0].openID, 7)
        guard case .directive(_, let value) = page.accounts[0].openRecord.value else { return XCTFail() }
        XCTAssertEqual(value.account, "Assets:Stock")
        XCTAssertEqual(value.currencies, ["XYZ", "USD"])
        XCTAssertEqual(value.booking, "STRICT")
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(backend.request.utf8)) as? [String: Any])
        XCTAssertEqual(request["limit"] as? Int, 1)
        XCTAssertEqual(request["cursor"] as? String, "old")
        for quantity in ["0", "-1", "0.00001", String(repeating: "9", count: 4096), "-0." + String(repeating: "0", count: 4095) + "1"] {
            backend.response = balance(quantity)
            XCTAssertEqual(try client.accountBalances(account: "Assets:Stock").balances[0].quantity, quantity)
        }
        backend.response = balance().replacingOccurrences(of: "\"balances\":", with: "\"start\":\"2024-02-29\",\"end\":\"2025-03-01\",\"balances\":")
        _ = try client.accountBalances(account: "Assets:Stock", start: "2024-02-29", end: "2025-03-01", limit: 500, cursor: String(repeating: "x", count: 512))
        let filter = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(backend.request.utf8)) as? [String: Any])
        XCTAssertEqual(filter["account"] as? String, "Assets:Stock")
        XCTAssertEqual(filter["start"] as? String, "2024-02-29")
        XCTAssertEqual(filter["end"] as? String, "2025-03-01")
        XCTAssertEqual(filter["limit"] as? Int, 500)
    }
    func testRequestBoundsRejectBeforeBackend() throws {
        let (client, backend) = client(catalog())
        for limit in [0, -1, 501] {
            XCTAssertThrowsError(try client.accounts(limit: limit))
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", limit: limit))
        }
        for account in ["", " Assets:X", "Assets:X ", "Assets:\nX", "Assets:\0X", String(repeating: "é", count: 513)] {
            XCTAssertThrowsError(try client.accountBalances(account: account))
        }
        for (start, end) in [("2023-02-29", "2024-01-01"), ("0000-01-01", "2024-01-01"), ("2024-2-01", "2025-01-01"), ("2025-01-01", "2024-01-01"), ("2024-01-01", "2024-01-01"), ("", "2024-01-01"), ("2024-01-01", "")] {
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", start: start, end: end))
        }
        XCTAssertThrowsError(try client.accounts(cursor: String(repeating: "é", count: 257)))
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", cursor: String(repeating: "x", count: 513)))
        XCTAssertEqual(backend.calls, 0)
    }
    func testRejectWrongAccountBasisDatesAndDecimalSpellings() throws {
        let (client, backend) = client("")
        for bad in ["", "01", "-0", "+1", "1.0", "0.00", "1.", ".1", "1e2", "NaN", "Infinity", "1/2", "1,2", " 1", "١", "--1"] {
            backend.response = balance(bad)
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock")) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
        }
        for bad in [balance().replacingOccurrences(of: "Assets:Stock", with: "Assets:Other"), balance().replacingOccurrences(of: "native_nominal", with: "valuation"), balance().replacingOccurrences(of: "\"balances\":", with: "\"start\":\"2024-01-01\",\"balances\":"), balance().replacingOccurrences(of: "\"quantity\":\"123456789012345678901234567890.00000000000000000001\"", with: "\"quantity\":1")] {
            backend.response = bad
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock"))
        }
        for bad in [row.replacingOccurrences(of: "\"id\":7", with: "\"id\":8"), row.replacingOccurrences(of: "\"Kind\":\"open\"", with: "\"Kind\":\"close\""), row.replacingOccurrences(of: "2024-02-29", with: "2023-02-29"), row.replacingOccurrences(of: "\"Account\":\"Assets:Stock\"", with: "\"Account\":\"Assets:Wrong\"")] {
            backend.response = catalog(bad)
            XCTAssertThrowsError(try client.accounts())
        }
    }
    func testWireByteRowAndCursorCapsAndNullPages() throws {
        let (client, backend) = client(String(repeating: "x", count: (1 << 20) + 1))
        XCTAssertThrowsError(try client.accounts()) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock")) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        backend.response = #"{"revision":"r","accounts":[\#(Array(repeating: row, count: 501).joined(separator: ","))]}"#
        XCTAssertThrowsError(try client.accounts(limit: 500)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        let unit = #"{"currency":"XYZ","quantity":"1"}"#
        backend.response = #"{"revision":"r","basis":"native_nominal","account":"Assets:Stock","balances":[\#(Array(repeating: unit, count: 501).joined(separator: ","))]}"#
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", limit: 500)) { XCTAssertEqual($0 as? BoundedReadIndexError, .resourceLimit) }
        for cursor in ["", String(repeating: "x", count: 513), "same"] {
            backend.response = catalog().replacingOccurrences(of: "\"next\"", with: "\"\(cursor)\"")
            XCTAssertThrowsError(try client.accounts(cursor: "same"))
            backend.response = balance().dropLast() + ",\"next_cursor\":\"\(cursor)\"}"
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", cursor: "same"))
        }
        backend.response = #"{"revision":"r","accounts":null}"#
        XCTAssertTrue(try client.accounts().accounts.isEmpty)
        backend.response = #"{"revision":"r","basis":"native_nominal","account":"Assets:Stock","balances":null}"#
        XCTAssertTrue(try client.accountBalances(account: "Assets:Stock").balances.isEmpty)
        backend.response = #"{"revision":"r","account":"Assets:Stock","basis":"native_nominal","balances":[{"currency":"Z","quantity":"1"},{"currency":"A","quantity":"2"}]}"#
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock"))
        backend.response = catalog(row + "," + row)
        XCTAssertThrowsError(try client.accounts())
    }
    func testFullWirePageAcceptedButRequestedRowLimitEnforced() throws {
        let (client, backend) = client("")
        let accounts = (1...500).map { id in
            let name = String(format: "Assets:%04d", id)
            return row.replacingOccurrences(of: "Assets:Stock", with: name)
                .replacingOccurrences(of: "\"open_id\":7", with: "\"open_id\":\(id)")
                .replacingOccurrences(of: "\"id\":7", with: "\"id\":\(id)")
        }.joined(separator: ",")
        backend.response = #"{"revision":"r","accounts":[\#(accounts)]}"#
        XCTAssertEqual(try client.accounts(limit: 500).accounts.count, 500)
        XCTAssertThrowsError(try client.accounts(limit: 100)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
        let units = (1...500).map { id in
            #"{"currency":"U\#(String(format: "%04d", id))","quantity":"1"}"#
        }.joined(separator: ",")
        backend.response = #"{"revision":"r","account":"Assets:Stock","basis":"native_nominal","balances":[\#(units)]}"#
        XCTAssertEqual(try client.accountBalances(account: "Assets:Stock", limit: 500).balances.count, 500)
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", limit: 100)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
        // A valid interval for the wrong request must still be rejected.
        backend.response = balance().replacingOccurrences(of: "\"balances\":", with: "\"start\":\"2024-01-01\",\"end\":\"2025-01-01\",\"balances\":")
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", start: "2024-02-01", end: "2025-01-01"))
        XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock", start: "2024-01-01", end: "2025-02-01"))
    }

    func testDuplicateOpenIDsRejectedEvenForDistinctSortedNames() throws {
        // Each embedded directive ID matches its row; only cross-row identity is bad.
        let first = row.replacingOccurrences(of: "Assets:Stock", with: "Assets:A")
        let second = row.replacingOccurrences(of: "Assets:Stock", with: "Assets:B")
        let (client, _) = client(catalog(first + "," + second))
        XCTAssertThrowsError(try client.accounts()) {
            XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt)
        }
    }

    func testAccountIdentityUsesUTF8WithoutUnicodeNormalization() throws {
        let nfc = "Assets:Caf\u{00e9}"
        let nfd = "Assets:Cafe\u{0301}"
        XCTAssertEqual(nfc, nfd) // Swift equality is deliberately NOT account identity.
        XCTAssertFalse(nfc.utf8.elementsEqual(nfd.utf8))
        let first = row.replacingOccurrences(of: "Assets:Stock", with: nfd)
        let second = row.replacingOccurrences(of: "Assets:Stock", with: nfc)
            .replacingOccurrences(of: "\"open_id\":7", with: "\"open_id\":8")
            .replacingOccurrences(of: "\"id\":7", with: "\"id\":8")
        let (client, backend) = client(catalog(first + "," + second))
        let page = try client.accounts()
        XCTAssertEqual(page.accounts.map(\.openID), [7, 8])
        XCTAssertTrue(page.accounts[0].account.utf8.elementsEqual(nfd.utf8))
        XCTAssertTrue(page.accounts[1].account.utf8.elementsEqual(nfc.utf8))
        for (expected, other) in [(nfc, nfd), (nfd, nfc)] {
            backend.response = catalog(row.replacingOccurrences(of: "Assets:Stock", with: expected)
                .replacingOccurrences(of: "\"Account\":\"\(expected)\"", with: "\"Account\":\"\(other)\""))
            XCTAssertThrowsError(try client.accounts()) {
                XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt)
            }
            backend.response = balance().replacingOccurrences(of: "Assets:Stock", with: expected)
            XCTAssertTrue(try client.accountBalances(account: expected).account.utf8.elementsEqual(expected.utf8))
            backend.response = balance().replacingOccurrences(of: "Assets:Stock", with: other)
            for cursor in [nil, "continuation"] as [String?] {
                XCTAssertThrowsError(try client.accountBalances(account: expected, cursor: cursor)) {
                    XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt)
                }
            }
        }
    }

    func testPublicationManifestSchemaTwoOnly() throws {
        let digest = String(repeating: "a", count: 64)
        for schema in [1, 2, 3] {
            let index = BoundedIndexManifest(schemaVersion: schema, streamVersion: 1,
                sourceDigest: digest, runtime: "fixture", exporter: "bounded-v1", entrypoint: "main.bean",
                streamDigest: digest, records: 1, directives: 1, postings: 0, options: 0,
                commodities: 0, metadata: 0, transactions: 0, bytes: 100, maxRecordBytes: 100, revision: digest)
            let manifest = BoundedLedgerManifest(version: 1, generationID: UUID(), sourceRevisionID: UUID(), sourceIdentity: digest, index: index)
            let encoded = try JSONEncoder().encode(manifest)
            if schema == 2 {
                XCTAssertEqual(try BoundedLedgerManifest.decode(encoded), manifest)
                XCTAssertNoThrow(try manifest.encoded())
            } else {
                XCTAssertThrowsError(try BoundedLedgerManifest.decode(encoded)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
                XCTAssertThrowsError(try manifest.encoded()) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
                let (client, backend) = client("")
                XCTAssertThrowsError(try client.open(databasePath: "index.sqlite", manifest: index)) { XCTAssertEqual($0 as? BoundedReadIndexError, .corrupt) }
                XCTAssertEqual(backend.calls, 0)
            }
        }
    }

    func testLockedClosedAndInFlightCancellationBothOperations() async throws {
        for accounts in [true, false] {
            let (client, backend) = client(accounts ? catalog() : balance())
            client.lock()
            XCTAssertThrowsError(try client.accounts())
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock"))
            XCTAssertEqual(backend.calls, 0)
            client.unlock(); backend.block = true
            let operation = Task.detached {
                if accounts { _ = try client.accounts() }
                else { _ = try client.accountBalances(account: "Assets:Stock") }
            }
            let started = await Task.detached { backend.started.wait(timeout: .now() + 5) == .success }.value
            XCTAssertTrue(started)
            XCTAssertThrowsError(try client.accounts()) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock")) { XCTAssertEqual($0 as? BoundedReadIndexError, .busy) }
            XCTAssertEqual(backend.calls, 1)
            client.cancel(); backend.release.signal()
            do { try await operation.value; XCTFail("late result") }
            catch { XCTAssertEqual(error as? BoundedReadIndexError, .canceled) }
            client.close(); client.unlock()
            XCTAssertThrowsError(try client.accounts())
            XCTAssertThrowsError(try client.accountBalances(account: "Assets:Stock"))
        }
    }
}
