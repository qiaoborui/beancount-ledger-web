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
                    await session.resume()
                }
                .task(id: scenePhase) {
                    await session.updateActivity(
                        isActive: scenePhase == .active,
                        isBackground: scenePhase == .background
                    )
                }
                .onOpenURL { url in
                    session.openWidgetURL(url)
                }
        }
    }
}
