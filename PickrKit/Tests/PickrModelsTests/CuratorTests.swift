import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

private let ids = TestLibrary.ids
private let id = TestLibrary.id

/// a1 1 KB, a2 2 KB, a3 3 KB; everything else 1 MB.
private func sizedHarness(access: LibraryAccess = .full) -> Harness {
    var sizes = TestLibrary.sizes(TestLibrary.standard)
    sizes[id("a1")] = 1_000
    sizes[id("a2")] = 2_000
    sizes[id("a3")] = 3_000
    return Harness(access: access, sizes: sizes)
}

@Suite("Curator: deletion (§1.5, §2.5 rail 5)")
struct CuratorDeletionTests {
    @Test func partialDeleteUpdatesStatsKeptAndTheListAtOnce() async throws {
        let h = sizedHarness()
        await h.launch()
        let a = try h.requireMoment("a1")

        let result = await h.curator.commit(a, selection: Selection(kept: [id("a1")]))

        #expect(result == .committed(deleted: 2, freed: ByteEstimate(bytes: 5_000, isApproximate: false)))
        #expect(h.fake.calls.delete == [ids("a2", "a3")], "one PhotoKit request per commit")
        // Stats: confirmed deletions only.
        #expect(h.settings.stats.photosDeleted == 2)
        #expect(h.settings.stats.bytesFreed == 5_000)
        #expect(h.settings.stats.momentsCleared == 1)
        let persisted = StatsRepository(store: h.defaults).load(now: TestLibrary.now)
        #expect(persisted == h.settings.stats)
        // The keeper goes to Kept so it never comes back as a leftover.
        #expect(h.kept.items[id("a1")]?.kind == .reviewed)
        #expect(h.kept.items[id("a1")]?.since == TestLibrary.now)
        // The moment leaves the list at once, without waiting for the library delta.
        #expect(h.moment("a1") == nil)
        #expect(h.anchors == ["b1", "c1"])
        let toast = try #require(h.toasts.current)
        #expect(toast.message.hasPrefix("Moved 2 photos to Recently Deleted · "))
        #expect(!toast.isError)
        #expect(!toast.canUndo)

        await h.settle()
        #expect(h.anchors == ["b1", "c1"])
        #expect(try await h.keptFile().items.map(\.id) == ids("a1"))
    }

    @Test func statsCountOnlyWhatPhotoKitConfirmed() async throws {
        let h = sizedHarness()
        await h.launch()
        let b = try h.requireMoment("b1")
        h.fake.hide(ids("b4")) // hidden since indexing: the Deleter drops it

        let result = await h.curator.commit(b, selection: Selection(kept: [id("b1")]))

        #expect(result == .committed(deleted: 2, freed: ByteEstimate(bytes: 2_000_000, isApproximate: false)))
        #expect(h.settings.stats.photosDeleted == 2)
        #expect(h.settings.stats.bytesFreed == 2_000_000)
        #expect(!h.library.index.contains { $0.id == id("b4") }, "a missing photo leaves the index too")
        #expect(h.kept.ids == Set(ids("b1")))
    }

    @Test func unknownSizesMakeTheFreedFigureApproximate() async throws {
        let h = Harness(sizes: [id("a2"): 2_000])
        await h.launch()
        let a = try h.requireMoment("a1")

        let result = await h.curator.commit(a, selection: Selection(kept: [id("a1")]))

        #expect(result == .committed(deleted: 2, freed: ByteEstimate(bytes: 2_000, isApproximate: true)))
        #expect(h.settings.stats.bytesFreed == 2_000)
        #expect(h.toasts.current?.message.contains("about") == true)
    }

    @Test func cancelChangesNothingAndStaysSilent() async throws {
        let h = sizedHarness()
        await h.launch()
        let a = try h.requireMoment("a1")
        h.fake.enqueueDeleteOutcomes(.fail(.cancelled))

        let result = await h.curator.commit(a, selection: Selection(kept: [id("a1")]))
        await h.settle()

        #expect(result == .cancelled)
        #expect(h.settings.stats.photosDeleted == 0)
        #expect(h.settings.stats.momentsCleared == 0)
        #expect(h.kept.items.isEmpty)
        #expect(h.anchors == ["a1", "b1", "c1"])
        #expect(h.toasts.current == nil)
    }

