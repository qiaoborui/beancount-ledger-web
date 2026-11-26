#if os(iOS)
import SwiftUI
import UIKit

/// One row of the conversation: a question, an answer, the running turn, a
/// card under them. The row is drawn by SwiftUI inside a UIKit cell, and
/// drawn again only when its `token` changes; a keystroke, the keyboard or
/// another row changing leaves it alone.
struct LedgerAgentListRow {
    let id: String
    let token: LedgerAgentRowToken
    let content: AnyView

    init<Token: Equatable, Content: View>(id: String, token: Token, @ViewBuilder content: () -> Content) {
        self.id = id
        self.token = LedgerAgentRowToken(token)
        self.content = AnyView(content())
    }
}

/// What a row shows, compared by value.
struct LedgerAgentRowToken: Equatable {
    private let value: Any
    private let same: (Any) -> Bool

    init<Value: Equatable>(_ value: Value) {
        self.value = value
        same = { ($0 as? Value) == value }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.same(rhs.value) }
}

/// What the page around the list needs from it: whether to show the jump
/// button, and the scrolls it asks for. Only `showsJump` is published, so
/// scrolling redraws the button alone.
@MainActor
final class LedgerAgentListModel: ObservableObject {
    @Published fileprivate(set) var showsJump = false
    fileprivate weak var list: LedgerAgentListView?

    /// Follows the conversation again and goes to its end.
    func jumpToBottom() { list?.jump() }

    /// New content: shown when the list follows, or always with `force` (a
    /// question just sent).
    func follow(force: Bool = false) { list?.follow(force: force) }

    /// The reader is reading back: new content no longer moves the list.
    func pause() { list?.following = false }
}

/// The conversation as a UIKit list, the way FlowDown's `MessageListView`
/// is one: cells keep their measured heights, only changed rows are drawn
/// again, and following the reply is a matter of the scroll view's offset
/// after each layout, not of SwiftUI scrolling to an anchor.
struct LedgerAgentMessageList: UIViewRepresentable {
    var rows: [LedgerAgentListRow]
    /// The bar and the composer (and the keyboard) over the list.
    var insets: EdgeInsets
    /// A turn is running; the jump button stays away while it is followed.
    var running: Bool
    let model: LedgerAgentListModel
    var onTap: () -> Void = {}

    func makeUIView(context: Context) -> LedgerAgentListView {
        let view = LedgerAgentListView()
        view.model = model
        model.list = view
        return view
    }

    func updateUIView(_ view: LedgerAgentListView, context: Context) {
        model.list = view
        view.onTap = onTap
        view.running = running
        view.apply(rows: rows, environment: context.environment, pause: model)
        view.setInsets(UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0),
                       animated: context.transaction.animation != nil)
    }
}

