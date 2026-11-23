import Foundation
import Testing
@testable import PickrPersistence

@Suite("Legacy tips")
struct LegacyTipsTests {
    private typealias Keys = PersistedKeys.Hint

    @Test(arguments: StoreKind.allCases)
    func readsTheV1Fixture(kind: StoreKind) throws {
        let box = kind.make(try V1Fixture.values())
        let seen = LegacyTips.seen(in: box.store)
        #expect(seen.tapToKeep)
        #expect(seen.swipeUp)
    }

    @Test func absentCountsMeanNotSeen() {
        let seen = LegacyTips.seen(in: InMemoryKeyValueStore())
        #expect(!seen.tapToKeep)
        #expect(!seen.swipeUp)
    }

    @Test(arguments: [(0, false), (1, true), (2, true), (37, true), (-1, false)])
    func aCountOfOneOrMoreMeansSeen(count: Int, seen: Bool) {
        let tapOnly = LegacyTips.seen(in: InMemoryKeyValueStore([Keys.tapToKeepDismissCount: count]))
        #expect(tapOnly.tapToKeep == seen)
        #expect(!tapOnly.swipeUp)

        let swipeOnly = LegacyTips.seen(in: InMemoryKeyValueStore([Keys.swipeUpKeepDismissCount: count]))
        #expect(swipeOnly.swipeUp == seen)
        #expect(!swipeOnly.tapToKeep)
    }

    @Test func valuesOfAnotherTypeMeanNotSeen() {
        let seen = LegacyTips.seen(in: InMemoryKeyValueStore([
            Keys.tapToKeepDismissCount: "1",
            Keys.swipeUpKeepDismissCount: Data([1]),
        ]))
        #expect(!seen.tapToKeep)
        #expect(!seen.swipeUp)
    }

    @Test func retiredHintCountersAreIgnored() {
        let seen = LegacyTips.seen(in: InMemoryKeyValueStore([
            Keys.longPressDismissCount: 1,
            Keys.longPressThumbDismissCount: 1,
            Keys.pendingRestoreRefresh: true,
            Keys.refreshDismissCount: 3,
            Keys.swipeDismissCount: 3,
        ]))
        #expect(!seen.tapToKeep)
        #expect(!seen.swipeUp)
    }

    @Test func readingWritesNothing() throws {
        let store = RecordingStore(try V1Fixture.values())
        _ = LegacyTips.seen(in: store)
        #expect(store.writtenKeys.isEmpty)
    }
}
