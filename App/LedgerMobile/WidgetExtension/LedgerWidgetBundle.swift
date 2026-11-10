import SwiftUI
import WidgetKit

@main
struct LedgerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExpenseOverviewWidget()
        AccountBalanceWidget()
        ExpenseCalendarWidget()
        ExpenseTrendWidget()
        ExpenseHeatmapWidget()
        #if !targetEnvironment(macCatalyst)
        ExpenseLockScreenWidget()
        #endif
        ImportStatusWidget()
        // One slot for the quick-entry widgets (快捷入口 and 记一笔) and their
        // controls keeps this block within the builder's ten-widget limit.
        LedgerQuickActionsBundle().body
#if !targetEnvironment(macCatalyst)
        ImportIndexLiveActivity()
        LedgerAgentLiveActivity()
#endif
    }
}

/// 快捷入口, 记一笔 and the matching Control Center buttons (iOS 18).
struct LedgerQuickActionsBundle: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
        QuickRecordWidget()
#if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            LedgerAgentControl()
            LedgerRecordControl()
        }
#endif
    }
}
