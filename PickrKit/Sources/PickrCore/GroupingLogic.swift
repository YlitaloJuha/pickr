import Foundation

// The logic-bearing members of the grouping contract types (§4.3, §1.5).

extension TimeWindow {
    /// 10 s, 30 s, 1 min, 3 min; none of them custom.
    public static let presets: [TimeWindow] = presetSeconds.map { TimeWindow(seconds: $0, isCustom: false) }

    /// The custom values the Grouping sheet offers, in whole minutes.
    static let customMinutes: ClosedRange<Int> = 1...120

    /// A custom window of `minutes`, clamped to 1...120.
    ///
    /// A custom 1 min or 3 min stays custom, so the Grouping sheet keeps showing the
    /// slider instead of collapsing to the preset (fixes [ARCH A4]).
    public static func custom(minutes: Int) -> TimeWindow {
        let clamped = min(max(minutes, customMinutes.lowerBound), customMinutes.upperBound)
        return TimeWindow(seconds: clamped * 60, isCustom: true)
    }
}

extension ScanRangePreset {
    /// The look-back length of a rolling preset; `nil` for `.all` and `.custom`.
    var days: Int? {
        switch self {
        case .d7: 7
        case .d14: 14
        case .d30: 30
        case .all, .custom: nil
        }
    }
}

extension ScanRange {
    /// `.d30` when `.custom` lacks dates; otherwise `preset`.
    ///
    /// v1 could store `custom` without dates; such a range both scans and displays as the
    /// last 30 days.
    public var effectivePreset: ScanRangePreset {
        preset == .custom && custom == nil ? .d30 : preset
    }

    /// The capture-date interval to group, or `nil` for the whole library.
    ///
    /// - 7d, 14d and 30d run from the same clock time N days ago up to `now`. The day
    ///   arithmetic goes through `calendar`, so across a daylight-saving change the start
    ///   keeps its wall-clock time and the interval is an hour shorter or longer than N × 24 h.
    /// - Custom runs from the saved start to the saved end.
    /// - Both ends are inclusive (`DateInterval.contains`).
    public func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let preset = effectivePreset
        switch preset {
        case .all:
            return nil
        case .custom:
            // `effectivePreset` is `.custom` only when the dates exist.
            guard let custom else { return nil }
            return DateInterval(start: custom.start, end: custom.end)
        case .d7, .d14, .d30:
            let days = preset.days ?? 30
            let start = calendar.date(byAdding: .day, value: -days, to: now)
                ?? now.addingTimeInterval(-TimeInterval(days) * 86_400)
            return DateInterval(start: min(start, now), end: now)
        }
    }
}
