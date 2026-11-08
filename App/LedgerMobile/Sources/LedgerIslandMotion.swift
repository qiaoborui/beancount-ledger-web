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

/// Decides whether the island still needs animation frames.
///
/// The island renders inside `TimelineView(.animation)`, which re-evaluates at
/// display refresh rate. Once `timeline.end` has passed the content is settled
/// and the timeline pauses instead of ticking for nothing.
enum LedgerIslandFrameGate {
    static func needsFrames(entry: LedgerIslandStageEntry, reduceMotion: Bool, now: Double) -> Bool {
        // Reduce Motion still crossfades, so it ticks for the same window; it
        // never blurs or scales, so those frames are cheap.
        now < entry.start + entry.timeline.end
    }
}

/// Per-notice choreography in seconds from the notice's start.
///
/// Content starts with the shape, not after it: the row is clipped by the
/// growing island and fades in as the shape reveals it, so no frame shows an
/// empty black slab. The expanded card holds long enough to read one row, the
/// compact pill a little shorter.
struct LedgerIslandTimeline: Equatable, Sendable {
    let contentIn: Double
    /// When the checkmark draws and the success haptic fires.
    let check: Double
    let toCompact: Double
    let toPill: Double
    let end: Double

    /// Expanded hold: one entry is a payee and an amount; an import also
    /// carries a count, so it stays up a little longer.
    static let entryHold: Double = 1.6
    static let importHold: Double = 2.2
    static let compactHold: Double = 1.2

    init(isImport: Bool) {
        contentIn = 0.08
        check = 0.2
        toCompact = isImport ? Self.importHold : Self.entryHold
        toPill = toCompact + Self.compactHold
        end = toPill + 0.45
    }

    /// The shape follows the content out, so it retargets slightly after it.
    var compactShapeStart: Double { toCompact + 0.04 }
    var pillShapeStart: Double { toPill + 0.06 }
    var compactContentIn: Double { toCompact + 0.16 }
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
    /// The settled expanded row: its width and how the title column fits.
    let row: LedgerIslandStage.Layout.Row
    let compactWidth: Double
    var interruptedAt: Double?

    init(notice: LedgerIslandNotice, start: Double, timeline: LedgerIslandTimeline,
         row: LedgerIslandStage.Layout.Row = .init(width: 300, titleWidth: 120, showsSecondary: false),
         compactWidth: Double, interruptedAt: Double? = nil) {
        self.notice = notice
        self.start = start
        self.timeline = timeline
        self.row = row
        self.compactWidth = compactWidth
        self.interruptedAt = interruptedAt
    }

    func localTime(_ now: Double) -> Double { now - start }

    /// Blur only softens the first frames of the entry; content leaves with a
    /// plain fade, because a smear on the way out read as lag.
    static let maxBlur: Double = 3

