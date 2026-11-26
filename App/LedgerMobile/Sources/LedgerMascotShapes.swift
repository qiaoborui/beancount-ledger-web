import SwiftUI

// 豆豆, 账本助手's character: a Beancount bean with a sprout on its head.
//
// The drawing is the design draft's own geometry
// (docs/design/ios-balanced/mascot/mascots.js, `bean`): one 64-unit square,
// the same path data, so the app, the widgets and the draft agree. This file
// has no app dependencies; the widget extension compiles it too.

/// What the character is doing.
enum LedgerMascotState: String, CaseIterable, Sendable {
    /// Waiting above the greeting: breathes and blinks, the sprout sways.
    case idle
    /// The model is thinking: dots rise, the sprout rocks.
    case thinking
    /// A tool is running: it holds up a magnifier.
    case tool
    /// The answer landed: a hop, a flower opens between the leaves.
    case success
    /// Failed or cut off: wilted leaves, a bead of sweat.
    case error
}

/// The character's own colours. They do not follow the 配色方案; at night the
/// body dims a little and the dark outline keeps its edge on black.
struct LedgerMascotPalette: Equatable, Sendable {
    var line: Color
    var body: Color
    var shade: Color
    var hilum: Color
    var cheek: Color
    var leaf: Color
    var leafDark: Color
    var eye: Color
    var highlight: Color
    var petal: Color
    var lens: Color
    /// Marks floating beside the body (the thinking dots), which sit on the page.
    var aux: Color
    var sweat: Color
    var star: Color
    var bud: Color
    var tongue: Color
    /// One colour: the face, the lens and the notch are cut out of the
    /// silhouette, so a template image or a tinted glyph shows them as holes.
    var isMono = false

    static let light = LedgerMascotPalette(
        line: rgb(0x3B2A1E), body: rgb(0xEFC48E), shade: rgb(0xDDA46A), hilum: rgb(0xF8E2BF),
        cheek: rgb(0xF2A08E), leaf: rgb(0x7FAE6A), leafDark: rgb(0x5F8F4E), eye: rgb(0x2A1D14),
        highlight: .white, petal: rgb(0xF6B7C3), lens: rgb(0x9CC9E6), aux: rgb(0x3B2A1E),
        sweat: rgb(0x9FD0EE), star: rgb(0xF2B84B), bud: rgb(0xF7D36B), tongue: rgb(0xE8877A))

    static let dark = LedgerMascotPalette(
        line: rgb(0x24180F), body: rgb(0xE3B47E), shade: rgb(0xC98F57), hilum: rgb(0xF2D6AE),
        cheek: rgb(0xE58C7A), leaf: rgb(0x86B872), leafDark: rgb(0x5F8F4E), eye: rgb(0x21160E),
        highlight: .white, petal: rgb(0xF0A7B5), lens: rgb(0x8FC0E0), aux: rgb(0xC9BBA8),
        sweat: rgb(0x9FD0EE), star: rgb(0xF2B84B), bud: rgb(0xF7D36B), tongue: rgb(0xE8877A))

