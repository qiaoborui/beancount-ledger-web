import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var comparisonDetails: OverviewComparisonDetails?
    @ScaledMetric(relativeTo: .body) private var shareWidth: CGFloat = 48
    var isRoot = true

    var body: some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = session.errorMessage {
                    StatusBanner(message: error, onDismiss: session.dismissError)
                }
                if let ledger = session.ledger {
                    summary(ledger)
                    let categories = session.isLocal
                        ? localSpendingCategories(accountLabels: accountLabels)
                        : spendingCategories(from: ledger.transactions, accountLabels: accountLabels)
                    spending(categories, currency: ledger.summary.currency)
                    recentTransactions(ledger, accountLabels: accountLabels)
                } else {
                    EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: "暂无财务数据", detail: "下拉刷新重新读取账本。")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .terminalPageChrome("财务概览", compactTitle: "概览", isRoot: isRoot, showsTimeRange: true)
        .refreshable {
            // Native refresh controls may cancel their action as the view updates.
            // Let the requested refresh finish; session generations still reject
            // results after a lock, ledger switch, or newer request.
            await Task { await session.refresh() }.value
        }
        .sheet(item: $comparisonDetails) { details in
            NavigationStack {
                List {
                    Section("当前期间") {
                        Text("\(details.comparisons.monthOverMonth.currentRange.start) 至 \(details.comparisons.monthOverMonth.currentRange.end)")
                    }
                    comparisonSection("环比", value: details.comparisons.monthOverMonth, currency: details.currency)
                    comparisonSection("同比", value: details.comparisons.yearOverYear, currency: details.currency)
                    Section("计算口径") {
                        Text("变化金额 = 本期 − 基期；变化率 = 变化金额 ÷ 基期绝对值。基期为零时不计算变化率。结余 = 收入 − 支出，转账不计收支。")
                    }
                }
                .navigationTitle("\(details.title) · 比较口径")
                .terminalNativeChrome()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comparisonDetails = nil } } }
            }
            .ledgerPrivacyProtectedSheet()
        }
    }

    private func summary(_ ledger: LedgerBootstrap) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                showComparison("净结余", comparisons: netComparisons(ledger.comparisons), currency: ledger.summary.currency)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("净结余")
                        Image(systemName: "info.circle").font(.system(size: 11))
                    }.terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                        : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
                    layout {
                        TerminalAmount(minorUnits: ledger.summary.net, currency: ledger.summary.currency,
                            color: TerminalPalette.accent, size: 28, showsCurrency: false)
                            .tracking(-1).accessibilityIdentifier("overview-monthly-net")
                        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        comparisonLabels(netComparisons(ledger.comparisons))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            TerminalRule()
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            layout {
                metric("收入", amount: ledger.summary.income, currency: ledger.summary.currency,
                    prefix: "+", comparisons: ledger.comparisons?.income)
                metric("支出", amount: ledger.summary.expense, currency: ledger.summary.currency,
                    prefix: "−", comparisons: ledger.comparisons?.expense)
            }
        }.padding(.vertical, 4)
    }

    private func metric(_ title: String, amount: Int, currency: String, prefix: String,
                        comparisons: LedgerMetricPeriodComparisons?) -> some View {
        Button { showComparison(title, comparisons: comparisons, currency: currency) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
                TerminalAmount(minorUnits: amount, currency: currency, size: 19,
                    prefix: amount >= 0 ? prefix : "", showsCurrency: false)
                comparisonLabels(comparisons)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func comparisonLabels(_ comparisons: LedgerMetricPeriodComparisons?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("环比  " + changeText(comparisons?.monthOverMonth))
            Text("同比  " + changeText(comparisons?.yearOverYear))
        }.terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
    }

    private func changeText(_ comparison: LedgerPeriodComparison?) -> String {
        guard session.amountsVisible else { return "••••" }
        guard let comparison, comparison.delta != nil else { return "暂无数据" }
        guard let percentage = comparison.percentage else { return "基期为零" }
        return String(format: "%+.1f%%", percentage * 100)
    }

    private func showComparison(_ title: String, comparisons: LedgerMetricPeriodComparisons?, currency: String) {
        guard let comparisons else { return }
        comparisonDetails = .init(title: title, comparisons: comparisons, currency: currency)
    }

    private func comparisonSection(_ title: String, value: LedgerPeriodComparison, currency: String) -> some View {
        Section(title) {
            Text("对比 \(value.baselineRange.start) 至 \(value.baselineRange.end)")
            if let current = value.current { LabeledContent("本期") { TerminalAmount(minorUnits: current, currency: currency) } }
            if let baseline = value.baseline { LabeledContent("基期") { TerminalAmount(minorUnits: baseline, currency: currency) } }
            if let delta = value.delta { LabeledContent("变化金额") { TerminalAmount(minorUnits: delta, currency: currency, prefix: delta > 0 ? "+" : "") } }
            LabeledContent("变化率", value: changeText(value))
        }
    }

    private func netComparisons(_ comparisons: LedgerPeriodComparisons?) -> LedgerMetricPeriodComparisons? {
        guard let comparisons else { return nil }
        func net(_ income: LedgerPeriodComparison, _ expense: LedgerPeriodComparison) -> LedgerPeriodComparison {
            let current = income.current.flatMap { i in expense.current.map { i - $0 } }
            let baseline = income.baseline.flatMap { i in expense.baseline.map { i - $0 } }
            let delta = current.flatMap { c in baseline.map { c - $0 } }
            let percentage = delta.flatMap { d in baseline.flatMap { $0 == 0 ? nil : Double(d) / abs(Double($0)) } }
            return .init(currentRange: income.currentRange, baselineRange: income.baselineRange,
                current: current, baseline: baseline, delta: delta, percentage: percentage)
        }
        return .init(monthOverMonth: net(comparisons.income.monthOverMonth, comparisons.expense.monthOverMonth),
            yearOverYear: net(comparisons.income.yearOverYear, comparisons.expense.yearOverYear))
    }

    private func sectionTitle(_ title: String, action: String, destination: LedgerDestination? = nil) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return layout {
            Text(title).terminalFont(size: 13, weight: .semibold)
                .foregroundStyle(TerminalPalette.accent)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            if let destination {
                Button { session.primaryDestinationID = destination.rawValue } label: {
                    Text(action).terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                Text(action).terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
            }
        }.frame(minHeight: 44)
    }

    private func spending(_ categories: [OverviewCategorySpending], currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("01 / 支出矩阵", action: "金额 · 占比")
            TerminalRule()
            if categories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.localOverviewCategoriesError
                        ?? (session.isLocal && session.localOverviewCategories == nil
                            ? "正在读取支出排行…" : "所选范围暂无支出"))
                        .terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
                    if session.localOverviewCategoriesError != nil {
                        Button("重试") { Task { await session.refresh() } }
                    }
                }.padding(.vertical, 16)
            } else {
                if !dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 0) {
                        Text("序").frame(width: 32, alignment: .leading)
                        Text("分类").frame(maxWidth: .infinity, alignment: .leading)
                        Text("金额 / \(currency)")
                        Text("占比").frame(width: 48, alignment: .trailing)
                    }.terminalFont(size: 11, design: .monospaced)
                        .foregroundStyle(TerminalPalette.secondary).padding(.vertical, 8)
                } else {
                    Text("金额 / \(currency)").terminalFont(size: 11, design: .monospaced)
                        .foregroundStyle(TerminalPalette.secondary).padding(.vertical, 8)
                }
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, item in
                    TerminalRule()
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 0))
                    layout {
                        Text(String(format: "%02d", index + 1))
                            .terminalFont(size: 12, design: .monospaced)
                            .foregroundStyle(TerminalPalette.accent).frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 32, alignment: .leading)
                        Text(item.label).terminalFont(size: 13).foregroundStyle(TerminalPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TerminalAmount(minorUnits: item.totalMinorUnits, currency: currency, size: 13)
                        Text(session.amountsVisible ? String(format: "%.1f%%", item.percentage * 100) : "—")
                            .terminalFont(size: 13, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
                            .frame(width: shareWidth, alignment: .trailing)
                    }.padding(.vertical, 8).frame(minHeight: 36)
                }
            }
        }
    }

    private func recentTransactions(_ ledger: LedgerBootstrap, accountLabels: [String: String]) -> some View {
        VStack(spacing: 0) {
            sectionTitle("02 / 最近流水", action: "全部", destination: .transactions)
            TerminalRule()
            if ledger.transactions.isEmpty {
                Text("所选范围暂无流水").font(.subheadline).foregroundStyle(TerminalPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
            }
            ForEach(Array(ledger.transactions.prefix(3))) { transaction in
                NavigationLink {
                    TransactionDetailView(transaction: transaction)
                } label: {
                    TerminalTransactionRow(transaction: transaction, accountLabels: accountLabels, accountCurrency: ledger.summary.currency)
                }
                .buttonStyle(.plain)
                .ledgerTransactionActions(transaction)
                TerminalRule()
            }
            if let stats = session.overviewTransactionStats {
                Text("所选期间 \(stats.transactionCount) 笔流水 · 转账不计收支")
                    .terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
        }
    }

    private func localSpendingCategories(accountLabels: [String: String]) -> [OverviewCategorySpending] {
        guard let response = session.localOverviewCategories,
              response.positiveTotalMinorUnits > 0 else { return [] }
        return response.categories.sorted {
            $0.totalMinorUnits == $1.totalMinorUnits
                ? $0.label < $1.label : $0.totalMinorUnits > $1.totalMinorUnits
        }.map { item in
            let visual = TransactionVisualCategory.resolve(
                transaction: item.representative,
                presentation: TransactionPresentation(transaction: item.representative),
                accountLabels: accountLabels)
            return OverviewCategorySpending(id: item.label, label: item.label,
                iconName: visual.iconName, color: visual.color,
                totalMinorUnits: item.totalMinorUnits, count: max(1, item.positiveTransactionCount),
                percentage: Double(item.totalMinorUnits) / Double(response.positiveTotalMinorUnits))
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
            .sorted { $0.amount == $1.amount ? $0.label < $1.label : $0.amount > $1.amount }
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

private struct OverviewCategorySpending: Identifiable {
    let id: String
    let label: String
    let iconName: String
    let color: Color
    let totalMinorUnits: Int
    let count: Int
    let percentage: Double
}

struct TerminalTransactionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: LedgerTransaction
    let accountLabels: [String: String]
    let accountCurrency: String
    var showsYear = false
    @ScaledMetric(relativeTo: .body) private var dateWidth: CGFloat = 36

    var body: some View {
        let presentation = TransactionPresentation(transaction: transaction)
        let visual = TransactionVisualCategory.resolve(transaction: transaction,
            presentation: presentation, accountLabels: accountLabels)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                if showsYear { Text(String(transaction.date.prefix(4))) }
                Text(String(transaction.date.suffix(5)).replacingOccurrences(of: "-", with: "/"))
            }
            .terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.accent)
            .frame(width: dateWidth, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transaction.date)
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title).terminalFont(size: 16, weight: .medium)
                    .foregroundStyle(TerminalPalette.ink)
                    .lineLimit(2)
                Text(presentation.subtitle)
                    .terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                TerminalAmount(minorUnits: presentation.minorUnits, currency: presentation.currency,
                    size: 13, prefix: presentation.kind == .expense ? "−" : presentation.kind == .income ? "+" : "",
                    showsCurrency: presentation.currency != accountCurrency)
                Text(visual.categoryLabel).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                    .accessibilityIdentifier("transaction-category-\(transaction.source.line)")
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct OverviewComparisonDetails: Identifiable {
    var id: String { title }
    let title: String
    let comparisons: LedgerMetricPeriodComparisons
    let currency: String
}
