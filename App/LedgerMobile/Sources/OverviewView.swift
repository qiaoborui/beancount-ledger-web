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
                            session.primaryDestinationID = LedgerDestination.assets.rawValue
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
                    } header: {
                        HStack {
                            Text("当月支出排行")
                                .font(.system(.subheadline, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer()
                            Text("Top 分类")
                                .font(.system(.caption2, design: .default, weight: .medium))
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
                    } header: {
                        HStack {
                            Text("消费节奏")
                                .font(.system(.subheadline, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.ink)
                            Spacer()
                        }
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
                    HStack {
                        Text("最近流水")
                            .font(.system(.subheadline, design: .default, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Spacer()
                    }
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
        var overallExpense: Int = 0

        for tx in transactions {
            let presentation = TransactionPresentation(transaction: tx)
            guard presentation.kind == .expense, presentation.minorUnits > 0 else { continue }
            let visual = TransactionVisualCategory.resolve(
                transaction: tx,
                presentation: presentation,
                accountLabels: accountLabels
            )
            overallExpense += presentation.minorUnits
            if var existing = categoryTotals[visual.categoryLabel] {
                existing.amount += presentation.minorUnits
                existing.count += 1
                categoryTotals[visual.categoryLabel] = existing
            } else {
                categoryTotals[visual.categoryLabel] = (
                    label: visual.categoryLabel,
                    icon: visual.iconName,
                    color: visual.color,
                    amount: presentation.minorUnits,
                    count: 1
                )
            }
        }

        guard overallExpense > 0 else { return [] }

        return categoryTotals.values
            .sorted { $0.amount > $1.amount }
            .prefix(4)
            .map { item in
                OverviewCategorySpending(
                    id: item.label,
                    label: item.label,
                    iconName: item.icon,
                    color: item.color,
                    totalMinorUnits: item.amount,
                    count: item.count,
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
        HStack(spacing: 8) {
            QuickActionItem(
                title: "记一笔",
                subtitle: "快捷记录",
                icon: "plus.circle.fill",
                tint: LedgerPalette.cobalt,
                action: onAddTransaction
            )
            QuickActionItem(
                title: "账单导入",
                subtitle: "智能对账",
                icon: "arrow.down.doc.fill",
                tint: LedgerPalette.success,
                action: onImport
            )
            QuickActionItem(
                title: "收支趋势",
                subtitle: "月度收支",
                icon: "chart.xyaxis.line",
                tint: LedgerPalette.gold,
                action: onIncomeExpense
            )
            QuickActionItem(
                title: "资产分布",
                subtitle: "账户净值",
                icon: "building.columns.fill",
                tint: Color(red: 0.55, green: 0.35, blue: 0.85),
                action: onAssets
            )
        }
        .padding(.vertical, 2)
    }
}

private struct QuickActionItem: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.system(.caption, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(LedgerPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(LedgerPalette.panel)
            .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6),
                                LedgerPalette.cardBorder.opacity(0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.2 : 0.03),
                radius: 4,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.94))
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
    @EnvironmentObject private var session: LedgerSession
    let categories: [OverviewCategorySpending]
    let totalExpense: Int
    let currency: String

    var body: some View {
        VStack(spacing: 12) {
            ForEach(categories) { item in
                VStack(spacing: 6) {
                    HStack(alignment: .center, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(item.color.opacity(0.14))
                                .frame(width: 32, height: 32)
                            Image(systemName: item.iconName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(item.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.label)
                                    .font(.system(.subheadline, design: .default, weight: .medium))
                                    .foregroundStyle(LedgerPalette.ink)
                                Text("\(item.count) 笔")
                                    .font(.system(.caption2, design: .default))
                                    .foregroundStyle(LedgerPalette.secondary)
                            }
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            AmountLabel(
                                minorUnits: item.totalMinorUnits,
                                currency: currency,
                                font: .system(.subheadline, design: .rounded, weight: .semibold),
                                color: LedgerPalette.ink
                            )
                            Text(String(format: "%.1f%%", item.percentage * 100))
                                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }

                    // Progress track
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .frame(height: 5)
                            Capsule()
                                .fill(item.color)
                                .frame(
                                    width: max(5, min(geo.size.width, geo.size.width * CGFloat(item.percentage))),
                                    height: 5
                                )
                        }
                    }
                    .frame(height: 5)
                }
                if item.id != categories.last?.id {
                    Divider()
                        .overlay(LedgerPalette.line.opacity(0.5))
                        .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .background(LedgerPalette.panel)
    }
}

private struct OverviewSpendingRhythmCard: View {
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
            guard presentation.kind == .expense, presentation.minorUnits > 0 else { return nil }
            return (presentation.title, presentation.minorUnits)
        }
        return expenseTx.max { $0.1 < $1.1 }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Daily average
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.gold)
                    Text("日均支出")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                AmountLabel(
                    minorUnits: dailyAverage,
                    currency: ledger.summary.currency,
                    font: .system(.title3, design: .rounded, weight: .bold),
                    color: LedgerPalette.ink
                )
                Text("按已过 \(daysElapsed) 天计算")
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(LedgerPalette.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LedgerPalette.cardBorder.opacity(0.4), lineWidth: 0.5)
            }

            // Highest single expense
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.expense)
                    Text("单笔最高")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                if let highest = highestExpense {
                    AmountLabel(
                        minorUnits: highest.amount,
                        currency: ledger.summary.currency,
                        font: .system(.title3, design: .rounded, weight: .bold),
                        color: LedgerPalette.expense
                    )
                    Text(highest.title)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                } else {
                    Text("无支出")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(LedgerPalette.secondary)
                    Text("—")
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(LedgerPalette.cardBorder.opacity(0.4), lineWidth: 0.5)
            }
        }
        .padding(16)
        .background(LedgerPalette.panel)
    }
}

