import Charts
import AppIntents
import SwiftUI
import WidgetKit

struct ExpenseOverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerWidgetSnapshot?
    var period: LedgerWidgetPeriod = .month
}

extension LedgerWidgetPeriod: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "统计周期"
    static let caseDisplayRepresentations: [LedgerWidgetPeriod: DisplayRepresentation] = [
        .week: "周", .month: "月", .year: "年"
    ]
}

struct ExpenseWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "消费统计"
    static let description = IntentDescription("选择周、月或年维度。")
    @Parameter(title: "统计周期", default: .month) var period: LedgerWidgetPeriod
}

struct ExpenseOverviewProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ExpenseOverviewEntry {
        ExpenseOverviewEntry(date: Date(), snapshot: .placeholder)
    }

    func snapshot(for configuration: ExpenseWidgetIntent, in context: Context) async -> ExpenseOverviewEntry {
            ExpenseOverviewEntry(
                date: Date(),
                snapshot: context.isPreview ? .placeholder : LedgerWidgetSnapshotStore.shared.load(),
                period: configuration.period
            )
    }

    func timeline(for configuration: ExpenseWidgetIntent, in context: Context) async -> Timeline<ExpenseOverviewEntry> {
        let now = Date()
        let result = await LedgerWidgetTimelineLoader.shared.load(now: now)
        return Timeline(
            entries: [ExpenseOverviewEntry(date: now, snapshot: result.snapshot, period: configuration.period)],
            policy: .after(now.addingTimeInterval(result.refreshInterval))
        )
    }
}

struct ExpenseOverviewWidget: Widget {
    let kind = "LedgerExpenseOverviewWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ExpenseWidgetIntent.self, provider: ExpenseOverviewProvider()) { entry in
            ExpenseOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("消费概览")
        .description("按周、月或年查看消费、同比与主要分类。")
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
        if let snapshot = entry.snapshot, let expense = entry.period.currentExpense(in: snapshot, now: entry.date) {
            let updatedAt = entry.period == .month ? snapshot.updatedAt : snapshot.insights?.date ?? snapshot.updatedAt
            Group {
                if (familyOverride ?? family) == .systemMedium {
                    medium(expense, updatedAt: updatedAt)
                } else {
                    small(expense, updatedAt: updatedAt)
                }
            }
            .widgetURL(URL(string: "ledger://overview"))
            .privacySensitive()
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
            LedgerWidgetHeader(title: entry.period.title, detail: periodDetail(expense))
            Spacer(minLength: 8)
            Text(MoneyText.formatWidget(minorUnits: expense.amount, currency: expense.currency))
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(LedgerWidgetColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
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
                LedgerWidgetHeader(title: entry.period.title, detail: periodDetail(expense))
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

    private func periodDetail(_ expense: LedgerWidgetExpenseSnapshot) -> String {
        switch entry.period {
        case .month: expense.periodTitle
        case .year: String(expense.start.prefix(4)) + "年"
        case .week: String(expense.start.suffix(5)).replacingOccurrences(of: "-", with: "/") + " 起"
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
