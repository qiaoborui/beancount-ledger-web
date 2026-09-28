import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var isRoot = true

    var body: some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
            .padding(.top, 16)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .terminalPageChrome("财务概览", compactTitle: "概览")
        .refreshable { await session.refresh() }
    }

    private func summary(_ ledger: LedgerBootstrap) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("净结余").font(.subheadline)
                Spacer()
                if let stats = session.overviewTransactionStats {
                    Text("\(stats.transactionCount) 笔流水").font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(TerminalPalette.secondary)
            TerminalAmount(minorUnits: ledger.summary.net, currency: ledger.summary.currency,
                color: ledger.summary.net < 0 ? TerminalPalette.negative : TerminalPalette.accent, size: 28)
                .accessibilityIdentifier("overview-monthly-net")
            TerminalRule()
            metric("收入", amount: ledger.summary.income, currency: ledger.summary.currency,
                color: TerminalPalette.ink, prefix: "+")
            metric("支出", amount: ledger.summary.expense, currency: ledger.summary.currency,
                color: TerminalPalette.ink, prefix: "−")
            let income = Double(max(0, ledger.summary.income))
            let expense = Double(max(0, ledger.summary.expense))
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    if session.amountsVisible, income + expense > 0 {
                        Rectangle().fill(TerminalPalette.accent)
                            .frame(width: max(0, geometry.size.width - 2) * income / (income + expense))
                        Rectangle().fill(TerminalPalette.secondary)
                    } else {
                        Rectangle().fill(TerminalPalette.line)
                    }
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .padding(16)
        .background(TerminalPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(TerminalPalette.line, lineWidth: 0.5))
    }

    private func metric(_ title: String, amount: Int, currency: String, color: Color, prefix: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        return layout {
            Text(title).font(.subheadline).foregroundStyle(TerminalPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            TerminalAmount(minorUnits: amount, currency: currency, color: color, size: 16,
                prefix: amount >= 0 ? prefix : "")
        }
    }

    private func sectionTitle(_ title: String, action: String, destination: LedgerDestination) -> some View {
        HStack {
            Text(title).font(.system(.subheadline, design: .monospaced, weight: .bold))
                .foregroundStyle(TerminalPalette.accent)
            Spacer()
            Button { session.primaryDestinationID = destination.rawValue } label: {
                HStack(spacing: 5) {
                    Text(action)
                    Image(systemName: "arrow.up.right")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(TerminalPalette.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func spending(_ categories: [OverviewCategorySpending], currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("01 / 支出矩阵", action: "分析", destination: .incomeExpense)
            TerminalRule()
            if categories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.localOverviewCategoriesError ?? "所选范围暂无支出")
                        .font(.subheadline).foregroundStyle(TerminalPalette.secondary)
                    if session.localOverviewCategoriesError != nil {
                        Button("重试") { Task { await session.refresh() } }
                    }
                }.padding(.vertical, 16)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 20) {
                    ForEach(categories) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Text(item.label).font(.subheadline).foregroundStyle(TerminalPalette.ink)
                                Spacer(minLength: 0)
                                Text(session.amountsVisible ? String(format: "%.0f%%", item.percentage * 100) : "—")
                                    .font(.caption.monospacedDigit()).foregroundStyle(TerminalPalette.secondary)
                            }
                            TerminalAmount(minorUnits: item.totalMinorUnits, currency: currency)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(TerminalPalette.line)
                                    if session.amountsVisible {
                                        Rectangle().fill(TerminalPalette.accent)
                                            .frame(width: geometry.size.width * min(1, max(0, item.percentage)))
                                    }
                                }
                            }.frame(height: 3).accessibilityHidden(true)
                        }
                    }
                }.padding(.vertical, 16)
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
                    TerminalTransactionRow(transaction: transaction, accountLabels: accountLabels)
                }
                .buttonStyle(.plain)
                .ledgerTransactionActions(transaction)
                TerminalRule()
            }
        }
    }

    private func localSpendingCategories(accountLabels: [String: String]) -> [OverviewCategorySpending] {
        guard let response = session.localOverviewCategories,
              response.positiveTotalMinorUnits > 0 else { return [] }
        return response.categories.sorted {
            $0.totalMinorUnits == $1.totalMinorUnits
                ? $0.label < $1.label : $0.totalMinorUnits > $1.totalMinorUnits
        }.prefix(4).map { item in
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

private struct OverviewCategorySpending: Identifiable {
    let id: String
    let label: String
    let iconName: String
    let color: Color
    let totalMinorUnits: Int
    let count: Int
    let percentage: Double
}

private struct TerminalTransactionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: LedgerTransaction
    let accountLabels: [String: String]

    var body: some View {
        let presentation = TransactionPresentation(transaction: transaction)
        let visual = TransactionVisualCategory.resolve(transaction: transaction,
            presentation: presentation, accountLabels: accountLabels)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title).font(.subheadline.weight(.medium))
                    .foregroundStyle(TerminalPalette.ink)
                    .lineLimit(2)
                Text("\(transaction.date) · \(visual.categoryLabel)")
                    .font(.caption).foregroundStyle(TerminalPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TerminalAmount(minorUnits: presentation.minorUnits, currency: presentation.currency,
                color: presentation.kind == .income ? TerminalPalette.positive : TerminalPalette.ink,
                prefix: presentation.kind == .expense ? "−" : presentation.kind == .income ? "+" : "↔ ")
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
