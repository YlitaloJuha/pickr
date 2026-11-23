import Foundation
import Photos
import PickrCore
import Synchronization
import Testing
import UIKit
@testable import Pickr

@Suite("Image request specs")
struct RequestSpecTests {
    @Test func thumbnailClassesUseFixedPixelSizes() {
        let card = RequestSpec(.card, displayScale: 3)
        let filmstrip = RequestSpec(.filmstrip, displayScale: 2)
        let tile = RequestSpec(.tile, displayScale: 3)
        #expect(card.targetSize == CGSize(width: 144, height: 144))
        #expect(filmstrip.targetSize == CGSize(width: 168, height: 168))
        #expect(tile.targetSize == CGSize(width: 360, height: 360))
        for spec in [card, filmstrip, tile] {
            #expect(spec.kind == .thumbnail)
            #expect(spec.contentMode == .aspectFill)
        }
    }

    @Test func viewerMultipliesPointsByTheDisplayScale() {
        let spec = RequestSpec(.viewer(CGSize(width: 402, height: 874)), displayScale: 3)
        #expect(spec.kind == .viewer)
        #expect(spec.contentMode == .aspectFit)
        #expect(spec.targetSize == CGSize(width: 1206, height: 2622))
    }

    @Test func viewerSizeStaysWithinBounds() {
        let huge = RequestSpec(.viewer(CGSize(width: 5_000, height: 1_000_000)), displayScale: 3)
        #expect(huge.targetSize == CGSize(width: 4_096, height: 4_096))
        let empty = RequestSpec(.viewer(.zero), displayScale: 3)
        #expect(empty.targetSize == CGSize(width: 64, height: 64))
        let invalid = RequestSpec(.viewer(CGSize(width: CGFloat.nan, height: .infinity)), displayScale: 3)
        #expect(invalid.targetSize == CGSize(width: 64, height: 64))
    }
}

@Suite("LRU cache")
struct LRUCacheTests {
    @Test func returnsWhatWasInserted() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.insert(1, for: "a")
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == nil)
    }

    @Test func evictsTheLeastRecentlyUsed() {
        var cache = LRUCache<Int, Int>(capacity: 10)
        for key in 0..<10 { cache.insert(key, for: key) }
        _ = cache.value(for: 0) // 0 is now the most recently used.
        cache.insert(10, for: 10)
        #expect(cache.count == 9)
        #expect(cache.value(for: 0) == 0)
        #expect(cache.value(for: 10) == 10)
        #expect(cache.value(for: 1) == nil)
        #expect(cache.value(for: 2) == nil)
    }

    @Test func neverExceedsCapacity() {
        var cache = LRUCache<Int, Int>(capacity: ImageLoader.assetCacheCapacity)
        for key in 0..<5_000 { cache.insert(key, for: key) }
        #expect(cache.count <= ImageLoader.assetCacheCapacity)
        #expect(cache.value(for: 4_999) == 4_999)
    }
}

/// Records cancellations instead of talking to PhotoKit. `PHImageManager` is unchecked
/// `Sendable`; this subclass adds only a `Mutex`.
nonisolated final class RecordingImageManager: PHImageManager, @unchecked Sendable {
    let cancelled = Mutex<[PHImageRequestID]>([])

    override func cancelImageRequest(_ requestID: PHImageRequestID) {
        cancelled.withLock { $0.append(requestID) }
    }
}

@Suite("Image load streams")
struct ImageLoadTests {
    let manager = RecordingImageManager()
    let degraded = UIImage()
    let final = UIImage()

    private func makeLoad() -> (ImageLoad, AsyncStream<UIImage>) {
        let (stream, continuation) = AsyncStream.makeStream(of: UIImage.self)
        let load = ImageLoad(manager: manager, continuation: continuation)
        continuation.onTermination = { _ in load.cancel() }
        return (load, stream)
    }

    private func collect(_ stream: AsyncStream<UIImage>) async -> [UIImage] {
        var images: [UIImage] = []
        for await image in stream { images.append(image) }
        return images
    }

    @Test func thumbnailYieldsDegradedThenFinal() async {
        let (load, stream) = makeLoad()
        load.register(7)
        load.receive(degraded, ImageResult(isDegraded: true))
        load.receive(final, ImageResult())
        let images = await collect(stream)
        #expect(images.count == 2)
        #expect(images.first === degraded)
        #expect(images.last === final)
        // A finished request is not cancelled.
        #expect(manager.cancelled.withLock { $0 }.isEmpty)
    }

    @Test func thumbnailFailureEndsWithoutImage() async {
        let (load, stream) = makeLoad()
        load.receive(nil, ImageResult(failed: true))
        #expect(await collect(stream).isEmpty)
    }

    @Test func iCloudFailureKeepsTheDegradedImage() async {
        let (load, stream) = makeLoad()
        load.receive(degraded, ImageResult(isDegraded: true))
        load.receive(nil, ImageResult(isDegraded: true, failed: true))
        let images = await collect(stream)
        #expect(images.count == 1)
        #expect(images.first === degraded)
    }

    /// A high-quality viewer request delivers one result. A failure ends the stream with no
    /// image, which is how the pager tells a failed download from a loaded photo.
    @Test func viewerFailureEndsWithoutImage() async {
        let (load, stream) = makeLoad()
        load.register(2)
        load.receive(nil, ImageResult(failed: true))
        #expect(await collect(stream).isEmpty)
    }

    @Test func synchronousResultNeedsNoCancel() async {
        let (load, stream) = makeLoad()
        load.receive(final, ImageResult())
        load.register(3)
        #expect(await collect(stream).count == 1)
        #expect(manager.cancelled.withLock { $0 }.isEmpty)
    }

    @Test func endingTheStreamCancelsTheRequest() async {
        let (load, stream) = makeLoad()
        load.register(12)
        let consumer = Task { await collect(stream) }
        consumer.cancel()
        _ = await consumer.value
        #expect(manager.cancelled.withLock { $0 } == [12])
    }

    @Test func requestsStartedAfterTheEndAreCancelledAtOnce() {
        let (load, _) = makeLoad()
        load.cancel()
        load.register(21)
        #expect(manager.cancelled.withLock { $0 } == [21])
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        load.attach(task)
        #expect(task.isCancelled)
    }

    @Test func cancelledResultsAreIgnored() async {
        let (load, stream) = makeLoad()
        load.receive(final, ImageResult(isCancelled: true))
        load.finish()
        #expect(await collect(stream).isEmpty)
    }

    @Test func resultFlagsComeFromTheInfoDictionary() {
        let degraded = ImageResult([PHImageResultIsDegradedKey: true])
        #expect(degraded.isDegraded && !degraded.isFinal)
        let failed = ImageResult([PHImageResultIsDegradedKey: true, PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3169)])
        #expect(failed.failed && failed.isFinal)
        let cancelled = ImageResult([PHImageCancelledKey: true])
        #expect(cancelled.isCancelled)
        #expect(ImageResult(nil).isFinal)
    }
}
