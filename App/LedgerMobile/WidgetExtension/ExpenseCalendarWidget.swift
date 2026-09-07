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

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ExpenseCalendarEntry>) -> Void) {
        let now = Date()
        Task {
            let result = await LedgerWidgetTimelineLoader.shared.load(now: now)
            completion(
                Timeline(
                    entries: [ExpenseCalendarEntry(date: now, snapshot: result.snapshot)],
                    policy: .after(now.addingTimeInterval(result.refreshInterval))
                )
            )
        }
    }
}

struct ExpenseCalendarWidget: Widget {
    let kind = "LedgerExpenseCalendarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExpenseCalendarProvider()) { entry in
            ExpenseCalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("消费日历")
        .description("查看每日消费，轻点日期打开当天的全部支出。")
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
            let layout = ExpenseCalendarLayout(expense: snapshot.expense, now: entry.date)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("消费日历", systemImage: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.cobalt)
                Text(expense.periodTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                Spacer(minLength: 0)
                if let today = layout.today, let url = layout.url(for: today) {
                    Link(destination: url) {
                        calendarMetric(title: "今日消费", value: money(layout.amounts[today] ?? 0, expense), prominent: true)
                    }
                } else {
                    calendarMetric(title: "月度消费", value: money(expense.amount, expense), prominent: true)
                }
                if layout.today != nil {
                    Text("本月 \(money(expense.amount, expense))")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .privacySensitive()
                }
                Spacer(minLength: 0)
                Text("点日期看支出")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            .frame(width: 96, alignment: .leading)

            ExpenseMonthGrid(layout: layout, currency: expense.currency, compact: true)
                .privacySensitive()
        }
    }

    private func large(
        _ expense: LedgerWidgetExpenseSnapshot,
        layout: ExpenseCalendarLayout,
        updatedAt: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(expense.periodTitle, systemImage: "calendar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LedgerWidgetColors.cobalt)
                    Text("消费日历 · 点日期看支出")
                        .font(.system(size: 10))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                }
                Spacer(minLength: 8)
                calendarMetric(title: "月度消费", value: money(expense.amount, expense))
                    .fixedSize(horizontal: true, vertical: false)
            }
            ExpenseMonthGrid(layout: layout, currency: expense.currency, compact: false)
                .privacySensitive()
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text("\(layout.spendingDayCount) 天有消费")
                    .privacySensitive()
                Spacer(minLength: 0)
                Text("少")
                ForEach(1...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LedgerWidgetColors.expense.opacity(Double(level) * 0.1))
                        .frame(width: 9, height: 9)
                }
                Text("多")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(LedgerWidgetColors.secondary)
            Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                .font(.system(size: 9))
                .foregroundStyle(LedgerWidgetColors.secondary)
        }
    }

    private func money(_ amount: Int, _ expense: LedgerWidgetExpenseSnapshot) -> String {
        MoneyText.formatWidget(minorUnits: amount, currency: expense.currency)
    }

    private func calendarMetric(title: String, value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
            Text(value)
                .font(.system(size: prominent ? 21 : 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .privacySensitive()
    }
}

private struct ExpenseMonthGrid: View {
    let layout: ExpenseCalendarLayout
    let currency: String
    let compact: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: compact ? 2 : 3) {
                ForEach(weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, compact ? 2 : 4)
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
        if let day, let url = layout.url(for: day) {
            let amount = layout.amounts[day] ?? 0
            Link(destination: url) {
                VStack(spacing: 2) {
                    Text("\(day)")
                        .font(.system(size: compact ? 11 : 12, weight: day == layout.today || amount > 0 ? .semibold : .regular))
                    if !compact {
                        Text(amount == 0 ? " " : MoneyText.formatWidget(minorUnits: amount, currency: currency))
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .monospacedDigit()
                .foregroundStyle(layout.isFuture(day) ? LedgerWidgetColors.secondary.opacity(0.55) : LedgerWidgetColors.ink)
                .frame(maxWidth: .infinity)
                .frame(height: compact ? 17 : 34)
                .background(heatColor(amount), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    if day == layout.today {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(LedgerWidgetColors.cobalt, lineWidth: 1.5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(layout.date(for: day))，支出 \(MoneyText.formatWidget(minorUnits: amount, currency: currency))")
            .accessibilityHint("查看当天全部支出")
        } else {
            Color.clear
                .frame(height: compact ? 17 : 34)
        }
    }

    private func heatColor(_ amount: Int) -> Color {
        guard amount > 0, layout.maxAmount > 0 else { return .clear }
        let ratio = min(max(Double(amount) / Double(layout.maxAmount), 0), 1)
        let level = max(1, ceil(sqrt(ratio) * 4))
        return LedgerWidgetColors.expense.opacity(level * 0.1)
    }
}

struct ExpenseCalendarLayout {
    let cells: [Int?]
    let amounts: [Int: Int]
    let maxAmount: Int
    let peakDay: Int?
    let peakAmount: Int
    let spendingDayCount: Int
    let monthPrefix: String
    let today: Int?
    private let currentDay: String

    func date(for day: Int) -> String { String(format: "%@-%02d", monthPrefix, day) }
    func url(for day: Int) -> URL? { LedgerWidgetLink.expenseDay(date(for: day)) }
    func isFuture(_ day: Int) -> Bool { date(for: day) > currentDay }

    init(expense: LedgerWidgetExpenseSnapshot, now: Date = Date()) {
        let startParts = expense.start.split(separator: "-").compactMap { Int($0) }
        let year = startParts.count == 3 ? startParts[0] : 2001
        let month = startParts.count == 3 ? startParts[1] : 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let startDate = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date()
        let dayCount = calendar.range(of: .day, in: .month, for: startDate)?.count ?? 31
        let weekday = calendar.component(.weekday, from: startDate)
        let leadingEmptyCount = (weekday + 5) % 7
        monthPrefix = String(format: "%04d-%02d", year, month)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        currentDay = formatter.string(from: now)
        today = currentDay.hasPrefix(monthPrefix + "-") ? Int(currentDay.suffix(2)) : nil

        var dailyAmounts: [Int: Int] = [:]
        for point in expense.dailySeries {
            let parts = point.date.split(separator: "-").compactMap { Int($0) }
            guard LedgerWidgetLink.isValidDay(point.date), parts.count == 3,
                  parts[0] == year, parts[1] == month else { continue }
            dailyAmounts[parts[2], default: 0] += point.amount
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
