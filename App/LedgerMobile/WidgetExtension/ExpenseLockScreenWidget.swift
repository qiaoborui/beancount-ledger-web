import SwiftUI
import WidgetKit

struct ExpenseLockScreenWidget: Widget {
  let kind = "LedgerExpenseLockScreenWidget"
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: kind, intent: ExpenseWidgetIntent.self, provider: ExpenseOverviewProvider()
    ) { entry in
      ExpenseLockScreenWidgetView(entry: entry)
    }
    .configurationDisplayName("锁屏消费")
    .description("在锁屏查看本周、本月或本年消费。")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

struct ExpenseLockScreenWidgetView: View {
  @Environment(\.widgetFamily) private var family
  let entry: ExpenseOverviewEntry
  var familyOverride: WidgetFamily?

  var body: some View {
    Group {
      if let snapshot = entry.snapshot,
        let expense = entry.period.currentExpense(in: snapshot, now: entry.date)
      {
        content(
          expense,
          updatedAt: entry.period == .month
            ? snapshot.updatedAt : snapshot.insights?.date ?? snapshot.updatedAt
        )
        .privacySensitive()
      } else {
        Label("打开 Ledger 刷新", systemImage: "arrow.clockwise")
          .font(.caption2).minimumScaleFactor(0.6)
      }
    }
    .widgetURL(URL(string: "ledger://overview"))
    .containerBackground(for: .widget) { Color.clear }
  }

  @ViewBuilder
  private func content(_ expense: LedgerWidgetExpenseSnapshot, updatedAt: Date) -> some View {
    let amount = MoneyText.formatCompact(minorUnits: expense.amount, currency: expense.currency)
    switch familyOverride ?? family {
    case .accessoryInline:
      Text("\(entry.period.title) \(amount)")
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        VStack(spacing: 2) {
          Text(entry.period.title).font(.system(size: 9, weight: .medium))
          Text(amount).font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
        }.padding(4)
      }
    default:
      VStack(alignment: .leading, spacing: 2) {
        Label(entry.period.title, systemImage: "chart.line.uptrend.xyaxis").font(.caption2)
        Text(amount).font(.system(size: 21, weight: .semibold, design: .rounded))
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        Text(LedgerWidgetText.updated(updatedAt, now: entry.date)).font(.system(size: 9)).lineLimit(
          1)
      }
    }
  }
}
