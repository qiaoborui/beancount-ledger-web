import SwiftUI
import UIKit

/// 账本助手's character, 豆豆, alive: it breathes, blinks and plays its
/// state's loop (`LedgerMascotPose.at`). The drawing is `LedgerMascotCanvas`
/// in `LedgerMascotShapes.swift`, which the widgets share.
///
/// Below 30pt it takes the small detail. The clock runs at 30 fps and only
/// while the scene is active; with 减弱动态效果 on it stands still.
struct LedgerMascotView: View {
    var state: LedgerMascotState = .idle
    var size: CGFloat
    var animated = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// When the current state began, so a new state plays from its start
    /// (the hop of `.success`).
    @State private var since = Date()

    var body: some View {
        let moving = animated && !reduceMotion
        let palette: LedgerMascotPalette = colorScheme == .dark ? .dark : .light
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving || scenePhase != .active)) { timeline in
            LedgerMascotCanvas(state: state, palette: palette, small: size < 30,
                               pose: moving ? .at(timeline.date.timeIntervalSince(since), state: state) : .rest)
        }
        .frame(width: size, height: size)
        .onChange(of: state) { since = Date() }
        .accessibilityHidden(true)
    }
}

/// The launch screen's character at a point of its landing (0...1). Both
/// ends are the still drawing: the storyboard's `LaunchMark` is the same
/// picture, and `LedgerLaunchHandoff` moves the settled one onto the greeting.
struct LedgerMascotEntrance: View, @MainActor Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LedgerMascotCanvas(state: .idle, palette: colorScheme == .dark ? .dark : .light,
                           pose: .entrance(progress))
    }
}

/// The tab bar's 账本助手 glyph: 豆豆's silhouette with its face cut out,
/// rendered once into a template image.
///
/// A tab bar draws a label's image and not an arbitrary view, so the drawing
/// has to become one. Template rendering keeps the icon free of colours: the
/// system tints it for the selected tab, the unselected tabs and each
/// appearance, the same way it tints the SF Symbols beside it.
@MainActor
enum LedgerTabMark {
    /// A bar glyph sits in about 25pt. The character fills the middle of its
    /// 64-unit square (about 39 by 51 units), so a 24pt square draws it about
    /// 15 by 19pt: the height of a symbol's ink, narrower than most.
    private static let canvas: CGFloat = 25
    private static let mark: CGFloat = 24

    static let image: Image = {
        guard let rendered = rendered() else {
            // Never expected; an ordinary symbol is a better bar than no glyph.
            return Image(systemName: LedgerDestination.agent.systemImage)
        }
        return Image(uiImage: rendered.withRenderingMode(.alwaysTemplate))
    }()

    /// The glyph as a bitmap, which the geometry test reads too. Rendered at 4x
    /// rather than a device's scale: the detached button can draw the label
    /// above its 25pt canvas, and the headroom keeps that from going soft.
    ///
    /// The ink and the face are rendered apart and the face is cut out with
    /// Core Graphics: SwiftUI's destination-out blending, in a Canvas or on a
    /// view, left the eyes filled under ImageRenderer.
    static func rendered() -> UIImage? {
        func pass(_ pass: LedgerMascotDrawing.Pass) -> UIImage? {
            let palette: LedgerMascotPalette = pass == .holes ? .mono(.clear) : .mono(.black)
            let content = Canvas { context, size in
                LedgerMascotDrawing(state: .idle, palette: palette, small: true, pose: .rest, pass: pass)
                    .draw(in: context, size: size)
            }
            .frame(width: mark, height: mark)
            .frame(width: canvas, height: canvas)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 4
            return renderer.uiImage
        }
        guard let ink = pass(.ink), let holes = pass(.holes) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = false
        return UIGraphicsImageRenderer(size: ink.size, format: format).image { _ in
            ink.draw(at: .zero)
            holes.draw(at: .zero, blendMode: .destinationOut, alpha: 1)
        }
    }
}
