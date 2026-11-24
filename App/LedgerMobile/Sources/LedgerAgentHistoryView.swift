#if os(iOS)
import SwiftUI
import UIKit

/// Saved conversations of this ledger, as the content of the drawer that
/// opens beside the chat from the left: a serif title with search beside it,
/// 已置顶 then 最近 (the rest, in the order of `LedgerAgentHistoryGroup`), and
/// 新对话 at the bottom. Picking a conversation switches the screen to it; a
/// running one keeps running. A row can be renamed, pinned, shared as plain
/// text or deleted from its context menu, and pinned by a swipe from the
/// left. A drag to the left anywhere on it closes the drawer, so rows have
/// no swipe from the right.
struct LedgerAgentHistoryView: View {
    /// Whether amounts are on screen; a conversation is not shared as text
    /// while privacy protection masks them.
    var sharesText: Bool
    /// How many times the drawer has gone all the way in; a search is put
    /// away each time.
    var closings: Int
    /// Closes the drawer, opens 助手设置, or opens one of the places at the
    /// top of the drawer on the chat page's navigation stack.
    var actions: LedgerAgentDrawerActions
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @ObservedObject private var automations = LedgerAutomationCenter.shared
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var confirmingClear = false
    @State private var renaming: LedgerAgentRenameTarget?

    private func close() { actions.close() }

    var body: some View {
        // Grouped once per update: a search reads every message.
        let groups = LedgerAgentHistoryGroup.grouping(sessions.saved.filter { $0.matches(query) })
        let pinned = groups.first { $0.kind == .pinned }?.items ?? []
        // Everything not pinned, newest first, as the groups order it.
        let recent = groups.filter { $0.kind != .pinned }.flatMap(\.items)
        return VStack(spacing: 0) {
            header
            List {
                // Claude puts its places (项目, Code, …) above the
                // conversations; these are the assistant's. A search is about
                // conversations, so they step aside while one is typed.
                if query.isEmpty {
                    ForEach(LedgerAgentDrawerRoute.available) { route in place(route) }
                }
                if sessions.saved.isEmpty {
                    note("还没有历史对话。问过的问题会按账本存在本机。")
                } else if groups.isEmpty {
                    note("没有匹配的对话。")
                }
                if !pinned.isEmpty {
                    sectionTitle("已置顶")
                    ForEach(pinned) { item in entry(item) }
                }
                if !recent.isEmpty {
                    sectionTitle("最近")
                    ForEach(recent) { item in entry(item) }
                }
                if !sessions.saved.isEmpty {
                    note("对话跟着账本存在本机，不进 Git 同步、备份或导出。置顶的对话不会因为数量太多被自动清理。")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("ledger-agent-history-list")
            // FlowDown's list ends above its footer instead of running
            // under it.
            footer
        }
        .privacySensitive()
        // New runs of the scheduled tasks join the history below.
        .task { automations.refreshIfStale() }
        .confirmationDialog("清空这本账本的全部历史对话？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { sessions.deleteAll() }
        }
        .ledgerAgentRenameAlert($renaming)
        .onChange(of: closings) { _, _ in
            searchFocused = false
            searching = false
            query = ""
        }
    }

    // MARK: Header

    /// The title, or the search field in its place, and the round button
    /// that swaps them. Closing the search clears it.
    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LedgerAgentPalette.meta)
                        .accessibilityHidden(true)
                    TextField("搜索标题、问题和回答", text: $query)
                        .balancedFont(size: 15)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ledger-agent-history-search-field")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Capsule().fill(LedgerAgentHistoryDrawer.selectedFill))
                .transition(.opacity)
            } else {
                Text("账本助手")
                    .font(BalancedReading.font(.regular, size: 24, relativeTo: .title))
                    .foregroundStyle(LedgerAgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            // FlowDown's header: the name, and 新对话 as a round floating
            // button beside it. A search under way puts its close there.
            Button {
                if searching {
                    searching = false
                    query = ""
                } else {
                    sessions.startNew()
                    close()
                }
            } label: {
                Image(systemName: searching ? "xmark" : "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LedgerAgentPalette.ink)
                    .frame(width: 44, height: 44)
                    .background {
                        if !LedgerGlass.isAvailable { Circle().fill(LedgerAgentHistoryDrawer.selectedFill) }
                    }
                    .ledgerGlassControl()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searching ? "关闭搜索" : "新对话")
            .accessibilityIdentifier(searching ? "ledger-agent-history-search-close" : "ledger-agent-new")
        }
        .animation(.easeInOut(duration: 0.18), value: searching)
        // Claude's sidebar sets its title on the line of the page's round
        // buttons, a little further out than the rows.
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: Rows

    /// 已置顶 and 最近, a size under the rows in the quiet colour, with the
    /// room of about one row above it and less below, so it belongs to the
    /// rows it heads.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .balancedFont(size: 14).foregroundStyle(LedgerAgentPalette.meta)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 18, leading: 24, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A place: its symbol and name, set like a conversation row.
    private func place(_ route: LedgerAgentDrawerRoute) -> some View {
        Button {
            // Pushed over the open drawer, which closes out of sight once
            // the page covers it (`onDisappear` below): closing it while the
            // page came in ran two slides at once.
            actions.openRoute(route)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: route.symbol).font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LedgerAgentPalette.ink)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                Text(route.title).balancedFont(size: 17).foregroundStyle(LedgerAgentPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if route == .automations, automations.unseen > 0 {
                    Text(verbatim: "\(automations.unseen)")
                        .balancedFont(size: 12, weight: .medium)
                        .foregroundStyle(LedgerAgentPalette.page)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Capsule().fill(LedgerAgentPalette.ink))
                        .accessibilityLabel("\(automations.unseen) 次新运行")
                }
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("ledger-agent-drawer-\(route.rawValue)")
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .balancedFont(size: 13).foregroundStyle(LedgerAgentPalette.meta)
            .listRowInsets(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func entry(_ item: LedgerAgentSavedConversation) -> some View {
        Button {
            sessions.open(item.id)
            close()
        } label: { row(item) }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 22))
        .listRowSeparator(.hidden)
        // The conversation on screen sits on a sunken block, inset 14pt
        // from the drawer's edges like Claude's selected row.
        // The selected row: a rounded pill, as FlowDown's.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(item.id == sessions.current.id ? LedgerAgentHistoryDrawer.selectedFill : Color.clear)
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
        )
        .accessibilityAddTraits(item.id == sessions.current.id ? .isSelected : [])
        .contextMenu { menu(item) }
        // Only from the left: a drag to the left closes the drawer, and
        // deleting is in the menu a long press opens.
        .swipeActions(edge: .leading) {
            Button { sessions.setPinned(item.id, item.pinnedAt == nil) } label: { pinLabel(item) }
                .tint(LedgerAgentPalette.secondary)
        }
    }

