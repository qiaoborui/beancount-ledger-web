import SwiftUI

@main
struct LedgerMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = LedgerSession.appSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .task {
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
                    }
                }
                .onOpenURL { url in
                    session.openWidgetURL(url)
                }
        }
    }
}
