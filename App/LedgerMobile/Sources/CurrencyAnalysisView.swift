import Charts
import SwiftUI

struct CurrencyAnalysisView: View {
    @EnvironmentObject private var session: LedgerSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var snapshot: CurrencyAnalysisSnapshot?

    var showsAppBar = false

    private var ledger: LedgerBootstrap? { session.ledger }

    var body: some View {
        VStack(spacing: 0) {
            if showsAppBar {
                LedgerAppBar { PrivacyToolbarButton() }
            }

            if let ledger {
                content(ledger)
            } else {
                ProgressView()
                    .tint(LedgerPalette.cobalt)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LedgerPalette.canvas)
        .navigationTitle(showsAppBar ? "" : "货币与汇率")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showsAppBar ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(LedgerPalette.panel, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if !showsAppBar {
                ToolbarItem(placement: .topBarTrailing) { PrivacyToolbarButton() }
            }
        }
    }

    @ViewBuilder
    private func content(_ ledger: LedgerBootstrap) -> some View {
        let input = CurrencyAnalysisInput(ledger: ledger)

        Group {
            if let snapshot, snapshot.input == input {
                analysisContent(ledger: ledger, snapshot: snapshot)
            } else {
                ProgressView("正在分析汇率…")
                    .tint(LedgerPalette.cobalt)
                    .foregroundStyle(LedgerPalette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: input) {
            let nextSnapshot = await Task.detached(priority: .userInitiated) {
                CurrencyAnalysis.snapshot(input: input)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = nextSnapshot
        }
    }

    private func analysisContent(
        ledger: LedgerBootstrap,
        snapshot: CurrencyAnalysisSnapshot
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                LedgerPageIntro(
                    title: "货币与汇率",
                    detail: "查看账本货币之间的当前汇率、价格来源与近期变化。",
                    meta: snapshot.latestDate.map { "最新价格 · \($0)" } ?? "暂无价格记录"
                ) { EmptyView() }

                valuationPicker(currencies: snapshot.currencies, selected: ledger.valuationCurrency)

                if snapshot.missingCount > 0 {
                    missingRateBanner(count: snapshot.missingCount, valuationCurrency: ledger.valuationCurrency)
                }

                if snapshot.rows.isEmpty {
                    EmptyLedgerState(
                        icon: "coloncurrencysign",
                        title: "暂无货币",
                        detail: "账本中还没有可用于汇率分析的货币或价格记录。"
                    )
                } else {
                    LazyVStack(spacing: LedgerSpacing.md) {
                        ForEach(snapshot.rows) { row in
                            CurrencyRateCard(
                                row: row,
                                valuationCurrency: ledger.valuationCurrency,
                                regularLayout: horizontalSizeClass == .regular
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalSizeClass == .regular ? 0 : LedgerSpacing.lg)
            .padding(.top, horizontalSizeClass == .regular ? LedgerSpacing.xl : 0)
            .padding(.bottom, horizontalSizeClass == .regular ? LedgerSpacing.xxl : LedgerLayout.compactTabBarClearance)
            .ledgerAdaptivePageWidth()
        }
        .accessibilityIdentifier("currency-analysis-content")
        .refreshable { await session.refresh() }
    }

    private func valuationPicker(currencies: [String], selected: String) -> some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            HStack {
                SectionHeading(title: "估值货币")
                Spacer()
                if session.isValuationCurrencyLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LedgerPalette.cobalt)
                        .accessibilityLabel("正在切换估值货币")
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: LedgerSpacing.sm) {
                        ForEach(currencies, id: \.self) { currency in
                            Button {
                                Task { await session.setValuationCurrency(currency) }
                            } label: {
                                Text(currency)
                                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(currency == selected ? LedgerPalette.onBrand : LedgerPalette.warm)
                                    .padding(.horizontal, LedgerSpacing.lg)
                                    .frame(minHeight: 40)
                                    .background(currency == selected ? LedgerPalette.cobalt : LedgerPalette.tag)
                                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
                                    .overlay {
                                        if currency != selected {
                                            RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                                                .stroke(LedgerPalette.line, lineWidth: 1)
                                        }
                                    }
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityLabel("估值货币 \(currency)")
                            .accessibilityAddTraits(currency == selected ? .isSelected : [])
                            .accessibilityIdentifier("valuation-currency-\(currency)")
                            .id(currency)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(selected, anchor: .leading) }
                .onChange(of: selected) { _, currency in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(currency, anchor: .leading)
                    }
                }
            }
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.line, lineWidth: 1)
        }
    }

    private func missingRateBanner(count: Int, valuationCurrency: String) -> some View {
        HStack(alignment: .top, spacing: LedgerSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LedgerPalette.gold)
                .frame(width: 20, height: 20)
            Text("有 \(count) 种货币缺少到 \(valuationCurrency) 的可用汇率，相关金额将无法完整估值。")
                .font(.system(size: 12))
                .foregroundStyle(LedgerPalette.olive)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(LedgerSpacing.lg)
        .background(LedgerPalette.gold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LedgerRadius.sm, style: .continuous)
                .stroke(LedgerPalette.gold.opacity(0.38), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("currency-missing-rate-warning")
    }
}

private struct CurrencyRateCard: View {
    let row: CurrencyRateRow
    let valuationCurrency: String
    let regularLayout: Bool

    var body: some View {
        LedgerPanel {
            if regularLayout {
                HStack(spacing: LedgerSpacing.xl) {
                    currencyIdentity.frame(width: 104, alignment: .leading)
                    rateSummary.frame(maxWidth: .infinity, alignment: .leading)
                    changeSummary.frame(width: 84, alignment: .trailing)
                    sparkline.frame(width: 250, height: 82)
                }
                .padding(LedgerSpacing.lg)
            } else {
                VStack(alignment: .leading, spacing: LedgerSpacing.lg) {
                    HStack(alignment: .center, spacing: LedgerSpacing.md) {
                        currencyIdentity
                        Spacer(minLength: LedgerSpacing.sm)
                        changeSummary
                    }
                    rateSummary
                    sparkline.frame(height: 92)
                }
                .padding(LedgerSpacing.lg)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("currency-rate-\(row.currency)")
    }

    private var currencyIdentity: some View {
        VStack(alignment: .leading, spacing: LedgerSpacing.sm) {
            Text(row.currency)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .tracking(-0.3)
                .foregroundStyle(LedgerPalette.ink)
            CurrencyRateBadge(currency: row.currency, valuationCurrency: valuationCurrency, rate: row.rate)
        }
    }

    private var rateSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(CurrencyRateText.value(currency: row.currency, valuationCurrency: valuationCurrency, rate: row.rate))
                .font(.system(size: regularLayout ? 20 : 19, weight: .semibold).monospacedDigit())
                .tracking(-0.25)
                .foregroundStyle(row.rate == nil ? LedgerPalette.risk : LedgerPalette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            HStack(spacing: LedgerSpacing.sm) {
                Text(row.rate?.date ?? (row.rate?.source == .base ? "当前基准" : "暂无可用价格"))
                Text("·")
                Text(row.rate?.source.title ?? "无法估值")
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(LedgerPalette.secondary)
        }
    }

    private var changeSummary: some View {
        VStack(alignment: regularLayout ? .trailing : .leading, spacing: 3) {
            Text("最近变化")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LedgerPalette.secondary)
            Text(CurrencyRateText.change(row.recentChange))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(CurrencyRateText.changeColor(row.recentChange))
        }
    }

    @ViewBuilder
    private var sparkline: some View {
        if row.history.count >= 2 {
            CurrencySparkline(points: row.history, currency: row.currency, valuationCurrency: valuationCurrency)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                    .fill(LedgerPalette.raised.opacity(0.45))
                RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous)
                    .stroke(LedgerPalette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Text("暂无趋势")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LedgerPalette.secondary)
            }
        }
    }
}

private struct CurrencyRateBadge: View {
    let currency: String
    let valuationCurrency: String
    let rate: CurrencyRateInfo?

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .frame(minHeight: 26)
            .background(background)
            .clipShape(Capsule())
    }

    private var label: String {
        if currency == valuationCurrency { return "基准" }
        return rate?.source.title ?? "缺少汇率"
    }

    private var foreground: Color {
        if currency == valuationCurrency { return LedgerPalette.onBrand }
        return rate == nil ? LedgerPalette.risk : LedgerPalette.olive
    }

    private var background: Color {
        if currency == valuationCurrency { return LedgerPalette.cobalt }
        return rate == nil ? LedgerPalette.risk.opacity(0.10) : LedgerPalette.tag
    }
}

private struct CurrencySparkline: View {
    let points: [CurrencyRatePoint]
    let currency: String
    let valuationCurrency: String

