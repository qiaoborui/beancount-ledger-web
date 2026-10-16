import Testing
import Foundation
@testable import LedgerMobile

@Suite("LedgerIslandMotionTests")
struct LedgerIslandMotionTests {
    private func notice(_ type: LedgerIslandNoticeType = .expense) -> LedgerIslandNotice {
        LedgerIslandNotice(type: type, title: "Coffee", amountText: "-¥38.00", iconName: "cup.and.saucer.fill", iconColorHex: 0xFF9F0A)
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

        #expect(stage.size(at: 0).width == LedgerIslandStage.pill.width)
        let expanded = stage.size(at: entry.timeline.toCompact)
        #expect(abs(expanded.width - stage.expandedWidth) < 1)
        #expect(abs(expanded.height - stage.expandedHeight) < 1)
        let compacted = stage.size(at: entry.timeline.toPill)
        #expect(abs(compacted.width - compact) < 1)
        #expect(abs(compacted.height - LedgerIslandStage.pill.height) < 1)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - LedgerIslandStage.pill.width) < 0.5)
        #expect(stage.visibleEntries(at: entry.timeline.end + 1).isEmpty)
    }

    @Test("Hardware islands reserve the camera cutout band")
    func cutoutReservation() {
        let plain = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        #expect(plain.contentCenterY == plain.expandedHeight / 2)
        let island = LedgerIslandStage(containerWidth: 393, reduceMotion: false, reservesCutout: true)
        #expect(island.expandedHeight > plain.expandedHeight)
        // A 57pt progress ring around the row centre must clear the 37pt cutout.
        #expect(island.contentCenterY - 28.5 > Double(LedgerIslandStage.pill.height))
        #expect(island.contentCenterY + 28.5 < island.expandedHeight)
    }

    @Test("Expanded width respects narrow screens")
    func expandedWidthFitsContainer() {
        #expect(LedgerIslandStage(containerWidth: 320, reduceMotion: false).expandedWidth == 296)
        #expect(LedgerIslandStage(containerWidth: 440, reduceMotion: false).expandedWidth == LedgerIslandStage.maxExpandedWidth)
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
