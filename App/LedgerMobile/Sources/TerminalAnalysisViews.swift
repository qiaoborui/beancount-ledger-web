import Charts
import SwiftUI

/// Report sections use the same reading columns and rules as the approved terminal prototype.
struct TerminalReportSection<Content: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).terminalFont(size: 13, weight: .semibold)
                    .foregroundStyle(TerminalPalette.accent)
                Spacer(minLength: 8)
                Text(detail).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 44)
            .accessibilityAddTraits(.isHeader)
            TerminalRule()
            content
        }
    }
}

struct TerminalReportMetric: View {
    let title: String
    let amount: Int?
    let currency: String
    var value: String? = nil
    var note: String = "所选期间"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
            if let amount {
                TerminalAmount(minorUnits: amount, currency: currency, size: 17)
            } else {
                Text(value ?? "暂无数据").terminalFont(size: 17, weight: .medium, design: .monospaced)
                    .foregroundStyle(TerminalPalette.ink)
            }
            Text(note).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 12)
    }
}

struct TerminalReportGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 1) {
            content.frame(maxHeight: .infinity, alignment: .topLeading).background(TerminalPalette.page)
        }
        .background(TerminalPalette.line)
        .overlay(alignment: .top) { TerminalRule() }
        .overlay(alignment: .bottom) { TerminalRule() }
    }
}

struct TerminalReportRow: View {
    let title: String
    var detail: String = ""
    let amount: Int
    let currency: String
    var annotation: String = ""
    var showsCurrency = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).terminalFont(size: 14, weight: .medium).foregroundStyle(TerminalPalette.ink)
                if !detail.isEmpty {
                    Text(detail).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                TerminalAmount(minorUnits: amount, currency: currency, size: 13, showsCurrency: showsCurrency)
                if !annotation.isEmpty {
                    Text(annotation).terminalFont(size: 11, design: .monospaced)
                        .foregroundStyle(TerminalPalette.secondary)
                }
            }
        }
        .padding(.vertical, 12).frame(minHeight: 48)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { TerminalRule() }
    }
}

/// Hiding amounts also hides chart geometry and derived ratios, not only labels.
private struct TerminalReportChart: View {
    @EnvironmentObject private var session: LedgerSession
    let points: [LedgerCashflowPoint]
    let currency: String
    var netOnly = false
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.amountsVisible {
                Text("金额已隐藏").terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").terminalFont(size: 12)
                    .foregroundStyle(TerminalPalette.secondary).frame(minHeight: 100)
            } else {
                Chart(points) { point in
                    if netOnly {
                        LineMark(x: .value("月份", point.month), y: .value("结余", Double(point.net) / 100))
                            .foregroundStyle(TerminalPalette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("月份", point.month), y: .value("结余", Double(point.net) / 100))
                            .foregroundStyle(TerminalPalette.accent).symbolSize(14)
                    } else {
                        BarMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / 100))
                            .position(by: .value("类别", "收入")).foregroundStyle(TerminalPalette.ink)
                        BarMark(x: .value("月份", point.month), y: .value("支出", Double(point.expense) / 100))
                            .position(by: .value("类别", "支出")).foregroundStyle(TerminalPalette.accent)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(TerminalPalette.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TerminalPalette.secondary)
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(.hidden)
                .frame(height: 156)
                .accessibilityLabel(netOnly ? "结余趋势" : "月度收支")
                .accessibilityIdentifier(netOnly ? "terminal-net-chart" : "terminal-cashflow-chart")
                if !netOnly {
                    HStack(spacing: 16) {
                        legend("收入", color: TerminalPalette.ink)
                        legend("支出", color: TerminalPalette.accent)
                    }
                }
                DisclosureGroup("查看数据 · \(currency)", isExpanded: $showsData) {
                    ForEach(points) { point in
                        TerminalReportRow(title: point.month,
                            detail: netOnly ? "结余" : "收入 / 支出",
                            amount: netOnly ? point.net : point.income, currency: currency,
                            annotation: netOnly ? "" : MoneyText.format(minorUnits: point.expense, currency: currency))
                    }
                }.terminalFont(size: 12).tint(TerminalPalette.accent)
            }
        }.padding(.vertical, 12)
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 12, height: 4)
            Text(label).terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
        }
    }
}

