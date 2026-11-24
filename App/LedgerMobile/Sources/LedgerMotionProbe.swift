#if os(iOS)
import QuartzCore
import UIKit

/// A frame meter for development builds on a device, compiled in only with
/// `LEDGER_PERF_PROBE` (pass `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited)
/// LEDGER_PERF_PROBE'` to xcodebuild). It watches every frame while the app is
/// active and writes to `Library/Caches/motion-probe.log`:
/// - one line per labelled span (a drawer open or close, the keyboard), with
///   its frames, the frames it dropped and its worst frame;
/// - one line per stall, a frame that took over 50 ms, with the spans under
///   way at the time.
/// Copy the log off the phone with `xcrun devicectl device copy from`.
/// Without the flag every call is empty.
@MainActor
final class LedgerMotionProbe {
    static let shared = LedgerMotionProbe()

    #if LEDGER_PERF_PROBE
    private struct Span {
        var start: CFTimeInterval
        var frames = 0
        var dropped = 0
        var worst: CFTimeInterval = 0
    }

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var spans: [String: Span] = [:]
    private var lines: [String] = []
    private let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("motion-probe.log")
    private let clock = DateFormatter()

    private init() {
        clock.dateFormat = "HH:mm:ss.SSS"
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LedgerMotionProbe.shared.run(true) }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LedgerMotionProbe.shared.run(false) }
        }
        center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LedgerMotionProbe.shared.mark("keyboard-show", for: 0.6) }
        }
        center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LedgerMotionProbe.shared.mark("keyboard-hide", for: 0.6) }
        }
        write("--- launch \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")")
    }

    func start() { run(UIApplication.shared.applicationState == .active) }

    func begin(_ label: String) {
        if spans[label] == nil { spans[label] = Span(start: CACurrentMediaTime()) }
    }

    func end(_ label: String) {
        guard let span = spans.removeValue(forKey: label) else { return }
        let duration = (CACurrentMediaTime() - span.start) * 1000
        write(String(format: "span %@ %.0fms frames=%d dropped=%d worst=%.1fms", label, duration,
                     span.frames, span.dropped, span.worst * 1000))
    }

    /// A span that ends by itself after `seconds`.
    func mark(_ label: String, for seconds: TimeInterval) {
        begin(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.end(label) }
    }

    private func run(_ on: Bool) {
        link?.invalidate()
        link = nil
        last = 0
        guard on else { flush(); return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let delta = link.timestamp - last
        let expected = max(1.0 / 120, link.targetTimestamp - link.timestamp)
        let missed = max(0, Int((delta / expected).rounded()) - 1)
        for key in spans.keys {
            spans[key]!.frames += 1
            spans[key]!.dropped += missed
            spans[key]!.worst = max(spans[key]!.worst, delta)
        }
        if delta > 0.05 {
            let during = spans.keys.sorted().joined(separator: ",")
            write(String(format: "stall %.0fms%@", delta * 1000, during.isEmpty ? "" : " during " + during))
        }
    }

    private func write(_ line: String) {
        lines.append("\(clock.string(from: Date())) \(line)")
        if lines.count >= 20 { flush() }
    }

    private func flush() {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        lines.removeAll()
        let url = url
        DispatchQueue.global(qos: .utility).async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
    #else
    func start() {}
    func begin(_ label: String) {}
    func end(_ label: String) {}
    func mark(_ label: String, for seconds: TimeInterval) {}
    #endif
}
#endif
