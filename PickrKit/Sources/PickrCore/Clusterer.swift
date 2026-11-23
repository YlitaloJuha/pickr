import Foundation

/// Groups photos into moments by capture time (§1.5, DNA §5.2).
public enum Clusterer {
    /// DNA (v1 ClusterService.swift:11-43): sort ascending by (created, id); chain while gap <= window (inclusive);
    /// drop groups smaller than minimumCount; order by end descending, ties by anchor.
    ///
    /// - A photo joins the current moment when its gap to the *previous* photo is at most
    ///   `window`: the chain follows the previous photo and is not anchored to the first.
    /// - Photos inside a moment stay in ascending capture order.
    /// - A `minimumCount` below 1 counts as 1. The Moments list uses 2; Kept uses 1 so
    ///   single photos appear too.
    /// - O(n) when `records` is already in capture order (the library index always is),
    ///   otherwise O(n log n).
    public static func moments(from records: [AssetRecord], window: TimeWindow, minimumCount: Int = 2) -> [Moment] {
        guard !records.isEmpty else { return [] }
        let minimum = max(minimumCount, 1)
        let sorted = isInCaptureOrder(records) ? records : records.sorted(by: AssetRecord.inCaptureOrder)
        let limit = window.interval

        var moments: [Moment] = []
        var runStart = sorted.startIndex
        for index in sorted.indices.dropFirst()
        where sorted[index].created.timeIntervalSince(sorted[index - 1].created) > limit {
            appendRun(sorted[runStart..<index], minimum: minimum, to: &moments)
            runStart = index
        }
        appendRun(sorted[runStart...], minimum: minimum, to: &moments)

        // Runs come out in ascending time order, and consecutive runs are more than
        // `window` (at least 10 s) apart, so each run ends strictly later than the one
        // before. Reversing therefore gives "end descending" with no ties left to break.
        moments.reverse()
        return moments
    }

    private static func appendRun(_ run: ArraySlice<AssetRecord>, minimum: Int, to moments: inout [Moment]) {
        guard run.count >= minimum else { return }
        moments.append(Moment(photos: Array(run)))
    }

    /// Whether `records` is ascending by `(created, id)`. Equal neighbours count as ordered.
    static func isInCaptureOrder(_ records: [AssetRecord]) -> Bool {
        zip(records, records.dropFirst()).allSatisfy { !AssetRecord.inCaptureOrder($1, $0) }
    }
}
