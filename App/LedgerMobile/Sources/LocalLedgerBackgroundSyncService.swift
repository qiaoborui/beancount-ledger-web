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
    nonisolated static let processingTaskIdentifier = "com.qiaoborui.ledger.mobile.local-sync"
    nonisolated static let appRefreshTaskIdentifier = "com.qiaoborui.ledger.mobile.refresh"
    nonisolated static var taskIdentifier: String { processingTaskIdentifier }

    private static let lastRunDateKey = "ledger.mobile.background-sync.last-run-date"
    private static let lastRunKindKey = "ledger.mobile.background-sync.last-run-kind"
    private static let lastRunSuccessKey = "ledger.mobile.background-sync.last-run-success"
    private static let runCountKey = "ledger.mobile.background-sync.run-count"

    private var operation: (@MainActor @Sendable () async -> Bool)?
    private var schedulingEnabled = false
    private var schedulingGeneration = UUID()
    #if os(iOS)
    private var monitor: NWPathMonitor?
    private var registered = false
    #endif

    enum BackgroundTaskKind: String, Sendable {
        case appRefresh = "后台刷新"
        case processing = "夜间维护"
        case sceneFlush = "切后台同步"
    }

    struct ExecutionSummary: Equatable, Sendable {
        let date: Date
        let kind: String
        let success: Bool
        let runCount: Int
    }

    var lastExecutionSummary: ExecutionSummary? {
        let defaults = UserDefaults.standard
        let time = defaults.double(forKey: Self.lastRunDateKey)
        guard time > 0 else { return nil }
        let kind = defaults.string(forKey: Self.lastRunKindKey) ?? "后台刷新"
        let success = defaults.bool(forKey: Self.lastRunSuccessKey)
        let count = defaults.integer(forKey: Self.runCountKey)
        return ExecutionSummary(
            date: Date(timeIntervalSince1970: time),
            kind: kind,
            success: success,
            runCount: count
        )
    }

    func recordExecution(kind: BackgroundTaskKind, success: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: Self.lastRunDateKey)
        defaults.set(kind.rawValue, forKey: Self.lastRunKindKey)
        defaults.set(success, forKey: Self.lastRunSuccessKey)
        let count = defaults.integer(forKey: Self.runCountKey) + 1
        defaults.set(count, forKey: Self.runCountKey)
    }

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
        let registeredRefresh = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.appRefreshTaskIdentifier,
            using: .main
        ) { task in
            Task { @MainActor in Self.shared.execute(task, kind: .appRefresh) }
        }
        let registeredProcessing = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: .main
        ) { task in
            Task { @MainActor in Self.shared.execute(task, kind: .processing) }
        }
        registered = registeredRefresh || registeredProcessing
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        if schedulingEnabled != enabled { schedulingGeneration = UUID() }
        schedulingEnabled = enabled
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if enabled {
            schedule()
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.appRefreshTaskIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
        }
        #endif
    }

    func schedule() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard schedulingEnabled, registered else { return }
        let generation = schedulingGeneration
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let refreshPending = requests.contains { $0.identifier == Self.appRefreshTaskIdentifier }
            let processingPending = requests.contains { $0.identifier == Self.processingTaskIdentifier }
            Task { @MainActor in
                guard self.schedulingEnabled, self.schedulingGeneration == generation else { return }

                // 1. Opportunistic daytime BGAppRefreshTask (typical iOS Background App Refresh)
                if !refreshPending {
                    let refreshRequest = BGAppRefreshTaskRequest(identifier: Self.appRefreshTaskIdentifier)
                    // Earliest opportunity: 15 minutes
                    refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
                    do {
                        try BGTaskScheduler.shared.submit(refreshRequest)
                    } catch {
                        #if DEBUG
                        print("[BackgroundSync] Failed to submit app refresh task: \(error)")
                        #endif
                    }
                }

                // 2. Idle / Charging BGProcessingTask (maintenance)
                if !processingPending {
                    let processingRequest = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
                    processingRequest.requiresNetworkConnectivity = true
                    processingRequest.requiresExternalPower = false
                    // Earliest opportunity: 60 minutes
                    processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
                    do {
                        try BGTaskScheduler.shared.submit(processingRequest)
                    } catch {
                        #if DEBUG
                        print("[BackgroundSync] Failed to submit processing task: \(error)")
                        #endif
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func execute(_ task: BGTask, kind: BackgroundTaskKind) {
        // On a cold background launch, authorization is checked from persisted
        // configuration by operation, independently of the foreground UI phase.
        guard let operation else { task.setTaskCompleted(success: false); return }
        let work = Task { @MainActor in await operation() }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            let success = await work.value
            task.expirationHandler = nil
            let finalSuccess = success && !work.isCancelled
            task.setTaskCompleted(success: finalSuccess)
            self.recordExecution(kind: kind, success: finalSuccess)
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
