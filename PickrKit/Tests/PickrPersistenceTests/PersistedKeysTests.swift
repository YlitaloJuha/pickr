import Foundation
import Testing
@testable import PickrPersistence

// Created by WP0 to lock the frozen key strings (§1.2). Owned by WP2 from here on.

@Suite("Persisted keys")
struct PersistedKeysTests {
    @Test func everyKeyIsUnique() {
        #expect(Set(PersistedKeys.all).count == PersistedKeys.all.count)
    }

    @Test func legacyKeyStringsAreExact() {
        #expect(PersistedKeys.legacy == [
            "settings.timeWindowSeconds",
            "settings.scanRangePreset",
            "settings.customRangeStart",
            "settings.customRangeEnd",
            "settings.onboardingCompleted",
            "settings.hapticFeedbackEnabled",
            "ignoreList.photoIDs",
            "stats.photosDeleted",
            "stats.mbFreed",
            "stats.clustersCleared",
            "stats.firstUseDate",
            "hint.tapToKeepDismissCount",
            "hint.swipeUpKeepDismissCount",
            "hint.longPressDismissCount",
            "hint.longPressThumbDismissCount",
            "hint.pendingRestoreRefresh",
            "hint.refreshDismissCount",
            "hint.swipeDismissCount",
        ])
    }

    @Test func v2KeyStringsAreExact() {
        #expect(PersistedKeys.introducedInV2 == [
            "settings.timeWindowIsCustom",
            "settings.momentOrder",
            "settings.protectFavorites",
            "stats.bytesFreed",
            "app.schemaVersion",
            "app.whatsNewSeen",
        ])
    }

    @Test func readOnlyKeysAreLegacy() {
        #expect(PersistedKeys.readOnly.isSubset(of: Set(PersistedKeys.legacy)))
        #expect(PersistedKeys.readOnly.contains("ignoreList.photoIDs"))
    }

    @Test func inMemoryStoreBehavesLikeUserDefaults() {
        let store = InMemoryKeyValueStore(["a": 1])
        #expect(store.object(forKey: "a") as? Int == 1)
        store.set("x", forKey: "b")
        #expect(store.object(forKey: "b") as? String == "x")
        store.set(nil, forKey: "b")
        #expect(store.object(forKey: "b") == nil)
        store.removeObject(forKey: "a")
        #expect(store.values.isEmpty)
    }
}
