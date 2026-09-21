import SwiftUI
import WidgetKit

@main
struct LedgerWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if LEDGER_BOUNDED_READ_INDEX
        // Keep known kinds but never instantiate legacy providers, views or live
        // activities. No credentials, snapshot cache or financial placeholder.
        BoundedUnavailableWidget(kind: "LedgerExpenseOverviewWidget")
        BoundedUnavailableWidget(kind: "LedgerAccountBalanceWidget")
        BoundedUnavailableWidget(kind: "LedgerExpenseCalendarWidget")
        BoundedUnavailableWidget(kind: "LedgerExpenseTrendWidget")
        BoundedUnavailableWidget(kind: "LedgerExpenseHeatmapWidget")
        #if !targetEnvironment(macCatalyst)
        BoundedUnavailableWidget(kind: "LedgerExpenseLockScreenWidget")
        #endif
        BoundedUnavailableWidget(kind: "LedgerImportStatusWidget")
        #else
        ExpenseOverviewWidget()
        AccountBalanceWidget()
        ExpenseCalendarWidget()
        ExpenseTrendWidget()
        ExpenseHeatmapWidget()
        #if !targetEnvironment(macCatalyst)
        ExpenseLockScreenWidget()
        #endif
        ImportStatusWidget()
#if !targetEnvironment(macCatalyst)
        ImportIndexLiveActivity()
#endif
        #endif
    }
}

#if LEDGER_BOUNDED_READ_INDEX
private struct BoundedUnavailableEntry: TimelineEntry {
    let date: Date
}

private struct BoundedUnavailableProvider: TimelineProvider {
    func placeholder(in context: Context) -> BoundedUnavailableEntry { .init(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (BoundedUnavailableEntry) -> Void) {
        completion(.init(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BoundedUnavailableEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: Date())], policy: .never))
    }
}

private struct BoundedUnavailableWidget: Widget {
    let kind: String

    // Widget requires a zero-argument initializer even when the bundle supplies
    // an explicit kind for each disabled legacy widget.
    init() {
        self.init(kind: "LedgerExpenseOverviewWidget")
    }

    init(kind: String) {
        self.kind = kind
    }
    private var families: [WidgetFamily] {
        #if !targetEnvironment(macCatalyst)
        if kind == "LedgerExpenseLockScreenWidget" {
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
        #endif
        return [.systemSmall, .systemMedium, .systemLarge]
    }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BoundedUnavailableProvider()) { _ in
            Label("只读实验构建不提供小组件", systemImage: "lock.fill")
                .font(.caption)
                .containerBackground(.background, for: .widget)
        }
        .supportedFamilies(families)
        .configurationDisplayName("Ledger · 小组件停用")
        .description("有界只读构建不读取或显示财务快照，也不执行后台获取。")
    }
}
#endif