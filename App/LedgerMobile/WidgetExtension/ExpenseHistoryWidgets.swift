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
  let entry: ExpenseCalendarEntry

  var body: some View {
    Group {
      if let insights = entry.snapshot?.insights {
        let history = insights.history
        let points = LedgerWidgetDates.series(
          history, start: LedgerWidgetDates.adding(-30, to: history.end), end: history.end)
        if points.count == 30 {
          content(points, insights: insights)
        } else {
          unavailable
        }
      } else {
        unavailable
      }
    }
    .widgetURL(URL(string: "ledger://overview"))
    .containerBackground(for: .widget) { LedgerWidgetColors.panel }
  }

  private var unavailable: some View {
    LedgerWidgetUnavailableView(title: "等待消费趋势", detail: "打开 Ledger 并刷新一次")
  }

  private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights)
    -> some View
  {
    let total = points.reduce(0) { $0 + $1.amount }
    let previous = LedgerWidgetDates.series(
      insights.history,
      start: LedgerWidgetDates.adding(-60, to: insights.history.end),
      end: LedgerWidgetDates.adding(-30, to: insights.history.end))
    let baseline = previous.reduce(0) { $0 + $1.amount }
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("消费趋势").font(.system(size: 12, weight: .semibold))
        Text("近 30 天").font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
        Spacer(minLength: 4)
        Text(MoneyText.formatCompact(minorUnits: total, currency: insights.history.currency))
          .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.65)
      }
      HStack(spacing: 4) {
        Text("退款前支出 ·")
        Text("较前 30 天")
        Text(
          previous.count == 30 && baseline != 0
            ? LedgerWidgetText.percentage(
              (Double(total) - Double(baseline)) / abs(Double(baseline)))
            : "暂无对比")
      }
      .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
      Chart(points) { point in
        if let date = LedgerWidgetDates.date(point.date) {
          AreaMark(x: .value("日期", date), y: .value("消费", point.amount))
            .foregroundStyle(LedgerWidgetColors.expense.opacity(0.10))
          LineMark(x: .value("日期", date), y: .value("消费", point.amount))
            .foregroundStyle(LedgerWidgetColors.expense)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
      }
      .chartXAxis(.hidden).chartYAxis(.hidden)
      .chartYScale(
        domain: min(points.map(\.amount).min() ?? 0, 0)...max(points.map(\.amount).max() ?? 1, 1)
      )
      .accessibilityLabel("最近 30 天每日消费趋势")
      HStack {
        Text(String(points[0].date.suffix(5)).replacingOccurrences(of: "-", with: "/"))
        Spacer()
        Text(LedgerWidgetText.updated(insights.date ?? entry.date, now: entry.date))
        Spacer()
        Text(String(points[29].date.suffix(5)).replacingOccurrences(of: "-", with: "/"))
      }
      .font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary)
    }
    .foregroundStyle(LedgerWidgetColors.ink)
    .privacySensitive()
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
      if let insights = entry.snapshot?.insights {
        let history = insights.history
        let points = LedgerWidgetDates.series(history, start: history.start, end: history.end)
        if (78...84).contains(points.count) {
          content(points, insights: insights)
        } else {
          unavailable
        }
      } else {
        unavailable
      }
    }
    .widgetURL(URL(string: "ledger://overview"))
    .containerBackground(for: .widget) { LedgerWidgetColors.panel }
  }

  private var unavailable: some View {
    LedgerWidgetUnavailableView(title: "等待消费热力图", detail: "打开 Ledger 并刷新一次")
  }

  private func content(_ points: [LedgerWidgetDailyExpense], insights: LedgerWidgetExpenseInsights)
    -> some View
  {
    let peak = max(points.map(\.amount).max() ?? 0, 1)
    return GeometryReader { bounds in
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("消费热力图").font(.system(size: 12, weight: .semibold))
          Text("近 12 周").font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
          Spacer()
          Text("\(points.filter { $0.amount > 0 }.count) 个消费日")
            .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
        }
        GeometryReader { geometry in
          let width = max(1, (geometry.size.width - 18 - 33) / 12)
          let height = max(1, (geometry.size.height - 18) / 7)
          HStack(spacing: 3) {
            VStack(spacing: 3) {
              ForEach(0..<7) { row in
                Text(["一", "", "三", "", "五", "", "日"][row])
                  .font(.system(size: 8)).foregroundStyle(LedgerWidgetColors.secondary)
                  .frame(width: 15, height: height)
              }
            }
            ForEach(0..<12) { column in
              VStack(spacing: 3) {
                ForEach(0..<7) { row in
                  let index = column * 7 + row
                  if index < points.count, let url = LedgerWidgetNavigation.transactions(
                    date: points[index].date, isRedacted: !redactionReasons.isEmpty)
                  {
                    let point = points[index]
                    Link(destination: url) {
                      RoundedRectangle(cornerRadius: 2)
                        .fill(color(point.amount, peak: peak))
                        .overlay {
                          if index == points.count - 1 {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(
                              LedgerWidgetColors.cobalt, lineWidth: 1)
                          }
                        }
                        .frame(width: width, height: height)
                    }
                    .accessibilityLabel(
                      redactionReasons.isEmpty
                        ? "\(point.date)，\(MoneyText.formatWidget(minorUnits: point.amount, currency: insights.history.currency))，查看当天消费"
                        : "流水"
                    )
                  } else {
                    Color.clear.frame(width: width, height: height)
                  }
                }
              }
            }
          }
        }
        .frame(height: max(35, bounds.size.height - 40))
        HStack(spacing: 3) {
          Text(String(insights.history.start.suffix(5)).replacingOccurrences(of: "-", with: "/"))
          Text("至 " + String(points.last!.date.suffix(5)).replacingOccurrences(of: "-", with: "/"))
          Spacer(minLength: 3)
          Text("少")
          ForEach(0..<4) { level in
            RoundedRectangle(cornerRadius: 1.5).fill(
              LedgerWidgetColors.expense.opacity(0.18 + Double(level) * 0.22)
            )
            .frame(width: 7, height: 7)
          }
          Text("多")
          Spacer(minLength: 3)
          Text(LedgerWidgetText.updated(insights.date ?? entry.date, now: entry.date)).lineLimit(1)
        }
        .font(.system(size: 8)).foregroundStyle(LedgerWidgetColors.secondary)
      }
      .frame(width: bounds.size.width, height: bounds.size.height, alignment: .top)
      .foregroundStyle(LedgerWidgetColors.ink).privacySensitive()
    }
  }

  private func color(_ amount: Int, peak: Int) -> Color {
    guard amount > 0 else { return LedgerWidgetColors.raised }
    let level = min(3, Int(sqrt(Double(amount) / Double(peak)) * 4))
    return LedgerWidgetColors.expense.opacity(0.18 + Double(level) * 0.22)
  }
}
