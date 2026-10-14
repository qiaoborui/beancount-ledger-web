import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var comparisonDetails: OverviewComparisonDetails?
    var isRoot = true

    var body: some View {
        let labels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let error = session.errorMessage { StatusBanner(message: error, onDismiss: session.dismissError).padding(.horizontal, 20).padding(.bottom, 16) }
                if let ledger = session.ledger {
                    balanceSheet(ledger); retention(ledger); cashflow(ledger)
                    let categories = session.isLocal ? localSpendingCategories(accountLabels: labels) : spendingCategories(from: ledger.transactions, accountLabels: labels)
                    spending(categories, currency: ledger.summary.currency)
                    recentTransactions(ledger, accountLabels: labels)
                } else { EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: "暂无财务数据", detail: "下拉刷新重新读取账本。").padding(.horizontal, 20) }
            }.padding(.bottom, 24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
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

    // MARK: Settlement blocks (design batch 1, `.settle` / `.band`)

    /// Preset ranges end on the first day after the period; show the last day it covers.
    private func periodEndLabel(_ ledger: LedgerBootstrap) -> String {
        session.selectedRange.preset == .custom ? ledger.end : LedgerReconciliationDates.previousDay(from: ledger.end)
    }

    /// The design labels the period by its month alone ("8 月") when it is one month.
    private var periodShortLabel: String {
        let range = session.selectedRange
        if range.preset == .month, let month = range.start.split(separator: "-").dropFirst().first.flatMap({ Int($0) }) {
            return "\(month) 月"
        }
        return range.displayTitle
    }

    private func balanceSheet(_ ledger: LedgerBootstrap) -> some View {
        let t = ledger.balanceSheetTotals
        let currency = ledger.valuationCurrency
        return settle(title: "资产负债结算", aside: periodEndLabel(ledger)) {
            settleRow("资产", amount(abs(t.assets), currency: currency, prefix: t.assets < 0 ? "−" : ""))
            settleRow("负债", amount(abs(t.liabilities), currency: currency, prefix: t.liabilities != 0 ? "−" : ""))
        } total: {
            settleTotal("净值", amount(abs(t.netWorth), currency: currency, prefix: t.netWorth < 0 ? "−" : "", size: 30, weight: .medium, currencySymbol: true))
        }
    }

    private func retention(_ ledger: LedgerBootstrap) -> some View {
        let income = max(ledger.summary.income, 0), retained = ledger.summary.net
        let ratio = income == 0 ? 0 : min(max(Double(retained) / Double(income), 0), 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本期留存率").balancedFont(size: 12.5)
                    Text("\(periodShortLabel) · 净结余 ÷ 收入").balancedFont(size: 11.5)
                }.foregroundStyle(BalancedPalette.meta)
                Spacer(minLength: 0)
                if session.amountsVisible {
                    (Text(String(format: "%.1f", ratio * 100)).font(.custom(BalancedWeight.medium.sansPostscriptName, size: 21, relativeTo: .title3)).tracking(-0.42).foregroundColor(BalancedPalette.ink)
                     + Text(" %").font(.custom(BalancedWeight.text.sansPostscriptName, size: 12, relativeTo: .caption)).foregroundColor(BalancedPalette.meta))
                        .monospacedDigit()
                } else {
                    Text("••••").balancedFont(size: 21, weight: .medium).foregroundStyle(BalancedPalette.ink)
                }
            }.padding(.bottom, 12)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    BalancedPalette.ink.frame(width: max(0, (proxy.size.width - 2) * ratio))
                    BalancedPalette.expense.frame(maxWidth: .infinity)
                }
            }.frame(height: 10).padding(.bottom, 12).accessibilityHidden(true)
            HStack {
                legend("留存", value: retained, color: BalancedPalette.ink, currency: ledger.summary.currency)
                Spacer(minLength: 16)
                legend("支出", value: ledger.summary.expense, color: BalancedPalette.expense, currency: ledger.summary.currency)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private func cashflow(_ ledger: LedgerBootstrap) -> some View {
        let net = ledger.summary.net, currency = ledger.summary.currency
        // Opening net worth is the last recorded point before the period starts; the
        // row is omitted rather than estimated when the history doesn't reach back.
        let opening = ledger.netWorthHistory.filter { $0.date < ledger.start }.max { $0.date < $1.date }?.netWorth
        return settle(title: "本期收支结算", aside: periodShortLabel) {
            if let opening {
                settleRow("期初净资产", amount(abs(opening), currency: ledger.valuationCurrency, prefix: opening < 0 ? "−" : ""))
            }
            settleRow("收入", amount(ledger.summary.income, currency: currency, prefix: "+"))
            settleRow("支出", amount(ledger.summary.expense, currency: currency, prefix: "−"))
        } total: {
            settleTotal("净结余", amount(abs(net), currency: currency, prefix: net >= 0 ? "+" : "−", size: 30, weight: .medium,
                color: net >= 0 ? BalancedPalette.income : BalancedPalette.expense))
        }
        .overlay(alignment: .top) { BalancedPalette.rule.frame(height: 1) }
    }

    private func settle<Rows: View, Total: View>(title: String, aside: String, @ViewBuilder rows: () -> Rows, @ViewBuilder total: () -> Total) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.secondary)
                Spacer(minLength: 0)
                Text(aside).balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
            }.padding(.bottom, 14)
            rows()
            total()
        }
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BalancedPalette.sunken)
    }

    private func settleRow(_ label: String, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).balancedFont(size: 15).foregroundStyle(BalancedPalette.secondary)
            Spacer(minLength: 0)
            value.lineLimit(1).minimumScaleFactor(0.6)
        }.padding(.vertical, 6)
    }

    private func settleTotal(_ label: String, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).balancedFont(size: 13).foregroundStyle(BalancedPalette.meta)
            Spacer(minLength: 0)
            value.lineLimit(1).minimumScaleFactor(0.45)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { BalancedPalette.ink.frame(height: 1) }
        .padding(.top, 10)
    }

    /// Balanced amount: proportional Plex with tabular figures. The currency symbol
    /// appears only on a total, at 0.62em in ink-3; the sign stays full size.
    private func amount(_ minorUnits: Int, currency: String, prefix: String = "", size: CGFloat = 15, weight: BalancedWeight = .text,
                        color: Color = BalancedPalette.ink, currencySymbol: Bool = false) -> Text {
        let font = Font.custom(weight.sansPostscriptName, size: size, relativeTo: size > 20 ? .title : .body)
        guard session.amountsVisible else { return Text("••••••").font(font).foregroundColor(color) }
        let number = MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: false)
        var text = Text(prefix).font(font).foregroundColor(color)
        if currencySymbol {
            text = text + Text(MoneyText.currencySymbol(for: currency))
                .font(.custom(BalancedWeight.text.sansPostscriptName, size: size * 0.62, relativeTo: .body)).foregroundColor(BalancedPalette.meta)
        }
        text = text + Text(number).font(font).foregroundColor(color)
        return (size > 20 ? text.tracking(-0.025 * size) : text).monospacedDigit()
    }

    private func legend(_ title: String, value: Int, color: Color, currency: String) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 9, height: 9)
            Text(title).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
            amount(value, currency: currency, size: 13, weight: .medium, color: BalancedPalette.secondary)
        }
    }

    // MARK: Sections

    private func sectionHead(_ title: String, @ViewBuilder aside: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).balancedFont(size: 15, weight: .semibold).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
            Spacer(minLength: 0)
            aside()
        }.padding(EdgeInsets(top: 26, leading: 20, bottom: 10, trailing: 20))
    }

    private func spending(_ categories: [OverviewCategorySpending], currency: String) -> some View {
        let total = categories.reduce(0) { $0 + $1.totalMinorUnits }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHead("支出分类") {
                if !categories.isEmpty {
                    HStack(spacing: 4) {
                        amount(total, currency: currency, size: 12.5, weight: .regular, color: BalancedPalette.meta)
                        Text(currency).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
            if categories.isEmpty {
                Text(session.localOverviewCategoriesError ?? (session.isLocal && session.localOverviewCategories == nil ? "正在读取支出排行…" : "所选范围暂无支出"))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
            } else {
                spendingRow { Text("分类") } amount: { Text("金额") } share: { Text("占比") }
                    .balancedFont(size: 12, weight: .medium).foregroundStyle(BalancedPalette.meta)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                ForEach(categories) { item in
                    spendingRow {
                        Text(item.label).balancedFont(size: 14.5).foregroundStyle(BalancedPalette.ink).lineLimit(2)
                    } amount: {
                        amount(item.totalMinorUnits, currency: currency, size: 14.5, weight: .medium)
                    } share: {
                        Text(session.amountsVisible ? String(format: "%.1f%%", item.percentage * 100) : "—")
                            .balancedFont(size: 14.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                }
            }
        }
    }

    private func spendingRow(@ViewBuilder label: () -> some View, @ViewBuilder amount: () -> some View, @ViewBuilder share: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            label().frame(maxWidth: .infinity, alignment: .leading)
            amount().lineLimit(1).padding(.leading, 8)
            share().lineLimit(1).frame(width: 54, alignment: .trailing).padding(.leading, 28)
        }.padding(.horizontal, 20)
    }

    private func recentTransactions(_ ledger: LedgerBootstrap, accountLabels: [String: String]) -> some View {
        let recent = Array(ledger.transactions.prefix(3))
        let days = recent.reduce(into: [(String, [LedgerTransaction])]()) { groups, tx in
            if groups.last?.0 == tx.date { groups[groups.count - 1].1.append(tx) } else { groups.append((tx.date, [tx])) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHead("最近流水") {
                if !ledger.transactions.isEmpty {
                    Button { session.primaryDestinationID = LedgerDestination.transactions.rawValue } label: {
                        Text("全部 \(ledger.transactions.count) 笔").balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                            .padding(.bottom, 1).overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.vertical, -16)
                }
            }
            if recent.isEmpty {
                Text("所选范围暂无流水").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
            } else {
                ForEach(days, id: \.0) { day in
                    daySeparator(day.0)
                    ForEach(Array(day.1.enumerated()), id: \.element.id) { index, tx in
                        NavigationLink { TransactionDetailView(transaction: tx) } label: {
                            BalancedTransactionRow(transaction: tx, accountLabels: accountLabels, accountCurrency: ledger.summary.currency, showsRule: index < day.1.count - 1)
                        }.buttonStyle(.plain).ledgerTransactionActions(tx)
                    }
                }
            }
        }
    }

    private func daySeparator(_ raw: String) -> some View {
        let parts = Self.dayLabel(raw)
        return HStack(spacing: 10) {
            (Text(parts.date).font(.custom(BalancedWeight.semibold.sansPostscriptName, size: 12.5, relativeTo: .caption)).foregroundColor(BalancedPalette.secondary)
             + Text(" " + parts.weekday).font(.custom(BalancedWeight.regular.sansPostscriptName, size: 12.5, relativeTo: .caption)).foregroundColor(BalancedPalette.meta))
                .monospacedDigit()
            BalancedPalette.rule.frame(height: 1)
        }.padding(EdgeInsets(top: 20, leading: 20, bottom: 6, trailing: 20))
    }

    private static func dayLabel(_ raw: String) -> (date: String, weekday: String) {
        guard let date = LedgerDateRange.parse(raw) else { return (raw, "") }
        let c = LedgerDateRange.calendar.dateComponents([.month, .day, .weekday], from: date)
        guard let month = c.month, let day = c.day, let weekday = c.weekday else { return (raw, "") }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return (String(format: "%02d/%02d", month, day), weekdays[max(0, min(6, weekday - 1))])
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

/// `.txn` from design batch 1: payee 15.5/500 over the note, amount 15.5/500 over
/// the category. Income is the only direction drawn in colour; expense and
/// transfers stay ink and carry their meaning in the sign.
private struct BalancedTransactionRow: View {
    @EnvironmentObject private var session: LedgerSession
    let transaction: LedgerTransaction
    let accountLabels: [String: String]
    let accountCurrency: String
    var showsRule = true
    var body: some View {
        let p = TransactionPresentation(transaction: transaction)
        let visual = TransactionVisualCategory.resolve(transaction: transaction, presentation: p, accountLabels: accountLabels)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).balancedFont(size: 15.5, weight: .medium).tracking(-0.08).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Text(p.subtitle).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amountText(p)).font(.custom(BalancedWeight.medium.sansPostscriptName, size: 15.5, relativeTo: .body)).monospacedDigit()
                    .foregroundStyle(p.kind == .income ? BalancedPalette.income : BalancedPalette.ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(p.kind == .transfer ? "转账" : visual.categoryLabel).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }.frame(minWidth: 104, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 56)
        .overlay(alignment: .bottom) { if showsRule { BalancedPalette.rule.frame(height: 1) } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func amountText(_ p: TransactionPresentation) -> String {
        guard session.amountsVisible else { return "••••••" }
        let sign = p.kind == .expense ? "−" : p.kind == .income ? "+" : ""
        return sign + MoneyText.format(minorUnits: abs(p.minorUnits), currency: p.currency, showsCurrency: p.currency != accountCurrency)
    }
}

private struct OverviewComparisonDetails: Identifiable { var id: String { title }; let title: String; let comparisons: LedgerMetricPeriodComparisons; let currency: String }
