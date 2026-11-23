import Foundation
import PickrModels
import PickrPersistence
import UIKit

/// Builds the live object graph for the app (blueprint §4.4, WP14).
///
/// - The models: `AppServices` over PhotoKit (`LivePhotoLibrary`), the standard user
///   defaults (the v1 keys live there, §1.2) and `Application Support/Pickr/kept.json`
///   (backed up, protected until the first unlock; `KeptStore` creates the folder on the
///   first save).
/// - The image loader: one `ImageLoader` per display scale, so `viewer` requests match the
///   scene's pixels (`ImageLoaders`).
///
/// Creating the services reads the settings and touches nothing else (`AppServices.init`);
/// `AppServices.launch()` does the rest once the first frame is up.
///
/// In Debug builds launched with `-PickrDemo YES` (`DemoMode`), the demo library, loader and
/// settings replace these, and the PhotoKit ones are never created.
enum LiveServices {
    /// Where the Kept list is stored: `Library/Application Support/Pickr/kept.json`.
    static var keptURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Pickr", directoryHint: .isDirectory)
            .appending(path: "kept.json", directoryHint: .notDirectory)
    }

    /// The settings store: the standard user defaults (the v1 keys live there, §1.2).
    static let defaults: any KeyValueStore = {
        #if DEBUG
        if DemoMode.isActive { return DemoServices.makeDefaults() }
        #endif
        return UserDefaults.standard
    }()

    static func makeServices() -> AppServices {
        #if DEBUG
        if DemoMode.isActive { return DemoServices.makeServices(defaults: defaults) }
        #endif
        return AppServices(
            client: LivePhotoLibrary(),
            defaults: defaults,
            keptURL: keptURL,
            now: { .now }
        )
    }

    /// The live loader for a scene with this many pixels per point.
    static func makeImageLoader(displayScale: CGFloat) -> any ImageLoading {
        #if DEBUG
        if DemoMode.isActive { return DemoImageLoader(displayScale: displayScale) }
        #endif
        return ImageLoader(displayScale: displayScale)
    }
}

/// The scene's image loaders, one per display scale, created on first use and then kept
/// (with their PhotoKit caches) for the life of the app. A window that moves to a display
/// with another scale gets a loader for that scale; moving back reuses the first one.
@MainActor
final class ImageLoaders {
    private var loaders: [CGFloat: any ImageLoading] = [:]

    /// The loader for `displayScale`. A scale that isn't a positive number uses 3, as
    /// `ImageLoader` itself does.
    func loader(for displayScale: CGFloat) -> any ImageLoading {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 3
        if let loader = loaders[scale] { return loader }
        let loader = LiveServices.makeImageLoader(displayScale: scale)
        loaders[scale] = loader
        return loader
    }
}
