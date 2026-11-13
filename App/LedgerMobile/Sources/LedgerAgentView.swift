#if os(iOS)
import Charts
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 账本助手 — a conversation over the local ledger. The design is
/// `docs/design/ios-balanced/agent.html`: questions sit in a sunken block on
/// the right, replies run on the page with a collapsible list of the reads
/// behind them, and the composer is the glass dock used by the import flow.
/// The Agent edits a private draft of the ledger; the change card under the
/// conversation is the only way that draft reaches the ledger. History and
/// the thinking effort follow `docs/design/ios-balanced/agent-history.html`.
struct LedgerAgentView: View {
    var isRoot = false
    /// Set when the assistant is a sheet: a close button joins the header.
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var session: LedgerSession
    /// Shared, so a turn keeps going when this page closes or the app leaves
    /// the screen; `LedgerAgentBackgroundRun` holds it while it runs there.
    @ObservedObject private var sessions = LedgerAgentSessions.shared

    var body: some View {
        LedgerAgentChatScreen(isRoot: isRoot, onClose: onClose, conversation: sessions.current)
            .id(sessions.current.id)
            // The lock and privacy cover hide this page; the conversations
            // stay, so a turn sent before leaving the app still lands here.
            // Another ledger has its own history.
            .task(id: session.localRepository?.descriptor.id) {
                if let repository = session.localRepository {
                    sessions.bind(ledger: repository.descriptor.id, storage: .live(repository))
                }
            }
            // A question from Siri, a shortcut or a ledger://agent?q= link
            // starts a conversation of its own, unless one is answering.
            .task(id: session.pendingAgentQuestion?.id) {
                guard let question = session.takePendingAgentQuestion() else { return }
                if !sessions.current.isRunning, !sessions.busyElsewhere { sessions.startNew() }
                sessions.queuedQuestion = question
            }
    }
}

private struct LedgerAgentChatScreen: View {
    var isRoot: Bool
    var onClose: (() -> Void)?
    @ObservedObject var conversation: LedgerAgentConversation
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @ObservedObject private var starters = LedgerAgentStarters.shared
    @State private var draft = ""
    @State private var historyPresented = false
    @State private var memoryPresented = false
    /// When the app last left the screen, for a recap on a long absence.
    @State private var awaySince: Date?
    @State private var settingsPresented = false
    @State private var bookkeeping: BookkeepingPrefill?
    @State private var crashReport: String?
    @State private var choosingFiles = false
    /// The photo library is presented by the view, not from inside the attach
    /// menu: a picker nested in a `Menu` is dismissed with the menu and never
    /// appears, which made "从相册选截图或照片" look like a dead button.
    @State private var photoLibraryPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cameraPresented = false
    @State private var attaching = false
    @State private var attachError: String?
    @State private var inboxItems: [LedgerSharedImportInbox.Item] = []
    /// True while a drag from another app hovers the conversation.
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// The question being edited in the composer, and what the composer held
    /// before, given back when the edit is cancelled.
    @State private var editing: UUID?
    @State private var draftBeforeEdit = ""
    /// A regenerate, edit or switch waiting for the user's word.
    @State private var confirming: BranchConfirmation?
    /// Counts copies, for the haptic.
    @State private var copies = 0

    private struct BookkeepingPrefill: Identifiable {
        let id = UUID()
        let text: String
    }

    private enum BranchAction {
        case regenerate(UUID)
        case edit(UUID, String)
        case switchVersion(UUID, Int)
        case latestAnswer(UUID)
    }

    private struct BranchConfirmation: Identifiable {
        let id = UUID()
        let action: BranchAction
        let warning: LedgerAgentBranchWarning
    }

