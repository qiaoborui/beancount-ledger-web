#if os(iOS)
import Charts
import SwiftUI

/// 账本助手 — a conversation over the local ledger. The design is
/// `docs/design/ios-balanced/agent.html`: questions sit in a sunken block on
/// the right, replies run on the page with a collapsible list of the reads
/// behind them, and the composer is the glass dock used by the import flow.
/// The Agent edits a private draft of the ledger; the change card under the
/// conversation is the only way that draft reaches the ledger. History and
/// the thinking effort follow `docs/design/ios-balanced/agent-history.html`.
struct LedgerAgentView: View {
    var isRoot = false
    @EnvironmentObject private var session: LedgerSession
    /// Shared, so a turn keeps going when this page closes or the app leaves
    /// the screen; `LedgerAgentBackgroundRun` holds it while it runs there.
    @ObservedObject private var sessions = LedgerAgentSessions.shared

    var body: some View {
        LedgerAgentChatScreen(isRoot: isRoot, conversation: sessions.current)
            .id(sessions.current.id)
            // The lock and privacy cover hide this page; the conversations
            // stay, so a turn sent before leaving the app still lands here.
            // Another ledger has its own history.
            .task(id: session.localRepository?.descriptor.id) {
                if let repository = session.localRepository {
                    sessions.bind(ledger: repository.descriptor.id, storage: .live(repository))
                }
            }
    }
}

private struct LedgerAgentChatScreen: View {
    var isRoot: Bool
    @ObservedObject var conversation: LedgerAgentConversation
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
<<<<<<< HEAD
    @ObservedObject private var sessions = LedgerAgentSessions.shared
=======
    /// Shared, so a turn keeps going when this page closes or the app leaves
    /// the screen; `LedgerAgentBackgroundRun` holds it while it runs there.
    @ObservedObject private var conversation = LedgerAgentConversation.shared
>>>>>>> origin/main
    @State private var draft = ""
    @State private var historyPresented = false
    @State private var settingsPresented = false
    @State private var bookkeeping: BookkeepingPrefill?
    @State private var crashReport: String?
    @FocusState private var composerFocused: Bool

