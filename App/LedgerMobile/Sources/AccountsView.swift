import Charts
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedCategory = AccountBalanceCategory.all
    @State private var expandedSectionIDs: Set<String> = []
    var isRoot = true

    private var activeExpandedSectionIDs: Set<String> {
        expandedSectionIDs
    }

    private var allVisibleSectionsExpanded: Bool {
        !sections.isEmpty && sections.allSatisfy { activeExpandedSectionIDs.contains($0.id) }
    }

    private var sections: [AccountBalanceSection] {
        guard let ledger = session.ledger else { return [] }
        return ledger.accountSections(
            periodBalancesAvailable: session.accountPeriodBalancesAvailable && ledger.periodAccountBalancesAvailable
        ).compactMap { section in
            let rows = section.rows.filter { row in
                selectedCategory.includes(row)
            }
            return rows.isEmpty ? nil : AccountBalanceSection(id: section.id, title: section.title, rows: rows)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("账户分类", selection: $selectedCategory) {
                    ForEach(AccountBalanceCategory.allCases) { category in
                        Text(category.title)
                            .tag(category)
                            .accessibilityIdentifier("account-filter-\(category.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("account-category-picker")
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let error = session.errorMessage {
                Section { StatusBanner(message: error, onDismiss: session.dismissError) }
            }
            if !sections.isEmpty {
                HStack {
                    Text("\(sections.count) 个分组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(allVisibleSectionsExpanded ? "全部折叠" : "全部展开") {
                        let visibleIDs = Set(sections.map(\.id))
                        setExpandedSectionIDs(allVisibleSectionsExpanded
                            ? activeExpandedSectionIDs.subtracting(visibleIDs)
                            : activeExpandedSectionIDs.union(visibleIDs))
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("account-groups-toggle-all")
                }
                .listRowSeparator(.hidden)
            }
            ForEach(sections) { section in
                Section {
                    DisclosureGroup(isExpanded: expandedBinding(for: section.id)) {
                        ForEach(section.rows) { row in
                            NavigationLink {
                                AccountDetailView(account: row.account, currency: row.nativeCurrency)
                            } label: {
                                AccountRowView(row: row)
                            }
                        }
                    } label: {
                        Label {
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                : AnyLayout(HStackLayout())
                            layout {
                                Text(section.title).font(.subheadline.weight(.medium))
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                                    Text("\(section.rows.count) 个账户").font(.caption).foregroundStyle(.secondary)
                                    AmountLabel(
                                        minorUnits: section.rows.filter {
                                            $0.periodBalancesAvailable ? !$0.periodValuationMissing : !$0.valuationMissing
                                        }.reduce(0) { $0 + ($1.periodBalancesAvailable ? $1.closingValuation : $1.valuation) },
                                        currency: session.ledger?.valuationCurrency ?? "CNY",
                                        font: .subheadline.weight(.medium)
                                    )
                                }
                            }
                        } icon: {
                            Image(systemName: AccountGroupSymbol.symbol(for: section.id))
                                .foregroundStyle(LedgerPalette.cobalt)
                        }
                    }
                    .accessibilityIdentifier("account-group-\(section.id)")
                }
            }
            if sections.isEmpty {
                ContentUnavailableView("暂无匹配账户", systemImage: "building.columns", description: Text("切换分类或调整搜索条件。"))
            }
        }
        .ledgerReadingList()
        .accessibilityIdentifier("accounts-list")
        .ledgerNavigation("账户", isRoot: isRoot, showsTimeRange: true)
        .refreshable { await session.refresh() }
    }

    private func setExpandedSectionIDs(_ ids: Set<String>) {
        expandedSectionIDs = ids
    }

    private func expandedBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: { activeExpandedSectionIDs.contains(sectionID) },
            set: { expanded in
                var ids = activeExpandedSectionIDs
                if expanded { ids.insert(sectionID) }
                else { ids.remove(sectionID) }
                setExpandedSectionIDs(ids)
            }
        )
    }
}

private enum AccountGroupSymbol {
    static func symbol(for group: String) -> String {
        switch group {
        case "cash": "wallet.bifold"
        case "credit": "creditcard"
        case "liability": "creditcard.trianglebadge.exclamationmark"
        case "wealth": "chart.line.uptrend.xyaxis"
        case "receivable": "arrow.down.left.circle"
        case "asset": "building.columns"
        case "expense": "cart"
        case "income": "arrow.down.circle"
        case "equity": "scalemass"
        default: "folder"
        }
    }

    static func title(for group: String) -> String {
        switch group {
        case "cash": "现金与支付"
        case "credit": "信用账户"
        case "liability": "负债"
        case "wealth": "储蓄与资产"
        case "receivable": "应收"
        case "asset": "资产"
        case "expense": "支出账户"
        case "income": "收入账户"
        case "equity": "权益"
        default: "其他"
        }
    }
}

