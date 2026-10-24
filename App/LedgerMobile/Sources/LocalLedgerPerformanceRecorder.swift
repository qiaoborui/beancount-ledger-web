import CryptoKit
import Foundation

/// Opt-in accumulation of the signposts `LocalLedgerPerformance` already emits,
/// so real-device acceptance numbers can be exported instead of watched in
/// Instruments.
///
/// Recording is off unless it is explicitly turned on (the app reads the launch
/// argument `--ledger-perf-record` at startup). While it is off every entry
/// point returns after one lock/unlock: no sampling, no allocation and no file.
/// The signpost output itself is identical either way.
///
/// The JSON follows `docs/ios-large-ledger-measurement-protocol.md` §7.2:
/// a top-level `workload` identity (`tier`, `sourceTreeSha256`, `entrypoint`,
/// `canonicalEntries`, `streamBytes`), a `runs` list whose items carry `role`
/// (cold / warmup / measured), `round`, `device` and `build`, and per-segment
/// count/min/median/p95/max that every aggregate can be traced back to through
/// the per-run raw milliseconds.
///
/// The report holds aggregate timings, counts and memory numbers only. Segment
/// names come from `LocalLedgerPerformance.Segment`, the workload tier from a
/// fixed label list, and every other string is a hash, a version or a device
/// identifier, so no field can carry ledger source text, payees, account names
/// or amounts. It is written to an app-owned Documents/support directory, never
/// into a ledger workspace (`generations/`, `staging/`, `current.json`).
final class LocalLedgerPerformanceRecorder: @unchecked Sendable {
    /// Report schema version; bump it when a field changes meaning.
    static let reportVersion = 1
    static let schemaName = "ledger-perf-report"
    /// Fingerprints below this size are remembered; the recorder only ever sees
    /// the three root files plus month files, and the cap bounds memory.
    static let sourceFileCap = 4096

    /// A run is one measured pass (one outermost ledger operation sequence).
    enum Role: String, CaseIterable, Sendable {
        case cold, warmup, measured

        /// The protocol discards two warm-up rounds before the measured ones.
        static let requiredWarmups = 2

        /// Next role in the protocol's round structure: 1 cold, 2 warmup, then
        /// every further run is measured.
        func next(afterWarmups warmups: Int) -> Role {
            switch self {
            case .cold: return .warmup
            case .warmup: return warmups < Role.requiredWarmups ? .warmup : .measured
            case .measured: return .measured
            }
        }
    }

    /// The fixed ledger sizes the acceptance gate measures; the only things a
    /// caller may put in the report's workload tier.
    enum WorkloadTier: String, CaseIterable, Sendable {
        case k10, k50, k100, k200

        /// Label as the protocol's manifest spells it (`"10k"`, `"50k"`, ...).
        var label: String { String(rawValue.dropFirst()) + "k" }

        init?(label: String) {
            let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let tier = Self.allCases.first(where: { $0.label == normalized }) else { return nil }
            self = tier
        }
    }

    /// Protocol thermal states. The reading itself comes from outside (the
    /// protocol measures it with `idevicediagnostics`); unknown text is dropped.
    enum Thermal: String, CaseIterable, Sendable {
        case nominal, fair, serious, critical

        init?(reading: String) {
            let normalized = reading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let state = Self(rawValue: normalized) else { return nil }
            self = state
        }
    }

    struct Stat: Sendable, Equatable, Codable {
        let count: Int
        let minMs: Double
        let medianMs: Double
        let p95Ms: Double
        let maxMs: Double
        let meanMs: Double
    }

    /// `sha256:<64 hex>` over relative path, size and file hash, matching
    /// `_source_tree_sha256` in `scripts/large_ledger_bench.py` byte for byte.
    struct SourceTreeFingerprint: Sendable, Equatable {
        let sourceTreeSha256: String
        let sourceFileCount: Int
        let sourceBytes: Int
    }

