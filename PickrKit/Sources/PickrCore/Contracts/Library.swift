import Foundation

/// Photos authorization as the app sees it. `.restricted` maps to `.denied`.
public enum LibraryAccess: Hashable, Sendable {
    case notDetermined, full, limited, denied
}

/// Every failure the photo library can report, mapped from PhotoKit and Cocoa errors.
public enum LibraryError: Error, Hashable, Sendable {
    /// The user cancelled the system dialog. Callers stay silent.
    case cancelled
    case notAuthorized
    /// The library is offline or switching.
    case unavailable
    /// An iCloud download failed.
    case network
    /// Too many items in one request.
    case limitExceeded
    /// None of the requested photos exist any more.
    case nothingToDelete
    case failed(domain: String, code: Int)
}

/// The whole index at one point in time.
public struct IndexSnapshot: Sendable {
    /// Ascending by `(created, id)`.
    public let records: [AssetRecord]
    /// `false` for the cached snapshot at launch and the partial snapshots of a full build.
    public let isComplete: Bool

    public init(records: [AssetRecord], isComplete: Bool) {
        self.records = records
        self.isComplete = isComplete
    }
}

/// What the library index reports over time.
public enum IndexEvent: Sendable {
    case snapshot(IndexSnapshot)
    case progress(done: Int, total: Int)
    /// Photos known to be deleted from the library (persistent history); prunes Kept.
    case confirmedDeleted(Set<PhotoID>)
    case failed(LibraryError)
}

/// What one delete request actually did.
public struct DeletionReceipt: Hashable, Sendable {
    /// Moved to Recently Deleted.
    public let deleted: [PhotoID]
    /// Requested but already gone or hidden, so not deleted.
    public let missing: [PhotoID]

    public init(deleted: [PhotoID], missing: [PhotoID]) {
        self.deleted = deleted
        self.missing = missing
    }
}

/// The app's only door to the photo library. The live implementation wraps PhotoKit;
/// tests use `FakePhotoLibrary`.
public protocol PhotoLibraryClient: Sendable {
    func access() async -> LibraryAccess
    func requestAccess() async -> LibraryAccess
    /// Long-lived. Emits the cached snapshot first (if any), then progress, then a complete snapshot;
    /// afterwards a fresh snapshot after every library change.
    func indexEvents() -> AsyncStream<IndexEvent>
    /// A single-flight nudge to look for library changes.
    func refresh() async
    /// Library storage for each photo. Unknown sizes are left out.
    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable
    /// Re-fetches the photos now. Hidden and missing photos are excluded.
    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord]
    /// The IDs that still exist, hidden photos INCLUDED (prune safety).
    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID>
    /// Deletes through PhotoKit, which shows the system confirmation. Deleted photos go to
    /// Recently Deleted. Throws `.cancelled` when the user cancels.
    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt
}
