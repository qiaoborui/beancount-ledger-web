import CoreGraphics
import Foundation

/// Closed-form `spring(response:dampingFraction:)` maths. Every island frame is a
/// pure function of time, so a new notice can retarget the shape mid-flight while
/// keeping its current velocity instead of restarting from a fixed size.
struct LedgerIslandSpringSegment: Equatable, Sendable {
    var start: Double
    var from: Double
    var velocity: Double
    var target: Double
    var response: Double
    var damping: Double

    func sample(at time: Double) -> (value: Double, velocity: Double) {
        let t = max(0, time - start)
        let omega = 2 * Double.pi / max(response, 0.0001)
        let zeta = min(max(damping, 0), 1)
        let a = from - target
        let decay = exp(-zeta * omega * t)

        if zeta >= 0.9999 {
            let b = velocity + omega * a
            let value = target + (a + b * t) * decay
            let speed = (b - omega * (a + b * t)) * decay
            return (value, speed)
        }

        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        let b = (velocity + zeta * omega * a) / omegaD
        let cosine = cos(omegaD * t), sine = sin(omegaD * t)
        let value = target + decay * (a * cosine + b * sine)
        let speed = decay * (-zeta * omega * (a * cosine + b * sine) + omegaD * (b * cosine - a * sine))
        return (value, speed)
    }
}

enum LedgerIslandSpring {
    /// Step response from 0 to 1; values overshoot 1 for under-damped springs.
    static func progress(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        return LedgerIslandSpringSegment(start: 0, from: 0, velocity: 0, target: 1, response: response, damping: damping)
            .sample(at: t).value
    }
}

struct LedgerIslandSpringTrack: Equatable, Sendable {
    private(set) var segments: [LedgerIslandSpringSegment]

    init(value: Double) {
        segments = [LedgerIslandSpringSegment(start: -.infinity, from: value, velocity: 0, target: value, response: 1, damping: 1)]
    }

    func sample(at time: Double) -> (value: Double, velocity: Double) {
        guard let segment = segments.last(where: { $0.start <= time }) ?? segments.first else { return (0, 0) }
        if segment.start == -.infinity { return (segment.target, 0) }
        return segment.sample(at: time)
    }

    func value(at time: Double) -> Double { sample(at: time).value }

    /// Retargets at `time`, dropping any segments scheduled after it.
    mutating func retarget(to target: Double, at time: Double, response: Double, damping: Double) {
        let current = sample(at: time)
        segments.removeAll { $0.start >= time && $0.start != -.infinity }
        segments.append(LedgerIslandSpringSegment(
            start: time, from: current.value, velocity: current.velocity,
            target: target, response: response, damping: damping
        ))
    }
}

/// Per-notice choreography in seconds from the notice's start.
struct LedgerIslandTimeline: Equatable, Sendable {
    let contentIn: Double
    let ringStart: Double
    let ringEnd: Double
    let check: Double
    let toCompact: Double
    let toPill: Double
    let end: Double

    init(isImport: Bool, interrupting: Bool) {
        contentIn = interrupting ? 0.1 : 0.05
        ringStart = isImport ? 0.2 : 0.22
        ringEnd = isImport ? 1.55 : 0.62
        check = ringEnd + 0.04
        toCompact = isImport ? 3.0 : 2.3
        toPill = toCompact + 1.5
        end = toPill + 0.55
    }

    /// The shape follows the content out, so it retargets slightly after it.
    var compactShapeStart: Double { toCompact + 0.06 }
    var pillShapeStart: Double { toPill + 0.08 }
    var compactContentIn: Double { toCompact + 0.2 }
}

enum LedgerIslandLayer: Sendable {
    case expanded
    case compact
}

/// Opacity / blur / scale for one content element, anchored on the island centre.
struct LedgerIslandEffect: Equatable, Sendable {
    var opacity: Double
    var blur: Double
    var scale: Double
    var yOffset: Double

    static let hidden = LedgerIslandEffect(opacity: 0, blur: 0, scale: 1, yOffset: 0)
}

struct LedgerIslandStageEntry: Equatable, Sendable {
    let notice: LedgerIslandNotice
    let start: Double
    let timeline: LedgerIslandTimeline
    let compactWidth: Double
    var interruptedAt: Double?

    func localTime(_ now: Double) -> Double { now - start }

