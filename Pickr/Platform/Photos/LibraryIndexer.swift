import Foundation
import Photos
import PickrCore

/// Owns the persisted whole-library index, the size cache, the persistent-change token and
/// the single-flight refresh (blueprint §4.4, §4.6).
///
/// - **Cold start:** loads `IndexCache` and emits it at once as an incomplete snapshot, so
///   Home appears without a spinner, then refreshes.
/// - **Refresh:** with a token and full access, asks `fetchPersistentChanges(since:)` for
///   what changed and re-fetches only those photos. Without a usable token, after history
///   errors 3105/3210, under limited access, or with no cache, it runs a full build: one
///   newest-first image fetch that reads only cheap metadata, emitting progress every
///   1,000 photos (when there is more than one chunk) and, on a first build, partial
///   snapshots after 2,000 and every 10,000 more.
/// - **Triggers:** the first subscriber, `refresh()` (launch, scene activation, the
///   limited-picker completion) and `LibraryChangeObserver` signals debounced by 300 ms.
///
/// It is the only code that touches `PHAssetResource` (through `AssetSizer`), which is not
/// `Sendable`. Only `Sendable` snapshots leave the actor.
actor LibraryIndexer {
    static let enumerationChunk = 1_000
    static let firstPartialSnapshot = 2_000
    static let partialSnapshotStride = 10_000
    static let changeDebounce: Duration = .milliseconds(300)
    static let cacheWriteDelay: Duration = .seconds(1)

    private let library: PHPhotoLibrary
    private let cache: IndexCache
    private let observer: LibraryChangeObserver

    private var subscribers: [UUID: AsyncStream<IndexEvent>.Continuation] = [:]
    private var lastSnapshot: IndexSnapshot?

    /// Ascending by `(created, id)`.
    private var records: [AssetRecord] = []
    private var sizes: [PhotoID: IndexCache.CachedSize] = [:]
    /// Photos whose size could not be measured during the current refresh pass. Cleared at
    /// every pass, because PhotoKit reports some sizes only once processing finishes.
    private var unknownSizes: Set<PhotoID> = []
    private var token: PHPersistentChangeToken?
    /// The access level `records` were built under; `nil` until something is indexed.
    private var scope: IndexCache.Scope?

    private var isStarted = false
    private var observerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var needsAnotherPass = false

    private var saveTask: Task<Void, Never>?
    private var isWriting = false
    private var needsWrite = false

    init(library: PHPhotoLibrary = .shared(), cache: IndexCache = IndexCache()) {
        self.library = library
        self.cache = cache
        observer = LibraryChangeObserver(library: library)
    }

    deinit {
        observerTask?.cancel()
        refreshTask?.cancel()
        saveTask?.cancel()
    }

    // MARK: Subscriptions

    /// Adds a subscriber. It first receives the latest snapshot, if there is one; the first
    /// subscriber with access granted starts indexing.
    func subscribe(_ id: UUID, _ continuation: AsyncStream<IndexEvent>.Continuation) {
        subscribers[id] = continuation
        if let lastSnapshot {
            continuation.yield(.snapshot(lastSnapshot))
        }
        start()
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Starts indexing once access has been granted. Does not wait for the build.
    func accessDidChange() {
        start()
    }

    // MARK: Refresh

    /// Looks for library changes and waits until the index reflects them. Calls made while
    /// a refresh runs share it and get one more pass after it, so no nudge is lost.
    func refresh() async {
        start()
        guard isStarted else { return }
        await refreshPass().value
    }

    /// Starts once access is granted: registers the change observer, emits the cached
    /// index and kicks off the first refresh.
    private func start() {
        guard !isStarted else { return }
        let access = Self.currentAccess()
        guard let currentScope = IndexCache.Scope(access) else {
            // Access was revoked: drop the photo identifiers kept on disk.
            if access == .denied { cache.remove() }
            return
        }
        isStarted = true
        observer.start()
        let changes = observer.changes
        observerTask = Task.detached(priority: .utility) { [weak self] in
            for await _ in changes {
                try? await Task.sleep(for: LibraryIndexer.changeDebounce)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
        loadCache(scope: currentScope)
        _ = refreshPass()
    }

    private func refreshPass() -> Task<Void, Never> {
        if let refreshTask {
            needsAnotherPass = true
            return refreshTask
        }
        let task = Task { await self.runRefreshPasses() }
        refreshTask = task
        return task
    }

    private func runRefreshPasses() async {
        repeat {
            needsAnotherPass = false
            unknownSizes.removeAll()
            await performRefresh()
        } while needsAnotherPass && !Task.isCancelled
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let currentScope = IndexCache.Scope(Self.currentAccess()) else {
            broadcast(.failed(.notAuthorized))
            return
        }
        if let reason = library.unavailabilityReason {
            // An offline library fetches as empty; never let that replace the index.
            broadcast(.failed(PhotoErrorMapping.libraryError(from: reason)))
            return
        }
        // Limited libraries are small and their selection changes may not show up in the
        // persistent history, so they are always rebuilt (§4.6, verify on device).
        if currentScope == .full, scope == .full, let token {
            do {
                try applyChanges(since: token)
                return
            } catch {
                if !PhotoErrorMapping.requiresFullRebuild(error) {
                    let nsError = error as NSError
                    PhotosLog.logger.error(
                        "Persistent history failed (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)); rebuilding the index"
                    )
                }
            }
        }
        await fullBuild(scope: currentScope)
    }

    // MARK: Full build

    private func fullBuild(scope newScope: IndexCache.Scope) async {
        let signpost = PhotosLog.signposter.beginInterval("Full build")
        defer { PhotosLog.signposter.endInterval("Full build", signpost) }

        // Taken before the fetch, so changes made during the build are replayed next time.
        let startToken = library.currentChangeToken
        let result = PHAsset.fetchAssets(with: .image, options: AssetQueries.indexOptions())
        let total = result.count
        // Partial snapshots only fill an empty screen; they never replace a cached index.
        let emitsPartials = lastSnapshot == nil
        // A build that fits in one chunk (a small limited library rebuilding after every
        // change, for example) is over before progress could be shown.
        let reportsProgress = total > Self.enumerationChunk
        var nextPartial = Self.firstPartialSnapshot
        var newestFirst: [AssetRecord] = []
        newestFirst.reserveCapacity(total)
        if reportsProgress { broadcast(.progress(done: 0, total: total)) }

        var start = 0
        while start < total {
            let end = min(start + Self.enumerationChunk, total)
            var cancelled = false
            result.enumerateObjects(at: IndexSet(integersIn: start..<end), options: []) { asset, _, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                } else if let record = AssetQueries.record(for: asset) {
                    newestFirst.append(record)
                }
            }
            if cancelled { return }
            start = end
            if reportsProgress { broadcast(.progress(done: start, total: total)) }
            if emitsPartials, start >= nextPartial, start < total {
                emit(IndexSnapshot(records: Self.captureOrdered(newestFirst: newestFirst), isComplete: false))
                nextPartial += Self.partialSnapshotStride
            }
            // Lets size requests and new subscribers in between chunks.
            await Task.yield()
        }
        guard !Task.isCancelled else { return }

        let rebuilt = Self.captureOrdered(newestFirst: newestFirst)
        // A rebuild that finds the index unchanged causes no regroup.
        let changesIndex = rebuilt != records || lastSnapshot?.isComplete != true
        records = rebuilt
        var validSizes: [PhotoID: IndexCache.CachedSize] = [:]
        validSizes.reserveCapacity(min(sizes.count, records.count))
        for record in records {
            if let size = sizes[record.id], size.modified == record.modified {
                validSizes[record.id] = size
            }
        }
        sizes = validSizes
        token = startToken
        scope = newScope
        if changesIndex { emitSnapshot(isComplete: true) }
        scheduleCacheWrite(after: .zero)
    }

    // MARK: Delta

    /// Applies the persistent changes since `token`. Throws before changing any state.
    private func applyChanges(since token: PHPersistentChangeToken) throws {
        let signpost = PhotosLog.signposter.beginInterval("Index delta")
        defer { PhotosLog.signposter.endInterval("Index delta", signpost) }

        var touched = Set<String>()
        var reportedDeleted = Set<String>()
        var latestToken: PHPersistentChangeToken?
        for change in try library.fetchPersistentChanges(since: token) {
            let details = try change.changeDetails(for: .asset)
            touched.formUnion(details.insertedLocalIdentifiers)
            touched.formUnion(details.updatedLocalIdentifiers)
            reportedDeleted.formUnion(details.deletedLocalIdentifiers)
            latestToken = change.changeToken
        }
        guard let latestToken else {
            // Nothing changed. The cached snapshot is now known to be current.
            if lastSnapshot?.isComplete != true { emitSnapshot(isComplete: true) }
            return
        }

        // Every touched or deleted photo is re-fetched: whatever comes back visible is
        // upserted, everything else (deleted, hidden, no longer an image) leaves the index.
        // This also gets a delete followed by a restore right.
        let candidates = Set(touched.union(reportedDeleted).map(PhotoID.init))
        let visible = AssetQueries.currentRecords(candidates)
        let visibleIDs = Set(visible.map(\.id))
        let removed = candidates.subtracting(visibleIDs)
        let delta = effectiveDelta(upserted: visible, removed: removed)

        // Kept pruning trusts these, so a deletion is confirmed only when the photo is gone
        // even counting hidden photos (§2.5 rail 6).
        let deletedCandidates = Set(reportedDeleted.map(PhotoID.init)).subtracting(visibleIDs)
        let confirmedDeleted = deletedCandidates.isEmpty
            ? []
            : deletedCandidates.subtracting(AssetQueries.existingIDs(among: deletedCandidates))

        self.token = latestToken
        let changesIndex = !delta.upserted.isEmpty || !delta.deleted.isEmpty
        if changesIndex {
            records = IndexMath.apply(delta, to: records)
            for id in delta.deleted { sizes[id] = nil }
            for record in delta.upserted where sizes[record.id]?.modified != record.modified {
                sizes[record.id] = nil
            }
        }
        if !confirmedDeleted.isEmpty {
            broadcast(.confirmedDeleted(confirmedDeleted))
        }
        if changesIndex || lastSnapshot?.isComplete != true {
            emitSnapshot(isComplete: true)
        }
        scheduleCacheWrite()
    }

    /// Drops upserts that change nothing and deletions of photos that were never indexed,
    /// so unrelated library changes (album edits, for example) cause no regroup.
    private func effectiveDelta(upserted: [AssetRecord], removed: Set<PhotoID>) -> IndexDelta {
        let relevant = removed.union(upserted.map(\.id))
        guard !relevant.isEmpty else { return IndexDelta() }
        var existing: [PhotoID: AssetRecord] = [:]
        for record in records where relevant.contains(record.id) {
            existing[record.id] = record
        }
        return IndexDelta(
            upserted: upserted.filter { existing[$0.id] != $0 },
            deleted: removed.filter { existing[$0] != nil }
        )
    }

    // MARK: Sizes

    /// Library storage for each photo, measured once per `(id, modified)` and cached.
    /// Unknown sizes are left out. Stops early, with what it has, when the calling task is
    /// cancelled.
    func sizes(for ids: [PhotoID]) -> SizeTable {
        var table: SizeTable = [:]
        var misses: [PhotoID] = []
        for id in ids {
            if let size = sizes[id] {
                table[id] = size.bytes
            } else if !unknownSizes.contains(id) {
                misses.append(id)
            }
        }
        guard !misses.isEmpty, !Task.isCancelled else { return table }

        let signpost = PhotosLog.signposter.beginInterval("Size batch")
        defer { PhotosLog.signposter.endInterval("Size batch", signpost) }

        var measured = Set<PhotoID>()
        var learnedAny = false
        for asset in AssetQueries.assets(withIDs: Set(misses), options: AssetQueries.visibleOptions()) {
            guard !Task.isCancelled else { break }
            let id = PhotoID(asset.localIdentifier)
            measured.insert(id)
            if let bytes = AssetSizer.bytes(of: asset) {
                sizes[id] = IndexCache.CachedSize(bytes: bytes, modified: asset.modificationDate)
                table[id] = bytes
                learnedAny = true
            } else {
                unknownSizes.insert(id)
            }
        }
        if !Task.isCancelled {
            // Missing photos have no size until the next pass either.
            unknownSizes.formUnion(misses.filter { !measured.contains($0) })
        }
        if learnedAny { scheduleCacheWrite() }
        return table
    }

    // MARK: Events

    private func emitSnapshot(isComplete: Bool) {
        emit(IndexSnapshot(records: records, isComplete: isComplete))
    }

    private func emit(_ snapshot: IndexSnapshot) {
        lastSnapshot = snapshot
        broadcast(.snapshot(snapshot))
    }

    private func broadcast(_ event: IndexEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    // MARK: Cache

    private func loadCache(scope currentScope: IndexCache.Scope) {
        let signpost = PhotosLog.signposter.beginInterval("Load index cache")
        defer { PhotosLog.signposter.endInterval("Load index cache", signpost) }

        guard let contents = cache.load() else { return }
        guard contents.scope == currentScope else {
            cache.remove()
            return
        }
        records = contents.records
        sizes = contents.sizes
        token = contents.token.flatMap(IndexCache.unarchiveToken(from:))
        scope = contents.scope
        emitSnapshot(isComplete: false)
    }

    /// Writes the cache after `delay`, coalescing the requests that arrive meanwhile. A
    /// pending write keeps the indexer alive until it has run.
    private func scheduleCacheWrite(after delay: Duration = LibraryIndexer.cacheWriteDelay) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.writeCache()
        }
    }

    /// One writer at a time; a request that arrives during a write gets one more write.
    private func writeCache() async {
        guard !isWriting else {
            needsWrite = true
            return
        }
        isWriting = true
        defer { isWriting = false }
        repeat {
            needsWrite = false
            guard let scope else { return }
            let contents = IndexCache.Contents(
                scope: scope,
                records: records,
                sizes: sizes,
                token: token.flatMap(IndexCache.archive)
            )
            await Self.write(contents, to: cache)
        } while needsWrite
    }

    @concurrent private static func write(_ contents: IndexCache.Contents, to cache: IndexCache) async {
        let signpost = PhotosLog.signposter.beginInterval("Write index cache")
        defer { PhotosLog.signposter.endInterval("Write index cache", signpost) }
        do {
            try cache.save(contents)
        } catch {
            let nsError = error as NSError
            PhotosLog.logger.error(
                "Saving the index cache failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)"
            )
        }
    }

    // MARK: Helpers

    static func currentAccess() -> LibraryAccess {
        LivePhotoLibrary.access(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Records collected newest first (the fetch order), in capture order. The reversal is
    /// almost sorted already; only photos sharing a capture time need reordering.
    static func captureOrdered(newestFirst records: [AssetRecord]) -> [AssetRecord] {
        var ordered = Array(records.reversed())
        if zip(ordered, ordered.dropFirst()).contains(where: { AssetRecord.inCaptureOrder($1, $0) }) {
            ordered.sort(by: AssetRecord.inCaptureOrder)
        }
        return ordered
    }
}
