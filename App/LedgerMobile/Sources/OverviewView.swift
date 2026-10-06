import SwiftUI

private enum BalancedPalette {
    static let page = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x121110) : UIColor(hex: 0xFBFAF8) })
    static let sunken = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1918) : UIColor(hex: 0xF1EFE9) })
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF6F3EE) : UIColor(hex: 0x14100C) })
    static let secondary = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xC4BCB0) : UIColor(hex: 0x453E36) })
    static let meta = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x9A9086) : UIColor(hex: 0x6F675A) })
    static let rule = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x2B2825) : UIColor(hex: 0xE2DED4) })
    static let income = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x4FBFAB) : UIColor(hex: 0x0D5346) })
    static let expense = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xCF7A52) : UIColor(hex: 0x96401F) })
}

private struct BalancedAmount: View {
    @EnvironmentObject private var session: LedgerSession
    let minorUnits: Int
    let currency: String
    var size: CGFloat = 15
    var color: Color = BalancedPalette.ink
    var prefix = ""
    var showsCurrency = false
    var body: some View {
        Text(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: showsCurrency) : "••••••")
            .font(.system(size: size, weight: .medium)).monospacedDigit().foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.45)
            .accessibilityLabel(session.amountsVisible ? prefix + MoneyText.format(minorUnits: minorUnits, currency: currency) : "金额已隐藏")
    }
}

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var comparisonDetails: OverviewComparisonDetails?
    var isRoot = true

    var body: some View {
        let labels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = session.errorMessage { StatusBanner(message: error, onDismiss: session.dismissError).padding(.bottom, 16) }
                if let ledger = session.ledger {
                    balanceSheet(ledger); cashflow(ledger)
                    let categories = session.isLocal ? localSpendingCategories(accountLabels: labels) : spendingCategories(from: ledger.transactions, accountLabels: labels)
                    spending(categories, currency: ledger.summary.currency)
                    recentTransactions(ledger, accountLabels: labels)
                } else { EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: "暂无财务数据", detail: "下拉刷新重新读取账本。") }
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden).background(BalancedPalette.page)
        .terminalPageChrome("财务概览", compactTitle: "概览", isRoot: isRoot, showsTimeRange: true)
        .refreshable { await Task { await session.refresh() }.value }
        .sheet(item: $comparisonDetails) { details in
            NavigationStack {
                List {
                    Section("当前期间") { Text("\(details.comparisons.monthOverMonth.currentRange.start) 至 \(details.comparisons.monthOverMonth.currentRange.end)") }
                    comparisonSection("环比", value: details.comparisons.monthOverMonth, currency: details.currency)
                    comparisonSection("同比", value: details.comparisons.yearOverYear, currency: details.currency)
                    Section("计算口径") { Text("变化金额 = 本期 − 基期；变化率 = 变化金额 ÷ 基期绝对值。基期为零时不计算变化率。结余 = 收入 − 支出，转账不计收支。") }
                }.navigationTitle("\(details.title) · 比较口径").terminalNativeChrome()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comparisonDetails = nil } } }
            }.ledgerPrivacyProtectedSheet()
        }
    }

    private func balanceSheet(_ ledger: LedgerBootstrap) -> some View {
        let t = ledger.balanceSheetTotals
        return settle(title: "资产负债结算", date: ledger.end, rows: [("资产", t.assets, BalancedPalette.ink, ""), ("负债", t.liabilities, BalancedPalette.expense, "−")], totalTitle: "净值", total: t.netWorth, totalColor: BalancedPalette.ink, currency: ledger.valuationCurrency)
    }

    private func cashflow(_ ledger: LedgerBootstrap) -> some View {
        let income = max(ledger.summary.income, 0), retained = ledger.summary.net
        let ratio = income == 0 ? 0 : min(max(Double(retained) / Double(income), 0), 1)
        return VStack(alignment: .leading, spacing: 0) {
            settle(title: "本期收支结算", date: ledger.end, rows: [("收入", ledger.summary.income, BalancedPalette.income, "+"), ("支出", ledger.summary.expense, BalancedPalette.expense, "−")], totalTitle: "净结余", total: retained, totalColor: BalancedPalette.income, currency: ledger.summary.currency)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) { VStack(alignment: .leading, spacing: 3) { Text("本期留存率").font(.system(size: 13, weight: .medium)); Text("净结余 ÷ 收入").font(.system(size: 12)).foregroundStyle(BalancedPalette.meta) }; Spacer(); Text(session.amountsVisible ? String(format: "%.1f%%", ratio * 100) : "••••").font(.system(size: 21, weight: .medium)).monospacedDigit() }
                GeometryReader { proxy in HStack(spacing: 2) { BalancedPalette.ink.frame(width: proxy.size.width * ratio); BalancedPalette.expense.frame(maxWidth: .infinity) }.frame(height: 10) }.frame(height: 10)
                HStack { legend("留存", value: retained, color: BalancedPalette.ink, currency: ledger.summary.currency); Spacer(); legend("支出", value: ledger.summary.expense, color: BalancedPalette.expense, currency: ledger.summary.currency) }
            }.padding(20).background(BalancedPalette.sunken)
        }
    }

    private func settle(title: String, date: String, rows: [(String, Int, Color, String)], totalTitle: String, total: Int, totalColor: Color, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.system(size: 13, weight: .medium)); Spacer(); Text(date).font(.system(size: 12)).monospacedDigit().foregroundStyle(BalancedPalette.meta) }.padding(.bottom, 12)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in HStack { Text(row.0).font(.system(size: 15)).foregroundStyle(BalancedPalette.secondary); Spacer(); BalancedAmount(minorUnits: row.1, currency: currency, color: row.2, prefix: row.3) }.padding(.vertical, 6) }
            HStack(alignment: .firstTextBaseline) { Text(totalTitle).font(.system(size: 13)).foregroundStyle(BalancedPalette.meta); Spacer(); BalancedAmount(minorUnits: total, currency: currency, size: 30, color: totalColor, prefix: total >= 0 && totalTitle == "净结余" ? "+" : total < 0 ? "−" : "") }.padding(.top, 10).padding(.bottom, 3).overlay(alignment: .top) { BalancedPalette.ink.frame(height: 1) }
        }.padding(20).background(BalancedPalette.sunken).padding(.bottom, 12)
    }

    private func legend(_ title: String, value: Int, color: Color, currency: String) -> some View { HStack(spacing: 6) { Circle().fill(color).frame(width: 7, height: 7); Text(title).font(.system(size: 12)).foregroundStyle(BalancedPalette.meta); BalancedAmount(minorUnits: value, currency: currency, size: 12) } }

    private func spending(_ categories: [OverviewCategorySpending], currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("支出分类", action: categories.isEmpty ? nil : MoneyText.format(minorUnits: categories.reduce(0) { $0 + $1.totalMinorUnits }, currency: currency))
            HStack { Text("分类"); Spacer(); Text("金额").frame(width: 92, alignment: .trailing); Text("占比").frame(width: 58, alignment: .trailing) }.font(.system(size: 12, weight: .medium)).foregroundStyle(BalancedPalette.meta).padding(.vertical, 9)
            if categories.isEmpty { Text(session.localOverviewCategoriesError ?? (session.isLocal && session.localOverviewCategories == nil ? "正在读取支出排行…" : "所选范围暂无支出")).font(.system(size: 13)).foregroundStyle(BalancedPalette.meta).padding(.vertical, 14) } else {
                ForEach(categories) { item in HStack(spacing: 8) { Text(item.label).font(.system(size: 15)).foregroundStyle(BalancedPalette.ink).lineLimit(2); Spacer(minLength: 8); BalancedAmount(minorUnits: item.totalMinorUnits, currency: currency, size: 14).frame(width: 92, alignment: .trailing); Text(session.amountsVisible ? String(format: "%.1f%%", item.percentage * 100) : "—").font(.system(size: 13)).monospacedDigit().foregroundStyle(BalancedPalette.meta).frame(width: 58, alignment: .trailing) }.padding(.vertical, 11).overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) } }
            }
        }
    }

    private func sectionTitle(_ title: String, action: String?) -> some View { HStack(alignment: .firstTextBaseline) { Text(title).font(.system(size: 15, weight: .semibold)); Spacer(); if let action { Text(action).font(.system(size: 12)).monospacedDigit().foregroundStyle(BalancedPalette.meta) } }.padding(.top, 14).padding(.bottom, 4) }

    private func recentTransactions(_ ledger: LedgerBootstrap, accountLabels: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("最近流水", action: ledger.transactions.isEmpty ? nil : "全部 \(ledger.transactions.count) 笔")
            if ledger.transactions.isEmpty { Text("所选范围暂无流水").font(.system(size: 13)).foregroundStyle(BalancedPalette.meta).padding(.vertical, 14) } else {
                ForEach(Array(ledger.transactions.prefix(3))) { tx in NavigationLink { TransactionDetailView(transaction: tx) } label: { BalancedTransactionRow(transaction: tx, accountLabels: accountLabels, accountCurrency: ledger.summary.currency) }.buttonStyle(.plain).ledgerTransactionActions(tx) }
                Button { session.primaryDestinationID = LedgerDestination.transactions.rawValue } label: { Text("查看全部流水").font(.system(size: 13, weight: .medium)).foregroundStyle(BalancedPalette.ink).frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.plain)
            }
        }
    }

    private func comparisonSection(_ title: String, value: LedgerPeriodComparison, currency: String) -> some View { Section(title) { Text("对比 \(value.baselineRange.start) 至 \(value.baselineRange.end)"); if let v = value.current { LabeledContent("本期") { BalancedAmount(minorUnits: v, currency: currency) } }; if let v = value.baseline { LabeledContent("基期") { BalancedAmount(minorUnits: v, currency: currency) } }; if let v = value.delta { LabeledContent("变化金额") { BalancedAmount(minorUnits: v, currency: currency, prefix: v > 0 ? "+" : "") } }; LabeledContent("变化率", value: changeText(value)) } }
    private func changeText(_ c: LedgerPeriodComparison?) -> String { guard session.amountsVisible else { return "••••" }; guard let c, c.delta != nil else { return "暂无数据" }; guard let p = c.percentage else { return "基期为零" }; return String(format: "%+.1f%%", p * 100) }

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

