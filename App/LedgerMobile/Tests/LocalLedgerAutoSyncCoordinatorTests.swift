import Foundation
import XCTest
@testable import LedgerMobile

@MainActor
final class LocalLedgerAutoSyncCoordinatorTests: XCTestCase {
    @MainActor private final class Sleeper {
        struct Wait {
            let duration: Duration
            let continuation: CheckedContinuation<Void, Error>
        }
        var waits: [UUID: Wait] = [:]

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waits[id] = Wait(duration: duration, continuation: continuation) }
                }
            } onCancel: {
                Task { @MainActor in
                    self.waits.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                }
            }
        }

        func fire(_ duration: Duration) {
            let matching = waits.filter { $0.value.duration == duration }
            for (id, _) in matching {
                waits.removeValue(forKey: id)?.continuation.resume()
            }
        }

        var durations: [Duration] { waits.values.map(\.duration) }
    }

    /// Controlled operations deliberately ignore cancellation until completion.
    @MainActor private final class Operations {
        var calls = 0
        var active = 0
        var maximumActive = 0
        var continuation: CheckedContinuation<LocalLedgerAutoSyncCoordinator.Outcome, Never>?

        func run() async -> LocalLedgerAutoSyncCoordinator.Outcome {
            calls += 1
            active += 1
            maximumActive = max(maximumActive, active)
            let outcome = await withCheckedContinuation { continuation = $0 }
            active -= 1
            return outcome
        }

        func finish(_ outcome: LocalLedgerAutoSyncCoordinator.Outcome = .success) {
            let current = continuation
            continuation = nil
            current?.resume(returning: outcome)
        }
    }

    private func eventually(
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }

    private func make(_ sleeper: Sleeper, _ operations: Operations) -> LocalLedgerAutoSyncCoordinator {
        LocalLedgerAutoSyncCoordinator(
            sleep: { try await sleeper.sleep($0) },
            operation: { await operations.run() }
        )
    }

    func testEligibilityStartsImmediatelyAndPeriodicallyFetchesWithoutLocalWrites() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        operations.finish()
        await eventually { sleeper.durations == [.seconds(300)] }
        sleeper.fire(.seconds(300))
        await eventually { operations.calls == 2 }
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning && sleeper.waits.isEmpty }
    }

    func testLocalSavesDebounceAndResetThePendingDelay() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        operations.finish()
        await eventually { sleeper.durations == [.seconds(300)] }
        coordinator.localChangesSaved()
        await eventually { sleeper.durations == [.seconds(2)] }
        let firstID = sleeper.waits.keys.first
        coordinator.localChangesSaved()
        await eventually { sleeper.durations == [.seconds(2)] && sleeper.waits.keys.first != firstID }
        XCTAssertEqual(operations.calls, 1)
        sleeper.fire(.seconds(2))
        await eventually { operations.calls == 2 }
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning }
    }

    func testEventsDuringRunCoalesceIntoOneSerialFollowup() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        for _ in 0..<20 {
            coordinator.localChangesSaved()
            coordinator.networkRestored()
        }
        XCTAssertEqual(operations.calls, 1)
        operations.finish()
        await eventually { operations.calls == 2 }
        operations.finish()
        await eventually { sleeper.durations == [.seconds(300)] }
        XCTAssertEqual(operations.calls, 2)
        XCTAssertEqual(operations.maximumActive, 1)
        coordinator.setEligible(false)
        await eventually { sleeper.waits.isEmpty }
    }

    func testTransientFailuresBackOffToCapAndSuccessResetsRetry() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        for seconds in [5, 10, 20, 40, 80, 160, 300, 300] {
            operations.finish(.retryableFailure)
            await eventually { sleeper.durations == [.seconds(seconds)] }
            coordinator.localChangesSaved()
            XCTAssertEqual(sleeper.durations, [.seconds(seconds)])
            let calls = operations.calls
            sleeper.fire(.seconds(seconds))
            await eventually { operations.calls == calls + 1 }
        }
        operations.finish()
        await eventually { sleeper.durations == [.seconds(300)] }
        coordinator.networkRestored()
        await eventually { operations.calls == 10 }
        operations.finish(.retryableFailure)
        await eventually { sleeper.durations == [.seconds(5)] }
        coordinator.setEligible(false)
        await eventually { sleeper.waits.isEmpty }
    }

    func testNetworkRecoveryExpeditesRetry() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        operations.finish(.retryableFailure)
        await eventually { sleeper.durations == [.seconds(5)] }
        coordinator.networkRestored()
        await eventually { operations.calls == 2 && sleeper.waits.isEmpty }
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning }
    }

    func testConflictOrAuthenticationPauseSurvivesLifecycleUntilExplicitResume() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        coordinator.localChangesSaved()
        operations.finish(.paused)
        await eventually { coordinator.isPaused }
        coordinator.networkRestored()
        coordinator.localChangesSaved()
        coordinator.setEligible(false)
        coordinator.setEligible(true)
        XCTAssertEqual(operations.calls, 1)
        XCTAssertTrue(sleeper.waits.isEmpty)
        coordinator.resume()
        await eventually { operations.calls == 2 }
        XCTAssertFalse(coordinator.isPaused)
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning }
    }

    func testEligibilityLossCancelsPendingTimerAndRestorationRunsImmediately() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        operations.finish()
        await eventually { sleeper.durations == [.seconds(300)] }
        coordinator.localChangesSaved()
        await eventually { sleeper.durations == [.seconds(2)] }
        coordinator.setEligible(false)
        coordinator.localChangesSaved()
        coordinator.networkRestored()
        await eventually { sleeper.waits.isEmpty }
        sleeper.fire(.seconds(2))
        XCTAssertEqual(operations.calls, 1)
        coordinator.setEligible(true)
        await eventually { operations.calls == 2 }
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning }
    }

    func testCancelledOperationOccupiesSlotUntilItReturnsAndCannotPauseNewSession() async {
        let sleeper = Sleeper(), operations = Operations()
        let coordinator = make(sleeper, operations)
        coordinator.setEligible(true)
        await eventually { operations.calls == 1 }
        coordinator.setEligible(false)
        coordinator.setEligible(true)
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(operations.calls, 1)
        operations.finish(.paused)
        await eventually { operations.calls == 2 }
        XCTAssertFalse(coordinator.isPaused)
        XCTAssertEqual(operations.maximumActive, 1)
        coordinator.setEligible(false)
        operations.finish()
        await eventually { !coordinator.isRunning }
    }
}
