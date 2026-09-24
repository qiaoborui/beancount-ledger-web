import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @State private var testingTagReport: String? = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--open-tag-report=") })?.replacingOccurrences(of: "--open-tag-report=", with: "")
    @State private var testingEventTags: Bool = ProcessInfo.processInfo.arguments.contains("--open-event-tags")
    @State private var testingTransactionDetail: Bool = ProcessInfo.processInfo.arguments.contains("--open-transaction-detail")
    @State private var testingCreateTransaction: Bool = ProcessInfo.processInfo.arguments.contains("--open-create-transaction")
    @State private var testingTransactionShare: Bool = ProcessInfo.processInfo.arguments.contains("--open-transaction-share")
    @State private var testingReconciliation: Bool = ProcessInfo.processInfo.arguments.contains("--open-reconciliation")
    @State private var testingSingleReconcile: Bool = ProcessInfo.processInfo.arguments.contains("--open-single-reconcile")
    #endif

    var body: some View {
        ZStack {
            LedgerPalette.canvas.ignoresSafeArea()

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

            // The cover gets its own animation scope so only its own presence
            // animates. Animating `session.phase` instead cross-fades the cover,
            // toolbar and populated list as one, which is why the local path had
            // animation disabled and cut into the ledger with no transition at all.
            ZStack {
                if coverVisible {
                    PrivacyCover()
                        .transition(coverTransition)
                }
            }
            .zIndex(1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: LedgerMotion.Cover.exitDuration),
                value: coverVisible
            )
        }
        .tint(LedgerPalette.cobalt)
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
                label: "日常账户",
                currency: "CNY"
            )
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

/// The startup surface. It is on screen for the whole ledger load, so it is
/// built to look alive while it waits: the mark breathes, the labels rise into
/// place in sequence, and the dots pulse. All three are suppressed by Reduce
/// Motion and by the launch arguments used for UI testing.
struct PrivacyCover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One flag per line, not one for the pair: separate states let each label
    /// carry its own delay, which is what makes the entrance read as a sequence
    /// rather than two lines arriving at once.
    @State private var titleRevealed = false
    @State private var subtitleRevealed = false

    private var animates: Bool { !reduceMotion && LedgerMotion.allowsAmbientMotion }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            LedgerBrandMark(size: 48, breathes: true)
            VStack(spacing: LedgerSpacing.xs) {
                Text("Ledger")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .opacity(titleRevealed ? 1 : 0)
                    .offset(y: titleRevealed ? 0 : 8)
                Text("敏感数据已隐藏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                    .opacity(subtitleRevealed ? 1 : 0)
                    .offset(y: subtitleRevealed ? 0 : 8)
            }
            LedgerAmbientMotion(duration: StartupWaitingDots.cycle, autoreverses: false) { phase in
                StartupWaitingDots(phase: phase)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LedgerPalette.canvas)
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .onAppear(perform: reveal)
    }

    /// The mark is on screen from the first frame, so only the text animates in.
    private func reveal() {
        guard animates else {
            titleRevealed = true
            subtitleRevealed = true
            return
        }
        withAnimation(.easeOut(duration: LedgerMotion.Cover.revealDuration).delay(0.10)) {
            titleRevealed = true
        }
        withAnimation(.easeOut(duration: LedgerMotion.Cover.revealDuration).delay(0.18)) {
            subtitleRevealed = true
        }
    }
}

/// Three dots that swell and fade in sequence, so the cover keeps a heartbeat
/// while the ledger loads. The row is always laid out at its full size and only
/// the motion is conditional, which keeps the cover from shifting when motion is
/// off.
private struct StartupWaitingDots: View {
    /// The shared driver's 0…1 value, or `nil` when motion is off.
    var phase: Double?

    /// The row runs one dot behind the next, so the three read as a travelling
    /// pulse. Each dot lags by a slice of the cycle, which is also what lets the
    /// row loop cleanly: by the time the first dot comes round again, it is
    /// exactly where the third one started.
    static let cycle: TimeInterval = 1.2
    private static let stagger: TimeInterval = 0.16
    private static let count = 3

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.count, id: \.self) { index in
                // With motion off the dots sit level and fully drawn. Laying them
                // out at the resting value instead would freeze the row at three
                // different opacities, which reads as a stalled animation.
                let value = phase.map { Self.pulse(at: $0, lagging: Self.stagger * Double(index)) } ?? 1
                Circle()
                    .fill(LedgerPalette.cobalt)
                    .frame(width: 5, height: 5)
                    .scaleEffect(0.8 + 0.4 * value)
                    .opacity(0.3 + 0.7 * value)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// Folds the driver's 0…1 into a single swell, offset by the dot's slice.
    private static func pulse(at phase: Double, lagging lag: Double) -> Double {
        let wrapped = (phase - lag / cycle).truncatingRemainder(dividingBy: 1)
        let normalized = wrapped < 0 ? wrapped + 1 : wrapped
        return 0.5 - 0.5 * cos(2 * .pi * normalized)
    }
}

struct ServerConfigurationView: View {
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
                    Label(session.isLocal ? session.localLedgerName : session.serverURL?.host ?? "Ledger", systemImage: "lock.shield")
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
                if !session.isLocal { Section("账本密码") {
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
                }
                if session.isAuthenticationBusy {
                    Section { ProgressView("正在安全恢复账本") }
                }
                if let error = session.errorMessage {
                    Section { StatusBanner(message: error, onDismiss: session.dismissError) }
                }
                Section {
                    Button("选择其他账本") { session.chooseLedger() }
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
                        .onSubmit(of: .search) { session.recordGlobalSearch(session.globalSearchQuery) }
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
