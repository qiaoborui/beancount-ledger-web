import Foundation
#if os(iOS)
import UIKit
import Network
@preconcurrency import BackgroundTasks
#endif

/// OS scheduling only. The session owns authorization, synchronization and snapshots.
@MainActor
final class LocalLedgerBackgroundSyncService {
    static let shared = LocalLedgerBackgroundSyncService()
    nonisolated static let taskIdentifier = "com.qiaoborui.ledger.mobile.local-sync"
    private var operation: (@MainActor @Sendable () async -> Bool)?
    private var schedulingEnabled = false
    private var schedulingGeneration = UUID()
    #if os(iOS)
    private var monitor: NWPathMonitor?
    private var registered = false
    #endif

    func configure(operation: @escaping @MainActor @Sendable () async -> Bool) {
        self.operation = operation
    }

    func startMonitoring(networkChanged: @escaping @MainActor @Sendable (Bool) -> Void) {
        #if os(iOS)
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let reachable = path.status == .satisfied
            Task { @MainActor in networkChanged(reachable) }
        }
        monitor.start(queue: DispatchQueue(label: "ledger.local-sync.network"))
        self.monitor = monitor
        #endif
    }

    func register() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            Task { @MainActor in Self.shared.execute(task) }
        }
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        if schedulingEnabled != enabled { schedulingGeneration = UUID() }
        schedulingEnabled = enabled
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if enabled { schedule() }
        else { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier) }
        #endif
    }

    func schedule() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard schedulingEnabled, registered else { return }
        let generation = schedulingGeneration
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let alreadyScheduled = requests.contains { $0.identifier == Self.taskIdentifier }
            Task { @MainActor in
                guard self.schedulingEnabled, self.schedulingGeneration == generation, !alreadyScheduled else { return }
                let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
                request.requiresNetworkConnectivity = true
                request.requiresExternalPower = false
                // This is an earliest opportunity, never a promised refresh interval.
                request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                try? BGTaskScheduler.shared.submit(request)
            }
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func execute(_ task: BGTask) {
        // On a cold background launch, authorization is checked from persisted
        // configuration by operation, independently of the foreground UI phase.
        guard let operation else { task.setTaskCompleted(success: false); return }
        let work = Task { @MainActor in await operation() }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            let success = await work.value
            task.expirationHandler = nil
            task.setTaskCompleted(success: success && !work.isCancelled)
            schedule()
        }
    }
    #endif
}

#if os(iOS)
final class LedgerBackgroundAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocalLedgerBackgroundSyncService.shared.register()
        return true
    }
}
#endif
