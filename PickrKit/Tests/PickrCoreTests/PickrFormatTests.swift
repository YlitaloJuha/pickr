import Foundation
import Testing
@testable import PickrCore

/// Formatting in en_US (12-hour), en_GB and fi_FI (24-hour), §4.8.
///
/// Foundation's output comes from the ICU data of the macOS that runs the tests, which can
/// change between releases (spacing characters, abbreviations). The assertions therefore
/// check the parts that matter (digits, separators, units, 12/24 hours, which pieces
/// appear) rather than whole strings, after normalizing ICU's special spaces.
@Suite("PickrFormat")
struct PickrFormatTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let enUS = Locale(identifier: "en_US")
    private let enGB = Locale(identifier: "en_GB")
    private let fiFI = Locale(identifier: "fi_FI")

    /// 2026-04-18 13:25:04 UTC.
    private var start: Date { Make.date(2026, 4, 18, 13, 25, 4, in: Make.calendar("UTC")) }

    // MARK: bytes

    @Test func bytesUseDecimalFileUnits() {
        // 1.5 MB decimal; binary units would read 1.4 MB.
        #expect(PickrFormat.bytes(1_500_000, locale: enUS).plainSpaces == "1.5 MB")
        #expect(PickrFormat.bytes(4_200_000, locale: enGB).plainSpaces == "4.2 MB")
        #expect(PickrFormat.bytes(3_400_000_000, locale: enUS).plainSpaces == "3.4 GB")
        // v1's lifetime figure of 1.5 MiB reads as 1.6 MB in v2 (§2.2 C13).
        #expect(PickrFormat.bytes(1_572_864, locale: enUS).plainSpaces == "1.6 MB")
    }

    @Test func bytesFollowTheLocale() {
        let finnish = PickrFormat.bytes(4_200_000, locale: fiFI).plainSpaces
        #expect(finnish.hasPrefix("4,2 "))
        #expect(finnish != PickrFormat.bytes(4_200_000, locale: enUS).plainSpaces)
    }

    @Test func zeroBytesIsANumber() {
        let zero = PickrFormat.bytes(0, locale: enUS).plainSpaces
        #expect(zero.hasPrefix("0 "))
        #expect(!zero.localizedCaseInsensitiveContains("zero"))
        #expect(PickrFormat.bytes(0, locale: fiFI).hasPrefix("0"))
    }

    @Test func publicBytesMatchesTheStyle() {
        #expect(PickrFormat.bytes(4_200_000) == PickrFormat.byteStyle.format(4_200_000))
        #expect(PickrFormat.bytes(4_200_000).contains("4"))
    }

    // MARK: timeSpan

    @Test func shortSpanShowsSecondsIn12HourEnglish() {
        let text = PickrFormat.timeSpan(start, start.addingTimeInterval(12), locale: enUS, timeZone: utc).plainSpaces
        #expect(text.contains("1:25:04"))
        #expect(text.contains("1:25:16"))
        #expect(text.contains("PM"))
        #expect(!text.contains("13"))
    }

    @Test func longSpanDropsSecondsIn12HourEnglish() {
        let text = PickrFormat.timeSpan(start, start.addingTimeInterval(380), locale: enUS, timeZone: utc).plainSpaces
        #expect(text.contains("1:25"))
        #expect(text.contains("1:31"))
        #expect(text.contains("PM"))
        #expect(!text.contains(":04"))
        #expect(!text.contains(":24"))
    }

    @Test func shortSpanIn24HourBritishEnglish() {
        let text = PickrFormat.timeSpan(start, start.addingTimeInterval(12), locale: enGB, timeZone: utc).plainSpaces
        #expect(text.contains("13:25:04"))
        #expect(text.contains("13:25:16"))
        #expect(text.contains("–"))
        #expect(!text.contains("PM"))
    }

    @Test func longSpanIn24HourBritishEnglish() {
        let text = PickrFormat.timeSpan(start, start.addingTimeInterval(380), locale: enGB, timeZone: utc).plainSpaces
        #expect(text.contains("13:25"))
        #expect(text.contains("13:31"))
        #expect(!text.contains("13:25:04"))
    }

    @Test func spansIn24HourFinnish() {
        let short = PickrFormat.timeSpan(start, start.addingTimeInterval(12), locale: fiFI, timeZone: utc)
        #expect(short.contains("13.25.04"))
        #expect(short.contains("13.25.16"))
        let long = PickrFormat.timeSpan(start, start.addingTimeInterval(380), locale: fiFI, timeZone: utc)
        #expect(long.contains("13.25"))
        #expect(long.contains("13.31"))
        #expect(!long.contains("13.25.04"))
    }

    /// The seconds rule switches exactly at 60 s.
    @Test func secondsAppearBelowSixtySeconds() {
        let below = PickrFormat.timeSpan(start, start.addingTimeInterval(59), locale: enGB, timeZone: utc)
        let at = PickrFormat.timeSpan(start, start.addingTimeInterval(60), locale: enGB, timeZone: utc)
        #expect(below.contains("13:26:03"))
        #expect(at.plainSpaces.contains("13:26"))
        #expect(!at.contains("13:26:04"))
    }

    @Test func equalEndsShowOneTime() {
        let text = PickrFormat.timeSpan(start, start, locale: enGB, timeZone: utc)
        #expect(text.contains("13:25:04"))
        #expect(!text.contains("–"))
    }

    @Test func endsMayComeInEitherOrder() {
        let end = start.addingTimeInterval(12)
        #expect(PickrFormat.timeSpan(end, start, locale: enUS, timeZone: utc) == PickrFormat.timeSpan(start, end, locale: enUS, timeZone: utc))
        #expect(PickrFormat.timeSpan(end, start) == PickrFormat.timeSpan(start, end))
    }

    @Test func spansFollowTheTimeZone() {
        let helsinki = TimeZone(identifier: "Europe/Helsinki")!
        let text = PickrFormat.timeSpan(start, start.addingTimeInterval(12), locale: enGB, timeZone: helsinki)
        #expect(text.contains("16:25:04")) // UTC+3 in April
    }

    // MARK: duration

    @Test func durationIsAbbreviatedWithAtMostTwoUnits() {
        let seconds = PickrFormat.duration(start, start.addingTimeInterval(12), locale: enUS).plainSpaces
        #expect(seconds.hasPrefix("12 "))
        #expect(seconds.contains("sec"))
        let minutes = PickrFormat.duration(start, start.addingTimeInterval(380), locale: enUS).plainSpaces
        #expect(minutes.contains("6 min"))
        #expect(minutes.contains("20 sec"))
        let hours = PickrFormat.duration(start, start.addingTimeInterval(3_905), locale: enUS).plainSpaces
        #expect(hours.contains("1 hr"))
        #expect(hours.contains("5 min"))
        #expect(!hours.contains("sec"), "two units at most")
    }

    @Test func durationInFinnish() {
        #expect(PickrFormat.duration(start, start.addingTimeInterval(12), locale: fiFI).plainSpaces == "12 s")
    }

    @Test func durationIgnoresTheOrderOfItsEnds() {
        let end = start.addingTimeInterval(380)
        #expect(PickrFormat.duration(end, start, locale: enGB) == PickrFormat.duration(start, end, locale: enGB))
        #expect(PickrFormat.duration(end, start) == PickrFormat.duration(start, end))
        #expect(PickrFormat.duration(start, start, locale: enUS).hasPrefix("0"))
    }

    // MARK: dayTitle

    /// Sunday 2026-04-12, 15:00.
    private func now(in calendar: Calendar) -> Date { Make.date(2026, 4, 12, 15, 0, 0, in: calendar) }

    @Test(arguments: [
        ("en_US", ["Today", "Yesterday", "Friday", "Monday"]),
        ("en_GB", ["Today", "Yesterday", "Friday", "Monday"]),
        ("fi_FI", ["Tänään", "Eilen", "Perjantai", "Maanantai"]),
    ])
    func recentDaysUseWords(locale: String, expected: [String]) {
        let calendar = Make.calendar("Europe/Helsinki", locale: locale)
        let now = now(in: calendar)
        let titles = [
            Make.date(2026, 4, 12, 0, 5, 0, in: calendar),
            Make.date(2026, 4, 11, 23, 55, 0, in: calendar),
            Make.date(2026, 4, 10, 9, 0, 0, in: calendar),
            Make.date(2026, 4, 6, 20, 0, 0, in: calendar),
        ].map { PickrFormat.dayTitle($0, now: now, calendar: calendar) }
        #expect(titles == expected)
    }

    @Test(arguments: ["en_US", "en_GB", "fi_FI"])
    func olderDaysUseAMediumDate(locale: String) {
        let calendar = Make.calendar("Europe/Helsinki", locale: locale)
        let day = Make.date(2026, 4, 5, 12, 0, 0, in: calendar) // 7 days back
        let title = PickrFormat.dayTitle(day, now: now(in: calendar), calendar: calendar)
        #expect(title.contains("5"))
        #expect(title.contains("2026"))
        let expected = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: locale),
                                        calendar: calendar, timeZone: calendar.timeZone,
                                        capitalizationContext: .beginningOfSentence)
        #expect(title == expected.format(day))
    }

    @Test func mediumDateInUSEnglish() {
        let calendar = Make.calendar("UTC", locale: "en_US")
        let title = PickrFormat.dayTitle(Make.date(2025, 12, 24, in: calendar), now: now(in: calendar), calendar: calendar)
        #expect(title.plainSpaces == "Dec 24, 2025")
    }

    @Test func futureDaysUseAMediumDate() {
        let calendar = Make.calendar("UTC", locale: "en_US")
        let title = PickrFormat.dayTitle(Make.date(2026, 4, 13, 9, 0, 0, in: calendar), now: now(in: calendar), calendar: calendar)
        #expect(title.plainSpaces == "Apr 13, 2026")
    }

    /// Calendar days, not 24-hour spans, in the calendar's time zone.
    @Test func daysAreCalendarDaysInTheCalendarsTimeZone() {
        let utcCalendar = Make.calendar("UTC", locale: "en_US")
        let helsinkiCalendar = Make.calendar("Europe/Helsinki", locale: "en_US")
        // 22:30 UTC on Saturday is 01:30 on Sunday in Helsinki.
        let photo = Make.date(2026, 4, 11, 22, 30, 0, in: utcCalendar)
        let now = Make.date(2026, 4, 12, 9, 0, 0, in: utcCalendar)
        #expect(PickrFormat.dayTitle(photo, now: now, calendar: utcCalendar) == "Yesterday")
        #expect(PickrFormat.dayTitle(photo, now: now, calendar: helsinkiCalendar) == "Today")
    }

    /// Helsinki springs forward on Sunday 2026-03-29, a 23-hour day: from Monday it is
    /// still "Yesterday", and the weekday window still ends 6 days back.
    @Test func dayCountsAcrossADaylightSavingChange() {
        let calendar = Make.calendar("Europe/Helsinki", locale: "en_GB")
        let now = Make.date(2026, 3, 30, 12, 0, 0, in: calendar)
        func title(_ day: Int, _ hour: Int) -> String {
            PickrFormat.dayTitle(Make.date(2026, 3, day, hour, 0, 0, in: calendar), now: now, calendar: calendar)
        }
        #expect(title(29, 1) == "Yesterday")
        #expect(title(24, 12) == "Tuesday")
        #expect(title(23, 23).plainSpaces == "23 Mar 2026")
    }
}
