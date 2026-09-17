import Charts
import SwiftUI

enum LedgerAnalysisKind: String, CaseIterable, Hashable {
    case assets
    case incomeExpense
    case investments

    var title: String {
        switch self {
        case .assets: "资产分析"
        case .incomeExpense: "收支分析"
        case .investments: "投资"
        }
    }

    var detail: String {
        switch self {
        case .assets: "资产、负债、结构与净值趋势"
        case .incomeExpense: "收入、支出、现金流与分类洞察"
        case .investments: "持仓市值、成本与收益"
        }
    }

    var systemImage: String {
        switch self {
        case .assets: "building.columns"
        case .incomeExpense: "chart.bar.xaxis"
        case .investments: "chart.pie"
        }
    }

    var resourceKind: LedgerAnalysisResourceKind {
        switch self {
        case .assets: .assets
        case .incomeExpense: .incomeExpense
        case .investments: .investments
        }
    }
}

struct LedgerAnalysisView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let kind: LedgerAnalysisKind
    var isRoot = false

    @State private var resource: LedgerAnalysisResource?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    private var requestKey: AnalysisRequestKey {
        AnalysisRequestKey(
            kind: kind,
            start: session.selectedRange.start,
            end: session.selectedRange.end,
            valuationCurrency: session.ledger?.valuationCurrency ?? "CNY",
            reloadToken: reloadToken
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let resource {
                    content(resource)
                } else if let errorMessage {
                    VStack(spacing: LedgerSpacing.lg) {
                        EmptyLedgerState(icon: "exclamationmark.triangle", title: "分析数据加载失败", detail: errorMessage)
                        Button("重新加载") { reloadToken += 1 }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.onBrand)
                            .padding(.horizontal, LedgerSpacing.xl)
                            .frame(minHeight: 44)
                            .background(LedgerPalette.cobalt)
                            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                            .buttonStyle(PressScaleButtonStyle())
                    }
                } else {
                    VStack(spacing: LedgerSpacing.md) {
                        ProgressView().tint(LedgerPalette.cobalt)
                        Text("正在整理\(kind.title)数据")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(LedgerPalette.canvas)
        .ledgerNavigation(kind.title, isRoot: isRoot, showsTimeRange: true)
        .task(id: requestKey) {
            await load(replacingContent: resource == nil)
        }
    }

    @ViewBuilder
    private func content(_ resource: LedgerAnalysisResource) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                    Color.clear
                        .frame(height: 0)
                        .id(analysisTopID)

                    if let errorMessage {
                        StatusBanner(message: errorMessage) { self.errorMessage = nil }
                    }

                    switch resource {
                    case let .assets(data):
                        AssetsAnalysisContent(data: data)
                    case let .incomeExpense(data):
                        IncomeExpenseAnalysisContent(data: data)
                    case let .investments(data):
                        InvestmentsAnalysisContent(data: data)
                    }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
                .padding(.top, LedgerLayout.pageTopInset)
                .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
                .ledgerAdaptivePageWidth()
            }
            .id(kind)
            .accessibilityIdentifier("analysis-content-\(kind.rawValue)")
            .refreshable { await refresh() }
            .onAppear {
                proxy.scrollTo(analysisTopID, anchor: .top)
            }
        }
    }

    private var analysisTopID: String { "analysis-top-\(kind.rawValue)" }

    private func load(replacingContent: Bool = true) async {
        if replacingContent { resource = nil }
        errorMessage = nil
        do {
            let updated = try await session.analysisResource(kind.resourceKind)
            guard !Task.isCancelled else { return }
            resource = updated
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        if kind == .assets {
            await session.refresh()
            if let message = session.errorMessage {
                errorMessage = message
                return
            }
        }
        await load(replacingContent: false)
    }
}

private struct AnalysisRequestKey: Hashable {
    let kind: LedgerAnalysisKind
    let start: String
    let end: String
    let valuationCurrency: String
    let reloadToken: Int
}

private struct AssetAccountItem: Identifiable {
    let account: String
    let label: String
    let amount: Int
    let ratio: Double
    var id: String { account }
}

private struct LiabilityAccountItem: Identifiable {
    let account: String
    let label: String
    let amount: Int
    let ratio: Double
    var id: String { account }
}

private struct AllocationSliceItem: Identifiable {
    let id: String
    let label: String
    let icon: String
    let color: Color
    let amount: Int
    let percentage: Double
}

private func assetVisual(for account: String, label: String, group: String? = nil) -> (icon: String, color: Color) {
    let text = "\(label) \(account)".lowercased()

    if account.hasPrefix("Liabilities:") {
        if text.contains("credit") || text.contains("信用卡") || text.contains("花呗") || text.contains("白条") {
            return ("creditcard.fill", Color(red: 0.94, green: 0.36, blue: 0.34))
        }
        if text.contains("loan") || text.contains("房贷") || text.contains("车贷") || text.contains("贷款") || text.contains("借款") {
            return ("house.fill", Color(red: 0.95, green: 0.55, blue: 0.22))
        }
        return ("creditcard.trianglebadge.exclamationmark", Color(red: 0.94, green: 0.36, blue: 0.34))
    }

    // Assets
    if text.contains("alipay") || text.contains("支付宝") || text.contains("余额宝") {
        return ("cart.fill", Color(red: 0.08, green: 0.52, blue: 0.98))
    }
    if text.contains("wechat") || text.contains("微信") || text.contains("财付通") {
        return ("message.fill", Color(red: 0.09, green: 0.72, blue: 0.32))
    }
    if text.contains("bank") || text.contains("银行") || text.contains("招商") || text.contains("工行") || text.contains("建行") || text.contains("农行") || text.contains("中行") || text.contains("交通银行") || text.contains("浦发") || text.contains("中信") || text.contains("民生") || text.contains("兴业") || text.contains("平安") || text.contains("广发") || text.contains("checking") || text.contains("savings") {
        return ("building.columns.fill", Color(red: 0.16, green: 0.54, blue: 0.95))
    }
    if text.contains("fund") || text.contains("invest") || text.contains("stock") || text.contains("理财") || text.contains("基金") || text.contains("股票") || text.contains("证券") || group == "wealth" {
        return ("chart.line.uptrend.xyaxis", Color(red: 0.35, green: 0.45, blue: 0.88))
    }
    if text.contains("receivable") || text.contains("应收") || text.contains("借出") || group == "receivable" {
        return ("arrow.uturn.backward.circle.fill", Color(red: 1.0, green: 0.58, blue: 0.0))
    }
    if text.contains("cash") || text.contains("现金") || group == "cash" {
        return ("banknote.fill", Color(red: 0.12, green: 0.68, blue: 0.36))
    }
    return ("wallet.bifold.fill", LedgerPalette.cobalt)
}

