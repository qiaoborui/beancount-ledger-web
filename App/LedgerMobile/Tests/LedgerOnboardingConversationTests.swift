import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerOnboardingConversationTests: XCTestCase {
    private actor Recorder {
        private(set) var sent: [Data] = []
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func next(_ data: Data) -> Data {
            sent.append(data)
            return Data((replies.isEmpty ? #"{"ok":false,"error":"no reply"}"# : replies.removeFirst()).utf8)
        }
    }

    private static let readyState = #"""
    {"draft":{"title":"日常账本","currency":"CNY","startDate":"2026-11-01",
      "accounts":[{"kind":"credit_card","name":"招行信用卡","account":"Liabilities:CreditCard:CMB","currency":"","openingBalance":"800"},
                  {"kind":"bank_card","name":"招商银行卡","account":"Assets:Bank:CMB","currency":"","openingBalance":"12345.6"},
                  {"kind":"cash","name":"港币现金","account":"Assets:Cash:HKD","currency":"HKD","openingBalance":""}],
      "incomeCategories":[{"name":"工资","account":"Income:Salary"}],
      "expenseCategories":[{"name":"餐饮","account":"Expenses:Food"}]},
     "ready":true}
    """#

    private static func requests(_ recorder: Recorder) async -> [[String: Any]] {
        await recorder.sent.map { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) ?? [:] }
    }

    @MainActor
    private func conversation(_ recorder: Recorder) -> LedgerOnboardingConversation {
        LedgerOnboardingConversation(runner: LedgerAgentRunner(run: { await recorder.next($0) }, cancel: { _ in }),
            credentials: { .init(choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", thinking: nil) })
    }

    @MainActor
    private func waitUntilIdle(_ conversation: LedgerOnboardingConversation) async throws {
        for _ in 0..<2000 where conversation.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(conversation.isRunning)
    }

    func testDraftDecodesTheNativeStateAndMapsToTheWizardSelections() throws {
        let state = try JSONDecoder().decode(LedgerOnboardingState.self, from: Data(Self.readyState.utf8))
        XCTAssertTrue(state.canCreate)
        XCTAssertEqual(state.draft.accountGroups.map(\.kind), ["cash", "bank_card", "credit_card"])
        let accounts = state.draft.accountSelections
        XCTAssertEqual(accounts.map(\.currency), ["CNY", "CNY", "HKD"])
        XCTAssertEqual(accounts.map(\.initialBalance), ["800", "12345.6", nil])
        XCTAssertEqual(accounts.map(\.isLiability), [true, false, false])
        XCTAssertEqual(state.draft.categorySelections.map(\.account), ["Income:Salary", "Expenses:Food"])

        let sparse = try JSONDecoder().decode(LedgerOnboardingState.self,
            from: Data(#"{"draft":{"title":"t","currency":"CNY","startDate":"","accounts":null,"incomeCategories":null,"expenseCategories":null},"ready":false}"#.utf8))
        XCTAssertEqual(sparse.draft.accounts, [])
        XCTAssertFalse(sparse.canCreate)
        var debtOnly = state
        debtOnly.draft.accounts.removeAll { !$0.isLiability }
        XCTAssertFalse(debtOnly.canCreate)
    }

    @MainActor
    func testTurnsCarryTheDraftWithoutALedgerAndKeepTheTranscript() async throws {
        let recorder = Recorder([
            #"{"ok":true,"reply":"你平时用哪些账户？","toolCalls":[],"transcript":"[1]","ask":{"question":"你平时用哪些账户？","options":["银行卡","支付宝"],"multiple":true},"onboarding":{"draft":{"title":"我的账本","currency":"CNY","startDate":"","accounts":[],"incomeCategories":[],"expenseCategories":[]},"ready":false}}"#,
            #"{"ok":true,"reply":"方案好了。","toolCalls":[],"transcript":"[2]","onboarding":"# + Self.readyState + "}",
        ])
        let conversation = conversation(recorder)
        conversation.start()
        try await waitUntilIdle(conversation)
        // The opening question is sent for the user and not shown.
        XCTAssertEqual(conversation.messages.map(\.role), [.assistant])
        XCTAssertEqual(conversation.pendingAsk?.options, ["银行卡", "支付宝"])

        conversation.send(conversation.pendingAsk!.answer(["支付宝", "银行卡"]))
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.messages.map(\.text), ["你平时用哪些账户？", "银行卡、支付宝", "方案好了。"])
        XCTAssertNil(conversation.pendingAsk)
        XCTAssertTrue(conversation.state.canCreate)
        XCTAssertEqual(conversation.state.draft.title, "日常账本")

        let requests = await Self.requests(recorder)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["message"] as? String, LedgerOnboardingConversation.opening)
        XCTAssertNil(requests[0]["transcript"])
        XCTAssertEqual(requests[1]["transcript"] as? String, "[1]")
        XCTAssertEqual(requests[0]["conversationId"] as? String, requests[1]["conversationId"] as? String)
        for request in requests {
            XCTAssertEqual(request["workspaceRoot"] as? String, "")
            XCTAssertNil(request["scratchRoot"])
            XCTAssertNil(request["memoryPath"])
            XCTAssertNotNil(request["onboarding"] as? [String: Any])
            XCTAssertEqual(request["today"] as? String, LedgerOnboardingConversation.localDay())
        }
    }

    @MainActor
    func testAFailedTurnKeepsTheDraftAndRetriesTheSameQuestion() async throws {
        let recorder = Recorder([
            #"{"ok":true,"reply":"好","toolCalls":[],"transcript":"[1]","onboarding":"# + Self.readyState + "}",
            #"{"ok":false,"toolCalls":[],"error":"HTTP 401 unauthorized"}"#,
            #"{"ok":true,"reply":"记下了","toolCalls":[],"transcript":"[2]","onboarding":{"draft":{"title":"日常账本","currency":"CNY","startDate":"","accounts":[],"incomeCategories":[],"expenseCategories":[]},"ready":false}}"#,
        ])
        let conversation = conversation(recorder)
        conversation.start()
        try await waitUntilIdle(conversation)
        conversation.send("再加一张卡")
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.error, .invalidKey("HTTP 401 unauthorized"))
        XCTAssertTrue(conversation.state.canCreate, "a failed turn must not lose the draft")

        conversation.retry()
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.error)
        XCTAssertFalse(conversation.state.ready)
        XCTAssertEqual(conversation.messages.filter { $0.role == .user }.map(\.text), ["再加一张卡"])
        let requests = await Self.requests(recorder)
        XCTAssertEqual(requests.map { $0["message"] as? String }, [LedgerOnboardingConversation.opening, "再加一张卡", "再加一张卡"])
        XCTAssertEqual(requests[2]["transcript"] as? String, "[1]")
    }

    @MainActor
    func testANewMessageAfterAFailureCarriesTheUnansweredQuestion() async throws {
        let recorder = Recorder([
            #"{"ok":true,"reply":"好","toolCalls":[],"transcript":"[1]","onboarding":"# + Self.readyState + "}",
            #"{"ok":false,"toolCalls":[],"error":"network timeout"}"#,
            #"{"ok":true,"reply":"都记下了","toolCalls":[],"transcript":"[2]","onboarding":"# + Self.readyState + "}",
        ])
        let conversation = conversation(recorder)
        conversation.start()
        try await waitUntilIdle(conversation)
        conversation.send("再加一张卡")
        try await waitUntilIdle(conversation)
        XCTAssertNotNil(conversation.error)
        conversation.send("余额 500")
        try await waitUntilIdle(conversation)
        XCTAssertNil(conversation.error)
        XCTAssertEqual(conversation.messages.filter { $0.role == .user }.map(\.text), ["再加一张卡", "余额 500"])
        let requests = await Self.requests(recorder)
        XCTAssertEqual(requests.last?["message"] as? String, "再加一张卡\n余额 500")
    }

    func testLocalDayUsesTheDeviceCalendarDay() {
        let day = LedgerOnboardingConversation.localDay(Date(timeIntervalSince1970: 0))
        XCTAssertNotNil(day.range(of: "^19(69-12-31|70-01-01)$", options: .regularExpression))
    }

    @MainActor
    func testWithoutAModelTheConversationAsksForSetup() async throws {
        let conversation = LedgerOnboardingConversation(runner: LedgerAgentRunner(run: { _ in Data() }, cancel: { _ in }),
                                                        credentials: { throw LedgerAgentError.notConfigured })
        conversation.start()
        try await waitUntilIdle(conversation)
        XCTAssertEqual(conversation.error, .notConfigured)
    }

    func testOpeningBalancesUseTheStartDateAndExactDecimals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingAI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class NoEngine: LocalLedgerEngine {
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
        }
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: NoEngine(), validator: { _, _ in })
        let descriptor = try await catalog.createCustom(name: "AI 开账", currency: "CNY", accounts: [
            OnboardingAccountSelection(name: "储蓄卡", account: "Assets:Bank:CMB", initialBalance: "1234567890123.45"),
            OnboardingAccountSelection(name: "支付宝", account: "Assets:Wallet:Alipay", initialBalance: "0.5"),
        ], categories: [], openingDate: "2026-11-01")
        let content = try await catalog.repository(for: descriptor).readFile(path: "main.bean").text
        XCTAssertTrue(content.contains("Assets:Bank:CMB  1234567890123.45 CNY"))
        XCTAssertTrue(content.contains("Assets:Wallet:Alipay  0.50 CNY"))
        XCTAssertTrue(content.contains("2026-11-01 * \"期初余额\""))
        XCTAssertEqual(LocalLedgerCatalog.openingAmount(Decimal(string: "88")!), "88.00")
        XCTAssertEqual(LocalLedgerCatalog.openingAmount(Decimal(string: "12345.6")!), "12345.60")

        do {
            _ = try await catalog.createCustom(name: "坏日期", openingDate: "11/01")
            XCTFail("an invalid opening date was accepted")
        } catch {}
        do {
            _ = try await catalog.createCustom(name: "太早", openingDate: "1969-12-31")
            XCTFail("an opening date before 1970 was accepted")
        } catch {}
        do {
            _ = try await catalog.createCustom(name: "坏币种", currency: "RMB.")
            XCTFail("a currency ending in punctuation was accepted")
        } catch {}
    }

    /// A live onboarding produced an HKD ledger with a CNY card; spending
    /// from that card must not hit the categories' currency constraint.
    func testCategoriesTakeEveryCurrencyTheLedgerHolds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingAI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        final class NoEngine: LocalLedgerEngine {
            func dispatch(_ request: LocalLedgerEngineRequest) async throws -> Data { Data("{}".utf8) }
        }
        let catalog = LocalLedgerCatalog(rootDirectory: root, engine: NoEngine(), validator: { _, _ in })
        let mixed = try await catalog.createCustom(name: "港币账本", currency: "HKD", accounts: [
            OnboardingAccountSelection(name: "汇丰", account: "Assets:Bank:HSBC", currency: "HKD"),
            OnboardingAccountSelection(name: "招行人民币卡", account: "Assets:Bank:CMB", currency: "CNY"),
        ], categories: [
            OnboardingCategorySelection(name: "工资", account: "Income:Salary", currency: "HKD"),
            OnboardingCategorySelection(name: "餐饮", account: "Expenses:Food", currency: "HKD"),
        ])
        let mixedText = try await catalog.repository(for: mixed).readFile(path: "main.bean").text
        XCTAssertTrue(mixedText.contains("open Expenses:Food HKD,CNY\n"))
        XCTAssertTrue(mixedText.contains("open Income:Salary HKD,CNY\n"))
        XCTAssertTrue(mixedText.contains("open Assets:Bank:CMB CNY\n"))

        let single = try await catalog.createCustom(name: "人民币账本", categories: [
            OnboardingCategorySelection(name: "餐饮", account: "Expenses:Food", currency: "CNY"),
        ])
        let singleText = try await catalog.repository(for: single).readFile(path: "main.bean").text
        XCTAssertTrue(singleText.contains("open Expenses:Food CNY\n"))
    }
}
