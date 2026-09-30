import Charts
import SwiftUI

/// Report sections use the same reading columns and rules as the approved terminal prototype.
struct TerminalReportSection<Content: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).terminalFont(size: 13, weight: .semibold)
                    .foregroundStyle(TerminalPalette.accent)
                Spacer(minLength: 8)
                Text(detail).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minHeight: 44)
            .accessibilityAddTraits(.isHeader)
            TerminalRule()
            content
        }
    }
}

struct TerminalReportMetric: View {
    let title: String
    let amount: Int?
    let currency: String
    var value: String? = nil
    var note: String = "所选期间"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).terminalFont(size: 13).foregroundStyle(TerminalPalette.secondary)
            if let amount {
                TerminalAmount(minorUnits: amount, currency: currency, size: 17)
            } else {
                Text(value ?? "暂无数据").terminalFont(size: 17, weight: .medium, design: .monospaced)
                    .foregroundStyle(TerminalPalette.ink)
            }
            Text(note).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 12)
    }
}

struct TerminalReportGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 1) {
            content.frame(maxHeight: .infinity, alignment: .topLeading).background(TerminalPalette.page)
        }
        .background(TerminalPalette.line)
        .overlay(alignment: .top) { TerminalRule() }
        .overlay(alignment: .bottom) { TerminalRule() }
    }
}

struct TerminalReportRow: View {
    let title: String
    var detail: String = ""
    let amount: Int
    let currency: String
    var annotation: String = ""
    var showsCurrency = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).terminalFont(size: 14, weight: .medium).foregroundStyle(TerminalPalette.ink)
                if !detail.isEmpty {
                    Text(detail).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                TerminalAmount(minorUnits: amount, currency: currency, size: 13, showsCurrency: showsCurrency)
                if !annotation.isEmpty {
                    Text(annotation).terminalFont(size: 11, design: .monospaced)
                        .foregroundStyle(TerminalPalette.secondary)
                }
            }
        }
        .padding(.vertical, 12).frame(minHeight: 48)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { TerminalRule() }
    }
}

/// Hiding amounts also hides chart geometry and derived ratios, not only labels.
private struct TerminalReportChart: View {
    @EnvironmentObject private var session: LedgerSession
    let points: [LedgerCashflowPoint]
    let currency: String
    var netOnly = false
    @State private var showsData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.amountsVisible {
                Text("金额已隐藏").terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else if points.isEmpty {
                Text("所选范围暂无趋势数据").terminalFont(size: 12)
                    .foregroundStyle(TerminalPalette.secondary).frame(minHeight: 100)
            } else {
                Chart(points) { point in
                    if netOnly {
                        LineMark(x: .value("月份", point.month), y: .value("结余", Double(point.net) / 100))
                            .foregroundStyle(TerminalPalette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("月份", point.month), y: .value("结余", Double(point.net) / 100))
                            .foregroundStyle(TerminalPalette.accent).symbolSize(14)
                    } else {
                        BarMark(x: .value("月份", point.month), y: .value("收入", Double(point.income) / 100))
                            .position(by: .value("类别", "收入")).foregroundStyle(TerminalPalette.ink)
                        BarMark(x: .value("月份", point.month), y: .value("支出", Double(point.expense) / 100))
                            .position(by: .value("类别", "支出")).foregroundStyle(TerminalPalette.accent)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(TerminalPalette.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TerminalPalette.secondary)
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartLegend(.hidden)
                .frame(height: 156)
                .accessibilityLabel(netOnly ? "结余趋势" : "月度收支")
                .accessibilityIdentifier(netOnly ? "terminal-net-chart" : "terminal-cashflow-chart")
                if !netOnly {
                    HStack(spacing: 16) {
                        legend("收入", color: TerminalPalette.ink)
                        legend("支出", color: TerminalPalette.accent)
                    }
                }
                DisclosureGroup("查看数据 · \(currency)", isExpanded: $showsData) {
                    ForEach(points) { point in
                        TerminalReportRow(title: point.month,
                            detail: netOnly ? "结余" : "收入 / 支出",
                            amount: netOnly ? point.net : point.income, currency: currency,
                            annotation: netOnly ? "" : MoneyText.format(minorUnits: point.expense, currency: currency))
                    }
                }.terminalFont(size: 12).tint(TerminalPalette.accent)
            }
        }.padding(.vertical, 12)
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(color).frame(width: 12, height: 4)
            Text(label).terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary)
        }
    }
}

