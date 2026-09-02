import Charts
import SwiftUI

enum LedgerAnalysisKind: String, CaseIterable, Hashable {
    case assets
    case incomeExpense
    case investments

    var title: String {
        switch self {
        case .assets: "资产"
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
    var showsAppBar = false

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
            if showsAppBar {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }
            }

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
        .navigationTitle(showsAppBar ? "" : kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsAppBar ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                    analysisHeader

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
                .padding(.top, horizontalSizeClass == .regular ? LedgerSpacing.xl : LedgerSpacing.lg)
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

    @ViewBuilder
    private var analysisHeader: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .bottom, spacing: LedgerSpacing.xl) {
                analysisIntro
                LedgerTimeRangeControl()
                    .frame(width: 420)
            }
        } else {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                analysisIntro
                LedgerTimeRangeControl()
            }
        }
    }

    @ViewBuilder
    private var analysisIntro: some View {
        if showsAppBar {
            LedgerPageIntro(
                title: kind.title,
                detail: kind.detail,
                meta: session.selectedRange.metricScope,
                style: .inline
            ) { EmptyView() }
        } else {
            LedgerPageContext(
                detail: kind.detail,
                meta: session.selectedRange.metricScope
            )
        }
    }

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

    private var assetAccounts: [(String, Int)] {
        let accounts = Dictionary(uniqueKeysWithValues: data.accounts.map { ($0.account, $0) })
        return valuations
            .filter { $0.key.hasPrefix("Assets:") && $0.value > 0 }
            .map { account, value in
                (accounts[account]?.displayLabel ?? account.split(separator: ":").last.map(String.init) ?? account, value)
            }
            .sorted { $0.1 > $1.1 }
    }

    private var allocation: [(String, Int)] {
        let known = Set(data.accounts.map(\.account))
        var totals = ["现金与存款": 0, "理财与投资": 0, "应收": 0, "其他资产": 0]
        for account in data.accounts where account.account.hasPrefix("Assets:") {
            let amount = valuations[account.account] ?? 0
            switch account.group {
            case "cash": totals["现金与存款", default: 0] += amount
            case "wealth": totals["理财与投资", default: 0] += amount
            case "receivable": totals["应收", default: 0] += amount
            default: totals["其他资产", default: 0] += amount
            }
        }
        totals["其他资产", default: 0] += valuations
            .filter { $0.key.hasPrefix("Assets:") && !known.contains($0.key) }
            .values.reduce(0, +)
        return ["现金与存款", "理财与投资", "应收", "其他资产"]
            .compactMap { label in
                guard let value = totals[label], value != 0 else { return nil }
                return (label, value)
            }
    }

    private var trendPoints: [LedgerNetWorthPoint] {
        trendMode == .monthEnd && data.monthEndNetWorth.count > 1
            ? data.monthEndNetWorth
            : data.netWorthHistory
    }

    private var concentration: Double? {
        guard assets > 0 else { return nil }
        return Double(assetAccounts.prefix(3).reduce(0) { $0 + $1.1 }) / Double(assets)
    }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("总资产", amount: assets, color: LedgerPalette.income),
                AnalysisMetric("总负债", amount: liabilities, color: LedgerPalette.expense),
                AnalysisMetric("净资产", amount: netWorth, color: netWorth >= 0 ? LedgerPalette.gold : LedgerPalette.expense),
            ], currency: data.valuationCurrency)

            AssetWindowPanel(
                debtRatio: assets > 0 ? Double(liabilities) / Double(assets) : nil,
                concentration: concentration,
                windows: data.netWorthWindows,
                currency: data.valuationCurrency
            )

            RankedAmountPanel(
                title: "资产用途结构",
                rows: allocation.map { ($0.0, $0.1, 0) },
                currency: data.valuationCurrency,
                color: LedgerPalette.cobalt
            )

            RankedAmountPanel(
                title: "资产账户集中度",
                rows: assetAccounts.prefix(8).map { ($0.0, $0.1, 0) },
                currency: data.valuationCurrency,
                color: LedgerPalette.gold
            )

            AnalysisChartPanel(title: "净值趋势", detail: "资产、负债与净资产的长期位置") {
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

private enum AssetTrendMode: String, CaseIterable, Identifiable {
    case daily
    case monthEnd

    var id: String { rawValue }
    var title: String { self == .daily ? "每日" : "月末" }
}

private struct IncomeExpenseAnalysisContent: View {
    let data: LedgerIncomeExpenseAnalysis

    private var dashboard: LedgerDashboard { data.dashboard }
    private var statement: LedgerIncomeStatement { data.statement }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("收入", amount: statement.totalIncome, color: LedgerPalette.income),
                AnalysisMetric("支出", amount: statement.totalExpense, color: LedgerPalette.expense),
                AnalysisMetric("期间结余", amount: statement.netIncome, color: statement.netIncome >= 0 ? LedgerPalette.gold : LedgerPalette.expense),
            ], currency: statement.valuationCurrency)

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

            RankedAmountPanel(
                title: "支出分类",
                rows: statement.expenseAnalytics.prefix(6).map { ($0.label, $0.amount, $0.txCount) },
                currency: statement.valuationCurrency,
                color: LedgerPalette.expense
            )

            IncomeExpenseHighlights(statement: statement)

            IncomeNodePanel(title: "收入账户", nodes: flattened(statement.income), currency: statement.valuationCurrency, color: LedgerPalette.income)
            IncomeNodePanel(title: "支出账户", nodes: flattened(statement.expense), currency: statement.valuationCurrency, color: LedgerPalette.expense)

            if !dashboard.anomalies.isEmpty {
                AnalysisListPanel(title: "需要留意", detail: "按金额与历史模式识别") {
                    ForEach(Array(dashboard.anomalies.prefix(4).enumerated()), id: \.offset) { _, anomaly in
                        AnalysisAmountRow(
                            title: anomaly.payee.isEmpty ? anomaly.narration : anomaly.payee,
                            detail: "\(anomaly.date) · \(anomaly.account.split(separator: ":").last.map(String.init) ?? anomaly.account)",
                            amount: anomaly.amount,
                            currency: dashboard.currency,
                            color: LedgerPalette.expense
                        )
                    }
                }
            }
        }
    }

    private func flattened(_ nodes: [LedgerIncomeNode]) -> [LedgerIncomeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
    }
}

