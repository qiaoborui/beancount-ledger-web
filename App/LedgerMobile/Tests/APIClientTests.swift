import Foundation
import XCTest
@testable import LedgerMobile

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testHealthUsesExpectedEndpointAndDecodesCapabilities() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ledger.example.com/api/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(
                for: request,
                body: #"{"apiVersion":1,"capabilities":["full-backend","cookie-auth"]}"#
            )
        }

        let status = try await makeClient().health(baseURL: URL(string: "https://ledger.example.com")!)
        XCTAssertEqual(status, HealthStatus(apiVersion: 1, capabilities: ["full-backend", "cookie-auth"]))
    }

    func testAuthStatusUsesExpectedEndpoint() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://ledger.example.com/api/auth/me")
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(
                for: request,
                body: #"{"authenticated":true,"sensitiveUnlocked":true,"authDisabled":false}"#
            )
        }

        let status = try await makeClient().authStatus(baseURL: URL(string: "https://ledger.example.com")!)
        XCTAssertEqual(status, AuthStatus(authenticated: true, sensitiveUnlocked: true, authDisabled: false))
    }

    func testLoginSendsPasswordAsJSON() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/auth/login")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.bodyData(from: request)
            let decoded = try JSONDecoder().decode([String: String].self, from: body)
            XCTAssertEqual(decoded, ["password": "test-password"])
            return Self.response(for: request, body: #"{"ok":true}"#)
        }

        try await makeClient().login(
            baseURL: URL(string: "https://ledger.example.com")!,
            password: "test-password"
        )
    }

    func testPasskeyStatusOptionsAndVerificationUseServerProtocol() async throws {
        var requestIndex = 0
        MockURLProtocol.requestHandler = { request in
            requestIndex += 1
            switch requestIndex {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/passkey/status")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(for: request, body: #"{"registered":true,"count":2}"#)
            case 2:
                XCTAssertEqual(request.url?.path, "/api/passkey/login/options")
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(
                    for: request,
                    body: #"{"challenge":"AQID","rpId":"beancount.borry.org","allowCredentials":[{"type":"public-key","id":"BAUG","transports":["internal"]}],"userVerification":"required"}"#
                )
            default:
                XCTAssertEqual(request.url?.path, "/api/passkey/login/verify")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["id"] as? String, "AQID")
                XCTAssertEqual(json["rawId"] as? String, "AQID")
                XCTAssertEqual(json["type"] as? String, "public-key")
                return Self.response(for: request, body: #"{"ok":true}"#)
            }
        }

        let client = makeClient()
        let baseURL = URL(string: "https://ledger.example.com")!
        let status = try await client.passkeyStatus(baseURL: baseURL)
        XCTAssertEqual(status, PasskeyStatus(registered: true, count: 2))
        let options = try await client.passkeyLoginOptions(baseURL: baseURL)
        XCTAssertEqual(options.challenge, "AQID")
        XCTAssertEqual(options.relyingPartyID, "beancount.borry.org")
        XCTAssertEqual(options.allowCredentials.first?.id, "BAUG")
        try await client.verifyPasskey(
            baseURL: baseURL,
            assertion: PasskeyAssertion(
                credentialID: Data([1, 2, 3]),
                clientDataJSON: Data([4]),
                authenticatorData: Data([5]),
                signature: Data([6]),
                userHandle: Data()
            )
        )
        XCTAssertEqual(requestIndex, 3)
    }

    func testQuickUnlockRegistrationAndVerificationUseServerProtocol() async throws {
        var requestIndex = 0
        MockURLProtocol.requestHandler = { request in
            requestIndex += 1
            let body = try Self.bodyData(from: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: String]
            if requestIndex == 1 {
                XCTAssertEqual(request.url?.path, "/api/quick-unlock/register")
                XCTAssertEqual(json, ["mode": "text", "name": "Ledger iPhone"])
                return Self.response(for: request, body: #"{"deviceId":"device-12345678","token":"secret-token"}"#)
            }
            XCTAssertEqual(request.url?.path, "/api/quick-unlock/verify")
            XCTAssertEqual(json, ["deviceId": "device-12345678", "token": "secret-token"])
            return Self.response(for: request, body: #"{"ok":true}"#)
        }

        let client = makeClient()
        let credential = try await client.registerQuickUnlock(
            baseURL: URL(string: "https://ledger.example.com")!,
            deviceName: "Ledger iPhone"
        )
        XCTAssertEqual(credential, QuickUnlockCredential(deviceID: "device-12345678", token: "secret-token"))
        try await client.verifyQuickUnlock(
            baseURL: URL(string: "https://ledger.example.com")!,
            credential: credential
        )
        XCTAssertEqual(requestIndex, 2)
    }

    func testBootstrapAddsCurrentRangeQuery() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
            XCTAssertEqual(components.path, "/api/ledger/bootstrap")
            XCTAssertEqual(query, [
                "start": "2026-08-01",
                "end": "2026-09-01",
                "today": "2026-08-30",
                "valuationCurrency": "USD",
            ])
            return Self.response(for: request, body: LedgerModelsTests.bootstrapJSON)
        }

        let payload = try await makeClient().bootstrap(
            baseURL: URL(string: "https://ledger.example.com")!,
            start: "2026-08-01",
            end: "2026-09-01",
            today: "2026-08-30",
            valuationCurrency: "USD"
        )
        XCTAssertEqual(payload.transactions.count, 2)
    }

    func testHomeReportUsesCurrentMonthAndDecodesExpenseOnlySurface() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/api/ledger/home-report")
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "start", value: "2026-08-01"),
                    URLQueryItem(name: "end", value: "2026-09-01"),
                    URLQueryItem(name: "valuationCurrency", value: "CNY"),
                ]
            )
            return Self.response(for: request, body: Self.homeReportJSON)
        }

        let report = try await makeClient().homeReport(
            baseURL: URL(string: "https://ledger.example.com")!,
            start: "2026-08-01",
            end: "2026-09-01",
            valuationCurrency: "CNY"
        )

        XCTAssertEqual(report.current.kpis.expense, 555_180)
        XCTAssertEqual(report.current.kpis.transactionCount, 9)
        XCTAssertEqual(report.previous.kpis.expense, 635_200)
        XCTAssertEqual(report.current.categorySeries.first?.label, "居住")
        XCTAssertEqual(report.dailyExpenseSeries.last?.amount, 32_800)
    }

    func testImportDocumentsUsesReadOnlyHistoryEndpoint() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/imports/documents")
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(
                for: request,
                body: #"{"documents":[{"path":"transactions/2026/documents/imports/private.csv","name":"private.csv","year":"2026","ext":".csv","provider":"alipay","dateStart":"2026-08-01","dateEnd":"2026-08-28","size":1024,"modTime":"2026-08-29T08:00:00Z"}]}"#
            )
        }

        let documents = try await makeClient().importDocuments(
            baseURL: URL(string: "https://ledger.example.com")!
        )

        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents.first?.provider, "alipay")
        XCTAssertEqual(documents.first?.dateEnd, "2026-08-28")
        XCTAssertEqual(documents.first?.modTime, "2026-08-29T08:00:00Z")
    }

    func testAccountDetailEncodesAccountAndDecodesRows() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/api/ledger/accounts/detail")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "account", value: "Assets:Bank:Daily")])
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(for: request, body: LedgerModelsTests.accountDetailJSON)
        }

        let detail = try await makeClient().accountDetail(
            baseURL: URL(string: "https://ledger.example.com")!,
            account: "Assets:Bank:Daily"
        )
        XCTAssertEqual(detail.label, "日常账户")
        XCTAssertEqual(detail.currentBalance, 1_235_000)
        XCTAssertEqual(detail.rows.first?.transaction.payee, "海底捞")
    }

    func testDashboardAddsRangeQueryAndDecodesAnalytics() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/api/ledger/dashboard")
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "start", value: "2026-08-01"),
                    URLQueryItem(name: "end", value: "2026-09-01"),
                    URLQueryItem(name: "valuationCurrency", value: "USD"),
                ]
            )
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(for: request, body: Self.dashboardJSON)
        }

        let dashboard = try await makeClient().dashboard(
            baseURL: URL(string: "https://ledger.example.com")!,
            start: "2026-08-01",
            end: "2026-09-01",
            valuationCurrency: "USD"
        )

        XCTAssertEqual(dashboard.kpis.netWorth, 1_414_910_466)
        XCTAssertEqual(dashboard.cashflowSeries.first?.income, 5_050_000)
        XCTAssertEqual(dashboard.categorySeries.first?.label, "居住")
        XCTAssertEqual(dashboard.anomalies.first?.payee, "城市书房")
    }

    func testIncomeStatementAddsRangeQueryAndDecodesHierarchy() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/api/ledger/income-statement")
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "start", value: "2026-08-01"),
                    URLQueryItem(name: "end", value: "2026-09-01"),
                    URLQueryItem(name: "valuationCurrency", value: "USD"),
                ]
            )
            return Self.response(for: request, body: Self.incomeStatementJSON)
        }

        let statement = try await makeClient().incomeStatement(
            baseURL: URL(string: "https://ledger.example.com")!,
            start: "2026-08-01",
            end: "2026-09-01",
            valuationCurrency: "USD"
        )

        XCTAssertEqual(statement.netIncome, 4_494_820)
        XCTAssertEqual(statement.expense.first?.children.first?.label, "房租")
        XCTAssertEqual(statement.expense.first?.children.first?.depth, 1)
    }

    func testInvestmentsUsesExpectedEndpointAndPreservesMissingValuation() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/investments")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(for: request, body: Self.investmentsJSON)
        }

        let investments = try await makeClient().investments(
            baseURL: URL(string: "https://ledger.example.com")!
        )

        XCTAssertEqual(investments.totalMarketValueCny, 67_850_000)
        XCTAssertEqual(investments.holdings.first?.commodity, "VT")
        XCTAssertNil(investments.holdings.last?.totalMarketValueCny)
        XCTAssertNil(investments.realizedPnlCny)
    }

    func testInvestmentsDecodesEmptyLedgerNullCollections() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/investments")
            return Self.response(
                for: request,
                body: #"{"totalMarketValueCny":0,"holdings":null,"positions":null}"#
            )
        }

        let investments = try await makeClient().investments(
            baseURL: URL(string: "https://ledger.example.com")!
        )

        XCTAssertEqual(investments.totalMarketValueCny, 0)
        XCTAssertEqual(investments.holdings, [])
        XCTAssertEqual(investments.positions, [])
    }

    func testBQLRunSendsCurrencyAndDecodesDynamicRows() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/bql")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["query"], "SELECT month, sum(value) AS total FROM postings GROUP BY month")
            XCTAssertEqual(json["valuationCurrency"], "CNY")
            return Self.response(for: request, body: Self.bqlResultJSON)
        }

        let result = try await makeClient().runBQL(
            baseURL: URL(string: "https://ledger.example.com")!,
            query: "SELECT month, sum(value) AS total FROM postings GROUP BY month",
            valuationCurrency: "CNY"
        )

        XCTAssertEqual(result.rowCount, 2)
        XCTAssertEqual(result.rows[0], [.string("2026-08"), .number(555_180)])
        XCTAssertEqual(result.warnings, ["结果已限制为 100 行"])
    }

    func testBQLHistoryUsesAllServerEndpointsIncludingNoContentDelete() async throws {
        var requestIndex = 0
        MockURLProtocol.requestHandler = { request in
            requestIndex += 1
            switch requestIndex {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/ledger/bql-history")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(for: request, body: #"{"records":[\#(Self.bqlHistoryRecordJSON)]}"#)
            case 2:
                XCTAssertEqual(request.url?.path, "/api/ledger/bql-history")
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["query"], "SELECT * FROM transactions")
                return Self.response(for: request, body: Self.bqlHistoryRecordJSON)
            case 3:
                XCTAssertEqual(request.url?.path, "/api/ledger/bql-history/history-1/title")
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(for: request, body: Self.bqlHistoryRecordJSON)
            case 4:
                XCTAssertEqual(request.url?.path, "/api/ledger/bql-history/history-1")
                XCTAssertEqual(request.httpMethod, "PATCH")
                let body = try Self.bodyData(from: request)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["title"], "最近交易")
                return Self.response(for: request, body: Self.bqlHistoryRecordJSON)
            default:
                XCTAssertEqual(request.url?.path, "/api/ledger/bql-history/history-1")
                XCTAssertEqual(request.httpMethod, "DELETE")
                return Self.response(for: request, status: 204, body: "")
            }
        }

        let client = makeClient()
        let baseURL = URL(string: "https://ledger.example.com")!
        let history = try await client.bqlHistory(baseURL: baseURL)
        XCTAssertEqual(history.count, 1)
        _ = try await client.saveBQLHistory(baseURL: baseURL, query: "SELECT * FROM transactions")
        _ = try await client.generateBQLHistoryTitle(baseURL: baseURL, id: "history-1")
        _ = try await client.renameBQLHistory(baseURL: baseURL, id: "history-1", title: "最近交易")
        try await client.deleteBQLHistory(baseURL: baseURL, id: "history-1")
        XCTAssertEqual(requestIndex, 5)
    }

    func testServerErrorSurfacesMessage() async {
        MockURLProtocol.requestHandler = { request in
            Self.response(for: request, status: 401, body: #"{"error":"Invalid password"}"#)
        }

        do {
            try await makeClient().login(
                baseURL: URL(string: "https://ledger.example.com")!,
                password: "wrong"
            )
            XCTFail("Expected login to fail")
        } catch let error as LedgerAPIError {
            XCTAssertEqual(error.localizedDescription, "Invalid password")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient() -> LedgerAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return LedgerAPIClient(session: URLSession(configuration: configuration))
    }

    private static func response(for request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count < 0 { throw stream.streamError ?? LedgerAPIError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static let dashboardJSON = #"""
    {
      "start":"2026-08-01",
      "end":"2026-09-01",
      "currency":"CNY",
      "kpis":{"assets":1415200366,"liabilities":289900,"netWorth":1414910466,"income":5050000,"expense":555180,"net":4494820,"savingsRate":0.8901},
      "netWorthSeries":[{"date":"2026-08","assets":1415200366,"liabilities":289900,"netWorth":1414910466}],
      "cashflowSeries":[{"month":"08","income":5050000,"expense":555180,"net":4494820}],
      "categorySeries":[{"account":"Expenses:Housing","alias":"居住","label":"居住","total":380000,"values":[]}],
      "topPayees":[{"payee":"房屋租金","amount":380000,"txCount":1}],
      "topPaymentAccounts":[{"account":"Assets:Bank:Daily","alias":"日常账户","label":"日常账户","amount":380000,"txCount":1}],
      "anomalies":[{"date":"2026-08-28","payee":"城市书房","narration":"年度阅读计划","account":"Expenses:Education:Books","amount":32800,"source":"transactions/2026/08.bean:88"}]
    }
    """#

    private static let homeReportJSON = #"""
    {
      "start":"2026-08-01",
      "end":"2026-09-01",
      "previousStart":"2025-08-01",
      "previousEnd":"2025-09-01",
      "currency":"CNY",
      "current":{
        "kpis":{"income":5050000,"expense":555180,"net":4494820,"transactionCount":9,"savingsRate":0.8901},
        "cashflowSeries":[],
        "categorySeries":[{"account":"Expenses:Housing","alias":"居住","label":"居住","total":380000,"values":[]}]
      },
      "previous":{
        "kpis":{"income":4800000,"expense":635200,"net":4164800,"transactionCount":12,"savingsRate":0.8677},
        "cashflowSeries":[],
        "categorySeries":[]
      },
      "budget":{"configured":false,"amount":0,"currency":"CNY"},
      "dailyExpenseSeries":[
        {"date":"2026-08-09","weekday":"周日","amount":380000,"txCount":1},
        {"date":"2026-08-28","weekday":"周五","amount":32800,"txCount":1}
      ],
      "accountBalanceSeries":[],
      "topPaymentAccounts":[],
      "generatedAt":"2026-08-31T05:30:00Z"
    }
    """#

    private static let incomeStatementJSON = #"""
    {
      "start":"2026-08-01",
      "end":"2026-09-01",
      "income":[{"account":"Income:Salary","alias":"工资","label":"工资","amount":5050000,"children":[],"depth":0,"txCount":1}],
      "expense":[{"account":"Expenses:Housing","alias":"居住","label":"居住","amount":380000,"children":[{"account":"Expenses:Housing:Rent","alias":"房租","label":"房租","amount":380000,"children":[],"depth":1,"txCount":1}],"depth":0,"txCount":1}],
      "totalIncome":5050000,
      "totalExpense":555180,
      "netIncome":4494820,
      "valuationCurrency":"CNY"
    }
    """#

    private static let investmentsJSON = #"""
    {
      "totalMarketValueCny":67850000,
      "holdings":[
        {"commodity":"VT","commodityName":"全球股票指数","totalQuantity":823.47,"averageCost":108.34,"totalCostValueCny":58270000,"totalMarketValueCny":67850000,"accountCount":2},
        {"commodity":"PRIVATE","commodityName":"未上市权益","totalQuantity":10,"accountCount":1}
      ],
      "positions":[],
      "updatedAt":"2026-08-30T16:00:00Z"
    }
    """#

    private static let bqlResultJSON = #"""
    {
      "columns":[{"name":"month","type":"date"},{"name":"total","type":"money"}],
      "rows":[["2026-08",555180],["2026-07",482300]],
      "query":"SELECT month, sum(value) AS total FROM postings GROUP BY month",
      "warnings":["结果已限制为 100 行"],
      "valuationCurrency":"CNY",
      "limit":100,
      "rowCount":2
    }
    """#

    private static let bqlHistoryRecordJSON = #"{"id":"history-1","query":"SELECT * FROM transactions","title":"最近交易","titleSource":"manual","createdAt":"2026-08-30T12:00:00Z","lastRunAt":"2026-08-30T12:30:00Z","runCount":2}"#
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: LedgerAPIError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
