#if os(iOS)
import Charts
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 账本助手 — a conversation over the local ledger. It opens as a chat, not a
/// page: no heading over the conversation, round buttons on the bar (history
/// left, 新对话 and model settings right), a greeting for the time of day with
/// the recommended starters when nothing has been asked yet, and a floating
/// capsule dock at the bottom. The mark over the greeting is the app's own,
/// never a model provider's.
/// The design is `docs/design/ios-balanced/agent.html`: questions sit in a
/// sunken block on the right, replies run on the page with a collapsible list
/// of the reads behind them. The Agent edits a private draft of the ledger;
/// the change card under the conversation is the only way that draft reaches
/// the ledger. History and the thinking effort follow
/// `docs/design/ios-balanced/agent-history.html`.
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
                    // After the bind, so AI 开账's greeting opens the new
                    // ledger's conversation instead of being dropped as the
                    // previous ledger's.
                    sessions.takeOpening()
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
    @StateObject private var voice = LedgerAgentVoiceRecorder()
    /// How the current dictation was started: by a tap, which keeps the
    /// recording bar in the dock until ✓, ✗ or send, or by holding the
    /// microphone button, which inserts on release.
    @State private var voiceMode: VoiceMode = .idle
    /// When the finger touched the microphone button, while it is down.
    @State private var voicePress: Date?
    /// The field's text before dictation began; the transcript is joined to
    /// it, so cancelling gives it back untouched.
    @State private var voiceBase = ""
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
        // No heading over a conversation: the bar is a row of round buttons,
        // the way the assistant reads as a chat rather than a page. History
        // sits on the left, 新对话 and model settings on the right; a
        // conversation's name and its rename live in the history drawer, where
        // the sessions are.
        .terminalPageChrome(String(localized: "账本助手"), isRoot: isRoot, showsSync: false,
                            actions: AnyView(actions), balanced: true, showsTitle: false,
                            leadingActions: settings.isReady ? AnyView(historyButton) : nil)
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
        // History is a drawer over the page, not a sheet. It is applied
        // after the chrome so it covers the top bar and the dock as well.
        .ledgerAgentHistoryDrawer(isPresented: $historyPresented, sharesText: session.amountsVisible) {
            settingsPresented = true
        }
        .onChange(of: historyPresented) { _, shown in if shown { composerFocused = false } }
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
            greetingNow = Date()
        }
        .onDisappear { conversation.isOnScreen = false }
        // A turn the system cut short goes on by itself once the user is
        // back on this screen with the ledger unlocked.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resumeIfInterrupted()
                refreshInbox()
                // The empty state's greeting is read from this clock, so a
                // page left open across 11:00, 13:00 or 18:00 says the right
                // thing when the user comes back instead of at launch.
                greetingNow = Date()
            }
            if phase == .background { awaySince = Date() }
            if phase == .active, let away = awaySince {
                awaySince = nil
                if Date().timeIntervalSince(away) >= Self.recapAfterAbsence { recapIfWanted() }
            }
        }
        // A conversation reopened from the history is recapped on arrival,
        // and an empty one offers fresh suggestions — unless they are hidden,
        // in which case fetching them would be a model call nobody reads.
        .task(id: conversation.id) {
            if conversation.restored { recapIfWanted() }
            if conversation.messages.isEmpty, settings.suggestions { refreshStarters() }
            // Answers that landed while another conversation was on screen
            // get their name here.
            nameSession()
        }
        .onChange(of: conversation.messages.count) { _, _ in
            predictNext()
            nameSession()
        }
        // Turning the recommendations back on fills the empty state again;
        // the starters are cached per ledger, so this is only a fetch the
        // first time.
        .onChange(of: settings.suggestions) { _, on in
            if on, conversation.messages.isEmpty { refreshStarters() }
        }
        .onChange(of: session.privacyShielded) { _, shielded in
            if !shielded {
                resumeIfInterrupted()
                nameSession()
            }
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

    /// 40pt round glass control, 16pt from the screen edge, as a chat app's
    /// floating top buttons are; before iOS 26 it is a sunken disc.
    private func circleButton(_ systemImage: String, label: LocalizedStringKey, identifier: String,
                              drawsGlass: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
                .foregroundStyle(BalancedPalette.ink)
                .frame(width: 40, height: 40)
                .background {
                    if !LedgerGlass.isAvailable { Circle().fill(BalancedPalette.sunken) }
                }
                .modifier(LedgerAgentCircleGlass(draws: drawsGlass))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var historyButton: some View {
        circleButton("line.3.horizontal", label: "历史对话", identifier: "ledger-agent-history") {
            historyPresented = true
        }
    }

    /// Nothing asked, nothing running and no draft waiting: the conversation
    /// as it is when the page opens or after 新对话. One opened from history
    /// has messages, so it is never fresh.
    private var conversationIsFresh: Bool {
        conversation.messages.isEmpty && !conversation.isRunning && conversation.pending == nil
    }

    /// The first button follows the conversation, then settings, then the
    /// close button when the assistant is a full-screen sheet. A fresh
    /// conversation has nothing to leave behind, so its first button is the
    /// app's own amount privacy (the same `toggleAmounts` as every other
    /// page's eye, not a separate "do not keep this chat" mode); once there
    /// is something on the page it becomes 新对话, one tap from the
    /// conversation it replaces.
    private var actions: some View {
        HStack(spacing: 0) {
            // The bar's trailing cluster already supplies one glass capsule
            // for its controls, so these are plain buttons inside it.
            if conversationIsFresh {
                circleButton(session.amountsVisible ? "eye.slash" : "eye",
                             label: session.amountsVisible ? "隐藏金额" : "显示金额",
                             identifier: "ledger-agent-privacy", drawsGlass: false) {
                    LedgerFeedback.selection()
                    session.toggleAmounts()
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                circleButton("square.and.pencil", label: "新对话", identifier: "ledger-agent-new",
                             drawsGlass: false) {
                    sessions.startNew()
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            circleButton("slider.horizontal.3", label: "助手设置", identifier: "ledger-agent-settings",
                         drawsGlass: false) {
                settingsPresented = true
            }
            if let onClose {
                circleButton("xmark", label: "关闭", identifier: "ledger-agent-close", drawsGlass: false,
                             action: onClose)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: conversationIsFresh)
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
    /// The height the conversation rests in, so the empty state can sit in
    /// the middle of the page rather than at its top.
    @State private var emptyHeight: CGFloat = 0
    /// When the empty state last read the clock for its greeting.
    @State private var greetingNow = Date()

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
                emptyHeight = height
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
                undoingSettings: conversation.undoingSettings == message.id,
                canUndoSettings: conversation.canUndoAppSettings(message),
                onMemory: { memoryPresented = true },
                onRecord: { bookkeeping = .init(text: question(before: message)) },
                onAnswer: { send($0, clearsComposer: false) },
                onAsk: { ask($0) },
                onUndo: { undo(message) },
                onUndoSettings: { conversation.undoAppSettings(message) })
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
            if case .edit = action {
                finishEditing()
                composerSent()
            }
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

    /// The page before the first question: the app's own mark, a greeting
    /// for the time of day, one question that carries it on, and the starters
    /// as pills, all on one centre line. The mark is the launch screen's
    /// (`LedgerMarkCanvas`, drawn finished), not a model provider's. The
    /// starters, and the refresh beside them, follow the 显示推荐问题 switch.
    private var emptyState: some View {
        VStack(spacing: 8) {
            // The mark fills the middle 40 of its 64-unit canvas, centred, so
            // a 60pt frame draws it about 38pt across and leaves 11pt of its
            // own margin above the greeting; the negative padding takes back
            // the stack's spacing so that margin is the whole gap. A fixed
            // size: it is a mark, not text, and a centred column keeps it
            // over the greeting at any type size.
            LedgerMarkCanvas(progress: 1)
                .frame(width: 60, height: 60)
                .padding(.bottom, -8)
                .accessibilityHidden(true)
            Text(Self.greeting(at: greetingNow))
                // The reading serif, as claude.ai sets its replies: Source
                // Serif 4 for Latin, falling through to PingFang for CJK.
                .font(BalancedReading.font(.regular, size: 30, relativeTo: .title))
                .foregroundStyle(BalancedPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Text("今天想查点什么？").balancedFont(size: 15)
                .foregroundStyle(BalancedPalette.meta)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            if settings.suggestions, settings.assists || !starters.suggestions.isEmpty {
                HStack(spacing: 4) {
                    Text("试试").balancedFont(size: 12.5, weight: .medium)
                        .foregroundStyle(BalancedPalette.meta)
                    if starters.loading {
                        ProgressView().controlSize(.mini)
                    } else if settings.assists {
                        Button { refreshStarters(force: true) } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(BalancedPalette.meta)
                                .frame(width: 32, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("换一批")
                        .accessibilityIdentifier("ledger-agent-starters-refresh")
                    }
                }
                .padding(.top, 14)
                ForEach(starters.suggestions, id: \.self) { suggestion in
                    Button { send(suggestion) } label: {
                        Text(suggestion)
                            .balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Capsule().fill(BalancedPalette.sunken))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(0, emptyHeight - 52), alignment: .center)
        .padding(.vertical, 16)
    }

    /// The empty state's greeting. Only the hour matters, and only the user's
    /// own clock: 05-11 早上好, 11-13 中午好, 13-18 下午好, 18-05 晚上好.
    /// `greetingNow` is refreshed on appear and on every return to the
    /// foreground, so the boundary is crossed when the page is looked at
    /// again rather than frozen at launch.
    private static func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: String(localized: "早上好")
        case 11..<13: String(localized: "中午好")
        case 13..<18: String(localized: "下午好")
        default: String(localized: "晚上好")
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

    /// The dock is in use: the field is or has been focused, or there is
    /// something to send (a draft, a question being edited, an attachment
    /// chosen or being read). It is two rows then, and one row otherwise.
    ///
    /// A tap in the field opens the second row at once, before anything is
    /// typed, and `composerOpened` keeps it open from then on: the keyboard
    /// going away, or a menu on that row taking focus, does not fold it.
    /// Only a question going out folds it again (`composerSent`).
    private var composerExpanded: Bool {
        composerOpened || composerFocused || !draft.isEmpty || editedQuestion != nil
            || !conversation.staged.isEmpty || attaching || voiceDocked
    }

    /// The field has been focused since the last question went out.
    @State private var composerOpened = false

    /// A question went out: the dock returns to one row. The focus goes with
    /// it, since a focused field is an open dock, so the keyboard comes down
    /// and the answer has the page.
    private func composerSent() {
        composerOpened = false
        composerFocused = false
    }

    /// The floating dock, 16pt in from either edge. At rest it is one row:
    /// the attach circle, the field and the solid send circle. With
    /// something to send it grows a second row under the field with the model and thinking chip
    /// and the context meter, and the field takes the row's whole width. The
    /// send circle is one view pinned to the bottom trailing corner in both
    /// states, so it never moves or changes identity; each row leaves room
    /// for it in turn. The hints and attachment chips above stay outside the
    /// dock, and the whole stack rides the keyboard through `safeAreaInset`.
    private var composer: some View {
        VStack(spacing: 8) {
            if sessions.busyElsewhere {
                Text("另一个对话正在回答，答完后才能在这里提问")
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if editedQuestion != nil { editBanner }
            if !conversation.staged.isEmpty || attaching || attachError != nil { stagedFiles }
            if let failure = voice.failure { voiceFailureNotice(failure) }
            VStack(spacing: 4) {
                HStack(alignment: .bottom, spacing: 4) {
                    attachMenu
                    composerField
                    if let ghost {
                        // Puts the suggestion in the field for editing; the
                        // send button sends it as it is.
                        Button { draft = ghost; composerFocused = true } label: {
                            Image(systemName: "text.insert").font(.system(size: 14, weight: .medium))
                                .foregroundStyle(BalancedPalette.meta)
                                .frame(width: 32, height: 40)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("编辑建议：\(ghost)")
                        .accessibilityIdentifier("ledger-agent-ghost-edit")
                    }
                    if !voiceDocked, !conversation.isRunning { voiceButton }
                }
                .padding(.trailing, composerExpanded ? 0 : Self.sendReserve)
                if composerExpanded {
                    // Not in the hierarchy at rest, so nothing empty is left
                    // for VoiceOver or a keyboard to land on.
                    if voiceDocked {
                        LedgerVoiceBar(recorder: voice, onCancel: cancelVoice, onConfirm: { Task { await commitVoice() } })
                            .frame(minHeight: 40)
                            .transition(.opacity)
                    } else {
                        LedgerAgentQuickSwitch(usage: conversation.usage) { settingsPresented = true }
                            .frame(minHeight: 40)
                            .padding(.leading, 4)
                            .padding(.trailing, Self.sendReserve)
                            .transition(.opacity)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) { sendButton }
            .padding(8)
            .modifier(LedgerAgentDock())
            .overlay(alignment: .top) {
                // Over the dock rather than in the stack, so it does not move
                // the conversation while the button is held.
                if voiceMode == .hold, voice.phase == .recording {
                    LedgerVoicePill(recorder: voice)
                        .offset(y: -60)
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                }
            }
        }
        // The dock is anchored to the bottom, so the second row opens upward
        // under the field. Only this change is animated here; the keyboard
        // moves the inset with the system's own animation.
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: composerExpanded)
        .onChange(of: composerFocused) { _, focused in if focused { composerOpened = true } }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 4)
        // What was typed in a conversation waits there while the user looks
        // at another one.
        .onAppear { if draft.isEmpty { draft = sessions.unsentText(for: conversation.id) } }
        .onChange(of: draft) { old, new in composerChanged(old: old, new: new) }
        .onChange(of: voice.transcript) { _, text in
            if voice.isActive { draft = LedgerVoiceTranscript.merged(base: voiceBase, transcript: text) }
        }
        .onChange(of: voice.phase) { _, phase in voicePhaseChanged(phase) }
        // A recording does not outlive the screen it was made on: leaving the
        // app keeps what was heard, leaving the page drops it.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, voice.isActive { Task { await commitVoice() } }
        }
        .onDisappear { if voice.isActive { cancelVoice() } }
    }

    /// The send circle's 40pt and the row's 4pt gap before it.
    private static let sendReserve: CGFloat = 44

    private var composerField: some View {
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
    }

    private var sendButton: some View {
        Button {
            if conversation.isRunning {
                conversation.stop()
            } else if voice.isActive {
                // What was said so far goes out as it stands.
                Task { await commitVoice(); submit() }
            } else {
                submit()
            }
        } label: {
            Image(systemName: conversation.isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BalancedPalette.page)
                .frame(width: 40, height: 40)
                .background(Circle().fill(BalancedPalette.ink))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!conversation.isRunning && !canSend)
        .opacity(!conversation.isRunning && !canSend ? 0.38 : 1)
        .accessibilityLabel(conversation.isRunning ? "停止" : "发送")
        .accessibilityIdentifier("ledger-agent-send")
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
        // The same 显示推荐问题 switch as the empty state's starters: hiding
        // the recommendations but leaving one floating in the field would
        // contradict the switch, so the field keeps only its placeholder.
        guard settings.suggestions, settings.assists, text.isEmpty, conversation.staged.isEmpty,
              !conversation.isRunning, !sessions.busyElsewhere, editedQuestion == nil else { return nil }
        if conversation.messages.isEmpty { return starters.isDynamic ? starters.suggestions.first : nil }
        guard case .idle = conversation.phase else { return nil }
        return conversation.nextSuggestion
    }

    // MARK: Suggestions and recap

    private func refreshStarters(force: Bool = false) {
        // Hidden recommendations are not fetched either: this is the only
        // path that spends a model call on the starters.
        guard settings.suggestions, settings.assists, settings.hasKey, let repository = session.localRepository,
              !session.privacyShielded, let key = try? settings.apiKey() else { return }
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
        // Only the composer's ghost reads the prediction, so it follows the
        // same switch: no ghost, no request.
        guard settings.suggestions, settings.assists, settings.hasKey, let repository = session.localRepository,
              let key = try? settings.apiKey() else { return }
        let choice = settings.choice, usesMemory = settings.usesMemory
        conversation.predictNext { history in
            try await repository.agentNextSuggestions(history: history, choice: choice, apiKey: key, usesMemory: usesMemory)
        }
    }

    /// Names the conversation once it has two answers, when the user allows
    /// the extra requests and is not hiding amounts. An unnamed conversation
    /// keeps its first question as its name.
    private func nameSession() {
        guard settings.assists, settings.hasKey, !session.privacyShielded, conversation.generatedTitle == nil,
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

    // MARK: Voice

    private enum VoiceMode: Equatable {
        case idle
        /// The finger is down and has not yet stayed long enough to be a hold.
        case pressing
        case dock
        case hold
    }

    /// The recording bar is in the dock.
    private var voiceDocked: Bool { voiceMode == .dock && voice.isActive }

    /// How long the button must stay down to be a hold rather than a tap.
    private static let voiceHoldDelay: Duration = .milliseconds(300)

    /// One button for both ways in: a tap starts a recording the dock keeps
    /// until it is confirmed, and holding records only while the finger is
    /// down. Recording starts on touch-down either way, so no first word is
    /// lost to the decision.
    private var voiceButton: some View {
        Image(systemName: "mic").font(.system(size: 16, weight: .medium))
            .foregroundStyle(BalancedPalette.secondary)
            .frame(width: 36, height: 40)
            .contentShape(Rectangle())
            .opacity(sessions.busyElsewhere ? 0.38 : 1)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if voicePress == nil { voicePressBegan() } }
                    .onEnded { _ in voicePressEnded() })
            .accessibilityElement()
            .accessibilityLabel("语音输入")
            .accessibilityHint("双击开始录音，再点完成")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { startVoice(mode: .dock) }
            .accessibilityIdentifier("ledger-agent-voice")
    }

    private func voicePressBegan() {
        guard !voice.isActive, !sessions.busyElsewhere else { return }
        voicePress = Date()
        startVoice(mode: .pressing)
        Task {
            try? await Task.sleep(for: Self.voiceHoldDelay)
            if voicePress != nil, voiceMode == .pressing { voiceMode = .hold }
        }
    }

    private func voicePressEnded() {
        guard voicePress != nil else { return }
        voicePress = nil
        switch voiceMode {
        case .hold: Task { await commitVoice() }
        case .pressing: voiceMode = .dock
        case .idle, .dock: break
        }
    }

    private func startVoice(mode: VoiceMode) {
        guard !voice.isActive, !conversation.isRunning, !sessions.busyElsewhere else { return }
        voiceMode = mode
        voiceBase = draft
        composerOpened = true
        composerFocused = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await voice.start() }
    }

    private func voicePhaseChanged(_ phase: LedgerAgentVoiceRecorder.Phase) {
        switch phase {
        case .idle:
            voiceMode = .idle
            voicePress = nil
        case .recording:
            // The permission sheet took the finger away before it was
            // released: nobody is holding any more, so the recording stays.
            if voiceMode == .hold, voicePress == nil { voiceMode = .dock }
        case .starting, .finishing:
            break
        }
    }

    /// Stops recording and leaves the text in the field, after what was
    /// already there.
    private func commitVoice() async {
        guard voice.isActive else { return }
        let text = await voice.finish()
        draft = LedgerVoiceTranscript.merged(base: voiceBase, transcript: text)
        voiceMode = .idle
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func cancelVoice() {
        voice.cancel()
        draft = voiceBase
        voiceMode = .idle
    }

    private func voiceFailureNotice(_ failure: LedgerAgentVoiceRecorder.Failure) -> some View {
        Button {
            if failure.opensSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            voice.dismissFailure()
        } label: {
            Label(failure.message, systemImage: "mic.slash")
                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint(failure.opensSettings ? "轻点打开系统设置" : "轻点关闭")
        .accessibilityIdentifier("ledger-agent-voice-error")
    }

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
            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                .foregroundStyle(BalancedPalette.ink)
                .frame(width: 40, height: 40)
                // The dock is the field; this disc is the one thing inside it,
                // as the attachment circle sits inside the reference's capsule.
                .background(Circle().fill(BalancedPalette.sunken))
                .contentShape(Circle())
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
        if started, clearsComposer {
            draft = ""
            composerSent()
        }
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
        // Read when the turn is asked for, like the model: the page may have
        // been open in another sheet since.
        let disabledSkills = LedgerAgentSkillSettings.shared.disabled
        // The App's own settings travel with the turn, so the assistant can
        // read and change them; the conversation applies what it changed.
        let appSettings = LedgerAgentAppSettings.load(valuationCurrency: session.ledger?.valuationCurrency ?? "CNY")
        let conversation = conversation, conversationID = conversation.id
        let location = repository.workspace.agentAttachmentLocation(id: conversationID)
        conversation.editor = .live(repository)
        conversation.writePolicy = settings.writePolicy
        conversation.appSettings = .live(session)
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
                                              maxOutputTokens: maxOutputTokens, disabledSkills: disabledSkills,
                                              appSettings: appSettings,
                                              onStep: report)
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
    var undoingSettings = false
    var canUndoSettings = false
    var onMemory: () -> Void = {}
    let onRecord: () -> Void
    var onAnswer: (String) -> Void = { _ in }
    /// A follow-up question from a visual's button.
    var onAsk: (String) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onUndoSettings: () -> Void = {}
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
            if let settings = message.settings {
                LedgerAgentSettingsChangeRow(change: settings, undoing: undoingSettings, canUndo: canUndoSettings,
                                             undoFailure: undoFailure, onUndo: onUndoSettings)
            }
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
        case .ready:
            let validation = String(localized: "校验通过。写入时会再校验一次，并生成一个可撤回的提交。")
            return pending.holdReason.map { $0 + "\n" + validation } ?? validation
        case .writing: return String(localized: "正在写入…")
        case let .invalid(message): return message + "\n" + String(localized: "可以让助手接着修，或者放弃草稿。")
        case let .conflict(paths): return String(localized: "对话期间账本有了新的改动，和草稿改到了同一处：\(paths.joined(separator: "、"))。可以让助手基于最新账本重改这些地方，或者放弃草稿。")
        case let .failed(message): return String(localized: "没有写入：") + message
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
        Ability(title: String(localized: "改账"), detail: String(localized: "改分类、补记漏记、删重复；校验通过就写入，可以撤销")),
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
                Text("改账时先改一份草稿，校验通过后直接写入，每次都是一个可以撤销的提交；删除文件或大量删改会先请你确认。需要你自己的模型 API Key，费用记在你的模型账户上。")
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

/// The composer's second row: starred models and the current model's
/// thinking levels, each one tap away, drawn as one chip that reads
/// "model effort" with a menu under each half, and the context meter at the
/// trailing end. A turn already running keeps the model and effort it was
/// sent with.
private struct LedgerAgentQuickSwitch: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    /// The conversation's latest usage; the meter shows once it is known.
    var usage: LedgerAgentUsage? = nil
    var manage: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Menu { models } label: {
                    half(settings.modelTitle, tint: BalancedPalette.ink, leading: 12, trailing: 4)
                }
                .accessibilityLabel(String(localized: "模型：\(settings.modelTitle)"))
                .accessibilityIdentifier("ledger-agent-quick-model")
                Menu { thinking } label: {
                    half(settings.effectiveThinking.title, tint: BalancedPalette.meta, leading: 4, trailing: 12)
                }
                // A long model name gives way before the effort does.
                .layoutPriority(1)
                .accessibilityLabel(String(localized: "思考强度：\(settings.effectiveThinking.title)"))
                .accessibilityIdentifier("ledger-agent-quick-thinking")
            }
            // A tint rather than the sunken fill, which is what the dock
            // itself is drawn in before iOS 26.
            .background(Capsule().fill(BalancedPalette.meta.opacity(0.1)))
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
            Button(action: manage) { Label("助手设置…", systemImage: "slider.horizontal.3") }
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

    /// One half of the chip; the two share the capsule drawn behind them.
    private func half(_ title: String, tint: Color, leading: CGFloat, trailing: CGFloat) -> some View {
        Text(verbatim: title).lineLimit(1)
            .balancedFont(size: 13)
            .foregroundStyle(tint)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
    }
}

/// Glass for a round bar control. The trailing cluster draws one capsule for
/// its controls already, so a button inside it passes `false`.
private struct LedgerAgentCircleGlass: ViewModifier {
    var draws: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if draws { content.ledgerGlassControl() } else { content }
    }
}

/// The composer's floating dock: glass on iOS 26, the sunken well the
/// earlier system uses elsewhere. Its corner is half the one-row height, so
/// at rest it is a capsule, and it keeps that corner when the second row or
/// a multi-line draft makes it taller; a true capsule that tall would cut
/// into the chip and the send circle in its corners.
private struct LedgerAgentDock: ViewModifier {
    private static let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Self.shape)
        } else {
            content
                .background(Self.shape.fill(BalancedPalette.sunken))
                .overlay(Self.shape.stroke(BalancedPalette.rule, lineWidth: 1))
        }
    }
}

#endif