private struct AssetsAnalysisContent: View {
    let data: LedgerAssetsAnalysis

    @State private var trendMode = AssetTrendMode.daily

    private var valuations: [String: Int] {
        Dictionary(grouping: data.accountBalances.filter { $0.valuationMissing != true }, by: \.account)
            .mapValues { $0.reduce(0) { $0 + $1.valuation } }
    }

    private var assets: Int {
        valuations.filter { $0.key.hasPrefix("Assets:") }.values.reduce(0, +)
    }

    private var liabilities: Int {
        valuations.filter { $0.key.hasPrefix("Liabilities:") }.values.reduce(0) { $0 + abs($1) }
    }

    private var netWorth: Int { assets - liabilities }

    private var assetAccountsList: [AssetAccountItem] {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.account, $0) })
        let total = max(assets, 1)
        return valuations
            .filter { $0.key.hasPrefix("Assets:") && $0.value > 0 }
            .map { account, value in
                let label = accounts[account]?.displayLabel ?? account.split(separator: ":").last.map(String.init) ?? account
                return AssetAccountItem(
                    account: account,
                    label: label,
                    amount: value,
                    ratio: Double(value) / Double(total)
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    private var liabilitiesAccountsList: [LiabilityAccountItem] {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.account, $0) })
        let total = max(liabilities, 1)
        return valuations
            .filter { $0.key.hasPrefix("Liabilities:") && $0.value != 0 }
            .map { account, value in
                let val = abs(value)
                let label = accounts[account]?.displayLabel ?? account.split(separator: ":").last.map(String.init) ?? account
                return LiabilityAccountItem(
                    account: account,
                    label: label,
                    amount: val,
                    ratio: Double(val) / Double(total)
                )
            }
            .sorted { $0.amount > $1.amount }
    }

    private var allocationList: [AllocationSliceItem] {
        let known = Set(data.accounts.map(\.account))
        var totals = ["现金与存款": 0, "理财与投资": 0, "应收与借出": 0, "其他资产": 0]
        for account in data.accounts where account.account.hasPrefix("Assets:") {
            let amount = valuations[account.account] ?? 0
            switch account.group {
            case "cash": totals["现金与存款", default: 0] += amount
            case "wealth": totals["理财与投资", default: 0] += amount
            case "receivable": totals["应收与借出", default: 0] += amount
            default: totals["其他资产", default: 0] += amount
            }
        }
        totals["其他资产", default: 0] += valuations
            .filter { $0.key.hasPrefix("Assets:") && !known.contains($0.key) }
            .values.reduce(0, +)

        let total = max(assets, 1)
        let configs: [(id: String, label: String, icon: String, color: Color)] = [
            ("cash", "现金与存款", "banknote.fill", Color(red: 0.12, green: 0.68, blue: 0.36)),
            ("wealth", "理财与投资", "chart.pie.fill", Color(red: 0.0, green: 0.48, blue: 1.0)),
            ("receivable", "应收与借出", "arrow.uturn.backward.circle.fill", Color(red: 1.0, green: 0.58, blue: 0.0)),
            ("other", "其他资产", "cube.box.fill", Color(red: 0.69, green: 0.32, blue: 0.87)),
        ]

        return configs.compactMap { config in
            guard let val = totals[config.label], val > 0 else { return nil }
            return AllocationSliceItem(
                id: config.id,
                label: config.label,
                icon: config.icon,
                color: config.color,
                amount: val,
                percentage: Double(val) / Double(total)
            )
        }
    }

    private var trendPoints: [LedgerNetWorthPoint] {
        trendMode == .monthEnd && data.monthEndNetWorth.count > 1
            ? data.monthEndNetWorth
            : data.netWorthHistory
    }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AssetsHeroCard(
                netWorth: netWorth,
                assets: assets,
                liabilities: liabilities,
                currency: data.valuationCurrency,
                windows: data.netWorthWindows,
                debtRatio: assets > 0 ? Double(liabilities) / Double(assets) : nil
            )

            AssetAllocationDonutCard(
                allocations: allocationList,
                totalAssets: assets,
                currency: data.valuationCurrency
            )

            AssetAccountsRankingCard(
                accounts: assetAccountsList,
                totalAssets: assets,
                currency: data.valuationCurrency
            )

            LiabilitiesBreakdownCard(
                accounts: liabilitiesAccountsList,
                totalLiabilities: liabilities,
                currency: data.valuationCurrency
            )

            AnalysisChartPanel(title: "净值走势", detail: "资产、负债与净资产的长期趋势") {
                Picker("趋势粒度", selection: $trendMode) {
                    ForEach(AssetTrendMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(data.monthEndNetWorth.count <= 1)

                if trendPoints.isEmpty {
                    AnalysisEmptyContent(icon: "chart.line.uptrend.xyaxis", message: "所选范围暂无净值趋势")
                } else {
                    NetWorthTrendChart(
                        points: trendPoints,
                        currency: data.valuationCurrency,
                        referenceLabel: trendPoints.first?.date ?? ""
                    )
                }
            }
        }
    }
}

