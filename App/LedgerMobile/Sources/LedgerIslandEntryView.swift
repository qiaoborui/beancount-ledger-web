import SwiftUI
import UIKit

/// 灵动岛入账反馈：从硬件岛长出 → 单行确认卡 → 紧凑态 → 收回。
/// 每一帧都是时间的纯函数（见 `LedgerIslandStage`），由 `TimelineView` 驱动，
/// 不依赖 `withAnimation` 链，因此新通知可以在任意时刻打断并保留形状速度。
/// 展开态是挂在摄像头下方的一行：色相圆盘（对勾 / 导入托盘）、标题、可选的
/// 小标签和金额。摄像头那一条始终留空；圆盘与圆角同心。紧凑态左侧是小圆盘
/// （单笔显示分类图标，多笔显示对勾，导入显示托盘），右侧是金额或笔数，都避开摄像头。
/// 一条通知只用一个色相：支出 #CF7A52、收入 #4FBFAB（即 `BalancedPalette`
/// 的深色值，岛永远是黑的），转账、批量记账和导入用白色。
struct LedgerIslandStyle {
    let hue: Color
    /// The compact pill's trailing text: the short amount, or the count.
    let trailingText: String

    init(_ notice: LedgerIslandNotice) {
        hue = Color(uiColor: UIColor(hex: notice.type.hueHex))
        trailingText = notice.compactText
    }
}

extension LedgerIslandFonts {
    /// SwiftUI faces for the island. They stay in this file because `Font` needs
    /// SwiftUI, which the portable package does not import.
    static let title = Font.system(size: titleSize, weight: .semibold)
    static let secondary = Font.system(size: secondarySize, weight: .medium)
    static let amount = Font.system(size: amountSize, weight: .semibold, design: .rounded).monospacedDigit()
    static let compact = Font.system(size: compactSize, weight: .semibold, design: .rounded).monospacedDigit()
}

/// Style and text measurements resolved once per notice; the island redraws
/// every frame, and measuring with UIKit fonts there is what made it stutter.
struct LedgerIslandEntryMetrics {
    let style: LedgerIslandStyle
    let titleWidth: Double
    let secondaryWidth: Double?
    let amountWidth: Double
    let trailingWidth: Double

