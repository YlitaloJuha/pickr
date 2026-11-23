import Foundation
import Testing
import PickrTestSupport
@testable import PickrCore

/// Invariants of `Clusterer.moments` over deterministic random libraries (§4.8).
@Suite("Clusterer properties")
struct ClustererPropertyTests {
    static let seeds: [UInt64] = Array(1...12)
    static let windows: [TimeWindow] = TimeWindow.presets + [
        TimeWindow(seconds: 45, isCustom: true),
        .custom(minutes: 20),
        .custom(minutes: 120),
    ]

    private func library(_ seed: UInt64) -> [AssetRecord] {
        Fixtures.syntheticLibrary(count: 600, seed: seed)
    }

    @Test(arguments: seeds, windows)
    func shufflingTheInputDoesNotChangeTheOutput(seed: UInt64, window: TimeWindow) {
        let records = library(seed)
        var generator = Fixtures.SeededGenerator(seed: seed &* 31)
        let shuffled = records.shuffled(using: &generator)
        #expect(Clusterer.moments(from: shuffled, window: window) == Clusterer.moments(from: records, window: window))
        #expect(Clusterer.moments(from: records.reversed(), window: window) == Clusterer.moments(from: records, window: window))
    }

    @Test(arguments: seeds, windows)
    func everyGapInsideAMomentIsWithinTheWindow(seed: UInt64, window: TimeWindow) {
        for moment in Clusterer.moments(from: library(seed), window: window) {
            #expect(moment.count >= 2)
            for (previous, next) in zip(moment.photos, moment.photos.dropFirst()) {
                #expect(!AssetRecord.inCaptureOrder(next, previous), "photos stay in capture order")
                #expect(next.created.timeIntervalSince(previous.created) <= window.interval)
            }
        }
    }

    @Test(arguments: seeds, windows)
    func adjacentMomentsAreMoreThanTheWindowApart(seed: UInt64, window: TimeWindow) {
        let moments = Clusterer.moments(from: library(seed), window: window)
        for (newer, older) in zip(moments, moments.dropFirst()) {
            #expect(newer.end > older.end, "newest first")
            #expect(newer.start.timeIntervalSince(older.end) > window.interval)
        }
    }

    @Test(arguments: seeds, windows)
    func photosOutsideMomentsAreIsolated(seed: UInt64, window: TimeWindow) {
        let records = library(seed)
        let grouped = Set(Clusterer.moments(from: records, window: window).flatMap(\.photoIDs))
        for (index, record) in records.enumerated() where !grouped.contains(record.id) {
            if index > 0 {
                #expect(record.created.timeIntervalSince(records[index - 1].created) > window.interval)
            }
            if index < records.count - 1 {
                #expect(records[index + 1].created.timeIntervalSince(record.created) > window.interval)
            }
        }
    }

    @Test(arguments: seeds, windows)
    func minimumCountOnePartitionsTheInput(seed: UInt64, window: TimeWindow) {
        let records = library(seed)
        let moments = Clusterer.moments(from: records, window: window, minimumCount: 1)
        let ids = moments.flatMap(\.photoIDs)
        #expect(ids.count == records.count)
        #expect(Set(ids) == Set(records.map(\.id)))
        let pairs = Clusterer.moments(from: records, window: window)
        #expect(pairs == moments.filter { $0.count >= 2 })
    }

    @Test(arguments: seeds, windows)
    func reclusteringAMomentReturnsItUnchanged(seed: UInt64, window: TimeWindow) {
        var generator = Fixtures.SeededGenerator(seed: seed)
        for moment in Clusterer.moments(from: library(seed), window: window) {
            #expect(Clusterer.moments(from: moment.photos, window: window) == [moment])
            #expect(Clusterer.moments(from: moment.photos.shuffled(using: &generator), window: window) == [moment])
        }
    }

