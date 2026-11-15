#if os(iOS)
import SwiftUI
import UIKit

/// Saved conversations of this ledger, as the content of the drawer that
/// opens beside the chat from the left: a serif title with search beside it,
/// 已置顶 then 最近 (the rest, in the order of `LedgerAgentHistoryGroup`), and
/// 新对话 at the bottom. Picking a conversation switches the screen to it; a
/// running one keeps running. A row can be renamed, pinned, shared as plain
/// text or deleted from its context menu, pinned by a swipe from the left
/// and deleted by a swipe from the right.
struct LedgerAgentHistoryView: View {
    /// Whether amounts are on screen; a conversation is not shared as text
    /// while privacy protection masks them.
    var sharesText: Bool
    /// Closes the drawer.
    var close: () -> Void
    /// Opens 助手设置 on the chat page.
    var openSettings: () -> Void
    /// A drag to the left on the header or the footer, which moves the
    /// drawer with the finger and closes it when let go far or fast enough.
    var closeDrag: LedgerAgentDrawerDrag
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var confirmingClear = false
    @State private var renaming: LedgerAgentRenameTarget?

    private var groups: [LedgerAgentHistoryGroup] {
        LedgerAgentHistoryGroup.grouping(sessions.saved.filter { $0.matches(query) })
    }

    private var pinned: [LedgerAgentSavedConversation] {
        groups.first { $0.kind == .pinned }?.items ?? []
    }

