import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession

    var isRoot = true

    var body: some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        List {
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }

            if let ledger = session.ledger {
                Section {
                    MonthlyConclusion(ledger: ledger, range: session.selectedRange)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    ForEach(Array(ledger.transactions.prefix(6))) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction, accountLabels: accountLabels)
                        }
                    }
                    if ledger.transactions.isEmpty {
                        Text("所选范围暂无流水").foregroundStyle(.secondary)
                    }
                    Button("查看全部流水") {
                        session.primaryDestinationID = LedgerDestination.transactions.rawValue
                    }
                } header: {
                    Text("最近流水")
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                }
            } else {
                EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: "暂无财务数据", detail: "下拉刷新重新读取账本。")
            }
        }
        .ledgerReadingList()
        .ledgerNavigation("财务概览", isRoot: isRoot, showsTimeRange: true)
        .refreshable { await session.refresh() }
    }
}

private struct MonthlyConclusion: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let ledger: LedgerBootstrap
    let range: LedgerDateRange

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(range.metricScope)结论").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(ledger.transactions.count) 笔").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            netMetric
            Divider().padding(.horizontal, 16)
            if dynamicTypeSize.isAccessibilitySize {
                incomeMetric
                expenseMetric
            } else {
                HStack(alignment: .top, spacing: 0) {
                    incomeMetric
                    expenseMetric
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
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
            AmountLabel(
                minorUnits: minorUnits,
                currency: currency,
                font: primary ? .title2.weight(.semibold) : .subheadline.weight(.semibold),
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
                    .font(.system(.caption2, design: .default))
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
            .font(.system(.caption2, design: .default, weight: .medium))
            .foregroundStyle(LedgerPalette.secondary)
    }

    private var comparisonValue: some View {
        Text(valueText)
            .font(.system(.caption2, design: .default, weight: .semibold).monospacedDigit())
            .foregroundStyle(valueColor)
            .fixedSize(horizontal: false, vertical: true)
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
