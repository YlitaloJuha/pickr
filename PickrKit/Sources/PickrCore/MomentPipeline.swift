import Foundation

/// Turns the library index into the Moments list. Pure, so it can run off the main actor
/// (`LibraryModel.computeMoments`) and regroup instantly when the settings change.
public enum MomentPipeline {
    /// (index ∩ range) − kept → Clusterer → order (.newest = Clusterer order; .mostSpace = savings desc, unknown last).
    ///
    /// - The range comes from `grouping.range.interval(now:calendar:)`; both ends are inclusive.
    /// - Kept photos are removed *before* grouping, so they never resurface and never bridge
    ///   two moments.
    /// - `.mostSpace` sorts by the keep-one estimate, largest first. A moment whose estimate
    ///   is unknown (approximate and zero, because fewer than two of its sizes are known)
    ///   goes last. Ties keep the newest-first order.
    /// - `MomentList.savings` is the sum of the keep-one estimates.
    public static func build(
        index: [AssetRecord],
        grouping: GroupingSettings,
        kept: Set<PhotoID>,
        sizes: SizeTable,
        now: Date,
        calendar: Calendar
    ) -> MomentList {
        let interval = grouping.range.interval(now: now, calendar: calendar)
        let candidates = index.filter { record in
            !kept.contains(record.id) && (interval?.contains(record.created) ?? true)
        }
        let newestFirst = Clusterer.moments(from: candidates, window: grouping.window)
        guard !newestFirst.isEmpty else { return .empty }

        let estimates = newestFirst.map { Savings.keepOneEstimate(for: $0, sizes: sizes) }
        let moments: [Moment]
        switch grouping.order {
        case .newest:
            moments = newestFirst
        case .mostSpace:
            moments = zip(newestFirst, estimates).enumerated()
                .sorted { lhs, rhs in
                    let (left, right) = (lhs.element.1, rhs.element.1)
                    if isUnknown(left) != isUnknown(right) { return isUnknown(right) }
                    if left.bytes != right.bytes { return left.bytes > right.bytes }
                    return lhs.offset < rhs.offset
                }
                .map(\.element.0)
        }
        return MomentList(moments: moments, savings: Savings.sum(estimates))
    }

    /// No usable figure: nothing known beyond, at most, the photo the user would keep.
    private static func isUnknown(_ estimate: ByteEstimate) -> Bool {
        estimate.isApproximate && estimate.bytes == 0
    }
}
