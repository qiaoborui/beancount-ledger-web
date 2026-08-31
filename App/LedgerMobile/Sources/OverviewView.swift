import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var usesRegularLayout: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                if let ledger = session.ledger {
                    ScrollView {
                        LazyVStack(spacing: usesRegularLayout ? LedgerSpacing.xl : 0) {
                            if usesRegularLayout {
                                HStack(alignment: .bottom, spacing: LedgerSpacing.xl) {
                                    overviewIntro
                                    LedgerTimeRangeControl()
                                        .frame(width: 420)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                                    overviewIntro
                                    LedgerTimeRangeControl()
                                }
                                .padding(LedgerSpacing.lg)
                                .background(LedgerPalette.panel)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(LedgerPalette.line).frame(height: 1)
                                }
                                .padding(.bottom, LedgerSpacing.lg)
                            }

                            if let error = session.errorMessage {
                                StatusBanner(message: error, onDismiss: session.dismissError)
                                    .padding(.horizontal, usesRegularLayout ? 0 : LedgerSpacing.lg)
                                    .padding(.bottom, usesRegularLayout ? 0 : LedgerSpacing.lg)
                            }

                            MonthlyConclusion(
                                ledger: ledger,
                                range: session.selectedRange,
                                regular: usesRegularLayout
                            )
                            .padding(.horizontal, usesRegularLayout ? 0 : LedgerSpacing.lg)
                            .padding(.bottom, usesRegularLayout ? 0 : LedgerSpacing.lg)

                            if usesRegularLayout {
                                RecentTransactionsSection(
                                    transactions: Array(ledger.transactions.prefix(6)),
                                    regular: true
                                )
                            } else {
                                RecentTransactionsSection(
                                    transactions: Array(ledger.transactions.prefix(6)),
                                    regular: false
                                )
                                .padding(.horizontal, LedgerSpacing.lg)
                            }
                        }
                        .ledgerAdaptivePageWidth()
                        .padding(.vertical, usesRegularLayout ? LedgerSpacing.xl : 0)
                        .padding(
                            .bottom,
                            usesRegularLayout ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance
                        )
                    }
                    .refreshable { await session.refresh() }
                } else {
                    EmptyLedgerState(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "暂无财务数据",
                        detail: "下拉刷新后重新读取所选范围。"
                    )
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var overviewIntro: some View {
        LedgerPageIntro(
            title: "财务概览",
            detail: "查看所选范围的结余、环比、同比与最近流水。",
            meta: session.selectedRange.metricScope,
            style: .inline
        ) {
            EmptyView()
        }
    }
}

private struct MonthlyConclusion: View {
    let ledger: LedgerBootstrap
    let range: LedgerDateRange
    let regular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionIntro(
                title: "\(range.metricScope)结论",
                detail: "聚焦所选范围现金流结果与同期变化。"
            )
            horizontalDivider
            metricGrid
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var metricGrid: some View {
        if regular {
            HStack(spacing: 0) {
                netMetric
                verticalDivider
                incomeMetric
                verticalDivider
                expenseMetric
                verticalDivider
                TransactionCountMetric(count: ledger.transactions.count)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    netMetric
                    verticalDivider
                    incomeMetric
                }
                horizontalDivider
                HStack(spacing: 0) {
                    expenseMetric
                    verticalDivider
                    TransactionCountMetric(count: ledger.transactions.count)
                }
            }
        }
    }

    private var netMetric: some View {
        OverviewPeriodMetric(
            label: "\(range.metricScope)结余",
            minorUnits: ledger.summary.net,
            currency: ledger.summary.currency,
            detail: "收入减去支出",
            color: ledger.summary.net < 0 ? LedgerPalette.risk : LedgerPalette.ink,
            primary: true,
            comparisons: netComparisons,
            metric: .net,
            showsMonthOverMonth: false
        )
    }

    private var incomeMetric: some View {
        OverviewPeriodMetric(
            label: "\(range.metricScope)收入",
            minorUnits: ledger.summary.income,
            currency: ledger.summary.currency,
            detail: "当前范围汇总",
            color: LedgerPalette.income,
            comparisons: ledger.comparisons?.income,
            metric: .income
        )
    }

    private var expenseMetric: some View {
        OverviewPeriodMetric(
            label: "\(range.metricScope)支出",
            minorUnits: ledger.summary.expense,
            currency: ledger.summary.currency,
            detail: "当前范围汇总",
            color: LedgerPalette.expense,
            comparisons: ledger.comparisons?.expense,
            metric: .expense
        )
    }

    private var netComparisons: LedgerMetricPeriodComparisons? {
        guard let comparisons = ledger.comparisons else { return nil }
        return LedgerMetricPeriodComparisons(
            monthOverMonth: netComparison(
                income: comparisons.income.monthOverMonth,
                expense: comparisons.expense.monthOverMonth
            ),
            yearOverYear: netComparison(
                income: comparisons.income.yearOverYear,
                expense: comparisons.expense.yearOverYear
            )
        )
    }

    private func netComparison(
        income: LedgerPeriodComparison,
        expense: LedgerPeriodComparison
    ) -> LedgerPeriodComparison {
        let current = combinedNet(income.current, expense.current)
        let baseline = combinedNet(income.baseline, expense.baseline)
        let delta = current.flatMap { currentValue in
            baseline.map { currentValue - $0 }
        }
        let percentage = delta.flatMap { deltaValue in
            baseline.flatMap { baselineValue in
                baselineValue == 0 ? nil : Double(deltaValue) / Double(abs(baselineValue))
            }
        }
        return LedgerPeriodComparison(
            currentRange: income.currentRange,
            baselineRange: income.baselineRange,
            current: current,
            baseline: baseline,
            delta: delta,
            percentage: percentage
        )
    }

    private func combinedNet(_ income: Int?, _ expense: Int?) -> Int? {
        guard let income, let expense else { return nil }
        return income - expense
    }

    private var verticalDivider: some View {
        Divider().overlay(LedgerPalette.line)
    }

    private var horizontalDivider: some View {
        Divider().overlay(LedgerPalette.line)
    }
}

