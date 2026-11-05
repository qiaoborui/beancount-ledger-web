#if os(iOS)
import Charts
import SwiftUI

/// Draws a `visual` block from a reply: headline numbers, interactive charts,
/// rankings, sortable tables with expandable rows, comparisons, tab switchers
/// and follow-up buttons, all native and in the page's ink. Links go through
/// the screen's `openURL`, which routes `ledger://` pages; follow-ups call
/// `onAsk` with the question the model prepared.
struct LedgerAgentVisualView: View {
    let visual: LedgerAgentVisual
    var onAsk: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if visual.title != nil || visual.subtitle != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = visual.title {
                        Text(verbatim: title).balancedFont(size: 16, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                    }
                    if let subtitle = visual.subtitle {
                        Text(verbatim: subtitle).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            LedgerAgentVisualBlocks(blocks: visual.blocks, unit: visual.unit, onAsk: onAsk)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { BalancedPalette.ruleStrong.frame(height: 1) }
        .accessibilityIdentifier("ledger-agent-visual")
    }
}

private struct LedgerAgentVisualBlocks: View {
    let blocks: [LedgerAgentVisual.Block]
    let unit: String?
    let onAsk: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .stats(stats): LedgerAgentStatsView(stats: stats, unit: unit)
                case let .chart(chart): LedgerAgentChartView(chart: chart, fallbackUnit: unit)
                case let .ranking(ranking): LedgerAgentRankingView(ranking: ranking, unit: ranking.unit ?? unit)
                case let .table(table): LedgerAgentTableView(table: table)
                case let .compare(compare): LedgerAgentCompareView(compare: compare, unit: compare.unit ?? unit)
                case let .tabs(tabs): LedgerAgentTabsView(tabs: tabs, unit: unit, onAsk: onAsk)
                case let .actions(actions): LedgerAgentActionsView(actions: actions, onAsk: onAsk)
                case let .note(text):
                    Text(LedgerAgentVisualText.inline(text)).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .row(children): LedgerAgentRowView(blocks: children, unit: unit, onAsk: onAsk)
                case let .section(section): LedgerAgentSectionView(section: section, unit: unit, onAsk: onAsk)
                case let .progress(progress): LedgerAgentProgressView(progress: progress, unit: progress.unit ?? unit)
                case let .timeline(timeline): LedgerAgentTimelineView(timeline: timeline, unit: timeline.unit ?? unit)
                case let .keyValues(values): LedgerAgentKeyValuesView(values: values)
                case let .callout(callout): LedgerAgentCalloutView(callout: callout)
                case let .heatmap(heatmap): LedgerAgentHeatmapView(heatmap: heatmap, unit: heatmap.unit ?? unit)
                }
            }
        }
    }
}

enum LedgerAgentVisualText {
    static func inline(_ text: String) -> AttributedString {
        let text = LedgerAgentReplyText.encodingLedgerLinks(text)
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in string.runs where run.link != nil { string[run.range].underlineStyle = .single }
        return string
    }

    static func color(_ tone: LedgerAgentVisual.Tone) -> Color {
        switch tone {
        case .good: BalancedPalette.income
        case .bad: BalancedPalette.expense
        case .neutral: BalancedPalette.meta
        }
    }
}

/// A block title in the section-label voice.
private struct LedgerAgentVisualCaption: View {
    let text: String?
    var aside: String? = nil

