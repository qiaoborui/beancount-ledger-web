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
        // Whatever the keyboard's region: a decimal comma, dotted thousands,
        // full-width marks, a currency sign, and a mark typed last.
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("12,5"), "12.5")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("12,50"), "12.50")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("12.000,50"), "12000.50")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("1，234。56"), "1234.56")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("¥88.8"), "88.8")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("12."), "12")
        XCTAssertEqual(LedgerOnboardingCardAnswer.normalizedAmount("0.05"), "0.05")
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
        XCTAssertEqual(summary, "余额：招行卡 12000 CNY，花呗 欠 800.5 CNY；期初 2026-11-01。")

        let (skipped, none) = LedgerOnboardingCardAnswer.balances([:], startDate: "").applied(to: try Self.draft())
        XCTAssertEqual(skipped.accounts.map(\.openingBalance), ["", ""])
        XCTAssertEqual(none, "余额：先不填余额；期初就是今天。")
    }

    func testAccountsSetTheCurrencyAndKeepBalances() throws {
        var start = try Self.draft()
        start.accounts[0].openingBalance = "50"
        let dbs = LedgerOnboardingDraft.account(for: AccountPresets.presets.first { $0.id == "bank_dbs" }!, ledgerCurrency: "CNY")!
        XCTAssertEqual(dbs.currency, "SGD")
        XCTAssertEqual(dbs.kind, "bank_card")
        let cash = LedgerOnboardingDraft.account(for: AccountPresets.presets.first { $0.id == "cash_cny" }!, ledgerCurrency: "SGD")!
        XCTAssertEqual(cash.account, "Assets:Cash:SGD")
        let (draft, summary) = LedgerOnboardingCardAnswer.accounts(currency: "CNY", [start.accounts[0], dbs])
            .applied(to: start)
        XCTAssertEqual(draft.currency, "CNY")
        XCTAssertEqual(draft.accounts.map(\.account), ["Assets:Bank:CMB", "Assets:Bank:DBS"])
        XCTAssertEqual(draft.accounts.first?.openingBalance, "50")
        XCTAssertTrue(summary.contains("星展银行(DBS/POSB)（SGD）"))

        // Switching the ledger to SGD makes the DBS account a plain one.
        let (sgd, _) = LedgerOnboardingCardAnswer.accounts(currency: "SGD", [dbs]).applied(to: start)
        XCTAssertEqual(sgd.accounts.first?.currency, "")

        let custom = LedgerOnboardingDraft.customAccount(name: "工资卡", kind: "bank_card", currency: "", taken: ["Assets:Bank:GongZiKa"])
        XCTAssertNotNil(custom)
        XCTAssertTrue(custom!.account.hasPrefix("Assets:Bank:"))
        XCTAssertNotEqual(custom!.account, "Assets:Bank:GongZiKa")
        XCTAssertNil(LedgerOnboardingDraft.customAccount(name: "  ", kind: "bank_card", currency: "", taken: []))
    }

    func testBalancesCanChangeAnAccountsCurrency() throws {
        let (draft, summary) = LedgerOnboardingCardAnswer
            .balances(["Assets:Bank:CMB": "1,5"], startDate: "", currencies: ["Assets:Bank:CMB": "HKD", "Liabilities:Alipay:Huabei": "CNY"])
            .applied(to: try Self.draft())
        XCTAssertEqual(draft.accounts.map(\.currency), ["HKD", ""])
        XCTAssertEqual(draft.accounts.first?.openingBalance, "1.5")
        XCTAssertEqual(summary, "余额：招行卡 1.5 HKD；期初就是今天。")
    }

    func testTheCategoriesCardStartsFromBuiltInCategories() {
        let defaults = LedgerOnboardingCard.defaultCategories
        XCTAssertEqual(defaults.count, LedgerOnboardingCard.defaultCategoryIDs.count)
        XCTAssertTrue(defaults.contains { $0.account == "Expenses:Food:Dining" && !$0.isIncome })
        XCTAssertTrue(defaults.contains { $0.account == "Income:Career:Salary" && $0.isIncome })
        // Every built-in path is one the draft accepts, and names are unique per side.
        for kind in [CategoryKind.income, .expense] {
            let items = CategoryPresets.sections(for: kind).flatMap { section in
                section.items.map { (name: $0.name, path: LedgerOnboardingCard.path(section, $0)) }
            }
            XCTAssertEqual(Set(items.map(\.name)).count, items.count)
            XCTAssertEqual(Set(items.map(\.path)).count, items.count)
            XCTAssertLessThanOrEqual(items.count, 80)
            for item in items { XCTAssertTrue(BeancountNaming.isValidAccountPath(item.path), item.path) }
        }
        XCTAssertEqual(LedgerOnboardingDraft.customCategory(name: "猫粮", income: false, taken: [])?.account.hasPrefix("Expenses:"), true)
    }

    func testImportConfigsNameOnlyAccountsTheLedgerOpens() {
        let accounts = [
            LedgerImportTemplates.Account(account: "Assets:Bank:CMB", currency: "CNY"),
            LedgerImportTemplates.Account(account: "Assets:Wallet:Alipay:Balance", currency: "CNY"),
            LedgerImportTemplates.Account(account: "Liabilities:CreditCard:HSBC", currency: "HKD"),
            LedgerImportTemplates.Account(account: "Liabilities:CreditCard:Huabei", currency: "CNY"),
        ]
        let categories = ["Expenses:Food:Dining", "Expenses:Transport:Taxi", "Expenses:Other", "Income:Other"]
        let configs = LedgerImportTemplates.configs(channels: ["alipay", "wechat", "hsbchk-credit", "cmb-checking", "meituan", "manual"],
                                                    currency: "CNY", accounts: accounts, categories: categories)
        XCTAssertEqual(configs.map(\.path), ["imports/alipay-config.yaml", "imports/wechat-config.yaml",
                                              "imports/hsbchk-credit-card-config.yaml", "imports/cmb-checking-config.yaml",
                                              "imports/meituan-config.yaml"])
        let opened = Set(accounts.map(\.account)).union(categories)
        for config in configs {
            for line in config.content.split(separator: "\n") {
                guard let range = line.range(of: #"(Assets|Liabilities|Income|Expenses):[A-Za-z0-9:-]+"#, options: .regularExpression) else { continue }
                XCTAssertTrue(opened.contains(String(line[range])), "\(config.path) names \(line[range])")
            }
        }
        let alipay = configs[0].content
        XCTAssertTrue(alipay.contains("methodAccount: Assets:Wallet:Alipay:Balance"))
        XCTAssertTrue(alipay.contains("methodAccount: Liabilities:CreditCard:Huabei"))
        XCTAssertFalse(alipay.contains("YuEBao"))
        XCTAssertTrue(alipay.contains("targetAccount: Expenses:Food:Dining"))
        XCTAssertTrue(configs[2].content.contains("defaultCashAccount: Liabilities:CreditCard:HSBC"))
        XCTAssertTrue(configs[2].content.contains("defaultCurrency: HKD"))
        XCTAssertTrue(configs[3].content.contains("defaultCashAccount: Assets:Bank:CMB"))
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
        XCTAssertEqual(conversation.messages.map(\.text), ["现在各有多少？", "余额：招行卡 100 CNY；期初就是今天。", "记下了。"])

        let sent = await recorder.sent
        XCTAssertEqual(sent.count, 2)
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: sent[1]) as? [String: Any])
        XCTAssertEqual(request["message"] as? String, "余额：招行卡 100 CNY；期初就是今天。")
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
        XCTAssertEqual(files.map(\.path), ["main.bean", "accounts.bean", "opening.bean", "imports/wechat-config.yaml",
                                           "imports/cmb-credit-card-config.yaml"])
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