struct TerminalIncomeExpenseReport: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerIncomeExpenseAnalysis
    @State private var incomeCategories = false
    @State private var eventsPresented = false
    @State private var selectedTag: String?
    private var statement: LedgerIncomeStatement { data.statement }
    private var currency: String { statement.valuationCurrency }
    private var savings: String {
        guard session.amountsVisible else { return "••••••" }
        guard statement.totalIncome > 0 else { return "暂无基数" }
        return (Double(statement.netIncome) / Double(statement.totalIncome)).formatted(.percent.precision(.fractionLength(1)))
    }
    private var events: [EventTagSummary] {
        if session.isLocal { return session.localEventTagSummaries ?? [] }
        return EventTagCalculator.summarizeAllTags(from: session.visibleTransactions,
            accountLabels: TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? []))
    }
    private var eventReadKey: String {
        "\(session.localGlobalSearchInvalidation)/\(session.phase)/\(session.privacyShielded)/\(session.isRangeLoading)/\(session.isValuationCurrencyLoading)/\(session.transactionMutationStates.values.contains(.pending))"
    }

    var body: some View {
        VStack(spacing: 16) {
            TerminalReportGrid {
                metric("收入", amount: statement.totalIncome, kind: .income)
                metric("支出", amount: statement.totalExpense, kind: .expense)
                metric("结余", amount: statement.netIncome, kind: .all)
                TerminalReportMetric(title: "储蓄率", amount: nil, currency: currency, value: savings, note: "结余 / 收入")
            }
            TerminalReportSection(title: "01 / 月度收支", detail: currency) {
                Text("按月汇总 · 转账不计收支").terminalFont(size: 11)
                    .foregroundStyle(TerminalPalette.secondary).padding(.top, 12)
                TerminalReportChart(points: data.dashboard.cashflowSeries, currency: currency)
            }
            TerminalReportSection(title: "02 / 结余趋势", detail: currency) {
                TerminalReportChart(points: data.dashboard.cashflowSeries, currency: currency, netOnly: true)
            }
            TerminalReportSection(title: "03 / 分类构成", detail: "金额 / 占比") {
                HStack(spacing: 0) {
                    categoryTab("支出", income: false)
                    categoryTab("收入", income: true)
                }
                if incomeCategories {
                    ForEach(statement.income) { node in
                        Button { session.navigateToTransactions(kind: .income, account: node.account) } label: {
                            TerminalReportRow(title: node.label, detail: "\(node.txCount) 笔",
                                amount: node.amount, currency: currency,
                                annotation: share(node.amount, total: statement.totalIncome))
                        }.buttonStyle(.plain)
                    }
                    if statement.income.isEmpty { empty("暂无收入分类") }
                } else {
                    ForEach(Array(statement.expenseAnalytics.enumerated()), id: \.element.id) { index, item in
                        Button { session.navigateToTransactions(kind: .expense, account: item.account) } label: {
                            TerminalReportRow(title: String(format: "%02d / ", index + 1) + item.label,
                                detail: "\(item.txCount) 笔" + categoryChange(item.changeRatio),
                                amount: item.amount, currency: currency,
                                annotation: share(item.amount, total: statement.totalExpense))
                        }.buttonStyle(.plain)
                    }
                    if statement.expenseAnalytics.isEmpty { empty("暂无支出分类") }
                }
            }
            TerminalReportSection(title: "04 / 商户排行", detail: "支出前 5 项") {
                ForEach(statement.topPayees.prefix(5)) { item in
                    Button { session.navigateToTransactions(query: item.payee) } label: {
                        TerminalReportRow(title: item.payee, detail: "\(item.txCount) 笔", amount: item.amount, currency: currency)
                    }.buttonStyle(.plain)
                }
                if statement.topPayees.isEmpty { empty("暂无商户数据") }
            }
            TerminalReportSection(title: "05 / 支付账户", detail: "前 5 项") {
                ForEach(statement.topPaymentAccounts.prefix(5)) { item in
                    Button { session.navigateToTransactions(account: item.account) } label: {
                        TerminalReportRow(title: item.label, detail: "\(item.txCount) 笔", amount: item.amount, currency: currency)
                    }.buttonStyle(.plain)
                }
            }
            TerminalReportSection(title: "06 / 事件与项目", detail: "独立核算") {
                if session.isLocal, let error = session.localEventTagSummaryError {
                    Text(error).terminalFont(size: 12)
                    Button("重试事件汇总") { Task { await session.loadLocalEventTagSummaries(force: true) } }
                } else if session.isLocal && session.localEventTagSummaries == nil {
                    ProgressView("正在统计事件与项目…").padding(.vertical, 12)
                }
                ForEach(events.prefix(3)) { event in
                    Button { selectedTag = event.tag } label: {
                        TerminalReportRow(title: "#" + event.tag, detail: "\(event.transactionCount) 笔",
                            amount: event.netSpend, currency: event.currency, showsCurrency: true)
                    }.buttonStyle(.plain)
                }
                Button("查看全部事件与项目") { eventsPresented = true }
                    .terminalFont(size: 12).frame(minHeight: 44).foregroundStyle(TerminalPalette.accent)
            }
            TerminalReportSection(title: "07 / 账户明细", detail: currency) {
                accountNodes(statement.income, kind: .income)
                accountNodes(statement.expense, kind: .expense)
            }
            if !data.dashboard.anomalies.isEmpty {
                TerminalReportSection(title: "08 / 需要留意", detail: "金额与历史模式") {
                    ForEach(data.dashboard.anomalies.prefix(4)) { item in
                        Button { session.navigateToTransactions(account: item.account) } label: {
                            TerminalReportRow(title: item.payee.isEmpty ? item.narration : item.payee,
                                detail: item.date, amount: item.amount, currency: data.dashboard.currency)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: eventReadKey) { if session.isLocal { await session.loadLocalEventTagSummaries() } }
        .sheet(isPresented: $eventsPresented) { EventTagListView().ledgerPrivacyProtectedSheet() }
        .sheet(isPresented: Binding(get: { selectedTag != nil }, set: { if !$0 { selectedTag = nil } })) {
            if let tag = selectedTag {
                NavigationStack {
                    EventTagReportView(tag: tag).toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("关闭") { selectedTag = nil } }
                    }
                }.ledgerPrivacyProtectedSheet()
            }
        }
    }

    private func metric(_ title: String, amount: Int, kind: TransactionKindFilter) -> some View {
        Button { session.navigateToTransactions(kind: kind) } label: {
            TerminalReportMetric(title: title, amount: amount, currency: currency, note: currency + " · 所选期间")
        }.buttonStyle(.plain)
    }
    private func share(_ amount: Int, total: Int) -> String {
        guard session.amountsVisible else { return "••••" }
        guard total > 0 else { return "暂无基数" }
        return (Double(amount) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
    }
    private func categoryChange(_ ratio: Double?) -> String {
        guard session.amountsVisible, let ratio, ratio.isFinite else { return "" }
        return " · 金额较上期 " + ratio.formatted(.percent.precision(.fractionLength(1)).sign(strategy: .always()))
    }
    private func categoryTab(_ label: String, income: Bool) -> some View {
        Button { incomeCategories = income } label: {
            Text(label).terminalFont(size: 13, weight: incomeCategories == income ? .semibold : .regular)
                .foregroundStyle(incomeCategories == income ? TerminalPalette.accent : TerminalPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(alignment: .bottom) {
                    if incomeCategories == income { Rectangle().fill(TerminalPalette.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(incomeCategories == income ? .isSelected : [])
    }
    private func flatten(_ nodes: [LedgerIncomeNode]) -> [LedgerIncomeNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
    private func accountNodes(_ nodes: [LedgerIncomeNode], kind: TransactionKindFilter) -> some View {
        ForEach(flatten(nodes)) { node in
            Button { session.navigateToTransactions(kind: kind, account: node.account) } label: {
                TerminalReportRow(title: node.label, detail: node.account, amount: node.amount, currency: currency)
                    .padding(.leading, CGFloat(min(node.depth, 3)) * 8)
            }.buttonStyle(.plain)
        }
    }
    private func empty(_ title: String) -> some View {
        Text(title).terminalFont(size: 12).foregroundStyle(TerminalPalette.secondary).padding(.vertical, 16)
    }
}

struct TerminalAssetsReport: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerAssetsAnalysis
    @State private var monthEnd = true
    @State private var showsHistory = false
    private var balances: [AccountBalance] {
        data.accountBalances.filter { $0.account.hasPrefix("Assets:") || $0.account.hasPrefix("Liabilities:") }
    }
    private var valuations: [String: Int] {
        Dictionary(grouping: balances.filter { $0.valuationMissing != true }, by: \.account)
            .mapValues { $0.reduce(0) { $0 + $1.valuation } }
    }
    private var assets: Int { valuations.filter { $0.key.hasPrefix("Assets:") }.values.reduce(0, +) }
    private var debt: Int { valuations.filter { $0.key.hasPrefix("Liabilities:") }.values.reduce(0) { $0 + abs($1) } }
    private var missing: Bool { balances.contains { $0.valuationMissing == true } }
    private var currency: String { data.valuationCurrency }
    private var points: [LedgerNetWorthPoint] {
        monthEnd && !data.monthEndNetWorth.isEmpty ? data.monthEndNetWorth : data.netWorthHistory
    }
    private var accountNames: [String] { Array(Set(balances.map(\.account))).sorted() }
    private var labels: [String: String] { TransactionCategoryPresentation.accountLabels(data.accounts) }

    var body: some View {
        VStack(spacing: 16) {
            TerminalReportGrid {
                TerminalReportMetric(title: "净资产", amount: assets - debt, currency: currency, note: missing ? "已知估值 · 部分缺价" : currency + " · 当前估值")
                TerminalReportMetric(title: "总资产", amount: assets, currency: currency, note: currency + " · 当前估值")
                TerminalReportMetric(title: "总负债", amount: debt, currency: currency, note: currency + " · 当前估值")
                TerminalReportMetric(title: "本月净值变化", amount: data.netWorthWindows?.monthChange, currency: currency, note: "较上月末 · 非所选期间")
            }
            if missing {
                Text("部分资产缺少价格，当前合计仅包含已知估值；缺价不按零估值。")
                    .terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
            }
            TerminalReportSection(title: "01 / 净资产历史", detail: currency) {
                HStack(spacing: 0) {
                    trendChoice("月末", value: true)
                    trendChoice("每日", value: false)
                }.padding(.vertical, 8)
                if !session.amountsVisible {
                    Text("金额已隐藏").terminalFont(size: 12).frame(minHeight: 156)
                } else if points.isEmpty {
                    Text("所选范围暂无净值趋势").terminalFont(size: 12).padding(.vertical, 24)
                } else {
                    let axis = LedgerChartAxis(labels: points.map(\.date), referenceLabel: session.selectedRange.start)
                    Chart(Array(points.enumerated()), id: \.element.id) { index, point in
                        LineMark(x: .value("日期", axis.position(at: index)), y: .value("净资产", Double(point.netWorth) / 100))
                            .foregroundStyle(TerminalPalette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("日期", axis.position(at: index)), y: .value("净资产", Double(point.netWorth) / 100))
                            .foregroundStyle(TerminalPalette.accent).symbolSize(10)
                    }
                    .chartXScale(domain: axis.domain)
                    .chartXAxis {
                        AxisMarks(values: axis.tickPositions(maxCount: 4)) { value in
                            AxisGridLine().foregroundStyle(TerminalPalette.line)
                            AxisValueLabel {
                                if let position = value.as(Double.self) {
                                    Text(axis.shortLabel(nearestTo: position)).font(.system(size: 10, design: .monospaced))
                                }
                            }
                        }
                    }
                    .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(TerminalPalette.line)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "zh_CN"))))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(TerminalPalette.secondary)
                            }
                        }
                    }
                }
                    .frame(height: 156).padding(.vertical, 12)
                    .accessibilityIdentifier("terminal-assets-chart")
                    DisclosureGroup("查看历史数据", isExpanded: $showsHistory) {
                        ForEach(points) { point in
                            TerminalReportRow(title: point.date, detail: "净资产", amount: point.netWorth, currency: currency)
                        }
                    }.terminalFont(size: 12).tint(TerminalPalette.accent).padding(.bottom, 12)
                }
            }
            TerminalReportSection(title: "02 / 资产负债构成", detail: "当前估值") {
                composition("资产", amount: assets)
                composition("负债", amount: debt)
                Text("占比以资产与负债绝对值之和为基数。净资产 = 资产 − 负债。")
                    .terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary).padding(.vertical, 8)
            }
            TerminalReportSection(title: "03 / 账户明细", detail: "当前 / 期间变化") {
                ForEach(accountNames, id: \.self) { account in
                    Button { session.navigateToTransactions(account: account) } label: {
                        accountRow(account)
                    }.buttonStyle(.plain)
                }
            }
            TerminalReportSection(title: "04 / 币种与折算", detail: currency) {
                ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(labels[balance.account] ?? balance.account).terminalFont(size: 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TerminalAmount(minorUnits: balance.amount, currency: balance.currency, size: 13, showsCurrency: true)
                        }
                        HStack {
                            Text(balance.currency + " → " + balance.valuationCurrency).terminalFont(size: 11)
                            Spacer()
                            if balance.valuationMissing == true {
                                Text("缺少价格").terminalFont(size: 11).foregroundStyle(TerminalPalette.accent)
                            } else {
                                TerminalAmount(minorUnits: balance.valuation, currency: balance.valuationCurrency, size: 12, showsCurrency: true)
                            }
                        }.foregroundStyle(TerminalPalette.secondary)
                    }.padding(.vertical, 12).overlay(alignment: .bottom) { TerminalRule() }
                }
                Text("折算采用账本提供的估值。价格日期与来源未提供时不作推断；内部转账不计入收支。")
                    .terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary).padding(.vertical, 12)
            }
        }
    }

    private func trendChoice(_ title: String, value: Bool) -> some View {
        Button { monthEnd = value } label: {
            Text(title).terminalFont(size: 13, weight: monthEnd == value ? .semibold : .regular)
                .foregroundStyle(monthEnd == value ? TerminalPalette.accent : TerminalPalette.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(monthEnd == value ? TerminalPalette.accent : TerminalPalette.line)
                        .frame(height: monthEnd == value ? 2 : 1)
                }
        }.buttonStyle(.plain).accessibilityAddTraits(monthEnd == value ? .isSelected : [])
    }

    private func composition(_ label: String, amount: Int) -> some View {
        HStack(spacing: 12) {
            Text(label).terminalFont(size: 12)
            GeometryReader { geometry in
                Rectangle().fill(TerminalPalette.line)
                if session.amountsVisible {
                    Rectangle().fill(label == "资产" ? TerminalPalette.accent : TerminalPalette.secondary)
                        .frame(width: geometry.size.width * min(1, max(0, Double(amount) / max(1, Double(abs(assets)) + Double(debt)))))
                }
            }.frame(height: 4)
            TerminalAmount(minorUnits: amount, currency: currency, size: 13)
        }.padding(.vertical, 12)
    }
    private func accountRow(_ account: String) -> some View {
        let rows = balances.filter { $0.account == account }
        let unavailable = rows.contains { $0.valuationMissing == true }
        let periodAvailable = rows.allSatisfy { $0.periodAvailable == true && $0.periodValuationMissing != true && $0.periodValuationChange != nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(labels[account] ?? account).terminalFont(size: 14, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if unavailable {
                    Text("缺少价格").terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
                } else {
                    TerminalAmount(minorUnits: valuations[account] ?? 0, currency: currency, size: 13)
                }
            }
            HStack(alignment: .top) {
                Text(account).terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                Spacer(minLength: 8)
                if periodAvailable {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("期间变化").terminalFont(size: 11)
                        TerminalAmount(minorUnits: rows.reduce(0) { $0 + ($1.periodValuationChange ?? 0) }, currency: currency, size: 11)
                    }
                } else { Text("暂无期间变化").terminalFont(size: 11) }
            }.foregroundStyle(TerminalPalette.secondary)
        }.padding(.vertical, 12).contentShape(Rectangle())
            .overlay(alignment: .bottom) { TerminalRule() }
    }
}

