import SwiftUI

struct RootView: View {
    @State private var showsLaunchAnimation = true
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var testingTagReport: String? = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open-tag-report=") })?.replacingOccurrences(of: "--open-tag-report=", with: "")
    @State private var testingPendingInbox = false
    @State private var testingPaginationReady = false
    @State private var testingEventTags: Bool = ProcessInfo.processInfo.arguments.contains("--open-event-tags")
    @State private var testingTransactionDetail: Bool = ProcessInfo.processInfo.arguments.contains("--open-transaction-detail")
    @State private var testingCreateTransaction: Bool = ProcessInfo.processInfo.arguments.contains("--open-create-transaction")
    @State private var testingTransactionShare: Bool = ProcessInfo.processInfo.arguments.contains("--open-transaction-share")
    @State private var testingReconciliation: Bool = ProcessInfo.processInfo.arguments.contains("--open-reconciliation")
    @State private var testingSingleReconcile: Bool = ProcessInfo.processInfo.arguments.contains("--open-single-reconcile")
    @State private var testingAccountDetail: Bool = ProcessInfo.processInfo.arguments.contains("--open-account-detail")
    #endif

    var body: some View {
        ZStack {
            LedgerPalette.canvas.ignoresSafeArea()

            Group {
                switch session.phase {
                case .configuration:
                    LedgerLibraryView()
                case .checking:
                    // A search deep link can arrive before authentication finishes. Keep native
                    // search controllers unmounted until the ready shell has a stable lifetime.
                    // The local ledger's startup cover is layered below rather than living here,
                    // so it can animate away when the first authenticated frame arrives.
                    Group {
                        if !session.isLocal { ProgressView("正在连接账本") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .locked(authenticated):
                    LoginView(authenticated: authenticated)
                case .ready:
                    MainTabView()
                }

            }
            .accessibilityHidden(showsLaunchAnimation || coverVisible)
            .allowsHitTesting(!showsLaunchAnimation && !coverVisible)

            // The cover gets its own animation scope so only its own presence
            // animates. Animating `session.phase` instead cross-fades the cover,
            // toolbar and populated list as one, which is why the local path had
            // animation disabled and cut into the ledger with no transition at all.
            ZStack {
                if coverVisible {
                    PrivacyCover()
                        .transition(coverTransition)
                }
                // Mount the privacy shield before launch fades, avoiding a flash
                // of the ledger chooser or protected content during loading.
                if showsLaunchAnimation {
                    LedgerLaunchView(contentReady: session.phase != .checking && !coverVisible) {
                        showsLaunchAnimation = false
                    }
                }
            }
            .zIndex(1)
            .animation(
                showsLaunchAnimation || reduceMotion ? nil : .easeOut(duration: LedgerLaunchTiming.exitDuration),
                value: coverVisible
            )

            // 灵动岛全屏入账浮层容器 (无论用户在哪个 Tab 页面记账/导入，均自顶部灵动岛优雅弹下)
            LedgerIslandOverlayContainer(currentNotice: $session.pendingIslandNotice)
                .zIndex(2)
        }
        // Balanced has no accent colour (docs/design/ios-balanced/README.md):
        // every native control that doesn't set its own explicit tint — a
        // system alert, a default-styled toolbar button, a List disclosure
        // chevron — falls back to this root tint. `LedgerPalette.cobalt` is
        // the retired terminal-design accent; leaving it here is what put a
        // stray blue glyph at the bottom-left edge of d09/d10 screenshots
        // (the DEBUG-only testing buttons in the `#if targetEnvironment(simulator)`
        // overlay below pick up whatever tint is active and have no
        // foregroundStyle override of their own).
        .tint(BalancedPalette.ink)
        // Remote startup cross-fades its connecting surface into the shell. The
        // local path is excluded here because it presents one authenticated frame;
        // its cover lifts on the scope above instead.
        .animation(session.isLocal || reduceMotion ? nil : .easeOut(duration: 0.18), value: session.phase)
        .onAppear {
            if let tab = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tab=") })?.replacingOccurrences(of: "--tab=", with: "") {
                session.primaryDestinationID = tab
            }
        }
        .sheet(isPresented: Binding(
            get: { session.canPresentWidgetDay },
            set: { presented in
                if !presented, session.phase == .ready { session.dismissWidgetDay() }
            }
        )) {
            if let day = session.pendingWidgetExpenseDay {
                NavigationStack {
                    WidgetDayTransactionsView(day: day)
                }
                .id(day)
                .ledgerPrivacyProtectedSheet()
            }
        }
        #if DEBUG
        #if targetEnvironment(simulator)
        // The testing buttons live in the bottom-left corner, which is exactly
        // where a presented sheet's rounded corner is: at 20pt gutter the
        // sheet does not cover x=0, so a label that draws wider than its own
        // hit box leaks a sliver of blue glyph through the corner gap in
        // d09/d10 screenshots. Two things were wrong — the overlay is applied
        // *outside* the `.tint(BalancedPalette.ink)` above, so its default
        // button style still drew in the system accent; and the label had no
        // frame, so it drew outside its own hit box. Give each button a real
        // 44×44 hit target with a clear label and its own ink tint.
        .overlay(alignment: .bottomLeading) {
            if ProcessInfo.processInfo.arguments.contains("--local-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--pagination-ui-testing"), session.phase != .ready {
                Button {
                    Task {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pagination-" + UUID().uuidString)
                        do {
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            defer { try? FileManager.default.removeItem(at: directory) }
                            var text = "2000-01-01 open Assets:Bank:International:DailySpendingAccount CNY\n2000-01-01 open Expenses:Food CNY\n\n"
                            for index in 1...292 {
                                text += "\(LedgerDateRange.today()) * \"Pagination \(index)\" \"Synthetic\"\n  Expenses:Food 1 CNY\n  Assets:Bank:International:DailySpendingAccount -1 CNY\n\n"
                            }
                            try text.write(to: directory.appendingPathComponent("main.bean"), atomically: true, encoding: .utf8)
                            await session.importLocalLedger(from: directory, name: "Pagination fixture", entrypoint: "main.bean")
                            testingPaginationReady = session.phase == .ready
                        } catch { session.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Text("测试分页账本").foregroundStyle(.clear)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .accessibilityIdentifier("test-import-pagination-ledger")
                .tint(BalancedPalette.ink)
            }
            if testingPaginationReady {
                Text("Fixture ready").font(.system(size: 1)).foregroundStyle(.clear).accessibilityIdentifier("pagination-fixture-ready")
            }
            if ProcessInfo.processInfo.arguments.contains("--local-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--pending-ui-testing"), session.phase == .ready {
                Button { testingPendingInbox = true } label: {
                    Text("测试待整理入口").foregroundStyle(.clear)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .accessibilityIdentifier("test-open-pending-inbox")
                .tint(BalancedPalette.ink)
            }
        }
        .sheet(isPresented: $testingPendingInbox) {
            PendingInboxView().ledgerPrivacyProtectedSheet()
        }
        #endif
        .sheet(isPresented: $testingEventTags) {
            EventTagListView()
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: Binding(
            get: { testingTagReport != nil },
            set: { if !$0 { testingTagReport = nil } }
        )) {
            if let tag = testingTagReport {
                NavigationStack {
                    EventTagReportView(tag: tag)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { testingTagReport = nil }
                            }
                        }
                }
                .ledgerPrivacyProtectedSheet()
            }
        }
        .sheet(isPresented: $testingTransactionDetail) {
            if let tx = session.visibleTransactions.first ?? session.ledger?.transactions.first {
                NavigationStack {
                    TransactionDetailView(transaction: tx)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { testingTransactionDetail = false }
                            }
                        }
                }
                .ledgerPrivacyProtectedSheet()
            }
        }
        .sheet(isPresented: $testingCreateTransaction) {
            TransactionEditorView(
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? []
            ) { entry in
                try await session.addLocalTransaction(entry)
            }
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $testingTransactionShare) {
            if let tx = session.visibleTransactions.first ?? session.ledger?.transactions.first {
                TransactionShareSheet(
                    transactions: [tx],
                    currency: tx.postings.first?.currency ?? session.ledger?.valuationCurrency ?? "CNY",
                    accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
                )
                .ledgerPrivacyProtectedSheet()
            }
        }
        .sheet(isPresented: $testingReconciliation) {
            NavigationStack {
                ReconciliationView()
            }
            .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: $testingSingleReconcile) {
            SingleAccountReconciliationSheet(
                account: "Assets:Bank:Daily",
                label: String(localized: "日常账户"),
                currency: "CNY"
            )
        }
        .sheet(isPresented: $testingAccountDetail) {
            NavigationStack {
                AccountDetailView(account: "Assets:Bank:Daily", currency: "CNY")
            }
            .ledgerPrivacyProtectedSheet()
        }
        #endif
    }

    /// True while the local ledger loads behind the startup cover. This is the
    /// cover's first-frame case, so it is the one that plays the entrance reveal.
    private var isStartupCover: Bool {
        session.isLocal && session.phase == .checking
    }

    /// The cover is on screen for the local ledger's load and whenever the
    /// session shields its content. It sits above the phase switch so that its
    /// exit animates on its own terms; animating the phase instead drags the
    /// cover, toolbar and populated list through one cross-fade, which is why
    /// the local path had animation switched off and cut in with nothing at all.
    private var coverVisible: Bool {
        isStartupCover || session.presentsPrivacyCover(sceneIsActive: scenePhase == .active)
    }

    /// The cover snaps in — it is either the app's first frame or a shield that
    /// must not fade over the content it is hiding — and lifts with a short fade
    /// and a slight swell, so the ledger appears to rise out from behind it.
    private var coverTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .identity,
            removal: .opacity.combined(with: .scale(scale: LedgerMotion.Cover.exitScale))
        )
    }
}

