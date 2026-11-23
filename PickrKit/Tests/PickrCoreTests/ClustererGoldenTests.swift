import Foundation
import Testing
@testable import PickrCore

/// The 12 v1 `ClusterServiceTests` (pickr-ios/PickrTests/ClusterServiceTests.swift), ported in
/// meaning. They lock the grouping DNA (§1.5): inclusive, chained gaps; moments of at least
/// two; ascending photos; newest moment first; keep-one savings.
@Suite("Clusterer golden cases (v1)")
struct ClustererGoldenTests {
    private let s10 = TimeWindow(seconds: 10, isCustom: false)
    private let s30 = TimeWindow(seconds: 30, isCustom: false)

    /// v1 `photo(_:id:bytes:)`: a record plus its size (v1 defaulted every size to 1 MB).
    private func photos(_ specs: [(TimeInterval, Int64)]) -> (records: [AssetRecord], sizes: SizeTable) {
        let records = specs.map { Make.record($0.0) }
        let sizes = Dictionary(uniqueKeysWithValues: zip(records.map(\.id), specs.map(\.1)))
        return (records, sizes)
    }

    private func photos(_ offsets: [TimeInterval]) -> [AssetRecord] {
        offsets.map { Make.record($0) }
    }

    // 1. testEmptyInputReturnsNoClusters
    @Test func emptyInputGivesNoMoments() {
        #expect(Clusterer.moments(from: [], window: s30).isEmpty)
    }

    // 2. testSingletonPhotosAreDropped
    @Test func singletonPhotosAreDropped() {
        #expect(Clusterer.moments(from: photos([0, 120, 500]), window: s30).isEmpty)
    }

    // 3. testTwoPhotosWithinWindowFormOneCluster
    @Test func twoPhotosWithinTheWindowFormOneMoment() {
        let moments = Clusterer.moments(from: photos([0, 10]), window: s30)
        #expect(moments.count == 1)
        #expect(moments.first?.count == 2)
    }

    // 4. testGapExactlyAtWindowBoundaryJoinsCluster: `<=`, so a 30 s gap joins at 30 s.
    @Test func gapExactlyAtTheWindowJoins() {
        let moments = Clusterer.moments(from: photos([0, 30]), window: s30)
        #expect(moments.count == 1)
        #expect(moments.first?.count == 2)
    }

    // 5. testGapJustOverWindowSplitsCluster
    @Test func gapOverTheWindowSplits() {
        let moments = Clusterer.moments(from: photos([0, 5, 40, 45]), window: s30)
        #expect(moments.count == 2)
        #expect(moments.map(\.count) == [2, 2])
    }

    // 6. testUnsortedInputIsHandled: sorted 0, 5, 10, 60, 65; the 10 → 60 gap splits.
    @Test func unsortedInputIsHandled() {
        let moments = Clusterer.moments(from: photos([60, 0, 10, 65, 5]), window: s30)
        #expect(moments.count == 2)
        for moment in moments {
            let dates = moment.photos.map(\.created)
            #expect(dates == dates.sorted())
        }
        #expect(moments.map(\.photoIDs) == [Make.ids("p-60", "p-65"), Make.ids("p-0", "p-5", "p-10")])
    }

    // 7. testClustersReturnedNewestFirst
    @Test func momentsAreNewestFirst() {
        let moments = Clusterer.moments(from: photos([0, 5, 500, 510]), window: s30)
        #expect(moments.count == 2)
        #expect(moments[0].end > moments[1].end)
        #expect(moments[0].id == MomentID(anchor: PhotoID("p-500")))
    }

    // 8. testLargeClusterStaysIntact: 10 photos 5 s apart, window 30 s.
    @Test func largeMomentStaysIntact() {
        let moments = Clusterer.moments(from: photos((0..<10).map { TimeInterval($0) * 5 }), window: s30)
        #expect(moments.count == 1)
        #expect(moments.first?.count == 10)
    }

    // 9. testSingletonAtEndIsDroppedButPriorClusterSurvives
    @Test func trailingSingletonIsDroppedAndTheMomentBeforeItSurvives() {
        let moments = Clusterer.moments(from: photos([0, 10, 500]), window: s30)
        #expect(moments.count == 1)
        #expect(moments.first?.photoIDs == Make.ids("p-0", "p-10"))
    }

    // 10. testTotalBytesMatchesSum
    @Test func totalBytesMatchSum() throws {
        let (records, sizes) = photos([(0, 2_000_000), (10, 3_000_000)])
        let moment = try #require(Clusterer.moments(from: records, window: s30).first)
        #expect(Savings.total(of: moment.photoIDs, sizes: sizes) == ByteEstimate(bytes: 5_000_000, isApproximate: false))
    }

    // 11. testReclaimableIfKeepOneExcludesLargest: 2 + 5 + 1 MB, keep the 5 MB one → 3 MB.
    @Test func keepOneEstimateExcludesTheLargest() throws {
        let (records, sizes) = photos([(0, 2_000_000), (5, 5_000_000), (10, 1_000_000)])
        let moment = try #require(Clusterer.moments(from: records, window: s30).first)
        #expect(Savings.keepOneEstimate(for: moment, sizes: sizes) == ByteEstimate(bytes: 3_000_000, isApproximate: false))
    }

    // 12. testDifferentWindowsProduceDifferentGrouping. v1 used photos at 0/8/20 s with 5/10/30 s
    // windows. v2 windows start at 10 s, so every time is doubled: 0/16/40 s with 10/20/60 s.
    @Test func differentWindowsGroupDifferently() {
        let records = photos([0, 16, 40])
        // 10 s: gaps of 16 s and 24 s both split → nothing of size 2 or more.
        #expect(Clusterer.moments(from: records, window: s10).isEmpty)
        // 20 s: 0 and 16 join, 16 → 40 splits → one moment of 2.
        let s20 = Clusterer.moments(from: records, window: TimeWindow(seconds: 20, isCustom: true))
        #expect(s20.map(\.count) == [2])
        // 60 s: all three.
        let s60 = Clusterer.moments(from: records, window: .default)
        #expect(s60.map(\.count) == [3])
    }

    // The v1 case above used a 5 s custom window, which v2 no longer allows: it clamps to 10 s.
    @Test func windowsBelowTenSecondsGroupLikeTenSeconds() {
        let records = photos([0, 8, 20])
        let clamped = Clusterer.moments(from: records, window: TimeWindow(seconds: 5, isCustom: true))
        #expect(clamped == Clusterer.moments(from: records, window: s10))
        #expect(clamped.map(\.count) == [2])
    }
}
