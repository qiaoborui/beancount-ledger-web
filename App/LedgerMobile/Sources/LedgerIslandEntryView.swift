import SwiftUI
import UIKit

/// 灵动岛入账反馈：从硬件岛长出 → 展开确认 → 紧凑态 → 收回。
/// 每一帧都是时间的纯函数（见 `LedgerIslandStage`），由 `TimelineView` 驱动，
/// 不依赖 `withAnimation` 链，因此新通知可以在任意时刻打断并保留形状速度。
/// 布局遵循 Apple HIG（Live Activities）：展开态宽为屏宽 − 22pt、圆角与内容同心，
/// 前后内容贴着摄像头两侧，其余内容放在摄像头下方；紧凑态紧贴摄像头；
/// 背景保持纯黑，深色模式用着色描边（keyline）而非阴影。
struct LedgerIslandStyle {
    let tint: Color
    let accent: Color
    let captionColor: Color
    let amountColor: Color
    let caption: String
    let pendingCaption: String?
    let pendingSubtitle: String?
    let count: Int?
    let trailingText: String

    init(_ notice: LedgerIslandNotice) {
        let blue = Color(uiColor: UIColor(hex: 0x0A84FF))
        let green = Color(uiColor: UIColor(hex: 0x30D158))
        switch notice.type {
        case .expense:
            tint = Color(uiColor: UIColor(hex: 0xFF9F0A)); accent = blue
            amountColor = .white; caption = "已记账"
            pendingCaption = nil; pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .income:
            tint = green; accent = green
            amountColor = green; caption = "已入账"
            pendingCaption = nil; pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .transfer:
            let cyan = Color(uiColor: UIColor(hex: 0x64D2FF))
            tint = cyan; accent = blue
            amountColor = cyan; caption = "已转账"
            pendingCaption = nil; pendingSubtitle = nil; count = nil
            trailingText = LedgerIslandAmount.compact(notice.amountText)
        case .batchImport(let total):
            tint = Color(uiColor: UIColor(hex: 0xBF5AF2)); accent = green
            amountColor = .white; caption = "已导入"
            pendingCaption = "写入中"; pendingSubtitle = "正在写入账本…"; count = total
            trailingText = "\(total) 笔"
        }
        captionColor = accent == blue ? Color(uiColor: UIColor(hex: 0x409CFF)) : accent
    }
}