struct TerminalInvestmentsReport: View {
    @EnvironmentObject private var session: LedgerSession
    let data: LedgerInvestmentSummary

    private var totalCost: Int? {
        guard !data.holdings.isEmpty, data.holdings.allSatisfy({ $0.totalCostValueCny != nil }) else { return nil }
        return data.holdings.reduce(0) { $0 + ($1.totalCostValueCny ?? 0) }
    }
    private var unrealized: Int? {
        guard let totalCost, data.holdings.allSatisfy({ $0.totalMarketValueCny != nil }) else { return nil }
        return data.totalMarketValueCny - totalCost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TerminalReportGrid {
                TerminalReportMetric(title: "持仓市值", amount: data.totalMarketValueCny, currency: "CNY", note: "当前估值 / CNY")
                TerminalReportMetric(title: "持仓成本", amount: totalCost, currency: "CNY", note: "缺失成本时不估算")
                TerminalReportMetric(title: "浮动收益", amount: unrealized, currency: "CNY", note: "市值减持仓成本")
                TerminalReportMetric(title: "已实现收益", amount: data.realizedPnlCny, currency: "CNY", note: "所选期间 / CNY")
            }
            TerminalReportSection(title: "01 / 当前持仓", detail: "\(data.holdings.count) 个品种") {
                if data.holdings.isEmpty {
                    Text("暂无投资持仓").terminalFont(size: 13).padding(.vertical, 24)
                }
                ForEach(data.holdings) { holding in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(holding.commodityName.isEmpty ? holding.commodity : holding.commodityName)
                                .terminalFont(size: 14, weight: .medium)
                            Spacer()
                            if let market = holding.totalMarketValueCny {
                                TerminalAmount(minorUnits: market, currency: "CNY", size: 14)
                            } else {
                                Text("缺少估值").terminalFont(size: 12).foregroundStyle(TerminalPalette.accent)
                            }
                        }
                        Text(holding.commodity + " · " + (session.amountsVisible ? holding.totalQuantity.formatted() : "••••") + " · \(holding.accountCount) 个账户")
                            .terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
                        if let cost = holding.totalCostValueCny {
                            HStack {
                                Text("成本").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                                TerminalAmount(minorUnits: cost, currency: "CNY", size: 12)
                                Spacer()
                                if let market = holding.totalMarketValueCny {
                                    Text("浮动").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                                    TerminalAmount(minorUnits: market - cost, currency: "CNY", color: market >= cost ? TerminalPalette.positive : TerminalPalette.negative, size: 12)
                                }
                            }
                        } else {
                            Text("成本缺失").terminalFont(size: 11).foregroundStyle(TerminalPalette.secondary)
                        }
                    }.padding(.vertical, 12)
                    TerminalRule()
                }
            }
            TerminalReportSection(title: "02 / 账户持仓", detail: "\(data.positions.count) 项") {
                ForEach(data.positions) { position in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(position.accountLabel.isEmpty ? position.account : position.accountLabel)
                            .terminalFont(size: 13, weight: .medium)
                        HStack {
                            Text(position.commodity + " · " + (session.amountsVisible ? position.quantity.formatted() : "••••"))
                                .terminalFont(size: 11, design: .monospaced).foregroundStyle(TerminalPalette.secondary)
                            Spacer()
                            if let market = position.marketValueCny {
                                TerminalAmount(minorUnits: market, currency: "CNY", size: 13)
                            } else {
                                Text("缺少估值").terminalFont(size: 11).foregroundStyle(TerminalPalette.accent)
                            }
                        }
                    }.padding(.vertical, 12)
                    TerminalRule()
                }
                if data.positions.isEmpty { Text("暂无账户持仓明细").terminalFont(size: 13).padding(.vertical, 24) }
            }
        }.foregroundStyle(TerminalPalette.ink)
    }
}
