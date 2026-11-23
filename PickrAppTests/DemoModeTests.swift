#if DEBUG
import Foundation
import PickrCore
import SwiftUI
import Testing
import UIKit
@testable import Pickr

// Demo mode (`-PickrDemo YES`), which records the README demos on a real device: its launch
// arguments, the guard in front of PhotoKit's delete, and the in-memory library and loader
// over the bundled test photos. None of these tests touches PhotoKit.

@Suite("Demo mode")
struct DemoModeTests {
    @Test func needsThePickrDemoArgument() {
        #expect(DemoMode.isRequested(in: ["Pickr", "-PickrDemo", "YES"]))
        #expect(DemoMode.isRequested(in: ["Pickr", "-PickrDemo", "1"]))
        #expect(DemoMode.isRequested(in: ["Pickr", "-PickrDemoAppearance", "dark", "-PickrDemo", "true"]))
        #expect(!DemoMode.isRequested(in: ["Pickr"]))
        #expect(!DemoMode.isRequested(in: ["Pickr", "-PickrDemo", "NO"]))
        #expect(!DemoMode.isRequested(in: ["Pickr", "-PickrDemo"]))
        #expect(!DemoMode.isRequested(in: ["Pickr", "-PickrDemoAppearance", "YES"]))
    }

    @Test func readsTheAppearance() {
        #expect(DemoMode.colorScheme(in: ["-PickrDemoAppearance", "light"]) == .light)
        #expect(DemoMode.colorScheme(in: ["-PickrDemoAppearance", "Dark"]) == .dark)
        #expect(DemoMode.colorScheme(in: ["-PickrDemoAppearance", "sepia"]) == nil)
        #expect(DemoMode.colorScheme(in: []) == nil)
    }

    @Test func theTestHostIsNotInDemoMode() {
        #expect(!DemoMode.isActive)
    }

    /// The second guard: in demo mode `Deleter` throws before PhotoKit is asked for anything.
    @Test func deleterRefusesInDemoMode() {
        #expect(throws: LibraryError.failed(domain: "PickrDemo", code: 1)) {
            try Deleter.refuseInDemoMode(true)
        }
        #expect(throws: Never.self) {
            try Deleter.refuseInDemoMode(false)
        }
    }
}

@Suite("Demo library")
struct DemoPhotoLibraryTests {
    @Test func servesTheFortyTestPhotosInCaptureOrder() async throws {
        let library = DemoPhotoLibrary()
        #expect(await library.access() == .full)
        #expect(await library.requestAccess() == .full)

        var events = library.indexEvents().makeAsyncIterator()
        guard case let .snapshot(snapshot) = try #require(await events.next()) else {
            Issue.record("The first event should be a snapshot")
            return
        }
        #expect(snapshot.isComplete)
        #expect(snapshot.records.count == 40)
        #expect(snapshot.records.first?.id == PhotoID("beach_1"))
        #expect(snapshot.records.last?.id == PhotoID("snow_3"))
        // beach_3 → sunset_1 is the first gap of the fixture timeline: 93 s.
        let gap = snapshot.records[3].created.timeIntervalSince(snapshot.records[2].created)
        #expect(gap == 93)
    }

    @Test func sizesAreStableAndPhoneLike() async {
        let library = DemoPhotoLibrary()
        let ids = [PhotoID("beach_1"), PhotoID("snow_3")]
        let sizes = await library.resolveSizes(ids)
        #expect(sizes.count == 2)
        for id in ids {
            #expect(sizes[id] == DemoPhotoLibrary.demoSize(of: id))
            #expect((1_600_000...4_400_000).contains(sizes[id] ?? 0))
        }
        #expect(await library.resolveSizes([PhotoID("not-a-photo")]).isEmpty)
    }

    @Test func deletesInMemoryOnly() async throws {
        let library = DemoPhotoLibrary()
        let ids = [PhotoID("beach_1"), PhotoID("beach_2"), PhotoID("missing")]
        let receipt = try await library.delete(ids)
        #expect(receipt.deleted == [PhotoID("beach_1"), PhotoID("beach_2")])
        #expect(receipt.missing == [PhotoID("missing")])
        #expect(await library.existingIDs(among: ids).isEmpty)
        #expect(await library.currentRecords([PhotoID("beach_3")]).count == 1)
        await #expect(throws: LibraryError.nothingToDelete) {
            try await library.delete([PhotoID("beach_1")])
        }
        // A new library (the next launch) has all 40 again.
        #expect(await DemoPhotoLibrary().existingIDs(among: ids).count == 2)
    }
}

@Suite("Demo images")
struct DemoImageLoaderTests {
    @Test func decodesToTheSizeClass() async throws {
        let loader = DemoImageLoader(displayScale: 3)
        let tile = try #require(await firstImage(loader, PhotoID("beach_1"), .tile))
        #expect(min(tile.size.width, tile.size.height) * tile.scale >= RequestSpec.tilePixels)
        let card = try #require(await firstImage(loader, PhotoID("beach_1"), .card))
        #expect(min(card.size.width, card.size.height) * card.scale >= RequestSpec.cardPixels)
        #expect(max(card.size.width, card.size.height) < max(tile.size.width, tile.size.height))
    }

    @Test func aMissingPhotoFinishesEmpty() async {
        let loader = DemoImageLoader(displayScale: 3)
        #expect(await firstImage(loader, PhotoID("not-a-photo"), .tile) == nil)
    }

    private func firstImage(_ loader: DemoImageLoader, _ id: PhotoID, _ size: ImageSizeClass) async -> UIImage? {
        for await image in loader.images(for: id, size: size) {
            return image
        }
        return nil
    }
}
#endif
