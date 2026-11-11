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
                    retentionHero(ledger); cashflow(ledger); periodStats(ledger)
                    // An older server sends no trend; the module stays out rather than claim an empty ledger.
                    if !ledger.monthlyExpenseTrend.isEmpty {
                        OverviewSpendingTrend(points: ledger.monthlyExpenseTrend, currency: ledger.summary.currency)
                    }
                    let breakdown = session.isLocal
                        ? localSpendingCategories(accountLabels: labels, fallbackCurrency: ledger.summary.currency)
                        : spendingCategories(from: ledger.transactions, prices: ledger.prices,
                                             currency: ledger.summary.currency, accountLabels: labels)
                    spending(breakdown)
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

    /// 本期指标: six figures drawn from data the page already holds (bootstrap
    /// summary, comparisons, net-worth windows, the category aggregate), so the
    /// grid appears with the page and never shows a loading state of its own.
    private func periodStats(_ ledger: LedgerBootstrap) -> some View {
        let range = session.selectedRange, currency = ledger.summary.currency
        let transactionStats = session.overviewTransactionStats
        let stats = OverviewPeriodStats(start: range.start, end: range.end, today: LedgerDateRange.today(now: session.now),
            summary: ledger.summary, comparisons: ledger.comparisons, netWorthWindows: ledger.netWorthWindows,
            transactionCount: transactionStats?.transactionCount)
        let baseline = stats.isInProgress ? String(localized: "比上月同期") : String(localized: "比上月")
        return VStack(alignment: .leading, spacing: 0) {
            sectionHead(String(localized: "本期指标")) { EmptyView() }
            statRow {
                statTile(String(localized: "日均支出"),
                         value: stats.dailyExpense.map { amount($0, currency: currency, size: 18, weight: .medium) } ?? dash,
                         caption: stats.elapsedDays.map { stats.isInProgress ? String(localized: "已过 \($0) 天") : String(localized: "共 \($0) 天") }
                            ?? String(localized: "期间未开始"))
            } trailing: {
                statTile(String(localized: "记账笔数"),
                         value: stats.transactionCount.map { Text(String(localized: "\($0) 笔")).font(statFont).foregroundColor(BalancedPalette.ink) } ?? dash,
                         caption: {
                            guard let count = stats.transactionCount, let days = stats.elapsedDays, days > 0 else { return String(localized: "本期交易") }
                            return String(localized: "日均 \(String(format: "%.1f", Double(count) / Double(days))) 笔")
                         }())
            }
            statRow {
                comparisonTile(String(localized: "支出环比"), stats.expenseMonthOverMonth, baseline: baseline,
                               currency: currency, details: ledger.comparisons.map { (String(localized: "支出"), $0.expense) })
            } trailing: {
                comparisonTile(String(localized: "收入环比"), stats.incomeMonthOverMonth, baseline: baseline,
                               currency: currency, details: ledger.comparisons.map { (String(localized: "收入"), $0.income) })
            }
            statRow {
                let highest = transactionStats?.highestExpense
                statTile(String(localized: "最大一笔"),
                         value: highest.map { amount($0.minorUnits, currency: currency, size: 18, weight: .medium) } ?? dash,
                         caption: highest?.title ?? String(localized: "本期暂无支出"))
            } trailing: {
                statTile(String(localized: "净资产"),
                         value: stats.netWorth.map { amount(abs($0), currency: currency, prefix: $0 < 0 ? "−" : "", size: 18, weight: .medium) } ?? dash,
                         caption: stats.netWorthMonthChange.map { change in
                            guard session.amountsVisible else { return String(localized: "较上月末 ••••") }
                            let sign = change > 0 ? "+" : change < 0 ? "−" : ""
                            return String(localized: "较上月末 \(sign + MoneyText.format(minorUnits: abs(change), currency: currency, showsCurrency: false))")
                         } ?? String(localized: "暂无上月末数据"))
            }
        }
    }

    private var statFont: Font { .custom(BalancedWeight.medium.sansPostscriptName, size: 18, relativeTo: .title3) }
    private var dash: Text { Text("—").font(statFont).foregroundColor(BalancedPalette.meta) }

    private func statRow(@ViewBuilder leading: () -> some View, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            leading().frame(maxWidth: .infinity, alignment: .leading)
            trailing().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .top) { insetRule }
    }

    private func statTile(_ title: String, value: Text, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
            value.monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(caption).balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// A change in percent over the delta in money. Opens the 比较口径 sheet,
    /// which spells out both ranges and the year-over-year figure.
    @ViewBuilder
    private func comparisonTile(_ title: String, _ comparison: LedgerPeriodComparison?, baseline: String,
                                currency: String, details: (String, LedgerMetricPeriodComparisons)?) -> some View {
        let value: Text = {
            guard let comparison else { return dash }
            guard session.amountsVisible else { return Text("••••").font(statFont).foregroundColor(BalancedPalette.ink) }
            guard let percentage = comparison.percentage else { return Text(String(localized: "基期为零")).font(statFont).foregroundColor(BalancedPalette.meta) }
            return Text(String(format: "%+.1f%%", percentage * 100)).font(statFont).foregroundColor(BalancedPalette.ink)
        }()
        let caption: String = {
            guard let comparison, let delta = comparison.delta else { return String(localized: "暂无可比数据") }
            guard session.amountsVisible else { return baseline }
            let sign = delta > 0 ? "+" : delta < 0 ? "−" : ""
            return baseline + " " + sign + MoneyText.format(minorUnits: abs(delta), currency: currency, showsCurrency: false)
        }()
        let tile = statTile(title, value: value, caption: caption)
        if let details, comparison != nil {
            Button {
                comparisonDetails = OverviewComparisonDetails(title: details.0, comparisons: details.1, currency: currency)
            } label: { tile.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityHint(Text("查看比较口径"))
        } else {
            tile
        }
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


/// Monthly expense bars (design: docs/design/ios-balanced/home-trend.html, variant A).
/// Only the selected bar carries the expense colour; the month in progress adds a
/// dashed, hatched box for its month-end estimate, and a dotted rule marks the
/// mean of the ended months.
private struct OverviewSpendingTrend: View {
    @EnvironmentObject private var session: LedgerSession
    let points: [LedgerMonthlyExpensePoint]
    let currency: String
    @State private var window = OverviewExpenseTrend.windows[0]
    /// Nil follows the last bar, which is the period the page is showing.
    @State private var selection: Int?

    private static let plotTop: CGFloat = 22
    private static let plotHeight: CGFloat = 104
    private static let labelHeight: CGFloat = 24

    var body: some View {
        let trend = OverviewExpenseTrend(points: points, months: window, today: session.now)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Text("支出趋势").balancedFont(size: 15, weight: .medium).tracking(-0.12).foregroundStyle(BalancedPalette.ink)
                Spacer(minLength: 0)
                // A twelve-month window over six months of history draws the same chart.
                if trend != nil, points.count > OverviewExpenseTrend.windows[0] { windowPicker }
            }.padding(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
            if let trend, let selected = trend.bars.first(where: { $0.id == selection }) ?? trend.bars.last {
                summary(trend, selected: selected)
                chart(trend, selected: selected)
                footer(trend, selected: selected)
            } else {
                Text("记满两个月后显示趋势").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                    .padding(EdgeInsets(top: 4, leading: 20, bottom: 12, trailing: 20))
            }
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 0) {
            ForEach(OverviewExpenseTrend.windows, id: \.self) { months in
                let isOn = months == window
                Button {
                    withLedgerAnimation(LedgerMotion.segment) { window = months; selection = nil }
                } label: {
                    Text(String(localized: "\(months) 月")).balancedFont(size: 12).monospacedDigit()
                        .foregroundStyle(isOn ? BalancedPalette.page : BalancedPalette.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(isOn ? BalancedPalette.ink : Color.clear)
                        .overlay(alignment: .leading) { if months != OverviewExpenseTrend.windows[0] { BalancedPalette.edge.frame(width: 1) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "近 \(months) 月")))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(BalancedPalette.edge, lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(minHeight: 44).contentShape(Rectangle())
        .padding(.vertical, -12)
    }

    // MARK: Summary

    private func summary(_ trend: OverviewExpenseTrend, selected bar: OverviewExpenseTrend.Bar) -> some View {
        let inProgress = isInProgress(bar, in: trend)
        let month = LedgerDateLabel.month(number: bar.month)
        let figure: Text = session.amountsVisible
            ? Text(money(bar.expense)).font(.custom(BalancedWeight.medium.sansPostscriptName, size: 20, relativeTo: .title3))
                .tracking(-0.3).foregroundColor(BalancedPalette.ink)
            : Text("••••••").font(.custom(BalancedWeight.medium.sansPostscriptName, size: 20, relativeTo: .title3)).foregroundColor(BalancedPalette.ink)
        let caption: String = {
            if let progress = trend.progress, inProgress {
                return String(localized: "\(month)至今 · 第 \(progress.day)/\(progress.days) 天")
            }
            return Self.yearMonth(year: bar.year, month: bar.month)
        }()
        let detail: Text? = {
            guard session.amountsVisible else { return nil }
            let change = trend.change(of: bar).map(Self.changeText)
            if inProgress, let projected = bar.projected {
                let pace = Text(String(localized: "按当前节奏约 \(money(projected))"))
                guard let change else { return pace }
                return pace + Text("，") + Text(change).foregroundColor(BalancedPalette.secondary)
            }
            return change.map { Text($0).foregroundColor(BalancedPalette.secondary) }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            (figure + Text("  ") + Text(caption)).lineLimit(1).minimumScaleFactor(0.7)
            if let detail { detail.lineLimit(1).minimumScaleFactor(0.8) }
        }
        .balancedFont(size: 13).monospacedDigit().foregroundStyle(BalancedPalette.meta)
        .frame(minHeight: 40, alignment: .topLeading)
        .padding(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private func chart(_ trend: OverviewExpenseTrend, selected: OverviewExpenseTrend.Bar) -> some View {
        let scale = Double(trend.scaleMaximum) * 1.08
        let base = Self.plotTop + Self.plotHeight
        let y: (Int) -> CGFloat = { base - CGFloat(Double($0) / scale) * Self.plotHeight }
        return GeometryReader { proxy in
            let width = proxy.size.width
            let band = width / CGFloat(trend.bars.count)
            let barWidth = min(22, band * 0.5)
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    BalancedPalette.ruleStrong.frame(width: width, height: 1).offset(y: base)
                    ForEach(Array(trend.bars.enumerated()), id: \.element.id) { index, bar in
                        let isSelected = bar == selected
                        let fill = isSelected ? BalancedPalette.expense : BalancedPalette.edge
                        let left = band * CGFloat(index) + (band - barWidth) / 2
                        if let projected = bar.projected, projected > bar.expense {
                            let top = UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            HatchFill().stroke(fill.opacity(0.35), lineWidth: 1).clipShape(top)
                                .overlay { top.inset(by: 0.75).stroke(fill, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])) }
                                .frame(width: barWidth, height: max(0, y(bar.expense) - y(projected)))
                                .offset(x: left, y: y(projected))
                            Rectangle().fill(fill)
                                .frame(width: barWidth, height: base - y(bar.expense)).offset(x: left, y: y(bar.expense))
                        } else {
                            UnevenRoundedRectangle(topLeadingRadius: min(4, (base - y(bar.expense)) / 2), topTrailingRadius: min(4, (base - y(bar.expense)) / 2))
                                .fill(fill)
                                .frame(width: barWidth, height: base - y(bar.expense)).offset(x: left, y: y(bar.expense))
                        }
                        // Twelve labels crowd a phone; every other month, and always the selected one.
                        if trend.bars.count <= 6 || index % 2 == 0 || isSelected {
                            Text(LedgerDateLabel.month(number: bar.month))
                                .balancedFont(size: 11.5, weight: isSelected ? .semibold : .regular).monospacedDigit()
                                .foregroundStyle(isSelected ? BalancedPalette.ink : BalancedPalette.meta)
                                .fixedSize()
                                .frame(width: band).offset(x: band * CGFloat(index), y: base + 5)
                        }
                    }
                    if let average = trend.average, average > 0 {
                        averageRule(width: width, y: y(average), average: average)
                    }
                    if session.amountsVisible, let index = trend.bars.firstIndex(of: selected) {
                        let value = selected.projected ?? selected.expense
                        let center = band * (CGFloat(index) + 0.5)
                        Text((selected.projected != nil ? String(localized: "约") + " " : "") + compact(value))
                            .balancedFont(size: 11.5, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                            .fixedSize()
                            // Centred on its bar, slid inward by its own width at either edge.
                            .alignmentGuide(.leading) { label in -min(max(center - label.width / 2, 0), width - label.width) }
                            .alignmentGuide(.top) { label in -(y(value) - 6 - label.height) }
                    }
                }
                .accessibilityHidden(true)
                ForEach(Array(trend.bars.enumerated()), id: \.element.id) { index, bar in
                    Color.clear.contentShape(Rectangle())
                        .frame(width: band, height: base + Self.labelHeight).offset(x: band * CGFloat(index))
                        .onTapGesture { select(bar, in: trend) }
                        .accessibilityElement()
                        .accessibilityLabel(Text(LedgerDateLabel.month(number: bar.month)))
                        .accessibilityValue(Text(accessibilityValue(bar, in: trend)))
                        .accessibilityAddTraits(bar == selected ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { select(bar, in: trend) }
                }
            }
        }
        .frame(height: base + Self.labelHeight)
        .padding(.horizontal, 20).padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "近 \(trend.bars.count) 月支出")))
    }

    private func averageRule(width: CGFloat, y: CGFloat, average: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y)) }
                .stroke(BalancedPalette.meta, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            Text(session.amountsVisible ? String(localized: "均") + " " + compact(average) : String(localized: "均值"))
                .balancedFont(size: 11).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                .fixedSize()
                .padding(.horizontal, 2).background(BalancedPalette.page)
                .offset(y: y - 16)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Footer

    private func footer(_ trend: OverviewExpenseTrend, selected: OverviewExpenseTrend.Bar) -> some View {
        let notes: [String] = [
            trend.average.flatMap { average -> String? in
                guard average > 0 else { return nil }
                let months = trend.progress == nil ? trend.bars.count : trend.bars.count - 1
                return String(localized: "近 \(months) 月均值") + " " + (session.amountsVisible ? money(average) : "••••")
            },
            trend.bars.last?.projected == nil ? nil : String(localized: "虚线框为外推"),
        ].compactMap { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(notes.joined(separator: " · ")).balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if !isShowing(selected) {
                Button {
                    Task { await session.applyRange(.month(year: selected.year, month: selected.month)) }
                } label: {
                    Text("查看该月").balancedFont(size: 12).foregroundStyle(BalancedPalette.secondary)
                        .padding(.bottom, 1).overlay(alignment: .bottom) { BalancedPalette.ruleStrong.frame(height: 1) }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, -16)
                .disabled(session.isRangeLoading)
                .accessibilityLabel(Text(String(localized: "查看 \(Self.yearMonth(year: selected.year, month: selected.month))")))
            }
        }
        .padding(EdgeInsets(top: 6, leading: 20, bottom: 4, trailing: 20))
    }

    // MARK: Helpers

    private func select(_ bar: OverviewExpenseTrend.Bar, in trend: OverviewExpenseTrend) {
        withLedgerAnimation(LedgerMotion.selection) { selection = bar == trend.bars.last ? nil : bar.id }
    }

    private func isInProgress(_ bar: OverviewExpenseTrend.Bar, in trend: OverviewExpenseTrend) -> Bool {
        trend.progress != nil && bar == trend.bars.last
    }

    /// True when the page already shows exactly this month.
    private func isShowing(_ bar: OverviewExpenseTrend.Bar) -> Bool {
        session.selectedRange == .month(year: bar.year, month: bar.month)
    }

    private func money(_ minorUnits: Int) -> String {
        MoneyText.currencySymbol(for: currency) + MoneyText.format(minorUnits: minorUnits, currency: currency, showsCurrency: false)
    }

    /// Chart labels are a scale, not a figure: no cents, compact once it reaches 万.
    private func compact(_ minorUnits: Int) -> String {
        abs(minorUnits) >= 1_000_000
            ? MoneyText.formatCompact(minorUnits: minorUnits, currency: currency)
            : MoneyText.format(minorUnits: minorUnits, currency: currency, maximumFractionDigits: 0)
    }

    private func accessibilityValue(_ bar: OverviewExpenseTrend.Bar, in trend: OverviewExpenseTrend) -> String {
        guard session.amountsVisible else { return String(localized: "金额已隐藏") }
        var parts = [String(localized: "支出 \(MoneyText.format(minorUnits: bar.expense, currency: currency))")]
        if isInProgress(bar, in: trend), let projected = bar.projected {
            parts.append(String(localized: "预计全月约 \(MoneyText.format(minorUnits: projected, currency: currency))"))
        }
        if let change = trend.change(of: bar) { parts.append(Self.changeText(change)) }
        return parts.joined(separator: "，")
    }

    private static func changeText(_ change: Double) -> String {
        let percent = Int((abs(change) * 100).rounded())
        if percent == 0 { return String(localized: "与均值持平") }
        return change > 0 ? String(localized: "高于均值 \(percent)%") : String(localized: "低于均值 \(percent)%")
    }

    private static func yearMonth(year: Int, month: Int) -> String {
        guard let date = LedgerDateRange.calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "\(year)-\(month)" }
        return date.formatted(.dateTime.year().month(.wide).locale(LedgerLocale.current))
    }
}

/// 45° hatching for the month-end estimate, 5pt apart.
private struct HatchFill: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        return path
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

private struct OverviewComparisonDetails: Identifiable { var id: String { title }; let title: String; let comparisons: LedgerMetricPeriodComparisons; let currency: String }
