import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import LedgerMobile

/// Opt-in, simulator-only baseline. Inputs must be disposable copies outside the
/// public repository. Nothing is read from the user's configured app catalog.
/// Outputs contain timings/counts only; never serialize responses or diagnostics.
final class LocalLedgerPerformanceBaselineTests: XCTestCase {
    private enum BaselineFailure: Error { case invariant }
    func testIsolatedBaseline() async throws {
        #if os(iOS) && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard environment["LEDGER_PERF_DISPOSABLE_COPY"] == "1",
              let sourcePath = environment["LEDGER_PERF_INPUT"],
              let outputPath = environment["LEDGER_PERF_OUTPUT"] else {
            throw XCTSkip("Explicit disposable-copy performance fixture not configured")
        }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().standardizedFileURL
        let output = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath().standardizedFileURL
        guard output != source, !output.path.hasPrefix(source.path + "/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            XCTFail("Metrics output must be new and outside fixture input")
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LedgerPerformance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var timings: [String: [Double]] = [:]
        var footprints: [String: UInt64] = [:]
        var stage = "initialization"
        let clock = ContinuousClock()
        func sample<T>(_ name: String, _ operation: () async throws -> T) async throws -> T {
            stage = name
            let start = clock.now
            let result = try await operation()
            let elapsed = start.duration(to: clock.now).components
            timings[name, default: []].append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            footprints[name] = max(footprints[name] ?? 0, Self.physicalFootprint())
            return result
        }
        func save(_ succeeded: Bool) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "schema": 1, "succeeded": succeeded, "last_stage": stage,
                "environment": "iOS Simulator; no UI rendering or authentication",
                "build_configuration": Self.buildConfiguration,
                "timings_ms": timings, "footprint_after_stage_bytes": footprints,
            ], options: [.sortedKeys])
            try data.write(to: output, options: .withoutOverwriting)
        }
        do {
            // First use includes interpreter initialization, preflight, booking,
            // canonical serialization, C bridge, and Swift result extraction.
            let model = try await sample("canonical_first_test_load") {
                try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: source)
            }
            for _ in 0..<10 {
                _ = try await sample("canonical_warm_interpreter_full_load") {
                    try await EmbeddedBeancountValidator.shared.canonicalModel(workspace: source)
                }
            }
            let workspace = LocalLedgerWorkspace(rootDirectory: temporary)
            _ = try await sample("import_copy_validate_publish") {
                try await workspace.importLedger(from: source) { root in
                    try await EmbeddedBeancountValidator.shared.validate(workspace: root)
                }
            }
            let descriptor = LocalLedgerDescriptor(id: UUID(), name: "Performance fixture",
                entrypoint: "main.bean", createdAt: Date())
            let engine = EmbeddedLocalLedgerEngine()
            let repository = LocalLedgerRepository(descriptor: descriptor, workspace: workspace, engine: engine)
            let query = ["start": "2026-09-01", "end": "2026-10-01", "today": "2026-09-21", "valuationCurrency": "CNY"]
            _ = try await sample("repository_bootstrap_first_model") {
                try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-21", valuationCurrency: "CNY")
            }
            for _ in 0..<30 {
                _ = try await sample("repository_bootstrap_presentation_hit") {
                    try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-21", valuationCurrency: "CNY")
                }
            }
            for _ in 0..<30 {
                _ = try await sample("repository_dashboard_hot") {
                    try await repository.dashboard(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
                }
                _ = try await sample("repository_income_statement_hot") {
                    try await repository.incomeStatement(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
                }
                _ = try await sample("repository_investments_hot") { try await repository.investments() }
            }
            for _ in 0..<10 {
                _ = try await sample("repository_all_transactions_hot") { try await repository.globalTransactions() }
                _ = try await sample("repository_bql_aggregate_hot") {
                    try await repository.runBQL(query: "SELECT account, sum(value) AS total FROM postings GROUP BY account", valuationCurrency: "CNY")
                }
            }
            // Remove presentation cache from this comparison: still include
            // pinned snapshot checks, canonical bridge and response extraction.
            for _ in 0..<20 {
                _ = try await sample("engine_bootstrap_hot_no_presentation") {
                    try await workspace.withCurrentSnapshot { _, root in
                        try await engine.dispatch(.init(workspaceRoot: root.path,
                            runtimeRoot: temporary.appendingPathComponent("runtime").path,
                            entrypoint: "main.bean", method: "GET", path: "/api/ledger/bootstrap", query: query))
                    }
                }
            }
            for readers in [1, 4, 8] {
                for _ in 0..<5 {
                    _ = try await sample("dashboard_batch_\(readers)_readers") {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            for _ in 0..<readers {
                                group.addTask {
                                    _ = try await repository.dashboard(start: "2026-09-01", end: "2026-10-01", valuationCurrency: "CNY")
                                }
                            }
                            try await group.waitForAll()
                        }
                    }
                }
            }
            // Add dedicated synthetic accounts only to the disposable workspace.
            // This never uses real account names or modifies the input copy.
            stage = "setup_synthetic_accounts"
            let current = try await workspace.currentRevision()
            let main = try await workspace.withCurrentSnapshot { _, root in
                try Data(contentsOf: root.appendingPathComponent("main.bean"))
            }
            var extended = main
            extended.append(Data("\n1900-01-01 open Assets:PerformanceFixture CNY\n1900-01-01 open Expenses:PerformanceFixture CNY\n".utf8))
            _ = try await workspace.commit(expectedRevisionID: current?.id, changes: [.write(extended, to: "main.bean")]) { root in
                try await EmbeddedBeancountValidator.shared.validate(workspace: root)
            }
            for iteration in 0..<10 {
                let entry = LedgerTransactionEntry(date: "2026-09-21", payee: "Synthetic performance fixture",
                    narration: "Isolated baseline \(iteration)", postings: [
                        .init(account: "Expenses:PerformanceFixture", amount: "1.00", currency: "CNY"),
                        .init(account: "Assets:PerformanceFixture", amount: "-1.00", currency: "CNY"),
                    ])
                let preview = try await sample("single_transaction_preview") {
                    try await repository.prepareBookkeeping(.manual(entry))
                }
                _ = try await sample("single_transaction_confirm_durable") {
                    try await repository.commitPrepared(preview)
                }
                _ = try await sample("repository_bootstrap_after_commit") {
                    try await repository.bootstrap(start: "2026-09-01", end: "2026-10-01", today: "2026-09-21", valuationCurrency: "CNY")
                }
            }
            // Validator must still reject an invalid stage without publication.
            stage = "invalid_stage_rollback"
            let before = try await workspace.currentRevision()
            guard before != nil else { throw BaselineFailure.invariant }
            do {
                _ = try await workspace.commit(expectedRevisionID: before?.id,
                    changes: [.write(Data("not valid beancount\n".utf8), to: "main.bean")]) { root in
                        try await EmbeddedBeancountValidator.shared.validate(workspace: root)
                    }
                throw BaselineFailure.invariant
            } catch is EmbeddedBeancountValidator.ValidationError { }
            let after = try await workspace.currentRevision()
            guard before?.id == after?.id, !model.isEmpty else { throw BaselineFailure.invariant }
            stage = "cleanup"
            try FileManager.default.removeItem(at: temporary)
            stage = "completed"
            try save(true)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: temporary.path) {
                    try FileManager.default.removeItem(at: temporary)
                }
            } catch { XCTFail("Disposable workspace cleanup failed; remove isolated simulator") }
            do { try save(false) } catch { XCTFail("Cannot write new baseline metrics file") }
            // Do not include the error: canonical diagnostics can contain data.
            XCTFail("Isolated baseline failed at stage: \(stage); details suppressed for privacy")
        }
        #else
        throw XCTSkip("Requires the embedded runtime in an iOS simulator app host")
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release (verify build settings separately)"
        #endif
    }

    private static func physicalFootprint() -> UInt64 {
        #if os(iOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
        #else
        return 0
        #endif
    }
}
