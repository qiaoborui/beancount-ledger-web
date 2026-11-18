import Foundation

/// The ledger an AI onboarding conversation is drafting. The app owns it and
/// sends it with every turn; the native loop edits it with its onboarding
/// tools and sends it back. Nothing is written until the user confirms, and
/// then through the same `createCustom` path the manual wizard uses.
struct LedgerOnboardingDraft: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable, Identifiable {
        var kind: String
        var name: String
        var account: String
        /// Empty for the ledger's currency.
        var currency = ""
        /// A plain non-negative decimal, or empty; for a liability, the
        /// amount owed.
        var openingBalance = ""

        var id: String { account }
        var isLiability: Bool { account.hasPrefix("Liabilities:") }
    }

    struct Category: Codable, Equatable, Sendable, Identifiable {
        var name: String
        var account: String
        var id: String { account }
    }

    /// The kinds the native tools accept, in the order the plan lists them.
    static let kinds = ["cash", "bank_card", "digital_wallet", "savings", "investment", "credit_card", "consumer_loan", "other_debt"]

    var title = String(localized: "我的账本")
    /// The device region's currency when it is a common one, else CNY; the
    /// accounts card shows it first so it is one tap to change.
    var currency = LedgerOnboardingDraft.regionCurrency()
    /// Dates the opening balances; empty means the day the ledger is created.
    var startDate = ""
    var accounts: [Account] = []
    var incomeCategories: [Category] = []
    var expenseCategories: [Category] = []
    /// Where the ledger lives: `device` or `git`; empty until asked, which
    /// is the device.
    var storage = ""
    /// The empty repository a Git ledger is pushed to. Never credentials:
    /// the token stays in the card and goes to the keychain.
    var remote = ""
    /// The bills the user means to import, by import provider id; `manual`
    /// is keeping the books by hand. Empty until asked.
    var importChannels: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate) ?? ""
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        incomeCategories = try container.decodeIfPresent([Category].self, forKey: .incomeCategories) ?? []
        expenseCategories = try container.decodeIfPresent([Category].self, forKey: .expenseCategories) ?? []
        storage = try container.decodeIfPresent(String.self, forKey: .storage) ?? ""
        remote = try container.decodeIfPresent(String.self, forKey: .remote) ?? ""
        importChannels = try container.decodeIfPresent([String].self, forKey: .importChannels) ?? []
    }

    /// The import channels the imports card offers, in its order.
    static let channels = ["alipay", "wechat", "cmb-checking", "cmb", "ccb-credit", "hsbchk-credit", "meituan", "manual"]

    static func channelTitle(_ channel: String) -> String {
        if channel == "manual" { return String(localized: "手动记账") }
        return LedgerImportProvider.provider(channel)?.compactLabel ?? channel
    }

    var isGitStorage: Bool { storage == "git" && !remote.isEmpty }

    /// The currencies the cards offer.
    static let currencies = AccountPresets.commonCurrencies

    static func regionCurrency(_ locale: Locale = .current) -> String {
        guard let code = locale.currency?.identifier.uppercased(), currencies.contains(code) else { return "CNY" }
        return code
    }

    /// The draft kind of a built-in account preset; nil for the kinds the
    /// draft has no root for (amounts owed to the user).
    static func kind(for category: AccountTypeCategory) -> String? {
        switch category {
        case .bank: "bank_card"
        case .wallet: "digital_wallet"
        case .credit: "credit_card"
        case .cash: "cash"
        case .wealth: "investment"
        case .loan: "consumer_loan"
        case .receivable: nil
        }
    }

    /// A built-in preset as a draft account. Cash is named and pathed after
    /// its currency; a preset meant for another currency keeps it.
    static func account(for preset: AccountPresetItem, ledgerCurrency: String) -> Account? {
        guard let kind = kind(for: preset.category) else { return nil }
        if preset.category == .cash, preset.id == "cash_cny" {
            return Account(kind: kind, name: String(localized: "\(ledgerCurrency) 现金"), account: "Assets:Cash:\(ledgerCurrency)",
                           currency: "")
        }
        let currency = preset.suggestedCurrency.flatMap { $0 == ledgerCurrency ? nil : $0 } ?? ""
        return Account(kind: kind, name: preset.name, account: preset.defaultAccount, currency: currency)
    }

    /// The draft kinds the custom-account row offers, with their titles.
    static let customKinds: [(kind: String, category: AccountTypeCategory)] = [
        ("bank_card", .bank), ("digital_wallet", .wallet), ("cash", .cash), ("investment", .wealth),
        ("credit_card", .credit), ("consumer_loan", .loan),
    ]

    /// A custom account the user typed: a pinyin path under the kind's root,
    /// numbered when it is taken.
    static func customAccount(name: String, kind: String, currency: String, taken: Set<String>) -> Account? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains("\""),
              let category = customKinds.first(where: { $0.kind == kind })?.category else { return nil }
        let base = BeancountNaming.buildAccountPath(category: category, preset: nil, customName: name)
        return Account(kind: kind, name: name, account: unique(base, taken: taken), currency: currency)
    }

    /// A custom category the user typed, under Income or Expenses.
    static func customCategory(name: String, income: Bool, taken: Set<String>) -> Category? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.contains("\"") else { return nil }
        let segment = BeancountNaming.toPinyinCamelCase(name)
        let base = (income ? "Income:" : "Expenses:") + (segment.isEmpty ? "Custom" : segment)
        return Category(name: name, account: unique(base, taken: taken))
    }

    private static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)\(index)") { index += 1 }
        return "\(base)\(index)"
    }

    /// What the ledger needs before it can be created: somewhere money is
    /// kept, and a category on each side.
    var isComplete: Bool {
        accounts.contains { !$0.isLiability } && !incomeCategories.isEmpty && !expenseCategories.isEmpty
    }

    /// The accounts grouped by kind, in `kinds` order; a kind this build
    /// does not know goes last under its own name.
    var accountGroups: [(kind: String, accounts: [Account])] {
        let order = Self.kinds + accounts.map(\.kind).filter { !Self.kinds.contains($0) }
        var seen = Set<String>()
        return order.filter { seen.insert($0).inserted }.compactMap { kind in
            let members = accounts.filter { $0.kind == kind }
            return members.isEmpty ? nil : (kind, members)
        }
    }

    static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "cash": String(localized: "现金")
        case "bank_card": String(localized: "银行卡")
        case "digital_wallet": String(localized: "电子钱包")
        case "savings": String(localized: "储蓄")
        case "investment": String(localized: "投资")
        case "credit_card": String(localized: "信用卡")
        case "consumer_loan": String(localized: "贷款")
        case "other_debt": String(localized: "其他欠款")
        default: kind
        }
    }

    var accountSelections: [OnboardingAccountSelection] {
        accounts.map {
            OnboardingAccountSelection(name: $0.name, account: $0.account,
                                       currency: $0.currency.isEmpty ? currency : $0.currency,
                                       initialBalance: $0.openingBalance.isEmpty ? nil : $0.openingBalance,
                                       isLiability: $0.isLiability)
        }
    }

    var categorySelections: [OnboardingCategorySelection] {
        (incomeCategories + expenseCategories).map { OnboardingCategorySelection(name: $0.name, account: $0.account, currency: currency) }
    }

    /// The files 创建账本 writes for this draft, in the split layout.
    func files(today: String) -> [LocalLedgerCatalog.LedgerFile] {
        LocalLedgerCatalog.customLedgerFiles(
            title: title, currency: currency, accounts: accountSelections, categories: categorySelections,
            openingDate: startDate.isEmpty ? today : startDate, layout: .split,
            importChannels: importChannels)
    }
}

