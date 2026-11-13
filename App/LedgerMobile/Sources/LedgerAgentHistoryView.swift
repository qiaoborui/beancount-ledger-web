#if os(iOS)
import SwiftUI

/// Saved conversations of this ledger: pinned ones first, then the rest by
/// when they were last used. Picking one switches the screen to it; a running
/// one keeps running. A row can be renamed, pinned, shared as plain text or
/// deleted from its context menu.
struct LedgerAgentHistoryView: View {
    /// Whether amounts are on screen; a conversation is not shared as text
    /// while privacy protection masks them.
    var sharesText: Bool
    @ObservedObject private var sessions = LedgerAgentSessions.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingClear = false
    @State private var renaming: LedgerAgentRenameTarget?

    private var groups: [LedgerAgentHistoryGroup] {
        LedgerAgentHistoryGroup.grouping(sessions.saved.filter { $0.matches(query) })
    }

    var body: some View {
        List {
            // The chat page has no 新对话 in its bar any more: starting over
            // belongs with the sessions it starts over from, at the top of
            // the list rather than in a second toolbar button.
            Section {
                Button {
                    sessions.startNew()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil").font(.system(size: 16, weight: .medium))
                        Text("新对话").balancedFont(size: 15, weight: .medium)
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(BalancedPalette.ink)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("ledger-agent-new")
            }
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
                }
            }
            if !sessions.saved.isEmpty {
                Section {
                    Button("清空历史", role: .destructive) { confirmingClear = true }
                } footer: {
                    Text("对话跟着账本存在本机，不进 Git 同步、备份或导出。置顶的对话不会因为数量太多被自动清理。")
                }
            }
        }
        .font(.subheadline)
        .searchable(text: $query, prompt: Text("搜索标题、问题和回答"))
        .navigationTitle("历史对话")
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
        }
        .confirmationDialog("清空这本账本的全部历史对话？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { sessions.deleteAll() }
        }
        .ledgerAgentRenameAlert($renaming)
        .accessibilityIdentifier("ledger-agent-history-list")
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

    private func row(_ item: LedgerAgentSavedConversation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if item.pinnedAt != nil {
                        Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(BalancedPalette.meta)
                            .accessibilityLabel("已置顶")
                    }
                    Text(item.title).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                }
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
