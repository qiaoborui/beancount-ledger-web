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
                    retentionHero(ledger); cashflow(ledger)
                    let breakdown = session.isLocal
                        ? localSpendingCategories(accountLabels: labels, fallbackCurrency: ledger.summary.currency)
                        : spendingCategories(from: ledger.transactions, prices: ledger.prices,
                                             currency: ledger.summary.currency, accountLabels: labels)
                    spending(breakdown)
                    recentTransactions(ledger, accountLabels: labels)
                } else { EmptyLedgerState(icon: "chart.line.uptrend.xyaxis", title: String(localized: "暂无财务数据"), detail: String(localized: "下拉刷新重新读取账本。")).padding(.horizontal, 20) }
            }.padding(.bottom, 24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden).background(BalancedPalette.page)
        .terminalPageChrome(String(localized: "财务概览"), compactTitle: String(localized: "概览"), isRoot: isRoot, showsTimeRange: true,
                            actions: AnyView(LedgerQuickEntryButton(accessibilityID: "overview-quick-entry")))
        .refreshable { await Task { await session.refresh() }.value }
        .sheet(item: $comparisonDetails) { details in
            NavigationStack {
                List {
                    Section("当前期间") { Text("\(details.comparisons.monthOverMonth.currentRange.start) 至 \(details.comparisons.monthOverMonth.currentRange.end)") }
                    comparisonSection(String(localized: "环比"), value: details.comparisons.monthOverMonth, currency: details.currency)
                    comparisonSection(String(localized: "同比"), value: details.comparisons.yearOverYear, currency: details.currency)
                    Section("计算口径") { Text("变化金额 = 本期 − 基期；变化率 = 变化金额 ÷ 基期绝对值。基期为零时不计算变化率。结余 = 收入 − 支出，转账不计收支。") }
                }.navigationTitle("\(details.title) · 比较口径").terminalNativeChrome()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comparisonDetails = nil } } }
            }.ledgerPrivacyProtectedSheet()
        }
    }

    // MARK: Settlement blocks (design batch 1 `.settle` / `.band`, glass palette in docs/design/ios-balanced/home-glass.html)

    /// The design labels the period by its month alone ("8 月") when it is one month.
    private var periodShortLabel: String {
        let range = session.selectedRange
        if range.preset == .month, let month = range.start.split(separator: "-").dropFirst().first.flatMap({ Int($0) }) {
            return LedgerDateLabel.month(number: month)
        }
        return range.displayTitle
    }

    /// The page's one headline: the period's net retention (收入 − 支出) at 30pt,
    /// the retention rate (净结余 ÷ 收入) beneath it, then the retention bar.
    private func retentionHero(_ ledger: LedgerBootstrap) -> some View {
        let income = max(ledger.summary.income, 0), net = ledger.summary.net, currency = ledger.summary.currency
        let rate: Double? = income == 0 ? nil : Double(net) / Double(income)
        let barRatio = min(max(rate ?? 0, 0), 1)
        let rateText: String = {
            guard session.amountsVisible else { return "••••" }
            guard let rate else { return "—" }
            return String(format: "%.1f%%", rate * 100)
        }()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("本期净结余").balancedFont(size: 12.5, weight: .medium).foregroundStyle(BalancedPalette.secondary)
                Spacer(minLength: 0)
                Text(periodShortLabel).balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
            }.padding(.bottom, 10)
            amount(abs(net), currency: currency, prefix: net < 0 ? "−" : "", size: 30, weight: .medium,
                   color: net >= 0 ? BalancedPalette.income : BalancedPalette.expense, currencySymbol: true)
                .lineLimit(1).minimumScaleFactor(0.45)
            Text(String(localized: "留存率") + " " + rateText)
                .balancedFont(size: 15).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                .padding(.top, 4)
            GeometryReader { proxy in
                if income == 0 && ledger.summary.expense <= 0 {
                    // Nothing earned or spent: an all-expense bar would claim spending.
                    Capsule().fill(BalancedPalette.rule)
                } else {
                    HStack(spacing: 3) {
                        Capsule().fill(BalancedPalette.ink).frame(width: max(0, (proxy.size.width - 3) * barRatio))
                        Capsule().fill(BalancedPalette.expense).frame(maxWidth: .infinity)
                    }
                }
            }.frame(height: 6).padding(.top, 16).padding(.bottom, 12).accessibilityHidden(true)
            HStack {
                legend(String(localized: "留存"), color: BalancedPalette.ink)
                Spacer(minLength: 16)
                legend(String(localized: "支出"), color: BalancedPalette.expense)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 22, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cashflow(_ ledger: LedgerBootstrap) -> some View {
        let currency = ledger.summary.currency
        // The net total is the hero at the top of the page; this block only itemises it.
        return settle(title: String(localized: "本期收支结算"), aside: periodShortLabel) {
            settleRow(String(localized: "收入"), amount(ledger.summary.income, currency: currency))
            settleRow(String(localized: "支出"), amount(ledger.summary.expense, currency: currency))
        } total: {
            EmptyView()
        }
        .overlay(alignment: .top) { insetRule }
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
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 0, trailing: 20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Under Liquid Glass nothing on this page runs edge to edge: full-bleed
    /// fills and hairlines were what the tab bar and top bar refracted into
    /// stripes. One paper surface; every rule stops 20pt short of the screen.
    private var insetRule: some View { BalancedPalette.rule.frame(height: 1).padding(.horizontal, 20) }

    private func settleRow(_ label: String, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label).balancedFont(size: 15).foregroundStyle(BalancedPalette.secondary)
            Spacer(minLength: 0)
            value.lineLimit(1).minimumScaleFactor(0.6)
        }.padding(.vertical, 6)
    }

    /// Balanced amount: proportional Plex with tabular figures. The currency symbol
    /// appears only on a total, at 0.6em in the same face and colour, on the baseline.
    private func amount(_ minorUnits: Int, currency: String, prefix: String = "", size: CGFloat = 15, weight: BalancedWeight = .text,
                        color: Color = BalancedPalette.ink, currencySymbol: Bool = false) -> Text {
        let font = Font.custom(weight.sansPostscriptName, size: size, relativeTo: size > 20 ? .title : .body)
        guard session.amountsVisible else { return Text("••••••").font(font).foregroundColor(color) }
        let number = MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: false)
        var text = Text(prefix).font(font).foregroundColor(color)
        if currencySymbol {
            text = text + Text(MoneyText.currencySymbol(for: currency))
                .font(.custom(weight.sansPostscriptName, size: size * 0.6, relativeTo: .body)).foregroundColor(color)
        }
        text = text + Text(number).font(font).foregroundColor(color)
        return (size > 20 ? text.tracking(-0.025 * size) : text).monospacedDigit()
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
        }
    }

    // MARK: Sections

    private func sectionHead(_ title: String, top: CGFloat = 26, @ViewBuilder aside: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).balancedFont(size: 15, weight: .medium).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
            Spacer(minLength: 0)
            aside()
        }.padding(EdgeInsets(top: top, leading: 20, bottom: 10, trailing: 20))
    }

    private func spending(_ breakdown: OverviewSpendingBreakdown) -> some View {
        let categories = breakdown.categories, total = breakdown.totalMinorUnits, currency = breakdown.currency
        return VStack(alignment: .leading, spacing: 0) {
            sectionHead(String(localized: "支出分类"), top: 18) {
                if !categories.isEmpty {
                    HStack(spacing: 4) {
                        amount(total, currency: currency, size: 12.5, weight: .regular, color: BalancedPalette.meta)
                        Text(currency).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
            if categories.isEmpty {
                Text(session.localOverviewCategoriesError ?? (session.isLocal && session.localOverviewCategories == nil ? String(localized: "正在读取支出排行…") : String(localized: "所选范围暂无支出")))
                    .balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).padding(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
            } else {
                spendingRow { Text("分类") } amount: { Text("金额") } share: { Text("占比") }
                    .balancedFont(size: 12, weight: .medium).foregroundStyle(BalancedPalette.meta)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { insetRule }
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
                    .overlay(alignment: .bottom) { insetRule }
                }
            }
        }
    }

    private func spendingRow(@ViewBuilder label: () -> some View, @ViewBuilder amount: () -> some View, @ViewBuilder share: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            label().frame(maxWidth: .infinity, alignment: .leading)
            amount().lineLimit(1).padding(.leading, 8)
            // Grows past 54pt at large text sizes instead of truncating "68.4%" to "68…".
            share().lineLimit(1).fixedSize().frame(minWidth: 54, alignment: .trailing).padding(.leading, 28)
        }.padding(.horizontal, 20)
    }

    private func recentTransactions(_ ledger: LedgerBootstrap, accountLabels: [String: String]) -> some View {
        let recent = Array(ledger.transactions.prefix(3))
        let days = recent.reduce(into: [(String, [LedgerTransaction])]()) { groups, tx in
            if groups.last?.0 == tx.date { groups[groups.count - 1].1.append(tx) } else { groups.append((tx.date, [tx])) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionHead(String(localized: "最近流水")) {
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
        return (String(format: "%02d/%02d", month, day), LedgerDateLabel.weekday(number: weekday))
    }
    private func comparisonSection(_ title: String, value: LedgerPeriodComparison, currency: String) -> some View { Section(title) { Text("对比 \(value.baselineRange.start) 至 \(value.baselineRange.end)"); if let v = value.current { LabeledContent("本期") { BalancedAmount(minorUnits: v, currency: currency) } }; if let v = value.baseline { LabeledContent("基期") { BalancedAmount(minorUnits: v, currency: currency) } }; if let v = value.delta { LabeledContent("变化金额") { BalancedAmount(minorUnits: v, currency: currency, prefix: v > 0 ? "+" : "") } }; LabeledContent("变化率", value: changeText(value)) } }
    private func changeText(_ c: LedgerPeriodComparison?) -> String { guard session.amountsVisible else { return "••••" }; guard let c, c.delta != nil else { return String(localized: "暂无数据") }; guard let p = c.percentage else { return String(localized: "基期为零") }; return String(format: "%+.1f%%", p * 100) }

    /// The engine lists the top four categories but values shares and the header
    /// against every category, so the header is its full total, not the rows' sum.
    private func localSpendingCategories(accountLabels: [String: String], fallbackCurrency: String) -> OverviewSpendingBreakdown {
        guard let response = session.localOverviewCategories,
              response.positiveTotalMinorUnits > 0 else {
            return OverviewSpendingBreakdown(categories: [], totalMinorUnits: 0, currency: fallbackCurrency)
        }
        let categories = response.categories.sorted {
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
        return OverviewSpendingBreakdown(categories: categories, totalMinorUnits: response.positiveTotalMinorUnits,
                                         currency: response.currency ?? fallbackCurrency)
    }

    /// Postings are valued into the summary currency the way the server values
    /// the 支出 row, so a JPY hotel is not shown as the same number of yuan.
    private func spendingCategories(
        from transactions: [LedgerTransaction],
        prices: [LedgerPrice],
        currency: String,
        accountLabels: [String: String]
    ) -> OverviewSpendingBreakdown {
        let valuation = LedgerPriceValuation(prices: prices)
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
            // A posting without a price path counts as zero, as in the server summary.
            let txExpense = expensePostings.reduce(0) {
                $0 &+ (valuation.value($1.amount, currency: $1.currency, in: currency) ?? 0)
            }

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
        guard overallExpense > 0 else {
            return OverviewSpendingBreakdown(categories: [], totalMinorUnits: 0, currency: currency)
        }

        let categories = positiveCategories
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
        return OverviewSpendingBreakdown(categories: categories, totalMinorUnits: overallExpense, currency: currency)
    }
}

private struct OverviewSpendingBreakdown {
    let categories: [OverviewCategorySpending]
    /// Header total: every positive category, including any the list leaves out.
    let totalMinorUnits: Int
    let currency: String
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
                Text(p.title).balancedFont(size: 15.5, weight: .text).tracking(-0.08).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                Text(p.subtitle).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(amountText(p)).font(.custom(BalancedWeight.medium.sansPostscriptName, size: 15.5, relativeTo: .body)).monospacedDigit()
                    .foregroundStyle(p.kind == .income ? BalancedPalette.income : BalancedPalette.ink).lineLimit(1).minimumScaleFactor(0.6)
                Text(p.kind == .transfer ? String(localized: "转账") : visual.categoryLabel).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta).lineLimit(1)
            }.frame(minWidth: 104, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(minHeight: 56)
        .overlay(alignment: .bottom) { if showsRule { BalancedPalette.rule.frame(height: 1).padding(.horizontal, 20) } }
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
