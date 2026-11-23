import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

private let ids = TestLibrary.ids
private let id = TestLibrary.id

@Suite("Router")
struct RouterTests {
    @Test func reviewStartsAtTheFirstMomentInListOrder() async throws {
        let h = Harness()
        await h.launch()
        h.router.tab = .kept

        h.router.startReview(at: nil)

        let session = try #require(h.router.review)
        #expect(session.current?.id.anchor == id("a1"))
        #expect(session.position == 1)
        #expect(session.total == 3)
        #expect(session.mode == .grid)
        #expect(h.router.momentsPath == [.review])
        #expect(h.router.tab == .moments)
    }

    @Test func reviewStartsAtTheTappedMoment() async throws {
        let h = Harness()
        await h.launch()

        h.router.startReview(at: try h.requireMoment("b1").id)

        let session = try #require(h.router.review)
        #expect(session.current?.id.anchor == id("b1"))
        #expect(session.position == 2)
        #expect(session.total == 3)
    }

    @Test func noReviewForAnUnlistedMomentOrAnEmptyList() async {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: MomentID(anchor: id("nope")))
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)

        let empty = Harness(records: [])
        await empty.launch()
        empty.router.startReview(at: nil)
        #expect(empty.router.review == nil)
    }

    @Test func poppingReviewEndsTheSession() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)

        h.router.momentsPath = [] // Back

        #expect(h.router.review == nil)
        #expect(!session.isActive)
    }

    @Test func sheetsAreIdentifiedByName() {
        #expect(Router.Sheet.grouping.id == "grouping")
        #expect(Router.Sheet.settings.id == "settings")
        #expect(Router.Sheet.whatsNew.id == "whatsNew")
    }

    @Test func endReviewPops() async {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)

        h.router.endReview()

        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
    }
}

@Suite("ReviewSession: flow")
struct ReviewSessionFlowTests {
    @Test func skipMovesOnAndKeepsTheMomentListed() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.mode = .single
        session.singleIndex = 2

        session.skip()

        #expect(session.current?.id.anchor == id("b1"))
        #expect(session.position == 2)
        #expect(session.singleIndex == 0)
        #expect(session.mode == .single, "the mode carries over")
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func skippingEverythingFinishesWithoutASummary() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)

        session.skip()
        session.skip()
        session.skip()

        #expect(session.isFinished)
        #expect(session.current == nil)
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
        #expect(h.toasts.current == nil)
        #expect(h.router.scrollTarget?.anchor == id("c1"))
    }

    @Test func commitsAdvanceAndTheEndShowsASummary() async throws {
        let records = TestLibrary.standard
        let h = Harness(records: records, sizes: TestLibrary.sizes(records))
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)

        session.toggle(id("a1"))
        #expect(session.outcome == .partial(keep: ids("a1"), delete: ids("a2", "a3")))
        #expect(session.deletionEstimate == ByteEstimate(bytes: 2_000_000, isApproximate: false))
        #expect(await session.commit() == .committed(deleted: 2, freed: ByteEstimate(bytes: 2_000_000, isApproximate: false)))
        #expect(session.current?.id.anchor == id("b1"))
        #expect(session.selection.kept.isEmpty)

        session.selectAll()
        #expect(await session.commit() == .keptAside)
        #expect(session.current?.id.anchor == id("c1"))

        #expect(await session.deleteWhole() == .committed(deleted: 2, freed: ByteEstimate(bytes: 2_000_000, isApproximate: false)))

        #expect(session.isFinished)
        #expect(session.summary.moments == 2, "keep-aside doesn't count as cleared")
        #expect(session.summary.photos == 4)
        #expect(session.summary.freed == ByteEstimate(bytes: 4_000_000, isApproximate: false))
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
        let toast = try #require(h.toasts.current)
        #expect(toast.message.hasPrefix("Done: 2 moments · 4 photos · "))
        #expect(toast.message.hasSuffix(" freed up."))
        await h.settle()
        #expect(h.anchors.isEmpty)
        #expect(h.router.scrollTarget == nil, "every reviewed moment is gone")
    }

    @Test func aCancelledCommitStaysOnTheMoment() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a2"))
        h.fake.enqueueDeleteOutcomes(.fail(.cancelled))

        #expect(await session.commit() == .cancelled)

        #expect(session.current?.id.anchor == id("a1"))
        #expect(session.selection.kept == Set(ids("a2")))
        #expect(!session.isCommitting)
        #expect(h.toasts.current == nil)
    }

    @Test func aFailedCommitCanBeRetriedFromTheToastAndThenMovesOn() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a2"))
        h.fake.enqueueDeleteOutcomes(.fail(.unavailable))

        #expect(await session.commit() == .failed(.unavailable))
        #expect(session.current?.id.anchor == id("a1"))
        #expect(h.toasts.current?.isError == true)

        await h.toasts.performRetry()

        #expect(session.current?.id.anchor == id("b1"))
        #expect(session.summary.moments == 1)
        #expect(session.summary.photos == 2)
    }

    @Test func keepMomentFromTheMenuMovesOn() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)

        session.keepAside()

        #expect(session.current?.id.anchor == id("b1"))
        #expect(h.kept.ids == Set(ids("a1", "a2", "a3")))
        #expect(h.toasts.current?.message == "Moment kept.", "not \"This moment changed\"")
    }

    @Test func selectionOperations() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("b1").id)
        let session = try #require(h.router.review)

        session.toggle(id("b1"))
        session.toggle(id("a1")) // not in this moment: ignored
        #expect(session.selection.kept == Set(ids("b1")))
        session.invert()
        #expect(session.selection.kept == Set(ids("b2", "b3", "b4")))
        session.selectAll()
        #expect(session.outcome == .keepAll)
        session.clear()
        #expect(session.outcome == .undecided)
    }

    @Test func protectedPhotosStartKept() async throws {
        let records = TestLibrary.burst("p", count: 4, daysAgo: 1, favorites: [2], ratings: [4: 3])
        let h = Harness(records: records)
        await h.launch()

        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        #expect(session.selection.kept == Set(ids("p2", "p4")))
        #expect(session.deletableCount == 2)
        #expect(session.canDeleteWhole)
        #expect(!session.needsBulkConfirmation)

        h.router.endReview()
        h.settings.protectFavorites = false
        h.router.startReview(at: nil)
        #expect(h.router.review?.selection.kept == Set(ids("p2", "p4")), "a remembered selection wins")
    }

    @Test func nothingIsPreselectedWithProtectionOff() async throws {
        let records = TestLibrary.burst("p", count: 4, daysAgo: 1, favorites: [2])
        let defaults = InMemoryKeyValueStore([PersistedKeys.Settings.protectFavorites: false])
        let h = Harness(records: records, defaults: defaults)
        await h.launch()

        h.router.startReview(at: nil)

        #expect(h.router.review?.selection.kept.isEmpty == true)
    }

    @Test func theSelectionSurvivesLeavingReview() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        h.router.review?.toggle(id("a2"))
        h.router.review?.skip()
        h.router.review?.toggle(id("b3"))

        h.router.momentsPath = [] // Back
        h.router.startReview(at: nil)
        #expect(h.router.review?.selection.kept == Set(ids("a2")))

        h.router.startReview(at: try h.requireMoment("b1").id)
        #expect(h.router.review?.selection.kept == Set(ids("b3")))
    }
}

