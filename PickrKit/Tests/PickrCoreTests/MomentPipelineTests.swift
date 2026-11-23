import Foundation
import Testing
import PickrTestSupport
@testable import PickrCore

@Suite("MomentPipeline")
struct MomentPipelineTests {
    private let utc = Make.calendar("UTC")
    private let all = ScanRange(preset: .all)

    private func build(
        _ index: [AssetRecord],
        window: TimeWindow = .default,
        range: ScanRange = ScanRange(preset: .all),
        order: MomentOrder = .newest,
        kept: Set<PhotoID> = [],
        sizes: SizeTable = [:],
        now: Date = Make.epoch
    ) -> MomentList {
        MomentPipeline.build(
            index: index,
            grouping: GroupingSettings(window: window, range: range, order: order),
            kept: kept,
            sizes: sizes,
            now: now,
            calendar: utc
        )
    }

    @Test func emptyIndexGivesTheEmptyList() {
        #expect(build([]) == .empty)
        #expect(build([Make.record(0)]) == .empty)
    }

    @Test func newestOrderIsTheClustererOrder() {
        let index = Fixtures.syntheticLibrary(count: 400, seed: 7)
        let list = build(index)
        #expect(list.moments == Clusterer.moments(from: index, window: .default))
        #expect(list.photoCount == list.moments.reduce(0) { $0 + $1.count })
    }

    @Test func rangeKeepsOnlyPhotosInsideIt() {
        let day: TimeInterval = 86_400
        let now = Make.epoch.addingTimeInterval(40 * day)
        // Two photos 31 days back (outside 30d), two 29 days back, two today.
        let index = [9 * day, 9 * day + 5, 11 * day, 11 * day + 5, 40 * day - 10, 40 * day - 5].map { Make.record($0) }
        let list = build(index, range: .default, now: now)
        #expect(list.moments.map(\.count) == [2, 2])
        #expect(list.moments.last?.id.anchor == PhotoID("p-\(Int(11 * day))"))
        #expect(build(index, range: all, now: now).moments.count == 3)
    }

    /// `DateInterval.contains` includes both ends: a photo taken exactly 30 days ago, or
    /// exactly now, is in range.
    @Test func rangeEndsAreInclusive() {
        let now = Make.epoch.addingTimeInterval(30 * 86_400)
        let index = [Make.record(0, id: "start"), Make.record(1, id: "inside"), Make.record(30 * 86_400, id: "now"),
                     Make.record(30 * 86_400 - 1, id: "late")]
        let list = build(index, range: .default, now: now)
        #expect(Set(list.moments.flatMap(\.photoIDs)) == Set(Make.ids("start", "inside", "now", "late")))
    }

    /// Kept photos leave the index before grouping, so they can't bridge two moments.
    @Test func keptPhotosAreRemovedBeforeGrouping() {
        let index = [0, 50, 100].map { Make.record($0) }
        #expect(build(index).moments.map(\.count) == [3])
        #expect(build(index, kept: [PhotoID("p-50")]).moments.isEmpty)
        #expect(build(index, kept: [PhotoID("p-100")]).moments.map(\.photoIDs) == [Make.ids("p-0", "p-50")])
    }

    @Test func keptPhotosNeverResurfaceInAnyWindowOrRange() {
        let index = Fixtures.testPhotos
        let kept = Set(index.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element.id))
        for window in TimeWindow.presets + [.custom(minutes: 120)] {
            for preset in ScanRangePreset.allCases {
                let list = build(index, window: window, range: ScanRange(preset: preset), kept: kept,
                                 now: Fixtures.testPhotosStart.addingTimeInterval(86_400))
                #expect(kept.isDisjoint(with: list.moments.flatMap(\.photoIDs)))
            }
        }
    }

    @Test func savingsSumTheKeepOneEstimates() {
        let index = [0, 5, 500, 505, 510].map { Make.record($0) }
        let sizes: SizeTable = [PhotoID("p-0"): 10, PhotoID("p-5"): 30, PhotoID("p-500"): 1, PhotoID("p-505"): 2, PhotoID("p-510"): 4]
        let list = build(index, sizes: sizes)
        #expect(list.savings == ByteEstimate(bytes: 10 + 3, isApproximate: false))
        #expect(list.photoCount == 5)

        var partial = sizes
        partial[PhotoID("p-510")] = nil
        #expect(build(index, sizes: partial).savings == ByteEstimate(bytes: 10 + 1, isApproximate: true))
    }

    @Test func mostSpaceOrdersBySavingsWithUnknownLast() {
        // Five moments, oldest first: A..E.
        let index = [
            Make.record(0, id: "a1"), Make.record(1, id: "a2"),
            Make.record(1000, id: "b1"), Make.record(1001, id: "b2"),
            Make.record(2000, id: "c1"), Make.record(2001, id: "c2"), Make.record(2002, id: "c3"),
            Make.record(3000, id: "d1"), Make.record(3001, id: "d2"),
            Make.record(4000, id: "e1"), Make.record(4001, id: "e2"),
        ]
        let sizes: SizeTable = [
            PhotoID("a1"): 100, PhotoID("a2"): 100,           // A: 100, exact
            PhotoID("b1"): 900,                                // B: unknown (only one size known)
            PhotoID("c1"): 500, PhotoID("c2"): 400,            // C: 400, approximate (c3 unknown)
            PhotoID("d1"): 100, PhotoID("d2"): 300,            // D: 100, exact (ties with A)
            // E: nothing known
        ]
        let list = build(index, order: .mostSpace, sizes: sizes)
        // C has the most known space; D and A tie at 100 and keep newest first; then the
        // unknowns in newest-first order: E, B.
        #expect(list.moments.map(\.id.anchor) == Make.ids("c1", "d1", "a1", "e1", "b1"))
        #expect(list.savings == ByteEstimate(bytes: 600, isApproximate: true))
        #expect(Set(list.moments) == Set(build(index, sizes: sizes).moments))
    }

    @Test func mostSpaceWithNoSizesKeepsNewestFirst() {
        let index = Fixtures.syntheticLibrary(count: 300, seed: 3)
        #expect(build(index, order: .mostSpace).moments == build(index).moments)
    }

    @Test func groupingChangesNeedOnlyTheIndex() {
        let index = Fixtures.testPhotos
        let counts = [10, 30, 60, 180, 240].map {
            build(index, window: TimeWindow(seconds: $0, isCustom: false), now: Fixtures.testPhotosStart).moments.count
        }
        #expect(counts == [10, 9, 7, 3, 1])
    }
}
