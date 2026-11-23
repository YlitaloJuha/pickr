import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

@Suite("LibraryModel: access × phase")
struct LibraryAccessPhaseTests {
    @Test(arguments: [LibraryAccess.notDetermined, .denied])
    func withoutAccessNothingIsIndexed(access: LibraryAccess) async {
        let h = Harness(access: access)
        await h.launch()

        #expect(h.library.access == access)
        #expect(h.library.phase == .idle)
        #expect(!h.library.isRefreshing)
        #expect(h.library.moments == .empty)
        #expect(h.fake.calls.indexEvents == 0)
    }

    /// The [ARCH A1] regression: limited access stays limited after the scan completes.
    @Test(arguments: [LibraryAccess.full, .limited])
    func withAccessTheLibraryIsGrouped(access: LibraryAccess) async {
        let h = Harness(access: access)
        await h.launch()

        #expect(h.library.access == access)
        #expect(h.library.phase == .ready)
        #expect(!h.library.isRefreshing)
        #expect(h.anchors == ["a1", "b1", "c1"])
        #expect(h.library.moments.photoCount == 9)
        #expect(h.library.index.count == 9)
    }

    @Test func limitedStaysLimitedThroughRefreshesAndSnapshots() async {
        let h = Harness(access: .limited)
        await h.launch()
        await h.library.refresh()
        h.fake.emitSnapshot(isComplete: false)
        h.fake.emitSnapshot()
        await h.settle()

        #expect(h.library.access == .limited)
        #expect(h.library.phase == .ready)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func progressWithoutDataShowsIndexing() async {
        let h = Harness()
        h.fake.setInitialEvents([.progress(done: 4_200, total: 12_000)])
        await h.launch()

        #expect(h.library.phase == .indexing(done: 4_200, total: 12_000))
        #expect(!h.library.isRefreshing)

        h.fake.emitSnapshot()
        await h.settle()
        #expect(h.library.phase == .ready)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func indexingStartsAtZeroBeforeAnyEvent() async {
        let h = Harness()
        h.fake.setInitialEvents([])
        await h.launch()

        #expect(h.library.phase == .indexing(done: 0, total: 0))
    }

    @Test func cachedDataShowsAtOnceAndUpdatesInPlace() async {
        let h = Harness()
        let cached = TestLibrary.burst("a", count: 3, daysAgo: 1)
        h.fake.setInitialEvents([
            .snapshot(IndexSnapshot(records: cached, isComplete: false)),
            .progress(done: 3, total: 9),
        ])
        await h.launch()

        #expect(h.library.phase == .ready)
        #expect(h.library.isRefreshing, "a refresh over cached data reads as Updating…")
        #expect(h.anchors == ["a1"])

        h.fake.emitSnapshot()
        await h.settle()
        #expect(h.library.phase == .ready)
        #expect(!h.library.isRefreshing)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func failureWithoutDataIsAFailedPhase() async {
        let h = Harness()
        h.fake.setInitialEvents([.failed(.unavailable)])
        await h.launch()

        #expect(h.library.phase == .failed(.unavailable))
        #expect(h.library.access == .full)

        h.fake.emitSnapshot()
        await h.settle()
        #expect(h.library.phase == .ready)
    }

    @Test func failureWithDataKeepsTheData() async {
        let h = Harness()
        await h.launch()
        h.fake.emit(.failed(.unavailable))
        await h.settle()

        #expect(h.library.phase == .ready)
        #expect(!h.library.isRefreshing)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func requestAccessStartsIndexingWhenGranted() async {
        let h = Harness(access: .notDetermined)
        await h.launch()
        h.fake.setAccessAfterRequest(.limited)

        await h.library.requestAccess()
        await h.settle()

        #expect(h.fake.calls.requestAccess == 1)
        #expect(h.library.access == .limited)
        #expect(h.library.phase == .ready)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func requestAccessDeniedStaysIdle() async {
        let h = Harness(access: .notDetermined)
        await h.launch()
        h.fake.setAccessAfterRequest(.denied)

        await h.library.requestAccess()

        #expect(h.library.access == .denied)
        #expect(h.library.phase == .idle)
        #expect(h.fake.calls.indexEvents == 0)
    }