    func effect(_ layer: LedgerIslandLayer, delay: Double, at now: Double, reduceMotion: Bool) -> LedgerIslandEffect {
        let lt = localTime(now)
        let enterAt = layer == .expanded ? timeline.contentIn : timeline.compactContentIn
        var exitAt = layer == .expanded ? timeline.toCompact : timeline.toPill
        if let interruptedAt { exitAt = min(exitAt, interruptedAt - start) }

        let enter = min(1.2, max(0, LedgerIslandSpring.progress(
            lt - enterAt - delay, response: 0.42, damping: reduceMotion ? 1 : 0.9
        )))
        let exit = LedgerIslandEasing.easeOut((lt - exitAt - delay * 0.4) / 0.16)
        let clampedEnter = min(1, enter)
        let opacity = clampedEnter * (1 - exit)
        guard !reduceMotion else {
            return LedgerIslandEffect(opacity: opacity, blur: 0, scale: 1, yOffset: 0)
        }
        return LedgerIslandEffect(
            opacity: opacity,
            blur: (1 - clampedEnter) * 10 + exit * 6,
            scale: 0.86 + 0.14 * enter - 0.05 * exit,
            yOffset: (1 - clampedEnter) * 3
        )
    }
}

enum LedgerIslandEasing {
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - clamp(t), 3)
    }

    static func easeInOut(_ t: Double) -> Double {
        let t = clamp(t)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}

/// Shape and notice schedule for the overlay. The shape grows out of the hardware
/// island, settles into an expanded confirmation, shrinks to a compact pill, then
/// retracts. Width leads height so the expansion reads as a sideways fling.
struct LedgerIslandStage: Equatable, Sendable {
    static let pill = CGSize(width: 126, height: 37)
    static let maxExpandedWidth: Double = 352

    let expandedWidth: Double
    /// On Dynamic Island hardware the camera cutout covers the top band of the
    /// shape, so the content row moves below it and the island grows taller.
    let expandedHeight: Double
    let contentCenterY: Double
    let reduceMotion: Bool
    private(set) var entries: [LedgerIslandStageEntry] = []
    private(set) var width = LedgerIslandSpringTrack(value: Double(pill.width))
    private(set) var height = LedgerIslandSpringTrack(value: Double(pill.height))

    init(containerWidth: Double, reduceMotion: Bool, reservesCutout: Bool = false) {
        expandedWidth = min(Self.maxExpandedWidth, max(Double(Self.pill.width), containerWidth - 24))
        let cutout = reservesCutout ? Double(Self.pill.height) : 0
        expandedHeight = reservesCutout ? 112 : 84
        contentCenterY = cutout + (expandedHeight - cutout) / 2
        self.reduceMotion = reduceMotion
    }

    var current: LedgerIslandStageEntry? { entries.last }

    /// Absolute time after which nothing remains on screen.
    var endTime: Double { current.map { $0.start + $0.timeline.end } ?? 0 }

    func compactWidth(trailingTextWidth: Double) -> Double {
        let side = max(48, trailingTextWidth + 30)
        return min(expandedWidth, Double(Self.pill.width) + 2 * side)
    }

    mutating func present(_ notice: LedgerIslandNotice, trailingTextWidth: Double, at now: Double) {
        let interrupting = current.map { now < $0.start + $0.timeline.end } ?? false
        if interrupting, var last = entries.popLast() {
            last.interruptedAt = now
            entries.append(last)
        }
        entries.removeAll { entry in
            let gone = entry.interruptedAt.map { now - $0 > 0.4 } ?? (now >= entry.start + entry.timeline.end)
            return gone
        }

        let isImport: Bool
        if case .batchImport = notice.type { isImport = true } else { isImport = false }
        let timeline = LedgerIslandTimeline(isImport: isImport, interrupting: interrupting)
        let compact = compactWidth(trailingTextWidth: trailingTextWidth)
        entries.append(LedgerIslandStageEntry(notice: notice, start: now, timeline: timeline, compactWidth: compact))

        let pill = Self.pill
        retarget(width: expandedWidth, (0.46, 0.70), height: expandedHeight, (0.54, 0.76), at: now)
        retarget(width: compact, (0.42, 0.82), height: Double(pill.height), (0.36, 0.86), at: now + timeline.compactShapeStart)
        retarget(width: Double(pill.width), (0.40, 0.88), height: Double(pill.height), (0.34, 0.90), at: now + timeline.pillShapeStart)
    }

    func size(at now: Double) -> CGSize {
        CGSize(width: width.value(at: now), height: height.value(at: now))
    }

    /// Entries whose content can still be visible at `now`.
    func visibleEntries(at now: Double) -> [LedgerIslandStageEntry] {
        entries.filter { entry in
            if let interruptedAt = entry.interruptedAt { return now - interruptedAt < 0.4 }
            return now < entry.start + entry.timeline.end
        }
    }

    private mutating func retarget(
        width targetWidth: Double, _ widthSpring: (Double, Double),
        height targetHeight: Double, _ heightSpring: (Double, Double),
        at time: Double
    ) {
        let critical = reduceMotion ? 1.0 : nil
        width.retarget(to: targetWidth, at: time, response: min(widthSpring.0, reduceMotion ? 0.32 : .infinity), damping: critical ?? widthSpring.1)
        height.retarget(to: targetHeight, at: time, response: min(heightSpring.0, reduceMotion ? 0.32 : .infinity), damping: critical ?? heightSpring.1)
    }
}