    /// Ledger identity the engine reports when it registers a model.
    ///
    /// `sourceVersion` is the digest the native core computed over the ledger
    /// sources. `canonicalEntries`, `streamBytes` and `streamSha256` exist only
    /// when an export actually ran in this session (they come from
    /// `EmbeddedBeancountValidator.StreamDescriptor`); a register from the
    /// stream cache never sees the descriptor, so the report then states the
    /// fields as null and names that source instead of reading the cache.
    struct LedgerIdentity: Sendable, Equatable {
        var sourceVersion: String?
        var canonicalEntries: Int?
        var streamBytes: Int?
        var streamSha256: String?

        init(sourceVersion: String? = nil, canonicalEntries: Int? = nil,
             streamBytes: Int? = nil, streamSha256: String? = nil) {
            self.sourceVersion = sourceVersion
            self.canonicalEntries = canonicalEntries
            self.streamBytes = streamBytes
            self.streamSha256 = streamSha256
        }
    }

    /// Where the canonical metrics in the report came from.
    enum CanonicalSource: String, Sendable {
        /// This session's export returned a `StreamDescriptor`.
        case exporterDescriptor = "exporter-descriptor"
        /// No export ran (the model was registered from the stream cache), so
        /// the canonical columns are unknown rather than read from the cache.
        case unavailable = "unavailable-this-session"
    }

    /// Device and process facts captured outside this type so the portable
    /// package stays free of UIKit.
    struct Environment: Sendable, Equatable {
        var appVersion: String?
        var buildNumber: String?
        var iosVersion: String?
        var osBuild: String?
        var deviceModel: String?
        var deviceName: String?

        init(appVersion: String? = nil, buildNumber: String? = nil, iosVersion: String? = nil,
             osBuild: String? = nil, deviceModel: String? = nil, deviceName: String? = nil) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.iosVersion = iosVersion
            self.osBuild = osBuild
            self.deviceModel = deviceModel
            self.deviceName = deviceName
        }

