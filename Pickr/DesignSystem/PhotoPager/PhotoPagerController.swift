import PickrCore
import UIKit

/// The UIKit side of `PhotoPager`: a horizontal `UICollectionView` of zoomable pages.
///
/// - Pages are inset by a gutter so photos sit apart while you swipe; drags snap to whole
///   pages with custom snapping, since `isPagingEnabled` would snap to the view width.
/// - Geometry always comes from the view's own bounds, never the screen, so resizable
///   scenes and the iPhone Duo keep the current photo in place.
/// - One VoiceOver element: adjustable paging, a Keep/Unkeep custom action, and
///   three-finger scrolling.
final class PhotoPagerController: UIViewController {
    /// Everything SwiftUI hands over on each update.
    struct Configuration {
        var photos: [PhotoID]
        var index: Int
        var loader: any ImageLoading
        var badge: (PhotoID) -> PagerBadge
        var accessibilityLabel: (Int) -> String
        var onIndexChange: (Int) -> Void
        var onSwipeUp: (() -> Void)?
        var onTap: (() -> Void)?
        var onKeepAction: ((Int) -> Void)?
        var reduceMotion: Bool
        var prefersReducedResourceUsage: Bool

        static let empty = Configuration(
            photos: [],
            index: 0,
            loader: NoImageLoader(),
            badge: { _ in .none },
            accessibilityLabel: { _ in "" },
            onIndexChange: { _ in },
            onSwipeUp: nil,
            onTap: nil,
            onKeepAction: nil,
            reduceMotion: false,
            prefersReducedResourceUsage: false
        )
    }

    private var config = Configuration.empty
    private var photos: [PhotoID] { config.photos }
    /// The page in view. Leads the binding while the user drags; follows it otherwise.
    private(set) var currentIndex = 0

    private let pagerView = PagerAccessibilityView()
    private let layout = PagerLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: UICollectionViewDiffableDataSource<Int, PagerItem>?
    private var hasAppliedData = false
    private let swipeUp = UISwipeGestureRecognizer()
    /// Set when a swipe up cancels a diagonal drag, so that drag settles on the page it
    /// started from instead of flicking to a neighbour.
    private var swipeUpCancelledDrag = false
    private var laidOutSize: CGSize = .zero
    private var preheat = Preheat()

    private var geometry: PagerGeometry { PagerGeometry(bounds: collectionView.bounds.size) }

    // MARK: - View lifecycle

    override func loadView() {
        view = pagerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        pagerView.accessibilityLabel = String(
            localized: "Photos",
            comment: "VoiceOver label of the single-photo pager; its value describes the photo in view"
        )
        pagerView.increment = { [weak self] in _ = self?.move(by: 1) }
        pagerView.decrement = { [weak self] in _ = self?.move(by: -1) }
        pagerView.scroll = { [weak self] direction in self?.pageForAccessibilityScroll(direction) ?? false }
        pagerView.windowDidChange = { [weak self] in self?.updatePreheating() }

        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        // Capture order runs left to right in every layout direction; the offsets assume it.
        collectionView.semanticContentAttribute = .forceLeftToRight
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.isPagingEnabled = false
        collectionView.decelerationRate = .fast
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = false
        collectionView.scrollsToTop = false
        collectionView.allowsSelection = false
        // Only pages in view load: no speculative full-size work for pages further away.
        collectionView.isPrefetchingEnabled = false
        collectionView.delegate = self
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<PagerCell, PagerItem> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }

        swipeUp.direction = .up
        swipeUp.delegate = self
        swipeUp.addTarget(self, action: #selector(handleSwipeUp(_:)))
        collectionView.addGestureRecognizer(swipeUp)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        guard size != laidOutSize else { return }
        // A resize (first layout, iPhone Duo fold or unfold): re-measure, keep the photo in view.
        laidOutSize = size
        layout.pinnedPage = currentIndex
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        scroll(to: currentIndex, animated: false)
        let viewerSize = geometry.viewerSize
        for cell in collectionView.visibleCells {
            (cell as? PagerCell)?.updateTargetSize(viewerSize)
        }
        updatePreheating()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopPreheating()
    }

    // MARK: - Updates from SwiftUI

