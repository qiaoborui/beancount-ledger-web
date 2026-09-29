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

struct ExpenseTrendWidgetView: View {
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseCalendarEntry
    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "消费趋势")
            } else if let insights = entry.snapshot?.insights {
                let points = LedgerWidgetDates.series(insights.history,
                    start: LedgerWidgetDates.adding(-30, to: insights.history.end), end: insights.history.end)
                if points.count == 30 { content(points, insights: insights) } else { unavailable }
            } else { unavailable }
        }
        .widgetURL(URL(string: "ledger://overview"))
        .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }
    private var unavailable: some View {
        LedgerWidgetUnavailableView(title: "等待消费趋势", detail: "打开 Ledger 并刷新一次")
    }
    private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights) -> some View {
        let total = points.reduce(0) { $0 + $1.amount }
        let previous = LedgerWidgetDates.series(insights.history,
            start: LedgerWidgetDates.adding(-60, to: insights.history.end),
            end: LedgerWidgetDates.adding(-30, to: insights.history.end))
        let baseline = previous.reduce(0) { $0 + $1.amount }
        let comparison = previous.count == 30 && baseline != 0
            ? "\(total < baseline ? "↓" : "↑") \(LedgerWidgetText.percentage(abs((Double(total) - Double(baseline)) / Double(baseline)))) · 前30天" : "暂无同期数据"
        let peak = max(points.map(\.amount).max() ?? 0, 100)
        return VStack(alignment: .leading, spacing: 4) {
            LedgerWidgetHeader(title: "消费趋势", detail: "近30天")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                LedgerWidgetAmount(amount: total, currency: insights.history.currency, size: 21)
                Spacer(minLength: 0)
                Text(comparison).font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            HStack(spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(String(format: "%.0f", Double(peak) / 100))
                    Spacer(minLength: 0)
                    Text("0")
                }.font(.system(size: 8, design: .monospaced)).foregroundStyle(LedgerWidgetColors.secondary)
                Chart(points) { point in
                    if let date = LedgerWidgetDates.date(point.date) {
                        LineMark(x: .value("日期", date), y: .value("支出", point.amount))
                            .interpolationMethod(.linear).foregroundStyle(LedgerWidgetColors.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...peak)
                    .overlay(alignment: .bottom) { Rectangle().fill(LedgerWidgetColors.line).frame(height: 0.5) }
                    .accessibilityLabel("最近30天每日支出，纵轴单位为元")
            }.frame(maxHeight: .infinity)
            HStack {
                Text(LedgerWidgetHeat.shortDate(points[0].date))
                Spacer(); Text(LedgerWidgetHeat.shortDate(points[14].date))
                Spacer(); Text(LedgerWidgetHeat.shortDate(points[29].date))
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(LedgerWidgetColors.secondary)
            LedgerWidgetFooter(label: "退款前支出 · \(insights.history.currency)", date: insights.date, now: entry.date)
        }.privacySensitive()
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

struct ExpenseHeatmapWidgetView: View {
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseCalendarEntry
    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "消费热力图")
            } else if let insights = entry.snapshot?.insights {
                let points = LedgerWidgetDates.series(insights.history, start: insights.history.start, end: insights.history.end)
                if (78...84).contains(points.count) { content(points, insights: insights) } else { unavailable }
            } else { unavailable }
        }.widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }
    private var unavailable: some View {
        LedgerWidgetUnavailableView(title: "等待消费热力图", detail: "打开 Ledger 并刷新一次")
    }
    private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LedgerWidgetHeader(title: "消费热力图", detail: "近12周")
            HStack {
                Text("\(points.filter { $0.amount > 0 }.count)个消费日")
                Spacer(minLength: 0)
                Text("\(LedgerWidgetHeat.shortDate(points[0].date))–\(LedgerWidgetHeat.shortDate(points[points.count - 1].date))")
                    .monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
            GeometryReader { bounds in
                let height = max(1, (bounds.size.height - 12) / 7)
                HStack(spacing: 3) {
                    VStack(spacing: 2) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(["一", "", "", "四", "", "", "日"][row])
                                .font(.system(size: 8)).foregroundStyle(LedgerWidgetColors.secondary)
                                .frame(width: 12, height: height)
                        }
                    }
                    ForEach(0..<12, id: \.self) { column in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = column * 7 + row
                                if index < points.count, let url = LedgerWidgetLink.expenseDay(points[index].date) {
                                    Link(destination: url) {
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(LedgerWidgetHeat.color(points[index].amount)).frame(height: height)
                                    }.accessibilityLabel("\(points[index].date)，\(MoneyText.format(minorUnits: points[index].amount, currency: insights.history.currency))")
                                } else { Color.clear.frame(height: height) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 3) {
                ForEach([0, 5_000, 20_001], id: \.self) { amount in
                    Rectangle().fill(LedgerWidgetHeat.color(amount)).frame(width: 7, height: 7)
                    Text(amount == 0 ? "0" : amount == 5_000 ? "≤50" : ">200")
                }
                Text(insights.history.currency + "/日")
                Spacer(minLength: 0)
                Text(insights.date.map { LedgerWidgetText.updated($0, now: entry.date) } ?? "尚未更新")
            }.font(.system(size: 8)).foregroundStyle(LedgerWidgetColors.secondary).lineLimit(1)
        }.privacySensitive()
    }
}
