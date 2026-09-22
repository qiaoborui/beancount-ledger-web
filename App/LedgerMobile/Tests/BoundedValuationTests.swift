import Foundation
import XCTest
@testable import LedgerMobile

final class BoundedValuationTests: XCTestCase {
    private func price(_ quantity: String = "1.00500000000000000001") -> String {
        #"{"revision":"r1","tie_policy":"source_sequence_last","found":true,"price":{"sequence":9,"entry_id":3,"date":"2026-01-01","currency":" éur ","quantity":"\#(quantity)","quote_currency":" usd "}}"#
    }
    private func cents(_ amount: Int64 = 0, found: Bool = true) -> String {
        #"{"revision":"r1","basis":"legacy_cents","tie_policy":"source_sequence_last","amount":\#(amount),"found":\#(found)}"#
    }
    private func fixture(_ response: String) -> (BoundedReadIndexClient, ValuationBackend) {
        let backend = ValuationBackend(response)
        let client = BoundedReadIndexClient(backend: backend)
        client.unlock()
        return (client, backend)
    }
    private func query(_ client: BoundedReadIndexClient, cents: Bool, base: String = "éur", quote: String = "USD", date: String? = nil) throws {
        if cents { _ = try client.valueLegacyCents(amount: 123, base: base, quote: quote, date: date) }
        else { _ = try client.priceLookup(base: base, quote: quote, date: date) }
    }
    private func error(_ expected: BoundedReadIndexError, _ operation: () throws -> Void,
                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? BoundedReadIndexError, expected, file: file, line: line)
        }
    }

    func testExactRawQuotesAndCanonicalExponentGrammar() throws {
        for quantity in ["1.00500000000000000001", "3e0", "1e999999999", "-0.000", "+001.2300E-999", ".1", "1.", String(repeating: "9", count: 4097)] {
            let (client, backend) = fixture(price(quantity))
            let result = try client.priceLookup(base: " \téur\u{2003}", quote: "USD", date: "2026-01-01")
            XCTAssertTrue(result.found)
            XCTAssertEqual(result.tiePolicy, "source_sequence_last")
            XCTAssertEqual(result.price?.quantity, quantity)
            XCTAssertEqual(result.price?.currency, " éur ")
            XCTAssertEqual(result.price?.quoteCurrency, " usd ")
            XCTAssertEqual(result.price?.sequence, 9)
            XCTAssertEqual(result.price?.entryID, 3)
            struct Request: Decodable { let base: String; let quote: String; let date: String }
            let request = try JSONDecoder().decode(Request.self, from: Data(backend.request.utf8))
            XCTAssertEqual(request.base, " \téur\u{2003}")
            XCTAssertEqual(request.quote, "USD")
            XCTAssertEqual(request.date, "2026-01-01")
        }
    }

    func testLegacyCentsInt64RoundTripsWithoutFloatingPoint() throws {
        for amount: Int64 in [.min, .max, -9_007_199_254_740_993, 9_007_199_254_740_993, -1, 0, 1] {
            let (client, backend) = fixture(cents(amount))
            let result = try client.valueLegacyCents(amount: amount, base: "USD", quote: "USD")
            XCTAssertEqual(result.amount, amount)
            XCTAssertEqual(result.basis, "legacy_cents")
            XCTAssertEqual(result.tiePolicy, "source_sequence_last")
            XCTAssertTrue(result.found)
            struct Request: Decodable { let amount: Int64; let basis: String; let base: String; let quote: String; let date: String? }
            let request = try JSONDecoder().decode(Request.self, from: Data(backend.request.utf8))
            XCTAssertEqual(request.amount, amount)
            XCTAssertEqual(request.basis, "legacy_cents")
            XCTAssertEqual(request.base, "USD")
            XCTAssertEqual(request.quote, "USD")
            XCTAssertNil(request.date)
        }
    }

    func testMissingIsNotZeroConversionOrBackendError() throws {
        let (client, backend) = fixture(#"{"revision":"r1","tie_policy":"source_sequence_last","found":false}"#)
        let missing = try client.priceLookup(base: "ABSENT", quote: "USD")
        XCTAssertFalse(missing.found)
        XCTAssertNil(missing.price)
        backend.response = cents(found: false)
        XCTAssertFalse(try client.valueLegacyCents(amount: 123, base: "ABSENT", quote: "USD").found)
        backend.response = cents(0)
        XCTAssertTrue(try client.valueLegacyCents(amount: 123, base: "USD", quote: "USD").found)
        for code in [BoundedReadIndexError.resourceLimit, .corrupt, .unavailable, .canceled, .invalidRequest, .notFound] {
            backend.response = #"{"error":{"code":"\#(code.rawValue)"}}"#
            for isCents in [false, true] { error(code) { try query(client, cents: isCents) } }
        }
        // Even identity/zero requests must consult Go; never fabricate results.
        error(.notFound) { _ = try client.valueLegacyCents(amount: 0, base: "USD", quote: "USD") }
    }

    func testMalformedAndContradictoryPriceResultsFailClosed() {
        let valid = price()
        let malformed = [
            valid.replacingOccurrences(of: "source_sequence_last", with: "source_sequence_first"),
            valid.replacingOccurrences(of: "\"found\":true", with: "\"found\":false"),
            valid.replacingOccurrences(of: "\"found\":true,", with: ""),
            valid.replacingOccurrences(of: "\"sequence\":9", with: "\"sequence\":0"),
            valid.replacingOccurrences(of: "\"entry_id\":3", with: "\"entry_id\":-1"),
            valid.replacingOccurrences(of: "2026-01-01", with: "2026-02-29"),
            valid.replacingOccurrences(of: "\"revision\":\"r1\"", with: "\"revision\":\"\""),
            valid.replacingOccurrences(of: "\"revision\":", with: "\"error\":{},\"revision\":"),
            valid.replacingOccurrences(of: "\"revision\":", with: "\"error\":null,\"revision\":"),
            #"{"revision":"r1","tie_policy":"source_sequence_last","found":true,"price":null}"#,
            #"{"revision":"r1","tie_policy":"source_sequence_last","found":true}"#,
        ]
        for json in malformed {
            let (client, _) = fixture(json)
            error(.corrupt) { _ = try client.priceLookup(base: "EUR", quote: "USD") }
        }
        for quantity in ["", "NaN", "Inf", "-Inf", "1/2", "1_000", " 1", "1e", "1e+", ".", "1.2.3", "1e2x", "١", "--1"] {
            let (client, _) = fixture(price(quantity))
            error(.corrupt) { _ = try client.priceLookup(base: "EUR", quote: "USD") }
        }
        let (client, _) = fixture(valid)
        error(.corrupt) { _ = try client.priceLookup(base: "EUR", quote: "USD", date: "2025-12-31") }
    }

    func testMalformedAndContradictoryCentsResultsFailClosed() {
        let valid = cents(1)
        for json in [
            valid.replacingOccurrences(of: "legacy_cents", with: "native_nominal"),
            valid.replacingOccurrences(of: "source_sequence_last", with: "last"),
            valid.replacingOccurrences(of: "\"found\":true", with: "\"found\":false"),
            valid.replacingOccurrences(of: "\"found\":true", with: "\"found\":null"),
            valid.replacingOccurrences(of: "\"amount\":1,", with: ""),
            valid.replacingOccurrences(of: "\"revision\":\"r1\"", with: "\"revision\":\"\""),
            valid.replacingOccurrences(of: "\"revision\":", with: "\"error\":{},\"revision\":"),
        ] + ["null", "1.25", "9223372036854775808", "-9223372036854775809", "\"1\""].map({ valid.replacingOccurrences(of: "\"amount\":1", with: "\"amount\":\($0)") }) {
            let (client, _) = fixture(json)
            error(.corrupt) { _ = try client.valueLegacyCents(amount: 1, base: "EUR", quote: "USD") }
        }
    }

    func testRequestDatesAndByteLimitsBeforeBackend() throws {
        for isCents in [false, true] {
            let (client, backend) = fixture(isCents ? cents() : price())
            for date in ["2026-02-29", "1900-02-29", "0000-01-01", "2026-04-31", "2026-1-01", "2026-01-01Z", "2026-01-01\n", "２０２６-01-01"] {
                error(.invalidRequest) { try query(client, cents: isCents, date: date) }
            }
            for currency in [String(repeating: "é", count: 513), "U\0SD", "U\tSD", "U\u{007F}SD", "U\u{0085}SD"] {
                error(.invalidRequest) { try query(client, cents: isCents, base: currency) }
                error(.invalidRequest) { try query(client, cents: isCents, quote: currency) }
            }
            XCTAssertEqual(backend.calls, 0)
            let escaped = String(repeating: "\"", count: 1024)
            error(.resourceLimit) { try query(client, cents: isCents, base: escaped, quote: escaped) }
            XCTAssertEqual(backend.calls, 0)
            for currency in ["", " \t\r\n", "éur", "ß", "\u{00A0}usd\u{2003}", String(repeating: "é", count: 512), "U\u{200B}SD"] {
                try query(client, cents: isCents, base: currency)
            }
            // Latest and inclusive valid dates; no date normalization by Swift.
            for date in [nil, "", "2026-01-01", "2028-02-29", "9999-12-31"] {
                try query(client, cents: isCents, date: date)
            }
        }
    }

    func testScalarAndWholeResponseCaps() throws {
        let cap = BoundedIndexWire.responseLimit / 6 - 4096
        let (client, backend) = fixture(price(String(repeating: "9", count: cap)))
        XCTAssertEqual(try client.priceLookup(base: "EUR", quote: "USD").price?.quantity.utf8.count, cap)
        backend.response = price(String(repeating: "9", count: cap + 1))
        error(.resourceLimit) { _ = try client.priceLookup(base: "EUR", quote: "USD") }
        backend.response = price().replacingOccurrences(of: " éur ", with: String(repeating: "é", count: 513))
        error(.corrupt) { _ = try client.priceLookup(base: "EUR", quote: "USD") }
        for isCents in [false, true] {
            let valid = isCents ? cents() : price()
            backend.response = valid + String(repeating: " ", count: BoundedIndexWire.responseLimit - valid.utf8.count)
            try query(client, cents: isCents)
            backend.response += " "
            error(.resourceLimit) { try query(client, cents: isCents) }
        }
    }

    func testUnavailableDefaultsKeepOldInjectedBackendsCompatible() {
        let client = BoundedReadIndexClient(backend: OldValuationBackend())
        client.unlock()
        for isCents in [false, true] { error(.unavailable) { try query(client, cents: isCents) } }
    }

    func testLifecycleCancellationBusyLockAndClose() async throws {
        for isCents in [false, true] {
            for transition in ["cancel", "lock", "close"] {
                let (client, backend) = fixture(isCents ? cents() : price())
                client.lock()
                error(.unavailable) { try query(client, cents: isCents) }
                XCTAssertEqual(backend.calls, 0)
                client.unlock()
                backend.block = true
                let work = Task.detached {
                    if isCents { _ = try client.valueLegacyCents(amount: 1, base: "EUR", quote: "USD") }
                    else { _ = try client.priceLookup(base: "EUR", quote: "USD") }
                }
                let entered = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: backend.entered.wait(timeout: .now() + 5) == .success) }
                }
                XCTAssertTrue(entered)
                error(.busy) { try query(client, cents: isCents) }
                switch transition {
                case "cancel": client.cancel()
                case "lock": client.lock()
                default: client.close()
                }
                do { try await work.value; XCTFail("stale result escaped") }
                catch { XCTAssertEqual(error as? BoundedReadIndexError, transition == "cancel" ? .canceled : .unavailable) }
                backend.block = false
                client.unlock()
                if transition == "close" { error(.unavailable) { try query(client, cents: isCents) } }
                else { try query(client, cents: isCents) }
            }
        }
    }
}

