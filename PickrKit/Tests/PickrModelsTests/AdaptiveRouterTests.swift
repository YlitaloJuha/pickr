import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

private let ids = TestLibrary.ids
private let id = TestLibrary.id

/// The moment anchored at `raw`, for selections and `startReview(at:)`.
private func momentID(_ raw: String) -> MomentID {
    MomentID(anchor: PhotoID(raw))
}

/// ADAPTIVE §3.3: the Router invariants that make a stack ↔ split swap lossless.
@Suite("Router: adaptive invariants")
struct AdaptiveRouterInvariantTests {
    @Test func pathAndReviewAgreeInBothDirections() async throws {
        let h = Harness()
        await h.launch()
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)

        h.router.startReview(at: nil)
        #expect(h.router.review != nil)
        #expect(h.router.momentsPath == [.review])

        h.router.endReview()
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)

        h.router.startReview(at: momentID("b1"))
        h.router.momentsPath = [] // Back in the stack
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
    }

    /// The stack's zoom back lands on the moment's card, so the list first brings it on screen.
    @Test func leavingMidReviewScrollsTheListToTheMomentOnScreen() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.skip()
        session.skip()
        #expect(session.current?.id == momentID("c1"))

        h.router.momentsPath = [] // Back in the stack
        #expect(h.router.scrollTarget == momentID("c1"))

        h.router.scrollTarget = nil // the list scrolled
        h.router.startReview(at: momentID("b1"))
        #expect(h.router.scrollTarget == nil)
        h.router.endReview() // Esc
        #expect(h.router.scrollTarget == momentID("b1"))
    }

    @Test func aStrayReviewRouteWithoutASessionIsRemoved() async {
        let h = Harness()
        await h.launch()

        h.router.momentsPath = [.review]

        #expect(h.router.momentsPath.isEmpty)
        #expect(h.router.review == nil)
    }

    @Test func reassertingThePathKeepsTheSession() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)
        session.toggle(id("b2"))
        session.mode = .single
        session.singleIndex = 3

        h.router.momentsPath = [.review] // a NavigationStack that appears with the path

        #expect(h.router.review === session)
        #expect(session.isActive)
        #expect(session.current?.id == momentID("b1"))
        #expect(session.selection.kept == Set(ids("b2")))
        #expect(session.mode == .single)
        #expect(session.singleIndex == 3)
    }

    @Test func startingAnotherMomentMovesTheOpenSession() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("a1"))
        let session = try #require(h.router.review)
        session.toggle(id("a2"))
        session.mode = .single
        session.singleIndex = 2

        h.router.startReview(at: momentID("c1")) // a sidebar tap

        #expect(h.router.review === session, "views holding the session keep working")
        #expect(session.isActive)
        #expect(session.current?.id == momentID("c1"))
        #expect(session.position == 3)
        #expect(session.total == 3)
        #expect(session.mode == .single, "the mode carries over")
        #expect(session.singleIndex == 0)
        #expect(session.selection.kept.isEmpty)
        #expect(h.router.momentsPath == [.review])

        h.router.startReview(at: momentID("a1"))
        #expect(session.current?.id == momentID("a1"))
        #expect(session.selection.kept == Set(ids("a2")), "the moment left keeps its selection")
    }

    @Test func startingAtTheFirstMomentDuringAReviewMovesThere() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))

        h.router.startReview(at: nil)

        #expect(h.router.review?.current?.id == momentID("a1"))
        #expect(h.router.review?.position == 1)
    }

    @Test func startingTheMomentUnderReviewChangesNothing() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("a1"))
        let session = try #require(h.router.review)
        session.toggle(id("a3"))
        session.mode = .single
        session.singleIndex = 1
        h.router.sheet = .grouping
        h.router.tab = .kept

        h.router.startReview(at: momentID("a1"))

        #expect(h.router.review === session)
        #expect(session.selection.kept == Set(ids("a3")))
        #expect(session.mode == .single)
        #expect(session.singleIndex == 1)
        #expect(h.router.sheet == nil, "it still closes the sheet")
        #expect(h.router.tab == .moments)
        #expect(h.router.momentsPath == [.review])
    }

    @Test func theSummaryCarriesOverToTheEnd() async throws {
        let records = TestLibrary.standard
        let h = Harness(records: records, sizes: TestLibrary.sizes(records))
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a1"))
        #expect(await session.commit() == .committed(deleted: 2, freed: ByteEstimate(bytes: 2_000_000, isApproximate: false)))
        #expect(session.current?.id == momentID("b1"))

        h.router.startReview(at: momentID("c1")) // a sidebar tap past b
        session.toggle(id("c1"))
        #expect(await session.commit() == .committed(deleted: 1, freed: ByteEstimate(bytes: 1_000_000, isApproximate: false)))

        #expect(session.isFinished)
        #expect(session.summary.moments == 2)
        #expect(session.summary.photos == 3)
        #expect(session.summary.freed == ByteEstimate(bytes: 3_000_000, isApproximate: false))
        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
        let toast = try #require(h.toasts.current)
        #expect(toast.message.hasPrefix("Done: 2 moments · 3 photos · "))
        #expect(toast.message.hasSuffix(" freed up."))
        #expect(h.router.scrollTarget == momentID("b1"), "the last reviewed moment still listed")
    }

    @Test func aTryAgainAfterMovingOnCountsWithoutMovingTheReview() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a2"))
        h.fake.enqueueDeleteOutcomes(.fail(.unavailable))
        #expect(await session.commit() == .failed(.unavailable))

        h.router.reviewSelection = momentID("c1")
        await h.toasts.performRetry()

        #expect(session.current?.id == momentID("c1"), "the review stays where the person is")
        #expect(h.moment("a1") == nil)
        #expect(session.summary.moments == 1)
        #expect(session.summary.photos == 2)
    }

    @Test func noMoveWhileACommitWaitsForPhotoKit() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)
        #expect(h.router.previousMoment == momentID("a1"))
        session.toggle(id("b1"))
        h.fake.holdDeletes()

        let commit = Task { await session.commit() }
        #expect(await eventually { h.fake.heldDeleteCount == 1 })
        #expect(session.isCommitting)

        h.router.startReview(at: momentID("c1"))
        h.router.reviewSelection = momentID("a1")
        h.router.reviewPreviousMoment()
        #expect(session.current?.id == momentID("b1"))
        #expect(h.router.previousMoment == nil, "Previous Moment is disabled")

        h.fake.releaseDeletes()
        #expect(await commit.value == .committed(deleted: 3, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(session.current?.id == momentID("c1"))
        #expect(h.router.previousMoment == momentID("a1"), "b left the list")
    }
}