private struct BalancedTransactionRow: View {
    @EnvironmentObject private var session: LedgerSession
    let transaction: LedgerTransaction
    let accountLabels: [String: String]
    let accountCurrency: String
    var body: some View {
        let p = TransactionPresentation(transaction: transaction)
        let visual = TransactionVisualCategory.resolve(transaction: transaction, presentation: p, accountLabels: accountLabels)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) { Text(p.title).font(.system(size: 15, weight: .medium)).foregroundStyle(BalancedPalette.ink).lineLimit(2); Text(p.subtitle).font(.system(size: 12)).foregroundStyle(BalancedPalette.meta).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) { BalancedAmount(minorUnits: p.minorUnits, currency: p.currency, size: 14, prefix: p.kind == .expense ? "−" : p.kind == .income ? "+" : "", color: p.kind == .income ? BalancedPalette.income : BalancedPalette.ink, showsCurrency: p.currency != accountCurrency); Text(visual.categoryLabel).font(.system(size: 12)).foregroundStyle(BalancedPalette.meta) }
        }.padding(.vertical, 12).overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }.contentShape(Rectangle())
    }
}

private struct OverviewComparisonDetails: Identifiable { var id: String { title }; let title: String; let comparisons: LedgerMetricPeriodComparisons; let currency: String }
