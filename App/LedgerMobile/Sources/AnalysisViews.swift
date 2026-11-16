import Charts
import SwiftUI

enum LedgerAnalysisKind: String, CaseIterable, Hashable {
    case incomeExpense
    case investments

    var title: String {
        switch self {
        case .incomeExpense: String(localized: "收支分析")
        case .investments: String(localized: "投资")
        }
    }

    var detail: String {
        switch self {
        case .incomeExpense: String(localized: "收入、支出、现金流与分类洞察")
        case .investments: String(localized: "持仓市值、成本与收益")
        }
    }

    var systemImage: String {
        switch self {
        case .incomeExpense: "chart.bar.xaxis"
        case .investments: "chart.pie"
        }
    }

    var resourceKind: LedgerAnalysisResourceKind {
        switch self {
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
    @State private var loadedKey: AnalysisRequestKey?
    // Above the cached/loaded branches, which rebuild the report on every reload.
    @State private var chartReveals = LedgerChartRevealMemory()

    private var requestKey: AnalysisRequestKey {
        AnalysisRequestKey(
            kind: kind,
            start: session.selectedRange.start,
            end: session.selectedRange.end,
            valuationCurrency: session.ledger?.valuationCurrency ?? "CNY",
            presentationID: session.analysisPresentationID,
            revision: session.localTransactionPresentationRevision,
            reloadToken: reloadToken
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let resource, loadedKey == requestKey, session.phase == .ready, !session.privacyShielded {
                    content(resource)
                } else if let cached = session.cachedAnalysisResource(kind.resourceKind) {
                    content(cached)
                } else if let errorMessage {
                    VStack(spacing: LedgerSpacing.lg) {
                        EmptyLedgerState(icon: "exclamationmark.triangle", title: String(localized: "分析数据加载失败"), detail: errorMessage)
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
            .environment(\.ledgerChartRevealMemory, chartReveals)
        }
        .background(BalancedPalette.page)
        .terminalPageChrome(kind.title, isRoot: isRoot, showsTimeRange: true, balanced: true)
        .task(id: requestKey) {
            await load(replacingContent: resource == nil)
        }
    }

    @ViewBuilder
    private func content(_ resource: LedgerAnalysisResource) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }

                switch resource {
                case let .incomeExpense(data):
                    TerminalIncomeExpenseReport(data: data)
                case let .investments(data):
                    TerminalInvestmentsReport(data: data)
                }
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : 20)
            .padding(.top, 0)
            .padding(.bottom, 24)
            .ledgerAdaptivePageWidth()
        }
        .id(kind)
        .accessibilityIdentifier("analysis-content-\(kind.rawValue)")
        .refreshable { await refresh() }
    }

