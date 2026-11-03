#if os(iOS)
import SwiftUI

/// The ledger's memory.md, as the user reads and edits it. The Agent keeps it
/// up to date on its own; this page is where the user corrects or clears it.
struct LedgerAgentMemoryView: View {
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmingClear = false
    @FocusState private var editing: Bool

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            if !settings.usesMemory {
                Section {
                    Text("记忆已关闭：助手不会读取或更新它。可以在「模型与密钥」里重新打开。")
                        .foregroundStyle(BalancedPalette.meta)
                }
            }
            Section {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty && loaded {
                        Text("还没有记忆。和助手说「记住……」，或者在这里直接写，比如：\n## 账户与分类\n- 美团外卖记 Expenses:Food:Delivery")
                            .balancedMono(size: 13)
                            .foregroundStyle(BalancedPalette.edge)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .balancedMono(size: 13)
                        .focused($editing)
                        .frame(minHeight: 320)
                        .scrollContentBackground(.hidden)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("ledger-agent-memory-editor")
                }
            } header: { Text("memory.md") } footer: {
                Text("一条一行，写成助手下次可以直接照做的话。不要写密码、验证码或卡号，助手也不会记这些。最多约 8000 字节。")
            }
            if !saved.isEmpty || !text.isEmpty {
                Section {
                    Button("清空记忆", role: .destructive) { confirmingClear = true }
                        .accessibilityIdentifier("ledger-agent-memory-clear")
                }
            }
        }
        .font(.subheadline)
        .navigationTitle("记忆")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save(text) }
                    .disabled(!loaded || text == saved)
                    .accessibilityIdentifier("ledger-agent-memory-save")
            }
        }
        .confirmationDialog("清空记忆？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { save("") }
        } message: {
            Text("助手会忘掉记下的所有偏好和习惯，之后再从对话里重新学。")
        }
        .task { await load() }
    }

    private func load() async {
        guard let repository = session.localRepository else { return }
        let content = await repository.workspace.agentMemory()
        text = content.trimmingCharacters(in: .newlines)
        saved = text
        loaded = true
    }

    private func save(_ content: String) {
        guard let repository = session.localRepository else { return }
        if content.utf8.count > 8000 {
            error = String(localized: "记忆太长了，请删掉或合并一些条目（最多约 8000 字节）。")
            return
        }
        Task {
            do {
                try await repository.workspace.saveAgentMemory(content)
                text = content.trimmingCharacters(in: .whitespacesAndNewlines)
                saved = text
                editing = false
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// The recap at the bottom of a conversation: what was asked, found and
/// changed, so a user coming back knows where things stand.
struct LedgerAgentRecapCard: View {
    let recap: LedgerAgentRecap?
    let isCurrent: Bool
    let isWorking: Bool
    let error: String?
    let onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                BalancedSectionLabel(text: String(localized: "回顾"))
                Spacer()
                if isWorking {
                    ProgressView().controlSize(.mini)
                } else if recap != nil {
                    Button(action: onSummarize) {
                        Text(isCurrent ? "重新总结" : "更新").balancedFont(size: 12.5)
                            .foregroundStyle(BalancedPalette.meta)
                            .frame(minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ledger-agent-recap-refresh")
                }
            }
            if let recap {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(recap.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "·").balancedFont(size: 14, weight: .semibold).foregroundStyle(BalancedPalette.meta)
                            Text(point).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }
                }
                .opacity(isCurrent ? 1 : 0.6)
                if !isCurrent {
                    Text("之后又聊了几句，点「更新」重新总结。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
            } else if !isWorking {
                Button(action: onSummarize) {
                    Label("总结这次对话", systemImage: "text.append")
                        .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.ink)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ledger-agent-recap")
            } else {
                Text("正在总结…").balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            }
            if let error, !isWorking {
                Text(error).balancedFont(size: 12).foregroundStyle(BalancedPalette.expense).lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 2) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ledger-agent-recap-card")
    }
}
#endif