    @ViewBuilder private func menu(_ item: LedgerAgentSavedConversation) -> some View {
        Button { renaming = .init(id: item.id, shown: item.title) } label: { Label("重命名", systemImage: "pencil") }
        Button { sessions.setPinned(item.id, item.pinnedAt == nil) } label: { pinLabel(item) }
        if sharesText {
            ShareLink(item: item.plainTextExport()) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        if !isRunning(item.id) {
            Divider()
            Button(role: .destructive) { sessions.delete(item.id) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func pinLabel(_ item: LedgerAgentSavedConversation) -> some View {
        item.pinnedAt == nil ? Label("置顶", systemImage: "pin") : Label("取消置顶", systemImage: "pin.slash")
    }

    private func isRunning(_ id: UUID) -> Bool {
        (sessions.current.id == id && sessions.current.isRunning) || (sessions.background?.id == id && sessions.background?.isRunning == true)
    }

    /// One line: a bubble and the title, cut at the tail, both in ink as in
    /// Claude's sidebar, the title starting 60pt in. A conversation that is
    /// answering shows a spinner at the end, and one holding a change not
    /// yet written shows a dot.
    private func row(_ item: LedgerAgentSavedConversation) -> some View {
        HStack(spacing: 12) {
            // A conversation a scheduled task began shows a clock.
            Image(systemName: item.automationRun == nil ? "bubble.left" : "clock")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(LedgerAgentPalette.ink)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(item.title).balancedFont(size: 17).foregroundStyle(LedgerAgentPalette.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if isRunning(item.id) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在回答…")
            } else if item.unwrittenChange {
                Circle().fill(LedgerAgentPalette.secondary).frame(width: 7, height: 7)
                    .accessibilityElement()
                    .accessibilityLabel("有未写入的草稿改动")
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    // MARK: Footer

    private func footerSymbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .regular))
            .foregroundStyle(LedgerAgentPalette.ink)
            .frame(width: 32, height: 32)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// FlowDown's footer: settings at the leading end and search at the
    /// trailing end, two plain 32pt symbols with nothing between them. The
    /// settings button's menu also holds 清空历史. Rows scrolling under them
    /// fade into the page.
    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    close()
                    actions.openSettings()
                } label: { Label("助手设置…", systemImage: "slider.horizontal.3") }
                if !sessions.saved.isEmpty {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label("清空历史", systemImage: "trash")
                    }
                }
            } label: {
                footerSymbol("gearshape")
            }
            .accessibilityLabel("设置")
            .accessibilityIdentifier("ledger-agent-history-more")
            Spacer(minLength: 0)
            Button {
                searching = true
                searchFocused = true
            } label: {
                footerSymbol("magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(searching)
            .accessibilityLabel("搜索")
            .accessibilityIdentifier("ledger-agent-history-search")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

extension View {
    /// The history drawer of a chat page, the way Claude's sidebar works: it
    /// is 80% of the page wide (400pt at most) and pushes the page to the
    /// right, which becomes a card with rounded corners under a light dim.
    /// A drag to the right that starts anywhere on the page opens it under
    /// the finger when `edgeOpens`; a tap on the card, a drag to the left
    /// anywhere on the drawer or the card, or the VoiceOver escape closes
    /// it. A finger can catch it mid-animation either way. In a regular width
    /// the page stays put and the drawer slides over it. The page is hidden
    /// from assistive technology while the drawer is open.
    func ledgerAgentHistoryDrawer(isPresented: Binding<Bool>, edgeOpens: Bool, sharesText: Bool,
                                  openSettings: @escaping () -> Void,
                                  openRoute: @escaping (LedgerAgentDrawerRoute) -> Void) -> some View {
        modifier(LedgerAgentHistoryDrawer(isPresented: isPresented, edgeOpens: edgeOpens, sharesText: sharesText,
                                          openSettings: openSettings, openRoute: openRoute))
    }
}

/// The places at the top of the drawer, pushed on the chat page's stack:
/// the built-in Linux's terminal and files when the engine is in this
/// build, then the scheduled task runs and the assistant's artifacts, skills
/// and memory.
enum LedgerAgentDrawerRoute: String, Identifiable, Hashable, CaseIterable {
    case terminal, files, automations, artifacts, skills, memory

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .terminal: "终端"
        case .files: "Linux 文件"
        case .automations: "定时任务"
        case .artifacts: "产物"
        case .skills: "技能"
        case .memory: "记忆"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .files: "folder"
        case .automations: "clock.arrow.circlepath"
        case .artifacts: "rectangle.stack"
        case .skills: "book.pages"
        case .memory: "brain"
        }
    }

    static var available: [LedgerAgentDrawerRoute] {
        LedgerLinuxMachine.engineAvailable ? allCases : [.automations, .artifacts, .skills, .memory]
    }
}

/// What the drawer's content does on its own: close, open 助手设置, open a
/// place. Kept in one box the drawer creates once, so the history list sees
/// the same value on every frame of a drag and is not rebuilt while the
/// finger moves (closures never compare equal, so passing them directly
/// re-ran the list's body on every frame).
@MainActor
final class LedgerAgentDrawerActions {
    var close: () -> Void = {}
    var openSettings: () -> Void = {}
    var openRoute: (LedgerAgentDrawerRoute) -> Void = { _ in }
}

/// Where the drawer was last sent by an animation, so a finger that grabs it
/// mid-flight starts from where it is on screen rather than from where the
/// animation is going. Not observed: reading it never redraws anything.
@MainActor
private final class LedgerAgentDrawerMotion {
    private var from: Double = 0
    private var to: Double = 0
    /// In points per second.
    private var velocity: Double = 0
    private var start: CFTimeInterval = 0
    private var running = false
    /// The position under the finger when the drag in progress began.
    var dragBase: CGFloat = 0
    /// The finger's speed at the end of the last drag, for the animation
    /// that the change of `isPresented` starts.
    var releaseSpeed: CGFloat = 0
    /// The open drag in progress has already tapped, on passing the point
    /// where letting go opens the drawer.
    var tickedThisDrag = false
    /// The drag in progress went far enough to decide: the drawer is already
    /// on its way, and the rest of that drag moves nothing.
    var committed = false
    /// The next settle jumps to its place without animating: the drawer
    /// is out of sight under a pushed page.
    var instant = false

    /// FlowDown's sidebar spring: half a second, damping 0.9.
    static let spring = Spring(duration: 0.5, bounce: 0.1)
    /// A drag this far opens or closes the drawer at once, as FlowDown's
    /// sidebar does: the finger only has to say which way, and the spring
    /// carries the drawer the rest of the way.
    static let commitDistance: CGFloat = 100
    /// How far the drawer starts left of its place, so it slides in a little
    /// under the page rather than lying still.
    static let parallax: CGFloat = 70

    func began(from: CGFloat, to: CGFloat, velocity: CGFloat) {
        self.from = from
        self.to = to
        self.velocity = velocity
        start = CACurrentMediaTime()
        running = true
    }

    func stop() { running = false }

    /// Where the running animation has the drawer now, if one is running.
    func presented() -> CGFloat? {
        guard running else { return nil }
        let time = CACurrentMediaTime() - start
        guard time < Self.spring.settlingDuration else { return nil }
        let moved = Self.spring.value(target: to - from, initialVelocity: velocity, time: time)
        return from + moved
    }
}

struct LedgerAgentHistoryDrawer: ViewModifier {
    @Binding var isPresented: Bool
    var edgeOpens: Bool
    var sharesText: Bool
    var openSettings: () -> Void
    var openRoute: (LedgerAgentDrawerRoute) -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pageWidth: CGFloat = 0
    /// How far the drawer is out, from 0 (closed) to `width` (open). A
    /// finger sets it directly; letting go or a tap animates it.
    @State private var reveal: CGFloat = 0
    /// The drawer is in the view tree. It comes in the first time the drawer
    /// starts to open and then stays, drawn only while it is out: building
    /// the list on every open was the hitch at the start of the slide, and
    /// taking it away at the end of the close flashed the strip behind it.
    @State private var loaded = false
    /// Counts the moments the drawer comes out, for the haptic tap.
    @State private var openTicks = 0
    /// Counts the times the drawer has gone all the way in, so the list can
    /// put away a search when it is out of sight.
    @State private var closings = 0
    /// The drawer is drawn: from the moment it starts to come out until a
    /// close has come all the way to rest. `reveal` alone cannot say, since
    /// an animated close sets it to 0 at the start and only the drawing
    /// moves; going by it took the drawer's ground and the card's corners
    /// away at once (the drawer faded out over the slide), and the strip
    /// behind them flashed while the page slid back.
    @State private var drawn = false
    @State private var motion = LedgerAgentDrawerMotion()
    @State private var actions = LedgerAgentDrawerActions()
    /// The page is drawn back into a card, as FlowDown's chat is while its
    /// sidebar is open. It follows `isPresented`, never the finger: a drag
    /// only moves the page sideways until it commits, as FlowDown's does.
    @State private var carded = false

    private static let overShape = UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28,
                                                          style: .continuous)
    /// FlowDown's chat card beside its sidebar: 28pt corners, 20pt in
    /// from the safe area at the top and the bottom.
    private static let cardRadius: CGFloat = 28
    private static let cardInset: CGFloat = 20
    /// The drawer's ground: FlowDown's page colour, so the sidebar and the
    /// card are one surface told apart by the card's shadow alone.
    static let fill = LedgerAgentPalette.page
    /// The selected row and the search field on that ground.
    static let selectedFill = LedgerAgentPalette.selected

    /// FlowDown leaves 60pt of the card on screen beside its sidebar on a
    /// phone; a wider window keeps a drawer of at most 400pt.
    private var width: CGFloat { pushes ? max(0, pageWidth - 60) : min(pageWidth * 0.8, 400) }
    /// The dim over the pushed page (compact) or the page under the sliding
    /// drawer (regular), at the drawer fully out.
    private var veilStrength: CGFloat {
        guard pushes else { return colorScheme == .dark ? 0.45 : 0.2 }
        // FlowDown leaves its chat card undimmed: the card and its shadow
        // are enough to tell it from the sidebar, and a grey card is what
        // made the page look like a second, muddier layer.
        return 0
    }
    /// Compact width pushes the page aside; regular width slides the drawer
    /// over it, since the system navigation bar there would not move.
    private var pushes: Bool { sizeClass != .regular }
    private var progress: CGFloat { width > 0 ? min(1, max(0, reveal / width)) : 0 }
    /// Anything of the drawer is on screen.
    private var isOut: Bool { drawn || reveal > 0.5 || isPresented }
    private var cardedPage: Bool { pushes && carded }

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .accessibilityHidden(isPresented)
                .environment(\.ledgerAgentDrawerOpen, isPresented)
                // FlowDown's card: the page lays itself out again 20pt inside
                // the safe area at the top and the bottom. Only a padding:
                // the safe area itself is left to the system, since taking
                // it over by hand fed back into the page's layout and hung
                // the app.
                .padding(.vertical, cardedPage ? Self.cardInset : 0)
                // The card's outline is drawn over the page rather than cut
                // out of it: a clip left the page's scroll view, a UIKit
                // view, with square corners and its edge effect showing
                // above the card. Everything outside the rounded card is
                // painted in the drawer's ground, with the shadow on top.
                .overlay {
                    if pushes && isOut {
                        LedgerAgentCardFrame(radius: cardedPage ? Self.cardRadius : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay { if isOut { cover } }
                .background {
                    LedgerAgentDrawerPan(
                        mode: !(width > 0) ? .off : isPresented ? .closes : (edgeOpens ? .opens : .off),
                        began: dragBegan, changed: dragChanged, ended: dragEnded)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                .offset(x: pushes ? reveal : 0)
            if loaded {
                drawer.zIndex(pushes ? -1 : 1)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: openTicks)
        .onChange(of: isPresented) { _, shown in
            if shown && !motion.tickedThisDrag { openTicks += 1 }
            motion.tickedThisDrag = false
            let speed = motion.releaseSpeed
            motion.releaseSpeed = 0
            settle(speed: speed)
        }
        .onChange(of: width) { _, _ in if isPresented { reveal = width } }
        .onAppear {
            actions.close = { [isPresented = $isPresented] in isPresented.wrappedValue = false }
            actions.openSettings = openSettings
            actions.openRoute = openRoute
            if isPresented { settle(speed: 0) }
        }
        // A page pushed from the drawer now covers it: it closes where it
        // cannot be seen, so a swipe back lands on the conversation.
        .onDisappear {
            guard isPresented else { return }
            motion.instant = true
            isPresented = false
        }
    }

    private var drawer: some View {
        LedgerAgentHistoryView(sharesText: sharesText, closings: closings, actions: actions)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(alignment: .leading) {
                if pushes {
                    // As wide as the screen and then some: the page's rounded
                    // corners and a spring's last point past the open
                    // position show this ground, never what lies behind it.
                    Rectangle().fill(Self.fill)
                        .frame(width: max(pageWidth, width) + 60)
                        .ignoresSafeArea()
                } else {
                    Self.overShape.fill(Self.fill)
                        .shadow(color: .black.opacity(0.18), radius: 24, x: 8, y: 0)
                        .ignoresSafeArea()
                }
            }
            // Compact width: the drawer slides in a little under the page as
            // the page is drawn aside. Regular width: it slides in whole.
            .offset(x: pushes ? (progress - 1) * LedgerAgentDrawerMotion.parallax : reveal - width)
            // Under the opaque page it would only cost drawing.
            .opacity(isOut ? 1 : 0)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { isPresented = false }
    }

    /// Over the page while the drawer is out: the dim that closes the drawer
    /// on a tap, and in a compact width the card's rounded leading corners,
    /// filled in the drawer's ground. Both are flat fills, so moving them
    /// with the page costs no offscreen drawing.
    private var cover: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(veilStrength * progress)
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .accessibilityElement()
                .accessibilityLabel("关闭历史对话")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("ledger-agent-history-dismiss")
                .accessibilityHidden(!isPresented)
        }
    }

    // MARK: Dragging

    /// A finger takes the drawer, from wherever it is on screen: at rest, or
    /// partway through an animation, which it stops.
    private func dragBegan() {
        loaded = true
        let base = min(width, max(0, motion.presented() ?? reveal))
        withTransaction(Self.still) { drawn = true }
        motion.stop()
        motion.dragBase = base
        motion.tickedThisDrag = false
        motion.committed = false
        withTransaction(Self.still) { reveal = base }
    }

    private func dragChanged(_ dx: CGFloat) {
        guard !motion.committed else { return }
        // Far enough to say which way: the spring takes it from here.
        if !isPresented && dx > LedgerAgentDrawerMotion.commitDistance {
            commit(open: true)
            return
        }
        if isPresented && dx < -LedgerAgentDrawerMotion.commitDistance {
            commit(open: false)
            return
        }
        let next = min(width, max(0, motion.dragBase + dx))
        reveal = next
        // Tap once on passing the point where letting go opens the drawer.
        if !isPresented && !motion.tickedThisDrag && next > width * 0.5 {
            motion.tickedThisDrag = true
            openTicks += 1
        }
    }

    /// Letting go: where the drawer would coast to at the finger's speed
    /// decides whether it opens, and the animation starts at that speed.
    private func dragEnded(_ dx: CGFloat, _ speed: CGFloat) {
        guard !motion.committed else {
            motion.committed = false
            return
        }
        let at = min(width, max(0, motion.dragBase + dx))
        let projected = at + speed * 0.18
        let open = projected > width * 0.5
        if open != isPresented {
            motion.releaseSpeed = speed
            isPresented = open
        } else {
            motion.tickedThisDrag = false
            settle(speed: speed)
        }
    }

    /// Sends the drawer open or closed in the middle of a drag, from where
    /// the finger has it, at the speed the spring gives a decided move.
    private func commit(open: Bool) {
        motion.committed = true
        if open && !motion.tickedThisDrag {
            motion.tickedThisDrag = true
            openTicks += 1
        }
        motion.releaseSpeed = 0
        isPresented = open
    }

    /// Brings the drawer to where `isPresented` says it is, carrying on at
    /// `speed` (points per second) from a finger that let go of it.
    private func settle(speed: CGFloat) {
        if isPresented { loaded = true }
        let target = isPresented ? width : 0
        let from = motion.presented() ?? reveal
        if isPresented || from > 0.5 { withTransaction(Self.still) { drawn = true } }
        if motion.instant {
            motion.instant = false
            motion.stop()
            withTransaction(Self.still) {
                reveal = target
                carded = isPresented
                if !isPresented {
                    drawn = false
                    closings += 1
                }
            }
            return
        }
        let distance = target - from
        let animation: Animation
        if reduceMotion {
            animation = .easeInOut(duration: 0.2)
            motion.stop()
        } else {
            // A spring's initial velocity is a share of the distance per
            // second. A fling faster than the distance allows is capped, so
            // the page does not overshoot far past the drawer.
            let relative = abs(distance) > 1 ? min(12, max(-12, speed / distance)) : 0
            animation = .interpolatingSpring(LedgerAgentDrawerMotion.spring, initialVelocity: relative)
            motion.began(from: from, to: target, velocity: relative * distance)
        }
        if carded != isPresented {
            // The card draws back or fills the screen again on FlowDown's
            // spring, from rest: the finger's speed is a sideways one.
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2)
                                       : .interpolatingSpring(LedgerAgentDrawerMotion.spring)) {
                carded = isPresented
            }
        }
        withAnimation(animation, completionCriteria: .removed) {
            reveal = target
        } completion: {
            guard !isPresented && reveal == 0 else { return }
            closings += 1
            // At rest now: the drawer and the corners go in one frame,
            // under the page, rather than fading over the slide.
            withTransaction(Self.still) { drawn = false }
        }
    }

    /// A change that is not animated, whatever animation is running.
    private static var still: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }
}

