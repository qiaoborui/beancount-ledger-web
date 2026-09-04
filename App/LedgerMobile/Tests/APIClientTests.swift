import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import LedgerMobile

final class APIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testGmailEventSessionUsesLongResourceBudget() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 40
        let client = LedgerAPIClient(session: URLSession(configuration: configuration))

        XCTAssertEqual(client.gmailEventResourceTimeoutForTesting, 7 * 24 * 60 * 60)
        XCTAssertEqual(LedgerAPIClient.gmailEventResourceTimeout, 7 * 24 * 60 * 60)
        XCTAssertGreaterThan(LedgerAPIClient.gmailEventResourceTimeout, 40)
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
        XCTAssertEqual(documents.first?.path, "transactions/2026/documents/imports/private.csv")
        XCTAssertEqual(documents.first?.name, "private.csv")
        XCTAssertEqual(documents.first?.year, "2026")
        XCTAssertEqual(documents.first?.ext, ".csv")
        XCTAssertEqual(documents.first?.provider, "alipay")
        XCTAssertEqual(documents.first?.dateEnd, "2026-08-28")
        XCTAssertEqual(documents.first?.size, 1024)
        XCTAssertEqual(documents.first?.modTime, "2026-08-29T08:00:00Z")
    }

    func testImportProvidersUsesExpectedEndpointAndDecodesMetadata() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/imports/providers")
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(
                for: request,
                body: #"{"providers":[{"id":"ccb-credit","label":"建设银行信用卡","detail":"邮件、PDF 或 CSV","extensions":[".eml",".pdf",".csv"],"accept":".eml / .pdf / .csv","engine":"native-ccb-credit"}]}"#
            )
        }

        let providers = try await makeClient().importProviders(
            baseURL: URL(string: "https://ledger.example.com")!
        )

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers.first?.id, "ccb-credit")
        XCTAssertEqual(providers.first?.extensions, [".eml", ".pdf", ".csv"])
        XCTAssertEqual(providers.first?.engine, "native-ccb-credit")
    }

    func testGmailAutomationUsesNativeAPIEndpointsAndDecodesPendingPreview() async throws {
        var requestIndex = 0
        MockURLProtocol.requestHandler = { request in
            requestIndex += 1
            switch requestIndex {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/integrations/gmail/status")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(
                    for: request,
                    body: #"{"configured":true,"deliveryMode":"webhook","connected":true,"email":"ledger@example.com","label":"Bills","watchExpiration":1788768000000,"lastSyncAt":"2026-09-01T08:00:00Z","lastError":null,"allowedSenders":["billing@example.com"],"oauthRedirectUrl":"https://ledger.example.com/api/integrations/gmail/callback"}"#
                )
            case 2:
                XCTAssertEqual(request.url?.path, "/api/integrations/gmail/connect")
                XCTAssertEqual(request.url?.query, "client=ios")
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(for: request, body: #"{"url":"https://accounts.google.com/o/oauth2/auth"}"#)
            case 3:
                XCTAssertEqual(request.url?.path, "/api/ledger/imports/pending")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(for: request, body: #"{"items":[{"id":"pending-1","importId":"import-1","messageId":"message-1","sender":"billing@example.com","subject":"August statement","receivedAt":"2026-09-01T08:00:00Z","filename":"statement.pdf","provider":"cmb","candidateCount":2,"status":"ready","createdAt":"2026-09-01T08:00:00Z","updatedAt":"2026-09-01T08:01:00Z"}]}"#)
            case 4:
                XCTAssertEqual(request.url?.path, "/api/ledger/imports/pending/pending-1")
                XCTAssertEqual(request.httpMethod, "GET")
                return Self.response(
                    for: request,
                    body: #"{"item":{"id":"pending-1","importId":"import-1","messageId":"message-1","sender":"billing@example.com","subject":"August statement","receivedAt":"2026-09-01T08:00:00Z","filename":"statement.pdf","provider":"cmb","candidateCount":2,"status":"ready","createdAt":"2026-09-01T08:00:00Z","updatedAt":"2026-09-01T08:01:00Z"},"preview":{"importId":"import-1","provider":"cmb","providerDetection":{"provider":"cmb","reason":"sender","confidence":"high"},"originalFilename":"statement.pdf","dedupReport":"无重复","entries":[],"candidateCount":0,"rawRowCount":0,"filteredRowCount":0,"generatedCount":0,"excludedRowCount":0,"skippedDuplicateCount":0,"warnings":[]}}"#
                )
            case 5:
                let components = try XCTUnwrap(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                )
                XCTAssertEqual(components.path, "/api/integrations/gmail/sync")
                XCTAssertEqual(components.queryItems, [URLQueryItem(name: "pendingId", value: "pending-1")])
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(for: request, body: #"{"ok":true,"processed":1,"retryPending":false}"#)
            case 6:
                XCTAssertEqual(request.url?.path, "/api/ledger/imports/pending/pending-1")
                XCTAssertEqual(request.httpMethod, "DELETE")
                return Self.response(for: request, body: #"{"ok":true}"#)
            default:
                XCTAssertEqual(request.url?.path, "/api/integrations/gmail")
                XCTAssertEqual(request.httpMethod, "DELETE")
                return Self.response(for: request, body: #"{"ok":true}"#)
            }
        }

        let client = makeClient()
        let baseURL = URL(string: "https://ledger.example.com")!
        let status = try await client.gmailStatus(baseURL: baseURL)
        let connect = try await client.gmailConnect(baseURL: baseURL)
        let pending = try await client.gmailPendingImports(baseURL: baseURL)
        let detail = try await client.gmailPendingImport(baseURL: baseURL, id: "pending-1")
        let sync = try await client.gmailSync(baseURL: baseURL, pendingID: "pending-1")
        try await client.dismissGmailPendingImport(baseURL: baseURL, id: "pending-1")
        try await client.gmailDisconnect(baseURL: baseURL)

        XCTAssertTrue(status.usesServerPush)
        XCTAssertEqual(status.email, "ledger@example.com")
        XCTAssertEqual(connect.url.host, "accounts.google.com")
        XCTAssertEqual(pending.first?.status, "ready")
        XCTAssertEqual(detail.preview?.importID, "import-1")
        XCTAssertEqual(sync.processed, 1)
        XCTAssertEqual(requestIndex, 7)
    }

    func testGmailPendingIdentifierCannotEscapeNativeEndpoint() async {
        MockURLProtocol.requestHandler = { request in
            XCTFail("unsafe pending identifier should be rejected before request: \(request)")
            return Self.response(for: request, body: "{}")
        }

        do {
            _ = try await makeClient().gmailPendingImport(
                baseURL: URL(string: "https://ledger.example.com")!,
                id: "../../integrations/gmail"
            )
            XCTFail("expected invalid response")
        } catch LedgerAPIError.invalidResponse {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testImportPreviewBuildsMultipartBodyAndSanitizesFilename() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/imports/preview")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=LedgerMobile-"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            let body = String(decoding: try Self.bodyData(from: request), as: UTF8.self)
            XCTAssertTrue(body.contains("--\(boundary)\r\n"))
            XCTAssertTrue(body.contains("name=\"provider\"\r\n\r\nccb-credit\r\n"))
            XCTAssertTrue(body.contains("name=\"alipayFundRounding\"\r\n\r\ntrue\r\n"))
            XCTAssertTrue(body.contains("name=\"archivePassword\"\r\n\r\n password with spaces \r\n"))
            XCTAssertTrue(body.contains("name=\"file\"; filename=\"statement'____name.zip\""))
            XCTAssertTrue(body.contains("safe-bill-content"))
            XCTAssertTrue(body.hasSuffix("\r\n--\(boundary)--\r\n"))
            return Self.response(for: request, body: Self.importPreviewJSON)
        }

        let preview = try await makeClient().previewImport(
            baseURL: URL(string: "https://ledger.example.com")!,
            file: LedgerImportSelectedFile(
                name: "statement\"/\\\r\nname.zip",
                data: Data("safe-bill-content".utf8)
            ),
            provider: "ccb-credit",
            alipayFundRounding: true,
            archivePassword: " password with spaces "
        )

        XCTAssertEqual(preview.importID, "preview-123")
        XCTAssertEqual(preview.providerDetection.confidence, "high")
        XCTAssertEqual(preview.entries.first?.orderID, "order-1")
        XCTAssertEqual(preview.entries.first?.transactionType, "支出")
        XCTAssertEqual(preview.skippedDuplicateCount, 1)
    }

    func testImportPreviewOmitsProviderAndPasswordForAutomaticCSV() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = String(decoding: try Self.bodyData(from: request), as: UTF8.self)
            XCTAssertFalse(body.contains("name=\"provider\""))
            XCTAssertFalse(body.contains("name=\"archivePassword\""))
            XCTAssertTrue(body.contains("name=\"alipayFundRounding\"\r\n\r\nfalse\r\n"))
            return Self.response(for: request, body: Self.importPreviewJSON)
        }

        _ = try await makeClient().previewImport(
            baseURL: URL(string: "https://ledger.example.com")!,
            file: LedgerImportSelectedFile(name: "statement.csv", data: Data("bill".utf8)),
            provider: nil,
            alipayFundRounding: false,
            archivePassword: "should-not-be-sent"
        )
    }

    func testImportCommitSendsPreviewIdentityAndSelectedEntriesAsJSON() async throws {
        let entry = Self.importEntry
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/imports/commit")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try Self.bodyData(from: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["importId"] as? String, "preview-123")
            XCTAssertEqual(json["provider"] as? String, "wechat")
            let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?["id"] as? String, "entry-1")
            XCTAssertEqual(entries.first?["orderId"] as? String, "order-1")
            XCTAssertEqual(entries.first?["txType"] as? String, "支出")
            return Self.response(
                for: request,
                body: #"{"ok":true,"outputFile":"transactions/2026/imports/import.bean","includeFile":"transactions/2026/08.bean","documentFile":"transactions/2026/documents/imports/statement.xlsx","count":1,"readModelPending":false}"#
            )
        }

        let result = try await makeClient().commitImport(
            baseURL: URL(string: "https://ledger.example.com")!,
            request: LedgerImportCommitRequest(
                importID: "preview-123",
                provider: "wechat",
                entries: [entry]
            )
        )

        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.documentFile, "transactions/2026/documents/imports/statement.xlsx")
    }

    func testTransactionUpdateUsesSourceHashAndCompleteEditableEntry() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/transactions")
            XCTAssertEqual(request.httpMethod, "PUT")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            let source = try XCTUnwrap(json["source"] as? [String: Any])
            XCTAssertEqual(source["file"] as? String, "transactions/2026/08.bean")
            XCTAssertEqual(source["line"] as? Int, 88)
            XCTAssertEqual(source["hash"] as? String, "source-hash")
            let entry = try XCTUnwrap(json["entry"] as? [String: Any])
            XCTAssertEqual(entry["kind"] as? String, "transaction")
            XCTAssertEqual(entry["date"] as? String, "2026-08-28")
            XCTAssertEqual(entry["tags"] as? [String], ["learning", "travel"])
            XCTAssertEqual(entry["flag"] as? String, "!")
            XCTAssertEqual(entry["links"] as? [String], ["receipt-2026"])
            XCTAssertEqual((entry["metadata"] as? [String: Any])?["verified"] as? Bool, true)
            XCTAssertTrue((entry["metadata"] as? [String: Any])?["reviewedAt"] is NSNull)
            let postings = try XCTUnwrap(entry["postings"] as? [[String: Any]])
            XCTAssertEqual(postings.first?["amount"] as? String, "1.23456789")
            XCTAssertEqual(postings.first?["costKind"] as? String, "total")
            XCTAssertEqual(postings.first?["costSpec"] as? String, #"{{ 123.456789 USD, 2026-05-01, "lot-a" }}"#)
            XCTAssertEqual(postings.first?["priceKind"] as? String, "unit")
            return Self.response(for: request, body: #"{"ok":true}"#)
        }

        try await makeClient().updateTransaction(
            baseURL: URL(string: "https://ledger.example.com")!,
            source: TransactionSource(
                file: "transactions/2026/08.bean",
                line: 88,
                hash: "source-hash",
                gitSHA: "git-sha"
            ),
            entry: LedgerTransactionEntry(
                date: "2026-08-28",
                flag: "!",
                payee: "城市书房",
                narration: "年度阅读计划",
                metadata: ["verified": .bool(true), "reviewedAt": .null],
                tags: ["learning", "travel"],
                links: ["receipt-2026"],
                postings: [
                    LedgerTransactionEntryPosting(account: "Expenses:Education:Books", flag: "!", amount: "1.23456789", currency: "VT", costKind: "total", costAmount: "123.456789", costCurrency: "USD", costSpec: #"{{ 123.456789 USD, 2026-05-01, "lot-a" }}"#, priceKind: "unit", priceAmount: "160.1234567", priceCurrency: "USD"),
                    LedgerTransactionEntryPosting(account: "Liabilities:CreditCard", amount: "-328.00", currency: "CNY"),
                ]
            )
        )
    }

    func testTransactionBulkTagsUsesAtomicEndpoint() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/transactions/tags")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: try Self.bodyData(from: request)) as? [String: Any]
            )
            XCTAssertEqual(json["tags"] as? [String], ["travel", "trip-2026"])
            XCTAssertEqual((json["sources"] as? [[String: Any]])?.count, 2)
            return Self.response(for: request, body: #"{"ok":true}"#)
        }

        let sources = [1, 2].map {
            TransactionSource(file: "transactions/2026/08.bean", line: $0, hash: "hash-\($0)", gitSHA: nil)
        }
        try await makeClient().addTransactionTags(
            baseURL: URL(string: "https://ledger.example.com")!,
            sources: sources,
            tags: ["travel", "trip-2026"]
        )
    }

    func testIndexInfoBypassesCachesAndDecodesActiveRevision() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/ledger/index-info")
            XCTAssertNotNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value)
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "gitSHA" })?.value,
                "target-index-revision"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return Self.response(
                for: request,
                body: #"{"enabled":true,"active":true,"gitSHA":"new-index-revision","indexedAt":"2026-09-01T08:30:00Z","requestCompleted":true}"#
            )
        }

        let info = try await makeClient().indexInfo(
            baseURL: URL(string: "https://ledger.example.com")!,
            targetGitSHA: "target-index-revision"
        )

        XCTAssertEqual(
            info,
            LedgerIndexInfo(
                enabled: true,
                active: true,
                gitSHA: "new-index-revision",
                indexedAt: "2026-09-01T08:30:00Z",
                requestCompleted: true
            )
        )
    }

    func testAccountDetailEncodesAccountAndDecodesRows() async throws {
        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/api/ledger/accounts/detail")
            XCTAssertEqual(
                components.queryItems,
                [
                    URLQueryItem(name: "account", value: "Assets:Bank:Daily"),
                    URLQueryItem(name: "currency", value: "CNY"),
                    URLQueryItem(name: "start", value: "2026-08-01"),
                    URLQueryItem(name: "end", value: "2026-09-01"),
                ]
            )
            XCTAssertEqual(request.httpMethod, "GET")
            return Self.response(for: request, body: LedgerModelsTests.accountDetailJSON)
        }

        let detail = try await makeClient().accountDetail(
            baseURL: URL(string: "https://ledger.example.com")!,
            account: "Assets:Bank:Daily",
            currency: "CNY",
            start: "2026-08-01",
            end: "2026-09-01"
        )
        XCTAssertEqual(detail.label, "日常账户")
        XCTAssertEqual(detail.currentBalance, 1_235_000)
        XCTAssertEqual(detail.openingBalance, 1_243_500)
        XCTAssertEqual(detail.closingBalance, 1_235_000)
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
        XCTAssertEqual(statement.expenseAnalytics.first?.txCount, 3)
        XCTAssertEqual(statement.topPayees.first?.payee, "房屋租金")
        XCTAssertEqual(statement.topPaymentAccounts.first?.account, "Assets:Bank:Daily")
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
      "expenseAnalytics":[{"account":"Expenses:Housing","alias":"居住","label":"居住","amount":380000,"txCount":3,"share":0.6845,"previousAmount":350000,"changeRatio":0.0857,"topPayees":[{"payee":"房屋租金","amount":380000,"txCount":1}]}],
      "topPayees":[{"payee":"房屋租金","amount":380000,"txCount":1}],
      "topPaymentAccounts":[{"account":"Assets:Bank:Daily","alias":"日常账户","label":"日常账户","amount":555180,"txCount":9}],
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

    private static let importEntry = LedgerImportEntry(
        id: "entry-1",
        date: "2026-08-30",
        flag: "*",
        payee: "青禾市场",
        narration: "周末食材",
        source: "wechat",
        orderID: "order-1",
        merchantID: nil,
        payTime: "2026-08-30 11:42:00",
        method: "银行卡",
        transactionType: "支出",
        status: "支付成功",
        type: nil,
        categoryAccount: "Expenses:Food:Groceries",
        fundingAccount: "Liabilities:CreditCard",
        amount: 186.8,
        currency: "CNY",
        metadata: ["orderId": "order-1"],
        postings: [
            LedgerImportPosting(
                account: "Expenses:Food:Groceries",
                amount: "186.80",
                currency: "CNY",
                priceKind: nil,
                priceAmount: nil,
                priceCurrency: nil
            ),
            LedgerImportPosting(
                account: "Liabilities:CreditCard",
                amount: "-186.80",
                currency: "CNY",
                priceKind: nil,
                priceAmount: nil,
                priceCurrency: nil
            ),
        ]
    )

    private static let importPreviewJSON = #"""
    {
      "importId":"preview-123",
      "provider":"wechat",
      "providerDetection":{"provider":"wechat","reason":"文件结构匹配","confidence":"high"},
      "originalFilename":"statement.xlsx",
      "dedupReport":"生成 2 条，跳过 1 条，待写入 1 条。",
      "entries":[{
        "id":"entry-1","date":"2026-08-30","flag":"*","payee":"青禾市场","narration":"周末食材",
        "source":"wechat","orderId":"order-1","payTime":"2026-08-30 11:42:00","method":"银行卡","txType":"支出","status":"支付成功",
        "categoryAccount":"Expenses:Food:Groceries","fundingAccount":"Liabilities:CreditCard","amount":186.8,"currency":"CNY",
        "metadata":{"orderId":"order-1"},
        "postings":[
          {"account":"Expenses:Food:Groceries","amount":"186.80","currency":"CNY"},
          {"account":"Liabilities:CreditCard","amount":"-186.80","currency":"CNY"}
        ]
      }],
      "candidateCount":1,"rawRowCount":2,"filteredRowCount":2,"generatedCount":2,"excludedRowCount":0,"skippedDuplicateCount":1,
      "dateStart":"2026-08-01","dateEnd":"2026-08-30","warnings":["已跳过 1 条重复交易。"]
    }
    """#
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