/// `.sechead` — plain 15/600 heading with a right-aligned aside, no numbered
/// prefix. A private copy of `OverviewView`'s section head (that one stays
/// file-private there) so this report can stay self-contained.
@MainActor
private func balancedSechead(_ title: String, aside: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
        Text(title).balancedFont(size: 15, weight: .semibold).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
        Spacer(minLength: 0)
        Text(aside).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
    }.padding(EdgeInsets(top: 26, leading: 20, bottom: 10, trailing: 20))
}

/// `.metric` cell: label, 22/500 tabular value, sub caption. Two per row with
/// a shared rule grid, matching `.metrics` / `.metric` in styles.css.
private struct BalancedAnalysisMetric: View {
    @EnvironmentObject private var session: LedgerSession
    let title: String
    let minorUnits: Int
    let currency: String
    var prefix = ""
    var color: Color = BalancedPalette.ink
    var sub = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
            Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: abs(minorUnits), currency: currency, showsCurrency: false) : "••••••")
                .font(.custom(BalancedWeight.medium.sansPostscriptName, size: 22, relativeTo: .title2))
                .tracking(-0.44).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.tbl` — a category/payee/account table: right-aligned `.amt` at 500
/// weight, a fixed-width `.share` column, an optional totals row in `--sunken`.
private struct BalancedAnalysisTable: View {
    @EnvironmentObject private var session: LedgerSession
    struct Row: Identifiable { let id: String; let label: String; let detail: String; let minorUnits: Int; let share: Double?; var action: (() -> Void)? = nil }
    let rows: [Row]
    let currency: String
    var total: (label: String, minorUnits: Int)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.label).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(amountText(row.minorUnits))
                        .balancedFont(size: 14.5, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.ink).lineLimit(1)
                    if let share = row.share {
                        Text(session.amountsVisible ? String(format: "%.1f%%", share * 100) : "—")
                            .balancedFont(size: 14.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                            .frame(width: 54, alignment: .trailing)
                    }
                }
                .padding(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                .contentShape(Rectangle())
                if let action = row.action {
                    Button(action: action) { content }.buttonStyle(.plain)
                } else { content }
            }
            if let total {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(total.label).balancedFont(size: 14.5, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                    Spacer(minLength: 8)
                    Text(amountText(total.minorUnits)).balancedFont(size: 14.5, weight: .semibold).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                    Text("100%").balancedFont(size: 14.5, weight: .semibold).monospacedDigit().foregroundStyle(BalancedPalette.secondary)
                        .frame(width: 54, alignment: .trailing)
                }
                .padding(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
                .background(BalancedPalette.sunken)
            }
        }
    }

    private func amountText(_ minorUnits: Int) -> String {
        session.amountsVisible ? MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: false) : "••••••"
    }
}

/// Design batch 1, 收支分析 (b05 light · 月度收支, b06 dark · 分类与商户). KPI
/// grid, two charts with ink/--out opposed colours, category tables with a
/// share column, and real flagged transactions under 异常与提示 — the mock's
/// prose insights ("本月支出低于前三月均值…") have no backing data source, so
/// this reads the actual anomaly rows instead of inventing summary text.
struct TerminalIncomeExpenseReport: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let data: LedgerIncomeExpenseAnalysis
    @State private var incomeCategories = false
    @State private var showsMonthlyData = false
    @State private var eventsPresented = false
    @State private var selectedTag: String?

    private var statement: LedgerIncomeStatement { data.statement }
    private var currency: String { statement.valuationCurrency }
    private var dayCount: Int {
        guard let start = LedgerDateRange.parse(data.dashboard.start), let end = LedgerDateRange.parse(data.dashboard.end) else { return 1 }
        let diff = LedgerDateRange.calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, diff)
    }
    private var dailyAverageExpense: Int { statement.totalExpense / dayCount }
    private var netColor: Color { statement.netIncome >= 0 ? BalancedPalette.income : BalancedPalette.expense }
    private var netPrefix: String { statement.netIncome >= 0 ? "+" : "−" }
    private var events: [EventTagSummary] {
        if session.isLocal { return session.localEventTagSummaries ?? [] }
        return EventTagCalculator.summarizeAllTags(from: session.visibleTransactions,
            accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
    }
    private var eventReadKey: String {
        "\(session.localGlobalSearchInvalidation)/\(session.phase)/\(session.privacyShielded)/\(session.isRangeLoading)/\(session.isValuationCurrencyLoading)/\(session.transactionMutationStates.values.contains(.pending))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // b05/b06 order: KPI grid, two charts, 支出构成, 支出商户, 资金来源,
            // (收入来源 — omitted, see below), 异常与提示. Existing functionality
            // the mock doesn't show (分类明细 toggle, 事件与项目, 账户明细) follows
            // after, so the mock's own section order stays intact up top.
            metricsGrid
            monthlyChart
            netTrendChart
            expenseComposition
            payeesSection
            fundingSection
            // b06 also tables a 收入来源 (deposit accounts income lands in) —
            // the API exposes only income by category account, not by the
            // destination asset account, so that table is omitted rather than
            // approximated.
            anomaliesSection
            categoryToggleSection
            eventsSection
            accountDetailSection
        }
        .padding(.horizontal, horizontalSizeClass == .regular ? 0 : -20)
        .task(id: eventReadKey) { if session.isLocal { await session.loadLocalEventTagSummaries() } }
        .sheet(isPresented: $eventsPresented) { EventTagListView().ledgerPrivacyProtectedSheet() }
        .sheet(isPresented: Binding(get: { selectedTag != nil }, set: { if !$0 { selectedTag = nil } })) {
            if let tag = selectedTag {
                NavigationStack {
                    EventTagReportView(tag: tag).toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("关闭") { selectedTag = nil } }
                    }
                }.ledgerPrivacyProtectedSheet()
            }
        }
    }

    // MARK: KPI grid (`.metrics`)

    private var metricsGrid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BalancedAnalysisMetric(title: "收入", minorUnits: statement.totalIncome, currency: currency, sub: currency + " · 所选区间")
                    .overlay(alignment: .trailing) { BalancedPalette.rule.frame(width: 1) }
                BalancedAnalysisMetric(title: "支出", minorUnits: statement.totalExpense, currency: currency, sub: currency + " · 所选区间")
            }.overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            HStack(spacing: 0) {
                BalancedAnalysisMetric(title: "净结余", minorUnits: statement.netIncome, currency: currency, prefix: netPrefix, color: netColor, sub: "收入 − 支出")
                    .overlay(alignment: .trailing) { BalancedPalette.rule.frame(width: 1) }
                BalancedAnalysisMetric(title: "日均支出", minorUnits: dailyAverageExpense, currency: currency, sub: "\(dayCount) 天")
            }
        }
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    // MARK: Charts (`.chart`, `.chart-foot`, `.disclose`)

    private var monthlyChart: some View {
        let points = data.dashboard.cashflowSeries
        return VStack(alignment: .leading, spacing: 0) {
            balancedSechead("月度收支", aside: currency)
            if !session.amountsVisible {
                Text("金额已隐藏").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).frame(maxWidth: .infinity, minHeight: 140)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
            } else {
                Chart(points) { point in
                    BarMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / 100))
                        .position(by: .value("类别", "收入")).foregroundStyle(BalancedPalette.ink)
                    BarMark(x: .value("月份", point.month), y: .value("支出", Double(point.expense) / 100))
                        .position(by: .value("类别", "支出")).foregroundStyle(BalancedPalette.expense)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(BalancedPalette.rule)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                .balancedFont(size: 10).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(.hidden)
                .frame(height: 156)
                .padding(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                .accessibilityLabel("月度收支").accessibilityIdentifier("balanced-cashflow-chart")
                HStack(spacing: 20) {
                    legendKey("收入", color: BalancedPalette.ink)
                    legendKey("支出", color: BalancedPalette.expense)
                }.padding(EdgeInsets(top: 10, leading: 20, bottom: 6, trailing: 20))
                Text("按月汇总 · 转账不计收支").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                Button { showsMonthlyData.toggle() } label: {
                    HStack {
                        Text("查看数据").balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                            .rotationEffect(.degrees(showsMonthlyData ? 90 : 0))
                    }
                    .padding(EdgeInsets(top: 13, leading: 20, bottom: 13, trailing: 20)).frame(minHeight: 44)
                    .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(.isButton)
                if showsMonthlyData {
                    ForEach(points) { point in monthlyDataRow(point) }
                }
            }
        }
    }

    private var netTrendChart: some View {
        let points = data.dashboard.cashflowSeries
        return VStack(alignment: .leading, spacing: 0) {
            balancedSechead("净结余趋势", aside: currency)
            if !session.amountsVisible {
                Text("金额已隐藏").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).frame(maxWidth: .infinity, minHeight: 120)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
            } else {
                Chart(points) { point in
                    LineMark(x: .value("月份", point.month), y: .value("净结余", Double(point.net) / 100))
                        .foregroundStyle(BalancedPalette.ink).lineStyle(StrokeStyle(lineWidth: 1.6))
                    PointMark(x: .value("月份", point.month), y: .value("净结余", Double(point.net) / 100))
                        .foregroundStyle(BalancedPalette.ink).symbolSize(16)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(BalancedPalette.rule)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                .balancedFont(size: 10).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(.hidden)
                .frame(height: 136)
                .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
                .accessibilityLabel("净结余趋势").accessibilityIdentifier("balanced-net-chart")
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private func legendKey(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 9, height: 9)
            Text(label).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
        }
    }

    private func monthlyDataRow(_ point: LedgerCashflowPoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(point.month).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.secondary)
            Spacer(minLength: 0)
            Text(session.amountsVisible ? "+" + MoneyText.format(minorUnits: point.income, currency: currency, showsCurrency: false) : "••••••")
                .balancedFont(size: 13, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.ink)
            Text(session.amountsVisible ? "−" + MoneyText.format(minorUnits: point.expense, currency: currency, showsCurrency: false) : "••••••")
                .balancedFont(size: 13, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.expense)
        }
        .padding(EdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20))
        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
    }

    // MARK: Tables (`.tbl`)

    private var expenseComposition: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("支出构成").balancedFont(size: 15, weight: .semibold).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(session.amountsVisible ? MoneyText.format(minorUnits: statement.totalExpense, currency: currency, showsCurrency: false) : "••••••")
                        .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                    Text(currency).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                }
            }.padding(EdgeInsets(top: 26, leading: 20, bottom: 10, trailing: 20))
            if statement.expenseAnalytics.isEmpty {
                empty("所选区间暂无支出")
            } else {
                BalancedAnalysisTable(rows: statement.expenseAnalytics.prefix(5).map { item in
                    .init(id: item.id, label: item.label, detail: "\(item.txCount) 笔", minorUnits: item.amount,
                        share: item.share ?? share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(kind: .expense, account: item.account) })
                }, currency: currency, total: ("合计", statement.totalExpense))
            }
            Text("占比按所选区间重算，不引用历史缓存。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var payeesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead("支出商户", aside: "按金额")
            if statement.topPayees.isEmpty {
                empty("暂无商户数据")
            } else {
                BalancedAnalysisTable(rows: statement.topPayees.prefix(6).map { item in
                    .init(id: item.id, label: item.payee, detail: "\(item.txCount) 笔", minorUnits: item.amount, share: share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(query: item.payee) })
                }, currency: currency)
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var fundingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead("资金来源", aside: "支出账户")
            if statement.topPaymentAccounts.isEmpty {
                empty("暂无支出账户数据")
            } else {
                BalancedAnalysisTable(rows: statement.topPaymentAccounts.prefix(6).map { item in
                    .init(id: item.id, label: item.label, detail: "\(item.txCount) 笔", minorUnits: item.amount, share: share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(account: item.account) })
                }, currency: currency)
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    /// 收入分类 isn't part of the b05/b06 mock, but the existing feature (a
    /// toggle onto the income breakdown) stays — reskinned onto the same
    /// `.sechead` / `.tbl` idiom rather than dropped.
    private var categoryToggleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead(incomeCategories ? "收入分类" : "支出分类明细", aside: "按分类")
            HStack(spacing: 22) {
                categoryTab("支出", income: false)
                categoryTab("收入", income: true)
            }.padding(.horizontal, 20).overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            if incomeCategories {
                if statement.income.isEmpty {
                    empty("暂无收入分类")
                } else {
                    BalancedAnalysisTable(rows: statement.income.map { node in
                        .init(id: node.id, label: node.label, detail: "\(node.txCount) 笔", minorUnits: node.amount,
                            share: share(node.amount, total: statement.totalIncome),
                            action: { session.navigateToTransactions(kind: .income, account: node.account) })
                    }, currency: currency)
                }
            } else if statement.expenseAnalytics.isEmpty {
                empty("暂无支出分类")
            } else {
                BalancedAnalysisTable(rows: statement.expenseAnalytics.map { item in
                    .init(id: item.id, label: item.label, detail: "\(item.txCount) 笔" + categoryChange(item.changeRatio), minorUnits: item.amount,
                        share: share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(kind: .expense, account: item.account) })
                }, currency: currency)
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead("事件与项目", aside: "独立核算")
            if session.isLocal, let error = session.localEventTagSummaryError {
                Text(error).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 20)
                Button("重试事件汇总") { Task { await session.loadLocalEventTagSummaries(force: true) } }
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink).padding(.horizontal, 20).frame(minHeight: 44)
            } else if session.isLocal && session.localEventTagSummaries == nil {
                ProgressView("正在统计事件与项目…").padding(.horizontal, 20).padding(.vertical, 12)
            }
            if events.isEmpty {
                empty("暂无事件与项目")
            } else {
                BalancedAnalysisTable(rows: events.prefix(3).map { event in
                    .init(id: event.tag, label: "#" + event.tag, detail: "\(event.transactionCount) 笔", minorUnits: event.netSpend, share: nil,
                        action: { selectedTag = event.tag })
                }, currency: events.first?.currency ?? currency)
            }
            Button("查看全部事件与项目") { eventsPresented = true }
                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink).frame(minHeight: 44)
                .padding(.horizontal, 20)
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var accountDetailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead("账户明细", aside: currency)
            accountNodes(statement.income, kind: .income)
            accountNodes(statement.expense, kind: .expense)
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var anomaliesSection: some View {
        let anomalies = data.dashboard.anomalies
        return VStack(alignment: .leading, spacing: 0) {
            balancedSechead("异常与提示", aside: "\(anomalies.count) 条")
            if anomalies.isEmpty {
                empty("区间内未发现异常交易")
            } else {
                ForEach(anomalies.prefix(6)) { item in
                    Button { session.navigateToTransactions(account: item.account) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.payee.isEmpty ? item.narration : item.payee)
                                .balancedFont(size: 15.5, weight: .medium).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                            Text(item.date + " · " + (session.amountsVisible ? MoneyText.format(minorUnits: item.amount, currency: data.dashboard.currency, showsCurrency: false) : "••••••"))
                                .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20)).frame(minHeight: 52)
                        .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("未记录的消费不会被推算，只提示差异。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 12, leading: 20, bottom: 24, trailing: 20))
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    // MARK: Helpers

    private func share(_ amount: Int, total: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(amount) / Double(total)
    }
    private func categoryChange(_ ratio: Double?) -> String {
        guard session.amountsVisible, let ratio, ratio.isFinite else { return "" }
        return " · 较上期 " + ratio.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
    }
    private func categoryTab(_ label: String, income: Bool) -> some View {
        Button { incomeCategories = income } label: {
            Text(label).balancedFont(size: 14.5, weight: incomeCategories == income ? .semibold : .regular)
                .foregroundStyle(incomeCategories == income ? BalancedPalette.ink : BalancedPalette.meta)
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    if incomeCategories == income { BalancedPalette.ink.frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(incomeCategories == income ? .isSelected : [])
    }
    private func flatten(_ nodes: [LedgerIncomeNode]) -> [LedgerIncomeNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
    private func accountNodes(_ nodes: [LedgerIncomeNode], kind: TransactionKindFilter) -> some View {
        ForEach(flatten(nodes)) { node in
            Button { session.navigateToTransactions(kind: kind, account: node.account) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.label).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                        Text(node.account).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(session.amountsVisible ? MoneyText.format(minorUnits: node.amount, currency: currency, showsCurrency: false) : "••••••")
                        .balancedFont(size: 14.5, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                }
                .padding(EdgeInsets(top: 11, leading: 20 + CGFloat(min(node.depth, 3)) * 12, bottom: 11, trailing: 20))
                .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
    private func empty(_ title: String) -> some View {
        Text(title).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
    }
}

struct TerminalAssetsReport: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerAssetsAnalysis
    @State private var monthEnd = true
    @State private var showsHistory = false
    private var balances: [AccountBalance] {
        data.accountBalances.filter { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }
    }
    private var valuations: [String: Int] {
        Dictionary(grouping: balances.filter { $0.valuationMissing != true }, by: \.account)
            .mapValues { $0.reduce(0) { $0 + $1.valuation } }
    }
    private var assets: Int { valuations.filter { $0.key.hasPrefix("Assets:") }.values.reduce(0, +) }
    private var debt: Int { valuations.filter { $0.key.hasPrefix("Liabilities:") }.values.reduce(0) { $0 + abs($1) } }
    private var missing: Bool { balances.contains { $0.valuationMissing == true } }
    private var currency: String { data.valuationCurrency }
    private var points: [LedgerNetWorthPoint] {
        monthEnd && !data.monthEndNetWorth.isEmpty ? data.monthEndNetWorth : data.netWorthHistory
    }
    private var accountNames: [String] { Array(Set(balances.map(\.account))).sorted() }
    private var labels: [String: String] { TransactionCategoryPresentation.accountLabels(data.accounts) }

    var body: some View {
        VStack(spacing: 16) {
            TerminalReportGrid {
                TerminalReportMetric(title: "净资产", amount: assets - debt, currency: currency, note: missing ? "已知估值 · 部分缺价" : currency + " · 当前估值")
                TerminalReportMetric(title: "总资产", amount: assets, currency: currency, note: currency + " · 当前估值")
                TerminalReportMetric(title: "总负债", amount: debt, currency: currency, note: currency + " · 当前估值")
                TerminalReportMetric(title: "本月净值变化", amount: data.netWorthWindows?.monthChange, currency: currency, note: "较上月末 · 非所选期间")
            }
            if missing {
                Text("部分资产缺少价格，当前合计仅包含已知估值；缺价不按零估值。")
                    .terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
            }
            TerminalReportSection(title: "01 / 净资产历史", detail: currency) {
                HStack(spacing: 0) {
                    trendChoice("月末", value: true)
                    trendChoice("每日", value: false)
                }.padding(.vertical, 8)
                if !session.amountsVisible {
                    Text("金额已隐藏").terminalFont(size: 12).frame(minHeight: 156)
                } else if points.isEmpty {
                    Text("所选范围暂无净值趋势").terminalFont(size: 12).padding(.vertical, 24)
                } else {
                    let axis = LedgerChartAxis(labels: points.map(\.date), referenceLabel: session.selectedRange.start)
                    Chart(Array(points.enumerated()), id: \.element.id) { index, point in
                        LineMark(x: .value("日期", axis.position(at: index)), y: .value("净资产", Double(point.netWorth) / 100))
                            .foregroundStyle(TerminalPalette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("日期", axis.position(at: index)), y: .value("净资产", Double(point.netWorth) / 100))
                            .foregroundStyle(TerminalPalette.accent).symbolSize(10)
                    }
                    .chartXScale(domain: axis.domain)
                    .chartXAxis {
                        AxisMarks(values: axis.tickPositions(maxCount: 4)) { value in
                            AxisGridLine().foregroundStyle(TerminalPalette.line)
                            AxisValueLabel {
                                if let position = value.as(Double.self) {
                                    Text(axis.shortLabel(nearestTo: position)).font(.system(size: 10, design: .monospaced))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(TerminalPalette.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TerminalPalette.secondary)
                            }
                        }
                    }
                }
                    .frame(height: 156).padding(.vertical, 12)
                    .accessibilityIdentifier("terminal-assets-chart")
                    DisclosureGroup("查看历史数据", isExpanded: $showsHistory) {
                        ForEach(points) { point in
                            TerminalReportRow(title: point.date, detail: "净资产", amount: point.netWorth, currency: currency)
                        }
                    }.terminalFont(size: 12).tint(TerminalPalette.accent).padding(.bottom, 12)
                }
            }
            TerminalReportSection(title: "02 / 资产负债构成", detail: "当前估值") {
                composition("资产", amount: assets)
                composition("负债", amount: debt)
                Text("占比以资产与负债绝对值之和为基数。净资产 = 资产 − 负债。")
                    .terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary).padding(.vertical, 8)
            }
            TerminalReportSection(title: "03 / 账户明细", detail: "当前 / 期间变化") {
                ForEach(accountNames, id: \.self) { account in
                    Button { session.navigateToTransactions(account: account) } label: {
                        accountRow(account)
                    }.buttonStyle(.plain)
                }
            }
            TerminalReportSection(title: "04 / 币种与折算", detail: currency) {
                ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(labels[balance.account] ?? balance.account).terminalFont(size: 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TerminalAmount(minorUnits: balance.amount, currency: balance.currency, size: 13, showsCurrency: true)
                        }
                        HStack {
                            Text(balance.currency + " → " + balance.valuationCurrency).terminalFont(size: 11)
                            Spacer()
                            if balance.valuationMissing == true {
                                Text("缺少价格").terminalFont(size: 11).foregroundStyle(TerminalPalette.accent)
                            } else {
                                TerminalAmount(minorUnits: balance.valuation, currency: balance.valuationCurrency, size: 12, showsCurrency: true)
                            }
                        }.foregroundStyle(TerminalPalette.secondary)
                    }.padding(.vertical, 12).overlay(alignment: .bottom) { TerminalRule() }
                }
                Text("折算采用账本提供的估值。价格日期与来源未提供时不作推断；内部转账不计入收支。")
                    .terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary).padding(.vertical, 12)
            }
        }
    }

    private func trendChoice(_ title: String, value: Bool) -> some View {
        Button { monthEnd = value } label: {
            Text(title).terminalFont(size: 13, weight: monthEnd == value ? .semibold : .regular)
                .foregroundStyle(monthEnd == value ? TerminalPalette.accent : TerminalPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(monthEnd == value ? TerminalPalette.accent : TerminalPalette.line)
                        .frame(height: monthEnd == value ? 2 : 1)
                }
        }.buttonStyle(.plain).accessibilityAddTraits(monthEnd == value ? .isSelected : [])
    }

    private func composition(_ label: String, amount: Int) -> some View {
        HStack(spacing: 12) {
            Text(label).terminalFont(size: 12)
            GeometryReader { geometry in
                Rectangle().fill(TerminalPalette.line)
                if session.amountsVisible {
                    Rectangle().fill(label == "资产" ? TerminalPalette.accent : TerminalPalette.secondary)
                        .frame(width: geometry.size.width * min(1, max(0, Double(amount) / max(1, Double(abs(assets)) + Double(debt)))))
                }
            }.frame(height: 4)
            TerminalAmount(minorUnits: amount, currency: currency, size: 13)
        }.padding(.vertical, 12)
    }
    private func accountRow(_ account: String) -> some View {
        let rows = balances.filter { $0.account == account }
        let unavailable = rows.contains { $0.valuationMissing == true }
        let periodAvailable = rows.allSatisfy { $0.periodAvailable == true && $0.periodValuationMissing != true && $0.periodValuationChange != nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(labels[account] ?? account).terminalFont(size: 14, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if unavailable {
                    Text("缺少价格").terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
                } else {
                    TerminalAmount(minorUnits: valuations[account] ?? 0, currency: currency, size: 13)
                }
            }
            HStack(alignment: .top) {
                Text(account).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                Spacer(minLength: 8)
                if periodAvailable {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("期间变化").terminalFont(size: 11)
                        TerminalAmount(minorUnits: rows.reduce(0) { $0 + ($1.periodValuationChange ?? 0) }, currency: currency, size: 11)
                    }
                } else { Text("暂无期间变化").terminalFont(size: 11) }
            }.foregroundStyle(TerminalPalette.secondary)
        }.padding(.vertical, 12).contentShape(Rectangle())
            .overlay(alignment: .bottom) { TerminalRule() }
    }
}

struct TerminalInvestmentsReport: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerInvestmentSummary

    private var totalCost: Int? {
        guard !data.holdings.isEmpty, data.holdings.allSatisfy({ $0.totalCostValueCny != nil }) else { return nil }
        return data.holdings.reduce(0) { $0 + ($1.totalCostValueCny ?? 0) }
    }
    private var unrealized: Int? {
        guard let totalCost, data.holdings.allSatisfy({ $0.totalMarketValueCny != nil }) else { return nil }
        return data.totalMarketValueCny - totalCost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalReportGrid {
                TerminalReportMetric(title: "持仓市值", amount: data.totalMarketValueCny, currency: "CNY", note: "当前估值 / CNY")
                TerminalReportMetric(title: "持仓成本", amount: totalCost, currency: "CNY", note: "缺失成本时不估算")
                TerminalReportMetric(title: "浮动收益", amount: unrealized, currency: "CNY", note: "市值减持仓成本")
                TerminalReportMetric(title: "已实现收益", amount: data.realizedPnlCny, currency: "CNY", note: "所选期间 / CNY")
            }
            TerminalReportSection(title: "01 / 当前持仓", detail: "\(data.holdings.count) 个品种") {
                if data.holdings.isEmpty {
                    Text("暂无投资持仓").terminalFont(size: 13).padding(.vertical, 24)
                }
                ForEach(data.holdings) { holding in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(holding.commodityName.isEmpty ? holding.commodity : holding.commodityName)
                                .terminalFont(size: 14, weight: .medium)
                            Spacer()
                            if let market = holding.totalMarketValueCny {
                                TerminalAmount(minorUnits: market, currency: "CNY", size: 14)
                            } else {
                                Text("缺少估值").terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
                            }
                        }
                        Text(holding.commodity + " · " + (session.amountsVisible ? holding.totalQuantity.formatted() : "••••") + " · \(holding.accountCount) 个账户")
                            .terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
                        if let cost = holding.totalCostValueCny {
                            HStack {
                                Text("成本").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                                TerminalAmount(minorUnits: cost, currency: "CNY", size: 12)
                                Spacer()
                                if let market = holding.totalMarketValueCny {
                                    Text("浮动").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                                    TerminalAmount(minorUnits: market - cost, currency: "CNY", color: market >= cost ? TerminalPalette.positive : TerminalPalette.negative, size: 12)
                                }
                            }
                        } else {
                            Text("成本缺失").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                        }
                    }.padding(.vertical, 12)
                    TerminalRule()
                }
            }
            TerminalReportSection(title: "02 / 账户持仓", detail: "\(data.positions.count) 项") {
                ForEach(data.positions) { position in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(position.accountLabel.isEmpty ? position.account : position.accountLabel)
                            .terminalFont(size: 13, weight: .medium)
                        HStack {
                            Text(position.commodity + " · " + (session.amountsVisible ? position.quantity.formatted() : "••••"))
                                .terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
                            Spacer()
                            if let market = position.marketValueCny {
                                TerminalAmount(minorUnits: market, currency: "CNY", size: 13)
                            } else {
                                Text("缺少估值").terminalFont(size: 11).foregroundStyle(TerminalPalette.accent)
                            }
                        }
                    }.padding(.vertical, 12)
                    TerminalRule()
                }
                if data.positions.isEmpty { Text("暂无账户持仓明细").terminalFont(size: 13).padding(.vertical, 24) }
            }
        }.foregroundStyle(TerminalPalette.ink)
    }
}