    private struct BookkeepingPrefill: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        Group {
            if settings.isReady { chat } else { LedgerAgentIntro { settingsPresented = true } }
        }
        .background(BalancedPalette.page)
        .terminalPageChrome(String(localized: "账本助手"), isRoot: isRoot, showsSync: false, actions: AnyView(actions), balanced: true)
        .sheet(isPresented: $settingsPresented) {
            NavigationStack { LedgerAgentSettingsView() }
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $historyPresented) {
            NavigationStack { LedgerAgentHistoryView() }
                .presentationDetents([.medium, .large])
                .ledgerPrivacyProtectedSheet()
        }
        .fullScreenCover(item: $bookkeeping) { prefill in
            NaturalLanguageBookkeepingView(onSaved: { bookkeeping = nil }, initialInput: prefill.text)
        }
<<<<<<< HEAD
        .onAppear {
            conversation.isOnScreen = true
            LedgerAgentBackgroundRun.shared.conversationSeen()
        }
=======
        // The lock and privacy cover hide this page; the conversation stays,
        // so a turn sent before leaving the app still lands here. Another
        // ledger starts a new one.
        .task(id: session.localRepository?.descriptor.id) {
            if let id = session.localRepository?.descriptor.id { conversation.bind(ledger: id) }
        }
        .onAppear {
            conversation.isOnScreen = true
            LedgerAgentBackgroundRun.shared.conversationSeen()
        }
>>>>>>> origin/main
        .onDisappear { conversation.isOnScreen = false }
        .task {
            guard crashReport == nil, let repository = session.localRepository else { return }
            crashReport = LedgerAgentCrashReport.take(
                runtimeRoot: repository.workspace.rootDirectory.appendingPathComponent("runtime"))
        }
        .accessibilityIdentifier("ledger-agent")
    }

    /// Shown once after the native core aborted the app during a turn.
    private func crashBand(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上次回答时 App 意外退出").balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.expense)
            Text("下面是设备端引擎留下的诊断信息，不含 API Key。复制后发给开发者可以定位原因。")
                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            ScrollView {
                Text(report).balancedMono(size: 11).foregroundStyle(BalancedPalette.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            HStack(spacing: 10) {
                Button("复制诊断信息") { UIPasteboard.general.string = report }.buttonStyle(.balanced(.outline))
                Button("关闭") { crashReport = nil }.buttonStyle(.balanced(.quiet))
            }
        }
        .balancedBand()
        .accessibilityIdentifier("ledger-agent-crash")
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if settings.isReady {
                Button { historyPresented = true } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 16)).frame(width: 44, height: 44)
                        .foregroundStyle(BalancedPalette.ink)
                }
                .accessibilityLabel("历史对话")
                .accessibilityIdentifier("ledger-agent-history")
                Button { sessions.startNew() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 16)).frame(width: 44, height: 44)
                        .foregroundStyle(BalancedPalette.ink)
                }
                .disabled(conversation.messages.isEmpty && !conversation.isRunning && conversation.pending == nil)
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("ledger-agent-new")
            }
            Button { settingsPresented = true } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).frame(width: 44, height: 44)
                    .foregroundStyle(BalancedPalette.ink)
            }
            .accessibilityLabel("模型与密钥")
            .accessibilityIdentifier("ledger-agent-settings")
        }
        .buttonStyle(.plain)
    }

    // MARK: Conversation

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let crashReport { crashBand(crashReport) }
                    if conversation.messages.isEmpty && !conversation.isRunning { emptyState }
                    ForEach(conversation.messages) { message in
                        switch message.role {
                        case .user: LedgerAgentQuestion(text: message.text)
                        case .assistant: LedgerAgentAnswer(message: message) { bookkeeping = .init(text: question(before: message)) }
                        }
                    }
                    if let notice = conversation.restoredNotice {
                        Text(notice).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(BalancedPalette.sunken)
                            .accessibilityIdentifier("ledger-agent-restored-notice")
                    }
                    if let pending = conversation.pending {
                        LedgerAgentChangeCard(pending: pending, isBusy: conversation.isRunning,
                                              onWrite: conversation.write, onDiscard: conversation.discard)
                    } else if let written = conversation.written {
                        Label(String(localized: "已写入账本 · \(written.files.count) 个文件"), systemImage: "checkmark")
                            .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                            .accessibilityIdentifier("ledger-agent-written")
                    }
                    switch conversation.phase {
                    case .idle: EmptyView()
                    case .running: LedgerAgentRunning(step: conversation.step)
                    case let .failed(error, question): failure(error, question: question)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.messages.count) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.pending) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.phase) { _, phase in
                if case let .failed(_, question) = phase, draft.isEmpty { draft = question }
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    private static let bottomID = "ledger-agent-bottom"

    private static let suggestions = [
        String(localized: "这个月花了多少，主要花在哪"),
        String(localized: "最近 10 笔餐饮"),
        String(localized: "信用卡这个月还要还多少"),
        String(localized: "把上个月的打车都归到交通"),
    ]

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("想查什么？").balancedFont(size: 22, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                .padding(.top, 24)
            Text("可以查账，也可以让它改账；改动先进草稿，你确认后才写入。").balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                .padding(.top, 6)
            BalancedSectionLabel(text: String(localized: "试试")).padding(.top, 22)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button { send(suggestion) } label: {
                    HStack {
                        Text(suggestion).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 12)
                        Image(systemName: "arrow.up.left").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BalancedPalette.edge)
                    }
                    .frame(minHeight: 44)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func failure(_ error: LedgerAgentError, question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error == .notConfigured || error == .interrupted ? error.localizedDescription : String(localized: "模型服务拒绝了这次请求"))
                .balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.expense)
            Text(failureDetail(error)).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if case .invalidKey = error {
                    Button("去更新 Key") { settingsPresented = true }.buttonStyle(.balanced(.outline))
                } else if error == .notConfigured {
                    Button("设置模型与 Key") { settingsPresented = true }.buttonStyle(.balanced(.outline))
                }
                Button("重试") { send(question) }.buttonStyle(.balanced(.primary))
                    .accessibilityIdentifier("ledger-agent-retry")
            }
            .padding(.top, 4)
        }
        .accessibilityIdentifier("ledger-agent-error")
    }

    private func failureDetail(_ error: LedgerAgentError) -> String {
        let reason = switch error {
        case .notConfigured: String(localized: "还没有为当前服务商保存 API Key。")
        case let .invalidKey(message): String(localized: "API Key 无效或已过期。") + " " + message
        case let .failed(message): message
        case .interrupted: String(localized: "草稿里已有的改动会保留，点重试接着做。")
        }
        return reason + " " + String(localized: "账本没有被写入，问题还在输入框里。")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.busyElsewhere {
                Text("另一个对话正在回答，答完后才能在这里提问")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(.horizontal, 6)
            } else {
                LedgerAgentQuickSwitch { settingsPresented = true }
                    .padding(.horizontal, 2)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(conversation.pending == nil ? String(localized: "问问账本，比如「上个月餐饮花了多少」")
                          : String(localized: "还要怎么改…"), text: $draft, axis: .vertical)
                    .balancedFont(size: 15)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .padding(.vertical, 11)
                    .padding(.leading, 6)
                    .accessibilityIdentifier("ledger-agent-input")
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
                .disabled(!conversation.isRunning && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessions.busyElsewhere))
                .opacity(!conversation.isRunning && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessions.busyElsewhere) ? 0.38 : 1)
                .accessibilityLabel(conversation.isRunning ? "停止" : "发送")
                .accessibilityIdentifier("ledger-agent-send")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
        .ledgerGlassDock()
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !conversation.isRunning, !sessions.busyElsewhere else { return }
        guard let repository = session.localRepository, !session.privacyShielded else { return }
        let key: String
        do { key = try settings.apiKey() } catch {
            settingsPresented = true
            return
        }
