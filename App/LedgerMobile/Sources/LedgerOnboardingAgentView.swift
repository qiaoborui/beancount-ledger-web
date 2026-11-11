import SwiftUI

/// AI 开账: the on-device Agent asks about the user's accounts and habits and
/// drafts the ledger as they talk. The plan under the conversation is the
/// draft itself; nothing is written until 确认创建, and then through the same
/// path as the manual wizard, which stays one tap away.
struct LedgerOnboardingAgentView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @StateObject private var conversation = LedgerOnboardingConversation()
    @State private var draft = ""
    @State private var picked: Set<String> = []
    @State private var settingsPresented = false
    @State private var showingWizard = false
    @State private var creating = false
    @FocusState private var composerFocused: Bool

    private var plan: LedgerOnboardingDraft { conversation.state.draft }

    var body: some View {
        NavigationStack {
            Group {
                if settings.isReady { chat } else { setup }
            }
            .background(BalancedPalette.page)
            .navigationTitle("AI 开账")
            .navigationBarTitleDisplayMode(.inline)
            .terminalNativeChrome()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { conversation.stop(); dismiss() }.disabled(creating)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("手动开账") { showingWizard = true }
                        .disabled(creating)
                        .accessibilityIdentifier("ai-onboarding-manual")
                }
            }
            .sheet(isPresented: $settingsPresented) {
                NavigationStack { LedgerAgentSettingsView() }.ledgerPrivacyProtectedSheet()
            }
            .sheet(isPresented: $showingWizard) { OnboardingWizardView() }
            .onChange(of: settings.isReady) { _, ready in if ready { conversation.start() } }
            .onChange(of: session.phase) { _, phase in if phase == .ready { dismiss() } }
            .onDisappear { conversation.stop() }
            .interactiveDismissDisabled(conversation.hasStarted || creating)
        }
    }

    // MARK: Model setup

    private var setup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TerminalSectionLabel(text: String(localized: "先接上模型"))
                Text("AI 开账用的是账本助手：选一个模型服务并填入你自己的 API Key，它会和你聊几句，按你实际用的账户和收支习惯搭好账本。")
                    .balancedFont(size: 15).foregroundStyle(BalancedPalette.ink).lineSpacing(4)
                Text("Key 只保存在这台设备的钥匙串里。对话只发送给你选的模型服务，确认创建前不会写入任何文件。")
                    .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary).lineSpacing(3)
                Button("设置模型与 API Key") { settingsPresented = true }
                    .buttonStyle(.balanced(.primary))
                    .accessibilityIdentifier("ai-onboarding-setup-model")
                Button("跳过，手动开账") { showingWizard = true }
                    .buttonStyle(.balanced(.quiet))
                    .accessibilityIdentifier("ai-onboarding-skip")
            }
            .balancedBand(lead: true)
            .padding(.horizontal, 20)
        }
    }

    // MARK: Conversation

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("说说你平时用哪些银行卡、钱包和信用卡，大概的余额，以及主要的收入和花销。账本结构会随着对话出现在下面，确认之前不会创建。")
                        .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary).lineSpacing(3)
                    ForEach(conversation.messages) { message in
                        switch message.role {
                        case .user: question(message.text)
                        case .assistant: answer(message)
                        }
                    }
                    if conversation.isRunning { running }
                    if let error = conversation.error { failure(error) }
                    if !plan.accounts.isEmpty || !plan.incomeCategories.isEmpty || !plan.expenseCategories.isEmpty { planBand }
                    if let error = session.errorMessage {
                        StatusBanner(message: error, onDismiss: session.dismissError)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock.padding(.horizontal, 12).padding(.bottom, 6) }
            .onChange(of: conversation.messages.count) { _, _ in
                picked = []
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: conversation.live.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .task { conversation.start() }
        }
    }

    private func question(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(BalancedPalette.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    private func answer(_ message: LedgerOnboardingConversation.Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                LedgerAgentStreamingReply(text: message.text, streaming: false) { send($0) }
            }
            if let ask = message.ask, message.id == conversation.messages.last?.id, conversation.pendingAsk != nil {
                choices(ask)
            }
        }
    }

    /// The options of an `ask_user` card, as on the Agent page: one tap
    /// answers a single choice; several are ticked, then sent together.
    private func choices(_ ask: LedgerAgentAsk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ask.options, id: \.self) { option in
                Button {
                    if ask.allowsMultiple {
                        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
                    } else {
                        send(option)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if ask.allowsMultiple {
                            Image(systemName: picked.contains(option) ? "checkmark.square.fill" : "square")
                                .font(.system(size: 15)).foregroundStyle(BalancedPalette.ink)
                        }
                        Text(option).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 12)
                        if !ask.allowsMultiple {
                            Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BalancedPalette.edge)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ai-onboarding-choice")
            }
            HStack(spacing: 10) {
                Text(ask.allowsMultiple ? String(localized: "可多选；也可以直接在下面输入") : String(localized: "也可以直接在下面输入"))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                Spacer(minLength: 8)
                if ask.allowsMultiple {
                    Button("发送") { send(ask.answer(picked)) }
                        .buttonStyle(.balanced(.primary))
                        .fixedSize()
                        .disabled(picked.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(BalancedPalette.sunken)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !conversation.live.text.isEmpty {
                LedgerAgentStreamingReply(text: conversation.live.text)
            }
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(BalancedPalette.meta)
                Text(conversation.status ?? String(localized: "正在思考"))
                    .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai-onboarding-running")
        }
    }

    private func failure(_ error: LedgerAgentError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.headline).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.expense)
            if let detail = error.detail {
                Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary).lineLimit(4)
            }
            HStack(spacing: 10) {
                if case .notConfigured = error {
                    Button("设置模型") { settingsPresented = true }.buttonStyle(.balanced())
                } else {
                    Button("重试") { conversation.retry() }.buttonStyle(.balanced())
                    if case .invalidKey = error {
                        Button("设置模型") { settingsPresented = true }.buttonStyle(.balanced(.quiet))
                    }
                }
            }
        }
        .accessibilityIdentifier("ai-onboarding-error")
    }

    // MARK: Plan

    /// The draft as the next 确认创建 would write it: the Agent's own
    /// working copy, shown in the user's words, never as account paths.
    private var planBand: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TerminalSectionLabel(text: String(localized: "账本结构"))
                Spacer()
                Text(conversation.state.canCreate ? String(localized: "方案已就绪") : String(localized: "整理中"))
                    .balancedFont(size: 12).foregroundStyle(conversation.state.canCreate ? BalancedPalette.income : BalancedPalette.meta)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.title).balancedFont(size: 17, weight: .medium).foregroundStyle(BalancedPalette.ink)
                Text(plan.startDate.isEmpty ? String(localized: "\(plan.currency) · 期初为创建当天") : String(localized: "\(plan.currency) · 期初 \(plan.startDate)"))
                    .balancedMono(size: 12).foregroundStyle(BalancedPalette.meta)
            }
            ForEach(plan.accountGroups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(LedgerOnboardingDraft.kindTitle(group.kind))
                        .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        .padding(.bottom, 2)
                    ForEach(group.accounts) { account in
                        HStack(alignment: .firstTextBaseline) {
                            Text(account.name).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                            Spacer(minLength: 12)
                            if !account.openingBalance.isEmpty {
                                Text(balanceText(account))
                                    .balancedMono(size: 13)
                                    .foregroundStyle(account.isLiability ? BalancedPalette.expense : BalancedPalette.ink)
                            }
                        }
                        .frame(minHeight: 32)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    }
                }
            }
            categories(String(localized: "收入分类"), plan.incomeCategories)
            categories(String(localized: "支出分类"), plan.expenseCategories)
        }
        .balancedBand(lead: true)
        .accessibilityIdentifier("ai-onboarding-plan")
    }

    private func balanceText(_ account: LedgerOnboardingDraft.Account) -> String {
        let currency = account.currency.isEmpty ? plan.currency : account.currency
        return account.isLiability
            ? String(localized: "欠 \(account.openingBalance) \(currency)")
            : "\(account.openingBalance) \(currency)"
    }

    @ViewBuilder
    private func categories(_ title: String, _ items: [LedgerOnboardingDraft.Category]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                Text(items.map(\.name).joined(separator: String(localized: "、")))
                    .balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink).lineSpacing(3)
            }
        }
    }

    // MARK: Dock

    private var dock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.state.canCreate && !conversation.isRunning {
                Button { create() } label: {
                    if creating { ProgressView().tint(BalancedPalette.page) } else { Text("确认创建「\(plan.title)」") }
                }
                .buttonStyle(.balanced(.primary))
                .disabled(creating || session.isLocalOperationBusy)
                .accessibilityIdentifier("ai-onboarding-create")
            }
            HStack(alignment: .bottom, spacing: 4) {
                TextField(text: $draft, prompt: Text("回答问题，或补充想调整的地方").foregroundStyle(BalancedPalette.meta), axis: .vertical) {
                    Text("回答问题，或补充想调整的地方")
                }
                .balancedFont(size: 15)
                .lineLimit(1...5)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.vertical, 11)
                .padding(.leading, 8)
                .disabled(creating)
                .accessibilityIdentifier("ai-onboarding-input")
                let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating
                Button {
                    if conversation.isRunning { conversation.stop() } else { send(draft) }
                } label: {
                    Image(systemName: conversation.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BalancedPalette.page)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(BalancedPalette.ink))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!conversation.isRunning && !canSend)
                .opacity(!conversation.isRunning && !canSend ? 0.38 : 1)
                .accessibilityLabel(conversation.isRunning ? "停止" : "发送")
                .accessibilityIdentifier("ai-onboarding-send")
            }
            .padding(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 4))
            .ledgerGlassDock()
        }
    }

    private func send(_ text: String) {
        guard !conversation.isRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversation.send(text)
        draft = ""
    }

    private func create() {
        let plan = plan
        creating = true
        composerFocused = false
        Task {
            await session.createCustomLocalLedger(name: plan.title, currency: plan.currency,
                                                  accounts: plan.accountSelections, categories: plan.categorySelections,
                                                  openingDate: plan.startDate.isEmpty ? nil : plan.startDate)
            creating = false
            if session.phase == .ready { dismiss() }
        }
    }
}