private struct AssetsHeroCard: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.colorScheme) private var colorScheme

    let netWorth: Int
    let assets: Int
    let liabilities: Int
    let currency: String
    let windows: LedgerNetWorthWindows?
    let debtRatio: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Top Row: Net worth title & Debt ratio badge
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("净资产")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)

                    AmountLabel(
                        minorUnits: netWorth,
                        currency: currency,
                        font: .system(size: 30, weight: .bold, design: .rounded),
                        color: netWorth >= 0 ? LedgerPalette.ink : LedgerPalette.expense
                    )
                }

                Spacer()

                if let debtRatio, debtRatio.isFinite {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(debtRatioColor(debtRatio))
                                .frame(width: 6, height: 6)
                            Text("负债率 \(debtRatio.formatted(.percent.precision(.fractionLength(1))))")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(debtRatioColor(debtRatio))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(debtRatioColor(debtRatio).opacity(0.12), in: Capsule())

                        Text(debtRatioLevel(debtRatio))
                            .font(.system(size: 10))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
            }

            // Middle: Assets vs Liabilities Dual Balance Bar
            VStack(spacing: 8) {
                HStack {
                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(kind: .all)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "building.columns.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(LedgerPalette.cobalt)
                            Text("总资产")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LedgerPalette.secondary)
                            AmountLabel(
                                minorUnits: assets,
                                currency: currency,
                                font: .system(size: 13, weight: .bold, design: .rounded),
                                color: LedgerPalette.ink
                            )
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    HStack(spacing: 5) {
                        Text("总负债")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(
                            minorUnits: liabilities,
                            currency: currency,
                            font: .system(size: 13, weight: .bold, design: .rounded),
                            color: LedgerPalette.expense
                        )
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.expense)
                    }
                }

                // Balance Progress Bar
                GeometryReader { geo in
                    let total = max(assets + liabilities, 1)
                    let assetWidth = max(geo.size.width * CGFloat(assets) / CGFloat(total), assets > 0 ? 6 : 0)
                    let liabilityWidth = geo.size.width - assetWidth

                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(LinearGradient(colors: [LedgerPalette.cobalt, Color(red: 0.20, green: 0.65, blue: 1.0)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: assetWidth)

                        if liabilities > 0 {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.35), LedgerPalette.expense], startPoint: .leading, endPoint: .trailing))
                                .frame(width: liabilityWidth)
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
            }
            .padding(.vertical, 4)

            // Bottom: Window Change metrics (Month Change, 6-Month, 12-Month)
            HStack(spacing: 8) {
                WindowMetricBadge(
                    title: "期间变化",
                    amount: windows?.monthChange,
                    currency: currency,
                    subtitle: windows?.previousMonthEnd != nil ? "比上月末" : nil
                )
                WindowMetricBadge(
                    title: "近 6 个月",
                    ratio: windows?.sixMonth.changeRatio,
                    amount: windows?.sixMonth.change,
                    currency: currency
                )
                WindowMetricBadge(
                    title: "近 12 个月",
                    ratio: windows?.twelveMonth.changeRatio,
                    amount: windows?.twelveMonth.change,
                    currency: currency
                )
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }

    private func debtRatioColor(_ ratio: Double) -> Color {
        if ratio <= 0.30 { return Color(red: 0.12, green: 0.68, blue: 0.36) }
        if ratio <= 0.55 { return Color(red: 0.96, green: 0.55, blue: 0.18) }
        return Color(red: 0.92, green: 0.28, blue: 0.28)
    }

    private func debtRatioLevel(_ ratio: Double) -> String {
        if ratio <= 0.15 { return "财务非常稳健" }
        if ratio <= 0.30 { return "负债健康" }
        if ratio <= 0.55 { return "负债适中" }
        return "负债偏高"
    }
}