<<<<<<< HEAD
        let choice = settings.choice, thinking = settings.effectiveThinking
=======
        let choice = settings.choice
        conversation.bind(ledger: repository.descriptor.id)
>>>>>>> origin/main
        conversation.editor = .live(repository)
        conversation.lifecycle = LedgerAgentBackgroundRun.shared
        LedgerAgentBackgroundRun.shared.concealsContent = session.localPrivacyProtectionEnabled
        conversation.send(question, reporting: { message, history, draftRoot, report in
            try await repository.runAgentTurn(message: message, history: history, choice: choice,
<<<<<<< HEAD
                                              apiKey: key, sensitiveUnlocked: true, thinking: thinking,
                                              draft: draftRoot, onStep: report)
=======
                                              apiKey: key, sensitiveUnlocked: true, draft: draftRoot, onStep: report)
>>>>>>> origin/main
        })
        draft = ""
    }

    private func question(before answer: LedgerAgentMessage) -> String {
        guard let index = conversation.messages.firstIndex(where: { $0.id == answer.id }) else { return "" }
        return conversation.messages[..<index].last { $0.role == .user }?.text ?? ""
    }
}

/// A question: right-aligned in the sunken well, never a bubble with a tail.
private struct LedgerAgentQuestion: View {
    let text: String
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(BalancedPalette.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }
}

/// A reply on the page, with the reads behind it folded above.
private struct LedgerAgentAnswer: View {
    let message: LedgerAgentMessage
    let onRecord: () -> Void
    @State private var toolsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.toolCalls.isEmpty { tools }
            ForEach(Array(LedgerAgentReplyText.segments(message.text).enumerated()), id: \.offset) { _, segment in
                LedgerAgentReplyBlock(segment: segment)
            }
            if LedgerAgentReplyText.beancountDraft(in: message.text) != nil {
                Button("用「记一笔」录入", action: onRecord).buttonStyle(.balanced(.outline))
                    .accessibilityIdentifier("ledger-agent-record")
            }
            if let footer { Text(footer).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta) }
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { toolsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(toolsSummary).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(BalancedPalette.edge)
                        .rotationEffect(.degrees(toolsExpanded ? 180 : 0))
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(toolsExpanded ? "已展开" : "已收起")
            if toolsExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(message.toolCalls.enumerated()), id: \.offset) { _, call in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(call.title).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(call.isError ? String(localized: "失败") : call.name)
                                    .balancedMono(size: 11)
                                    .foregroundStyle(call.isError ? BalancedPalette.expense : BalancedPalette.meta)
                            }
                            if let source = call.source {
                                Text(source).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                                    .textSelection(.enabled)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 1) }
            }
        }
    }

    private var toolsSummary: String {
        let edits = message.toolCalls.filter { ["edit_file", "write_file"].contains($0.name) && !$0.isError }.count
        return edits == 0
            ? String(localized: "读取了账本 \(message.toolCalls.count) 次")
            : String(localized: "调用了 \(message.toolCalls.count) 次工具，改了草稿 \(edits) 处")
    }

    private var footer: String? {
        guard let duration = message.duration else { return nil }
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        return message.toolCalls.isEmpty
            ? String(localized: "\(seconds) 秒")
            : String(localized: "\(message.toolCalls.count) 次工具调用 · \(seconds) 秒")
    }

}