private struct AssetWindowPanel: View {
    let debtRatio: Double?
    let concentration: Double?
    let windows: LedgerNetWorthWindows?
    let currency: String

    var body: some View {
        AnalysisListPanel(title: "资产位置", detail: "结构、变化与集中度") {
            AssetWindowRow(title: "负债率", value: percent(debtRatio), detail: "总负债 / 总资产")
            AssetWindowAmountRow(title: "期间变化", amount: windows?.monthChange, currency: currency, detail: windows?.previousMonthEnd?.date ?? "暂无月末基准")
            AssetWindowAmountRow(title: "近 6 个月", amount: windows?.sixMonth.change, currency: currency, detail: percent(windows?.sixMonth.changeRatio))
            AssetWindowAmountRow(title: "近 12 个月", amount: windows?.twelveMonth.change, currency: currency, detail: percent(windows?.twelveMonth.changeRatio))
            AssetWindowRow(title: "前三账户集中度", value: percent(concentration), detail: "前三个资产账户占总资产比例")
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "暂无数据" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }
}

private struct AssetWindowRow: View {
    @EnvironmentObject private var session: LedgerSession

    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LedgerPalette.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(LedgerPalette.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(session.amountsVisible ? value : "••••••")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(LedgerPalette.gold)
        }
        .padding(LedgerSpacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg) }
    }
}

private struct AssetWindowAmountRow: View {
    let title: String
    let amount: Int?
    let currency: String
    let detail: String

    var body: some View {
        HStack(spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(LedgerPalette.ink)
                Text(detail).font(.system(size: 10)).foregroundStyle(LedgerPalette.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let amount {
                AmountLabel(
                    minorUnits: amount,
                    currency: currency,
                    font: .system(size: 13, weight: .semibold),
                    color: amount >= 0 ? LedgerPalette.income : LedgerPalette.expense,
                    showSign: true
                )
            } else {
                Text("暂无数据")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
        .padding(LedgerSpacing.lg)
        .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg) }
    }
}

private struct IncomeExpenseHighlights: View {
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
                color: LedgerPalette.expense
            )
            RankedAmountPanel(
                title: "支付账户",
                rows: statement.topPaymentAccounts.prefix(5).map { ($0.label, $0.amount, $0.txCount) },
                currency: statement.valuationCurrency,
                color: LedgerPalette.cobalt
            )
            AnalysisListPanel(title: "待整理项目", detail: "Expenses:Unknown") {
                if let unknown {
                    AnalysisAmountRow(
                        title: unknown.label,
                        detail: "\(unknown.txCount) 笔 · 占支出 \(percent(unknown.share))",
                        amount: unknown.amount,
                        currency: statement.valuationCurrency,
                        color: LedgerPalette.expense
                    )
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

    private let compactColumns = [
        GridItem(.flexible(), spacing: 1),
        GridItem(.flexible(), spacing: 1),
    ]

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 1) {
                    ForEach(metrics.indices, id: \.self) { index in
                        AnalysisMetricCell(metric: metrics[index], currency: currency)
                    }
                }
            } else if metrics.count == 3 {
                VStack(spacing: 1) {
                    AnalysisMetricCell(metric: metrics[0], currency: currency)
                    LazyVGrid(columns: compactColumns, spacing: 1) {
                        ForEach(1 ..< metrics.count, id: \.self) { index in
                            AnalysisMetricCell(metric: metrics[index], currency: currency)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: compactColumns, spacing: 1) {
                    ForEach(metrics.indices, id: \.self) { index in
                        AnalysisMetricCell(metric: metrics[index], currency: currency)
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

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text(metric.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
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

    private var maximum: Double { Double(max(rows.map(\.1).max() ?? 1, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            SectionHeading(title: title, detail: "前 \(rows.count) 项")
            if rows.isEmpty {
                AnalysisEmptyRow(message: "所选范围暂无支出分类")
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(spacing: 6) {
                        HStack {
                            Text(row.0).font(.system(size: 12, weight: .medium)).foregroundStyle(LedgerPalette.ink).lineLimit(1)
                            Spacer()
                            AmountLabel(minorUnits: row.1, currency: currency, font: .system(size: 11, weight: .semibold), color: color)
                        }
                        ProgressView(value: Double(row.1), total: maximum).tint(color)
                    }
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
                    HStack(alignment: .top, spacing: LedgerSpacing.md) {
                        Text(node.label)
                            .font(.system(size: node.depth == 0 ? 13 : 12, weight: node.depth == 0 ? .semibold : .regular))
                            .foregroundStyle(node.depth == 0 ? LedgerPalette.ink : LedgerPalette.olive)
                            .padding(.leading, min(CGFloat(node.depth), 3) * LedgerSpacing.md)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        AmountLabel(minorUnits: node.amount, currency: currency, font: .system(size: 12, weight: .semibold), color: color)
                            .lineLimit(1)
                    }
                    .padding(LedgerSpacing.lg)
                    .overlay(alignment: .bottom) { Rectangle().fill(LedgerPalette.line).frame(height: 1).padding(.leading, LedgerSpacing.lg) }
                }
            }
        }
    }
}
