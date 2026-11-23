import Foundation
import PickrCore
import Synchronization

/// A scriptable in-memory `PhotoLibraryClient` for model tests (§4.8).
///
/// It holds a library of visible records plus hidden photos (which exist but are never
/// indexed), answers every client call from that state, and records each call so tests can
/// assert what the models asked for.
///
/// - `indexEvents()` emits `initialEvents` to each new subscriber (by default one complete
///   snapshot of the visible records); `emit(_:)` and `emitSnapshot(isComplete:)` send more.
/// - `refresh()` emits a complete snapshot when `snapshotOnRefresh` is on (the default), and
///   can be held with `holdRefreshes()` to test single-flight behaviour.
/// - `delete(_:)` follows `Deleter`: hidden or missing photos are reported as missing, and
///   nothing found throws `.nothingToDelete`. Scripted outcomes replace the real delete.
///   `holdDeletes()` keeps deletes waiting, as if the system dialog were still up.
public nonisolated final class FakePhotoLibrary: PhotoLibraryClient {
    /// What the next `delete(_:)` does.
    public enum DeleteOutcome: Sendable {
        /// Delete the photos that are visible; report the rest as missing.
        case succeed
        /// Throw this error, for example `.cancelled` for the system dialog's Cancel.
        case fail(LibraryError)
    }

    /// Every call the models made, in order per method.
    public struct Calls: Sendable {
        public var access = 0
        public var requestAccess = 0
        public var indexEvents = 0
        public var refresh = 0
        public var resolveSizes: [[PhotoID]] = []
        public var currentRecords: [[PhotoID]] = []
        public var existingIDs: [[PhotoID]] = []
        public var delete: [[PhotoID]] = []

        /// The number of client calls of any kind.
        public var total: Int {
            access + requestAccess + indexEvents + refresh + resolveSizes.count
                + currentRecords.count + existingIDs.count + delete.count
        }
    }

    private struct State {
        var access: LibraryAccess
        var accessAfterRequest: LibraryAccess
        var records: [PhotoID: AssetRecord]
        var hidden: Set<PhotoID> = []
        var sizes: SizeTable
        var deleteOutcomes: [DeleteOutcome] = []
        var initialEvents: [IndexEvent]?
        var snapshotOnRefresh = true
        var snapshotAfterDelete = false
        var subscribers: [UUID: AsyncStream<IndexEvent>.Continuation] = [:]
        var holdsRefreshes = false
        var heldRefreshes: [CheckedContinuation<Void, Never>] = []
        var holdsDeletes = false
        var heldDeletes: [CheckedContinuation<Void, Never>] = []
        var yieldedEvents = 0
        var calls = Calls()
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - records: the visible library.
    ///   - access: what `access()` returns; `requestAccess()` returns `.full` unless set.
    ///   - sizes: what `resolveSizes(_:)` knows; a missing ID is an unknown size.
    public init(records: [AssetRecord] = [], access: LibraryAccess = .full, sizes: SizeTable = [:]) {
        state = Mutex(State(
            access: access,
            accessAfterRequest: .full,
            records: Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }),
            sizes: sizes
        ))
    }

    deinit {
        let subscribers = state.withLock { Array($0.subscribers.values) }
        for subscriber in subscribers { subscriber.finish() }
    }

    // MARK: - Scripting

    /// The calls made so far.
    public var calls: Calls {
        state.withLock { $0.calls }
    }

    /// The visible records, in capture order.
    public var records: [AssetRecord] {
        state.withLock { Self.ordered($0.records) }
    }

    public func setAccess(_ access: LibraryAccess) {
        state.withLock { $0.access = access }
    }

    /// What `requestAccess()` grants; it also becomes the new `access()`.
    public func setAccessAfterRequest(_ access: LibraryAccess) {
        state.withLock { $0.accessAfterRequest = access }
    }

    /// Adds or replaces visible records. A hidden photo with the same ID becomes visible.
    public func upsert(_ records: [AssetRecord]) {
        state.withLock { state in
            for record in records {
                state.records[record.id] = record
                state.hidden.remove(record.id)
            }
        }
    }

    /// Deletes photos from the library behind the models' back (another device, say).
    public func remove(_ ids: some Sequence<PhotoID>) {
        state.withLock { state in
            for id in ids {
                state.records[id] = nil
                state.hidden.remove(id)
            }
        }
    }

    /// Hides photos: they still exist (`existingIDs`) but leave every snapshot and fetch.
    public func hide(_ ids: some Sequence<PhotoID>) {
        state.withLock { state in
            for id in ids where state.records.removeValue(forKey: id) != nil {
                state.hidden.insert(id)
            }
        }
    }

    /// Adds photos that exist only as hidden photos.
    public func addHidden(_ ids: some Sequence<PhotoID>) {
        state.withLock { $0.hidden.formUnion(ids) }
    }

    /// Changes a photo's favorite flag in the library (not in any snapshot already sent).
    public func setFavorite(_ id: PhotoID, _ isFavorite: Bool) {
        state.withLock { $0.records[id]?.isFavorite = isFavorite }
    }

    public func setSizes(_ sizes: SizeTable) {
        state.withLock { $0.sizes.merge(sizes) { _, new in new } }
    }

    /// Queues outcomes for the next `delete(_:)` calls; once used up, deletes succeed.
    public func enqueueDeleteOutcomes(_ outcomes: DeleteOutcome...) {
        state.withLock { $0.deleteOutcomes += outcomes }
    }

    /// The events each new `indexEvents()` subscriber gets first. `nil` (the default) sends
    /// one complete snapshot of the visible records.
    public func setInitialEvents(_ events: [IndexEvent]?) {
        state.withLock { $0.initialEvents = events }
    }

    /// Whether `refresh()` emits a complete snapshot. On by default.
    public func setSnapshotOnRefresh(_ enabled: Bool) {
        state.withLock { $0.snapshotOnRefresh = enabled }
    }

    /// Whether a successful delete emits a complete snapshot, as PhotoKit's change
    /// notification eventually would. Off by default, so tests see the models' own update.
    public func setSnapshotAfterDelete(_ enabled: Bool) {
        state.withLock { $0.snapshotAfterDelete = enabled }
    }

    /// Sends an event to every subscriber.
    public func emit(_ event: IndexEvent) {
        let subscribers = state.withLock { state in
            state.yieldedEvents += state.subscribers.count
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield(event) }
    }

    /// Events sent so far, counted once per subscriber, so a test can wait until a model has
    /// handled them all.
    public var yieldedEvents: Int {
        state.withLock { $0.yieldedEvents }
    }

    /// Sends a snapshot of the visible records.
    public func emitSnapshot(isComplete: Bool = true) {
        emit(.snapshot(IndexSnapshot(records: records, isComplete: isComplete)))
    }

    /// Makes `refresh()` wait until `releaseRefreshes()`.
    public func holdRefreshes() {
        state.withLock { $0.holdsRefreshes = true }
    }

    /// Lets every held `refresh()` finish, and the following ones run straight through.
    public func releaseRefreshes() {
        let held = state.withLock { state in
            state.holdsRefreshes = false
            defer { state.heldRefreshes = [] }
            return state.heldRefreshes
        }
        for continuation in held { continuation.resume() }
    }

    /// The number of `refresh()` calls waiting in `holdRefreshes()`.
    public var heldRefreshCount: Int {
        state.withLock { $0.heldRefreshes.count }
    }

    /// Makes `delete(_:)` wait, after recording the call, until `releaseDeletes()`: the
    /// system delete dialog is still up.
    public func holdDeletes() {
        state.withLock { $0.holdsDeletes = true }
    }

    /// Lets every held `delete(_:)` go on, and the following ones run straight through.
    public func releaseDeletes() {
        let held = state.withLock { state in
            state.holdsDeletes = false
            defer { state.heldDeletes = [] }
            return state.heldDeletes
        }
        for continuation in held { continuation.resume() }
    }

    /// The number of `delete(_:)` calls waiting in `holdDeletes()`.
    public var heldDeleteCount: Int {
        state.withLock { $0.heldDeletes.count }
    }

    // MARK: - PhotoLibraryClient

    public func access() async -> LibraryAccess {
        state.withLock { state in
            state.calls.access += 1
            return state.access
        }
    }

    public func requestAccess() async -> LibraryAccess {
        state.withLock { state in
            state.calls.requestAccess += 1
            state.access = state.accessAfterRequest
            return state.access
        }
    }

    public func indexEvents() -> AsyncStream<IndexEvent> {
        let (stream, continuation) = AsyncStream<IndexEvent>.makeStream()
        let key = UUID()
        let initial = state.withLock { state in
            state.calls.indexEvents += 1
            state.subscribers[key] = continuation
            let events = state.initialEvents
                ?? [.snapshot(IndexSnapshot(records: Self.ordered(state.records), isComplete: true))]
            state.yieldedEvents += events.count
            return events
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: key) }
        }
        for event in initial { continuation.yield(event) }
        return stream
    }

    public func refresh() async {
        let mustWait = state.withLock { state in
            state.calls.refresh += 1
            return state.holdsRefreshes
        }
        if mustWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    guard state.holdsRefreshes else { return true }
                    state.heldRefreshes.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if state.withLock({ $0.snapshotOnRefresh }) {
            emitSnapshot()
        }
    }

    public func resolveSizes(_ ids: [PhotoID]) async -> SizeTable {
        state.withLock { state in
            state.calls.resolveSizes.append(ids)
            var table = SizeTable()
            for id in ids {
                if let size = state.sizes[id] { table[id] = size }
            }
            return table
        }
    }

    public func currentRecords(_ ids: [PhotoID]) async -> [AssetRecord] {
        state.withLock { state in
            state.calls.currentRecords.append(ids)
            return ids.compactMap { state.records[$0] }
        }
    }

    public func existingIDs(among ids: [PhotoID]) async -> Set<PhotoID> {
        state.withLock { state in
            state.calls.existingIDs.append(ids)
            return Set(ids.filter { state.records[$0] != nil || state.hidden.contains($0) })
        }
    }

    public func delete(_ ids: [PhotoID]) async throws(LibraryError) -> DeletionReceipt {
        let mustWait = state.withLock { state in
            state.calls.delete.append(ids)
            return state.holdsDeletes
        }
        if mustWait {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    guard state.holdsDeletes else { return true }
                    state.heldDeletes.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let result: Result<DeletionReceipt, LibraryError> = state.withLock { state in
            let outcome = state.deleteOutcomes.isEmpty ? .succeed : state.deleteOutcomes.removeFirst()
            switch outcome {
            case let .fail(error):
                return .failure(error)
            case .succeed:
                let found = ids.filter { state.records[$0] != nil }
                guard !found.isEmpty else { return .failure(.nothingToDelete) }
                for id in found { state.records[id] = nil }
                let foundSet = Set(found)
                return .success(DeletionReceipt(deleted: found, missing: ids.filter { !foundSet.contains($0) }))
            }
        }
        let receipt = try result.get()
        if state.withLock({ $0.snapshotAfterDelete }) {
            emitSnapshot()
        }
        return receipt
    }

    private static func ordered(_ records: [PhotoID: AssetRecord]) -> [AssetRecord] {
        records.values.sorted(by: AssetRecord.inCaptureOrder)
    }
}
