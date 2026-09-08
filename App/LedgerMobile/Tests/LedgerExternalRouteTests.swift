import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LedgerMobile

@MainActor
final class LedgerExternalRouteTests: XCTestCase {
    func testPlainSystemDestinationsAndSearchDefaults() throws {
        for (host, destination) in [
            ("overview", LedgerDestination.overview), ("transactions", .transactions),
            ("accounts", .accounts), ("imports", .imports)
        ] {
            XCTAssertEqual(try parse("ledger://" + host), .page(destination))
            XCTAssertEqual(try parse("ledger://" + host + "/"), .page(destination))
        }
        XCTAssertEqual(try parse("ledger://search"), .search(""))
        XCTAssertEqual(try parse("ledger://search?q="), .search(""))
        XCTAssertEqual(try parse("LEDGER://SEARCH?q=Coffee"), .search("Coffee"))
    }

    func testEncodedChineseAccountAndSearchPreserveReservedCharacters() throws {
        let account = "Assets:银行:日常 & 储蓄?#/卡"
        let query = "午餐 + 咖啡 & #旅行? 2026/09"
        var url = URLComponents()
        url.scheme = "ledger"
        url.host = "accounts"
        url.queryItems = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "currency", value: "CNY")]
        XCTAssertEqual(LedgerExternalRoute.parse(try XCTUnwrap(url.url)), .account(account, "CNY"))
        url.queryItems = [URLQueryItem(name: "account", value: account)]
        XCTAssertEqual(LedgerExternalRoute.parse(try XCTUnwrap(url.url)), .account(account, ""))
        url.host = "search"
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        XCTAssertEqual(LedgerExternalRoute.parse(try XCTUnwrap(url.url)), .search(query))
    }

    func testRejectsAmbiguousParametersAndUnexpectedAuthority() throws {
        for raw in [
            "https://search?q=coffee", "other://accounts", "ledger://unknown", "ledger://",
            "ledger://user@accounts", "ledger://user:password@search", "ledger://accounts:443",
            "ledger://search/extra?q=coffee", "ledger://search?q=coffee#fragment",
            "ledger://search?q=first&q=second", "ledger://search?q=&q=second",
            "ledger://search?q", "ledger://search?other=coffee", "ledger://overview?q=coffee",
            "ledger://imports?provider=wechat", "ledger://accounts?currency=CNY",
            "ledger://accounts?account=", "ledger://accounts?account=A&account=B",
            "ledger://accounts?account=A&currency=CNY&currency=USD",
            "ledger://accounts?account=A&unexpected=1", "ledger://accounts?account=A%0AB",
            "ledger://accounts?account=A&currency=CNY%0A",
            "ledger://transactions?date=2026-09-08&date=2026-09-09",
            "ledger://transactions?date=2026-09-08&other=1", "ledger://gmail-import?state=state"
        ] {
            XCTAssertNil(try parse(raw), raw)
        }
        XCTAssertNil(try parse("ledger://search?q=" + String(repeating: "a", count: 501)))
        XCTAssertNil(try parse("ledger://accounts?account=" + String(repeating: "a", count: 513)))
        XCTAssertNil(try parse("ledger://accounts?account=A&currency=" + String(repeating: "C", count: 33)))
    }

    func testValidatesCalendarDayWithoutNormalizingInvalidDates() throws {
        XCTAssertEqual(try parse("ledger://transactions?date=2028-02-29"), .transactions("2028-02-29"))
        XCTAssertEqual(try parse("ledger://transactions?date=2026-12-31"), .transactions("2026-12-31"))
        for day in ["2026-02-29", "2026-04-31", "2026-13-01", "2026-00-10", "2026-09-00", "2026-9-08", "26-09-08", "2026-09-08T00:00:00Z"] {
            XCTAssertNil(try parse("ledger://transactions?date=" + day), day)
        }
    }

    func testCheckingAndLockedSessionsDeferExternalActionsWithoutRequests() async throws {
        for locked in [false, true] {
            let suite = "ledger-external-route-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
            if locked { defaults.set(["https://ledger.example.com"], forKey: "ledger.mobile.locally-locked-origins") }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ExternalRouteRejectingURLProtocol.self]
            let session = LedgerSession(api: LedgerAPIClient(session: URLSession(configuration: configuration)), defaults: defaults)
            XCTAssertEqual(session.phase, locked ? .locked(authenticated: true) : .checking)
            let initialRange = session.selectedRange
            for raw in ["ledger://accounts?account=Assets:Bank&currency=CNY", "ledger://search?q=coffee", "ledger://transactions?date=2028-02-29"] {
                let url = try XCTUnwrap(URL(string: raw))
                session.openWidgetURL(url)
                if let day = LedgerWidgetLink.expenseDay(from: url) {
                    XCTAssertEqual(session.pendingWidgetExpenseDay, day)
                    XCTAssertNil(session.pendingExternalRoute)
                    XCTAssertFalse(session.canPresentWidgetDay)
                    await session.applyPendingExternalRoute()
                    XCTAssertNil(session.ledger)
                    XCTAssertEqual(session.selectedRange, initialRange)
                    continue
                }
                let request = try XCTUnwrap(session.pendingExternalRoute)
                XCTAssertEqual(request.route, LedgerExternalRoute.parse(url))
                await session.applyPendingExternalRoute()
                XCTAssertEqual(session.pendingExternalRoute, request)
                XCTAssertNil(session.externalAccount)
                XCTAssertTrue(session.globalSearchQuery.isEmpty)
                XCTAssertNil(session.ledger)
                XCTAssertEqual(session.selectedRange, initialRange)
            }
        }
    }

    func testGmailCallbackKeepsCorrelationAndDoesNotBecomeAnExternalRoute() throws {
        let suite = "ledger-external-gmail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://ledger.example.com", forKey: "ledger.mobile.server-origin")
        defaults.set(try JSONEncoder().encode(["https://ledger.example.com": ["ios.expected-state"]]), forKey: "ledger.mobile.gmail-oauth-states")
        let session = LedgerSession(defaults: defaults)
        session.openWidgetURL(try XCTUnwrap(URL(string: "ledger://gmail-import?gmail=connected&state=forged")))
        XCTAssertNil(session.gmailOAuthResult)
        XCTAssertNil(session.pendingExternalRoute)
        session.openWidgetURL(try XCTUnwrap(URL(string: "ledger://gmail-import?gmail=connected&state=ios.expected-state")))
        XCTAssertEqual(session.gmailOAuthResult?.status, .connected)
        XCTAssertEqual(session.primaryDestinationID, LedgerDestination.imports.rawValue)
        XCTAssertNil(session.pendingExternalRoute)
        let result = try XCTUnwrap(session.gmailOAuthResult)
        session.consumeGmailOAuthResult(id: result.id)
        session.openWidgetURL(try XCTUnwrap(URL(string: "ledger://gmail-import?gmail=connected&state=ios.expected-state")))
        XCTAssertNil(session.gmailOAuthResult)
    }

    private func parse(_ raw: String) throws -> LedgerExternalRoute? {
        LedgerExternalRoute.parse(try XCTUnwrap(URL(string: raw)))
    }
}

private final class ExternalRouteRejectingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("A deferred external route must not issue network requests")
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
