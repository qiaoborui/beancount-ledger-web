import SwiftUI
import UIKit

/// 灵动岛入账反馈：从硬件岛长出 → 展开确认 → 紧凑态 → 收回。
/// 每一帧都是时间的纯函数（见 `LedgerIslandStage`），由 `TimelineView` 驱动，
/// 不依赖 `withAnimation` 链，因此新通知可以在任意时刻打断并保留形状速度。
/// 展开态离屏幕两边 24pt，内容在圆角内留出边距，前后内容分列摄像头两侧，
/// 其余内容放在摄像头下方；紧凑态紧贴摄像头；
/// 背景保持纯黑，深色模式用着色描边（keyline）而非阴影。
/// 一条通知只用一个色相：徽章里的图标、进度环和对勾共用一个强调色，类别色
/// 只给图标染色。导入因此从“写入中”到“已入库”是同一个绿色动作，而不是紫色
/// 图标配绿色对勾的两种颜色。
struct LedgerIslandStyle {
    let tint: Color
    let accent: Color
    let amountColor: Color
    let pendingSubtitle: String?
    let count: Int?
    let trailingText: String
    /// The ring / check badge is tinted with the same accent, so the icon's
    /// category colour never sits inside a differently coloured glyph.
    let badgeIconColor: Color

    init(_ notice: LedgerIslandNotice) {
        let blue = Color(uiColor: UIColor(hex: 0x0A84FF))
        let green = Color(uiColor: UIColor(hex: 0x30D158))
        switch notice.type {
        case .expense:
            tint = Color(uiColor: UIColor(hex: 0xFF9F0A)); accent = blue
            amountColor = .white
            pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .income:
            tint = green; accent = green
            amountColor = green
            pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .transfer:
            let cyan = Color(uiColor: UIColor(hex: 0x64D2FF))
            tint = cyan; accent = blue
            amountColor = cyan
            pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .batchImport(let total):
            tint = green; accent = green
            amountColor = .white
            pendingSubtitle = String(localized: "正在写入账本…"); count = total
            trailingText = String(localized: "\(total) 笔")
        }
        // Expense and transfer keep their category tint on the icon so the
        // confirmation stays legible against the blue check bloom; transfers
        // are cyan next to a blue check, imports are green on both.
        if case .batchImport = notice.type {
            badgeIconColor = accent
        } else {
            badgeIconColor = tint
        }
    }
}

extension LedgerIslandFonts {
    /// Width of the amount column: the count for imports, the compact amount
    /// otherwise. `笔` is the localized counter used in the compact island.
    static func amountWidth(_ notice: LedgerIslandNotice, style: LedgerIslandStyle) -> Double {
        if let count = style.count {
            return width(String(count), size: 20, weight: .bold, rounded: true) + width(String(localized: " 笔"), size: 13, weight: .semibold)
        }
        return width(notice.amountText, size: 20, weight: .bold, rounded: true)
    }
}

/// Style and text measurements resolved once per notice; the island redraws
/// every frame, and measuring with UIKit fonts there is what made it stutter.
struct LedgerIslandEntryMetrics {
    let style: LedgerIslandStyle
    let amountWidth: Double
    let trailingWidth: Double

    init(_ notice: LedgerIslandNotice) {
        style = LedgerIslandStyle(notice)
        amountWidth = LedgerIslandFonts.amountWidth(notice, style: style)
        trailingWidth = LedgerIslandFonts.width(style.trailingText, size: 14, weight: .semibold, rounded: true)
    }
}

@MainActor
final class LedgerIslandPresenter: ObservableObject {
    @Published private(set) var stage: LedgerIslandStage?
    @Published private(set) var hidesStatusBar = false
    private(set) var metrics: [LedgerIslandNotice.ID: LedgerIslandEntryMetrics] = [:]
    var onFinished: (() -> Void)?

    private var hapticTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    /// Second key for the stage. The prelude (island growing out of the camera
    /// before its content arrives) changes only the stage value, never its
    /// published properties, so a change post is scheduled explicitly.
    @Published fileprivate(set) var stagePulse = 0
    private var pulseTask: Task<Void, Never>?

