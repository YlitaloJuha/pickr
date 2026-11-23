import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

/// `SettingsModel.sessionStats` (contract-changes/WP7-session-totals.md): the **Just now**
/// totals of the All clean state count only what was deleted since launch.
@Suite("Settings: session totals (Just now)")
struct SessionStatsTests {
    @Test func startAtZeroWhateverTheLifetimeTotals() async {
        let defaults = InMemoryKeyValueStore()
        _ = StatsRepository(store: defaults).record(deleted: 40, bytes: 9_000_000, momentCleared: true)
        let h = Harness(defaults: defaults)
        await h.launch()

        #expect(h.settings.stats.photosDeleted == 40)
        #expect(h.settings.sessionStats.photosDeleted == 0)
        #expect(h.settings.sessionStats.bytesFreed == 0)
        #expect(h.settings.sessionStats.momentsCleared == 0)
    }

    @Test func countEveryConfirmedDeleteSinceLaunch() async throws {
        let defaults = InMemoryKeyValueStore()
        _ = StatsRepository(store: defaults).record(deleted: 7, bytes: 1_000, momentCleared: true)
        let h = Harness(sizes: TestLibrary.sizes(TestLibrary.standard), defaults: defaults)
        await h.launch()

        let a = try h.requireMoment("a1")
        _ = await h.curator.commit(a, selection: Selection(kept: [PhotoID("a1")]))
        await h.settle()
        let b = try h.requireMoment("b1")
        _ = await h.curator.deleteWhole(b)

        #expect(h.settings.sessionStats.momentsCleared == 2)
        #expect(h.settings.sessionStats.photosDeleted == 6)
        #expect(h.settings.sessionStats.bytesFreed == 6_000_000)
        #expect(h.settings.stats.photosDeleted == 13, "lifetime totals keep counting on top")
    }

    @Test func keepAllAndCancelledDeletesAddNothing() async throws {
        let h = Harness(sizes: TestLibrary.sizes(TestLibrary.standard))
        await h.launch()

        let a = try h.requireMoment("a1")
        h.curator.keepAside(a)
        await h.settle()
        h.fake.enqueueDeleteOutcomes(.fail(.cancelled))
        let b = try h.requireMoment("b1")
        _ = await h.curator.deleteWhole(b)

        #expect(h.settings.sessionStats.momentsCleared == 0)
        #expect(h.settings.sessionStats.photosDeleted == 0)
    }
}
