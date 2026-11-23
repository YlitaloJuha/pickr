import Foundation

/// Foundation-localized pieces only; words live in the app's String Catalog.
///
/// `bytes`, `timeSpan` and `duration` follow the user's locale and time zone through the
/// format styles' defaults. `dayTitle` follows the injected calendar: its locale, time zone
/// and day boundaries, so the app passes the user's autoupdating calendar.
public enum PickrFormat {
    /// `ByteCountFormatStyle(style: .file)`: decimal units, like iOS Settings > Storage.
    ///
    /// Zero is a number ("0 bytes"), not a word, so it reads like the other stats.
    public static func bytes(_ bytes: Int64) -> String {
        byteStyle.format(bytes)
    }

    /// "13:25:04 – 13:25:16"; seconds only when the span is under 60 s. 12/24-hour per locale.
    ///
    /// A localized interval: "1:25 – 1:31 PM" in en_US, "13.25–13.31" in fi_FI. Equal ends
    /// give one time; a span across midnight includes the dates. The ends may come in either
    /// order.
    public static func timeSpan(_ start: Date, _ end: Date) -> String {
        timeSpanStyle(start, end).format(min(start, end)..<max(start, end))
    }

    /// `Duration.UnitsFormatStyle`, for example "12 s".
    ///
    /// The absolute length of the span in at most two units, abbreviated: "12 sec",
    /// "6 min, 20 sec", "1 hr, 5 min" in en_US; "12 s" in fi_FI.
    public static func duration(_ start: Date, _ end: Date) -> String {
        durationStyle.format(duration(between: start, and: end))
    }

    /// Today / Yesterday / a weekday within the last 6 days / a medium date.
    ///
    /// Days are compared as calendar days in `calendar`'s time zone, not as 24-hour spans:
    /// a photo from 23:50 reads "Yesterday" at 00:10. A day after `now` (a camera clock
    /// ahead) gets the medium date. Words come from Foundation in `calendar.locale`,
    /// capitalized as a title.
    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        let dayStart = calendar.startOfDay(for: day)
        let todayStart = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: dayStart, to: todayStart).day ?? .min

        switch daysAgo {
        case 0, 1:
            // The anchored style describes its anchor as seen from the input date.
            var style = Date.AnchoredRelativeFormatStyle(
                anchor: dayStart,
                allowedFields: [.day],
                presentation: .named,
                unitsStyle: .wide,
                capitalizationContext: .beginningOfSentence
            )
            style.calendar = calendar
            if let locale = calendar.locale { style.locale = locale }
            return style.format(todayStart)
        case 2...6:
            return dateStyle(calendar: calendar).weekday(.wide).format(day)
        default:
            return dateStyle(calendar: calendar, date: .abbreviated, time: .omitted).format(day)
        }
    }
}

// MARK: - Styles

extension PickrFormat {
    static let byteStyle = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false)

    static let durationStyle = Duration.UnitsFormatStyle(
        allowedUnits: [.days, .hours, .minutes, .seconds],
        width: .abbreviated,
        maximumUnitCount: 2
    )

    /// Seconds when the span is under a minute, hours and minutes otherwise.
    static func timeSpanStyle(_ start: Date, _ end: Date) -> Date.IntervalFormatStyle {
        Date.IntervalFormatStyle(time: abs(end.timeIntervalSince(start)) < 60 ? .standard : .shortened)
    }

    static func duration(between start: Date, and end: Date) -> Duration {
        .seconds(abs(end.timeIntervalSince(start)))
    }

    /// A date style in the calendar's locale (when it has one) and time zone, capitalized
    /// as a title. With no date or time style it formats only the fields added to it.
    static func dateStyle(
        calendar: Calendar,
        date: Date.FormatStyle.DateStyle? = nil,
        time: Date.FormatStyle.TimeStyle? = nil
    ) -> Date.FormatStyle {
        var style = Date.FormatStyle(date: date, time: time, capitalizationContext: .beginningOfSentence)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if let locale = calendar.locale { style.locale = locale }
        return style
    }
}

// MARK: - Locale-pinned variants for tests

extension PickrFormat {
    static func bytes(_ bytes: Int64, locale: Locale) -> String {
        byteStyle.locale(locale).format(bytes)
    }

    static func timeSpan(_ start: Date, _ end: Date, locale: Locale, timeZone: TimeZone) -> String {
        var style = timeSpanStyle(start, end).locale(locale)
        style.timeZone = timeZone
        return style.format(min(start, end)..<max(start, end))
    }

    static func duration(_ start: Date, _ end: Date, locale: Locale) -> String {
        durationStyle.locale(locale).format(duration(between: start, and: end))
    }
}