    @Test func failureShowsAnErrorToastAndRetryFinishesTheJob() async throws {
        let h = sizedHarness()
        await h.launch()
        let a = try h.requireMoment("a1")
        h.fake.enqueueDeleteOutcomes(.fail(.failed(domain: "PHPhotosErrorDomain", code: -1)))

        let result = await h.curator.commit(a, selection: Selection(kept: [id("a1")]))
        await h.settle()

        #expect(result == .failed(.failed(domain: "PHPhotosErrorDomain", code: -1)))
        let toast = try #require(h.toasts.current)
        #expect(toast.isError)
        #expect(h.settings.stats.photosDeleted == 0)
        #expect(h.kept.items.isEmpty)
        #expect(h.anchors == ["a1", "b1", "c1"])

        await h.toasts.performRetry()
        await h.settle()

        #expect(h.fake.calls.delete == [ids("a2", "a3"), ids("a2", "a3")])
        #expect(h.settings.stats.photosDeleted == 2)
        #expect(h.kept.ids == Set(ids("a1")))
        #expect(h.anchors == ["b1", "c1"])
        #expect(h.toasts.current?.isError == false)
    }

    @Test(arguments: [LibraryError.notAuthorized, .unavailable, .network, .limitExceeded])
    func everyRealFailureGetsAnErrorToast(error: LibraryError) async throws {
        let h = Harness()
        await h.launch()
        let c = try h.requireMoment("c1")
        h.fake.enqueueDeleteOutcomes(.fail(error))

        let result = await h.curator.deleteWhole(c)

        #expect(result == .failed(error))
        #expect(h.toasts.current?.isError == true)
        #expect(h.settings.stats == StatsRepository(store: h.defaults).load(now: TestLibrary.now))
        #expect(h.settings.stats.photosDeleted == 0)
    }

    @Test func photosAlreadyGoneFinishTheMomentWithoutCounting() async throws {
        let h = Harness()
        await h.launch()
        let a = try h.requireMoment("a1")
        h.fake.remove(ids("a2", "a3")) // deleted on another device

        let result = await h.curator.commit(a, selection: Selection(kept: [id("a1")]))

        #expect(result == .failed(.nothingToDelete))
        #expect(h.settings.stats.photosDeleted == 0)
        #expect(h.settings.stats.momentsCleared == 0)
        #expect(h.moment("a1") == nil)
        #expect(h.kept.ids == Set(ids("a1")))
        #expect(h.toasts.current?.isError == false)
    }

    @Test func undecidedCommitDoesNothing() async throws {
        let h = Harness()
        await h.launch()
        let a = try h.requireMoment("a1")

        let result = await h.curator.commit(a, selection: Selection())

        #expect(result == .cancelled)
        #expect(h.fake.calls.delete.isEmpty)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }
}

@Suite("Curator: protection (§2.5 rails 1–3)")
struct CuratorProtectionTests {
    /// b2 is a favorite, b3 is rated.
    private func protectedHarness(protect: Bool = true) -> Harness {
        let records = TestLibrary.burst("a", count: 3, daysAgo: 1)
            + TestLibrary.burst("b", count: 4, daysAgo: 2, favorites: [2], ratings: [3: 4])
            + TestLibrary.burst("c", count: 2, daysAgo: 3)
        let defaults = InMemoryKeyValueStore()
        if !protect { defaults.set(false, forKey: PersistedKeys.Settings.protectFavorites) }
        return Harness(records: records, defaults: defaults)
    }

    @Test func deleteMomentNeverDeletesProtectedPhotos() async throws {
        let h = protectedHarness()
        await h.launch()
        let b = try h.requireMoment("b1")
        #expect(h.curator.deletableIDs(wholeMoment: b) == ids("b1", "b4"))

        let result = await h.curator.deleteWhole(b)

        #expect(result == .committed(deleted: 2, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(h.fake.calls.delete == [ids("b1", "b4")])
        #expect(h.kept.items[id("b2")]?.kind == .reviewed, "protected photos survive as reviewed Kept items")
        #expect(h.kept.items[id("b3")]?.kind == .reviewed)
        #expect(h.moment("b1") == nil)
        #expect(h.fake.records.contains { $0.id == id("b2") })
    }

    @Test func withProtectionOffDeleteMomentDeletesEverything() async throws {
        let h = protectedHarness(protect: false)
        await h.launch()
        let b = try h.requireMoment("b1")
        #expect(!h.settings.protectFavorites)
        #expect(h.curator.deletableIDs(wholeMoment: b) == ids("b1", "b2", "b3", "b4"))

        _ = await h.curator.deleteWhole(b)

        #expect(h.fake.calls.delete == [ids("b1", "b2", "b3", "b4")])
        #expect(h.fake.calls.currentRecords.isEmpty)
        #expect(h.kept.items.isEmpty)
    }