/// What lies outside FlowDown's chat card while the drawer is out: the
/// drawer's ground, everywhere beyond the card's rounded outline, and the
/// card's shadow (black at 10%, 8pt) over it, cast from a path and masked
/// to the outside of the card so it never darkens the page.
private struct LedgerAgentCardFrame: UIViewRepresentable {
    var radius: CGFloat

    func makeUIView(context: Context) -> FrameView { FrameView() }

    func updateUIView(_ view: FrameView, context: Context) {
        view.radius = radius
    }

    final class FrameView: UIView {
        var radius: CGFloat = 0 { didSet { if radius != oldValue { setNeedsLayout() } } }
        private let ground = CAGradientLayer()
        private let groundMask = CAShapeLayer()
        private let shadow = CALayer()
        private let shadowMask = CAShapeLayer()
        /// How far past the card the ground reaches: off every edge of the
        /// screen, whichever way the card has moved.
        private static let reach: CGFloat = 3000

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            clipsToBounds = false
            groundMask.fillRule = .evenOdd
            ground.mask = groundMask
            shadow.shadowColor = UIColor.black.cgColor
            shadow.shadowOpacity = 0.1
            shadow.shadowRadius = 8
            shadow.shadowOffset = .zero
            shadowMask.fillRule = .evenOdd
            shadow.mask = shadowMask
            layer.addSublayer(ground)
            layer.addSublayer(shadow)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let card = UIBezierPath(roundedRect: bounds, cornerRadius: radius)
            let outside = UIBezierPath(rect: bounds.insetBy(dx: -Self.reach, dy: -Self.reach))
            outside.append(card)
            // Only the card's own column, above it, below it and in its
            // corners: the drawer lies to its left and must stay in view.
            ground.frame = CGRect(x: 0, y: -Self.reach, width: bounds.width + Self.reach,
                                  height: bounds.height + Self.reach * 2)
            ground.colors = [LedgerAgentPalette.groundTopUI, LedgerAgentPalette.groundBottomUI]
                .map { $0.resolvedColor(with: traitCollection).cgColor }
            // The mask is in the ground's own coordinates.
            let maskPath = UIBezierPath(rect: CGRect(origin: .zero, size: ground.frame.size))
            maskPath.append(UIBezierPath(roundedRect: bounds.offsetBy(dx: 0, dy: Self.reach),
                                         cornerRadius: radius))
            groundMask.frame = CGRect(origin: .zero, size: ground.frame.size)
            groundMask.path = maskPath.cgPath
            shadow.frame = bounds
            shadow.shadowPath = card.cgPath
            shadowMask.frame = bounds
            shadowMask.path = outside.cgPath
            CATransaction.commit()
        }

        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }
    }
}

private struct LedgerAgentDrawerOpenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The history drawer is out beside the page.
    var ledgerAgentDrawerOpen: Bool {
        get { self[LedgerAgentDrawerOpenKey.self] }
        set { self[LedgerAgentDrawerOpenKey.self] = newValue }
    }
}

/// What a horizontal drag does to the drawer right now.
enum LedgerAgentDrawerPanMode: Equatable {
    /// Nothing: the page is not a root page, or the drawer has no width yet.
    case off
    /// A drag to the right that starts anywhere on the page opens it.
    case opens
    /// A drag to the left that starts anywhere on the drawer or the page
    /// beside it closes it.
    case closes
}

/// The drawer's drag, as a UIKit pan on the window so it sees touches over
/// the conversation, a table that scrolls sideways or a chart, and over the
/// drawer's own list. It begins only for a drag that goes mostly sideways in
/// the direction of `mode`; the page's and the drawer's scroll views and
/// swipes wait for it to give up, which it does at once for any other drag.
/// Anything presented over the page (a sheet, a menu) or pushed on top of it
/// takes the touch out of its reach.
private struct LedgerAgentDrawerPan: UIViewRepresentable {
    var mode: LedgerAgentDrawerPanMode
    var began: () -> Void
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> LedgerAgentDrawerPanView { LedgerAgentDrawerPanView() }