/// A native card an onboarding turn ended on: the user fills it in on the
/// page, the app edits the draft itself and sends a summary as the next
/// message. `prompt` is the line the model said above it.
struct LedgerOnboardingCard: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case accounts, balances, categories, storage, imports
    }

    struct Suggestion: Decodable, Equatable, Hashable, Sendable, Identifiable {
        /// `income` or `expense`.
        let kind: String
        let name: String
        let account: String
        var id: String { account }
        var isIncome: Bool { kind == "income" }
    }

    let kind: Kind
    let prompt: String
    var suggested: [Suggestion] = []

    /// The path a built-in category gets: `Expenses:Food:Dining`.
    static func path(_ section: CategorySectionPreset, _ item: CategoryItemPreset) -> String {
        BeancountNaming.buildCategoryPath(kind: section.kind, sectionCode: section.code, itemCode: item.code, customName: item.name)
    }

    /// The built-in categories a card starts with when the draft has none:
    /// what most people spend on and earn from in their first month.
    static let defaultCategoryIDs = [
        "food_dining", "food_takeaway", "food_groceries", "food_coffee", "shop_daily", "trans_public", "trans_taxi",
        "home_rent", "home_utilities", "home_telecom", "apparel_clothes", "fun_subs", "health_med", "soc_gift",
        "other_misc", "career_salary", "career_bonus", "invest_interest", "refund_shop",
    ]

    static var defaultCategories: [Suggestion] {
        defaultCategoryIDs.compactMap { id in
            for section in CategoryPresets.sections {
                if let item = section.items.first(where: { $0.id == id }) {
                    return Suggestion(kind: section.kind == .income ? "income" : "expense", name: item.name,
                                      account: path(section, item))
                }
            }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, prompt, suggested }

    init(kind: Kind, prompt: String, suggested: [Suggestion] = []) {
        self.kind = kind
        self.prompt = prompt
        self.suggested = suggested
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        suggested = (try? container.decodeIfPresent([Suggestion].self, forKey: .suggested)) ?? []
    }
}

