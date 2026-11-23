import Foundation

/// Every UserDefaults key Pickr. has ever written, legacy (v1) and v2.
///
/// This is the ONLY source file where these strings may appear (tests excepted);
/// `scripts/policy-check.sh` enforces it. Users' devices hold the legacy values, so a
/// key string never changes. See blueprint §1.2 and docs/PERSISTENCE.md.
public enum PersistedKeys {
    /// Grouping, onboarding and feedback settings.
    public enum Settings {
        /// Int seconds. Absent means 60. Clamp to 10...7200; never minutes. (v1, live)
        public static let timeWindowSeconds = "settings.timeWindowSeconds"
        /// String `d7` `d14` `d30` `all` `custom`. Unknown or absent means `d30`. (v1, live)
        public static let scanRangePreset = "settings.scanRangePreset"
        /// Date, 00:00:00 local on the FROM day. (v1, live)
        public static let customRangeStart = "settings.customRangeStart"
        /// Date, 23:59:59 local on the TO day. (v1, live)
        public static let customRangeEnd = "settings.customRangeEnd"
        /// Bool. `true` marks an existing user. (v1, live)
        public static let onboardingCompleted = "settings.onboardingCompleted"
        /// Bool. ABSENT MEANS `true`. (v1, live)
        public static let hapticFeedbackEnabled = "settings.hapticFeedbackEnabled"
        /// Bool. Absent means "not a preset". (v2)
        public static let timeWindowIsCustom = "settings.timeWindowIsCustom"
        /// String `newest` / `mostSpace`. Absent means `newest`. (v2)
        public static let momentOrder = "settings.momentOrder"
        /// Bool. Absent means `true`. (v2)
        public static let protectFavorites = "settings.protectFavorites"
    }

    /// The v1 Kept list.
    public enum IgnoreList {
        /// [String] of `localIdentifier`s. Read ONCE during migration; NEVER written or
        /// removed in 2.x. (v1, read-only)
        public static let photoIDs = "ignoreList.photoIDs"
    }

    /// Lifetime statistics.
    public enum Stats {
        /// Int. Confirmed deletions. (v1, live)
        public static let photosDeleted = "stats.photosDeleted"
        /// Double, MiB. Read once during migration, never written. (v1, read-only)
        public static let mbFreed = "stats.mbFreed"
        /// Int. Shown as "Moments cleared". (v1, live)
        public static let clustersCleared = "stats.clustersCleared"
        /// Date. Write-once; its presence marks a v1 user. (v1, live)
        public static let firstUseDate = "stats.firstUseDate"
        /// Int64 bytes. (v2)
        public static let bytesFreed = "stats.bytesFreed"
    }

    /// v1 hint-banner counters. Read-only; nothing in v2 writes them.
    public enum Hint {
        /// Int. `>= 1` marks `TapToKeepTip` as seen. (v1, read-only)
        public static let tapToKeepDismissCount = "hint.tapToKeepDismissCount"
        /// Int. `>= 1` marks `SwipeUpKeepTip` as seen. (v1, read-only)
        public static let swipeUpKeepDismissCount = "hint.swipeUpKeepDismissCount"
        /// Int. Ignored: the gesture it taught is gone. (v1)
        public static let longPressDismissCount = "hint.longPressDismissCount"
        /// Int. Ignored: the gesture it taught is gone. (v1)
        public static let longPressThumbDismissCount = "hint.longPressThumbDismissCount"
        /// Bool. Ignored; TestFlight builds 1–3 only. (v1)
        public static let pendingRestoreRefresh = "hint.pendingRestoreRefresh"
        /// Int. Ignored; TestFlight builds 1–3 only. (v1)
        public static let refreshDismissCount = "hint.refreshDismissCount"
        /// Int. Ignored; TestFlight builds 1–3 only. (v1)
        public static let swipeDismissCount = "hint.swipeDismissCount"
    }

    /// App lifecycle markers.
    public enum App {
        /// Int. Absent means v1 or a fresh install. Set to 2 as the LAST migration step. (v2)
        public static let schemaVersion = "app.schemaVersion"
        /// String. The version whose What's New sheet was shown, for example "2.0". (v2)
        public static let whatsNewSeen = "app.whatsNewSeen"
    }

    /// Keys written by v1 and present on users' devices.
    public static let legacy: [String] = [
        Settings.timeWindowSeconds,
        Settings.scanRangePreset,
        Settings.customRangeStart,
        Settings.customRangeEnd,
        Settings.onboardingCompleted,
        Settings.hapticFeedbackEnabled,
        IgnoreList.photoIDs,
        Stats.photosDeleted,
        Stats.mbFreed,
        Stats.clustersCleared,
        Stats.firstUseDate,
        Hint.tapToKeepDismissCount,
        Hint.swipeUpKeepDismissCount,
        Hint.longPressDismissCount,
        Hint.longPressThumbDismissCount,
        Hint.pendingRestoreRefresh,
        Hint.refreshDismissCount,
        Hint.swipeDismissCount,
    ]

    /// Keys introduced by v2.
    public static let introducedInV2: [String] = [
        Settings.timeWindowIsCustom,
        Settings.momentOrder,
        Settings.protectFavorites,
        Stats.bytesFreed,
        App.schemaVersion,
        App.whatsNewSeen,
    ]

    /// Legacy keys v2 never writes or removes.
    public static let readOnly: Set<String> = [
        IgnoreList.photoIDs,
        Stats.mbFreed,
        Hint.tapToKeepDismissCount,
        Hint.swipeUpKeepDismissCount,
        Hint.longPressDismissCount,
        Hint.longPressThumbDismissCount,
        Hint.pendingRestoreRefresh,
        Hint.refreshDismissCount,
        Hint.swipeDismissCount,
    ]

    /// Every key, legacy first.
    public static var all: [String] { legacy + introducedInV2 }
}
