import Foundation
import Photos
import PickrCore
import Synchronization
import UIKit

/// The live `ImageLoading` implementation over `PHCachingImageManager` (blueprint §4.6).
///
/// - **Size classes:** `card` 144 px, `filmstrip` 168 px and `tile` 360 px are
///   opportunistic, fast-resize, aspect-fill requests; `viewer` is the view size times the
///   display scale (at most 4,096 px a side), high quality, aspect fit. Never the
///   original's full pixel size [ARCH B4].
/// - **One shared `PHImageRequestOptions` per kind**, used for both requests and caching,
///   because PhotoKit's cache only matches identical options (`PHImageManager.h:241-242`).
/// - **Streams:** a degraded image first when one is available, then the final image.
///   Ending the stream cancels the request.
/// - **Viewer streams** carry only the high-quality image, so a stream that ends without
///   one means the load failed (an iCloud download, for example). The pager shows its own
///   `tile` placeholder meanwhile and keeps it on failure; a placeholder mixed into this
///   stream would hide the failure and request the tile twice.
/// - **Assets:** a lock-protected LRU of 2,000 `PHAsset`s. Misses are fetched off the
///   caller's thread for images and in one batch for preheating.
/// - **Preheating** is skipped while the system prefers reduced resource usage.
/// - Network access is allowed, so PhotoKit may download an iCloud original to show it;
///   the app itself makes no network requests.
nonisolated final class ImageLoader: ImageLoading {
    static let assetCacheCapacity = 2_000

    private let manager: PHCachingImageManager
    private let displayScale: CGFloat
    private let assets = Mutex(LRUCache<PhotoID, PHAsset>(capacity: ImageLoader.assetCacheCapacity))
    /// Preheat and stop calls run here in order, off the caller's thread.
    private let preheatQueue = DispatchQueue(label: "com.juha.Culler.image-preheat", qos: .utility)
    private let prefersReducedResourceUsage = Atomic<Bool>(false)
    private let resourcePreferenceTask = Mutex<Task<Void, Never>?>(nil)

    // Configured once in `init` and never mutated afterwards, so sharing them across
    // threads is safe. Sharing the same instances keeps requests and caching identical.
    nonisolated(unsafe) private let thumbnailOptions: PHImageRequestOptions
    nonisolated(unsafe) private let viewerOptions: PHImageRequestOptions

    /// - Parameters:
    ///   - displayScale: pixels per point for `viewer` requests; pass the scene's
    ///     `displayScale`.
    ///   - manager: the caching image manager.
    init(displayScale: CGFloat = 3, manager: PHCachingImageManager = PHCachingImageManager()) {
        #if DEBUG
        precondition(!DemoMode.isActive, "Demo mode never loads images from PhotoKit")
        #endif
        self.displayScale = displayScale.isFinite && displayScale > 0 ? displayScale : 3
        self.manager = manager
        thumbnailOptions = Self.makeOptions(deliveryMode: .opportunistic)
        viewerOptions = Self.makeOptions(deliveryMode: .highQualityFormat)
        observeResourcePreference()
    }

    deinit {
        resourcePreferenceTask.withLock { $0?.cancel() }
    }

    // MARK: ImageLoading

    func images(for id: PhotoID, size: ImageSizeClass) -> AsyncStream<UIImage> {
        let spec = RequestSpec(size, displayScale: displayScale)
        // Only the newest image matters: a consumer that falls behind skips to the final one.
        let (stream, continuation) = AsyncStream.makeStream(of: UIImage.self, bufferingPolicy: .bufferingNewest(1))
        let load = ImageLoad(manager: manager, continuation: continuation)
        continuation.onTermination = { _ in load.cancel() }

        if let asset = assets.withLock({ $0.value(for: id) }) {
            start(load, for: asset, spec: spec)
        } else {
            load.attach(Task.detached(priority: .userInitiated) { [self] in
                guard let asset = resolveAssets([id])[id] else {
                    load.finish()
                    return
                }
                guard !Task.isCancelled else { return }
                start(load, for: asset, spec: spec)
            })
        }
        return stream
    }

    func preheat(_ ids: [PhotoID], size: ImageSizeClass) {
        guard !ids.isEmpty, !prefersReducedResourceUsage.load(ordering: .relaxed) else { return }
        let spec = RequestSpec(size, displayScale: displayScale)
        preheatQueue.async { [self] in
            let found = Array(resolveAssets(ids).values)
            guard !found.isEmpty else { return }
            manager.startCachingImages(
                for: found,
                targetSize: spec.targetSize,
                contentMode: spec.contentMode,
                options: options(for: spec)
            )
        }
    }

    func stopPreheating(_ ids: [PhotoID], size: ImageSizeClass) {
        guard !ids.isEmpty else { return }
        let spec = RequestSpec(size, displayScale: displayScale)
        preheatQueue.async { [self] in
            let found = Array(resolveAssets(ids).values)
            guard !found.isEmpty else { return }
            manager.stopCachingImages(
                for: found,
                targetSize: spec.targetSize,
                contentMode: spec.contentMode,
                options: options(for: spec)
            )
        }
    }

    // MARK: Requests

    private func start(_ load: ImageLoad, for asset: PHAsset, spec: RequestSpec) {
        let requestID = manager.requestImage(
            for: asset,
            targetSize: spec.targetSize,
            contentMode: spec.contentMode,
            options: options(for: spec)
        ) { image, info in
            load.receive(image, ImageResult(info))
        }
        load.register(requestID)
    }

    private func options(for spec: RequestSpec) -> PHImageRequestOptions {
        switch spec.kind {
        case .thumbnail: thumbnailOptions
        case .viewer: viewerOptions
        }
    }

    private static func makeOptions(deliveryMode: PHImageRequestOptionsDeliveryMode) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = deliveryMode
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }

    // MARK: Assets

    /// The assets for `ids` that exist and are visible: cached ones from the LRU, the rest
    /// in one fetch. Hidden photos are never loaded.
    private func resolveAssets(_ ids: [PhotoID]) -> [PhotoID: PHAsset] {
        let (cached, misses) = assets.withLock { cache in
            var cached: [PhotoID: PHAsset] = [:]
            var misses: [PhotoID] = []
            for id in ids {
                if let asset = cache.value(for: id) {
                    cached[id] = asset
                } else {
                    misses.append(id)
                }
            }
            return (cached, misses)
        }
        guard !misses.isEmpty else { return cached }
        let fetched = AssetQueries.assets(withIDs: misses, options: AssetQueries.visibleOptions())
        assets.withLock { cache in
            for asset in fetched {
                cache.insert(asset, for: PhotoID(asset.localIdentifier))
            }
        }
        var found = cached
        for asset in fetched {
            found[PhotoID(asset.localIdentifier)] = asset
        }
        return found
    }

    // MARK: Reduced resource usage

    /// Reads the preference now and again whenever the system posts a change. The task
    /// holds the loader weakly and is cancelled when the loader goes away.
    private func observeResourcePreference() {
        let task = Task { @MainActor [weak self] in
            self?.updateResourcePreference()
            let changes = NotificationCenter.default.notifications(
                named: UIApplication.systemPrefersReducedResourceUsageDidChangeNotification
            )
            for await _ in changes {
                guard let self else { return }
                updateResourcePreference()
            }
        }
        resourcePreferenceTask.withLock { $0 = task }
    }

    @MainActor private func updateResourcePreference() {
        prefersReducedResourceUsage.store(UIApplication.shared.systemPrefersReducedResourceUsage, ordering: .relaxed)
    }
}

