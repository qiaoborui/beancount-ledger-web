import CryptoKit
import Foundation
import XCTest
@testable import LedgerMobile

/// The recorder is process-wide in the app (`LocalLedgerPerformance` forwards to
/// it and the engine's 10 Hz sampler calls into it), so these tests use a private
/// instance except where they check that wiring.
final class LocalLedgerPerformanceRecorderTests: XCTestCase {
    private var recorder: LocalLedgerPerformanceRecorder!
    private var root: URL!

    override func setUpWithError() throws {
        recorder = LocalLedgerPerformanceRecorder()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalLedgerPerformanceRecorderTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        recorder?.stopRecording()
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// One interval per sample; `finishInterval` ends the run with the last
    /// interval, so `record` with two samples is two runs. Use `recordRun` for a
    /// single-sample run.
    private func record(_ segment: String, _ samples: [Double]) {
        for sample in samples {
            recorder.beginInterval()
            recorder.recordInterval(milliseconds: sample, segment: segment)
            recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        }
    }

    /// One interval, closed as its own run.
    private func recordRun(_ segment: String, _ milliseconds: Double) {
        recorder.beginInterval()
        recorder.recordInterval(milliseconds: milliseconds, segment: segment)
        recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(recorder.report()).jsonObject
    }

    private func segments() throws -> [String: Any] {
        try XCTUnwrap(try object()["segments"] as? [String: Any])
    }

    private func workload() throws -> [String: Any] {
        try XCTUnwrap(try object()["workload"] as? [String: Any])
    }

    private func session() throws -> [String: Any] {
        try XCTUnwrap(try object()["session"] as? [String: Any])
    }

    private func makeLedger(_ files: [String: String], name: String = "ledger") throws -> URL {
        let ledger = root.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let url = ledger.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return ledger
    }

    // MARK: - Enablement

    func testRecordingIsOffByDefaultAndTouchesNothing() throws {
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.report(), "a non-recording process must not claim a measurement")
        // Every entry point must tolerate being called with recording off.
        record("go-page", [12])
        recorder.sampleMemory(footprintBytes: 1, availableBytes: 2)
        recorder.recordLedgerTransactionCount(100)
        recorder.setSyntheticWorkloadTier("100k")
        recorder.setThermal("nominal")
        recorder.attachLedger(rootDirectory: root, entrypoint: "main.bean")
        recorder.beginRun()
        recorder.endRun()
        XCTAssertNil(recorder.report())
        XCTAssertEqual(recorder.completedRunCount, 0)
        // Launch arguments are the only switch; anything else stays off.
        XCTAssertFalse(recorder.configure(launchArguments: ["--other-flag", "--ledger-perf-workload=100k"]))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.report())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [],
                       "the default path writes no file")
    }

    func testLaunchArgumentEnablesRecordingAndStoppingDiscards() throws {
        XCTAssertTrue(recorder.configure(launchArguments: ["--ledger-perf-record"]))
        XCTAssertTrue(recorder.isRecording)
        record("go-page", [1])
        XCTAssertEqual((try object()["runs"] as? [Any])?.count, 1)
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.report())
    }

    func testWorkloadTierComesFromTheLaunchArgument() throws {
        // The app passes both arguments in one call; the tier must survive it.
        XCTAssertTrue(recorder.configure(launchArguments: ["--ledger-perf-record", "--ledger-perf-workload=50k"]))
        XCTAssertEqual(try workload()["tier"] as? String, "50k")
    }

    // MARK: - Aggregate math

    func testAggregateStatistics() throws {
        recorder.startRecording()
        record("python-booking", [10, 30, 20, 40])
        record("go-page", [5])
        let booking = try XCTUnwrap(try segments()["python-booking"] as? [String: Any])
        XCTAssertEqual(booking["count"] as? Int, 4)
        XCTAssertEqual(booking["minMs"] as? Double, 10)
        XCTAssertEqual(booking["maxMs"] as? Double, 40)
        XCTAssertEqual(booking["medianMs"] as? Double, 25, "even sample count averages the middle pair")
        XCTAssertEqual(booking["meanMs"] as? Double, 25)
        XCTAssertEqual(Set(try segments().keys), ["python-booking", "go-page"])
    }

    func testPercentilesUseNearestRank() {
        let samples = (1...100).map(Double.init)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile(samples, 0.95), 95)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile(samples, 0.5), 50)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile(samples, 1), 100)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile([7], 0.95), 7)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile([], 0.95), 0)
        XCTAssertEqual(LocalLedgerPerformanceRecorder.percentile([3, 1, 2, 4, 5], 0.95), 5)
        let stats = LocalLedgerPerformanceRecorder.stat([1, 2, 3])
        XCTAssertEqual(stats.count, 3)
        XCTAssertEqual(stats.minMs, 1)
        XCTAssertEqual(stats.medianMs, 2)
        XCTAssertEqual(stats.p95Ms, 3)
        XCTAssertEqual(stats.maxMs, 3)
        XCTAssertEqual(stats.meanMs, 2)
    }

    func testOddCountMedianAndInvalidSamples() throws {
        recorder.startRecording()
        record("python-parse", [41, 3, 22])
        // Non-finite and negative samples are dropped.
        for bad in [Double.nan, -1, .infinity] {
            recorder.beginInterval()
            recorder.recordInterval(milliseconds: bad, segment: "python-parse")
            recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        }
        let parse = try XCTUnwrap(try segments()["python-parse"] as? [String: Any])
        XCTAssertEqual(parse["count"] as? Int, 3)
        XCTAssertEqual(parse["medianMs"] as? Double, 22)
        XCTAssertEqual(parse["minMs"] as? Double, 3)
        XCTAssertEqual(parse["maxMs"] as? Double, 41)
    }

    func testUnknownSegmentNamesAreDropped() throws {
        recorder.startRecording()
        record("Payee Coffee Shop", [5])
        record("Expenses:Food", [5])
        record("go-page", [5])
        XCTAssertEqual(Set(try segments().keys), ["go-page"])
    }

    // MARK: - Run structure

    func testRunsFollowColdWarmupMeasuredCycle() throws {
        recorder.startRecording()
        XCTAssertEqual(recorder.beginRun(), .cold)
        recordRun("go-register", 100)
        XCTAssertEqual(recorder.completedRunCount, 1)
        // A role names the run that is about to start, so it is read before the
        // run's own samples arrive.
        XCTAssertEqual(recorder.beginRun(), .warmup)
        recordRun("go-register", 50)
        XCTAssertEqual(recorder.beginRun(), .warmup)
        recordRun("go-register", 45)
        XCTAssertEqual(recorder.beginRun(), .measured)
        recordRun("go-register", 40)
        recordRun("go-register", 41)
        let runs = try XCTUnwrap(try object()["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.compactMap { $0["role"] as? String },
                       ["cold", "warmup", "warmup", "measured", "measured"])
        XCTAssertEqual(runs.compactMap { $0["round"] as? Int }, [1, 2, 3, 4, 5])
        // Aggregates span every run and trace back to the per-run samples.
        let register = try XCTUnwrap(try segments()["go-register"] as? [String: Any])
        XCTAssertEqual(register["count"] as? Int, 5)
        let traced = runs.flatMap { ($0["samplesMs"] as? [String: [Double]])?["go-register"] ?? [] }
        XCTAssertEqual(traced.sorted(), [40, 41, 45, 50, 100])
        XCTAssertNotNil(ISO8601DateFormatter.timestamp(from: try XCTUnwrap(runs[0]["startedAt"] as? String)))
    }

    func testNestedIntervalsStayInOneRun() throws {
        recorder.startRecording()
        recorder.beginInterval()                 // python-load
        recorder.beginInterval()                 // go-register (nested)
        recorder.recordInterval(milliseconds: 7, segment: "go-register")
        recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        XCTAssertEqual(recorder.completedRunCount, 0, "the outer interval is still open")
        recorder.recordInterval(milliseconds: 9, segment: "python-load")
        recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        XCTAssertEqual(recorder.completedRunCount, 1)
        let runs = try XCTUnwrap(try object()["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual((runs[0]["samplesMs"] as? [String: [Double]])?.count, 2)
    }

    func testExplicitRoleOverrideAndEndRun() throws {
        recorder.startRecording()
        XCTAssertEqual(recorder.beginRun(role: .measured), .measured)
        record("go-page", [3])
        recorder.beginRun(role: .measured)
        XCTAssertEqual(recorder.completedRunCount, 1)
        recorder.endRun()
        XCTAssertEqual(recorder.completedRunCount, 2)
        let roles = try XCTUnwrap(try object()["runs"] as? [[String: Any]]).compactMap { $0["role"] as? String }
        XCTAssertEqual(roles, ["measured", "measured"])
    }

    // MARK: - Memory

    func testMemoryTracksPeakFootprintAndAvailableMinimum() throws {
        recorder.startRecording()
        recorder.beginInterval()
        recorder.sampleMemory(footprintBytes: 100, availableBytes: 900)
        recorder.sampleMemory(footprintBytes: 400, availableBytes: 500)
        recorder.recordInterval(milliseconds: 1, segment: "canonical-validate")
        // The outermost interval ends with the process-wide reading attached.
        recorder.finishInterval(globalFootprintBytes: 700, globalAvailableBytes: 300, runPeakAtEnd: 650)
        recorder.sampleMemory(footprintBytes: 250, availableBytes: 800)
        var memory = try XCTUnwrap(try object()["memory"] as? [String: Any])
        XCTAssertEqual(memory["peakFootprintBytes"] as? UInt64, 700)
        XCTAssertEqual(memory["minimumAvailableBytes"] as? UInt64, 300)
        XCTAssertEqual(try XCTUnwrap(memory["peakFootprintMegabytes"] as? Double),
                       (Double(700) / (1024 * 1024) * 100).rounded() / 100)
        var runs = try XCTUnwrap(try object()["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0]["peakFootprintBytes"] as? UInt64, 700)
        XCTAssertEqual(runs[0]["peakFootprintAtEndBytes"] as? UInt64, 650)
        // A second run aggregates into the same session peak, never resets it.
        recorder.beginInterval()
        recorder.sampleMemory(footprintBytes: 1200, availableBytes: 2000)
        recorder.recordInterval(milliseconds: 2, segment: "go-page")
        recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        memory = try XCTUnwrap(try object()["memory"] as? [String: Any])
        XCTAssertEqual(memory["peakFootprintBytes"] as? UInt64, 1200)
        runs = try XCTUnwrap(try object()["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1]["peakFootprintBytes"] as? UInt64, 1200)
    }

    // MARK: - Report shape (protocol 7.2)

    func testReportShape() throws {
        let ledger = try makeLedger([
            "main.bean": "; synthetic\ninclude \"accounts.bean\"\n",
            "accounts.bean": "2026-01-01 open Assets:Bank CNY\n",
            "transactions/2026-01.bean": "",
        ])
        recorder.startRecording()
        recorder.attachLedger(rootDirectory: ledger, entrypoint: "main.bean")
        recorder.setSyntheticWorkloadTier("100k")
        recorder.recordLedgerIdentity(.init(sourceVersion: String(repeating: "ab", count: 32),
                                            canonicalEntries: 11842, streamBytes: 5_591_901,
                                            streamSha256: String(repeating: "ef", count: 32)))
        recorder.setThermal("nominal")
        recorder.setBuildCommit(String(repeating: "cd", count: 20))
        record("go-page", [4.5])
        let report = try XCTUnwrap(recorder.report())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["schema", "reportVersion", "session", "device", "build",
                                          "workload", "runs", "segments", "memory"])
        XCTAssertEqual(object["schema"] as? String, LocalLedgerPerformanceRecorder.schemaName)
        XCTAssertEqual(object["reportVersion"] as? Int, LocalLedgerPerformanceRecorder.reportVersion)

        let session = try self.session()
        XCTAssertEqual(Set(session.keys), ["startedAt", "endedAt", "runCount", "droppedRuns", "thermal"])
        XCTAssertEqual(session["runCount"] as? Int, 1)
        XCTAssertEqual(session["thermal"] as? String, "nominal")
        XCTAssertNotNil(ISO8601DateFormatter.timestamp(from: try XCTUnwrap(session["startedAt"] as? String)))
        XCTAssertNotNil(ISO8601DateFormatter.timestamp(from: try XCTUnwrap(session["endedAt"] as? String)))

        // The protocol's required workload identity, including the tree digest.
        let workload = try self.workload()
        for key in ["tier", "sourceTreeSha256", "entrypoint", "canonicalEntries", "streamBytes"] {
            XCTAssertFalse(workload[key] is NSNull, "workload.\(key) must be present")
        }
        XCTAssertEqual(workload["tier"] as? String, "100k")
        XCTAssertEqual(workload["entrypoint"] as? String, "main.bean")
        XCTAssertEqual(workload["canonicalEntries"] as? Int, 11842)
        XCTAssertEqual(workload["streamBytes"] as? Int, 5_591_901)
        XCTAssertEqual(workload["sourceFileCount"] as? Int, 3)
        XCTAssertEqual(workload["sourceVersion"] as? String, "sha256:" + String(repeating: "ab", count: 32))
        XCTAssertEqual(workload["streamSha256"] as? String, "sha256:" + String(repeating: "ef", count: 32))
        XCTAssertEqual(workload["canonicalSource"] as? String, "exporter-descriptor",
                       "the export descriptor is the recorded source of the canonical columns")
        XCTAssertEqual(try XCTUnwrap(workload["sourceTreeSha256"] as? String).count, "sha256:".count + 64)

        let runs = try XCTUnwrap(object["runs"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(Set(runs[0].keys), ["role", "round", "startedAt", "endedAt", "peakFootprintBytes",
                                           "minimumAvailableBytes", "peakFootprintAtEndBytes", "samplesMs"])
        XCTAssertEqual(runs[0]["role"] as? String, "cold")

        let build = try XCTUnwrap(object["build"] as? [String: Any])
        XCTAssertEqual(Set(build.keys), ["appVersion", "buildNumber", "commit", "ipaSha256"])
        XCTAssertEqual(build["commit"] as? String, String(repeating: "cd", count: 20))
        XCTAssertTrue(build["ipaSha256"] is NSNull, "the IPA digest is recorded outside the app")
        let device = try XCTUnwrap(object["device"] as? [String: Any])
        XCTAssertEqual(Set(device.keys), ["model", "name", "osVersion", "osBuild"])

        // Per-segment statistics always carry a spread, never only a mean.
        let page = try XCTUnwrap(try segments()["go-page"] as? [String: Any])
        XCTAssertEqual(Set(page.keys), ["count", "minMs", "medianMs", "p95Ms", "maxMs", "meanMs"])

        XCTAssertGreaterThan(report.data.count, 0)
        XCTAssertLessThan(report.data.count, 8 * 1024, "the report stays small enough to share")
    }

    /// The digest is the protocol's gate against measuring the wrong ledger, so
    /// it must follow `_source_tree_sha256` in `scripts/large_ledger_bench.py`:
    /// `sha256:` over `path\0sha256(file)\n` in sorted path order.
    func testSourceTreeDigestMatchesProtocolAlgorithm() throws {
        let files = ["main.bean": "; synthetic\n", "accounts.bean": "2026-01-01 open Assets:Bank CNY\n"]
        let ledger = try makeLedger(files)
        let fingerprint = try XCTUnwrap(LocalLedgerPerformanceRecorder.sourceTreeFingerprint(of: ledger))
        var expected = ""
        for path in files.keys.sorted() {
            expected += path + "\u{0}" + sha256Hex(Data(files[path]!.utf8)) + "\n"
        }
        XCTAssertEqual(fingerprint.sourceTreeSha256, "sha256:" + sha256Hex(Data(expected.utf8)))
        XCTAssertEqual(fingerprint.sourceFileCount, 2)
        XCTAssertEqual(fingerprint.sourceBytes, files.values.map { Data($0.utf8).count }.reduce(0, +))
        // Re-reading an identical tree gives the same digest; one changed byte
        // changes it.
        XCTAssertEqual(LocalLedgerPerformanceRecorder.sourceTreeFingerprint(of: ledger), fingerprint)
        try Data("; changed\n".utf8).write(to: ledger.appendingPathComponent("accounts.bean"))
        XCTAssertNotEqual(LocalLedgerPerformanceRecorder.sourceTreeFingerprint(of: ledger), fingerprint)
    }

    func testSourceFilesRejectsLinksAndSortsByBytes() throws {
        let ledger = try makeLedger(["b.bean": "", "a.bean": "", "z/z.bean": ""])
        XCTAssertEqual(try LocalLedgerPerformanceRecorder.sourceFiles(of: ledger),
                       ["a.bean", "b.bean", "z/z.bean"])
        try FileManager.default.createSymbolicLink(at: ledger.appendingPathComponent("link.bean"),
                                                   withDestinationURL: ledger.appendingPathComponent("a.bean"))
        XCTAssertThrowsError(try LocalLedgerPerformanceRecorder.sourceFiles(of: ledger)) { error in
            XCTAssertEqual(error as? LocalLedgerPerformanceRecorder.RecorderError, .sourceUnreadable)
        }
        XCTAssertNil(LocalLedgerPerformanceRecorder.sourceTreeFingerprint(of: ledger))
    }

    func testWorkloadTierOnlyAcceptsFixedLabels() throws {
        recorder.startRecording()
        for label in ["100k", " 100K ", "50k", "10k", "200k"] {
            recorder.setSyntheticWorkloadTier(label)
            XCTAssertEqual(try workload()["tier"] as? String,
                           label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        for rejected in [nil, "", "1000k", "一百k", "10M", "../secrets", "Assets:Bank", "buy groceries"] {
            recorder.setSyntheticWorkloadTier(rejected)
            assertIsNull(try workload()["tier"])
        }
    }

    func testThermalOnlyAcceptsProtocolStates() throws {
        recorder.startRecording()
        for state in ["nominal", "Fair", " serious ", "critical"] {
            recorder.setThermal(state)
            XCTAssertEqual(try session()["thermal"] as? String,
                           state.trimmingCharacters(in: .whitespaces).lowercased())
        }
        for rejected in ["hot", "warm", "1", ""] {
            recorder.setThermal(rejected)
            assertIsNull(try session()["thermal"])
        }
    }

    func testAbsentMeasurementsAreNullNotZero() throws {
        recorder.startRecording()
        let object = try object()
        let workload = try XCTUnwrap(object["workload"] as? [String: Any])
        for key in ["tier", "sourceTreeSha256", "entrypoint", "canonicalEntries", "streamBytes"] {
            assertIsNull(workload[key], "workload.\(key)")
        }
        XCTAssertEqual(workload["canonicalSource"] as? String, "unavailable-this-session",
                       "no export ran, and the stream cache is not consulted")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        assertIsNull(session["startedAt"])
        assertIsNull(session["endedAt"])
        assertIsNull(session["thermal"])
        XCTAssertEqual(session["runCount"] as? Int, 0)
        XCTAssertEqual((object["runs"] as? [Any])?.count, 0)
        let memory = try XCTUnwrap(object["memory"] as? [String: Any])
        assertIsNull(memory["peakFootprintBytes"])
        assertIsNull(memory["minimumAvailableBytes"])
        XCTAssertEqual((object["segments"] as? [String: Any])?.count, 0)
    }

    // MARK: - No ledger content

    /// Every string a caller can influence lands in a closed field: segment
    /// names are checked against the fixed set, the tier against fixed labels,
    /// the thermal state against fixed states, and everything else is a digest,
    /// a version number or a `uname` identifier.
    func testReportCannotCarryLedgerContent() throws {
        let secrets = ["Assets:Bank", "Expenses:Food", "星巴克咖啡", "Starbucks", "Coffee Shop", "Payee",
                       "12.34", "2026-09-23 * \"lunch\"", "#tag", "noodle-bar"]
        let ledger = try makeLedger(["main.bean": "; synthetic\n"])
        recorder.startRecording()
        recorder.attachLedger(rootDirectory: ledger, entrypoint: "main.bean")
        recorder.setThermal("nominal")
        // Every free-form string entry point, fed ledger-looking text.
        for (index, secret) in secrets.enumerated() {
            recorder.setSyntheticWorkloadTier(secret)
            recorder.setThermal(secret)
            recorder.beginInterval()
            recorder.recordInterval(milliseconds: Double(index), segment: secret)
            recorder.finishInterval(globalFootprintBytes: nil, globalAvailableBytes: nil, runPeakAtEnd: nil)
        }
        record("go-page", [1000])
        let report = try XCTUnwrap(recorder.report())
        let text = String(decoding: report.data, as: UTF8.self)
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "report leaked \(secret)")
        }
        // Every leaf is a JSON scalar in a known field; walk them all.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.data) as? [String: Any])
        let environment = LocalLedgerPerformanceRecorder.Environment.current()
        let knownStrings = Set(Self.topLevelKeys + Self.sessionKeys + Self.deviceKeys + Self.buildKeys
            + Self.workloadKeys + Self.runKeys + Self.statKeys
            + Array(LocalLedgerPerformanceRecorder.segmentKeys)
            + LocalLedgerPerformanceRecorder.Role.allCases.map(\.rawValue)
            + LocalLedgerPerformanceRecorder.Thermal.allCases.map(\.rawValue)
            + LocalLedgerPerformanceRecorder.WorkloadTier.allCases.map(\.label)
            + [LocalLedgerPerformanceRecorder.CanonicalSource.exporterDescriptor.rawValue,
               LocalLedgerPerformanceRecorder.CanonicalSource.unavailable.rawValue]
            + [LocalLedgerPerformanceRecorder.schemaName, "main.bean"]
            + [environment.appVersion, environment.buildNumber, environment.iosVersion,
               environment.osBuild, environment.deviceModel].compactMap { $0 })
        for leaf in leaves(of: object) {
            XCTAssertFalse(leaf is [Any], "unexpected array leaf")
            guard let string = leaf as? String else { continue }
            XCTAssertTrue(knownStrings.contains(string) || ISO8601DateFormatter.timestamp(from: string) != nil
                          || Self.isDigest(string), "unexpected string leaf \(string)")
        }
        // Timings stay numbers: a stringified count or duration is what a
        // careless refactor introduces.
        let page = try XCTUnwrap(try segments()["go-page"] as? [String: Any])
        for key in Self.statKeys { XCTAssertTrue(page[key] is NSNumber, "\(key) is not numeric") }
        XCTAssertTrue(try workload()["sourceBytes"] is NSNumber)
    }

    func testTransactionCountIsOnlyKeptForSyntheticTiers() throws {
        recorder.startRecording()
        recorder.recordLedgerTransactionCount(1234)
        assertIsNull(try workload()["canonicalEntries"], "a real ledger's size must not be recorded")
        recorder.setSyntheticWorkloadTier("10k")
        recorder.recordLedgerTransactionCount(1234)
        XCTAssertEqual(try workload()["canonicalEntries"] as? Int, 1234)
    }

    // MARK: - Persistence

    /// A report must never land in the measured ledger: `generations/`,
    /// `staging/` and `current.json` live there, and a stray file would join the
    /// workspace tree the app validates.
    func testPersistRefusesDirectoriesInsideTheMeasuredLedger() throws {
        let ledger = try makeLedger(["main.bean": "; synthetic\n"])
        recorder.startRecording()
        recorder.attachLedger(rootDirectory: ledger, entrypoint: "main.bean")
        record("go-page", [1])
        let report = try XCTUnwrap(recorder.report())
        for directory in [ledger,
                          ledger.appendingPathComponent("generations"),
                          ledger.appendingPathComponent("staging/abc/workspace")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            XCTAssertThrowsError(try recorder.persist(report, in: directory)) { error in
                XCTAssertEqual(error as? LocalLedgerPerformanceRecorder.RecorderError, .unwritableDirectory)
            }
        }
        // The ledger's sibling directories are fine, and the only files below the
        // ledger are still its own sources.
        let outside = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        XCTAssertNoThrow(try recorder.persist(report, in: outside))
        XCTAssertEqual(try LocalLedgerPerformanceRecorder.sourceFiles(of: ledger), ["main.bean"])
    }

    func testPersistWritesIntoItsOwnSubdirectory() throws {
        recorder.startRecording()
        record("go-page", [1])
        let report = try XCTUnwrap(recorder.report())
        let url = try recorder.persist(report, in: root)
        XCTAssertEqual(url.lastPathComponent, LocalLedgerPerformanceRecorder.defaultReportFileName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       LocalLedgerPerformanceRecorder.reportDirectoryName)
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: url), report.data)
        try recorder.persist(report, fileName: "run-2.json", in: root)
        let names = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["ledger-perf-report.json", "run-2.json"])
    }

    func testPerRunFileNamesSortChronologically() {
        let first = LocalLedgerPerformanceRecorder.fileName(for: Date(timeIntervalSince1970: 1_700_000_000))
        let second = LocalLedgerPerformanceRecorder.fileName(for: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(first, "perf-20231114T221320Z.json")
        XCTAssertTrue(LocalLedgerPerformanceRecorder.isSafeFileName(first))
        XCTAssertLessThan(first, second)
    }

    func testPersistRejectsPathsThatCouldReachAnotherFile() throws {
        recorder.startRecording()
        record("go-page", [1])
        let report = try XCTUnwrap(recorder.report())
        for name in ["../escape.json", "sub/dir.json", ".hidden.json", "", "report.txt", "pérf.json", "a: b.json"] {
            XCTAssertThrowsError(try recorder.persist(report, fileName: name, in: root)) { error in
                XCTAssertEqual(error as? LocalLedgerPerformanceRecorder.RecorderError, .invalidFileName)
            }
        }
        XCTAssertThrowsError(try recorder.persist(report, in: URL(string: "https://example.com")!)) { error in
            XCTAssertEqual(error as? LocalLedgerPerformanceRecorder.RecorderError, .unwritableDirectory)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [],
                       "a rejected name must not create anything")
    }

    /// The opt-in must not leak across a reinstall: it is a `UserDefaults` flag
    /// under an explicit key, and the recorder's own state is process-local.
    func testOptInKeysAreExplicitAndProcessLocal() {
        XCTAssertEqual(LocalLedgerPerformanceRecorder.launchArgument, "--ledger-perf-record")
        XCTAssertEqual(LocalLedgerPerformanceRecorder.workloadLaunchArgument, "--ledger-perf-workload=")
        XCTAssertEqual(LocalLedgerPerformanceRecorder.reportDirectoryName, "PerfRecords")
        XCTAssertEqual(LocalLedgerPerformanceRecorder.defaultReportFileName, "ledger-perf-report.json")
        // A fresh recorder (what a new process gets) is always off.
        XCTAssertFalse(LocalLedgerPerformanceRecorder().isRecording)
    }

    // MARK: - Wiring into LocalLedgerPerformance

    /// `LocalLedgerPerformance` forwards every interval and the Python timing
    /// events to the shared recorder, which stays off unless configured.
    func testSharedRecorderIgnoresSignpostsUnlessConfigured() throws {
        let shared = LocalLedgerPerformance.recorder
        let wasRecording = shared.isRecording
        shared.stopRecording()
        defer {
            shared.stopRecording()
            if wasRecording { shared.startRecording() }
        }
        XCTAssertFalse(shared.configure(launchArguments: ["--ledger-perf-workload=100k"]))
        XCTAssertFalse(shared.isRecording)
        LocalLedgerPerformance.recordPythonTimings(["parse": 4.2, "booking": 9.6, "plugins": 1.7, "validate": 1.8])
        let ignored = LocalLedgerPerformance.begin(.goPage)
        LocalLedgerPerformance.end(ignored)
        XCTAssertFalse(shared.isRecording)
        XCTAssertNil(shared.report())

        XCTAssertTrue(shared.configure(launchArguments: ["--ledger-perf-record"]))
        LocalLedgerPerformance.recordPythonTimings(["parse": 4.2, "booking": 9.6, "plugins": 1.7, "validate": 1.8])
        let recorded = LocalLedgerPerformance.begin(.goRegister)
        LocalLedgerPerformance.end(recorded)
        let segments = try XCTUnwrap(try XCTUnwrap(shared.report()).jsonObject["segments"] as? [String: Any])
        XCTAssertEqual(Set(segments.keys), ["python-parse", "python-booking", "python-plugins",
                                            "python-validate", "go-register"])
        XCTAssertEqual(shared.completedRunCount, 1)
        shared.stopRecording()
        XCTAssertNil(shared.report())
    }

    // MARK: - Helpers

    private func assertIsNull(_ value: Any?, _ message: String = "expected null",
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value is NSNull, "\(message): got \(String(describing: value))", file: file, line: line)
    }

    /// Every non-container leaf of the decoded JSON.
    private func leaves(of value: Any) -> [Any] {
        if let array = value as? [Any] { return array.flatMap { leaves(of: $0) } }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap { leaves(of: $0) } }
        return [value]
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ string: String) -> Bool {
        string.hasPrefix("sha256:") && string.dropFirst("sha256:".count).count == 64
    }

    private static let topLevelKeys = ["schema", "reportVersion", "session", "device", "build",
                                       "workload", "runs", "segments", "memory"]
    private static let sessionKeys = ["startedAt", "endedAt", "runCount", "droppedRuns", "thermal"]
    private static let deviceKeys = ["model", "name", "osVersion", "osBuild"]
    private static let buildKeys = ["appVersion", "buildNumber", "commit", "ipaSha256"]
    private static let workloadKeys = ["tier", "sourceTreeSha256", "entrypoint", "canonicalEntries",
                                       "streamBytes", "sourceVersion", "sourceFileCount", "sourceBytes"]
    private static let runKeys = ["role", "round", "startedAt", "endedAt", "peakFootprintBytes",
                                  "minimumAvailableBytes", "peakFootprintAtEndBytes", "samplesMs"]
    private static let statKeys = ["count", "minMs", "medianMs", "p95Ms", "maxMs", "meanMs"]
}

private extension ISO8601DateFormatter {
    /// The report emits `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC.
    static func timestamp(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
