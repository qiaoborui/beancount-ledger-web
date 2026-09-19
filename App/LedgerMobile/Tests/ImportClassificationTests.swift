import Foundation
import XCTest
@testable import LedgerMobile

final class ImportClassificationTests: XCTestCase {
    override func tearDown() {
        ClassificationURLProtocol.handler = nil
        super.tearDown()
    }

    func testRetrievalUsesPersonalHistoryAndOmitsFutureAndUnrelatedTransactions() throws {
        let entry = try entry()
        let history = (0..<8).map { transaction(payee: "瑞幸咖啡", date: "2026-09-0\($0 + 1)", line: $0) }
            + [transaction(payee: "瑞幸咖啡", date: "2027-01-01", line: 10), transaction(payee: "房屋租金", line: 11)]
        let related = ImportClassificationContext.relatedHistory(for: entry, history: history)
        XCTAssertEqual(related.count, 5)
        XCTAssertEqual(related.map(\.date), ["2026-09-08", "2026-09-07", "2026-09-06", "2026-09-05", "2026-09-04"])
        let request = try XCTUnwrap(ImportClassificationContext.request(for: entry, accounts: accounts(), history: history))
        XCTAssertEqual(request.accounts.map(\.account), ["Expenses:Coffee", "Income:Salary"])
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        for secret in ["private-order", "private-merchant-id", "private-source", "private-tag", "private-history-path", "private-metadata"] {
            XCTAssertFalse(encoded.contains(secret), secret)
        }
        XCTAssertTrue(encoded.contains("瑞幸咖啡"))
    }

    func testAccountReplacementPreservesExactDecimalsAndRefundDirection() throws {
        let original = try entry(amount: "-18.123456789")
        let changed = try XCTUnwrap(ImportClassificationContext.applying("Expenses:Coffee", to: original, allowed: ["Expenses:Coffee"]))
        XCTAssertEqual(changed.postings.map(\.amount), original.postings.map(\.amount))
        XCTAssertEqual(changed.fundingAccount, original.fundingAccount)
        XCTAssertEqual(changed.tags, original.tags)
        XCTAssertEqual(changed.metadata, original.metadata)
        XCTAssertEqual(changed.orderID, original.orderID)
        XCTAssertEqual(changed.narration, original.narration)
        XCTAssertEqual(changed.postings.map(\.account), ["Expenses:Coffee", "Assets:Bank"])
        XCTAssertNil(ImportClassificationContext.applying("Expenses:Invented", to: original, allowed: ["Expenses:Coffee"]))
        XCTAssertNil(ImportClassificationContext.applying("Assets:Bank", to: original, allowed: ["Assets:Bank"]))
    }

    func testComplexAndPricedTransactionsStayForManualReview() throws {
        let original = try entry()
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var postings = try XCTUnwrap(data["postings"] as? [[String: Any]])
        postings.append(postings[0])
        data["postings"] = postings
        let split = try JSONDecoder().decode(LedgerImportEntry.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertFalse(ImportClassificationContext.supports(split))
        postings = Array(postings.prefix(2))
        postings[0]["priceKind"] = "unit"
        data["postings"] = postings
        let priced = try JSONDecoder().decode(LedgerImportEntry.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertFalse(ImportClassificationContext.supports(priced))
    }

    func testLargeAccountChartRequiresManualReviewInsteadOfDroppingCandidates() throws {
        let many = (0..<255).map { account("Expenses:Category\($0)") }
        XCTAssertNil(ImportClassificationContext.request(for: try entry(), accounts: many, history: []))
    }

    func testUncertainAndSpecialTransactionsRemainSuggestions() {
        for nature in ["transfer", "refund", "repayment", "review"] {
            XCTAssertFalse(suggestion(nature: nature).canPrefill)
        }
        XCTAssertFalse(suggestion(confidence: 0.5).canPrefill)
        XCTAssertFalse(suggestion(probability: 0.7).canPrefill)
        XCTAssertTrue(suggestion().canPrefill)
    }

    func testIncomingFundsCannotAutomaticallyBecomeAnExpense() throws {
        let outgoing = try entry()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(outgoing)) as? [String: Any])
        var postings = try XCTUnwrap(json["postings"] as? [[String: Any]])
        postings[0]["amount"] = "-18.00"
        postings[1]["amount"] = "18.00"
        json["postings"] = postings
        let incoming = try JSONDecoder().decode(LedgerImportEntry.self, from: JSONSerialization.data(withJSONObject: json))
        let outgoingState = try XCTUnwrap(ImportClassificationContext.request(for: outgoing, accounts: accounts(), history: []))
        let incomingState = try XCTUnwrap(ImportClassificationContext.request(for: incoming, accounts: accounts(), history: []))
        XCTAssertEqual(outgoingState.fundingAmount, "-18.00")
        XCTAssertEqual(incomingState.fundingAmount, "18.00")
        XCTAssertTrue(suggestion().canPrefill(for: outgoing))
        XCTAssertFalse(suggestion().canPrefill(for: incoming))
    }

