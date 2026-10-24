import SwiftUI

/// App-side control of the opt-in local-ledger performance recording.
///
/// The recorder itself lives in `LocalLedgerPerformanceRecorder`: it aggregates
/// the signposts `LocalLedgerPerformance` already emits (per-segment
/// count/min/median/p95/max, `phys_footprint` peak, `os_proc_available_memory`
/// minimum, run roles cold/warmup/measured) into one JSON report per session.
/// This type decides when a session starts and where its report is written.
///
/// Enabling it:
/// - launch argument `--ledger-perf-record` turns recording on for that process;
///   `--ledger-perf-workload=10k|50k|100k|200k` records the synthetic tier the
///   measurement protocol expects in `workload.tier`.
/// - The same arguments are remembered for subsequent launches, so a device
///   installed through a re-signing tool can be switched on from
///   Settings → 本地账本 → 性能录制 → 打开录制. Turning it off restores the normal
///   path exactly: no sampling, no file, unchanged signposts.
///
/// Reports are written after every completed run to
/// `Application Support/PerfRecords/<timestamp>.json`, an app-private directory
/// that is not a ledger root (`Application Support/Ledgers/<id>/` holds
/// `generations/`, `staging/` and `current.json`). The app does not expose
/// Documents through `UIFileSharingEnabled`, so the report is taken off the
/// device with the system share sheet from that settings screen.
@MainActor
final class LocalLedgerPerformanceRecording: ObservableObject {
    static let shared = LocalLedgerPerformanceRecording()

    static let launchArgument = LocalLedgerPerformanceRecorder.launchArgument
    static let workloadPrefix = LocalLedgerPerformanceRecorder.workloadLaunchArgument
    /// Launch arguments can only be passed by whatever installed the app, so the
    /// choice is persisted and re-applied on the next launch.
    static let persistedEnabledKey = "ledger.mobile.perf-record"
    static let persistedWorkloadKey = "ledger.mobile.perf-record-workload"

    /// Reports already written for this session, newest last.
    @Published private(set) var files: [URL] = []
    @Published private(set) var lastError: String?
    @Published var isEnabled: Bool

    private let defaults: UserDefaults
    private let recorder: LocalLedgerPerformanceRecorder
    private var writeTask: Task<Void, Never>?
    private var didInstallWriteHook = false

    init(defaults: UserDefaults = .standard, recorder: LocalLedgerPerformanceRecorder = .shared) {
        self.defaults = defaults
        self.recorder = recorder
        isEnabled = defaults.bool(forKey: Self.persistedEnabledKey)
    }

