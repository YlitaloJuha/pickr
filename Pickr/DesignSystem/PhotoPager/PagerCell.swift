import PickrCore
import UIKit

/// One page of the `PhotoPager`: a zoomable photo with its badge, a loading indicator and,
/// when needed, a note that the photo couldn't be loaded.
///
/// **Loading** goes through `ImageLoading`, never at the original's full size:
/// 1. a quick `tile` image (usually already cached by the grid) so the page is never blank;
/// 2. the `viewer` image at the page size, which replaces it;
/// 3. a `viewer` image at twice the page size, only once the zoom passes 1.5×.
///
/// Every request is a task that ends its stream, and so cancels the PhotoKit request, in
/// `prepareForReuse`, when the page scrolls away (`unload()`) and when the cell goes away.
final class PagerCell: UICollectionViewCell {
    /// The zoom beyond which the page asks for an image twice the page size.
    static let detailZoomThreshold: CGFloat = 1.5
    /// How far the page hops up to acknowledge a swipe up.
    static let hopDistance: CGFloat = 50

    /// Why a page has no sharp photo.
    enum Status: Equatable {
        /// The full-quality photo couldn't be downloaded; a lower-quality version is shown.
        case offline
        /// Nothing could be loaded.
        case unavailable

        var message: String {
            switch self {
            case .offline:
                String(localized: "Couldn't download from iCloud",
                       comment: "Photo pager: the full-quality photo couldn't be downloaded; a blurry preview is shown")
            case .unavailable:
                String(localized: "Couldn't load this photo",
                       comment: "Photo pager: no image could be loaded for this photo")
            }
        }

        var systemImage: String {
            switch self {
            case .offline: "icloud.slash"
            case .unavailable: "exclamationmark.triangle"
            }
        }
    }

    private enum Quality: Int, Comparable {
        case none, placeholder, viewer, detail

        static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private enum Phase {
        case idle, loading, loaded, failed
    }

    /// Called for a single tap on the photo (after a double-tap is ruled out).
    var onSingleTap: (() -> Void)?
    /// Called when `status` changes, so the pager can update its VoiceOver value.
    var onStatusChange: (() -> Void)?

    /// The photo this page shows, or nil once unloaded.
    private(set) var photoID: PhotoID?
    /// Why the photo isn't sharp, if it isn't.
    private(set) var status: Status? {
        didSet {
            guard status != oldValue else { return }
            applyStatus()
            onStatusChange?()
        }
    }

    /// True while the photo is zoomed in (swipe up is ignored then).
    var isZoomed: Bool { zoomView.isZoomed }

    /// The app's layout direction. The pager forces its collection view left to right
    /// (capture order), so the page is told the real direction for badge corners.
    var isRightToLeft = false {
        didSet {
            guard isRightToLeft != oldValue else { return }
            statusView.isRightToLeft = isRightToLeft
            setNeedsLayout()
        }
    }

    /// Holds everything on the page. It, not `contentView`, hops: UIKit lays out
    /// `contentView` by frame, which a transform would break.
    private let pageView = UIView()
    private let zoomView = ZoomingImageView()
    private let activityBackdrop = UIView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusView = PagerStatusView()
    private var badgeView: UIImageView?

    private var badge: PagerBadge = .none
    private var loader: (any ImageLoading)?
    /// The page size in points: the `viewer` size class.
    private var targetSize: CGSize = .zero
    private var viewerRequestSize: CGSize = .zero
    private var shown = Quality.none
    private var placeholderPhase = Phase.idle
    private var viewerPhase = Phase.idle
    private var placeholderTask: Task<Void, Never>?
    private var viewerTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var activityRevealTask: Task<Void, Never>?
    private var isActivityVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(pageView)

        zoomView.onSingleTap = { [weak self] in self?.onSingleTap?() }
        zoomView.onZoomChange = { [weak self] in self?.zoomDidChange() }
        pageView.addSubview(zoomView)

        activityBackdrop.backgroundColor = .secondarySystemBackground
        activityBackdrop.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        activityBackdrop.layer.cornerRadius = 20
        activityBackdrop.alpha = 0
        activityIndicator.hidesWhenStopped = false
        activityIndicator.center = CGPoint(x: 20, y: 20)
        activityBackdrop.addSubview(activityIndicator)
        pageView.addSubview(activityBackdrop)

        statusView.isHidden = true
        pageView.addSubview(statusView)

