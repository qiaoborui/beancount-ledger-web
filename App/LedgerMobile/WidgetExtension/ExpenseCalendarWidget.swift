import SwiftUI
import WidgetKit

struct ExpenseCalendarEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
}

struct ExpenseCalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExpenseCalendarEntry {
        ExpenseCalendarEntry(date: LedgerWidgetSnapshot.placeholder.updatedAt, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ExpenseCalendarEntry) -> Void) {
        completion(
            ExpenseCalendarEntry(
                date: Date(),
                snapshot: context.isPreview ? .placeholder : LedgerWidgetSnapshotStore.shared.load()
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExpenseCalendarEntry>) -> Void) {
        let now = Date()
        completion(
            Timeline(
                entries: [ExpenseCalendarEntry(date: now, snapshot: LedgerWidgetSnapshotStore.shared.load())],
                policy: .after(now.addingTimeInterval(30 * 60))
            )
        )
    }
}

struct ExpenseCalendarWidget: Widget {
    let kind = "LedgerExpenseCalendarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExpenseCalendarProvider()) { entry in
            ExpenseCalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("消费日历")
        .description("用日历热力图查看本月每日消费强度。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ExpenseCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExpenseCalendarEntry
    var familyOverride: WidgetFamily?

    init(entry: ExpenseCalendarEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            let layout = ExpenseCalendarLayout(expense: snapshot.expense)
            Group {
                if (familyOverride ?? family) == .systemLarge {
                    large(snapshot.expense, layout: layout, updatedAt: snapshot.updatedAt)
                } else {
                    medium(snapshot.expense, layout: layout, updatedAt: snapshot.updatedAt)
                }
            }
            .widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
        } else {
            LedgerWidgetUnavailableView(
                title: "等待消费日历",
                detail: "打开 Ledger 并刷新一次",
                symbol: "calendar"
            )
            .widgetURL(URL(string: "ledger://overview"))
        }
    }

    private func medium(
        _ expense: LedgerWidgetExpenseSnapshot,
        layout: ExpenseCalendarLayout,
        updatedAt: Date
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                LedgerWidgetHeader(title: "消费日历", detail: expense.periodTitle)
                Spacer(minLength: 6)
                Text(MoneyText.formatWidget(minorUnits: expense.amount, currency: expense.currency))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                    .privacySensitive()
                Text(layout.peakDay.map { "最高 \(Self.dayLabel($0))" } ?? "本月暂无消费")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .padding(.top, 4)
                Spacer(minLength: 4)
                Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            .frame(maxWidth: 132, alignment: .leading)

            ExpenseMonthGrid(layout: layout, compact: true)
                .privacySensitive()
        }
    }

    private func large(
        _ expense: LedgerWidgetExpenseSnapshot,
        layout: ExpenseCalendarLayout,
        updatedAt: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LedgerWidgetHeader(title: "消费日历", detail: expense.periodTitle)
                Text("消费越高颜色越深")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .lineLimit(1)
            }
            .padding(.bottom, 12)

            ExpenseMonthGrid(layout: layout, compact: false)
                .privacySensitive()

            Spacer(minLength: 10)
            HStack(spacing: 8) {
                calendarMetric(
                    title: "本月消费",
                    value: MoneyText.formatWidget(minorUnits: expense.amount, currency: expense.currency)
                )
                calendarMetric(title: "消费天数", value: "\(layout.spendingDayCount) 天")
                calendarMetric(
                    title: "最高单日",
                    value: MoneyText.formatWidget(minorUnits: layout.peakAmount, currency: expense.currency)
                )
            }
            .privacySensitive()
            Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
                .padding(.top, 8)
        }
    }

    private func calendarMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LedgerWidgetColors.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(LedgerWidgetColors.raised.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static func dayLabel(_ day: Int) -> String {
        String(format: "%02d日", day)
    }
}

private struct ExpenseMonthGrid: View {
    let layout: ExpenseCalendarLayout
    let compact: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            LazyVGrid(columns: columns, spacing: compact ? 2 : 4) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: compact ? 7 : 9, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(layout.cells.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func dayCell(_ day: Int?) -> some View {
        if let day {
            let amount = layout.amounts[day] ?? 0
            Text("\(day)")
                .font(.system(size: compact ? 6.5 : 9, weight: amount > 0 ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(amount > layout.maxAmount / 2 ? LedgerWidgetColors.onBrand : LedgerWidgetColors.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 10 : 24)
                .background(heatColor(amount))
                .clipShape(RoundedRectangle(cornerRadius: compact ? 2.5 : 5, style: .continuous))
        } else {
            Color.clear
                .frame(height: compact ? 10 : 24)
        }
    }

    private func heatColor(_ amount: Int) -> Color {
        guard amount > 0, layout.maxAmount > 0 else { return LedgerWidgetColors.raised.opacity(0.62) }
        let ratio = min(max(Double(amount) / Double(layout.maxAmount), 0), 1)
        return LedgerWidgetColors.expense.opacity(0.22 + ratio * 0.78)
    }
}

struct ExpenseCalendarLayout {
    let cells: [Int?]
    let amounts: [Int: Int]
    let maxAmount: Int
    let peakDay: Int?
    let peakAmount: Int
    let spendingDayCount: Int

    init(expense: LedgerWidgetExpenseSnapshot) {
        let startParts = expense.start.split(separator: "-").compactMap { Int($0) }
        let year = startParts.count == 3 ? startParts[0] : 2001
        let month = startParts.count == 3 ? startParts[1] : 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let startDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let dayCount = calendar.range(of: .day, in: .month, for: startDate)?.count ?? 31
        let weekday = calendar.component(.weekday, from: startDate)
        let leadingEmptyCount = (weekday + 5) % 7

        var dailyAmounts: [Int: Int] = [:]
        for point in expense.dailySeries {
            let parts = point.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, parts[0] == year, parts[1] == month else { continue }
            dailyAmounts[parts[2], default: 0] += max(point.amount, 0)
        }

        var values = Array<Int?>(repeating: nil, count: leadingEmptyCount)
        values.append(contentsOf: (1...dayCount).map(Optional.some))
        values.append(contentsOf: Array<Int?>(repeating: nil, count: max(42 - values.count, 0)))
        cells = Array(values.prefix(42))
        amounts = dailyAmounts
        let peak = dailyAmounts.max { left, right in
            if left.value != right.value { return left.value < right.value }
            return left.key > right.key
        }
        peakDay = peak?.key
        peakAmount = peak?.value ?? 0
        maxAmount = peakAmount
        spendingDayCount = dailyAmounts.values.filter { $0 > 0 }.count
    }
}