struct AccountDetailView: View {
    @EnvironmentObject private var session: LedgerSession
    let account: String
    let currency: String

    @State private var detail: LedgerAccountDetail?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

    private var requestKey: AccountDetailRequestKey {
        AccountDetailRequestKey(
            account: account,
            currency: currency,
            start: session.selectedRange.start,
            end: session.selectedRange.end,
            reloadToken: reloadToken
        )
    }

    var body: some View {
        Group {
            if let detail {
                detailContent(detail)
            } else if let errorMessage {
                VStack(spacing: LedgerSpacing.lg) {
                    EmptyLedgerState(
                        icon: "exclamationmark.triangle",
                        title: "账户详情加载失败",
                        detail: errorMessage
                    )
                    Button("重新加载") {
                        reloadToken += 1
                    }
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.onBrand)
                    .padding(.horizontal, LedgerSpacing.xl)
                    .frame(minHeight: 44)
                    .background(LedgerPalette.cobalt)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                    .buttonStyle(PressScaleButtonStyle())
                    .padding(.bottom, LedgerSpacing.xxl)
                }
            } else {
                VStack(spacing: LedgerSpacing.md) {
                    ProgressView()
                        .tint(LedgerPalette.cobalt)
                    Text("正在加载账户详情")
                        .font(.system(.caption, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(detail?.label ?? account.split(separator: ":").last.map(String.init) ?? account)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { LedgerTimeRangeButton() }
        }
        .toolbar(.visible, for: .navigationBar)

        .task(id: requestKey) {
            await load(replacingContent: detail == nil)
        }
    }

    private func detailContent(_ detail: LedgerAccountDetail) -> some View {
        let accountLabels = TransactionCategoryPresentation.accountLabels(session.ledger?.accounts ?? [])
        return ScrollView {
            LazyVStack(spacing: LedgerSpacing.md) {
                AccountDetailHero(detail: detail, range: session.selectedRange)

                if let errorMessage {
                    StatusBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                AccountBalanceTrendPanel(detail: detail, range: session.selectedRange)

                HStack(alignment: .firstTextBaseline) {
                    Text("账户流水")
                        .font(.system(.body, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Text("\(detail.rows.count) 笔")
                        .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.top, LedgerSpacing.sm)

                if detail.rows.isEmpty {
                    Text("这个账户暂无关联流水。")
                        .font(.system(.footnote, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    LedgerPanel {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(detail.rows.reversed().enumerated()), id: \.element.id) { index, row in
                                NavigationLink {
                                    TransactionDetailView(transaction: row.transaction)
                                } label: {
                                    AccountHistoryRow(row: row, currency: detail.currency, accountLabels: accountLabels)
                                }
                                .buttonStyle(PressScaleButtonStyle())

                                if index < detail.rows.count - 1 {
                                    Divider()
                                        .overlay(LedgerPalette.line)
                                        .padding(.leading, LedgerSpacing.lg)
                                }
                            }
                        }
                    }
                }
            }
            .padding(LedgerSpacing.lg)
            .padding(.bottom, LedgerSpacing.xxl)
            .ledgerAdaptivePageWidth()
        }
        .refreshable { await load(replacingContent: false) }
    }

    private func load(replacingContent: Bool = true) async {
        if replacingContent {
            detail = nil
        }
        errorMessage = nil
        do {
            let updatedDetail = try await session.accountDetail(for: account, currency: currency)
            guard !Task.isCancelled else { return }
            detail = updatedDetail
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountDetailRequestKey: Hashable {
    let account: String
    let currency: String
    let start: String
    let end: String
    let reloadToken: Int
}

private struct AccountDetailHero: View {
    let detail: LedgerAccountDetail
    let range: LedgerDateRange

    private var openingBalance: Int {
        detail.openingBalance ?? detail.rows.first.map { $0.balance - $0.change } ?? detail.currentBalance
    }

    private var closingBalance: Int {
        detail.closingBalance ?? detail.rows.last?.balance ?? openingBalance
    }

    private var periodChange: Int {
        detail.periodChange ?? (closingBalance - openingBalance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            HStack(alignment: .top, spacing: LedgerSpacing.md) {
                Image(systemName: AccountGroupSymbol.symbol(for: detail.group))
                    .font(.system(.headline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 46, height: 46)
                    .background(LedgerPalette.tag)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: LedgerSpacing.sm) {
                        Text(AccountGroupSymbol.title(for: detail.group))
                        Text("·")
                        Text(detail.currency)
                    }
                    .font(.system(.caption2, design: .default, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !detail.active {
                    Text("已关闭")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .background(LedgerPalette.raised)
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.account.hasPrefix("Liabilities:") ? "\(range.metricScope)期末待还" : "\(range.metricScope)期末余额")
                    .font(.system(.caption2, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.secondary)
                AmountLabel(
                    minorUnits: closingBalance,
                    currency: detail.currency,
                    font: .title2.weight(.semibold),
                    color: detail.account.hasPrefix("Liabilities:")
                        ? LedgerPalette.expense
                        : LedgerPalette.gold
                )
                .tracking(-0.75)
                .lineLimit(1)
            }

            HStack(spacing: LedgerSpacing.xl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("期初余额")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: openingBalance,
                        currency: detail.currency,
                        font: .system(.caption, design: .default, weight: .semibold),
                        color: LedgerPalette.olive
                    )
                    .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("期间变化")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: periodChange,
                        currency: detail.currency,
                        prefix: periodChange > 0 ? "+" : "",
                        font: .system(.caption, design: .default, weight: .semibold),
                        color: periodChange >= 0 ? LedgerPalette.income : LedgerPalette.expense
                    )
                    .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let alias = detail.alias, alias != detail.label {
                    Text(alias)
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.olive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail.account)
                    .font(.system(.caption2, design: .default, weight: .medium).monospaced())
                    .foregroundStyle(LedgerPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

private struct AccountBalanceTrendPanel: View {
    @EnvironmentObject private var session: LedgerSession
    let detail: LedgerAccountDetail
    let range: LedgerDateRange

    @State private var selectedIndex: Int?

    private var points: [LedgerAccountBalanceTrendPoint] {
        detail.balanceTrend(in: range, maxPoints: 180)
    }

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.date), referenceLabel: points.first?.date)
    }

    private var periodChange: Int? {
        detail.periodChange ?? points.first.flatMap { first in
            points.last.map { $0.balance - first.balance }
        }
    }

    var body: some View {
        LedgerPanel {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("余额趋势")
                            .font(.system(.body, design: .default, weight: .semibold))
                            .tracking(-0.15)
                            .foregroundStyle(LedgerPalette.ink)
                        Text(rangeLabel)
                            .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Spacer()
                    if let periodChange {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("期间变化")
                                .font(.system(.caption2, design: .default, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                            AmountLabel(
                                minorUnits: periodChange,
                                currency: detail.currency,
                                prefix: periodChange > 0 ? "+" : "",
                                font: .system(.caption2, design: .default, weight: .semibold),
                                color: periodChange >= 0 ? LedgerPalette.income : LedgerPalette.expense
                            )
                            .lineLimit(1)
                        }
                    }
                }

                if points.isEmpty {
                    trendEmptyState
                } else if session.amountsVisible {
                    trendChart
                } else {
                    hiddenTrendState
                }
            }
            .padding(LedgerSpacing.lg)
        }
    }

    private var trendChart: some View {
        ZStack(alignment: .topTrailing) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    let x = axis.position(at: index)
                    AreaMark(
                        x: .value("日期", x),
                        y: .value("余额", point.balance)
                    )
                    .foregroundStyle(LedgerPalette.cobalt.opacity(0.10))
                    .interpolationMethod(.stepEnd)

                    LineMark(
                        x: .value("日期", x),
                        y: .value("余额", point.balance)
                    )
                    .foregroundStyle(LedgerPalette.cobalt)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.stepEnd)

                    if points.count <= 12 {
                        PointMark(
                            x: .value("日期", x),
                            y: .value("余额", point.balance)
                        )
                        .foregroundStyle(LedgerPalette.cobalt)
                        .symbolSize(18)
                    }
                }

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let point = points[selectedIndex]
                    let x = axis.position(at: selectedIndex)
                    RuleMark(x: .value("选中日期", x))
                        .foregroundStyle(LedgerPalette.lineStrong)
                    PointMark(x: .value("选中日期", x), y: .value("选中余额", point.balance))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .symbolSize(52)
                }
            }
            .chartXScale(domain: axis.domain)
            .chartXAxis {
                AxisMarks(position: .bottom, values: axis.tickPositions(maxCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(LedgerPalette.line)
                    AxisTick().foregroundStyle(LedgerPalette.lineStrong)
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let position = value.as(Double.self) {
                            Text(axis.shortLabel(nearestTo: position))
                                .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
            .privacySensitive()
            .accessibilityLabel("账户余额趋势图，可点按或拖动查看数据")
            .accessibilityValue(axis.usesTimeScale ? "真实时间轴" : "有序分类轴")
            .accessibilityIdentifier("account-balance-trend-chart")

            if let selectedIndex, points.indices.contains(selectedIndex) {
                let point = points[selectedIndex]
                VStack(alignment: .leading, spacing: 3) {
                    Text(point.date)
                        .font(.system(.caption2, design: .default, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: point.balance,
                        currency: detail.currency,
                        font: .system(.caption2, design: .default, weight: .semibold),
                        color: LedgerPalette.ink
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LedgerPalette.panel.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous)
                        .stroke(LedgerPalette.line, lineWidth: 1)
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("account-balance-chart-selection")
            }
        }
        .frame(height: 210)
    }

    private var trendEmptyState: some View {
        HStack(spacing: LedgerSpacing.md) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("有账户流水后，这里会显示每日结余趋势。")
                .font(.system(.caption, design: .default))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var hiddenTrendState: some View {
        VStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("余额趋势已隐藏")
                .font(.system(.caption, design: .default, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private var rangeLabel: String {
        "\(range.start.replacingOccurrences(of: "-", with: "/")) 至 \(range.end.replacingOccurrences(of: "-", with: "/"))"
    }

    private func selectionOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            let x = value.location.x - frame.minX
                            guard x >= 0, x <= frame.width,
                                  let position: Double = proxy.value(atX: x) else { return }
                            selectedIndex = axis.nearestIndex(to: position)
                        }
                )
        }
    }
}

private struct AccountHistoryRow: View {
    let row: LedgerAccountDetailRow
    let currency: String
    let accountLabels: [String: String]

    private var title: String {
        if !row.payee.isEmpty { return row.payee }
        if !row.narration.isEmpty { return row.narration }
        return "未命名交易"
    }

    var body: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                HStack(spacing: LedgerSpacing.sm) {
                    Text(row.date)
                        .font(.system(.caption2, design: .default, weight: .medium).monospacedDigit())
                    TransactionContextLine(transaction: row.transaction, accountLabels: accountLabels)
                }
                .font(.system(.caption2, design: .default))
                .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                AmountLabel(
                    minorUnits: row.change,
                    currency: currency,
                    prefix: row.change > 0 ? "+" : "",
                    font: .system(.footnote, design: .default, weight: .semibold),
                    color: row.change >= 0 ? LedgerPalette.income : LedgerPalette.expense
                )
                .lineLimit(1)
                AmountLabel(
                    minorUnits: row.balance,
                    currency: currency,
                    font: .system(.caption2, design: .default, weight: .medium),
                    color: LedgerPalette.secondary
                )
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(.caption2, design: .default, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(.horizontal, LedgerSpacing.lg)
        .padding(.vertical, LedgerLayout.transactionVerticalInset)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: AccountBalanceRow

    private var headingLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            headingLayout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(row.account)
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if row.periodBalancesAvailable && row.periodValuationMissing {
                    Text("缺少期间汇率")
                        .font(.system(.caption2, design: .default, weight: .semibold))
                        .foregroundStyle(LedgerPalette.risk)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.periodBalancesAvailable ? "期末" : "当前")
                            .font(.system(.caption2, design: .default, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(
                            minorUnits: row.periodBalancesAvailable ? row.closingValuation : row.valuation,
                            currency: row.valuationCurrency,
                            font: .system(.footnote, design: .default, weight: .semibold)
                        )
                        .lineLimit(1)
                    }
                }
            }

            if row.periodBalancesAvailable && !row.periodValuationMissing {
                HStack(spacing: LedgerSpacing.lg) {
                    HStack(spacing: 5) {
                        Text("期初")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(
                            minorUnits: row.openingValuation,
                            currency: row.valuationCurrency,
                            font: .system(.caption2, design: .default, weight: .medium),
                            color: LedgerPalette.secondary
                        )
                        .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 5) {
                        Text("变化")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundStyle(LedgerPalette.secondary)
                        AmountLabel(
                            minorUnits: row.periodValuationChange,
                            currency: row.valuationCurrency,
                            prefix: row.periodValuationChange > 0 ? "+" : "",
                            font: .system(.caption2, design: .default, weight: .semibold),
                            color: row.periodValuationChange >= 0 ? LedgerPalette.income : LedgerPalette.expense
                        )
                        .lineLimit(1)
                    }
                }
            }

            if row.nativeCurrency != row.valuationCurrency {
                HStack(spacing: 5) {
                    Text(row.periodBalancesAvailable ? "原币期末" : "原币余额")
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer(minLength: 0)
                    AmountLabel(
                        minorUnits: row.periodBalancesAvailable ? row.closingNativeAmount : row.nativeAmount,
                        currency: row.nativeCurrency,
                        font: .system(.caption2, design: .default, weight: .medium),
                        color: LedgerPalette.secondary
                    )
                }
            }
        }
        .padding(.vertical, LedgerLayout.rowVerticalInset)
        .accessibilityElement(children: .combine)
    }
}