private struct WindowMetricBadge: View {
    let title: String
    var ratio: Double? = nil
    var amount: Int? = nil
    let currency: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)

            if let ratio {
                let isPositive = ratio >= 0
                Text((isPositive ? "+" : "") + ratio.formatted(.percent.precision(.fractionLength(1))))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isPositive ? LedgerPalette.income : LedgerPalette.expense)
            } else if let amount {
                AmountLabel(
                    minorUnits: amount,
                    currency: currency,
                    font: .system(size: 13, weight: .bold, design: .rounded),
                    color: amount >= 0 ? LedgerPalette.income : LedgerPalette.expense,
                    showSign: true
                )
            } else {
                Text("—")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(LedgerPalette.secondary.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(uiColor: .tertiarySystemFill).opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AssetAllocationDonutCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession

    let allocations: [AllocationSliceItem]
    let totalAssets: Int
    let currency: String

    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("资产配置结构")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                }
                Spacer()
                Text("\(allocations.count) 个类别")
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            if allocations.isEmpty || totalAssets == 0 {
                AnalysisEmptyRow(message: "所选范围暂无资产数据")
            } else {
                // Donut Chart
                Chart(allocations) { slice in
                    SectorMark(
                        angle: .value("金额", slice.amount),
                        innerRadius: .ratio(0.64),
                        outerRadius: .ratio(selectedID == slice.id ? 1.0 : 0.92),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
                    .opacity(selectedID == nil || selectedID == slice.id ? 1.0 : 0.42)
                }
                .chartLegend(.hidden)
                .frame(height: 180)
                .overlay {
                    VStack(spacing: 3) {
                        Text("资产总额")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)

                        AmountLabel(
                            minorUnits: totalAssets,
                            currency: currency,
                            font: .system(size: 18, weight: .bold, design: .rounded),
                            color: LedgerPalette.ink
                        )
                        .lineLimit(1)

                        Text("\(allocations.count) 大类配置")
                            .font(.system(size: 10))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }

                // Slices Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(allocations) { slice in
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if selectedID == slice.id {
                                    selectedID = nil
                                } else {
                                    selectedID = slice.id
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 8, height: 8)
                                Text(slice.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%%", slice.percentage * 100))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                selectedID == slice.id ? slice.color.opacity(0.12) : Color(uiColor: .tertiarySystemFill).opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

private struct AssetAccountsRankingCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession

    let accounts: [AssetAccountItem]
    let totalAssets: Int
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("核心资产账户")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                }
                Spacer()
                Text("\(accounts.count) 个账户")
                    .font(.system(size: 12))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            if accounts.isEmpty {
                AnalysisEmptyRow(message: "所选范围暂无资产账户")
            } else {
                VStack(spacing: 8) {
                    ForEach(accounts.prefix(8)) { item in
                        let visual = assetVisual(for: item.account, label: item.label)
                        Button {
                            LedgerFeedback.selection()
                            session.navigateToTransactions(account: item.account)
                        } label: {
                            HStack(spacing: 12) {
                                // Icon badge
                                Image(systemName: visual.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(visual.color)
                                    .frame(width: 32, height: 32)
                                    .background(visual.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                // Name & Progress
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.label)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        AmountLabel(
                                            minorUnits: item.amount,
                                            currency: currency,
                                            font: .system(size: 13, weight: .bold, design: .rounded),
                                            color: LedgerPalette.ink
                                        )
                                    }

                                    // Sub-row: progress bar & ratio
                                    HStack(spacing: 8) {
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule()
                                                    .fill(Color(uiColor: .tertiarySystemFill))
                                                Capsule()
                                                    .fill(visual.color)
                                                    .frame(width: max(geo.size.width * CGFloat(item.ratio), 4))
                                            }
                                        }
                                        .frame(height: 4)

                                        Text(String(format: "%.1f%%", item.ratio * 100))
                                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                                            .foregroundStyle(LedgerPalette.secondary)
                                            .frame(width: 38, alignment: .trailing)

                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.secondary.opacity(0.5))
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

private struct LiabilitiesBreakdownCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession

    let accounts: [LiabilityAccountItem]
    let totalLiabilities: Int
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.expense)
                    Text("负债结构与账户")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                }
                Spacer()
                if !accounts.isEmpty {
                    Text("\(accounts.count) 个负债账户")
                        .font(.system(size: 12))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }

            if accounts.isEmpty || totalLiabilities == 0 {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color(red: 0.12, green: 0.68, blue: 0.36))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前无负债")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Text("财务状况十分健康，无信用卡或借款待还")
                            .font(.system(size: 12))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(red: 0.12, green: 0.68, blue: 0.36).opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(accounts) { item in
                        let visual = assetVisual(for: item.account, label: item.label)
                        Button {
                            LedgerFeedback.selection()
                            session.navigateToTransactions(account: item.account)
                        } label: {
                            HStack(spacing: 12) {
                                // Icon badge
                                Image(systemName: visual.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(LedgerPalette.expense)
                                    .frame(width: 32, height: 32)
                                    .background(LedgerPalette.expense.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                                // Label & details
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.ink)
                                        .lineLimit(1)
                                    Text(item.account)
                                        .font(.system(size: 10))
                                        .foregroundStyle(LedgerPalette.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 3) {
                                    AmountLabel(
                                        minorUnits: item.amount,
                                        currency: currency,
                                        font: .system(size: 13, weight: .bold, design: .rounded),
                                        color: LedgerPalette.expense
                                    )
                                    Text(String(format: "占负债 %.1f%%", item.ratio * 100))
                                        .font(.system(size: 10))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary.opacity(0.5))
                            }
                            .padding(10)
                            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

private enum AssetTrendMode: String, CaseIterable, Identifiable {
    case daily
    case monthEnd

    var id: String { rawValue }
    var title: String { self == .daily ? "每日" : "月末" }
}

private struct IncomeExpenseAnalysisContent: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerIncomeExpenseAnalysis

    @State private var eventTagListPresented = false
    @State private var selectedEventTag: String?

    private var dashboard: LedgerDashboard { data.dashboard }
    private var statement: LedgerIncomeStatement { data.statement }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(
                metrics: [
                    AnalysisMetric("收入", amount: statement.totalIncome, color: LedgerPalette.income),
                    AnalysisMetric("支出", amount: statement.totalExpense, color: LedgerPalette.expense),
                    AnalysisMetric("期间结余", amount: statement.netIncome, color: statement.netIncome >= 0 ? LedgerPalette.gold : LedgerPalette.expense),
                ],
                currency: statement.valuationCurrency,
                onSelect: { idx in
                    switch idx {
                    case 0: session.navigateToTransactions(kind: .income)
                    case 1: session.navigateToTransactions(kind: .expense)
                    default: session.navigateToTransactions(kind: .all)
                    }
                }
            )

            AnalysisChartPanel(title: "现金流", detail: "按月比较收入、支出与结余") {
                if dashboard.cashflowSeries.isEmpty {
                    AnalysisEmptyContent(icon: "chart.xyaxis.line", message: "所选范围暂无现金流趋势")
                } else {
                    CashflowTrendChart(
                        points: dashboard.cashflowSeries,
                        currency: dashboard.currency,
                        referenceLabel: dashboard.start
                    )
                }
            }

            CookieCategoryDonutCard(
                statement: statement,
                currency: statement.valuationCurrency
            )

            CookieRankedCategoryPanel(
                title: "支出分类排行",
                items: statement.expenseAnalytics,
                totalExpense: statement.totalExpense,
                currency: statement.valuationCurrency
            )

            // Event & Tag Project Accounting Card
            let allSummaries = EventTagCalculator.summarizeAllTags(
                from: session.visibleTransactions,
                accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
            )
            if !allSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(LedgerPalette.cobalt)
                            Text("事件与项目独立核算")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                        }
                        Spacer()
                        Button("全部 \(allSummaries.count) 个 →") {
                            eventTagListPresented = true
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LedgerPalette.cobalt)
                    }

                    VStack(spacing: 8) {
                        ForEach(Array(allSummaries.prefix(3))) { summary in
                            Button {
                                selectedEventTag = summary.tag
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("#" + summary.tag)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(LedgerPalette.ink)
                                        if let start = summary.startDate, let end = summary.endDate {
                                            Text(start == end ? start : "\(start) ~ \(end)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(LedgerPalette.secondary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(MoneyText.format(minorUnits: summary.netSpend, currency: summary.currency))
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundStyle(LedgerPalette.expense)
                                        Text("\(summary.transactionCount) 笔")
                                            .font(.system(size: 11))
                                            .foregroundStyle(LedgerPalette.secondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.secondary)
                                        .padding(.leading, 4)
                                }
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
                        }
                    }
                }
                .padding(16)
                .background(LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
                )
            }

            IncomeExpenseHighlights(statement: statement)

            IncomeNodePanel(title: "收入账户", nodes: flattened(statement.income), currency: statement.valuationCurrency, color: LedgerPalette.income)
            IncomeNodePanel(title: "支出账户", nodes: flattened(statement.expense), currency: statement.valuationCurrency, color: LedgerPalette.expense)

            if !dashboard.anomalies.isEmpty {
                AnalysisListPanel(title: "需要留意", detail: "按金额与历史模式识别") {
                    ForEach(Array(dashboard.anomalies.prefix(4).enumerated()), id: \.offset) { _, anomaly in
                        Button {
                            LedgerFeedback.selection()
                            session.navigateToTransactions(account: anomaly.account)
                        } label: {
                            AnalysisAmountRow(
                                title: anomaly.payee.isEmpty ? anomaly.narration : anomaly.payee,
                                detail: "\(anomaly.date) · \(anomaly.account.split(separator: ":").last.map(String.init) ?? anomaly.account)",
                                amount: anomaly.amount,
                                currency: dashboard.currency,
                                color: LedgerPalette.expense
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $eventTagListPresented) {
            EventTagListView()
                .ledgerPrivacyProtectedSheet()
        }
        .sheet(isPresented: Binding(
            get: { selectedEventTag != nil },
            set: { if !$0 { selectedEventTag = nil } }
        )) {
            if let tag = selectedEventTag {
                NavigationStack {
                    EventTagReportView(tag: tag)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { selectedEventTag = nil }
                            }
                        }
                }
                .ledgerPrivacyProtectedSheet()
            }
        }
    }

    private func flattened(_ nodes: [LedgerIncomeNode]) -> [LedgerIncomeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }
}

private struct IncomeExpenseHighlights: View {
    @EnvironmentObject private var session: LedgerSession
    let statement: LedgerIncomeStatement

    private var unknown: LedgerExpenseCategoryAnalytics? {
        statement.expenseAnalytics.first { $0.account == "Expenses:Unknown" }
    }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            RankedAmountPanel(
                title: "热门商户",
                rows: statement.topPayees.prefix(5).map { ($0.payee, $0.amount, $0.txCount) },
                currency: statement.valuationCurrency,
                color: LedgerPalette.expense,
                onSelect: { idx in
                    let payees = Array(statement.topPayees.prefix(5))
                    if idx < payees.count {
                        session.navigateToTransactions(query: payees[idx].payee)
                    }
                }
            )
            RankedAmountPanel(
                title: "支付账户",
                rows: statement.topPaymentAccounts.prefix(5).map { ($0.label, $0.amount, $0.txCount) },
                currency: statement.valuationCurrency,
                color: LedgerPalette.cobalt,
                onSelect: { idx in
                    let accounts = Array(statement.topPaymentAccounts.prefix(5))
                    if idx < accounts.count {
                        session.navigateToTransactions(account: accounts[idx].account)
                    }
                }
            )
            AnalysisListPanel(title: "待整理项目", detail: "Expenses:Unknown") {
                if let unknown {
                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(account: "Expenses:Unknown")
                    } label: {
                        AnalysisAmountRow(
                            title: unknown.label,
                            detail: "\(unknown.txCount) 笔 · 占支出 \(percent(unknown.share))",
                            amount: unknown.amount,
                            currency: statement.valuationCurrency,
                            color: LedgerPalette.expense
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    AnalysisEmptyRow(message: "当前期间没有待整理支出")
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }
}

private struct CashflowTrendChart: View {
    let points: [LedgerCashflowPoint]
    let currency: String
    let referenceLabel: String

    @State private var selectedIndex: Int?

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.month), referenceLabel: referenceLabel)
    }

    private var selectedPoint: LedgerCashflowPoint? {
        selectedIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.md) {
            ZStack(alignment: .topTrailing) {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        let x = axis.position(at: index)
                        LineMark(
                            x: .value("月份", x),
                            y: .value("收入", point.income),
                            series: .value("系列", "收入")
                        )
                        .foregroundStyle(LedgerPalette.income)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("月份", x),
                            y: .value("支出", point.expense),
                            series: .value("系列", "支出")
                        )
                        .foregroundStyle(LedgerPalette.expense)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }

                    if let selectedIndex, points.indices.contains(selectedIndex) {
                        let point = points[selectedIndex]
                        let x = axis.position(at: selectedIndex)
                        RuleMark(x: .value("选中日期", x))
                            .foregroundStyle(LedgerPalette.lineStrong)
                        PointMark(x: .value("选中收入", x), y: .value("收入", point.income))
                            .foregroundStyle(LedgerPalette.income)
                            .symbolSize(44)
                        PointMark(x: .value("选中支出", x), y: .value("支出", point.expense))
                            .foregroundStyle(LedgerPalette.expense)
                            .symbolSize(44)
                    }
                }
                .chartXScale(domain: axis.domain)
                .chartXAxis { xAxisMarks(axis) }
                .chartYAxis(.hidden)
                .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
                .accessibilityLabel("现金流趋势图，可点按或拖动查看数据")
                .accessibilityValue(axis.usesTimeScale ? "真实时间轴" : "有序分类轴")
                .accessibilityIdentifier("cashflow-trend-chart")

                if let selectedPoint {
                    CashflowSelectionLabel(point: selectedPoint, currency: currency)
                }
            }
            .frame(height: 190)

            AnalysisChartLegend(items: [
                ("收入", LedgerPalette.income),
                ("支出", LedgerPalette.expense),
            ])
        }
    }

    @AxisContentBuilder
    private func xAxisMarks(_ axis: LedgerChartAxis) -> some AxisContent {
        AxisMarks(position: .bottom, values: axis.tickPositions(maxCount: 5)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                .foregroundStyle(LedgerPalette.line)
            AxisTick().foregroundStyle(LedgerPalette.lineStrong)
            AxisValueLabel(collisionResolution: .disabled) {
                if let position = value.as(Double.self) {
                    Text(axis.shortLabel(nearestTo: position))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
        }
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

private struct CashflowSelectionLabel: View {
    let point: LedgerCashflowPoint
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(point.month)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(LedgerPalette.secondary)
            HStack(spacing: 4) {
                Circle().fill(LedgerPalette.income).frame(width: 6, height: 6)
                AmountLabel(minorUnits: point.income, currency: currency, font: .system(size: 10, weight: .semibold), color: LedgerPalette.ink)
            }
            HStack(spacing: 4) {
                Circle().fill(LedgerPalette.expense).frame(width: 6, height: 6)
                AmountLabel(minorUnits: point.expense, currency: currency, font: .system(size: 10, weight: .semibold), color: LedgerPalette.ink)
            }
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
        .accessibilityIdentifier("cashflow-chart-selection")
    }
}

private struct NetWorthTrendChart: View {
    let points: [LedgerNetWorthPoint]
    let currency: String
    let referenceLabel: String

    @State private var selectedIndex: Int?

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.date), referenceLabel: referenceLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.md) {
            ZStack(alignment: .topTrailing) {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                        let x = axis.position(at: index)
                        AreaMark(x: .value("日期", x), y: .value("净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt.opacity(0.12))
                        LineMark(x: .value("日期", x), y: .value("净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("日期", x),
                            y: .value("资产", point.assets),
                            series: .value("系列", "资产")
                        )
                        .foregroundStyle(LedgerPalette.ink)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("日期", x),
                            y: .value("负债", point.liabilities),
                            series: .value("系列", "负债")
                        )
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                    }

                    if let selectedIndex, points.indices.contains(selectedIndex) {
                        let point = points[selectedIndex]
                        let x = axis.position(at: selectedIndex)
                        RuleMark(x: .value("选中日期", x))
                            .foregroundStyle(LedgerPalette.lineStrong)
                        PointMark(x: .value("选中日期", x), y: .value("选中净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .symbolSize(48)
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
                                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
                .accessibilityLabel("净资产走势图，可点按或拖动查看数据")
                .accessibilityValue(axis.usesTimeScale ? "真实时间轴" : "有序分类轴")
                .accessibilityIdentifier("net-worth-trend-chart")

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let point = points[selectedIndex]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.date)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(minorUnits: point.netWorth, currency: currency, prefix: "净值 ", font: .system(size: 10, weight: .semibold), color: LedgerPalette.cobalt)
                        AmountLabel(minorUnits: point.assets, currency: currency, prefix: "资产 ", font: .system(size: 9, weight: .medium), color: LedgerPalette.ink)
                        AmountLabel(minorUnits: point.liabilities, currency: currency, prefix: "负债 ", font: .system(size: 9, weight: .medium), color: LedgerPalette.secondary)
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
                    .accessibilityIdentifier("net-worth-chart-selection")
                }
            }
            .frame(height: 190)

            AnalysisChartLegend(items: [
                ("净资产", LedgerPalette.cobalt),
                ("资产", LedgerPalette.ink),
                ("负债", LedgerPalette.secondary),
            ])
        }
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

private struct InvestmentsAnalysisContent: View {
    let data: LedgerInvestmentSummary

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("持仓市值", amount: data.totalMarketValueCny, color: LedgerPalette.gold),
                AnalysisMetric(
                    "已实现收益",
                    amount: data.realizedPnlCny,
                    placeholder: "暂无记录",
                    color: (data.realizedPnlCny ?? 0) >= 0 ? LedgerPalette.income : LedgerPalette.expense
                ),
            ], currency: "CNY")

            AnalysisListPanel(title: "当前持仓", detail: "\(data.holdings.count) 个品种") {
                if data.holdings.isEmpty {
                    AnalysisEmptyRow(message: "暂无投资持仓")
                } else {
                    ForEach(data.holdings) { holding in
                        InvestmentHoldingRow(
                            holding: holding,
                            quantityText: quantityText(holding.totalQuantity)
                        )
                    }
                }
            }
        }
    }

    private func quantityText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

private struct AnalysisMetric {
    let title: String
    let amount: Int?
    let placeholder: String
    let color: Color

    init(_ title: String, amount: Int?, placeholder: String = "暂无数据", color: Color) {
        self.title = title
        self.amount = amount
        self.placeholder = placeholder
        self.color = color
    }
}

private struct AnalysisMetricGrid: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let metrics: [AnalysisMetric]
    let currency: String
    var onSelect: ((Int) -> Void)? = nil

    private let compactColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
    ]

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 1) {
                    ForEach(metrics.indices, id: \.self) { index in
                        AnalysisMetricCell(metric: metrics[index], currency: currency) {
                            onSelect?(index)
                        }
                    }
                }
            } else if metrics.count == 3 {
                VStack(spacing: 1) {
                    AnalysisMetricCell(metric: metrics[0], currency: currency) {
                        onSelect?(0)
                    }
                    LazyVGrid(columns: compactColumns, spacing: 1) {
                        ForEach(1 ..< metrics.count, id: \.self) { index in
                            AnalysisMetricCell(metric: metrics[index], currency: currency) {
                                onSelect?(index)
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: compactColumns, spacing: 1) {
                    ForEach(metrics.indices, id: \.self) { index in
                        AnalysisMetricCell(metric: metrics[index], currency: currency) {
                            onSelect?(index)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
    }
}

private struct AnalysisMetricCell: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let metric: AnalysisMetric
    let currency: String
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            if let onTap {
                LedgerFeedback.selection()
                onTap()
            }
        } label: {
            VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
                HStack {
                    Text(metric.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    if onTap != nil {
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary.opacity(0.6))
                    }
                }
                if let amount = metric.amount {
                    AmountLabel(
                        minorUnits: amount,
                        currency: currency,
                        font: .system(size: 20, weight: .semibold),
                        color: metric.color,
                        displayMode: horizontalSizeClass == .regular ? .adaptive : .compact
                    )
                    .tracking(-0.4)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(metric.placeholder)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
            }
            .padding(LedgerSpacing.lg)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .background(LedgerPalette.panel)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: onTap == nil ? 1.0 : 0.98))
        .disabled(onTap == nil)
        .accessibilityIdentifier("analysis-metric-\(metric.title)")
    }
}

private struct AnalysisChartPanel<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            SectionHeading(title: title, detail: detail)
            content
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
    }
}

