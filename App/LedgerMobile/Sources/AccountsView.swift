import Charts
import SwiftUI

enum AccountFilterCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case cash = "资金"
    case credit = "信用"
    case wealth = "理财"
    case receivable = "应收"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .cash: String(localized: "资金")
        case .credit: String(localized: "信用")
        case .wealth: String(localized: "理财")
        case .receivable: String(localized: "应收")
        }
    }

    func matches(section: AccountBalanceSection) -> Bool {
        switch self {
        case .all:
            return true
        case .cash:
            return section.id == "cash" || (section.id == "asset" && !section.title.contains("理财") && !section.title.contains("投资"))
        case .credit:
            return section.id == "credit" || section.id == "liability"
        case .wealth:
            return section.id == "wealth" || section.title.contains("理财") || section.title.contains("投资") || section.title.contains("基金")
        case .receivable:
            return section.id == "receivable" || section.title.contains("应收") || section.title.contains("借出")
        }
    }
}

struct AccountsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedFilter: AccountFilterCategory = .all
    @State private var trendRange: NetWorthTrendRange = .all
    @State private var showingReconciliationView = false
    @State private var showingAddAccount = false
    @State private var selectedAccountForReconciliation: AccountBalanceRow? = nil
    var isRoot = true

    /// Outer margin of a group card, and the inner padding of its content.
    private static let cardMargin: CGFloat = 16
    private static let cardPadding: CGFloat = 16
    private static let cardGap: CGFloat = 12
    private static let iconSize: CGFloat = 36
    private static let iconSpacing: CGFloat = 12

    private var allSections: [AccountBalanceSection] {
        guard let ledger = session.ledger else { return [] }
        return ledger.accountSections(
            periodBalancesAvailable: session.accountPeriodBalancesAvailable && ledger.periodAccountBalancesAvailable
        ).filter { !$0.rows.isEmpty }
    }

    private var sections: [AccountBalanceSection] {
        allSections.filter { section in
            selectedFilter.matches(section: section)
        }
    }

    private var totals: BalanceSheetTotals {
        guard let ledger = session.ledger else {
            return BalanceSheetTotals(assets: 0, liabilities: 0, netWorth: 0)
        }
        let periodAvailable = session.accountPeriodBalancesAvailable && ledger.periodAccountBalancesAvailable
        if periodAvailable {
            let assetSections = allSections.filter { $0.id == "cash" || $0.id == "asset" || $0.id == "wealth" || $0.id == "receivable" }
            let liabilitySections = allSections.filter { $0.id == "credit" || $0.id == "liability" }
            let assets = assetSections.flatMap(\.rows).reduce(0) { $0 + ($1.periodBalancesAvailable ? $1.closingValuation : $1.valuation) }
            let liabilities = liabilitySections.flatMap(\.rows).reduce(0) { $0 + abs($1.periodBalancesAvailable ? $1.closingValuation : $1.valuation) }
            return BalanceSheetTotals(assets: assets, liabilities: liabilities, netWorth: assets - liabilities)
        }
        return ledger.balanceSheetTotals
    }

    private var valuationCurrency: String { session.ledger?.valuationCurrency ?? "CNY" }

    /// Net-worth history in date order ("YYYY-MM-DD" sorts lexicographically).
    private var trendHistory: [LedgerNetWorthPoint] {
        (session.ledger?.netWorthHistory ?? []).sorted { $0.date < $1.date }
    }

    var body: some View {
        let history = trendHistory
        List {
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }
            Section {
                netWorthHeader
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if history.count >= 2 {
                    AccountsNetWorthChart(points: trendRange.filter(history))
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    trendRangePicker
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            Section {
                HStack(spacing: 22) {
                    ForEach(AccountFilterCategory.allCases) { filter in
                        let count = filter == .all
                            ? allSections.reduce(0) { $0 + $1.rows.count }
                            : allSections.filter { filter.matches(section: $0) }.reduce(0) { $0 + $1.rows.count }
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.easeOut(duration: 0.18)) { selectedFilter = filter }
                        } label: {
                            VStack(spacing: 7) {
                                HStack(spacing: 4) {
                                    Text(filter.title).balancedFont(size: 13, weight: selectedFilter == filter ? .medium : .regular).lineLimit(1)
                                    Text("\(count)").balancedFont(size: 11).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                                }
                                .foregroundStyle(selectedFilter == filter ? BalancedPalette.ink : BalancedPalette.meta)
                                Rectangle().fill(selectedFilter == filter ? BalancedPalette.ink : .clear).frame(height: 2)
                            }
                            .frame(minHeight: 44)
                        }.buttonStyle(.plain)
                        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)

            // One card per account group. Each card is a run of plain List rows
            // (header + one row per account) whose backgrounds join into a single
            // rounded surface, so every account keeps its native swipe actions.
            Section {
                ForEach(sections) { section in
                    groupCard(section)
                }
            }
            if sections.isEmpty {
                ContentUnavailableView("暂无账户", systemImage: "building.columns", description: Text("当前筛选分类下暂无账户。"))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BalancedPalette.page)
        .listStyle(.plain)
        .listSectionSpacing(8)
        .tint(TerminalPalette.accent)
        .accessibilityIdentifier("accounts-list")
        .terminalPageChrome(String(localized: "账户"), isRoot: isRoot, showsTimeRange: true, actions: AnyView(
            Menu {
                Button("新建账户") { showingAddAccount = true }
                    .accessibilityIdentifier("accounts-add-button")
                Button("账户对账") { showingReconciliationView = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(TerminalPalette.accent).frame(width: 44, height: 44)
            }.accessibilityLabel("账户操作")
        ), balanced: true)
        .navigationDestination(item: $session.externalAccount) { account in
            AccountDetailView(account: account.account, currency: account.currency)
        }
        .sheet(isPresented: $showingAddAccount) { AddAccountView().ledgerPrivacyProtectedSheet() }
        .sheet(isPresented: $showingReconciliationView) { NavigationStack { ReconciliationView() } }
        .sheet(item: $selectedAccountForReconciliation) { row in
            SingleAccountReconciliationSheet(account: row.account, label: row.label, currency: row.nativeCurrency)
        }
        .refreshable { await session.refresh() }
    }

    // MARK: Net worth

    private var netWorthHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.accountPeriodBalancesAvailable && (session.ledger?.periodAccountBalancesAvailable ?? false) ? "期末净资产" : "当前净资产")
                    .balancedFont(size: 12, weight: .medium)
                    .foregroundStyle(BalancedPalette.meta)
                Spacer()
                Button { session.toggleAmounts() } label: {
                    Image(systemName: session.amountsVisible ? "eye" : "eye.slash")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TerminalPalette.accent)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain)
                    .accessibilityLabel(session.amountsVisible ? "隐藏金额" : "显示金额")
            }
            BalancedKeyTotalText.value(minorUnits: totals.netWorth, currency: valuationCurrency, color: BalancedPalette.ink, amountsVisible: session.amountsVisible)
                .accessibilityLabel(session.amountsVisible ? MoneyText.format(minorUnits: totals.netWorth, currency: valuationCurrency) : String(localized: "金额已隐藏"))
            Text(balanceSheetSubtotalText)
                .balancedFont(size: 15)
                .monospacedDigit()
                .foregroundStyle(BalancedPalette.meta)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    /// "资产 ¥x · 负债 ¥y" under the net-worth figure.
    private var balanceSheetSubtotalText: String {
        let assetsLabel = String(localized: "资产"), liabilitiesLabel = String(localized: "负债")
        guard session.amountsVisible else { return "\(assetsLabel) •••••• · \(liabilitiesLabel) ••••••" }
        let assets = MoneyText.format(minorUnits: totals.assets, currency: valuationCurrency)
        let liabilities = MoneyText.format(minorUnits: totals.liabilities, currency: valuationCurrency)
        return "\(assetsLabel) \(assets) · \(liabilitiesLabel) \(liabilities)"
    }

    private var trendRangePicker: some View {
        HStack(spacing: 0) {
            ForEach(NetWorthTrendRange.allCases) { range in
                let selected = trendRange == range
                Button {
                    LedgerFeedback.selection()
                    withAnimation(.easeOut(duration: 0.18)) { trendRange = range }
                } label: {
                    Text(range.title)
                        .balancedFont(size: 13, weight: .medium)
                        .lineLimit(1)
                        .foregroundStyle(selected ? BalancedPalette.ink : BalancedPalette.meta)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selected { Capsule().fill(BalancedPalette.sunken) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("net-worth-trend-range")
    }

    // MARK: Group cards

    private func groupTotal(_ section: AccountBalanceSection) -> Int {
        section.rows.filter { $0.periodBalancesAvailable ? !$0.periodValuationMissing : !$0.valuationMissing }
            .reduce(0) { $0 + ($1.periodBalancesAvailable ? $1.closingValuation : $1.valuation) }
    }

    private func assetShareText(_ total: Int) -> String? {
        guard session.amountsVisible, total > 0, totals.assets > 0 else { return nil }
        return String(localized: "占资产") + " " + String(format: "%.1f%%", Double(total) / Double(totals.assets) * 100)
    }

    /// A group card: the header row, then one List row per account.
    @ViewBuilder
    private func groupCard(_ section: AccountBalanceSection) -> some View {
        groupHeader(section)
            .listRowInsets(EdgeInsets(top: Self.cardGap, leading: Self.cardMargin + Self.cardPadding,
                                      bottom: 0, trailing: Self.cardMargin + Self.cardPadding))
            .listRowBackground(cardBackground(top: true, bottom: false, topGap: Self.cardGap))
            .listRowSeparator(.hidden)
        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
            let isLast = index == section.rows.count - 1
            NavigationLink(destination: AccountDetailView(account: row.account, currency: row.nativeCurrency)) {
                AccountRowView(row: row)
                    .frame(minHeight: 60)
                    .overlay(alignment: .bottom) {
                        if !isLast {
                            BalancedPalette.rule.frame(height: 0.5)
                                .padding(.leading, Self.iconSize + Self.iconSpacing)
                        }
                    }
                    .padding(.bottom, isLast ? 6 : 0)
            }
            .navigationLinkIndicatorVisibility(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: Self.cardMargin + Self.cardPadding,
                                      bottom: 0, trailing: Self.cardMargin + Self.cardPadding))
            .listRowBackground(cardBackground(top: false, bottom: isLast))
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("account-link-" + row.account + "-" + row.nativeCurrency)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button { selectedAccountForReconciliation = row } label: {
                    Label("校对余额", systemImage: "checkmark.seal")
                }.tint(TerminalPalette.accent)
            }
            .contextMenu {
                Button { selectedAccountForReconciliation = row } label: {
                    Label("校对余额 (对账)", systemImage: "checkmark.seal")
                }
            }
        }
    }

    private func groupHeader(_ section: AccountBalanceSection) -> some View {
        let total = groupTotal(section)
        let share = assetShareText(total)
        return HStack(alignment: .center, spacing: 12) {
            Text(section.title)
                .balancedFont(size: 17, weight: .medium)
                .foregroundStyle(BalancedPalette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.amountsVisible ? MoneyText.format(minorUnits: total, currency: valuationCurrency) : "••••••")
                    .balancedFont(size: 17, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(BalancedPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let share {
                    Text(share)
                        .balancedFont(size: 13)
                        .monospacedDigit()
                        .foregroundStyle(BalancedPalette.meta)
                        .lineLimit(1)
                }
            }
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account-group-\(section.id)")
    }

    private func cardBackground(top: Bool, bottom: Bool, topGap: CGFloat = 0) -> some View {
        let radius: CGFloat = 16
        return UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0,
            topTrailingRadius: top ? radius : 0,
            style: .continuous
        )
        .fill(AccountCardPalette.background)
        .padding(.horizontal, Self.cardMargin)
        .padding(.top, topGap)
    }
}

private enum AccountCardPalette {
    /// White in light mode, #1B1918 in dark.
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1918) : .white })
}