/// The draft's change against the ledger: files with their line counts, an
/// expandable diff each, the validation result, and the only write button.
private struct LedgerAgentChangeCard: View {
    let pending: LedgerAgentPendingEdit
    let isBusy: Bool
    let onWrite: () -> Void
    let onDiscard: () -> Void
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 12)
                if let review = pending.review { counts(review.added, review.removed) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            if let review = pending.review {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.files) { file in fileRow(file, single: review.files.count == 1) }
                }
                .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            Text(note).balancedFont(size: 12.5).foregroundStyle(noteColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            HStack(spacing: 10) {
                Button(pending.review == nil ? String(localized: "放弃草稿") : String(localized: "放弃改动"), action: onDiscard)
                    .buttonStyle(.balanced(.outline))
                    .accessibilityIdentifier("ledger-agent-discard")
                if pending.review != nil {
                    Button(action: onWrite) {
                        if pending.status == .writing { ProgressView() } else { Text("写入账本") }
                    }
                    .buttonStyle(.balanced(.primary))
                    .disabled(pending.status != .ready)
                    .accessibilityIdentifier("ledger-agent-write")
                }
            }
            .disabled(isBusy || pending.status == .writing)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(BalancedPalette.sunken)
        .accessibilityIdentifier("ledger-agent-change")
    }

    private var title: String {
        switch pending.status {
        case .stale: String(localized: "账本已经变了")
        case .invalid: String(localized: "草稿没有通过校验")
        default: String(localized: "改动 \(pending.review?.files.count ?? 0) 个文件")
        }
    }

    private var note: String {
        switch pending.status {
        case .ready: String(localized: "校验通过。写入时会再校验一次，并生成一个可撤回的提交。")
        case .writing: String(localized: "正在写入…")
        case let .invalid(message): message + "\n" + String(localized: "可以让助手接着修，或者放弃草稿。")
        case .stale: String(localized: "对话期间账本有了新的改动，这份草稿不能直接写入。放弃后助手会基于最新账本重做。")
        case let .failed(message): String(localized: "没有写入：") + message
        }
    }

    private var noteColor: Color {
        switch pending.status {
        case .invalid, .stale, .failed: BalancedPalette.expense
        default: BalancedPalette.meta
        }
    }

    private func counts(_ added: Int, _ removed: Int) -> some View {
        HStack(spacing: 6) {
            if added > 0 { Text(verbatim: "+\(added)").foregroundStyle(BalancedPalette.income) }
            if removed > 0 { Text(verbatim: "−\(removed)").foregroundStyle(BalancedPalette.expense) }
        }
        .balancedMono(size: 12)
    }

    private func fileRow(_ file: LedgerAgentFileDiff, single: Bool) -> some View {
        let open = single || expanded.contains(file.path)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if expanded.contains(file.path) { expanded.remove(file.path) } else { expanded.insert(file.path) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(file.path).balancedMono(size: 12).foregroundStyle(BalancedPalette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    switch file.change {
                    case .added: Text("新文件").balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
                    case .removed: Text("删除").balancedFont(size: 11.5).foregroundStyle(BalancedPalette.expense)
                    case .modified: EmptyView()
                    }
                    Spacer(minLength: 8)
                    counts(file.added, file.removed)
                    if !single {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BalancedPalette.edge)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(single)
            .accessibilityValue(open ? "已展开" : "已收起")
            if open { diff(file) }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    private func diff(_ file: LedgerAgentFileDiff) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    switch line.kind {
                    case .context: Text(verbatim: "  " + line.text).foregroundStyle(BalancedPalette.meta)
                    case .added: Text(verbatim: "+ " + line.text).foregroundStyle(BalancedPalette.income)
                    case .removed: Text(verbatim: "- " + line.text).foregroundStyle(BalancedPalette.expense)
                    case .gap: Text(verbatim: "  … " + line.text).foregroundStyle(BalancedPalette.edge)
                    }
                }
            }
            .balancedMono(size: 11.5)
            .textSelection(.enabled)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BalancedPalette.page)
        .padding(.bottom, 8)
    }
}

/// One Markdown block of a reply.
private struct LedgerAgentReplyBlock: View {
    let segment: LedgerAgentReplyText.Segment

