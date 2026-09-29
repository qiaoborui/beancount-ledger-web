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
    @Environment(\.redactionReasons) private var redactionReasons
    let entry: ExpenseOverviewEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        Group {
            if !redactionReasons.isEmpty {
                LedgerWidgetPrivacyView(title: "支出概览")
            } else if let snapshot = entry.snapshot,
                      let expense = entry.period.currentExpense(in: snapshot, now: entry.date) {
                let updated = entry.period == .month ? snapshot.updatedAt : snapshot.insights?.date ?? snapshot.updatedAt
                content(expense, updated: updated)
            } else {
                LedgerWidgetUnavailableView(title: "等待消费数据", detail: "打开 Ledger 并刷新一次")
            }
        }
        .widgetURL(URL(string: "ledger://overview"))
        .containerBackground(for: .widget) { LedgerWidgetColors.panel }
    }

    private func content(_ expense: LedgerWidgetExpenseSnapshot, updated: Date) -> some View {
        let medium = (familyOverride ?? family) == .systemMedium
        return VStack(alignment: .leading, spacing: 8) {
            LedgerWidgetHeader(title: "支出", detail: periodDetail(expense))
            if medium {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        LedgerWidgetAmount(amount: expense.amount, currency: expense.currency)
                        comparison(expense.yearOverYearPercentage)
                        Spacer(minLength: 0)
                        Text(expense.transactionCount == 0 ? "暂无支出" : "\(expense.transactionCount) 笔 · 分类占比 →")
                            .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(LedgerWidgetColors.line).frame(width: 1)
                    categories(expense).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            } else {
                LedgerWidgetAmount(amount: expense.amount, currency: expense.currency)
                comparison(expense.yearOverYearPercentage)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Rectangle().fill(LedgerWidgetColors.accent).frame(width: 16, height: 2)
                    Text(expense.transactionCount == 0 ? "暂无支出" : "\(expense.transactionCount) 笔支出")
                        .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
                }
            }
            LedgerWidgetFooter(label: expense.currency, date: updated, now: entry.date)
        }.privacySensitive()
    }

    private func comparison(_ percentage: Double?) -> some View {
        Text(percentage.map { "\($0 < 0 ? "↓" : "↑") \(LedgerWidgetText.percentage(abs($0))) · 同比" } ?? "暂无同期数据")
            .font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
    }

    private func periodDetail(_ expense: LedgerWidgetExpenseSnapshot) -> String {
        switch entry.period {
        case .month: expense.periodTitle
        case .year: String(expense.start.prefix(4)) + "年"
        case .week: LedgerWidgetHeat.shortDate(expense.start) + " 起"
        }
    }

    private func categories(_ expense: LedgerWidgetExpenseSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if expense.categories.isEmpty {
                Text("暂无分类数据").font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.secondary)
            } else {
                ForEach(Array(expense.categories.prefix(3).enumerated()), id: \.element.id) { index, category in
                    let fraction = expense.amount > 0 ? min(max(Double(category.amount) / Double(expense.amount), 0), 1) : 0
                    HStack(alignment: .top, spacing: 6) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(LedgerWidgetColors.accent)
                        VStack(spacing: 4) {
                            HStack(spacing: 3) {
                                Text(category.label).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(LedgerWidgetText.percentage(fraction)).monospacedDigit()
                            }.font(.system(size: 10)).foregroundStyle(LedgerWidgetColors.ink)
                            GeometryReader { bounds in
                                Rectangle().fill(LedgerWidgetColors.line)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(LedgerWidgetColors.accent).frame(width: bounds.size.width * fraction)
                                    }
                            }.frame(height: 2)
                        }
                    }
                }
            }
        }
    }
}
