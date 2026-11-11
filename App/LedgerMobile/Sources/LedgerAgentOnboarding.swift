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
    static let opening = "你好，我想新建一个账本，请帮我完成初始化。"

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
        run(question)
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
            conversationId: conversationID.uuidString, streamEvents: true, onboarding: state)
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