    func updateUIView(_ view: LedgerAgentDrawerPanView, context: Context) {
        view.began = began
        view.changed = changed
        view.ended = ended
        view.setMode(mode)
    }

    static func dismantleUIView(_ view: LedgerAgentDrawerPanView, coordinator: ()) { view.detach() }
}

final class LedgerAgentDrawerPanView: UIView {
    var began: (() -> Void)?
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat, CGFloat) -> Void)?
    private(set) var mode: LedgerAgentDrawerPanMode = .off
    private let driver = LedgerAgentDrawerPanDriver()
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: driver, action: #selector(LedgerAgentDrawerPanDriver.handle(_:)))
        pan.delegate = driver
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        return pan
    }()
    private weak var attachedWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        driver.view = self
    }

    required init?(coder: NSCoder) { nil }

    func setMode(_ mode: LedgerAgentDrawerPanMode) {
        self.mode = mode
        // A drag in progress keeps going when the drawer it opened becomes
        // presented; only a new one reads the new mode.
        let enabled = mode != .off
        if pan.isEnabled != enabled && (enabled || pan.state == .possible) { pan.isEnabled = enabled }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== attachedWindow else { return }
        attachedWindow?.removeGestureRecognizer(pan)
        attachedWindow = window
        window?.addGestureRecognizer(pan)
    }

    func detach() {
        attachedWindow?.removeGestureRecognizer(pan)
        attachedWindow = nil
    }

    /// The view of the page this view is on: that of the nearest view
    /// controller. The drawer is drawn in it too.
    var pageView: UIView? {
        var responder: UIResponder? = self
        while let next = responder {
            if let controller = next as? UIViewController { return controller.view }
            responder = next.next
        }
        return nil
    }
}

