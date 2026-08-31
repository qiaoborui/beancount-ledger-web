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
                .onOpenURL { url in
                    session.openWidgetURL(url)
                }
                .onChange(of: scenePhase) { _, nextPhase in
                    session.updateActivity(isActive: nextPhase == .active)
                }
        }
    }
}
