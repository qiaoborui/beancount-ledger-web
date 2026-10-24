import Foundation
#if canImport(os)
import os
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Low-cost stage instrumentation for the local ledger pipeline.
///
/// Emits `os_signpost` intervals/events under subsystem
/// `app.beancount.ledger.local-performance` (category `ledger`), so a write can
/// be split into Python load stages, Go registration and page/snapshot cost in
/// Instruments (Points of Interest, or `log stream --signpost`). The same
/// intervals sample `phys_footprint` (via `task_info`/`task_vm_info`) and, on
/// iOS, the `os_proc_available_memory` headroom, emitting peak events at the end
/// of each outermost interval.
///
/// The Python loader breakdown arrives through the canonical stream descriptor:
/// `EmbeddedBeancountValidator` asks `ledger_validator.py` for timings by
/// setting `LEDGER_VALIDATION_TIMINGS=1` before an export (the Python default
/// stays quiet and byte-identical), then turns the four values into signpost
/// events. This file builds on macOS too: `os_proc_available_memory` is
/// iOS-only, so the macOS sampler reports footprint only.
enum LocalLedgerPerformance {
    enum Segment: Sendable {
        case canonicalValidate
        case pythonLoad
        case pythonExport
        case pythonParse
        case pythonBooking
        case pythonPlugins
        case pythonValidate
        case goRegister
        case goModelRegister
        case goPage

        var signpostName: StaticString {
            switch self {
            case .canonicalValidate: return "canonical-validate"
            case .pythonLoad: return "python-load"
            case .pythonExport: return "python-export"
            case .pythonParse: return "python-parse"
            case .pythonBooking: return "python-booking"
            case .pythonPlugins: return "python-plugins"
            case .pythonValidate: return "python-validate"
            case .goRegister: return "go-register"
            case .goModelRegister: return "go-model-register"
            case .goPage: return "go-page"
            }
        }

        init?(pythonStage: String) {
            switch pythonStage {
            case "parse": self = .pythonParse
            case "booking": self = .pythonBooking
            case "plugins": self = .pythonPlugins
            case "validate": self = .pythonValidate
            default: return nil
            }
        }
    }

    struct MemorySample: Sendable, Equatable {
        let footprintBytes: UInt64
        let availableBytes: UInt64?
    }

    struct Interval {
        let segment: Segment
        let name: StaticString
        let signpostState: OSSignpostIntervalState
        let started: ContinuousClock.Instant
    }

    static let subsystem = "app.beancount.ledger.local-performance"
    static let category = "ledger"
    /// Python reads the same variable; the app sets it explicitly before an
    /// export. Tools and tests that never set it keep the default behaviour.
    static let pythonTimingsEnvironment = "LEDGER_VALIDATION_TIMINGS"

    private static let signposter = OSSignposter(subsystem: subsystem, category: category)
    private static let memoryPeakName: StaticString = "memory-peak"
    private static let state = MemoryState()
    private static let clock = ContinuousClock()

    // MARK: - Python loader breakdown

    /// Explicitly opts this process into `loader.log_timings` collection.
    static func preparePythonTimings() {
        #if canImport(Darwin)
        guard ProcessInfo.processInfo.environment[pythonTimingsEnvironment] == nil else { return }
        _ = setenv(pythonTimingsEnvironment, "1", 1)
        #endif
    }

    /// Events carry the duration already measured by beancount; they are point
    /// events because the Python-side duration is only known once a stage ends.
    static func recordPythonTimings(_ timings: [String: Double]) {
        for (stage, milliseconds) in timings.sorted(by: { $0.key < $1.key }) {
            guard let segment = Segment(pythonStage: stage) else { continue }
            emit(segment.signpostName, "duration_ms=\(millisecondsString(milliseconds))")
        }
    }

    // MARK: - Intervals and memory

    static func begin(_ segment: Segment) -> Interval {
        let name = segment.signpostName
        let signpostState = signposter.beginInterval(name, id: signposter.makeSignpostID())
        _ = state.begin()
        return Interval(segment: segment, name: name, signpostState: signpostState,
                        started: clock.now)
    }

    static func end(_ interval: Interval) {
        let elapsed = interval.started.duration(to: clock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        signposter.endInterval(interval.name, interval.signpostState)
        let summary = state.finish()
        var message = "duration_ms=\(millisecondsString(milliseconds))"
        if let sample = summary.latest {
            message += " footprint_mb=\(megabytesString(sample.footprintBytes))"
            if let available = sample.availableBytes {
                message += " available_mb=\(megabytesString(available))"
            }
        }
        emit(interval.segment.signpostName, message)
        if summary.sessionEnded, let peak = summary.peakFootprint {
            emit(memoryPeakName,
                 "peak_footprint_mb=\(megabytesString(peak))"
                 + (summary.latest?.availableBytes.map { " available_mb=\(megabytesString($0))" } ?? ""))
        }
    }

    /// Current `phys_footprint` and (iOS only) process memory headroom.
    static func memorySample() -> MemorySample? {
        guard let footprint = footprintBytes() else { return nil }
        return MemorySample(footprintBytes: footprint, availableBytes: availableBytes())
    }

    /// `phys_footprint` is the number the OS counts against the app's limit;
    /// resident size is not a substitute.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// `os_proc_available_memory` has no macOS equivalent; the portable build
    /// reports no headroom instead of failing.
    static func availableBytes() -> UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }

    private static func emit(_ name: StaticString, _ message: String) {
        signposter.emitEvent(name, "\(message)")
    }

    private static func millisecondsString(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }

    private static func megabytesString(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / (1024 * 1024))
    }

    /// Samples while at least one interval is active; a 10 Hz timer catches the
    /// transient peak of a Python load that has already released the AST by the
    /// time the interval ends. State is locked because intervals start/end from
    /// both the engine actor and the embedded-validator actor.
    private final class MemoryState: @unchecked Sendable {
        struct Summary {
            let peakFootprint: UInt64?
            let latest: MemorySample?
            let sessionEnded: Bool
        }

        private let lock = NSLock()
        private let queue = DispatchQueue(
            label: "app.beancount.ledger.local-performance.memory", qos: .utility)
        private var active = 0
        private var peak: UInt64 = 0
        private var latest: MemorySample?
        private var sampler: DispatchSourceTimer?

        func begin() -> MemorySample? {
            lock.lock()
            defer { lock.unlock() }
            active += 1
            if active == 1 {
                peak = 0
                latest = nil
                startSamplerLocked()
            }
            return recordLocked(LocalLedgerPerformance.memorySample())
        }

        func finish() -> Summary {
            lock.lock()
            defer { lock.unlock() }
            active = max(0, active - 1)
            guard active == 0 else {
                return Summary(peakFootprint: peak > 0 ? peak : nil,
                               latest: latest, sessionEnded: false)
            }
            stopSamplerLocked()
            let summary = Summary(peakFootprint: peak > 0 ? peak : nil,
                                  latest: latest, sessionEnded: true)
            peak = 0
            latest = nil
            return summary
        }

        private func sample() -> MemorySample? {
            lock.lock()
            defer { lock.unlock() }
            return recordLocked(LocalLedgerPerformance.memorySample())
        }

        private func recordLocked(_ sample: MemorySample?) -> MemorySample? {
            guard let sample else { return nil }
            latest = sample
            peak = max(peak, sample.footprintBytes)
            return sample
        }

        private func startSamplerLocked() {
            guard sampler == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100),
                           repeating: .milliseconds(100), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in _ = self?.sample() }
            sampler = timer
            timer.resume()
        }

        private func stopSamplerLocked() {
            sampler?.cancel()
            sampler = nil
        }
    }
}