    func update(_ new: Configuration) {
        loadViewIfNeeded()
        let old = config
        config = new
        swipeUp.isEnabled = new.onSwipeUp != nil

        let target = PagerGeometry.clamp(new.index, count: new.photos.count)
        if new.photos != old.photos || !hasAppliedData {
            setCurrentIndex(target, notify: false)
            applyData()
        } else if target != currentIndex, !collectionView.isTracking, !collectionView.isDragging {
            // The index changed outside the pager (a filmstrip tap). A user drag in
            // progress wins: its own report follows when it settles.
            let distance = abs(target - currentIndex)
            setCurrentIndex(target, notify: false)
            scroll(to: target, animated: !new.reduceMotion && distance == 1)
        }
        if target != new.index, !new.photos.isEmpty {
            writeBack(target)
        }
        if new.prefersReducedResourceUsage != old.prefersReducedResourceUsage {
            updatePreheating()
        }
        refreshVisibleCells()
        updateAccessibility()
    }

    /// Cancels every image request and preheat. Called when SwiftUI removes the pager.
    func tearDown() {
        stopPreheating()
        for cell in collectionView.visibleCells {
            (cell as? PagerCell)?.unload()
        }
    }

    private func applyData() {
        guard let dataSource else { return }
        hasAppliedData = true
        var snapshot = NSDiffableDataSourceSnapshot<Int, PagerItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(PagerItem.items(for: photos))
        // Pages that stay keep their cells and images (for example when Review drops a
        // photo that left the library).
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.layoutIfNeeded()
        scroll(to: currentIndex, animated: false)
        updatePreheating()
    }

    /// Corrects an out-of-range binding after the update pass (never during it).
    private func writeBack(_ index: Int) {
        Task { [weak self] in
            guard let self, self.currentIndex == index else { return }
            self.config.onIndexChange(index)
        }
    }

    // MARK: - Index and scrolling

    private func setCurrentIndex(_ index: Int, notify: Bool) {
        let changed = index != currentIndex
        currentIndex = index
        layout.pinnedPage = index
        guard changed else { return }
        // A zoomed neighbour that is now only peeking returns to 1×.
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.item != index {
            (collectionView.cellForItem(at: indexPath) as? PagerCell)?.resetZoom(animated: false)
        }
        updatePreheating()
        updateAccessibility()
        if notify {
            config.onIndexChange(index)
        }
    }

    private func scroll(to index: Int, animated: Bool) {
        let geometry = geometry
        guard geometry.isUsable, photos.indices.contains(index) else { return }
        let target = geometry.offset(for: index)
        guard abs(collectionView.contentOffset.x - target.x) > 0.5 || abs(collectionView.contentOffset.y) > 0.5 else {
            return
        }
        collectionView.setContentOffset(target, animated: animated)
    }

    /// Moves by whole pages for VoiceOver. Returns false at either end.
    private func move(by step: Int) -> Bool {
        let target = currentIndex + step
        guard photos.indices.contains(target) else { return false }
        setCurrentIndex(target, notify: true)
        scroll(to: target, animated: !config.reduceMotion)
        return true
    }

    /// Reports the page under a user drag or its deceleration.
    private func updateIndexFromOffset() {
        let index = geometry.index(at: collectionView.contentOffset.x, count: photos.count)
        if photos.indices.contains(index), index != currentIndex {
            setCurrentIndex(index, notify: true)
        }
    }

    private var currentCell: PagerCell? {
        guard photos.indices.contains(currentIndex) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? PagerCell
    }

    // MARK: - Cells

    private func configure(_ cell: PagerCell, for item: PagerItem) {
        // The root view keeps the app's direction; the collection view is forced left to right.
        cell.isRightToLeft = pagerView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        cell.configure(photo: item.id, badge: config.badge(item.id), loader: config.loader,
                       targetSize: geometry.viewerSize)
        cell.onSingleTap = { [weak self] in self?.config.onTap?() }
        cell.onStatusChange = { [weak self] in self?.updateAccessibility() }
    }