enum LedgerIslandFonts {
    static let title = Font.system(size: 16, weight: .semibold)
    static let subtitle = Font.system(size: 12.5, weight: .medium)
    static let amount = Font.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()
    static let unit = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 12, weight: .semibold)
    static let compact = Font.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()

    static func width(_ text: String, size: CGFloat, weight: UIFont.Weight, rounded: Bool = false) -> Double {
        var font = rounded ? UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : UIFont.systemFont(ofSize: size, weight: weight)
        if rounded, let descriptor = font.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return Double(ceil((text as NSString).size(withAttributes: [.font: font]).width))
    }

    static func amountWidth(_ notice: LedgerIslandNotice, style: LedgerIslandStyle) -> Double {
        if let count = style.count {
            return width(String(count), size: 20, weight: .bold, rounded: true) + width(" 笔", size: 13, weight: .semibold)
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

    var isActive: Bool { stage?.current != nil }

    func present(_ notice: LedgerIslandNotice, containerWidth: Double, reduceMotion: Bool, pill: CGSize) {
        let now = Date.timeIntervalSinceReferenceDate
        // Only a mid-flight stage is kept, so its springs carry their velocity.
        var next = stage.flatMap { $0.visibleEntries(at: now).isEmpty ? nil : $0 }
            ?? LedgerIslandStage(containerWidth: containerWidth, reduceMotion: reduceMotion, pill: pill)
        let entryMetrics = LedgerIslandEntryMetrics(notice)
        next.present(notice, trailingTextWidth: entryMetrics.trailingWidth, at: now)
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
        TimelineView(.animation(minimumInterval: nil, paused: !presenter.isActive)) { context in
            if let stage = presenter.stage {
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
    /// Places an element on the island with its enter/exit effect. The effect
    /// runs at the element's own size (blurring a full island-sized layer per
    /// element was expensive), while scale still pivots on the island centre so
    /// content emerges from inside the shape. Fully hidden elements are skipped.
    @ViewBuilder
    func islandPlaced(_ effect: LedgerIslandEffect, at point: CGPoint, in size: CGSize) -> some View {
        if effect.opacity > 0.001 {
            let cx = size.width / 2, cy = size.height / 2
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

    /// Layout lives in final-size coordinates and is mapped onto the live
    /// shape (top-anchored, centred), so text never reflows while it grows.
    private func map(_ x: Double, _ y: Double) -> CGPoint {
        let fullWidth = stage.expandedWidth
        return CGPoint(
            x: size.width / 2 + (x - fullWidth / 2) * size.width / fullWidth,
            y: y * size.height / stage.expandedHeight
        )
    }

    var body: some View {
        let notice = entry.notice
        let style = metrics.style
        let lt = entry.localTime(now)
        let timeline = entry.timeline
        let rightEdge = stage.expandedWidth - L.inset
        // Per-glyph rolling columns lose kerning, so leave a little slack, and
        // shrink an amount that would reach under the camera.
        let amountWidth = metrics.amountWidth + 4
        let amountScale = min(1, stage.flankWidth / amountWidth)
        let captionWidth = 48.0
        let textWidth = max(40, rightEdge - L.textLeft)
        let subtitleWidth = max(40, textWidth - captionWidth - 8)

        let reduce = stage.reduceMotion
        let ringProgress = LedgerIslandEasing.easeInOut((lt - timeline.ringStart) / (timeline.ringEnd - timeline.ringStart))

        ZStack {
            LedgerIslandBadge(notice: notice, style: style, lt: lt, timeline: timeline, ringProgress: ringProgress)
                .islandPlaced(entry.effect(.expanded, delay: 0, at: now, reduceMotion: reduce), at: map(L.badgeCenter.x, L.badgeCenter.y), in: size)

            Group {
                if let count = style.count {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        LedgerIslandOdometer(value: Double(count) * ringProgress, digits: String(count).count)
                        Text(" 笔")
                            .font(LedgerIslandFonts.unit)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                } else {
                    LedgerIslandRollingText(text: notice.amountText, lt: lt, start: timeline.contentIn + 0.12)
                }
            }
            .font(LedgerIslandFonts.amount)
            .foregroundStyle(style.amountColor)
            .fixedSize()
            .frame(width: amountWidth, alignment: .trailing)
            .scaleEffect(amountScale, anchor: .trailing)
            .islandPlaced(entry.effect(.expanded, delay: 0.04, at: now, reduceMotion: reduce), at: map(rightEdge - amountWidth / 2, L.amountY), in: size)

            Text(notice.title)
                .font(LedgerIslandFonts.title)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: textWidth, alignment: .leading)
                .islandPlaced(entry.effect(.expanded, delay: 0.07, at: now, reduceMotion: reduce), at: map(L.textLeft + textWidth / 2, L.titleY), in: size)

            LedgerIslandSubtitle(notice: notice, style: style, lt: lt, timeline: timeline)
                .lineLimit(1)
                .frame(width: subtitleWidth, alignment: .leading)
                .islandPlaced(entry.effect(.expanded, delay: 0.1, at: now, reduceMotion: reduce), at: map(L.textLeft + subtitleWidth / 2, L.subtitleY), in: size)

            LedgerIslandCaption(style: style, lt: lt, timeline: timeline)
                .frame(width: captionWidth, alignment: .trailing)
                .islandPlaced(entry.effect(.expanded, delay: 0.1, at: now, reduceMotion: reduce), at: map(rightEdge - captionWidth / 2, L.subtitleY), in: size)
        }
        .frame(width: size.width, height: size.height)
    }
}

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
                .islandPlaced(entry.effect(.compact, delay: 0.04, at: now, reduceMotion: reduce), at: CGPoint(x: cx + (compactWidth / 2 - C.trailingInset + 2) * kx - trailingWidth / 2, y: cy), in: size)
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

    var body: some View {
        let bloom = LedgerIslandSpring.progress(lt - timeline.check, response: 0.38, damping: 0.62)
        let tick = LedgerIslandEasing.easeOut((lt - timeline.check - 0.06) / 0.26)
        let ripple = LedgerIslandEasing.clamp((lt - timeline.check) / 0.55)
        let glyphPop = 0.6 + 0.4 * min(1.1, LedgerIslandSpring.progress(lt - 0.08, response: 0.5, damping: 0.6))

        ZStack {
            Circle()
                .fill(style.tint.opacity(0.2))
                .frame(width: 44, height: 44)
            Image(systemName: notice.iconName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(style.tint)
                .scaleEffect(glyphPop * (1 - 0.35 * LedgerIslandEasing.clamp(bloom)))
                .opacity(1 - LedgerIslandEasing.clamp(bloom * 1.6))
            Circle()
                .fill(style.accent)
                .frame(width: 44, height: 44)
                .scaleEffect(max(0, bloom))
            LedgerIslandCheckmark()
                .trim(from: 0, to: tick)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 44, height: 44)

            if lt < timeline.check {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                    .frame(width: 53, height: 53)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(style.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 53, height: 53)
            } else if ripple < 1 {
                Circle()
                    .stroke(style.accent.opacity(0.7 * (1 - ripple)), lineWidth: 2.5 * (1 - ripple) + 0.5)
                    .frame(width: 53 + 14 * LedgerIslandEasing.easeOut(ripple), height: 53 + 14 * LedgerIslandEasing.easeOut(ripple))
            }
        }
        .frame(width: 80, height: 80)
    }
}

private struct LedgerIslandSubtitle: View {
    let notice: LedgerIslandNotice
    let style: LedgerIslandStyle
    let lt: Double
    let timeline: LedgerIslandTimeline

    var body: some View {
        let done = notice.subtitle ?? ""
        ZStack(alignment: .leading) {
            if let pending = style.pendingSubtitle {
                let swap = LedgerIslandEasing.clamp(LedgerIslandSpring.progress(lt - timeline.check - 0.08, response: 0.4, damping: 0.95))
                Text(pending).opacity(1 - swap).offset(y: -4 * swap)
                Text(done).opacity(swap).offset(y: 4 * (1 - swap))
            } else {
                Text(done)
            }
        }
        .font(LedgerIslandFonts.subtitle)
        .foregroundStyle(Color.white.opacity(0.6))
    }
}

private struct LedgerIslandCaption: View {
    let style: LedgerIslandStyle
    let lt: Double
    let timeline: LedgerIslandTimeline

    var body: some View {
        let shown = LedgerIslandEasing.clamp(LedgerIslandSpring.progress(lt - timeline.check - 0.05, response: 0.4, damping: 0.9))
        ZStack(alignment: .trailing) {
            if let pending = style.pendingCaption {
                Text(pending)
                    .foregroundStyle(Color.white.opacity(0.45))
                    .opacity(1 - shown)
            }
            Text(style.caption)
                .foregroundStyle(style.captionColor)
                .opacity(shown)
                .offset(y: 4 * (1 - shown))
        }
        .font(LedgerIslandFonts.caption)
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
private struct LedgerIslandOdometer: View {
    let value: Double
    let digits: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach((0..<digits).reversed(), id: \.self) { place in
                let unit = pow(10, Double(place))
                let position: Double = place == 0
                    ? value
                    : floor(value / unit) + max(0, value.truncatingRemainder(dividingBy: unit) - (unit - 1))
                LedgerIslandDigitColumn(
                    position: position,
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
            }
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
            pill: pill
        )
    }

    private func destroyWindow() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
