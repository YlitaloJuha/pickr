import Foundation
import Photos
import PickrCore

/// The library storage a photo takes, from the public `PHAssetResource.dataSize` (iOS 27,
/// `PHAssetResource.h:49`), summed over every resource of the asset (blueprint §4.6, C9).
///
/// Every resource counts, because deleting the photo frees all of them: the original, a
/// RAW alternate, the paired Live Photo video, edited renders and adjustment data.
///
/// On "Optimize iPhone Storage" devices this is library storage, so the space freed on the
/// device itself can be smaller.
///
/// `PHAssetResource` is not `Sendable`: only `LibraryIndexer` calls `bytes(of:)`, inside
/// its own isolation.
nonisolated enum AssetSizer {
    /// The summed size of every resource of `asset`, or `nil` when no resource reports a
    /// size (the size is unknown, which is not the same as zero).
    static func bytes(of asset: PHAsset) -> Int64? {
        total(ofResourceSizes: PHAssetResource.assetResources(for: asset).map(\.dataSize))
    }

    /// The sum of the known sizes, or `nil` when there are none. Unknown sizes are skipped,
    /// so a partly known asset reports a lower bound.
    static func total(ofResourceSizes sizes: some Sequence<Int?>) -> Int64? {
        var total: Int64 = 0
        var knowsAny = false
        for case let size? in sizes where size >= 0 {
            total += Int64(size)
            knowsAny = true
        }
        return knowsAny ? total : nil
    }
}
