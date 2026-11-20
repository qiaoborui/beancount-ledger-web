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
    var note: String = String(localized: "所选期间")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
            if let amount {
                TerminalAmount(minorUnits: amount, currency: currency, size: 17)
            } else {
                Text(value ?? String(localized: "暂无数据")).terminalFont(size: 17, weight: .medium, design: .monospaced)
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
                            .foregroundStyle(BalancedPalette.chartAccent).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("月份", point.month), y: .value("结余", Double(point.net) / 100))
                            .foregroundStyle(BalancedPalette.chartAccent).symbolSize(14)
                    } else {
                        BarMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / 100))
                            .position(by: .value("类别", "收入")).foregroundStyle(BalancedPalette.chartAccent)
                        BarMark(x: .value("月份", point.month), y: .value("支出", Double(point.expense) / 100))
                            .position(by: .value("类别", "支出")).foregroundStyle(BalancedPalette.chartExpense)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(TerminalPalette.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(LedgerLocale.current)))
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
                        legend(String(localized: "收入"), color: TerminalPalette.ink)
                        legend(String(localized: "支出"), color: TerminalPalette.accent)
                    }
                }
                DisclosureGroup("查看数据 · \(currency)", isExpanded: $showsData) {
                    ForEach(points) { point in
                        TerminalReportRow(title: point.month,
                            detail: netOnly ? String(localized: "结余") : String(localized: "收入 / 支出"),
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
        Text(title).balancedFont(size: 15, weight: .medium).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
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
                    // Same as each row: the share column is a ratio, so it hides with the amounts.
                    Text(session.amountsVisible ? "100%" : "—").balancedFont(size: 14.5, weight: .semibold).monospacedDigit().foregroundStyle(BalancedPalette.secondary)
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
                BalancedAnalysisMetric(title: String(localized: "收入"), minorUnits: statement.totalIncome, currency: currency, sub: currency + String(localized: " · 所选区间"))
                    .overlay(alignment: .trailing) { BalancedPalette.rule.frame(width: 1) }
                BalancedAnalysisMetric(title: String(localized: "支出"), minorUnits: statement.totalExpense, currency: currency, sub: currency + String(localized: " · 所选区间"))
            }.overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            HStack(spacing: 0) {
                BalancedAnalysisMetric(title: String(localized: "净结余"), minorUnits: statement.netIncome, currency: currency, prefix: netPrefix, color: netColor, sub: String(localized: "收入 − 支出"))
                    .overlay(alignment: .trailing) { BalancedPalette.rule.frame(width: 1) }
                BalancedAnalysisMetric(title: String(localized: "日均支出"), minorUnits: dailyAverageExpense, currency: currency, sub: String(localized: "\(dayCount) 天"))
            }
        }
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    // MARK: Charts (`.chart`, `.chart-foot`, `.disclose`)

    private var monthlyChart: some View {
        let points = data.dashboard.cashflowSeries
        return VStack(alignment: .leading, spacing: 0) {
            balancedSechead(BalancedBucketAxis.title(points.map(\.month)), aside: currency)
            if !session.amountsVisible {
                Text("金额已隐藏").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).frame(maxWidth: .infinity, minHeight: 140)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
            } else {
                Chart(points) { point in
                    BarMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / 100))
                        .position(by: .value("类别", "收入")).foregroundStyle(BalancedPalette.chartAccent)
                    BarMark(x: .value("月份", point.month), y: .value("支出", Double(point.expense) / 100))
                        .position(by: .value("类别", "支出")).foregroundStyle(BalancedPalette.chartExpense)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(BalancedPalette.rule)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(LedgerLocale.current)))
                                .balancedFont(size: 10).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                } }
                .chartXAxis { BalancedBucketAxis.marks(for: points.map(\.month)) }
                .chartLegend(.hidden)
                .frame(height: 156)
                .padding(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                .accessibilityLabel(BalancedBucketAxis.title(points.map(\.month))).accessibilityIdentifier("balanced-cashflow-chart")
                HStack(spacing: 20) {
                    legendKey(String(localized: "收入"), color: BalancedPalette.chartAccent)
                    legendKey(String(localized: "支出"), color: BalancedPalette.chartExpense)
                }.padding(EdgeInsets(top: 10, leading: 20, bottom: 6, trailing: 20))
                Text(BalancedBucketAxis.footnote(points.map(\.month))).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
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
            balancedSechead(String(localized: "净结余趋势"), aside: currency)
            if !session.amountsVisible {
                Text("金额已隐藏").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).frame(maxWidth: .infinity, minHeight: 120)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
            } else {
                Chart(points) { point in
                    LineMark(x: .value("月份", point.month), y: .value("净结余", Double(point.net) / 100))
                        .foregroundStyle(BalancedPalette.chartAccent).lineStyle(StrokeStyle(lineWidth: 1.6))
                    PointMark(x: .value("月份", point.month), y: .value("净结余", Double(point.net) / 100))
                        .foregroundStyle(BalancedPalette.chartAccent).symbolSize(16)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(BalancedPalette.rule)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(LedgerLocale.current)))
                                .balancedFont(size: 10).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                } }
                .chartXAxis { BalancedBucketAxis.marks(for: points.map(\.month)) }
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
                Text("支出构成").balancedFont(size: 15, weight: .medium).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(session.amountsVisible ? MoneyText.format(minorUnits: statement.totalExpense, currency: currency, showsCurrency: false) : "••••••")
                        .balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                    Text(currency).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                }
            }.padding(EdgeInsets(top: 26, leading: 20, bottom: 10, trailing: 20))
            if statement.expenseAnalytics.isEmpty {
                empty(String(localized: "所选区间暂无支出"))
            } else {
                BalancedAnalysisTable(rows: statement.expenseAnalytics.prefix(5).map { item in
                    .init(id: item.id, label: item.label, detail: String(localized: "\(item.txCount) 笔"), minorUnits: item.amount,
                        share: item.share ?? share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(kind: .expense, account: item.account) })
                }, currency: currency, total: (String(localized: "合计"), statement.totalExpense))
            }
            Text("占比按所选区间重算，不引用历史缓存。").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                .padding(EdgeInsets(top: 12, leading: 20, bottom: 20, trailing: 20))
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var payeesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead(String(localized: "支出商户"), aside: String(localized: "按金额"))
            if statement.topPayees.isEmpty {
                empty(String(localized: "暂无商户数据"))
            } else {
                BalancedAnalysisTable(rows: statement.topPayees.prefix(6).map { item in
                    .init(id: item.id, label: item.payee, detail: String(localized: "\(item.txCount) 笔"), minorUnits: item.amount, share: share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(query: item.payee) })
                }, currency: currency)
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var fundingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead(String(localized: "资金来源"), aside: String(localized: "支出账户"))
            if statement.topPaymentAccounts.isEmpty {
                empty(String(localized: "暂无支出账户数据"))
            } else {
                BalancedAnalysisTable(rows: statement.topPaymentAccounts.prefix(6).map { item in
                    .init(id: item.id, label: item.label, detail: String(localized: "\(item.txCount) 笔"), minorUnits: item.amount, share: share(item.amount, total: statement.totalExpense),
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
            balancedSechead(incomeCategories ? String(localized: "收入分类") : String(localized: "支出分类明细"), aside: String(localized: "按分类"))
            HStack(spacing: 22) {
                categoryTab(String(localized: "支出"), income: false)
                categoryTab(String(localized: "收入"), income: true)
            }.padding(.horizontal, 20).overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            if incomeCategories {
                if statement.income.isEmpty {
                    empty(String(localized: "暂无收入分类"))
                } else {
                    BalancedAnalysisTable(rows: statement.income.map { node in
                        .init(id: node.id, label: node.label, detail: String(localized: "\(node.txCount) 笔"), minorUnits: node.amount,
                            share: share(node.amount, total: statement.totalIncome),
                            action: { session.navigateToTransactions(kind: .income, account: node.account) })
                    }, currency: currency)
                }
            } else if statement.expenseAnalytics.isEmpty {
                empty(String(localized: "暂无支出分类"))
            } else {
                BalancedAnalysisTable(rows: statement.expenseAnalytics.map { item in
                    .init(id: item.id, label: item.label, detail: String(localized: "\(item.txCount) 笔") + categoryChange(item.changeRatio), minorUnits: item.amount,
                        share: share(item.amount, total: statement.totalExpense),
                        action: { session.navigateToTransactions(kind: .expense, account: item.account) })
                }, currency: currency)
            }
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            balancedSechead(String(localized: "事件与项目"), aside: String(localized: "独立核算"))
            if session.isLocal, let error = session.localEventTagSummaryError {
                Text(error).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(.horizontal, 20)
                Button("重试事件汇总") { Task { await session.loadLocalEventTagSummaries(force: true) } }
                    .balancedFont(size: 12.5).foregroundStyle(BalancedPalette.ink).padding(.horizontal, 20).frame(minHeight: 44)
            } else if session.isLocal && session.localEventTagSummaries == nil {
                ProgressView("正在统计事件与项目…").padding(.horizontal, 20).padding(.vertical, 12)
            }
            if events.isEmpty {
                empty(String(localized: "暂无事件与项目"))
            } else {
                BalancedAnalysisTable(rows: events.prefix(3).map { event in
                    .init(id: event.tag, label: "#" + event.tag, detail: String(localized: "\(event.transactionCount) 笔"), minorUnits: event.netSpend, share: nil,
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
            balancedSechead(String(localized: "账户明细"), aside: currency)
            accountNodes(statement.income, kind: .income)
            accountNodes(statement.expense, kind: .expense)
        }.overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private var anomaliesSection: some View {
        let anomalies = data.dashboard.anomalies
        return VStack(alignment: .leading, spacing: 0) {
            balancedSechead(String(localized: "异常与提示"), aside: String(localized: "\(anomalies.count) 条"))
            if anomalies.isEmpty {
                empty(String(localized: "区间内未发现异常交易"))
            } else {
                ForEach(anomalies.prefix(6)) { item in
                    Button { session.navigateToTransactions(account: item.account) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.payee.isEmpty ? item.narration : item.payee)
                                .balancedFont(size: 15.5, weight: .text).foregroundStyle(BalancedPalette.ink).lineLimit(1)
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
        return String(localized: " · 较上期 ") + ratio.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
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
                TerminalReportMetric(title: String(localized: "持仓市值"), amount: data.totalMarketValueCny, currency: "CNY", note: String(localized: "当前估值 / CNY"))
                TerminalReportMetric(title: String(localized: "持仓成本"), amount: totalCost, currency: "CNY", note: String(localized: "缺失成本时不估算"))
                TerminalReportMetric(title: String(localized: "浮动收益"), amount: unrealized, currency: "CNY", note: String(localized: "市值减持仓成本"))
                TerminalReportMetric(title: String(localized: "已实现收益"), amount: data.realizedPnlCny, currency: "CNY", note: String(localized: "所选期间 / CNY"))
            }
            TerminalReportSection(title: String(localized: "01 / 当前持仓"), detail: String(localized: "\(data.holdings.count) 个品种")) {
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
                        Text(holding.commodity + " · " + (session.amountsVisible ? holding.totalQuantity.formatted() : "••••") + String(localized: " · \(holding.accountCount) 个账户"))
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
            TerminalReportSection(title: String(localized: "02 / 账户持仓"), detail: String(localized: "\(data.positions.count) 项")) {
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


/// Axis for the income/expense series. The server buckets by day (≤45
/// days, "08-01"), week ("08-01~08-07"), month ("2026-08") or quarter
/// ("2026-Q1"). `.automatic` printed every daily "08-01" label in the system
/// face or dropped arbitrary months. Labels now thin to an even stride and
/// read "8/1", "8月" or "26 Q1", with the year at January or where the range
/// starts in another year.
@MainActor
extension BalancedBucketAxis {
    @AxisContentBuilder
    static func marks(for labels: [String]) -> some AxisContent {
        let shown = labelled(labels)
        let years = Set(labels.compactMap { $0.split(separator: "-").first }.filter { $0.count == 4 })
        // A category axis ignores an explicit `values:` list and labels every
        // bucket, so unlabelled buckets render an empty label instead.
        AxisMarks { value in
            AxisValueLabel(centered: true, collisionResolution: .disabled) {
                if let raw = value.as(String.self), shown.contains(raw) {
                    Text(label(raw, showsYear: years.count > 1 && raw == shown.first))
                        .balancedFont(size: 11).monospacedDigit()
                        .foregroundStyle(BalancedPalette.secondary).fixedSize()
                }
            }
        }
    }
}
