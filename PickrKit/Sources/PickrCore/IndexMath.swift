import Foundation

/// An incremental change to the library index.
public struct IndexDelta: Sendable {
    /// Inserted or updated records.
    public var upserted: [AssetRecord]
    public var deleted: Set<PhotoID>

    public init(upserted: [AssetRecord] = [], deleted: Set<PhotoID> = []) {
        self.upserted = upserted
        self.deleted = deleted
    }
}

public enum IndexMath {
    /// Applies the delta. The result stays sorted by `(created, id)`.
    ///
    /// - An upserted record replaces any record with the same ID, wherever it sat, so a
    ///   changed capture date moves the photo to its new place.
    /// - When the delta upserts one ID twice, the later record wins.
    /// - An ID that is both upserted and deleted ends up deleted: a stale upsert must never
    ///   bring back a photo the library reported gone.
    /// - Each ID appears at most once in the result, given an index without duplicates.
    /// - O(n + k log k) for an index of n records and k upserts. An index that is not in
    ///   capture order (the indexer never produces one) is sorted first.
    public static func apply(_ d: IndexDelta, to index: [AssetRecord]) -> [AssetRecord] {
        // Last write wins among duplicate upserts; deletions win over upserts.
        var latest: [PhotoID: AssetRecord] = [:]
        latest.reserveCapacity(d.upserted.count)
        for record in d.upserted where !d.deleted.contains(record.id) {
            latest[record.id] = record
        }
        let incoming = latest.values.sorted(by: AssetRecord.inCaptureOrder)

        var remaining = index
        if !d.deleted.isEmpty || !latest.isEmpty {
            let removed = d.deleted.union(latest.keys)
            remaining.removeAll { removed.contains($0.id) }
        }
        if !Clusterer.isInCaptureOrder(remaining) {
            remaining.sort(by: AssetRecord.inCaptureOrder)
        }
        return merge(remaining, incoming)
    }

    /// Merges two arrays that are each in capture order into one in capture order.
    private static func merge(_ lhs: [AssetRecord], _ rhs: [AssetRecord]) -> [AssetRecord] {
        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }
        var result: [AssetRecord] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = lhs.startIndex
        var j = rhs.startIndex
        while i < lhs.endIndex, j < rhs.endIndex {
            if AssetRecord.inCaptureOrder(rhs[j], lhs[i]) {
                result.append(rhs[j])
                j += 1
            } else {
                result.append(lhs[i])
                i += 1
            }
        }
        result.append(contentsOf: lhs[i...])
        result.append(contentsOf: rhs[j...])
        return result
    }
}
