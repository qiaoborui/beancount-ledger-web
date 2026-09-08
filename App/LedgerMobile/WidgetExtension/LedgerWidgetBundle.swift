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
#if !targetEnvironment(macCatalyst)
        ImportIndexLiveActivity()
#endif
    }
}
