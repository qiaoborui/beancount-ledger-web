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
                    entries: Self.entries(snapshot: result.snapshot, now: now, refreshInterval: result.refreshInterval),
                    policy: .after(now.addingTimeInterval(result.refreshInterval))
                )
            )
        }
    }

    /// Adds an entry at the next local midnight when the refresh falls after
    /// it, so today's outline and 今天支出 move to the new day on time.
    static func entries(snapshot: LedgerWidgetSnapshot?, now: Date, refreshInterval: TimeInterval,
                        calendar: Calendar = .current) -> [ExpenseCalendarEntry] {
        var entries = [ExpenseCalendarEntry(date: now, snapshot: snapshot)]
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           midnight < now.addingTimeInterval(refreshInterval) {
            entries.append(ExpenseCalendarEntry(date: midnight, snapshot: snapshot))
        }
        return entries
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

/// A locked device keeps the grid and masks the figures and heat; the day
/// links are dropped with them.
struct ExpenseCalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ExpenseCalendarEntry
    var familyOverride: WidgetFamily?

    /// The month to draw, or nil once it is over: after a rollover the stored
    /// month is last month's, which the overview already hides the same way.
    static func expense(in snapshot: LedgerWidgetSnapshot, now: Date) -> LedgerWidgetExpenseSnapshot? {
        LedgerWidgetPeriod.month.currentExpense(in: snapshot, now: now)
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let expense = Self.expense(in: snapshot, now: entry.date) {
                content(expense, updated: snapshot.updatedAt)
            } else {
                LedgerWidgetUnavailableView(title: String(localized: "消费日历"))
            }
        }
        .widgetURL(URL(string: "ledger://transactions"))
        .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }

    private func content(_ expense: LedgerWidgetExpenseSnapshot, updated: Date) -> some View {
        let tone = LedgerWidgetTone(renderingMode)
        let layout = ExpenseCalendarLayout(expense: expense, now: entry.date)
        let large = (familyOverride ?? family) == .systemLarge
        let grid = ExpenseMonthGrid(layout: layout, currency: expense.currency, compact: !large,
                                    isRedacted: !redactionReasons.isEmpty, mode: renderingMode)
        return VStack(alignment: .leading, spacing: large ? 10 : 6) {
            LedgerWidgetHeader(title: String(localized: "消费日历"), detail: expense.periodTitle)
            if large {
                HStack(alignment: .firstTextBaseline) {
                    LedgerWidgetAmount(amount: expense.amount, currency: expense.currency, size: 27)
                    Spacer(minLength: 0)
                    Text("\(layout.spendingDayCount)天有消费").font(LedgerWidgetFont.text(10))
                        .monospacedDigit().foregroundStyle(tone.meta).privacySensitive()
                }
                grid
                Rectangle().fill(tone.rule).frame(height: 1)
                HStack(spacing: 4) {
                    Text(layout.peakDay.map { String(localized: "最高 \(LedgerWidgetHeat.shortDate(layout.date(for: $0))) \(MoneyText.formatWidget(minorUnits: layout.peakAmount, currency: expense.currency))") } ?? String(localized: "暂无消费记录"))
                    Spacer(minLength: 0)
                    Text("日均 \(MoneyText.formatWidget(minorUnits: expense.amount / max(expense.elapsedDays(now: entry.date), 1), currency: expense.currency))")
                }.font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75).privacySensitive()
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        LedgerWidgetAmount(amount: expense.amount, currency: expense.currency, size: 23)
                        Text("\(layout.spendingDayCount)天有消费").monospacedDigit()
                            .foregroundStyle(tone.secondary).privacySensitive()
                        Spacer(minLength: 0)
                        Text("颜色越深支出越多").foregroundStyle(tone.meta)
                    }.font(LedgerWidgetFont.text(10)).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 104, alignment: .leading)
                    grid
                }.frame(maxHeight: .infinity)
            }
            LedgerWidgetFooter(label: large ? String(localized: "每日金额 · \(expense.currency)") : String(localized: "描边为今天"),
                               date: updated, now: entry.date)
        }
    }
}