/// What the user filled in on an onboarding card. Applying it edits the
/// draft; the summary is what goes back to the model as the user's answer.
enum LedgerOnboardingCardAnswer: Equatable, Sendable {
    /// The ledger's currency and the accounts picked, in order; an account
    /// already in the draft keeps its opening balance.
    case accounts(currency: String, [LedgerOnboardingDraft.Account])
    /// Opening amounts by account path (empty for none), the start date
    /// (empty for the day the ledger is created), and each account's
    /// currency where the user changed it (empty for the ledger's).
    case balances([String: String], startDate: String, currencies: [String: String] = [:])
    /// The draft categories kept, by account path, and the suggestions added.
    case categories(kept: Set<String>, added: [LedgerOnboardingCard.Suggestion])
    /// `device`, or `git` with the repository address.
    case storage(String, remote: String)
    case imports([String])

    /// A plain non-negative amount with at most two decimals, or empty.
    /// Reads what a keyboard in any region types: a decimal comma
    /// (`12,5`), thousands separators (`12,000.50`, `12.000,50`), full-width
    /// punctuation, currency signs, and a separator typed last.
    static func normalizedAmount(_ raw: String) -> String? {
        var text = raw.filter { !$0.isWhitespace && !"¥￥$€£'_".contains($0) }
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "。", with: ".").replacingOccurrences(of: "．", with: ".")
        if text.isEmpty { return "" }
        if let last = text.last, last == "." || last == "," { text.removeLast() }
        let lastDot = text.lastIndex(of: "."), lastComma = text.lastIndex(of: ",")
        if let lastDot, let lastComma {
            // Whichever comes last is the decimal mark; the other groups.
            let (group, mark) = lastDot > lastComma ? (",", ".") : (".", ",")
            text = text.replacingOccurrences(of: group, with: "")
            if mark == "," { text = text.replacingOccurrences(of: ",", with: ".") }
        } else if lastComma != nil {
            // One comma with one or two digits after it is a decimal comma;
            // anything else groups thousands.
            if text.range(of: "^[0-9]+,[0-9]{1,2}$", options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: ",", with: ".")
            } else {
                text = text.replacingOccurrences(of: ",", with: "")
            }
        }
        guard text.range(of: "^[0-9]{1,13}(\\.[0-9]{1,2})?$", options: .regularExpression) != nil else { return nil }
        return Decimal(string: text) == 0 ? "" : text
    }

    func applied(to draft: LedgerOnboardingDraft) -> (draft: LedgerOnboardingDraft, summary: String) {
        var next = draft
        let separator = String(localized: "、")
        switch self {
        case let .accounts(currency, accounts):
            next.currency = currency
            let balances = Dictionary(draft.accounts.map { ($0.account, $0.openingBalance) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            next.accounts = accounts.filter { seen.insert($0.account).inserted }.map { account in
                var account = account
                if account.currency == currency { account.currency = "" }
                if account.openingBalance.isEmpty { account.openingBalance = balances[account.account] ?? "" }
                return account
            }
            let names = next.accounts.map { account in
                account.currency.isEmpty ? account.name : "\(account.name)（\(account.currency)）"
            }
            let body = names.isEmpty ? String(localized: "先不加") : names.joined(separator: separator)
            return (next, String(localized: "用 \(currency) 记账；账户：\(body)。"))
        case let .balances(amounts, startDate, currencies):
            var parts: [String] = []
            for index in next.accounts.indices {
                let account = next.accounts[index]
                if let currency = currencies[account.account] {
                    next.accounts[index].currency = currency == next.currency ? "" : currency
                }
                guard let raw = amounts[account.account], let amount = Self.normalizedAmount(raw) else { continue }
                next.accounts[index].openingBalance = amount
                guard !amount.isEmpty else { continue }
                let unit = next.accounts[index].currency.isEmpty ? next.currency : next.accounts[index].currency
                parts.append(account.isLiability ? String(localized: "\(account.name) 欠 \(amount) \(unit)") : "\(account.name) \(amount) \(unit)")
            }
            next.startDate = startDate
            let start = startDate.isEmpty ? String(localized: "期初就是今天") : String(localized: "期初 \(startDate)")
            let body = parts.isEmpty ? String(localized: "先不填余额") : parts.joined(separator: String(localized: "，"))
            return (next, String(localized: "余额：\(body)；\(start)。"))
        case let .categories(kept, added):
            let before = draft.incomeCategories + draft.expenseCategories
            next.incomeCategories = draft.incomeCategories.filter { kept.contains($0.account) }
                + added.filter(\.isIncome).map { .init(name: $0.name, account: $0.account) }
            next.expenseCategories = draft.expenseCategories.filter { kept.contains($0.account) }
                + added.filter { !$0.isIncome }.map { .init(name: $0.name, account: $0.account) }
            let removed = before.filter { !kept.contains($0.account) }.map(\.name)
            var parts = [String(localized: "分类定了，收入 \(next.incomeCategories.count) 个、支出 \(next.expenseCategories.count) 个")]
            if !added.isEmpty { parts.append(String(localized: "加上") + added.map(\.name).joined(separator: separator)) }
            if !removed.isEmpty { parts.append(String(localized: "去掉") + removed.joined(separator: separator)) }
            return (next, parts.joined(separator: String(localized: "，")) + String(localized: "。"))
        case let .storage(storage, remote):
            next.storage = storage
            next.remote = storage == "git" ? remote : ""
            return (next, storage == "git"
                ? String(localized: "存到 Git 仓库 \(remote)，令牌已经存进钥匙串。")
                : String(localized: "账本先只存在这台设备上。"))
        case let .imports(channels):
            let ordered = LedgerOnboardingDraft.channels.filter(channels.contains)
            next.importChannels = ordered
            let names = ordered.filter { $0 != "manual" }.map(LedgerOnboardingDraft.channelTitle)
            if names.isEmpty { return (next, String(localized: "平时都手动记账，不导入账单。")) }
            let manual = ordered.contains("manual") ? String(localized: "，其余手动记") : ""
            return (next, String(localized: "平时会导入：") + names.joined(separator: separator) + manual + String(localized: "。"))
        }
    }
}

/// The draft and whether the model presented it as finished. Any later edit
/// clears `ready`, so what the user confirms is what the model last showed.
struct LedgerOnboardingState: Codable, Equatable, Sendable {
    var draft = LedgerOnboardingDraft()
    var ready = false

    var canCreate: Bool { ready && draft.isComplete }
    var coverage: LedgerOnboardingCoverage { LedgerOnboardingCoverage(draft: draft) }
}

/// How much of the ledger the draft already describes, derived from the draft
/// itself rather than from what the conversation asked: which parts hold
/// something and which the ledger still needs, whatever order the user
/// answered in. Amounts owed and the profile have defaults, so they are shown
/// when present but never hold the plan back.
struct LedgerOnboardingCoverage: Equatable, Sendable {
    enum Part: String, CaseIterable, Sendable, Identifiable {
        case accounts, debts, income, expenses

        var id: String { rawValue }

        var title: String {
            switch self {
            case .accounts: String(localized: "资金账户")
            case .debts: String(localized: "待还款项")
            case .income: String(localized: "收入分类")
            case .expenses: String(localized: "支出分类")
            }
        }

        /// A ledger can be created without money owed; it cannot without
        /// somewhere to keep money and a category on each side.
        var isRequired: Bool { self != .debts }
    }

    struct Item: Equatable, Sendable, Identifiable {
        let part: Part
        let count: Int

        var id: String { part.rawValue }
        var isDone: Bool { count > 0 }
        var isMissing: Bool { part.isRequired && !isDone }
        /// 资金账户 2 / 待还款项 1 / 收入分类
        var label: String { isDone ? "\(part.title) \(count)" : part.title }
    }

    let items: [Item]

    init(draft: LedgerOnboardingDraft) {
        let accounts = draft.accounts.filter { !$0.isLiability }.count
        items = [
            Item(part: .accounts, count: accounts),
            Item(part: .debts, count: draft.accounts.count - accounts),
            Item(part: .income, count: draft.incomeCategories.count),
            Item(part: .expenses, count: draft.expenseCategories.count),
        ]
    }

    var missing: [Item] { items.filter(\.isMissing) }

    /// Whether the draft holds everything 确认创建 needs.
    var isComplete: Bool { missing.isEmpty }

    /// The one line above the conversation: which parts are still open, or
    /// that the plan is ready to review.
    var summary: String {
        guard !missing.isEmpty else { return String(localized: "资料齐了，可以看结构") }
        return String(localized: "还缺 ") + missing.map(\.part.title).joined(separator: String(localized: "、"))
    }
}

/// The greeting 账本助手 opens with once AI 开账 created the ledger: what the
/// ledger holds now and a few steps to tap. The app writes it, so the
/// hand-off costs no turn; a tap sends that step on as the first question.
struct LedgerAgentOpening: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let steps: [String]

    /// What a brand-new ledger most often needs next, in the order a new
    /// user tends to want it.
    static let nextSteps = [
        String(localized: "帮我导入一份账单"),
        String(localized: "帮我设置记账提醒"),
        String(localized: "帮我记第一笔账"),
        String(localized: "帮我调整首页"),
    ]

    /// The card under the greeting: one tap asks the assistant for that step.
    var ask: LedgerAgentAsk {
        LedgerAgentAsk(question: String(localized: "接下来想做什么？"), options: steps)
    }

    init(text: String, steps: [String] = Self.nextSteps) {
        self.text = text
        self.steps = steps
    }

    /// The greeting once first-run setup connected an existing Git ledger:
    /// the ledger already has its history, so the next steps differ.
    static func connected(name: String) -> LedgerAgentOpening {
        LedgerAgentOpening(
            text: String(localized: "「\(name)」接好了，之后在这台设备上记的账会推回仓库。") + "\n\n"
                + String(localized: "接下来想做什么？点一个，也可以直接说。"),
            steps: [String(localized: "这个月花了多少，主要花在哪"), String(localized: "帮我导入一份账单"),
                    String(localized: "帮我检查一下账本有没有问题"), String(localized: "帮我设置记账提醒")])
    }

    /// `storageNote` says how pushing to the ledger's Git repository went.
    init(draft: LedgerOnboardingDraft, storageNote: String? = nil) {
        let accounts = draft.accounts.count
        let categories = draft.incomeCategories.count + draft.expenseCategories.count
        text = String(localized: "「\(draft.title)」建好了：\(accounts) 个账户、\(categories) 个分类，用 \(draft.currency) 记账。")
            + (storageNote.map { "\n\n" + $0 } ?? "")
            + "\n\n" + String(localized: "接下来想做什么？点一个，也可以直接说。")
        steps = Self.nextSteps
    }
}

