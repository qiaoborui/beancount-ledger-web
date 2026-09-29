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
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseOverviewEntry
    var familyOverride: WidgetFamily?
    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                Label("已隐藏", systemImage: "lock.fill").font(.system(size: 11)).unredacted()
            } else if let snapshot = entry.snapshot,
                      let expense = entry.period.currentExpense(in: snapshot, now: entry.date) {
                content(expense, updated: entry.period == .month ? snapshot.updatedAt : snapshot.insights?.date ?? snapshot.updatedAt)
                    .privacySensitive()
            } else {
                Text("打开 Ledger 刷新").font(.system(size: 10)).lineLimit(2)
            }
        }.widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { Color.clear }
    }
    @ViewBuilder private func content(_ expense: LedgerWidgetExpenseSnapshot, updated: Date) -> some View {
        let amount = MoneyText.format(minorUnits: expense.amount, currency: expense.currency)
        switch familyOverride ?? family {
        case .accessoryInline:
            Text("\(entry.period.title) \(amount)").font(.system(size: 11, design: .monospaced))
        case .accessoryCircular:
            VStack(spacing: 3) {
                Text(entry.period.title.replacingOccurrences(of: "消费", with: ""))
                    .font(.system(size: 10))
                Text(MoneyText.formatWidget(minorUnits: expense.amount, currency: expense.currency))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("约").font(.system(size: 8))
            }.accessibilityElement(children: .ignore).accessibilityLabel("\(entry.period.title) \(amount)")
        default:
            HStack(spacing: 8) {
                Rectangle().frame(width: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.period.title).font(.system(size: 10))
                    Text(amount).font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.4)
                    Text("\(expense.transactionCount)笔 · \(LedgerWidgetText.updated(updated, now: entry.date))")
                        .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }
}
