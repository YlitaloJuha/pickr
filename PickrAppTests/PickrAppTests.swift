import Foundation
import Photos
import PickrCore
import Testing
import UIKit
@testable import Pickr

// Hosted tests for the PhotoKit adapter (blueprint §4.8, WP3). They run once an iOS
// simulator runtime is installed; until then they are compiled with build-for-testing.
//
// The live suite needs full Photos access and the 40 test photos:
//
//     xcrun simctl privacy booted grant photos com.juha.Culler
//     xcrun simctl addmedia booted test-photos/*.jpg

private nonisolated enum Authorization {
    static var status: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }
    static var isFull: Bool { status == .authorized }
    static var isMissing: Bool { status == .notDetermined || status == .denied || status == .restricted }
}

@Suite("Photos adapter")
struct PhotosAdapterTests {
    @Test func noImageLoaderFinishesImmediately() async {
        var count = 0
        for await _ in NoImageLoader().images(for: PhotoID("x"), size: .card) {
            count += 1
        }
        #expect(count == 0)
    }

    @Test func sumsEveryKnownResourceSize() {
        #expect(AssetSizer.total(ofResourceSizes: [2_000_000, 3_500_000, 120_000]) == 5_620_000)
        #expect(AssetSizer.total(ofResourceSizes: [nil, 4_096, nil]) == 4_096)
        #expect(AssetSizer.total(ofResourceSizes: [0]) == 0)
    }

    @Test func unknownSizesAreNotZero() {
        #expect(AssetSizer.total(ofResourceSizes: [nil, nil]) == nil)
        #expect(AssetSizer.total(ofResourceSizes: []) == nil)
        #expect(AssetSizer.total(ofResourceSizes: [-1]) == nil)
    }

    @Test func indexFetchSetsEveryFlag() throws {
        let options = AssetQueries.indexOptions()
        #expect(!options.includeHiddenAssets)
        #expect(!options.includeAllBurstAssets)
        #expect(options.includeAssetSourceTypes == [.typeUserLibrary])
        #expect(!options.wantsIncrementalChangeDetails)
        let sort = try #require(options.sortDescriptors?.first)
        #expect(sort.key == "creationDate")
        #expect(!sort.ascending)
    }

    @Test func refetchesExcludeHiddenPhotos() {
        let options = AssetQueries.visibleOptions()
        #expect(!options.includeHiddenAssets)
        #expect(!options.includeAllBurstAssets)
        #expect(options.includeAssetSourceTypes == [.typeUserLibrary])
        #expect(!options.wantsIncrementalChangeDetails)
    }

    @Test func existenceChecksIncludeHiddenPhotos() {
        let options = AssetQueries.existenceOptions()
        #expect(options.includeHiddenAssets)
        #expect(options.includeAllBurstAssets)
        #expect(options.includeAssetSourceTypes == [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced])
        #expect(!options.wantsIncrementalChangeDetails)
    }

    @Test func newestFirstRecordsComeOutInCaptureOrder() {
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let newestFirst = [
            AssetRecord(id: PhotoID("d"), created: t0.addingTimeInterval(20)),
            AssetRecord(id: PhotoID("b"), created: t0.addingTimeInterval(10)),
            AssetRecord(id: PhotoID("c"), created: t0.addingTimeInterval(10)),
            AssetRecord(id: PhotoID("a"), created: t0),
        ]
        let ordered = LibraryIndexer.captureOrdered(newestFirst: newestFirst)
        #expect(ordered.map(\.id.rawValue) == ["a", "b", "c", "d"])
        #expect(LibraryIndexer.captureOrdered(newestFirst: []).isEmpty)
    }

    @Test func deletingNothingThrowsNothingToDelete() async {
        await #expect(throws: LibraryError.nothingToDelete) {
            try await Deleter.delete([])
        }
    }
}

@Suite("Photos adapter without access", .enabled(if: Authorization.isMissing))
struct PhotosAdapterWithoutAccessTests {
    let library = LivePhotoLibrary(cache: IndexCache(url: URL.temporaryDirectory.appending(path: "no-access-\(UUID().uuidString).plist")))

    @Test func reportsTheSystemStatus() async {
        #expect(await library.access() == LivePhotoLibrary.access(from: Authorization.status))
    }