// MARK: - Request specs

/// The pixel size and content mode of one image request.
nonisolated struct RequestSpec: Equatable, Sendable {
    enum Kind: Sendable {
        /// Opportunistic: a degraded image first, then the final one.
        case thumbnail
        /// High quality: one final image.
        case viewer
    }

    static let cardPixels: CGFloat = 144
    static let filmstripPixels: CGFloat = 168
    static let tilePixels: CGFloat = 360
    /// Viewer requests stay within these bounds on each side, whatever the view reports.
    static let viewerPixelRange: ClosedRange<CGFloat> = 64...4_096

    let kind: Kind
    /// In pixels.
    let targetSize: CGSize
    let contentMode: PHImageContentMode

    init(_ size: ImageSizeClass, displayScale: CGFloat) {
        switch size {
        case .card:
            self.init(thumbnailSide: Self.cardPixels)
        case .filmstrip:
            self.init(thumbnailSide: Self.filmstripPixels)
        case .tile:
            self.init(thumbnailSide: Self.tilePixels)
        case .viewer(let points):
            let pixels = CGSize(
                width: Self.viewerPixels(points.width, displayScale: displayScale),
                height: Self.viewerPixels(points.height, displayScale: displayScale)
            )
            self.init(kind: .viewer, targetSize: pixels, contentMode: .aspectFit)
        }
    }

    private init(thumbnailSide side: CGFloat) {
        self.init(kind: .thumbnail, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill)
    }

    private init(kind: Kind, targetSize: CGSize, contentMode: PHImageContentMode) {
        self.kind = kind
        self.targetSize = targetSize
        self.contentMode = contentMode
    }

    static func viewerPixels(_ points: CGFloat, displayScale: CGFloat) -> CGFloat {
        let pixels = (points * displayScale).rounded(.up)
        guard pixels.isFinite else { return viewerPixelRange.lowerBound }
        return min(max(pixels, viewerPixelRange.lowerBound), viewerPixelRange.upperBound)
    }
}

