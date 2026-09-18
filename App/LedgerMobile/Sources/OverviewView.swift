import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @State private var creatingTransaction = false

    var isRoot = true

    var body: some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        List {
            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }

            if let ledger = session.ledger {
                // 1. Monthly Overview Hero Card
                Section {
                    MonthlyConclusion(ledger: ledger, range: session.selectedRange)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                // 2. Quick Actions Dock
                Section {
                    OverviewQuickActionsBar(
                        onAddTransaction: {
                            if session.isLocal {
                                creatingTransaction = true
                            } else {
                                session.primaryDestinationID = LedgerDestination.transactions.rawValue
                            }
                        },
                        onImport: {
                            session.primaryDestinationID = LedgerDestination.imports.rawValue
                        },
                        onIncomeExpense: {
                            session.primaryDestinationID = LedgerDestination.incomeExpense.rawValue
                        },
                        onAssets: {
                            session.primaryDestinationID = LedgerDestination.accounts.rawValue
                        }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }


                // 3. Top Spending Categories
                let topCategories = spendingCategories(from: ledger.transactions, accountLabels: accountLabels)
                if !topCategories.isEmpty {
                    Section {
                        OverviewTopCategoriesCard(
                            categories: topCategories,
                            totalExpense: ledger.summary.expense,
                            currency: ledger.summary.currency
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } header: {
                        HStack {
                            Text("当月支出排行")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                            Spacer()
                            Text("Top 分类")
                                .font(.caption2)
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .textCase(nil)
                    }
                }

                // 4. Financial Rhythm & Pace
                if ledger.summary.expense > 0 {
                    Section {
                        OverviewSpendingRhythmCard(
                            ledger: ledger,
                            range: session.selectedRange
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    } header: {
                        Text("消费节奏")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                            .textCase(nil)
                    }
                }

                // 5. Recent Transactions
                Section {
                    ForEach(Array(ledger.transactions.prefix(6))) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction, accountLabels: accountLabels)
                        }
                        .ledgerTransactionActions(transaction)
                    }
                    if ledger.transactions.isEmpty {
                        Text("所选范围暂无流水").foregroundStyle(.secondary)
                    }
                    Button {
                        session.primaryDestinationID = LedgerDestination.transactions.rawValue
                    } label: {
                        HStack {
                            Text("查看全部流水")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LedgerPalette.cobalt)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("最近流水")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .textCase(nil)
                }
            } else {
                EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: "暂无财务数据", detail: "下拉刷新重新读取账本。")
            }
        }
        .ledgerReadingList()
        .ledgerNavigation("财务概览", isRoot: isRoot, showsTimeRange: true)
        .refreshable { await session.refresh() }
        .sheet(isPresented: $creatingTransaction) {
            TransactionEditorView(
                accounts: session.ledger?.accounts ?? [],
                commodities: session.ledger?.commodities ?? []
            ) { entry in
                try await session.addLocalTransaction(entry)
            }
            .ledgerPrivacyProtectedSheet()
        }
    }

    private func spendingCategories(
        from transactions: [LedgerTransaction],
        accountLabels: [String: String]
    ) -> [OverviewCategorySpending] {
        var categoryTotals: [String: (label: String, icon: String, color: Color, amount: Int, count: Int)] = [:]

        for tx in transactions {
            let expensePostings = tx.postings.filter { $0.account.hasPrefix("Expenses:") && $0.amount != 0 }
            guard !expensePostings.isEmpty else { continue }
            let presentation = TransactionPresentation(transaction: tx)
            let visual = TransactionVisualCategory.resolve(
                transaction: tx,
                presentation: presentation,
                accountLabels: accountLabels
            )
            let txExpense = expensePostings.reduce(0) { $0 + $1.amount }

            if var existing = categoryTotals[visual.categoryLabel] {
                existing.amount += txExpense
                if txExpense > 0 {
                    existing.count += 1
                }
                categoryTotals[visual.categoryLabel] = existing
            } else {
                categoryTotals[visual.categoryLabel] = (
                    label: visual.categoryLabel,
                    icon: visual.iconName,
                    color: visual.color,
                    amount: txExpense,
                    count: txExpense > 0 ? 1 : 0
                )
            }
        }

        let positiveCategories = categoryTotals.values.filter { $0.amount > 0 }
        let overallExpense = positiveCategories.reduce(0) { $0 + $1.amount }
        guard overallExpense > 0 else { return [] }

        return positiveCategories
            .sorted { $0.amount > $1.amount }
            .prefix(4)
            .map { item in
                OverviewCategorySpending(
                    id: item.label,
                    label: item.label,
                    iconName: item.icon,
                    color: item.color,
                    totalMinorUnits: item.amount,
                    count: max(1, item.count),
                    percentage: Double(item.amount) / Double(overallExpense)
                )
            }
    }
}