private struct AnalysisListPanel<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeading(title: title, detail: detail)
                .padding(LedgerSpacing.lg)
            Divider().overlay(LedgerPalette.line)
            VStack(spacing: 0) { content }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
    }
}

private struct AnalysisAmountRow: View {
    let title: String
    let detail: String
    let amount: Int
    let currency: String
    let color: Color

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LedgerPalette.ink).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(LedgerPalette.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AmountLabel(minorUnits: amount, currency: currency, font: .system(size: 13, weight: .semibold), color: color)
                .lineLimit(1)
        }
        .padding(LedgerSpacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg) }
    }
}

private struct InvestmentHoldingRow: View {
    let holding: LedgerInvestmentHolding
    let quantityText: String

    private var performanceColor: Color {
        guard let market = holding.totalMarketValueCny,
              let cost = holding.totalCostValueCny else {
            return LedgerPalette.gold
        }
        return market - cost >= 0 ? LedgerPalette.income : LedgerPalette.expense
    }

    private var secondaryAmount: (prefix: String, amount: Int, showSign: Bool)? {
        switch (holding.totalMarketValueCny, holding.totalCostValueCny) {
        case let (market?, cost?):
            return ("浮动 ", market - cost, true)
        case (nil, let cost?):
            return ("成本 ", cost, false)
        case (_, nil):
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(holding.commodityName.isEmpty ? holding.commodity : holding.commodityName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(2)
                Text("\(holding.commodity) · \(quantityText) · \(holding.accountCount) 个账户")
                    .font(.system(size: 10))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                if let market = holding.totalMarketValueCny {
                    AmountLabel(
                        minorUnits: market,
                        currency: "CNY",
                        font: .system(size: 13, weight: .semibold),
                        color: performanceColor
                    )
                    .lineLimit(1)
                } else {
                    Text("暂无估值")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                }

                if let secondaryAmount {
                    AmountLabel(
                        minorUnits: secondaryAmount.amount,
                        currency: "CNY",
                        prefix: secondaryAmount.prefix,
                        font: .system(size: 9, weight: .medium),
                        color: LedgerPalette.secondary,
                        showSign: secondaryAmount.showSign
                    )
                        .lineLimit(1)
                } else if holding.totalCostValueCny == nil {
                    Text("成本缺失")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
        }
        .padding(LedgerSpacing.lg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg)
        }
    }
}

private struct AnalysisChartLegend: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: LedgerSpacing.lg) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 6) {
                    Circle().fill(item.1).frame(width: 7, height: 7)
                    Text(item.0)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AnalysisEmptyContent: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: LedgerSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(LedgerPalette.canvas)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous))
    }
}