private struct TransactionCountMetric: View {
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text("交易笔数")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            Text(String(count))
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .tracking(-0.35)
                .foregroundStyle(LedgerPalette.ink)
            Text("当前范围记录")
                .font(.system(size: 11))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(LedgerSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(LedgerPalette.panel)
    }
}

private enum OverviewComparisonMetric: Equatable {
    case income
    case expense
    case net
}

private struct OverviewPeriodMetric: View {
    let label: String
    let minorUnits: Int
    let currency: String
    let detail: String
    var color = LedgerPalette.ink
    var primary = false
    let comparisons: LedgerMetricPeriodComparisons?
    let metric: OverviewComparisonMetric
    var showsMonthOverMonth = true

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            AmountLabel(
                minorUnits: minorUnits,
                currency: currency,
                font: .system(size: primary ? 24 : 18, weight: .semibold),
                color: color
            )
            .tracking(primary ? -0.65 : -0.35)
            .lineLimit(1)

            if let comparisons {
                Divider().overlay(LedgerPalette.line)
                if showsMonthOverMonth {
                    OverviewComparisonRow(
                        label: "环比",
                        comparison: comparisons.monthOverMonth,
                        currency: currency,
                        metric: metric
                    )
                }
                OverviewComparisonRow(
                    label: "同比",
                    comparison: comparisons.yearOverYear,
                    currency: currency,
                    metric: metric
                )
            } else {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(2)
            }
        }
        .padding(LedgerSpacing.lg)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(LedgerPalette.panel)
    }
}

private struct OverviewComparisonRow: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let label: String
    let comparison: LedgerPeriodComparison
    let currency: String
    let metric: OverviewComparisonMetric

    var body: some View {
        comparisonContent
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var comparisonContent: some View {
        if horizontalSizeClass == .compact {
            VStack(alignment: .leading, spacing: 2) {
                comparisonLabel
                comparisonValue
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                comparisonLabel
                Spacer(minLength: 0)
                comparisonValue
            }
        }
    }

    private var comparisonLabel: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(LedgerPalette.secondary)
    }

    private var comparisonValue: some View {
        Text(valueText)
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(valueColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var valueText: String {
        guard session.amountsVisible else { return "••••••" }
        guard let delta = comparison.delta else { return "暂无" }
        let arrow = delta > 0 ? "↑" : delta < 0 ? "↓" : "→"
        let amount = MoneyText.formatCompact(minorUnits: delta, currency: currency, showSign: true)
        guard let percentage = comparison.percentage else { return "\(arrow) \(amount) · —" }
        let sign = percentage > 0 ? "+" : ""
        return "\(arrow) \(amount) · \(sign)\(String(format: "%.1f", percentage * 100))%"
    }

    private var valueColor: Color {
        guard session.amountsVisible, let delta = comparison.delta, delta != 0 else {
            return LedgerPalette.secondary
        }
        let favorable = metric == .expense ? delta < 0 : delta > 0
        return favorable ? LedgerPalette.income : LedgerPalette.risk
    }

    private var accessibilityText: String {
        "\(label)，\(valueText)，当前 \(comparison.currentRange.start) 至 \(comparison.currentRange.end)，对比 \(comparison.baselineRange.start) 至 \(comparison.baselineRange.end)"
    }
}

private struct SectionIntro: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(LedgerPalette.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerSpacing.lg)
    }
}

private struct RecentTransactionsSection: View {
    let transactions: [LedgerTransaction]
    let regular: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionIntro(
                title: "最近流水",
                detail: transactions.isEmpty ? "所选范围暂无流水。" : "按日期显示最近的账本记录。"
            )
            Divider().overlay(LedgerPalette.line)

            if transactions.isEmpty {
                Text("所选范围暂无流水")
                    .font(.system(size: 13))
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(LedgerSpacing.lg)
            } else {
                ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                            .padding(.horizontal, LedgerSpacing.lg)
                    }
                    .buttonStyle(.plain)

                    if index < transactions.count - 1 {
                        Divider()
                            .overlay(LedgerPalette.line)
                            .padding(.leading, 72)
                    }
                }
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }
}