    private func load(replacingContent: Bool = true) async {
        let key = requestKey
        if replacingContent { resource = nil }
        errorMessage = nil
        do {
            let updated = try await session.analysisResource(kind.resourceKind)
            guard !Task.isCancelled, key == requestKey else { return }
            resource = updated
            loadedKey = key
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, key == requestKey else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func refresh() async {
        let key = requestKey
        do {
            let updated = try await session.analysisResource(kind.resourceKind, forceRefresh: true)
            guard !Task.isCancelled, key == requestKey else { return }
            resource = updated
            loadedKey = key
            errorMessage = nil
        } catch is CancellationError { } catch {
            guard !Task.isCancelled, key == requestKey else { return }
            errorMessage = error.localizedDescription
        }
    }
}

private struct AnalysisRequestKey: Hashable {
    let kind: LedgerAnalysisKind
    let start: String
    let end: String
    let valuationCurrency: String
    let presentationID: Int
    let revision: UUID?
    let reloadToken: Int
}

private struct IncomeExpenseAnalysisContent: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerIncomeExpenseAnalysis

    @State private var eventTagListPresented = false
    @State private var selectedEventTag: String?

    private var dashboard: LedgerDashboard { data.dashboard }
    private var statement: LedgerIncomeStatement { data.statement }

    private var eventSummaries: [EventTagSummary] {
        if session.isLocal { return session.localEventTagSummaries ?? [] }
        return EventTagCalculator.summarizeAllTags(from: session.visibleTransactions,
            accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
    }
    private var eventReadKey: String {
        "\(session.localGlobalSearchInvalidation)/\(session.phase)/\(session.privacyShielded)/\(session.isRangeLoading)/\(session.isValuationCurrencyLoading)/\(session.transactionMutationStates.values.contains(.pending))"
    }

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(
                metrics: [
                    AnalysisMetric(String(localized: "期间结余"), amount: statement.netIncome, color: statement.netIncome >= 0 ? LedgerPalette.ink : LedgerPalette.expense),
                    AnalysisMetric(String(localized: "收入"), amount: statement.totalIncome, color: LedgerPalette.income),
                    AnalysisMetric(String(localized: "支出"), amount: statement.totalExpense, color: LedgerPalette.expense),
                ],
                currency: statement.valuationCurrency,
                onSelect: { idx in
                    switch idx {
                    case 1: session.navigateToTransactions(kind: .income)
                    case 2: session.navigateToTransactions(kind: .expense)
                    default: session.navigateToTransactions(kind: .all)
                    }
                }
            )

            AnalysisChartPanel(title: String(localized: "现金流"), detail: String(localized: "按月比较收入、支出与结余")) {
                if dashboard.cashflowSeries.isEmpty {
                    AnalysisEmptyContent(icon: "chart.xyaxis.line", message: String(localized: "所选范围暂无现金流趋势"))
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
                title: String(localized: "支出分类排行"),
                items: statement.expenseAnalytics,
                totalExpense: statement.totalExpense,
                currency: statement.valuationCurrency
            )

            // Event & Tag Project Accounting Card
            let allSummaries = eventSummaries
            if session.isLocal, let error = session.localEventTagSummaryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text("事件汇总读取失败：\(error)").foregroundStyle(.secondary)
                    Button("重试事件汇总") { Task { await session.loadLocalEventTagSummaries(force: true) } }
                }
            } else if session.isLocal && session.localEventTagSummaries == nil {
                ProgressView("正在统计事件与项目…")
            }
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
                                            .font(.system(size: 14, weight: .bold, design: .monospaced))
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
                                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                            }
                            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
                        }
                    }
                }
                .padding(16)
                .background(LedgerPalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                        .stroke(LedgerPalette.cardBorder, lineWidth: 0.8)
                )
            }

            IncomeExpenseHighlights(statement: statement)

            IncomeNodePanel(title: String(localized: "收入账户"), nodes: flattened(statement.income), currency: statement.valuationCurrency, color: LedgerPalette.income)
            IncomeNodePanel(title: String(localized: "支出账户"), nodes: flattened(statement.expense), currency: statement.valuationCurrency, color: LedgerPalette.expense)

            if !dashboard.anomalies.isEmpty {
                AnalysisListPanel(title: String(localized: "需要留意"), detail: String(localized: "按金额与历史模式识别")) {
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
        .task(id: eventReadKey) { if session.isLocal { await session.loadLocalEventTagSummaries() } }
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
                title: String(localized: "热门商户"),
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
                title: String(localized: "支付账户"),
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
            AnalysisListPanel(title: String(localized: "待整理项目"), detail: "Expenses:Unknown") {
                if let unknown {
                    Button {
                        LedgerFeedback.selection()
                        session.navigateToTransactions(account: "Expenses:Unknown")
                    } label: {
                        AnalysisAmountRow(
                            title: unknown.label,
                            detail: String(localized: "\(unknown.txCount) 笔 · 占支出 \(percent(unknown.share))"),
                            amount: unknown.amount,
                            currency: statement.valuationCurrency,
                            color: LedgerPalette.expense
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    AnalysisEmptyRow(message: String(localized: "当前期间没有待整理支出"))
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
                            series: .value("系列", String(localized: "收入"))
                        )
                        .foregroundStyle(LedgerPalette.income)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        LineMark(
                            x: .value("月份", x),
                            y: .value("支出", point.expense),
                            series: .value("系列", String(localized: "支出"))
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
                .ledgerChartReveal("cashflow")
                .accessibilityLabel("现金流趋势图，可点按或拖动查看数据")
                .accessibilityValue(axis.usesTimeScale ? "真实时间轴" : "有序分类轴")
                .accessibilityIdentifier("cashflow-trend-chart")

                if let selectedPoint {
                    CashflowSelectionLabel(point: selectedPoint, currency: currency)
                }
            }
            .frame(height: 190)

            AnalysisChartLegend(items: [
                (String(localized: "收入"), LedgerPalette.income),
                (String(localized: "支出"), LedgerPalette.expense),
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

private struct InvestmentsAnalysisContent: View {
    let data: LedgerInvestmentSummary

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric(String(localized: "持仓市值"), amount: data.totalMarketValueCny, color: LedgerPalette.gold),
                AnalysisMetric(
                    String(localized: "已实现收益"),
                    amount: data.realizedPnlCny,
                    placeholder: String(localized: "暂无记录"),
                    color: (data.realizedPnlCny ?? 0) >= 0 ? LedgerPalette.income : LedgerPalette.expense
                ),
            ], currency: "CNY")

            AnalysisListPanel(title: String(localized: "当前持仓"), detail: String(localized: "\(data.holdings.count) 个品种")) {
                if data.holdings.isEmpty {
                    AnalysisEmptyRow(message: String(localized: "暂无投资持仓"))
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

    init(_ title: String, amount: Int?, placeholder: String = String(localized: "暂无数据"), color: Color) {
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
        .overlay { Rectangle().stroke(BalancedPalette.rule, lineWidth: 1) }
    }
}

private struct AnalysisMetricCell: View {
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
                        displayMode: .adaptive
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
            .background(BalancedPalette.sunken)
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
        .overlay { Rectangle().stroke(BalancedPalette.rule, lineWidth: 1) }
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
        .background(BalancedPalette.page)
        .overlay { Rectangle().stroke(BalancedPalette.rule, lineWidth: 1) }
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
            return (String(localized: "浮动 "), market - cost, true)
        case (nil, let cost?):
            return (String(localized: "成本 "), cost, false)
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
            SectionHeading(title: title, detail: String(localized: "前 \(rows.count) 项"))
            if rows.isEmpty {
                AnalysisEmptyRow(message: String(localized: "所选范围暂无支出分类"))
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
        AnalysisListPanel(title: title, detail: String(localized: "\(nodes.filter { $0.children.isEmpty }.count) 个分类")) {
            if nodes.isEmpty {
                AnalysisEmptyRow(message: String(localized: "所选范围暂无\(title)"))
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

        var title: String {
            switch self {
            case .expense: String(localized: "支出")
            case .income: String(localized: "收入")
            }
        }
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
                    label: String(localized: "其他"),
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
                    label: String(localized: "其他"),
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
                            withLedgerAnimation(LedgerMotion.toggle) {
                                selectedTab = tab
                                selectedSliceID = nil
                            }
                        } label: {
                            Text(tab.title)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? Color.white : LedgerPalette.ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    isSelected
                                        ? (tab == .expense ? LedgerPalette.expense : LedgerPalette.income)
                                        : Color(uiColor: .tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: LedgerRadius.sm)
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
                    Text("当前期间暂无\(selectedTab.title)记录")
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
                            font: .system(size: 18, weight: .bold, design: .monospaced),
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
                            withLedgerAnimation(LedgerMotion.selection) {
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
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                selectedSliceID == slice.id ? slice.color.opacity(0.12) : Color(uiColor: .tertiarySystemFill).opacity(0.4),
                                in: RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
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
                        .background(slice.color.opacity(0.12), in: RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .fill(LedgerPalette.panel)

        }
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
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
                AnalysisEmptyRow(message: String(localized: "所选范围暂无支出分类"))
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
                                    RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                                        .fill(rankBadgeBackground(index))
                                        .frame(width: 20, height: 20)
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(rankTextColor(index))
                                }

                                // Squircle icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
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
                                        font: .system(size: 14.5, weight: .semibold, design: .monospaced),
                                        color: LedgerPalette.ink
                                    )
                                    Text(String(format: "%.1f%%", pct * 100))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced).monospacedDigit())
                                        .foregroundStyle(LedgerPalette.secondary)
                                }

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(LedgerPalette.secondary.opacity(0.5))
                            }

                            // Proportional progress track
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: LedgerRadius.sm)
                                        .fill(Color(uiColor: .tertiarySystemFill))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: LedgerRadius.sm)
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
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .fill(LedgerPalette.panel)

        }
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
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
