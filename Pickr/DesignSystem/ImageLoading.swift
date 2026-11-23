import PickrCore
import SwiftUI
import UIKit

// App contract frozen by WP0 (§4.3). WP3's ImageLoader is the live implementation.

/// How big an image to request. Each class has one shared request configuration, used
/// for both requests and preheating.
nonisolated enum ImageSizeClass: Equatable, Sendable {
    /// Moment card thumbnails: 144 px.
    case card
    /// Single-mode filmstrip thumbnails: 168 px.
    case filmstrip
    /// Grid tiles and context-menu previews: 360 px.
    case tile
    /// Full-screen viewing: the view size in points (the loader multiplies by the display scale).
    case viewer(CGSize)
}

/// Loads photo images for display. Never requests the original's full pixel size.
nonisolated protocol ImageLoading: Sendable {
    /// Yields a fast degraded image first (when one is available), then the final image,
    /// then finishes. Ending the stream (for example when the calling task is cancelled)
    /// cancels the underlying request.
    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage>
    /// Starts caching images for photos about to appear.
    func preheat(_ ids: [PhotoID], size: ImageSizeClass)
    /// Stops caching images for photos that left the visible range.
    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass)
}

/// The environment default: loads nothing. Keeps previews and tests free of PhotoKit.
nonisolated struct NoImageLoader: ImageLoading {
    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage> {
        AsyncStream { $0.finish() }
    }

    func preheat(_ ids: [PhotoID], size: ImageSizeClass) {}

    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass) {}
}

extension EnvironmentValues {
    /// The image loader for every thumbnail, tile and pager cell.
    @Entry var imageLoader: any ImageLoading = NoImageLoader()
}
