import Foundation
import Testing
import PickrTestSupport
@testable import PickrCore

@Suite("IndexMath")
struct IndexMathTests {
    private let index = [0, 10, 20, 30].map { Make.record($0) }

    @Test func emptyDeltaChangesNothing() {
        #expect(IndexMath.apply(IndexDelta(), to: index) == index)
        #expect(IndexMath.apply(IndexDelta(), to: []).isEmpty)
    }

    @Test func insertsLandInCaptureOrder() {
        let delta = IndexDelta(upserted: [Make.record(15), Make.record(-5), Make.record(99)])
        let result = IndexMath.apply(delta, to: index)
        #expect(result.map(\.id) == Make.ids("p--5", "p-0", "p-10", "p-15", "p-20", "p-30", "p-99"))
    }

    @Test func deletesRemoveRecords() {
        let result = IndexMath.apply(IndexDelta(deleted: Set(Make.ids("p-10", "p-30", "unknown"))), to: index)
        #expect(result.map(\.id) == Make.ids("p-0", "p-20"))
    }

    @Test func anUpdateReplacesTheRecordInPlace() {
        var favorite = Make.record(10)
        favorite.isFavorite = true
        let result = IndexMath.apply(IndexDelta(upserted: [favorite]), to: index)
        #expect(result.count == 4)
        #expect(result[1] == favorite)
    }

    /// An edited capture date moves the photo to its new place without leaving a copy behind.
    @Test func anUpdateWithANewCaptureDateMovesTheRecord() {
        var moved = Make.record(10)
        moved.created = Make.epoch.addingTimeInterval(25)
        let result = IndexMath.apply(IndexDelta(upserted: [moved]), to: index)
        #expect(result.map(\.id) == Make.ids("p-0", "p-20", "p-10", "p-30"))
        #expect(result.filter { $0.id == PhotoID("p-10") }.count == 1)
    }

    @Test func theLaterOfTwoUpsertsWins() {
        var first = Make.record(40, id: "new")
        first.rating = 1
        var second = first
        second.rating = 5
        let result = IndexMath.apply(IndexDelta(upserted: [first, second]), to: index)
        #expect(result.filter { $0.id == PhotoID("new") } == [second])
    }

    @Test func deletionWinsOverAnUpsertOfTheSameID() {
        let delta = IndexDelta(upserted: [Make.record(10), Make.record(50, id: "ghost")], deleted: Set(Make.ids("p-10", "ghost")))
        #expect(IndexMath.apply(delta, to: index).map(\.id) == Make.ids("p-0", "p-20", "p-30"))
    }

    @Test func equalCaptureTimesAreOrderedByID() {
        let base = [Make.record(0, id: "b"), Make.record(0, id: "d")]
        let result = IndexMath.apply(IndexDelta(upserted: [Make.record(0, id: "c"), Make.record(0, id: "a")]), to: base)
        #expect(result.map(\.id) == Make.ids("a", "b", "c", "d"))
    }

    @Test func anUnsortedIndexComesBackSorted() {
        let shuffled = [Make.record(30), Make.record(0), Make.record(20)]
        #expect(IndexMath.apply(IndexDelta(), to: shuffled).map(\.id) == Make.ids("p-0", "p-20", "p-30"))
        #expect(IndexMath.apply(IndexDelta(upserted: [Make.record(10)]), to: shuffled).map(\.id)
            == Make.ids("p-0", "p-10", "p-20", "p-30"))
    }

    /// Random deltas against a reference implementation: drop deleted and replaced IDs,
    /// add the upserts, sort.
    @Test(arguments: Array(1...10) as [UInt64])
    func matchesTheReferenceForRandomDeltas(seed: UInt64) {
        var generator = Fixtures.SeededGenerator(seed: seed)
        let index = Fixtures.syntheticLibrary(count: 500, seed: seed)
        let deleted = Set(index.shuffled(using: &generator).prefix(40).map(\.id))
        let updated = index.shuffled(using: &generator).prefix(40).map { record -> AssetRecord in
            var copy = record
            copy.created = record.created.addingTimeInterval(Double(Int.random(in: -3600...3600, using: &generator)))
            copy.isFavorite.toggle()
            return copy
        }
        let inserted = Fixtures.syntheticLibrary(count: 30, seed: seed &+ 1000).map {
            AssetRecord(id: PhotoID("new/\($0.id.rawValue)"), created: $0.created.addingTimeInterval(1800))
        }
        let delta = IndexDelta(upserted: updated + inserted, deleted: deleted)

        var reference = index.filter { record in !deleted.contains(record.id) && !updated.contains { $0.id == record.id } }
        reference += (updated + inserted).filter { !deleted.contains($0.id) }
        reference.sort(by: AssetRecord.inCaptureOrder)

        let result = IndexMath.apply(delta, to: index)
        #expect(result == reference)
        #expect(Set(result.map(\.id)).count == result.count)
    }
}