    var body: some View {
        if let text, !text.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: text).balancedFont(size: 14, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                if let aside {
                    Spacer(minLength: 8)
                    Text(verbatim: aside).balancedFont(size: 11.5).foregroundStyle(BalancedPalette.meta)
                }
            }
            .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Wraps content in a button that opens a ledger page when there is one.
private struct LedgerAgentLinked<Content: View>: View {
    let link: URL?
    @ViewBuilder let content: () -> Content
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let link {
            Button { openURL(link) } label: { content().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint(Text("打开账本里的对应页面"))
        } else {
            content()
        }
    }
}

// MARK: - Stats

private struct LedgerAgentStatsView: View {
    let stats: [LedgerAgentVisual.Stat]
    let unit: String?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 14) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                LedgerAgentLinked(link: stat.link) { tile(stat) }
            }
        }
    }

    private func tile(_ stat: LedgerAgentVisual.Stat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: stat.label).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.meta).lineLimit(1)
                if stat.link != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                }
            }
            Text(verbatim: stat.value.map { LedgerAgentVisual.amount($0, unit: stat.unit ?? unit) } ?? stat.text ?? "")
                .balancedFont(size: 21, weight: .semibold).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let spark = stat.spark {
                Chart(Array(spark.enumerated()), id: \.offset) { index, value in
                    LineMark(x: .value("序号", index), y: .value("金额", value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(BalancedPalette.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 26)
                .accessibilityHidden(true)
            }
            if let delta = stat.delta {
                let tone = LedgerAgentVisual.tone(of: delta, better: stat.better)
                HStack(spacing: 3) {
                    Image(systemName: delta > 0 ? "arrow.up.right" : delta < 0 ? "arrow.down.right" : "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(verbatim: LedgerAgentVisual.percent(delta)).monospacedDigit()
                    if let label = stat.deltaLabel { Text(verbatim: label).foregroundStyle(BalancedPalette.meta) }
                }
                .balancedFont(size: 12)
                .foregroundStyle(LedgerAgentVisualText.color(tone))
            }
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { BalancedPalette.ruleStrong.frame(width: 2) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart

/// A chart drawn with Swift Charts. Tapping a column, bar, point or slice
/// selects it and shows its values underneath, with the page behind it when
/// the model linked one; tapping a legend entry hides or shows that series.
struct LedgerAgentChartView: View {
    let chart: LedgerAgentChart
    var fallbackUnit: String? = nil
    @State private var selected: String?
    @State private var hidden: Set<String> = []
    @Environment(\.openURL) private var openURL

    private static let palette: [Color] = [BalancedPalette.ink, BalancedPalette.expense, BalancedPalette.income,
                                           BalancedPalette.meta, BalancedPalette.secondary, BalancedPalette.edge,
                                           BalancedPalette.ruleStrong, BalancedPalette.rule]
    private static let waterfallNames = ["增加", "减少", LedgerAgentChart.waterfallTotal]

    private var isPie: Bool { chart.type == .pie }
    private var isWaterfall: Bool { chart.type == .waterfall }
    private var unit: String? { chart.unit ?? fallbackUnit }
    private var names: [String] {
        isWaterfall ? Self.waterfallNames : isPie ? chart.labels : chart.series.map(\.name)
    }
    private var colors: [Color] {
        isWaterfall ? [BalancedPalette.income, BalancedPalette.expense, BalancedPalette.ink]
            : names.indices.map { Self.palette[$0 % Self.palette.count] }
    }
    private var visiblePoints: [LedgerAgentChart.Point] {
        chart.points.filter { !hidden.contains(isPie ? $0.label : $0.series) }
    }
    private var height: CGFloat {
        switch chart.type {
        case .pie: 220
        case .hbar: min(max(CGFloat(chart.labels.count) * CGFloat(max(chart.series.count, 1)) * 26, 140), 520)
        default: 200
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LedgerAgentVisualCaption(text: chart.title, aside: isPie ? nil : unit.map { String(localized: "单位：\($0)") })
            plot
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in select(at: location, proxy: proxy, geometry: geometry) }
                    }
                }
                .frame(height: height)
                .animation(.easeInOut(duration: 0.2), value: hidden)
            if names.count > 1, !isWaterfall { legend }
            if let selected { detail(selected) }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: chart.title ?? String(localized: "图表")))
    }

    @ViewBuilder private var plot: some View {
        switch chart.type {
        case .pie: pie
        case .hbar: horizontalBars
        case .waterfall: waterfall
        case .bar, .line, .area: cartesian
        }
    }

    private var cartesian: some View {
        Chart {
            ForEach(visiblePoints) { point in
                let kind = chart.kind(of: point.series)
                if kind == .bar {
                    if chart.stacked == false {
                        BarMark(x: .value("项目", point.label), y: .value("金额", point.value))
                            .foregroundStyle(by: .value("系列", point.series))
                            .position(by: .value("系列", point.series))
                            .opacity(dims(point.label) ? 0.35 : 1)
                    } else {
                        BarMark(x: .value("项目", point.label), y: .value("金额", point.value))
                            .foregroundStyle(by: .value("系列", point.series))
                            .opacity(dims(point.label) ? 0.35 : 1)
                    }
                } else {
                    if kind == .area {
                        AreaMark(x: .value("项目", point.label), y: .value("金额", point.value),
                                 stacking: chart.stacked == true ? .standard : .unstacked)
                            .foregroundStyle(by: .value("系列", point.series))
                            .interpolationMethod(.monotone)
                            .opacity(0.22)
                    }
                    LineMark(x: .value("项目", point.label), y: .value("金额", point.value))
                        .foregroundStyle(by: .value("系列", point.series))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("项目", point.label), y: .value("金额", point.value))
                        .foregroundStyle(by: .value("系列", point.series))
                        .symbolSize(selected == point.label ? 60 : 18)
                }
            }
            rules
            if let selected, chart.type != .bar {
                RuleMark(x: .value("项目", selected))
                    .foregroundStyle(BalancedPalette.edge)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 10.5)) } }
        .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 10.5)) } }
    }

    @ChartContentBuilder private var rules: some ChartContent {
        ForEach(Array((chart.rules ?? []).enumerated()), id: \.offset) { _, rule in
            RuleMark(y: .value("金额", rule.value))
                .foregroundStyle(BalancedPalette.expense)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(verbatim: rule.label ?? LedgerAgentVisual.amount(rule.value, unit: unit))
                        .font(.system(size: 10)).foregroundStyle(BalancedPalette.expense)
                }
        }
    }

    private var horizontalBars: some View {
        Chart {
            ForEach(visiblePoints) { point in
                if chart.stacked == false {
                    BarMark(x: .value("金额", point.value), y: .value("项目", point.label))
                        .foregroundStyle(by: .value("系列", point.series))
                        .position(by: .value("系列", point.series))
                        .opacity(dims(point.label) ? 0.35 : 1)
                } else {
                    BarMark(x: .value("金额", point.value), y: .value("项目", point.label))
                        .foregroundStyle(by: .value("系列", point.series))
                        .opacity(dims(point.label) ? 0.35 : 1)
                }
            }
            ForEach(Array((chart.rules ?? []).enumerated()), id: \.offset) { _, rule in
                RuleMark(x: .value("金额", rule.value))
                    .foregroundStyle(BalancedPalette.expense)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXAxis { AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 10.5)) } }
        .chartYAxis { AxisMarks { AxisValueLabel().font(.system(size: 11)) } }
    }

    private var waterfall: some View {
        Chart(chart.steps) { step in
            BarMark(x: .value("项目", step.label), yStart: .value("金额", step.start), yEnd: .value("金额", step.end))
                .foregroundStyle(by: .value("类别", step.category))
                .opacity(dims(step.label) ? 0.35 : 1)
        }
        .chartXAxis { AxisMarks { AxisValueLabel().font(.system(size: 10.5)) } }
        .chartYAxis { AxisMarks { AxisGridLine(); AxisValueLabel().font(.system(size: 10.5)) } }
    }

    private var pie: some View {
        Chart(visiblePoints) { point in
            SectorMark(angle: .value("金额", point.value), innerRadius: .ratio(0.58),
                       outerRadius: .ratio(selected == point.label ? 1 : 0.92), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(by: .value("项目", point.label))
                .opacity(dims(point.label) ? 0.35 : 1)
        }
    }

    private func dims(_ label: String) -> Bool { selected != nil && selected != label }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    let off = hidden.contains(name)
                    Button {
                        if off { hidden.remove(name) } else if hidden.count < names.count - 1 { hidden.insert(name) }
                        if let selected, isPie, hidden.contains(selected) { self.selected = nil }
                    } label: {
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1.5).fill(colors[index]).frame(width: 10, height: 10)
                                .opacity(off ? 0.25 : 1)
                            Text(verbatim: name).balancedFont(size: 12)
                                .foregroundStyle(off ? BalancedPalette.edge : BalancedPalette.secondary)
                                .strikethrough(off, color: BalancedPalette.edge)
                        }
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text(off ? "已隐藏" : "显示中"))
                    .accessibilityHint(Text("显示或隐藏这一项"))
                }
            }
        }
    }

    private func detail(_ label: String) -> some View {
        let values = visiblePoints.filter { $0.label == label }
        let total = visiblePoints.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: label).balancedFont(size: 13.5, weight: .medium).foregroundStyle(BalancedPalette.ink)
                Spacer()
                Button { selected = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("取消选择"))
            }
            if isWaterfall, let step = chart.steps.first(where: { $0.label == label }) {
                if step.category != LedgerAgentChart.waterfallTotal {
                    row(name: String(localized: "变化"), value: step.end - step.start, trailing: nil)
                }
                row(name: String(localized: "累计"), value: step.end, trailing: nil)
            } else if isPie, let point = values.first {
                row(name: nil, value: point.value,
                    trailing: total > 0 ? LedgerAgentVisual.percent(point.value / total).replacingOccurrences(of: "+", with: "") : nil)
            } else {
                ForEach(values) { point in row(name: chart.series.count > 1 ? point.series : nil, value: point.value, trailing: nil) }
                let barValues = values.filter { chart.kind(of: $0.series) == .bar }
                if barValues.count > 1, chart.stacked != false {
                    row(name: String(localized: "合计"), value: barValues.reduce(0) { $0 + $1.value }, trailing: nil)
                }
            }
            if let link = chart.link(for: label) {
                Button { openURL(link) } label: {
                    Label("查看这部分流水", systemImage: "arrow.up.right").balancedFont(size: 13, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink).frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BalancedPalette.sunken)
        .transition(.opacity)
    }

    private func row(name: String?, value: Double, trailing: String?) -> some View {
        HStack {
            if let name { Text(verbatim: name).balancedFont(size: 13).foregroundStyle(BalancedPalette.secondary) }
            Spacer()
            Text(verbatim: LedgerAgentVisual.amount(value, unit: unit)).balancedFont(size: 13.5).monospacedDigit()
                .foregroundStyle(BalancedPalette.ink)
            if let trailing { Text(verbatim: trailing).balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta) }
        }
        .accessibilityElement(children: .combine)
    }

    private func select(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let anchor = proxy.plotFrame else { return }
        let frame = geometry[anchor]
        let label: String? = switch chart.type {
        case .pie: sliceLabel(at: location, in: frame)
        case .hbar: proxy.value(atY: location.y - frame.origin.y, as: String.self)
        default: proxy.value(atX: location.x - frame.origin.x, as: String.self)
        }
        withAnimation(.easeInOut(duration: 0.15)) { selected = (label == nil || label == selected) ? nil : label }
    }

    /// The slice under a tap: its angle measured clockwise from twelve
    /// o'clock, against the running share of each visible slice.
    private func sliceLabel(at location: CGPoint, in frame: CGRect) -> String? {
        let dx = location.x - frame.midX, dy = location.y - frame.midY
        let radius = min(frame.width, frame.height) / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance <= radius, distance >= radius * 0.45 else { return nil }
        var angle = Double(atan2(dx, -dy))
        if angle < 0 { angle += 2 * .pi }
        let points = visiblePoints
        let total = points.reduce(0) { $0 + $1.value }
        guard total > 0 else { return nil }
        var running = 0.0
        for point in points {
            running += point.value
            if angle <= running / total * 2 * .pi { return point.label }
        }
        return points.last?.label
    }
}

