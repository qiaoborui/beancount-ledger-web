import SwiftUI

/// Preserve the prototype fold and fade. Skip its optional static hold when
/// authenticated content is ready; loading always runs concurrently.
enum LedgerLaunchTiming {
    static let foldDuration: TimeInterval = 0.24
    static let exitStartsAt: TimeInterval = 0.4
    static let exitDuration: TimeInterval = 0.2
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
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let elapsed = startedAt.map { max(0, timeline.date.timeIntervalSince($0)) } ?? 0
                let linear = min(elapsed / LedgerLaunchTiming.foldDuration, 1)
                let eased = 1 - pow(1 - linear, 3)
                LedgerLaunchBrand(progress: reduceMotion || scenePhase != .active ? 1 : eased)
            }
        }
        .opacity(fading ? 0 : 1)
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
struct LedgerLaunchBrand: View {
    var progress: CGFloat = 1

    var body: some View {
        VStack(spacing: 24) {
            LedgerMarkCanvas(progress: progress)
                .frame(width: 96, height: 96)
            Text("Ledger")
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(TerminalPalette.ink)
        }
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
            var page = Path()
            page.move(to: CGPoint(x: origin.x + 12 * scale, y: origin.y + 12 * scale))
            page.addLine(to: CGPoint(x: origin.x + 36 * scale, y: origin.y + 12 * scale))
            page.addLine(to: CGPoint(x: origin.x + 36 * scale, y: origin.y + 28 * scale))
            page.addLine(to: CGPoint(x: origin.x + 52 * scale, y: origin.y + 28 * scale))
            page.addLine(to: CGPoint(x: origin.x + 52 * scale, y: origin.y + 52 * scale))
            page.addLine(to: CGPoint(x: origin.x + 12 * scale, y: origin.y + 52 * scale))
            page.closeSubpath()
            var cut = Path()
            cut.move(to: CGPoint(x: origin.x + 22 * scale, y: origin.y + 22 * scale))
            cut.addLine(to: CGPoint(x: origin.x + 28 * scale, y: origin.y + 22 * scale))
            cut.addLine(to: CGPoint(x: origin.x + 28 * scale, y: origin.y + 40 * scale))
            cut.addLine(to: CGPoint(x: origin.x + 42 * scale, y: origin.y + 40 * scale))
            cut.addLine(to: CGPoint(x: origin.x + 42 * scale, y: origin.y + 46 * scale))
            cut.addLine(to: CGPoint(x: origin.x + 22 * scale, y: origin.y + 46 * scale))
            cut.closeSubpath()
            page.addPath(cut)
            context.fill(page, with: .color(TerminalPalette.ink), style: FillStyle(eoFill: true))

            let travel = -2 * (1 - progress)
            var fold = Path()
            fold.move(to: CGPoint(x: origin.x + 40 * scale, y: origin.y + (12 + travel) * scale))
            fold.addLine(to: CGPoint(x: origin.x + 52 * scale, y: origin.y + (24 + travel) * scale))
            fold.addLine(to: CGPoint(x: origin.x + 40 * scale, y: origin.y + (24 + travel) * scale))
            fold.closeSubpath()
            context.opacity = progress
            context.fill(fold, with: .color(TerminalPalette.accent))
        }
    }
}
