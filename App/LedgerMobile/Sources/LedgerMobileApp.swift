import SwiftUI

@main
struct LedgerMobileApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LedgerBackgroundAppDelegate.self) private var backgroundDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: LedgerSession
    #if os(iOS)
    private let quickActions = LedgerQuickActionCenter.shared
    #endif
    @State private var didStartSession = false

    init() {
        // As early as possible: a crash during launch or the first ledger read
        // then still has the launch breadcrumb and the version in its report.
        LedgerCrashLog.shared.install()
        // Opt-in measurement recording must exist before the first ledger work
        // so a cold-start run is captured. Without `--ledger-perf-record` (and
        // without a stored opt-in) this changes nothing.
        LocalLedgerPerformanceRecording.configureLaunch()
        let session = LedgerSession.appSession()
        _session = StateObject(wrappedValue: session)
        LocalLedgerBackgroundSyncService.shared.configure { [weak session] in
            let synced = await session?.performBackgroundLocalSync() ?? false
            #if os(iOS)
            // Extends the reminders' two-week horizon without a visit.
            LedgerLocalReminders.shared.reschedule()
            #endif
            return synced
        }
        LedgerShortcutRecordingHost.shared.configure { [weak session] id, catalog in
            await session?.shortcutRecordCommitted(ledgerID: id, catalog: catalog)
        }
        LocalLedgerBackgroundSyncService.shared.startMonitoring { [weak session] reachable in
            session?.updateLocalSyncNetworkAvailability(reachable)
        }
        #if os(iOS)
        LedgerAgentNotifications.shared.open = { [weak session] in
            // Only hand the tap to the route; the assistant's cover (and the
            // background conversation it reveals) waits for an active scene and
            // a ready ledger, where `applyPendingExternalRoute` presents it once.
            LedgerCrashLog.shared.record("账本助手通知：打开")
            session?.openAgentFromNotification()
        }
        // 记账提醒 and 导入账单提醒 open their pages like a widget link.
        LedgerLocalReminders.shared.open = { [weak session] url in
            session?.openWidgetURL(url)
        }
        LedgerLocalReminders.shared.attach(session)
        // 周报 / 月报 and the 导入账单 reminder before each report.
        LedgerReportReminders.install()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .ledgerSoftTopEdge()
                .environmentObject(session)
                .task {
                    session.startLocalAutomaticSyncServices()
                    await session.updateActivity(
                        isActive: scenePhase == .active,
                        isBackground: scenePhase == .background
                    )
                    await session.start()
                    didStartSession = true
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    LedgerCrashLog.shared.record("scene \(phase)")
                    // System authentication briefly makes the scene inactive. Its task must
                    // survive that transition, and only a real background visit rearms it.
                    Task {
                        await session.updateActivity(
                            isActive: phase == .active,
                            isBackground: phase == .background
                        )
                        // The initial active callback runs alongside the startup task.
                        // `start()` owns cold-launch authentication; only later foreground
                        // transitions need a second automatic-unlock attempt.
                        if didStartSession {
                            await session.automaticallyUnlockIfNeeded()
                        }
                        if phase == .active {
                            // A notification tap that cold-started or resumed the
                            // app waited for an active scene before presenting the
                            // assistant; apply it now that the scene is active.
                            await session.applyPendingExternalRoute()
                            #if os(iOS)
                            LedgerLocalReminders.shared.reschedule()
                            #endif
                            await session.runAutomaticLedgerBackupIfDue()
                        }
                        #if os(iOS)
                        if phase == .background {
                            await session.flushBackgroundLocalSyncIfNeeded()
                        }
                        #endif
                    }
                }
                .onChange(of: session.phase) { _, phase in
                    // Unlocking finishes after the scene became active.
                    if phase == .ready, scenePhase == .active {
                        Task { await session.runAutomaticLedgerBackupIfDue() }
                    }
                    #if os(iOS)
                    // 智能跳过 can only read the ledger once it is unlocked.
                    if phase == .ready { LedgerLocalReminders.shared.reschedule() }
                    #endif
                }
                #if os(iOS)
                // A write, an import, a sync or another ledger.
                .onChange(of: session.presentedLocalRevisionID) { _, _ in
                    LedgerLocalReminders.shared.reschedule()
                }
                #endif
                .onOpenURL { url in
                    if url.isFileURL {
                        Task { await session.receiveSharedFile(url) }
                    } else {
                        session.openWidgetURL(url)
                    }
                }
                #if os(iOS)
                // A long press on the app icon: opened like a widget link, so
                // the same unlock-then-run path applies.
                .onReceive(quickActions.$pending) { url in
                    guard let url else { return }
                    quickActions.pending = nil
                    session.openWidgetURL(url)
                }
                .task { quickActions.installShortcutItems() }
                #endif
        }
    }
}