/// ADAPTIVE §3.2: the list's selection in a split mirrors the moment under review, and the
/// Kept list's selection maps onto `keptPath`.
@Suite("Router: list selections")
struct AdaptiveRouterSelectionTests {
    @Test func theSelectionFollowsTheReview() async throws {
        let h = Harness()
        await h.launch()
        #expect(h.router.reviewSelection == nil)

        h.router.reviewSelection = momentID("b1") // a sidebar tap with nothing under review
        let session = try #require(h.router.review)
        #expect(session.current?.id == momentID("b1"))
        #expect(session.position == 2)
        #expect(h.router.momentsPath == [.review])

        session.skip()
        #expect(h.router.reviewSelection == momentID("c1"), "the highlight follows Skip")

        h.router.reviewSelection = momentID("a1")
        session.keepAside()
        #expect(h.router.reviewSelection == momentID("b1"), "the highlight follows a commit")

        session.skip()
        session.skip()
        #expect(session.isFinished)
        #expect(h.router.reviewSelection == nil)
        #expect(h.router.momentsPath.isEmpty)
    }

    @Test func theSelectionFollowsRevalidation() async throws {
        let h = Harness()
        await h.launch()
        h.router.reviewSelection = momentID("b1")

        h.fake.remove(ids("b1")) // the moment's first photo is deleted elsewhere
        h.fake.emitSnapshot()
        await h.settle()

        #expect(h.router.reviewSelection == momentID("b2"))
    }