@Suite("ReviewSession: revalidation")
struct ReviewSessionRevalidationTests {
    @Test func aLibraryChangeRestrictsTheSelection() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("b1").id)
        let session = try #require(h.router.review)
        session.toggle(id("b1"))
        session.toggle(id("b2"))
        session.singleIndex = 3

        h.fake.remove(ids("b2")) // deleted on another device
        h.fake.emitSnapshot()
        await h.settle()

        #expect(session.current?.photoIDs == ids("b1", "b3", "b4"))
        #expect(session.selection.kept == Set(ids("b1")))
        #expect(session.singleIndex == 2)
        #expect(h.toasts.current == nil)
    }

    @Test func aMomentWhoseFirstPhotoIsGoneIsFollowedByItsPhotos() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("b1").id)
        let session = try #require(h.router.review)
        session.toggle(id("b3"))

        h.fake.remove(ids("b1"))
        h.fake.emitSnapshot()
        await h.settle()

        #expect(session.current?.id.anchor == id("b2"))
        #expect(session.selection.kept == Set(ids("b3")))
        #expect(session.position == 2)
    }

    @Test func aMomentBelowTwoPhotosIsSkippedWithAToast() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("b1").id)
        let session = try #require(h.router.review)

        h.fake.remove(ids("b1", "b2", "b3"))
        h.fake.emitSnapshot()
        await h.settle()

        #expect(session.current?.id.anchor == id("c1"))
        #expect(session.position == 3)
        #expect(h.toasts.current?.message == "This moment changed")
    }

    @Test func newProtectedMembersStartKept() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("c1").id)
        let session = try #require(h.router.review)

        // A favorite taken right after c2 joins the moment.
        let c2 = try #require(h.fake.records.first { $0.id == id("c2") })
        h.fake.upsert([AssetRecord(id: id("c3"), created: c2.created.addingTimeInterval(5), isFavorite: true)])
        h.fake.emitSnapshot()
        await h.settle()

        #expect(session.current?.photoIDs == ids("c1", "c2", "c3"))
        #expect(session.selection.kept == Set(ids("c3")))
    }

    /// The [ARCH A2] regression: a moment deleted after a mid-review refresh still leaves the
    /// list, and a refresh that started before the delete can't bring it back.
    @Test func aMomentDeletedAfterAMidReviewRefreshStaysGone() async throws {
        let h = Harness()
        await h.launch()
        let before = h.fake.records
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)

        h.fake.emitSnapshot() // a refresh while the review is open
        await h.settle()
        session.toggle(id("a1"))
        #expect(await session.commit() == .committed(deleted: 2, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(h.moment("a1") == nil)

        // A stale complete snapshot from a refresh that began before the delete.
        h.fake.emit(.snapshot(IndexSnapshot(records: before, isComplete: true)))
        await h.settle()
        #expect(h.anchors == ["b1", "c1"])
        #expect(!h.library.index.contains { $0.id == id("a2") })

        // The library catches up.
        h.fake.emitSnapshot()
        await h.settle()
        #expect(h.anchors == ["b1", "c1"])
        #expect(session.current?.id.anchor == id("b1"))
    }

    @Test func aLeftReviewIgnoresLibraryChanges() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: try h.requireMoment("c1").id)
        let session = try #require(h.router.review)
        h.router.endReview()

        h.fake.remove(ids("c1"))
        h.fake.emitSnapshot()
        await h.settle()

        #expect(h.toasts.current == nil)
        #expect(session.current?.id.anchor == id("c1"))
    }
}
