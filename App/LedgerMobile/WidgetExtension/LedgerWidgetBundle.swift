import SwiftUI
import WidgetKit

@main
struct LedgerWidgetBundle: WidgetBundle {
    var body: some Widget {
        ExpenseOverviewWidget()
        AccountBalanceWidget()
        ExpenseCalendarWidget()
        ImportStatusWidget()
#if !targetEnvironment(macCatalyst)
        ImportIndexLiveActivity()
#endif
    }
}
