#if os(iOS)
import SwiftUI
import UIKit

/// The history drawer beside 账本助手, laid out and moved by UIKit the way
/// FlowDown's `MainController` moves its sidebar.
///
/// The chat page and the drawer are each in a hosting controller of their
/// own, and opening or closing the drawer only moves layers: the page is
/// translated and scaled into a card, never laid out again at another size,
/// so SwiftUI does no work while the drawer slides. In a compact width the
/// page is pushed aside into a card with 28pt corners and a light shadow,
/// 40pt of it left on screen, and the drawer comes in from 70pt under it; in
/// a regular width the drawer slides over the page under a dim.
///
/// A drag that goes mostly sideways opens it (from anywhere on a root page,
/// or from the leading edge over content that scrolls sideways) or closes
/// it. Past 100pt the drag decides and FlowDown's spring (half a second,
/// damping 0.9) carries the rest; letting go before that opens it past
/// halfway or at 300pt/s. A tap on the card closes it. A finger can catch
/// it mid-flight.
struct LedgerAgentDrawerShell<Page: View, Drawer: View>: UIViewControllerRepresentable {
    let state: LedgerAgentDrawerState
    /// A drag to the right opens the drawer: a root page, nothing pushed.
    var edgeOpens: Bool
    /// What the drawer's content is built from besides the number of times
    /// it closed; the drawer is drawn again only when this changes.
    var drawerKey: AnyHashable = 0
    @ViewBuilder var page: () -> Page
    /// The drawer's content, given how many times it has gone all the way in.
    var drawer: (Int) -> Drawer

    func makeUIViewController(context: Context) -> LedgerAgentDrawerController {
        let controller = LedgerAgentDrawerController()
        state.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: LedgerAgentDrawerController, context: Context) {
        state.controller = controller
        // The hosting controllers start an environment of their own: hand
        // them this one, with everything the app put in it.
        let environment = context.environment
        controller.pushes = environment.horizontalSizeClass != .regular
        controller.reduceMotion = environment.accessibilityReduceMotion
        controller.edgeOpens = edgeOpens
        controller.setPage(AnyView(page()
            // The page's own glass bar, in every width: the system bar of
            // the stack around this controller cannot move with the card.
            .environment(\.ledgerChromeDrawsOwnBar, true)
            .environment(\.self, environment)))
        controller.updateDrawer(key: drawerKey) { closings in
            AnyView(drawer(closings).environment(\.self, environment))
        }
    }

    static func dismantleUIViewController(_ controller: LedgerAgentDrawerController, coordinator: ()) {
        controller.cancelMotion()
    }
}

/// The drawer's state, shared by the chat page (its history button), the
/// drawer's content and the stack that pushes the places picked in it. Only
/// `route` is published: opening and closing never redraws SwiftUI.
@MainActor
final class LedgerAgentDrawerState: ObservableObject {
    /// A place picked at the top of the drawer, pushed on the page's stack.
    @Published var route: LedgerAgentDrawerRoute?
    fileprivate weak var controller: LedgerAgentDrawerController?
    let actions = LedgerAgentDrawerActions()
    /// Set by the chat page, which owns these.
    var openSettings: () -> Void = {}
    var revise: (LedgerAgentArtifactSpec) -> Void = { _ in }
    var ask: (String) -> Void = { _ in }

    init() {
        actions.close = { [weak self] in self?.close() }
        actions.openSettings = { [weak self] in self?.openSettings() }
        actions.openRoute = { [weak self] in self?.route = $0 }
    }

    var isPresented: Bool { controller?.isOpen ?? false }

    func open() { controller?.setOpen(true, animated: true) }

    func close(animated: Bool = true) { controller?.setOpen(false, animated: animated) }
}

/// What the drawer's hosting controller shows. Its content is redrawn when
/// the drawer has closed (to put a search away) or its key changed, never
/// for an open or a close.
@MainActor
private final class LedgerAgentDrawerFeed: ObservableObject {
    var make: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
    var key: AnyHashable?
    @Published var closings = 0
    @Published var insets = EdgeInsets()
}

private struct LedgerAgentDrawerHostView: View {
    @ObservedObject var feed: LedgerAgentDrawerFeed

    var body: some View {
        feed.make(feed.closings).safeAreaPadding(feed.insets)
    }
}

private struct LedgerChromeDrawsOwnBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The page draws its glass bar in a regular width too: it is inside the
    /// drawer's card, which the system navigation bar would not follow.
    var ledgerChromeDrawsOwnBar: Bool {
        get { self[LedgerChromeDrawsOwnBarKey.self] }
        set { self[LedgerChromeDrawsOwnBarKey.self] = newValue }
    }
}

@MainActor
final class LedgerAgentDrawerController: UIViewController, UIGestureRecognizerDelegate {
    var pushes = true {
        didSet { if oldValue != pushes { relayout() } }
    }
    var reduceMotion = false
    var edgeOpens = false {
        didSet { updatePan() }
    }
    private(set) var isOpen = false

    /// FlowDown's numbers: the card's corners, its distance from the safe
    /// area at the top and the bottom, how much of it stays on screen, the
    /// gap between it and the drawer, and how far the drawer slides in.
    static let cardRadius: CGFloat = 28
    static let cardInset: CGFloat = 20
    static let cardShowing: CGFloat = 40
    static let gutter: CGFloat = 20
    static let parallax: CGFloat = 70
    /// A drag this far decides, as FlowDown's sidebar does.
    static let commitDistance: CGFloat = 100
    static let springDuration: TimeInterval = 0.5
    static let springDamping: CGFloat = 0.9

    private let pageHost = UIHostingController(rootView: AnyView(EmptyView()))
    private var drawerHost: UIHostingController<AnyView>?
    private var pageContent = AnyView(EmptyView())
    /// The safe area the page and the drawer are laid out in: this view's,
    /// never their own. UIKit works out a view's safe area from where its
    /// frame lies, so a page moved into a card would lose its own and be
    /// laid out again at every open and close; they are given this one
    /// instead (`safeAreaRegions` leaves them the keyboard alone).
    private var appliedSafeArea: UIEdgeInsets?
    /// What lies behind the drawer and around the card: the drawer's ground.
    private let ground = UIView()
    /// Carries the card's transform and shadow.
    private let card = UIView()
    /// Rounds the card's corners.
    private let clip = UIView()
    /// Over the page while the drawer is out: a tap on it closes the drawer.
    /// In a regular width it also dims the page.
    private let veil = UIView()
    private let pan = UIPanGestureRecognizer()
    private let tap = UITapGestureRecognizer()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    /// Where the drawer is: how far the card is pushed (compact) or the
    /// drawer is out (regular), in points.
    private var offset: CGFloat = 0
    /// How far the page is drawn back into a card, from 0 to 1.
    private var carded: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var closings = 0
    private let drawerFeed = LedgerAgentDrawerFeed()
    private var preloaded = false
    private var dragBase: CGFloat = 0
    private var committed = false
    private var touchDown: CGPoint?
    private var lastSize: CGSize = .zero
    private var lastSafeArea: UIEdgeInsets = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        ground.backgroundColor = LedgerAgentPalette.groundTopUI
        ground.isHidden = true
        view.addSubview(ground)

        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0
        card.layer.shadowOffset = .zero
        clip.clipsToBounds = true
        clip.layer.cornerCurve = .continuous
        view.addSubview(card)
        card.addSubview(clip)

        addChild(pageHost)
        pageHost.safeAreaRegions = .keyboard
        pageHost.view.backgroundColor = .clear
        clip.addSubview(pageHost.view)
        pageHost.didMove(toParent: self)

        veil.backgroundColor = .black
        veil.alpha = 0
        veil.isHidden = true
        veil.isAccessibilityElement = true
        veil.accessibilityLabel = String(localized: "关闭历史对话")
        veil.accessibilityTraits = .button
        veil.accessibilityIdentifier = "ledger-agent-history-dismiss"
        tap.addTarget(self, action: #selector(tapped))
        veil.addGestureRecognizer(tap)

        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        updatePan()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !preloaded else { return }
        preloaded = true
        // Once the page has settled, so the drawer's first build never lands
        // on the page's own first frames.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.loadDrawer() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize || view.safeAreaInsets != lastSafeArea else { return }
        lastSize = view.bounds.size
        lastSafeArea = view.safeAreaInsets
        applySafeArea()
        relayout()
    }

