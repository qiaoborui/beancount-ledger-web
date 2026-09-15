import SwiftUI

struct LocalLedgerStorageView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var status: LocalStorageSyncStatus?
    @State private var repositoryURL = ""
    @State private var branch = "main"
    @State private var username = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirmingSync = false
    @State private var confirmingDisconnect = false
    @State private var conflictChoice: Bool?
    @State private var confirmingResolution = false
    @State private var conflictExport: URL?

    private var matchesConfiguration: Bool {
        guard let config = session.localGitConfiguration else { return false }
        return repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) == config.repositoryURL.absoluteString
            && branch.trimmingCharacters(in: .whitespacesAndNewlines) == config.branch
            && token.isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("账本", value: session.localLedgerName)
                LabeledContent("存储提供方", value: session.localGitConfiguration == nil ? "本机目录" : "Git 工作区")
                LabeledContent("状态", value: statusTitle)
                if let date = status?.lastSyncedAt { LabeledContent("最近同步", value: date.formatted()) }
                if let commit = status?.baseCommit { LabeledContent("同步版本", value: String(commit.prefix(12))).monospaced() }
            } footer: {
                Text("查询、统计、校验和保存都在本机执行。存储提供方负责版本交换，离线时仍可继续使用账本。")
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            if error == nil, let message = status?.message {
                Section { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let paths = status?.conflictPaths, !paths.isEmpty {
                Section("需要处理的文件") {
                    ForEach(paths, id: \.self) { Text($0).font(.footnote.monospaced()).textSelection(.enabled) }
                    Button("保留这些文件的本机版本") { conflictChoice = true; confirmingResolution = true }
                    Button("采用这些文件的远端版本") { conflictChoice = false; confirmingResolution = true }
                    Button("导出两边版本供检查") { Task { await exportConflicts() } }
                    if let conflictExport { ShareLink("分享冲突文件", item: conflictExport) }
                }
            }
            Section {
                TextField("https://git.example.com/owner/ledger.git", text: $repositoryURL)
                    .textContentType(.URL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("local-git-url")
                TextField("分支", text: $branch)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("local-git-branch")
                TextField("Git 用户名（可选）", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("访问令牌（留空保留已有凭据）", text: $token)
                    .textContentType(.password)
                Button("保存存储设置") { Task { await saveConfiguration() } }
                    .disabled(repositoryURL.isEmpty || branch.isEmpty)
                    .accessibilityIdentifier("local-git-save")
            } header: { Text("Git 存储") }
            footer: { Text("填写 HTTPS 仓库地址。令牌仅存于此设备的钥匙串。保存后将按自动同步设置交换本地与远端变更，请确认仓库和分支。") }
            if session.localGitConfiguration != nil {
                Section {
                    Toggle("自动同步", isOn: Binding(get: { session.localAutomaticSyncEnabled }, set: { enabled in
                        Task { await session.setLocalAutomaticSyncEnabled(enabled); await reloadStatus() }
                    }))
                    .accessibilityIdentifier("local-git-auto-sync")
                    Button("立即同步") { confirmingSync = true }
                        .disabled(!matchesConfiguration)
                        .accessibilityIdentifier("local-git-sync")
                    Button("改用本机存储") { confirmingDisconnect = true }
                } footer: {
                    Text("保存后自动同步，联网及回到前台时自动重试。后台同步由 iOS 调度；设备首次解锁后可在锁屏时运行。冲突或凭据失效时暂停，账本仍保存在本机。")
                }
            }
        }
        .disabled(busy || session.isStorageSyncBusy)
        .navigationTitle("存储与同步")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let config = session.localGitConfiguration {
                repositoryURL = config.repositoryURL.absoluteString
                branch = config.branch
            }
            await reloadStatus()
        }
        .refreshable { await reloadStatus() }
        .onChange(of: session.localSyncStatus) { _, value in
            if let value { status = value }
        }
        .confirmationDialog("同步这个 Git 工作区？", isPresented: $confirmingSync, titleVisibility: .visible) {
            Button("拉取、校验并推送") { Task { await synchronize() } }
        } message: { Text("\(repositoryURL)\n分支：\(branch)\n本地和远端已保存的变更将交换并校验。") }
        .confirmationDialog("改用本机存储？", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("保留本地账本并断开 Git") { Task { await disconnect() } }
        } message: { Text("账本文件和本地历史会保留。远端仓库保持原状。") }
        .confirmationDialog("确认处理上面列出的冲突文件？", isPresented: $confirmingResolution, titleVisibility: .visible) {
            Button(conflictChoice == true ? "保留本机版本并校验" : "采用远端版本并校验") {
                if let choice = conflictChoice { Task { await resolveConflicts(keepingLocal: choice) } }
            }
        } message: { Text("选择将应用于上面列出的所有冲突文件。通过完整账本校验后保存为本地新版本；开启自动同步时会继续上传。") }
        .privacySensitive()
    }

    private var statusTitle: String {
        if busy || session.isStorageSyncBusy { return "正在处理" }
        switch status?.phase {
        case .localOnly: return "已保存到本机"
        case .pending: return "本机可用 · 等待同步"
        case .synchronizing: return "正在同步"
        case .synced: return "已同步备份"
        case .conflicted: return "需要处理冲突"
        case .failed: return "同步失败 · 本机可用"
        case nil: return "读取状态中"
        }
    }

    private func reloadStatus() async {
        do { status = try await session.localRepository?.storageStatus() }
        catch { self.error = error.localizedDescription }
    }

    private func saveConfiguration() async {
        busy = true
        defer { busy = false }
        do {
            let credential = token.isEmpty ? nil : LocalGitCredential(username: username.isEmpty ? "git" : username, token: token)
            try await session.configureLocalGit(repositoryURL: repositoryURL, branch: branch, credential: credential)
            token = ""
            if let config = session.localGitConfiguration { repositoryURL = config.repositoryURL.absoluteString; branch = config.branch }
            error = nil
            await reloadStatus()
        } catch { self.error = error.localizedDescription }
    }

    private func synchronize() async {
        do { status = try await session.synchronizeLocalStorage(); error = nil }
        catch { self.error = error.localizedDescription; await reloadStatus() }
    }

    private func disconnect() async {
        busy = true
        defer { busy = false }
        do {
            try await session.disconnectLocalGit()
            repositoryURL = ""; token = ""; username = ""; conflictExport = nil
            error = nil
            await reloadStatus()
        } catch { self.error = error.localizedDescription }
    }

    private func exportConflicts() async {
        do { conflictExport = try await session.localRepository?.exportSyncConflictVersions() }
        catch { self.error = error.localizedDescription }
    }

    private func resolveConflicts(keepingLocal: Bool) async {
        busy = true
        defer { busy = false }
        do {
            status = try await session.resolveLocalStorageConflicts(keepingLocal: keepingLocal)
            error = nil
        } catch { self.error = error.localizedDescription; await reloadStatus() }
    }
}

struct GitLedgerSetupView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = "我的账本"
    @State private var repositoryURL = ""
    @State private var branch = "main"
    @State private var entrypoint = "main.bean"
    @State private var username = ""
    @State private var token = ""
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("账本") {
                    TextField("名称", text: $name)
                    TextField("入口文件", text: $entrypoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Git 仓库") {
                    TextField("HTTPS 仓库地址", text: $repositoryURL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("local-git-clone-url")
                    TextField("分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Git 用户名（可选）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("访问令牌（私有仓库）", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("下载工作区并在此设备上校验。之后所有账本功能都使用本地文件；本次添加只读取远端仓库。")
                        .foregroundStyle(.secondary)
                }
                if let error = session.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                if session.isLocalOperationBusy { Section { ProgressView("正在下载并校验工作区") } }
            }
            .navigationTitle("添加 Git 账本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { operation?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        operation = Task {
                            let credential = token.isEmpty ? nil : LocalGitCredential(username: username.isEmpty ? "git" : username, token: token)
                            await session.importGitLedger(repositoryURL: repositoryURL, branch: branch,
                                name: name, entrypoint: entrypoint, credential: credential)
                            if session.phase == .ready { token = ""; dismiss() }
                        }
                    }
                    .disabled(session.isLocalOperationBusy || repositoryURL.isEmpty || name.isEmpty || branch.isEmpty || entrypoint.isEmpty)
                }
            }
            .interactiveDismissDisabled(session.isLocalOperationBusy)
            .onDisappear { operation?.cancel(); token = "" }
        }
    }
}