    @Test func refreshPicksUpAccessGrantedInSettings() async {
        let h = Harness(access: .denied)
        await h.launch()
        h.fake.setAccess(.full)

        await h.library.refresh()
        await h.settle()

        #expect(h.library.access == .full)
        #expect(h.library.phase == .ready)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func withdrawnAccessForgetsTheLibrary() async {
        let h = Harness()
        await h.launch()
        h.fake.setAccess(.denied)

        await h.library.refresh()
        await h.library.settle()

        #expect(h.library.access == .denied)
        #expect(h.library.phase == .idle)
        #expect(h.library.index.isEmpty)
        #expect(h.library.moments == .empty)
    }

    @Test func startIsIdempotent() async {
        let h = Harness()
        await h.launch()
        await h.library.start()
        await h.services.launch()

        #expect(h.fake.calls.indexEvents == 1)
        #expect(h.fake.calls.access == 1)
    }
}

@Suite("LibraryModel: regrouping")
struct LibraryRegroupTests {
    /// Grouping is pure and in memory (C6): no PhotoKit call, whatever changes.
    @Test func groupingChangesRegroupWithoutAnyClientCall() async {
        let h = Harness(
            records: Fixtures.testPhotos,
            sizes: Fixtures.testPhotoSizes,
            now: Fixtures.testPhotosStart.addingTimeInterval(86_400)
        )
        await h.launch()
        #expect(h.library.moments.moments.count == 7)
        #expect(h.library.moments.moments.map(\.count) == [3, 4, 8, 10, 7, 5, 3])
        let callsAfterLaunch = h.fake.calls.total

        let expectations: [(seconds: Int, moments: Int)] = [(10, 10), (30, 9), (180, 3), (240, 1), (60, 7)]
        for (seconds, count) in expectations {
            h.settings.grouping.window = TimeWindow(seconds: seconds, isCustom: seconds == 240)
            await h.library.settle()
            #expect(h.library.moments.moments.count == count, "window \(seconds) s")
        }
        h.settings.grouping.range = ScanRange(preset: .all)
        await h.library.settle()
        h.settings.grouping.order = .mostSpace
        await h.library.settle()
        #expect(h.library.moments.moments.count == 7)

        #expect(h.fake.calls.total == callsAfterLaunch)
    }

    @Test func rangeFiltersTheIndexInMemory() async {
        let records = TestLibrary.burst("old", count: 2, daysAgo: 20) + TestLibrary.burst("new", count: 2, daysAgo: 2)
        let h = Harness(records: records)
        await h.launch()
        #expect(h.anchors == ["new1", "old1"])

        h.settings.grouping.range = ScanRange(preset: .d7)
        await h.library.settle()
        #expect(h.anchors == ["new1"])

        let customStart = TestLibrary.now.addingTimeInterval(-21 * 86_400)
        let customEnd = TestLibrary.now.addingTimeInterval(-19 * 86_400)
        h.settings.grouping.range = ScanRange(preset: .custom, custom: CustomRange(customStart, customEnd))
        await h.library.settle()
        #expect(h.anchors == ["old1"])
    }

    @Test func keptPhotosNeverResurfaceWhateverTheWindow() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try #require(h.moment("b1")))
        await h.settle()

