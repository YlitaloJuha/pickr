import Foundation

/// Which v1 hint banners the user already dismissed (§1.2).
///
/// v1 counted dismissals in `hint.*DismissCount` and showed a banner while its count was
/// below 1. v2 shows tips instead and only reads these counters; it never writes them. The
/// long-press counters and the TestFlight-only keys are ignored because the gestures they
/// taught are gone.
public enum LegacyTips {
    /// `tapToKeep` marks `TapToKeepTip` as seen, `swipeUp` marks `SwipeUpKeepTip`. A count of
    /// 1 or more means dismissed; an absent count, or a value of another type, means not.
    public static func seen(in store: any KeyValueStore) -> (tapToKeep: Bool, swipeUp: Bool) {
        (
            tapToKeep: dismissed(PersistedKeys.Hint.tapToKeepDismissCount, in: store),
            swipeUp: dismissed(PersistedKeys.Hint.swipeUpKeepDismissCount, in: store)
        )
    }

    private static func dismissed(_ key: String, in store: any KeyValueStore) -> Bool {
        (store.readInt(key) ?? 0) >= 1
    }
}