private struct MonthlyConclusion: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var session: LedgerSession

    let ledger: LedgerBootstrap
    let range: LedgerDateRange

    private var savingsRate: Double? {
        guard ledger.summary.income > 0 else { return nil }
        return Double(ledger.summary.net) / Double(ledger.summary.income)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header: Scope & Transaction Count
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                    Text("\(range.metricScope)概览")
                        .font(.system(.subheadline, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                }
                Spacer()
                Text("\(ledger.transactions.count) 笔流水")
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(LedgerPalette.tag)
                    .clipShape(Capsule())
            }

            // Net Metric Hero
            VStack(alignment: .leading, spacing: 6) {
                Text("\(range.metricScope)净结余")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    AmountLabel(
                        minorUnits: ledger.summary.net,
                        currency: ledger.summary.currency,
                        font: .system(size: 32, weight: .bold, design: .rounded),
                        color: ledger.summary.net < 0 ? LedgerPalette.risk : LedgerPalette.ink
                    )
                    .tracking(-0.5)
                    .lineLimit(1)

                    primaryComparisonBadge
                }
            }

            // Income & Expense Split Cards
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    incomeMetricCard
                    expenseMetricCard
                }
            } else {
                HStack(spacing: 12) {
                    incomeMetricCard
                    expenseMetricCard
                }
            }

            // Savings Rate Progress Bar
            if let rate = savingsRate, session.amountsVisible {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("储蓄结余率")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                        Spacer()
                        Text(String(format: "%.1f%%", max(0, rate * 100)))
                            .font(.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit())
                            .foregroundStyle(rate >= 0.2 ? LedgerPalette.income : LedgerPalette.warm)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color(uiColor: .tertiarySystemFill))
                                .frame(height: 6)

                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [LedgerPalette.cobalt, LedgerPalette.income],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(6, min(geo.size.width, geo.size.width * CGFloat(max(0, min(1.0, rate))))), height: 6)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.top, 2)
            }
        }
        .padding(18)
        .background(LedgerPalette.panel)
    }

    private var primaryComparisonBadge: some View {
        Group {
            if let comparisons = netComparisons {
                let comp = comparisons.yearOverYear.percentage != nil ? comparisons.yearOverYear : comparisons.monthOverMonth
                if let delta = comp.delta, session.amountsVisible {
                    let favorable = delta >= 0
                    let percentText = comp.percentage.map { String(format: "%+.1f%%", $0 * 100) } ?? ""
                    let label = comp.currentRange == comparisons.yearOverYear.currentRange ? "同比" : "环比"
                    HStack(spacing: 3) {
                        Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(percentText) \(label)")
                            .font(.system(.caption2, design: .rounded, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(favorable ? LedgerPalette.income : LedgerPalette.risk)
                    .background((favorable ? LedgerPalette.income : LedgerPalette.risk).opacity(0.12))
                    .clipShape(Capsule())
                }
            }
        }
    }

    private var incomeMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LedgerPalette.income.opacity(0.14))
                        .frame(width: 22, height: 22)
                    Image(systemName: "arrow.down.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LedgerPalette.income)
                }
                Text("收入")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            AmountLabel(
                minorUnits: ledger.summary.income,
                currency: ledger.summary.currency,
                prefix: "+",
                font: .system(.title3, design: .rounded, weight: .bold),
                color: LedgerPalette.income
            )
            .lineLimit(1)

            if let comp = ledger.comparisons?.income.monthOverMonth {
                compactComparison(comp, metric: .income, label: "环比")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LedgerPalette.cardBorder.opacity(0.4), lineWidth: 0.5)
        }
    }

    private var expenseMetricCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LedgerPalette.expense.opacity(0.14))
                        .frame(width: 22, height: 22)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LedgerPalette.expense)
                }
                Text("支出")
                    .font(.system(.caption, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }

            AmountLabel(
                minorUnits: ledger.summary.expense,
                currency: ledger.summary.currency,
                prefix: "−",
                font: .system(.title3, design: .rounded, weight: .bold),
                color: LedgerPalette.expense
            )
            .lineLimit(1)

            if let comp = ledger.comparisons?.expense.monthOverMonth {
                compactComparison(comp, metric: .expense, label: "环比")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(LedgerPalette.cardBorder.opacity(0.4), lineWidth: 0.5)
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