    @State private var selectedIndex: Int?

    private var axis: LedgerChartAxis {
        LedgerChartAxis(labels: points.map(\.date), referenceLabel: points.first?.date)
    }

    private var selectedPoint: CurrencyRatePoint? {
        selectedIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.rate)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let span = maximum - minimum
        let padding = span > 0 ? span * 0.16 : max(abs(maximum) * 0.04, 0.01)
        return (minimum - padding)...(maximum + padding)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Chart {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    LineMark(
                        x: .value("日期", axis.position(at: index)),
                        y: .value("汇率", point.rate)
                    )
                    .foregroundStyle(LedgerPalette.cobaltLight)
                    .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }

                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let selectedPoint = points[selectedIndex]
                    let x = axis.position(at: selectedIndex)
                    RuleMark(x: .value("选中日期", x))
                        .foregroundStyle(LedgerPalette.lineStrong)
                    PointMark(
                        x: .value("选中日期", x),
                        y: .value("选中汇率", selectedPoint.rate)
                    )
                    .foregroundStyle(LedgerPalette.cobalt)
                    .symbolSize(38)
                }
            }
            .chartXScale(domain: axis.domain)
            .chartXAxis {
                AxisMarks(position: .bottom, values: axis.tickPositions(maxCount: 2)) { value in
                    AxisValueLabel(collisionResolution: .disabled) {
                        if let position = value.as(Double.self) {
                            Text(axis.shortLabel(nearestTo: position))
                                .font(.system(size: 8, weight: .medium).monospacedDigit())
                                .foregroundStyle(LedgerPalette.secondary)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .chartOverlay { proxy in selectionOverlay(proxy: proxy) }
            .accessibilityLabel("\(currency) 到 \(valuationCurrency) 的汇率趋势")
            .accessibilityValue(CurrencyRateText.accessibilityTrend(points))
            .accessibilityIdentifier("currency-sparkline-\(currency)")
            .padding(.horizontal, 2)
            .padding(.vertical, LedgerSpacing.sm)

            if let selectedPoint {
                Text("\(selectedPoint.date)  \(CurrencyRateText.number(selectedPoint.rate))")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LedgerPalette.ink)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 22)
                    .background(LedgerPalette.panel.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: LedgerRadius.xs, style: .continuous)
                            .stroke(LedgerPalette.line, lineWidth: 1)
                    }
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("currency-chart-selection-\(currency)")
            }
        }
        .background(LedgerPalette.raised.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: LedgerRadius.md, style: .continuous))
        .accessibilityElement(children: .contain)
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

private enum CurrencyRateText {
    static func value(currency: String, valuationCurrency: String, rate: CurrencyRateInfo?) -> String {
        if currency == valuationCurrency { return "1 \(currency) = 1 \(valuationCurrency)" }
        guard let rate else { return "\(currency) → \(valuationCurrency) 暂无汇率" }
        return "1 \(currency) = \(number(rate.rate)) \(valuationCurrency)"
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = value >= 1 ? 2 : 4
        formatter.maximumFractionDigits = value >= 1 ? 4 : 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func change(_ value: Double?) -> String {
        guard let value else { return "暂无" }
        return String(format: "%@%.2f%%", value > 0 ? "+" : "", value * 100)
    }

    static func changeColor(_ value: Double?) -> Color {
        guard let value else { return LedgerPalette.secondary }
        if value > 0 { return LedgerPalette.income }
        if value < 0 { return LedgerPalette.expense }
        return LedgerPalette.secondary
    }

    static func accessibilityTrend(_ points: [CurrencyRatePoint]) -> String {
        guard let first = points.first, let last = points.last else { return "暂无趋势" }
        return "从 \(first.date) 的 \(number(first.rate)) 到 \(last.date) 的 \(number(last.rate))"
    }
}
