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

/// Accessory families render vibrant: only `.primary`/`.secondary` and opacity
/// survive. A locked device keeps each layout and masks the figure.
struct ExpenseLockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseOverviewEntry
    var familyOverride: WidgetFamily?
    var body: some View {
        Group {
            if let snapshot = entry.snapshot,
               let expense = entry.period.currentExpense(in: snapshot, now: entry.date) {
                content(expense)
            } else {
                Text("打开 Ledger 刷新").font(LedgerWidgetFont.text(11)).lineLimit(2)
                    .multilineTextAlignment(resolvedFamily == .accessoryCircular ? .center : .leading)
            }
        }.widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) {
                if resolvedFamily == .accessoryCircular { AccessoryWidgetBackground() } else { Color.clear }
            }
    }

    private var resolvedFamily: WidgetFamily { familyOverride ?? family }

    @ViewBuilder private func content(_ expense: LedgerWidgetExpenseSnapshot) -> some View {
        let amount = MoneyText.format(minorUnits: expense.amount, currency: expense.currency)
        switch resolvedFamily {
        case .accessoryInline:
            // Inline shows a single Text, so the label masks with the figure.
            Text(verbatim: "\(entry.period.shortTitle) \(amount)")
                .font(LedgerWidgetFont.text(12)).monospacedDigit().privacySensitive()
        case .accessoryCircular:
            // 约 marks a compact figure that differs from the full amount. Its
            // presence depends on the amount, so a locked device never shows it.
            let compact = MoneyText.formatCompact(minorUnits: expense.amount, currency: expense.currency)
            VStack(spacing: 1) {
                Text(entry.period.glyph)
                    .font(LedgerWidgetFont.medium(10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(verbatim: compact)
                    .font(LedgerWidgetFont.medium(15)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5).privacySensitive()
                if compact != amount && redactionReasons.isEmpty {
                    Text("约").font(LedgerWidgetFont.text(8)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(entry.period.title) \(amount)")
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.period.title).font(LedgerWidgetFont.medium(11)).foregroundStyle(.secondary)
                Text(verbatim: amount).font(LedgerWidgetFont.medium(22)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4).privacySensitive()
                if let percentage = expense.yearOverYearPercentage {
                    Text("同比 \(LedgerWidgetText.signedPercentage(percentage))")
                        .font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).privacySensitive()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension LedgerWidgetPeriod {
    /// One-word period name for the circular Lock Screen widget.
    var glyph: LocalizedStringKey {
        switch self {
        case .week: "周"
        case .month: "月"
        case .year: "年"
        }
    }
}