@MainActor
final class LedgerAgentListView: UIView, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    /// Within this many points of the end still counts as at it.
    static let slack: CGFloat = 24
    static let spacing: CGFloat = 22

    weak var model: LedgerAgentListModel?
    var onTap: () -> Void = {}
    var running = false {
        didSet {
            collection.growsWithoutAnimation = running
            if running != oldValue { updateJump() }
        }
    }
    /// New content moves the list to its end. Reading back turns it off;
    /// coming to rest at the end, the jump button or sending turns it on.
    var following = true {
        didSet { if following != oldValue { updateJump() } }
    }

    private let collection: LedgerAgentListCollectionView
    private var source: UICollectionViewDiffableDataSource<Int, String>!
    private var rows: [String: LedgerAgentListRow] = [:]
    private var order: [String] = []
    private var environment = EnvironmentValues()
    private var pause: LedgerAgentFollowPause?
    private var insets = UIEdgeInsets.zero
    private var readerScrolling = false

    override init(frame: CGRect) {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = LedgerAgentListView.spacing
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 8, trailing: 20)
            return section
        }
        collection = LedgerAgentListCollectionView(frame: frame, collectionViewLayout: layout)
        super.init(frame: frame)
        backgroundColor = .clear
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.automaticallyAdjustsScrollIndicatorInsets = false
        collection.alwaysBounceVertical = true
        collection.keyboardDismissMode = .interactive
        collection.delegate = self
        collection.accessibilityIdentifier = "ledger-agent-list"
        if #available(iOS 26.0, *) {
            collection.topEdgeEffect.style = .soft
        }
        collection.didLayout = { [weak self] in self?.laidOut() }
        addSubview(collection)

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        source = UICollectionViewDiffableDataSource(collectionView: collection) { view, path, id in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: id)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collection.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if collection.frame != bounds { collection.frame = bounds }
    }

    // MARK: Rows

    func apply(rows newRows: [LedgerAgentListRow], environment: EnvironmentValues, pause: LedgerAgentListModel) {
        self.environment = environment
        if self.pause == nil {
            self.pause = LedgerAgentFollowPause { [weak pause] in pause?.pause() }
        }
        let ids = newRows.map(\.id)
        var changed: [String] = []
        var next: [String: LedgerAgentListRow] = [:]
        for row in newRows {
            if let old = rows[row.id], old.token != row.token { changed.append(row.id) }
            next[row.id] = row
        }
        rows = next
        if ids != order {
            order = ids
            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            source.apply(snapshot, animatingDifferences: false)
        }
        // A changed row on screen is drawn again in its cell; one off screen
        // is drawn when it comes on.
        for id in changed {
            guard let path = source.indexPath(for: id), let cell = collection.cellForItem(at: path) else { continue }
            configure(cell, id: id)
        }
        updateJump()
    }

    private func configure(_ cell: UICollectionViewCell, id: String) {
        guard let row = rows[id] else { return }
        cell.contentConfiguration = UIHostingConfiguration {
            row.content
                .frame(maxWidth: .infinity, alignment: .leading)
                // A reused cell is another row: its state starts afresh
                // rather than carrying the last row's (a group left open).
                .id(id)
                // Opening a tool group or reasoning block is reading back:
                // the rows it shows stay where they were tapped.
                .environment(\.ledgerAgentFollowPause, pause)
                .environment(\.self, environment)
        }
        .margins(.all, 0)
        cell.backgroundConfiguration = .clear()
    }

    // MARK: Insets

    func setInsets(_ new: UIEdgeInsets, animated: Bool) {
        // Less than half a point is an animation's in-between value, not a
        // new bar or composer: setting it would lay the rows out again.
        guard abs(new.top - insets.top) >= 0.5 || abs(new.bottom - insets.bottom) >= 0.5 else { return }
        let atEnd = following || distanceToEnd <= Self.slack
        let grew = abs(new.bottom - insets.bottom) > 40
        insets = new
        let change = { [self] in
            collection.contentInset = new
            collection.verticalScrollIndicatorInsets = new
            // The keyboard or a taller composer covers the end: the list
            // keeps it in view, in the same motion.
            if atEnd { scrollToEnd() }
        }
        if animated || grew {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
        } else {
            change()
        }
    }

    // MARK: Following

    /// The content is taller than the space between the bar and the
    /// composer. Until it is, the list rests at its top.
    private var overflows: Bool {
        collection.contentSize.height > collection.bounds.height - insets.top - insets.bottom + 1
    }

    private var endOffset: CGFloat {
        guard overflows else { return -insets.top }
        return collection.contentSize.height + insets.bottom - collection.bounds.height
    }

    private var distanceToEnd: CGFloat { endOffset - collection.contentOffset.y }

    private func scrollToEnd(animated: Bool = false) {
        let target = CGPoint(x: 0, y: endOffset)
        guard abs(collection.contentOffset.y - target.y) > 0.5 else { return }
        collection.setContentOffset(target, animated: animated)
    }

    /// After each layout: rows took their heights, a reply grew. A list that
    /// follows keeps its end in view.
    private func laidOut() {
        if following && !readerScrolling { scrollToEnd() }
        updateJump()
    }

    func follow(force: Bool) {
        if force { following = true }
        guard following else { return }
        collection.layoutIfNeeded()
        scrollToEnd(animated: true)
    }

    func jump() {
        following = true
        // A list still coasting stops where it is told; an animated scroll
        // would be fought by it.
        scrollToEnd(animated: !readerScrolling)
        readerScrolling = false
    }

    private func updateJump() {
        let shows = !order.isEmpty && overflows && distanceToEnd > Self.slack && !(following && running)
        if model?.showsJump != shows { model?.showsJump = shows }
    }

    @objc private func tapped() { onTap() }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        readerScrolling = true
        following = false
        LedgerMotionProbe.shared.begin("list-scroll")
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { cameToRest() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { cameToRest() }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { following = false }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateJump() }

    /// Where the reader left the list decides whether it follows.
    private func cameToRest() {
        LedgerMotionProbe.shared.end("list-scroll")
        readerScrolling = false
        following = distanceToEnd <= Self.slack
    }
}

/// Reports each layout, after which the list may move to its end.
final class LedgerAgentListCollectionView: UICollectionView {
    var didLayout: (() -> Void)?
    /// While a reply streams in, a row that grew takes its new height at
    /// once. A hosting cell's self-sizing is otherwise applied as an animated
    /// change: the list moved to the new end in the same pass, but the row
    /// grew into it over a few frames, crossfading its old and new text, so
    /// every new line made the reply jump up and settle back. FlowDown sizes
    /// a row before showing it and moves the row and the offset together;
    /// here the row's size is applied in the same frame as the offset.
    var growsWithoutAnimation = false
    private var lastContentHeight: CGFloat = -1
    private var lastHeight: CGFloat = -1

    override func layoutSubviews() {
        if growsWithoutAnimation {
            UIView.performWithoutAnimation { super.layoutSubviews() }
        } else {
            super.layoutSubviews()
        }
        guard contentSize.height != lastContentHeight || bounds.height != lastHeight else { return }
        lastContentHeight = contentSize.height
        lastHeight = bounds.height
        didLayout?()
    }
}
#endif