/// Privacy surface shown until authenticated content is ready.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            TerminalPalette.page.ignoresSafeArea()
            LedgerLaunchBrand()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("敏感数据已隐藏")
        .accessibilityIdentifier("ledger-privacy-cover")
    }
}

struct ServerConfigurationView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var serverFocused: Bool

    var body: some View {
        NavigationStack {
            List {
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
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// `.empty` — the locked state shows no ledger content at all, not even the
/// ledger name's account figures. A 1px-stroke lock glyph, a title, one
/// sentence, then the unlock actions as a `.btn` stack (primary first).
private struct LoginView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var passwordFocused: Bool
    @State private var showingPasswordField = false
    let authenticated: Bool

    private var ledgerTitle: String {
        session.isLocal ? session.localLedgerName : (session.serverURL?.host ?? "Ledger")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 0) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(BalancedPalette.meta)
                        .padding(.bottom, 20)
                    Text(ledgerTitle)
                        .balancedFont(size: 19, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                        .padding(.bottom, 6)
                    Text(authenticated ? "验证身份后即可继续查看。账本内容在此之前不会出现在屏幕上。" : "使用账本密码或已启用的解锁方式登录。")
                        .balancedFont(size: 13.5)
                        .foregroundStyle(BalancedPalette.meta)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                }
                Spacer()

                if session.isAuthenticationBusy {
                    ProgressView("正在安全恢复账本")
                        .balancedFont(size: 13)
                        .foregroundStyle(BalancedPalette.meta)
                        .padding(.bottom, 12)
                }
                if let error = session.errorMessage {
                    StatusBanner(message: error, onDismiss: session.dismissError)
                        .padding(.bottom, 12)
                }

                VStack(spacing: 10) {
                    if session.canUseBiometricUnlock {
                        Button("使用 \(session.biometricTitle) 解锁") {
                            passwordFocused = false
                            Task { await session.unlockWithBiometrics() }
                        }
                        .buttonStyle(.balanced(.primary))
                        .disabled(session.isAuthenticationBusy)
                    }
                    if session.passkeyAvailable {
                        Button(authenticated ? "使用通行密钥解锁" : "使用通行密钥登录") {
                            passwordFocused = false
                            Task { await session.loginWithPasskey() }
                        }
                        .buttonStyle(.balanced(session.canUseBiometricUnlock ? .outline : .primary))
                        .disabled(session.isAuthenticationBusy)
                    }
                    if !session.isLocal {
                        if showingPasswordField || !(session.canUseBiometricUnlock || session.passkeyAvailable) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("账本密码").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                                SecureField("输入密码", text: $session.password)
                                    .balancedFont(size: 15)
                                    .textContentType(.password)
                                    .submitLabel(.go)
                                    .focused($passwordFocused)
                                    .onSubmit { Task { await session.login() } }
                                    .padding(.vertical, 10)
                                    .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            }
                            .padding(.bottom, 4)
                            Button(authenticated ? "使用密码解锁" : "登录") {
                                passwordFocused = false
                                Task { await session.login() }
                            }
                            .buttonStyle(.balanced(.outline))
                            .disabled(session.password.isEmpty || session.isAuthenticationBusy)
                        } else {
                            Button("使用密码") { showingPasswordField = true; passwordFocused = true }
                                .buttonStyle(.balanced(.quiet))
                                .disabled(session.isAuthenticationBusy)
                        }
                    }
                    Button("选择其他账本") { session.chooseLedger() }
                        .buttonStyle(.balanced(.quiet))
                        .disabled(session.isAuthenticationBusy)
                }
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(authenticated ? "账本已锁定" : "登录 Ledger")
            .terminalNativeChrome()
            .navigationBarTitleDisplayMode(.inline)
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
                if #available(iOS 26.0, *) {
                    nativeTabs.tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    compactTabs
                }
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

    @available(iOS 26.0, *)
    private var nativeTabs: some View {
        TabView(selection: compactSelection) {
            ForEach(session.compactTabDestinations) { destination in
                Tab(destination == .transactions ? String(localized: "流水") : destination.compactTitle,
                    systemImage: destination.systemImage, value: destination) {
                    NavigationStack { LedgerDestinationView(destination: destination, isRoot: true) }
                }
            }
            Tab("更多", systemImage: "ellipsis", value: LedgerDestination.settings) {
                NavigationStack { MoreView(overflowDestination: $moreDestination) }
            }
            // Search floats as its own button beside the tab bar, one tap from every root page.
            Tab("搜索", systemImage: "magnifyingglass", value: LedgerDestination.search, role: Self.searchTabRole) {
                NavigationStack { SearchTabRoot() }
            }
        }
    }

    /// iOS 26 detaches a search-role tab by itself. Built with the iOS 27 SDK it stays
    /// inside the bar, and only the prominent role sets a tab apart.
    @available(iOS 26.0, *)
    private static var searchTabRole: TabRole {
        if #available(iOS 27.0, *) { .prominent } else { .search }
    }

    private var compactTabs: some View {
        TabView(selection: compactSelection) {
            ForEach(session.compactTabDestinations) { destination in
                NavigationStack {
                    LedgerDestinationView(destination: destination, isRoot: true)
                }
                .tabItem { Label(destination == .transactions ? String(localized: "流水") : destination.compactTitle, systemImage: destination.systemImage) }
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

/// A prominent tab no longer hands its field to the tab bar, so on iOS 27 search keeps
/// the field in its own navigation bar.
@available(iOS 26.0, *)
private struct SearchTabRoot: View {
    var body: some View {
        if #available(iOS 27.0, *) { GlobalSearchPage() } else { GlobalSearchTabPage() }
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
        case .agent: LedgerAgentView(isRoot: isRoot)
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
                    sidebarRow(.agent)
                }
                Section { sidebarRow(.settings) }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("ledger-sidebar")
            .navigationTitle("Ledger")
            .terminalNativeChrome()
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
