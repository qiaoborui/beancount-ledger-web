import Foundation
import XCTest
@testable import LedgerMobile

final class LedgerSetupCardsTests: XCTestCase {
    private actor Recorder {
        private(set) var sent: [Data] = []
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func next(_ data: Data) -> Data {
            sent.append(data)
            return Data((replies.isEmpty ? #"{"ok":false,"error":"no reply"}"# : replies.removeFirst()).utf8)
        }
    }

    private static let draftJSON = #"""
    {"title":"日常账本","currency":"CNY","startDate":"",
     "accounts":[{"kind":"bank_card","name":"招行卡","account":"Assets:Bank:CMB","currency":"","openingBalance":""},
                 {"kind":"credit_card","name":"花呗","account":"Liabilities:Alipay:Huabei","currency":"","openingBalance":""}],
     "incomeCategories":[{"name":"工资","account":"Income:Salary"}],
     "expenseCategories":[{"name":"餐饮","account":"Expenses:Food"},{"name":"交通","account":"Expenses:Transport"}]}
    """#

    private static func draft() throws -> LedgerOnboardingDraft {
        try JSONDecoder().decode(LedgerOnboardingDraft.self, from: Data(draftJSON.utf8))
    }

    func testTheDraftDecodesStorageAndChannelsWithDefaults() throws {
        let plain = try Self.draft()
        XCTAssertEqual(plain.storage, "")
        XCTAssertEqual(plain.remote, "")
        XCTAssertEqual(plain.importChannels, [])
        XCTAssertFalse(plain.isGitStorage)

        var git = plain
        git.storage = "git"
        git.remote = "https://github.com/me/ledger"
        git.importChannels = ["alipay", "manual"]
        let round = try JSONDecoder().decode(LedgerOnboardingDraft.self, from: JSONEncoder().encode(git))
        XCTAssertEqual(round, git)
        XCTAssertTrue(round.isGitStorage)
        XCTAssertEqual(LedgerOnboardingDraft.channelTitle("alipay"), "支付宝")
        XCTAssertEqual(LedgerOnboardingDraft.channelTitle("manual"), "手动记账")
    }

    func testACardDecodesAndAnUnknownOneIsDropped() throws {
        let response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(#"""
        {"ok":true,"reply":"挑一下分类。","toolCalls":[],
         "onboardingCard":{"kind":"categories","prompt":"挑一下分类。",
           "suggested":[{"kind":"expense","name":"房租","account":"Expenses:Housing:Rent"}]}}
        """#.utf8))
        XCTAssertEqual(response.onboardingCard?.kind, .categories)
        XCTAssertEqual(response.onboardingCard?.suggested.map(\.name), ["房租"])

        let unknown = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: Data(#"""
        {"ok":true,"reply":"填一下。","toolCalls":[],"onboardingCard":{"kind":"budget","prompt":"填一下。"}}
        """#.utf8))
        XCTAssertNil(unknown.onboardingCard)
        XCTAssertEqual(unknown.reply, "填一下。")
    }

    func testAmountsAreReadAsPlainDecimals() {
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount(" 12,000.5 "), "12000.5")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount(""), "")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("0"), "")
        XCTAssertNil(LedgerOnboardingCardAnswer.normalizedAmount("-5"))
        XCTAssertNil(LedgerOnboardingCardAnswer.normalizedAmount("1.234"))
        XCTAssertNil(LedgerOnboardingCardAnswer.normalizedAmount("一千"))
    }

    func testBalancesFillTheAccountsAndTheStartDate() throws {
        let (draft, summary) = LedgerOnboardingCardAnswer
            .balances(["Assets:Bank:CMB": "12000", "Liabilities:Alipay:Huabei": "800.5"], startDate: "2026-11-01")
            .applied(to: try Self.draft())
        XCTAssertEqual(draft.accounts.map(\.openingBalance), ["12000", "800.5"])
        XCTAssertEqual(draft.startDate, "2026-11-01")
        XCTAssertEqual(summary, "余额：招行卡 12000，花呗 欠 800.5；期初 2026-11-01。")

        let (skipped, none) = LedgerOnboardingCardAnswer.balances([:], startDate: "").applied(to: try Self.draft())
        XCTAssertEqual(skipped.accounts.map(\.openingBalance), ["", ""])
        XCTAssertEqual(none, "余额：先不填余额；期初就是今天。")
    }

    func testCategoriesKeepRemoveAndAdd() throws {
        let rent = LedgerOnboardingCard.Suggestion(kind: "expense", name: "房租", account: "Expenses:Housing:Rent")
        let bonus = LedgerOnboardingCard.Suggestion(kind: "income", name: "奖金", account: "Income:Bonus")
        let (draft, summary) = LedgerOnboardingCardAnswer
            .categories(kept: ["Income:Salary", "Expenses:Food"], added: [rent, bonus])
            .applied(to: try Self.draft())
        XCTAssertEqual(draft.incomeCategories.map(\.name), ["工资", "奖金"])
        XCTAssertEqual(draft.expenseCategories.map(\.name), ["餐饮", "房租"])
        XCTAssertEqual(summary, "分类定了，收入 2 个、支出 2 个，加上房租、奖金，去掉交通。")
    }

    func testStorageAndImportsGoIntoTheDraft() throws {
        let (git, gitSummary) = LedgerOnboardingCardAnswer.storage("git", remote: "https://github.com/me/ledger")
            .applied(to: try Self.draft())
        XCTAssertTrue(git.isGitStorage)
        XCTAssertTrue(gitSummary.contains("https://github.com/me/ledger"))
        let (device, _) = LedgerOnboardingCardAnswer.storage("device", remote: "https://x.example/a/b").applied(to: git)
        XCTAssertEqual(device.storage, "device")
        XCTAssertEqual(device.remote, "")

        let (imports, importSummary) = LedgerOnboardingCardAnswer.imports(["manual", "wechat", "alipay"])
            .applied(to: try Self.draft())
        XCTAssertEqual(imports.importChannels, ["alipay", "wechat", "manual"])
        XCTAssertEqual(importSummary, "平时会导入：支付宝、微信支付，其余手动记。")
        XCTAssertEqual(LedgerOnboardingCardAnswer.imports([]).applied(to: try Self.draft()).summary,
                       "平时都手动记账，不导入账单。")
    }

    @MainActor
    func testSubmittingACardEditsTheDraftAndSendsItsSummary() async throws {
        let state = #"{"draft":"# + Self.draftJSON + #","ready":true}"#
        let recorder = Recorder([
            #"{"ok":true,"reply":"现在各有多少？","toolCalls":[],"onboardingCard":{"kind":"balances","prompt":"现在各有多少？"},"onboarding":"# + state + "}",
            #"{"ok":true,"reply":"记下了。","toolCalls":[]}"#,
        ])
        let conversation = LedgerOnboardingConversation(
            runner: LedgerAgentRunner(run: { await recorder.next($0) }, cancel: { _ in }),
            credentials: { .init(choice: .init(provider: "anthropic", model: "claude-sonnet-4-5"), apiKey: "k", thinking: nil) })
        conversation.start()
        for _ in 0..<2000 where conversation.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(conversation.pendingCard?.kind, .balances)
        XCTAssertNil(conversation.pendingAsk)
        XCTAssertTrue(conversation.state.ready)

        conversation.submit(.balances(["Assets:Bank:CMB": "100"], startDate: ""))
        // The edit clears ready at once: what was presented is no longer the plan.
        XCTAssertFalse(conversation.state.ready)
        XCTAssertEqual(conversation.state.draft.accounts.first?.openingBalance, "100")
        for _ in 0..<2000 where conversation.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(conversation.pendingCard)
        XCTAssertEqual(conversation.messages.map(\.text), ["现在各有多少？", "余额：招行卡 100；期初就是今天。", "记下了。"])

        let sent = await recorder.sent
        XCTAssertEqual(sent.count, 2)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(request["message"] as? String, "余额：招行卡 100；期初就是今天。")
        let onboarding = try XCTUnwrap(request["onboarding"] as? [String: Any])
        XCTAssertEqual(onboarding["ready"] as? Bool, false)
        let accounts = try XCTUnwrap((onboarding["draft"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.first?["openingBalance"] as? String, "100")
    }

    func testTheSplitLayoutKeepsAccountsAndOpeningBalancesApart() throws {
        var draft = try Self.draft()
        draft.accounts[0].openingBalance = "12000"
        draft.importChannels = ["wechat", "cmb"]
        let files = draft.files(today: "2026-11-18")
        XCTAssertEqual(files.map(\.path), ["main.bean", "accounts.bean", "opening.bean", "imports/wechat-config.yaml"])
        let main = files[0].content
        XCTAssertTrue(main.contains("option \"title\" \"日常账本\""))
        XCTAssertTrue(main.contains("include \"accounts.bean\""))
        XCTAssertTrue(main.contains("include \"opening.bean\""))
        XCTAssertFalse(main.contains(" open "))
        XCTAssertTrue(files[1].content.contains("1970-01-01 open Assets:Bank:CMB CNY"))
        XCTAssertTrue(files[1].content.contains("1970-01-01 open Expenses:Food CNY"))
        XCTAssertFalse(files[1].content.contains("期初余额\" \"初始化"))
        XCTAssertTrue(files[2].content.contains("2026-11-18 * \"期初余额\""))
        XCTAssertTrue(files[2].content.contains("Assets:Bank:CMB  12000.00 CNY"))

        // No balances: no opening file and no include for it.
        draft.accounts[0].openingBalance = ""
        draft.importChannels = ["manual"]
        let bare = draft.files(today: "2026-11-18")
        XCTAssertEqual(bare.map(\.path), ["main.bean", "accounts.bean"])
        XCTAssertFalse(bare[0].content.contains("opening.bean"))

        // Nothing chosen yet: both common import configurations, as before.
        draft.importChannels = []
        XCTAssertEqual(draft.files(today: "2026-11-18").map(\.path),
                       ["main.bean", "accounts.bean", "imports/alipay-config.yaml", "imports/wechat-config.yaml"])
    }

    func testTheSingleLayoutIsUnchanged() {
        let files = LocalLedgerCatalog.customLedgerFiles(
            title: "t", currency: "CNY",
            accounts: [OnboardingAccountSelection(name: "卡", account: "Assets:Bank:A", initialBalance: "5")],
            categories: [], openingDate: "2026-01-02", layout: .single)
        XCTAssertEqual(files.map(\.path), ["main.bean", "imports/alipay-config.yaml", "imports/wechat-config.yaml"])
        XCTAssertTrue(files[0].content.contains("1970-01-01 open Assets:Bank:A CNY"))
        XCTAssertTrue(files[0].content.contains("2026-01-02 * \"期初余额\""))
        XCTAssertFalse(files[0].content.contains("include"))
    }

    func testASplitLedgerPassesTheRealValidator() async throws {
        #if os(iOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SetupSplit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = LocalLedgerCatalog(rootDirectory: root)
        var draft = try Self.draft()
        draft.accounts[0].openingBalance = "12000"
        draft.accounts[1].openingBalance = "800"
        let descriptor = try await catalog.createCustom(
            name: draft.title, currency: draft.currency, accounts: draft.accountSelections,
            categories: draft.categorySelections, openingDate: "2026-11-01", layout: .split, importChannels: ["alipay"])
        let repository = catalog.repository(for: descriptor)
        let transactions = try await repository.globalTransactions()
        XCTAssertEqual(transactions.transactions.count, 2)
        let opening = try await repository.readFile(path: "opening.bean").text
        XCTAssertTrue(opening.contains("Liabilities:Alipay:Huabei  -800.00 CNY"))
        #else
        throw XCTSkip("Requires the app-linked iOS Go and canonical Beancount runtimes")
        #endif
    }
}
