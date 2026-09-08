import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LedgerPalette.canvas.ignoresSafeArea()

            switch session.phase {
            case .configuration:
                ServerConfigurationView()
            case .checking:
                // A search deep link can arrive before authentication finishes. Keep native
                // search controllers unmounted until the ready shell has a stable lifetime.
                ProgressView("正在连接账本")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .locked(authenticated):
                LoginView(authenticated: authenticated)
            case .ready:
                MainTabView()
            }

            if session.presentsPrivacyCover(sceneIsActive: scenePhase == .active) {
                PrivacyCover()
                    .transition(.opacity)
            }
        }
        .tint(LedgerPalette.cobalt)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.phase)
    }
}

struct PrivacyCover: View {
    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            LedgerBrandMark(size: 48)
            VStack(spacing: LedgerSpacing.xs) {
                Text("Ledger")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Text("敏感数据已隐藏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LedgerPalette.canvas)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
    }
}

private struct ServerConfigurationView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var serverFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        LedgerBrandMark(size: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("你的个人账本").font(.title2.weight(.semibold))
                            Text("连接服务器，随时查看与整理收支。").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                }
                Section {
                    TextField("https://ledger.example.com", text: $session.serverInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.continue)
                        .focused($serverFocused)
                        .onSubmit { Task { await session.saveServer() } }
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("输入 Ledger 服务器的 HTTPS 地址。验证连接后即可登录。")
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
                Section {
                    Button("验证并继续") {
                        serverFocused = false
                        Task { await session.saveServer() }
                    }
                    .disabled(session.serverInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("欢迎使用 Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var passwordFocused: Bool
    let authenticated: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(session.serverURL?.host ?? "Ledger", systemImage: "lock.shield")
                        .font(.headline)
                        .padding(.vertical, 8)
                } footer: {
                    Text(authenticated ? "验证身份后即可继续查看账本。" : "使用账本密码或已启用的解锁方式登录。")
                }
                if session.canUseBiometricUnlock || session.passkeyAvailable {
                    Section {
                        if session.canUseBiometricUnlock {
                            Button {
                                passwordFocused = false
                                Task { await session.unlockWithBiometrics() }
                            } label: {
                                Label("使用 \(session.biometricTitle) 解锁", systemImage: session.biometricSystemImage)
                            }
                        }
                        if session.passkeyAvailable {
                            Button {
                                passwordFocused = false
                                Task { await session.loginWithPasskey() }
                            } label: {
                                Label(authenticated ? "使用通行密钥解锁" : "使用通行密钥登录", systemImage: "person.badge.key.fill")
                            }
                        }
                    }
                    .disabled(session.isAuthenticationBusy)
                }
                Section("账本密码") {
                    SecureField("输入密码", text: $session.password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($passwordFocused)
                        .onSubmit { Task { await session.login() } }
                    Button(authenticated ? "使用密码解锁" : "登录") {
                        passwordFocused = false
                        Task { await session.login() }
                    }
                    .disabled(session.password.isEmpty)
                }
                .disabled(session.isAuthenticationBusy)
                if session.isAuthenticationBusy {
                    Section { ProgressView("正在安全恢复账本") }
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
                Section {
                    Button("更换服务器") { session.changeServer() }
                        .disabled(session.isAuthenticationBusy)
                }
            }
            .navigationTitle(authenticated ? "账本已锁定" : "登录 Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var moreDestination: LedgerDestination?

    private var selection: Binding<LedgerDestination> {
        Binding(
            get: { LedgerDestination.stored(session.primaryDestinationID) },
            set: { session.primaryDestinationID = $0.rawValue }
        )
    }

    private var compactSelection: Binding<LedgerDestination> {
        Binding(
            get: {
                LedgerDestination.stored(session.primaryDestinationID)
                    .compactSelection(in: session.compactTabDestinations)
            },
            set: { destination in
                let overflow = moreDestination.flatMap {
                    $0.isCompactOverflow(in: session.compactTabDestinations) ? $0 : nil
                }
                session.primaryDestinationID = destination == .settings
                    ? (overflow ?? .settings).rawValue
                    : destination.rawValue
            }
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                LedgerRegularShell(selection: selection)
            } else {
                compactTabs.ledgerAdaptiveTabBar()
            }
        }
        .ledgerTimeRangeSheet()
        .task(id: session.pendingExternalRoute?.id) { await session.applyPendingExternalRoute() }
        .onChange(of: session.isRangeLoading) { _, loading in
            if !loading { Task { await session.applyPendingExternalRoute() } }
        }
        .onChange(of: session.compactTabDestinations) { _, destinations in
            if let moreDestination, destinations.contains(moreDestination) {
                self.moreDestination = nil
            }
        }
    }

    @ViewBuilder
    private var compactTabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: compactSelection) {
                ForEach(session.compactTabDestinations) { destination in
                    Tab(destination.compactTitle, systemImage: destination.systemImage, value: destination) {
                        NavigationStack { LedgerDestinationView(destination: destination, isRoot: true) }
                    }
                }
                Tab("更多", systemImage: "ellipsis", value: LedgerDestination.settings) {
                    NavigationStack { MoreView(overflowDestination: $moreDestination) }
                }
                Tab(value: LedgerDestination.search, role: .search) {
                    NavigationStack { GlobalSearchView(query: $session.globalSearchQuery, usesNativeSearchTab: true) }
                        .searchable(text: $session.globalSearchQuery, prompt: "搜索整个账本")
                }
            }
            .tabViewSearchActivation(.searchTabSelection)
        } else {
            legacyCompactTabs
        }
    }

    private var legacyCompactTabs: some View {
        TabView(selection: compactSelection) {
            ForEach(session.compactTabDestinations) { destination in
                NavigationStack {
                    LedgerDestinationView(destination: destination, isRoot: true)
                }
                .tabItem { Label(destination.compactTitle, systemImage: destination.systemImage) }
                .tag(destination)
            }
            NavigationStack { MoreView(overflowDestination: $moreDestination) }
                .tabItem { Label("更多", systemImage: "ellipsis") }
                .tag(LedgerDestination.settings)
            NavigationStack { GlobalSearchPage() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(LedgerDestination.search)
        }
    }
}

struct LedgerDestinationView: View {
    let destination: LedgerDestination
    var isRoot = false

    var body: some View {
        switch destination {
        case .overview: OverviewView(isRoot: isRoot)
        case .assets: LedgerAnalysisView(kind: .assets, isRoot: isRoot)
        case .incomeExpense: LedgerAnalysisView(kind: .incomeExpense, isRoot: isRoot)
        case .investments: LedgerAnalysisView(kind: .investments, isRoot: isRoot)
        case .currencies: CurrencyAnalysisView(isRoot: isRoot)
        case .query: BQLQueryView(isRoot: isRoot)
        case .imports: ImportHistoryView(isRoot: isRoot)
        case .transactions: TransactionsView(isRoot: isRoot)
        case .accounts: AccountsView(isRoot: isRoot)
        case .settings: SettingsView(isRoot: isRoot)
        case .search: GlobalSearchPage()
        }
    }
}

private struct LedgerRegularShell: View {
    @Binding var selection: LedgerDestination
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List {
                Section("账本") {
                    sidebarRow(.overview)
                    sidebarRow(.transactions)
                    sidebarRow(.accounts)
                }
                Section("财务分析") {
                    sidebarRow(.assets)
                    sidebarRow(.incomeExpense)
                    sidebarRow(.investments)
                }
                Section("工具") {
                    sidebarRow(.search)
                    sidebarRow(.imports)
                    sidebarRow(.currencies)
                    sidebarRow(.query)
                }
                Section { sidebarRow(.settings) }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("ledger-sidebar")
            .navigationTitle("Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            NavigationStack {
                LedgerDestinationView(destination: selection, isRoot: true)
            }
        }
        .navigationSplitViewStyle(.balanced)
        // SplitView also owns a UIKit navigation container for view-based pushes.
        // Recreate that container while retaining visibility in this shell's state.
        .id(selection)
    }

    private func sidebarRow(_ destination: LedgerDestination) -> some View {
        Button { selection = destination } label: {
            Label(destination.title, systemImage: destination.systemImage)
                .foregroundStyle(selection == destination ? LedgerPalette.cobalt : LedgerPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .listRowBackground(selection == destination ? LedgerPalette.tag : Color.clear)
        .accessibilityAddTraits(selection == destination ? .isSelected : [])
        .accessibilityIdentifier("sidebar-\(destination.rawValue)")
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(LedgerSession(defaults: UserDefaults(suiteName: "preview-config")!))
    }
}