    var displayedStage: LedgerIslandStage? { stage }

    /// Advances the stage without presenting a notice, so the island can settle
    /// into its expanded size before its content fades in.
    func prelude(_ notice: LedgerIslandNotice, containerWidth: Double, reduceMotion: Bool, pill: CGSize,
                 pillTop: Double = 0, flank: Double? = nil) {
        let now = Date.timeIntervalSinceReferenceDate
        var next = stage.flatMap { $0.visibleEntries(at: now).isEmpty ? nil : $0 }
            ?? LedgerIslandStage(containerWidth: containerWidth, reduceMotion: reduceMotion, pill: pill,
                                 pillTop: pillTop, flank: flank)
        let rows = LedgerIslandTextLayout.rows(for: notice, stage: next)
        // A shape still on its way receives its next instruction when the
        // notice is presented; a resting pill starts moving toward the
        // expanded size here, ahead of the content.
        let resting = next.size(at: now)
        let atRest = abs(resting.width - Double(pill.width)) < 2 && abs(resting.height - Double(pill.height)) < 2
        guard atRest else { return }
        next.grow(to: rows, at: now)
        stage = next
        stagePulse &+= 1
    }

    var isActive: Bool { stage?.current != nil }

    /// True only while an effect still changes with time. Once every entry has
    /// settled the timeline can stop; a `TimelineView(.animation)` that stays
    /// unpaused re-evaluates the island at display refresh rate for nothing.
    var needsFrames: Bool {
        guard let stage, let entry = stage.current else { return false }
        return LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: stage.reduceMotion,
            now: Date.timeIntervalSinceReferenceDate)
    }

    func present(_ notice: LedgerIslandNotice, containerWidth: Double, reduceMotion: Bool, pill: CGSize,
                 pillTop: Double = 0, flank: Double? = nil) {
        let now = Date.timeIntervalSinceReferenceDate
        // Only a mid-flight stage is kept, so its springs carry their velocity.
        var next = stage.flatMap { $0.visibleEntries(at: now).isEmpty ? nil : $0 }
            ?? LedgerIslandStage(containerWidth: containerWidth, reduceMotion: reduceMotion, pill: pill,
                                 pillTop: pillTop, flank: flank)
        let entryMetrics = LedgerIslandEntryMetrics(notice)
        // The settled height depends on whether the title needs two lines.
        let rows = LedgerIslandTextLayout.rows(for: notice, stage: next)
        // If the prelude did not run, the shape has to travel before content
        // appears; the notice then starts at the top of the expansion instead
        // of posing the island at its full size for a moment.
        let wait = next.preludeDelay(rows: rows, at: now)
        next.present(notice, trailingTextWidth: entryMetrics.trailingWidth, rows: rows, at: now + wait)
        let live = Set(next.entries.map(\.notice.id))
        metrics = metrics.filter { live.contains($0.key) }
        metrics[notice.id] = entryMetrics
        stage = next

        guard let entry = next.current else { return }
        setStatusBarHidden(true)

        hapticTask?.cancel()
        hapticTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(entry.timeline.check))
            guard !Task.isCancelled else { return }
            LedgerFeedback.success()
        }
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(entry.timeline.pillShapeStart))
            guard !Task.isCancelled else { return }
            self?.setStatusBarHidden(false)
        }
        pulseTask?.cancel()
        // Wake the timeline when the content phase starts, whatever the stage
        // value did in between.
        pulseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(next.contentIn(entry: entry)))
            guard !Task.isCancelled else { return }
            self?.stagePulse &+= 1
        }
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(entry.timeline.end + 0.05))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func setStatusBarHidden(_ hidden: Bool) {
        guard hidesStatusBar != hidden else { return }
        // The system draws the status bar above every app window, so it must be
        // gone before the island grows over it; only its return is animated.
        if hidden {
            hidesStatusBar = true
        } else {
            withAnimation(.easeOut(duration: 0.2)) { hidesStatusBar = false }
        }
    }

    private func finish() {
        pulseTask?.cancel()
        stage = nil
        metrics = [:]
        setStatusBarHidden(false)
        onFinished?()
    }
}

