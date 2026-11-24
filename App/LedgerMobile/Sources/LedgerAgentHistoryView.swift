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
                .background(Capsule().fill(LedgerAgentPalette.selected))
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
                        if !LedgerGlass.isAvailable { Circle().fill(LedgerAgentPalette.selected) }
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
                .fill(item.id == sessions.current.id ? LedgerAgentPalette.selected : Color.clear)
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
