import Testing
import Foundation
@testable import LedgerMobile

@Suite("LedgerIslandMotionTests")
struct LedgerIslandMotionTests {
    private func notice(_ type: LedgerIslandNoticeType = .expense) -> LedgerIslandNotice {
        LedgerIslandNotice(type: type, title: "Coffee", amountText: "-¥38.00", iconName: "cup.and.saucer.fill", iconColorHex: 0xFF9F0A)
    }

    /// The island is drawn inside `TimelineView(.animation)`, which re-evaluates
    /// at display refresh rate. Under Reduce Motion every effect is constant, and
    /// after the choreography ends nothing changes, so both cases must stop
    /// requesting frames instead of ticking for the whole 4-5 s window.
    @Test("Frames are requested only while an effect can still change")
    func frameGating() {
        let entry = LedgerIslandStageEntry(notice: notice(), start: 100,
            timeline: LedgerIslandTimeline(isImport: false, interrupting: false), compactWidth: 120)
        let now = Date.timeIntervalSinceReferenceDate

        // Mid-flight with motion allowed: the island is animating.
        #expect(LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false, now: entry.start + 0.5))
        // Same instant under Reduce Motion: every effect is a constant.
        #expect(!LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: true, now: entry.start + 0.5))
        // Past the end of the choreography: settled, nothing left to animate.
        #expect(!LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false,
            now: entry.start + entry.timeline.end + 0.01))
        // A live entry keeps animating right up to its end.
        #expect(LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false,
            now: entry.start + entry.timeline.end - 0.01))
        _ = now
    }

    @Test("Springs settle on their target")
    func springConverges() {
        for damping in [0.6, 0.82, 1.0] {
            let segment = LedgerIslandSpringSegment(start: 0, from: 0, velocity: 0, target: 100, response: 0.45, damping: damping)
            let settled = segment.sample(at: 3)
            #expect(abs(settled.value - 100) < 0.01)
            #expect(abs(settled.velocity) < 0.1)
        }
        #expect(LedgerIslandSpring.progress(-1, response: 0.4, damping: 0.8) == 0)
    }

    @Test("Under-damped springs overshoot")
    func springOvershoots() {
        let peak = stride(from: 0.0, through: 1.0, by: 0.01)
            .map { LedgerIslandSpring.progress($0, response: 0.38, damping: 0.62) }
            .max() ?? 0
        #expect(peak > 1.05)
    }

    @Test("Retargeting keeps position and velocity continuous")
    func retargetIsContinuous() {
        var track = LedgerIslandSpringTrack(value: 126)
        track.retarget(to: 352, at: 0, response: 0.46, damping: 0.7)
        let before = track.sample(at: 0.15)
        track.retarget(to: 200, at: 0.15, response: 0.42, damping: 0.82)
        let after = track.sample(at: 0.15)
        #expect(abs(before.value - after.value) < 1e-9)
        #expect(abs(before.velocity - after.velocity) < 1e-6)
        #expect(abs(track.value(at: 4) - 200) < 0.01)
    }

    @Test("Retargeting drops segments scheduled later")
    func retargetDropsFutureSegments() {
        var track = LedgerIslandSpringTrack(value: 0)
        track.retarget(to: 10, at: 0, response: 0.4, damping: 1)
        track.retarget(to: 20, at: 2, response: 0.4, damping: 1)
        track.retarget(to: 5, at: 1, response: 0.4, damping: 1)
        #expect(track.segments.count == 3)
        #expect(abs(track.value(at: 5) - 5) < 0.01)
    }

    @Test("Timeline orders the choreography")
    func timelineOrder() {
        for isImport in [false, true] {
            let t = LedgerIslandTimeline(isImport: isImport, interrupting: false)
            let marks = [t.contentIn, t.ringStart, t.ringEnd, t.check, t.toCompact, t.compactShapeStart, t.compactContentIn, t.toPill, t.pillShapeStart, t.end]
            #expect(marks == marks.sorted())
        }
        #expect(LedgerIslandTimeline(isImport: true, interrupting: false).ringEnd > LedgerIslandTimeline(isImport: false, interrupting: false).ringEnd)
    }

    @Test("Stage expands, compacts, then retracts to the pill")
    func stageShapeLifecycle() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        stage.present(notice(), trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let compact = stage.compactWidth(trailingTextWidth: 60)

        #expect(stage.size(at: 0).width == stage.pill.width)
        let expanded = stage.size(at: entry.timeline.toCompact)
        #expect(abs(expanded.width - stage.expandedWidth) < 1)
        #expect(abs(expanded.height - stage.expandedHeight) < 1)
        let compacted = stage.size(at: entry.timeline.toPill)
        #expect(abs(compacted.width - compact) < 1)
        #expect(abs(compacted.height - stage.pill.height) < 1)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - stage.pill.width) < 0.5)
        #expect(stage.visibleEntries(at: entry.timeline.end + 1).isEmpty)
    }

    @Test("Expanded layout wraps the camera like a Live Activity")
    func expandedLayoutWrapsCamera() {
        typealias L = LedgerIslandStage.Layout
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false, pill: CGSize(width: 126.8, height: 38.2))
        let cameraLeft = (stage.expandedWidth - Double(stage.pill.width)) / 2
        // Leading badge (with its 53pt ring) clears the camera and the edges.
        #expect(L.badgeCenter.x + 26.5 < cameraLeft)
        #expect(L.badgeCenter.y - 26.5 > 0)
        #expect(L.badgeCenter.y + 26.5 < stage.expandedHeight)
        // Text rows sit below the camera.
        #expect(L.titleY - 10 > Double(stage.pill.height))
        #expect(L.subtitleY + 8 < stage.expandedHeight)
        #expect(stage.flankWidth > 80)
        // Expanded corners are rounded rather than a full capsule.
        #expect(LedgerIslandStage.cornerRadius(height: stage.expandedHeight) < stage.expandedHeight / 2)
        #expect(LedgerIslandStage.cornerRadius(height: 37) == 18.5)
    }

    @Test("Compact island stays snug and symmetric around the camera")
    func compactIsSnug() {
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false)
        let narrow = stage.compactWidth(trailingTextWidth: 30)
        let wide = stage.compactWidth(trailingTextWidth: 60)
        #expect(narrow < wide)
        #expect(wide - Double(stage.pill.width) < 2 * 90)
        #expect(LedgerIslandAmount.compact("-¥38.00") == "-¥38")
        #expect(LedgerIslandAmount.compact("+¥12,800.00") == "+¥1.28万")
        #expect(LedgerIslandAmount.compact("¥3.50") == "¥3.50")
    }

    @Test("Hardware cutout is located per panel and covered with a bleed")
    func hardwareCutout() {
        // iPhone 16 Pro / 17 Pro: the island starts 14pt down, not 11pt.
        let pro = LedgerIslandCutout.hardware(nativeWidth: 1206, nativeHeight: 2622, nativeScale: 3, safeTop: 62)
        #expect(abs(pro.top - 14) < 0.01)
        #expect(abs(pro.size.width - 376.0 / 3) < 0.01)
        let base = LedgerIslandCutout.hardware(nativeWidth: 1179, nativeHeight: 2556, nativeScale: 3, safeTop: 59)
        #expect(abs(base.top - 34.0 / 3) < 0.01)
        // Display Zoom changes the point scale, not the physical cutout.
        let zoomed = LedgerIslandCutout.hardware(nativeWidth: 1206, nativeHeight: 2622, nativeScale: 3.5, safeTop: 54)
        #expect(abs(zoomed.top - 12) < 0.01)
        let unknown = LedgerIslandCutout.hardware(nativeWidth: 1320, nativeHeight: 2868, nativeScale: 3, safeTop: 62)
        #expect(abs(unknown.top - 14) < 0.01)

        let cover = pro.covering(bleed: 0.75)
        #expect(cover.top < pro.top)
        #expect(cover.top + Double(cover.pill.height) > pro.top + Double(pro.size.height))
        #expect(Double(cover.pill.width) > Double(pro.size.width))

        var stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false, pill: cover.pill)
        stage.present(notice(), trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - cover.pill.width) < 0.5)
        #expect(abs(retracted.height - cover.pill.height) < 0.5)
    }

    @Test("Expanded width follows the screen minus 22pt")
    func expandedWidthFitsContainer() {
        #expect(LedgerIslandStage(containerWidth: 393, reduceMotion: false).expandedWidth == 371)
        #expect(LedgerIslandStage(containerWidth: 430, reduceMotion: false).expandedWidth == 408)
    }

    @Test("A new notice interrupts without jumping the shape")
    func interruptionIsContinuous() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        stage.present(notice(), trailingTextWidth: 60, at: 0)
        let at = 2.45
        let before = stage.size(at: at)
        stage.present(notice(.batchImport(count: 8)), trailingTextWidth: 40, at: at)
        let after = stage.size(at: at)
        #expect(abs(before.width - after.width) < 1e-6)
        #expect(abs(before.height - after.height) < 1e-6)

        #expect(stage.entries.count == 2)
        #expect(stage.entries.first?.interruptedAt == at)
        #expect(stage.current?.timeline.contentIn == 0.1)
        #expect(stage.visibleEntries(at: at + 0.5).count == 1)

        let old = stage.entries[0]
        #expect(old.effect(.expanded, delay: 0, at: at + 0.3, reduceMotion: false).opacity < 0.01)
        // The re-scheduled expansion must win over the first notice's compact step.
        #expect(abs(stage.size(at: at + 1.5).height - stage.expandedHeight) < 1)
    }

    @Test("Content effects enter blurred and leave cleanly")
    func contentEffects() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        stage.present(notice(), trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let start = entry.effect(.expanded, delay: 0, at: entry.timeline.contentIn, reduceMotion: false)
        #expect(start.opacity == 0)
        #expect(start.blur == 10)
        let settled = entry.effect(.expanded, delay: 0, at: 1.5, reduceMotion: false)
        #expect(settled.opacity > 0.99)
        #expect(settled.blur < 0.1)
        #expect(entry.effect(.expanded, delay: 0, at: entry.timeline.toCompact + 0.3, reduceMotion: false).opacity == 0)
        #expect(entry.effect(.compact, delay: 0, at: 1.5, reduceMotion: false).opacity == 0)

        let reduced = entry.effect(.expanded, delay: 0, at: 0.2, reduceMotion: true)
        #expect(reduced.blur == 0 && reduced.scale == 1)
    }
}
