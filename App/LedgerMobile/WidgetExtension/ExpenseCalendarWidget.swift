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
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseCalendarEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "消费日历")
            } else if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                LedgerWidgetUnavailableView(title: "等待消费日历", detail: "打开 Ledger 并刷新一次", symbol: "calendar")
            }
        }
        .widgetURL(URL(string: "ledger://transactions"))
        .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }

    private func content(_ snapshot: LedgerWidgetSnapshot) -> some View {
        let expense = snapshot.expense
        let layout = ExpenseCalendarLayout(expense: expense, now: entry.date)
        let large = (familyOverride ?? family) == .systemLarge
        return VStack(alignment: .leading, spacing: large ? 12 : 6) {
            LedgerWidgetHeader(title: "消费日历", detail: expense.periodTitle)
            if large {
                HStack(alignment: .firstTextBaseline) {
                    LedgerWidgetAmount(amount: expense.amount, currency: expense.currency, size: 26)
                    Spacer(minLength: 0)
                    Text("\(layout.spendingDayCount)天有消费").font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
                }
                ExpenseMonthGrid(layout: layout, currency: expense.currency, compact: false)
                Rectangle().fill(LedgerWidgetColors.line).frame(height: 1)
                HStack(spacing: 4) {
                    Text(layout.peakDay.map { "最高 \(LedgerWidgetHeat.shortDate(layout.date(for: $0))) " + MoneyText.formatWidget(minorUnits: layout.peakAmount, currency: expense.currency) } ?? "暂无消费记录")
                    Spacer(minLength: 0)
                    Text("日均 " + MoneyText.formatWidget(minorUnits: expense.amount / max(layout.elapsedDayCount, 1), currency: expense.currency))
                }.font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary).lineLimit(1).minimumScaleFactor(0.75)
            } else {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        LedgerWidgetAmount(amount: expense.amount, currency: expense.currency, size: 17)
                        Text("\(layout.spendingDayCount)天有消费")
                        Text("色阶表示金额高低").font(.system(size: 9))
                    }.font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
                        .frame(width: 96, alignment: .leading)
                    ExpenseMonthGrid(layout: layout, currency: expense.currency, compact: true)
                }.frame(maxHeight: .infinity)
            }
            LedgerWidgetFooter(label: large ? "每日金额 · \(expense.currency)" : "描边为今天", date: snapshot.updatedAt, now: entry.date)
        }.privacySensitive()
    }
}

private struct ExpenseMonthGrid: View {
    @Environment(\.colorScheme) private var colorScheme
    let layout: ExpenseCalendarLayout
    let currency: String
    let compact: Bool

    // Trim only the trailing empty week; retain the calendar model's 42-cell contract.
    private var weeks: Int { ((layout.cells.lastIndex { $0 != nil } ?? 27) / 7) + 1 }
    var body: some View {
        GeometryReader { bounds in
            let gap: CGFloat = compact ? 2 : 4
            let header: CGFloat = compact ? 12 : 16
            let height = max(1, (bounds.size.height - header - CGFloat(weeks) * gap) / CGFloat(weeks))
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                        Text(day).font(.system(size: 9)).foregroundStyle(LedgerWidgetColors.secondary)
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
            let level = LedgerWidgetHeat.level(amount)
            let ink = level >= 3 ? LedgerWidgetColors.heatInk : LedgerWidgetColors.ink
            Link(destination: url) {
                VStack(spacing: 2) {
                    Text("\(day)").font(.system(size: compact ? 9 : 11, design: .monospaced))
                    if !compact {
                        Text(layout.isFuture(day) ? "–" : amount == 0 ? "·" : String(format: "%.0f", Double(amount) / 100))
                            .font(.system(size: 9, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.5)
                    }
                }.foregroundStyle(layout.isFuture(day) ? LedgerWidgetColors.secondary : ink)
                    .frame(maxWidth: .infinity).frame(height: height)
                    .background(layout.isFuture(day) ? Color.clear : LedgerWidgetHeat.color(amount))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay {
                        if day == layout.today {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(LedgerWidgetColors.accent, lineWidth: 1)
                        }
                    }
            }.buttonStyle(.plain)
                .accessibilityLabel("\(layout.date(for: day))，支出 \(MoneyText.format(minorUnits: amount, currency: currency))")
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: height)
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
    var elapsedDayCount: Int {
        cells.compactMap { $0 }.filter { !isFuture($0) }.count
    }
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
