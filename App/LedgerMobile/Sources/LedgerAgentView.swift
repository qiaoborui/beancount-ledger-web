#if os(iOS)
import SwiftUI

/// 账本助手 — a conversation over the local ledger. The design is
/// `docs/design/ios-balanced/agent.html`: questions sit in a sunken block on
/// the right, replies run on the page with a collapsible list of the reads
/// behind them, and the composer is the glass dock used by the import flow.
/// The Agent edits a private draft of the ledger; the change card under the
/// conversation is the only way that draft reaches the ledger.
struct LedgerAgentView: View {
    var isRoot = false
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @StateObject private var conversation = LedgerAgentConversation()
    @State private var draft = ""
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
        .fullScreenCover(item: $bookkeeping) { prefill in
            NaturalLanguageBookkeepingView(onSaved: { bookkeeping = nil }, initialInput: prefill.text)
        }
        // Locking hides the ledger everywhere; the questions go with it.
        .onChange(of: session.privacyShielded) { _, shielded in
            if shielded { conversation.reset() }
        }
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
                Button {
                    conversation.reset()
                    draft = ""
                } label: {
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
                    case .running: LedgerAgentRunning()
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
            Text(error == .notConfigured ? error.localizedDescription : String(localized: "模型服务拒绝了这次请求"))
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
        }
        return reason + " " + String(localized: "账本没有被写入，问题还在输入框里。")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if conversation.messages.isEmpty && !conversation.isRunning {
                Text(verbatim: "\(settings.modelTitle) · \(settings.providerTitle)")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(.horizontal, 6)
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
                .disabled(!conversation.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(!conversation.isRunning && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.38 : 1)
                .accessibilityLabel(conversation.isRunning ? "停止" : "发送")
                .accessibilityIdentifier("ledger-agent-send")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 8))
        .ledgerGlassDock()
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !conversation.isRunning else { return }
        guard let repository = session.localRepository, !session.privacyShielded else { return }
        let key: String
        do { key = try settings.apiKey() } catch {
            settingsPresented = true
            return
        }
        let choice = settings.choice
        if conversation.editor == nil { conversation.editor = .live(repository) }
        conversation.send(question) { message, history, draftRoot in
            try await repository.runAgentTurn(message: message, history: history, choice: choice,
                                              apiKey: key, sensitiveUnlocked: true, draft: draftRoot)
        }
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

private struct LedgerAgentRunning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).tint(BalancedPalette.meta).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在查询账本").balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                Text("助手可能会读取几次，期间不会改动账本").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
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
            } header: { Text("模型") } footer: {
                if settings.choice.isCustom {
                    let invalid = !(settings.choice.custom?.baseURL ?? "").isEmpty && settings.choice.custom?.isValid != true
                    Text(invalid ? "Base URL 需要是 http(s) 地址，不能带账号密码或查询参数。"
                                 : "兼容这三种协议的服务都可以用，比如自建网关、OneAPI、Ollama、vLLM。Base URL 填到 /v1 为止，Anthropic 协议也一样。模型需要支持工具调用。")
                }
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

/// The models the native loop knows for the selected provider, searchable
/// because OpenRouter lists hundreds; a typed id is accepted as is.
private struct LedgerAgentModelPicker: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var models: [LedgerAgentCatalog.Model] {
        let all = settings.catalog.provider(settings.choice.provider)?.models ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.id.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            let typed = query.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty, !models.contains(where: { $0.id == typed }) {
                Button { choose(typed) } label: { Text("使用「\(typed)」") }
            }
            ForEach(models) { model in
                Button { choose(model.id) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.title).foregroundStyle(BalancedPalette.ink)
                            Text(model.id).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                        }
                        Spacer()
                        if model.id == settings.choice.model {
                            Image(systemName: "checkmark").foregroundStyle(BalancedPalette.ink)
                        }
                    }
                }
            }
        }
        .font(.subheadline)
        .searchable(text: $query, prompt: Text("搜索或输入模型 ID"))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(settings.providerTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ id: String) {
        settings.select(model: id)
        dismiss()
    }
}
#endif
