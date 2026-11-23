import Foundation
import PickrCore

/// The settings as stored in UserDefaults.
public struct StoredSettings: Hashable, Sendable {
    public var grouping: GroupingSettings
    public var hapticsEnabled: Bool
    public var protectFavorites: Bool
    public var onboardingCompleted: Bool
    public var whatsNewSeen: String?

    public init(
        grouping: GroupingSettings,
        hapticsEnabled: Bool,
        protectFavorites: Bool,
        onboardingCompleted: Bool,
        whatsNewSeen: String?
    ) {
        self.grouping = grouping
        self.hapticsEnabled = hapticsEnabled
        self.protectFavorites = protectFavorites
        self.onboardingCompleted = onboardingCompleted
        self.whatsNewSeen = whatsNewSeen
    }
}

/// Reads and writes `StoredSettings` under the §1.2 keys.
///
/// Reading never fails. An absent key, or a value of an unexpected type, gives the §1.2
/// default:
/// - time window 60 s, clamped to 10...7200; custom when the stored flag says so, or when
///   the value isn't a preset;
/// - scan range `d30` for an unknown or absent preset, and for `custom` without both dates;
///   custom dates in either order;
/// - order newest first; haptics on; protect favorites on; onboarding not completed.
///
/// Saving writes only the keys whose value would read back differently, so absent keys
/// stay absent while they hold the default.
public struct SettingsRepository {
    private typealias Keys = PersistedKeys.Settings