    func effect(_ layer: LedgerIslandLayer, delay: Double, at now: Double, reduceMotion: Bool) -> LedgerIslandEffect {
        let lt = localTime(now)
        let enterAt = layer == .expanded ? timeline.contentIn : timeline.compactContentIn
        var exitAt = layer == .expanded ? timeline.toCompact : timeline.toPill
        if let interruptedAt { exitAt = min(exitAt, interruptedAt - start) }

        let enter = min(1.1, max(0, LedgerIslandSpring.progress(
            lt - enterAt - delay, response: 0.3, damping: reduceMotion ? 1 : 0.9
        )))
        let exit = LedgerIslandEasing.easeOut((lt - exitAt - delay * 0.4) / 0.14)
        let clampedEnter = min(1, enter)
        let opacity = clampedEnter * (1 - exit)
        guard !reduceMotion else {
            return LedgerIslandEffect(opacity: opacity, blur: 0, scale: 1, yOffset: 0)
        }
        // The spring only approaches 1, so snap the tail: a sub-pixel blur still
        // costs an offscreen pass on every frame while content sits settled.
        let blur = (1 - clampedEnter) * Self.maxBlur
        return LedgerIslandEffect(
            opacity: opacity,
            blur: blur < 0.1 ? 0 : blur,
            scale: 0.92 + 0.08 * enter - 0.03 * exit,
            yOffset: (1 - clampedEnter) * 2
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
/// The expanded confirmation is a single-row card: the camera band at the top
/// stays empty, and one row under it carries a check disc, the title and the
/// amount. The card is only as wide as that row needs (never narrower than
/// `Layout.minWidth`), and keeps at least `screenMargin` to the screen edges.
struct LedgerIslandStage: Equatable, Sendable {
    /// Resting shape on screens without a hardware island.
    static let defaultPill = CGSize(width: 126, height: 37)
    /// Least gap between the expanded island and the screen edges.
    static let screenMargin: Double = 24
    /// Expanded corners; smaller shapes use half their height, i.e. a capsule.
    static var cornerRadius: Double { Layout.cornerRadius }

    /// Expanded layout in final-size coordinates (origin at the shape's top-left).
    ///
    /// The shape's top edge is the camera's top edge, so the camera occupies a
    /// fixed rectangle at the top centre: `band` tall (the resting shape that
    /// covers it) and the cutout's width across. Nothing is ever placed in
    /// that band. One row sits under it:
    ///
    ///     [disc]  title  secondary              amount
    ///
    /// The disc is concentric with the bottom-leading corner: its centre is
    /// the corner arc's centre, so the corner radius is `discPadding` plus
    /// the disc's radius, and the disc keeps `discPadding` to both edges.
    /// The title and the amount share the disc's centre line.
    enum Layout {
        static let disc: Double = 28
        /// Gap from the disc to the leading and bottom edges.
        static let discPadding: Double = 16
        /// Gap between the camera's bottom edge and the top of the disc.
        static let rowGap: Double = 4
        /// Gap between the disc and the title.
        static let discGap: Double = 10
        /// Gap between the title and the secondary label beside it.
        static let secondaryGap: Double = 6
        /// Least gap between the text and the amount.
        static let amountGap: Double = 14
        /// Gap from the amount's trailing edge to the shape's edge. A little
        /// more than `discPadding`, because text has no round side to sit in
        /// the corner arc.
        static let trailingInset: Double = 20
        /// The card never shrinks below this, so a short payee still reads as
        /// a card hanging from the camera rather than a swollen pill.
        static let minWidth: Double = 300
        /// The title column never gives up more than this to the amount.
        static let minTitleWidth: Double = 56

        static var cornerRadius: Double { discPadding + disc / 2 }
        static var discCenterX: Double { discPadding + disc / 2 }
        static var textLeft: Double { discPadding + disc + discGap }

        /// The row's centre line, just under the camera band.
        static func rowCenterY(band: Double) -> Double { band + rowGap + disc / 2 }

        /// The settled shape's height: camera band, the row, bottom padding.
        static func expandedHeight(band: Double) -> Double { band + rowGap + disc + discPadding }

        /// How one notice's row fits: the settled width, the room the title
        /// gets, and whether the secondary label has room beside it.
        struct Row: Equatable, Sendable {
            let width: Double
            let titleWidth: Double
            let showsSecondary: Bool
        }

        /// Fits a row whose title, secondary label and amount measure the
        /// given widths into at most `maxWidth`. The secondary label is shown
        /// only when the title still fits whole beside it; otherwise it is
        /// dropped and the title truncates.
        static func row(titleWidth: Double, secondaryWidth: Double?, amountWidth: Double, maxWidth: Double) -> Row {
            let fixed = textLeft + amountGap + amountWidth + trailingInset
            let floor = min(minWidth, maxWidth)
            if let secondaryWidth, secondaryWidth > 0 {
                let needed = fixed + titleWidth + secondaryGap + secondaryWidth
                if needed <= maxWidth {
                    return Row(width: max(floor, needed), titleWidth: titleWidth, showsSecondary: true)
                }
            }
            let width = min(maxWidth, max(floor, fixed + titleWidth))
            return Row(width: width, titleWidth: max(minTitleWidth, min(titleWidth, width - fixed)), showsSecondary: false)
        }
    }

    /// Compact layout: the leading disc sits concentric with the end cap.
    enum CompactLayout {
        static let glyph: Double = 18
        static let trailingInset: Double = 14
        /// Space between the amount and the end cap.
        static let trailingGap: Double = 3
        /// Space kept clear between the glyph or the amount and the camera.
        static let cameraGap: Double = 8
    }

    /// The hardware island as the overlay sees it: its top in overlay
    /// coordinates and the size the resting shape takes to cover it. Without a
    /// hardware island the resting shape itself stands in for the cutout.
    struct Viewport: Equatable, Sendable {
        let top: Double
        let pillWidth: Double
        let pillHeight: Double
    }

    /// The shape's footprint: the resting shape, which covers the camera on
    /// Dynamic Island hardware.
    let pill: CGSize
    /// The hardware island. Content is placed against it, never against the
    /// shape's own size: the shape may be mid-flight, and the camera does not move.
    let cutout: Viewport
    let reduceMotion: Bool
    /// The widest the expanded island may grow: the screen less its margins.
    let maxWidth: Double
    private(set) var entries: [LedgerIslandStageEntry] = []
    private(set) var width: LedgerIslandSpringTrack
    private(set) var height: LedgerIslandSpringTrack

    init(containerWidth: Double, reduceMotion: Bool, pill: CGSize = Self.defaultPill, pillTop: Double = 0) {
        self.pill = pill
        cutout = Viewport(top: pillTop, pillWidth: Double(pill.width), pillHeight: Double(pill.height))
        self.reduceMotion = reduceMotion
        width = LedgerIslandSpringTrack(value: Double(pill.width))
        height = LedgerIslandSpringTrack(value: Double(pill.height))
        maxWidth = max(Double(pill.width), containerWidth - 2 * Self.screenMargin)
    }

    /// Height of the camera band: the resting shape, which covers the camera.
    var band: Double { cutout.pillHeight }

    /// Height of the settled expanded shape.
    var expandedHeight: Double { Layout.expandedHeight(band: band) }

    /// The camera in a settled shape `width` wide. The shape's top edge is the
    /// camera's, and the shape grows symmetrically around it.
    func cameraRect(width: Double) -> CGRect {
        CGRect(x: (width - cutout.pillWidth) / 2, y: 0, width: cutout.pillWidth, height: band)
    }

    /// The row for a notice whose parts measure these widths, on this screen.
    func row(titleWidth: Double, secondaryWidth: Double?, amountWidth: Double) -> Layout.Row {
        Layout.row(titleWidth: titleWidth, secondaryWidth: secondaryWidth, amountWidth: amountWidth, maxWidth: maxWidth)
    }

    var current: LedgerIslandStageEntry? { entries.last }

    /// Absolute time after which nothing remains on screen.
    var endTime: Double { current.map { $0.start + $0.timeline.end } ?? 0 }

    static func cornerRadius(height: Double) -> Double { min(height / 2, cornerRadius) }

    /// Both sides take the wider of the two so the camera stays centred and
    /// the leading and trailing elements read as one piece.
    func compactWidth(trailingTextWidth: Double) -> Double {
        let leading = (Double(pill.height) - CompactLayout.glyph) / 2 + CompactLayout.glyph
        // The end cap curves away at the top and bottom, so the amount needs
        // a little more room than its own width to clear the rounded edges.
        let trailing = CompactLayout.trailingInset + trailingTextWidth + CompactLayout.trailingGap
        let side = max(leading, trailing) + CompactLayout.cameraGap
        return min(maxWidth, Double(pill.width) + 2 * side)
    }

    /// Spring for the expansion: brisk, with a hint of overshoot on the width
    /// only, so the card lands instead of wobbling.
    static let expandWidth = (response: 0.38, damping: 0.82)
    static let expandHeight = (response: 0.36, damping: 0.88)
    static let collapseWidth = (response: 0.42, damping: 0.86)
    static let collapseHeight = (response: 0.36, damping: 0.9)
    static let retractWidth = (response: 0.40, damping: 0.9)
    static let retractHeight = (response: 0.34, damping: 0.92)

    mutating func present(_ notice: LedgerIslandNotice, row: Layout.Row, trailingTextWidth: Double, at now: Double) {
        let interrupting = current.map { now < $0.start + $0.timeline.end } ?? false
        if interrupting, var last = entries.popLast() {
            last.interruptedAt = now
            entries.append(last)
        }
        entries.removeAll { entry in
            let gone = entry.interruptedAt.map { now - $0 > 0.4 } ?? (now >= entry.start + entry.timeline.end)
            return gone
        }

        let timeline = LedgerIslandTimeline(isImport: notice.type.isImport)
        let compact = compactWidth(trailingTextWidth: trailingTextWidth)
        entries.append(LedgerIslandStageEntry(notice: notice, start: now, timeline: timeline, row: row, compactWidth: compact))

        retarget(width: row.width, Self.expandWidth, height: expandedHeight, Self.expandHeight, at: now)
        retarget(width: compact, Self.collapseWidth, height: Double(pill.height), Self.collapseHeight,
                 at: now + timeline.compactShapeStart)
        retarget(width: Double(pill.width), Self.retractWidth, height: Double(pill.height), Self.retractHeight,
                 at: now + timeline.pillShapeStart)
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
        width targetWidth: Double, _ widthSpring: (response: Double, damping: Double),
        height targetHeight: Double, _ heightSpring: (response: Double, damping: Double),
        at time: Double
    ) {
        // Reduce Motion keeps the shape change (it is the content's frame) but
        // without any overshoot; the content itself only crossfades.
        let critical = reduceMotion ? 1.0 : nil
        width.retarget(to: targetWidth, at: time, response: min(widthSpring.response, reduceMotion ? 0.3 : .infinity),
                       damping: critical ?? widthSpring.damping)
        height.retarget(to: targetHeight, at: time, response: min(heightSpring.response, reduceMotion ? 0.3 : .infinity),
                        damping: critical ?? heightSpring.damping)
    }
}

enum LedgerIslandAmount {
    /// The compact island stays snug around the camera, so large amounts use
    /// a shorter unit (12,800.00 → "¥1.28万") and whole amounts drop the cents.
    /// It works on minor units: the display string's decimal separator follows
    /// the region ("€150,00"), so parsing it back would scale the value.
    static func compact(minorUnits: Int, currency: String, showSign: Bool = false) -> String {
        let magnitude = MoneyText.magnitude(minorUnits)
        guard magnitude >= 1_000_000 else {
            return MoneyText.format(minorUnits: minorUnits, currency: currency, showSign: showSign,
                                    maximumFractionDigits: magnitude % 100 == 0 ? 0 : nil)
        }
        let chineseUnits = LedgerLocale.usesChineseNumberUnits
        var short = String(format: "%.2f", Double(magnitude) / 100 / (chineseUnits ? 10_000 : 1_000))
        while short.hasSuffix("0") { short.removeLast() }
        if short.hasSuffix(".") { short.removeLast() }
        let sign = minorUnits < 0 ? "-" : showSign ? "+" : ""
        return sign + MoneyText.currencySymbol(for: currency.isEmpty ? "CNY" : currency) + short + (chineseUnits ? "万" : "k")
    }
}
