import Charts
import SwiftUI

enum LedgerAnalysisKind: String, CaseIterable, Hashable {
    case dashboard
    case netWorth
    case incomeStatement
    case investments

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .netWorth: "净资产"
        case .incomeStatement: "损益"
        case .investments: "投资"
        }
    }

    var detail: String {
        switch self {
        case .dashboard: "现金流、支出结构与异常活动"
        case .netWorth: "资产、负债与净值趋势"
        case .incomeStatement: "收入、支出与期间结余"
        case .investments: "持仓市值、成本与收益"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "rectangle.3.group"
        case .netWorth: "chart.line.uptrend.xyaxis"
        case .incomeStatement: "sum"
        case .investments: "chart.pie"
        }
    }

    var resourceKind: LedgerAnalysisResourceKind {
        switch self {
        case .dashboard, .netWorth: .dashboard
        case .incomeStatement: .incomeStatement
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
                LedgerAppBar { PrivacyToolbarButton() }
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
        .toolbar {
            if !showsAppBar {
                ToolbarItem(placement: .topBarTrailing) { PrivacyToolbarButton() }
            }
        }
        .task(id: requestKey) { await load() }
    }

    @ViewBuilder
    private func content(_ resource: LedgerAnalysisResource) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                LedgerPageIntro(
                    title: kind.title,
                    detail: kind.detail,
                    meta: session.selectedRange.displayTitle
                ) { EmptyView() }

                if let errorMessage {
                    StatusBanner(message: errorMessage) { self.errorMessage = nil }
                }

                switch resource {
                case let .dashboard(data):
                    if kind == .netWorth {
                        NetWorthAnalysisContent(data: data)
                    } else {
                        DashboardAnalysisContent(data: data)
                    }
                case let .incomeStatement(data):
                    IncomeStatementAnalysisContent(data: data)
                case let .investments(data):
                    InvestmentsAnalysisContent(data: data)
                }
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
            .padding(.top, horizontalSizeClass == .regular ? LedgerSpacing.xl : 0)
            .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
            .ledgerAdaptivePageWidth()
        }
        .accessibilityIdentifier("analysis-content-\(kind.rawValue)")
        .refreshable { await load(replacingContent: false) }
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
}

private struct AnalysisRequestKey: Hashable {
    let kind: LedgerAnalysisKind
    let start: String
    let end: String
    let valuationCurrency: String
    let reloadToken: Int
}

private struct DashboardAnalysisContent: View {
    let data: LedgerDashboard

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("净资产", amount: data.kpis.netWorth, color: LedgerPalette.gold),
                AnalysisMetric("期间结余", amount: data.kpis.net, color: data.kpis.net >= 0 ? LedgerPalette.income : LedgerPalette.expense),
                AnalysisMetric("收入", amount: data.kpis.income, color: LedgerPalette.income),
                AnalysisMetric("支出", amount: data.kpis.expense, color: LedgerPalette.expense),
            ], currency: data.currency)

            AnalysisChartPanel(title: "现金流趋势", detail: "按月比较收入与支出") {
                if data.cashflowSeries.isEmpty {
                    AnalysisEmptyContent(icon: "chart.xyaxis.line", message: "所选范围暂无现金流趋势")
                } else {
                    Chart(data.cashflowSeries) { point in
                        LineMark(x: .value("月份", point.month), y: .value("收入", point.income), series: .value("系列", "收入"))
                            .foregroundStyle(LedgerPalette.income)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("月份", point.month), y: .value("支出", point.expense), series: .value("系列", "支出"))
                            .foregroundStyle(LedgerPalette.expense)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 190)
                    .accessibilityLabel("现金流趋势图")

                    AnalysisChartLegend(items: [
                        ("收入", LedgerPalette.income),
                        ("支出", LedgerPalette.expense),
                    ])
                }
            }

            RankedAmountPanel(
                title: "支出结构",
                rows: data.categorySeries.prefix(6).map { ($0.label, $0.total, 0) },
                currency: data.currency,
                color: LedgerPalette.expense
            )

            if !data.anomalies.isEmpty {
                AnalysisListPanel(title: "需要留意", detail: "按金额与历史模式识别") {
                    ForEach(Array(data.anomalies.prefix(4).enumerated()), id: \.offset) { _, anomaly in
                        AnalysisAmountRow(
                            title: anomaly.payee.isEmpty ? anomaly.narration : anomaly.payee,
                            detail: "\(anomaly.date) · \(anomaly.account.split(separator: ":").last.map(String.init) ?? anomaly.account)",
                            amount: anomaly.amount,
                            currency: data.currency,
                            color: LedgerPalette.expense
                        )
                    }
                }
            }
        }
    }
}