// MARK: - Ranking

private struct LedgerAgentRankingView: View {
    let ranking: LedgerAgentVisual.Ranking
    let unit: String?
    @State private var expanded = false

    private static let collapsed = 6

    var body: some View {
        let whole = ranking.whole
        let top = ranking.items.map(\.value).max() ?? 0
        let items = expanded ? ranking.items : Array(ranking.items.prefix(Self.collapsed))
        VStack(alignment: .leading, spacing: 10) {
            LedgerAgentVisualCaption(text: ranking.title)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                LedgerAgentLinked(link: item.link) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: item.label).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                            if item.link != nil {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                            }
                            Spacer(minLength: 8)
                            Text(verbatim: LedgerAgentVisual.amount(item.value, unit: unit)).balancedFont(size: 14).monospacedDigit()
                                .foregroundStyle(BalancedPalette.ink)
                            if whole > 0 {
                                Text(verbatim: LedgerAgentVisual.percent(max(item.value, 0) / whole).replacingOccurrences(of: "+", with: ""))
                                    .balancedFont(size: 12).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                                    .frame(minWidth: 40, alignment: .trailing)
                            }
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                BalancedPalette.rule
                                BalancedPalette.ink.frame(width: top > 0 ? geometry.size.width * max(item.value, 0) / top : 0)
                            }
                        }
                        .frame(height: 4)
                        if let note = item.note {
                            Text(verbatim: note).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if ranking.items.count > Self.collapsed {
                LedgerAgentExpandButton(expanded: $expanded, count: ranking.items.count, noun: String(localized: "项"))
            }
        }
    }
}