    /// Everything not pinned, newest first, as the groups order it.
    private var recent: [LedgerAgentSavedConversation] {
        groups.filter { $0.kind != .pinned }.flatMap(\.items)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
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
                // Room for the last line to clear the footer's fade.
                Color.clear.frame(height: 28)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityHidden(true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .accessibilityIdentifier("ledger-agent-history-list")
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .privacySensitive()
        .confirmationDialog("清空这本账本的全部历史对话？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { sessions.deleteAll() }
        }
        .ledgerAgentRenameAlert($renaming)
    }

    // MARK: Header

    /// The title, or the search field in its place, and the round button
    /// that swaps them. Closing the search clears it. The rows keep their
    /// own swipes, so the drag that closes the drawer lives here, on the
    /// footer and on the page beside the drawer.
    private var header: some View {
        HStack(spacing: 12) {
            if searching {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(BalancedPalette.meta)
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
                .background(Capsule().fill(BalancedPalette.sunken))
                .transition(.opacity)
            } else {
                Text("账本助手")
                    .font(BalancedReading.font(.regular, size: 24, relativeTo: .title))
                    .foregroundStyle(BalancedPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            Button {
                searching.toggle()
                if searching { searchFocused = true } else { query = "" }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(width: 44, height: 44)
                    .background {
                        if !LedgerGlass.isAvailable { Circle().fill(BalancedPalette.sunken) }
                    }
                    .ledgerGlassControl()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searching ? "关闭搜索" : "搜索")
            .accessibilityIdentifier("ledger-agent-history-search")
        }
        .animation(.easeInOut(duration: 0.18), value: searching)
        // Claude's sidebar sets its title on the line of the page's round
        // buttons, a little further out than the rows.
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .gesture(closeDrag.gesture)
    }

    // MARK: Rows

    /// 已置顶 and 最近, a size under the rows in the quiet colour, with the
    /// room of about one row above it and less below, so it belongs to the
    /// rows it heads.
    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .balancedFont(size: 14).foregroundStyle(BalancedPalette.meta)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 18, leading: 24, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
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
        .listRowBackground(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.id == sessions.current.id ? BalancedPalette.sunken : Color.clear)
                .padding(.horizontal, 14)
                .padding(.vertical, 1)
        )
        .accessibilityAddTraits(item.id == sessions.current.id ? .isSelected : [])
        .contextMenu { menu(item) }
        .swipeActions(edge: .leading) {
            Button { sessions.setPinned(item.id, item.pinnedAt == nil) } label: { pinLabel(item) }
                .tint(BalancedPalette.secondary)
        }
        .swipeActions(edge: .trailing) {
            if !isRunning(item.id) {
                Button(role: .destructive) { sessions.delete(item.id) } label: { Label("删除", systemImage: "trash") }
            }
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
            Image(systemName: "bubble.left").font(.system(size: 18, weight: .regular))
                .foregroundStyle(BalancedPalette.ink)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(item.title).balancedFont(size: 17).foregroundStyle(BalancedPalette.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if isRunning(item.id) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在回答…")
            } else if item.unwrittenChange {
                Circle().fill(BalancedPalette.secondary).frame(width: 7, height: 7)
                    .accessibilityElement()
                    .accessibilityLabel("有未写入的草稿改动")
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    // MARK: Footer

    /// At the leading end a round button with the app's mark where Claude
    /// puts the user's picture: the ledger has no profile, so it holds what
    /// is left over, 助手设置 and 清空历史. 新对话 is an ink capsule at the
    /// trailing end. Rows scrolling under the two fade into the page.
    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    close()
                    openSettings()
                } label: { Label("助手设置…", systemImage: "slider.horizontal.3") }
                if !sessions.saved.isEmpty {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label("清空历史", systemImage: "trash")
                    }
                }
            } label: {
                LedgerMarkCanvas(progress: 1)
                    .frame(width: 32, height: 32)
                    .frame(width: 48, height: 48)
                    .background {
                        if !LedgerGlass.isAvailable {
                            Circle().fill(BalancedPalette.sunken)
                        }
                    }
                    .ledgerGlassControl()
                    .contentShape(Circle())
            }
            .accessibilityLabel("更多")
            .accessibilityIdentifier("ledger-agent-history-more")
            Spacer(minLength: 0)
            Button {
                sessions.startNew()
                close()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    Text("新对话").balancedFont(size: 16, weight: .medium).lineLimit(1)
                }
                .foregroundStyle(BalancedPalette.page)
                .padding(.leading, 18)
                .padding(.trailing, 22)
                .frame(minHeight: 48)
                .background(Capsule().fill(BalancedPalette.ink))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ledger-agent-new")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .background {
            LinearGradient(stops: [.init(color: BalancedPalette.page.opacity(0), location: 0),
                                   .init(color: BalancedPalette.page.opacity(0.9), location: 0.4),
                                   .init(color: BalancedPalette.page, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(closeDrag.gesture)
    }
}

extension View {
    /// The history drawer of a chat page, the way Claude's sidebar works: it
    /// is 80% of the page wide (400pt at most) and pushes the page to the
    /// right, which becomes a card with rounded corners under a light veil.
    /// A drag to the right that starts at the leading edge of the screen
    /// opens it under the finger when `edgeOpens`; a tap on the card, a drag
    /// to the left on the card or on the drawer's header or footer, or the
    /// VoiceOver escape closes it, also under the finger. In a regular width
    /// the page stays put and the drawer slides over it. The page is hidden
    /// from assistive technology while the drawer is open.
    func ledgerAgentHistoryDrawer(isPresented: Binding<Bool>, edgeOpens: Bool, sharesText: Bool,
                                  openSettings: @escaping () -> Void) -> some View {
        modifier(LedgerAgentHistoryDrawer(isPresented: isPresented, edgeOpens: edgeOpens, sharesText: sharesText,
                                          openSettings: openSettings))
    }
}

/// A finger moving the drawer: how far it has gone to the right so far
/// (negative to the left), and at the end, that distance and its speed.
@MainActor
struct LedgerAgentDrawerDrag {
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    var gesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { changed($0.translation.width) }
            .onEnded { ended($0.translation.width, $0.velocity.width) }
    }
}

struct LedgerAgentHistoryDrawer: ViewModifier {
    @Binding var isPresented: Bool
    var edgeOpens: Bool
    var sharesText: Bool
    var openSettings: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageWidth: CGFloat = 0
    /// How far the drawer is out, from 0 (closed) to `width` (open). A
    /// finger sets it directly; letting go or a tap animates it.
    @State private var reveal: CGFloat = 0
    /// The drawer is in the view tree: from the moment it starts to come out
    /// until it is all the way back in.
    @State private var mounted = false

    private static let overShape = UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28,
                                                          style: .continuous)
    /// Light mode lifts the pushed page towards white, dark mode dims it.
    private static let veil = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })

    @Environment(\.colorScheme) private var colorScheme

    private var width: CGFloat { min(pageWidth * 0.8, 400) }
    /// A white veil any stronger would melt the card into the drawer.
    private var veilStrength: CGFloat {
        guard pushes else { return 0.32 }
        return colorScheme == .dark ? 0.5 : 0.3
    }
    /// Compact width pushes the page aside; regular width slides the drawer
    /// over it, since the system navigation bar there would not move.
    private var pushes: Bool { sizeClass != .regular }
    private var progress: CGFloat { width > 0 ? min(1, max(0, reveal / width)) : 0 }
    private var settling: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.88)
    }

    private var closeDrag: LedgerAgentDrawerDrag {
        LedgerAgentDrawerDrag(
            changed: { dx in reveal = min(width, max(0, width + min(0, dx))) },
            ended: { dx, speed in finish(open: !(dx < -width * 0.35 || speed < -600)) })
    }

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .accessibilityHidden(isPresented)
                .overlay { if mounted { cover } }
                .background {
                    LedgerLeadingEdgePan(
                        isEnabled: edgeOpens && !isPresented && width > 0,
                        changed: { dx in
                            mounted = true
                            reveal = min(width, max(0, dx))
                        },
                        ended: { dx, speed in finish(open: (dx > width * 0.35 && speed > -300) || speed > 600) })
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                .offset(x: pushes ? reveal : 0)
            if mounted {
                drawer.zIndex(pushes ? -1 : 1)
            }
        }
        .onChange(of: isPresented) { _, _ in settle() }
        .onChange(of: width) { _, _ in if isPresented { reveal = width } }
        .onAppear { if isPresented { settle() } }
    }

    private var drawer: some View {
        LedgerAgentHistoryView(sharesText: sharesText, close: { isPresented = false },
                               openSettings: openSettings, closeDrag: closeDrag)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background {
                if pushes {
                    Rectangle().fill(BalancedPalette.page).ignoresSafeArea()
                } else {
                    Self.overShape.fill(BalancedPalette.page)
                        .shadow(color: .black.opacity(0.18 * progress), radius: 24, x: 8, y: 0)
                        .ignoresSafeArea()
                }
            }
            .offset(x: reveal - width)
            .accessibilityHidden(!isPresented)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { isPresented = false }
    }

    /// Over the page while the drawer is out: the veil that closes the
    /// drawer, and in a compact width the card's rounded leading corners and
    /// the soft shadow it casts on the drawer.
    private var cover: some View {
        ZStack(alignment: .leading) {
            Self.veil.opacity(veilStrength * progress)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .gesture(closeDrag.gesture)
                .accessibilityElement()
                .accessibilityLabel("关闭历史对话")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("ledger-agent-history-dismiss")
                .accessibilityHidden(!isPresented)
            if pushes {
                LedgerAgentCardCorners(radius: 44)
                    .fill(BalancedPalette.page)
                    .ignoresSafeArea()
                    .opacity(progress > 0 ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(colorScheme == .dark ? 0.12 : 0.09)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 22)
                    .offset(x: -22)
                    .ignoresSafeArea()
                    .opacity(progress)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func finish(open: Bool) {
        if open != isPresented { isPresented = open } else { settle() }
    }

    /// Brings the drawer to where `isPresented` says it is, and takes it out
    /// of the view tree once it is all the way in.
    private func settle() {
        if isPresented { mounted = true }
        withAnimation(settling) {
            reveal = isPresented ? width : 0
        } completion: {
            if !isPresented && reveal == 0 { mounted = false }
        }
    }
}

/// The two leading corners of the pushed page, filled in the drawer's
/// colour so the page reads as a card with rounded corners.
private struct LedgerAgentCardCorners: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A rightward drag that starts within 24pt of the leading edge of the
/// screen, on the page that holds this view. The recognizer sits on the
/// window, so it sees touches over the conversation, a table that scrolls
/// sideways or a chart; scroll views on the page wait for it to give up, and
/// it gives up unless the drag starts at the edge and goes mostly right.
/// Anything presented over the page (a sheet, a menu) or pushed on top of it
/// takes the touch out of its reach, and so does a drawer already open.
private struct LedgerLeadingEdgePan: UIViewRepresentable {
    var isEnabled: Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> LedgerLeadingEdgePanView { LedgerLeadingEdgePanView() }

    func updateUIView(_ view: LedgerLeadingEdgePanView, context: Context) {
        view.changed = changed
        view.ended = ended
        view.setEnabled(isEnabled)
    }

    static func dismantleUIView(_ view: LedgerLeadingEdgePanView, coordinator: ()) { view.detach() }
}

final class LedgerLeadingEdgePanView: UIView {
    var changed: ((CGFloat) -> Void)?
    var ended: ((CGFloat, CGFloat) -> Void)?
    private let driver = LedgerLeadingEdgePanDriver()
    private lazy var pan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: driver, action: #selector(LedgerLeadingEdgePanDriver.handle(_:)))
        pan.delegate = driver
        pan.maximumNumberOfTouches = 1
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

    func setEnabled(_ enabled: Bool) {
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
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
    /// controller.
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
final class LedgerLeadingEdgePanDriver: NSObject, UIGestureRecognizerDelegate {
    weak var view: LedgerLeadingEdgePanView?
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
        switch pan.state {
        case .began, .changed:
            view.changed?(pan.translation(in: window).x)
        case .ended:
            view.ended?(pan.translation(in: window).x, pan.velocity(in: window).x)
        case .cancelled, .failed:
            view.ended?(0, 0)
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view, let window = view.window,
              let page = view.pageView else { return false }
        let now = pan.location(in: window)
        let start = touchDown ?? now
        var moved = CGPoint(x: now.x - start.x, y: now.y - start.y)
        if moved == .zero {
            let speed = pan.velocity(in: window)
            moved = CGPoint(x: speed.x, y: speed.y)
        }
        guard moved.x > 0, moved.x > abs(moved.y) else { return false }
        guard start.x <= window.safeAreaInsets.left + Self.edgeWidth,
              let hit = window.hitTest(start, with: nil) else { return false }
        return hit.isDescendant(of: page)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let scroll = other.view as? UIScrollView, other === scroll.panGestureRecognizer,
              let page = view?.pageView else { return false }
        return scroll.isDescendant(of: page)
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