    @Test func aMomentOfOnlyProtectedPhotosCannotBeDeletedWhole() async throws {
        let records = TestLibrary.burst("f", count: 3, daysAgo: 1, favorites: [1, 2], ratings: [3: 1])
        let h = Harness(records: records)
        await h.launch()
        let f = try h.requireMoment("f1")

        #expect(!h.curator.canDeleteWhole(f))
        #expect(await h.curator.deleteWhole(f) == .cancelled)
        #expect(h.fake.calls.delete.isEmpty)
        #expect(h.anchors == ["f1"])

        h.settings.protectFavorites = false
        #expect(h.curator.canDeleteWhole(f))
    }

    @Test func aPhotoFavoritedSinceIndexingIsSpared() async throws {
        let h = Harness()
        await h.launch()
        let b = try h.requireMoment("b1")
        h.fake.setFavorite(id("b2"), true) // favorited in Photos; the index doesn't know yet

        let result = await h.curator.deleteWhole(b)

        #expect(result == .committed(deleted: 3, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(h.fake.calls.currentRecords == [ids("b1", "b2", "b3", "b4")])
        #expect(h.fake.calls.delete == [ids("b1", "b3", "b4")])
        #expect(h.kept.items[id("b2")]?.kind == .reviewed)
    }

    @Test func aPartialCommitHonoursAnExplicitUnkeep() async throws {
        let h = protectedHarness()
        await h.launch()
        let b = try h.requireMoment("b1")

        // The user un-kept the favorite b2 and kept only b1.
        let result = await h.curator.commit(b, selection: Selection(kept: [id("b1")]))

        #expect(result == .committed(deleted: 3, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(h.fake.calls.delete == [ids("b2", "b3", "b4")])
    }

    @Test func bulkConfirmationAppearsAtTwentyDeletablePhotos() async throws {
        let records = TestLibrary.burst("x", count: 20, daysAgo: 1, spacing: 1)
            + TestLibrary.burst("y", count: 19, daysAgo: 2, spacing: 1)
            + TestLibrary.burst("z", count: 21, daysAgo: 3, spacing: 1, favorites: [1, 2])
        let h = Harness(records: records)
        await h.launch()
        let x = try h.requireMoment("x1")
        let y = try h.requireMoment("y1")
        let z = try h.requireMoment("z1")

        #expect(Curator.bulkConfirmationThreshold == 20)
        #expect(h.curator.needsBulkConfirmation(wholeMoment: x))
        #expect(!h.curator.needsBulkConfirmation(wholeMoment: y))
        #expect(!h.curator.needsBulkConfirmation(wholeMoment: z), "21 photos, 2 protected: 19 deletable")

        h.settings.protectFavorites = false
        #expect(h.curator.needsBulkConfirmation(wholeMoment: z))
    }
}

@Suite("Curator: Kept")
struct CuratorKeptTests {
    @Test func keepAsideIsUndoable() async throws {
        let h = Harness()
        await h.launch()
        let a = try h.requireMoment("a1")

        h.curator.keepAside(a)

        #expect(h.moment("a1") == nil, "the card leaves at once")
        #expect(h.kept.ids == Set(ids("a1", "a2", "a3")))
        #expect(h.kept.items.values.allSatisfy { $0.kind == .keptAside && $0.since == TestLibrary.now })
        #expect(h.settings.stats.momentsCleared == 0, "keep-aside doesn't count as cleared")
        let toast = try #require(h.toasts.current)
        #expect(toast.message == "Moment kept.")
        #expect(toast.canUndo)
        await h.settle()
        #expect(h.anchors == ["b1", "c1"])
        #expect(try await h.keptFile().items.count == 3)

        await h.toasts.performUndo()
        await h.settle()

        #expect(h.kept.items.isEmpty)
        #expect(h.anchors == ["a1", "b1", "c1"])
        #expect(h.toasts.current == nil)
        #expect(try await h.keptFile().items.isEmpty)
    }

