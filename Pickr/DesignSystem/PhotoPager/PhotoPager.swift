import PickrCore
import SwiftUI
import UIKit

// API frozen by WP0 (§4.3). Implemented by WP6 (§4.6 PhotoPager).

/// The badge a pager page shows for its photo.
nonisolated enum PagerBadge: Hashable, Sendable {
    case none, kept, willDelete, protected
}

/// The full-screen, zoomable photo pager used by Review and Kept in Single mode.
///
/// A UIKit pager (`PhotoPagerController`) because nested scroll views coordinate paging
/// and zooming properly:
/// - **Swipe sideways** to page. Both neighbours peek in by 12 pt; drags snap to pages.
/// - **Pinch** peeks and springs back to 1×; **double-tap** zooms to 2.5× and back.
/// - **Swipe up** calls `onSwipeUp`, with a 50 pt hop of the page unless Reduce Motion is
///   on. Pass nil (Kept) to turn the gesture off.
/// - **Single tap** calls `onTap` once a double-tap has been ruled out (chrome toggle).
/// - **VoiceOver:** one adjustable element labelled "Photos". Swiping up or down pages;
///   the value is `accessibilityLabel(index)` (for example "Photo 2 of 5, 13:25:08,
///   kept"). With `onKeepAction`, a custom action is named "Unkeep" when the photo's
///   badge is `.kept` and "Keep" otherwise.
///
/// `badge` and `accessibilityLabel` are read on every update, so the pages follow state
/// changes; badge changes crossfade. `index` follows the page during a drag and scrolls the
/// pager when changed from outside (an adjacent page animates, a jump doesn't).
///
/// Images come from the `imageLoader` environment value at the `viewer` size class (the
/// page size, from the pager's own bounds), with a quick `tile` image first and twice the
/// page size once zoomed past 1.5×. Never the original's full size. Requests are cancelled
/// when a page is reused or scrolls away; ±1 pages are preheated unless the system prefers
/// reduced resource usage.
struct PhotoPager: UIViewControllerRepresentable {
    let photos: [PhotoID]
    @Binding var index: Int
    let badge: (PhotoID) -> PagerBadge
    let accessibilityLabel: (Int) -> String
    let onSwipeUp: (() -> Void)?
    let onTap: (() -> Void)?
    let onKeepAction: ((Int) -> Void)?

    init(
        photos: [PhotoID],
        index: Binding<Int>,
        badge: @escaping (PhotoID) -> PagerBadge,
        accessibilityLabel: @escaping (Int) -> String,
        onSwipeUp: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil,
        onKeepAction: ((Int) -> Void)? = nil
    ) {
        self.photos = photos
        _index = index
        self.badge = badge
        self.accessibilityLabel = accessibilityLabel
        self.onSwipeUp = onSwipeUp
        self.onTap = onTap
        self.onKeepAction = onKeepAction
    }

    func makeUIViewController(context: Context) -> PhotoPagerController {
        PhotoPagerController()
    }

    func updateUIViewController(_ controller: PhotoPagerController, context: Context) {
        let index = $index
        controller.update(PhotoPagerController.Configuration(
            photos: photos,
            index: index.wrappedValue,
            loader: context.environment.imageLoader,
            badge: badge,
            accessibilityLabel: accessibilityLabel,
            onIndexChange: { index.wrappedValue = $0 },
            onSwipeUp: onSwipeUp,
            onTap: onTap,
            onKeepAction: onKeepAction,
            reduceMotion: context.environment.accessibilityReduceMotion,
            prefersReducedResourceUsage: context.environment.systemPrefersReducedResourceUsage
        ))
    }

    static func dismantleUIViewController(_ controller: PhotoPagerController, coordinator: ()) {
        controller.tearDown()
    }
}

#if DEBUG

/// Renders a coloured stand-in for each photo, in alternating shapes, so the pager can be
/// tried in previews without PhotoKit.
private nonisolated struct PreviewImageLoader: ImageLoading {
    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                continuation.yield(Self.render(id))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func preheat(_ ids: [PhotoID], size: ImageSizeClass) {}

    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass) {}

    @MainActor
    private static func render(_ id: PhotoID) -> UIImage {
        let number = Int(id.rawValue) ?? 0
        let size = number.isMultiple(of: 2) ? CGSize(width: 300, height: 400) : CGSize(width: 400, height: 300)
        let hue = CGFloat(number % 7) / 7
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.5, brightness: 0.85, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = NSAttributedString(
                string: id.rawValue,
                attributes: [.font: UIFont.boldSystemFont(ofSize: 96), .foregroundColor: UIColor.white]
            )
            let textSize = text.size()
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        }
    }
}

#Preview("Photo pager") {
    @Previewable @State var index = 1
    @Previewable @State var kept: Set<PhotoID> = [PhotoID("2")]
    let photos = (1 ... 6).map { PhotoID(String($0)) }
    PhotoPager(
        photos: photos,
        index: $index,
        badge: { kept.contains($0) ? .kept : (kept.isEmpty ? .none : .willDelete) },
        accessibilityLabel: { "Photo \($0 + 1) of \(photos.count)" },
        onSwipeUp: {
            let id = photos[index]
            if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
        },
        onKeepAction: { position in
            let id = photos[position]
            if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
        }
    )
    .environment(\.imageLoader, PreviewImageLoader())
    .ignoresSafeArea(.container, edges: .vertical)
    .background(Color(.systemGroupedBackground))
}

#endif
