import Foundation

/// Photo count in one calendar bucket of the custom-range chart.
public struct DensityBucket: Hashable, Sendable, Identifiable {
    public var id: Date { start }
    /// The first instant of the month or year.
    public let start: Date
    /// The first instant of the next month or year (exclusive).
    public let end: Date
    public let count: Int

    public init(start: Date, end: Date, count: Int) {
        self.start = start
        self.end = end
        self.count = count
    }
}

/// Buckets capture dates for the custom-range chart (§3.3 S7), from the in-memory index.
public enum DensityHistogram {
    /// Monthly buckets when the span is under 3 years, otherwise yearly.
    ///
    /// - The span is the number of whole calendar years from the earliest to the latest
    ///   date (v1 `DensityPlotViewModel.swift:61-73`): 3 or more gives yearly buckets.
    /// - Buckets are contiguous and ascending, from the earliest date's month (or year) to
    ///   the latest date's, and include empty ones with a count of 0, so a date axis and a
    ///   range selection see no gaps. (v1 omitted empty months.)
    /// - Month and year boundaries follow `calendar`, including its time zone.
    /// - `dates` may be in any order. No dates give no buckets.
    public static func buckets(dates: [Date], calendar: Calendar) -> [DensityBucket] {
        guard let earliest = dates.min(), let latest = dates.max() else { return [] }
        let years = calendar.dateComponents([.year], from: earliest, to: latest).year ?? 0
        let unit: Calendar.Component = years >= 3 ? .year : .month

        // Bucket boundaries: the start of every bucket plus the end of the last one.
        guard var cursor = calendar.dateInterval(of: unit, for: earliest)?.start else { return [] }
        var boundaries: [Date] = []
        while cursor <= latest {
            boundaries.append(cursor)
            guard let next = calendar.dateInterval(of: unit, for: cursor)?.end, next > cursor else { return [] }
            cursor = next
        }
        boundaries.append(cursor)

        // Binary search over the few boundaries is far cheaper than calendar arithmetic
        // per date, which matters for a 50k-photo index.
        var counts = [Int](repeating: 0, count: boundaries.count - 1)
        for date in dates {
            counts[bucketIndex(of: date, in: boundaries)] += 1
        }
        return counts.indices.map { index in
            DensityBucket(start: boundaries[index], end: boundaries[index + 1], count: counts[index])
        }
    }

    /// The index `i` with `boundaries[i] <= date < boundaries[i + 1]`, for a date inside the
    /// boundaries' overall range.
    private static func bucketIndex(of date: Date, in boundaries: [Date]) -> Int {
        var low = 0
        var high = boundaries.count - 1 // `boundaries[high]` is always after `date`.
        while high - low > 1 {
            let middle = (low + high) / 2
            if boundaries[middle] <= date {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}
