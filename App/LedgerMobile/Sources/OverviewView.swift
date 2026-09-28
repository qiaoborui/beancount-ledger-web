import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var ratioLabelWidth: CGFloat = 32
    @ScaledMetric(relativeTo: .body) private var ratioValueWidth: CGFloat = 40
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
        .terminalPageChrome("财务概览", compactTitle: "概览", isRoot: isRoot)
        .refreshable { await session.refresh() }
    }

    private func summary(_ ledger: LedgerBootstrap) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("净结余").terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
                .padding(.bottom, 8)
            TerminalAmount(minorUnits: ledger.summary.net, currency: ledger.summary.currency,
                color: TerminalPalette.accent, size: 28)
                .tracking(-1)
                .accessibilityIdentifier("overview-monthly-net")
            TerminalRule().padding(.vertical, 16)
            VStack(spacing: 12) {
                metric("收入", amount: ledger.summary.income, currency: ledger.summary.currency, prefix: "+")
                metric("支出", amount: ledger.summary.expense, currency: ledger.summary.currency, prefix: "−")
            }
            VStack(spacing: 8) {
                ratio("收入", amount: ledger.summary.income, maximum: max(ledger.summary.income, ledger.summary.expense), color: TerminalPalette.accent)
                ratio("支出", amount: ledger.summary.expense, maximum: max(ledger.summary.income, ledger.summary.expense), color: TerminalPalette.secondary)
            }.padding(.top, 16)
        }
        .padding(.vertical, 16).padding(.horizontal, 12)
        .background(TerminalPalette.panel)
        .overlay(Rectangle().stroke(TerminalPalette.line, lineWidth: 1))
    }

    private func metric(_ title: String, amount: Int, currency: String, prefix: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
            Spacer(minLength: 0)
            TerminalAmount(minorUnits: amount, currency: currency, size: 16, prefix: amount >= 0 ? prefix : "")
        }
    }

    private func ratio(_ title: String, amount: Int, maximum: Int, color: Color) -> some View {
        let fraction = maximum > 0 ? min(1, max(0, Double(amount) / Double(maximum))) : 0
        return HStack(spacing: 8) {
            Text(title).frame(width: ratioLabelWidth, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(TerminalPalette.line)
                    if session.amountsVisible {
                        Rectangle().fill(color).frame(width: geometry.size.width * fraction)
                    }
                }
            }.frame(height: 4).accessibilityHidden(true)
            Text(session.amountsVisible ? String(format: "%.0f%%", fraction * 100) : "—")
                .frame(width: ratioValueWidth, alignment: .trailing)
        }.terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
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
                    Text(session.localOverviewCategoriesError ?? "所选范围暂无支出")
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