enum NetWorthTrendRange: String, CaseIterable, Identifiable {
    case oneMonth, threeMonths, sixMonths, yearToDate, oneYear, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMonth: String(localized: "1月")
        case .threeMonths: String(localized: "3月")
        case .sixMonths: String(localized: "6月")
        case .yearToDate: String(localized: "今年")
        case .oneYear: String(localized: "1年")
        case .all: String(localized: "全部")
        }
    }

    /// Filters date-sorted points relative to the *last* point's date, not today.
    /// Always returns at least two points (when available) so a line can be drawn.
    func filter(_ points: [LedgerNetWorthPoint]) -> [LedgerNetWorthPoint] {
        guard self != .all, let last = points.last else { return points }
        let cutoff: String
        if self == .yearToDate {
            cutoff = String(last.date.prefix(4)) + "-01-01"
        } else {
            guard let lastDate = LedgerDateRange.parse(last.date) else { return points }
            let months: Int
            switch self {
            case .oneMonth: months = 1
            case .threeMonths: months = 3
            case .sixMonths: months = 6
            default: months = 12
            }
            let start = LedgerDateRange.calendar.date(byAdding: .month, value: -months, to: lastDate) ?? lastDate
            cutoff = LedgerDateRange.format(start)
        }
        let filtered = points.filter { $0.date >= cutoff }
        return filtered.count >= 2 ? filtered : Array(points.suffix(2))
    }
}