@MainActor
final class LedgerAgentDrawerPanDriver: NSObject, UIGestureRecognizerDelegate {
    weak var view: LedgerAgentDrawerPanView?
    /// A drag that starts this close to the leading edge opens the drawer
    /// even over content that scrolls sideways.
    private static let edgeWidth: CGFloat = 24
    /// Where the finger came down, in the window. A pan's translation is
    /// still zero when it asks whether to begin, so the distance is measured
    /// from here.
    private var touchDown: CGPoint?

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchDown = touch.location(in: view?.window)
        return true
    }

    @objc func handle(_ pan: UIPanGestureRecognizer) {
        guard let view, let window = view.window else { return }
        let dx = pan.translation(in: window).x
        switch pan.state {
        case .began:
            view.began?()
            view.changed?(dx)
        case .changed:
            view.changed?(dx)
        case .ended:
            view.ended?(dx, pan.velocity(in: window).x)
        case .cancelled, .failed:
            view.ended?(dx, 0)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view, let window = view.window,
              let page = view.pageView, view.mode != .off else { return false }
        let now = pan.location(in: window)
        let start = touchDown ?? now
        var moved = CGPoint(x: now.x - start.x, y: now.y - start.y)
        if moved == .zero {
            let speed = pan.velocity(in: window)
            moved = CGPoint(x: speed.x, y: speed.y)
        }
        // Mostly sideways: a slanted scroll of the conversation stays a scroll.
        guard abs(moved.x) > abs(moved.y) * 1.2 else { return false }
        guard view.mode == .opens ? moved.x > 0 : moved.x < 0 else { return false }
        guard let hit = window.hitTest(start, with: nil), hit.isDescendant(of: page) else { return false }
        if view.mode == .closes { return true }
        if start.x <= window.safeAreaInsets.left + Self.edgeWidth { return true }
        return !Self.claimsRightwardDrag(from: hit, upTo: page)
    }

    /// Something under the finger that a drag to the right already means
    /// something to: a slider or other control, or a scroll view that is
    /// scrolled away from its leading end (a wide table, a code block).
    private static func claimsRightwardDrag(from hit: UIView, upTo page: UIView) -> Bool {
        var current: UIView? = hit
        while let view = current, view !== page {
            if view is UISlider || view is UISwitch || view is UIDatePicker { return true }
            if let scroll = view as? UIScrollView {
                let insets = scroll.adjustedContentInset
                let scrollsSideways = scroll.contentSize.width + insets.left + insets.right > scroll.bounds.width + 1
                if scrollsSideways && scroll.contentOffset.x > -insets.left + 1 { return true }
            }
            current = view.superview
        }
        return false
    }

    /// The page's and the drawer's own drags, scrolls and row swipes among
    /// them, wait to see whether this one takes the touch. It decides on the
    /// first movement, so they start as soon as it does not. Taps and long
    /// presses do not wait: a still finger would hold them up.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard other is UIPanGestureRecognizer, let otherView = other.view,
              let page = view?.pageView else { return false }
        return otherView.isDescendant(of: page)
    }
}

