#if os(iOS)
import SwiftUI

/// iCloud 云盘同步 — keeps the assistant's history and memory.md in a folder
/// the user picks, so deleting the app loses nothing and other devices see
/// the same conversations. See `LedgerAgentCloudSync`.
struct LedgerAgentSyncView: View {
    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var sync = LedgerAgentCloudSync.shared
    @State private var choosingFolder = false
    @State private var confirmingStop = false
    @State private var linking: LedgerAgentSyncLayout.LedgerInfo?

    var body: some View {
        List {
            if let error = sync.error {
                Section { StatusBanner(message: error) { } }
            }
            if sync.isOn {
                Section {
                    LabeledContent("文件夹") { AgentSyncValue(text: sync.folderName ?? String(localized: "无法访问")) }
                    LabeledContent("上次同步") { AgentSyncValue(text: lastSyncedText) }
                    Button {
                        Task { await sync.syncNow() }
                    } label: {
                        HStack {
                            Text("立即同步")
                            Spacer()
                            if sync.running { ProgressView() }
                        }
                    }
                    .disabled(sync.running)
                    .accessibilityIdentifier("ledger-agent-sync-now")
                    Toggle("同步附件", isOn: $sync.includesAttachments)
                        .accessibilityIdentifier("ledger-agent-sync-attachments")
                } header: { Text("iCloud 云盘") } footer: {
                    Text("回到 App、每段对话保存后都会自动同步。附件是你发给助手的账单和图片，关掉后只同步对话和记忆。")
                }
                if !sync.otherLedgers.isEmpty {
                    Section {
                        ForEach(sync.otherLedgers) { ledger in
                            Button {
                                linking = ledger
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ledger.name).foregroundStyle(.primary)
                                    Text(otherLedgerDetail(ledger)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("云盘里的其他账本") } footer: {
                        Text("重装后账本换了名字或仓库地址时，点一下原来的账本，就会把它的聊天记录和记忆合并到当前账本。")
                    }
                }
                Section {
                    Button("停止同步", role: .destructive) { confirmingStop = true }
                        .accessibilityIdentifier("ledger-agent-sync-stop")
                }
            } else {
                Section {
                    Button("选择 iCloud 云盘文件夹") { choosingFolder = true }
                        .accessibilityIdentifier("ledger-agent-sync-choose")
                } footer: {
                    Text("在 iCloud 云盘里新建或选一个文件夹，比如「账本助手」。之后聊天记录和记忆会自动存一份到那里，删掉 App 也不会丢；重装后回到这里选同一个文件夹就能找回。别的设备选同一个文件夹，会合并成同一份记录。")
                }
            }
            Section {
                Label("聊天记录、附件和 memory.md", systemImage: "checkmark.circle")
                Label("模型选择、收藏和各项开关", systemImage: "checkmark.circle")
                Label("API key 只在本机钥匙串，不会上传", systemImage: "lock")
            } header: { Text("同步的内容") }
        }
        .font(.subheadline)
        .navigationTitle("iCloud 云盘同步")
        .terminalNativeChrome()
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .task {
            if let repository = session.localRepository { sync.attach(repository) }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { sync.choose(folder: url) }
        }
        .confirmationDialog("停止同步？", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("停止同步", role: .destructive) { sync.turnOff() }
        } message: {
            Text("本机和云盘文件夹里的记录都会保留，只是不再互相更新。")
        }
        .confirmationDialog("合并这个账本的助手数据？", isPresented: Binding(
            get: { linking != nil }, set: { if !$0 { linking = nil } }), titleVisibility: .visible, presenting: linking) { ledger in
            Button("合并到当前账本") { sync.link(to: ledger.key) }
        } message: { ledger in
            Text("「\(ledger.name)」的聊天记录和记忆会和当前账本的合并，以后两边用同一份。")
        }
    }

    private var lastSyncedText: String {
        if sync.running { return String(localized: "正在同步") }
        guard let date = sync.lastSynced else { return String(localized: "还没有同步") }
        return date.formatted(.relative(presentation: .named))
    }

    private func otherLedgerDetail(_ ledger: LedgerAgentSyncLayout.LedgerInfo) -> String {
        let date = ledger.updatedAt.formatted(date: .abbreviated, time: .shortened)
        guard let device = ledger.deviceName, !device.isEmpty else { return date }
        return device + " · " + date
    }
}

private struct AgentSyncValue: View {
    let text: String

    var body: some View {
        Text(text).foregroundStyle(.secondary).lineLimit(1)
    }
}
#endif