        // The pager is the single VoiceOver element; its value carries this page's state.
        contentView.accessibilityElementsHidden = true

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: PagerCell, _: UITraitCollection) in
            cell.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagerCell is built in code")
    }

    isolated deinit {
        cancelRequests()
    }

    // MARK: - Configuration

    /// Shows `photo`. Reconfiguring with the photo already shown only updates the badge
    /// (with a crossfade) and the page size.
    func configure(photo: PhotoID, badge: PagerBadge, loader: any ImageLoading, targetSize: CGSize) {
        if photo == photoID {
            setBadge(badge, animated: true)
            updateTargetSize(targetSize)
            return
        }
        unload()
        photoID = photo
        self.loader = loader
        self.targetSize = targetSize
        setBadge(badge, animated: false)
        startPlaceholderRequest()
        startViewerRequestIfPossible()
        updateLoadingState()
    }

    /// Cancels every request and clears the page. The next `configure` loads again.
    func unload() {
        cancelRequests()
        photoID = nil
        loader = nil
        viewerRequestSize = .zero
        shown = .none
        placeholderPhase = .idle
        viewerPhase = .idle
        zoomView.setImage(nil, crossfade: false)
        pageView.layer.removeAllAnimations()
        pageView.transform = .identity
        setBadge(.none, animated: false)
        setActivityVisible(false, animated: false)
        status = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        unload()
    }

    /// The page size changed (a resize, or the first layout). Asks again for a viewer image
    /// when the page grew noticeably, keeping the current image until the new one arrives.
    func updateTargetSize(_ size: CGSize) {
        guard size != targetSize else { return }
        targetSize = size
        guard photoID != nil else { return }
        let grew = size.width > viewerRequestSize.width * 1.1 || size.height > viewerRequestSize.height * 1.1
        if viewerTask == nil || viewerPhase == .failed || grew {
            startViewerRequestIfPossible()
            updateLoadingState()
        }
    }

    /// Shows `badge`. Animated changes crossfade, so they read the same with Reduce Motion.
    func setBadge(_ newBadge: PagerBadge, animated: Bool) {
        guard newBadge != badge else { return }
        badge = newBadge
        let old = badgeView
        let new = Self.makeBadgeView(for: newBadge)
        badgeView = new
        if let new {
            new.alpha = 0
            pageView.insertSubview(new, belowSubview: activityBackdrop)
            layoutOverlays()
        }
        let alpha = badgeAlpha
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                old?.alpha = 0
                new?.alpha = alpha
            } completion: { _ in
                old?.removeFromSuperview()
            }
        } else {
            old?.removeFromSuperview()
            new?.alpha = alpha
        }
    }

    /// Returns to 1×.
    func resetZoom(animated: Bool) {
        zoomView.resetZoom(animated: animated)
    }

    /// Acknowledges a swipe up: the page hops up and back; the neighbours stay put.
    /// The pager skips this when Reduce Motion is on.
    func hop() {
        let content = pageView
        content.layer.removeAllAnimations()
        content.transform = .identity
        UIView.animateKeyframes(
            withDuration: 0.3,
            delay: 0,
            options: [.calculationModeCubic, .allowUserInteraction]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1.0 / 3.0) {
                content.transform = CGAffineTransform(translationX: 0, y: -Self.hopDistance)
            }
            UIView.addKeyframe(withRelativeStartTime: 1.0 / 3.0, relativeDuration: 2.0 / 3.0) {
                content.transform = .identity
            }
        }
    }

    // MARK: - Loading

    private func startPlaceholderRequest() {
        guard let loader, let id = photoID else { return }
        placeholderPhase = .loading
        placeholderTask = Task { [weak self] in
            for await image in loader.images(for: id, size: .tile) {
                guard let self else { return }
                self.show(image, quality: .placeholder, for: id)
            }
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            self.placeholderTask = nil
            self.placeholderPhase = self.shown >= .placeholder ? .loaded : .failed
            self.updateLoadingState()
        }
    }

    private func startViewerRequestIfPossible() {
        guard let loader, let id = photoID, targetSize.width >= 1, targetSize.height >= 1 else { return }
        viewerTask?.cancel()
        let size = targetSize
        viewerRequestSize = size
        viewerPhase = .loading
        viewerTask = Task { [weak self] in
            for await image in loader.images(for: id, size: .viewer(size)) {
                guard let self else { return }
                self.show(image, quality: .viewer, for: id)
            }
            guard !Task.isCancelled, let self, self.photoID == id else { return }
            self.viewerPhase = self.shown >= .viewer ? .loaded : .failed
            self.updateLoadingState()
        }
    }

    /// Asks for twice the page size once the zoom passes 1.5×, never for the original size.
    private func requestDetailIfNeeded() {
        guard zoomView.zoomScale > Self.detailZoomThreshold, detailTask == nil, shown == .viewer,
              let loader, let id = photoID, viewerRequestSize.width >= 1, viewerRequestSize.height >= 1
        else { return }
        let size = CGSize(width: viewerRequestSize.width * 2, height: viewerRequestSize.height * 2)
        detailTask = Task { [weak self] in
            for await image in loader.images(for: id, size: .viewer(size)) {
                guard let self else { return }
                self.show(image, quality: .detail, for: id)
            }
        }
    }

    /// Shows `image` unless a better one is already up. A later stage replaces an earlier
    /// one only when it has at least as many pixels, so a small degraded viewer image never
    /// replaces a sharper placeholder.
    private func show(_ image: UIImage, quality: Quality, for id: PhotoID) {
        guard id == photoID else { return }
        let accepted: Bool
        if shown == .none || quality == shown {
            accepted = true
        } else if quality > shown {
            accepted = Self.pixelCount(image) >= (zoomView.image.map(Self.pixelCount) ?? 0)
        } else {
            accepted = false
        }
        guard accepted else { return }
        let isReplacement = shown != .none
        shown = quality
        zoomView.setImage(image, crossfade: isReplacement)
        if quality >= .viewer {
            placeholderTask?.cancel()
            placeholderTask = nil
            if placeholderPhase == .loading { placeholderPhase = .idle }
        }
        updateLoadingState()
        updateBadgeAlpha(animated: isReplacement)
        setNeedsLayout()
    }

    private func cancelRequests() {
        placeholderTask?.cancel()
        viewerTask?.cancel()
        detailTask?.cancel()
        activityRevealTask?.cancel()
        placeholderTask = nil
        viewerTask = nil
        detailTask = nil
        activityRevealTask = nil
    }

    private static func pixelCount(_ image: UIImage) -> CGFloat {
        image.size.width * image.scale * image.size.height * image.scale
    }

    // MARK: - Loading state

    private func updateLoadingState() {
        guard photoID != nil else {
            setActivityVisible(false, animated: false)
            status = nil
            return
        }
        let viewerPending = viewerPhase == .loading || viewerPhase == .idle
        let placeholderPending = placeholderPhase == .loading
        let busy = shown < .viewer && (viewerPending || (shown == .none && placeholderPending))
        setActivityVisible(busy, animated: true)

        if viewerPhase == .failed {
            if shown >= .placeholder {
                status = .offline
            } else {
                status = placeholderPending ? nil : .unavailable
            }
        } else {
            status = nil
        }
    }

    /// Shows the spinner after a short delay, so local photos that load at once never flash it.
    private func setActivityVisible(_ visible: Bool, animated: Bool) {
        guard visible != isActivityVisible else { return }
        isActivityVisible = visible
        activityRevealTask?.cancel()
        activityRevealTask = nil
        if visible {
            activityIndicator.startAnimating()
            activityRevealTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.isActivityVisible else { return }
                UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.activityBackdrop.alpha = 1
                }
            }
        } else if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.activityBackdrop.alpha = 0
            } completion: { [weak self] _ in
                guard let self, !self.isActivityVisible else { return }
                self.activityIndicator.stopAnimating()
            }
        } else {
            activityBackdrop.alpha = 0
            activityIndicator.stopAnimating()
        }
    }

    private func applyStatus() {
        if let status {
            statusView.configure(systemImage: status.systemImage, message: status.message)
            statusView.isHidden = false
            setNeedsLayout()
        } else {
            statusView.isHidden = true
        }
    }

    // MARK: - Zoom

    private func zoomDidChange() {
        updateBadgeAlpha(animated: true)
        layoutOverlays()
        requestDetailIfNeeded()
    }

    /// Badges sit on the photo's corners at 1×; they fade out while zoomed in.
    private var badgeAlpha: CGFloat {
        shown != .none && !zoomView.isZoomed ? 1 : 0
    }

    private func updateBadgeAlpha(animated: Bool) {
        guard let badgeView else { return }
        let alpha = badgeAlpha
        guard badgeView.alpha != alpha else { return }
        if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                badgeView.alpha = alpha
            }
        } else {
            badgeView.alpha = alpha
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: they stay valid while the page hops.
        pageView.bounds = CGRect(origin: .zero, size: contentView.bounds.size)
        pageView.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        zoomView.frame = pageView.bounds
        zoomView.layoutIfNeeded()
        layoutOverlays()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    /// Places the badge, spinner and status note on the part of the photo that isn't under
    /// the bars (the page can extend under them).
    private func layoutOverlays() {
        // `pageView` has the same coordinate space as `contentView`, apart from the hop.
        let bounds = pageView.bounds
        let safe = bounds.inset(by: contentView.safeAreaInsets)
        let image = zoomView.image == nil ? CGRect.null : zoomView.convert(zoomView.imageFrame, to: pageView)
        var visible = image.intersection(safe)
        if visible.isNull || visible.width < 80 || visible.height < 80 {
            visible = image.isNull ? safe : image
        }

        if let badgeView {
            badgeView.sizeToFit()
            let size = badgeView.bounds.size
            let inset: CGFloat = 10
            let leadingX = isRightToLeft ? visible.maxX - inset - size.width : visible.minX + inset
            let trailingX = isRightToLeft ? visible.minX + inset : visible.maxX - inset - size.width
            let origin: CGPoint = switch badge {
            case .kept: CGPoint(x: trailingX, y: visible.minY + inset)
            case .willDelete: CGPoint(x: trailingX, y: visible.maxY - inset - size.height)
            case .protected, .none: CGPoint(x: leadingX, y: visible.maxY - inset - size.height)
            }
            badgeView.frame = CGRect(origin: origin, size: size)
        }

        activityBackdrop.center = CGPoint(x: visible.midX, y: visible.midY)

        if !statusView.isHidden {
            let maxWidth = max(0, visible.width - 32)
            let size = statusView.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            let y = status == .offline ? visible.minY + 12 : visible.midY - size.height / 2
            statusView.frame = CGRect(x: visible.midX - size.width / 2, y: y, width: size.width, height: size.height)
        }
    }

    // MARK: - Badges

    /// Badges are solid content on the photo, never glass (§3.2), and match the grid tiles:
    /// kept top-trailing, will-delete bottom-trailing, favorite bottom-leading.
    private static func makeBadgeView(for badge: PagerBadge) -> UIImageView? {
        let accent = UIColor(named: "AccentColor") ?? .systemBlue
        let size = UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        let image: UIImage? = switch badge {
        case .none:
            nil
        case .kept:
            UIImage(systemName: "checkmark.circle.fill",
                    withConfiguration: size.applying(UIImage.SymbolConfiguration(paletteColors: [.white, accent])))
        case .willDelete:
            UIImage(systemName: "trash.circle.fill",
                    withConfiguration: size.applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed])))
        case .protected:
            UIImage(systemName: "heart.fill",
                    withConfiguration: size.applying(UIImage.SymbolConfiguration(paletteColors: [.white])))
        }
        guard let image else { return nil }
        let view = UIImageView(image: image)
        view.contentMode = .center
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.3
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        return view
    }
}

