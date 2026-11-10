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
        .description("按周、月或年查看支出、同比与主要分类。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// A locked device keeps this layout and masks only the figures.
struct ExpenseOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.redactionReasons) private var redactionReasons
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: ExpenseOverviewEntry
    var familyOverride: WidgetFamily?

    var body: some View {
        Group {
            if let snapshot = entry.snapshot,
               let expense = entry.period.currentExpense(in: snapshot, now: entry.date) {
                let updated = entry.period == .month ? snapshot.updatedAt : snapshot.insights?.date ?? snapshot.updatedAt
                content(expense, updated: updated)
            } else {
                LedgerWidgetUnavailableView(title: String(localized: "支出"))
            }
        }
        .widgetURL(URL(string: "ledger://overview"))
        .containerBackground(for: .widget) { LedgerWidgetColors.sunken }
    }

    private var tone: LedgerWidgetTone { LedgerWidgetTone(renderingMode) }

    private func content(_ expense: LedgerWidgetExpenseSnapshot, updated: Date) -> some View {
        let medium = (familyOverride ?? family) == .systemMedium
        return VStack(alignment: .leading, spacing: 0) {
            LedgerWidgetHeader(title: String(localized: "支出"), detail: entry.period.shortTitle)
            if medium {
                HStack(spacing: 12) {
                    summary(expense, showsCount: true).frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(tone.rule).frame(width: 1)
                    categories(expense).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 10).frame(maxHeight: .infinity, alignment: .top)
            } else {
                summary(expense, showsCount: false).padding(.top, 10)
                Spacer(minLength: 0)
            }
            LedgerWidgetFooter(date: updated, now: entry.date)
        }
    }

    private func summary(_ expense: LedgerWidgetExpenseSnapshot, showsCount: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LedgerWidgetAmount(amount: expense.amount, currency: expense.currency, size: 27)
            // `previous` is the same range a year earlier, so this is 同比 for
            // every period; a missing or zero baseline hides the line.
            if let percentage = expense.yearOverYearPercentage {
                Text("同比 \(LedgerWidgetText.signedPercentage(percentage))")
                    .font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8).privacySensitive()
            }
            if showsCount {
                Spacer(minLength: 0)
                Text(countLine(expense))
                    .font(LedgerWidgetFont.text(10)).monospacedDigit().foregroundStyle(tone.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8).privacySensitive()
            }
        }
    }

    private func countLine(_ expense: LedgerWidgetExpenseSnapshot) -> String {
        guard expense.transactionCount > 0 else { return String(localized: "暂无支出") }
        let daily = expense.amount / max(expense.elapsedDays(now: entry.date), 1)
        return String(localized: "\(expense.transactionCount) 笔 · 日均 \(MoneyText.formatWidget(minorUnits: daily, currency: expense.currency))")
    }

    /// The builder already keeps the top three; render what the snapshot holds.
    private func categories(_ expense: LedgerWidgetExpenseSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if expense.categories.isEmpty {
                Text("暂无分类数据").font(LedgerWidgetFont.text(10)).foregroundStyle(tone.meta)
            } else {
                ForEach(expense.categories) { category in
                    // Bars are shapes, which `privacySensitive` leaves visible.
                    let fraction = expense.amount > 0 && redactionReasons.isEmpty
                        ? min(max(Double(category.amount) / Double(expense.amount), 0), 1) : 0
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text(category.label).foregroundStyle(tone.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(MoneyText.formatWidget(minorUnits: category.amount, currency: expense.currency))
                                .monospacedDigit().foregroundStyle(tone.ink).lineLimit(1)
                        }.font(LedgerWidgetFont.text(10))
                        GeometryReader { bounds in
                            Rectangle().fill(tone.rule)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(tone.isFullColor ? LedgerWidgetColors.expense : tone.ink)
                                        .frame(width: bounds.size.width * fraction)
                                        .widgetAccentable()
                                }
                        }.frame(height: 2)
                    }.privacySensitive()
                }
            }
        }
    }
}