    @Test func nilOrTheCurrentMomentChangesNothing() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("a1"))
        let session = try #require(h.router.review)
        session.mode = .single
        session.singleIndex = 2

        h.router.reviewSelection = nil // a list leaving in a swap
        h.router.reviewSelection = momentID("a1") // a list appearing in a swap

        #expect(h.router.review === session)
        #expect(session.current?.id == momentID("a1"))
        #expect(session.singleIndex == 2)
        #expect(h.router.momentsPath == [.review])
    }

    @Test func anUnlistedSelectionDoesNothing() async {
        let h = Harness()
        await h.launch()

        h.router.reviewSelection = momentID("nope")

        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
    }

    @Test func clearingTheLastMomentEndsInTheFullWidthState() async throws {
        let h = Harness(records: TestLibrary.burst("s", count: 3, daysAgo: 1))
        await h.launch()
        #expect(h.library.showsMomentList)
        h.router.reviewSelection = momentID("s1")
        let session = try #require(h.router.review)

        session.toggle(id("s1"))
        #expect(await session.commit() == .committed(deleted: 2, freed: ByteEstimate(bytes: 0, isApproximate: true)))

        #expect(h.router.review == nil)
        #expect(h.router.momentsPath.isEmpty)
        #expect(h.router.reviewSelection == nil)
        #expect(!h.library.showsMomentList, "All clean takes the whole tab")
    }

    @Test func theKeptSelectionMapsOntoTheKeptPath() async {
        let h = Harness()
        await h.launch()
        #expect(h.router.keptSelection == nil)

        h.router.keptSelection = momentID("k1")
        #expect(h.router.keptPath == [.keptMoment(momentID("k1"))])

        h.router.keptSelection = momentID("k2")
        #expect(h.router.keptPath == [.keptMoment(momentID("k2"))])

        h.router.keptSelection = nil // a list leaving in a swap
        #expect(h.router.keptPath == [.keptMoment(momentID("k2"))])

        h.router.keptPath = [] // Back in the stack
        #expect(h.router.keptSelection == nil)

        h.router.keptPath.append(.keptMoment(momentID("k3"))) // a push in the stack
        #expect(h.router.keptSelection == momentID("k3"))
    }
}

/// ADAPTIVE §7, ⌘↑: Previous Moment goes to the moment listed just above.
@Suite("Router: Previous Moment")
struct AdaptiveRouterPreviousMomentTests {
    @Test func previousMomentIsTheOneListedAbove() async throws {
        let h = Harness()
        await h.launch()
        #expect(h.router.previousMoment == nil, "no review")

        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        #expect(h.router.previousMoment == nil, "the top of the list")
        session.toggle(id("a2"))
        session.mode = .single
        session.skip()
        session.toggle(id("b3"))
        #expect(h.router.previousMoment == momentID("a1"))

        h.router.reviewPreviousMoment()

        #expect(h.router.review === session)
        #expect(session.current?.id == momentID("a1"))
        #expect(session.position == 1)
        #expect(session.selection.kept == Set(ids("a2")), "with its remembered selection")
        #expect(session.mode == .single)
        #expect(h.router.reviewSelection == momentID("a1"))

        session.skip() // ⌘↓ goes back down
        #expect(session.current?.id == momentID("b1"))
        #expect(session.selection.kept == Set(ids("b3")))
    }

    @Test func previousMomentSkipsMomentsThatLeftTheList() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.keepAside()
        session.skip()
        #expect(session.current?.id == momentID("c1"))