    func testDirectAPIUsesTypedChoicesAndValidatesResponse() async throws {
        let input = try XCTUnwrap(ImportClassificationContext.request(for: entry(), accounts: accounts(), history: []))
        ClassificationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try Self.body(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "jev-1.13.0")
            let questions = try XCTUnwrap(json["questions"] as? [String: [String: Any]])
            XCTAssertEqual(Set(questions.keys), ["category", "nature"])
            XCTAssertEqual(questions["category"]?["type"] as? String, "choice")
            XCTAssertNotNil((questions["category"]?["criteria"] as? [String: String])?["review"])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-key"))
            return (200, Self.response())
        }
        let result = try await client().classify(input, apiKey: "fixture-key")
        XCTAssertEqual(result.category, "Expenses:Coffee")
        XCTAssertTrue(result.canPrefill)
    }

    func testMalformedAndOutOfSetModelAnswersAreRejected() async throws {
        let input = try XCTUnwrap(ImportClassificationContext.request(for: entry(), accounts: accounts(), history: []))
        let invalid = [
            Self.response().replacingOccurrences(of: "\"choice\":\"a0\"", with: "\"choice\":\"invented\""),
            Self.response().replacingOccurrences(of: "\"a0\":0.98", with: "\"a0\":-0.98"),
            Self.response().replacingOccurrences(of: "\"a0\":0.98", with: "\"a0\":0.1"),
            Self.response().replacingOccurrences(of: "\"confidence\":0.99", with: "\"confidence\":2"),
            Self.response().replacingOccurrences(of: "\"choice\":\"a0\"", with: "\"choice\":\"a1\""),
            "{}"
        ]
        for raw in invalid {
            ClassificationURLProtocol.handler = { _ in (200, raw) }
            do { _ = try await client().classify(input, apiKey: "fixture-key"); XCTFail("Accepted invalid response") }
            catch { }
        }
    }

    func testServiceFailuresDoNotBecomeClassificationResults() async throws {
        let input = try XCTUnwrap(ImportClassificationContext.request(for: entry(), accounts: accounts(), history: []))
        for status in [401, 429, 500, 302] {
            ClassificationURLProtocol.handler = { _ in (status, "private provider error") }
            do { _ = try await client().classify(input, apiKey: "fixture-key"); XCTFail("Accepted HTTP \(status)") }
            catch { XCTAssertFalse(error.localizedDescription.contains("private provider error")) }
        }
    }

    @MainActor
    func testConsentIsPerLedgerAndKeyIsStoredSeparatelyFromPreferences() throws {
        let namespace = "classification-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let store = ClassificationKeyStore(service: namespace)
        defer { defaults.removePersistentDomain(forName: namespace); try? store.remove() }
        let settings = ImportClassificationSettings(defaults: defaults, credentials: store)
        let first = UUID(), second = UUID()
        XCTAssertFalse(settings.isEnabled(for: first))
        try settings.saveKey("fixture-key")
        XCTAssertFalse(settings.isEnabled(for: first))
        settings.setEnabled(true, for: first)
        XCTAssertTrue(settings.isEnabled(for: first))
        XCTAssertFalse(settings.isEnabled(for: second))
        XCTAssertEqual(try store.load(), "fixture-key")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: namespace)).contains("fixture-key"))
        try settings.removeKey()
        XCTAssertNil(try store.load())
        XCTAssertFalse(settings.isEnabled(for: first))
    }

    @MainActor
    func testDelayedAnswersAreDiscardedAfterPauseEditDeselectionOrCancellation() async throws {
        let original = try entry()
        let input = try XCTUnwrap(ImportClassificationContext.request(for: original, accounts: accounts(), history: []))
        for change in ["pause", "edit", "deselect", "cancel"] {
            let delayed = DeferredClassification()
            var mayContinue = true, eligible = true, applied = false
            var current = original
            let work = Task {
                try await ImportClassificationBatch.run([original], makeInput: { _ in input }, classify: { _ in
                    await delayed.response()
                }, canContinue: { mayContinue }, currentEntry: { _ in current }, isEligible: { _ in eligible },
                accept: { _, _ in applied = true })
            }
            await delayed.waitUntilStarted()
            switch change {
            case "pause": mayContinue = false
            case "edit": current = original.applyingTags(["changed-during-request"])
            case "deselect": eligible = false
            default: work.cancel()
            }
            delayed.finish(suggestion())
            do { try await work.value }
            catch is CancellationError { XCTAssertEqual(change, "cancel") }
            XCTAssertFalse(applied, change)
        }
    }

    @MainActor
    func testBatchStopsBeforeNextPaidRequestAndKeepsAcceptedResults() async throws {
        let original = try entry()
        let input = try XCTUnwrap(ImportClassificationContext.request(for: original, accounts: accounts(), history: []))
        let result = suggestion()
        var allowed = true, calls = 0, accepted = 0
        try await ImportClassificationBatch.run([original, original], makeInput: { _ in input }, classify: { _ in
            calls += 1
            return result
        }, canContinue: { allowed }, currentEntry: { _ in original }, isEligible: { _ in true }, accept: { _, _ in
            accepted += 1
            allowed = false
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(accepted, 1)
    }

    private func client() -> ImportClassificationClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClassificationURLProtocol.self]
        return ImportClassificationClient(session: URLSession(configuration: config))
    }
    private func suggestion(nature: String = "expense", confidence: Double = 0.99, probability: Double = 0.98) -> ImportClassificationSuggestion {
        .init(model: "jev-1.13.0", category: "Expenses:Coffee", nature: nature, confidence: confidence,
              candidates: [.init(account: "Expenses:Coffee", probability: probability)])
    }
    private func accounts() -> [LedgerAccount] {
        [account("Expenses:Coffee"), account("Assets:Bank"), account("Income:Salary"),
         account("Expenses:Closed", active: false), account("Expenses:Foreign", currency: "USD")]
    }
    private func account(_ name: String, active: Bool = true, currency: String = "CNY") -> LedgerAccount {
        .init(account: name, openDate: "2020-01-01", closeDate: nil, currency: currency, alias: nil,
              label: name, group: "test", active: active)
    }
    private func transaction(payee: String, date: String = "2026-09-01", line: Int = 1) -> LedgerTransaction {
        .init(date: date, payee: payee, narration: "拿铁", metadata: ["secret": .string("private-metadata")],
              postings: [.init(account: "Expenses:Coffee", amount: 1800, currency: "CNY"),
                         .init(account: "Assets:Bank", amount: -1800, currency: "CNY")],
              source: .init(file: "private-history-path", line: line))
    }
    private func entry(amount: String = "18.00") throws -> LedgerImportEntry {
        let json = """
        {"id":"entry-1","date":"2026-09-19","flag":"*","payee":"瑞幸咖啡","narration":"拿铁",
        "source":"private-source","orderId":"private-order","merchantId":"private-merchant-id","method":"微信支付",
        "categoryAccount":"Expenses:Unknown","fundingAccount":"Assets:Bank","amount":18,"currency":"CNY",
        "tags":["private-tag"],"metadata":{"note":"private-metadata"},
        "postings":[{"account":"Expenses:Unknown","amount":"\(amount)","currency":"CNY"},
        {"account":"Assets:Bank","amount":"-18.00","currency":"CNY"}]}
        """
        return try JSONDecoder().decode(LedgerImportEntry.self, from: Data(json.utf8))
    }
    private static func response() -> String {
        #"{"model":"jev-1.13.0","answers":{"category":{"type":"choice","choice":"a0","confidence":0.99,"probabilities":{"a0":0.98,"a1":0.01,"review":0.01}},"nature":{"type":"choice","choice":"expense","confidence":0.99,"probabilities":{"expense":0.98,"income":0,"transfer":0,"repayment":0,"refund":0,"review":0.02}}}}"#
    }
    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

@MainActor
private final class DeferredClassification {
    private var continuation: CheckedContinuation<ImportClassificationSuggestion, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func response() async -> ImportClassificationSuggestion {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ result: ImportClassificationSuggestion) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class ClassificationURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