/// An onboarding conversation: the on-device Agent asks about the user's
/// accounts and habits and drafts the ledger, with no ledger open. It lives
/// only as long as the onboarding page.
@MainActor
final class LedgerOnboardingConversation: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: LedgerAgentMessage.Role
        var text: String
        var ask: LedgerAgentAsk? = nil
        var card: LedgerOnboardingCard? = nil
    }

    struct Credentials: Sendable {
        let choice: LedgerAgentModelChoice
        let apiKey: String
        let thinking: LedgerAgentThinking?
    }

    /// The first question, sent on the user's behalf and not shown.
    static let opening = "你好，我想开始记账，帮我建一本账本吧。"

    @Published private(set) var messages: [Message] = []
    @Published private(set) var state = LedgerOnboardingState()
    @Published private(set) var live = LedgerAgentLiveTurn()
    /// What the running turn is doing now, for the line under the reply.
    @Published private(set) var status: String?
    @Published private(set) var isRunning = false
    @Published private(set) var error: LedgerAgentError?

    private let runner: LedgerAgentRunner
    private let credentials: @MainActor () throws -> Credentials
    private let conversationID = UUID()
    private var transcript: String?
    /// The question of the turn that failed, for a retry.
    private var failedQuestion: String?
    private var task: Task<Void, Never>?
    private var epoch = 0

    init(runner: LedgerAgentRunner = .native,
         credentials: @escaping @MainActor () throws -> Credentials = LedgerOnboardingConversation.savedCredentials) {
        self.runner = runner
        self.credentials = credentials
    }

    static func savedCredentials() throws -> Credentials {
        let settings = LedgerAgentSettings.shared
        guard settings.isReady else { throw LedgerAgentError.notConfigured }
        return Credentials(choice: settings.choice, apiKey: try settings.apiKey(), thinking: settings.effectiveThinking)
    }

    var hasStarted: Bool { !messages.isEmpty || isRunning || transcript != nil }

    /// The pending choice card: the last reply's, while nothing newer exists.
    var pendingAsk: LedgerAgentAsk? {
        guard !isRunning, let last = messages.last, last.role == .assistant else { return nil }
        return last.ask
    }

    /// The pending onboarding card: the last reply's, while nothing newer
    /// exists.
    var pendingCard: LedgerOnboardingCard? {
        guard !isRunning, let last = messages.last, last.role == .assistant else { return nil }
        return last.card
    }

    /// Applies what the user filled in on the pending card to the draft and
    /// sends its summary as the user's answer. The draft changed, so the
    /// plan has to be presented again before it can be created.
    func submit(_ answer: LedgerOnboardingCardAnswer) {
        guard pendingCard != nil, !isRunning else { return }
        let (draft, summary) = answer.applied(to: state.draft)
        state.draft = draft
        state.ready = false
        send(summary)
    }

    /// Starts the conversation. `text` is what the user already said on
    /// the setup page before a model was connected; it opens the
    /// conversation as their own first message instead of the hidden one.
    func start(saying text: String? = nil) {
        guard !hasStarted else { return }
        let said = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if said.isEmpty {
            run(Self.opening)
        } else {
            messages.append(Message(role: .user, text: said))
            run(Self.opening + "\n" + said)
        }
    }

    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning else { return }
        messages.append(Message(role: .user, text: question))
        // A question the model never answered goes along with the next one.
        run(failedQuestion.map { "\($0)\n\(question)" } ?? question)
    }

    func retry() {
        guard let question = failedQuestion, !isRunning else { return }
        run(question)
    }

    func stop() { task?.cancel() }

    /// Drops the conversation and the draft, for starting over.
    func reset() {
        task?.cancel()
        epoch += 1
        messages = []
        state = LedgerOnboardingState()
        transcript = nil
        failedQuestion = nil
        error = nil
        finish()
    }

    private func run(_ question: String) {
        guard !isRunning else { return }
        error = nil
        failedQuestion = nil
        isRunning = true
        live = LedgerAgentLiveTurn()
        status = LedgerAgentStep.startingLoop.title
        let epoch = epoch, runner = runner, current = state, transcript = transcript, conversationID = conversationID
        let report: LedgerAgentSteps.Handler = { [weak self] step in
            Task { @MainActor in self?.advance(step, epoch: epoch) }
        }
        task = Task { [weak self] in
            do {
                guard let credentials = try self?.credentials() else { return }
                let response = try await Self.turn(message: question, state: current, transcript: transcript,
                                                   conversationID: conversationID, credentials: credentials,
                                                   runner: runner, onStep: report)
                guard let self, self.epoch == epoch else { return }
                self.settle(response, question: question)
            } catch is CancellationError {
                guard let self, self.epoch == epoch else { return }
                self.finish()
            } catch {
                guard let self, self.epoch == epoch else { return }
                self.fail(error as? LedgerAgentError ?? .failed(error.localizedDescription), question: question)
            }
        }
    }

    private func advance(_ step: LedgerAgentStep, epoch: Int) {
        guard self.epoch == epoch, isRunning else { return }
        if step.kind == .live {
            if let event = step.live { live.apply(event) }
            return
        }
        status = step.title
    }

    private func settle(_ response: LedgerAgentTurnResponse, question: String) {
        guard response.ok || response.cancelled == true else {
            return fail(LedgerAgentError.classify(response.error ?? String(localized: "这次没有得到回答")), question: question)
        }
        if let onboarding = response.onboarding { state = onboarding }
        if let next = response.transcript { transcript = next }
        let reply = (response.reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty || response.ask != nil || response.onboardingCard != nil {
            messages.append(Message(role: .assistant, text: reply, ask: response.ask, card: response.onboardingCard))
        }
        finish()
    }

    private func fail(_ failure: LedgerAgentError, question: String) {
        error = failure
        failedQuestion = question
        finish()
    }

    private func finish() {
        isRunning = false
        status = nil
        live = LedgerAgentLiveTurn()
        task = nil
    }

    nonisolated static func localDay(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// One onboarding turn through the native loop, stopped with the task.
    nonisolated static func turn(message: String, state: LedgerOnboardingState, transcript: String?,
                                 conversationID: UUID, credentials: Credentials, runner: LedgerAgentRunner,
                                 onStep: @escaping LedgerAgentSteps.Handler) async throws -> LedgerAgentTurnResponse {
        let turnID = UUID().uuidString
        let choice = credentials.choice
        let request = LedgerAgentTurnRequest(turnId: turnID, workspaceRoot: "", runtimeRoot: "", entrypoint: "",
            modelHandle: nil, sensitiveUnlocked: false, provider: choice.provider, model: choice.model,
            apiKey: credentials.apiKey, custom: choice.isCustom ? choice.custom : nil,
            thinking: credentials.thinking?.rawValue, history: [], message: message, transcript: transcript,
            conversationId: conversationID.uuidString, streamEvents: true, onboarding: state, today: localDay())
        let encoded = try JSONEncoder().encode(request)
        LedgerAgentSteps.observe(turnID, onStep)
        defer { LedgerAgentSteps.stop(turnID) }
        let data = try await withTaskCancellationHandler {
            try await runner.run(encoded)
        } onCancel: { runner.cancel(turnID) }
        let response: LedgerAgentTurnResponse
        do { response = try JSONDecoder().decode(LedgerAgentTurnResponse.self, from: data) } catch {
            try Task.checkCancellation()
            throw error
        }
        if Task.isCancelled, response.cancelled != true { throw CancellationError() }
        return response
    }
}

/// The ways into a first ledger that the setup page offers before any model
/// is involved: build one from scratch with the assistant, connect a Git
/// repository, or one of the file based ways.
enum LedgerSetupPath: String, CaseIterable, Sendable {
    case scratch, git, other
}

/// The scripted part of first-run setup. It runs on the device without a
/// model, so it only recognises what it can recognise for certain: which way
/// the user means and a repository address. Anything else is left to the
/// cards, or, from scratch, to the model once it is connected.
enum LedgerSetupScript {
    /// The way a free-text answer on the welcome screen points to. Anything
    /// that is not clearly about a repository or a file is about building a
    /// ledger, which is what most first answers describe.
    static func path(for text: String) -> LedgerSetupPath {
        let lower = text.lowercased()
        if gitRepository(in: text) != nil { return .git }
        if ["git", "仓库", "repo", "gitea", "gitlab"].contains(where: lower.contains) { return .git }
        if ["icloud", "云盘", "备份", "文件夹", ".bean", "恢复"].contains(where: lower.contains) { return .other }
        return .scratch
    }

    private static let hosts = ["github.com", "gitlab.com", "codeberg.org", "gitee.com", "bitbucket.org"]

    /// The first repository address in the text, as an HTTPS URL: a full
    /// `https://` address on any host, or `host/owner/repo` on a host that is
    /// known to serve Git. SSH addresses are not supported by the app's Git
    /// transport, so they are not recognised.
    static func gitRepository(in text: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，。；、“”「」()（）<>"))
        for raw in text.components(separatedBy: separators) {
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\"`"))
            guard !token.isEmpty else { continue }
            let lower = token.lowercased()
            if lower.hasPrefix("http://") { continue }
            if !lower.hasPrefix("https://") {
                guard hosts.contains(where: { lower.hasPrefix($0 + "/") }) else { continue }
                token = "https://" + token
            }
            guard let url = URL(string: token), let host = url.host, !host.isEmpty else { continue }
            let parts = url.path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            // A browser link into the repository (…/tree/main/x) names the
            // repository by its first two path parts on the known hosts.
            if hosts.contains(host.lowercased()), parts.count > 2 {
                return "https://\(host)/\(parts[0])/\(parts[1])"
            }
            return token
        }
        return nil
    }

    /// A name for a ledger connected from a repository: its last path part
    /// without `.git`, or 我的账本.
    static func ledgerName(forRepository address: String) -> String {
        guard let url = URL(string: address) else { return String(localized: "我的账本") }
        var name = url.lastPathComponent
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "/" ? String(localized: "我的账本") : trimmed
    }
}
