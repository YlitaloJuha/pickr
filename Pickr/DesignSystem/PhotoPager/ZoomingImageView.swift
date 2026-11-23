import UIKit

/// One photo, fitted to the view and centred, that zooms like the Photos app (§4.6).
///
/// - **Pinch** peeks: the photo zooms up to 5× and springs back to 1× when the fingers lift.
/// - **Double-tap** zooms to 2.5× around the tapped point, or back to 1×.
/// - **Single tap** calls `onSingleTap`, but only once a double-tap has been ruled out.
///
/// At 1× the view doesn't scroll, so horizontal drags page the enclosing pager. Once zoomed
/// in it pans; at its edges the nested-scroll-view hand-off gives the drag back to the pager.
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    /// The zoom a double-tap goes to.
    static let doubleTapZoom: CGFloat = 2.5
    /// How far a pinch can peek before it springs back.
    static let maximumZoom: CGFloat = 5

    /// Called for a single tap that is not the first half of a double-tap.
    var onSingleTap: (() -> Void)?
    /// Called on every zoom change, including the spring back to 1×.
    var onZoomChange: (() -> Void)?

    private let imageView = UIImageView()
    private var fittedBoundsSize: CGSize = .zero
    private var isPinchHandlerAttached = false

    /// The photo, or nil.
    var image: UIImage? { imageView.image }

    /// True while the photo is shown larger than fitted.
    var isZoomed: Bool { zoomScale > minimumZoomScale + 0.01 }

    /// The photo's frame in this view's coordinate space, or `.null` without a photo.
    var imageFrame: CGRect { imageView.image == nil ? .null : imageView.frame }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = Self.maximumZoom
        bouncesZoom = true
        // Off at 1× so the pager owns horizontal drags; on while zoomed in (scrollViewDidZoom).
        isScrollEnabled = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        scrollsToTop = false
        backgroundColor = .clear

        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        attachPinchHandlerIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ZoomingImageView is built in code")
    }

    // MARK: - Image

    /// Shows `image`. A photo with a different shape resets the zoom; a sharper version of
    /// the same photo keeps it. With `crossfade`, a replacement fades in over the old image.
    func setImage(_ image: UIImage?, crossfade: Bool) {
        let previous = imageView.image
        let keepsShape: Bool = {
            guard let previous, let image else { return false }
            return Self.hasSameShape(previous.size, image.size)
        }()
        if crossfade, previous != nil, image != nil {
            UIView.transition(
                with: imageView,
                duration: 0.2,
                options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
            ) {
                self.imageView.image = image
            }
        } else {
            imageView.image = image
        }
        if !keepsShape {
            fitImage()
        }
    }

    /// Returns to 1×.
    func resetZoom(animated: Bool) {
        guard isZoomed else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        attachPinchHandlerIfNeeded()
        // Zooming changes the bounds origin, never its size: refit only on a real resize
        // (for example the iPhone Duo folding or unfolding).
        if bounds.size != fittedBoundsSize {
            fittedBoundsSize = bounds.size
            fitImage()
        }
    }

    /// Sizes the image view to the photo's aspect-fitted size at 1× and centres it.
    private func fitImage() {
        setZoomScale(minimumZoomScale, animated: false)
        let fitted = Self.fittedSize(of: imageView.image?.size ?? .zero, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        contentOffset = .zero
        isScrollEnabled = false
        centerImage()
    }

    /// Keeps the photo centred while it is smaller than the view in either direction.
    private func centerImage() {
        let size = contentSize
        let horizontal = max((bounds.width - size.width) / 2, 0)
        let vertical = max((bounds.height - size.height) / 2, 0)
        imageView.center = CGPoint(x: size.width / 2 + horizontal, y: size.height / 2 + vertical)
    }

    /// The largest size with the image's aspect ratio that fits in `bounds`.
    static func fittedSize(of imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// True when two image sizes have the same aspect ratio, within 1 %.
    private static func hasSameShape(_ a: CGSize, _ b: CGSize) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let ratio = (a.width / a.height) / (b.width / b.height)
        return abs(ratio - 1) < 0.01
    }

    // MARK: - Gestures

    /// The pinch recogniser exists once zooming is configured; attach the spring-back
    /// handler to it exactly once.
    private func attachPinchHandlerIfNeeded() {
        guard !isPinchHandlerAttached, let pinch = pinchGestureRecognizer else { return }
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        isPinchHandlerAttached = true
    }

    /// Peek-to-zoom: when the fingers lift, spring back to 1×.
    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .ended, .cancelled, .failed:
            resetZoom(animated: true)
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        if isZoomed {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        // Zoom around the tapped point, kept on the photo when the tap lands beside it.
        var point = recognizer.location(in: imageView)
        point.x = min(max(point.x, 0), imageView.bounds.width)
        point.y = min(max(point.y, 0), imageView.bounds.height)
        let width = bounds.width / Self.doubleTapZoom
        let height = bounds.height / Self.doubleTapZoom
        zoom(
            to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
            animated: true
        )
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        onSingleTap?()
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        isScrollEnabled = isZoomed
        onZoomChange?()
    }
}