    private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
    }

    public func load() -> StoredSettings {
        StoredSettings(
            grouping: GroupingSettings(window: readWindow(), range: readRange(), order: readOrder()),
            hapticsEnabled: readHapticsEnabled(),
            protectFavorites: readProtectFavorites(),
            onboardingCompleted: readOnboardingCompleted(),
            whatsNewSeen: store.readString(PersistedKeys.App.whatsNewSeen)
        )
    }

    /// Writes only changed keys; writes the custom range only with dates.
    ///
    /// `load()` afterwards returns `s`. In detail:
    /// - `range.custom` is stored as the two dates, and a `nil` custom removes them. To keep
    ///   offering the last range, keep `custom` when switching to another preset. Callers
    ///   pass start at 00:00:00 local on the FROM day and end at 23:59:59 local on the TO day.
    /// - `custom` is stored only together with both dates. A `.custom` range without dates is
    ///   saved as `d30`, the range it scans; this also repairs a v1 `custom` stored without
    ///   dates.
    public func save(_ s: StoredSettings) {
        saveRange(s.grouping.range)

        // Seconds before the flag: an absent flag reads as "not a preset" of the seconds.
        let window = s.grouping.window
        if readWindow().seconds != window.seconds {
            store.set(window.seconds, forKey: Keys.timeWindowSeconds)
        }
        if readWindow().isCustom != window.isCustom {
            store.set(window.isCustom, forKey: Keys.timeWindowIsCustom)
        }

        if readOrder() != s.grouping.order {
            store.set(s.grouping.order.rawValue, forKey: Keys.momentOrder)
        }
        if readHapticsEnabled() != s.hapticsEnabled {
            store.set(s.hapticsEnabled, forKey: Keys.hapticFeedbackEnabled)
        }
        if readProtectFavorites() != s.protectFavorites {
            store.set(s.protectFavorites, forKey: Keys.protectFavorites)
        }
        if readOnboardingCompleted() != s.onboardingCompleted {
            store.set(s.onboardingCompleted, forKey: Keys.onboardingCompleted)
        }
        if store.readString(PersistedKeys.App.whatsNewSeen) != s.whatsNewSeen {
            if let seen = s.whatsNewSeen {
                store.set(seen, forKey: PersistedKeys.App.whatsNewSeen)
            } else {
                store.removeObject(forKey: PersistedKeys.App.whatsNewSeen)
            }
        }
    }

    /// Orders the writes so that `custom` is never stored without both dates, even if the
    /// app stops between two of them: dates go in before `custom`, and come out after it.
    private func saveRange(_ range: ScanRange) {
        let preset = Self.normalizedPreset(range.preset, hasDates: range.custom != nil)
        // Compared with the stored string as parsed, not as read: a stored `custom` without
        // dates reads as d30 but is still rewritten.
        let storedPreset = store.readString(Keys.scanRangePreset).flatMap(ScanRangePreset.init(rawValue:))
            ?? Self.fallbackPreset

        if let custom = range.custom {
            if store.readDate(Keys.customRangeStart) != custom.start {
                store.set(custom.start, forKey: Keys.customRangeStart)
            }
            if store.readDate(Keys.customRangeEnd) != custom.end {
                store.set(custom.end, forKey: Keys.customRangeEnd)
            }
            if storedPreset != preset {
                store.set(preset.rawValue, forKey: Keys.scanRangePreset)
            }
        } else {
            if storedPreset != preset {
                store.set(preset.rawValue, forKey: Keys.scanRangePreset)
            }
            if readRange().custom != nil {
                store.removeObject(forKey: Keys.customRangeStart)
                store.removeObject(forKey: Keys.customRangeEnd)
            }
        }
    }

    // MARK: - Reading one setting

    /// The stored seconds, clamped, ignoring the custom flag. Its `isCustom` is the default
    /// for an absent flag: `true` exactly when the seconds aren't a preset.
    static func windowIgnoringFlag(in store: any KeyValueStore) -> TimeWindow {
        TimeWindow(seconds: store.readInt(Keys.timeWindowSeconds) ?? TimeWindow.default.seconds, isCustom: false)
    }

    private func readWindow() -> TimeWindow {
        let base = Self.windowIgnoringFlag(in: store)
        let isCustom = store.readBool(Keys.timeWindowIsCustom) ?? base.isCustom
        return TimeWindow(seconds: base.seconds, isCustom: isCustom)
    }

    private func readRange() -> ScanRange {
        var custom: CustomRange?
        if let start = store.readDate(Keys.customRangeStart), let end = store.readDate(Keys.customRangeEnd) {
            custom = CustomRange(start, end)
        }
        let stored = store.readString(Keys.scanRangePreset).flatMap(ScanRangePreset.init(rawValue:))
        let preset = Self.normalizedPreset(stored ?? Self.fallbackPreset, hasDates: custom != nil)
        return ScanRange(preset: preset, custom: custom)
    }

    private func readOrder() -> MomentOrder {
        store.readString(Keys.momentOrder).flatMap(MomentOrder.init(rawValue:)) ?? .newest
    }

    /// Absent means `true`. `UserDefaults.bool(forKey:)` would say `false` and silently turn
    /// haptics off for everyone who never touched the toggle.
    private func readHapticsEnabled() -> Bool {
        store.readBool(Keys.hapticFeedbackEnabled) ?? true
    }

    private func readProtectFavorites() -> Bool {
        store.readBool(Keys.protectFavorites) ?? true
    }

    private func readOnboardingCompleted() -> Bool {
        store.readBool(Keys.onboardingCompleted) ?? false
    }

    /// The range used for an unknown or absent preset, and for `custom` without dates.
    private static let fallbackPreset = ScanRangePreset.d30

    private static func normalizedPreset(_ preset: ScanRangePreset, hasDates: Bool) -> ScanRangePreset {
        preset == .custom && !hasDates ? fallbackPreset : preset
    }
}

// MARK: - Typed reads

/// Reads in the style of `object(forKey:) as? T`, so "absent" and "false" or "0" stay
/// different. A value of another type reads as absent. Shared by this module's repositories.
extension KeyValueStore {
    func readBool(_ key: String) -> Bool? {
        object(forKey: key) as? Bool
    }

    func readInt(_ key: String) -> Int? {
        object(forKey: key) as? Int
    }

    func readInt64(_ key: String) -> Int64? {
        switch object(forKey: key) {
        case let value as Int64: value
        case let value as Int: Int64(value)
        default: nil
        }
    }

    func readDouble(_ key: String) -> Double? {
        switch object(forKey: key) {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as Int64: Double(value)
        default: nil
        }
    }

    func readString(_ key: String) -> String? {
        object(forKey: key) as? String
    }

    func readDate(_ key: String) -> Date? {
        object(forKey: key) as? Date
    }
}
