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
        #expect(abs(expanded.height - stage.settledHeight(rows: .init(titleLines: 1))) < 1)
        let compacted = stage.size(at: entry.timeline.toPill)
        #expect(abs(compacted.width - compact) < 1)
        #expect(abs(compacted.height - stage.pill.height) < 1)
        let retracted = stage.size(at: entry.timeline.end + 1)
        #expect(abs(retracted.width - stage.pill.width) < 0.5)
        #expect(stage.visibleEntries(at: entry.timeline.end + 1).isEmpty)
    }

    /// Content rectangles of the settled island, derived from the same layout
    /// the view uses. The badge rect includes the check's ripple.
    private func contentRects(_ stage: LedgerIslandStage, rows: LedgerIslandStage.Layout.TextRows) -> [String: CGRect] {
        typealias L = LedgerIslandStage.Layout
        let band = stage.band
        let mid = L.bandCenterY(band: band)
        let right = stage.expandedWidth - L.inset
        let flank = stage.flankWidth
        let text = LedgerIslandTextLayout.columnWidth(stage: stage)
        let ripple = L.ring + 12
        let badgeY = L.badgeCenterY(band: band, rows: rows)
        let titleHeight = Double(rows.titleLines) * LedgerIslandFonts.titleLineHeight
        return [
            "caption": CGRect(x: L.inset, y: mid - 8, width: flank, height: 16),
            "amount": CGRect(x: right - flank, y: mid - 12, width: flank, height: 24),
            "badge": CGRect(x: L.badgeCenterX - ripple / 2, y: badgeY - ripple / 2, width: ripple, height: ripple),
            "title": CGRect(x: L.textLeft, y: L.titleCenterY(band: band, rows: rows) - titleHeight / 2,
                            width: text, height: titleHeight),
            "subtitle": CGRect(x: L.textLeft, y: L.subtitleCenterY(band: band, rows: rows) - 8, width: text, height: 16),
        ]
    }

    @Test("No expanded content touches the camera, on any island")
    func expandedContentClearsTheCamera() {
        typealias L = LedgerIslandStage.Layout
        let base = LedgerIslandCutout.hardware(nativeWidth: 1179, nativeHeight: 2556, nativeScale: 3, safeTop: 59).covering(bleed: 0.75)
        let pro = LedgerIslandCutout.hardware(nativeWidth: 1206, nativeHeight: 2622, nativeScale: 3, safeTop: 62).covering(bleed: 0.75)
        let unknown = LedgerIslandCutout.hardware(nativeWidth: 1320, nativeHeight: 2868, nativeScale: 3, safeTop: 62).covering(bleed: 0.75)
        let islands: [(screen: Double, pill: CGSize, top: Double)] = [
            (393, base.pill, base.top), (402, pro.pill, pro.top), (440, unknown.pill, unknown.top),
            (375, LedgerIslandStage.defaultPill, 8),
        ]
        for island in islands {
            let stage = LedgerIslandStage(containerWidth: island.screen, reduceMotion: false, pill: island.pill,
                pillTop: island.top,
                flank: LedgerIslandStage.flank(screenWidth: island.screen, cutoutWidth: Double(island.pill.width)))
            let camera = stage.cameraRect
            // The camera spans the band at the top centre of the island.
            #expect(camera.minY == 0 && abs(camera.height - Double(island.pill.height)) < 0.001)
            #expect(abs(camera.midX - stage.expandedWidth / 2) < 0.001)
            // The island spans the screen less its margins, leaving each
            // flank room for the caption and the amount.
            #expect(abs(stage.expandedWidth - (island.screen - 2 * LedgerIslandStage.screenMargin)) < 0.01)
            #expect(stage.flankWidth >= 60)
            let keepOut = camera.insetBy(dx: -L.cameraGap + 0.01, dy: 0)
            for lines in [1, 2] {
                let rows = L.TextRows(titleLines: lines)
                let height = stage.settledHeight(rows: rows)
                let shape = CGRect(x: 0, y: 0, width: stage.expandedWidth, height: height)
                for (name, rect) in contentRects(stage, rows: rows) {
                    #expect(!rect.intersects(keepOut), "\(name) overlaps the camera on \(island.pill)")
                    #expect(shape.insetBy(dx: 12, dy: 2).contains(rect), "\(name) leaves the island on \(island.pill)")
                }
                // Body rows start below the camera.
                let rects = contentRects(stage, rows: rows)
                for name in ["badge", "title", "subtitle"] {
                    #expect(rects[name]!.minY > camera.maxY, "\(name) rides beside the camera")
                }
                // Caption and amount sit on the camera's centre line.
                #expect(abs(rects["amount"]!.midY - camera.midY) < 0.001)
                #expect(abs(rects["caption"]!.midY - camera.midY) < 0.001)
                // The ring stays inside the rounded bottom-leading corner.
                let radius = LedgerIslandStage.cornerRadius(height: height)
                let corner = CGPoint(x: radius, y: height - radius)
                let ringCentre = CGPoint(x: L.badgeCenterX, y: L.badgeCenterY(band: stage.band, rows: rows))
                let reach = hypot(max(0, corner.x - ringCentre.x), max(0, ringCentre.y - corner.y)) + L.ring / 2
                #expect(reach <= radius - 4)
            }
        }
        // Expanded corners are rounded rather than a full capsule.
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false)
        let height = stage.settledHeight(rows: .init(titleLines: 1))
        #expect(LedgerIslandStage.cornerRadius(height: height) < height / 2)
        #expect(LedgerIslandStage.cornerRadius(height: 37) == 18.5)
    }

    @Test("Long titles take a second line instead of truncating")
    func longTitleGrowsTheTextColumn() {
        typealias L = LedgerIslandStage.Layout
        // English fits per glyph, not per CJK character: a short Latin name
        // stays on one line even in a narrow column.
        let latin = LedgerIslandTextLayout(title: "Synthetic context action", totalWidth: 128)
        #expect(latin.rows.titleLines == 2)
        let short = LedgerIslandTextLayout(title: "Coffee", totalWidth: 128)
        #expect(short.rows.titleLines == 1)
        // A CJK title that fits on one line does not wrap.
        let cjk = LedgerIslandTextLayout(title: "楼下便利店", totalWidth: 128)
        #expect(cjk.rows.titleLines == 1)
        // A second title line makes the settled shape taller, by the
        // difference between the text block and the ring.
        let one = L.TextRows(titleLines: 1)
        let two = L.TextRows(titleLines: 2)
        #expect(L.expandedHeight(band: 37, rows: one) == 37 + L.bodyGap + L.ring + L.bottomMargin)
        #expect(L.expandedHeight(band: 37, rows: two) > L.expandedHeight(band: 37, rows: one))
        #expect(L.subtitleCenterY(band: 37, rows: two) > L.titleCenterY(band: 37, rows: two))
        // A one-line text block is centred on the badge.
        let block = (L.titleCenterY(band: 37, rows: one) - LedgerIslandFonts.titleLineHeight / 2
            + L.subtitleCenterY(band: 37, rows: one) + LedgerIslandFonts.subtitleLineHeight / 2) / 2
        #expect(abs(block - L.badgeCenterY(band: 37, rows: one)) < 0.001)
    }

    @Test("The shape lands before content arrives, and interruptions keep moving")
    func preludeAndContentPhase() {
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false, pill: CGSize(width: 125.8, height: 37.2))
        let rows = LedgerIslandStage.Layout.TextRows(titleLines: 1)
        let pill = stage.size(at: 0)
        #expect(abs(pill.width - Double(stage.pill.width)) < 0.01)
        let wait = stage.preludeDelay(rows: rows, at: 0)
        #expect(wait > 0.05 && wait < 0.6)
        // A shape already on its way starts its notice immediately.
        var moving = stage
        moving.grow(to: rows, at: 0)
        #expect(moving.preludeDelay(rows: rows, at: 0.15) == 0)

        // Content enters later when the shape has further to travel.
        func entry(compactWidth: Double) -> LedgerIslandStageEntry {
            LedgerIslandStageEntry(notice: notice(), start: 0,
                timeline: LedgerIslandTimeline(isImport: false, interrupting: false), compactWidth: compactWidth)
        }
        let farther = LedgerIslandFrameGate.contentIn(entry: entry(compactWidth: 150), expandedWidth: 354)
        let close = LedgerIslandFrameGate.contentIn(entry: entry(compactWidth: 345), expandedWidth: 354)
        #expect(close == entry(compactWidth: 345).timeline.contentIn)
        #expect(farther > close)
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

    @Test("The island is sized around the camera, not the screen or the pill")
    func expandedWidthWrapsTheCamera() {
        // A little more breathing room than a Live Activity's 22pt.
        #expect(LedgerIslandStage.screenMargin > 22)
        // The amount keeps the same margins whether the cutout is a measured
        // 125.3pt band or a narrower one: the island grows to make room.
        let inset = LedgerIslandStage.Layout.inset + LedgerIslandStage.Layout.cameraGap
        let wide = LedgerIslandStage(containerWidth: 402, reduceMotion: false,
                                     pill: CGSize(width: 125.3, height: 36.7), flank: 36)
        #expect(abs(wide.expandedWidth - (125.3 + 2 * 36)) < 0.01)
        #expect(abs(wide.flankWidth - (36 - inset)) < 0.01)
        let narrow = LedgerIslandStage(containerWidth: 402, reduceMotion: false,
                                       pill: CGSize(width: 112, height: 36.7), flank: 43.3)
        #expect(abs(narrow.flankWidth - (43.3 - inset)) < 0.01)
        // The screen only bounds it, so it never runs under the bezel.
        let cramped = LedgerIslandStage(containerWidth: 393, reduceMotion: false,
                                        pill: CGSize(width: 126, height: 37), flank: 133.5)
        #expect(cramped.expandedWidth == 393 - 2 * LedgerIslandStage.screenMargin)
        // Never narrower than the cutout it grows out of.
        #expect(narrow.expandedWidth > Double(narrow.pill.width))
    }

    @Test("The camera band follows the cutout, not the live shape")
    func expandedRowsAnchorOnTheCamera() {
        typealias L = LedgerIslandStage.Layout
        // The shape's top is the camera's top, so the band is the covering
        // pill's height wherever the cutout sits on the screen.
        let idle = LedgerIslandStage(containerWidth: 402, reduceMotion: false,
                                     pill: CGSize(width: 125.3, height: 36.7), pillTop: 13.25, flank: 102)
        #expect(abs(idle.band - 36.7) < 0.001)
        #expect(abs(L.bandCenterY(band: idle.band) - 36.7 / 2) < 0.001)
        #expect(L.bodyTop(band: idle.band) > idle.cameraRect.maxY)
        // The text column spans the island under the camera, not beside it.
        #expect(abs(LedgerIslandTextLayout.columnWidth(stage: idle) - (idle.expandedWidth - L.inset - L.textLeft)) < 0.001)
        let title = LedgerIslandTextLayout(title: "Synthetic context action",
                                           totalWidth: LedgerIslandTextLayout.columnWidth(stage: idle))
        #expect(title.rows.titleLines == 1)
    }

    @Test("Long titles fold at words and keep the camera band clear")
    func titleFoldsAtWords() {
        // "Synthetic context action" fits two lines at full size in the column
        // between the badge and the camera; it must not be cut mid-word.
        let layout = LedgerIslandTextLayout(title: "Synthetic context action", totalWidth: 128)
        #expect(layout.rows.titleLines == 2)
        #expect(layout.scale == 1)
        // Latin words fold between words; the folded lines never exceed the
        // column one line of CJK would occupy.
        let lines = LedgerIslandFonts.foldedLines("Synthetic context action", size: 16, weight: .semibold,
                                                  count: 2, width: 128)
        #expect(lines.count <= 2)
        #expect(lines.allSatisfy { !$0.hasSuffix(" ") })
        // No folded line reaches past the column.
        #expect(lines.allSatisfy {
            LedgerIslandFonts.width($0, size: 16, weight: .semibold) <= 128
        })
    }

    @Test("Compact amount stays clear of the end cap")
    func compactTrailingKeepsGap() {
        let stage = LedgerIslandStage(containerWidth: 402, reduceMotion: false, pill: CGSize(width: 125.5, height: 37.25))
        let textWidth = 60.0
        // Re-derive the amount's right edge from the same layout constants the
        // view uses, and require a gap to where the end cap starts to curve.
        typealias C = LedgerIslandStage.CompactLayout
        let width = stage.compactWidth(trailingTextWidth: textWidth)
        // The view right-aligns the amount this many points inside the end cap.
        let rightInset = C.trailingInset + C.trailingGap
        let amountHalfWidth = (textWidth + 4) / 2
        #expect(C.trailingGap > 0)
        #expect(width / 2 - rightInset - amountHalfWidth > Double(stage.pill.width) / 2)
        #expect(width > Double(stage.pill.width))
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
        #expect(abs(stage.size(at: at + 1.5).height - stage.settledHeight(rows: .init(titleLines: 1))) < 1)
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
