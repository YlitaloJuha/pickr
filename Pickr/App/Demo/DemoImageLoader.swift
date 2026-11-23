#if DEBUG
import Foundation
import ImageIO
import PickrCore
import Synchronization
import UIKit

/// Demo mode's image loader (`DemoMode`): decodes the bundled test photos with ImageIO,
/// downsampled to the size class (the live loader's pixel sizes), off the main actor. Never
/// touches PhotoKit.
///
/// Each stream yields one image and finishes; a missing file finishes with none. Decoded
/// images stay in memory (40 small photos), so scrolling back costs nothing.
nonisolated final class DemoImageLoader: ImageLoading {
    private struct Key: Hashable {
        let id: PhotoID
        let maxPixels: Int
    }

    private let displayScale: CGFloat
    private let bundle: Bundle
    private let cache = Mutex<[Key: UIImage]>([:])

    private static let cacheLimit = 400

    init(displayScale: CGFloat, bundle: Bundle = .main) {
        self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 3
        self.bundle = bundle
    }

    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage> {
        let (stream, continuation) = AsyncStream.makeStream(of: UIImage.self, bufferingPolicy: .bufferingNewest(1))
        let task = Task.detached(priority: .userInitiated) { [self] in
            if let image = image(for: id, size: size), !Task.isCancelled {
                continuation.yield(image)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func preheat(_ ids: [PhotoID], size: ImageSizeClass) {}

    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass) {}

    // MARK: Decoding

    private func image(for id: PhotoID, size: ImageSizeClass) -> UIImage? {
        guard let url = DemoPhotoLibrary.url(for: id, in: bundle),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let maxPixels = Self.maxPixels(for: size, displayScale: displayScale, source: source)
        let key = Key(id: id, maxPixels: maxPixels)
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.withLock { cache in
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = image
        }
        return image
    }

    /// The longest side to decode. Thumbnails fill a square of the live loader's size, so
    /// their shorter side reaches it; viewer images fit the view's pixels. Never more than
    /// the photo itself.
    private static func maxPixels(for size: ImageSizeClass, displayScale: CGFloat, source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longest = max(width, height)
        let shortest = min(width, height)

        let wanted: Double
        switch size {
        case .card, .filmstrip, .tile:
            let side: CGFloat = switch size {
            case .card: RequestSpec.cardPixels
            case .filmstrip: RequestSpec.filmstripPixels
            default: RequestSpec.tilePixels
            }
            wanted = shortest > 0 ? Double(side) * longest / shortest : Double(side)
        case .viewer(let points):
            let range = RequestSpec.viewerPixelRange
            let pixels = Double(max(points.width, points.height) * displayScale)
            wanted = min(max(pixels, Double(range.lowerBound)), Double(range.upperBound))
        }
        let limited = longest > 0 ? min(wanted, longest) : wanted
        return max(Int(limited.rounded(.up)), 1)
    }
}
#endif
