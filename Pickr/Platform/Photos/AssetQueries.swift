import Foundation
import Photos
import PickrCore

/// Every PhotoKit asset query the app makes, with every fetch flag set explicitly
/// (blueprint §4.6, ARCH B8/B10). Nothing here touches `PHAssetResource`.
nonisolated enum AssetQueries {
    /// The most identifiers passed to one `fetchAssets(withLocalIdentifiers:)` call.
    static let identifierBatchSize = 500

    // MARK: Fetch options

    /// The whole-library index fetch: images only (the media type is the query), newest
    /// first so the default 30-day range fills in at once, burst representatives only,
    /// the user's own library only, no hidden photos, no change tracking.
    static func indexOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.wantsIncrementalChangeDetails = false
        return options
    }

    /// Re-fetching known photos by identifier with the same visibility rules as the index:
    /// hidden photos and non-representative burst frames are left out.
    static func visibleOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.wantsIncrementalChangeDetails = false
        return options
    }

    /// Existence checks for Kept pruning: as inclusive as possible, so a photo that is
    /// merely hidden, a burst frame or synced is never mistaken for a deleted one.
    static func existenceOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.wantsIncrementalChangeDetails = false
        return options
    }

    // MARK: Fetching

    /// Fetches the assets for `ids`, in batches. Missing identifiers are simply absent.
    static func assets(withIDs ids: some Collection<PhotoID>, options: PHFetchOptions) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        var assets: [PHAsset] = []
        assets.reserveCapacity(ids.count)
        let rawIDs = ids.map(\.rawValue)
        var start = rawIDs.startIndex
        while start < rawIDs.endIndex {
            let end = min(start + identifierBatchSize, rawIDs.endIndex)
            let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(rawIDs[start..<end]), options: options)
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            start = end
        }
        return assets
    }

    /// The index facts for the photos that still exist and are visible, in capture order.
    /// Hidden, missing and non-image assets and assets without a capture date are excluded.
    static func currentRecords(_ ids: some Collection<PhotoID>) -> [AssetRecord] {
        assets(withIDs: ids, options: visibleOptions())
            .compactMap(record(for:))
            .sorted(by: AssetRecord.inCaptureOrder)
    }

    /// The identifiers among `ids` that still exist in the library, hidden photos included.
    static func existingIDs(among ids: some Collection<PhotoID>) -> Set<PhotoID> {
        Set(assets(withIDs: ids, options: existenceOptions()).map { PhotoID($0.localIdentifier) })
    }

    /// `currentRecords(_:)` off the caller's actor.
    @concurrent static func fetchCurrentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        currentRecords(ids)
    }

    /// `existingIDs(among:)` off the caller's actor.
    @concurrent static func fetchExistingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        existingIDs(among: ids)
    }

    // MARK: Records

    /// The index record for an asset, or `nil` when the asset must not be indexed: not an
    /// image, hidden, or without a capture date (§1.5). Reads only cheap metadata.
    static func record(for asset: PHAsset) -> AssetRecord? {
        guard asset.mediaType == .image, !asset.isHidden, let created = asset.creationDate else { return nil }
        return AssetRecord(
            id: PhotoID(asset.localIdentifier),
            created: created,
            modified: asset.modificationDate,
            isFavorite: asset.isFavorite,
            rating: min(max(asset.rating.rawValue, 0), 5)
        )
    }
}