struct LedgerIslandStageView: View {
    @ObservedObject var presenter: LedgerIslandPresenter
    let hasHardwareIsland: Bool
    let topOffset: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !presenter.needsFrames)) { context in
            let _ = presenter.stagePulse
            if let stage = presenter.displayedStage {
                island(stage, now: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private func island(_ stage: LedgerIslandStage, now: Double) -> some View {
        let size = stage.size(at: now)
        let pill = stage.pill
        let growth = LedgerIslandEasing.clamp(Double((size.width - pill.width) / 30))
        // Without a hardware island there is nothing to grow out of, so fade in.
        let appear = hasHardwareIsland ? 1 : growth
        let entries = stage.visibleEntries(at: now)
        let shape = RoundedRectangle(cornerRadius: LedgerIslandStage.cornerRadius(height: size.height), style: .continuous)
        // Dark mode outlines the island with a tinted key line; it never casts a
        // shadow, and it stays pure black so the camera disappears into it.
        let keyline = colorScheme == .dark
            ? stage.current.flatMap { presenter.metrics[$0.notice.id]?.style.tint }
            : nil

        return ZStack {
            ForEach(entries, id: \.notice.id) { entry in
                if let metrics = presenter.metrics[entry.notice.id] {
                    LedgerIslandExpandedContent(entry: entry, metrics: metrics, stage: stage, size: size, now: now)
                    LedgerIslandCompactContent(entry: entry, metrics: metrics, stage: stage, size: size, now: now)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .background(shape.fill(Color.black))
        .overlay {
            if let keyline {
                shape.strokeBorder(keyline.opacity(0.45 * growth), lineWidth: 1)
            }
        }
        .opacity(appear)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ledger-dynamic-island-notice")
        .accessibilityLabel(stage.current.map { "\($0.notice.title), \($0.notice.amountText)" } ?? "")
        .padding(.top, topOffset)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private extension View {
    /// `.islandPlaced` positions an element's own centre, but a view that
    /// stretches to its slot (a centre-aligned block inside the island stack)
    /// has its drawing at the slot's centre. Scaling about the view's centre
    /// keeps the size and has no visual effect; it only makes the view's own
    /// centre the point the island places.
    func centredBeforePlacement() -> some View {
        scaleEffect(1.0)
    }

    /// Places an element on the island with its enter/exit effect. The effect
    /// runs at the element's own size (blurring a full island-sized layer per
    /// element was expensive), while scale still pivots on the island centre so
    /// content emerges from inside the shape. Fully hidden elements are skipped.
    @ViewBuilder
    func islandPlaced(_ effect: LedgerIslandEffect, at point: CGPoint, in size: CGSize) -> some View {
        if effect.opacity > 0.001 {
            let cx = size.width / 2, cy = size.height / 2
            // The content stack gives every row the island's height and centres
            // it, so a row's own centre is the island centre plus
            // `point - islandCentre`. `position` then wants that offset from
            // the island centre, which is exactly this.
            scaleEffect(effect.scale)
                .blur(radius: effect.blur)
                .opacity(effect.opacity)
                .position(
                    x: cx + (point.x - cx) * effect.scale,
                    y: cy + (point.y - cy) * effect.scale + effect.yOffset
                )
        }
    }
}

private struct LedgerIslandExpandedContent: View {
    let entry: LedgerIslandStageEntry
    let metrics: LedgerIslandEntryMetrics
    let stage: LedgerIslandStage
    let size: CGSize
    let now: Double

    private typealias L = LedgerIslandStage.Layout

    /// The amount needs a little slack: per-glyph rolling columns lose kerning.
    private var amountWidth: Double { metrics.amountWidth + 4 }

    private var textWidth: Double { LedgerIslandTextLayout.columnWidth(stage: stage) }

    private var layout: LedgerIslandTextLayout {
        LedgerIslandTextLayout(title: entry.notice.title, totalWidth: textWidth)
    }

    /// Text rows live in final-size coordinates and are mapped onto the live
    /// shape (top-anchored, centred), so text never reflows while it grows.
    /// Vertically they map into the part of the shape below the camera band,
    /// so even a shape that is still short never pulls them up beside the
    /// camera. The horizontal mapping applies to anchor points only.
    private func bodyPoint(_ x: Double, _ y: Double) -> CGPoint {
        let band = stage.band
        let full = stage.settledHeight(rows: layout.rows)
        let live = max(0, Double(size.height) - band)
        return CGPoint(x: mapX(x), y: band + (y - band) * live / max(1, full - band))
    }

    private func mapX(_ x: Double) -> Double {
        let fullWidth = stage.expandedWidth
        return size.width / 2 + (x - fullWidth / 2) * size.width / fullWidth
    }

    /// Flank elements are anchored to the camera, not to the live shape: they
    /// keep their final distance from the cutout and the growing shape reveals
    /// them (the island clips its content), so no frame slides them under it.
    private func flankPoint(_ x: Double) -> CGPoint {
        CGPoint(x: size.width / 2 + (x - stage.expandedWidth / 2), y: L.flankY(band: stage.band))
    }

    var body: some View {
        let notice = entry.notice
        let style = metrics.style
        let lt = entry.localTime(now)
        let timeline = entry.timeline
        let band = stage.band
        let rightEdge = stage.expandedWidth - L.inset
        let amountScale = min(1, max(0, stage.flankWidth) / amountWidth)
        let rows = layout.rows
        // One scale for the whole text column, so a two-line title keeps both
        // rows at the same size as the subtitle.
        let textScale = layout.scale
        let contentIn = stage.contentIn(entry: entry)
        let titleHeight = Double(rows.titleLines) * LedgerIslandFonts.titleLineHeight

        let reduce = stage.reduceMotion
        let ringProgress = LedgerIslandEasing.easeInOut((lt - timeline.ringStart) / (timeline.ringEnd - timeline.ringStart))

        ZStack {
            LedgerIslandBadge(notice: notice, style: style, lt: lt, timeline: timeline, ringProgress: ringProgress)
                .centredBeforePlacement()
                .islandPlaced(entry.effect(.expanded, delay: 0, at: now, reduceMotion: reduce, contentIn: contentIn),
                              at: flankPoint(L.badgeCenterX), in: size)

            Group {
                if let count = style.count {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        LedgerIslandOdometer(value: Double(count) * ringProgress, digits: String(count).count)
                        Text(" 笔")
                            .font(LedgerIslandFonts.unit)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                } else {
                    LedgerIslandRollingText(text: notice.amountText, lt: lt, start: contentIn + 0.12)
                }
            }
            .font(LedgerIslandFonts.amount)
            .foregroundStyle(style.amountColor)
            .fixedSize()
            .frame(width: amountWidth, alignment: .trailing)
            .scaleEffect(amountScale, anchor: .trailing)
            .islandPlaced(entry.effect(.expanded, delay: 0.04, at: now, reduceMotion: reduce, contentIn: contentIn),
                          at: flankPoint(rightEdge - amountWidth / 2), in: size)

            Text(layout.title)
                .font(LedgerIslandFonts.title)
                .foregroundStyle(.white)
                .lineLimit(L.titleLines)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: textWidth, height: titleHeight, alignment: .leading)
                .scaleEffect(textScale, anchor: .leading)
                .centredBeforePlacement()
                .islandPlaced(entry.effect(.expanded, delay: 0.07, at: now, reduceMotion: reduce, contentIn: contentIn),
                              at: bodyPoint(L.textLeft + textWidth / 2, L.titleCenterY(band: band, rows: rows)), in: size)

            LedgerIslandSubtitle(notice: notice, style: style, lt: lt, timeline: timeline)
                .lineLimit(1)
                .frame(width: textWidth, alignment: .leading)
                .scaleEffect(textScale, anchor: .leading)
                .islandPlaced(entry.effect(.expanded, delay: 0.1, at: now, reduceMotion: reduce, contentIn: contentIn),
                              at: bodyPoint(L.textLeft + textWidth / 2, L.subtitleCenterY(band: band, rows: rows)), in: size)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Fits the text column under the camera: the title folds to two lines before
/// it truncates, and only if two lines still overflow does the whole column
/// (title and subtitle) take a smaller type size.
private struct LedgerIslandCompactContent: View {
    let entry: LedgerIslandStageEntry
    let metrics: LedgerIslandEntryMetrics
    let stage: LedgerIslandStage
    let size: CGSize
    let now: Double

    private typealias C = LedgerIslandStage.CompactLayout

    var body: some View {
        let style = metrics.style
        let compactWidth = entry.compactWidth
        let kx = size.width / compactWidth
        let cx = size.width / 2, cy = size.height / 2
        let trailingWidth = metrics.trailingWidth + 4
        let reduce = stage.reduceMotion
        // The glyph sits on the end cap's centre, so its margin is concentric.
        let capCenter = Double(stage.pill.height) / 2

        ZStack {
            ZStack {
                Circle().fill(style.accent)
                LedgerIslandCheckmark()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: C.glyph, height: C.glyph)
            .islandPlaced(entry.effect(.compact, delay: 0, at: now, reduceMotion: reduce), at: CGPoint(x: cx + (-compactWidth / 2 + capCenter) * kx, y: cy), in: size)

            Text(style.trailingText)
                .font(LedgerIslandFonts.compact)
                .foregroundStyle(style.amountColor)
                .lineLimit(1)
                .fixedSize()
                .frame(width: trailingWidth, alignment: .trailing)
                .islandPlaced(entry.effect(.compact, delay: 0.04, at: now, reduceMotion: reduce), at: CGPoint(x: cx + (compactWidth / 2 - C.trailingInset - C.trailingGap) * kx - trailingWidth / 2, y: cy), in: size)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Category badge that traces a progress ring, then blooms into a solid check.
private struct LedgerIslandBadge: View {
    let notice: LedgerIslandNotice
    let style: LedgerIslandStyle
    let lt: Double
    let timeline: LedgerIslandTimeline
    let ringProgress: Double

    private typealias L = LedgerIslandStage.Layout

    var body: some View {
        let bloom = LedgerIslandSpring.progress(lt - timeline.check, response: 0.38, damping: 0.62)
        let tick = LedgerIslandEasing.easeOut((lt - timeline.check - 0.06) / 0.26)
        let ripple = LedgerIslandEasing.clamp((lt - timeline.check) / 0.55)
        let glyphPop = 0.6 + 0.4 * min(1.1, LedgerIslandSpring.progress(lt - 0.08, response: 0.5, damping: 0.6))
        let badge = L.badge
        let ring = L.ring

        ZStack {
            Circle()
                .fill(style.badgeIconColor.opacity(0.2))
                .frame(width: badge, height: badge)
            Image(systemName: notice.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.badgeIconColor)
                .scaleEffect(glyphPop * (1 - 0.35 * LedgerIslandEasing.clamp(bloom)))
                .opacity(1 - LedgerIslandEasing.clamp(bloom * 1.6))
            Circle()
                .fill(style.accent)
                .frame(width: badge, height: badge)
                .scaleEffect(max(0, bloom))
            LedgerIslandCheckmark()
                .trim(from: 0, to: tick)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: badge, height: badge)

            if lt < timeline.check {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2)
                    .frame(width: ring, height: ring)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(style.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ring, height: ring)
            } else if ripple < 1 {
                Circle()
                    .stroke(style.accent.opacity(0.7 * (1 - ripple)), lineWidth: 2 * (1 - ripple) + 0.5)
                    .frame(width: ring + 10 * LedgerIslandEasing.easeOut(ripple), height: ring + 10 * LedgerIslandEasing.easeOut(ripple))
            }
        }
        .frame(width: 60, height: 60)
    }
}

private struct LedgerIslandSubtitle: View {
    let notice: LedgerIslandNotice
    let style: LedgerIslandStyle
    let lt: Double
    let timeline: LedgerIslandTimeline

    var body: some View {
        let done = notice.subtitle ?? ""
        // The text swap uses the subtitle line's own opacity. Two texts in one
        // stack would compose their opacity before the swap applies and both
        // would show at once, so only one exists at a time.
        Group {
            if let pending = style.pendingSubtitle,
               LedgerIslandEasing.clamp(LedgerIslandSpring.progress(lt - timeline.check - 0.08, response: 0.4, damping: 0.95)) < 0.5 {
                Text(pending)
            } else {
                Text(done)
            }
        }
        .font(LedgerIslandFonts.subtitle)
        .foregroundStyle(Color.white.opacity(0.6))
    }
}

/// Slot-machine roll: each digit spins one revolution, staggered left to right.
private struct LedgerIslandRollingText: View {
    let text: String
    let lt: Double
    let start: Double

    var body: some View {
        let characters = Array(text)
        let digitIndices: [Int?] = {
            var next = 0
            return characters.map { $0.isNumber ? { defer { next += 1 }; return next }() : nil }
        }()
        let symbolOpacity = LedgerIslandEasing.clamp(LedgerIslandSpring.progress(lt - start, response: 0.4, damping: 1))

        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                if let digitIndex = digitIndices[index], let digit = character.wholeNumberValue {
                    let progress = LedgerIslandSpring.progress(lt - start - Double(digitIndex) * 0.03, response: 0.62, damping: 0.82)
                    LedgerIslandDigitColumn(position: Double(digit) - 10 * (1 - progress), opacity: 1)
                } else {
                    Text(String(character)).opacity(symbolOpacity)
                }
            }
        }
    }
}

/// Real odometer: a higher digit only turns while every lower digit sits on 9.
/// The count rolls during the progress ring, so it visibly arrives at the
/// final number instead of sitting there while the ring catches up.
private struct LedgerIslandOdometer: View {
    let value: Double
    let digits: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach((0..<digits).reversed(), id: \.self) { place in
                let unit = pow(10, Double(place))
                // Turn this wheel only once everything below it has carried.
                let carried = place == 0 ? value : value.truncatingRemainder(dividingBy: unit)
                let position = place == 0
                    ? carried
                    : floor(value / unit) + max(0, carried - (unit - 1))
                LedgerIslandDigitColumn(
                    position: position,
                    // A leading place stays hidden until the number reaches it.
                    opacity: place == 0 ? 1 : LedgerIslandEasing.clamp(value - unit + 1)
                )
            }
        }
    }
}

private struct LedgerIslandDigitColumn: View {
    let position: Double
    let opacity: Double

    var body: some View {
        let base = Int(floor(position))
        Text("0")
            .hidden()
            .overlay {
                ZStack {
                    ForEach(0..<4, id: \.self) { slot in
                        let k = base - 1 + slot
                        let distance = position - Double(k)
                        Text(String(((k % 10) + 10) % 10))
                            .offset(y: -distance * 22)
                            .opacity(max(0, 1 - min(1, abs(distance))))
                    }
                }
            }
            .clipped()
            .opacity(opacity)
    }
}

private struct LedgerIslandCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 48
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: center.x - 8.5 * unit, y: center.y + 0.5 * unit))
        path.addLine(to: CGPoint(x: center.x - 2.5 * unit, y: center.y + 6.5 * unit))
        path.addLine(to: CGPoint(x: center.x + 9 * unit, y: center.y - 6 * unit))
        return path
    }
}

/// 顶部悬浮容器，用于挂载在全局 RootView。
/// The status bar belongs to the app's key window, so it is hidden from here
/// rather than from the overlay window, clearing the clock around the island.
struct LedgerIslandOverlayContainer: View {
    @Binding var currentNotice: LedgerIslandNotice?
    @ObservedObject private var presenter = LedgerIslandWindowManager.shared.presenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .statusBarHidden(presenter.hidesStatusBar)
            .onChange(of: currentNotice, initial: true) { _, newNotice in
                LedgerIslandWindowManager.shared.present(newNotice) {
                    currentNotice = nil
                }
            }
            .task { await previewLoop() }
    }

    /// `--preview-island` replays sample notices so the island can be checked
    /// on a simulator or device without writing to a ledger.
    private func previewLoop() async {
        guard ProcessInfo.processInfo.arguments.contains("--preview-island") else { return }
        let samples = [
            LedgerIslandNotice(type: .expense, title: "楼下便利店", subtitle: "餐饮 · 支出已记录",
                               amountText: "-¥38.00", iconName: "fork.knife", iconColorHex: 0xF59E0B),
            LedgerIslandNotice(type: .batchImport(count: 128), title: "支付宝账单导入", subtitle: "已归档至账本",
                               amountText: "128 笔已归档", iconName: "tray.and.arrow.down.fill", iconColorHex: 0x30D158),
            LedgerIslandNotice(type: .income, title: "Synthetic context action with a long name",
                               subtitle: "收入入账", amountText: "+¥12,800.00", iconName: "banknote.fill",
                               iconColorHex: 0x107C41),
        ]
        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            currentNotice = samples[index % samples.count]
            index += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }
}

/// 穿透触控的 UIWindow，将灵动岛抬升至 statusBar / alert 层级之上，
/// 确保它绝不会被任何 modal sheet、formSheet 或 fullScreenCover 弹窗遮挡。
final class LedgerIslandPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else { return nil }
        return (hitView === self || hitView === rootViewController?.view) ? nil : hitView
    }
}

