#if os(iOS)
import SwiftUI

/// Saved conversations of this ledger, as the content of the drawer that
/// slides over the chat from the left: a serif title with search beside it,
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
    /// Opens 模型与密钥 on the chat page.
    var openSettings: () -> Void
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
    /// own swipes, so the drag that closes the drawer lives here and on the
    /// page beside the drawer.
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
                    .font(BalancedReading.font(.regular, size: 28, relativeTo: .title))
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
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(LedgerAgentHistoryDrawer.closeDrag(close))
    }

    // MARK: Rows

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            .accessibilityAddTraits(.isHeader)
            .listRowInsets(EdgeInsets(top: 14, leading: 22, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            .listRowInsets(EdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 16))
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
        // The conversation on screen sits on a sunken block, inset from the
        // drawer's edges.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(item.id == sessions.current.id ? BalancedPalette.sunken : Color.clear)
                .padding(.horizontal, 10)
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

    /// One line: a bubble and the title, cut at the tail. A conversation
    /// that is answering shows a spinner at the end, and one holding a
    /// change not yet written shows a dot.
    private func row(_ item: LedgerAgentSavedConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left").font(.system(size: 16, weight: .regular))
                .foregroundStyle(BalancedPalette.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(item.title).balancedFont(size: 16).foregroundStyle(BalancedPalette.ink)
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
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    // MARK: Footer

    /// 新对话 in the middle, and at the leading end a round button with the
    /// app's mark where another app would put the user's picture: the ledger
    /// has no profile, so it holds what is left over, 模型与密钥 and 清空历史.
    /// A clear spacer of the round button's width keeps the capsule centred
    /// without letting the two overlap at large type sizes.
    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    close()
                    openSettings()
                } label: { Label("模型与密钥…", systemImage: "slider.horizontal.3") }
                if !sessions.saved.isEmpty {
                    Button(role: .destructive) { confirmingClear = true } label: {
                        Label("清空历史", systemImage: "trash")
                    }
                }
            } label: {
                LedgerMarkCanvas(progress: 1)
                    .frame(width: 34, height: 34)
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
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    Text("新对话").balancedFont(size: 15, weight: .medium).lineLimit(1)
                }
                .foregroundStyle(BalancedPalette.page)
                .padding(.horizontal, 22)
                .frame(minHeight: 48)
                .background(Capsule().fill(BalancedPalette.ink))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ledger-agent-new")
            Spacer(minLength: 0)
            Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

extension View {
    /// The history drawer over a chat page. It comes in from the leading
    /// edge on a spring, as wide as 86% of the page (420pt at most on a wide
    /// one) so a strip of the conversation stays in view; a tap on that
    /// strip, a drag to the left on it or on the drawer's header, or the
    /// VoiceOver escape closes it. The page underneath is hidden from
    /// assistive technology while the drawer is open.
    func ledgerAgentHistoryDrawer(isPresented: Binding<Bool>, sharesText: Bool,
                                  openSettings: @escaping () -> Void) -> some View {
        modifier(LedgerAgentHistoryDrawer(isPresented: isPresented, sharesText: sharesText, openSettings: openSettings))
    }
}

struct LedgerAgentHistoryDrawer: ViewModifier {
    @Binding var isPresented: Bool
    var sharesText: Bool
    var openSettings: () -> Void

    private static let shape = UnevenRoundedRectangle(bottomTrailingRadius: 28, topTrailingRadius: 28,
                                                      style: .continuous)

    /// A drag to the left, far enough to be meant.
    static func closeDrag(_ close: @escaping () -> Void) -> some Gesture {
        DragGesture(minimumDistance: 16).onEnded { drag in
            if drag.translation.width < -48, abs(drag.translation.height) < abs(drag.translation.width) { close() }
        }
    }

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isPresented)
            .overlay {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        if isPresented {
                            Color.black.opacity(0.32)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture { isPresented = false }
                                .gesture(Self.closeDrag { isPresented = false })
                                .accessibilityElement()
                                .accessibilityLabel("关闭历史对话")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("ledger-agent-history-dismiss")
                                .transition(.opacity)
                            LedgerAgentHistoryView(sharesText: sharesText, close: { isPresented = false },
                                                   openSettings: openSettings)
                                .frame(width: min(proxy.size.width * 0.86, 420))
                                .background {
                                    Self.shape.fill(BalancedPalette.page)
                                        .shadow(color: .black.opacity(0.18), radius: 24, x: 8, y: 0)
                                        .ignoresSafeArea()
                                }
                                .accessibilityAddTraits(.isModal)
                                .accessibilityAction(.escape) { isPresented = false }
                                .transition(.move(edge: .leading))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .animation(.spring(response: 0.36, dampingFraction: 0.88), value: isPresented)
            }
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