        for window in [TimeWindow.custom(minutes: 120), TimeWindow(seconds: 10, isCustom: false)] {
            h.settings.grouping.window = window
            h.settings.grouping.range = ScanRange(preset: .all)
            await h.library.settle()
            let listed = Set(h.library.moments.moments.flatMap(\.photoIDs))
            #expect(listed.isDisjoint(with: TestLibrary.ids("b1", "b2", "b3", "b4")))
        }
    }

    /// The generation guard: a result computed from old inputs is never applied.
    @Test func staleRegroupResultsAreDropped() async {
        // d1…d3 are 20 s apart: one moment at 3 min, none at 10 s.
        let records = TestLibrary.standard + TestLibrary.burst("d", count: 3, daysAgo: 5, spacing: 20)
        let h = Harness(records: records)
        await h.launch()
        #expect(h.anchors == ["a1", "b1", "c1", "d1"])

        let gate = Gate()
        let computations = Counter()
        h.library.computeMoments = { input in
            if computations.next() == 1 { await gate.wait() }
            return await LibraryModel.computeMoments(input)
        }
        let applied = h.library.appliedRegroups

        h.settings.grouping.window = TimeWindow(seconds: 10, isCustom: false) // held at the gate
        #expect(await eventually { gate.waiterCount == 1 })
        h.settings.grouping.window = TimeWindow(seconds: 180, isCustom: false) // runs at once
        #expect(await eventually { h.library.appliedRegroups == applied + 1 })
        #expect(h.anchors == ["a1", "b1", "c1", "d1"])

        let dropped = h.library.droppedRegroups
        gate.open()
        #expect(await eventually { h.library.droppedRegroups == dropped + 1 })
        await h.library.settle()
        #expect(computations.current == 2)
        #expect(h.library.appliedRegroups == applied + 1, "the 10 s result was computed but dropped")
        #expect(h.anchors == ["a1", "b1", "c1", "d1"])
        #expect(h.settings.grouping.window.seconds == 180)
    }

    @Test func changesInOneTurnShareOneComputation() async {
        let h = Harness()
        await h.launch()
        let computations = Counter()
        h.library.computeMoments = { input in
            _ = computations.next()
            return await LibraryModel.computeMoments(input)
        }

        h.settings.grouping.window = TimeWindow(seconds: 30, isCustom: false)
        h.settings.grouping.order = .mostSpace
        h.settings.grouping.range = ScanRange(preset: .all)
        await h.library.settle()

        #expect(computations.current == 1)
    }

    @Test func photoCountComesFromTheIndex() async {
        let records = TestLibrary.burst("a", count: 3, daysAgo: 1)
            + TestLibrary.burst("m", count: 4, daysAgo: 10)
            + TestLibrary.burst("y", count: 5, daysAgo: 400)
        let h = Harness(records: records)
        await h.launch()
        let calls = h.fake.calls.total

        #expect(h.library.photoCount(in: ScanRange(preset: .d7)) == 3)
        #expect(h.library.photoCount(in: ScanRange(preset: .d30)) == 7)
        #expect(h.library.photoCount(in: ScanRange(preset: .all)) == 12)
        let start = TestLibrary.now.addingTimeInterval(-11 * 86_400)
        let end = TestLibrary.now.addingTimeInterval(-9 * 86_400)
        #expect(h.library.photoCount(in: ScanRange(preset: .custom, custom: CustomRange(end, start))) == 4)
        #expect(h.library.photoCount(in: ScanRange(preset: .custom)) == 7, "custom without dates counts as 30 days")
        #expect(h.fake.calls.total == calls)
    }

    @Test func momentLookupFollowsMembers() async throws {
        let h = Harness()
        await h.launch()
        let b = try h.requireMoment("b1")

        #expect(h.library.moment(b.id) == b)
        #expect(h.library.moment(containingAnyOf: Set(TestLibrary.ids("b3", "zzz"))) == b)
        #expect(h.library.moment(containingAnyOf: Set(TestLibrary.ids("a2", "b2", "b3")))?.id == b.id)
        #expect(h.library.moment(containingAnyOf: Set(TestLibrary.ids("zzz"))) == nil)
        #expect(h.library.moment(MomentID(anchor: TestLibrary.id("b2"))) == nil)
    }

    @Test func confirmedDeletionsLeaveTheIndexAtOnce() async {
        let h = Harness()
        await h.launch()

        h.fake.emit(.confirmedDeleted(Set(TestLibrary.ids("c1"))))
        await h.settle()

        #expect(!h.library.index.contains { $0.id == TestLibrary.id("c1") })
        #expect(h.anchors == ["a1", "b1"])
    }
}

