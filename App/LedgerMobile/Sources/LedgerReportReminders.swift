import Foundation

/// Connects 周报 / 月报 to the local reminder scheduler from #668. The report
/// schedule itself is pure (`LedgerReportSchedule.contribution`); this only
/// tells the scheduler that the report settings changed.
enum LedgerReportReminders {
    /// Called after the report settings are saved.
    @MainActor static func settingsChanged() {
        // Wired to #668's `LedgerLocalReminders` once its registration lands.
    }
}