/// No new methods: protocol defaults must fail unavailable, not fall back.
private struct OldValuationBackend: BoundedReadIndexBackend {
    func build(_ streamPath: String, destination: String) -> String { "" }
    func open(_ databasePath: String, manifestJSON: String) -> String { "" }
    func transactions(_ requestJSON: String) -> String { "" }
    func detail(_ id: Int64) -> String { "" }
    func unlock() {}
    func cancel() {}
    func lock() {}
    func close() {}
}

private final class ValuationBackend: BoundedReadIndexBackend, @unchecked Sendable {
    var response: String
    var request = ""
    var calls = 0
    var block = false
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    init(_ response: String) { self.response = response }
    private func respond(_ request: String) -> String {
        self.request = request
        calls += 1
        if block { entered.signal(); release.wait() }
        return response
    }
    func priceLookup(_ requestJSON: String) -> String { respond(requestJSON) }
    func valueLegacyCents(_ requestJSON: String) -> String { respond(requestJSON) }
    func build(_ streamPath: String, destination: String) -> String { "" }
    func open(_ databasePath: String, manifestJSON: String) -> String { "" }
    func transactions(_ requestJSON: String) -> String { "" }
    func detail(_ id: Int64) -> String { "" }
    func unlock() {}
    func cancel() { if block { release.signal() } }
    func lock() { if block { release.signal() } }
    func close() { if block { release.signal() } }
}