    var body: some View {
        switch segment {
        case let .prose(text):
            prose(text)
        case let .heading(level, text):
            Text(Self.inline(text))
                .balancedFont(size: level == 1 ? 19 : level == 2 ? 17 : 15.5, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(BalancedPalette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case let .list(_, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .balancedFont(size: 15, weight: item.marker.hasSuffix(".") ? .medium : .regular)
                            .monospacedDigit()
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(minWidth: 14, alignment: .trailing)
                        prose(item.text)
                    }
                    .padding(.leading, CGFloat(min(item.depth, 4)) * 16)
                }
            }
        case let .quote(text):
            prose(text, color: BalancedPalette.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 2) }
        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                            Text(Self.inline(cell)).balancedFont(size: 13, weight: .medium).foregroundStyle(BalancedPalette.meta)
                                .padding(.vertical, 6)
                                .gridColumnAlignment(Self.isAmountColumn(column, rows) ? .trailing : .leading)
                        }
                    }
                    BalancedPalette.ruleStrong.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Self.inline(cell)).balancedFont(size: 14).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                                    .padding(.vertical, 7)
                            }
                        }
                        BalancedPalette.rule.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .rule:
            BalancedPalette.rule.frame(height: 1).padding(.vertical, 4)
        case let .code(code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).balancedMono(size: 12.5).foregroundStyle(BalancedPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .balancedBand()
        case let .chart(chart):
            LedgerAgentChartView(chart: chart)
        }
    }

    private func prose(_ text: String, color: Color = BalancedPalette.ink) -> some View {
        Text(Self.inline(text)).balancedFont(size: 15).foregroundStyle(color)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Amount columns align right so their digits line up.
    private static func isAmountColumn(_ column: Int, _ rows: [[String]]) -> Bool {
        let cells = rows.map { $0[column] }.filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy(isAmount)
    }

    private static func isAmount(_ cell: String) -> Bool {
        cell.replacingOccurrences(of: "*", with: "").range(of: #"^[-+¥$€£]?\s?-?[\d,]+(\.\d+)?\s?([A-Z]{3}|元|%)?$"#, options: .regularExpression) != nil
    }
}

/// A chart the reply asked for, drawn with Swift Charts in the page's ink.
private struct LedgerAgentChartView: View {
    let chart: LedgerAgentChart
    private static let palette: [Color] = [BalancedPalette.ink, BalancedPalette.expense, BalancedPalette.income,
                                           BalancedPalette.meta, BalancedPalette.secondary, BalancedPalette.edge,
                                           BalancedPalette.ruleStrong, BalancedPalette.rule]

    private var names: [String] { chart.type == .pie ? chart.labels : chart.series.map(\.name) }
    private var colors: [Color] { names.indices.map { Self.palette[$0 % Self.palette.count] } }
    private var showsLegend: Bool { chart.type == .pie || chart.series.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chart.title, !title.isEmpty {
                Text(verbatim: title).balancedFont(size: 14, weight: .semibold).foregroundStyle(BalancedPalette.ink)
            }
            plot
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(showsLegend ? .visible : .hidden)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: chart.type == .pie ? 220 : 200)
            if let unit = chart.unit, !unit.isEmpty, chart.type != .pie {
                Text(verbatim: String(localized: "单位：\(unit)")).balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: chart.title ?? String(localized: "图表")))
    }

    @ViewBuilder private var plot: some View {
        let points = chart.points
        switch chart.type {
        case .bar:
            Chart(points) { point in
                if chart.stacked == false {
                    BarMark(x: .value("项目", point.label), y: .value("金额", point.value))
                        .foregroundStyle(by: .value("系列", point.series))
                        .position(by: .value("系列", point.series))
                } else {
                    BarMark(x: .value("项目", point.label), y: .value("金额", point.value))
                        .foregroundStyle(by: .value("系列", point.series))
                }
            }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 10.5)) } }
            .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 10.5)) } }
        case .line:
            Chart(points) { point in
                LineMark(x: .value("项目", point.label), y: .value("金额", point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("项目", point.label), y: .value("金额", point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .symbolSize(18)
            }
            .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 10.5)) } }
            .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 10.5)) } }
        case .pie:
            Chart(points) { point in
                SectorMark(angle: .value("金额", point.value), innerRadius: .ratio(0.58), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(by: .value("项目", point.label))
            }
        }
    }
}

private struct LedgerAgentRunning: View {
    let step: LedgerAgentStep?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).tint(BalancedPalette.meta).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(step?.title ?? String(localized: "正在查询账本")).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                    .lineLimit(1)
                Text("可以离开这一页或切到后台，答完会通知你").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ledger-agent-running")
    }
}

/// First use: what the assistant can do and what it sends, before any key.
private struct LedgerAgentIntro: View {
    let onSetUp: () -> Void

    private struct Ability: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    private let abilities = [
        Ability(title: String(localized: "汇总"), detail: String(localized: "某段时间的收入、支出和分类")),
        Ability(title: String(localized: "搜索流水"), detail: String(localized: "按商户、账户、标签、日期找交易")),
        Ability(title: String(localized: "BQL 查询"), detail: String(localized: "分组、排序、自定义统计")),
        Ability(title: String(localized: "账户"), detail: String(localized: "账户名称、别名和币种")),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("用对话查询账本").balancedFont(size: 24, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                    .padding(.top, 24)
                Text("问收支、余额或某一笔流水。助手在本机读取账本，再把查询结果发给你选的模型。")
                    .balancedFont(size: 15).foregroundStyle(BalancedPalette.secondary).lineSpacing(3)
                    .padding(.top, 10)
                BalancedSectionLabel(text: String(localized: "它能做什么")).padding(.top, 26)
                ForEach(abilities) { ability in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ability.title).balancedFont(size: 15, weight: .text).foregroundStyle(BalancedPalette.ink)
                        Text(ability.detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                }
                Text("这一版只读：不会新增、修改或删除交易。需要你自己的模型 API Key，费用记在你的模型账户上。")
                    .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .balancedBand()
                    .padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("设置模型与 Key", action: onSetUp)
                .buttonStyle(.balanced(.primary))
                .accessibilityIdentifier("ledger-agent-setup")
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                .ledgerGlassDock()
        }
    }
}

