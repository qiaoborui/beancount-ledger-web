import SwiftUI

/// Land 豆豆, then settle the wordmark. Skip its optional static hold when
/// authenticated content is ready; loading always runs concurrently.
enum LedgerLaunchTiming {
    static let foldDuration: TimeInterval = 0.5
    static let exitStartsAt: TimeInterval = 0.66
    static let exitDuration: TimeInterval = 0.22
    static let reducedMotionDuration: TimeInterval = 0.16
    /// The mark's move onto 账本助手's greeting.
    static let handoffDuration: TimeInterval = 0.34
}

/// The launch cover's hand-off to 账本助手: the empty conversation reports
/// where its greeting's mark is, and the cover moves its own mark there
/// before it lifts, so the two read as one mark. Without a greeting on
/// screen (the ledger tabs, the intro before a model is set) the cover
/// leaves as it always did.
@MainActor
enum LedgerLaunchHandoff {
    struct Motion: Equatable {
        var offset: CGSize
        var scale: CGFloat
    }

    /// The greeting's mark in global coordinates, while the empty
    /// conversation is on screen; nil otherwise.
    static var greetingMark: CGRect?

    static func motion(from mark: CGRect?) -> Motion? {
        guard let mark, let target = greetingMark, mark.width > 0, target.width > 0 else { return nil }
        return Motion(offset: CGSize(width: target.midX - mark.midX, height: target.midY - mark.midY),
                      scale: target.width / mark.width)
    }
}

/// Only the foreground presentation clock drives the decorative transition.
/// Behind the system authentication sheet the brand rests fully drawn. When the
/// scene returns it stays settled and leaves at once: replaying the entrance after
/// Face ID redrew the mark from nothing and held the ledger back by the whole fold.
struct LedgerLaunchView: View {
    let contentReady: Bool
    let onFinished: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var foldFinished = false
    @State private var holdFinished = false
    @State private var fading = false
    @State private var startedAt: Date?
    /// Where the brand's mark is on screen, for the hand-off to 账本助手.
    @State private var markFrame: CGRect?
    /// The mark's move onto the greeting's mark, and the title fading, while
    /// the launch lands on 账本助手.
    @State private var handoff: LedgerLaunchHandoff.Motion?

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
                LedgerLaunchBrand(progress: reduceMotion || scenePhase != .active || foldFinished ? 1 : linear,
                                  motion: handoff,
                                  onMarkFrame: { markFrame = $0 })
            }
        }
        .opacity(fading ? 0 : 1)
        // A hand-off moves the mark instead; zooming the whole cover would
        // pull it off the greeting's mark.
        .scaleEffect(fading && !reduceMotion && handoff == nil ? 1.04 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var reset = Transaction()
            reset.disablesAnimations = true
            if startedAt != nil {
                // Interrupted (Face ID, passcode, app switcher): the startup cover
                // below shows the same settled brand until the ledger is ready.
                withTransaction(reset) {
                    foldFinished = true
                    holdFinished = true
                }
                return
            }
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
                // Landing on 账本助手: the mark moves onto the greeting's own
                // mark and shrinks to its size while the title goes, and the
                // cover fades over the second half, so the page is there
                // when it lifts.
                if !reduceMotion, scenePhase == .active, let motion = LedgerLaunchHandoff.motion(from: markFrame) {
                    let duration = LedgerLaunchTiming.handoffDuration
                    withAnimation(.easeInOut(duration: duration)) { handoff = motion }
                    withAnimation(.easeIn(duration: duration / 2).delay(duration / 2)) { fading = true }
                    try await Task.sleep(for: .seconds(duration))
                    try Task.checkCancellation()
                    onFinished()
                    return
                }
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
        // Content that authentication revealed behind its dismissing sheet does
        // not wait for the active scene; the interrupted fold leaves at once.
        if contentReady, scenePhase != .active { return startedAt != nil }
        return scenePhase == .active && foldFinished && (reduceMotion || contentReady || holdFinished)
    }
}

/// Shared with the privacy shield so returning from the app switcher never
/// resurrects the previous brand or plays another entrance animation.
/// `progress` is the linear launch clock; each stage eases its own slice so
/// the default of 1 always renders the settled brand.
struct LedgerLaunchBrand: View {
    var progress: CGFloat = 1
    /// The hand-off to 账本助手's greeting, while it runs.
    var motion: LedgerLaunchHandoff.Motion? = nil
    /// Reports the mark's frame on screen.
    var onMarkFrame: ((CGRect) -> Void)? = nil

    var body: some View {
        let title = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0.5, 0.9))
        let rule = LedgerLaunchCurve.easeOut(LedgerLaunchCurve.slice(progress, 0.65, 1))
        VStack(spacing: 24) {
            // 豆豆 lands: crouch, hop, squash, the sprout springs, a blink.
            // It starts and ends as the storyboard's still picture.
            LedgerMascotEntrance(progress: progress)
                .frame(width: 96, height: 96)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    onMarkFrame?(frame)
                }
                .scaleEffect(motion?.scale ?? 1)
                .offset(motion?.offset ?? .zero)
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
            .opacity(motion == nil ? 1 : 0)
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
