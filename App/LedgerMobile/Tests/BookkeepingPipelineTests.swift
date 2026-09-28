import Foundation
import XCTest
@testable import LedgerMobile

final class BookkeepingPipelineTests: XCTestCase {
    private func account(_ name: String, currency: String = "CNY", close: String? = nil) -> LedgerAccount {
        .init(account: name, openDate: "2020-01-01", closeDate: close, currency: currency, alias: nil,
              label: name, group: "test", active: close == nil)
    }
    private var accounts: [LedgerAccount] {
        [account("Expenses:Books"), account("Assets:Receivable"), account("Liabilities:Card")]
    }
    private var input: BookkeepingParseInput {
        .init(text: "昨天用信用卡买书 128 元，其中 48 元替同事垫付。", referenceDate: "2026-09-19",
              timeZone: "Asia/Singapore", accounts: accounts, currency: "CNY")
    }
    private func parsed() throws -> SemanticBookkeepingResponse {
        try JSONDecoder().decode(SemanticBookkeepingResponse.self, from: Data(#"{"records":[{"date":"2026-09-18","payee":"书店","narration":"买书，替同事垫付","postings":[{"account":"Expenses:Books","role":"expense","currency":"CNY","terms":[{"value":"128","sign":1},{"value":"48","sign":-1}],"evidence":"昨天用信用卡买书 128 元，其中 48 元替同事垫付。"},{"account":"Assets:Receivable","role":"receivable","currency":"CNY","terms":[{"value":"48","sign":1}],"evidence":"48 元替同事垫付"},{"account":"Liabilities:Card","role":"funding","currency":"CNY","terms":[{"value":"128","sign":-1}],"evidence":"信用卡买书 128 元"}]}],"questions":[]}"#.utf8))
    }

    func testSplitDraftComputesAmountsLocallyAndKeepsEvidence() throws {
        let draft = try parsed().draft(for: input)
        XCTAssertEqual(draft.records[0].postings.map(\.amount), ["80", "48", "-128"])
        XCTAssertEqual(draft.evidence.first?.original, input.text)
        XCTAssertEqual(draft.evidence.first?.locator, "2026-09-19 Asia/Singapore")
        XCTAssertEqual(draft.accountRoles, [["expense", "receivable", "funding"]])
        try draft.validate()
    }

    func testExactArithmeticNeverRoundsThroughDouble() throws {
        XCTAssertEqual(try ExactBookkeepingAmount.sum([("9007199254740993.000001", 1), ("0.000001", -1)]), "9007199254740993")
        XCTAssertEqual(try ExactBookkeepingAmount.sum([("128.123456789", 1), ("48.123456788", -1)]), "80.000000001")
        for text in ["NaN", "1e100", "1.2junk", "1,200", "9999999999999999999999999999999999999999"] {
            XCTAssertNil(ExactBookkeepingAmount.parse(text))
        }
        XCTAssertThrowsError(try ExactBookkeepingAmount.sum([("128", 4)]))
    }

    func testEditingInvalidatesOnlyAffectedAccountProposals() {
        let original = LedgerTransactionEntry(date: "2026-09-18", narration: "fixture", postings: [
            .init(account: "", amount: "10", currency: "CNY"), .init(account: "", amount: "-10", currency: "CNY")])
        let proposals = (0...1).map { index in AccountDecisionProposal(recordIndex: 0, postingIndex: index,
            provider: "fixture", decision: .init(value: "review", confidence: 0, candidates: [])) }
        let selected = LedgerTransactionEntry(date: original.date, narration: original.narration, postings: [
            .init(account: "Expenses:Books", amount: "10", currency: "CNY"), original.postings[1]])
        XCTAssertEqual(BookkeepingPipeline.validProposals(proposals, before: [original], after: [selected]).map(\.postingIndex), [1])
        let changedDate = LedgerTransactionEntry(date: "2020-01-01", narration: original.narration, postings: original.postings)
        XCTAssertTrue(BookkeepingPipeline.validProposals(proposals, before: [original], after: [changedDate]).isEmpty)
    }

    func testInventedQuantitiesAndAbsentEvidenceAreRejected() throws {
        var altered = input
        altered = .init(text: "买书 12 元", referenceDate: altered.referenceDate, timeZone: altered.timeZone,
                        accounts: altered.accounts, currency: altered.currency)
        XCTAssertThrowsError(try parsed().draft(for: altered))
    }

    func testMissingAccountRemainsAnExplicitQuestion() throws {
        let noAccounts = BookkeepingParseInput(text: input.text, referenceDate: input.referenceDate,
            timeZone: input.timeZone, accounts: [], currency: "CNY")
        let draft = try parsed().draft(for: noAccounts)
        XCTAssertEqual(draft.records[0].postings.map(\.account), ["", "", ""])
        XCTAssertEqual(draft.questions.count, 3)
        XCTAssertThrowsError(try draft.validate())
    }

    func testCompatibleEndpointRequiresHTTPSAndNeverAcceptsEmbeddedCredentials() throws {
        for endpoint in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret"] {
            XCTAssertThrowsError(try CompatibleBookkeepingParser.Configuration(baseURL: endpoint, model: "fixture").endpoint())
        }
        XCTAssertEqual(try CompatibleBookkeepingParser.Configuration(baseURL: "https://example.com/v1/", model: "fixture")
            .endpoint().absoluteString, "https://example.com/v1/chat/completions")
    }

    func testCompatibleTransportUsesTypedJSONAndRejectsTruncatedResponses() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SemanticFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); SemanticFixtureProtocol.handler = nil }
        let content = String(decoding: try JSONEncoder().encode(parsed()), as: UTF8.self)
        for finishReason in ["stop", "length"] {
            SemanticFixtureProtocol.handler = { request in
                XCTAssertEqual(request.url?.absoluteString, "https://fixture.invalid/v1/chat/completions")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                    body = data
                }
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
                XCTAssertEqual((json["response_format"] as? [String: String])?["type"], "json_object")
                XCTAssertFalse(String(decoding: try XCTUnwrap(body), as: UTF8.self).contains("fixture-key"))
                return try JSONSerialization.data(withJSONObject: ["choices": [[
                    "message": ["content": content], "finish_reason": finishReason]]])
            }
            let parser = CompatibleBookkeepingParser(configuration: .init(baseURL: "https://fixture.invalid/v1", model: "fixture"),
                apiKey: "fixture-key", session: session)
            do {
                let draft = try await parser.parse(input)
                XCTAssertEqual(finishReason, "stop")
                XCTAssertEqual(draft.records[0].postings[0].amount, "80")
            } catch { XCTAssertEqual(finishReason, "length", "Unexpected parse failure: \(error)") }
        }
    }

    @MainActor
    func testSemanticCredentialsStayLocalAndChangingEndpointRequiresFreshKey() throws {
        let namespace = "semantic-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let store = ClassificationKeyStore(service: namespace)
        defer { defaults.removePersistentDomain(forName: namespace); try? store.remove() }
        let settings = BookkeepingSettings(defaults: defaults, keyStore: store)
        try settings.save(baseURL: "https://fixture.invalid/v1", model: "fixture", key: "synthetic-key")
        XCTAssertEqual(try store.load(), "synthetic-key")
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("synthetic-key"))
        XCTAssertThrowsError(try settings.save(baseURL: "https://different.invalid/v1", model: "fixture", key: ""))
        XCTAssertEqual(settings.configuration.baseURL, "https://fixture.invalid/v1")
        try settings.removeKey()
        XCTAssertThrowsError(try settings.parser())
    }

    private actor OfflineClassifier: BookkeepingClassifier {
        var requests: [BookkeepingAccountQuestion] = []
        func classify(_ input: ImportClassificationRequest) async throws -> ImportClassificationSuggestion {
            throw BookkeepingError.invalidModelResponse
        }
        func decideAccount(_ input: BookkeepingAccountQuestion) async throws -> AccountDecisionProposal {
            requests.append(input)
            let value = input.candidates[0].account
            return .init(recordIndex: input.recordIndex, postingIndex: input.postingIndex,
                provider: "offline-fixture-v1", decision: .init(value: value, confidence: 1,
                    candidates: [.init(value: value, probability: 1)]))
        }
    }

    func testOfflineClassifierIsInterchangeableAndOnlyEnrichesUnresolvedAccounts() async throws {
        var draft = try parsed().draft(for: input)
        draft.records = [.init(date: "2026-09-18", narration: "买书", postings: [
            .init(account: "", amount: "80", currency: "CNY"),
            .init(account: "Assets:Receivable", amount: "48", currency: "CNY"),
            .init(account: "Liabilities:Card", amount: "-128", currency: "CNY")])]
        let provider = OfflineClassifier()
        let result = try await BookkeepingPipeline.enrich(draft, accounts: accounts + [
            account("Expenses:Closed", close: "2025-01-01"), account("Expenses:USD", currency: "USD")],
            history: [], provider: provider)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].candidates.map(\.account), ["Expenses:Books"])
        XCTAssertEqual(result.records, draft.records, "Even a confident judgment is a proposal until selected")
        XCTAssertEqual(result.proposals.first?.provider, "offline-fixture-v1")
    }

    func testCancellationDuringLastHistoryPageNeverCallsClassifier() async throws {
        var draft = try parsed().draft(for: input)
        draft.records = [.init(date: "2026-09-18", narration: "Synthetic", postings: [
            .init(account: "", amount: "80", currency: "CNY")])]
        let provider = OfflineClassifier()
        do {
            _ = try await BookkeepingPipeline.enrich(draft, accounts: accounts, relatedHistory: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }, provider: provider)
            XCTFail("Cancelled history was accepted")
        } catch is CancellationError { }
        let calls = await provider.requests
        XCTAssertTrue(calls.isEmpty)
    }

    private func repository() async throws -> LocalLedgerRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BookkeepingTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("""
        ; preserve source comment
        option "operating_currency" "CNY"
        2020-01-01 commodity CNY
        2020-01-01 open Expenses:Books CNY
        2020-01-01 open Assets:Receivable CNY
        2020-01-01 open Liabilities:Card CNY

        """.utf8).write(to: source.appendingPathComponent("main.bean"))
        let catalog = LocalLedgerCatalog(rootDirectory: root.appendingPathComponent("managed"))
        let descriptor = try await catalog.importLedger(from: source, name: "Synthetic bookkeeping")
        return catalog.repository(for: descriptor)
    }

    func testFullEnginePreviewDoesNotWriteAndConfirmationPublishesExactBytes() async throws {
        #if os(iOS)
        let repository = try await repository()
        let before = try await repository.workspace.currentRevision()
        let preview = try await repository.prepareBookkeeping(parsed().draft(for: input))
        let unchanged = try await repository.workspace.currentRevision()
        XCTAssertEqual(unchanged, before)
        XCTAssertFalse(preview.files.files.isEmpty)
        let oldTransactions = try await repository.globalTransactions()
        XCTAssertTrue(oldTransactions.transactions.isEmpty)
        _ = try await repository.commitPrepared(preview)
        for file in preview.files.files {
            if let expected = file.after {
                let saved = try await repository.workspace.readFile(at: file.path)
                XCTAssertEqual(saved, expected)
            }
        }
        let transactions = try await repository.globalTransactions()
        XCTAssertEqual(transactions.transactions.count, 1)
        XCTAssertEqual(transactions.transactions.first?.postings.count, 3)
        do { _ = try await repository.commitPrepared(preview); XCTFail("Token was reused") } catch { }
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testManualInferredPostingAndExistingNumericSyntaxReachCanonicalValidation() async throws {
        #if os(iOS)
        let repository = try await repository()
        for amount in ["+10", "10.", "12.123456789"] {
            let draft = BookkeepingDraft.manual(.init(date: "2026-09-18", payee: "Fixture", narration: "manual fixture", postings: [
                .init(account: "Expenses:Books", amount: amount, currency: "CNY"),
                .init(account: "Liabilities:Card", amount: "", currency: "")]))
            let preview = try await repository.prepareBookkeeping(draft)
            let text = preview.files.files.compactMap { $0.after.flatMap { String(data: $0, encoding: .utf8) } }.joined()
            if amount == "12.123456789" { XCTAssertTrue(text.contains(amount), text) }
            await repository.discardPrepared(preview)
        }
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testCanonicalFailureAndStaleRevisionLeaveWorkspaceUntouched() async throws {
        #if os(iOS)
        let repository = try await repository()
        let initial = try await repository.readFile(path: "main.bean")
        let invalid = BookkeepingDraft.manual(.init(date: "2026-09-18", payee: "Fixture", narration: "Unbalanced fixture", postings: [
            .init(account: "Expenses:Books", amount: "10", currency: "CNY"),
            .init(account: "Liabilities:Card", amount: "-9", currency: "CNY")]))
        do { _ = try await repository.prepareBookkeeping(invalid); XCTFail("Invalid draft passed canonical validator") } catch { }
        let afterFailure = try await repository.readFile(path: "main.bean")
        XCTAssertEqual(initial.revisionID, afterFailure.revisionID)
        let preview = try await repository.prepareBookkeeping(parsed().draft(for: input))
        try await repository.saveFile(initial, text: initial.text + "; concurrent edit\n")
        do { _ = try await repository.commitPrepared(preview); XCTFail("Stale preview published") }
        catch { XCTAssertEqual(error as? LocalLedgerWorkspace.WorkspaceError, .staleRevision) }
        let final = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(final.text.hasSuffix("; concurrent edit\n"))
        let transactions = try await repository.globalTransactions()
        XCTAssertTrue(transactions.transactions.isEmpty)
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }

    func testBeanImportPreservesBytesAndRejectsDuplicateOrWorkspaceDirectives() async throws {
        #if os(iOS)
        let repository = try await repository()
        let text = """
        ; untouched comment
        2026-09-18 * "Books" "precise" #reading
          purpose: "retain metadata"
          Expenses:Books  1.123456789 CNY
          Liabilities:Card  -1.123456789 CNY

        """
        let preview = try await repository.prepareBeanTransactions(text)
        let mainFile = try XCTUnwrap(preview.files.files.first { $0.path == "main.bean" })
        let afterText = String(decoding: mainFile.after ?? Data(), as: UTF8.self)
        XCTAssertTrue(afterText.contains("Expenses:Books"))
        _ = try await repository.commitPrepared(preview)
        do { _ = try await repository.prepareBeanTransactions(text); XCTFail("Duplicate accepted") } catch { }
        for directive in ["include \"other.bean\"", "plugin \"beancount.plugins.auto_accounts\"", "2020-01-01 open Assets:New CNY"] {
            XCTAssertThrowsError(try BeanTransactionParser.transactionCount(directive + "\n" + text))
        }
        let main = try await repository.readFile(path: "main.bean")
        XCTAssertTrue(main.text.contains("Expenses:Books"))
        XCTAssertTrue(main.text.hasPrefix("; preserve source comment"))
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}

private final class SemanticFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