    init(_ notice: LedgerIslandNotice) {
        style = LedgerIslandStyle(notice)
        titleWidth = LedgerIslandFonts.width(notice.title, size: LedgerIslandFonts.titleSize, weight: .semibold)
        secondaryWidth = notice.subtitle.flatMap { $0.isEmpty ? nil : $0 }
            .map { LedgerIslandFonts.width($0, size: LedgerIslandFonts.secondarySize, weight: .medium) }
        // Monospaced digits run a little wider than the proportional measure.
        amountWidth = LedgerIslandFonts.width(notice.amountText, size: LedgerIslandFonts.amountSize,
                                              weight: .semibold, rounded: true) + 2
        trailingWidth = LedgerIslandFonts.width(style.trailingText, size: LedgerIslandFonts.compactSize,
                                                weight: .semibold, rounded: true) + 2
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

    /// True only while an effect still changes with time. Once every entry has
    /// settled the timeline can stop; a `TimelineView(.animation)` that stays
    /// unpaused re-evaluates the island at display refresh rate for nothing.
    var needsFrames: Bool {
        guard let stage, let entry = stage.current else { return false }
        return LedgerIslandFrameGate.needsFrames(entry: entry, reduceMotion: stage.reduceMotion,
            now: Date.timeIntervalSinceReferenceDate)
    }

    func present(_ notice: LedgerIslandNotice, containerWidth: Double, reduceMotion: Bool, pill: CGSize,
                 pillTop: Double = 0) {
        let now = Date.timeIntervalSinceReferenceDate
        // Only a mid-flight stage is kept, so its springs carry their velocity.
        var next = stage.flatMap { $0.visibleEntries(at: now).isEmpty ? nil : $0 }
            ?? LedgerIslandStage(containerWidth: containerWidth, reduceMotion: reduceMotion, pill: pill, pillTop: pillTop)
        let entryMetrics = LedgerIslandEntryMetrics(notice)
        let row = next.row(titleWidth: entryMetrics.titleWidth, secondaryWidth: entryMetrics.secondaryWidth,
                           amountWidth: entryMetrics.amountWidth)
        // The shape starts toward the card immediately; the row fades in while
        // the shape reveals it, so there is no wait on an empty island.
        next.present(notice, row: row, trailingTextWidth: entryMetrics.trailingWidth, at: now)
        let live = Set(next.entries.map(\.notice.id))
        metrics = metrics.filter { live.contains($0.key) }
        metrics[notice.id] = entryMetrics
        stage = next

        guard let entry = next.current else { return }
        setStatusBarHidden(true)
        // The overlay window never takes focus, so VoiceOver hears the
        // confirmation as an announcement instead.
        UIAccessibility.post(notification: .announcement, argument: notice.announcement)

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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !presenter.needsFrames)) { context in
            if let stage = presenter.stage {
                island(stage, now: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    /// One inner hairline in both appearances, faded in with the growth so the
    /// resting shape over the camera never draws a ring around the hardware.
    /// Dark mode needs it: a black card on a near-black page otherwise has no
    /// edge. Light mode keeps a fainter one so the shape is identical in both
    /// appearances and its edge does not read as a hole cut in the page. It is
    /// never a shadow and never tinted, so the card stays the hardware's black.
    private func keyline(_ visibility: Double) -> Color {
        let level = (colorScheme == .dark ? 0.2 : 0.1) * LedgerIslandEasing.clamp(visibility)
        // Reduce Transparency gets the same grey as an opaque colour.
        return reduceTransparency ? Color(white: level) : Color.white.opacity(level)
    }

    private func island(_ stage: LedgerIslandStage, now: Double) -> some View {
        let entries = stage.visibleEntries(at: now)
        return Group {
            if stage.reduceMotion {
                crossfaded(stage, entries: entries, now: now)
            } else {
                morphing(stage, entries: entries, now: now)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("ledger-dynamic-island-notice")
        .accessibilityLabel(stage.current?.notice.announcement ?? "")
        .padding(.top, topOffset)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The shape springs out of the hardware island and carries both layers;
    /// each layer fades in while the shape reveals it.
    private func morphing(_ stage: LedgerIslandStage, entries: [LedgerIslandStageEntry], now: Double) -> some View {
        let size = stage.size(at: now)
        let pill = stage.pill
        let growth = Double((size.width - pill.width) / 30)
        // Without a hardware island there is nothing to grow out of, so fade in.
        let appear = hasHardwareIsland ? 1 : LedgerIslandEasing.clamp(growth)
        let shape = RoundedRectangle(cornerRadius: LedgerIslandStage.cornerRadius(height: size.height), style: .continuous)

        return ZStack {
            ForEach(entries, id: \.notice.id) { entry in
                if let metrics = presenter.metrics[entry.notice.id] {
                    LedgerIslandExpandedContent(entry: entry, metrics: metrics, stage: stage, size: size, now: now,
                                                reduceTransparency: reduceTransparency)
                    LedgerIslandCompactContent(entry: entry, metrics: metrics, stage: stage, size: size, now: now)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .background(shape.fill(Color.black))
        .overlay { shape.strokeBorder(keyline(growth), lineWidth: 0.75) }
        .opacity(appear)
    }

    /// Reduce Motion: no shape travels. The card and the compact pill each
    /// appear at their settled size and crossfade; on hardware a resting pill
    /// stays over the camera underneath, so the cutout never shows between them.
    private func crossfaded(_ stage: LedgerIslandStage, entries: [LedgerIslandStageEntry], now: Double) -> some View {
        let pill = stage.pill
        let pillShape = Capsule(style: .continuous)
        return ZStack(alignment: .top) {
            if hasHardwareIsland {
                pillShape.fill(Color.black).frame(width: pill.width, height: pill.height)
            }
            ForEach(entries, id: \.notice.id) { entry in
                if let metrics = presenter.metrics[entry.notice.id] {
                    let card = CGSize(width: entry.row.width, height: stage.expandedHeight)
                    let cardShape = RoundedRectangle(cornerRadius: LedgerIslandStage.cornerRadius, style: .continuous)
                    let cardOpacity = entry.effect(.expanded, delay: 0, at: now, reduceMotion: true).opacity
                    LedgerIslandExpandedContent(entry: entry, metrics: metrics, stage: stage, size: card, now: now,
                                                reduceTransparency: reduceTransparency)
                        .frame(width: card.width, height: card.height)
                        .background(cardShape.fill(Color.black))
                        .overlay { cardShape.strokeBorder(keyline(1), lineWidth: 0.75) }
                        .opacity(cardOpacity)

                    let compact = CGSize(width: entry.compactWidth, height: pill.height)
                    LedgerIslandCompactContent(entry: entry, metrics: metrics, stage: stage, size: compact, now: now)
                        .frame(width: compact.width, height: compact.height)
                        .background(pillShape.fill(Color.black))
                        .opacity(entry.effect(.compact, delay: 0, at: now, reduceMotion: true).opacity)
                }
            }
        }
    }
}

private extension View {
    /// Applies one element's enter/exit effect at its own size and centres it
    /// on `point`. Fully hidden elements are skipped.
    @ViewBuilder
    func islandPlaced(_ effect: LedgerIslandEffect, at point: CGPoint) -> some View {
        if effect.opacity > 0.001 {
            scaleEffect(effect.scale)
                .blur(radius: effect.blur)
                .opacity(effect.opacity)
                .position(x: point.x, y: point.y + effect.yOffset)
        }
    }
}

/// The single row under the camera band.
///
/// Positions live in the settled card's coordinates and are anchored on the
/// camera, which never moves: horizontally about the shape's centre, and
/// vertically from the shape's top (the camera's top). The growing shape
/// reveals the row by clipping it, so nothing slides or reflows mid-flight and
/// nothing ever sits beside the camera.
private struct LedgerIslandExpandedContent: View {
    let entry: LedgerIslandStageEntry
    let metrics: LedgerIslandEntryMetrics
    let stage: LedgerIslandStage
    let size: CGSize
    let now: Double
    let reduceTransparency: Bool

    private typealias L = LedgerIslandStage.Layout

    private func point(_ x: Double) -> CGPoint {
        CGPoint(x: size.width / 2 + (x - entry.row.width / 2), y: L.rowCenterY(band: stage.band))
    }

    var body: some View {
        let notice = entry.notice
        let style = metrics.style
        let row = entry.row
        let reduce = stage.reduceMotion
        let secondary = row.showsSecondary ? notice.subtitle : nil
        let textWidth = row.titleWidth + (secondary == nil ? 0 : L.secondaryGap + (metrics.secondaryWidth ?? 0))

        ZStack {
            LedgerIslandDisc(symbol: notice.type.isImport ? notice.iconName : nil, hue: style.hue,
                             size: L.disc, glyphSize: 13, lineWidth: 2.4,
                             tick: reduce ? 1 : LedgerIslandEasing.easeOut((entry.localTime(now) - entry.timeline.check) / 0.24))
                .islandPlaced(entry.effect(.expanded, delay: 0, at: now, reduceMotion: reduce), at: point(L.discCenterX))

            HStack(alignment: .firstTextBaseline, spacing: L.secondaryGap) {
                Text(notice.title)
                    .font(LedgerIslandFonts.title)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: row.titleWidth, alignment: .leading)
                if let secondary {
                    Text(secondary)
                        .font(LedgerIslandFonts.secondary)
                        .foregroundStyle(reduceTransparency ? Color(white: 0.62) : Color.white.opacity(0.55))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(width: textWidth, alignment: .leading)
            .islandPlaced(entry.effect(.expanded, delay: 0.03, at: now, reduceMotion: reduce),
                          at: point(L.textLeft + textWidth / 2))

            Text(notice.amountText)
                .font(LedgerIslandFonts.amount)
                .foregroundStyle(style.hue)
                .lineLimit(1)
                .fixedSize()
                .frame(width: metrics.amountWidth, alignment: .trailing)
                .islandPlaced(entry.effect(.expanded, delay: 0.06, at: now, reduceMotion: reduce),
                              at: point(row.width - L.trailingInset - metrics.amountWidth / 2))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The compact pill: a small disc on the leading end cap (the category for one
/// entry, the check for several, the tray for an import), the amount or count
/// before the trailing one, the camera clear between them. Anchored on the
/// camera like the row, so the collapsing shape never drags either across it.
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
        let left = size.width / 2 - compactWidth / 2
        let cy = Double(stage.pill.height) / 2
        let reduce = stage.reduceMotion
        // The disc sits on the end cap's centre, so its margin is concentric.
        let capCenter = Double(stage.pill.height) / 2

        ZStack {
            LedgerIslandDisc(symbol: entry.notice.compactSymbol, hue: style.hue, size: C.glyph, glyphSize: 8.5,
                             lineWidth: 1.8, tick: 1)
                .islandPlaced(entry.effect(.compact, delay: 0, at: now, reduceMotion: reduce),
                              at: CGPoint(x: left + capCenter, y: cy))

            Text(style.trailingText)
                .font(LedgerIslandFonts.compact)
                .foregroundStyle(style.hue)
                .lineLimit(1)
                .fixedSize()
                .frame(width: metrics.trailingWidth, alignment: .trailing)
                .islandPlaced(entry.effect(.compact, delay: 0.04, at: now, reduceMotion: reduce),
                              at: CGPoint(x: left + compactWidth - C.trailingInset - C.trailingGap - metrics.trailingWidth / 2,
                                          y: cy))
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A solid disc in the notice's hue with the glyph knocked out in black: the
/// given symbol, or a drawn check when there is none.
private struct LedgerIslandDisc: View {
    let symbol: String?
    let hue: Color
    let size: Double
    let glyphSize: Double
    let lineWidth: Double
    /// How far the check has drawn, 0…1.
    let tick: Double

    var body: some View {
        ZStack {
            Circle().fill(hue)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(Color.black)
            } else {
                LedgerIslandCheckmark()
                    .trim(from: 0, to: LedgerIslandEasing.clamp(tick))
                    .stroke(Color.black, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
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
/// It also connects `LedgerIslandNotices` to the overlay window, so a saved
/// entry reaches the island by a direct call rather than through published
/// session state.
struct LedgerIslandOverlayContainer: View {
    @ObservedObject private var presenter = LedgerIslandWindowManager.shared.presenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .statusBarHidden(presenter.hidesStatusBar)
            .onAppear {
                LedgerIslandNotices.handler = { LedgerIslandWindowManager.shared.present($0) }
            }
            .task { await previewLoop() }
    }

    /// `--preview-island` replays sample notices so the island can be checked
    /// on a simulator or device without writing to a ledger.
    private func previewLoop() async {
        guard ProcessInfo.processInfo.arguments.contains("--preview-island") else { return }
        let samples = [
            LedgerIslandNotice(type: .expense, title: "楼下便利店", subtitle: "餐饮",
                               amountText: "-¥38.00", compactText: "-¥38", iconName: "fork.knife"),
            LedgerIslandNotice.fromImport(count: 128, provider: "alipay"),
            LedgerIslandNotice(type: .income, title: "Synthetic context action with a long name",
                               subtitle: "工资", amountText: "+¥12,800.00", compactText: "+¥1.28万",
                               iconName: "banknote.fill"),
        ]
        var index = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            LedgerIslandNotices.post(samples[index % samples.count])
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
    /// Top of the hardware island in overlay coordinates.
    private var cameraTop: Double = 8

    private init() {
        presenter.onFinished = { [weak self] in self?.destroyWindow() }
    }

    func present(_ notice: LedgerIslandNotice) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return
        }

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
            pillTop: cameraTop
        )
    }

    private func destroyWindow() {
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController = nil
        overlayWindow = nil
    }
}