private struct AnalysisEmptyRow: View {
    let message: String

    var body: some View {
        HStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
            Spacer(minLength: 0)
        }
        .padding(LedgerSpacing.lg)
    }
}

private struct RankedAmountPanel: View {
    let title: String
    let rows: [(String, Int, Int)]
    let currency: String
    let color: Color
    var onSelect: ((Int) -> Void)? = nil

    private var maximum: Double { Double(max(rows.map(\.1).max() ?? 1, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            SectionHeading(title: title, detail: "前 \(rows.count) 项")
            if rows.isEmpty {
                AnalysisEmptyRow(message: "所选范围暂无支出分类")
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    Button {
                        LedgerFeedback.selection()
                        onSelect?(idx)
                    } label: {
                        VStack(spacing: 6) {
                            HStack {
                                Text(row.0).font(.system(size: 12, weight: .medium)).foregroundStyle(LedgerPalette.ink).lineLimit(1)
                                Spacer()
                                AmountLabel(minorUnits: row.1, currency: currency, font: .system(size: 11, weight: .semibold), color: color)
                                if onSelect != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(LedgerPalette.secondary.opacity(0.4))
                                }
                            }
                            ProgressView(value: Double(row.1), total: maximum).tint(color)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onSelect == nil)
                }
            }
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
    }
}

private struct IncomeNodePanel: View {
    @EnvironmentObject private var session: LedgerSession

