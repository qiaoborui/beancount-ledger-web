import SwiftUI

/// 设置 › MCP 服务器: the remote servers whose tools join the ledger
/// assistant's own. Only the list is saved on this device; each token stays in
/// the Keychain, and a turn sends it as a header.
struct LedgerAgentMCPView: View {
    @ObservedObject private var settings = LedgerAgentMCPSettings.shared

    var body: some View {
        List {
            Section {
                if settings.servers.isEmpty {
                    Text("还没有接入 MCP 服务器。添加后，它的工具会跟账本工具一起出现在助手里。")
                        .balancedFont(size: 13.5)
                        .foregroundStyle(BalancedPalette.meta)
                }
                ForEach(settings.servers) { server in
                    LedgerAgentMCPRow(server: server, isOn: Binding(
                        get: { server.enabled },
                        set: { settings.setEnabled($0, for: server.id) }))
                }
                .onDelete { settings.remove(at: $0) }
            } header: { Text("服务器") } footer: {
                Text("助手调用这些工具时，调用参数会发给对应服务器。令牌只保存在本机钥匙串，不随账本导出、备份或 Git 同步。左滑删除。")
            }
        }
        .navigationTitle("MCP 服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LedgerAgentMCPEditor(server: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加服务器")
                .accessibilityIdentifier("ledger-agent-mcp-add")
            }
        }
    }
}

private struct LedgerAgentMCPRow: View {
    let server: LedgerAgentMCPServer
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            // The name opens the editor; the switch stays its own control, so
            // a tap on it never turns into a navigation.
            NavigationLink {
                LedgerAgentMCPEditor(server: server)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.title)
                        .balancedFont(size: 15)
                        .foregroundStyle(BalancedPalette.ink)
                    Text(verbatim: server.trimmedURL)
                        .balancedMono(size: 11.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .accessibilityLabel(Text("启用 \(server.title)"))
        }
    }
}

/// Adding or editing one server: name, address, optional token, and a test
/// that lists the tools it offers right now.
struct LedgerAgentMCPEditor: View {
    let server: LedgerAgentMCPServer?
    @ObservedObject private var settings = LedgerAgentMCPSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var token = ""
    @State private var enabled: Bool
    @State private var probing = false
    @State private var tools: [LedgerAgentMCPProbeTool] = []
    @State private var probeError: String?
    @State private var error: String?
    private let prober = LedgerAgentMCPProber.native

    init(server: LedgerAgentMCPServer?) {
        self.server = server
        _name = State(initialValue: server?.name ?? "")
        _url = State(initialValue: server?.url ?? "")
        _enabled = State(initialValue: server?.enabled ?? true)
    }

    private var isNew: Bool { server == nil }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && LedgerAgentMCPServer.isValid(url: trimmedURL)
    }
    private var draft: LedgerAgentMCPServer {
        LedgerAgentMCPServer(id: server?.id ?? "probe", name: name, url: url, enabled: enabled)
    }

    var body: some View {
        List {
            if let error { Section { StatusBanner(message: error) { self.error = nil } } }
            Section {
                TextField("名称", text: $name, prompt: Text("例如 我的笔记"))
                    .accessibilityIdentifier("ledger-agent-mcp-name")
                TextField("地址", text: $url, prompt: Text(verbatim: "https://mcp.example.com/mcp"))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .balancedMono(size: 13)
                    .accessibilityIdentifier("ledger-agent-mcp-url")
                SecureField(settings.hasToken(for: server?.id ?? "") && token.isEmpty ? "替换令牌（已保存）" : "令牌（可选）", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ledger-agent-mcp-token")
                Toggle("启用", isOn: $enabled)
                    .accessibilityIdentifier("ledger-agent-mcp-enabled")
            } header: { Text("连接") } footer: {
                Text("助手调用这个服务器的工具时，调用参数会发给它。需要鉴权的服务器填令牌，会作为 Authorization: Bearer 头发送，只保存在本机钥匙串。地址用 https；本机或局域网的服务可以用 http。")
            }
            Section {
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if probing { ProgressView() }
                    }
                }
                .disabled(probing || !LedgerAgentMCPServer.isValid(url: trimmedURL))
                .accessibilityIdentifier("ledger-agent-mcp-probe")
                if let probeError {
                    Text(probeError)
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.expense)
                }
                ForEach(tools) { tool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).balancedMono(size: 12.5).foregroundStyle(BalancedPalette.ink)
                        if !tool.summary.isEmpty {
                            Text(tool.summary).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                }
            } header: { Text("工具") } footer: {
                if !tools.isEmpty { Text("工具很多时，助手只接入前一部分，其余这一轮用不到。") }
            }
            if !isNew {
                Section {
                    Button("删除服务器", role: .destructive) {
                        settings.remove(id: server?.id ?? "")
                        dismiss()
                    }
                    .accessibilityIdentifier("ledger-agent-mcp-delete")
                }
            }
        }
        .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("ledger-agent-mcp-save")
            }
        }
        .onChange(of: url) { _, _ in
            tools = []
            probeError = nil
        }
    }

    private func save() {
        do {
            if let server {
                try settings.update(id: server.id, name: name, url: url, token: token.isEmpty ? nil : token)
                settings.setEnabled(enabled, for: server.id)
            } else {
                let added = try settings.add(name: name, url: url, token: token)
                settings.setEnabled(enabled, for: added.id)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func probe() async {
        probing = true
        probeError = nil
        tools = []
        defer { probing = false }
        do {
            // The field's own token wins; an untouched field falls back to the
            // one already in the Keychain.
            let saved = settings.token(for: server?.id ?? "")
            tools = try await prober.tools(for: draft, token: token.isEmpty ? saved : token)
        } catch {
            probeError = error.localizedDescription
        }
    }
}