/// A small solid capsule that says why a photo isn't sharp or isn't there.
/// Solid content, not glass: it sits on the photo (§3.2).
final class PagerStatusView: UIView {
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 8
    private static let spacing: CGFloat = 6

    private let iconView = UIImageView()
    private let label = UILabel()

    /// Puts the icon on the right, for right-to-left languages.
    var isRightToLeft = false {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerCurve = .continuous

        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        addSubview(iconView)

        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagerStatusView is built in code")
    }

    func configure(systemImage: String, message: String) {
        iconView.image = UIImage(systemName: systemImage)
        label.text = message
        setNeedsLayout()
    }

    private var iconSize: CGSize {
        iconView.image == nil ? .zero : iconView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                                      height: .greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let icon = iconSize
        let chrome = 2 * Self.horizontalPadding + icon.width + Self.spacing
        let labelSize = label.sizeThatFits(CGSize(width: max(0, size.width - chrome), height: .greatestFiniteMagnitude))
        let width = min(size.width, chrome + ceil(labelSize.width))
        let height = 2 * Self.verticalPadding + max(icon.height, ceil(labelSize.height))
        return CGSize(width: max(0, width), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let icon = iconSize
        let labelWidth = max(0, bounds.width - 2 * Self.horizontalPadding - icon.width - Self.spacing)
        let labelHeight = ceil(label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
        var iconFrame = CGRect(x: Self.horizontalPadding, y: (bounds.height - icon.height) / 2,
                               width: icon.width, height: icon.height)
        var labelFrame = CGRect(x: iconFrame.maxX + Self.spacing, y: (bounds.height - labelHeight) / 2,
                                width: labelWidth, height: labelHeight)
        if isRightToLeft {
            iconFrame.origin.x = bounds.width - iconFrame.maxX
            labelFrame.origin.x = bounds.width - labelFrame.maxX
            label.textAlignment = .right
        } else {
            label.textAlignment = .left
        }
        iconView.frame = iconFrame
        label.frame = labelFrame
        layer.cornerRadius = min(bounds.height / 2, 18)
    }
}
