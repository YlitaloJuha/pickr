import Foundation

/// Space-to-free arithmetic over a `SizeTable` (§1.5 "Savings shown").
///
/// A photo missing from the table has an unknown size. It adds nothing to a figure but
/// makes it approximate, so the UI shows "about …". An approximate figure is always a
/// lower bound of the true one.
public enum Savings {
    /// The optimistic keep-one estimate: total minus the largest known size.
    ///
    /// Shown on moment cards and in subtitles: it assumes the user keeps the biggest photo
    /// and deletes the rest (v1 `PhotoCluster.reclaimableBytesIfKeepOne`). Approximate when
    /// any photo's size is unknown; with no known size at all it is zero, approximate.
    public static func keepOneEstimate(for m: Moment, sizes: SizeTable) -> ByteEstimate {
        var total: Int64 = 0
        var largest: Int64 = 0
        var hasUnknown = false
        for id in m.photoIDs {
            guard let size = sizes[id] else {
                hasUnknown = true
                continue
            }
            total += size
            largest = max(largest, size)
        }
        return ByteEstimate(bytes: total - largest, isApproximate: hasUnknown)
    }

    /// The sum of the known sizes; approximate when any size is unknown.
    ///
    /// Used for the commit button (the exact photos to delete) and for stats. An empty
    /// sequence is exactly zero.
    public static func total(of ids: some Sequence<PhotoID>, sizes: SizeTable) -> ByteEstimate {
        var total: Int64 = 0
        var hasUnknown = false
        for id in ids {
            if let size = sizes[id] {
                total += size
            } else {
                hasUnknown = true
            }
        }
        return ByteEstimate(bytes: total, isApproximate: hasUnknown)
    }

    /// Adds estimates; the sum is approximate when any part is.
    static func sum(_ estimates: some Sequence<ByteEstimate>) -> ByteEstimate {
        estimates.reduce(.zero) { partial, next in
            ByteEstimate(bytes: partial.bytes + next.bytes, isApproximate: partial.isApproximate || next.isApproximate)
        }
    }
}