        #expect(h.router.previousMoment == momentID("b1"))
        h.router.reviewPreviousMoment()
        #expect(session.current?.id == momentID("b1"))
        #expect(h.router.previousMoment == nil, "a was kept and left the list")
    }

    @Test func previousMomentAtTheTopDoesNothing() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.singleIndex = 2

        h.router.reviewPreviousMoment()

        #expect(session.current?.id == momentID("a1"))
        #expect(session.singleIndex == 2)
    }

    @Test func previousMomentFollowsTheListOrder() async throws {
        let records = TestLibrary.standard
        // b is the biggest moment, then a, then c.
        var sizes = TestLibrary.sizes(records)
        for record in records where record.id.rawValue.hasPrefix("b") { sizes[record.id] = 5_000_000 }
        let h = Harness(records: records, sizes: sizes)
        await h.launch()
        h.router.startReview(at: momentID("a1"))

        h.settings.grouping.order = .mostSpace // Sort in the Adjust popover beside the review
        await h.settle()

        #expect(h.anchors == ["b1", "a1", "c1"])
        #expect(h.router.previousMoment == momentID("b1"))
    }
}

/// ADAPTIVE §3.4: what a posture change, rotation or resize keeps. A container swap only
/// re-reads model state and re-writes what it read; none of that may change it.
@Suite("Router: container swaps")
struct AdaptiveContainerSwapTests {
    @Test func aSwapMidReviewKeepsEverything() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a1"))
        await session.commit()
        let toast = try #require(h.toasts.current)
        session.toggle(id("b2"))
        session.toggle(id("b4"))
        session.mode = .single
        session.singleIndex = 2
        h.router.sheet = .grouping // the Adjust popover beside the review

        // Stack → split: the sidebar list appears and asserts its selection.
        let selection = h.router.reviewSelection
        h.router.reviewSelection = selection
        // Split → stack: the NavigationStack appears with the path; the sidebar goes.
        let path = h.router.momentsPath
        h.router.momentsPath = path
        h.router.reviewSelection = nil

        #expect(h.router.review === session)
        #expect(session.isActive)
        #expect(session.current?.id == momentID("b1"))
        #expect(session.selection.kept == Set(ids("b2", "b4")))
        #expect(session.mode == .single)
        #expect(session.singleIndex == 2)
        #expect(session.summary.moments == 1)
        #expect(session.summary.photos == 2)
        #expect(h.toasts.current?.id == toast.id)
        #expect(h.router.sheet == .grouping)
        #expect(h.router.tab == .moments)
        #expect(h.router.momentsPath == [.review])
    }

    @Test func anInFlightCommitSurvivesASwap() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: nil)
        let session = try #require(h.router.review)
        session.toggle(id("a1"))
        h.fake.holdDeletes()

        let commit = Task { await session.commit() }
        #expect(await eventually { h.fake.heldDeleteCount == 1 })
        h.router.reviewSelection = momentID("a1")
        h.router.momentsPath = [.review]
        h.router.reviewSelection = nil
        h.fake.releaseDeletes()

        #expect(await commit.value == .committed(deleted: 2, freed: ByteEstimate(bytes: 0, isApproximate: true)))
        #expect(session.current?.id == momentID("b1"))
        #expect(session.summary.moments == 1)
        #expect(h.router.review === session)
    }

    @Test func theKeptMomentSurvivesASwap() async {
        let h = Harness()
        await h.launch()
        h.router.tab = .kept
        h.router.keptPath = [.keptMoment(momentID("k1"))]

        let selection = h.router.keptSelection
        h.router.keptSelection = selection // the sidebar appears
        let path = h.router.keptPath
        h.router.keptPath = path // the stack appears
        h.router.keptSelection = nil // the sidebar goes

        #expect(h.router.keptPath == [.keptMoment(momentID("k1"))])
        #expect(h.router.tab == .kept)
    }
}