// MARK: - One image load

/// The parts of a PhotoKit result `info` dictionary the loader needs.
nonisolated struct ImageResult: Sendable {
    let isDegraded: Bool
    let isCancelled: Bool
    let failed: Bool

    init(isDegraded: Bool = false, isCancelled: Bool = false, failed: Bool = false) {
        self.isDegraded = isDegraded
        self.isCancelled = isCancelled
        self.failed = failed
    }

    init(_ info: [AnyHashable: Any]?) {
        self.init(
            isDegraded: (info?[PHImageResultIsDegradedKey] as? Bool) ?? false,
            isCancelled: (info?[PHImageCancelledKey] as? Bool) ?? false,
            failed: info?[PHImageErrorKey] != nil
        )
    }

    /// No more results follow for this request.
    var isFinal: Bool { !isDegraded || failed }
}

/// The state of one `images(for:size:)` stream: its PhotoKit request, the asset-fetch task
/// and whether it has ended. The request is cancelled when the stream ends.
///
/// PhotoKit may call the result handler synchronously inside `requestImage`, before the
/// request ID is known, so registration after the stream ended cancels at once. The
/// continuation is only called outside the lock: finishing it runs `cancel()`.
nonisolated final class ImageLoad: Sendable {
    private struct State {
        var requestID: PHImageRequestID?
        var task: Task<Void, Never>?
        var isTerminated = false
        /// The request delivered its final result.
        var isDone = false
    }

    private let manager: PHImageManager
    private let continuation: AsyncStream<UIImage>.Continuation
    private let state = Mutex(State())

    init(manager: PHImageManager, continuation: AsyncStream<UIImage>.Continuation) {
        self.manager = manager
        self.continuation = continuation
    }

    /// Tracks the task that fetches the asset; cancels it at once if the stream ended.
    func attach(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state in
            guard !state.isTerminated else { return true }
            state.task = task
            return false
        }
        if cancelNow { task.cancel() }
    }

    /// Tracks the started request; cancels it at once if the stream ended meanwhile. A
    /// request that already completed synchronously needs neither.
    func register(_ requestID: PHImageRequestID) {
        let cancelNow = state.withLock { state in
            guard !state.isTerminated else { return !state.isDone }
            state.requestID = requestID
            return false
        }
        if cancelNow { manager.cancelImageRequest(requestID) }
    }

    /// Handles one PhotoKit result: every image is shown, and the final result (an image or
    /// a failure) ends the stream.
    func receive(_ image: UIImage?, _ result: ImageResult) {
        guard !result.isCancelled else { return }
        let (shown, finishes) = state.withLock { state -> (UIImage?, Bool) in
            guard !state.isTerminated else { return (nil, false) }
            guard result.isFinal else { return (image, false) }
            state.isDone = true
            state.isTerminated = true
            state.requestID = nil
            return (image, true)
        }
        if let shown { continuation.yield(shown) }
        if finishes { continuation.finish() }
    }

    /// Ends the stream without an image (the photo no longer exists or is hidden).
    func finish() {
        state.withLock { $0.isTerminated = true }
        continuation.finish()
    }

    /// Called when the stream ends for any reason: cancels whatever is still running.
    func cancel() {
        let (requestID, task) = state.withLock { state -> (PHImageRequestID?, Task<Void, Never>?) in
            state.isTerminated = true
            let running = (state.requestID, state.task)
            state.requestID = nil
            state.task = nil
            return running
        }
        task?.cancel()
        if let requestID { manager.cancelImageRequest(requestID) }
    }
}

// MARK: - LRU cache

/// A small least-recently-used cache. Evicts the oldest tenth when it grows past capacity.
nonisolated struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var lastUse: UInt64
    }

    let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        clock &+= 1
        entries[key]?.lastUse = clock
        return entries[key]?.value
    }

    mutating func insert(_ value: Value, for key: Key) {
        clock &+= 1
        entries[key] = Entry(value: value, lastUse: clock)
        if entries.count > capacity {
            evictLeastRecentlyUsed()
        }
    }

    private mutating func evictLeastRecentlyUsed() {
        let target = max(capacity - capacity / 10, 1)
        let oldest = entries.sorted { $0.value.lastUse < $1.value.lastUse }.prefix(entries.count - target)
        for (key, _) in oldest {
            entries[key] = nil
        }
    }
}
