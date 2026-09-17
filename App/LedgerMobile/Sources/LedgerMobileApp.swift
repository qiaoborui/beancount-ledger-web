import SwiftUI

@main
struct LedgerMobileApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LedgerBackgroundAppDelegate.self) private var backgroundDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session: LedgerSession

    init() {
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
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // System authentication briefly makes the scene inactive. Its task must
                    // survive that transition, and only a real background visit rearms it.
                    Task {
                        await session.updateActivity(
                            isActive: phase == .active,
                            isBackground: phase == .background
                        )
                        await session.automaticallyUnlockIfNeeded()
                        #if os(iOS)
                        if phase == .background {
                            await session.flushBackgroundLocalSyncIfNeeded()
                        }
                        #endif
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
