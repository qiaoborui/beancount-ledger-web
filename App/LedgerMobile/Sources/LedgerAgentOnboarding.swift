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
    var currency = "CNY"
    /// Dates the opening balances; empty means the day the ledger is created.
    var startDate = ""
    var accounts: [Account] = []
    var incomeCategories: [Category] = []
    var expenseCategories: [Category] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? ""
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate) ?? ""
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        incomeCategories = try container.decodeIfPresent([Category].self, forKey: .incomeCategories) ?? []
        expenseCategories = try container.decodeIfPresent([Category].self, forKey: .expenseCategories) ?? []
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

    init(draft: LedgerOnboardingDraft) {
        let accounts = draft.accounts.count
        let categories = draft.incomeCategories.count + draft.expenseCategories.count
        text = String(localized: "「\(draft.title)」建好了：\(accounts) 个账户、\(categories) 个分类，用 \(draft.currency) 记账。")
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

    func start() {
        guard !hasStarted else { return }
        run(Self.opening)
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
        if !reply.isEmpty || response.ask != nil {
            messages.append(Message(role: .assistant, text: reply, ask: response.ask))
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
