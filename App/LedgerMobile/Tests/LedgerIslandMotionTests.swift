import Testing
import Foundation
@testable import LedgerMobile

@Suite("LedgerIslandMotionTests")
struct LedgerIslandMotionTests {
    private func notice(_ type: LedgerIslandNoticeType = .expense) -> LedgerIslandNotice {
        LedgerIslandNotice(type: type, title: "Coffee", amountText: "-¥38.00", iconName: "fork.knife")
    }

    private func row(_ stage: LedgerIslandStage) -> LedgerIslandStage.Layout.Row {
        stage.row(titleWidth: 50, secondaryWidth: 26, amountWidth: 62)
    }

    /// The island is drawn inside `TimelineView(.animation)`, which re-evaluates
    /// at display refresh rate. After the choreography ends nothing changes, so
    /// it must stop requesting frames instead of ticking until the window goes.
    @Test("Frames are requested only while the notice is on screen")
    func frameGating() {
        let entry = LedgerIslandStageEntry(notice: notice(), start: 100,
            timeline: LedgerIslandTimeline(isImport: false), compactWidth: 120)

        #expect(LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false, now: entry.start + 0.5))
        // Reduce Motion still crossfades the card into the compact pill.
        #expect(LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: true, now: entry.start + 0.5))
        #expect(!LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false,
            now: entry.start + entry.timeline.end + 0.01))
        #expect(!LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: true,
            now: entry.start + entry.timeline.end + 0.01))
        #expect(LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: false,
            now: entry.start + entry.timeline.end - 0.01))
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

    @Test("Timeline orders the choreography and holds per kind")
    func timelineOrder() {
        for isImport in [false, true] {
            let t = LedgerIslandTimeline(isImport: isImport)
            let marks = [t.contentIn, t.check, t.toCompact, t.compactShapeStart, t.compactContentIn, t.toPill, t.pillShapeStart, t.end]
            #expect(marks == marks.sorted())
            // Content starts with the shape: no wait for the island to land.
            #expect(t.contentIn <= 0.1)
            #expect(abs(t.toPill - t.toCompact - 1.2) < 1e-9)
        }
        let entry = LedgerIslandTimeline(isImport: false)
        #expect(entry.toCompact == 1.6)
        // Expanded plus compact plus retract: an entry is gone in about 2-3.5 s.
        #expect(entry.end > 2 && entry.end < 3.5)
        #expect(LedgerIslandTimeline(isImport: true).toCompact == 2.2)
        #expect(LedgerIslandNoticeType.batchImport(count: 3).isImport)
        #expect(!LedgerIslandNoticeType.entries(count: 3).isImport)
    }

    @Test("Stage expands, compacts, then retracts to the pill")
    func stageShapeLifecycle() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        let fitted = row(stage)
        stage.present(notice(), row: fitted, trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let compact = stage.compactWidth(trailingTextWidth: 60)

        #expect(stage.size(at: 0).width == stage.pill.width)
        let expanded = stage.size(at: entry.timeline.toCompact)
        #expect(abs(expanded.width - fitted.width) < 1)
        #expect(abs(expanded.height - stage.expandedHeight) < 1)
        let compacted = stage.size(at: entry.timeline.toPill)
        #expect(abs(compacted.width - compact) < 1)
        #expect(abs(compacted.height - stage.pill.height) < 1)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - stage.pill.width) < 0.5)
        #expect(stage.visibleEntries(at: entry.timeline.end + 1).isEmpty)
    }

    /// The covering pills of every island the overlay knows about, plus the
    /// fallback on a screen without one.
    private var islands: [(name: String, screen: Double, pill: CGSize, top: Double)] {
        let base = LedgerIslandCutout.hardware(nativeWidth: 1179, nativeHeight: 2556, nativeScale: 3, safeTop: 59).covering(bleed: 0.75)
        let pro = LedgerIslandCutout.hardware(nativeWidth: 1206, nativeHeight: 2622, nativeScale: 3, safeTop: 62).covering(bleed: 0.75)
        let unknown = LedgerIslandCutout.hardware(nativeWidth: 1320, nativeHeight: 2868, nativeScale: 3, safeTop: 62).covering(bleed: 0.75)
        return [
            ("1179", 393, base.pill, base.top), ("1206", 402, pro.pill, pro.top), ("unknown", 440, unknown.pill, unknown.top),
            ("no hardware", 375, LedgerIslandStage.defaultPill, 8),
        ]
    }

    @Test("The row sits under the camera, concentric with the corner, on any island")
    func expandedRowClearsTheCamera() {
        typealias L = LedgerIslandStage.Layout
        let rows: [(title: Double, secondary: Double?, amount: Double)] = [
            (40, 26, 62),     // short payee, category, everyday amount
            (78, 26, 104),    // income with a five-digit amount
            (400, 26, 62),    // a title that has to truncate
            (90, nil, 54),    // import: bill name and a count
        ]
        for island in islands {
            let stage = LedgerIslandStage(containerWidth: island.screen, reduceMotion: false, pill: island.pill,
                                          pillTop: island.top)
            let band = stage.band
            #expect(abs(band - Double(island.pill.height)) < 0.001)
            // About 84-90pt: the camera band, one row and its padding.
            #expect(stage.expandedHeight >= 84 && stage.expandedHeight <= 90, "height on \(island.name)")

            for parts in rows {
                let row = stage.row(titleWidth: parts.title, secondaryWidth: parts.secondary, amountWidth: parts.amount)
                let shape = CGRect(x: 0, y: 0, width: row.width, height: stage.expandedHeight)
                let camera = stage.cameraRect(width: row.width)
                // The shape's top is the camera's top, centred on it.
                #expect(camera.minY == 0 && abs(camera.midX - row.width / 2) < 0.001)
                // Never wider than the screen less its margins, never narrower
                // than the floor or the cutout.
                #expect(row.width <= island.screen - 2 * LedgerIslandStage.screenMargin + 0.001)
                #expect(row.width >= min(L.minWidth, island.screen - 2 * LedgerIslandStage.screenMargin) - 0.001)
                #expect(row.width > Double(island.pill.width))

                let y = L.rowCenterY(band: band)
                let disc = CGRect(x: L.discCenterX - L.disc / 2, y: y - L.disc / 2, width: L.disc, height: L.disc)
                let textWidth = row.titleWidth + (row.showsSecondary ? L.secondaryGap + (parts.secondary ?? 0) : 0)
                let text = CGRect(x: L.textLeft, y: y - 10, width: textWidth, height: 20)
                let amount = CGRect(x: row.width - L.trailingInset - parts.amount, y: y - 11, width: parts.amount, height: 22)
                for (name, rect) in [("disc", disc), ("text", text), ("amount", amount)] {
                    // Everything sits below the camera band, inside the shape.
                    #expect(rect.minY >= camera.maxY, "\(name) reaches the camera on \(island.name)")
                    #expect(!rect.intersects(camera), "\(name) overlaps the camera on \(island.name)")
                    #expect(shape.insetBy(dx: L.discPadding - 0.01, dy: 0).contains(rect), "\(name) is tight on \(island.name)")
                }
                // Text and amount never collide.
                #expect(text.maxX + L.amountGap <= amount.minX + 0.001, "text meets amount on \(island.name)")
                // The disc is concentric with the bottom-leading corner.
                let radius = LedgerIslandStage.cornerRadius(height: stage.expandedHeight)
                #expect(abs(disc.midX - radius) < 0.001)
                #expect(abs((stage.expandedHeight - disc.midY) - radius) < 0.001)
                #expect(abs(radius - L.disc / 2 - L.discPadding) < 0.001)
            }
        }
        // Expanded corners are rounded rather than a full capsule.
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false)
        #expect(LedgerIslandStage.cornerRadius(height: stage.expandedHeight) < stage.expandedHeight / 2)
        #expect(LedgerIslandStage.cornerRadius(height: 37) == 18.5)
    }

    @Test("The card is only as wide as the row, and drops the label first")
    func rowFitting() {
        typealias L = LedgerIslandStage.Layout
        // A short row stays at the floor, narrower than the screen allows.
        let short = L.row(titleWidth: 40, secondaryWidth: 26, amountWidth: 62, maxWidth: 354)
        #expect(short.width == L.minWidth)
        #expect(short.showsSecondary)
        #expect(short.titleWidth == 40)
        // A longer row grows to fit, label included.
        let longer = L.row(titleWidth: 120, secondaryWidth: 26, amountWidth: 62, maxWidth: 354)
        #expect(longer.width > L.minWidth && longer.width < 354)
        #expect(longer.showsSecondary)
        // Too long for the screen: the label goes and the title truncates.
        let long = L.row(titleWidth: 400, secondaryWidth: 26, amountWidth: 62, maxWidth: 354)
        #expect(long.width == 354)
        #expect(!long.showsSecondary)
        #expect(abs(L.textLeft + long.titleWidth + L.amountGap + 62 + L.trailingInset - 354) < 0.001)
        // A very wide amount never squeezes the title below its floor.
        let wideAmount = L.row(titleWidth: 80, secondaryWidth: nil, amountWidth: 400, maxWidth: 354)
        #expect(wideAmount.titleWidth == L.minTitleWidth)
    }

    @Test("Compact island stays snug, symmetric and clear of the camera")
    func compactIsSnug() {
        typealias C = LedgerIslandStage.CompactLayout
        for island in islands {
            let stage = LedgerIslandStage(containerWidth: island.screen, reduceMotion: false, pill: island.pill,
                                          pillTop: island.top)
            let narrow = stage.compactWidth(trailingTextWidth: 30)
            let wide = stage.compactWidth(trailingTextWidth: 60)
            #expect(narrow < wide)
            #expect(wide - Double(stage.pill.width) < 2 * 90)

            let height = Double(stage.pill.height)
            let camera = CGRect(x: (wide - Double(island.pill.width)) / 2, y: 0, width: Double(island.pill.width), height: height)
            let disc = CGRect(x: height / 2 - C.glyph / 2, y: height / 2 - C.glyph / 2, width: C.glyph, height: C.glyph)
            let amount = CGRect(x: wide - C.trailingInset - C.trailingGap - 60, y: height / 2 - 9, width: 60, height: 18)
            #expect(disc.maxX + C.cameraGap <= camera.minX + 0.001, "disc meets the camera on \(island.name)")
            #expect(amount.minX >= camera.maxX + C.cameraGap - 0.001, "amount meets the camera on \(island.name)")
            #expect(C.trailingGap > 0)
        }
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
        stage.present(notice(), row: row(stage), trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - cover.pill.width) < 0.5)
        #expect(abs(retracted.height - cover.pill.height) < 0.5)
    }

    @Test("The expansion lands without wobbling and the collapse is softer")
    func springTuning() {
        // A hint of overshoot on the width only; the height barely moves past.
        let widthPeak = stride(from: 0.0, through: 1.5, by: 0.005)
            .map { LedgerIslandSpring.progress($0, response: LedgerIslandStage.expandWidth.response,
                                               damping: LedgerIslandStage.expandWidth.damping) }
            .max() ?? 0
        #expect(widthPeak > 1 && widthPeak < 1.05)
        #expect(LedgerIslandStage.collapseWidth.response > LedgerIslandStage.expandWidth.response)
        #expect(LedgerIslandStage.collapseWidth.damping > LedgerIslandStage.expandWidth.damping)

        // Reduce Motion never overshoots.
        var reduced = LedgerIslandStage(containerWidth: 402, reduceMotion: true)
        let fitted = row(reduced)
        reduced.present(notice(), row: fitted, trailingTextWidth: 60, at: 0)
        let widths = stride(from: 0.0, through: 1.5, by: 0.01).map { reduced.size(at: $0).width }
        #expect((widths.max() ?? 0) <= fitted.width + 0.001)
    }

    @Test("A new notice interrupts without jumping the shape")
    func interruptionIsContinuous() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        stage.present(notice(), row: row(stage), trailingTextWidth: 60, at: 0)
        let at = 2.0
        let before = stage.size(at: at)
        let importRow = stage.row(titleWidth: 90, secondaryWidth: 40, amountWidth: 54)
        stage.present(notice(.batchImport(count: 8)), row: importRow, trailingTextWidth: 40, at: at)
        let after = stage.size(at: at)
        #expect(abs(before.width - after.width) < 1e-6)
        #expect(abs(before.height - after.height) < 1e-6)

        #expect(stage.entries.count == 2)
        #expect(stage.entries.first?.interruptedAt == at)
        #expect(stage.current?.timeline.contentIn == 0.08)
        #expect(stage.visibleEntries(at: at + 0.5).count == 1)

        let old = stage.entries[0]
        #expect(old.effect(.expanded, delay: 0, at: at + 0.3, reduceMotion: false).opacity < 0.01)
        // The re-scheduled expansion must win over the first notice's compact step.
        #expect(abs(stage.size(at: at + 1.5).height - stage.expandedHeight) < 1)
        #expect(abs(stage.size(at: at + 1.5).width - importRow.width) < 1)
    }

    @Test("Content enters softly blurred and leaves without a smear")
    func contentEffects() {
        var stage = LedgerIslandStage(containerWidth: 393, reduceMotion: false)
        stage.present(notice(), row: row(stage), trailingTextWidth: 60, at: 0)
        let entry = try! #require(stage.current)
        let start = entry.effect(.expanded, delay: 0, at: entry.timeline.contentIn, reduceMotion: false)
        #expect(start.opacity == 0)
        #expect(start.blur == LedgerIslandStageEntry.maxBlur)
        #expect(LedgerIslandStageEntry.maxBlur <= 3)
        let settled = entry.effect(.expanded, delay: 0, at: 1.2, reduceMotion: false)
        #expect(settled.opacity > 0.99)
        #expect(settled.blur == 0)
        // Leaving: fading, never blurred.
        let leaving = entry.effect(.expanded, delay: 0, at: entry.timeline.toCompact + 0.05, reduceMotion: false)
        #expect(leaving.opacity < settled.opacity && leaving.blur == 0)
        #expect(entry.effect(.expanded, delay: 0, at: entry.timeline.toCompact + 0.3, reduceMotion: false).opacity == 0)
        #expect(entry.effect(.compact, delay: 0, at: 1.2, reduceMotion: false).opacity == 0)

        let reduced = entry.effect(.expanded, delay: 0, at: 0.2, reduceMotion: true)
        #expect(reduced.blur == 0 && reduced.scale == 1 && reduced.yOffset == 0)
        #expect(reduced.opacity > 0)
    }
}