/// A conversation being renamed, with the name it showed when the field
/// opened and the name typed so far.
struct LedgerAgentRenameTarget: Identifiable, Equatable {
    let id: UUID
    let shown: String
    var name: String

    init(id: UUID, shown: String) {
        self.id = id
        self.shown = shown
        self.name = shown
    }
}

extension View {
    /// The rename alert of the history list, which is where a conversation is
    /// named now that the chat page has no title. Saving an empty name gives
    /// the conversation back its generated one.
    func ledgerAgentRenameAlert(_ target: Binding<LedgerAgentRenameTarget?>) -> some View {
        modifier(LedgerAgentRenameAlert(target: target))
    }
}

private struct LedgerAgentRenameAlert: ViewModifier {
    @Binding var target: LedgerAgentRenameTarget?

    func body(content: Content) -> some View {
        content.alert("重命名对话", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("名称", text: Binding(get: { target?.name ?? "" }, set: { target?.name = $0 }))
                .accessibilityIdentifier("ledger-agent-rename-field")
            Button("取消", role: .cancel) { target = nil }
            Button("保存") {
                if let target { LedgerAgentSessions.shared.rename(target.id, to: target.name, shown: target.shown) }
                target = nil
            }
        } message: {
            Text("留空就用自动起的名字。")
        }
    }
}
#endif