private struct OverviewQuickActionsBar: View {
    let onAddTransaction: () -> Void
    let onImport: () -> Void
    let onIncomeExpense: () -> Void
    let onAssets: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            QuickActionButton(
                title: "记账",
                icon: "plus",
                isProminent: true,
                action: onAddTransaction
            )
            .frame(maxWidth: .infinity)

            QuickActionButton(
                title: "导入",
                icon: "arrow.down.doc",
                isProminent: false,
                action: onImport
            )
            .frame(maxWidth: .infinity)

            QuickActionButton(
                title: "趋势",
                icon: "chart.xyaxis.line",
                isProminent: false,
                action: onIncomeExpense
            )
            .frame(maxWidth: .infinity)

            QuickActionButton(
                title: "资产",
                icon: "building.columns",
                isProminent: false,
                action: onAssets
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
}

private struct QuickActionButton: View {
    let title: String
    let icon: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            LedgerFeedback.light()
            action()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isProminent ? Color.primary : Color(uiColor: .tertiarySystemFill))
                        .frame(width: 46, height: 46)
                        .shadow(
                            color: isProminent ? Color.primary.opacity(0.16) : Color.clear,
                            radius: 6,
                            x: 0,
                            y: 2
                        )
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: isProminent ? .semibold : .medium))
                        .foregroundStyle(isProminent ? Color(uiColor: .systemBackground) : Color.primary)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.92))
    }
}

struct OverviewCategorySpending: Identifiable {
    let id: String
    let label: String
    let iconName: String
    let color: Color
    let totalMinorUnits: Int
    let count: Int
    let percentage: Double
}

private struct OverviewTopCategoriesCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession
    let categories: [OverviewCategorySpending]
    let totalExpense: Int
    let currency: String

    var body: some View {
        VStack(spacing: 11) {
            ForEach(categories) { item in
                VStack(spacing: 5) {
                    HStack(alignment: .center, spacing: 9) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(item.color.opacity(0.14))
                                .frame(width: 28, height: 28)
                            Image(systemName: item.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(item.color)
                        }

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(item.label)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("\(item.count) 笔")
                                    .font(.system(size: 10.5, weight: .regular))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            AmountLabel(
                                minorUnits: item.totalMinorUnits,
                                currency: currency,
                                font: .system(size: 13.5, weight: .semibold, design: .rounded),
                                color: LedgerPalette.ink
                            )
                            Text(String(format: "%.1f%%", item.percentage * 100))
                                .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }

                    // Continuous smooth progress track
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .frame(height: 3.5)
                            Capsule()
                                .fill(item.color)
                                .frame(
                                    width: max(3.5, min(geo.size.width, geo.size.width * CGFloat(item.percentage))),
                                    height: 3.5
                                )
                        }
                    }
                    .frame(height: 3.5)
                }
                if item.id != categories.last?.id {
                    Divider()
                        .overlay(LedgerPalette.line.opacity(0.4))
                        .padding(.top, 1)
                }
            }
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

private struct OverviewSpendingRhythmCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: LedgerSession
    let ledger: LedgerBootstrap
    let range: LedgerDateRange

    private var daysElapsed: Int {
        guard let start = LedgerDateRange.parse(range.start),
              let end = LedgerDateRange.parse(range.end) else { return 30 }
        let now = Date()
        let effectiveEnd = min(end, now)
        let days = (LedgerDateRange.calendar.dateComponents([.day], from: start, to: effectiveEnd).day ?? 0) + 1
        return max(1, days)
    }

    private var dailyAverage: Int {
        guard daysElapsed > 0 else { return 0 }
        return ledger.summary.expense / daysElapsed
    }

    private var highestExpense: (title: String, amount: Int)? {
        let expenseTx = ledger.transactions.compactMap { tx -> (String, Int)? in
            let presentation = TransactionPresentation(transaction: tx)
            guard presentation.kind == .expense, !presentation.isRefund, presentation.minorUnits > 0 else { return nil }
            return (presentation.title, presentation.minorUnits)
        }
        return expenseTx.max { $0.1 < $1.1 }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Daily average
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "sun.max")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("日均支出")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                AmountLabel(
                    minorUnits: dailyAverage,
                    currency: ledger.summary.currency,
                    font: .system(size: 16, weight: .semibold, design: .rounded),
                    color: LedgerPalette.ink
                )
                .lineLimit(1)
                Text("已过 \(daysElapsed) 天")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(LedgerPalette.line.opacity(0.5))
                .frame(width: 0.5, height: 38)
                .padding(.horizontal, 14)

            // Highest single expense
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "flame")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("单笔最高")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                if let highest = highestExpense {
                    AmountLabel(
                        minorUnits: highest.amount,
                        currency: ledger.summary.currency,
                        font: .system(size: 16, weight: .semibold, design: .rounded),
                        color: LedgerPalette.ink
                    )
                    .lineLimit(1)
                    Text(highest.title)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                } else {
                    Text("暂无支出")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("—")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.035),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LedgerPalette.cardBorder.opacity(colorScheme == .dark ? 0.35 : 0.5),
                    lineWidth: 0.5
                )
        }
    }
}

