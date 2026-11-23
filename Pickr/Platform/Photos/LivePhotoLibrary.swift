import Foundation
import Photos
import PickrCore

/// The live `PhotoLibraryClient` over PhotoKit (blueprint §4.6).
///
/// It composes the pieces of the adapter: `LibraryIndexer` for the index, change history
/// and sizes, `AssetQueries` for re-fetches, and `Deleter` for the one deletion path.
/// Heavy work never runs on the caller's actor: the indexer is its own actor, and the
/// re-fetches and the delete are `@concurrent`.
nonisolated final class LivePhotoLibrary: PhotoLibraryClient {
    private let library: PHPhotoLibrary
    private let indexer: LibraryIndexer

    /// - Parameters:
    ///   - library: the photo library; tests keep the shared one.
    ///   - cache: where the index cache lives (`Library/Caches/Pickr/index.v1.plist`).
    init(library: PHPhotoLibrary = .shared(), cache: IndexCache = IndexCache()) {
        #if DEBUG
        precondition(!DemoMode.isActive, "Demo mode never creates the PhotoKit client")
        #endif
        self.library = library
        indexer = LibraryIndexer(library: library, cache: cache)
    }

    /// Read-write authorization as the app sees it. `.restricted` maps to `.denied`.
    static func access(from status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .full
        case .limited: .limited
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    // MARK: PhotoLibraryClient

    func access() async -> LibraryAccess {
        LibraryIndexer.currentAccess()
    }

    /// Shows the system prompt when access is not determined yet; otherwise returns the
    /// current access at once. Granting access starts indexing.
    func requestAccess() async -> LibraryAccess {
        let access = Self.access(from: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
        if access == .full || access == .limited {
            await indexer.accessDidChange()
        }
        return access
    }

    /// Long-lived: the cached snapshot first (if any), then progress, then a complete
    /// snapshot, and afterwards a fresh snapshot after every library change. Each call
    /// gets its own stream; ending it unsubscribes.
    func indexEvents() -> AsyncStream<IndexEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: IndexEvent.self)
        let id = UUID()
        let indexer = indexer
        let subscription = Task { await indexer.subscribe(id, continuation) }
        continuation.onTermination = { _ in
            Task {
                await subscription.value
                await indexer.unsubscribe(id)
            }
        }
        return stream
    }

    func refresh() async {
        await indexer.refresh()
    }

    func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        guard !ids.isEmpty else { return [:] }
        return await indexer.sizes(for: ids)
    }

    func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        guard !ids.isEmpty else { return [] }
        return await AssetQueries.fetchCurrentRecords(ids)
    }

    /// Hidden photos count as existing. Without full access nothing can be confirmed gone
    /// (a limited library shows only its selection), so every ID is reported as existing.
    func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        guard !ids.isEmpty else { return [] }
        guard LibraryIndexer.currentAccess() == .full else { return Set(ids) }
        return await AssetQueries.fetchExistingIDs(among: ids)
    }

    func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt {
        switch LibraryIndexer.currentAccess() {
        case .full, .limited:
            return try await Deleter.delete(ids, in: library)
        case .notDetermined, .denied:
            throw .notAuthorized
        }
    }
}