        /// Bundle version/build and OS from the running process, and the machine
        /// identifier from `uname`, which no app-supplied string can influence.
        static func current() -> Environment {
            let info = Bundle.main.infoDictionary
            var uts = utsname()
            var machine: String?
            if uname(&uts) == 0 {
                machine = withUnsafeBytes(of: &uts.machine) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Environment(
                appVersion: info?["CFBundleShortVersionString"] as? String,
                buildNumber: info?["CFBundleVersion"] as? String,
                iosVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                osBuild: osBuild(),
                deviceModel: machine
            )
        }

        /// `kern.osversion` is `23A344`-style: the OS *build*, which the protocol
        /// requires in addition to the version number.
        private static func osBuild() -> String? {
            #if canImport(Darwin)
            var size = 0
            guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0, size <= 256 else {
                return nil
            }
            var buffer = [CChar](repeating: 0, count: size)
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctlbyname("kern.osversion", raw.baseAddress, &size, nil, 0)
            }
            guard status == 0 else { return nil }
            return buffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return nil }
                return String(validatingUTF8: base)
            }
            #else
            return nil
            #endif
        }
    }

    /// The encoded report; `data` is what gets written or shared.
    struct Report: Sendable, Equatable {
        let data: Data
        var jsonObject: [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
    }

    static let launchArgument = "--ledger-perf-record"
    static let workloadLaunchArgument = "--ledger-perf-workload="
    static let defaultReportFileName = "ledger-perf-report.json"
    /// The app-owned subdirectory a report is written to.
    static let reportDirectoryName = "PerfRecords"

    /// Default location for reports in the running app: `Application Support/PerfRecords`.
    /// Application Support is the app's own private directory and is *not* a
    /// ledger root (`Application Support/Ledgers/<id>/`), so a report never joins
    /// a ledger tree, its `TreeLimits` budget or its canonical validation.
    static func appReportDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent(reportDirectoryName, isDirectory: true)
    }

    enum RecorderError: Error, Equatable {
        case notRecording
        case unwritableDirectory
        case invalidFileName
        case sourceUnreadable
    }

    /// The closed set of segment names a sample may be recorded under; mirrors
    /// `LocalLedgerPerformance.Segment.key`.
    static let segmentKeys: Set<String> = [
        "canonical-validate", "python-load", "python-export", "python-parse", "python-booking",
        "python-plugins", "python-validate", "go-register", "go-model-register", "go-page",
    ]

    /// In-process singleton; `LocalLedgerPerformance` forwards to it.
    static let shared = LocalLedgerPerformanceRecorder()

    private struct IncrementingRun {
        var role: Role
        var round: Int
        var startedAt: Date
        var intervals: [String: [Double]] = [:]
        /// Memory sampled while this run had an interval open.
        var peakFootprint: UInt64?
        var minimumAvailable: UInt64?
        var peakAtEnd: UInt64?
    }

    private struct FinishedRun {
        let role: Role
        let round: Int
        let startedAt: Date
        let endedAt: Date
        let intervals: [String: [Double]]
        let peakFootprint: UInt64?
        let minimumAvailable: UInt64?
        let peakAtEnd: UInt64?
    }

    private struct WorkloadIdentity {
        var tier: WorkloadTier?
        /// Ledger container (`.../Ledgers/<id>`); reports must never be written
        /// under it.
        var ledgerRoot: URL?
        /// The committed generation's `.bean` tree the digest covers.
        var sourceTree: URL?
        var fingerprint: SourceTreeFingerprint?
        var entrypoint: String?
        /// 64 lowercase hex characters, quoted as `"sha256:<hex>"`.
        var sourceVersion: String?
        var canonicalEntries: Int?
        var streamBytes: Int?
        var streamSha256: String?
        var canonicalSource: CanonicalSource = .unavailable
    }

    /// Called off the main thread when a run finishes, so the app can write the
    /// aggregate to disk without polling. Never called while recording is off.
    var onRunFinished: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var recording = false
    private var environment = Environment()
    private var buildCommit: String?
    private var thermal: Thermal?
    // Interval counting is tracked even while recording is off: the engine's
    // sampler calls it on every tick and must never be the thing that turns
    // recording on.
    private var openIntervals = 0
    // Everything below only changes while `recording` is true.
    private var currentRun: IncrementingRun?
    private var finishedRuns: [FinishedRun] = []
    private var runPeakFootprint: UInt64?
    private var runMinimumAvailable: UInt64?
    private var runPeakAtEnd: UInt64?
    private var sessionMinimumAvailable: UInt64?
    private var droppedRuns = 0
    private var workload = WorkloadIdentity()

    // MARK: - Enablement

    /// Fixed-instrumentation hook: the app reads the launch arguments once at
    /// startup. Recording stays off for every launch that does not ask for it.
    @discardableResult
    func configure(launchArguments: [String]) -> Bool {
        guard launchArguments.contains(Self.launchArgument) else { return false }
        startRecording()
        // Recording has to be on before the tier can be accepted.
        if let argument = launchArguments.first(where: { $0.hasPrefix(Self.workloadLaunchArgument) }) {
            setSyntheticWorkloadTier(String(argument.dropFirst(Self.workloadLaunchArgument.count)))
        }
        return true
    }

    func startRecording() {
        lock.lock()
        defer { lock.unlock() }
        guard !recording else { return }
        recording = true
        environment = .current()
        openIntervals = 0
        currentRun = nil
        finishedRuns = []
        runPeakFootprint = nil
        runMinimumAvailable = nil
        runPeakAtEnd = nil
        sessionMinimumAvailable = nil
        droppedRuns = 0
        workload = WorkloadIdentity()
    }

    func stopRecording() {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        currentRun = nil
        finishedRuns = []
        openIntervals = 0
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    /// Number of completed runs; the app uses it to notice that new data
    /// arrived and to offer the export.
    var completedRunCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finishedRuns.count
    }

    var completedFileCount: Int { 0 }

    /// Release builds record the packaged commit (stamped into Info.plist by
    /// `scripts/stamp-ios-build-commit.sh`); the report states it when present.
    func setBuildCommit(_ commit: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        guard let commit else { return }
        let hex = commit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        buildCommit = hex.count == 40 && hex.allSatisfy({ "0123456789abcdef".contains($0) }) ? hex : nil
    }

    func setThermal(_ reading: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        thermal = reading.flatMap { Thermal(reading: $0) }
    }

    func setSyntheticWorkloadTier(_ label: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        // Anything that is not an exact tier label is dropped, never copied.
        workload.tier = label.flatMap { WorkloadTier(label: $0) }
    }

    /// The app calls this when it opens a local ledger. `rootDirectory` is the
    /// ledger's own directory; `attachSourceTree` adds the committed generation
    /// whose files the digest covers.
    func attachLedger(rootDirectory: URL, entrypoint: String) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        workload.ledgerRoot = rootDirectory.standardizedFileURL
        workload.sourceTree = nil
        workload.entrypoint = entrypoint
        workload.fingerprint = nil
        workload.canonicalEntries = nil
        workload.streamBytes = nil
        workload.streamSha256 = nil
        workload.canonicalSource = .unavailable
        workload.sourceVersion = nil
    }

    /// Points the digest at the committed generation's source tree. Hashing runs
    /// on the next report, never here.
    func attachSourceTree(_ workspace: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        workload.sourceTree = workspace.standardizedFileURL
        workload.fingerprint = nil
    }

    /// Refuses a directory that is (or is inside) the measured ledger, so a
    /// report can never land in `generations/`, `staging/` or next to
    /// `current.json` and be counted as a source file.
    func isInsideMeasuredLedger(_ directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let ledger = workload.ledgerRoot else { return false }
        let target = directory.standardizedFileURL.path
        let affected = ledger.path
        return target == affected || target.hasPrefix(affected + "/")
    }

    /// Called when the engine gets (or already has) a registered model for the
    /// current ledger root. Records the source version the native core computed
    /// and, when the stream cache has an entry, the canonical metrics, so the
    /// report never needs an extra load.
    func recordLedgerIdentity(_ identity: LedgerIdentity) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        if let version = identity.sourceVersion {
            let hex = version.lowercased()
            if hex.count == 64, hex.allSatisfy({ "0123456789abcdef".contains($0) }) {
                workload.sourceVersion = hex
            }
        }
        // A descriptor from this session's export is the only source of the
        // canonical columns; the stream cache is deliberately not consulted.
        if let entries = identity.canonicalEntries, entries >= 0,
           let bytes = identity.streamBytes, bytes > 0,
           let sha256 = identity.streamSha256, sha256.count == 64 {
            workload.canonicalEntries = entries
            workload.streamBytes = bytes
            workload.streamSha256 = sha256
            workload.canonicalSource = .exporterDescriptor
        }
    }

    /// Links a run to the ledger identity captured when the app opened it, which
    /// is what the protocol's `workload.sourceTreeSha256` gate compares.
    /// The app calls this when it opens a ledger, so the report can name the
    /// entrypoint even before the first registration.
    func setEntrypoint(_ entrypoint: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, let entrypoint else { return }
        workload.entrypoint = entrypoint
    }

    // MARK: - Run structure

    /// Opens a run. The role names the run that is about to start: the first run
    /// is `cold`, then `warmup`, then `warmup` again, then every further run is
    /// `measured` — the protocol's "1 cold + 2 warmups + N measured" without the
    /// caller tracking it. An explicit role (the protocol script knows the
    /// structure) always wins.
    @discardableResult
    func beginRun(role: Role? = nil) -> Role {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return .measured }
        // Close whatever ran so far; the role it had decides the next default.
        // `closeLocked` clears `currentRun`, so remember the role first.
        var previous: Role?
        if let open = currentRun {
            if open.intervals.isEmpty {
                // Nothing measured yet: relabel instead of starting a second run.
                if let role {
                    currentRun = IncrementingRun(role: role, round: open.round,
                                                 startedAt: open.startedAt)
                    return role
                }
                return open.role
            }
            previous = open.role
            closeLocked(open, endedAt: Date())
        }
        let next: Role
        if let role {
            next = role
        } else if let lastRole = previous ?? finishedRuns.last?.role {
            next = lastRole.next(afterWarmups: finishedRuns.filter { $0.role == .warmup }.count)
        } else {
            next = .cold
        }
        let round = (finishedRuns.last?.round ?? 0) + 1
        currentRun = IncrementingRun(role: next, round: round, startedAt: Date())
        return next
    }

    /// Ends the open run; the recorder keeps it for the report even when the
    /// process dies later, because the app persists after every run.
    func endRun() {
        lock.lock()
        defer { lock.unlock() }
        guard recording, let current = currentRun else { return }
        closeLocked(current, endedAt: Date())
    }

    /// Promotes the last run to `measured` (a caller that ran warmups first).
    func markLastRunMeasured() {
        lock.lock()
        defer { lock.unlock() }
        guard recording, let current = currentRun else { return }
        currentRun = IncrementingRun(role: .measured, round: current.round, startedAt: current.startedAt,
                                     intervals: current.intervals, peakFootprint: current.peakFootprint,
                                     minimumAvailable: current.minimumAvailable, peakAtEnd: current.peakAtEnd)
    }

    // MARK: - Sampling (every entry point is a no-op while recording is off)

    func beginInterval() {
        lock.lock()
        defer { lock.unlock() }
        openIntervals += 1
        guard recording else { return }
        if currentRun == nil { _ = beginRunLocked() }
    }

    /// `segment` must be one of the fixed `Segment::key` values; anything else
    /// is dropped rather than stored, so the report's keys stay a closed set.
    func recordInterval(milliseconds: Double, segment: String) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, milliseconds.isFinite, milliseconds >= 0,
              Self.segmentKeys.contains(segment) else { return }
        if currentRun == nil { _ = beginRunLocked() }
        currentRun?.intervals[segment, default: []].append(milliseconds)
    }

    /// The existing 10 Hz sampler; it only runs while an interval is open, the
    /// same window the signpost `memory-peak` event uses. `peakAtEnd` is the
    /// process-wide reading taken by `LocalLedgerPerformance.end`.
    func sampleMemory(footprintBytes: UInt64?, availableBytes: UInt64?) {
        recordMemoryCheckpoint(footprintBytes: footprintBytes, availableBytes: availableBytes,
                               runPeakAtEnd: nil)
    }

    /// `runPeakAtEnd` is the reading attached to an outermost interval ending.
    func recordMemoryCheckpoint(footprintBytes: UInt64?, availableBytes: UInt64?,
                                runPeakAtEnd: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return }
        applyMemoryLocked(footprintBytes: footprintBytes, availableBytes: availableBytes)
        if let runPeakAtEnd { recordRunEndPeakLocked(runPeakAtEnd) }
    }

    /// Ends one outermost interval. The run closes when the last interval closes,
    /// so a nested interval never splits a run.
    func finishInterval(globalFootprintBytes: UInt64?, globalAvailableBytes: UInt64?, runPeakAtEnd: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        openIntervals = max(0, openIntervals - 1)
        guard recording else { return }
        applyMemoryLocked(footprintBytes: globalFootprintBytes, availableBytes: globalAvailableBytes)
        if let runPeakAtEnd {
            let current = currentRun?.peakAtEnd ?? 0
            currentRun?.peakAtEnd = max(current, runPeakAtEnd)
        }
        guard openIntervals == 0, let current = currentRun,
              !current.intervals.isEmpty || current.peakFootprint != nil || current.peakAtEnd != nil else { return }
        closeLocked(current, endedAt: Date())
    }

    /// Count only; the report never carries anything but an integer.
    func recordLedgerTransactionCount(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard recording, count >= 0 else { return }
        // Not part of the protocol contract: a transaction count is a ledger
        // statistic, so it is only kept when a synthetic tier makes it safe.
        guard workload.tier != nil else { return }
        workload.canonicalEntries = count
    }

    // MARK: - Report

    /// JSON report for everything recorded so far, or nil when recording is off
    /// (nothing was captured, so nothing may claim to be a measurement).
    /// `report()` never performs I/O beyond reading the ledger's own files for
    /// the source-tree digest the first time it is needed.
    func report() -> Report? {
        fingerprintIfNeeded()
        return makeReport()
    }

    /// Same as `report()`, but also refreshes the ledger source-tree digest,
    /// which must not run inside the lock.
    private func fingerprintIfNeeded() {
        lock.lock()
        // The committed generation once the app attached it; before that the
        // ledger directory itself (a directly-imported or still-unpublished
        // ledger has no generation yet).
        let root = recording ? (workload.sourceTree ?? workload.ledgerRoot) : nil
        let cached = workload.fingerprint
        lock.unlock()
        guard let root, cached == nil else { return }
        guard let fingerprint = Self.sourceTreeFingerprint(of: root) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard recording, workload.sourceTree == root || workload.sourceTree == nil else { return }
        workload.fingerprint = fingerprint
    }

    private func makeReport() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard recording else { return nil }
        var runs = finishedRuns
        // A run still in flight is reported as a completed one only when it
        // already has data; otherwise the report would claim a run that ran
        // nothing.
        if let current = currentRun, !current.intervals.isEmpty {
            runs.append(FinishedRun(role: current.role, round: current.round, startedAt: current.startedAt,
                                    endedAt: Date(), intervals: current.intervals,
                                    peakFootprint: current.peakFootprint,
                                    minimumAvailable: current.minimumAvailable,
                                    peakAtEnd: current.peakAtEnd))
        }
        var segments: [String: Stat] = [:]
        for (name, seconds) in Self.collect(runs).sorted(by: { $0.key < $1.key }) {
            segments[name] = Self.stat(seconds)
        }
        let object = Self.object(
            environment: environment, buildCommit: buildCommit, thermal: thermal,
            workload: workload, runs: runs, segments: segments, droppedRuns: droppedRuns,
            peakFootprint: runPeakFootprint ?? runs.compactMap(\.peakAtEnd).max()
                ?? runs.compactMap(\.peakFootprint).max(),
            minimumAvailable: runMinimumAvailable ?? sessionMinimumAvailable)
        // Sorted keys keep files diffable; integers stay integers.
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys, .prettyPrinted]))
            ?? Data("{}".utf8)
        return Report(data: data)
    }

    /// Writes the report below `directory`, which must be an app-owned
    /// Documents/support directory but not a ledger root. The file always lands
    /// one level deeper in `PerfRecords/`, so a caller cannot aim it at a ledger
    /// file, and a name collision replaces the previous run instead of growing.
    @discardableResult
    func persist(_ report: Report, fileName: String? = nil, in directory: URL) throws -> URL {
        guard directory.isFileURL, directory.pathComponents.count > 2 else {
            throw RecorderError.unwritableDirectory
        }
        let name = fileName ?? Self.defaultReportFileName
        guard Self.isSafeFileName(name) else { throw RecorderError.invalidFileName }
        guard !isInsideMeasuredLedger(directory) else { throw RecorderError.unwritableDirectory }
        let folder = directory.standardizedFileURL.appendingPathComponent(Self.reportDirectoryName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        // macOS 27 rejects a data-protection class at write time, so reuse the
        // shared helper that omits it there and keeps it on iOS.
        try report.data.write(to: destination, options: .ledgerProtected)
        return destination
    }

    /// First `perf-<ISO instant>.json` name (sorted order is chronological).
    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "perf-" + formatter.string(from: date) + ".json"
    }

    // MARK: - Source tree digest

    /// The protocol's `sourceTreeSha256`: `sha256:` over `path\0sha256hex\n` for
    /// every source file in sorted path order, exactly as
    /// `scripts/large_ledger_bench.py` computes it so the `record` gate accepts
    /// the number without converting anything.
    static func sourceTreeFingerprint(of root: URL) -> SourceTreeFingerprint? {
        let files: [String]
        do {
            files = try sourceFiles(of: root)
        } catch {
            return nil
        }
        var digest = SHA256()
        var totalBytes = 0
        for relative in files {
            let url = root.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else { return nil }
            totalBytes += data.count
            var fileDigest = SHA256()
            fileDigest.update(data: data)
            digest.update(data: Data(relative.utf8))
            digest.update(data: Data([0]))
            digest.update(data: Data(Self.hex(fileDigest.finalize()).utf8))
            digest.update(data: Data([0x0A]))
        }
        let value = "sha256:" + Self.hex(digest.finalize())
        return SourceTreeFingerprint(sourceTreeSha256: value, sourceFileCount: files.count,
                                     sourceBytes: totalBytes)
    }

    /// Every regular file below `root`, as `"/"`-joined relative paths in byte
    /// order. Symbolic links and non-regular files are reported as an error: the
    /// app would not have committed such a tree, and guessing would produce a
    /// digest that cannot match the manifest.
    static func sourceFiles(of root: URL) throws -> [String] {
        let manager = FileManager.default
        var pending: [String] = [""]
        var found: [String] = []
        while let next = pending.popLast() {
            let directory = next.isEmpty ? root : root.appendingPathComponent(next)
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } catch {
                throw RecorderError.sourceUnreadable
            }
            for child in children {
                let name = child.lastPathComponent
                let relative = next.isEmpty ? name : next + "/" + name
                guard let stat = try? PosixStat.at(child) else { throw RecorderError.sourceUnreadable }
                if stat.isDirectory {
                    pending.append(relative)
                } else if stat.isRegularFile {
                    found.append(relative)
                    guard found.count <= sourceFileCap else { throw RecorderError.sourceUnreadable }
                } else {
                    throw RecorderError.sourceUnreadable
                }
            }
        }
        return found.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    // MARK: - Statistics

    /// Nearest-rank percentile: `ceil(p * n)`-th smallest sample, index clamped.
    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let raw = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(raw, 0), sorted.count - 1)]
    }

    static func stat(_ samples: [Double]) -> Stat {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.isEmpty ? 0 : (sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
        let total = sorted.reduce(0, +)
        return Stat(count: sorted.count, minMs: sorted.first ?? 0, medianMs: median,
                    p95Ms: percentile(sorted, 0.95), maxMs: sorted.last ?? 0,
                    meanMs: sorted.isEmpty ? 0 : total / Double(sorted.count))
    }

    private static func collect(_ runs: [FinishedRun]) -> [String: [Double]] {
        var collected: [String: [Double]] = [:]
        for run in runs {
            for (name, samples) in run.intervals {
                collected[name, default: []].append(contentsOf: samples)
            }
        }
        return collected
    }

    // MARK: - Internals

    private func applyMemoryLocked(footprintBytes: UInt64?, availableBytes: UInt64?) {
        if let footprintBytes {
            runPeakFootprint = max(runPeakFootprint ?? 0, footprintBytes)
            let current = currentRun?.peakFootprint ?? 0
            currentRun?.peakFootprint = max(current, footprintBytes)
        }
        if let availableBytes {
            runMinimumAvailable = min(runMinimumAvailable ?? .max, availableBytes)
            sessionMinimumAvailable = min(sessionMinimumAvailable ?? .max, availableBytes)
            let current = currentRun?.minimumAvailable ?? .max
            currentRun?.minimumAvailable = min(current, availableBytes)
        }
    }

    private func recordRunEndPeakLocked(_ footprint: UInt64) {
        runPeakFootprint = max(runPeakFootprint ?? 0, footprint)
        let current = currentRun?.peakAtEnd ?? 0
        currentRun?.peakAtEnd = max(current, footprint)
    }

    private func beginRunLocked() -> Role {
        if let current = currentRun {
            if current.intervals.isEmpty { return current.role }
            closeLocked(current, endedAt: Date())
        }
        let warmups = finishedRuns.filter { $0.role == .warmup }.count
        let next = finishedRuns.last?.role.next(afterWarmups: warmups) ?? .cold
        currentRun = IncrementingRun(role: next, round: (finishedRuns.last?.round ?? 0) + 1, startedAt: Date())
        return next
    }

    private func closeLocked(_ run: IncrementingRun, endedAt: Date) {
        finishedRuns.append(FinishedRun(role: run.role, round: run.round, startedAt: run.startedAt,
                                        endedAt: endedAt, intervals: run.intervals,
                                        peakFootprint: run.peakFootprint,
                                        minimumAvailable: run.minimumAvailable, peakAtEnd: run.peakAtEnd))
        currentRun = nil
        if recording { onRunFinished?() }
    }

    // MARK: - JSON

    private static func object(environment: Environment, buildCommit: String?, thermal: Thermal?,
                               workload: WorkloadIdentity, runs: [FinishedRun],
                               segments: [String: Stat], droppedRuns: Int,
                               peakFootprint: UInt64?, minimumAvailable: UInt64?) -> [String: Any] {
        var root: [String: Any] = [
            "schema": schemaName,
            "reportVersion": reportVersion,
            "session": [
                "startedAt": timestamp(runs.first?.startedAt),
                "endedAt": timestamp(runs.last?.endedAt),
                "runCount": runs.count,
                "droppedRuns": droppedRuns,
                "thermal": thermal?.rawValue ?? null,
            ],
            "device": device(environment),
            "build": build(environment, commit: buildCommit),
            "workload": workloadObject(workload),
            "runs": runs.map(runObject),
            "segments": segments.mapValues(statObject),
            "memory": memory(peakFootprint: peakFootprint, minimumAvailable: minimumAvailable),
        ]
        root["schema"] = schemaName
        return root
    }

    private static func device(_ environment: Environment) -> [String: Any] {
        strings([
            "model": environment.deviceModel,
            "name": environment.deviceName,
            "osVersion": environment.iosVersion,
            "osBuild": environment.osBuild,
        ])
    }

    private static func build(_ environment: Environment, commit: String?) -> [String: Any] {
        // `ipaSha256` cannot be known inside the app: it is recorded by
        // `build-info.txt` on the Mac and joined by the protocol's `record` step.
        strings([
            "appVersion": environment.appVersion,
            "buildNumber": environment.buildNumber,
            "commit": commit,
            "ipaSha256": nil,
        ])
    }

    private static func workloadObject(_ workload: WorkloadIdentity) -> [String: Any] {
        var object = strings([
            "tier": workload.tier?.label,
            "sourceTreeSha256": workload.fingerprint?.sourceTreeSha256,
            "entrypoint": workload.entrypoint,
            "sourceVersion": workload.sourceVersion.map { "sha256:" + $0 },
            "streamSha256": workload.streamSha256.map { "sha256:" + $0 },
        ])
        object["canonicalEntries"] = workload.canonicalEntries ?? null
        object["streamBytes"] = workload.streamBytes ?? null
        object["sourceFileCount"] = workload.fingerprint?.sourceFileCount ?? null
        object["sourceBytes"] = workload.fingerprint?.sourceBytes ?? null
        // Names where the canonical columns came from, so a reader can tell
        // "not exported in this session" from "zero".
        object["canonicalSource"] = workload.canonicalSource.rawValue
        return object
    }

    private static func runObject(_ run: FinishedRun) -> [String: Any] {
        // Per-run raw milliseconds per segment: the aggregates above trace back
        // to exactly these numbers, which is what the protocol requires in place
        // of a bare average.
        var samples: [String: [Double]] = [:]
        for (name, values) in run.intervals.sorted(by: { $0.key < $1.key }) {
            samples[name] = values
        }
        return [
            "role": run.role.rawValue,
            "round": run.round,
            "startedAt": timestamp(run.startedAt),
            "endedAt": timestamp(run.endedAt),
            "peakFootprintBytes": run.peakFootprint ?? null,
            "minimumAvailableBytes": run.minimumAvailable ?? null,
            "peakFootprintAtEndBytes": run.peakAtEnd ?? null,
            "samplesMs": samples,
        ]
    }

    private static func statObject(_ stat: Stat) -> [String: Any] {
        [
            "count": stat.count,
            "minMs": stat.minMs,
            "medianMs": stat.medianMs,
            "p95Ms": stat.p95Ms,
            "maxMs": stat.maxMs,
            "meanMs": stat.meanMs,
        ]
    }

    private static func memory(peakFootprint: UInt64?, minimumAvailable: UInt64?) -> [String: Any] {
        [
            "peakFootprintBytes": peakFootprint ?? null,
            "peakFootprintMegabytes": peakFootprint.map(megabytes) ?? null,
            "minimumAvailableBytes": minimumAvailable ?? null,
            "minimumAvailableMegabytes": minimumAvailable.map(megabytes) ?? null,
        ]
    }

    private static func strings(_ fields: [String: String?]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (key, value) in fields { object[key] = value ?? null }
        return object
    }

    /// Only a plain `.json` name: no separators, no traversal, no hidden file.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.hasSuffix(".json") && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    /// Missing values are JSON null rather than an invented zero, so "not
    /// measured" stays distinguishable from "measured as zero".
    private static var null: NSNull { NSNull() }

    /// `2026-10-24T09:19:45.668Z`: UTC always, so two devices compare directly.
    private static func timestamp(_ date: Date?) -> Any {
        guard let date else { return null }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }

    private static func megabytes(_ bytes: UInt64) -> Double {
        (Double(bytes) / (1024 * 1024) * 100).rounded() / 100
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
