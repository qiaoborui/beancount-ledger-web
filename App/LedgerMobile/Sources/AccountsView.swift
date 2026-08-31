import Charts
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedCategory = AccountBalanceCategory.all
    @State private var collapsedSectionIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LedgerAppBar {
                    PrivacyToolbarButton()
                }

                if let ledger = session.ledger, !ledger.accountSections.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            LedgerPageIntro(
                                title: "账户",
                                detail: "按资产类型查看余额，展开分类进入账户趋势与流水。",
                                meta: "\(ledger.accountBalances.count) 个账户"
                            ) {
                                EmptyView()
                            }

                            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                                AccountCategoryPicker(
                                    selection: $selectedCategory,
                                    rows: ledger.accountSections.flatMap(\.rows)
                                )

                                if let error = session.errorMessage {
                                    StatusBanner(message: error, onDismiss: session.dismissError)
                                }
                            }
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(.bottom, LedgerSpacing.lg)

                            LazyVStack(spacing: LedgerSpacing.md) {
                                ForEach(filteredSections(in: ledger)) { section in
                                    AccountGroupPanel(
                                        section: section,
                                        valuationCurrency: ledger.valuationCurrency,
                                        isCollapsed: collapseBinding(for: section.id)
                                    )
                                }

                                if filteredSections(in: ledger).isEmpty {
                                    EmptyLedgerState(
                                        icon: selectedCategory == .liabilities ? "creditcard" : "building.columns",
                                        title: "这个分类暂无账户",
                                        detail: "切换到其他分类查看账户余额。"
                                    )
                                    .padding(.top, LedgerSpacing.xl)
                                }
                            }
                            .padding(.horizontal, LedgerSpacing.lg)
                            .padding(
                                .bottom,
                                horizontalSizeClass == .regular
                                    ? LedgerSpacing.xxl
                                    : LedgerLayout.compactTabBarClearance
                            )
                        }
                        .ledgerAdaptivePageWidth()
                        .padding(.vertical, horizontalSizeClass == .regular ? LedgerSpacing.xl : 0)
                    }
                    .refreshable { await session.refresh() }
                } else {
                    EmptyLedgerState(
                        icon: "building.columns",
                        title: "暂无账户余额",
                        detail: "服务器返回的账本没有可展示的账户余额。"
                    )
                }
            }
            .background(LedgerPalette.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func filteredSections(in ledger: LedgerBootstrap) -> [AccountBalanceSection] {
        ledger.accountSections.compactMap { section in
            let rows = section.rows.filter(selectedCategory.includes)
            guard !rows.isEmpty else { return nil }
            return AccountBalanceSection(id: section.id, title: section.title, rows: rows)
        }
    }

    private func collapseBinding(for sectionID: String) -> Binding<Bool> {
        Binding(
            get: { collapsedSectionIDs.contains(sectionID) },
            set: { isCollapsed in
                if isCollapsed {
                    collapsedSectionIDs.insert(sectionID)
                } else {
                    collapsedSectionIDs.remove(sectionID)
                }
            }
        )
    }
}

private struct AccountCategoryPicker: View {
    @Binding var selection: AccountBalanceCategory
    let rows: [AccountBalanceRow]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(AccountBalanceCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 5) {
                        Text(category.title)
                        Text("\(rows.filter(category.includes).count)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .opacity(0.72)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selection == category ? LedgerPalette.onBrand : LedgerPalette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(selection == category ? LedgerPalette.cobalt : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityAddTraits(selection == category ? .isSelected : [])
                .accessibilityIdentifier("account-filter-\(category.rawValue)")
            }
        }
        .padding(3)
        .background(LedgerPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
    }
}