/// 模型与密钥 — provider, model, the Keychain key, and what leaves the device.
struct LedgerAgentSettingsView: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                Picker("服务商", selection: Binding(get: { settings.choice.provider }, set: { settings.select(provider: $0) })) {
                    ForEach(settings.catalog.providers) { provider in Text(provider.title).tag(provider.id) }
                }
                .accessibilityIdentifier("ledger-agent-provider")
                if settings.choice.isCustom {
                    Picker("接口协议", selection: Binding(get: { settings.choice.custom?.api ?? .openAICompletions },
                                                      set: { settings.setCustom(api: $0) })) {
                        ForEach(LedgerAgentModelChoice.CustomEndpoint.API.allCases) { api in Text(api.title).tag(api) }
                    }
                    .accessibilityIdentifier("ledger-agent-custom-api")
                    TextField("Base URL", text: Binding(get: { settings.choice.custom?.baseURL ?? "" },
                                                        set: { settings.setCustom(baseURL: $0) }),
                              prompt: Text(verbatim: "https://api.example.com/v1"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .balancedMono(size: 13)
                        .accessibilityIdentifier("ledger-agent-custom-url")
                    TextField("模型 ID", text: Binding(get: { settings.choice.model }, set: { settings.select(model: $0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .balancedMono(size: 13)
                        .accessibilityIdentifier("ledger-agent-custom-model")
                    if settings.hasKey, settings.choice.custom?.isValid == true {
                        NavigationLink("从服务拉取模型列表") { LedgerAgentModelPicker() }
                            .accessibilityIdentifier("ledger-agent-custom-list")
                    }
                } else {
                    NavigationLink {
                        LedgerAgentModelPicker()
                    } label: {
                        LabeledContent("模型") {
                            Text(settings.modelTitle).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    .accessibilityIdentifier("ledger-agent-model")
                }
                NavigationLink {
                    LedgerAgentThinkingPicker()
                } label: {
                    LabeledContent("思考强度") {
                        Text(settings.effectiveThinking.title).foregroundStyle(BalancedPalette.meta)
                    }
                }
                .accessibilityIdentifier("ledger-agent-thinking")
            } header: { Text("模型") } footer: {
                if settings.choice.isCustom {
                    let invalid = !(settings.choice.custom?.baseURL ?? "").isEmpty && settings.choice.custom?.isValid != true
                    Text(invalid ? "Base URL 需要是 http(s) 地址，不能带账号密码或查询参数。"
                                 : "兼容这三种协议的服务都可以用，比如自建网关、OneAPI、Ollama、vLLM。Base URL 填到 /v1 为止，Anthropic 协议也一样。模型需要支持工具调用。")
                }
            }
            Section {
                if settings.favorites.isEmpty {
                    Text("在模型列表里点星标收藏，聊天页就能一键切换。")
                        .foregroundStyle(BalancedPalette.meta)
                }
                ForEach(settings.favorites) { favorite in
                    Button { settings.select(favorite: favorite) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(favorite.title).foregroundStyle(BalancedPalette.ink)
                                Text(verbatim: settings.providerTitle(for: favorite.choice.provider) + " · " + favorite.choice.model)
                                    .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if favorite.id == LedgerAgentSettings.identity(settings.choice) {
                                Image(systemName: "checkmark").foregroundStyle(BalancedPalette.ink)
                            }
                        }
                    }
                }
                .onDelete { settings.removeFavorites(at: $0) }
                .onMove { settings.moveFavorites(from: $0, to: $1) }
            } header: { Text("收藏的模型") } footer: {
                if !settings.favorites.isEmpty { Text("左滑删除。最多 \(LedgerAgentSettings.favoriteLimit) 个，各自用对应服务商的 Key。") }
            }
            Section {
                if settings.hasKey { Label("\(settings.providerTitle) API Key 已保存在本机", systemImage: "key.fill") }
                SecureField(settings.hasKey ? "替换 API Key" : "\(settings.providerTitle) API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ledger-agent-api-key")
                Button("保存 API Key") {
                    do { try settings.saveKey(key); key = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ledger-agent-save-key")
                if settings.hasKey {
                    Button("删除 Key", role: .destructive) {
                        do { try settings.removeKey(); key = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } header: { Text("密钥") } footer: {
                Text("每个服务商的 Key 分开存放在本机钥匙串，不随账本导出、备份或 Git 同步。调用费用记在你的模型账户上。")
            }
            Section("发给模型的内容") {
                Text("你的问题、本次对话，以及助手调用工具后得到的结果（例如汇总金额、匹配到的流水）。不会发送整本账本文件，也不会发送 Git 凭据或本机路径。")
            }
            Section("可用工具 · 只读") {
                tool(String(localized: "汇总与搜索流水"), "get_ledger_summary · search_transactions")
                tool(String(localized: "BQL 查询"), "run_bql · validate_bql · get_bql_capabilities")
                tool(String(localized: "账户"), "get_accounts")
            }
        }
        .font(.subheadline)
        .navigationTitle("模型与密钥")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .onDisappear { key = "" }
    }

    private func tool(_ title: String, _ names: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(names).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
        }
    }
}

/// The selected provider's models: its own list once fetched with the saved
/// key, else the built-in catalog. Searchable because OpenRouter lists
/// hundreds; a typed id is accepted as is. The star keeps a model for the
/// chat page's switcher.
private struct LedgerAgentModelPicker: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let title: String
        let levels: [LedgerAgentThinking]
    }

    private var all: [Row] {
        if let listed = settings.listedModels { return listed.map { .init(id: $0.id, title: $0.title, levels: $0.thinking) } }
        return (settings.catalog.provider(settings.choice.provider)?.models ?? []).map { .init(id: $0.id, title: $0.title, levels: $0.thinking) }
    }

    private var rows: [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.id.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if let error = settings.listError {
                Section { StatusBanner(message: error) { settings.clearListError() } }
            }
            Section {
                let typed = query.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty, !rows.contains(where: { $0.id == typed }) {
                    Button { choose(typed) } label: { Text("使用「\(typed)」") }
                }
                ForEach(rows) { row in
                    HStack {
                        Button { choose(row.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).foregroundStyle(BalancedPalette.ink)
                                    Text(row.id).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                                }
                                Spacer()
                                if row.id == settings.choice.model {
                                    Image(systemName: "checkmark").foregroundStyle(BalancedPalette.ink)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            settings.toggleFavorite(model: row.id, title: row.title, levels: row.levels)
                        } label: {
                            Image(systemName: settings.isFavorite(model: row.id) ? "star.fill" : "star")
                                .foregroundStyle(settings.isFavorite(model: row.id) ? BalancedPalette.ink : BalancedPalette.meta)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(settings.isFavorite(model: row.id) ? "取消收藏" : "收藏")
                    }
                }
            } header: {
                if settings.listing {
                    Text("正在向 \(settings.providerTitle) 拉取…")
                } else if let listed = settings.listedModels {
                    Text("\(settings.providerTitle) 提供的 \(listed.count) 个模型")
                } else if !settings.choice.isCustom {
                    Text("内置目录")
                }
            } footer: {
                if settings.listedModels == nil, !settings.choice.isCustom {
                    Text("内置目录随 App 更新。点右上角刷新，用已保存的 Key 拉取服务商当前提供的模型。")
                } else if settings.listedModels != nil {
                    Text("目录里没有的模型，思考强度最高给到「高」，不支持时由服务端忽略。")
                }
            }
        }
        .font(.subheadline)
        .searchable(text: $query, prompt: Text("搜索或输入模型 ID"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(settings.providerTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if settings.listing {
                    ProgressView()
                } else {
                    Button { Task { await settings.refreshModels() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!settings.hasKey)
                        .accessibilityLabel("拉取模型列表")
                        .accessibilityIdentifier("ledger-agent-refresh-models")
                }
            }
        }
        .task {
            if settings.listedModels == nil, settings.hasKey, settings.choice.isCustom { await settings.refreshModels() }
        }
    }

    private func choose(_ id: String) {
        settings.select(model: id)
        dismiss()
    }
}

/// The chat page's switcher: starred models and the current model's
/// thinking levels, each one tap away. A turn already running keeps the
/// model and effort it was sent with.
private struct LedgerAgentQuickSwitch: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    var manage: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Menu { models } label: { chip(settings.modelTitle) }
                .accessibilityLabel(String(localized: "模型：\(settings.modelTitle)"))
                .accessibilityIdentifier("ledger-agent-quick-model")
            Menu { thinking } label: { chip(String(localized: "思考 \(settings.effectiveThinking.title)")) }
                .accessibilityLabel(String(localized: "思考强度：\(settings.effectiveThinking.title)"))
                .accessibilityIdentifier("ledger-agent-quick-thinking")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var models: some View {
        let current = LedgerAgentSettings.identity(settings.choice)
        Section(settings.favorites.isEmpty ? String(localized: "当前模型") : String(localized: "收藏")) {
            if !settings.currentIsFavorite {
                Button {} label: {
                    Label(settings.modelTitle, systemImage: "checkmark")
                    Text(verbatim: settings.providerTitle)
                }
            }
            ForEach(settings.favorites) { favorite in
                let provider = settings.providerTitle(for: favorite.choice.provider)
                Button {
                    settings.select(favorite: favorite)
                    if !settings.hasKey { manage() }
                } label: {
                    if favorite.id == current { Label(favorite.title, systemImage: "checkmark") } else { Text(favorite.title) }
                    Text(settings.hasKey(for: favorite.choice.provider) ? provider : String(localized: "\(provider) · 未保存 Key"))
                }
            }
        }
        Section {
            Button { settings.toggleFavoriteForCurrent() } label: {
                Label(settings.currentIsFavorite ? "取消收藏当前模型" : "收藏当前模型",
                      systemImage: settings.currentIsFavorite ? "star.slash" : "star")
            }
            Button(action: manage) { Label("全部模型与密钥…", systemImage: "slider.horizontal.3") }
        }
    }

    @ViewBuilder private var thinking: some View {
        Picker("思考强度", selection: Binding(get: { settings.effectiveThinking }, set: { settings.select(thinking: $0) })) {
            ForEach(settings.supportedThinking.reversed()) { level in
                Text(level.title).tag(level)
            }
        }
        .pickerStyle(.inline)
        if settings.thinkingIsAssumed {
            Section { Text("这个模型是否支持推理无从得知，不支持时由服务端忽略") }
        }
    }

    private func chip(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }
        .balancedFont(size: 12)
        .foregroundStyle(BalancedPalette.meta)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(BalancedPalette.meta.opacity(0.1)))
        .contentShape(Capsule())
    }
}

/// The efforts the current model accepts. The choice is kept across models;
/// a model without it uses the nearest level, which is the one checked.
private struct LedgerAgentThinkingPicker: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared

    var body: some View {
        List {
            Section {
                ForEach(settings.supportedThinking) { level in
                    Button { settings.select(thinking: level) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(level.title).foregroundStyle(BalancedPalette.ink)
                                if let hint = level.hint {
                                    Text(level == .default ? String(localized: "默认。") + hint : hint)
                                        .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                                }
                            }
                            Spacer()
                            if level == settings.effectiveThinking {
                                Image(systemName: "checkmark").foregroundStyle(BalancedPalette.ink)
                            }
                        }
                    }
                }
            } header: {
                Text("\(settings.modelTitle) 支持")
            } footer: {
                Text(settings.thinkingIsAssumed
                     ? "这个模型是否支持推理无从得知，最高给到「高」；不支持时由服务端忽略。"
                     : "越高越慢、越贵，复杂的批量改动更稳。换到不支持这一档的模型时，自动用最接近的一档。")
            }
        }
        .font(.subheadline)
        .navigationTitle("思考强度")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Saved conversations of this ledger, newest first, grouped by day. Picking
/// one switches the screen to it; a running one keeps running.
private struct LedgerAgentHistoryView: View {
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingClear = false

    private struct DaySection: Identifiable {
        let title: String
        let items: [LedgerAgentSavedConversation]
        var id: String { title }
    }

    private var groups: [DaySection] {
        let calendar = Calendar.current
        var today: [LedgerAgentSavedConversation] = [], yesterday: [LedgerAgentSavedConversation] = [], earlier: [LedgerAgentSavedConversation] = []
        for item in sessions.saved where item.matches(query) {
            if calendar.isDateInToday(item.updatedAt) { today.append(item) }
            else if calendar.isDateInYesterday(item.updatedAt) { yesterday.append(item) }
            else { earlier.append(item) }
        }
        return [DaySection(title: String(localized: "今天"), items: today), DaySection(title: String(localized: "昨天"), items: yesterday),
                DaySection(title: String(localized: "更早"), items: earlier)].filter { !$0.items.isEmpty }
    }

    var body: some View {
        List {
            if sessions.saved.isEmpty {
                Text("还没有历史对话。问过的问题会按账本存在本机。")
                    .foregroundStyle(BalancedPalette.meta)
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Button {
                            sessions.open(item.id)
                            dismiss()
                        } label: { row(item) }
                        .listRowBackground(item.id == sessions.current.id ? BalancedPalette.sunken : nil)
                        .swipeActions {
                            if !isRunning(item.id) {
                                Button(role: .destructive) { sessions.delete(item.id) } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            if !sessions.saved.isEmpty {
                Section {
                    Button("清空历史", role: .destructive) { confirmingClear = true }
                } footer: {
                    Text("对话跟着账本存在本机，不进 Git 同步、备份或导出。")
                }
            }
        }
        .font(.subheadline)
        .searchable(text: $query, prompt: Text("搜索问题和回答"))
        .navigationTitle("历史对话")
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sessions.startNew()
                    dismiss()
                } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel("新对话")
            }
        }
        .confirmationDialog("清空这本账本的全部历史对话？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { sessions.deleteAll() }
        }
        .accessibilityIdentifier("ledger-agent-history-list")
    }

    private func isRunning(_ id: UUID) -> Bool {
        (sessions.current.id == id && sessions.current.isRunning) || (sessions.background?.id == id && sessions.background?.isRunning == true)
    }

    private func row(_ item: LedgerAgentSavedConversation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Text(isRunning(item.id) ? String(localized: "正在回答…") : item.summary)
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                if item.unwrittenChange {
                    Text("有未写入的草稿改动").balancedFont(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(Self.time(item.updatedAt)).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private static func time(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }
}
#endif
