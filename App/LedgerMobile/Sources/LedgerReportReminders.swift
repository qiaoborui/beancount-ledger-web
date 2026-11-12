#if os(iOS)
import Foundation
@preconcurrency import UserNotifications

/// Connects 周报 / 月报 to the local reminder scheduler (`LedgerLocalReminders`).
/// The schedule itself is pure (`LedgerReportSchedule.contribution`): the next
/// report notifications, without amounts, and the 导入账单 reminders the evening
/// before, which the planner merges with the user's own import reminder.
@MainActor
enum LedgerReportReminders {
    static let source = "reports"

    /// Registers the report provider once, at launch.
    static func install() {
        LedgerLocalReminders.shared.register(source: source) { context in
            LedgerReportSchedule.contribution(settings: LedgerReportSettings.load(),
                now: context.now, calendar: context.calendar)
        }
    }

    /// Called after the report settings are saved. Turning a report on asks
    /// for notification permission the first time.
    static func settingsChanged() {
        let settings = LedgerReportSettings.load()
        Task { @MainActor in
            if settings.anyEnabled { await requestPermissionIfNeeded() }
            LedgerLocalReminders.shared.reschedule()
        }
    }

    private static func requestPermissionIfNeeded() async {
        await LedgerLocalReminders.shared.refreshPermission()
        guard LedgerLocalReminders.shared.permission == .notDetermined else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                continuation.resume()
            }
        }
        await LedgerLocalReminders.shared.refreshPermission()
    }
}
#endif
