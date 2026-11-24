import SwiftUI
import UniformTypeIdentifiers

/// First-run setup as one conversation. With no ledger on the device the app
/// opens here instead of on the library: the assistant greets the user and
/// asks which way they want in. The greeting, the choice of way, connecting
/// a Git repository and the file based ways are scripted on the device and
/// need no model. Building from scratch is a conversation with the model; a
/// card in the conversation connects one first when there is none.
///
/// Secrets (the model's API key, a repository token) are only ever typed into
/// native cards, kept in the keychain, and never become conversation text.
struct LedgerSetupView: View {
    /// Set when the page is presented over the library: a close button joins
    /// the bar. As the first screen there is nothing to close to.
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var session: LedgerSession
    @ObservedObject private var settings = LedgerAgentSettings.shared
    @StateObject private var conversation = LedgerOnboardingConversation()

    /// One scripted line of the conversation, said by the app or the user.
    private struct Line: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    private enum Importer { case joinFolder, backup }

    @State private var path: LedgerSetupPath?
    @State private var lines: [Line] = []
    /// What the user typed on the welcome screen before choosing building
    /// from scratch; it opens the model's conversation once one is connected.
    @State private var firstWords: String?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    // Git
    @State private var gitURL = ""
    @State private var gitBranch = "main"
    @State private var gitUser = ""
    @State private var gitToken = ""
    @State private var gitEntrypoint = "main.bean"
    @State private var gitAdvanced = false
    @State private var gitTask: Task<Void, Never>?
    @State private var gitFailure: String?

    // Model
    @State private var modelKey = ""
    @State private var modelFailure: String?

    // From scratch
    @State private var picked: Set<String> = []
    @State private var planPresented = false
    @State private var creating = false
    /// The token and username for a from-scratch ledger stored in Git: kept
    /// on the page until 创建账本 puts them in the keychain.
    @State private var storageToken = ""
    @State private var storageUser = ""

    // Other ways
    @State private var importer: Importer?
    @State private var settingsPresented = false
    @State private var wizardPresented = false
    @State private var folderImportPresented = false
    @State private var iCloudJoinPresented = false
    @State private var emptyLedgerPresented = false

