import Foundation
@testable import PickrCore

/// Builders shared by the PickrCore suites.
enum Make {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A record `seconds` after `epoch`, with the ID `p-<seconds>` unless one is given.
    static func record(
        _ seconds: TimeInterval,
        id: String? = nil,
        favorite: Bool = false,
        rating: Int = 0
    ) -> AssetRecord {
        AssetRecord(
            id: PhotoID(id ?? "p-\(Int(seconds))"),
            created: epoch.addingTimeInterval(seconds),
            isFavorite: favorite,
            rating: rating
        )
    }

    static func ids(_ raw: String...) -> [PhotoID] {
        raw.map(PhotoID.init)
    }

    /// A Gregorian calendar pinned to a time zone and, optionally, a locale.
    static func calendar(_ timeZone: String, locale: String? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        if let locale { calendar.locale = Locale(identifier: locale) }
        return calendar
    }

    /// A wall-clock date in `calendar`'s time zone.
    static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}

extension String {
    /// Replaces the no-break and thin spaces ICU puts in formatted output with plain spaces,
    /// so assertions don't depend on which space a given ICU version picks.
    var plainSpaces: String {
        String(map { "\u{00A0}\u{202F}\u{2009}".contains($0) ? " " : $0 })
    }
}

extension Array where Element == Moment {
    /// Moment sizes in capture order (the Clusterer returns newest first).
    var sizesInCaptureOrder: [Int] { reversed().map(\.count) }
}
