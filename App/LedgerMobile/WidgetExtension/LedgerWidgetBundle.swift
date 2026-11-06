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
        // One slot for the quick-entry widget and its controls keeps this
        // block within the builder's ten-widget limit.
        LedgerQuickActionsBundle().body
#if !targetEnvironment(macCatalyst)
        ImportIndexLiveActivity()
        LedgerAgentLiveActivity()
#endif
    }
}

/// 快捷入口 and the matching Control Center buttons (iOS 18).
struct LedgerQuickActionsBundle: WidgetBundle {
    var body: some Widget {
        QuickActionsWidget()
#if !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            LedgerAgentControl()
            LedgerRecordControl()
        }
#endif
    }
}