    @Test func committingWithEverythingKeptKeepsTheMomentAside() async throws {
        let h = Harness()
        await h.launch()
        let c = try h.requireMoment("c1")

        let result = await h.curator.commit(c, selection: Selection(kept: Set(c.photoIDs)))

        #expect(result == .keptAside)
        #expect(h.fake.calls.delete.isEmpty)
        #expect(h.kept.items[id("c1")]?.kind == .keptAside)
        #expect(h.toasts.current?.canUndo == true)
    }

    @Test func restoreRegroupsAndIsUndoable() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try h.requireMoment("a1"))
        await h.settle()
        let applied = h.library.appliedRegroups
        let before = h.kept.items

        h.curator.restore(ids("a1", "a2", "a3"))
        await h.settle()

        #expect(h.kept.items.isEmpty)
        #expect(h.library.appliedRegroups > applied, "a restore triggers a regroup")
        #expect(h.anchors == ["a1", "b1", "c1"])
        let toast = try #require(h.toasts.current)
        #expect(toast.message == "It will show up in Moments again.")
        #expect(toast.canUndo)

        await h.toasts.performUndo()
        await h.settle()
        #expect(h.kept.items == before, "undo puts the items back with their kind and date")
        #expect(h.anchors == ["b1", "c1"])
    }

    @Test func restoringPhotosThatArentKeptDoesNothing() async {
        let h = Harness()
        await h.launch()

        h.curator.restore(ids("a1"))

        #expect(h.toasts.current == nil)
    }

    @Test func restoreAllRestoresOnlyLivePhotos() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try h.requireMoment("a1"))
        h.fake.hide(ids("a1")) // hidden: still exists, but out of the index
        h.fake.emitSnapshot()
        await h.settle()
        #expect(h.kept.liveIDs(in: h.library.index) == Set(ids("a2", "a3")))

        h.curator.restoreAll()

        #expect(h.kept.ids == Set(ids("a1")))
        let toast = try #require(h.toasts.current)
        #expect(toast.message == "They will show up in Moments again.")
        #expect(!toast.canUndo)
    }

    @Test func keptGroupsSplitKeptAsideFromReviewed() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try h.requireMoment("c1"))
        _ = await h.curator.commit(try h.requireMoment("b1"), selection: Selection(kept: [id("b1"), id("b3")]))
        await h.settle()

        let groups = h.kept.groups(index: h.library.index, window: h.settings.grouping.window)

        #expect(groups.aside.map(\.photoIDs) == [ids("c1", "c2")])
        #expect(groups.reviewed.map(\.photoIDs) == [ids("b1", "b3")], "single photos and survivors appear too")
    }
}

@Suite("Curator: pruning (§2.5 rail 6)")
struct CuratorPruneTests {
    /// A v1 user whose Kept list holds a deleted photo ("gone") and a hidden one ("secret").
    private func upgrader(access: LibraryAccess) -> Harness {
        let defaults = InMemoryKeyValueStore([
            PersistedKeys.Settings.onboardingCompleted: true,
            PersistedKeys.IgnoreList.photoIDs: ["a1", "gone", "secret"],
        ])
        let h = Harness(access: access, defaults: defaults)
        h.fake.addHidden(ids("secret"))
        return h
    }

    @Test func confirmedGoneItemsMoveToOrphans() async throws {
        let h = upgrader(access: .full)
        await h.launch()

        #expect(h.kept.ids == Set(ids("a1", "secret")), "hidden photos are never pruned")
        #expect(h.fake.calls.existingIDs == [ids("gone", "secret")])
        let file = try await h.keptFile()
        #expect(file.orphans.map(\.id) == ids("gone"))
        #expect(file.orphans.first?.kind == .legacy)
    }

    @Test func limitedAccessNeverPrunes() async throws {
        let h = upgrader(access: .limited)
        await h.launch()
        h.fake.emit(.confirmedDeleted(Set(ids("a1", "gone"))))
        await h.settle()

        #expect(h.kept.ids == Set(ids("a1", "gone", "secret")))
        #expect(h.fake.calls.existingIDs.isEmpty)
        #expect(try await h.keptFile().orphans.isEmpty)
    }

    @Test func persistentHistoryDeletionsPruneDirectly() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try h.requireMoment("c1"))
        await h.settle()

        h.fake.remove(ids("c1"))
        h.fake.emit(.confirmedDeleted(Set(ids("c1"))))
        await h.settle()

        #expect(h.kept.ids == Set(ids("c2")))
        #expect(try await h.keptFile().orphans.map(\.id) == ids("c1"))
    }
}
