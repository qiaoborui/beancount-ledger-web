import Charts
import SwiftUI
import WidgetKit

struct ExpenseOverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
}

struct ExpenseOverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> ExpenseOverviewEntry {
        ExpenseOverviewEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ExpenseOverviewEntry) -> Void) {
        completion(
            ExpenseOverviewEntry(
                date: Date(),
                snapshot: context.isPreview ? .placeholder : LedgerWidgetSnapshotStore.shared.load()
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ExpenseOverviewEntry>) -> Void) {
        let now = Date()
        let entry = ExpenseOverviewEntry(date: now, snapshot: LedgerWidgetSnapshotStore.shared.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct ExpenseOverviewWidget: Widget {
    let kind = "LedgerExpenseOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ExpenseOverviewProvider()) { entry in
            ExpenseOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("消费概览")
        .description("查看本月支出、同比变化与主要消费分类。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ExpenseOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ExpenseOverviewEntry
    var familyOverride: WidgetFamily?

    init(entry: ExpenseOverviewEntry, familyOverride: WidgetFamily? = nil) {
        self.entry = entry
        self.familyOverride = familyOverride
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            Group {
                if (familyOverride ?? family) == .systemMedium {
                    medium(snapshot.expense, updatedAt: snapshot.updatedAt)
                } else {
                    small(snapshot.expense, updatedAt: snapshot.updatedAt)
                }
            }
            .widgetURL(URL(string: "ledger://overview"))
            .containerBackground(for: .widget) { LedgerWidgetColors.panel }
        } else {
            LedgerWidgetUnavailableView(
                title: "等待消费数据",
                detail: "打开 Ledger 并刷新一次"
            )
            .widgetURL(URL(string: "ledger://overview"))
        }
    }

    private func small(_ expense: LedgerWidgetExpenseSnapshot, updatedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerWidgetHeader(title: "本月消费", detail: expense.periodTitle)
            Spacer(minLength: 8)
            Text(MoneyText.formatWidget(minorUnits: expense.amount, currency: expense.currency))
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
                .privacySensitive()
            HStack(spacing: 6) {
                comparisonLabel(expense.yearOverYearPercentage)
                Text("·")
                Text("\(expense.transactionCount) 笔")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(LedgerWidgetColors.secondary)
            .padding(.top, 5)
            Spacer(minLength: 5)
            Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(LedgerWidgetColors.secondary)
        }
    }

    private func medium(_ expense: LedgerWidgetExpenseSnapshot, updatedAt: Date) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                LedgerWidgetHeader(title: "本月消费", detail: expense.periodTitle)
                Spacer(minLength: 6)
                Text(MoneyText.formatCompact(minorUnits: expense.amount, currency: expense.currency))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                    .privacySensitive()
                HStack(spacing: 5) {
                    comparisonLabel(expense.yearOverYearPercentage)
                    Text("\(expense.transactionCount) 笔")
                        .foregroundStyle(LedgerWidgetColors.secondary)
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.top, 4)
                if !expense.dailySeries.isEmpty {
                    Chart(expense.dailySeries) { point in
                        AreaMark(
                            x: .value("日期", point.date),
                            y: .value("支出", point.amount)
                        )
                        .foregroundStyle(LedgerWidgetColors.expense.opacity(0.12))
                        LineMark(
                            x: .value("日期", point.date),
                            y: .value("支出", point.amount)
                        )
                        .foregroundStyle(LedgerWidgetColors.expense)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 30)
                    .padding(.top, 5)
                    .privacySensitive()
                }
                Spacer(minLength: 2)
                Text(LedgerWidgetText.updated(updatedAt, now: entry.date))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LedgerWidgetColors.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text("主要分类")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.secondary)
                if expense.categories.isEmpty {
                    Text("暂无分类数据")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LedgerWidgetColors.secondary)
                } else {
                    ForEach(expense.categories) { category in
                        expenseCategory(category, total: expense.amount, currency: expense.currency)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func comparisonLabel(_ percentage: Double?) -> some View {
        if let percentage {
            Text("同比 \(LedgerWidgetText.percentage(percentage))")
                .foregroundStyle(percentage <= 0 ? LedgerWidgetColors.success : LedgerWidgetColors.expense)
        } else {
            Text("同比 --")
                .foregroundStyle(LedgerWidgetColors.secondary)
        }
    }

    private func expenseCategory(
        _ category: LedgerWidgetExpenseCategory,
        total: Int,
        currency: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(category.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LedgerWidgetColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(MoneyText.formatWidget(minorUnits: category.amount, currency: currency))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LedgerWidgetColors.secondary)
                    .privacySensitive()
            }
            GeometryReader { geometry in
                Capsule()
                    .fill(LedgerWidgetColors.raised)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LedgerWidgetColors.expense)
                            .frame(width: geometry.size.width * categoryFraction(category.amount, total: total))
                    }
            }
            .frame(height: 4)
        }
    }

    private func categoryFraction(_ value: Int, total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return min(max(CGFloat(value) / CGFloat(total), 0), 1)
    }
}
