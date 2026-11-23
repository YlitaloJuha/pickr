import Foundation
import Photos
import PickrCore

/// The app's only deletion call site (blueprint §1.3 promise 3, §4.6; policy check 3).
///
/// Deleting goes through `PHAssetChangeRequest.deleteAssets` inside `performChanges`, so
/// iOS always shows its own confirmation and the photos move to Recently Deleted for 30
/// days. One commit is one request, so the user sees one system dialog.
nonisolated enum Deleter {
    /// Deletes the photos that still exist and are visible.
    ///
    /// 1. Re-fetches `ids` with hidden photos excluded (§2.5 rail 2): photos deleted
    ///    elsewhere, hidden since indexing or no longer images are not deleted.
    /// 2. Throws `.nothingToDelete` when none is left.
    /// 3. Deletes the rest in one `performChanges` request.
    /// 4. Reports what was deleted and what was missing.
    ///
    /// Runs off the caller's actor. A cancel in the system dialog throws `.cancelled`, which
    /// callers keep silent; every other failure is mapped by `PhotoErrorMapping`.
    @concurrent static func delete(
        _ ids: [PhotoID],
        in library: PHPhotoLibrary = .shared()
    ) async throws(LibraryError) -> DeletionReceipt {
        #if DEBUG
        try refuseInDemoMode(DemoMode.isActive)
        #endif
        var seen = Set<PhotoID>()
        let requested = ids.filter { seen.insert($0).inserted }
        guard !requested.isEmpty else { throw .nothingToDelete }

        let assets = AssetQueries.assets(withIDs: requested, options: AssetQueries.visibleOptions())
            .filter { $0.mediaType == .image && !$0.isHidden }
        let found = Set(assets.map { PhotoID($0.localIdentifier) })
        guard !found.isEmpty else { throw .nothingToDelete }

        do {
            try await library.performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            let mapped = PhotoErrorMapping.libraryError(from: error)
            if mapped != .cancelled {
                let nsError = error as NSError
                PhotosLog.logger.error(
                    "Deleting \(assets.count, privacy: .public) photos failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
                )
            }
            throw mapped
        }

        return DeletionReceipt(
            deleted: requested.filter(found.contains),
            missing: requested.filter { !found.contains($0) }
        )
    }

    #if DEBUG
    /// The second guard for demo mode, which records the README demos on a real device: demo
    /// mode never creates the live client, and even so a delete stops here, before PhotoKit
    /// is asked for anything (policy check 22c keeps this call first).
    static func refuseInDemoMode(_ isDemoMode: Bool) throws(LibraryError) {
        guard isDemoMode else { return }
        PhotosLog.logger.error("Refused to delete photos in demo mode")
        throw .failed(domain: "PickrDemo", code: 1)
    }
    #endif
}
