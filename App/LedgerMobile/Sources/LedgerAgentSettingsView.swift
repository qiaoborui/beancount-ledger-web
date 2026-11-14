#if os(iOS)
import SwiftUI

/// 助手设置 — which model answers, how much it may do on its own, what it
/// remembers, and what it can use. One short list: every row says its current
/// value and opens its own page, so nothing needs a paragraph under it.
struct LedgerAgentSettingsView: View {
    /// AI 开账 opens this before a ledger exists. Only the model and key page
    /// applies then, so that page is the whole sheet.
    var modelOnly = false

    var body: some View {
        if modelOnly {
            LedgerAgentModelSettingsView()
        } else {
            LedgerAgentSettingsRoot()
        }
    }
}

/// The settings list itself: the model and its thinking effort, 写入账本,
/// 记忆, 建议, 能力, and the page for what rarely changes.
private struct LedgerAgentSettingsRoot: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                NavigationLink {
                    LedgerAgentModelSettingsView()
                } label: {
                    LabeledContent("模型") {
                        AgentSettingsValue(text: settings.providerTitle + " · " + settings.modelTitle)
                    }
                }
                .accessibilityIdentifier("ledger-agent-settings-model")
                NavigationLink {
                    LedgerAgentThinkingPicker()
                } label: {
                    LabeledContent("思考强度") { AgentSettingsValue(text: settings.effectiveThinking.title) }
                }
                .accessibilityIdentifier("ledger-agent-thinking")
            } header: { Text("模型") }
            // 权限: the one choice that decides how much the assistant may do
            // without asking, so it says what the choice means right under it.
            Section {
                Picker(selection: Binding(get: { settings.writePolicy }, set: { settings.setWritePolicy($0) })) {
                    ForEach(LedgerAgentWritePolicy.allCases) { policy in
                        Text(policy == .tiered ? String(localized: "自动写入（推荐）") : policy.title).tag(policy)
                    }
                } label: {
                    Text("写入账本")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("ledger-agent-write-policy")
            } header: { Text("权限") } footer: {
                Text(settings.writePolicy.detail)
            }
            Section {
                NavigationLink {
                    LedgerAgentMemoryView()
                } label: {
                    LabeledContent("记忆") {
                        AgentSettingsValue(text: settings.usesMemory ? String(localized: "已开启") : String(localized: "已关闭"))
                    }
                }
                .accessibilityIdentifier("ledger-agent-memory")
            } header: { Text("记忆") }
            Section {
                Toggle("智能建议", isOn: Binding(get: { settings.assists }, set: { settings.setAssists($0) }))
                    .accessibilityIdentifier("ledger-agent-assists")
                Toggle("推荐问题", isOn: Binding(get: { settings.suggestions }, set: { settings.setSuggestions($0) }))
                    .accessibilityIdentifier("ledger-agent-suggestions")
            } header: { Text("建议") } footer: {
                Text("智能建议用不带思考的小请求写回顾、预测下一句并给对话起名；推荐问题只控制空态里的「试试」。")
            }
            Section {
                // 技能 and MCP 服务器 join this section as their own rows.
                NavigationLink("可用工具") { LedgerAgentToolsView() }
            } header: { Text("能力") }
            Section {
                NavigationLink("高级") { LedgerAgentAdvancedSettingsView() }
            }
        }
        .font(.subheadline)
        .navigationTitle("助手设置")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
    }
}

/// 模型与密钥 — provider, model or custom endpoint, the Keychain key, and the
/// starred models. Also the whole sheet AI 开账 opens, since it has no ledger
/// to write into yet.
private struct LedgerAgentModelSettingsView: View {
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
                            AgentSettingsValue(text: settings.modelTitle)
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
}

/// 可用工具 — the tools the assistant can call, grouped by what they do. The
/// names are the core's own, so a user reading a step can match it here.
private struct LedgerAgentToolsView: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared

    var body: some View {
        List {
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
            } footer: {
                Text("查询工具只读账本。改账工具只改一份私有草稿，改动按「写入账本」的设置通过校验后写入。附件工具在对话附了文件时才有，看图需要模型支持图片。")
            }
        }
        .font(.subheadline)
        .navigationTitle("可用工具")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
    }

    private func tool(_ title: String, _ names: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(names).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
        }
    }
}

/// 高级 — the background toggle and what a turn sends. Both are set once and
/// then left alone, so they are a page rather than rows on the first screen.
private struct LedgerAgentAdvancedSettingsView: View {
    @ObservedObject private var settings = LedgerAgentSettings.shared

    var body: some View {
        List {
            Section {
                Toggle("后台保持运行", isOn: Binding(get: { settings.keepsAwake }, set: { settings.setKeepsAwake($0) }))
                    .accessibilityIdentifier("ledger-agent-keep-awake")
            } header: { Text("后台") } footer: {
                Text("回答期间在后台播放无声音频，锁屏后助手也能做完，不影响你正在听的音乐。关掉后只用系统给的后台时间，较长的回答可能被中断，回到 App 时会自动接着做。")
            }
            Section("发给模型的内容") {
                Text("你的问题、本次对话，以及助手调用工具后得到的结果（例如汇总金额、匹配到的流水）。不会发送整本账本文件，也不会发送 Git 凭据或本机路径。")
            }
        }
        .font(.subheadline)
        .navigationTitle("高级")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
    }
}

/// The current value at the trailing end of a settings row.
private struct AgentSettingsValue: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(BalancedPalette.meta)
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
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
    }
}
#endif