    /// Pushes the latest badges to the pages in view (with a crossfade).
    private func refreshVisibleCells() {
        guard let dataSource else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? PagerCell,
                  let item = dataSource.itemIdentifier(for: indexPath)
            else { continue }
            cell.setBadge(config.badge(item.id), animated: true)
        }
    }

    // MARK: - Swipe up

    @objc private func handleSwipeUp(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, let onSwipeUp = config.onSwipeUp, !photos.isEmpty else { return }
        // A diagonal flick must not page as well: cancel the drag; it settles where it began.
        let pan = collectionView.panGestureRecognizer
        if pan.state == .began || pan.state == .changed {
            swipeUpCancelledDrag = true
            pan.isEnabled = false
            pan.isEnabled = true
        }
        onSwipeUp()
        // The badge change crossfades on the next update; the hop is extra motion.
        if !config.reduceMotion {
            currentCell?.hop()
        }
    }

    // MARK: - Preheating (§4.6: ±1 at the viewer class; none under reduced resource usage)

    private struct Preheat {
        var ids: [PhotoID] = []
        var size: CGSize = .zero
        var loader: (any ImageLoading)?
    }

    private func updatePreheating() {
        let geometry = geometry
        guard isViewLoaded, view.window != nil, geometry.isUsable, !config.prefersReducedResourceUsage,
              photos.indices.contains(currentIndex)
        else {
            stopPreheating()
            return
        }
        let size = geometry.viewerSize
        if size != preheat.size {
            stopPreheating()
        }
        let window = (currentIndex - 1 ... currentIndex + 1).filter(photos.indices.contains).map { photos[$0] }
        let leaving = preheat.ids.filter { !window.contains($0) }
        let entering = window.filter { !preheat.ids.contains($0) }
        if !leaving.isEmpty {
            (preheat.loader ?? config.loader).stopPreheating(leaving, size: .viewer(preheat.size))
        }
        if !entering.isEmpty {
            config.loader.preheat(entering, size: .viewer(size))
        }
        preheat = Preheat(ids: window, size: size, loader: config.loader)
    }

    private func stopPreheating() {
        if let loader = preheat.loader, !preheat.ids.isEmpty {
            loader.stopPreheating(preheat.ids, size: .viewer(preheat.size))
        }
        preheat = Preheat()
    }

    // MARK: - Accessibility

    private func updateAccessibility() {
        guard isViewLoaded else { return }
        guard photos.indices.contains(currentIndex) else {
            pagerView.accessibilityValue = nil
            pagerView.accessibilityCustomActions = nil
            return
        }
        let description = config.accessibilityLabel(currentIndex)
        if let status = currentCell?.status {
            pagerView.accessibilityValue = String(
                localized: "\(description), \(status.message)",
                comment: "VoiceOver value of the photo pager: the photo's description, then why it isn't sharp"
            )
        } else {
            pagerView.accessibilityValue = description
        }

        guard config.onKeepAction != nil else {
            pagerView.accessibilityCustomActions = nil
            return
        }
        let isKept = config.badge(photos[currentIndex]) == .kept
        let name = isKept
            ? String(localized: "Unkeep", comment: "VoiceOver action in the photo pager: stop keeping this photo")
            : String(localized: "Keep", comment: "VoiceOver action in the photo pager: keep this photo")
        guard pagerView.accessibilityCustomActions?.first?.name != name else { return }
        pagerView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self, let onKeepAction = self.config.onKeepAction,
                      self.photos.indices.contains(self.currentIndex)
                else { return false }
                onKeepAction(self.currentIndex)
                return true
            },
        ]
    }

    private func pageForAccessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: Int
        switch direction {
        case .left, .next: step = 1
        case .right, .previous: step = -1
        default: return false
        }
        guard move(by: step) else { return false }
        UIAccessibility.post(notification: .pageScrolled, argument: pagerView.accessibilityValue)
        return true
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension PhotoPagerController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        geometry.itemSize
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        insetForSectionAt section: Int) -> UIEdgeInsets {
        geometry.sectionInset
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        PagerGeometry.gutter
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // A page that scrolled away was unloaded; load it again if UIKit shows it once more.
        guard let cell = cell as? PagerCell, cell.photoID == nil,
              let item = dataSource?.itemIdentifier(for: indexPath)
        else { return }
        configure(cell, for: item)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // Off screen: cancel its requests and free its image now, not when it is reused.
        (cell as? PagerCell)?.unload()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Only user drags report; programmatic scrolls already set the index.
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        updateIndexFromOffset()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let geometry = geometry
        guard geometry.isUsable, !photos.isEmpty else { return }
        let index: Int
        if swipeUpCancelledDrag {
            swipeUpCancelledDrag = false
            index = currentIndex
        } else {
            index = geometry.targetIndex(from: scrollView.contentOffset.x, proposed: targetContentOffset.pointee.x,
                                         velocity: velocity.x, count: photos.count)
        }
        targetContentOffset.pointee = geometry.offset(for: index)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateIndexFromOffset()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateIndexFromOffset()
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PhotoPagerController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeUp else { return true }
        // A zoomed photo pans vertically instead.
        return config.onSwipeUp != nil && !(currentCell?.isZoomed ?? false)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Swipe up runs alongside the pager's pan and the page's pinch, so neither swallows it.
        gestureRecognizer === swipeUp
    }
}

// MARK: - Geometry