    var body: some View {
        Group {
            if settings.isReady { chat } else { LedgerAgentIntro { settingsPresented = true } }
        }
        .background(BalancedPalette.page)
        .terminalPageChrome(headerTitle, isRoot: isRoot, showsSync: false, actions: AnyView(actions), balanced: true,
                            titleAction: headerTitleAction)
        .sheet(isPresented: $settingsPresented) {
            NavigationStack { LedgerAgentSettingsView() }
                .ledgerPrivacyProtectedSheet()
        }
        // The context meter and compaction need the model's window, which only
        // the provider's list gives for most models; read it once, quietly.
        // Keyed on the saved key too: a key saved after the endpoint and model
        // were filled in must still start the read.
        .task(id: settings.contextWindowTaskID) { await settings.learnContextWindow() }
        .sheet(isPresented: $memoryPresented) {
            NavigationStack { LedgerAgentMemoryView() }
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $historyPresented) {
            NavigationStack { LedgerAgentHistoryView(sharesText: session.amountsVisible) }
                .presentationDetents([.medium, .large])
                .ledgerPrivacyProtectedSheet()
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: LedgerAgentAttachments.pickerTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): attach(urls.map { .file($0) })
            case let .failure(error): attachError = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $photoLibraryPresented, selection: $photoItems,
                      maxSelectionCount: 6, matching: .images)
        .fullScreenCover(isPresented: $cameraPresented) {
            LedgerCameraPicker { data in
                attach([.imageData(data, suggestedName: String(localized: "票据照片") + ".jpg")])
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            attach(items.map { .photo($0) })
        }
        .fullScreenCover(item: $bookkeeping) { prefill in
            NaturalLanguageBookkeepingView(onSaved: { bookkeeping = nil }, initialInput: prefill.text)
        }
        .alert(confirming.map { confirmationTitle($0.warning) } ?? "", isPresented: confirmingPresented,
               presenting: confirming) { confirmation in
            Button("继续") { perform(confirmation.action, confirmed: true) }
                .accessibilityIdentifier("ledger-agent-branch-continue")
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmationMessage(confirmation))
        }
        .sensoryFeedback(.success, trigger: copies)
        // An edit belongs to its conversation.
        .onChange(of: conversation.id) { _, _ in cancelEditing() }
        .onAppear {
            conversation.isOnScreen = true
            LedgerAgentBackgroundRun.shared.conversationSeen()
            resumeIfInterrupted()
        }
        .onDisappear { conversation.isOnScreen = false }
        // A turn the system cut short goes on by itself once the user is
        // back on this screen with the ledger unlocked.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resumeIfInterrupted()
                refreshInbox()
            }
            if phase == .background { awaySince = Date() }
            if phase == .active, let away = awaySince {
                awaySince = nil
                if Date().timeIntervalSince(away) >= Self.recapAfterAbsence { recapIfWanted() }
            }
        }
        // A conversation reopened from the history is recapped on arrival,
        // and an empty one offers fresh suggestions.
        .task(id: conversation.id) {
            if conversation.restored { recapIfWanted() }
            if conversation.messages.isEmpty { refreshStarters() }
        }
        .onChange(of: conversation.messages.count) { _, _ in
            predictNext()
            nameSession()
        }
        .onChange(of: session.privacyShielded) { _, shielded in
            if !shielded { resumeIfInterrupted() }
        }
        // A turn found dead after a freeze is interrupted while the user
        // may already be looking.
        .onChange(of: conversation.phase) { _, phase in
            if case .failed(.interrupted, _) = phase { resumeIfInterrupted() }
        }
        .task {
            guard crashReport == nil, let repository = session.localRepository else { return }
            crashReport = LedgerAgentCrashReport.take(
                runtimeRoot: repository.workspace.rootDirectory.appendingPathComponent("runtime"))
        }
        .task { refreshInbox() }
        .onChange(of: sessions.queuedQuestion) { _, _ in sendQueuedQuestion() }
        .onAppear { sendQueuedQuestion() }
        // Links in replies point into the ledger (a day's transactions, an
        // account, a search) and open the page they name.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "ledger" else { return .systemAction }
            session.openWidgetURL(url)
            return .handled
        })
        .accessibilityIdentifier("ledger-agent")
    }

    /// Sends the question Siri or a shortcut left for this screen, or puts it
    /// in the composer when it cannot be sent yet.
    private func sendQueuedQuestion() {
        guard let question = sessions.queuedQuestion else { return }
        sessions.queuedQuestion = nil
        if settings.isReady, !conversation.isRunning, !sessions.busyElsewhere, !session.privacyShielded,
           settings.hasKey {
            send(question, clearsComposer: false)
        } else {
            draft = question
        }
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

    /// The conversation's name once something was asked; 账本助手 before.
    private var headerTitle: String {
        guard settings.isReady, !conversation.messages.isEmpty else { return String(localized: "账本助手") }
        return sessions.title(of: conversation)
    }

    /// Tapping a named conversation's title renames it.
    private var headerTitleAction: TerminalTitleAction? {
        guard settings.isReady, !conversation.messages.isEmpty else { return nil }
        let id = conversation.id, name = headerTitle
        return TerminalTitleAction(hint: String(localized: "重命名这段对话")) { renaming = .init(id: id, shown: name) }
    }

    @State private var renaming: LedgerAgentRenameTarget?

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
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 16)).frame(width: 44, height: 44)
                        .foregroundStyle(BalancedPalette.ink)
                }
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("ledger-agent-close")
            }
        }
        .buttonStyle(.plain)
        .ledgerAgentRenameAlert($renaming)
    }

    // MARK: Conversation

    /// The 1-pt anchor under the last message is on screen; the jump button
    /// shows otherwise, except while the page is following a running turn.
    @State private var isAtBottom = false
    /// New content scrolls the page down to it. The reader scrolling up or
    /// opening a tool group or reasoning block turns this off; the page
    /// coming to rest at the bottom, the jump button or sending a question
    /// turns it back on. Content growing past the bottom never turns it off,
    /// so a burst of streamed text or a new tool row cannot leave the page
    /// stranded above the reply. A screen opens following only when it opens
    /// at the bottom, so a reopened conversation read from the top is not
    /// pulled down when its recap arrives.
    @State private var following = false
    /// The reader's finger, or a fling or scroll they started, is moving the
    /// page.
    @State private var readerScrolling = false
    /// The conversation is taller than the page. Until it is, the page rests
    /// at the top and following never scrolls it (`LedgerAgentScrollFit`).
    @State private var contentOverflows = false
    /// Before iOS 18, the measures `contentOverflows` is worked out from.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var showsJumpButton: Bool {
        // Not while the page is on its way down to a growing reply.
        !isAtBottom && !conversation.messages.isEmpty && !(following && conversation.isRunning)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if let crashReport { crashBand(crashReport) }
                    if conversation.messages.isEmpty && !conversation.isRunning { emptyState }
                    ForEach(conversation.messages) { message in
                        switch message.role {
                        case .user: question(message)
                        case .assistant: answer(message)
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
                    } else if let written = conversation.written,
                              conversation.messages.last(where: { $0.role == .assistant })?.write == nil {
                        // Written without a record to undo it by.
                        Label(String(localized: "已写入账本 · \(written.files.count) 个文件"), systemImage: "checkmark")
                            .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    }
                    if !conversation.isRunning, conversation.answerCount >= LedgerAgentRecap.minimumAnswers || conversation.recap != nil {
                        LedgerAgentRecapCard(recap: conversation.recap, isCurrent: conversation.recapIsCurrent,
                                             isWorking: conversation.recapping, error: conversation.recapError,
                                             onSummarize: summarize)
                    }
                    switch conversation.phase {
                    case .idle: EmptyView()
                    case let .running(since):
                        // The streamed turn once its first event is in; before
                        // that (preparing, or a core that does not stream) the
                        // step line with its elapsed and slow hints.
                        if let live = conversation.live, !live.isEmpty || live.compacting {
                            LedgerAgentLiveTimeline(turn: live, since: since, quietSince: conversation.stepSince ?? since,
                                                    following: following)
                        } else {
                            LedgerAgentRunning(step: conversation.step, steps: conversation.stepCount,
                                               since: since, stepSince: conversation.stepSince ?? since)
                        }
                    case let .failed(error, question): failure(error, question: question)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onAppear {
                            isAtBottom = true
                            // Reached without the reader moving the page (it
                            // opened here, or content shrank onto it); a
                            // scroll they are making decides when it ends.
                            if !readerScrolling { following = true }
                        }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if #available(iOS 18.0, *) { return }
                    contentHeight = height
                    measureFit()
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height - geometry.safeAreaInsets.top - geometry.safeAreaInsets.bottom
            } action: { height in
                if #available(iOS 18.0, *) { return }
                viewportHeight = height
                measureFit()
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(LedgerAgentScrollTracking(following: $following, scrolling: $readerScrolling,
                                                overflows: $contentOverflows, isAtBottom: isAtBottom) {
                // Rows, text and charts take their height after the update
                // that added them; follow that too while a turn runs.
                if conversation.isRunning { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            })
            // The conversation just outgrew the page: bring the bottom into
            // view once, from where it rested at the top.
            .onChange(of: contentOverflows) { _, overflows in
                if overflows, following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.messages.count) { _, _ in
                // Another version on screen: nothing was asked or answered,
                // and the user stays by the switch they tapped.
                guard !conversation.replacedByVersionChange else { return }
                let last = conversation.messages.last?.role
                // The question the user just sent is always shown.
                follow(proxy, force: last == .user)
                if last == .assistant, conversation.messages.last?.stopped == false { announceAnswer() }
            }
            // The reply growing while it streams is followed without an
            // animation per redraw.
            .onChange(of: conversation.live) { _, _ in
                if following, contentOverflows { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            // Opening a tool group or reasoning block is reading back: the
            // rows it shows stay where they were tapped.
            .environment(\.ledgerAgentFollowPause, LedgerAgentFollowPause { following = false })
            .onAppear {
                // A conversation still answering opens on its reply.
                guard conversation.isRunning else { return }
                following = true
                // Once, before the page has measured whether it overflows; a
                // single scroll does not bounce the way one per update did.
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: conversation.pending) { _, _ in follow(proxy) }
            .onChange(of: conversation.recap) { _, _ in follow(proxy) }
            .onChange(of: conversation.phase) { _, phase in
                if case let .failed(_, question) = phase, draft.isEmpty { draft = question }
                if case .running = phase {
                    // A question just sent follows its reply again.
                    following = true
                    follow(proxy, force: true)
                } else {
                    follow(proxy)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    if showsJumpButton {
                        jumpToBottom(proxy).transition(.opacity)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 10)
                .ledgerAnimation(LedgerMotion.disclose, value: showsJumpButton)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            // Bills and screenshots can also be dragged in from Photos, Files
            // or another window (iPad, or the Mac build).
            .onDrop(of: Self.dropTypes, isTargeted: $dropTargeted) { providers in
                guard !providers.isEmpty else { return false }
                attachDropped(providers)
                return true
            }
            .overlay { if dropTargeted { dropHint } }
        }
    }

    private func answer(_ message: LedgerAgentMessage) -> some View {
        let asksNow = message.id == conversation.messages.last?.id && !conversation.isRunning && !sessions.busyElsewhere
        let undoFailure = conversation.undoFailure?.message == message.id ? conversation.undoFailure?.text : nil
        return VStack(alignment: .leading, spacing: 6) {
            LedgerAgentAnswer(
                message: message,
                asksNow: asksNow,
                undoing: conversation.undoing == message.id,
                canUndo: conversation.canUndo(message),
                undoFailure: undoFailure,
                onMemory: { memoryPresented = true },
                onRecord: { bookkeeping = .init(text: question(before: message)) },
                onAnswer: { send($0, clearsComposer: false) },
                onAsk: { ask($0) },
                onUndo: { undo(message) })
            // No context menu over the answer: a long press there selects
            // its text, tool sources and errors, as everywhere else.
            answerActions(message)
        }
    }

    /// Copy, regenerate and share under a finished answer, and the switch
    /// between its versions when it was regenerated. A long press on copy
    /// offers the reply without its Markdown.
    private func answerActions(_ message: LedgerAgentMessage) -> some View {
        let versions = conversation.versions(of: message.id)
        return HStack(spacing: 0) {
            if !message.text.isEmpty {
                Menu {
                    Button { copy(LedgerAgentReplyText.plainText(message.text)) } label: {
                        Label("复制为纯文本", systemImage: "text.alignleft")
                    }
                } label: {
                    actionIcon("doc.on.doc")
                } primaryAction: {
                    copy(message.text)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("复制")
                .accessibilityAction(named: "复制为纯文本") { copy(LedgerAgentReplyText.plainText(message.text)) }
                .accessibilityIdentifier("ledger-agent-copy")
            }
            actionButton("重新生成", systemImage: "arrow.clockwise", identifier: "ledger-agent-regenerate") {
                perform(.regenerate(message.id))
            }
            .disabled(!canStartVersion)
            // Shared text carries the amounts the privacy mask hides.
            if session.amountsVisible, !message.text.isEmpty {
                ShareLink(item: message.text) { actionIcon("square.and.arrow.up") }
                    .accessibilityLabel("分享")
                    .accessibilityIdentifier("ledger-agent-share")
            }
            Spacer(minLength: 8)
            if versions.count > 1 {
                LedgerAgentVersionSwitch(index: versions.index, count: versions.count, enabled: conversation.canBranch) {
                    perform(.switchVersion(message.id, $0))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, -12)
        .accessibilityIdentifier("ledger-agent-answer-actions")
    }

    /// A question, with edit beside it, and the switch between its versions
    /// when it was edited. Its text stays selectable on a long press.
    private func question(_ message: LedgerAgentMessage) -> some View {
        let versions = conversation.versions(of: message.id)
        let earlierAnswers = conversation.answersBeside(message.id)
        return VStack(alignment: .trailing, spacing: 4) {
            LedgerAgentQuestion(text: message.text, attachments: message.attachments,
                                isEditing: editing == message.id)
            HStack(spacing: 4) {
                if editing != message.id, !conversation.isRunning {
                    Button { startEditing(message) } label: {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canStartVersion)
                    .accessibilityLabel("编辑后重新发送")
                    .accessibilityIdentifier("ledger-agent-edit-question")
                }
                // A regenerate that failed or stopped before replying leaves
                // the question without an answer; the earlier ones are kept.
                if earlierAnswers > 0, !conversation.isRunning {
                    Button { perform(.latestAnswer(message.id)) } label: {
                        Label("回到之前的回答", systemImage: "arrow.uturn.backward")
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                            .frame(minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!conversation.canBranch)
                    .accessibilityIdentifier("ledger-agent-latest-answer")
                }
                if versions.count > 1 {
                    LedgerAgentVersionSwitch(index: versions.index, count: versions.count, enabled: conversation.canBranch) {
                        perform(.switchVersion(message.id, $0))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func actionButton(_ label: LocalizedStringKey, systemImage: String, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { actionIcon(systemImage) }
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }

    private func actionIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
            .foregroundStyle(BalancedPalette.meta)
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copies += 1
    }

    // MARK: Versions

    /// Regenerating and editing start a turn, so they also wait for another
    /// conversation's turn and for files being attached.
    private var canStartVersion: Bool { conversation.canBranch && !sessions.busyElsewhere && !attaching }

    private var confirmingPresented: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    /// Regenerates, edits or switches; asks first when written answers or an
    /// unreviewed draft would be replaced. Nothing is ever written here.
    private func perform(_ action: BranchAction, confirmed: Bool = false) {
        let result: LedgerAgentBranchResult
        switch action {
        case let .regenerate(id):
            guard let reporting = turnReporting() else { return }
            result = conversation.regenerate(id, confirmed: confirmed, reporting: reporting)
        case let .edit(id, text):
            guard let reporting = turnReporting() else { return }
            result = conversation.editAndResend(id, newText: text, confirmed: confirmed, reporting: reporting)
        case let .switchVersion(id, direction):
            result = conversation.switchBranch(id, direction: direction, confirmed: confirmed)
        case let .latestAnswer(id):
            result = conversation.showLatestAnswer(of: id, confirmed: confirmed)
        }
        switch result {
        case let .needsConfirmation(warning): confirming = BranchConfirmation(action: action, warning: warning)
        case .started:
            if case .edit = action { finishEditing() }
        case .refused: break
        }
    }

    private func confirmationTitle(_ warning: LedgerAgentBranchWarning) -> String {
        warning.contains(.written) ? String(localized: "已写入的改动不会撤销") : String(localized: "丢弃未确认的草稿？")
    }

    private func confirmationMessage(_ confirmation: BranchConfirmation) -> String {
        var lines: [String] = []
        if confirmation.warning.contains(.written) {
            let written = switch confirmation.action {
            case .regenerate: String(localized: "这些回答已写入账本，重新生成不会撤销写入。可以先在对应回答上撤销。")
            case .edit: String(localized: "这些回答已写入账本，编辑后重新发送不会撤销写入。可以先在对应回答上撤销。")
            case .switchVersion, .latestAnswer:
                String(localized: "这些回答已写入账本，切换版本不会撤销写入。可以先在对应回答上撤销。")
            }
            lines.append(written)
        }
        if confirmation.warning.contains(.unreviewedDraft) {
            lines.append(String(localized: "停止的回答可能在草稿里留下了没有确认过的改动，继续会丢弃草稿，账本不变。"))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Puts the question in the composer; sending sends it as another
    /// version of that question.
    private func startEditing(_ message: LedgerAgentMessage) {
        guard canStartVersion else { return }
        if editing == nil { draftBeforeEdit = draft }
        editing = message.id
        draft = message.text
        composerFocused = true
    }

    /// Leaves the edit and gives the composer back what it held.
    private func cancelEditing() {
        guard editing != nil else { return }
        editing = nil
        draft = draftBeforeEdit
        draftBeforeEdit = ""
    }

    private func finishEditing() {
        editing = nil
        draft = draftBeforeEdit
        draftBeforeEdit = ""
    }

    /// The question being edited and its number, while it is on screen.
    private var editedQuestion: (id: UUID, number: Int)? {
        guard let editing, let number = conversation.questionNumber(editing) else { return nil }
        return (editing, number)
    }

    private var editBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
            Text("正在编辑第 \(editedQuestion?.number ?? 0) 个问题")
            Text("·").accessibilityHidden(true)
            Button("取消") { cancelEditing() }
                .buttonStyle(.plain)
                .foregroundStyle(BalancedPalette.ink)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .accessibilityLabel("取消编辑")
                .accessibilityIdentifier("ledger-agent-edit-cancel")
        }
        .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
        .padding(.horizontal, 6)
        .accessibilityIdentifier("ledger-agent-edit-banner")
    }

    private func follow(_ proxy: ScrollViewProxy, force: Bool = false) {
        // Content that fits already shows its bottom; scrolling it would
        // only shift the page and spring it back.
        guard force || following, contentOverflows else { return }
        scrollToBottom(proxy)
    }

    /// Before iOS 18 the page has no scroll geometry, so whether the content
    /// fits is measured from its frame; from iOS 18 `LedgerAgentScrollTracking`
    /// reads it off the scroll view.
    private func measureFit() {
        let overflows = LedgerAgentScrollFit.overflows(contentHeight: Double(contentHeight),
                                                       viewportHeight: Double(viewportHeight))
        if overflows != contentOverflows { contentOverflows = overflows }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withLedgerAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy) -> some View {
        Button {
            following = true
            readerScrolling = false
            scrollToBottom(proxy)
        } label: {
            Image(systemName: "arrow.down").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BalancedPalette.ink)
                .frame(width: 40, height: 40)
                // Glass on iOS 26; a page-coloured disc with a rule before.
                .background {
                    if !LedgerGlass.isAvailable {
                        Circle().fill(BalancedPalette.page).overlay(Circle().stroke(BalancedPalette.rule, lineWidth: 1))
                    }
                }
                .ledgerGlassControl()
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("回到底部")
        .accessibilityIdentifier("ledger-agent-jump-bottom")
    }

    /// VoiceOver hears that the answer landed while the user is on this
    /// screen; elsewhere the notification says so.
    private func announceAnswer() {
        guard conversation.isOnScreen, scenePhase == .active else { return }
        AccessibilityNotification.Announcement(String(localized: "回答好了")).post()
    }

    private static let dropTypes: [UTType] = [.image, .fileURL]

    private static let bottomID = "ledger-agent-bottom"

    /// A recap is written when the user comes back after this long.
    private static let recapAfterAbsence: TimeInterval = 10 * 60

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("想查什么？").balancedFont(size: 22, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                .padding(.top, 24)
            Text("可以查账，也可以让它改账；改动先进草稿，你确认后才写入。").balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                .padding(.top, 6)
            Text("点输入框左边的 ＋ 上传账单（CSV、Excel、PDF 或截图），它会和账本逐笔对账。").balancedFont(size: 13.5)
                .foregroundStyle(BalancedPalette.meta)
                .padding(.top, 4)
            HStack(alignment: .lastTextBaseline) {
                BalancedSectionLabel(text: String(localized: "试试"))
                Spacer()
                if starters.loading {
                    ProgressView().controlSize(.mini)
                } else if settings.assists {
                    Button { refreshStarters(force: true) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("换一批")
                    .accessibilityIdentifier("ledger-agent-starters-refresh")
                }
            }
            .padding(.top, 22)
            ForEach(starters.suggestions, id: \.self) { suggestion in
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
            Text(error.headline)
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
        case .interrupted:
            (LedgerAgentBackgroundRun.shared.interruptionCause.map { $0 + String(localized: "。") } ?? "")
                + String(localized: "草稿里已有的改动会保留，点重试接着做。")
        }
        return reason + " " + String(localized: "账本没有被写入，问题还在输入框里。")
    }

    /// Shift-Return on a hardware keyboard asked for the newline the field is
    /// about to get, so it is not read as Return.
    @State private var newlineRequested = false

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.busyElsewhere {
                Text("另一个对话正在回答，答完后才能在这里提问")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(.horizontal, 6)
            } else {
                LedgerAgentQuickSwitch(usage: conversation.usage) { settingsPresented = true }
                    .padding(.horizontal, 2)
            }
            if editedQuestion != nil { editBanner }
            if !conversation.staged.isEmpty || attaching || attachError != nil { stagedFiles }
            HStack(alignment: .bottom, spacing: 4) {
                attachMenu
                TextField(text: $draft, prompt: Text(ghost ?? placeholder)
                    .foregroundStyle(ghost == nil ? BalancedPalette.meta : BalancedPalette.edge), axis: .vertical) {
                    Text(placeholder)
                }
                    .balancedFont(size: 15)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    // Return sends and Shift-Return starts a new line; the
                    // software keyboard's Return arrives as a newline instead
                    // and is read in `composerChanged`.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            newlineRequested = true
                            return .ignored
                        }
                        submit()
                        return .handled
                    }
                    .padding(.vertical, 11)
                    .accessibilityIdentifier("ledger-agent-input")
                if let ghost {
                    // Puts the suggestion in the field for editing; the send
                    // button sends it as it is.
                    Button { draft = ghost; composerFocused = true } label: {
                        Image(systemName: "text.insert").font(.system(size: 14, weight: .medium))
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑建议：\(ghost)")
                    .accessibilityIdentifier("ledger-agent-ghost-edit")
                }
                Button {
                    if conversation.isRunning { conversation.stop() } else { submit() }
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
                .accessibilityIdentifier("ledger-agent-send")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 8))
        .ledgerGlassDock()
        // What was typed in a conversation waits there while the user looks
        // at another one.
        .onAppear { if draft.isEmpty { draft = sessions.unsentText(for: conversation.id) } }
        .onChange(of: draft) { old, new in composerChanged(old: old, new: new) }
    }

    /// Sends what the composer holds, or the suggestion shown in it.
    private func submit() {
        guard !conversation.isRunning, canSend else { return }
        if let edited = editedQuestion {
            perform(.edit(edited.id, draft))
            return
        }
        editing = nil
        send(draft.isEmpty ? ghost ?? "" : draft)
    }

    private func composerChanged(old: String, new: String) {
        let requested = newlineRequested
        newlineRequested = false
        let edit = LedgerAgentComposer.submission(old: old, new: new)
        // Return that cannot send right now keeps its newline, so the next
        // question can still be drafted over several lines.
        if edit.submit, !requested, !conversation.isRunning, canSend(edit.text) {
            draft = edit.text
            submit()
        }
        sessions.setUnsentText(draft, for: conversation.id)
    }

    private var placeholder: String {
        if !conversation.staged.isEmpty { return String(localized: "说说要对哪个账户，或直接发送") }
        return conversation.pending == nil ? String(localized: "问问账本，比如「上个月餐饮花了多少」")
            : String(localized: "还要怎么改…")
    }

    private var canSend: Bool { canSend(draft) }

    private func canSend(_ text: String) -> Bool {
        guard !sessions.busyElsewhere, !attaching else { return false }
        if editedQuestion != nil {
            return conversation.canBranch && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conversation.staged.isEmpty
            || ghost(for: text) != nil
    }

    /// The suggestion shown faintly in an empty composer: the likely next
    /// question after an answer, or the first starter in a new conversation.
    private var ghost: String? { ghost(for: draft) }

    private func ghost(for text: String) -> String? {
        guard settings.assists, text.isEmpty, conversation.staged.isEmpty, !conversation.isRunning,
              !sessions.busyElsewhere, editedQuestion == nil else { return nil }
        if conversation.messages.isEmpty { return starters.isDynamic ? starters.suggestions.first : nil }
        guard case .idle = conversation.phase else { return nil }
        return conversation.nextSuggestion
    }

    // MARK: Suggestions and recap

    private func refreshStarters(force: Bool = false) {
        guard settings.assists, settings.hasKey, let repository = session.localRepository, !session.privacyShielded,
              let key = try? settings.apiKey() else { return }
        let choice = settings.choice, usesMemory = settings.usesMemory
        let recent = sessions.recentQuestions()
        let workspace = repository.workspace
        let source = LedgerAgentStarters.Source(
            load: { await workspace.agentStarters().flatMap { try? LedgerAgentAssistCoding.decoder.decode(LedgerAgentStarterCache.self, from: $0) } },
            save: { cache in
                guard let data = try? LedgerAgentAssistCoding.encoder.encode(cache) else { return }
                try? await workspace.saveAgentStarters(data)
            },
            state: { await repository.agentStarterState() },
            fetch: { try await repository.agentStarterSuggestions(choice: choice, apiKey: key, recent: recent, usesMemory: usesMemory) })
        starters.refresh(ledger: repository.descriptor.id, source: source, force: force)
    }

    private func predictNext() {
        guard settings.assists, settings.hasKey, let repository = session.localRepository,
              let key = try? settings.apiKey() else { return }
        let choice = settings.choice, usesMemory = settings.usesMemory
        conversation.predictNext { history in
            try await repository.agentNextSuggestions(history: history, choice: choice, apiKey: key, usesMemory: usesMemory)
        }
    }

    /// Names the conversation once it has two answers, when the user allows
    /// the extra requests. An unnamed conversation keeps its first question
    /// as its name.
    private func nameSession() {
        guard settings.assists, settings.hasKey, conversation.generatedTitle == nil,
              let repository = session.localRepository, let key = try? settings.apiKey() else { return }
        let choice = settings.choice
        conversation.nameSession { history in
            try await repository.agentSessionTitle(history: history, choice: choice, apiKey: key)
        }
    }

    /// Recaps on its own only when the recap would add something and the
    /// user allows the extra requests.
    private func recapIfWanted() {
        guard settings.assists, conversation.wantsRecap, !session.privacyShielded else { return }
        summarize()
    }

    private func summarize() {
        guard settings.hasKey, let repository = session.localRepository, let key = try? settings.apiKey() else { return }
        let choice = settings.choice
        conversation.summarize { history in
            try await repository.agentRecap(history: history, choice: choice, apiKey: key)
        }
    }

    private static let reconcileQuestion = String(localized: "帮我把附件和账本对一下账，列出对不上的地方")

    // MARK: Attachments

    private var attachMenu: some View {
        Menu {
            Button { choosingFiles = true } label: { Label("选择文件（CSV、Excel、PDF）", systemImage: "doc") }
            Button { photoLibraryPresented = true } label: { Label("从相册选截图或照片", systemImage: "photo.on.rectangle") }
            if LedgerCameraPicker.isAvailable {
                Button { cameraPresented = true } label: { Label("拍照", systemImage: "camera") }
            }
            // Bills shared into Ledger from another app wait in the import
            // inbox; the assistant can reconcile them from there.
            if !inboxItems.isEmpty {
                Menu {
                    ForEach(inboxItems) { item in
                        Button(item.name) { attach([.inbox(item)]) }
                    }
                } label: {
                    Label("待导入收件箱里的账单", systemImage: "tray")
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                .foregroundStyle(BalancedPalette.ink)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!conversation.canAttach || attaching || conversation.isRunning)
        .accessibilityLabel("添加附件")
        .accessibilityIdentifier("ledger-agent-attach")
    }

    private var stagedFiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.staged) { file in
                    LedgerAgentAttachmentChip(name: file.name, symbol: file.symbol, detail: file.detail) {
                        conversation.unstage(file.id)
                    }
                }
                if attaching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取附件…").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                }
                if let attachError {
                    Button { self.attachError = nil } label: {
                        Label(attachError, systemImage: "exclamationmark.circle")
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                            .lineLimit(2)
                            .frame(maxWidth: 260, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("轻点关闭")
                }
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("ledger-agent-staged")
    }

    /// Shown while a drag hovers the conversation, so the user can let go.
    private var dropHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.badge.plus").font(.system(size: 24, weight: .medium))
            Text("松开以添加图片或账单").balancedFont(size: 14, weight: .medium)
        }
        .foregroundStyle(BalancedPalette.ink)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(BalancedPalette.edge, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BalancedPalette.page.opacity(0.6))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private enum Pick {
        case file(URL)
        case photo(PhotosPickerItem)
        /// An image dragged in from Photos or another app: only its bytes are
        /// available, with no file on disk to copy.
        case imageData(Data, suggestedName: String)
        case inbox(LedgerSharedImportInbox.Item)
    }

    /// Turns what another app is dragging into attachments. A drop carries
    /// either a file path (Files) or image bytes (Photos, Safari), so both are
    /// tried before an item is reported as unreadable.
    private func attachDropped(_ providers: [NSItemProvider]) {
        guard !attaching, !providers.isEmpty else { return }
        Task { @MainActor in
            var picks: [Pick] = []
            var unreadable: [String] = []
            for (index, provider) in providers.enumerated() {
                if let url = await Self.droppedFileURL(of: provider) {
                    picks.append(.file(url))
                } else if let data = await Self.droppedImageData(of: provider) {
                    picks.append(.imageData(data, suggestedName: Self.droppedName(of: provider, index: index)))
                } else {
                    unreadable.append(provider.suggestedName ?? String(localized: "第 \(index + 1) 个文件"))
                }
            }
            if !picks.isEmpty { attach(picks) }
            if !unreadable.isEmpty {
                attachError = LedgerAgentAttachmentError
                    .unreadable(unreadable.joined(separator: "、")).localizedDescription
            }
        }
    }

    private static func droppedFileURL(of provider: NSItemProvider) async -> URL? {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .fileURL) == true
        }) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func droppedImageData(of provider: NSItemProvider) async -> Data? {
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// A dropped image keeps the name the source app gave it, plus the
    /// extension its type implies, so the attachment chip reads like the file.
    private static func droppedName(of provider: NSItemProvider, index: Int) -> String {
        let type = provider.registeredTypeIdentifiers
            .compactMap { UTType($0) }
            .first { $0.conforms(to: .image) }
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let base = (provider.suggestedName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return String(localized: "拖入的图片") + " \(index + 1)." + ext }
        return (base as NSString).pathExtension.isEmpty ? base + "." + ext : base
    }

    /// Files shared into Ledger that are waiting in the import inbox.
    private func refreshInbox() {
        let items = (try? LedgerSharedImportInbox.appInbox().items()) ?? []
        let readable = items.filter { LedgerAgentAttachments.kind(of: $0.name) != nil }
        if readable != inboxItems { inboxItems = readable }
    }

    /// Undoes the change written after `message`. A reopened conversation
    /// has no editor until it asks something, so it gets one here.
    private func undo(_ message: LedgerAgentMessage) {
        guard let repository = session.localRepository, !session.privacyShielded else { return }
        if conversation.editor == nil { conversation.editor = .live(repository) }
        conversation.undo(message)
    }

    /// Copies the picked files into the conversation's attachment folder one
    /// by one, so each gets the next id, and reads PDFs and images on the way.
    private func attach(_ picks: [Pick]) {
        guard !attaching else { return }
        guard let repository = session.localRepository else {
            attachError = String(localized: "账本还没打开，暂时不能添加附件。")
            return
        }
        let conversation = conversation
        let workspace = repository.workspace
        attaching = true
        attachError = nil
        Task { @MainActor in
            defer { attaching = false }
            do {
                let directory = try await workspace.agentAttachmentDirectory(id: conversation.id)
                for (index, pick) in picks.enumerated() {
                    guard conversation.canAttach else { throw LedgerAgentAttachmentError.tooMany }
                    let id = LedgerAgentAttachments.nextID(after: conversation.allAttachments)
                    let attachment: LedgerAgentAttachment
                    switch pick {
                    case let .file(url):
                        attachment = try await LedgerAgentAttachments.importFile(at: url, id: id, into: directory)
                    case let .photo(item):
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw LedgerAgentAttachmentError.unreadable(String(localized: "照片没有可读取的数据"))
                        }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let name = String(localized: "图片\(index + 1)") + "." + ext
                        attachment = try await LedgerAgentAttachments.importImage(data, name: name, id: id, into: directory)
                    case let .imageData(data, suggestedName):
                        attachment = try await LedgerAgentAttachments
                            .importImage(data, name: suggestedName, id: id, into: directory)
                    case let .inbox(item):
                        guard let kind = LedgerAgentAttachments.kind(of: item.name) else {
                            throw LedgerAgentAttachmentError.unsupported(item.name)
                        }
                        let data = try LedgerSharedImportInbox.appInbox().read(item)
                        attachment = try await LedgerAgentAttachments.store(data, name: item.name, kind: kind, id: id, into: directory)
                    }
                    conversation.stage(attachment)
                }
                try? await workspace.protectAgentAttachments(id: conversation.id)
            } catch {
                attachError = error.localizedDescription
            }
        }
    }

    private func resumeIfInterrupted() {
        guard conversation.isOnScreen, scenePhase == .active, !session.privacyShielded, !sessions.busyElsewhere,
              !attaching, settings.hasKey, let question = conversation.takeResumableQuestion() else { return }
        send(question, clearsComposer: draft == question)
    }

    private func send(_ text: String, clearsComposer: Bool = true) {
        var question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty, !conversation.staged.isEmpty { question = Self.reconcileQuestion }
        guard !question.isEmpty, !conversation.isRunning, let reporting = turnReporting() else { return }
        let started = conversation.send(question, reporting: reporting)
        if started, clearsComposer { draft = "" }
    }

    /// How a turn of this conversation runs: the native loop over the local
    /// ledger with the chosen model. Sending, regenerating and editing share
    /// it. nil when no turn can start now.
    private func turnReporting() -> LedgerAgentConversation.SendReporting? {
        guard !sessions.busyElsewhere, !attaching else { return nil }
        guard let repository = session.localRepository, !session.privacyShielded else { return nil }
        let key: String
        do { key = try settings.apiKey() } catch {
            settingsPresented = true
            return nil
        }
        let choice = settings.choice, thinking = settings.effectiveThinking, usesMemory = settings.usesMemory
        let contextWindow = settings.contextWindow(for: choice), maxOutputTokens = settings.maxOutputTokens(for: choice)
        let conversation = conversation, conversationID = conversation.id
        let location = repository.workspace.agentAttachmentLocation(id: conversationID)
        conversation.editor = .live(repository)
        conversation.autoWrites = settings.autoWrites
        conversation.lifecycle = LedgerAgentBackgroundRun.shared
        LedgerAgentBackgroundRun.shared.concealsContent = session.localPrivacyProtectionEnabled
        LedgerAgentBackgroundRun.shared.keepsAwake = settings.keepsAwake
        return { message, history, draftRoot, report in
            // Read when the turn starts, not when it is asked: a turn stopped
            // just before may still be bringing back the transcript to follow,
            // and a regenerate or edit cuts it first and sends the question's
            // files again.
            let transcript = await conversation.transcript
            let attachments = await conversation.turnAttachmentPayloads(in: location)
            return try await repository.runAgentTurn(message: message, history: history, choice: choice,
                                              apiKey: key, sensitiveUnlocked: true, thinking: thinking,
                                              draft: draftRoot, transcript: transcript,
                                              conversationID: conversationID, attachments: attachments,
                                              usesMemory: usesMemory, contextWindow: contextWindow,
                                              maxOutputTokens: maxOutputTokens, onStep: report)
        }
    }

    /// Sends a visual's follow-up question, or leaves it in the composer
    /// when a turn is already running.
    private func ask(_ question: String) {
        if conversation.isRunning || sessions.busyElsewhere {
            draft = question
        } else {
            send(question, clearsComposer: false)
        }
    }

    private func question(before answer: LedgerAgentMessage) -> String {
        guard let index = conversation.messages.firstIndex(where: { $0.id == answer.id }) else { return "" }
        return conversation.messages[..<index].last { $0.role == .user }?.text ?? ""
    }
}

/// A question: right-aligned in the sunken well, never a bubble with a tail.
/// Files sent with it are listed above the text.
private struct LedgerAgentQuestion: View {
    let text: String
    var attachments: [String] = []
    /// The question is in the composer being edited.
    var isEditing = false
    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: LedgerAgentAttachments.kind(of: name) == .image ? "photo" : "doc")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(text).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BalancedPalette.sunken)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                if isEditing {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(BalancedPalette.ruleStrong, lineWidth: 1)
                }
            }
        }
    }
}

/// '‹ 2/3 ›' between the versions of a question or an answer.
private struct LedgerAgentVersionSwitch: View {
    let index: Int
    let count: Int
    var enabled = true
    let onStep: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            step(-1, systemImage: "chevron.left", label: "上一个版本")
                .disabled(!enabled || index == 0)
            Text(verbatim: "\(index + 1)/\(count)").balancedMono(size: 12).foregroundStyle(BalancedPalette.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
            step(1, systemImage: "chevron.right", label: "下一个版本")
                .disabled(!enabled || index >= count - 1)
        }
        .accessibilityIdentifier("ledger-agent-versions")
    }

    private func step(_ offset: Int, systemImage: String, label: LocalizedStringKey) -> some View {
        Button { onStep(offset) } label: {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BalancedPalette.meta)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(Text(verbatim: "\(index + 1) / \(count)"))
    }
}

/// A file waiting to be sent with the next question.
private struct LedgerAgentAttachmentChip: View {
    let name: String
    let symbol: String
    let detail: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(BalancedPalette.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).balancedFont(size: 13).foregroundStyle(BalancedPalette.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).balancedFont(size: 11).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }
            .frame(maxWidth: 180, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BalancedPalette.meta)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除 \(name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(minHeight: 44)
        .background(BalancedPalette.sunken)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// A reply on the page, with the reads behind it folded above.
private struct LedgerAgentAnswer: View {
    let message: LedgerAgentMessage
    /// The reply is the last message and nothing is running, so its choices
    /// can still be picked.
    var asksNow = false
    var undoing = false
    var canUndo = false
    var undoFailure: String? = nil
    var onMemory: () -> Void = {}
    let onRecord: () -> Void
    var onAnswer: (String) -> Void = { _ in }
    /// A follow-up question from a visual's button.
    var onAsk: (String) -> Void = { _ in }
    var onUndo: () -> Void = {}
    @State private var toolsExpanded = false
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if message.compacted {
                Text("已压缩较早的对话，以便继续").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("ledger-agent-compacted")
            }
            // Replies from older builds have only their tool calls.
            if !message.steps.isEmpty {
                LedgerAgentStepTimeline(steps: message.steps, duration: message.duration, onAsk: onAsk)
            } else if !message.toolCalls.isEmpty {
                tools
            }
            // A stopped reply reads as it did when stopped: a fence cut off
            // mid-chart stays prose rather than a block of broken JSON.
            ForEach(Array(LedgerAgentReplyText.segments(message.text, streaming: message.stopped).enumerated()),
                    id: \.offset) { _, segment in
                LedgerAgentReplyBlock(segment: segment, onAsk: onAsk)
            }
            if message.stopped {
                Text("已停止").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .accessibilityIdentifier("ledger-agent-stopped")
            }
            if let ask = message.ask, asksNow { choices(ask) }
            if LedgerAgentReplyText.beancountDraft(in: message.text) != nil {
                Button("用「记一笔」录入", action: onRecord).buttonStyle(.balanced(.outline))
                    .accessibilityIdentifier("ledger-agent-record")
            }
            if let write = message.write { writeRow(write) }
            if message.rememberedMemory {
                Button(action: onMemory) {
                    Label("已更新记忆", systemImage: "brain")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看和编辑记忆")
                .accessibilityIdentifier("ledger-agent-memory-updated")
            }
            if let footer { Text(footer).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta) }
        }
    }

    /// The options of an `ask_user` card. One tap answers a single choice;
    /// several choices are ticked, then sent together.
    private func choices(_ ask: LedgerAgentAsk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ask.options, id: \.self) { option in
                Button {
                    if ask.allowsMultiple {
                        if picked.contains(option) { picked.remove(option) } else { picked.insert(option) }
                    } else {
                        onAnswer(option)
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
                .accessibilityIdentifier("ledger-agent-choice")
            }
            HStack(spacing: 10) {
                Text(ask.allowsMultiple ? String(localized: "可多选；也可以直接在下面输入") : String(localized: "也可以直接在下面输入"))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                Spacer(minLength: 8)
                if ask.allowsMultiple {
                    Button("发送") { onAnswer(ask.answer(picked)) }
                        .buttonStyle(.balanced(.primary))
                        .disabled(picked.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(BalancedPalette.sunken)
        .accessibilityIdentifier("ledger-agent-ask")
    }

    /// What was written after this reply, with the way back.
    private func writeRow(_ write: LedgerAgentWriteRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if write.undoneAt != nil {
                    Label(String(localized: "已撤销这次写入 · \(write.files.count) 个文件"), systemImage: "arrow.uturn.backward")
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                } else {
                    Label(String(localized: "已写入账本 · \(write.files.count) 个文件"), systemImage: "checkmark")
                        .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                    Spacer(minLength: 8)
                    Button(action: onUndo) {
                        if undoing { ProgressView().controlSize(.small) } else { Text("撤销") }
                    }
                    .buttonStyle(.balanced(.quiet))
                    .disabled(!canUndo)
                    .accessibilityIdentifier("ledger-agent-undo")
                }
            }
            if let undoFailure {
                Text(undoFailure).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                    .textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("ledger-agent-written")
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

    private var toolsSummary: String { LedgerAgentProcess.toolSummary(message.toolCalls) }

    private var footer: String? {
        guard let duration = message.duration else { return nil }
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        let tools = message.steps.isEmpty ? message.toolCalls.count : message.steps.filter { $0.kind == .tool }.count
        return tools == 0
            ? String(localized: "\(seconds) 秒")
            : String(localized: "\(tools) 次工具调用 · \(seconds) 秒")
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
        case .conflict: String(localized: "和账本的新改动冲突")
        case .invalid: String(localized: "草稿没有通过校验")
        default: String(localized: "改动 \(pending.review?.files.count ?? 0) 个文件")
        }
    }

    private var note: String {
        switch pending.status {
        case .ready: String(localized: "校验通过。写入时会再校验一次，并生成一个可撤回的提交。")
        case .writing: String(localized: "正在写入…")
        case let .invalid(message): message + "\n" + String(localized: "可以让助手接着修，或者放弃草稿。")
        case let .conflict(paths): String(localized: "对话期间账本有了新的改动，和草稿改到了同一处：\(paths.joined(separator: "、"))。可以让助手基于最新账本重改这些地方，或者放弃草稿。")
        case let .failed(message): String(localized: "没有写入：") + message
        }
    }

    private var noteColor: Color {
        switch pending.status {
        case .invalid, .conflict, .failed: BalancedPalette.expense
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
struct LedgerAgentReplyBlock: View {
    let segment: LedgerAgentReplyText.Segment
    var onAsk: (String) -> Void = { _ in }
    /// Counts copies of a code block, for the haptic.
    @State private var copies = 0

    var body: some View {
        switch segment {
        case let .prose(text):
            prose(text)
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(BalancedReading.font(.semibold, size: level == 1 ? 20 : level == 2 ? 18 : 16.5, relativeTo: .headline))
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
                            .balancedFont(size: BalancedReading.size, weight: item.marker.hasSuffix(".") ? .medium : .regular)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                        copies += 1
                    } label: {
                        Label("复制", systemImage: "doc.on.doc").balancedFont(size: 12)
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制代码")
                    .accessibilityIdentifier("ledger-agent-code-copy")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).balancedMono(size: 12.5).foregroundStyle(BalancedPalette.ink)
                        .textSelection(.enabled)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .balancedBand()
            .sensoryFeedback(.success, trigger: copies)
        case let .chart(chart):
            LedgerAgentChartView(chart: chart)
        case let .visual(visual):
            LedgerAgentVisualView(visual: visual, onAsk: onAsk)
        }
    }

    private func prose(_ text: String, color: Color = BalancedPalette.ink) -> some View {
        Text(Self.inline(text, serif: true)).font(BalancedReading.font()).foregroundStyle(color)
            .lineSpacing(BalancedReading.lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline Markdown. In serif runs, `**bold**` is pinned to the bundled
    /// Semibold face instead of letting the system synthesise a Bold that
    /// isn't shipped; CJK inside it still falls back to PingFang.
    private static func inline(_ text: String, serif: Bool = false) -> AttributedString {
        let text = LedgerAgentReplyText.encodingLedgerLinks(text)
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in string.runs where run.link != nil {
            string[run.range].underlineStyle = .single
        }
        guard serif else { return string }
        for run in string.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            // The face carries the weight; drop the intent so SwiftUI doesn't
            // synthesise a heavier Bold on top of Semibold.
            var intent = run.inlinePresentationIntent ?? []
            intent.remove(.stronglyEmphasized)
            string[run.range].inlinePresentationIntent = intent.isEmpty ? nil : intent
            string[run.range].font = BalancedReading.font(.semibold)
        }
        return string
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

/// The running turn: what it is doing, for how long, and, once a step has
/// been quiet for a while, that stopping and asking again is an option.
private struct LedgerAgentRunning: View {
    let step: LedgerAgentStep?
    /// Model calls and tools so far.
    let steps: Int
    let since: Date
    let stepSince: Date

    /// A step quiet this long gets the hint.
    private static let slowAfter = LedgerAgentLiveTimeline.slowAfter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).tint(BalancedPalette.meta).padding(.top, 2)
            TimelineView(.periodic(from: since, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(since).rounded(.down))
                let quiet = context.date.timeIntervalSince(stepSince)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(step?.title ?? String(localized: "正在准备")).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                            .lineLimit(1)
                        Text("\(max(elapsed, 0)) 秒").balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                    }
                    // Which step, and how long this one has been going, so a
                    // slow model reads as slow rather than stuck.
                    if steps > 0 {
                        Text("第 \(steps) 步 · 这一步 \(max(Int(quiet.rounded(.down)), 0)) 秒")
                            .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                    }
                    if quiet >= Self.slowAfter {
                        Text("模型这一步比较慢。网络不好时可以点停止，再发一次。")
                            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                    } else {
                        Text("可以离开这一页或切到后台，答完会通知你").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ledger-agent-running")
    }
}

/// Turns following off when the reader scrolls up and back on when they
/// leave the page at the bottom. iOS 18 sees the scroll phases and the
/// real distance to the bottom, and reports content growing while
/// following; before it, a drag up pauses following until a drag down ends
/// at the bottom anchor or the anchor comes back on screen.
private struct LedgerAgentScrollTracking: ViewModifier {
    @Binding var following: Bool
    /// The reader is moving the page.
    @Binding var scrolling: Bool
    /// The content is taller than the page (iOS 18; the view measures it
    /// before).
    @Binding var overflows: Bool
    /// The bottom anchor is on screen (the only measure before iOS 18).
    let isAtBottom: Bool
    /// The content grew while following, past the page's height.
    let onGrow: () -> Void

    /// Within this many points of the bottom still counts as at it.
    private static let slack: CGFloat = 24

    /// The page's whole height, the parts under the top bar and the composer
    /// included, which the content insets are measured against.
    /// `containerSize` and `bounds` leave the insets out (with the keyboard
    /// up they are a third of the page), so adding the insets to the content
    /// and comparing with them made a two-line chat "overflow" and left the
    /// bottom hundreds of points away even when the page was resting on it.
    @available(iOS 18.0, *)
    private static func pageHeight(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.visibleRect.height
    }

    private struct Position: Equatable {
        var offset: CGFloat
        var toBottom: CGFloat
    }

    private struct Extent: Equatable {
        var height: CGFloat
        var overflows: Bool
    }

    /// How far the page is from its bottom, measured on every move; nil
    /// until it first moves, when only the anchor says.
    @State private var toBottom: CGFloat?
    /// Any scroll is under way: the reader's, or one the system animates
    /// (a tap on the status bar).
    @State private var inMotion = false
    /// The reader has moved the page since it last came to rest.
    @State private var moved = false
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .onScrollGeometryChange(for: Position.self) { geometry in
                    let bottom = geometry.contentSize.height + geometry.contentInsets.bottom - Self.pageHeight(geometry)
                    return Position(offset: geometry.contentOffset.y, toBottom: bottom - geometry.contentOffset.y)
                } action: { old, new in
                    toBottom = new.toBottom
                    // Moving up and away from the bottom by any means other
                    // than a drag (the status bar, VoiceOver, a pointer) is
                    // reading back too. The app's own scrolls only go down,
                    // and layout settling at rest is not a scroll.
                    if inMotion, new.offset < old.offset - 1, new.toBottom > Self.slack { following = false }
                }
                .onScrollGeometryChange(for: Extent.self) { geometry in
                    Extent(height: geometry.contentSize.height,
                           overflows: LedgerAgentScrollFit.overflows(
                               contentHeight: Double(geometry.contentSize.height),
                               topInset: Double(geometry.contentInsets.top),
                               bottomInset: Double(geometry.contentInsets.bottom),
                               viewportHeight: Double(Self.pageHeight(geometry))))
                } action: { old, new in
                    if new.overflows != overflows { overflows = new.overflows }
                    // Content that still fits rests at the top: a scroll to
                    // its bottom only shifts the page and springs it back.
                    if new.height > old.height, new.overflows, following { onGrow() }
                }
                .onScrollPhaseChange { _, phase in
                    inMotion = phase != .idle
                    switch phase {
                    // A finger resting on the page (.tracking), or a tap on a
                    // control in it, is not reading back.
                    case .interacting:
                        moved = true
                        scrolling = true
                        following = false
                    case .decelerating:
                        moved = true
                        scrolling = true
                    case .idle:
                        scrolling = false
                        // Where the reader left the page decides; a scroll the
                        // app animated (.animating) does not count.
                        if moved {
                            moved = false
                            following = toBottom.map { $0 <= Self.slack } ?? isAtBottom
                        }
                    default:
                        break
                    }
                }
        } else {
            content
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        // A finger moving down the screen scrolls back up.
                        if value.translation.height > 0 { following = false }
                    }
                    .onEnded { value in
                        // The anchor also counts as shown behind the composer
                        // or keyboard, so only a drag toward the bottom that
                        // ends by it resumes.
                        if isAtBottom, value.translation.height <= 0 { following = true }
                    })
                // A cancelled drag never ends, but its state still resets.
                .onChange(of: dragging) { _, now in scrolling = now }
        }
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
        Ability(title: String(localized: "改账（草稿确认后写入）"), detail: String(localized: "改分类、补记漏记、删重复，先改草稿，你确认后才写入")),
        Ability(title: String(localized: "附件对账"), detail: String(localized: "上传 CSV、Excel、PDF 或截图，和账本逐笔核对")),
        Ability(title: String(localized: "记忆"), detail: String(localized: "记住你的偏好和常用账户，只存在本机")),
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
                Text("改账时先改一份草稿，改动以卡片给你过目，点「写入账本」并通过校验后才会写入。需要你自己的模型 API Key，费用记在你的模型账户上。")
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
            Section {
                NavigationLink {
                    LedgerAgentMemoryView()
                } label: {
                    Label("记忆", systemImage: "brain")
                }
                .accessibilityIdentifier("ledger-agent-memory")
                Toggle("使用记忆", isOn: Binding(get: { settings.usesMemory }, set: { settings.setUsesMemory($0) }))
                    .accessibilityIdentifier("ledger-agent-uses-memory")
                Toggle("智能建议、回顾与命名", isOn: Binding(get: { settings.assists }, set: { settings.setAssists($0) }))
                    .accessibilityIdentifier("ledger-agent-assists")
            } header: { Text("记忆与建议") } footer: {
                Text("记忆是这本账的 memory.md：你的偏好、常用的账户和分类、常做的事。助手每次回答都会读，你说「记住」或纠正它时会自己更新。只存在本机，不随 Git 同步。智能建议会根据账本和记忆生成「试试」、在输入框里预测下一句、回来时总结对话，并在聊过两句后给这段对话起一个名字，每次都是一个不带思考的小请求。")
            }
            Section {
                Toggle("后台保持运行", isOn: Binding(get: { settings.keepsAwake }, set: { settings.setKeepsAwake($0) }))
                    .accessibilityIdentifier("ledger-agent-keep-awake")
            } header: { Text("后台") } footer: {
                Text("回答期间在后台播放无声音频，锁屏后助手也能一直做完，不影响你正在听的音乐。关掉后只能用系统给的后台时间，较长的回答可能被中断；被中断的回答回到 App 时会自动接着做。")
            }
            Section {
                Toggle("改完自动写入", isOn: Binding(get: { settings.autoWrites }, set: { settings.setAutoWrites($0) }))
                    .accessibilityIdentifier("ledger-agent-auto-write")
            } header: { Text("写入") } footer: {
                Text("打开后，助手的改动通过校验就直接写入账本，不再弹出确认卡片。每次写入都是一个单独的提交，回答下方的「撤销」可以把它退回去。和账本新改动冲突或校验没通过时，仍然停下来让你处理。")
            }
            Section("发给模型的内容") {
                Text("你的问题、本次对话，以及助手调用工具后得到的结果（例如汇总金额、匹配到的流水）。不会发送整本账本文件，也不会发送 Git 凭据或本机路径。")
            }
            Section {
                tool(String(localized: "汇总与搜索流水"), "get_ledger_summary · search_transactions")
                tool(String(localized: "BQL 查询"), "run_bql · validate_bql · get_bql_capabilities")
                tool(String(localized: "账户"), "get_accounts")
                tool(String(localized: "向你提问（选项卡）"), "ask_user")
                tool(String(localized: "改账（只改草稿）"),
                     "list_files · grep_files · read_file · edit_file · write_file · copy_file · move_file · delete_file · draft_changes · bean_check")
                if settings.usesMemory { tool(String(localized: "记忆"), "edit_memory · write_memory") }
                tool(String(localized: "附件"),
                     "list_attachments · read_attachment · reconcile_attachment · view_attachment_image · save_attachment")
                tool(String(localized: "历史对话"), "list_saved_conversations · read_saved_conversation")
            } header: { Text("可用工具") } footer: {
                Text("查询工具只读账本。改账工具只改一份私有草稿，改动卡片上点「写入账本」并通过校验后才写入；打开「改完自动写入」时校验通过即写入。附件工具在对话附了文件时才有，看图需要模型支持图片。")
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
    /// The conversation's latest usage; the meter shows once it is known.
    var usage: LedgerAgentUsage? = nil
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
            if let usage, usage.fraction != nil { LedgerAgentContextMeter(usage: usage) }
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
#endif
