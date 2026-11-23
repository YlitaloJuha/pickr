import Foundation

// Grouping settings. `TimeWindow.presets`, `TimeWindow.custom(minutes:)`,
// `ScanRange.effectivePreset` and `ScanRange.interval(now:calendar:)` live in
// GroupingLogic.swift.

/// How far apart two consecutive photos may be and still share a moment.
public struct TimeWindow: Hashable, Codable, Sendable {
    /// Always within 10...7200.
    public let seconds: Int
    /// Whether the user picked a custom value (1–120 min) rather than a preset.
    /// Always `true` for a value that is not a preset.
    public let isCustom: Bool

    /// The preset values in seconds: 10 s, 30 s, 1 min, 3 min.
    static let presetSeconds: [Int] = [10, 30, 60, 180]

    /// Clamps `seconds` to 10...7200. A value that is not a preset is always custom,
    /// so `isCustom: false` with 45 s gives a custom 45 s window.
    public init(seconds: Int, isCustom: Bool) {
        let clamped = min(max(seconds, 10), 7200)
        self.seconds = clamped
        self.isCustom = isCustom || !Self.presetSeconds.contains(clamped)
    }

    /// 1 minute, not custom.
    public static let `default` = TimeWindow(seconds: 60, isCustom: false)

    public var interval: TimeInterval { TimeInterval(seconds) }

    private enum CodingKeys: String, CodingKey { case seconds, isCustom }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            seconds: try container.decode(Int.self, forKey: .seconds),
            isCustom: try container.decode(Bool.self, forKey: .isCustom)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(isCustom, forKey: .isCustom)
    }
}

/// The scan range choices. The raw values are persisted and must never change.
public enum ScanRangePreset: String, CaseIterable, Codable, Sendable {
    case d7, d14, d30, all, custom
}

/// A user-chosen date range. `start` is never after `end`.
public struct CustomRange: Hashable, Codable, Sendable {
    public let start: Date
    public let end: Date

    /// Takes the two dates in either order and swaps them if needed.
    public init(_ a: Date, _ b: Date) {
        start = min(a, b)
        end = max(a, b)
    }

    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(Date.self, forKey: .start),
            try container.decode(Date.self, forKey: .end)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}

/// Which part of the library is grouped.
public struct ScanRange: Hashable, Sendable {
    public var preset: ScanRangePreset
    /// The saved custom dates. Kept even while another preset is selected, so the
    /// Grouping sheet can offer the last range again.
    public var custom: CustomRange?

    public init(preset: ScanRangePreset, custom: CustomRange? = nil) {
        self.preset = preset
        self.custom = custom
    }

    /// The last 30 days.
    public static let `default` = ScanRange(preset: .d30)
}

/// The order of the Moments list.
public enum MomentOrder: String, CaseIterable, Codable, Sendable {
    /// Newest first, by each moment's last photo, in day sections.
    case newest
    /// The most space to free first; unknown sizes last.
    case mostSpace
}

/// Everything that decides which moments exist and how they are listed.
public struct GroupingSettings: Hashable, Sendable {
    public var window: TimeWindow
    public var range: ScanRange
    public var order: MomentOrder

    public init(window: TimeWindow = .default, range: ScanRange = .default, order: MomentOrder = .newest) {
        self.window = window
        self.range = range
        self.order = order
    }

    /// 1 minute, the last 30 days, newest first.
    public static let `default` = GroupingSettings()
}