private struct LedgerAgentExpandButton: View {
    @Binding var expanded: Bool
    let count: Int
    let noun: String

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: 4) {
                Text(expanded ? String(localized: "收起") : String(localized: "显示全部 \(count) \(noun)"))
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .balancedFont(size: 13, weight: .medium)
            .foregroundStyle(BalancedPalette.secondary)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Table

/// A table whose headers sort and whose rows expand or open a page.
private struct LedgerAgentTableView: View {
    let table: LedgerAgentVisual.Table
    @State private var sort: (column: Int, ascending: Bool)?
    @State private var open: Set<Int> = []
    @State private var expanded = false
    @State private var chip: String?
    @Environment(\.openURL) private var openURL

    private var hasChildren: Bool { table.rows.contains { !$0.children.isEmpty } }

    var body: some View {
        let filtered = table.rows.filter { row in chip.map { row.cells[table.filter ?? 0] == $0 } ?? true }
        let rows = sort.map { table.sorted(filtered, by: $0.column, ascending: $0.ascending) } ?? filtered
        let shown = expanded ? rows : Array(rows.prefix(LedgerAgentVisual.Table.collapsedRows))
        VStack(alignment: .leading, spacing: 6) {
            LedgerAgentVisualCaption(text: table.title, aside: table.sortable && table.rows.count > 1 ? String(localized: "点表头排序") : nil)
            if table.filter != nil { chips }
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        if hasChildren { Color.clear.frame(width: 14, height: 1) }
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in header(index, column) }
                        Color.clear.frame(width: 10, height: 1)
                    }
                    BalancedPalette.ruleStrong.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(shown.enumerated()), id: \.offset) { index, row in
                        // Sorting reorders rows, so expansion is keyed by the
                        // row's place in the model's order.
                        let key = table.rows.firstIndex(of: row) ?? index
                        rowView(row, key: key, child: false)
                        BalancedPalette.rule.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                        if open.contains(key) {
                            ForEach(Array(row.children.enumerated()), id: \.offset) { _, child in
                                rowView(child, key: -1, child: true)
                            }
                            BalancedPalette.rule.frame(height: 1).gridCellUnsizedAxes(.horizontal)
                        }
                    }
                    if table.totals { totalsRow(rows) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if rows.count > LedgerAgentVisual.Table.collapsedRows {
                LedgerAgentExpandButton(expanded: $expanded, count: rows.count, noun: String(localized: "行"))
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach([nil] + table.filterValues.map(Optional.some), id: \.self) { value in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            chip = value
                            open = []
                        }
                    } label: {
                        BalancedMark(title: value ?? String(localized: "全部"), selected: chip == value, size: 13)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chip == value ? .isSelected : [])
                }
            }
        }
    }

    private func totalsRow(_ rows: [LedgerAgentVisual.Table.Row]) -> some View {
        let sums = table.totals(of: rows)
        return GridRow {
            if hasChildren { Color.clear.frame(width: 14, height: 1) }
            ForEach(Array(sums.enumerated()), id: \.offset) { index, sum in
                Text(verbatim: sum.map(LedgerAgentVisual.plain) ?? (index == 0 ? String(localized: "合计") : ""))
                    .balancedFont(size: 14, weight: .medium).monospacedDigit().foregroundStyle(BalancedPalette.ink)
                    .padding(.vertical, 7)
            }
            Color.clear.frame(width: 10, height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func header(_ index: Int, _ column: LedgerAgentVisual.Table.Column) -> some View {
        let label = HStack(spacing: 3) {
            Text(verbatim: column.title)
            if let sort, sort.column == index {
                Image(systemName: sort.ascending ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
            }
        }
        .balancedFont(size: 13, weight: .medium)
        .foregroundStyle(sort?.column == index ? BalancedPalette.ink : BalancedPalette.meta)
        .padding(.vertical, 6)
        if table.sortable {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    // Numbers start largest first; text starts A to Z.
                    if let current = sort, current.column == index {
                        sort = current.ascending == column.numeric ? nil : (index, !current.ascending)
                    } else {
                        sort = (index, !column.numeric)
                    }
                }
            } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .gridColumnAlignment(column.numeric ? .trailing : .leading)
            .accessibilityHint(Text("按这一列排序"))
        } else {
            label.gridColumnAlignment(column.numeric ? .trailing : .leading)
        }
    }

    @ViewBuilder private func rowView(_ row: LedgerAgentVisual.Table.Row, key: Int, child: Bool) -> some View {
        let isOpen = open.contains(key)
        GridRow {
            if hasChildren {
                Group {
                    if row.children.isEmpty {
                        Color.clear
                    } else {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
                    }
                }
                .frame(width: 14, height: 14)
            }
            ForEach(Array(row.cells.enumerated()), id: \.offset) { index, cell in
                Text(LedgerAgentVisualText.inline(cell))
                    .balancedFont(size: child ? 13 : 14).monospacedDigit()
                    .foregroundStyle(child ? BalancedPalette.secondary : BalancedPalette.ink)
                    .padding(.leading, child && index == 0 ? 12 : 0)
                    .padding(.vertical, child ? 5 : 7)
            }
            Group {
                if row.link == nil {
                    Color.clear
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                }
            }
            .frame(width: 10, height: 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !row.children.isEmpty {
                withAnimation(.easeInOut(duration: 0.15)) { if isOpen { open.remove(key) } else { open.insert(key) } }
            } else if let link = row.link {
                openURL(link)
            }
        }
        .contextMenu {
            if let link = row.link { Button("打开流水", systemImage: "arrow.up.right") { openURL(link) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.link != nil || !row.children.isEmpty ? .isButton : [])
        .accessibilityHint(row.children.isEmpty ? (row.link == nil ? Text("") : Text("打开账本里的对应页面"))
                           : Text(isOpen ? "收起明细" : "展开明细"))
    }
}

// MARK: - Compare

private struct LedgerAgentCompareView: View {
    let compare: LedgerAgentVisual.Compare
    let unit: String?

    var body: some View {
        let top = compare.items.flatMap { [abs($0.left), abs($0.right)] }.max() ?? 0
        let leftTotal = compare.items.reduce(0) { $0 + $1.left }
        let rightTotal = compare.items.reduce(0) { $0 + $1.right }
        VStack(alignment: .leading, spacing: 12) {
            LedgerAgentVisualCaption(text: compare.title)
            HStack(spacing: 14) {
                legend(compare.left, color: BalancedPalette.ruleStrong)
                legend(compare.right, color: BalancedPalette.ink)
                Spacer()
                Text("变化").balancedFont(size: 12).foregroundStyle(BalancedPalette.meta)
            }
            if compare.items.count > 1 {
                item(.init(label: String(localized: "合计"), left: leftTotal, right: rightTotal), top: nil, bold: true)
                BalancedPalette.rule.frame(height: 1)
            }
            ForEach(Array(compare.items.enumerated()), id: \.offset) { _, entry in
                LedgerAgentLinked(link: entry.link) { item(entry, top: top, bold: false) }
            }
        }
    }

    private func legend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 10, height: 10)
            Text(verbatim: text).balancedFont(size: 12).foregroundStyle(BalancedPalette.secondary)
        }
    }

    private func item(_ entry: LedgerAgentVisual.Compare.Item, top: Double?, bold: Bool) -> some View {
        let change = entry.right - entry.left
        let tone = LedgerAgentVisual.tone(of: change, better: compare.better)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: entry.label).balancedFont(size: 14, weight: bold ? .medium : .regular).foregroundStyle(BalancedPalette.ink)
                if entry.link != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: (change > 0 ? "+" : "") + LedgerAgentVisual.amount(change, unit: unit))
                        .balancedFont(size: 13.5, weight: bold ? .medium : .regular).monospacedDigit()
                        .foregroundStyle(LedgerAgentVisualText.color(tone))
                    if entry.left != 0 {
                        Text(verbatim: LedgerAgentVisual.percent(change / abs(entry.left))).balancedFont(size: 11.5).monospacedDigit()
                            .foregroundStyle(BalancedPalette.meta)
                    }
                }
            }
            if let top, top > 0 {
                bar(entry.left, top: top, color: BalancedPalette.ruleStrong)
                bar(entry.right, top: top, color: BalancedPalette.ink)
            }
            Text(verbatim: "\(compare.left) \(LedgerAgentVisual.amount(entry.left, unit: unit)) → \(compare.right) \(LedgerAgentVisual.amount(entry.right, unit: unit))")
                .balancedFont(size: 11.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
        }
        .accessibilityElement(children: .combine)
    }

    private func bar(_ value: Double, top: Double, color: Color) -> some View {
        GeometryReader { geometry in
            color.frame(width: geometry.size.width * abs(value) / top)
        }
        .frame(height: 4)
    }
}

