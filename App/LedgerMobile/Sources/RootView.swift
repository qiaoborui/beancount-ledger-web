import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LedgerPalette.canvas.ignoresSafeArea()

            switch session.phase {
            case .configuration:
                ServerConfigurationView()
            case .checking, .loading:
                LoadingView()
            case let .locked(authenticated):
                LoginView(authenticated: authenticated)
            case .ready:
                MainTabView()
            }

            if scenePhase != .active || session.privacyShielded {
                PrivacyCover()
                    .transition(.opacity)
            }
        }
        .tint(LedgerPalette.cobalt)
        .animation(.easeOut(duration: 0.18), value: session.phase)
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

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            LedgerBrandMark(size: 48)
            ProgressView()
                .tint(LedgerPalette.cobalt)
            Text("正在连接 Ledger")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AuthCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(LedgerPalette.cobalt)
                .frame(width: 48, height: 4)
                .padding(.bottom, LedgerSpacing.xl)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.65)
                .foregroundStyle(LedgerPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(LedgerPalette.olive)
                .lineSpacing(3)
                .padding(.top, LedgerSpacing.sm)

            content
                .padding(.top, LedgerSpacing.xl)
        }
        .padding(28)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }
}

private struct AuthCanvas<Content: View>: View {
    var accented = false
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack {
                    content
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .padding(.horizontal, LedgerSpacing.lg)
                .padding(.vertical, LedgerSpacing.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(accented ? LedgerPalette.cobalt : LedgerPalette.canvas)
    }
}

private struct LedgerTextFieldStyle: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(LedgerPalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                    .stroke(focused ? LedgerPalette.cobalt : LedgerPalette.line, lineWidth: focused ? 1.5 : 1)
            }
            .shadow(color: focused ? LedgerPalette.cobalt.opacity(0.16) : .clear, radius: 3, x: 0, y: 0)
    }
}

