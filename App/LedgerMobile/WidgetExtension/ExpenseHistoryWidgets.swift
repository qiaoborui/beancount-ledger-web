import Charts
import SwiftUI
import WidgetKit

struct ExpenseTrendWidget: Widget {
  let kind = "LedgerExpenseTrendWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ExpenseCalendarProvider()) { entry in
      ExpenseTrendWidgetView(entry: entry)
    }
    .configurationDisplayName("消费趋势")
    .description("最近 30 天的退款前支出，与前 30 天对比。")
    .supportedFamilies([.systemMedium])
  }
}

/// Positive daily expense before refunds, as the copy says. A locked device
/// keeps the layout and masks the figures and the line.
struct ExpenseTrendWidgetView: View {
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ExpenseCalendarEntry
    var body: some View {
        Group {
            if let insights = entry.snapshot?.insights {
                let points = LedgerWidgetDates.series(insights.history,
                    start: LedgerWidgetDates.adding(-30, to: insights.history.end), end: insights.history.end)
                if points.count == 30 { content(points, insights: insights) } else { unavailable }
            } else { unavailable }
        }
        .widgetURL(URL(string: "ledger://overview"))
        .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }
    private var unavailable: some View {
        LedgerWidgetUnavailableView(title: String(localized: "消费趋势"))
    }
    private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        let total = points.reduce(0) { $0 + $1.amount }
        let previous = LedgerWidgetDates.series(insights.history,
            start: LedgerWidgetDates.adding(-60, to: insights.history.end),
            end: LedgerWidgetDates.adding(-30, to: insights.history.end))
        let baseline = previous.reduce(0) { $0 + $1.amount }
        let comparison = previous.count == 30 && baseline != 0
            ? String(localized: "\(LedgerWidgetText.signedPercentage((Double(total) - Double(baseline)) / Double(baseline))) · 前30天") : String(localized: "暂无同期数据")
        let peak = max(points.map(\.amount).max() ?? 0, 100)
        let line = tone.expense
        return VStack(alignment: .leading, spacing: 4) {
            LedgerWidgetHeader(title: String(localized: "消费趋势"), detail: String(localized: "近30天"))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                LedgerWidgetAmount(amount: total, currency: insights.history.currency, size: 23)
                Spacer(minLength: 0)
                Text(comparison).font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
            }
            // `privacySensitive` masks text, not marks, so a locked device
            // draws an empty plot instead of the line's shape.
            if !redactionReasons.isEmpty {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tone.rule)
                    .frame(maxHeight: .infinity)
            } else {
                Chart(points) { point in
                    if let date = LedgerWidgetDates.date(point.date) {
                        AreaMark(x: .value("日期", date), y: .value("支出", point.amount))
                            .interpolationMethod(.linear).foregroundStyle(line.opacity(0.12))
                        LineMark(x: .value("日期", date), y: .value("支出", point.amount))
                            .interpolationMethod(.linear).foregroundStyle(line)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...peak)
                    .widgetAccentable()
                    .overlay(alignment: .bottom) { Rectangle().fill(tone.rule).frame(height: 1) }
                    .frame(maxHeight: .infinity)
                    .privacySensitive()
                    .accessibilityLabel("最近30天每日支出，纵轴单位为元")
            }
            HStack {
                Text(LedgerWidgetHeat.shortDate(points[0].date))
                Spacer(); Text(LedgerWidgetHeat.shortDate(points[29].date))
            }.font(LedgerWidgetFont.text(9)).monospacedDigit().foregroundStyle(tone.meta)
            LedgerWidgetFooter(label: String(localized: "退款前支出 · \(insights.history.currency)"), date: insights.date, now: entry.date)
        }
    }
}

struct ExpenseHeatmapWidget: Widget {
  let kind = "LedgerExpenseHeatmapWidget"
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: ExpenseCalendarProvider()) { entry in
      ExpenseHeatmapWidgetView(entry: entry)
    }
    .configurationDisplayName("消费热力图")
    .description("最近 12 周的消费强度，轻点色块查看当天流水。")
    .supportedFamilies([.systemMedium])
  }
}

/// A locked device keeps the grid and masks the heat; the day links are
/// dropped with it.
struct ExpenseHeatmapWidgetView: View {
    /// Monday, Thursday, and Sunday rows; the grid starts on Monday.
    private static var heatmapWeekdayLabels: [String] {
        let symbols = LedgerDateLabel.veryShortWeekdaySymbols
        return [symbols[1], "", "", symbols[4], "", "", symbols[0]]
    }

    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ExpenseCalendarEntry
    var body: some View {
        Group {
            if let insights = entry.snapshot?.insights {
                let points = LedgerWidgetDates.series(insights.history, start: insights.history.start, end: insights.history.end)
                if (78...84).contains(points.count) { content(points, insights: insights) } else { unavailable }
            } else { unavailable }
        }.widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }
    private var unavailable: some View {
        LedgerWidgetUnavailableView(title: String(localized: "消费热力图"))
    }
    private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        return VStack(alignment: .leading, spacing: 5) {
            LedgerWidgetHeader(title: String(localized: "消费热力图"), detail: String(localized: "近12周"))
            HStack {
                Text("\(points.filter { $0.amount > 0 }.count)个消费日").privacySensitive()
                Spacer(minLength: 0)
                Text(verbatim: "\(LedgerWidgetHeat.shortDate(points[0].date))–\(LedgerWidgetHeat.shortDate(points[points.count - 1].date))")
            }.font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.secondary)
            GeometryReader { bounds in
                let height = max(1, (bounds.size.height - 12) / 7)
                HStack(spacing: 3) {
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(Self.heatmapWeekdayLabels[row])
                                .font(LedgerWidgetFont.text(8)).foregroundStyle(tone.meta)
                                .frame(width: 12, height: height)
                        }
                    }
                    ForEach(0..<12, id: \.self) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = column * 7 + row
                                if index < points.count, let url = LedgerWidgetLink.expenseDay(points[index].date) {
                                    let cell = RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(redactionReasons.isEmpty ? LedgerWidgetHeat.color(points[index].amount, mode: renderingMode)
                                              : LedgerWidgetHeat.color(level: 0, mode: renderingMode))
                                        .frame(height: height)
                                        .privacySensitive()
                                        .accessibilityLabel("\(points[index].date)，\(MoneyText.format(minorUnits: points[index].amount, currency: insights.history.currency))")
                                    if redactionReasons.isEmpty {
                                        Link(destination: url) { cell }
                                    } else {
                                        cell
                                    }
                                } else { Color.clear.frame(height: height) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                Text("少")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LedgerWidgetHeat.color(level: level, mode: renderingMode)).frame(width: 8, height: 8)
                }
                Text("多")
                Spacer(minLength: 0)
                Text(insights.date.map { LedgerWidgetText.updated($0, now: entry.date) } ?? String(localized: "尚未更新"))
            }.font(LedgerWidgetFont.text(9)).monospacedDigit().foregroundStyle(tone.meta).lineLimit(1)
        }
    }
}