/// Full-bleed net-worth sparkline: area + line only, no axes or grid, with a
/// dashed baseline at the first visible value. Draws even when amounts are
/// hidden — it carries no figures.
private struct AccountsNetWorthChart: View {
    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    private let data: [Point]
    private let lower: Double
    private let upper: Double

    init(points: [LedgerNetWorthPoint]) {
        let parsed: [Point] = points.compactMap { point in
            guard let date = LedgerDateRange.parse(point.date) else { return nil }
            return Point(id: point.date, date: date, value: Double(point.netWorth))
        }
        data = parsed
        let minValue = parsed.map(\.value).min() ?? 0
        let maxValue = parsed.map(\.value).max() ?? 0
        let span = maxValue - minValue
        let pad = span > 0 ? span * 0.08 : max(abs(maxValue) * 0.01, 1)
        lower = minValue - pad
        upper = maxValue + pad
    }

    private var areaFill: LinearGradient {
        LinearGradient(colors: [BalancedPalette.income.opacity(0.18), BalancedPalette.income.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        Chart {
            ForEach(data) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("下限", lower),
                    yEnd: .value("净资产", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(areaFill)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("净资产", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(BalancedPalette.income)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let first = data.first {
                RuleMark(y: .value("基准", first.value))
                    .foregroundStyle(BalancedPalette.ruleStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: lower...upper)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("净资产趋势"))
    }
}

private enum AccountGroupSymbol {
    static func symbol(for group: String) -> String {
        switch group {
        case "cash": "wallet.bifold"
        case "credit": "creditcard"
        case "liability": "creditcard.trianglebadge.exclamationmark"
        case "wealth": "chart.line.uptrend.xyaxis"
        case "receivable": "arrow.down.left.circle"
        case "asset": "building.columns"
        case "expense": "cart"
        case "income": "arrow.down.circle"
        case "equity": "scalemass"
        default: "folder"
        }
    }

    static func color(for group: String) -> Color {
        switch group {
        case "cash": Color(red: 0.12, green: 0.68, blue: 0.36)
        case "credit": Color(red: 0.96, green: 0.55, blue: 0.18)
        case "liability": Color(red: 0.88, green: 0.32, blue: 0.28)
        case "wealth": Color(red: 0.65, green: 0.36, blue: 0.88)
        case "receivable": Color(red: 0.16, green: 0.62, blue: 0.88)
        case "asset": Color(red: 0.16, green: 0.54, blue: 0.95)
        case "expense": Color(red: 0.95, green: 0.45, blue: 0.22)
        case "income": Color(red: 0.10, green: 0.72, blue: 0.44)
        case "equity": Color(red: 0.45, green: 0.55, blue: 0.68)
        default: LedgerPalette.cobalt
        }
    }

    static func title(for group: String) -> String {
        switch group {
        case "cash": String(localized: "现金与支付")
        case "credit": String(localized: "信用账户")
        case "liability": String(localized: "负债")
        case "wealth": String(localized: "储蓄与资产")
        case "receivable": String(localized: "应收")
        case "asset": String(localized: "资产")
        case "expense": String(localized: "支出账户")
        case "income": String(localized: "收入账户")
        case "equity": String(localized: "权益")
        default: String(localized: "其他")
        }
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var session: LedgerSession
    let account: String
    let currency: String

    @State private var detail: LedgerAccountDetail?
    @State private var errorMessage: String?
    @State private var reloadToken = 0
    @State private var showingReconcileSheet = false
    @State private var localWindow: LedgerSession.LocalAccountWindow?
    @State private var completeTrend: LocalAccountTrendScan.Result?
    @State private var trendError: String?
    @State private var pageLoading = false
    /// Rows appended by scrolling. `detail` always describes the accumulated page,
    /// so the hero and row count keep matching what is on screen.
    @State private var accumulatedRows: [LedgerAccountDetailRow] = []
    @State private var loadedRowIDs: Set<String> = []
    @State private var reachedRowCap = false
    static let historyRowCap = 1_000
    @State private var trendLoading = false
    @State private var active = false
    @State private var completedRequest: AccountDetailRequestKey?
    @State private var completedTrendRequest: AccountDetailRequestKey?
    private var displayedRange: LedgerDateRange {
        guard session.isLocal, let completedRequest else { return session.selectedRange }
        return .init(start: completedRequest.start, end: completedRequest.end, preset: .custom)
    }

    private var readable: Bool {
        session.phase == .ready && !session.privacyShielded && !session.isRangeLoading
            && !session.isValuationCurrencyLoading && !session.transactionMutationStates.values.contains(.pending)
    }
    private var trendKey: AccountDetailRequestKey {
        var key = requestKey
        key.page = 0
        return key
    }

    private var requestKey: AccountDetailRequestKey {
        AccountDetailRequestKey(
            account: account,
            currency: currency,
            start: session.selectedRange.start,
            end: session.selectedRange.end,
            reloadToken: reloadToken,
            revision: session.isLocal ? session.localTransactionPresentationRevision : nil,
            invalidation: session.isLocal ? session.localGlobalSearchInvalidation : 0,
            readable: session.isLocal ? readable : true,
            active: session.isLocal ? active : true,
            page: 0
        )
    }

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if let cached = session.cachedLocalAccountDetail(account: account, currency: currency) {
                detailContent(cached)
            } else if let errorMessage {
                VStack(spacing: LedgerSpacing.lg) {
                    EmptyLedgerState(
                        icon: "exclamationmark.triangle",
                        title: String(localized: "账户详情加载失败"),
                        detail: errorMessage
                    )
                    Button("重新加载") {
                        reloadToken += 1
                    }
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.onBrand)
                    .padding(.horizontal, LedgerSpacing.xl)
                    .frame(minHeight: 44)
                    .background(LedgerPalette.cobalt)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    .buttonStyle(PressScaleButtonStyle())
                    .padding(.bottom, LedgerSpacing.xxl)
                }
            } else if session.isLocal {
                localAccountSummary
            } else {
                VStack(spacing: LedgerSpacing.md) {
                    ProgressView()
                        .tint(LedgerPalette.cobalt)
                    Text("正在加载账户详情")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LedgerPalette.canvas)
        .terminalPageChrome(detail?.label ?? String(localized: "账户详情"), compactTitle: String(localized: "账户详情"), isRoot: false, showsTimeRange: true, actions: AnyView(
            Button { showingReconcileSheet = true } label: {
                Image(systemName: "checkmark.seal").font(.system(size: 16))
                    .foregroundStyle(TerminalPalette.accent).frame(width: 44, height: 44)
            }.accessibilityLabel("校对余额")
        ))
        .sheet(isPresented: $showingReconcileSheet, onDismiss: {
            reloadToken += 1
        }) {
            SingleAccountReconciliationSheet(
                account: account,
                label: detail?.label,
                currency: currency
            )
        }
        .task(id: requestKey) {
            if session.isLocal { await loadLocalPage() }
            else { await load(replacingContent: detail == nil) }
        }
        .task(id: trendKey) { if session.isLocal { await loadLocalTrend() } }
        .onAppear {
            active = true
            if let cached = session.cachedLocalAccountTrend(account: account, currency: currency) {
                completeTrend = cached
                completedTrendRequest = trendKey
            }
        }
        .onDisappear { active = false }
        .onChange(of: readable) { _, allowed in
            if session.isLocal && !allowed {
                detail = nil; localWindow = nil; completeTrend = nil; completedRequest = nil; completedTrendRequest = nil
                errorMessage = nil; trendError = nil
            }
        }
        .onChange(of: session.selectedRange) { _, _ in resetHistory() }
        .onChange(of: session.localTransactionPresentationRevision) { _, _ in resetHistory() }
    }

    // The bootstrap already contains the account catalog and current balances.
    // Present those facts immediately while the bounded history page is read.
    private var localAccountSummary: some View {
        List {
            Section("账户") {
                Text(session.ledger?.accounts.first(where: { $0.account == account })?.label ?? account)
                    .font(.headline)
                Text(account).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let balance = session.ledger?.accountBalances.first(where: { $0.account == account && $0.currency == currency }) {
                Section("当前余额") {
                    AmountLabel(minorUnits: balance.amount, currency: balance.currency, font: .custom(BalancedWeight.medium.sansPostscriptName, size: 21, relativeTo: .title2))
                }
            }
        }
        .ledgerReadingList()
    }

    private func detailContent(_ detail: LedgerAccountDetail) -> some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        let visibleRows: [LedgerAccountDetailRow] = session.isLocal && !accumulatedRows.isEmpty ? accumulatedRows : detail.rows
        return ScrollView {
            LazyVStack(spacing: LedgerSpacing.md) {
                AccountDetailHero(
                    detail: detail,
                    range: displayedRange,
                    onReconcile: { showingReconcileSheet = true }
                )

                if let errorMessage {
                    StatusBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                    if session.isLocal {
                        Button("重试账户流水") { reloadToken += 1 }
                            .accessibilityIdentifier("account-history-retry")
                    }
                }

                if session.isLocal {
                    if let completeTrend, completedTrendRequest == trendKey {
                        AccountBalanceTrendPanel(detail: completeTrend.detail, range: session.selectedRange,
                            completePoints: completeTrend.points)
                    } else if let trendError {
                        Text("余额趋势读取失败：\(trendError)").foregroundStyle(.secondary)
                        Button("重试余额趋势") { reloadToken += 1 }
                    } else if trendLoading {
                        ProgressView("正在读取完整余额趋势…")
                    } else {
                        Text("余额趋势需要重新读取。").foregroundStyle(.secondary)
                        Button("重新读取余额趋势") { reloadToken += 1 }
                    }
                } else {
                    AccountBalanceTrendPanel(detail: detail, range: session.selectedRange)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("账户流水")
                        .font(.system(.body, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Text("\(session.isLocal && !accumulatedRows.isEmpty ? accumulatedRows.count : (localWindow?.page.rowCount ?? detail.rows.count)) 笔")
                        .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.top, LedgerSpacing.sm)

                if visibleRows.isEmpty {
                    Text("这个账户暂无关联流水。")
                        .font(.system(.footnote, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LedgerPanel {
                        LazyVStack(spacing: 0) {
                            ForEach(Array((session.isLocal ? visibleRows : Array(detail.rows.reversed())).enumerated()), id: \.element.id) { index, row in
                                NavigationLink {
                                    TransactionDetailView(transaction: row.transaction)
                                } label: {
                                    AccountHistoryRow(row: row, currency: detail.currency, accountLabels: accountLabels)
                                }
                                .buttonStyle(PressScaleButtonStyle())
                                .ledgerTransactionActions(row.transaction)
                                .disabled(session.isLocal && pageLoading)
                                .accessibilityIdentifier("account-history-row-" + row.transaction.id)

                                if index < visibleRows.count - 1 {
                                    Divider()
                                        .overlay(LedgerPalette.line)
                                        .padding(.leading, LedgerSpacing.lg)
                                }
                            }
                        }
                    }
                }
                if session.isLocal, let localWindow, localWindow.continuation != nil, !reachedRowCap {
                    historyLoadMore
                } else if session.isLocal, reachedRowCap {
                    Text("已加载 \(accumulatedRows.count) 笔，缩小时间范围可以看得更远。")
                        .font(.system(.caption, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, LedgerSpacing.sm)
                }
            }
            .padding(LedgerSpacing.lg)
            .padding(.bottom, LedgerSpacing.xxl)
            .ledgerAdaptivePageWidth()
        }
        .refreshable {
            if session.isLocal { resetHistory(); reloadToken += 1 }
            else { await load(replacingContent: false) }
        }
    }

    /// Tail of the account history. Appearing appends the next window in place, so
    /// the reader keeps its position; tapping retries a stalled fetch.
    private var historyLoadMore: some View {
        let busy = pageLoading
        return Button {
            guard !busy else { return }
            Task { await appendLocalPage() }
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).tint(LedgerPalette.secondary)
                    Text("正在加载更多流水…")
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 14))
                    Text("继续加载")
                }
            }
            .font(.system(.caption, design: .default))
            .foregroundStyle(LedgerPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .padding(.top, LedgerSpacing.sm)
        .onAppear {
            guard !busy else { return }
            Task { await appendLocalPage() }
        }
        .accessibilityIdentifier("account-history-load-more")
        .accessibilityLabel(busy ? "正在加载更多账户流水" : "继续加载更多账户流水")
    }

    private func resetHistory() {
        accumulatedRows = []
        loadedRowIDs = []
        reachedRowCap = false
    }

    /// Append the next bounded page of history without replacing what is visible.
    private func appendLocalPage() async {
        guard active, readable, !pageLoading, let localWindow,
              let continuation = localWindow.continuation,
              accumulatedRows.count < Self.historyRowCap else { return }
        let key = requestKey
        pageLoading = true
        errorMessage = nil
        defer { if key == requestKey { pageLoading = false } }
        do {
            let window = try await session.localAccountWindow(account: account, currency: currency,
                continuation: continuation, order: .desc)
            guard !Task.isCancelled, key == requestKey, readable else { return }
            for row in window.page.detail.rows where !loadedRowIDs.contains(row.id) {
                accumulatedRows.append(row)
                loadedRowIDs.insert(row.id)
            }
            reachedRowCap = accumulatedRows.count >= Self.historyRowCap
            self.localWindow = window
        } catch {
            if !Task.isCancelled, key == requestKey {
                errorMessage = error is CancellationError ? String(localized: "账户读取已中断，请重新加载。") : error.localizedDescription
            }
        }
    }

    private func loadLocalPage() async {
        guard active, readable else { return }
        let key = requestKey
        pageLoading = true
        errorMessage = nil
        defer { if key == requestKey { pageLoading = false } }
        do {
            // Always load the first page of the window; further pages append from here.
            let window = try await session.localAccountWindow(account: account, currency: currency,
                continuation: nil, order: .desc)
            guard !Task.isCancelled, key == requestKey, readable else { return }
            localWindow = window
            detail = window.page.detail
            accumulatedRows = window.page.detail.rows
            loadedRowIDs = Set(window.page.detail.rows.map(\.id))
            reachedRowCap = accumulatedRows.count >= Self.historyRowCap
            completedRequest = key
        } catch {
            if !Task.isCancelled, key == requestKey {
                errorMessage = error is CancellationError ? String(localized: "账户读取已中断，请重新加载。") : error.localizedDescription
            }
        }
    }

    private func loadLocalTrend() async {
        guard active, readable else { return }
        let key = trendKey
        trendLoading = true
        trendError = nil
        defer { if key == trendKey { trendLoading = false } }
        do {
            let result = try await session.localAccountTrend(account: account, currency: currency,
                forceRefresh: key.reloadToken != 0 && completedTrendRequest?.reloadToken != key.reloadToken)
            guard !Task.isCancelled, key == trendKey, readable else { return }
            completeTrend = result
            completedTrendRequest = key
        } catch {
            if !Task.isCancelled, key == trendKey {
                completeTrend = nil
                trendError = error is CancellationError ? String(localized: "读取已中断，请重试。") : error.localizedDescription
            }
        }
    }

    private func load(replacingContent: Bool = true) async {
        if replacingContent {
            detail = nil
        }
        errorMessage = nil
        do {
            let updatedDetail = try await session.accountDetail(for: account, currency: currency)
            guard !Task.isCancelled else { return }
            detail = updatedDetail
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountDetailRequestKey: Hashable {
    let account: String
    let currency: String
    let start: String
    let end: String
    let reloadToken: Int
    let revision: UUID?
    let invalidation: Int
    let readable: Bool
    let active: Bool
    var page: Int
}

private struct AccountDetailHero: View {
    let detail: LedgerAccountDetail
    let range: LedgerDateRange
    var onReconcile: (() -> Void)? = nil

    private var openingBalance: Int {
        detail.openingBalance ?? detail.rows.first.map { $0.balance - $0.change } ?? detail.currentBalance
    }

    private var closingBalance: Int {
        detail.closingBalance ?? detail.rows.last?.balance ?? openingBalance
    }

    private var periodChange: Int {
        detail.periodChange ?? (closingBalance - openingBalance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            HStack(alignment: .top, spacing: LedgerSpacing.md) {
                Image(systemName: AccountGroupSymbol.symbol(for: detail.group))
                    .font(.system(.headline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 46, height: 46)
                    .background(LedgerPalette.tag)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: LedgerSpacing.sm) {
                        Text(AccountGroupSymbol.title(for: detail.group))
                        Text("·")
                        Text(detail.currency)
                    }
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !detail.active {
                    Text("已关闭")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .background(LedgerPalette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm))
                }
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(detail.account.hasPrefix("Liabilities:") ? "期末待还" : "期末余额")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: closingBalance,
                        currency: detail.currency,
                        font: .custom(BalancedWeight.medium.sansPostscriptName, size: 21, relativeTo: .title2),
                        color: detail.account.hasPrefix("Liabilities:")
                            ? LedgerPalette.expense
                            : LedgerPalette.gold
                    )
                    .tracking(-0.75)
                    .lineLimit(1)
                }

                if let onReconcile {
                    Spacer()
                    Button(action: onReconcile) {
                        Text("校对")
                            .balancedFont(size: 13)
                            .foregroundStyle(BalancedPalette.secondary)
                            .padding(.bottom, 1)
                            .overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel("校对余额")
                }
            }

            HStack(spacing: LedgerSpacing.xl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("期初余额")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: openingBalance,
                        currency: detail.currency,
                        font: .custom(BalancedWeight.text.sansPostscriptName, size: 12, relativeTo: .caption),
                        color: LedgerPalette.olive
                    )
                    .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("期间变化")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: periodChange,
                        currency: detail.currency,
                        prefix: periodChange > 0 ? "+" : "",
                        font: .custom(BalancedWeight.text.sansPostscriptName, size: 12, relativeTo: .caption),
                        color: periodChange >= 0 ? LedgerPalette.income : LedgerPalette.expense
                    )
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let alias = detail.alias, alias != detail.label {
                    Text(alias)
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.olive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail.label).terminalFont(size: 14, weight: .semibold)
                Text(detail.account)
                    .font(.system(.caption2, design: .default, weight: .medium).monospaced())
                    .foregroundStyle(LedgerPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

private struct AccountBalanceTrendPanel: View {
    @EnvironmentObject private var session: LedgerSession
    let detail: LedgerAccountDetail
    let range: LedgerDateRange
    var completePoints: [LedgerAccountBalanceTrendPoint]? = nil

    @State private var selectedIndex: Int?

    private var points: [LedgerAccountBalanceTrendPoint] {
        completePoints ?? detail.balanceTrend(in: range, maxPoints: 180)
    }

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.date), referenceLabel: points.first?.date)
    }

    private var periodChange: Int? {
        detail.periodChange ?? points.first.flatMap { first in
            points.last.map { $0.balance - first.balance }
        }
    }

    var body: some View {
        LedgerPanel {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("余额趋势")
                            .font(.system(.body, design: .default, weight: .semibold))
                            .tracking(-0.15)
                            .foregroundStyle(LedgerPalette.ink)
                        Text("所选期间 · 原币余额").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                    }
                    Spacer()
                    if let periodChange {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("期间变化")
                                .font(.system(.caption2, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                            AmountLabel(
                                minorUnits: periodChange,
                                currency: detail.currency,
                                prefix: periodChange > 0 ? "+" : "",
                                font: .custom(BalancedWeight.medium.sansPostscriptName, size: 11.5, relativeTo: .caption2),
                                color: periodChange >= 0 ? LedgerPalette.income : LedgerPalette.expense
                            )
                            .lineLimit(1)
                        }
                    }
                }

                if points.isEmpty {
                    trendEmptyState
                } else if session.amountsVisible {
                    trendChart
                } else {
                    hiddenTrendState
                }
            }
            .padding(LedgerSpacing.lg)
        }
    }

    private var trendChart: some View {
        ZStack(alignment: .topTrailing) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let x = axis.position(at: index)
                    AreaMark(
                        x: .value("日期", x),
                        y: .value("余额", point.balance)
                    )
                    .foregroundStyle(LedgerPalette.cobalt.opacity(0.10))
                    .interpolationMethod(.stepEnd)

                    LineMark(
                        x: .value("日期", x),
                        y: .value("余额", point.balance)
                    )
                    .foregroundStyle(LedgerPalette.cobalt)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.stepEnd)

                    if points.count <= 12 {
                        PointMark(
                            x: .value("日期", x),
                            y: .value("余额", point.balance)
                        )
                        .foregroundStyle(LedgerPalette.cobalt)
                        .symbolSize(18)
                    }
                }

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let point = points[selectedIndex]
                    let x = axis.position(at: selectedIndex)
                    RuleMark(x: .value("选中日期", x))
                        .foregroundStyle(LedgerPalette.lineStrong)
                    PointMark(x: .value("选中日期", x), y: .value("选中余额", point.balance))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .symbolSize(52)
                }
            }
            .chartXScale(domain: axis.domain)
            .chartXAxis {
                AxisMarks(position: .bottom, values: axis.tickPositions(maxCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(LedgerPalette.line)
                    AxisTick().foregroundStyle(LedgerPalette.lineStrong)
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let position = value.as(Double.self) {
                            Text(axis.shortLabel(nearestTo: position))
                                .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
            .privacySensitive()
            .accessibilityLabel("账户余额趋势图，可点按或拖动查看数据")
            .accessibilityValue(axis.usesTimeScale ? "真实时间轴" : "有序分类轴")
            .accessibilityIdentifier("account-balance-trend-chart")

            if let selectedIndex, points.indices.contains(selectedIndex) {
                let point = points[selectedIndex]
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.date)
                        .font(.system(.caption2, design: .default, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: point.balance,
                        currency: detail.currency,
                        font: .custom(BalancedWeight.medium.sansPostscriptName, size: 11.5, relativeTo: .caption2),
                        color: LedgerPalette.ink
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LedgerPalette.panel.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous)
                        .stroke(LedgerPalette.line, lineWidth: 1)
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("account-balance-chart-selection")
            }
        }
        .frame(height: 210)
    }

    private var trendEmptyState: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("有账户流水后，这里会显示每日结余趋势。")
                .font(.system(.caption, design: .default))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var hiddenTrendState: some View {
        VStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("余额趋势已隐藏")
                .font(.system(.caption, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private var rangeLabel: String {
        String(localized: "\(range.start.replacingOccurrences(of: "-", with: "/")) 至 \(range.end.replacingOccurrences(of: "-", with: "/"))")
    }

    private func selectionOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let x = value.location.x - frame.minX
                            guard x >= 0, x <= frame.width,
                                  let position: Double = proxy.value(atX: x) else { return }
                            selectedIndex = axis.nearestIndex(to: position)
                        }
                )
        }
    }
}

private struct AccountHistoryRow: View {
    let row: LedgerAccountDetailRow
    let currency: String
    let accountLabels: [String: String]

    private var title: String {
        if !row.payee.isEmpty { return row.payee }
        if !row.narration.isEmpty { return row.narration }
        return String(localized: "未命名交易")
    }

    var body: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                HStack(spacing: LedgerSpacing.sm) {
                    Text(row.date)
                        .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                    TransactionContextLine(transaction: row.transaction, accountLabels: accountLabels)
                }
                .font(.system(.caption2, design: .default))
                .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                AmountLabel(
                    minorUnits: row.change,
                    currency: currency,
                    prefix: row.change > 0 ? "+" : "",
                    font: .custom(BalancedWeight.medium.sansPostscriptName, size: 13, relativeTo: .footnote),
                    color: row.change >= 0 ? LedgerPalette.income : LedgerPalette.expense
                )
                .lineLimit(1)
                AmountLabel(
                    minorUnits: row.balance,
                    currency: currency,
                    font: .custom(BalancedWeight.text.sansPostscriptName, size: 11.5, relativeTo: .caption2),
                    color: LedgerPalette.secondary
                )
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerLayout.transactionVerticalInset)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRowView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: AccountBalanceRow

    private var accountIcon: (name: String, color: Color) {
        let act = row.account.lowercased()
        if act.contains("alipay") || row.label.contains("支付宝") {
            return ("a.square.fill", Color(red: 0.08, green: 0.52, blue: 0.95))
        }
        if act.contains("wechat") || act.contains("wx") || row.label.contains("微信") {
            return ("message.fill", Color(red: 0.12, green: 0.75, blue: 0.38))
        }
        if act.contains("card") || act.contains("credit") || row.label.contains("信用卡") {
            return ("creditcard.fill", Color(red: 0.96, green: 0.55, blue: 0.18))
        }
        if act.contains("bank") || row.label.contains("银行") || row.label.contains("储蓄") {
            return ("building.columns.fill", Color(red: 0.16, green: 0.54, blue: 0.95))
        }
        if act.contains("cash") || row.label.contains("现金") {
            return ("banknote.fill", Color(red: 0.12, green: 0.68, blue: 0.36))
        }
        if act.contains("invest") || act.contains("stock") || act.contains("fund") || row.label.contains("基金") || row.label.contains("股票") {
            return ("chart.line.uptrend.xyaxis", Color(red: 0.65, green: 0.36, blue: 0.88))
        }
        return (AccountGroupSymbol.symbol(for: row.group), AccountGroupSymbol.color(for: row.group))
    }

    /// One short secondary line: the account path without its root, e.g. "Bank:CMB".
    private var subtitle: String {
        let parts = row.account.split(separator: ":")
        return parts.count > 1 ? parts.dropFirst().joined(separator: ":") : row.account
    }

    private var balance: Int { row.periodBalancesAvailable ? row.closingValuation : row.valuation }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: accountIcon.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TerminalPalette.accent)
                .frame(width: 36, height: 36)
                .background(Circle().fill(BalancedPalette.sunken))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.label)
                        .balancedFont(size: 16, weight: .text)
                        .foregroundStyle(BalancedPalette.ink)
                        .lineLimit(1)
                    if let status = session.accountStatus(for: row.account) {
                        Circle()
                            .fill(status.statusColor)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(subtitle)
                    .balancedFont(size: 13)
                    .foregroundStyle(BalancedPalette.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if row.periodBalancesAvailable && row.periodValuationMissing {
                    Text("缺少期间汇率")
                        .balancedFont(size: 13, weight: .medium)
                        .foregroundStyle(LedgerPalette.risk)
                } else {
                    AmountLabel(
                        minorUnits: balance,
                        currency: row.valuationCurrency,
                        font: .custom(BalancedWeight.text.sansPostscriptName, size: 16, relativeTo: .body),
                        color: BalancedPalette.ink
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
                if row.nativeCurrency != row.valuationCurrency {
                    AmountLabel(
                        minorUnits: row.periodBalancesAvailable ? row.closingNativeAmount : row.nativeAmount,
                        currency: row.nativeCurrency,
                        font: .custom(BalancedWeight.text.sansPostscriptName, size: 13, relativeTo: .caption),
                        color: BalancedPalette.meta
                    )
                    .lineLimit(1)
                } else if row.periodBalancesAvailable && !row.periodValuationMissing && row.periodValuationChange != 0 {
                    AmountLabel(
                        minorUnits: row.periodValuationChange,
                        currency: row.valuationCurrency,
                        prefix: row.periodValuationChange > 0 ? "+" : "",
                        font: .custom(BalancedWeight.text.sansPostscriptName, size: 13, relativeTo: .caption),
                        color: row.periodValuationChange >= 0 ? BalancedPalette.income : BalancedPalette.expense
                    )
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