private struct ServerConfigurationView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var serverFocused: Bool

    var body: some View {
        AuthCanvas {
            AuthCard(
                title: "Ledger",
                detail: "连接你的个人财务工作台，读取当前账本数据。"
            ) {
                VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                    VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                        Text("服务器地址")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        TextField("https://ledger.example.com", text: $session.serverInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .submitLabel(.continue)
                            .focused($serverFocused)
                            .onSubmit { Task { await session.saveServer() } }
                            .modifier(LedgerTextFieldStyle(focused: serverFocused))
                        Text("仅保存 HTTPS 服务器地址，连接验证通过后才会进入密码登录。")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.secondary)
                            .lineSpacing(2)
                    }

                    if let error = session.errorMessage {
                        StatusBanner(message: error, onDismiss: session.dismissError)
                    }

                    Button {
                        Task { await session.saveServer() }
                    } label: {
                        PrimaryButtonLabel(title: "验证并继续", loading: false)
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    HStack(spacing: LedgerSpacing.sm) {
                        Image(systemName: "shield.checkered")
                            .foregroundStyle(LedgerPalette.cobalt)
                        Text("密码和账本内容不会写入本地设置")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
            }
        }
        .onAppear { serverFocused = true }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var session: LedgerSession
    @FocusState private var passwordFocused: Bool

    let authenticated: Bool

    var body: some View {
        AuthCanvas(accented: authenticated) {
            AuthCard(
                title: authenticated ? "账本已锁定" : "登录 Ledger",
                detail: authenticated
                    ? session.hasBiometricUnlock
                        ? "使用 \(session.biometricTitle) 快速恢复，通行密钥和密码可用于账户验证。"
                        : session.passkeyAvailable
                            ? "使用通行密钥恢复敏感金额，密码仍可随时使用。"
                            : "当前会话仍然有效，输入密码即可恢复敏感金额。"
                    : session.passkeyAvailable
                        ? "使用通行密钥访问你的个人财务工作台。"
                        : "使用 Ledger Web 密码访问你的个人财务工作台。"
            ) {
                VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                    if let origin = session.serverURL?.absoluteString {
                        HStack(alignment: .top, spacing: LedgerSpacing.md) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(width: 36, height: 36)
                                .background(LedgerPalette.tag)
                                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("当前后端")
                                    .font(.system(size: 11))
                                    .foregroundStyle(LedgerPalette.secondary)
                                Text(origin)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(LedgerSpacing.md)
                        .background(LedgerPalette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                                .stroke(LedgerPalette.line, lineWidth: 1)
                        }
                    }

                    if session.hasBiometricUnlock {
                        Button {
                            passwordFocused = false
                            Task { await session.unlockWithBiometrics() }
                        } label: {
                            HStack(spacing: LedgerSpacing.sm) {
                                Image(systemName: session.biometricSystemImage)
                                    .font(.system(size: 18, weight: .medium))
                                Text("使用 \(session.biometricTitle) 解锁")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(LedgerPalette.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(LedgerPalette.cobalt)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }

                    if session.passkeyAvailable {
                        Button {
                            passwordFocused = false
                            Task { await session.loginWithPasskey() }
                        } label: {
                            HStack(spacing: LedgerSpacing.sm) {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.system(size: 17, weight: .medium))
                                Text(authenticated ? "使用通行密钥解锁" : "使用通行密钥登录")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(session.hasBiometricUnlock ? LedgerPalette.cobalt : LedgerPalette.onBrand)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(session.hasBiometricUnlock ? LedgerPalette.panel : LedgerPalette.cobalt)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            .overlay {
                                if session.hasBiometricUnlock {
                                    RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                                        .stroke(LedgerPalette.cobalt, lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }

                    if session.hasBiometricUnlock || session.passkeyAvailable {
                        HStack(spacing: LedgerSpacing.md) {
                            Rectangle().fill(LedgerPalette.line).frame(height: 1)
                            Text("或使用密码")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(LedgerPalette.secondary)
                                .fixedSize()
                            Rectangle().fill(LedgerPalette.line).frame(height: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                        Text("账本密码")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        SecureField("输入密码", text: $session.password)
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($passwordFocused)
                            .onSubmit { Task { await session.login() } }
                            .modifier(LedgerTextFieldStyle(focused: passwordFocused))
                    }

                    if let error = session.errorMessage {
                        StatusBanner(message: error, onDismiss: session.dismissError)
                    }

                    Button {
                        Task { await session.login() }
                    } label: {
                        if session.hasBiometricUnlock || session.passkeyAvailable {
                            Text(authenticated ? "使用密码解锁" : "使用密码登录")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LedgerPalette.cobalt)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(LedgerPalette.panel)
                                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                                        .stroke(LedgerPalette.cobalt, lineWidth: 1)
                                }
                        } else {
                            PrimaryButtonLabel(title: authenticated ? "解锁金额" : "登录", loading: false)
                        }
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    Button("更换服务器") {
                        session.changeServer()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
        }
        .onAppear { passwordFocused = !session.hasBiometricUnlock && !session.passkeyAvailable }
    }
}

enum LedgerDestination: String, CaseIterable, Hashable {
    case overview
    case dashboard
    case netWorth
    case incomeStatement
    case investments
    case currencies
    case query
    case transactions
    case accounts
    case settings

    var title: String {
        switch self {
        case .overview: "财务概览"
        case .dashboard: "仪表盘"
        case .netWorth: "净资产"
        case .incomeStatement: "损益"
        case .investments: "投资"
        case .currencies: "货币与汇率"
        case .query: "查询"
        case .transactions: "交易账本"
        case .accounts: "账户"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "house"
        case .dashboard: "rectangle.3.group"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .incomeStatement: "sum"
        case .investments: "chart.pie"
        case .currencies: "coloncurrencysign"
        case .query: "cylinder.split.1x2"
        case .transactions: "list.bullet"
        case .accounts: "book.closed"
        case .settings: "gearshape"
        }
    }
}

private struct MainTabView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var selection: Binding<LedgerDestination> {
        Binding(
            get: { LedgerDestination(rawValue: session.primaryDestinationID) ?? .overview },
            set: { session.primaryDestinationID = $0.rawValue }
        )
    }

    private var compactSelection: Binding<LedgerDestination> {
        Binding(
            get: {
                switch LedgerDestination(rawValue: session.primaryDestinationID) ?? .overview {
                case .overview, .transactions, .accounts, .settings:
                    return LedgerDestination(rawValue: session.primaryDestinationID) ?? .overview
                case .dashboard, .netWorth, .incomeStatement, .investments, .currencies, .query:
                    return .settings
                }
            },
            set: { session.primaryDestinationID = $0.rawValue }
        )
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            LedgerRegularShell(selection: selection)
        } else {
            compactTabs
        }
    }

    private var compactTabs: some View {
        TabView(selection: compactSelection) {
            OverviewView()
                .tabItem { Label("概览", systemImage: "house") }
                .tag(LedgerDestination.overview)
            TransactionsView()
                .tabItem { Label("交易", systemImage: "list.bullet") }
                .tag(LedgerDestination.transactions)
            AccountsView()
                .tabItem { Label("账户", systemImage: "book.closed") }
                .tag(LedgerDestination.accounts)
            MoreView()
                .tabItem { Label("更多", systemImage: "ellipsis") }
                .tag(LedgerDestination.settings)
        }
        .toolbarBackground(LedgerPalette.panel, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

private struct LedgerRegularShell: View {
    @Binding var selection: LedgerDestination
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LedgerSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: LedgerLayout.sidebarWidth,
                    ideal: LedgerLayout.sidebarWidth,
                    max: 260
                )
        } detail: {
            Group {
                switch selection {
                case .overview:
                    OverviewView()
                case .dashboard:
                    LedgerAnalysisView(kind: .dashboard, showsAppBar: true)
                case .netWorth:
                    LedgerAnalysisView(kind: .netWorth, showsAppBar: true)
                case .incomeStatement:
                    LedgerAnalysisView(kind: .incomeStatement, showsAppBar: true)
                case .investments:
                    LedgerAnalysisView(kind: .investments, showsAppBar: true)
                case .currencies:
                    CurrencyAnalysisView(showsAppBar: true)
                case .query:
                    BQLQueryView(showsAppBar: true)
                case .transactions:
                    TransactionsView()
                case .accounts:
                    AccountsView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .id(selection)
        .environment(\.ledgerSidebarVisibility, $columnVisibility)
        .background(LedgerPalette.canvas)
    }
}

private struct LedgerSidebar: View {
    @Binding var selection: LedgerDestination

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: LedgerSpacing.md) {
                LedgerBrandMark(size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ledger")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text("个人财务工作台")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LedgerSpacing.md)
            .frame(height: 56)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LedgerPalette.line).frame(height: 1)
            }

            VStack(spacing: LedgerSpacing.xs) {
                ForEach(LedgerDestination.allCases.filter { $0 != .settings }, id: \.self) { destination in
                    sidebarButton(destination)
                }
            }
            .padding(LedgerSpacing.sm)

            Spacer(minLength: 0)

            sidebarButton(.settings)
                .padding(.horizontal, LedgerSpacing.sm)
                .padding(.bottom, LedgerSpacing.sm)

            Text("只读模式")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LedgerSpacing.md)
                .overlay(alignment: .top) {
                    Rectangle().fill(LedgerPalette.line).frame(height: 1)
                }
        }
        .frame(minWidth: LedgerLayout.sidebarWidth)
        .background(LedgerPalette.panel.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func sidebarButton(_ destination: LedgerDestination) -> some View {
        let selected = selection == destination

        return Button {
            selection = destination
        } label: {
            HStack(spacing: LedgerSpacing.md) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(destination.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? LedgerPalette.cobalt : LedgerPalette.olive)
            .padding(.horizontal, LedgerSpacing.md)
            .frame(minHeight: 40)
            .background(selected ? LedgerPalette.tag : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityIdentifier("sidebar-\(destination.rawValue)")
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(LedgerSession(defaults: UserDefaults(suiteName: "preview-config")!))
    }
}