    private func relayout() {
        guard isViewLoaded else { return }
        cancelMotion()
        // Frames are set with the transforms off; they go back on below.
        card.transform = .identity
        drawerHost?.view.transform = .identity
        veil.removeFromSuperview()
        let bounds = view.bounds
        ground.frame = bounds
        card.bounds = CGRect(origin: .zero, size: bounds.size)
        card.center = CGPoint(x: bounds.midX, y: bounds.midY)
        clip.frame = card.bounds
        pageHost.view.frame = clip.bounds
        if pushes {
            clip.addSubview(veil)
            veil.frame = clip.bounds
        } else {
            view.insertSubview(veil, aboveSubview: card)
            veil.frame = bounds
        }
        if let drawer = drawerHost?.view {
            drawer.frame = drawerFrame
            if pushes { view.insertSubview(drawer, belowSubview: card) } else { view.addSubview(drawer) }
        }
        offset = isOpen ? openOffset : 0
        carded = isOpen && pushes ? 1 : 0
        apply()
        settleVisibility()
    }

    // MARK: Content

    func setPage(_ page: AnyView) {
        pageContent = page
        pageHost.rootView = AnyView(page.safeAreaPadding(Self.edgeInsets(view.safeAreaInsets)))
    }

    /// The drawer's content for the next time it is drawn, and whether
    /// that is now: only when `key` changed.
    func updateDrawer(key: AnyHashable, make: @escaping (Int) -> AnyView) {
        drawerFeed.make = make
        if drawerFeed.key != key {
            drawerFeed.key = key
            drawerFeed.objectWillChange.send()
        }
    }

    private func applySafeArea() {
        guard appliedSafeArea != view.safeAreaInsets else { return }
        appliedSafeArea = view.safeAreaInsets
        setPage(pageContent)
        var insets = view.safeAreaInsets
        insets.right = 0
        drawerFeed.insets = Self.edgeInsets(insets)
    }

    private static func edgeInsets(_ insets: UIEdgeInsets) -> EdgeInsets {
        EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
    }

    /// The drawer's list is built once, soon after the page appears or when
    /// the drawer first starts to come out, and then stays under the card:
    /// building it on the first open, and drawing it again each time it
    /// came back from hidden, were the hitches at the start of an open.
    private func loadDrawer() {
        guard drawerHost == nil else { return }
        let host = UIHostingController(rootView: AnyView(LedgerAgentDrawerHostView(feed: drawerFeed)))
        host.safeAreaRegions = .keyboard
        host.view.backgroundColor = .clear
        addChild(host)
        if pushes { view.insertSubview(host.view, belowSubview: card) } else { view.addSubview(host.view) }
        host.view.frame = drawerFrame
        host.didMove(toParent: self)
        drawerHost = host
        apply()
    }

    // MARK: Geometry

    private var drawerWidth: CGFloat {
        let width = view.bounds.width
        return pushes ? max(0, width - Self.cardShowing - Self.gutter) : min(width * 0.8, 400)
    }

    /// The offset with the drawer all the way out.
    private var openOffset: CGFloat {
        pushes ? max(0, view.bounds.width - Self.cardShowing) : drawerWidth
    }

    private var drawerFrame: CGRect {
        CGRect(x: 0, y: 0, width: drawerWidth, height: view.bounds.height)
    }

    /// The page's scale as a card: the height FlowDown gives its card, 20pt
    /// inside the safe area at the top and the bottom, over the page's.
    private var cardScale: CGFloat {
        let height = view.bounds.height
        guard height > 0 else { return 1 }
        let safe = view.safeAreaInsets
        return max(0.5, (height - safe.top - safe.bottom - Self.cardInset * 2) / height)
    }

    private var progress: CGFloat { openOffset > 0 ? offset / openOffset : 0 }

    /// Puts every layer where `offset` and `carded` say, without animating
    /// unless called in an animation block.
    private func apply() {
        let size = view.bounds.size
        if pushes {
            let scale = 1 - carded * (1 - cardScale)
            let safe = view.safeAreaInsets
            // Scaled about its centre, the card's leading edge moves in by
            // half what it loses; it is moved back to sit at `offset`.
            let x = offset - size.width * (1 - scale) / 2
            let y = carded * (safe.top - safe.bottom) / 2
            card.transform = CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
            clip.layer.cornerRadius = carded * Self.cardRadius / scale
            card.layer.shadowRadius = 8 / scale
            drawerHost?.view.transform = CGAffineTransform(
                translationX: (min(1, max(0, progress)) - 1) * Self.parallax, y: 0)
            // Clear but there: a view under 1% opacity takes no touches.
            veil.backgroundColor = .clear
            veil.alpha = 1
        } else {
            card.transform = .identity
            clip.layer.cornerRadius = 0
            drawerHost?.view.transform = CGAffineTransform(translationX: offset - drawerWidth, y: 0)
            let strength: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.45 : 0.2
            veil.backgroundColor = .black
            veil.alpha = strength * min(1, max(0, progress))
        }
    }