private struct MonthlyConclusion: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var session: LedgerSession

    let ledger: LedgerBootstrap
    let range: LedgerDateRange

    private var savingsRate: Double? {
        guard ledger.summary.income > 0 else { return nil }
        return Double(ledger.summary.net) / Double(ledger.summary.income)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Scope & Transaction Count
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("\(range.metricScope)概览")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                Spacer()
                Text("\(ledger.transactions.count) 笔流水")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Capsule())
            }

            // Net Metric Hero (Refined, comfortable scale)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(range.metricScope)净结余")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AmountLabel(
                        minorUnits: ledger.summary.net,
                        currency: ledger.summary.currency,
                        font: .system(size: 25, weight: .semibold, design: .rounded),
                        color: ledger.summary.net < 0 ? LedgerPalette.risk : LedgerPalette.ink
                    )
                    .tracking(-0.3)
                    .lineLimit(1)
                    .accessibilityIdentifier("overview-monthly-net")

                    primaryComparisonBadge

                    if let rate = savingsRate, session.amountsVisible {
                        Text("储蓄率 \(Int(max(0, rate * 100)))%")
                            .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(Capsule())
                    }
                }
            }

            // Hairline Divider
            Divider()
                .overlay(LedgerPalette.line.opacity(0.5))
                .padding(.vertical, 1)

            // Two-column Income & Expense Summary (Zero nested cards!)
            HStack(spacing: 0) {
                // Income Column
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(LedgerPalette.income)
                            .frame(width: 5, height: 5)
                        Text("总收入")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    AmountLabel(
                        minorUnits: ledger.summary.income,
                        currency: ledger.summary.currency,
                        font: .system(size: 15.5, weight: .semibold, design: .rounded),
                        color: LedgerPalette.income
                    )
                    .lineLimit(1)

                    if let comp = ledger.comparisons?.income.monthOverMonth {
                        compactComparison(comp, metric: .income, label: "环比")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Center Hairline
                Rectangle()
                    .fill(LedgerPalette.line.opacity(0.5))
                    .frame(width: 0.5, height: 38)
                    .padding(.horizontal, 14)

                // Expense Column
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(LedgerPalette.expense)
                            .frame(width: 5, height: 5)
                        Text("总支出")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    AmountLabel(
                        minorUnits: ledger.summary.expense,
                        currency: ledger.summary.currency,
                        font: .system(size: 15.5, weight: .semibold, design: .rounded),
                        color: LedgerPalette.ink
                    )
                    .lineLimit(1)

                    if let comp = ledger.comparisons?.expense.monthOverMonth {
                        compactComparison(comp, metric: .expense, label: "环比")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LedgerPalette.panel)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.035),
                    radius: 10,
                    x: 0,
                    y: 3
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

    private var primaryComparisonBadge: some View {
        Group {
            if let comparisons = netComparisons {
                let comp = comparisons.yearOverYear.percentage != nil ? comparisons.yearOverYear : comparisons.monthOverMonth
                if let delta = comp.delta, session.amountsVisible {
                    let favorable = delta >= 0
                    let percentText = comp.percentage.map { String(format: "%+.1f%%", $0 * 100) } ?? ""
                    let label = comp.currentRange == comparisons.yearOverYear.currentRange ? "同比" : "环比"
                    HStack(spacing: 2) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(percentText) \(label)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .foregroundStyle(favorable ? LedgerPalette.income : LedgerPalette.risk)
                    .background((favorable ? LedgerPalette.income : LedgerPalette.risk).opacity(0.12))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private func compactComparison(_ comparison: LedgerPeriodComparison, metric: OverviewComparisonMetric, label: String) -> some View {
        Group {
            if session.amountsVisible, let delta = comparison.delta, delta != 0 {
                let favorable = metric == .expense ? delta < 0 : delta > 0
                let arrow = delta > 0 ? "↑" : "↓"
                let pct = comparison.percentage.map { String(format: "%.1f%%", abs($0 * 100)) } ?? ""
                HStack(spacing: 2) {
                    Text("\(label) \(arrow)\(pct)")
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(favorable ? LedgerPalette.income : LedgerPalette.risk)
                }
            } else {
                Text("\(label) 持平")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
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
}

private enum OverviewComparisonMetric: Equatable {
    case income
    case expense
    case net
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


