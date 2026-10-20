import SwiftUI

/// Draw the mark, drop the fold, then settle the wordmark. Skip its optional static hold when
/// authenticated content is ready; loading always runs concurrently.
enum LedgerLaunchTiming {
    static let foldDuration: TimeInterval = 0.5
    static let exitStartsAt: TimeInterval = 0.66
    static let exitDuration: TimeInterval = 0.22
    static let reducedMotionDuration: TimeInterval = 0.16
}

/// Only the foreground presentation clock drives the decorative transition.
/// An interrupted authentication scene restarts it when the app becomes active,
/// instead of consuming the animation behind the system authentication surface.
struct LedgerLaunchView: View {
    let contentReady: Bool
    let onFinished: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var foldFinished = false
    @State private var holdFinished = false
    @State private var fading = false
    @State private var startedAt: Date?

    var body: some View {
        ZStack {
            TerminalPalette.page.ignoresSafeArea()
            // Tick only while the fold is actually moving. Unpaused, the
            // timeline re-rendered 60 times a second for as long as the view
            // stayed up, including behind Face ID while the scene was inactive.
            TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                    paused: reduceMotion || scenePhase != .active || foldFinished)) { timeline in
                let elapsed = startedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                let linear = min(elapsed / LedgerLaunchTiming.foldDuration, 1)
                LedgerLaunchBrand(progress: reduceMotion || scenePhase != .active || foldFinished ? 1 : linear)
            }
        }
        .opacity(fading ? 0 : 1)
        .scaleEffect(fading && !reduceMotion ? 1.04 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                fading = false
                foldFinished = false
                holdFinished = false
                startedAt = Date()
            }
            do {
                if !reduceMotion { try await Task.sleep(for: .seconds(LedgerLaunchTiming.foldDuration)) }
                try Task.checkCancellation()
                foldFinished = true
                if !reduceMotion {
                    try await Task.sleep(for: .seconds(LedgerLaunchTiming.exitStartsAt - LedgerLaunchTiming.foldDuration))
                }
                try Task.checkCancellation()
                holdFinished = true
            } catch { }
        }
        .task(id: canFinish) {
            guard canFinish else { return }
            do {
                let duration = reduceMotion ? LedgerLaunchTiming.reducedMotionDuration : LedgerLaunchTiming.exitDuration
                withAnimation(reduceMotion ? .linear(duration: duration) : .easeIn(duration: duration)) {
                    fading = true
                }
                try await Task.sleep(for: .seconds(duration))
                try Task.checkCancellation()
                onFinished()
            } catch { /* Keep the privacy shield until an active presentation can finish. */ }
        }
    }

    private var canFinish: Bool {
        scenePhase == .active && foldFinished && (reduceMotion || contentReady || holdFinished)
    }
}

/// Shared with the privacy shield so returning from the app switcher never
/// resurrects the previous brand or plays another entrance animation.
/// `progress` is the linear launch clock; each stage eases its own slice so
/// the default of 1 always renders the settled brand.
struct LedgerLaunchBrand: View {
    var progress: CGFloat = 1

    var body: some View {
        let mark = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0, 0.6))
        let title = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0.5, 0.9))
        let rule = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0.65, 1))
        VStack(spacing: 24) {
            LedgerMarkCanvas(progress: progress)
                .frame(width: 96, height: 96)
                .scaleEffect(0.86 + 0.14 * mark)
            VStack(spacing: 10) {
                Text("Ledger")
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TerminalPalette.ink)
                    .opacity(title)
                    .offset(y: 8 * (1 - title))
                Capsule()
                    .fill(TerminalPalette.accent)
                    .frame(width: 28 * rule, height: 2)
                    .frame(width: 28, height: 2)
            }
        }
    }
}

enum LedgerLaunchCurve {
    static func slice(_ value: CGFloat, _ start: CGFloat, _ end: CGFloat) -> CGFloat {
        min(max((value - start) / (end - start), 0), 1)
    }

    static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    /// Back-out with a small overshoot, settling exactly on 1.
    static func backOut(_ t: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.6
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

struct LedgerMarkCanvas: View, @MainActor Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 64
            let origin = CGPoint(x: (size.width - 64 * scale) / 2, y: (size.height - 64 * scale) / 2)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
            }
            var page = Path()
            page.move(to: point(12, 12))
            page.addLine(to: point(36, 12))
            page.addLine(to: point(36, 28))
            page.addLine(to: point(52, 28))
            page.addLine(to: point(52, 52))
            page.addLine(to: point(12, 52))
            page.closeSubpath()
            var cut = Path()
            cut.move(to: point(22, 22))
            cut.addLine(to: point(28, 22))
            cut.addLine(to: point(28, 40))
            cut.addLine(to: point(42, 40))
            cut.addLine(to: point(42, 46))
            cut.addLine(to: point(22, 46))
            cut.closeSubpath()

            let draw = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0, 0.45))
            let fill = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0.3, 0.6))
            let drop = LedgerLaunchCurve.slice(progress, 0.45, 0.85)

            if fill < 1 {
                let stroke = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round, lineJoin: .round)
                context.drawLayer { layer in
                    layer.opacity = 1 - fill
                    layer.stroke(page.trimmedPath(from: 0, to: draw), with: .color(TerminalPalette.ink), style: stroke)
                    layer.stroke(cut.trimmedPath(from: 0, to: draw), with: .color(TerminalPalette.ink), style: stroke)
                }
            }
            page.addPath(cut)
            context.drawLayer { layer in
                layer.opacity = fill
                layer.fill(page, with: .color(TerminalPalette.ink), style: FillStyle(eoFill: true))
            }

            guard drop > 0 else { return }
            let travel = -8 * (1 - LedgerLaunchCurve.backOut(drop))
            var fold = Path()
            fold.move(to: point(40, 12 + travel))
            fold.addLine(to: point(52, 24 + travel))
            fold.addLine(to: point(40, 24 + travel))
            fold.closeSubpath()
            context.opacity = min(drop * 2, 1)
            context.fill(fold, with: .color(TerminalPalette.accent))
        }
    }
}