    /// The card's shadow, faded on the card's spring rather than switched.
    private func setShadow(_ on: Bool) {
        let layer = card.layer
        let opacity: Float = on && pushes ? 0.1 : 0
        let radius = Self.cardRadius / cardScale
        layer.shadowPath = UIBezierPath(roundedRect: card.bounds, cornerRadius: radius).cgPath
        guard layer.shadowOpacity != opacity else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        fade.toValue = opacity
        fade.duration = 0.3
        layer.add(fade, forKey: "fade")
        layer.shadowOpacity = opacity
    }

    /// What is drawn, interactive and seen by VoiceOver for where the
    /// drawer is now.
    private func settleVisibility() {
        let out = isOpen || offset > 0.5 || animator != nil
        ground.isHidden = !(out && pushes)
        veil.isHidden = !isOpen
        pageHost.view.accessibilityElementsHidden = isOpen
        drawerHost?.view.accessibilityElementsHidden = !isOpen
        drawerHost?.view.accessibilityViewIsModal = isOpen
    }

    // MARK: Opening and closing

    func setOpen(_ open: Bool, animated: Bool) {
        guard isViewLoaded else {
            isOpen = open
            return
        }
        if open { loadDrawer() }
        let changed = open != isOpen
        isOpen = open
        if changed && open { haptic.impactOccurred() }
        if open { view.endEditing(true) }
        if animated {
            settle(speed: 0)
        } else {
            cancelMotion()
            offset = open ? openOffset : 0
            carded = open && pushes ? 1 : 0
            apply()
            setShadow(open)
            finished()
        }
    }

    /// Stops a running animation where it has the layers on screen now.
    func cancelMotion() {
        guard let animator else { return }
        LedgerMotionProbe.shared.end("drawer-settle")
        readPresentation()
        animator.stopAnimation(true)
        self.animator = nil
        apply()
    }

    /// `offset` and `carded` read back from what is on screen.
    private func readPresentation() {
        let width = view.bounds.width
        if pushes {
            guard let shown = card.layer.presentation()?.affineTransform() else { return }
            let scale = shown.a
            let full = 1 - cardScale
            carded = full > 0 ? min(1, max(0, (1 - scale) / full)) : 0
            offset = shown.tx + width * (1 - scale) / 2
        } else if let shown = drawerHost?.view.layer.presentation()?.affineTransform() {
            offset = shown.tx + drawerWidth
        }
    }