/// ADAPTIVE §7: the state and actions the keyboard commands and the bottom bar use.
@Suite("ReviewSession: commands")
struct ReviewSessionCommandTests {
    @Test func theCurrentPhotoFollowsTheIndex() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)
        #expect(session.currentPhoto?.id == id("b1"))

        session.singleIndex = 2
        #expect(session.currentPhoto?.id == id("b3"))

        session.toggleCurrentPhoto() // Space
        #expect(session.selection.kept == Set(ids("b3")))
        session.toggleCurrentPhoto()
        #expect(session.selection.kept.isEmpty)
    }

    @Test func theIndexStaysInsideTheMoment() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("a1"))
        let session = try #require(h.router.review)

        session.singleIndex = 10
        #expect(session.singleIndex == 2)
        session.singleIndex -= 5
        #expect(session.singleIndex == 0)

        session.singleIndex = 2
        session.skip() // b has 4 photos; a new moment starts at its first photo
        #expect(session.singleIndex == 0)
        session.singleIndex += 1
        #expect(session.singleIndex == 1)
    }

    @Test func numberKeysToggleByPosition() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)

        session.togglePhoto(at: 0)
        session.togglePhoto(at: 3)
        session.togglePhoto(at: 8) // no 9th photo
        session.togglePhoto(at: -1)

        #expect(session.selection.kept == Set(ids("b1", "b4")))
    }

    @Test func showSingleOpensOneByOneAtThePhoto() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)

        session.showSingle(id("a1")) // not in this moment
        #expect(session.mode == .grid)

        session.showSingle(id("b3"))
        #expect(session.mode == .single)
        #expect(session.singleIndex == 2)
        #expect(session.currentPhoto?.id == id("b3"))
    }

    @Test func commandAvailabilityFollowsTheSelection() async throws {
        let h = Harness()
        await h.launch()
        h.router.startReview(at: momentID("b1"))
        let session = try #require(h.router.review)
        #expect(session.canMoveOn)
        #expect(!session.canCommit, "nothing kept yet")
        #expect(session.deleteCount == 0)

        session.toggle(id("b1"))
        #expect(session.canCommit)
        #expect(session.deleteCount == 3, "Delete 3 Photos")

        session.selectAll()
        #expect(session.canCommit, "Keep All & Next")
        #expect(session.deleteCount == 0)

        session.toggle(id("b2"))
        h.fake.holdDeletes()
        let commit = Task { await session.commit() }
        #expect(await eventually { h.fake.heldDeleteCount == 1 })
        #expect(!session.canMoveOn)
        #expect(!session.canCommit)
        h.fake.releaseDeletes()
        _ = await commit.value

        #expect(session.current?.id == momentID("c1"))
        session.skip()
        #expect(session.isFinished)
        #expect(!session.canMoveOn)
        #expect(!session.canCommit)
        #expect(session.currentPhoto == nil)
        #expect(session.deleteCount == 0)
    }
}

/// ADAPTIVE §3.2: a column container splits only while the Moments list is showing.
@Suite("LibraryModel: showsMomentList")
struct ShowsMomentListTests {
    @Test func theListShowsWithReadableAccessAReadyLibraryAndMoments() async {
        let h = Harness()
        #expect(!h.library.showsMomentList, "before launch")
        await h.launch()
        #expect(h.library.showsMomentList)

        let limited = Harness(access: .limited)
        await limited.launch()
        #expect(limited.library.showsMomentList)
    }

    @Test func noListWithoutAccess() async {
        let denied = Harness(access: .denied)
        await denied.launch()
        #expect(!denied.library.showsMomentList)

        let undetermined = Harness(access: .notDetermined)
        await undetermined.launch()
        #expect(!undetermined.library.showsMomentList)
    }

    @Test func noListWhileIndexingOrAfterAFailure() async {
        let indexing = Harness()
        indexing.fake.setInitialEvents([.progress(done: 0, total: 0)])
        await indexing.launch()
        #expect(indexing.library.phase == .indexing(done: 0, total: 0))
        #expect(!indexing.library.showsMomentList)

        indexing.fake.emitSnapshot()
        await indexing.settle()
        #expect(indexing.library.showsMomentList)

        let failed = Harness()
        failed.fake.setInitialEvents([.failed(.unavailable)])
        await failed.launch()
        #expect(!failed.library.showsMomentList)
    }

    @Test func noListWhenEverythingIsClean() async {
        let h = Harness(records: [])
        await h.launch()
        #expect(h.library.phase == .ready)
        #expect(!h.library.showsMomentList)
    }
}