@Suite("LibraryModel: refresh and sizes")
struct LibraryRefreshAndSizeTests {
    @Test func concurrentRefreshesShareOneClientRefresh() async {
        let h = Harness()
        await h.launch()
        h.fake.holdRefreshes()

        async let first: Void = h.library.refresh()
        async let second: Void = h.library.refresh()
        #expect(await eventually { h.fake.heldRefreshCount == 1 })
        #expect(h.library.isRefreshing)
        h.fake.releaseRefreshes()
        _ = await (first, second)

        #expect(h.fake.calls.refresh == 1)
        #expect(!h.library.isRefreshing)

        await h.library.refresh()
        #expect(h.fake.calls.refresh == 2, "a refresh after the first one finished runs again")
    }

    @Test func sizesAreRequestedOnlyForPhotosInMomentsInBatchesOf200() async {
        // 250 photos in moments (newest first: n, then o), plus singletons far apart.
        let newer = TestLibrary.burst("n", count: 150, daysAgo: 1, spacing: 1)
        let older = TestLibrary.burst("o", count: 100, daysAgo: 2, spacing: 1)
        let singles = (1...5).flatMap { TestLibrary.burst("s\($0)-", count: 1, daysAgo: Double(3 + $0)) }
        let records = newer + older + singles
        let h = Harness(records: records, sizes: TestLibrary.sizes(records))
        await h.launch()

        let batches = h.fake.calls.resolveSizes
        #expect(batches.map(\.count) == [200, 50])
        #expect(batches.first?.first == TestLibrary.id("n1"), "newest moment first")
        let requested = Set(batches.joined())
        #expect(requested == Set((newer + older).map(\.id)))
        #expect(h.library.sizes.count == 250)
        #expect(h.library.moments.savings == ByteEstimate(bytes: 248_000_000, isApproximate: false))
    }

    @Test func unknownSizesAreAskedForOnce() async {
        let h = Harness(sizes: [:])
        await h.launch()
        h.settings.grouping.order = .mostSpace
        await h.settle()
        h.fake.emitSnapshot()
        await h.settle()

        #expect(h.fake.calls.resolveSizes.count == 1)
        #expect(h.library.moments.savings == ByteEstimate(bytes: 0, isApproximate: true))
    }

    @Test func aModifiedPhotoIsSizedAgain() async {
        let records = TestLibrary.standard
        let h = Harness(records: records, sizes: TestLibrary.sizes(records))
        await h.launch()
        #expect(h.fake.calls.resolveSizes.count == 1)

        var edited = records[0]
        edited.modified = TestLibrary.now
        h.fake.upsert([edited])
        h.fake.setSizes([edited.id: 5_000_000])
        h.fake.emitSnapshot()
        await h.settle()

        #expect(h.fake.calls.resolveSizes.last == [edited.id])
        #expect(h.library.sizes[edited.id] == 5_000_000)
    }

    @Test func mostSpaceOrderFollowsSizesAsTheyArrive() async {
        // c is listed last by date but frees the most.
        let records = TestLibrary.standard
        var sizes = TestLibrary.sizes(records, bytes: 1_000)
        sizes[TestLibrary.id("c1")] = 9_000_000
        sizes[TestLibrary.id("c2")] = 9_000_000
        let h = Harness(records: records, sizes: sizes)
        await h.launch()
        #expect(h.anchors == ["a1", "b1", "c1"])

        h.settings.grouping.order = .mostSpace
        await h.library.settle()
        #expect(h.anchors == ["c1", "b1", "a1"])
    }
}
