import Foundation
import Testing
@testable import PickrCore

@Suite("TimeWindow")
struct TimeWindowTests {
    @Test func presetsAre10s30s1m3mAndNotCustom() {
        #expect(TimeWindow.presets.map(\.seconds) == [10, 30, 60, 180])
        #expect(TimeWindow.presets.allSatisfy { !$0.isCustom })
        #expect(TimeWindow.presets.contains(.default))
        #expect(TimeWindow.default.interval == 60)
    }

    @Test(arguments: [(1, 60), (2, 120), (45, 2700), (120, 7200)])
    func customMinutes(minutes: Int, seconds: Int) {
        let window = TimeWindow.custom(minutes: minutes)
        #expect(window.seconds == seconds)
        #expect(window.isCustom)
    }

    @Test(arguments: [(0, 60), (-10, 60), (121, 7200), (10_000, 7200)])
    func customMinutesClampTo1Through120(minutes: Int, seconds: Int) {
        #expect(TimeWindow.custom(minutes: minutes) == TimeWindow(seconds: seconds, isCustom: true))
    }

    /// v1 collapsed a custom 1 min or 3 min into the preset (`SettingsStore.swift:33-38`,
    /// [ARCH A4]). In v2 they stay distinct, so the sheet keeps showing Custom.
    @Test func custom1And3MinutesStayCustom() {
        #expect(TimeWindow.custom(minutes: 1) != .default)
        #expect(TimeWindow.custom(minutes: 1).seconds == TimeWindow.default.seconds)
        #expect(TimeWindow.custom(minutes: 3).isCustom)
        #expect(!TimeWindow.presets.contains(.custom(minutes: 3)))
    }

    @Test func customWindowsRoundTripThroughCodable() throws {
        for window in TimeWindow.presets + [.custom(minutes: 1), .custom(minutes: 3), TimeWindow(seconds: 45, isCustom: false)] {
            let decoded = try JSONDecoder().decode(TimeWindow.self, from: JSONEncoder().encode(window))
            #expect(decoded == window)
        }
    }
}

@Suite("ScanRange")
struct ScanRangeTests {
    private let helsinki = Make.calendar("Europe/Helsinki")

    @Test func effectivePreset() {
        let dates = CustomRange(Make.epoch, Make.epoch.addingTimeInterval(86_400))
        #expect(ScanRange(preset: .custom).effectivePreset == .d30)
        #expect(ScanRange(preset: .custom, custom: dates).effectivePreset == .custom)
        #expect(ScanRange(preset: .d14, custom: dates).effectivePreset == .d14)
        for preset in [ScanRangePreset.d7, .d14, .d30, .all] {
            #expect(ScanRange(preset: preset).effectivePreset == preset)
        }
        #expect(ScanRange.default.effectivePreset == .d30)
    }

    @Test(arguments: [(ScanRangePreset.d7, 7), (.d14, 14), (.d30, 30)])
    func rollingPresetsRunFromTheSameClockTimeNDaysAgo(preset: ScanRangePreset, days: Int) throws {
        let now = Make.date(2026, 6, 15, 13, 25, 4, in: helsinki)
        let interval = try #require(ScanRange(preset: preset).interval(now: now, calendar: helsinki))
        #expect(interval.end == now)
        #expect(interval.start == Make.date(2026, 6, 15 - days, 13, 25, 4, in: helsinki))
        #expect(interval.duration == TimeInterval(days * 86_400))
    }

    /// Helsinki moves to summer time on 2026-03-29 (03:00 → 04:00): 7 days back from
    /// 2 April is 26 March at the same wall-clock time, 167 hours earlier.
    @Test func springForwardKeepsTheWallClockTime() throws {
        let now = Make.date(2026, 4, 2, 12, 0, 0, in: helsinki)
        let interval = try #require(ScanRange(preset: .d7).interval(now: now, calendar: helsinki))
        #expect(interval.start == Make.date(2026, 3, 26, 12, 0, 0, in: helsinki))
        #expect(interval.duration == TimeInterval(7 * 86_400 - 3600))
        #expect(helsinki.component(.hour, from: interval.start) == 12)
    }

    /// Helsinki returns to winter time on 2026-10-25 (04:00 → 03:00): 169 hours.
    @Test func fallBackKeepsTheWallClockTime() throws {
        let now = Make.date(2026, 10, 28, 12, 0, 0, in: helsinki)
        let interval = try #require(ScanRange(preset: .d7).interval(now: now, calendar: helsinki))
        #expect(interval.start == Make.date(2026, 10, 21, 12, 0, 0, in: helsinki))
        #expect(interval.duration == TimeInterval(7 * 86_400 + 3600))
    }

    @Test func theSameNowGivesTheSameIntervalInEveryTimeZoneWithoutDST() throws {
        let now = Make.epoch
        let utc = try #require(ScanRange(preset: .d30).interval(now: now, calendar: Make.calendar("UTC")))
        let tokyo = try #require(ScanRange(preset: .d30).interval(now: now, calendar: Make.calendar("Asia/Tokyo")))
        #expect(utc == tokyo)
    }

    @Test func allIsTheWholeLibrary() {
        #expect(ScanRange(preset: .all).interval(now: Make.epoch, calendar: helsinki) == nil)
        let saved = CustomRange(Make.epoch, Make.epoch.addingTimeInterval(60))
        #expect(ScanRange(preset: .all, custom: saved).interval(now: Make.epoch, calendar: helsinki) == nil)
    }

    @Test func customUsesTheSavedDates() throws {
        let start = Make.date(2026, 4, 1, 0, 0, 0, in: helsinki)
        let end = Make.date(2026, 4, 18, 23, 59, 59, in: helsinki)
        let range = ScanRange(preset: .custom, custom: CustomRange(start, end))
        let interval = try #require(range.interval(now: Make.date(2026, 11, 21, in: helsinki), calendar: helsinki))
        #expect(interval == DateInterval(start: start, end: end))
    }

    @Test func invertedCustomDatesAreSwapped() throws {
        let early = Make.date(2026, 4, 1, in: helsinki)
        let late = Make.date(2026, 4, 18, in: helsinki)
        let range = ScanRange(preset: .custom, custom: CustomRange(late, early))
        let interval = try #require(range.interval(now: late, calendar: helsinki))
        #expect(interval.start == early)
        #expect(interval.end == late)
    }

    @Test func customWithoutDatesScansAsThirtyDays() {
        let now = Make.date(2026, 6, 15, 9, 0, 0, in: helsinki)
        #expect(ScanRange(preset: .custom).interval(now: now, calendar: helsinki)
            == ScanRange(preset: .d30).interval(now: now, calendar: helsinki))
    }

    @Test func otherPresetsIgnoreSavedCustomDates() {
        let now = Make.date(2026, 6, 15, 9, 0, 0, in: helsinki)
        let saved = CustomRange(Make.date(2020, 1, 1, in: helsinki), Make.date(2020, 2, 1, in: helsinki))
        #expect(ScanRange(preset: .d7, custom: saved).interval(now: now, calendar: helsinki)
            == ScanRange(preset: .d7).interval(now: now, calendar: helsinki))
    }
}