private struct NetWorthAnalysisContent: View {
    let data: LedgerDashboard

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("净资产", amount: data.kpis.netWorth, color: LedgerPalette.gold),
                AnalysisMetric("总资产", amount: data.kpis.assets, color: LedgerPalette.income),
                AnalysisMetric("总负债", amount: data.kpis.liabilities, color: LedgerPalette.expense),
            ], currency: data.currency)

            AnalysisChartPanel(title: "净资产走势", detail: "资产减去负债后的长期位置") {
                if data.netWorthSeries.isEmpty {
                    AnalysisEmptyContent(icon: "chart.line.uptrend.xyaxis", message: "所选范围暂无净资产趋势")
                } else {
                    Chart(data.netWorthSeries) { point in
                        AreaMark(x: .value("日期", point.date), y: .value("净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt.opacity(0.12))
                        LineMark(x: .value("日期", point.date), y: .value("净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.4))
                        PointMark(x: .value("日期", point.date), y: .value("净资产", point.netWorth))
                            .foregroundStyle(LedgerPalette.cobalt)
                            .symbolSize(18)
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 220)
                    .accessibilityLabel("净资产走势图")
                }
            }

            AnalysisListPanel(title: "最近位置", detail: "最近 6 个观察点") {
                if data.netWorthSeries.isEmpty {
                    AnalysisEmptyRow(message: "暂无净资产观察点")
                } else {
                    ForEach(data.netWorthSeries.suffix(6).reversed()) { point in
                        AnalysisAmountRow(title: point.date, detail: "资产与负债汇总", amount: point.netWorth, currency: data.currency, color: LedgerPalette.gold)
                    }
                }
            }
        }
    }
}

private struct IncomeStatementAnalysisContent: View {
    let data: LedgerIncomeStatement

    var body: some View {
        VStack(spacing: LedgerSpacing.lg) {
            AnalysisMetricGrid(metrics: [
                AnalysisMetric("净结余", amount: data.netIncome, color: data.netIncome >= 0 ? LedgerPalette.gold : LedgerPalette.expense),
                AnalysisMetric("收入", amount: data.totalIncome, color: LedgerPalette.income),
                AnalysisMetric("支出", amount: data.totalExpense, color: LedgerPalette.expense),
            ], currency: data.valuationCurrency)

            IncomeNodePanel(title: "收入构成", nodes: flattened(data.income), currency: data.valuationCurrency, color: LedgerPalette.income)
            IncomeNodePanel(title: "支出构成", nodes: flattened(data.expense), currency: data.valuationCurrency, color: LedgerPalette.expense)
        }
    }

    private func flattened(_ nodes: [LedgerIncomeNode]) -> [LedgerIncomeNode] {
        nodes.flatMap { [$0] + flattened($0.children) }
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

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 1) {
                    ForEach(metrics.indices, id: \.self) { index in
                        AnalysisMetricCell(metric: metrics[index], currency: currency)
                    }
                }
            } else {
                VStack(spacing: 1) {
                    ForEach(compactRows.indices, id: \.self) { rowIndex in
                        HStack(spacing: 1) {
                            ForEach(compactRows[rowIndex], id: \.self) { metricIndex in
                                AnalysisMetricCell(metric: metrics[metricIndex], currency: currency)
                            }
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous).stroke(LedgerPalette.line, lineWidth: 1) }
    }

    private var compactRows: [[Int]] {
        if metrics.count == 3 { return [[0], [1, 2]] }
        return stride(from: 0, to: metrics.count, by: 2).map { start in
            Array(start ..< min(start + 2, metrics.count))
        }
    }
}

private struct AnalysisMetricCell: View {
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
                    color: metric.color
                )
                .tracking(-0.4)
                .lineLimit(1)
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
