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
/// Decides whether the island still needs animation frames, and when its
/// expanded content may start.
///
/// The island renders inside `TimelineView(.animation)`, which re-evaluates at
/// display refresh rate. Under Reduce Motion every effect is a constant, so no
/// frame can change anything; and once `timeline.end` has passed the content is
/// settled. Both cases previously kept ticking for the whole 4-5 s window.
enum LedgerIslandFrameGate {
    static func needsFrames(entry: LedgerIslandStageEntry, reduceMotion: Bool, now: Double) -> Bool {
        if reduceMotion { return false }
        return now < entry.start + entry.timeline.end
    }

    /// Content enters once the shape is past `settled` of its way to the
    /// expanded width. Large amounts close to the pill hide nothing: the shape
    /// is already most of the way there when the content starts.
    static let settled: Double = 0.55

    static func contentIn(entry: LedgerIslandStageEntry, expandedWidth: Double) -> Double {
        let start = entry.compactWidth
        let travel = expandedWidth - start
        let tolerance = max(30, travel * 0.18)
        return start + travel * settled > expandedWidth - tolerance
            ? entry.timeline.contentIn
            : entry.timeline.contentIn + settled
    }

    /// Time for the shape to grow from the pill past `settled` of the way to the
    /// expanded size; zero when it is already that far (content would show at
    /// once, so the expansion is not worth delaying for).
    static func preludeDelay(pillWidth: Double, pillHeight: Double, expandedWidth: Double,
                             expandedHeight: Double) -> Double {
        let travel = expandedWidth - pillWidth
        guard travel > 30 else { return 0 }
        let target = pillWidth + travel * settled
        let width = LedgerIslandSpringSegment(start: 0, from: pillWidth, velocity: 0, target: expandedWidth,
                                              response: 0.46, damping: 0.70)
        let height = LedgerIslandSpringSegment(start: 0, from: pillHeight, velocity: 0, target: expandedHeight,
                                               response: 0.54, damping: 0.76)
        // The target is reached once and never again for these damping ratios,
        // so the first crossing is the whole answer.
        var time = 0.0
        while time < 1.2 {
            if width.sample(at: time).value >= target && height.sample(at: time).value >= pillHeight + (expandedHeight - pillHeight) * settled {
                return time
            }
            time += 0.005
        }
        return 0
    }
}

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

    func effect(_ layer: LedgerIslandLayer, delay: Double, at now: Double, reduceMotion: Bool,
                contentIn: Double? = nil) -> LedgerIslandEffect {
        let lt = localTime(now)
        // The stage hands back its own content time, which waits for the shape
        // when the shape has further to travel (a short notice that never needed
        // the full expanded width). Content then never fades out of a shape that
        // is still growing, which is what read as a flash.
        let enterAt = contentIn ?? (layer == .expanded ? timeline.contentIn : timeline.compactContentIn)
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
/// Proportions follow the expanded Live Activity: leading and trailing content
/// flank the camera in the top band and the rest sits below it, while the
/// compact and resting shapes stay snug around the camera.
///
/// The expanded island keeps a wider margin to the screen edges than a Live
/// Activity does (24pt instead of 22pt), and its content is inset from the
/// rounded edges rather than hugging them, so the confirmation reads as a card
/// floating under the camera instead of something pressed against the bezel.
struct LedgerIslandStage: Equatable, Sendable {
    /// Resting shape on screens without a hardware island.
    static let defaultPill = CGSize(width: 126, height: 37)
    /// Gap between the expanded island and the screen edges.
    static let screenMargin: Double = 24
    /// Expanded corners; smaller shapes use half their height, i.e. a capsule.
    static let cornerRadius: Double = 38

    /// Expanded layout in final-size coordinates (origin at the shape's top-left).
    ///
    /// The shape's top edge is the camera's top edge, so the camera occupies a
    /// fixed rectangle at the top centre: `band` tall (the resting shape that
    /// covers it) and the cutout's width across. Nothing is ever placed in that
    /// rectangle. The island is split the way a Live Activity is:
    ///
    /// - the camera band, on the camera's centre line: the status caption in
    ///   the leading flank and the amount in the trailing flank, each kept
    ///   `cameraGap` from the camera and `inset` from the edge;
    /// - the body, below the camera: the badge with its ring, then the title
    ///   and subtitle across the full width.
    ///
    /// The 44pt ring is taller than the camera band, so it never rides beside
    /// the camera: there it would either run into the cutout or out of the
    /// rounded corner.
    enum Layout {
        /// Margin from the body row (badge, title, subtitle) to the island's
        /// leading and trailing edges.
        static let inset: Double = 26
        /// Margin from the caption and the amount to the island's edges. The
        /// camera band runs through the top corners, where the edge curves in,
        /// so it keeps more room than the body row below.
        static let bandInset: Double = 32
        static let badge: Double = 36
        /// The ring around the badge; the badge is centred inside it.
        static let ring: Double = 44
        /// Space kept clear between flanking content and the camera.
        static let cameraGap: Double = 8
        /// Space between the camera's bottom edge and the body row.
        static let bodyGap: Double = 12
        /// Space kept under the body row.
        static let bottomMargin: Double = 22
        /// Space between the ring and the text column.
        static let textGap: Double = 12
        /// Cap for the title when it has to fold; `titleLines` names it.
        static let titleLines: Int = 2
        /// A title that still overflows two lines uses this type scale.
        static let longTitleScale: Double = 0.9
        /// Gap between the title block and the subtitle.
        static let titleGap: Double = 3

        static var badgeCenterX: Double { inset + ring / 2 }
        /// The text column clears the ring, not just the badge.
        static var textLeft: Double { inset + ring + textGap }

        /// Rows the text column needs: the title folded to one or two lines.
        struct TextRows: Equatable, Sendable {
            let titleLines: Int
        }

        /// The camera's centre line, shared by the caption and the amount.
        static func bandCenterY(band: Double) -> Double { band / 2 }

        /// Top of the body row: under the camera, never beside it.
        static func bodyTop(band: Double) -> Double { band + bodyGap }

        /// Title lines, the gap and the subtitle.
        static func textBlockHeight(rows: TextRows) -> Double {
            Double(rows.titleLines) * LedgerIslandFonts.titleLineHeight + titleGap + LedgerIslandFonts.subtitleLineHeight
        }

        /// The body row is as tall as the ring or the text, whichever is taller;
        /// the other is centred beside it.
        static func bodyHeight(rows: TextRows) -> Double { max(ring, textBlockHeight(rows: rows)) }

        static func badgeCenterY(band: Double, rows: TextRows) -> Double {
            bodyTop(band: band) + bodyHeight(rows: rows) / 2
        }

        private static func textTop(band: Double, rows: TextRows) -> Double {
            bodyTop(band: band) + (bodyHeight(rows: rows) - textBlockHeight(rows: rows)) / 2
        }

        static func titleCenterY(band: Double, rows: TextRows) -> Double {
            textTop(band: band, rows: rows) + Double(rows.titleLines) * LedgerIslandFonts.titleLineHeight / 2
        }

        static func subtitleCenterY(band: Double, rows: TextRows) -> Double {
            textTop(band: band, rows: rows) + Double(rows.titleLines) * LedgerIslandFonts.titleLineHeight
                + titleGap + LedgerIslandFonts.subtitleLineHeight / 2
        }

        /// The settled shape's height: camera band, body row, bottom margin.
        static func expandedHeight(band: Double, rows: TextRows) -> Double {
            bodyTop(band: band) + bodyHeight(rows: rows) + bottomMargin
        }
    }

    /// Compact layout: the leading glyph sits concentric with the end cap.
    enum CompactLayout {
        static let glyph: Double = 22
        static let trailingInset: Double = 14
        /// Space between the amount and the end cap. The expanded island leaves
        /// a breath at the bottom, and the compact one keeps that ratio.
        static let trailingGap: Double = 3
    }

    /// The hardware island as the overlay sees it: its top in overlay
    /// coordinates and the size the resting shape takes to cover it. Without a
    /// hardware island the resting shape itself stands in for the cutout.
    struct Viewport: Equatable, Sendable {
        let top: Double
        let pillWidth: Double
        let pillHeight: Double

        init(top: Double, pillWidth: Double, pillHeight: Double) {
            self.top = top
            self.pillWidth = pillWidth
            self.pillHeight = pillHeight
        }

        /// The same cutout with a different resting shape behind it.
        func sized(width: Double, height: Double) -> Viewport {
            Viewport(top: top, pillWidth: width, pillHeight: height)
        }
    }

    /// The shape's footprint: the resting shape, which covers the camera on
    /// Dynamic Island hardware.
    let pill: CGSize
    /// Gap between the expanded island's leading edge and the cutout's.
    let flank: Double
    /// The hardware island. Content is placed against it, never against the
    /// shape's own size: the shape may be mid-flight or, for a short notice
    /// before its prelude, still the resting pill, and the camera does not move.
    let cutout: Viewport
    let reduceMotion: Bool
    private(set) var entries: [LedgerIslandStageEntry] = []
    private(set) var width: LedgerIslandSpringTrack
    private(set) var height: LedgerIslandSpringTrack

    init(containerWidth: Double, reduceMotion: Bool, pill: CGSize = Self.defaultPill,
         pillTop: Double = 0, flank: Double? = nil) {
        self.pill = pill
        let flank = flank ?? Self.flank(screenWidth: containerWidth, cutoutWidth: Double(pill.width))
        self.flank = flank
        cutout = Viewport(top: pillTop, pillWidth: Double(pill.width), pillHeight: Double(pill.height))
        self.reduceMotion = reduceMotion
        width = LedgerIslandSpringTrack(value: Double(pill.width))
        height = LedgerIslandSpringTrack(value: Double(pill.height))
        // The island is as wide as the camera band needs; the screen only
        // bounds it so it never runs under the rounded screen edges on a
        // small phone.
        let room = containerWidth - 2 * Self.screenMargin
        expandedWidth = min(max(Double(pill.width), cutout.pillWidth + 2 * flank), max(room, Double(pill.width)))
    }

    /// Gap between the expanded island's edge and the cutout's. The caption
    /// and the amount flank the camera, each `inset` short of the island's
    /// edge and `cameraGap` short of the camera, so the island spans the
    /// screen (less its margins) whatever the cutout's width. Phones without
    /// a hardware island use the stand-in pill the same way.
    static func flank(screenWidth: Double, cutoutWidth: Double) -> Double {
        let wanted = cutoutWidth / 2 + Layout.bandInset + Layout.cameraGap
        let room = screenWidth / 2 - screenMargin
        return max(wanted, room) - cutoutWidth / 2
    }

    /// Width of the expanded island, set in `init` from the cutout and the
    /// screen: beyond the camera by `flank` on each side.
    let expandedWidth: Double

    /// Height of the camera band: the resting shape, which covers the camera.
    var band: Double { cutout.pillHeight }

    /// The camera in the settled shape's coordinates. The shape's top edge is
    /// the camera's, and the shape grows symmetrically around it.
    var cameraRect: CGRect {
        CGRect(x: (expandedWidth - cutout.pillWidth) / 2, y: 0, width: cutout.pillWidth, height: band)
    }

    /// Height of the settled shape for a notice's text rows.
    func settledHeight(rows: Layout.TextRows) -> Double {
        Layout.expandedHeight(band: band, rows: rows)
    }

    var current: LedgerIslandStageEntry? { entries.last }

    /// Absolute time after which nothing remains on screen.
    var endTime: Double { current.map { $0.start + $0.timeline.end } ?? 0 }

    static func cornerRadius(height: Double) -> Double { min(height / 2, cornerRadius) }

    /// Width each flank of the camera band offers the caption and the amount.
    var flankWidth: Double {
        (expandedWidth - cutout.pillWidth) / 2 - Layout.bandInset - Layout.cameraGap
    }

    /// Both sides take the wider of the two so the camera stays centred and
    /// the leading and trailing elements read as one piece.
    func compactWidth(trailingTextWidth: Double) -> Double {
        let leading = (Double(pill.height) - CompactLayout.glyph) / 2 + CompactLayout.glyph
        // The end cap curves away at the top and bottom, so the amount needs
        // a little more room than its own width to clear the rounded edges.
        let trailing = CompactLayout.trailingInset + trailingTextWidth + CompactLayout.trailingGap
        let side = max(leading, trailing) + Layout.cameraGap
        return min(expandedWidth, Double(pill.width) + 2 * side)
    }

    mutating func present(_ notice: LedgerIslandNotice, trailingTextWidth: Double,
                          rows: Layout.TextRows = .init(titleLines: 1), at now: Double) {
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

        retarget(width: expandedWidth, (0.46, 0.70), height: settledHeight(rows: rows), (0.54, 0.76), at: now)
        retarget(width: compact, (0.42, 0.82), height: Double(pill.height), (0.36, 0.86), at: now + timeline.compactShapeStart)
        retarget(width: Double(pill.width), (0.40, 0.88), height: Double(pill.height), (0.34, 0.90), at: now + timeline.pillShapeStart)
    }

    /// Starts the expansion to the expanded size without content yet; the
    /// notice is presented `wait` seconds later, when the shape has landed.
    mutating func grow(to rows: Layout.TextRows, at now: Double) {
        retarget(width: expandedWidth, (0.46, 0.70), height: settledHeight(rows: rows), (0.54, 0.76), at: now)
    }

    func size(at now: Double) -> CGSize {
        CGSize(width: width.value(at: now), height: height.value(at: now))
    }

    /// The expanded content starts only once the shape is close to its final
    /// width: when the start line is too far from the expanded width, the
    /// content waits for the shape instead of arriving into a still-growing
    /// pill and then fading out again.
    func contentIn(entry: LedgerIslandStageEntry) -> Double {
        LedgerIslandFrameGate.contentIn(entry: entry, expandedWidth: expandedWidth)
    }

    /// Delay before a notice starts when nothing has moved it yet. A resting
    /// pill waits for the expansion to land first; a shape that is already
    /// moving starts its notice right away, so an interruption keeps speed.
    func preludeDelay(rows: Layout.TextRows, at now: Double) -> Double {
        let current = size(at: now)
        let atRest = abs(current.width - Double(pill.width)) < 2 && abs(current.height - Double(pill.height)) < 2
        guard atRest else { return 0 }
        return LedgerIslandFrameGate.preludeDelay(pillWidth: Double(pill.width), pillHeight: Double(pill.height),
            expandedWidth: expandedWidth, expandedHeight: settledHeight(rows: rows))
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