/// Page geometry for a pager of a given size. Pages have a `gutter` on each side, so photos
/// sit apart while you swipe; drags snap to whole `stride`s. No neighbour peeks in at rest
/// (`peek` 0): a 12 pt sliver of a portrait neighbour read as a glitch on device.
nonisolated struct PagerGeometry: Equatable {
    static let peek: CGFloat = 0
    static let gutter: CGFloat = 8
    /// Horizontal release speed, in points per millisecond, that counts as a flick.
    static let flickVelocity: CGFloat = 0.2

    var bounds: CGSize

    var itemSize: CGSize {
        CGSize(width: max(0, bounds.width - 2 * (Self.peek + Self.gutter)), height: max(0, bounds.height))
    }

    var stride: CGFloat { itemSize.width + Self.gutter }

    var sectionInset: UIEdgeInsets {
        UIEdgeInsets(top: 0, left: Self.peek + Self.gutter, bottom: 0, right: Self.peek + Self.gutter)
    }

    var isUsable: Bool { itemSize.width >= 1 && itemSize.height >= 1 }

    /// The `viewer` size class size for a page, in whole points, so requests and preheating
    /// share one cache key.
    var viewerSize: CGSize {
        CGSize(width: itemSize.width.rounded(), height: itemSize.height.rounded())
    }

    func offset(for index: Int) -> CGPoint {
        CGPoint(x: CGFloat(max(index, 0)) * stride, y: 0)
    }

    /// The page nearest to a content offset.
    func index(at offsetX: CGFloat, count: Int) -> Int {
        guard isUsable, count > 0 else { return 0 }
        return Self.clamp(Int((offsetX / stride).rounded()), count: count)
    }

    /// The page a drag released at `offsetX` settles on: never more than one page away
    /// from where the finger lifted; a flick goes to the neighbour in its direction.
    func targetIndex(from offsetX: CGFloat, proposed proposedX: CGFloat, velocity: CGFloat, count: Int) -> Int {
        guard isUsable, count > 0 else { return 0 }
        let position = offsetX / stride
        let target: CGFloat
        if velocity > Self.flickVelocity {
            target = position.rounded(.up)
        } else if velocity < -Self.flickVelocity {
            target = position.rounded(.down)
        } else {
            target = min(max((proposedX / stride).rounded(), position.rounded(.down)), position.rounded(.up))
        }
        return Self.clamp(Int(target), count: count)
    }

    static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

/// A page's identity in the data source. `occurrence` keeps identifiers unique even if a
/// photo appears twice, which a diffable data source would not accept.
nonisolated struct PagerItem: Hashable, Sendable {
    let id: PhotoID
    let occurrence: Int

    static func items(for photos: [PhotoID]) -> [PagerItem] {
        var seen: [PhotoID: Int] = [:]
        return photos.map { id in
            let occurrence = seen[id, default: 0]
            seen[id] = occurrence + 1
            return PagerItem(id: id, occurrence: occurrence)
        }
    }
}

// MARK: - Layout

/// A horizontal flow layout (sizes come from the delegate) that keeps `pinnedPage` in view
/// whenever UIKit recomputes the content offset: resizes and data updates.
final class PagerLayout: UICollectionViewFlowLayout {
    /// The page to keep in view; the controller sets it to the current page.
    var pinnedPage = 0

    override init() {
        super.init()
        scrollDirection = .horizontal
        minimumInteritemSpacing = 0
        minimumLineSpacing = PagerGeometry.gutter
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagerLayout is built in code")
    }

    override var flipsHorizontallyInOppositeLayoutDirection: Bool { false }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        // Page sizes depend on the bounds: ask the delegate again.
        (context as? UICollectionViewFlowLayoutInvalidationContext)?.invalidateFlowLayoutDelegateMetrics = true
        return context
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        guard let collectionView else { return proposedContentOffset }
        let geometry = PagerGeometry(bounds: collectionView.bounds.size)
        guard geometry.isUsable else { return proposedContentOffset }
        return geometry.offset(for: pinnedPage)
    }
}

// MARK: - Accessibility element

/// The pager's root view and its single VoiceOver element. VoiceOver swipes up and down to
/// page (adjustable), scrolls with three fingers, and finds Keep/Unkeep under Actions.
final class PagerAccessibilityView: UIView {
    var increment: () -> Void = {}
    var decrement: () -> Void = {}
    var scroll: (UIAccessibilityScrollDirection) -> Bool = { _ in false }
    var windowDidChange: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityIdentifier = "PhotoPager"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagerAccessibilityView is built in code")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowDidChange()
    }

    override func accessibilityIncrement() {
        increment()
    }

    override func accessibilityDecrement() {
        decrement()
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        scroll(direction)
    }

    /// Activation is consumed: a tap would hide the bars, taking the controls away from
    /// VoiceOver. Keep and paging have their own accessible paths.
    override func accessibilityActivate() -> Bool {
        true
    }
}
