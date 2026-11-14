#if os(iOS)
import SwiftUI

/// 技能 — the instructions the ledger assistant loads on demand: how to import
/// a bank's statement, how this person likes the ledger kept. The prompt only
/// lists their names; a body is read when the model needs it.
struct LedgerAgentSkillsView: View {
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSkillSettings.shared
    @State private var catalog: LedgerAgentSkillCatalog?
    @State private var error: String?
    @State private var loading = true
    @State private var reading: LedgerAgentSkill?

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            if loading, catalog == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在读取技能…").foregroundStyle(BalancedPalette.meta)
                    }
                }
            } else if session.localRepository == nil {
                Section {
                    Text("技能只读本地账本。连到服务端的账本没有技能。").foregroundStyle(BalancedPalette.meta)
                }
            } else if skills.isEmpty {
                Section {
                    Text("还没有技能。和助手说「以后都这样做」并讲清楚步骤，它会写成一份技能。")
                        .foregroundStyle(BalancedPalette.meta)
                }
            }
            if !skills.isEmpty {
                Section {
                    ForEach(skills) { skill in row(skill) }
                } header: { Text("技能") } footer: {
                    Text("关掉的技能不会出现在助手每轮的清单里，也用不了。技能内容属于账本，改动会随 Git 同步；这里的开关只在这台设备上生效。")
                }
            }
            if let problems = catalog?.problems, !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.path) { problem in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: problem.path).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                            Text(problem.error).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.expense)
                        }
                    }
                } header: { Text("读不了的技能") } footer: {
                    Text("这几份 SKILL.md 会被跳过，不影响助手回答。改好格式后回到这一页会重新读取。")
                }
            }
        }
        .font(.subheadline)
        .navigationTitle("技能")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .task { await load() }
        .sheet(item: $reading) { skill in
            LedgerAgentSkillBodyView(skill: skill)
        }
    }

    private var skills: [LedgerAgentSkill] { catalog?.skills ?? [] }

    private func row(_ skill: LedgerAgentSkill) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { reading = skill } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .balancedFont(size: 14.5, weight: .medium)
                            .foregroundStyle(BalancedPalette.ink)
                        Text(skill.sourceTitle)
                            .balancedFont(size: 10.5)
                            .foregroundStyle(BalancedPalette.meta)
                        if !settings.isEnabled(skill.name) {
                            Text("已关闭")
                                .balancedFont(size: 10.5)
                                .foregroundStyle(BalancedPalette.meta)
                        }
                    }
                    Text(skill.description)
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ledger-agent-skill-\(skill.name)")
            Toggle("", isOn: Binding(get: { settings.isEnabled(skill.name) },
                                     set: { settings.setEnabled($0, name: skill.name) }))
                .labelsHidden()
                .accessibilityLabel(Text(skill.name))
                .accessibilityIdentifier("ledger-agent-skill-toggle-\(skill.name)")
        }
    }

    private func load() async {
        guard let repository = session.localRepository else {
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        do {
            let root = try await repository.workspace.withCurrentSnapshot { _, url in url.path }
            catalog = try await LedgerAgentSkillCatalog.load(workspaceRoot: root, disabled: settings.disabled)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One skill's body, read-only: the text the assistant follows, as it is in
/// the ledger.
struct LedgerAgentSkillBodyView: View {
    let skill: LedgerAgentSkill
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(skill.description)
                        .balancedFont(size: 13)
                        .foregroundStyle(BalancedPalette.meta)
                    Text(verbatim: skill.body)
                        .balancedMono(size: 12.5)
                        .foregroundStyle(BalancedPalette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 12, leading: 18, bottom: 24, trailing: 18))
            }
            .navigationTitle(skill.name)
            .navigationBarTitleDisplayMode(.inline)
            .terminalNativeChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .privacySensitive()
    }
}
#endif
