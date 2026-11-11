import SwiftUI
import WidgetKit

/// 记一笔: the two entry forms one tap away, with what was spent today. The
/// buttons stay usable on a locked device, because the app asks for Face ID
/// before the form opens; only the figures are masked.
struct QuickRecordWidget: Widget {
    let kind = "LedgerQuickRecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExpenseCalendarProvider()) { entry in
            QuickRecordWidgetView(entry: entry)
        }
        .configurationDisplayName("记一笔")
        .description("一键记一笔或一句话记账，并查看今天的支出。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickRecordWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ExpenseCalendarEntry
    var familyOverride: WidgetFamily?

    /// Today's expense from the month's daily series, or nil when the stored
    /// month is over. The series nets refunds per day and drops days at or
    /// below zero, so this is not meant to add up to the month total.
    static func today(in snapshot: LedgerWidgetSnapshot?, now: Date) -> (today: Int, period: LedgerWidgetExpenseSnapshot)? {
        guard let snapshot, let expense = LedgerWidgetPeriod.month.currentExpense(in: snapshot, now: now),
              let amount = expense.amount(onDay: LedgerWidgetDates.localDay(now)) else { return nil }
        return (amount, expense)
    }

    var body: some View {
        Group {
            if (familyOverride ?? family) == .systemMedium { medium } else { small }
        }
        .widgetURL(LedgerQuickLink.record.url)
        .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }

    private var tone: LedgerWidgetTone { LedgerWidgetTone(renderingMode) }
    private var figures: (today: Int, period: LedgerWidgetExpenseSnapshot)? { Self.today(in: entry.snapshot, now: entry.date) }
    private var dayLabel: String { LedgerWidgetHeat.shortDate(LedgerWidgetDates.localDay(entry.date)) }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            LedgerWidgetHeader(title: String(localized: "记一笔"), detail: dayLabel)
            Link(destination: LedgerQuickLink.record.url) { recordButton }
            Link(destination: LedgerQuickLink.sentence.url) { tile(.sentence).frame(height: 30) }
            if let figures {
                HStack(spacing: 4) {
                    Text("今天支出")
                    Spacer(minLength: 0)
                    Text(verbatim: MoneyText.formatWidget(minorUnits: figures.today, currency: figures.period.currency))
                        .foregroundStyle(tone.ink).privacySensitive()
                }.font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.meta).lineLimit(1)
            } else {
                refresh
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                LedgerWidgetHeader(title: String(localized: "记一笔"), detail: dayLabel)
                Spacer(minLength: 0)
                if let figures {
                    Text("今天支出").font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
                    LedgerWidgetAmount(amount: figures.today, currency: figures.period.currency, size: 27)
                    HStack(spacing: 4) {
                        Text(LedgerWidgetPeriod.month.shortTitle)
                        Text(verbatim: MoneyText.formatWidget(minorUnits: figures.period.amount, currency: figures.period.currency))
                            .foregroundStyle(tone.secondary).privacySensitive()
                    }.font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.meta).lineLimit(1)
                } else {
                    refresh
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Link(destination: LedgerQuickLink.record.url) { recordButton }
                HStack(spacing: 8) {
                    Link(destination: LedgerQuickLink.sentence.url) { tile(.sentence) }
                    Link(destination: LedgerQuickLink.agent.url) { tile(.agent) }
                }.frame(height: 40)
            }.frame(width: 156)
        }
    }

    private var refresh: some View {
        Text("打开 Ledger 刷新").font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta).lineLimit(1)
    }

    /// The big "+", filled in full colour and outlined on tinted Home Screens.
    private var recordButton: some View {
        Image(systemName: LedgerQuickLink.record.systemImage)
            .font(.system(size: 26, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ledgerWidgetPrimaryButton(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LedgerQuickLink.record.title)
    }

    private func tile(_ link: LedgerQuickLink) -> some View {
        HStack(spacing: 5) {
            Image(systemName: link.systemImage).font(.system(size: 12, weight: .medium))
            Text(link.shortTitle).font(LedgerWidgetFont.medium(11)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ledgerWidgetTile()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.title)
    }
}