    static func mono(_ ink: Color) -> LedgerMascotPalette {
        LedgerMascotPalette(line: ink, body: ink, shade: ink, hilum: ink, cheek: .clear, leaf: ink, leafDark: ink,
                            eye: ink, highlight: .clear, petal: ink, lens: ink, aux: ink, sweat: ink, star: ink,
                            bud: ink, tongue: .clear, isMono: true)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The moving parts at one instant. `rest` is the still drawing; `at` is the
/// loop for a state, `entrance` the launch screen's landing.
struct LedgerMascotPose: Equatable, Sendable {
    /// Eyelids: 0 open, 1 shut.
    var blink: CGFloat = 0
    /// Squash and stretch about the feet (32, 58).
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    /// In grid units.
    var offset: CGSize = .zero
    /// Lean about the feet, in degrees.
    var tilt: Double = 0
    /// The sprout's swing about its root (32, 19), in degrees.
    var sway: Double = 0
    /// The sprout's growth, 0...1.
    var sprout: CGFloat = 1
    /// The magnifier's swing about the hand, in degrees.
    var tool: Double = 0
    /// Each thinking dot's pulse, 0...1.
    var dots: [CGFloat] = [0.75, 0.75, 0.75]
    /// Each sparkle's twinkle, 0...1.
    var sparkles: [CGFloat] = [0.75, 0.75, 0.75]
    /// The flower opening, 0...1.
    var bloom: CGFloat = 1
    /// The sweat drop's slide, 0...1.
    var sweat: CGFloat = 0.5

    static let rest = LedgerMascotPose()

    /// The state's loop, `time` seconds after the state began.
    static func at(_ time: TimeInterval, state: LedgerMascotState) -> LedgerMascotPose {
        var pose = LedgerMascotPose()
        let t = max(0, time)
        func wave(_ period: Double) -> CGFloat { CGFloat((1 - cos(2 * .pi * t / period)) / 2) }
        func phase(_ period: Double, delay: Double = 0) -> Double {
            let x = (t - delay) / period
            return x - floor(x)
        }
        func pulse(_ f: Double) -> CGFloat { CGFloat(max(0, 1 - abs(f - 0.4) / 0.4)) }

        let lid = phase(4.6)
        if lid > 0.92, lid < 0.97 { pose.blink = CGFloat(1 - abs(lid - 0.945) / 0.025) }

        switch state {
        case .idle:
            let w = wave(3.4)
            pose.scaleX = 1 + 0.018 * w
            pose.scaleY = 1 - 0.018 * w
            pose.sway = Double(-4 + 8 * w)
        case .thinking:
            pose.sway = Double(-9 + 18 * wave(1.6))
            pose.tilt = Double(-3 * wave(3.2))
            pose.dots = (0..<3).map { pulse(phase(1.4, delay: Double($0) * 0.18)) }
        case .tool:
            pose.tool = Double(-6 + 14 * wave(1.2))
            pose.offset.height = -0.8 * wave(1.2)
        case .success:
            // One hop, then it stands still and the sparkles keep going.
            let hop = keyframes(CGFloat(t / 1.6), [
                (0, 0, 1, 1), (0.08, 0, 1.06, 0.92), (0.24, -5, 0.97, 1.04), (0.40, 0, 1.04, 0.96), (0.55, 0, 1, 1),
            ])
            pose.offset.height = hop.y
            pose.scaleX = hop.sx
            pose.scaleY = hop.sy
            pose.bloom = min(1, CGFloat(t / 0.4))
            pose.sparkles = (0..<3).map { pulse(phase(1.6, delay: Double($0) * 0.3)) }
            pose.blink = 0
        case .error:
            let f = phase(2.4)
            if f > 0.6, f < 0.76 { pose.offset.width = Int((f - 0.6) / 0.04).isMultiple(of: 2) ? -1 : 1 }
            pose.sweat = CGFloat(f)
        }
        return pose
    }

    /// The launch landing at `progress` (0...1): the storyboard's still frame
    /// crouches, hops, lands with a squash, the sprout springs, it blinks.
    /// Both ends are the still drawing, so the cut from the storyboard and the
    /// hand-off to the greeting do not jump.
    static func entrance(_ progress: CGFloat) -> LedgerMascotPose {
        var pose = LedgerMascotPose()
        let p = min(max(progress, 0), 1)
        let hop = keyframes(p, [
            (0, 0, 1, 1), (0.18, 0, 1.06, 0.93), (0.42, -7, 0.96, 1.05), (0.64, 0, 1.07, 0.92), (0.8, 0, 0.98, 1.02), (1, 0, 1, 1),
        ])
        pose.offset.height = hop.y
        pose.scaleX = hop.sx
        pose.scaleY = hop.sy
        if p > 0.4 { pose.sway = Double(12 * sin(.pi * (p - 0.4) / 0.2) * (1 - p) / 0.6) }
        if p > 0.82, p < 0.98 { pose.blink = 1 - abs(p - 0.9) / 0.08 }
        return pose
    }

    /// Piecewise smooth interpolation over (time, y, scaleX, scaleY) stops;
    /// past the last stop it rests there.
    private static func keyframes(_ t: CGFloat, _ stops: [(CGFloat, CGFloat, CGFloat, CGFloat)])
        -> (y: CGFloat, sx: CGFloat, sy: CGFloat) {
        guard let last = stops.last else { return (0, 1, 1) }
        if t >= last.0 { return (last.1, last.2, last.3) }
        for (a, b) in zip(stops, stops.dropFirst()) where t < b.0 {
            let u = max(0, (t - a.0) / (b.0 - a.0))
            let s = u * u * (3 - 2 * u)
            return (a.1 + (b.1 - a.1) * s, a.2 + (b.2 - a.2) * s, a.3 + (b.3 - a.3) * s)
        }
        return (last.1, last.2, last.3)
    }
}

/// The character drawn once: no clock of its own. `small` is the detail for
/// 16–30pt (no sheen, hilum, leaf veins or flower; heavier lines, bigger eyes).
struct LedgerMascotCanvas: View {
    var state: LedgerMascotState = .idle
    var palette: LedgerMascotPalette = .light
    var small = false
    var pose: LedgerMascotPose = .rest

    var body: some View {
        Group {
            if palette.isMono {
                // The silhouette, then the face punched out of it as a view
                // of its own: a blend mode inside one Canvas did not cut
                // through when rendered to an image (the tab glyph).
                ZStack {
                    canvas(.ink)
                    canvas(.holes).blendMode(.destinationOut)
                }
                .compositingGroup()
            } else {
                canvas(.full)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func canvas(_ pass: LedgerMascotDrawing.Pass) -> some View {
        Canvas { context, size in
            LedgerMascotDrawing(state: state, palette: pass == .holes ? .mono(.clear) : palette, small: small,
                                pose: pose, pass: pass)
                .draw(in: context, size: size)
        }
    }
}

struct LedgerMascotDrawing {
    let state: LedgerMascotState
    let palette: LedgerMascotPalette
    let small: Bool
    let pose: LedgerMascotPose
    var pass: Pass = .full

    /// A one-colour character is drawn twice: the ink without its face,
    /// then only the face, which the canvas view cuts out of the ink.
    enum Pass { case full, ink, holes }

    private static var bodyPath: Path { LedgerMascotPath.parse(
        "M32 18.5C44.5 18.5 51.5 26.5 51.5 37.5C51.5 49.5 43.5 56 32 56C20.5 56 12.5 50 12.5 44C12.5 40.4 15.6 38.8 15.6 35.4C15.6 32.2 13.6 30.4 14.4 27C16.4 21.4 23.5 18.5 32 18.5Z") }
    private static var leafLeft: Path { LedgerMascotPath.parse("M32.6 12.6C29.6 7.4 25.2 6.6 22.6 8.4C24.6 12.4 28.8 13.8 32.6 12.6Z") }
    private static var leafRight: Path { LedgerMascotPath.parse("M32.6 12.6C35.4 6.6 40.6 5.6 43.4 7.6C41 12.2 36.4 13.8 32.6 12.6Z") }
    private static var stem: Path { LedgerMascotPath.parse("M32 19.5C32 16.6 32.4 14.4 32.6 12.6") }

    func draw(in context: GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 64
        var root = context
        root.translateBy(x: (size.width - 64 * scale) / 2, y: (size.height - 64 * scale) / 2)
        root.scaleBy(x: scale, y: scale)
        root.drawLayer { layer in
            var c = layer
            c.translateBy(x: pose.offset.width, y: pose.offset.height)
            Self.about(&c, 32, 58, rotate: pose.tilt, scaleX: pose.scaleX, scaleY: pose.scaleY)
            drawFeet(c)
            drawSprout(c)
            drawBody(c)
            drawFace(c)
            drawProps(c)
        }
    }

    // MARK: Parts

    private var lineWidth: CGFloat { small ? 2.6 : 2 }

    private func drawFeet(_ c: GraphicsContext) {
        for x in [25.5, 38.0] as [CGFloat] {
            let foot = Self.ellipse(x, 56, 4, 2.4)
            c.fill(foot, with: .color(palette.shade))
            c.stroke(foot, with: .color(palette.line), style: Self.round(lineWidth))
        }
    }

    private func drawSprout(_ c: GraphicsContext) {
        var s = c
        Self.about(&s, 32, 19, rotate: (state == .error ? 14 : 0) + pose.sway, scaleX: pose.sprout, scaleY: pose.sprout)
        s.stroke(Self.stem, with: .color(palette.line), style: Self.round(lineWidth + 0.4))
        s.stroke(Self.stem, with: .color(palette.leafDark), style: Self.round(lineWidth - 1))
        let (left, right): (Double, Double) = switch state {
        case .error: (-62, 58)
        case .success: (-8, 8)
        default: (0, 0)
        }
        for (leaf, angle, vein) in [(Self.leafLeft, left, "M31 12.2Q27.5 10.3 25 9.4"),
                                    (Self.leafRight, right, "M34.2 12Q37.8 9.6 41 8.6")] {
            var l = s
            Self.about(&l, 32.6, 12.6, rotate: angle)
            l.fill(leaf, with: .color(palette.leaf))
            l.stroke(leaf, with: .color(palette.line), style: Self.round(lineWidth * 0.85))
            if !small, !palette.isMono {
                l.stroke(LedgerMascotPath.parse(vein), with: .color(palette.leafDark), style: Self.round(0.9))
            }
        }
        if state == .success, !small {
            var b = s
            Self.about(&b, 32.6, 11.2, scaleX: pose.bloom, scaleY: pose.bloom)
            for angle in stride(from: 0.0, to: 360, by: 72) {
                var petal = b
                Self.about(&petal, 32.6, 11.2, rotate: angle)
                let shape = Self.ellipse(32.6, 8.6, 1.7, 2.5)
                petal.fill(shape, with: .color(palette.petal))
                petal.stroke(shape, with: .color(palette.line), style: Self.round(0.8))
            }
            let bud = Self.ellipse(32.6, 11.2, 1.5, 1.5)
            b.fill(bud, with: .color(palette.bud))
            b.stroke(bud, with: .color(palette.line), style: Self.round(0.8))
        }
    }

    private func drawBody(_ c: GraphicsContext) {
        c.fill(Self.bodyPath, with: .color(palette.body))
        if palette.isMono {
            cut(c).stroke(LedgerMascotPath.parse("M16.4 31.6Q18.2 35.2 16.8 38.8"), with: .color(.black), style: Self.round(1.8))
        } else {
            var shade = c
            shade.clip(to: Self.bodyPath)
            shade.opacity = 0.55
            shade.fill(LedgerMascotPath.parse("M10 47C20 55 40 56 54 41V60H10Z"), with: .color(palette.shade))
            if !small {
                var sheen = c
                sheen.opacity = 0.75
                sheen.stroke(LedgerMascotPath.parse("M22.5 24.6C25 22.4 28 21.6 30.6 21.5"), with: .color(.white), style: Self.round(1.8))
                c.stroke(LedgerMascotPath.parse("M17.2 31.4Q18.7 35.2 17.5 38.6"), with: .color(palette.hilum), style: Self.round(2))
            }
        }
        c.stroke(Self.bodyPath, with: .color(palette.line), style: Self.round(lineWidth))
    }

    private func drawFace(_ c: GraphicsContext) {
        if !palette.isMono {
            var cheeks = c
            cheeks.opacity = 0.75
            let r: (CGFloat, CGFloat) = small ? (3.1, 2) : (2.9, 1.7)
            for x in [24.6, 43.4] as [CGFloat] { cheeks.fill(Self.ellipse(x, 42.6, r.0, r.1), with: .color(palette.cheek)) }
        }
        let f = cut(c)
        let eye = palette.isMono ? Color.black : palette.eye
        drawEyes(f, eye: eye, left: 28, right: 38.6, y: 37.4)
        drawMouth(f, ink: eye, cx: 33.3, y: 41.6)
    }

    private func drawEyes(_ f: GraphicsContext, eye: Color, left: CGFloat, right: CGFloat, y: CGFloat) {
        let width: CGFloat = small ? 2.3 : 1.8
        if state == .success {
            for x in [left, right] {
                f.stroke(LedgerMascotPath.parse("M\(x - 2.5) \(y + 1.1)Q\(x) \(y - 2.8) \(x + 2.5) \(y + 1.1)"),
                         with: .color(eye), style: Self.round(width))
            }
            return
        }
        var dx: CGFloat = 0, dy: CGFloat = 0, rx: CGFloat = 2.15, ry: CGFloat = 2.75
        switch state {
        case .thinking: dx = 0.9; dy = -0.9
        case .tool: dx = 0.7; dy = 0.5
        case .error: rx = 1.8; ry = 2.2; dy = 0.4
        default: break
        }
        if small { rx += 0.45; ry += 0.35 }
        let open = max(0.12, 1 - 0.88 * pose.blink)
        for x in [left, right] {
            f.fill(Self.ellipse(x + dx, y + dy, rx, ry * open), with: .color(eye))
            if !small, !palette.isMono, pose.blink < 0.3 {
                f.fill(Self.ellipse(x + dx + 0.75, y + dy - 1.05, 0.8, 0.8), with: .color(palette.highlight))
            }
        }
        if state == .error, !small {
            f.stroke(LedgerMascotPath.parse("M\(left - 2.8) \(y - 4.2)L\(left + 1.6) \(y - 5.8)M\(right + 2.8) \(y - 4.2)L\(right - 1.6) \(y - 5.8)"),
                     with: .color(eye), style: Self.round(1.3))
        }
    }

    private func drawMouth(_ f: GraphicsContext, ink: Color, cx: CGFloat, y: CGFloat) {
        let style = Self.round(small ? 1.9 : 1.4)
        let extras = !small && !palette.isMono
        switch state {
        case .thinking:
            f.stroke(LedgerMascotPath.parse("M\(cx - 1.1) \(y + 0.9)Q\(cx + 0.2) \(y + 0.2) \(cx + 1.4) \(y + 0.5)"), with: .color(ink), style: style)
        case .tool:
            f.stroke(LedgerMascotPath.parse("M\(cx - 1.3) \(y + 0.4)Q\(cx) \(y + 1.3) \(cx + 1.3) \(y + 0.4)"), with: .color(ink), style: style)
            if extras {
                f.fill(LedgerMascotPath.parse("M\(cx + 0.2) \(y + 0.9)Q\(cx + 0.9) \(y + 2.3) \(cx + 1.7) \(y + 1.1)Z"), with: .color(palette.tongue))
            }
        case .success:
            let open = LedgerMascotPath.parse("M\(cx - 2.7) \(y - 0.4)Q\(cx) \(y + 4.2) \(cx + 2.7) \(y - 0.4)Z")
            f.fill(open, with: .color(ink))
            f.stroke(open, with: .color(ink), style: Self.round(0.8))
            if extras {
                f.fill(LedgerMascotPath.parse("M\(cx - 1.3) \(y + 1.75)Q\(cx) \(y + 0.9) \(cx + 1.3) \(y + 1.75)Q\(cx) \(y + 2.9) \(cx - 1.3) \(y + 1.75)Z"),
                       with: .color(palette.tongue))
            }
        case .error:
            f.stroke(LedgerMascotPath.parse(
                "M\(cx - 2.4) \(y + 1.2)Q\(cx - 1.8) \(y + 0.1) \(cx - 1.2) \(y + 1.2)Q\(cx - 0.6) \(y + 2.3) \(cx) \(y + 1.2)"
                    + "Q\(cx + 0.6) \(y + 0.1) \(cx + 1.2) \(y + 1.2)Q\(cx + 1.8) \(y + 2.3) \(cx + 2.4) \(y + 1.2)"),
                with: .color(ink), style: style)
        case .idle:
            f.stroke(LedgerMascotPath.parse("M\(cx - 1.7) \(y)Q\(cx) \(y + 1.9) \(cx + 1.7) \(y)"), with: .color(ink), style: style)
        }
    }

    private func drawProps(_ c: GraphicsContext) {
        switch state {
        case .tool:
            var t = c
            Self.about(&t, 47, 44, rotate: pose.tool)
            t.stroke(LedgerMascotPath.parse("M46.4 43.6L50.6 38.6"), with: .color(palette.line), style: Self.round(small ? 3.6 : 3))
            let lens = Self.ellipse(53.2, 34.8, small ? 5 : 4.8, small ? 5 : 4.8)
            if palette.isMono {
                cut(t).fill(lens, with: .color(.black))
            } else {
                var glass = t
                glass.opacity = 0.45
                glass.fill(lens, with: .color(palette.lens))
            }
            t.stroke(lens, with: .color(palette.line), style: Self.round(lineWidth))
            if !small, !palette.isMono {
                t.stroke(LedgerMascotPath.parse("M50.8 33.4Q51.6 31.6 53.4 31.2"), with: .color(.white), style: Self.round(1.2))
            }
            var hand = t
            Self.about(&hand, 47.6, 44.4, rotate: -35)
            let nub = Self.ellipse(47.6, 44.4, 3.2, 2.5)
            hand.fill(nub, with: .color(palette.body))
            hand.stroke(nub, with: .color(palette.line), style: Self.round(lineWidth))
        case .thinking:
            let dots: [(CGFloat, CGFloat, CGFloat)] = small ? [(50, 17, 2.2), (56, 11, 2.6)]
                : [(48.6, 19.4, 1.4), (52.6, 14.6, 1.9), (57.4, 9.4, 2.5)]
            for (index, dot) in dots.enumerated() {
                let v = pose.dots[min(index, pose.dots.count - 1)]
                var d = c
                d.opacity = Double(0.25 + 0.75 * v)
                let r = dot.2 * (0.8 + 0.3 * v)
                d.fill(Self.ellipse(dot.0, dot.1, r, r), with: .color(palette.aux))
            }
        case .success:
            guard !small else { return }
            let stars: [(CGFloat, CGFloat, CGFloat)] = [(9, 20, 3.2), (55.5, 17, 2.4), (57, 46, 2)]
            for (index, star) in stars.enumerated() {
                let v = pose.sparkles[min(index, pose.sparkles.count - 1)]
                var s = c
                s.opacity = Double(0.4 + 0.6 * v)
                Self.about(&s, star.0, star.1, scaleX: 0.6 + 0.55 * v, scaleY: 0.6 + 0.55 * v)
                s.fill(Self.star(star.0, star.1, star.2), with: .color(palette.star))
            }
        case .error:
            let x: CGFloat = small ? 49 : 48.5, y: CGFloat = small ? 20 : 21.5, k: CGFloat = small ? 1.25 : 1
            let f = pose.sweat
            var d = c
            d.translateBy(x: 0, y: f < 0.8 ? -2 + 5 * f / 0.8 : 3 + (f - 0.8) / 0.2)
            d.opacity = Double(f < 0.2 ? f / 0.2 : (f > 0.8 ? 1 - (f - 0.8) / 0.2 : 1))
            let drop = LedgerMascotPath.parse(
                "M\(x) \(y)C\(x - 1.8 * k) \(y + 2.8 * k) \(x - 1.8 * k) \(y + 4.6 * k) \(x) \(y + 4.6 * k)"
                    + "C\(x + 1.8 * k) \(y + 4.6 * k) \(x + 1.8 * k) \(y + 2.8 * k) \(x) \(y)Z")
            d.fill(drop, with: .color(palette.sweat))
            d.stroke(drop, with: .color(palette.line), style: Self.round(0.9))
        case .idle:
            break
        }
    }

    // MARK: Helpers

    /// The face's context: drawn in ink, left out of the one-colour ink
    /// pass, and the only thing the holes pass shows.
    private func cut(_ c: GraphicsContext) -> GraphicsContext {
        var f = c
        if pass == .ink { f.opacity = 0 }
        return f
    }

    private static func about(_ c: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat,
                              rotate degrees: Double = 0, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        guard degrees != 0 || scaleX != 1 || scaleY != 1 else { return }
        c.translateBy(x: x, y: y)
        if degrees != 0 { c.rotate(by: .degrees(degrees)) }
        if scaleX != 1 || scaleY != 1 { c.scaleBy(x: scaleX, y: scaleY) }
        c.translateBy(x: -x, y: -y)
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
    }

    private static func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        let k = r * 0.28
        return LedgerMascotPath.parse(
            "M\(x) \(y - r)Q\(x + k) \(y - k) \(x + r) \(y)Q\(x + k) \(y + k) \(x) \(y + r)"
                + "Q\(x - k) \(y + k) \(x - r) \(y)Q\(x - k) \(y - k) \(x) \(y - r)Z")
    }

    private static func round(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// Absolute SVG path data (M L H V C Q Z), so the draft's paths are used as
/// written.
enum LedgerMascotPath {
    static func parse(_ data: String) -> Path {
        var tokens: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { tokens.append(number) }
            number = ""
        }
        for character in data {
            if character.isLetter {
                flush()
                tokens.append(String(character))
            } else if character == "-" {
                flush()
                number = "-"
            } else if character == "." {
                if number.contains(".") { flush() }
                number.append(character)
            } else if character.isNumber {
                number.append(character)
            } else {
                flush()
            }
        }
        flush()

        var path = Path()
        var index = 0
        var command = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        func value() -> CGFloat {
            defer { index += 1 }
            guard index < tokens.count, let number = Double(tokens[index]) else { return 0 }
            return CGFloat(number)
        }
        func point() -> CGPoint { CGPoint(x: value(), y: value()) }
        while index < tokens.count {
            if let first = tokens[index].first, first.isLetter {
                command = tokens[index]
                index += 1
            }
            switch command {
            case "M":
                current = point()
                start = current
                path.move(to: current)
                command = "L"
            case "L":
                current = point()
                path.addLine(to: current)
            case "H":
                current = CGPoint(x: value(), y: current.y)
                path.addLine(to: current)
            case "V":
                current = CGPoint(x: current.x, y: value())
                path.addLine(to: current)
            case "C":
                let c1 = point(), c2 = point()
                current = point()
                path.addCurve(to: current, control1: c1, control2: c2)
            case "Q":
                let control = point()
                current = point()
                path.addQuadCurve(to: current, control: control)
            case "Z", "z":
                path.closeSubpath()
                current = start
            default:
                index += 1
            }
        }
        return path
    }
}
