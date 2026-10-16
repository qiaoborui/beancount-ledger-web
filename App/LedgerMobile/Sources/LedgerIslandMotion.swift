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
        // The spring only approaches 1, so snap the tail: a sub-pixel blur still
        // costs an offscreen pass on every frame while content sits settled.
        let blur = (1 - clampedEnter) * 10 + exit * 6
        return LedgerIslandEffect(
            opacity: opacity,
            blur: blur < 0.1 ? 0 : blur,
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

/// Where the hardware Dynamic Island sits, so the overlay grows out of it
/// instead of guessing. Frames are stored in device pixels (measured from the
/// simulator device masks) and converted with `nativeScale`, which keeps them
/// right under Display Zoom, where points no longer map 1:1 to the panel.
struct LedgerIslandCutout: Equatable, Sendable {
    let top: Double
    let size: CGSize

    /// Native panel size (portrait px) → cutout top, width, height in px.
    static let measured: [LedgerIslandPanel: (top: Double, width: Double, height: Double)] = [
        LedgerIslandPanel(1179, 2556): (34, 375, 110),
        LedgerIslandPanel(1206, 2622): (42, 376, 110),
    ]

    static func hardware(nativeWidth: Double, nativeHeight: Double, nativeScale: Double, safeTop: Double) -> LedgerIslandCutout {
        let scale = max(nativeScale, 1)
        let panel = LedgerIslandPanel(min(nativeWidth, nativeHeight), max(nativeWidth, nativeHeight))
        if let px = measured[panel] {
            return LedgerIslandCutout(top: px.top / scale, size: CGSize(width: px.width / scale, height: px.height / scale))
        }
        // Unknown hardware: the cutout is the same physical size everywhere and
        // sits about 48pt above the bottom of the status bar inset.
        return LedgerIslandCutout(top: max(11, safeTop - 48), size: CGSize(width: 376 / scale, height: 110 / scale))
    }

    /// The overlay frame that hides the cutout, bleeding past its edges so the
    /// anti-aliased rim never leaves a hairline of hardware visible.
    func covering(bleed: Double) -> (top: Double, pill: CGSize) {
        (top - bleed, CGSize(width: size.width + 2 * bleed, height: size.height + 2 * bleed))
    }
}

struct LedgerIslandPanel: Hashable, Sendable {
    let width: Int
    let height: Int

    init(_ width: Double, _ height: Double) {
        self.width = Int(width.rounded())
        self.height = Int(height.rounded())
    }
}

/// Shape and notice schedule for the overlay. The shape grows out of the hardware
/// island, settles into an expanded confirmation, shrinks to a compact pill, then
/// retracts. Width leads height so the expansion reads as a sideways fling.
///
/// Proportions follow Apple's Live Activity specs (HIG): the expanded island
/// spans the screen minus 22pt, leading and trailing content flank the camera
/// in the top band, the rest sits below it, and the compact island stays snug
/// around the camera.
struct LedgerIslandStage: Equatable, Sendable {
    /// Resting shape on screens without a hardware island.
    static let defaultPill = CGSize(width: 126, height: 37)
    static let expandedHeight: Double = 96
    /// Expanded corners; smaller shapes use half their height, i.e. a capsule.
    static let cornerRadius: Double = 38

    /// Expanded layout in final-size coordinates (origin at the shape's top-left).
    /// The badge shares its centre with the top-left corner arc, so its margin
    /// is concentric; the amount flanks the camera and the text sits below it.
    enum Layout {
        static let inset: Double = 20
        static let badge: Double = 44
        static var badgeCenter: CGPoint { CGPoint(x: cornerRadius, y: cornerRadius) }
        static let amountY: Double = 27
        static let titleY: Double = 57
        static let subtitleY: Double = 76
        static var textLeft: Double { cornerRadius + badge / 2 + 12 }
        /// Space kept clear between flanking content and the camera.
        static let cameraGap: Double = 8
    }

    /// Compact layout: the leading glyph sits concentric with the end cap.
    enum CompactLayout {
        static let glyph: Double = 22
        static let trailingInset: Double = 12
    }

    /// Resting shape; on Dynamic Island hardware it covers the camera cutout.
    let pill: CGSize
    let expandedWidth: Double
    var expandedHeight: Double { Self.expandedHeight }
    let reduceMotion: Bool
    private(set) var entries: [LedgerIslandStageEntry] = []
    private(set) var width: LedgerIslandSpringTrack
    private(set) var height: LedgerIslandSpringTrack

    init(containerWidth: Double, reduceMotion: Bool, pill: CGSize = Self.defaultPill) {
        self.pill = pill
        expandedWidth = max(Double(pill.width), containerWidth - 22)
        self.reduceMotion = reduceMotion
        width = LedgerIslandSpringTrack(value: Double(pill.width))
        height = LedgerIslandSpringTrack(value: Double(pill.height))
    }

    var current: LedgerIslandStageEntry? { entries.last }

    /// Absolute time after which nothing remains on screen.
    var endTime: Double { current.map { $0.start + $0.timeline.end } ?? 0 }

    static func cornerRadius(height: Double) -> Double { min(height / 2, cornerRadius) }

    /// Width available to the amount beside the camera in the top band.
    var flankWidth: Double {
        (expandedWidth - Double(pill.width)) / 2 - Layout.inset - Layout.cameraGap
    }

    /// Both sides take the wider of the two so the camera stays centred and
    /// the leading and trailing elements read as one piece.
    func compactWidth(trailingTextWidth: Double) -> Double {
        let leading = (Double(pill.height) - CompactLayout.glyph) / 2 + CompactLayout.glyph
        let trailing = CompactLayout.trailingInset + trailingTextWidth
        let side = max(leading, trailing) + Layout.cameraGap
        return min(expandedWidth, Double(pill.width) + 2 * side)
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

enum LedgerIslandAmount {
    /// The compact island stays snug around the camera, so large amounts use
    /// a shorter unit ("¥12,800.00" → "¥1.28万") and whole amounts drop ".00".
    static func compact(_ text: String) -> String {
        guard let first = text.firstIndex(where: \.isNumber),
              let last = text.lastIndex(where: \.isNumber) else { return text }
        let prefix = String(text[..<first])
        let suffix = String(text[text.index(after: last)...])
        let digits = text[first...last].filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return text }
        let body: String
        if value >= 10_000 {
            var short = String(format: "%.2f", value / 10_000)
            while short.hasSuffix("0") { short.removeLast() }
            if short.hasSuffix(".") { short.removeLast() }
            body = short + "万"
        } else if value == value.rounded() {
            body = text[first...last].replacingOccurrences(of: ".00", with: "")
        } else {
            body = String(text[first...last])
        }
        return prefix + body + suffix
    }
}
