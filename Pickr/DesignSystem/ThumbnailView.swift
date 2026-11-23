import PickrCore
import SwiftUI
import UIKit

/// A square, aspect-filled photo thumbnail.
///
/// It loads through the `\.imageLoader` environment value: the fast degraded image appears
/// first and is replaced by the final one. The request is cancelled when the view
/// disappears (the task ends the stream). A thumbnail that already has its final image
/// does not load again when it reappears.
///
/// - A `viewer` size (large grid tiles) shows the `tile` image first, because a viewer
///   stream carries only the high-quality image; if that fails, the tile image stays.
/// - When only the size changes (a resize), the current image stays until the new one
///   arrives, so tiles never flash empty.
/// - Final images are offered to `AmbientCache`, which draws a tiny backdrop from them, so
///   ambient backgrounds show photos already on screen without requests of their own.
///
/// Decorative for VoiceOver: the card or tile that contains it carries the label.
struct ThumbnailView: View {
    let id: PhotoID
    let size: ImageSizeClass

    @Environment(\.imageLoader) private var loader

    @State private var image: UIImage?
    /// Which request `image` belongs to.
    @State private var imageKey: LoadKey?
    /// Set when a request finished with an image, so it is not repeated.
    @State private var completedKey: LoadKey?

    init(id: PhotoID, size: ImageSizeClass) {
        self.id = id
        self.size = size
    }

    var body: some View {
        let key = LoadKey(id: id, size: size)
        Theme.Palette.placeholder
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: image == nil)
            .accessibilityHidden(true)
            .task(id: key) {
                await load(key)
            }
    }

    private func load(_ key: LoadKey) async {
        guard completedKey != key else { return }
        if imageKey?.id != key.id {
            image = nil
            imageKey = nil
        }
        if case .viewer = key.size, imageKey == nil {
            for await next in loader.images(for: key.id, size: .tile) {
                image = next
                imageKey = LoadKey(id: key.id, size: .tile)
            }
            guard !Task.isCancelled else { return }
        }
        var final: UIImage?
        for await next in loader.images(for: key.id, size: key.size) {
            image = next
            imageKey = key
            final = next
        }
        guard let final, !Task.isCancelled else { return }
        completedKey = key
        await AmbientCache.shared.record(final, for: key.id)
    }
}

private struct LoadKey: Equatable {
    let id: PhotoID
    let size: ImageSizeClass
}

#if DEBUG
/// Previews only: a solid swatch per photo, so design-system previews show images without
/// PhotoKit. The colour is derived from the identifier, so it is stable between runs.
nonisolated struct SwatchImageLoader: ImageLoading {
    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage> {
        let seed = id.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let color = UIColor(hue: CGFloat(seed % 360) / 360, saturation: 0.45, brightness: 0.85, alpha: 1)
        let side = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: side).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: side))
        }
        return AsyncStream { continuation in
            continuation.yield(image)
            continuation.finish()
        }
    }

    func preheat(_ ids: [PhotoID], size: ImageSizeClass) {}

    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass) {}
}

/// Previews only: photos taken `spacing` seconds apart, every third one a favorite.
enum PreviewPhotos {
    static func records(count: Int, spacing: TimeInterval = 4) -> [AssetRecord] {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return (0..<count).map { index in
            AssetRecord(
                id: PhotoID("preview-\(index)"),
                created: start.addingTimeInterval(Double(index) * spacing),
                isFavorite: index % 3 == 2
            )
        }
    }
}

#Preview("Thumbnails") {
    HStack(spacing: Theme.Size.stripSpacing) {
        ForEach(PreviewPhotos.records(count: 4), id: \.id) { record in
            ThumbnailView(id: record.id, size: .card)
                .frame(width: Theme.Size.stripThumbnail, height: Theme.Size.stripThumbnail)
                .clipShape(Theme.Shapes.thumbnail)
        }
    }
    .environment(\.imageLoader, SwatchImageLoader())
}
#endif
