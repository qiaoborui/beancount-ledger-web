import Foundation

/// Serializes automatic Git synchronization while the session is eligible.
/// The operation owns persistence, error classification, and widget refresh.
@MainActor
final class LocalLedgerAutoSyncCoordinator {
    enum Outcome: Sendable {
        case success
        case retryableFailure
        /// Conflict, credentials, or configuration require explicit intervention.
        case paused
    }

    struct Timing: Sendable {
        var debounce: Duration = .seconds(2)
        var periodic: Duration = .seconds(300)
        var initialRetry: Duration = .seconds(5)
        var maximumRetry: Duration = .seconds(300)
    }

    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void
    typealias Operation = @MainActor @Sendable () async -> Outcome

    private enum WaitKind { case debounce, periodic, retry }

    private let timing: Timing
    private let sleep: Sleep
    private let operation: Operation
    private var eligible = false
    private var pending = false
    private var retryDelay: Duration
    private var timer: Task<Void, Never>?
    private var timerID = UUID()
    private var waitKind: WaitKind?
    private var running: Task<Void, Never>?
    private(set) var isPaused = false
    var isRunning: Bool { running != nil }

    init(
        timing: Timing = .init(),
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        operation: @escaping Operation
    ) {
        precondition(timing.debounce >= .zero && timing.periodic > .zero)
        precondition(timing.initialRetry > .zero && timing.maximumRetry >= timing.initialRetry)
        self.timing = timing
        self.sleep = sleep
        self.operation = operation
        retryDelay = timing.initialRetry
    }

    deinit {
        timer?.cancel()
        running?.cancel()
    }

    /// Combine foreground/background execution allowance, network, unlock, and
    /// configured Git storage in the caller. Becoming eligible fetches immediately.
    func setEligible(_ value: Bool) {
        guard eligible != value else { return }
        eligible = value
        if value {
            requestSync()
        } else {
            pending = false
            cancelTimer()
            // Keep the slot occupied until even a non-cooperative operation exits.
            running?.cancel()
        }
    }

    func localChangesSaved() {
        guard eligible, !isPaused else { return }
        if running != nil {
            pending = true
        } else if waitKind != .retry {
            schedule(after: timing.debounce, kind: .debounce)
        }
    }

    func networkRestored() {
        requestSync()
    }

    /// Explicit foreground/recovery events can expedite an outstanding retry.
    func requestSync() {
        guard eligible, !isPaused else { return }
        cancelTimer()
        if running != nil {
            pending = true
        } else {
            start()
        }
    }

    /// Call after a credential/configuration change or conflict resolution.
    func resume() {
        isPaused = false
        retryDelay = timing.initialRetry
        requestSync()
    }

    private func cancelTimer() {
        timerID = UUID()
        timer?.cancel()
        timer = nil
        waitKind = nil
    }

    private func schedule(after delay: Duration, kind: WaitKind) {
        cancelTimer()
        let id = timerID
        let sleep = sleep
        waitKind = kind
        timer = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.timerID == id else { return }
            self.timer = nil
            self.waitKind = nil
            self.start()
        }
    }

    private func start() {
        guard eligible, !isPaused, running == nil else { return }
        pending = false
        let operation = operation
        running = Task { [weak self] in
            // Eligibility may have changed before this task received execution time.
            guard !Task.isCancelled else {
                self?.finished(.success, cancelled: true)
                return
            }
            let outcome = await operation()
            self?.finished(outcome, cancelled: Task.isCancelled)
        }
    }

    private func finished(_ outcome: Outcome, cancelled: Bool) {
        running = nil
        guard eligible else { return }
        if cancelled {
            // A new eligible session may be waiting on the cancelled operation.
            if pending { start() }
            return
        }
        switch outcome {
        case .success:
            retryDelay = timing.initialRetry
            if pending { start() }
            else { schedule(after: timing.periodic, kind: .periodic) }
        case .retryableFailure:
            pending = false
            schedule(after: retryDelay, kind: .retry)
            retryDelay = min(retryDelay * 2, timing.maximumRetry)
        case .paused:
            isPaused = true
            pending = false
            cancelTimer()
        }
    }
}
