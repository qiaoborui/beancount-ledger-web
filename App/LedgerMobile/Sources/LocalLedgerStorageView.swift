import SwiftUI
import UniformTypeIdentifiers

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
    @State private var choosingFolder = false

    private var providerTitle: String {
        if session.localFolderConfiguration != nil { return String(localized: "iCloud 云盘文件夹") }
        return session.localGitConfiguration == nil ? String(localized: "本机目录") : String(localized: "Git 工作区")
    }

    private var matchesConfiguration: Bool {
        guard let config = session.localGitConfiguration else { return false }
        return repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines) == config.repositoryURL.absoluteString
            && branch.trimmingCharacters(in: .whitespacesAndNewlines) == config.branch
            && token.isEmpty
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    StorageKeyRow(label: String(localized: "账本"), value: session.localLedgerName)
                    StorageKeyRow(label: String(localized: "存储提供方"), value: providerTitle)
                    if let folder = session.localFolderConfiguration {
                        StorageKeyRow(label: String(localized: "同步文件夹"), value: folder.folderName)
                    }
                    StorageKeyRow(label: String(localized: "状态"), value: statusTitle, color: statusColor)
                    if let date = status?.lastSyncedAt { StorageKeyRow(label: String(localized: "最近同步"), value: date.formatted()) }
                    if let commit = status?.baseCommit { StorageKeyRow(label: String(localized: "同步版本"), value: String(commit.prefix(12)), mono: true) }
                }
                .balancedBand(lead: true)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 18, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                Text("查询、统计、校验和保存都在本机执行。存储提供方负责版本交换，离线时仍可继续使用账本。")
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            if let error {
                Section { Text(error).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.expense).textSelection(.enabled) }
            }
            if error == nil, let message = status?.message {
                Section { Text(message).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary).textSelection(.enabled) }
            }
            if let paths = status?.conflictPaths, !paths.isEmpty {
                Section {
                    ForEach(paths, id: \.self) { path in
                        Text(path).balancedMono(size: 12.5).foregroundStyle(BalancedPalette.ink)
                            .frame(minHeight: 44, alignment: .leading)
                            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                            .textSelection(.enabled)
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    Button("保留这些文件的本机版本") { conflictChoice = true; confirmingResolution = true }
                        .buttonStyle(.balanced(.outline))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Button("采用这些文件的远端版本") { conflictChoice = false; confirmingResolution = true }
                        .buttonStyle(.balanced(.outline))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Button("导出两边版本供检查") { Task { await exportConflicts() } }
                        .buttonStyle(.balanced(.quiet))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if let conflictExport {
                        ShareLink("分享冲突文件", item: conflictExport)
                            .buttonStyle(.balanced(.quiet))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } header: { TerminalSectionLabel(text: String(localized: "需要处理的文件")).listRowBackground(BalancedPalette.page).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
            }
            if session.localGitConfiguration == nil {
                Section {
                    if session.localFolderConfiguration == nil {
                        Button("选择 iCloud 云盘文件夹") { choosingFolder = true }
                            .buttonStyle(.balanced(.primary))
                            .accessibilityIdentifier("local-folder-choose")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else {
                        Button("关闭 iCloud 云盘同步") { confirmingDisconnect = true }
                            .buttonStyle(.balanced(.quiet))
                            .accessibilityIdentifier("local-folder-disconnect")
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } header: { TerminalSectionLabel(text: String(localized: "iCloud 云盘同步")).listRowBackground(BalancedPalette.page)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                footer: {
                    Text("在“文件”中新建或选择一个 iCloud 云盘文件夹，每个账本单独使用一个。其他设备在账本库中选择“从 iCloud 云盘加入账本”并选同一个文件夹即可多设备同步。两台设备改了同一个文件时，会在这里让你选择保留哪一边。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
            if session.localFolderConfiguration == nil {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仓库地址").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        TextField("https://git.example.com/owner/ledger.git", text: $repositoryURL)
                            .balancedMono(size: 15)
                            .foregroundStyle(BalancedPalette.ink)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .textContentType(.URL).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("local-git-url")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("分支").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        TextField("分支", text: $branch)
                            .balancedMono(size: 15)
                            .foregroundStyle(BalancedPalette.ink)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("local-git-branch")
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Git 用户名（可选）").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        TextField("Git 用户名（可选）", text: $username)
                            .balancedFont(size: 15)
                            .foregroundStyle(BalancedPalette.ink)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("访问令牌").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        SecureField("访问令牌（留空保留已有凭据）", text: $token)
                            .balancedMono(size: 15)
                            .foregroundStyle(BalancedPalette.ink)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .textContentType(.password)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Button("保存存储设置") { Task { await saveConfiguration() } }
                        .buttonStyle(.balanced(.outline, disabled: repositoryURL.isEmpty || branch.isEmpty))
                        .disabled(repositoryURL.isEmpty || branch.isEmpty)
                        .accessibilityIdentifier("local-git-save")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } header: { TerminalSectionLabel(text: String(localized: "Git 存储")).listRowBackground(BalancedPalette.page)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                footer: {
                    Text("填写 HTTPS 仓库地址。令牌仅存于此设备的钥匙串。保存后将按自动同步设置交换本地与远端变更，请确认仓库和分支。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
            if session.hasLocalRemoteSync {
                Section {
                    Toggle("自动同步", isOn: Binding(get: { session.localAutomaticSyncEnabled }, set: { enabled in
                        Task { await session.setLocalAutomaticSyncEnabled(enabled); await reloadStatus() }
                    }))
                    .balancedFont(size: 15)
                    .accessibilityIdentifier("local-git-auto-sync")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Button("立即同步") {
                        if session.localFolderConfiguration != nil { Task { await synchronize() } } else { confirmingSync = true }
                    }
                        .buttonStyle(.balanced(.outline, disabled: !canSynchronize))
                        .disabled(!canSynchronize)
                        .accessibilityIdentifier("local-git-sync")
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    if session.localGitConfiguration != nil {
                        Button("改用本机存储") { confirmingDisconnect = true }
                            .buttonStyle(.balanced(.quiet))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } footer: {
                    Text("保存后自动同步，联网及回到前台时自动重试。后台同步由 iOS 调度；设备首次解锁后可在锁屏时运行。冲突或凭据失效时暂停，账本仍保存在本机。")
                        .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        .listRowBackground(BalancedPalette.page)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }
            }
        }
        .toggleStyle(BalancedToggleStyle())
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .disabled(busy || session.isStorageSyncBusy)
        .navigationTitle("存储与同步")
        .terminalNativeChrome()
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
        .confirmationDialog(session.localFolderConfiguration != nil ? Text("关闭 iCloud 云盘同步？") : Text("改用本机存储？"),
                            isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            if session.localFolderConfiguration != nil {
                Button("保留本地账本并停止同步") { Task { await disconnect() } }
            } else {
                Button("保留本地账本并断开 Git") { Task { await disconnect() } }
            }
        } message: {
            if session.localFolderConfiguration != nil {
                Text("账本文件和本地历史会保留。iCloud 云盘文件夹保持原状，其他设备仍可继续使用它同步。")
            } else {
                Text("账本文件和本地历史会保留。远端仓库保持原状。")
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(url): Task { await connectFolder(url) }
            case let .failure(error): self.error = error.localizedDescription
            }
        }
        .confirmationDialog("确认处理上面列出的冲突文件？", isPresented: $confirmingResolution, titleVisibility: .visible) {
            Button(conflictChoice == true ? "保留本机版本并校验" : "采用远端版本并校验") {
                if let choice = conflictChoice { Task { await resolveConflicts(keepingLocal: choice) } }
            }
        } message: { Text("选择将应用于上面列出的所有冲突文件。通过完整账本校验后保存为本地新版本；开启自动同步时会继续上传。") }
        .privacySensitive()
    }

    private var statusTitle: String {
        if busy || session.isStorageSyncBusy { return String(localized: "正在处理") }
        switch status?.phase {
        case .localOnly: return String(localized: "已保存到本机")
        case .pending: return String(localized: "本机可用 · 等待同步")
        case .synchronizing: return String(localized: "正在同步")
        case .synced: return String(localized: "已同步备份")
        case .conflicted: return String(localized: "需要处理冲突")
        case .failed: return String(localized: "同步失败 · 本机可用")
        case nil: return String(localized: "读取状态中")
        }
    }

    /// Direction is spent sparingly here: `--in` once sync is verified
    /// complete, `--out` only while it is paused or broken — never for an
    /// in-progress or merely local state.
    private var statusColor: Color {
        if busy || session.isStorageSyncBusy { return BalancedPalette.ink }
        switch status?.phase {
        case .synced: return BalancedPalette.income
        case .conflicted, .failed: return BalancedPalette.expense
        default: return BalancedPalette.ink
        }
    }

    private var canSynchronize: Bool {
        session.localFolderConfiguration != nil || matchesConfiguration
    }

    private func connectFolder(_ url: URL) async {
        busy = true
        defer { busy = false }
        do {
            try await session.configureLocalFolder(url)
            error = nil
            await reloadStatus()
        } catch { self.error = error.localizedDescription }
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
            if session.localFolderConfiguration != nil {
                try await session.disconnectLocalFolder()
            } else {
                try await session.disconnectLocalGit()
            }
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
    @State private var name = String(localized: "我的账本")
    @State private var repositoryURL = ""
    @State private var branch = "main"
    @State private var entrypoint = "main.bean"
    @State private var username = ""
    @State private var token = ""
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("名称", text: $name).balancedFont(size: 15)
                    TextField("入口文件", text: $entrypoint)
                        .balancedMono(size: 13.5)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { TerminalSectionLabel(text: String(localized: "账本")).listRowBackground(BalancedPalette.page).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                Section {
                    TextField("HTTPS 仓库地址", text: $repositoryURL)
                        .balancedMono(size: 13)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("local-git-clone-url")
                    TextField("分支", text: $branch)
                        .balancedMono(size: 13)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Git 用户名（可选）", text: $username)
                        .balancedFont(size: 14)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("访问令牌（私有仓库）", text: $token)
                        .balancedMono(size: 13)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { TerminalSectionLabel(text: String(localized: "Git 仓库")).listRowBackground(BalancedPalette.page).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)) }
                Section {
                    Text("下载工作区并在此设备上校验。之后所有账本功能都使用本地文件；本次添加只读取远端仓库。")
                        .balancedFont(size: 12.5)
                        .foregroundStyle(BalancedPalette.meta)
                }
                if let error = session.errorMessage {
                    Section { Text(error).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.expense) }
                }
                if session.isLocalOperationBusy { Section { ProgressView("正在下载并校验工作区") } }
            }
            .scrollContentBackground(.hidden)
            .background(BalancedPalette.page)
            .navigationTitle("添加 Git 账本")
            .terminalNativeChrome()
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

/// `.key` — a plain label/value pair on a shared baseline, used inside the
/// `.band--lead` status summary (no amount, so `BalancedKeyRow` doesn't fit).
private struct StorageKeyRow: View {
    let label: String
    let value: String
    var color: Color = BalancedPalette.ink
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).balancedFont(size: 14).foregroundStyle(BalancedPalette.secondary)
            Spacer()
            if mono {
                Text(value).balancedMono(size: 12).foregroundStyle(color)
            } else {
                Text(value).balancedFont(size: 15, weight: .text).foregroundStyle(color)
            }
        }
        .padding(.vertical, 3)
    }
}