// MARK: - Tabs

private struct LedgerAgentTabsView: View {
    let tabs: [LedgerAgentVisual.Tab]
    let unit: String?
    let onAsk: (String) -> Void
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { selection = index } } label: {
                            BalancedMark(title: tab.label, selected: selection == index, size: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == index ? .isSelected : [])
                    }
                }
            }
            .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
            LedgerAgentVisualBlocks(blocks: tabs[min(selection, tabs.count - 1)].blocks, unit: unit, onAsk: onAsk)
                .id(selection)
                .transition(.opacity)
        }
    }
}

// MARK: - Layout

/// Blocks side by side when they fit, stacked when they do not.
private struct LedgerAgentRowView: View {
    let blocks: [LedgerAgentVisual.Block]
    let unit: String?
    let onAsk: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    LedgerAgentVisualBlocks(blocks: [block], unit: unit, onAsk: onAsk)
                        .frame(minWidth: 150, maxWidth: .infinity, alignment: .topLeading)
                }
            }
            LedgerAgentVisualBlocks(blocks: blocks, unit: unit, onAsk: onAsk)
        }
    }
}

/// A titled group that folds, for detail the reader may skip.
private struct LedgerAgentSectionView: View {
    let section: LedgerAgentVisual.Section
    let unit: String?
    let onAsk: (String) -> Void
    @State private var open: Bool