@MainActor
final class LedgerIslandWindowManager {
    static let shared = LedgerIslandWindowManager()

    private var overlayWindow: LedgerIslandPassthroughWindow?
    let presenter = LedgerIslandPresenter()
    private var hasHardwareIsland = false
    private var pill = LedgerIslandStage.defaultPill
    /// Top of the hardware island in overlay coordinates, and the room the
    /// expanded island gets on each side of it.
    private var cameraTop: Double = 8
    private var flank: Double = LedgerIslandStage.Layout.inset + LedgerIslandStage.Layout.cameraGap
    private var dismissHandler: (() -> Void)?

    private init() {
        presenter.onFinished = { [weak self] in
            let handler = self?.dismissHandler
            self?.dismissHandler = nil
            self?.destroyWindow()
            handler?()
        }
    }

    func present(_ notice: LedgerIslandNotice?, onDismiss: @escaping () -> Void) {
        // `nil` only arrives after our own dismissal has cleared the binding.
        guard let notice else {
            if !presenter.isActive { destroyWindow() }
            return
        }

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }

        dismissHandler = onDismiss
        if overlayWindow == nil || overlayWindow?.windowScene != scene {
            destroyWindow()
            let window = LedgerIslandPassthroughWindow(windowScene: scene)
            window.windowLevel = .statusBar + 100
            window.backgroundColor = .clear
            window.isOpaque = false

            let safeTop = scene.windows.first(where: \.isKeyWindow)?.safeAreaInsets.top ?? 0
            // Dynamic Island devices report a top inset of 51pt or more.
            hasHardwareIsland = UIDevice.current.userInterfaceIdiom == .phone && safeTop >= 51
            var topOffset: CGFloat = 8
            pill = LedgerIslandStage.defaultPill
            cameraTop = topOffset
            if hasHardwareIsland {
                let screen = scene.screen
                let cover = LedgerIslandCutout.hardware(
                    nativeWidth: screen.nativeBounds.width,
                    nativeHeight: screen.nativeBounds.height,
                    nativeScale: screen.nativeScale,
                    safeTop: safeTop
                ).covering(bleed: 0.75)
                topOffset = cover.top
                pill = cover.pill
                cameraTop = cover.top
            }
            flank = LedgerIslandStage.flank(screenWidth: Double(scene.screen.bounds.width),
                                            cutoutWidth: Double(pill.width))
            let hosting = UIHostingController(rootView: LedgerIslandStageView(
                presenter: presenter,
                hasHardwareIsland: hasHardwareIsland,
                topOffset: topOffset
            ))
            hosting.view.backgroundColor = .clear
            hosting.view.isOpaque = false
            window.rootViewController = hosting
            window.isHidden = false
            overlayWindow = window
        }

        presenter.present(
            notice,
            containerWidth: Double(scene.screen.bounds.width),
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            pill: pill,
            pillTop: cameraTop,
            flank: flank
        )
    }

    private func destroyWindow() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