    let title: String
    let nodes: [LedgerIncomeNode]
    let currency: String
    let color: Color

    var body: some View {
        AnalysisListPanel(title: title, detail: "\(nodes.filter { $0.children.isEmpty }.count) 个分类") {
            if nodes.isEmpty {
                AnalysisEmptyRow(message: "所选范围暂无\(title)")
            } else {
                ForEach(nodes) { node in
                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(account: node.account)
                    } label: {
                        HStack(alignment: .top, spacing: LedgerSpacing.md) {
                            Text(node.label)
                                .font(.system(size: node.depth == 0 ? 13 : 12, weight: node.depth == 0 ? .semibold : .regular))
                                .foregroundStyle(node.depth == 0 ? LedgerPalette.ink : LedgerPalette.olive)
                                .padding(.leading, min(CGFloat(node.depth), 3) * LedgerSpacing.md)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            AmountLabel(minorUnits: node.amount, currency: currency, font: .system(size: 12, weight: .semibold), color: color)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary.opacity(0.4))
                        }
                        .padding(LedgerSpacing.lg)
                        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CookieCategoryDonutCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession

    let statement: LedgerIncomeStatement
    let currency: String

    enum AnalysisTab: String, CaseIterable, Identifiable {
        case expense = "支出"
        case income = "收入"
        var id: String { rawValue }
    }

    @State private var selectedTab: AnalysisTab = .expense
    @State private var selectedSliceID: String?

    private struct SliceItem: Identifiable {
        let id: String
        let label: String
        let icon: String
        let color: Color
        let amount: Int
        let percentage: Double
    }

    private var activeTotal: Int {
        selectedTab == .expense ? statement.totalExpense : statement.totalIncome
    }

    private var slices: [SliceItem] {
        let total = activeTotal
        guard total > 0 else { return [] }

        if selectedTab == .expense {
            let top = statement.expenseAnalytics.filter { $0.amount > 0 }.prefix(5)
            var items: [SliceItem] = []
            var topSum = 0

            for item in top {
                let visual = TransactionVisualCategory.resolve(account: item.account, label: item.label)
                let pct = Double(item.amount) / Double(total)
                topSum += item.amount
                items.append(SliceItem(
                    id: item.account,
                    label: visual.categoryLabel,
                    icon: visual.iconName,
                    color: visual.color,
                    amount: item.amount,
                    percentage: pct
                ))
            }

            let remainder = total - topSum
            if remainder > 0 {
                items.append(SliceItem(
                    id: "other_expense",
                    label: "其他",
                    icon: "ellipsis.circle",
                    color: Color(red: 0.68, green: 0.70, blue: 0.74),
                    amount: remainder,
                    percentage: Double(remainder) / Double(total)
                ))
            }
            return items
        } else {
            let top = statement.income.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }.prefix(5)
            var items: [SliceItem] = []
            var topSum = 0

            for node in top {
                let visual = TransactionVisualCategory.resolve(account: node.account, label: node.label)
                let pct = Double(node.amount) / Double(total)
                topSum += node.amount
                items.append(SliceItem(
                    id: node.account,
                    label: visual.categoryLabel,
                    icon: visual.iconName,
                    color: visual.color,
                    amount: node.amount,
                    percentage: pct
                ))
            }

            let remainder = total - topSum
            if remainder > 0 {
                items.append(SliceItem(
                    id: "other_income",
                    label: "其他",
                    icon: "ellipsis.circle",
                    color: Color(red: 0.68, green: 0.70, blue: 0.74),
                    amount: remainder,
                    percentage: Double(remainder) / Double(total)
                ))
            }
            return items
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            // Header with Switcher
            HStack {
                HStack(spacing: 4) {
                    ForEach(AnalysisTab.allCases) { tab in
                        let isSelected = selectedTab == tab
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                selectedTab = tab
                                selectedSliceID = nil
                            }
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected
                                        ? (tab == .expense ? LedgerPalette.expense : LedgerPalette.income)
                                        : Color(uiColor: .tertiarySystemFill),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                    }
                }

                Spacer()

                Text(session.selectedRange.displayTitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            if slices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 28))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("当前期间暂无\(selectedTab.rawValue)记录")
                        .font(.system(size: 13))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                // Donut Chart
                Chart(slices) { slice in
                    SectorMark(
                        angle: .value("金额", slice.amount),
                        innerRadius: .ratio(0.64),
                        outerRadius: .ratio(selectedSliceID == slice.id ? 1.0 : 0.92),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
                    .opacity(selectedSliceID == nil || selectedSliceID == slice.id ? 1.0 : 0.42)
                }
                .chartLegend(.hidden)
                .frame(height: 180)
                .overlay {
                    VStack(spacing: 3) {
                        Text(selectedTab == .expense ? "总支出" : "总收入")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)

                        AmountLabel(
                            minorUnits: activeTotal,
                            currency: currency,
                            font: .system(size: 18, weight: .bold, design: .rounded),
                            color: LedgerPalette.ink
                        )
                        .lineLimit(1)

                        Text("\(slices.count) 项占比")
                            .font(.system(size: 10))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }

                // Slices Legend Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(slices) { slice in
                        Button {
                            LedgerFeedback.selection()
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if selectedSliceID == slice.id {
                                    selectedSliceID = nil
                                } else {
                                    selectedSliceID = slice.id
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(slice.color)
                                    .frame(width: 8, height: 8)
                                Text(slice.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%%", slice.percentage * 100))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                selectedSliceID == slice.id ? slice.color.opacity(0.12) : Color(uiColor: .tertiarySystemFill).opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)

                if let slice = slices.first(where: { $0.id == selectedSliceID }), !slice.id.hasPrefix("other_") {
                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(kind: selectedTab == .expense ? .expense : .income, account: slice.id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("查看「\(slice.label)」流水")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(slice.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(slice.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

struct CookieRankedCategoryPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession

    let title: String
    let items: [LedgerExpenseCategoryAnalytics]
    let totalExpense: Int
    let currency: String

    private var positiveItems: [LedgerExpenseCategoryAnalytics] {
        items.filter { $0.amount > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                Spacer()
                Text("前 \(min(positiveItems.count, 8)) 项 · 点击查看流水")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            if positiveItems.isEmpty {
                AnalysisEmptyRow(message: "所选范围暂无支出分类")
            } else {
                ForEach(Array(positiveItems.prefix(8).enumerated()), id: \.element.id) { index, item in
                    let visual = TransactionVisualCategory.resolve(account: item.account, label: item.label)
                    let pct = totalExpense > 0 ? (Double(item.amount) / Double(totalExpense)) : 0.0

                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(kind: .expense, account: item.account)
                    } label: {
                        VStack(spacing: 8) {
                            HStack(spacing: 10) {
                                // Rank number badge
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(rankBadgeBackground(index))
                                        .frame(width: 20, height: 20)
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(rankTextColor(index))
                                }

                                // Squircle icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(visual.color.opacity(0.14))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: visual.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(visual.color)
                                }

                                // Category info
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(visual.categoryLabel)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(LedgerPalette.ink)
                                        .lineLimit(1)
                                    Text("\(item.txCount) 笔")
                                        .font(.system(size: 11))
                                        .foregroundStyle(LedgerPalette.secondary)
                                }

                                Spacer()

                                // Amount & Percentage
                                VStack(alignment: .trailing, spacing: 2) {
                                    AmountLabel(
                                        minorUnits: item.amount,
                                        currency: currency,
                                        font: .system(size: 14.5, weight: .semibold, design: .rounded),
                                        color: LedgerPalette.ink
                                    )
                                    Text(String(format: "%.1f%%", pct * 100))
                                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                        .foregroundStyle(LedgerPalette.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary.opacity(0.5))
                            }

                            // Proportional progress track
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(uiColor: .tertiarySystemFill))
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(visual.color)
                                        .frame(
                                            width: max(4, min(geo.size.width, geo.size.width * CGFloat(pct))),
                                            height: 4
                                        )
                                }
                            }
                            .frame(height: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))

                    if index < min(items.count - 1, 7) {
                        Divider()
                            .overlay(LedgerPalette.line.opacity(0.4))
                            .padding(.top, 2)
                    }
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.04),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }

    private func rankBadgeBackground(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.98, green: 0.82, blue: 0.25).opacity(0.2)
        case 1: return Color(red: 0.70, green: 0.75, blue: 0.82).opacity(0.2)
        case 2: return Color(red: 0.82, green: 0.58, blue: 0.40).opacity(0.2)
        default: return Color(uiColor: .tertiarySystemFill)
        }
    }

    private func rankTextColor(_ index: Int) -> Color {
        switch index {
        case 0: return Color(red: 0.85, green: 0.55, blue: 0.05)
        case 1: return Color(red: 0.45, green: 0.50, blue: 0.58)
        case 2: return Color(red: 0.72, green: 0.45, blue: 0.25)
        default: return LedgerPalette.secondary
        }
    }
}