    init(section: LedgerAgentVisual.Section, unit: String?, onAsk: @escaping (String) -> Void) {
        self.section = section
        self.unit = unit
        self.onAsk = onAsk
        _open = State(initialValue: !section.collapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(BalancedPalette.meta)
                        .frame(width: 12)
                    Text(verbatim: section.title).balancedFont(size: 14.5, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                    Spacer(minLength: 8)
                    if let summary = section.summary {
                        Text(verbatim: summary).balancedFont(size: 12.5).monospacedDigit().foregroundStyle(BalancedPalette.meta)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(open ? "已展开" : "已收起"))
            if open {
                LedgerAgentVisualBlocks(blocks: section.blocks, unit: unit, onAsk: onAsk)
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { if !open { BalancedPalette.rule.frame(height: 1) } }
    }
}

// MARK: - Progress

private struct LedgerAgentProgressView: View {
    let progress: LedgerAgentVisual.Progress
    let unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LedgerAgentVisualCaption(text: progress.title)
            ForEach(Array(progress.items.enumerated()), id: \.offset) { _, item in
                LedgerAgentLinked(link: item.link) { meter(item) }
            }
        }
    }

    private func meter(_ item: LedgerAgentVisual.Progress.Item) -> some View {
        let ratio = item.value / item.target
        let over = ratio > 1
        let tone = LedgerAgentVisual.tone(of: item.value - item.target, better: progress.better)
        let fill: Color = over ? LedgerAgentVisualText.color(tone) : (ratio >= 0.85 && progress.better == .lower ? BalancedPalette.expense.opacity(0.7) : BalancedPalette.ink)
        let rest = item.target - item.value
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: item.label).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink).lineLimit(1)
                if item.link != nil {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(LedgerAgentVisual.plain(item.value)) / \(LedgerAgentVisual.amount(item.target, unit: unit))")
                    .balancedFont(size: 13).monospacedDigit().foregroundStyle(BalancedPalette.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    BalancedPalette.rule
                    fill.frame(width: geometry.size.width * min(max(ratio, 0), 1))
                }
            }
            .frame(height: 6)
            HStack {
                Text(verbatim: LedgerAgentVisual.percent(ratio).replacingOccurrences(of: "+", with: ""))
                    .monospacedDigit().foregroundStyle(over ? LedgerAgentVisualText.color(tone) : BalancedPalette.meta)
                Spacer()
                Text(verbatim: rest >= 0 ? String(localized: "剩 \(LedgerAgentVisual.amount(rest, unit: unit))")
                                         : String(localized: "超出 \(LedgerAgentVisual.amount(-rest, unit: unit))"))
                    .monospacedDigit().foregroundStyle(over ? LedgerAgentVisualText.color(tone) : BalancedPalette.meta)
            }
            .balancedFont(size: 12)
            if let note = item.note { Text(verbatim: note).balancedFont(size: 12).foregroundStyle(BalancedPalette.meta) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Timeline

private struct LedgerAgentTimelineView: View {
    let timeline: LedgerAgentVisual.Timeline
    let unit: String?
    @State private var expanded = false

    private static let collapsed = 8

    var body: some View {
        let items = expanded ? timeline.items : Array(timeline.items.prefix(Self.collapsed))
        VStack(alignment: .leading, spacing: 0) {
            LedgerAgentVisualCaption(text: timeline.title).padding(.bottom, 8)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                LedgerAgentLinked(link: item.link) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 0) {
                            Circle().fill(item.tone == .neutral ? BalancedPalette.ink : LedgerAgentVisualText.color(item.tone))
                                .frame(width: 7, height: 7).padding(.top, 6)
                            if index < items.count - 1 { BalancedPalette.rule.frame(width: 1).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.date).balancedMono(size: 11.5).foregroundStyle(BalancedPalette.meta)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(LedgerAgentVisualText.inline(item.title)).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink)
                                if item.link != nil {
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                                }
                                Spacer(minLength: 8)
                                if let value = item.value {
                                    Text(verbatim: LedgerAgentVisual.amount(value, unit: unit)).balancedFont(size: 14).monospacedDigit()
                                        .foregroundStyle(item.tone == .neutral ? BalancedPalette.ink : LedgerAgentVisualText.color(item.tone))
                                }
                            }
                            if let detail = item.detail {
                                Text(verbatim: detail).balancedFont(size: 12.5).foregroundStyle(BalancedPalette.secondary)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if timeline.items.count > Self.collapsed {
                LedgerAgentExpandButton(expanded: $expanded, count: timeline.items.count, noun: String(localized: "条"))
            }
        }
    }
}

// MARK: - Key values

private struct LedgerAgentKeyValuesView: View {
    let values: LedgerAgentVisual.KeyValues

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerAgentVisualCaption(text: values.title).padding(.bottom, 4)
            ForEach(Array(values.items.enumerated()), id: \.offset) { _, item in
                LedgerAgentLinked(link: item.link) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: item.label).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.meta)
                        Spacer(minLength: 8)
                        Text(LedgerAgentVisualText.inline(item.value)).balancedFont(size: 14).monospacedDigit()
                            .foregroundStyle(item.tone == .neutral ? BalancedPalette.ink : LedgerAgentVisualText.color(item.tone))
                            .multilineTextAlignment(.trailing)
                        if item.link != nil {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(BalancedPalette.edge)
                        }
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { BalancedPalette.rule.frame(height: 1) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Callout

private struct LedgerAgentCalloutView: View {
    let callout: LedgerAgentVisual.Callout

    private var color: Color {
        switch callout.kind {
        case .info: BalancedPalette.secondary
        case .good: BalancedPalette.income
        case .warn, .bad: BalancedPalette.expense
        }
    }

    private var symbol: String {
        switch callout.kind {
        case .info: "info.circle"
        case .good: "checkmark.circle"
        case .warn: "exclamationmark.triangle"
        case .bad: "xmark.octagon"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if let title = callout.title {
                    Text(verbatim: title).balancedFont(size: 14, weight: .semibold).foregroundStyle(BalancedPalette.ink)
                }
                Text(LedgerAgentVisualText.inline(callout.text)).balancedFont(size: 13.5).foregroundStyle(BalancedPalette.secondary)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(BalancedPalette.sunken)
        .overlay(alignment: .leading) { color.frame(width: 2) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heatmap

/// A calendar of daily values: one column per week, Monday on top. Tapping
/// a day shows its value and opens that day's transactions.
private struct LedgerAgentHeatmapView: View {
    let heatmap: LedgerAgentVisual.Heatmap
    let unit: String?
    @State private var selected: Date?
    @Environment(\.openURL) private var openURL

    private static let cell: CGFloat = 14
    private static let gap: CGFloat = 3

    /// Weeks of seven optional days, from the Monday on or before the first day.
    private var weeks: [[LedgerAgentVisual.Heatmap.Day?]] {
        guard let first = heatmap.days.first?.date, let last = heatmap.days.last?.date else { return [] }
        let byDay = Dictionary(heatmap.days.map { ($0.date, $0) }, uniquingKeysWith: { $1 })
        var cursor = LedgerAgentVisual.addingDays(-LedgerAgentVisual.weekdayIndex(first), to: first)
        var weeks: [[LedgerAgentVisual.Heatmap.Day?]] = []
        while cursor <= last, weeks.count < 60 {
            var week: [LedgerAgentVisual.Heatmap.Day?] = []
            for _ in 0..<7 {
                week.append(cursor < first || cursor > last ? nil : byDay[cursor] ?? .init(date: cursor, value: 0))
                cursor = LedgerAgentVisual.addingDays(1, to: cursor)
            }
            weeks.append(week)
        }
        return weeks
    }

    var body: some View {
        let top = heatmap.days.map { abs($0.value) }.max() ?? 0
        VStack(alignment: .leading, spacing: 8) {
            LedgerAgentVisualCaption(text: heatmap.title, aside: unit.map { String(localized: "单位：\($0)") })
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { index in
                                square(week[index], top: top)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .defaultScrollAnchor(.trailing)
            HStack(spacing: 4) {
                Text(verbatim: heatmap.days.first.map { LedgerAgentVisual.dayString($0.date) } ?? "")
                Spacer()
                Text("少")
                ForEach([0.12, 0.35, 0.6, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(BalancedPalette.ink.opacity(level)).frame(width: 10, height: 10)
                }
                Text("多")
                Spacer()
                Text(verbatim: heatmap.days.last.map { LedgerAgentVisual.dayString($0.date) } ?? "")
            }
            .balancedFont(size: 11).monospacedDigit().foregroundStyle(BalancedPalette.meta)
            if let selected {
                let day = heatmap.days.first { $0.date == selected } ?? .init(date: selected, value: 0)
                HStack {
                    Text(verbatim: LedgerAgentVisual.dayString(day.date)).balancedFont(size: 13.5, weight: .medium)
                        .foregroundStyle(BalancedPalette.ink)
                    Spacer()
                    Text(verbatim: LedgerAgentVisual.amount(day.value, unit: unit)).balancedFont(size: 13.5).monospacedDigit()
                        .foregroundStyle(BalancedPalette.ink)
                    if let link = heatmap.link(for: day) {
                        Button { openURL(link) } label: {
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BalancedPalette.ink).frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("查看当天流水"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(BalancedPalette.sunken)
            }
        }
    }

    @ViewBuilder private func square(_ day: LedgerAgentVisual.Heatmap.Day?, top: Double) -> some View {
        if let day {
            let level = top > 0 ? abs(day.value) / top : 0
            RoundedRectangle(cornerRadius: 2)
                .fill(day.value == 0 ? BalancedPalette.rule : BalancedPalette.ink.opacity(0.12 + 0.88 * level))
                .frame(width: Self.cell, height: Self.cell)
                .overlay {
                    if selected == day.date { RoundedRectangle(cornerRadius: 2).stroke(BalancedPalette.expense, lineWidth: 1.5) }
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = selected == day.date ? nil : day.date }
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "\(LedgerAgentVisual.dayString(day.date)) \(LedgerAgentVisual.amount(day.value, unit: unit))"))
                .accessibilityAddTraits(.isButton)
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }
}

// MARK: - Actions

private struct LedgerAgentActionsView: View {
    let actions: [LedgerAgentVisual.Action]
    let onAsk: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button {
                    switch action.target {
                    case let .ask(question): onAsk(question)
                    case let .link(url): openURL(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isAsk(action) ? "arrow.turn.down.right" : "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BalancedPalette.meta)
                        Text(verbatim: action.label).balancedFont(size: 14).foregroundStyle(BalancedPalette.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(BalancedPalette.rule, lineWidth: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(isAsk(action) ? "把这个问题发给助手" : "打开账本里的对应页面"))
            }
        }
    }

    private func isAsk(_ action: LedgerAgentVisual.Action) -> Bool {
        if case .ask = action.target { return true }
        return false
    }
}
#endif
