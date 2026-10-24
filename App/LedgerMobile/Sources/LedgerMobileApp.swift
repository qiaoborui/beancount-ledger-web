import SwiftUI

@main
struct LedgerMobileApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LedgerBackgroundAppDelegate.self) private var backgroundDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: LedgerSession
    @State private var didStartSession = false

    init() {
        // Opt-in measurement recording must exist before the first ledger work
        // so a cold-start run is captured. Without `--ledger-perf-record` (and
        // without a stored opt-in) this changes nothing.
        LocalLedgerPerformanceRecording.configureLaunch()
        let session = LedgerSession.appSession()
        _session = StateObject(wrappedValue: session)
        LocalLedgerBackgroundSyncService.shared.configure { [weak session] in
            await session?.performBackgroundLocalSync() ?? false
        }
        LocalLedgerBackgroundSyncService.shared.startMonitoring { [weak session] reachable in
            session?.updateLocalSyncNetworkAvailability(reachable)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
                }
                .onOpenURL { url in
                    if url.isFileURL {
                        Task { await session.receiveSharedFile(url) }
                    } else {
                        session.openWidgetURL(url)
                    }
                }
        }
    }
}