private struct AccountGroupPanel: View {
    let section: AccountBalanceSection
    let valuationCurrency: String
    @Binding var isCollapsed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int {
        section.rows
            .filter { !$0.valuationMissing }
            .reduce(0) { $0 + $1.valuation }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: LedgerSpacing.md) {
                    Image(systemName: AccountGroupSymbol.symbol(for: section.id))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LedgerPalette.cobalt)
                        .frame(width: 42, height: 42)
                        .background(LedgerPalette.tag)
                        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(LedgerPalette.ink)
                        Text("\(section.rows.count) 个账户")
                            .font(.system(size: 11))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 4) {
                        AmountLabel(
                            minorUnits: total,
                            currency: valuationCurrency,
                            font: .system(size: 14, weight: .semibold),
                            color: LedgerPalette.gold
                        )
                        .lineLimit(1)
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                }
                .padding(LedgerSpacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("\(isCollapsed ? "展开" : "收起") \(section.title)")
            .accessibilityValue("\(section.rows.count) 个账户")
            .accessibilityIdentifier("account-group-\(section.id)")

            if !isCollapsed {
                Divider().overlay(LedgerPalette.line)

                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    NavigationLink {
                        AccountDetailView(account: row.account)
                    } label: {
                        HStack(spacing: LedgerSpacing.sm) {
                            AccountRowView(row: row)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                        .padding(.horizontal, LedgerSpacing.lg)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleButtonStyle())

                    if index < section.rows.count - 1 {
                        Divider()
                            .overlay(LedgerPalette.line)
                            .padding(.leading, 70)
                    }
                }
            }
        }
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isCollapsed)
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

    @State private var detail: LedgerAccountDetail?
    @State private var errorMessage: String?
    @State private var reloadToken = 0

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
                    .font(.system(size: 14, weight: .semibold))
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(detail?.label ?? "账户详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PrivacyToolbarButton()
            }
        }
        .task(id: reloadToken) {
            await load()
        }
    }

    private func detailContent(_ detail: LedgerAccountDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: LedgerSpacing.md) {
                AccountDetailHero(detail: detail)

                if let errorMessage {
                    StatusBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                AccountBalanceTrendPanel(detail: detail)

                HStack(alignment: .firstTextBaseline) {
                    Text("账户流水")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Spacer()
                    Text("\(detail.rows.count) 笔")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                }
                .padding(.top, LedgerSpacing.sm)

                if detail.rows.isEmpty {
                    Text("这个账户暂无关联流水。")
                        .font(.system(size: 13))
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
                                    AccountHistoryRow(row: row, currency: detail.currency)
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
            let updatedDetail = try await session.accountDetail(for: account)
            guard !Task.isCancelled else { return }
            detail = updatedDetail
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AccountDetailHero: View {
    let detail: LedgerAccountDetail

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
            HStack(alignment: .top, spacing: LedgerSpacing.md) {
                Image(systemName: AccountGroupSymbol.symbol(for: detail.group))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LedgerPalette.cobalt)
                    .frame(width: 46, height: 46)
                    .background(LedgerPalette.tag)
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.label)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(LedgerPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: LedgerSpacing.sm) {
                        Text(AccountGroupSymbol.title(for: detail.group))
                        Text("·")
                        Text(detail.currency)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !detail.active {
                    Text("已关闭")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LedgerPalette.secondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 26)
                        .background(LedgerPalette.raised)
                        .clipShape(Capsule())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(detail.account.hasPrefix("Liabilities:") ? "当前待还" : "当前余额")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerPalette.secondary)
                AmountLabel(
                    minorUnits: detail.currentBalance,
                    currency: detail.currency,
                    font: .system(size: 30, weight: .semibold),
                    color: detail.account.hasPrefix("Liabilities:")
                        ? LedgerPalette.expense
                        : LedgerPalette.gold
                )
                .tracking(-0.75)
                .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 3) {
                if let alias = detail.alias, alias != detail.label {
                    Text(alias)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerPalette.olive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(detail.account)
                    .font(.system(size: 10, weight: .medium).monospaced())
                    .foregroundStyle(LedgerPalette.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }
}

private struct AccountBalanceTrendPanel: View {
    @EnvironmentObject private var session: LedgerSession
    let detail: LedgerAccountDetail

    @State private var selectedIndex: Int?

    private var points: [LedgerAccountBalanceTrendPoint] {
        detail.balanceTrend(maxPoints: 180)
    }

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.date), referenceLabel: points.first?.date)
    }

    private var periodChange: Int? {
        guard let first = points.first, let last = points.last, first.id != last.id else { return nil }
        return last.balance - first.balance
    }

    var body: some View {
        LedgerPanel {
            VStack(alignment: .leading, spacing: LedgerSpacing.md) {
                HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("余额趋势")
                            .font(.system(size: 16, weight: .semibold))
                            .tracking(-0.15)
                            .foregroundStyle(LedgerPalette.ink)
                        Text(rangeLabel)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(LedgerPalette.secondary)
                    }
                    Spacer()
                    if let periodChange {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("期间变化")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(LedgerPalette.secondary)
                            AmountLabel(
                                minorUnits: periodChange,
                                currency: detail.currency,
                                prefix: periodChange > 0 ? "+" : "",
                                font: .system(size: 11, weight: .semibold),
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
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
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
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(LedgerPalette.secondary)
                    AmountLabel(
                        minorUnits: point.balance,
                        currency: detail.currency,
                        font: .system(size: 10, weight: .semibold),
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("有账户流水后，这里会显示每日结余趋势。")
                .font(.system(size: 12))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }

    private var hiddenTrendState: some View {
        VStack(spacing: LedgerSpacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LedgerPalette.cobalt)
            Text("余额趋势已隐藏")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
    }

    private var rangeLabel: String {
        guard let first = points.first?.date, let last = points.last?.date else {
            return "暂无趋势数据"
        }
        if first == last { return first.replacingOccurrences(of: "-", with: "/") }
        return "\(first.replacingOccurrences(of: "-", with: "/")) 至 \(last.replacingOccurrences(of: "-", with: "/"))"
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

    private var title: String {
        if !row.payee.isEmpty { return row.payee }
        if !row.narration.isEmpty { return row.narration }
        return "未命名交易"
    }

    var body: some View {
        HStack(alignment: .center, spacing: LedgerSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(LedgerPalette.ink)
                    .lineLimit(1)
                HStack(spacing: LedgerSpacing.sm) {
                    Text(row.date)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                    if !row.narration.isEmpty, row.narration != title {
                        Text(row.narration)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(LedgerPalette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                AmountLabel(
                    minorUnits: row.change,
                    currency: currency,
                    prefix: row.change > 0 ? "+" : "",
                    font: .system(size: 13, weight: .semibold),
                    color: row.change >= 0 ? LedgerPalette.income : LedgerPalette.expense
                )
                .lineLimit(1)
                AmountLabel(
                    minorUnits: row.balance,
                    currency: currency,
                    font: .system(size: 10, weight: .medium),
                    color: LedgerPalette.secondary
                )
                .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LedgerPalette.secondary)
        }
        .padding(LedgerSpacing.lg)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRowView: View {
    let row: AccountBalanceRow

    var body: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: LedgerSpacing.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LedgerPalette.ink)
                    Text(row.account)
                        .font(.system(size: 10))
                        .foregroundStyle(LedgerPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if row.valuationMissing {
                    Text("缺少汇率")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LedgerPalette.risk)
                } else {
                    AmountLabel(
                        minorUnits: row.valuation,
                        currency: row.valuationCurrency,
                        font: .system(size: 13, weight: .semibold)
                    )
                    .lineLimit(1)
                }
            }

            if row.nativeCurrency != row.valuationCurrency {
                HStack {
                    Text("原币")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerPalette.secondary)
                    Spacer()
                    AmountLabel(
                        minorUnits: row.nativeAmount,
                        currency: row.nativeCurrency,
                        font: .system(size: 10, weight: .medium),
                        color: LedgerPalette.secondary
                    )
                }
            }
        }
        .padding(.vertical, LedgerSpacing.md)
        .accessibilityElement(children: .combine)
    }
}