    private var plan: LedgerOnboardingDraft { conversation.state.draft }
    private var aiStarted: Bool { path == .scratch && conversation.hasStarted }
    private var busy: Bool { creating || session.isLocalOperationBusy }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if path == nil { welcome } else { thread }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if aiStarted { progress.padding(.horizontal, 12).padding(.bottom, 6) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                .onChange(of: lines.count) { _, _ in scrollDown(proxy) }
                .onChange(of: conversation.messages.count) { _, _ in
                    picked = []
                    scrollDown(proxy)
                }
                .onChange(of: conversation.live.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: session.isLocalOperationBusy) { _, _ in scrollDown(proxy) }
            }
            .background(BalancedPalette.page)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .terminalNativeChrome()
            .toolbar { toolbar }
            .balancedRoundedControls()
        }
        .sheet(isPresented: $settingsPresented) {
            // No ledger yet, so only the model and key page applies.
            NavigationStack { LedgerAgentSettingsView(modelOnly: true) }.ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $wizardPresented) { OnboardingWizardView() }
        .sheet(isPresented: $folderImportPresented) { LocalLedgerSetupView(importing: true) }
        .sheet(isPresented: $iCloudJoinPresented) { ICloudJoinSheet { importer = .joinFolder } }
        .sheet(isPresented: $emptyLedgerPresented) { LocalLedgerSetupView(importing: false) }
        .sheet(isPresented: $planPresented) { planSheet }
        .fileImporter(isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                      allowedContentTypes: importer == .joinFolder ? [.folder] : [.item]) { result in
            let mode = importer
            importer = nil
            switch result {
            case let .success(url):
                Task {
                    if mode == .joinFolder { await session.importFolderLedger(url) }
                    else { await session.restoreLedgerBackupAsNew(fileAt: url) }
                }
            case let .failure(error): session.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: settings.isReady) { _, ready in
            if ready, path == .scratch { conversation.start(saying: firstWords) }
        }
        // 确认创建 and a connected repository hand over to the assistant once
        // this page is gone; the cover cannot present into its dismissal.
        .onAppear { session.aiOnboardingOnScreen = true }
        .onDisappear {
            session.aiOnboardingOnScreen = false
            conversation.stop()
            gitTask?.cancel()
            gitToken = ""
            modelKey = ""
        }
        .task { await session.refreshLocalLedgers() }
    }

    private var title: String {
        switch path {
        case nil: ""
        case .scratch: String(localized: "新建账本")
        case .git: String(localized: "接入 Git 账本")
        case .other: String(localized: "其他方式")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if let onClose {
                Button { conversation.stop(); onClose() } label: { Image(systemName: "xmark") }
                    .disabled(busy)
                    .accessibilityLabel("关闭")
            } else if path != nil {
                Button { restart() } label: { Image(systemName: "arrow.counterclockwise") }
                    .disabled(busy)
                    .accessibilityLabel("重新开始")
                    .accessibilityIdentifier("ledger-setup-restart")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if onClose != nil, path != nil {
                    Button { restart() } label: { Label("重新开始", systemImage: "arrow.counterclockwise") }
                }
                Button { wizardPresented = true } label: { Label("手动开账向导", systemImage: "list.bullet.rectangle") }
                    .accessibilityIdentifier("local-ledger-open-wizard")
                Button { emptyLedgerPresented = true } label: { Label("新建空账本", systemImage: "doc.badge.plus") }
                    .accessibilityIdentifier("local-ledger-create")
                Divider()
                Button { iCloudJoinPresented = true } label: { Label("从 iCloud 加入账本", systemImage: "icloud") }
                    .accessibilityIdentifier("local-ledger-join-folder")
                Button { folderImportPresented = true } label: { Label("导入账本文件夹", systemImage: "folder") }
                    .accessibilityIdentifier("local-ledger-import")
                Button { importer = .backup } label: { Label("从备份恢复", systemImage: "clock.arrow.circlepath") }
                    .accessibilityIdentifier("local-ledger-restore-backup")
                Divider()
                Button { settingsPresented = true } label: { Label("模型与 API Key", systemImage: "key") }
                    .accessibilityIdentifier("ledger-setup-model-settings")
            } label: {
                Image(systemName: "ellipsis")
            }
            .disabled(busy)
            .accessibilityLabel("更多开账方式")
            .accessibilityIdentifier("ledger-setup-more")
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                LedgerMarkCanvas(progress: 1)
                    .frame(width: 60, height: 60)
                    .padding(.bottom, -8)
                    .accessibilityHidden(true)
                Text("你好，我是账本助手")
                    .font(BalancedReading.font(.regular, size: 28, relativeTo: .title))
                    .foregroundStyle(BalancedPalette.secondary)
                Text("先帮你把账本准备好。你现在是哪种情况？")
                    .balancedFont(size: 15).foregroundStyle(BalancedPalette.meta)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 28)

            VStack(spacing: 10) {
                pathCard(.scratch, title: String(localized: "从零新建一本"),
                         detail: String(localized: "聊几句，按你用的卡、钱包和习惯搭好"), symbol: "plus", prominent: true)
                    .accessibilityIdentifier("local-ledger-open-ai-onboarding")
                pathCard(.git, title: String(localized: "接入已有的 Git 账本"),
                         detail: String(localized: "GitHub、Gitea 等仓库里的 Beancount 账本"),
                         symbol: "arrow.triangle.branch", prominent: false)
                    .accessibilityIdentifier("local-ledger-add-git")
            }
            .padding(.top, 24)

            HStack(spacing: 6) {
                chip(String(localized: "iCloud 里的账本")) { iCloudJoinPresented = true }
                chip(String(localized: "本机文件夹")) { folderImportPresented = true }
                chip(String(localized: "从备份恢复")) { importer = .backup }
            }
            .padding(.top, 14)

            Text("账本只存放在这台设备上。确认之前，不会创建或写入任何文件。")
                .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 16)
            if session.isLocalOperationBusy { ProgressView("正在打开账本").padding(.top, 16) }
            if let error = session.errorMessage {
                StatusBanner(message: error, onDismiss: session.dismissError).padding(.top, 12)
            }
        }
        .padding(.horizontal, 16)
    }

    private func pathCard(_ way: LedgerSetupPath, title: String, detail: String, symbol: String, prominent: Bool) -> some View {
        Button { choose(way, said: title) } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                    .foregroundStyle(prominent ? BalancedPalette.page : BalancedPalette.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(prominent ? BalancedPalette.page.opacity(0.14) : BalancedPalette.page))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).balancedFont(size: 16, weight: .medium)
                        .foregroundStyle(prominent ? BalancedPalette.page : BalancedPalette.ink)
                    Text(detail).balancedFont(size: 12.5)
                        .foregroundStyle(prominent ? BalancedPalette.page.opacity(0.7) : BalancedPalette.meta)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(prominent ? BalancedPalette.page.opacity(0.6) : BalancedPalette.edge)
            }
            .padding(16)
            .background(prominent ? BalancedPalette.ink : BalancedPalette.sunken,
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(Capsule().stroke(BalancedPalette.ruleStrong, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: Conversation

    @ViewBuilder
    private var thread: some View {
        ForEach(lines) { line in
            if line.fromUser { userBubble(line.text) } else { reply(line.text) }
        }
        switch path {
        case .git: gitCard
        case .other: otherCard
        case .scratch:
            if settings.isReady || conversation.hasStarted { aiThread } else { modelCard }
        case nil: EmptyView()
        }
        if path != .scratch || !conversation.hasStarted, let error = session.errorMessage, path != .git {
            StatusBanner(message: error, onDismiss: session.dismissError).padding(.horizontal, 16)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 48)
            Text(text).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                .lineSpacing(4)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: LedgerRound.bubble, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private func reply(_ text: String) -> some View {
        LedgerAgentStreamingReply(text: text, streaming: false)
            .padding(.horizontal, 20)
    }

    private func cardHeader(_ title: String, lock: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.ink)
            Spacer(minLength: 8)
            if let lock {
                Label(lock, systemImage: "lock.fill").labelStyle(.titleAndIcon)
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.income)
            }
        }
        .padding(.horizontal, 4)
    }

    private func fieldRow<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 10) {
            Text(label).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
                .frame(width: 64, alignment: .leading)
            field()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    // MARK: Git

    private var gitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(String(localized: "连接 Git 仓库"), lock: String(localized: "令牌只存钥匙串"))
            VStack(spacing: 0) {
                fieldRow(String(localized: "地址")) {
                    TextField("https://github.com/你/账本", text: $gitURL)
                        .balancedMono(size: 13)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("local-git-clone-url")
                }
                Divider().overlay(BalancedPalette.rule)
                fieldRow(String(localized: "分支")) {
                    TextField("main", text: $gitBranch)
                        .balancedMono(size: 13)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Divider().overlay(BalancedPalette.rule)
                fieldRow(String(localized: "令牌")) {
                    SecureField(String(localized: "私有仓库需要"), text: $gitToken)
                        .balancedMono(size: 13)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("ledger-setup-git-token")
                }
                if gitAdvanced {
                    Divider().overlay(BalancedPalette.rule)
                    fieldRow(String(localized: "用户名")) {
                        TextField(String(localized: "可选"), text: $gitUser)
                            .balancedFont(size: 14)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Divider().overlay(BalancedPalette.rule)
                    fieldRow(String(localized: "入口文件")) {
                        TextField("main.bean", text: $gitEntrypoint)
                            .balancedMono(size: 13)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
            }
            .ledgerInsetWell()
            .disabled(session.isLocalOperationBusy)

            HStack(spacing: 6) {
                Text("令牌不会出现在对话里，也不会发给模型。")
                Spacer(minLength: 4)
                if !gitAdvanced {
                    Button("更多选项") { withAnimation(.snappy) { gitAdvanced = true } }
                        .buttonStyle(.plain)
                        .foregroundStyle(BalancedPalette.ink)
                }
            }
            .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            .padding(.horizontal, 4)

            if session.isLocalOperationBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在下载仓库并在本机校验…").balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .ledgerInsetWell()
                .accessibilityIdentifier("ledger-setup-git-progress")
            } else if let gitFailure {
                VStack(alignment: .leading, spacing: 4) {
                    Text("没有连上").balancedFont(size: 14, weight: .medium).foregroundStyle(BalancedPalette.expense)
                    Text(gitFailure).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                        .textSelection(.enabled)
                    Text(gitHint(for: gitFailure)).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                }
                .padding(.horizontal, 4)
                .accessibilityIdentifier("ledger-setup-git-error")
            }

            Button {
                connectGit()
            } label: {
                if session.isLocalOperationBusy { ProgressView().tint(BalancedPalette.page) } else { Text(gitFailure == nil ? "连接" : "再试一次") }
            }
            .buttonStyle(.balanced(.primary))
            .disabled(!canConnectGit)
            .accessibilityIdentifier("ledger-setup-git-connect")
        }
        .ledgerCard(padding: 12)
        .padding(.horizontal, 16)
    }

    private var canConnectGit: Bool {
        !session.isLocalOperationBusy
            && LedgerSetupScript.gitRepository(in: gitURL) != nil
            && !gitBranch.trimmingCharacters(in: .whitespaces).isEmpty
            && !gitEntrypoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One line on what usually fixes a failed clone, read off the error.
    private func gitHint(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("403") || lower.contains("auth") || message.contains("认证") || message.contains("权限") {
            return String(localized: "看看令牌是否填对、是否有这个仓库的读写权限。")
        }
        if lower.contains("404") || message.contains("找不到") || lower.contains("not found") {
            return String(localized: "看看地址和分支是否正确；私有仓库不填令牌时也会显示找不到。")
        }
        if lower.contains(".bean") || message.contains("入口") {
            return String(localized: "入口文件不是 main.bean 的话，在「更多选项」里改。")
        }
        return String(localized: "检查网络和地址后再试一次。")
    }

    private func connectGit() {
        guard canConnectGit, let address = LedgerSetupScript.gitRepository(in: gitURL) else { return }
        composerFocused = false
        gitFailure = nil
        session.dismissError()
        let token = gitToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = gitUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.isEmpty ? nil : LocalGitCredential(username: user.isEmpty ? "git" : user, token: token)
        let name = LedgerSetupScript.ledgerName(forRepository: address)
        gitTask = Task {
            await session.importGitLedger(repositoryURL: address, branch: gitBranch.trimmingCharacters(in: .whitespaces),
                                          name: name, entrypoint: gitEntrypoint.trimmingCharacters(in: .whitespaces),
                                          credential: credential)
            if session.phase == .ready {
                gitToken = ""
                // The assistant opens on the connected ledger with what to
                // do next, the way it does after building one.
                session.openAgent(with: .connected(name: name))
                onClose?()
            } else if let error = session.errorMessage {
                gitFailure = error
                session.dismissError()
            }
        }
    }

    // MARK: Other ways

    private var otherCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            otherRow(String(localized: "iCloud 里的账本"), String(localized: "另一台设备已开启 iCloud 同步的账本"), "icloud") { iCloudJoinPresented = true }
            otherRow(String(localized: "本机文件夹"), String(localized: "已有 .bean 文件，直接接管"), "folder") { folderImportPresented = true }
            otherRow(String(localized: "从备份恢复"), String(localized: "选择 .ledgerbackup 文件"), "clock.arrow.circlepath") { importer = .backup }
            otherRow(String(localized: "手动开账向导"), String(localized: "不聊天，用表单选账户和分类"), "list.bullet.rectangle") { wizardPresented = true }
            if session.isLocalOperationBusy {
                ProgressView("正在打开账本").padding(.top, 6).frame(maxWidth: .infinity)
            }
        }
        .ledgerCard(padding: 12)
        .padding(.horizontal, 16)
    }

    private func otherRow(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(BalancedPalette.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                    Text(detail).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BalancedPalette.edge)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .background(BalancedPalette.page, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(BalancedPalette.rule, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    // MARK: Model

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(String(localized: "接上模型"), lock: String(localized: "只存钥匙串"))
            VStack(spacing: 0) {
                fieldRow(String(localized: "服务")) {
                    Menu {
                        ForEach(settings.catalog.providers) { provider in
                            Button(provider.title) { settings.select(provider: provider.id); modelFailure = nil }
                        }
                    } label: {
                        menuLabel(settings.providerTitle)
                    }
                    .accessibilityIdentifier("ledger-setup-provider")
                }
                Divider().overlay(BalancedPalette.rule)
                fieldRow(String(localized: "模型")) {
                    if settings.choice.isCustom {
                        Button { settingsPresented = true } label: { menuLabel(String(localized: "在设置里填地址和模型")) }
                            .buttonStyle(.plain)
                    } else {
                        Menu {
                            ForEach(settings.catalog.provider(settings.choice.provider)?.models ?? []) { model in
                                Button(model.title) { settings.select(model: model.id) }
                            }
                        } label: {
                            menuLabel(settings.modelTitle)
                        }
                    }
                }
                Divider().overlay(BalancedPalette.rule)
                fieldRow("API Key") {
                    SecureField(String(localized: "粘贴你的 Key"), text: $modelKey)
                        .balancedMono(size: 13)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(saveModelKey)
                        .accessibilityIdentifier("ledger-setup-model-key")
                }
            }
            .ledgerInsetWell()
            Text(modelFailure ?? String(localized: "对话只发给你选的服务。Key 不会出现在对话里，也不随账本同步。"))
                .balancedFont(size: 12)
                .foregroundStyle(modelFailure == nil ? BalancedPalette.meta : BalancedPalette.expense)
                .padding(.horizontal, 4)
            Button("保存并继续", action: saveModelKey)
                .buttonStyle(.balanced(.primary))
                .disabled(modelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !settings.choice.isComplete)
                .accessibilityIdentifier("ai-onboarding-setup-model")
            HStack(spacing: 0) {
                Button("更多设置") { settingsPresented = true }.buttonStyle(.balanced(.quiet))
                Button("不用 AI，用表单向导") { wizardPresented = true }.buttonStyle(.balanced(.quiet))
                    .accessibilityIdentifier("ai-onboarding-skip")
            }
        }
        .ledgerCard(padding: 12)
        .padding(.horizontal, 16)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: text).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .medium))
                .foregroundStyle(BalancedPalette.meta)
        }
        .contentShape(Rectangle())
    }

    private func saveModelKey() {
        do {
            try settings.saveKey(modelKey)
            modelKey = ""
            modelFailure = nil
            // `settings.isReady` turning true starts the conversation.
        } catch {
            modelFailure = (error as? LedgerAgentError)?.headline ?? error.localizedDescription
        }
    }

    // MARK: From scratch, with the model

    @ViewBuilder
    private var aiThread: some View {
        ForEach(conversation.messages) { message in
            switch message.role {
            case .user: userBubble(message.text)
            case .assistant: answer(message)
            }
        }
        if conversation.isRunning { running }
        if let error = conversation.error { failure(error) }
        if conversation.state.canCreate && !conversation.isRunning { createCard }
        if let error = session.errorMessage {
            StatusBanner(message: error, onDismiss: session.dismissError).padding(.horizontal, 16)
        }
    }

    private func answer(_ message: LedgerOnboardingConversation.Message) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.text.isEmpty {
                LedgerAgentStreamingReply(text: message.text, streaming: false) { send($0) }
                    .padding(.horizontal, 20)
            }
            if let ask = message.ask, message.id == conversation.messages.last?.id, conversation.pendingAsk != nil {
                LedgerAskCard(ask: ask, picked: $picked, identifier: "ai-onboarding-choice", disabled: creating) { send($0) }
                    .padding(.horizontal, 16)
            }
            if let card = message.card, message.id == conversation.messages.last?.id, conversation.pendingCard != nil {
                LedgerOnboardingCardView(card: card, draft: plan, gitToken: $storageToken, gitUser: $storageUser,
                                         disabled: creating) { answer in
                    composerFocused = false
                    conversation.submit(answer)
                }
                .id(message.id)
                .padding(.horizontal, 16)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !conversation.live.text.isEmpty {
                LedgerAgentStreamingReply(text: conversation.live.text, reveals: true)
            }
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(BalancedPalette.meta)
                Text(conversation.status ?? String(localized: "正在思考"))
                    .balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ai-onboarding-running")
        }
        .padding(.horizontal, 20)
    }

    private func failure(_ error: LedgerAgentError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(error.headline).balancedFont(size: 15, weight: .medium).foregroundStyle(BalancedPalette.expense)
            if let detail = error.detail {
                Text(detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary).lineLimit(4)
            }
            HStack(spacing: 10) {
                if case .notConfigured = error {
                    Button("设置模型") { settingsPresented = true }.buttonStyle(.balanced())
                } else {
                    Button("重试") { conversation.retry() }.buttonStyle(.balanced())
                    if case .invalidKey = error {
                        Button("设置模型") { settingsPresented = true }.buttonStyle(.balanced(.quiet))
                    }
                }
            }
        }
        .ledgerCard(padding: 14)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("ai-onboarding-error")
    }

    /// The plan is ready: what will be created, and the one button that
    /// creates it. The full structure is a tap away in the sheet.
    private var createCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(plan.title)
            Text(planSummary).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary).padding(.horizontal, 4)
            HStack(spacing: 8) {
                Button("查看结构") { planPresented = true }
                    .buttonStyle(.balanced())
                    .accessibilityIdentifier("ai-onboarding-review")
                Button { create() } label: {
                    if creating { ProgressView().tint(BalancedPalette.page) } else { Text("创建账本") }
                }
                .buttonStyle(.balanced(.primary))
                .disabled(busy)
                .accessibilityIdentifier("ai-onboarding-create")
            }
        }
        .ledgerCard(padding: 12)
        .padding(.horizontal, 16)
    }

    private var planSummary: String {
        let categories = plan.incomeCategories.count + plan.expenseCategories.count
        let start = plan.startDate.isEmpty ? String(localized: "期初为创建当天") : String(localized: "期初 \(plan.startDate)")
        let base = String(localized: "\(plan.accounts.count) 个账户 · \(categories) 个分类 · \(plan.currency) · \(start)")
        if plan.isICloudStorage { return base + String(localized: " · 存进 iCloud") }
        return plan.isGitStorage ? base + String(localized: " · 同步到 Git") : base
    }

    /// What the draft already holds and what it still needs, as one glass
    /// capsule over the conversation; a tap opens the structure.
    private var progress: some View {
        let state = conversation.state
        return Button { planPresented = true } label: {
            HStack(spacing: 4) {
                ForEach(state.coverage.items) { item in
                    Text(item.label)
                        .balancedFont(size: 12)
                        .foregroundStyle(item.isDone ? BalancedPalette.ink : BalancedPalette.meta)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(minHeight: 26)
                        .background(Capsule().fill(item.isDone ? BalancedPalette.meta.opacity(0.14) : .clear))
                }
                Spacer(minLength: 4)
                Image(systemName: state.canCreate ? "checkmark.circle.fill" : "chevron.down")
                    .font(.system(size: state.canCreate ? 15 : 11, weight: .semibold))
                    .foregroundStyle(state.canCreate ? BalancedPalette.income : BalancedPalette.meta)
                    .padding(.trailing, 6)
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .modifier(LedgerSetupStripGlass())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.canCreate ? String(localized: "方案已就绪，查看账本结构") : state.coverage.summary)
        .accessibilityIdentifier("ai-onboarding-progress")
    }

    private var planIsEmpty: Bool {
        plan.accounts.isEmpty && plan.incomeCategories.isEmpty && plan.expenseCategories.isEmpty
    }

    private var planSheet: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if planIsEmpty {
                        Text("还没有内容。回答问题后，账户和分类会出现在这里。")
                            .balancedFont(size: 14.5).foregroundStyle(BalancedPalette.secondary).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ledgerCard(padding: 16)
                    } else {
                        planBand
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(BalancedPalette.page)
            .navigationTitle("账本结构")
            .navigationBarTitleDisplayMode(.inline)
            .terminalNativeChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { planPresented = false } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if conversation.state.canCreate && !conversation.isRunning {
                    Button("创建「\(plan.title)」") { planPresented = false; create() }
                        .buttonStyle(.balanced(.primary))
                        .disabled(busy)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("ai-onboarding-plan-create")
                }
            }
            .balancedRoundedControls()
        }
        .presentationDetents([.medium, .large])
        .ledgerPrivacyProtectedSheet()
    }

    /// The draft as the next 创建 would write it, in the user's words,
    /// never as account paths.
    private var planBand: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(plan.title).balancedFont(size: 17, weight: .medium).foregroundStyle(BalancedPalette.ink)
                Spacer()
                Text(conversation.state.canCreate ? String(localized: "方案已就绪") : String(localized: "整理中"))
                    .balancedFont(size: 12).foregroundStyle(conversation.state.canCreate ? BalancedPalette.income : BalancedPalette.meta)
            }
            Text(plan.startDate.isEmpty ? String(localized: "\(plan.currency) · 期初为创建当天") : String(localized: "\(plan.currency) · 期初 \(plan.startDate)"))
                .balancedMono(size: 12).foregroundStyle(BalancedPalette.meta)
            ForEach(plan.accountGroups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(LedgerOnboardingDraft.kindTitle(group.kind))
                        .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        .padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(group.accounts.enumerated()), id: \.element.id) { index, account in
                            if index > 0 { Divider().overlay(BalancedPalette.rule) }
                            HStack(alignment: .firstTextBaseline) {
                                Text(account.name).balancedFont(size: 15).foregroundStyle(BalancedPalette.ink)
                                Spacer(minLength: 12)
                                if !account.openingBalance.isEmpty {
                                    Text(balanceText(account))
                                        .balancedMono(size: 13)
                                        .foregroundStyle(account.isLiability ? BalancedPalette.expense : BalancedPalette.ink)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 42)
                        }
                    }
                    .ledgerInsetWell()
                }
            }
            categories(String(localized: "收入分类"), plan.incomeCategories)
            categories(String(localized: "支出分类"), plan.expenseCategories)
            planSettings
            planFiles
        }
        .ledgerCard(padding: 14)
        .accessibilityIdentifier("ai-onboarding-plan")
    }

    /// Where the ledger will live and which bills it is set up to import.
    private var planSettings: some View {
        VStack(spacing: 0) {
            settingRow(String(localized: "存放"), plan.isGitStorage
                       ? String(localized: "Git · \(URL(string: plan.remote)?.host ?? plan.remote)")
                       : plan.isICloudStorage ? "iCloud" : String(localized: "这台设备"))
            Divider().overlay(BalancedPalette.rule).padding(.leading, 14)
            settingRow(String(localized: "导入"), plan.importChannels.isEmpty
                       ? String(localized: "还没选，先备好支付宝和微信")
                       : plan.importChannels.map(LedgerOnboardingDraft.channelTitle).joined(separator: String(localized: "、")))
        }
        .ledgerInsetWell()
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta).frame(width: 40, alignment: .leading)
            Text(value).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The files 创建账本 will write, each one a tap away from its text,
    /// so what is created is what was seen.
    private var planFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("会写入的文件").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
            VStack(spacing: 0) {
                let files = plan.files(today: LedgerOnboardingConversation.localDay())
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { Divider().overlay(BalancedPalette.rule).padding(.leading, 14) }
                    DisclosureGroup {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(file.content)
                                .balancedMono(size: 11.5).foregroundStyle(BalancedPalette.secondary)
                                .textSelection(.enabled)
                                .fixedSize()
                                .padding(10)
                        }
                        .background(BalancedPalette.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 8)
                    } label: {
                        Text(file.path).balancedMono(size: 13).foregroundStyle(BalancedPalette.ink)
                    }
                    .tint(BalancedPalette.meta)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .ledgerInsetWell()
        }
        .accessibilityIdentifier("ai-onboarding-plan-files")
    }

    private func balanceText(_ account: LedgerOnboardingDraft.Account) -> String {
        let currency = account.currency.isEmpty ? plan.currency : account.currency
        return account.isLiability
            ? String(localized: "欠 \(account.openingBalance) \(currency)")
            : "\(account.openingBalance) \(currency)"
    }

    @ViewBuilder
    private func categories(_ title: String, _ items: [LedgerOnboardingDraft.Category]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 4)
                LedgerSetupFlow(spacing: 6) {
                    ForEach(items) { item in
                        Text(item.name).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.ink)
                            .padding(.horizontal, 11)
                            .frame(minHeight: 30)
                            .background(Capsule().fill(BalancedPalette.page))
                            .overlay(Capsule().stroke(BalancedPalette.rule, lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func create() {
        let plan = plan
        let token = storageToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = storageUser.trimmingCharacters(in: .whitespacesAndNewlines)
        creating = true
        composerFocused = false
        Task {
            await session.createCustomLocalLedger(name: plan.title, currency: plan.currency,
                                                  accounts: plan.accountSelections, categories: plan.categorySelections,
                                                  openingDate: plan.startDate.isEmpty ? nil : plan.startDate,
                                                  layout: .split, importChannels: plan.importChannels)
            guard session.phase == .ready else { creating = false; return }
            // A ledger stored in Git is pushed to its empty repository now;
            // if that fails the ledger is still here, and the greeting says
            // where to retry.
            var storageNote: String?
            if plan.isGitStorage {
                let host = URL(string: plan.remote)?.host ?? plan.remote
                do {
                    try await session.configureLocalGit(repositoryURL: plan.remote, branch: "main",
                        credential: token.isEmpty ? nil : LocalGitCredential(username: user, token: token))
                    do {
                        _ = try await session.synchronizeLocalStorage()
                        storageNote = String(localized: "已经推到 \(host) 上的仓库，之后记的账会自动同步。")
                    } catch {
                        storageNote = String(localized: "已经连上 \(host) 上的仓库，第一次推送还没完成（\(error.localizedDescription)），之后会自动重试，也可以在设置的「存储」里手动同步。")
                    }
                } catch {
                    storageNote = String(localized: "没能连上 \(host)：\(error.localizedDescription)。账本已经存在这台设备上，可以在设置的「存储」里再接 Git。")
                }
                session.dismissError()
            } else if plan.isICloudStorage {
                // Like Git: the ledger is already here, so a failure only
                // changes what the greeting says.
                do {
                    try await session.configureLocalICloud()
                    do {
                        _ = try await session.synchronizeLocalStorage()
                        storageNote = String(localized: "已经存进 iCloud，之后记的账会自动同步到你的其他设备。")
                    } catch {
                        storageNote = String(localized: "已经开启 iCloud 同步，第一次上传还没完成（\(error.localizedDescription)），之后会自动重试。")
                    }
                } catch {
                    storageNote = String(localized: "没能开启 iCloud 同步：\(error.localizedDescription)。账本已经存在这台设备上，可以在设置的「存储」里再开。")
                }
                session.dismissError()
            }
            storageToken = ""
            creating = false
            // The assistant takes over from here: it opens with what was just
            // created and a few next steps.
            session.openAgent(with: LedgerAgentOpening(draft: plan, storageNote: storageNote))
            onClose?()
        }
    }

    // MARK: Composer

    private var placeholder: String {
        switch path {
        case nil: String(localized: "也可以直接说你的情况")
        case .git: String(localized: "可以直接贴仓库链接")
        case .other: String(localized: "选一种方式，或者说说你的情况")
        case .scratch: conversation.hasStarted ? String(localized: "回答问题，或补充想调整的地方") : String(localized: "说说你平时用哪些卡和钱包")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !busy
            && !(path == .scratch && conversation.hasStarted && conversation.isRunning)
    }

    private var composer: some View {
        LedgerChatInputBar(text: $draft, placeholder: placeholder, focused: $composerFocused,
                           isRunning: path == .scratch && conversation.isRunning, canSend: canSend,
                           onSend: { send(draft) }, onStop: conversation.stop)
            .disabled(busy)
            .accessibilityIdentifier("ai-onboarding-input")
    }

    /// Whatever the user types goes where the page is: on the welcome
    /// screen it picks the way, connecting Git it fills the address, from
    /// scratch it is the model's next question.
    private func send(_ text: String) {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, !busy else { return }
        if text == draft { draft = "" }
        switch path {
        case nil:
            let way = LedgerSetupScript.path(for: said)
            choose(way, said: said)
            if way == .scratch { firstWords = said }
            if way == .git, let address = LedgerSetupScript.gitRepository(in: said) { recognised(address) }
        case .git:
            lines.append(Line(fromUser: true, text: said))
            if let address = LedgerSetupScript.gitRepository(in: said) {
                recognised(address)
            } else {
                lines.append(Line(fromUser: false, text: String(localized: "我只认得出仓库地址，像 https://github.com/你/账本 这样。其他的请填在下面的卡片里。")))
            }
        case .other:
            lines.append(Line(fromUser: true, text: said))
            let way = LedgerSetupScript.path(for: said)
            if way == .other {
                lines.append(Line(fromUser: false, text: String(localized: "在下面选一种就行。")))
            } else {
                switchTo(way, said: said)
            }
        case .scratch:
            if conversation.hasStarted {
                guard !conversation.isRunning else { return }
                conversation.send(said)
            } else {
                // Kept for the model's first turn once a key is saved.
                lines.append(Line(fromUser: true, text: said))
                firstWords = [firstWords, said].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }

    private func recognised(_ address: String) {
        gitURL = address
        let host = URL(string: address)?.host ?? ""
        lines.append(Line(fromUser: false, text: String(localized: "认出来了，是 \(host) 上的仓库，已经填进卡片。私有仓库还需要一个访问令牌，填好后点「连接」。")))
    }

    private func choose(_ way: LedgerSetupPath, said: String) {
        session.dismissError()
        lines = [Line(fromUser: true, text: said)]
        path = way
        lines.append(Line(fromUser: false, text: Self.opening(for: way, modelReady: settings.isReady)))
        if way == .scratch, settings.isReady { conversation.start(saying: said == Self.scratchTitle ? nil : said) }
    }

    /// Moves from the file ways to another way the user named in words.
    private func switchTo(_ way: LedgerSetupPath, said: String) {
        path = way
        lines.append(Line(fromUser: false, text: Self.opening(for: way, modelReady: settings.isReady)))
        if way == .scratch {
            firstWords = said
            if settings.isReady { conversation.start(saying: said) }
        }
        if way == .git, let address = LedgerSetupScript.gitRepository(in: said) { recognised(address) }
    }

    private static let scratchTitle = String(localized: "从零新建一本")

    private static func opening(for way: LedgerSetupPath, modelReady: Bool) -> String {
        switch way {
        case .git:
            String(localized: "好。把仓库地址发给我，或者直接填在下面。私有仓库还需要一个访问令牌，它只存进钥匙串，不会出现在对话里。")
        case .other:
            String(localized: "可以从这几种方式里选：")
        case .scratch:
            modelReady
                ? String(localized: "好，我们从零开始。")
                : String(localized: "好。从零建账我会和你聊几句，这需要先接上一个模型服务，用你自己的 API Key。")
        }
    }

    private func restart() {
        conversation.reset()
        gitTask?.cancel()
        path = nil
        lines = []
        firstWords = nil
        draft = ""
        gitFailure = nil
        gitToken = ""
        storageToken = ""
        storageUser = ""
        modelKey = ""
        modelFailure = nil
        session.dismissError()
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

/// The glass capsule behind the from-scratch progress strip; the sunken
/// capsule before iOS 26.
private struct LedgerSetupStripGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(Capsule().fill(BalancedPalette.sunken))
        }
    }
}

/// Wraps its children onto as many rows as they need.
struct LedgerSetupFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += row + spacing; x = 0; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += row + spacing; x = bounds.minX; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