    @Test func neverConfirmsAPhotoGone() async {
        let ids = [PhotoID("A/L0/001"), PhotoID("B/L0/001")]
        #expect(await library.existingIDs(among: ids) == Set(ids))
    }

    @Test func refusesToDelete() async {
        await #expect(throws: LibraryError.notAuthorized) {
            try await library.delete([PhotoID("A/L0/001")])
        }
    }
}

@Suite(
    "Live photo library",
    .serialized,
    .enabled(if: Authorization.isFull, "Needs full Photos access and the test photos in the simulator")
)
struct LiveLibrarySmokeTests {
    /// The test photos were taken on 2026-04-12 between 09:37 and 09:54 local time; this
    /// window holds them in every time zone and leaves out the simulator's sample photos.
    static let testPhotoDays = DateInterval(
        start: Date(timeIntervalSince1970: 1_775_865_600), // 2026-04-11T00:00:00Z
        end: Date(timeIntervalSince1970: 1_776_124_800) // 2026-04-14T00:00:00Z
    )

    let cacheURL = URL.temporaryDirectory.appending(path: "live-index-\(UUID().uuidString).plist")

    private func testPhotos(in library: LivePhotoLibrary) async throws -> [AssetRecord] {
        var complete: IndexSnapshot?
        for await event in library.indexEvents() {
            if case .snapshot(let snapshot) = event, snapshot.isComplete {
                complete = snapshot
                break
            }
        }
        let snapshot = try #require(complete)
        return snapshot.records.filter { Self.testPhotoDays.contains($0.created) }
    }

    @Test(.timeLimit(.minutes(1)))
    func indexesFortyPhotosIntoSevenMoments() async throws {
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let library = LivePhotoLibrary(cache: IndexCache(url: cacheURL))
        let photos = try await testPhotos(in: library)
        #expect(photos.count == 40)
        #expect(Clusterer.moments(from: photos, window: .default).count == 7)
    }

    @Test(.timeLimit(.minutes(1)))
    func secondLaunchStartsFromTheCache() async throws {
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let firstLaunch = LivePhotoLibrary(cache: IndexCache(url: cacheURL))
        _ = try await testPhotos(in: firstLaunch)
        // The first build writes the cache right away; give the write a moment.
        try await Task.sleep(for: .milliseconds(500))
        withExtendedLifetime(firstLaunch) {}
        let cached = try #require(IndexCache(url: cacheURL).load())
        #expect(cached.scope == .full)
        #expect(cached.token != nil)
        #expect(cached.records.filter { Self.testPhotoDays.contains($0.created) }.count == 40)

        var first: IndexSnapshot?
        for await event in LivePhotoLibrary(cache: IndexCache(url: cacheURL)).indexEvents() {
            if case .snapshot(let snapshot) = event {
                first = snapshot
                break
            }
        }
        #expect(first?.isComplete == false)
        #expect(first?.records.count == cached.records.count)
    }

    @Test(.timeLimit(.minutes(1)))
    func sizesAreKnownForEveryTestPhoto() async throws {
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let library = LivePhotoLibrary(cache: IndexCache(url: cacheURL))
        let ids = try await testPhotos(in: library).map(\.id)
        let sizes = await library.resolveSizes(ids)
        #expect(sizes.count == 40)
        #expect(sizes.values.allSatisfy { $0 > 0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func refetchesAndExistenceAgreeWithTheIndex() async throws {
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let library = LivePhotoLibrary(cache: IndexCache(url: cacheURL))
        let photos = try await testPhotos(in: library)
        let ids = photos.map(\.id)
        let gone = PhotoID("00000000-0000-0000-0000-000000000000/L0/001")
        #expect(await library.currentRecords(ids + [gone]) == photos)
        #expect(await library.existingIDs(among: ids + [gone]) == Set(ids))
        await #expect(throws: LibraryError.nothingToDelete) {
            try await library.delete([gone])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsAThumbnail() async throws {
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let library = LivePhotoLibrary(cache: IndexCache(url: cacheURL))
        let id = try #require(try await testPhotos(in: library).first?.id)
        var last: UIImage?
        for await image in ImageLoader(displayScale: 3).images(for: id, size: .tile) {
            last = image
        }
        let image = try #require(last)
        #expect(min(image.size.width * image.scale, image.size.height * image.scale) > 0)
    }
}