    /// Photos added more than a window away from everything else are singletons: they are
    /// dropped and leave every existing moment, and its `MomentID`, exactly as it was.
    @Test(arguments: seeds, windows)
    func momentIDsAreStableWhenUnrelatedPhotosAreAdded(seed: UInt64, window: TimeWindow) throws {
        let records = library(seed)
        let before = Clusterer.moments(from: records, window: window)
        let margin = window.interval + 1
        let first = try #require(records.first)
        let last = try #require(records.last)

        var added = [
            AssetRecord(id: PhotoID("added/before"), created: first.created.addingTimeInterval(-margin)),
            AssetRecord(id: PhotoID("added/after"), created: last.created.addingTimeInterval(margin)),
        ]
        // One photo in the middle of every gap wide enough to stay apart from both sides.
        for (index, (previous, next)) in zip(records, records.dropFirst()).enumerated()
        where next.created.timeIntervalSince(previous.created) > 2 * margin {
            let middle = previous.created.addingTimeInterval(next.created.timeIntervalSince(previous.created) / 2)
            added.append(AssetRecord(id: PhotoID("added/\(index)"), created: middle))
        }

        let after = Clusterer.moments(from: records + added, window: window)
        #expect(after == before)
        #expect(after.map(\.id) == before.map(\.id))
    }

    /// A moment that grows (a later photo joins, or one is inserted inside it) keeps its ID.
    @Test(arguments: seeds)
    func momentIDSurvivesGrowth(seed: UInt64) throws {
        let records = library(seed)
        let window = TimeWindow.default
        let moment = try #require(Clusterer.moments(from: records, window: window).first)
        let inside = AssetRecord(id: PhotoID("added/inside"), created: moment.start.addingTimeInterval(0.5))
        let grown = Clusterer.moments(from: records + [inside], window: window)
        #expect(grown.contains { $0.id == moment.id && $0.count == moment.count + 1 })
    }
}

@Suite("Clusterer details")
struct ClustererDetailTests {
    @Test func chainingFollowsThePreviousPhotoNotTheFirst() {
        // Each gap is 50 s, under 1 min, so all four join although the span is 150 s.
        let moments = Clusterer.moments(from: [0, 50, 100, 150].map { Make.record($0) }, window: .default)
        #expect(moments.map(\.count) == [4])
        #expect(moments.first.map { $0.end.timeIntervalSince($0.start) } == 150)
    }

    @Test func equalCaptureTimesAreOrderedByID() {
        let records = [Make.record(0, id: "b"), Make.record(0, id: "c"), Make.record(0, id: "a")]
        let moments = Clusterer.moments(from: records, window: .default)
        #expect(moments.first?.photoIDs == Make.ids("a", "b", "c"))
        #expect(moments.first?.id == MomentID(anchor: PhotoID("a")))
    }

    @Test func minimumCountOneKeepsSinglePhotos() {
        let records = [0, 120, 125, 500].map { Make.record($0) }
        let moments = Clusterer.moments(from: records, window: TimeWindow(seconds: 30, isCustom: false), minimumCount: 1)
        #expect(moments.map(\.count) == [1, 2, 1])
        #expect(moments.map(\.id.anchor) == Make.ids("p-500", "p-120", "p-0"))
    }

    @Test(arguments: [0, -3])
    func minimumCountBelowOneCountsAsOne(minimum: Int) {
        let records = [0, 500].map { Make.record($0) }
        #expect(Clusterer.moments(from: records, window: .default, minimumCount: minimum).map(\.count) == [1, 1])
    }

    @Test func minimumCountAboveTwoDropsSmallerMoments() {
        let records = [0, 5, 500, 505, 510].map { Make.record($0) }
        #expect(Clusterer.moments(from: records, window: .default, minimumCount: 3).map(\.count) == [3])
    }

    @Test func theLongestCustomWindowJoinsGapsOfTwoHours() {
        let records = [0, 7200, 14_400, 21_601].map { Make.record($0) }
        #expect(Clusterer.moments(from: records, window: .custom(minutes: 120)).map(\.count) == [3])
    }
}