private struct ExpenseMonthGrid: View {
    /// Monday-first single-letter weekday headers.
    private static var weekdayHeaders: [String] {
        let symbols = LedgerDateLabel.veryShortWeekdaySymbols
        return Array(symbols[1...]) + [symbols[0]]
    }

    let layout: ExpenseCalendarLayout
    let currency: String
    let compact: Bool
    /// A masked grid carries no dates in its links and no heat: shapes are
    /// not redacted by `privacySensitive`, so the fill would show relative spend.
    let isRedacted: Bool
    let mode: WidgetRenderingMode

    private var tone: LedgerWidgetTone { LedgerWidgetTone(mode) }

    // Trim only the trailing empty week; retain the calendar model's 42-cell contract.
    private var weeks: Int { ((layout.cells.lastIndex { $0 != nil } ?? 27) / 7) + 1 }
    var body: some View {
        GeometryReader { bounds in
            let gap: CGFloat = compact ? 2 : 4
            let header: CGFloat = compact ? 12 : 16
            let height = max(1, (bounds.size.height - header - CGFloat(weeks) * gap) / CGFloat(weeks))
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { index in
                        let day = Self.weekdayHeaders[index]
                        Text(day).font(LedgerWidgetFont.text(9)).foregroundStyle(tone.meta)
                            .frame(maxWidth: .infinity).frame(height: header)
                    }
                }
                ForEach(0..<weeks, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { column in
                            cell(layout.cells[row * 7 + column], height: height)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ day: Int?, height: CGFloat) -> some View {
        if let day, let url = layout.url(for: day) {
            let amount = layout.amounts[day] ?? 0
            let face = cellFace(day: day, amount: amount, height: height)
                .accessibilityLabel("\(layout.date(for: day))，支出 \(MoneyText.format(minorUnits: amount, currency: currency))")
            if !isRedacted {
                Link(destination: url) { face }.buttonStyle(.plain)
            } else {
                face
            }
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: height)
        }
    }

    private func cellFace(day: Int, amount: Int, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let future = layout.isFuture(day)
        let level = future || isRedacted ? 0 : LedgerWidgetHeat.level(amount)
        return ZStack {
            if future {
                label(day: day, amount: amount, future: true).foregroundStyle(tone.meta)
            } else if level >= 3 && !tone.isFullColor {
                // Tinted modes keep only opacity: cut the label out of a dark
                // cell instead of drawing one tint on top of another.
                shape.fill(LedgerWidgetHeat.color(level: level, mode: mode))
                    .mask {
                        ZStack {
                            Rectangle()
                            label(day: day, amount: amount, future: false).blendMode(.destinationOut)
                        }.compositingGroup()
                    }
            } else {
                shape.fill(LedgerWidgetHeat.color(level: level, mode: mode))
                label(day: day, amount: amount, future: false)
                    .foregroundStyle(level >= 3 ? LedgerWidgetColors.page : tone.ink)
            }
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .overlay {
            if day == layout.today {
                shape.strokeBorder(tone.expense, lineWidth: 1.5).widgetAccentable()
            }
        }
        .privacySensitive()
    }

    private func label(day: Int, amount: Int, future: Bool) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(day)").font(LedgerWidgetFont.text(compact ? 9 : 11)).monospacedDigit()
            if !compact {
                Text(verbatim: future ? "–" : amount == 0 ? "·" : String(format: "%.0f", Double(amount) / 100))
                    .font(LedgerWidgetFont.text(9)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            }
        }
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
    func dateString(for day: Int) -> String? {
        guard cells.contains(day) else { return nil }
        return date(for: day)
    }
    func url(for day: Int) -> URL? {
        guard let date = dateString(for: day) else { return nil }
        return LedgerWidgetLink.expenseDay(date)
    }
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