    /// Brings the drawer to where `isOpen` says, carrying on at `speed`
    /// (points per second) from a finger that let go of it.
    private func settle(speed: CGFloat) {
        cancelMotion()
        let target = isOpen ? openOffset : 0
        let targetCard: CGFloat = isOpen && pushes ? 1 : 0
        let distance = target - offset
        // A spring's initial velocity is a share of the distance per second;
        // a fling faster than the distance allows is capped so the card does
        // not overshoot far past its place.
        let relative = abs(distance) > 1 ? min(12, max(-12, speed / distance)) : 0
        let timing: UITimingCurveProvider = reduceMotion
            ? UICubicTimingParameters(animationCurve: .easeInOut)
            : UISpringTimingParameters(dampingRatio: Self.springDamping,
                                       initialVelocity: CGVector(dx: relative, dy: 0))
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? 0.2 : Self.springDuration,
                                              timingParameters: timing)
        self.animator = animator
        LedgerMotionProbe.shared.begin("drawer-settle")
        settleVisibility()
        setShadow(isOpen)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            offset = target
            carded = targetCard
            apply()
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, self.animator === animator else { return }
            self.animator = nil
            LedgerMotionProbe.shared.end("drawer-settle")
            finished()
        }
        animator.startAnimation()
    }

    private func finished() {
        settleVisibility()
        updatePan()
        if !isOpen {
            // Out of sight now: a search in it is put away.
            closings += 1
            drawerFeed.closings = closings
        }
    }

    @objc private func tapped() {
        guard isOpen else { return }
        setOpen(false, animated: true)
    }

    // MARK: Dragging

    private enum Mode { case off, opens, closes }

    private var mode: Mode {
        guard view.bounds.width > 0 else { return .off }
        if isOpen { return .closes }
        return edgeOpens ? .opens : .off
    }

    private func updatePan() {
        let enabled = mode != .off
        // A drag in progress keeps going; only a new one reads the change.
        if pan.isEnabled != enabled && (enabled || pan.state == .possible) { pan.isEnabled = enabled }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: view).x
        switch pan.state {
        case .began:
            LedgerMotionProbe.shared.begin("drawer-drag")
            loadDrawer()
            cancelMotion()
            dragBase = offset
            committed = false
            view.endEditing(true)
            ground.isHidden = !pushes
            dragged(dx)
        case .changed:
            dragged(dx)
        case .ended:
            LedgerMotionProbe.shared.end("drawer-drag")
            released(dx, speed: pan.velocity(in: view).x)
        case .cancelled, .failed:
            LedgerMotionProbe.shared.end("drawer-drag")
            released(dx, speed: 0)
        default:
            break
        }
    }

    private func dragged(_ dx: CGFloat) {
        guard !committed else { return }
        // Far enough to say which way: the spring takes it from here.
        if !isOpen && dx > Self.commitDistance {
            committed = true
            setOpen(true, animated: true)
            return
        }
        if isOpen && dx < -Self.commitDistance {
            committed = true
            setOpen(false, animated: true)
            return
        }
        // FlowDown's drag only moves the page sideways; drawing it back into
        // a card waits for the decision.
        offset = min(openOffset, max(0, dragBase + dx))
        apply()
    }

    private func released(_ dx: CGFloat, speed: CGFloat) {
        guard !committed else {
            committed = false
            return
        }
        let moved = offset - dragBase
        let open: Bool
        if isOpen {
            open = !(moved < -Self.commitDistance / 2 || speed < -300)
        } else {
            open = moved > Self.commitDistance / 2 || speed > 300
        }
        if open != isOpen {
            isOpen = open
            if open { haptic.impactOccurred() }
        }
        settle(speed: speed)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if recognizer === pan { touchDown = touch.location(in: view) }
        return true
    }

    /// A drag starts only mostly sideways and in the direction of `mode`,
    /// on this page and nothing presented over it, and not over something a
    /// drag to the right already means something to.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return true }
        let mode = mode
        guard mode != .off, presentedViewController == nil else { return false }
        let now = pan.location(in: view)
        let start = touchDown ?? now
        var moved = CGPoint(x: now.x - start.x, y: now.y - start.y)
        if moved == .zero { moved = pan.velocity(in: view) }
        // Mostly sideways: a slanted scroll of the conversation stays a scroll.
        guard abs(moved.x) > abs(moved.y) * 1.2 else { return false }
        guard mode == .opens ? moved.x > 0 : moved.x < 0 else { return false }
        if mode == .closes { return true }
        if start.x <= view.safeAreaInsets.left + 24 { return true }
        guard let hit = view.hitTest(start, with: nil) else { return true }
        return !Self.claimsRightwardDrag(from: hit, upTo: view)
    }

    /// A slider or other control, or a scroll view scrolled away from its
    /// leading end (a wide table, a code block).
    private static func claimsRightwardDrag(from hit: UIView, upTo page: UIView) -> Bool {
        var current: UIView? = hit
        while let view = current, view !== page {
            if view is UISlider || view is UISwitch || view is UIDatePicker { return true }
            if let scroll = view as? UIScrollView {
                let insets = scroll.adjustedContentInset
                let scrollsSideways = scroll.contentSize.width + insets.left + insets.right > scroll.bounds.width + 1
                if scrollsSideways && scroll.contentOffset.x > -insets.left + 1 { return true }
            }
            current = view.superview
        }
        return false
    }

    /// The page's and the drawer's own drags, scrolls and row swipes among
    /// them, wait to see whether this one takes the touch. It decides on the
    /// first movement, so they start as soon as it does not.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard recognizer === pan, other !== pan, other is UIPanGestureRecognizer,
              let otherView = other.view else { return false }
        return otherView.isDescendant(of: view)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isOpen else { return false }
        setOpen(false, animated: true)
        return true
    }
}
#endif
