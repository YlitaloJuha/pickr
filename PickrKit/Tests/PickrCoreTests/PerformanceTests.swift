import Foundation
import Testing
import PickrTestSupport
@testable import PickrCore

/// Grouping must stay instant on big libraries (§4.9: a grouping change shows the new list
/// within 150 ms on a 50k library). WP1's bar: 200k records cluster in under 1 s, even in the
/// debug build `swift test` uses.
@Suite("Performance", .serialized)
struct PerformanceTests {
    private static let library = Fixtures.syntheticLibrary(count: 200_000, seed: 42)

    private func seconds(_ work: () -> Void) -> Double {
        let elapsed = ContinuousClock().measure(work)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test(.timeLimit(.minutes(1)))
    func clusters200kRecordsInUnderASecond() {
        let records = Self.library
        var moments: [Moment] = []
        let elapsed = seconds { moments = Clusterer.moments(from: records, window: .default) }
        #expect(!moments.isEmpty)
        #expect(elapsed < 1, "took \(elapsed) s")
    }

    @Test(.timeLimit(.minutes(1)))
    func pipelineOver200kRecordsInUnderASecond() {
        let records = Self.library
        let kept = Set(records.lazy.enumerated().filter { $0.offset.isMultiple(of: 50) }.map(\.element.id))
        let sizes = Fixtures.syntheticSizes(for: records, knownFraction: 0.7, seed: 42)
        var list = MomentList.empty
        let elapsed = seconds {
            list = MomentPipeline.build(
                index: records,
                grouping: GroupingSettings(range: ScanRange(preset: .all), order: .mostSpace),
                kept: kept,
                sizes: sizes,
                now: Fixtures.testPhotosStart,
                calendar: Make.calendar("UTC")
            )
        }
        #expect(list.photoCount > 0)
        #expect(elapsed < 1, "took \(elapsed) s")
    }

    /// Input in no particular order takes the O(n log n) path; still well within the minute.
    @Test(.timeLimit(.minutes(1)))
    func clusters200kShuffledRecords() {
        var generator = Fixtures.SeededGenerator(seed: 7)
        let shuffled = Self.library.shuffled(using: &generator)
        #expect(Clusterer.moments(from: shuffled, window: .default) == Clusterer.moments(from: Self.library, window: .default))
    }
}