    /// Called once from the app's startup path, before any ledger work.
    static func configureLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        _ = shared.applyLaunchArguments(arguments)
    }

    /// Mirrors the launch arguments and the stored opt-in into the recorder.
    /// Every later launch re-applies the stored opt-in, because a re-signed
    /// build cannot be given launch arguments from the Home Screen.
    @discardableResult
    func applyLaunchArguments(_ arguments: [String]) -> Bool {
        if let argument = arguments.first(where: { $0.hasPrefix(Self.workloadPrefix) }) {
            let label = String(argument.dropFirst(Self.workloadPrefix.count))
            if let tier = LocalLedgerPerformanceRecorder.WorkloadTier(label: label) {
                defaults.set(tier.label, forKey: Self.persistedWorkloadKey)
            }
        }
        let requested = arguments.contains(Self.launchArgument) ? true : isEnabled
        if requested {
            // Recording persists until it is switched off; the ledger identity
            // arrives per ledger, so a restart simply starts a new session.
            start(workloadLabel: defaults.string(forKey: Self.persistedWorkloadKey))
        }
        return requested
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.persistedEnabledKey)
        isEnabled = enabled
        if enabled {
            start(workloadLabel: defaults.string(forKey: Self.persistedWorkloadKey))
        } else {
            writeTask?.cancel()
            writeTask = nil
            recorder.stopRecording()
        }
    }

    /// Restricts the report to a synthetic tier; pass nil to record none.
    func setWorkloadTier(_ label: String?) {
        if let label, let tier = LocalLedgerPerformanceRecorder.WorkloadTier(label: label) {
            defaults.set(tier.label, forKey: Self.persistedWorkloadKey)
        } else {
            defaults.removeObject(forKey: Self.persistedWorkloadKey)
        }
        recorder.setSyntheticWorkloadTier(label)
    }

    var workloadTierLabel: String? {
        defaults.string(forKey: Self.persistedWorkloadKey)
            .flatMap { LocalLedgerPerformanceRecorder.WorkloadTier(label: $0)?.label }
    }

    /// Records the packaged commit for the report when the build carries one.
    func adoptBuildCommit() {
        // `scripts/stamp-ios-build-commit.sh` writes the packaged commit here.
        guard let commit = Bundle.main.object(forInfoDictionaryKey: "LedgerGitCommit") as? String else { return }
        recorder.setBuildCommit(commit)
    }

    /// Names the ledger a run belongs to. `rootDirectory` is the ledger's own
    /// directory (`…/Ledgers/<id>`), whose `generations/<id>/workspace` holds
    /// the `.bean` files the protocol's source-tree digest covers.
    func attachLedger(rootDirectory: URL, entrypoint: String) {
        guard recorder.isRecording else { return }
        recorder.attachLedger(rootDirectory: rootDirectory, entrypoint: entrypoint)
        recorder.setEntrypoint(entrypoint)
        // Reading the committed generation is I/O; keep it off the UI path. The
        // recorder hashes those files itself, at most once per ledger.
        let store = LocalLedgerWorkspace(rootDirectory: rootDirectory)
        Task.detached(priority: .utility) {
            // The layout is fixed (`generations/<revision>/workspace`); this only
            // finds the published revision, the recorder hashes the files.
            guard let workspace = await Self.committedWorkspace(of: store) else { return }
            LocalLedgerPerformanceRecorder.shared.attachSourceTree(workspace)
        }
    }

    private nonisolated static func committedWorkspace(of store: LocalLedgerWorkspace) async -> URL? {
        guard let revision = try? await store.currentRevision(),
              let workspace = try? await store.publishedWorkspaceRoot(for: revision) else { return nil }
        return workspace
    }

    /// Persists the report after a completed run and refreshes the file list.
    func scheduleWriteAfterRun() {
        guard recorder.isRecording else { return }
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            // Give the finishing interval a moment to record its last fields.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    /// Writes the current aggregate as one new report file.
    @discardableResult
    func writeNow() -> URL? {
        guard let report = recorder.report() else { return nil }
        do {
            let url = try recorder.persist(report, fileName: LocalLedgerPerformanceRecorder.fileName(for: Date()),
                                           in: try LocalLedgerPerformanceRecorder.appReportDirectory())
            refreshFiles()
            lastError = nil
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func refreshFiles() {
        let directory = (try? LocalLedgerPerformanceRecorder.appReportDirectory())?
            .appendingPathComponent(LocalLedgerPerformanceRecorder.reportDirectoryName)
        files = (try? FileManager.default.contentsOfDirectory(at: directory ?? URL(fileURLWithPath: "/"),
                                                              includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
    }

    /// Removes every stored report (the setting screen offers this so a device
    /// does not keep stale measurements).
    func deleteAllReports() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        refreshFiles()
    }

    /// Starts (or restarts, after a failure) a recording session.
    private func start(workloadLabel: String?) {
        if !recorder.isRecording { recorder.startRecording() }
        installWriteHookIfNeeded()
        adoptBuildCommit()
        recorder.setSyntheticWorkloadTier(workloadLabel)
        isEnabled = true
        defaults.set(true, forKey: Self.persistedEnabledKey)
        refreshFiles()
    }

    /// Drives the per-run report write from the recorder's completion hook.
    /// Registered lazily so the recorder keeps no back reference to the UI.
    private func installWriteHookIfNeeded() {
        guard !didInstallWriteHook else { return }
        didInstallWriteHook = true
        recorder.onRunFinished = { [weak self] in
            Task { @MainActor in self?.writeAfterRun() }
        }
    }

    private func writeAfterRun() {
        guard recorder.isRecording else { return }
        writeNow()
    }
}
