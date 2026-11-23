import Foundation
import Observation
import os
import PickrCore

/// Where loading the library stands.
public nonisolated enum LoadPhase: Equatable, Sendable {
    case idle
    case indexing(done: Int, total: Int)
    case ready
    case failed(LibraryError)
}

/// Access, the index, sizes and the current moments.
///
/// - `access` and `phase` are independent (fixes [ARCH A1]): limited access stays
///   `.limited` whatever the phase.
/// - `phase` is `.indexing` only while there is no data yet. A refresh over data already on
///   screen keeps `.ready` and sets `isRefreshing` ("Updating…").
/// - The Moments list is a pure function of (index ∩ range) − kept, recomputed off the main
///   actor by `regroup()` whenever an input changes. A generation counter drops results
///   computed from old inputs (fixes [ARCH A8]).
/// - Sizes are asked for only for photos in moments, newest moments first, 200 at a time.
@Observable public final class LibraryModel {
    public private(set) var access: LibraryAccess = .notDetermined
    public private(set) var phase: LoadPhase = .idle
    /// The whole library, ascending by `(created, id)`.
    public private(set) var index: [AssetRecord] = []
    public private(set) var sizes: SizeTable = [:]
    public private(set) var moments: MomentList = .empty
    public private(set) var isRefreshing = false

    /// `true` when the Moments tab shows its list: access is full or limited, the library
    /// is ready and at least one moment is listed. Every other state (primer, denied,
    /// indexing, failed, All clean) is one full-width column, so a column container splits
    /// only while this is `true` (ADAPTIVE §3.2).
    public var showsMomentList: Bool {
        access.allowsReading && phase == .ready && !moments.moments.isEmpty
    }

    // MARK: Dependencies and test seams

    @ObservationIgnored private let client: any PhotoLibraryClient
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let kept: KeptModel
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored var calendar: Calendar
    /// Computes the Moments list; tests replace it to control timing.
    @ObservationIgnored var computeMoments: MomentComputer = LibraryModel.computeMoments
    /// The throttle between a size batch and the regroup it causes (§4.4).
    @ObservationIgnored var sizeRegroupDelay: Duration = .milliseconds(500)
    /// Prunes Kept through `Curator`, the only path that changes Kept.
    @ObservationIgnored weak var keptMaintenance: (any KeptMaintenance)?
    /// Runs after every change to `moments`; `AppServices` revalidates the review session.
    @ObservationIgnored var onMomentsChange: (() -> Void)?

    // MARK: Internal state

    /// Bumped by every regroup request; a result is applied only if it is still current.
    @ObservationIgnored private(set) var generation = 0
    /// The number of regroup results applied so far (for tests).
    @ObservationIgnored private(set) var appliedRegroups = 0
    /// The number of regroup results dropped by the generation guard (for tests).
    @ObservationIgnored private(set) var droppedRegroups = 0
    /// The number of index events handled so far (for tests).
    @ObservationIgnored private(set) var handledEvents = 0
    @ObservationIgnored private var regroupScheduled = false
    @ObservationIgnored private var regroupTask: Task<Void, Never>?
    /// The index is in but its moments aren't grouped yet: `phase` turns `.ready` only once the
    /// regroup lands, so the list never shows "All clean" for an instant before its moments.
    @ObservationIgnored private var readyAfterRegroup = false
    @ObservationIgnored private var lookup = MomentLookup.empty

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    /// The client is still working toward a complete snapshot.
    @ObservationIgnored private var indexBusy = false

    /// Photos deleted through Pickr that the index may not reflect yet. A snapshot can't
    /// bring them back until a complete snapshot without them confirms the deletion.
    @ObservationIgnored private var tombstones: Set<PhotoID> = []

    @ObservationIgnored private var sizeQueue: [SizeRequest] = []
    @ObservationIgnored private var sizeCursor = 0
    /// Every ID asked for, with the modification date it had then. A changed date asks again.
    @ObservationIgnored private var sizeRequested: [PhotoID: Date?] = [:]
    @ObservationIgnored private var sizingTask: Task<Void, Never>?
    @ObservationIgnored private var sizeRegroupTask: Task<Void, Never>?

    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var prunePending = false

    private static let log = Logger(subsystem: "com.juha.Culler", category: "Library")
    /// Marks each regroup for Instruments (blueprint §6.4). Local only.
    private nonisolated static let signposter = OSSignposter(subsystem: "com.juha.Culler", category: "Library")

    init(
        client: any PhotoLibraryClient,
        settings: SettingsModel,
        kept: KeptModel,
        now: @escaping @Sendable () -> Date,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.client = client
        self.settings = settings
        self.kept = kept
        self.now = now
        self.calendar = calendar
    }

    isolated deinit {
        indexTask?.cancel()
        refreshTask?.cancel()
        regroupTask?.cancel()
        sizingTask?.cancel()
        sizeRegroupTask?.cancel()
        pruneTask?.cancel()
    }

    // MARK: - Public

    /// Reads the current access and, when allowed, starts following the library index.
    /// Returns once indexing has started; the index arrives over time. Safe to call again.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        applyAccess(await client.access())
    }

    /// Shows the system prompt (after the onboarding primer) and starts indexing if allowed.
    public func requestAccess() async {
        hasStarted = true
        applyAccess(await client.requestAccess())
    }

    /// Re-reads access (it may have changed in Settings) and asks the library to look for
    /// changes. Concurrent calls share one refresh.
    public func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        refreshInFlight = true
        updateRefreshing()
        await task.value
        refreshTask = nil
        refreshInFlight = false
        updateRefreshing()
    }

    /// The listed moment with this ID.
    public func moment(_ id: MomentID) -> Moment? {
        lookup.position[id].map { moments.moments[$0] }
    }

    /// Where the moment with this ID sits in `moments.moments`, if it is listed.
    func position(of id: MomentID) -> Int? {
        guard let position = lookup.position[id], moments.moments.indices.contains(position) else { return nil }
        return position
    }

    /// The listed moment that shares the most photos with `ids`; ties go to the one listed
    /// first. Used to follow a moment whose earliest photo disappeared.
    public func moment(containingAnyOf ids: Set<PhotoID>) -> Moment? {
        var shared: [Int: Int] = [:]
        for id in ids {
            if let momentID = lookup.owner[id], let position = lookup.position[momentID] {
                shared[position, default: 0] += 1
            }
        }
        let best = shared.min { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        return best.map { moments.moments[$0.key] }
    }

    /// Photos in `range`, counted from the in-memory index.
    public func photoCount(in range: ScanRange) -> Int {
        guard let interval = range.interval(now: now(), calendar: calendar) else { return index.count }
        let lower = Self.firstIndex(in: index) { $0.created >= interval.start }
        let upper = Self.firstIndex(in: index) { $0.created > interval.end }
        return max(upper - lower, 0)
    }

    // MARK: - Regrouping

    /// Recomputes the Moments list from the current inputs, off the main actor.
    ///
    /// Requests in the same main-actor turn share one computation. Any result computed
    /// before the latest request is dropped (the generation guard).
    func regroup() {
        generation &+= 1
        guard !regroupScheduled else { return }
        regroupScheduled = true
        regroupTask = Task { [weak self] in
            guard let self else { return }
            await self.performRegroup()
        }
    }

    /// Waits until every scheduled regroup, size batch and prune has finished.
    func settle() async {
        while true {
            if let task = regroupTask {
                await task.value
                if regroupTask == task { regroupTask = nil }
            } else if let task = sizingTask {
                await task.value
                if sizingTask == task { sizingTask = nil }
            } else if let task = sizeRegroupTask {
                await task.value
                if sizeRegroupTask == task { sizeRegroupTask = nil }
            } else if let task = pruneTask {
                await task.value
                if pruneTask == task { pruneTask = nil }
            } else {
                return
            }
        }
    }

    private func performRegroup() async {
        regroupScheduled = false
        let requested = generation
        let input = MomentInput(
            index: index,
            grouping: settings.grouping,
            kept: kept.ids,
            sizes: sizes,
            now: now(),
            calendar: calendar
        )
        let output = await computeMoments(input)
        guard requested == generation else {
            droppedRegroups += 1
            return
        }
        apply(output)
    }

    private func markReadyAfterRegroup() {
        if phase != .ready { readyAfterRegroup = true }
    }

    private func apply(_ output: MomentOutput) {
        appliedRegroups += 1
        defer {
            if readyAfterRegroup {
                readyAfterRegroup = false
                phase = .ready
                updateRefreshing()
            }
        }
        lookup = output.lookup
        sizeQueue = output.sizeQueue
        sizeCursor = 0
        if moments != output.list {
            moments = output.list
            onMomentsChange?()
        }
        scheduleSizing()
    }

    /// Off the main actor: the pipeline, plus the lookups and size order for the result.
    @concurrent nonisolated static func computeMoments(_ input: MomentInput) async -> MomentOutput {
        let signpost = signposter.beginInterval("Regroup")
        defer { signposter.endInterval("Regroup", signpost) }
        let list = MomentPipeline.build(
            index: input.index,
            grouping: input.grouping,
            kept: input.kept,
            sizes: input.sizes,
            now: input.now,
            calendar: input.calendar
        )
        var position: [MomentID: Int] = [:]
        position.reserveCapacity(list.moments.count)
        var owner: [PhotoID: MomentID] = [:]
        owner.reserveCapacity(list.photoCount)
        for (offset, moment) in list.moments.enumerated() {
            position[moment.id] = offset
            for photo in moment.photos { owner[photo.id] = moment.id }
        }
        // Sizes: newest moments first, whatever the list order.
        var sizeQueue: [SizeRequest] = []
        for moment in list.moments.sorted(by: { $0.end > $1.end }) {
            for photo in moment.photos where input.sizes[photo.id] == nil {
                sizeQueue.append(SizeRequest(id: photo.id, modified: photo.modified))
            }
        }
        return MomentOutput(list: list, lookup: MomentLookup(position: position, owner: owner), sizeQueue: sizeQueue)
    }

    // MARK: - Local changes (Curator)

    /// Takes a moment off the list at once, before the regroup that follows confirms it,
    /// so a deleted or kept moment never lingers on screen.
    func dismissMoment(_ id: MomentID) {
        guard let position = lookup.position[id] else { return }
        let removed = moments.moments[position]
        var remaining = moments.moments
        remaining.remove(at: position)
        let estimate = Savings.keepOneEstimate(for: removed, sizes: sizes)
        let savings = ByteEstimate(
            bytes: max(moments.savings.bytes - estimate.bytes, 0),
            isApproximate: moments.savings.isApproximate
        )
        moments = MomentList(moments: remaining, savings: savings)
        lookup = lookup.removing(removed)
        regroup()
        onMomentsChange?()
    }

    /// Drops photos Pickr deleted, or found already gone, from the index without waiting for
    /// the library to report it (§1.5 "the moment disappears at once").
    func removeDeleted(_ ids: some Collection<PhotoID>) {
        guard !ids.isEmpty else { return }
        let deleted = Set(ids)
        tombstones.formUnion(deleted)
        index = IndexMath.apply(IndexDelta(deleted: deleted), to: index)
        for id in deleted {
            sizes[id] = nil
            sizeRequested[id] = nil
        }
        regroup()
    }

    // MARK: - Access and indexing

    private func performRefresh() async {
        applyAccess(await client.access())
        guard access.allowsReading else { return }
        await client.refresh()
    }

    private func applyAccess(_ newAccess: LibraryAccess) {
        if access != newAccess { access = newAccess }
        if newAccess.allowsReading {
            startIndexing()
        } else {
            stopIndexing()
        }
    }

    private func startIndexing() {
        guard indexTask == nil else { return }
        switch phase {
        case .idle, .failed: phase = .indexing(done: 0, total: 0)
        case .indexing, .ready: break
        }
        indexBusy = true
        updateRefreshing()
        let events = client.indexEvents()
        indexTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// Access was withdrawn: forget the library rather than keep showing it.
    private func stopIndexing() {
        indexTask?.cancel()
        indexTask = nil
        indexBusy = false
        updateRefreshing()
        guard !index.isEmpty || phase != .idle else { return }
        index = []
        sizes = [:]
        sizeRequested = [:]
        tombstones = []
        phase = .idle
        regroup()
    }

    /// Applies one index event. Internal so tests can drive it directly.
    func handle(_ event: IndexEvent) {
        handledEvents += 1
        switch event {
        case let .snapshot(snapshot):
            apply(snapshot)
        case let .progress(done, total):
            if phase == .ready {
                indexBusy = true
            } else {
                phase = .indexing(done: done, total: total)
            }
        case let .confirmedDeleted(ids):
            confirmDeleted(ids)
        case let .failed(error):
            Self.log.error("Indexing failed: \(String(describing: error), privacy: .public)")
            indexBusy = false
            if phase != .ready { phase = .failed(error) }
            if error == .notAuthorized {
                Task { [weak self] in
                    guard let self else { return }
                    self.applyAccess(await self.client.access())
                }
            }
        }
        updateRefreshing()
    }

    private func apply(_ snapshot: IndexSnapshot) {
        var records = snapshot.records
        if !tombstones.isEmpty {
            if snapshot.isComplete {
                // Tombstones absent from a complete snapshot are confirmed; forget them.
                tombstones.formIntersection(records.lazy.map(\.id))
            }
            if !tombstones.isEmpty {
                records.removeAll { tombstones.contains($0.id) }
            }
        }
        reconcileSizes(with: records)
        index = records
        if snapshot.isComplete {
            indexBusy = false
            markReadyAfterRegroup()
            schedulePrune()
        } else {
            indexBusy = true
            if !records.isEmpty { markReadyAfterRegroup() }
        }
        regroup()
    }

    private func confirmDeleted(_ ids: Set<PhotoID>) {
        guard !ids.isEmpty else { return }
        tombstones.subtract(ids)
        if index.contains(where: { ids.contains($0.id) }) {
            index = IndexMath.apply(IndexDelta(deleted: ids), to: index)
            regroup()
        }
        if access == .full {
            keptMaintenance?.pruneConfirmedDeleted(ids)
        }
    }

    private func updateRefreshing() {
        let refreshing = refreshInFlight || (indexBusy && phase == .ready)
        if isRefreshing != refreshing { isRefreshing = refreshing }
    }

    // MARK: - Kept pruning

    /// After a complete snapshot with full access, prunes Kept items whose photos are gone.
    private func schedulePrune() {
        guard access == .full, keptMaintenance != nil else { return }
        if pruneTask != nil {
            prunePending = true
            return
        }
        pruneTask = Task { [weak self] in
            repeat {
                self?.prunePending = false
                await self?.keptMaintenance?.pruneMissing()
            } while self?.prunePending == true
            self?.pruneTask = nil
        }
    }

    // MARK: - Sizes

    /// Drops sizes for photos that left the index or changed since their size was read.
    private func reconcileSizes(with records: [AssetRecord]) {
        guard !sizeRequested.isEmpty else { return }
        var requested: [PhotoID: Date?] = [:]
        requested.reserveCapacity(sizeRequested.count)
        var kept = SizeTable()
        kept.reserveCapacity(sizes.count)
        for record in records {
            // `Date?` values: `updateValue` stores a nil date instead of removing the key.
            guard let modified = sizeRequested[record.id], modified == record.modified else { continue }
            requested.updateValue(modified, forKey: record.id)
            if let size = sizes[record.id] { kept[record.id] = size }
        }
        sizeRequested = requested
        if kept.count != sizes.count { sizes = kept }
    }

    private func scheduleSizing() {
        guard sizingTask == nil, access.allowsReading else { return }
        sizingTask = Task { [weak self] in
            while let self, let batch = self.nextSizeBatch() {
                let table = await self.client.resolveSizes(batch.map(\.id))
                guard !Task.isCancelled else { return }
                self.merge(table, for: batch)
            }
            self?.sizingTask = nil
        }
    }

    private func nextSizeBatch() -> [SizeRequest]? {
        var batch: [SizeRequest] = []
        while sizeCursor < sizeQueue.count, batch.count < Self.sizeBatchSize {
            let request = sizeQueue[sizeCursor]
            sizeCursor += 1
            if sizes[request.id] == nil, sizeRequested[request.id] == nil {
                batch.append(request)
            }
        }
        return batch.isEmpty ? nil : batch
    }

    /// Sizes of photos that left the index meanwhile are dropped by the next snapshot.
    private func merge(_ table: SizeTable, for batch: [SizeRequest]) {
        var updated = sizes
        for request in batch {
            sizeRequested.updateValue(request.modified, forKey: request.id)
            if let size = table[request.id] { updated[request.id] = size }
        }
        guard updated.count != sizes.count else { return }
        sizes = updated
        scheduleSizeRegroup()
    }

    /// Size batches regroup at most once per `sizeRegroupDelay`.
    private func scheduleSizeRegroup() {
        guard sizeRegroupTask == nil else { return }
        let delay = sizeRegroupDelay
        sizeRegroupTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.sizeRegroupTask = nil
            self?.regroup()
        }
    }

    // MARK: - Helpers

    static let sizeBatchSize = 200

    /// The first index whose record satisfies `predicate`, which must be false then true
    /// along the array (binary search).
    private nonisolated static func firstIndex(in records: [AssetRecord], where predicate: (AssetRecord) -> Bool) -> Int {
        var low = records.startIndex
        var high = records.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if predicate(records[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

/// Kept maintenance that `LibraryModel` triggers and `Curator` performs (§2.5 rail 6).
protocol KeptMaintenance: AnyObject {
    /// Moves Kept items whose photos are confirmed gone to orphans. Full access only.
    func pruneMissing() async
    /// Moves Kept items the library reported deleted to orphans. Full access only.
    func pruneConfirmedDeleted(_ ids: Set<PhotoID>)
}

/// Computes the Moments list for a set of inputs.
typealias MomentComputer = @concurrent @Sendable (MomentInput) async -> MomentOutput

/// Everything the Moments list depends on, captured at one moment.
nonisolated struct MomentInput: Sendable {
    var index: [AssetRecord]
    var grouping: GroupingSettings
    var kept: Set<PhotoID>
    var sizes: SizeTable
    var now: Date
    var calendar: Calendar
}

/// A computed Moments list with what the model needs to use it.
nonisolated struct MomentOutput: Sendable {
    var list: MomentList
    var lookup: MomentLookup
    /// Photos without a known size, newest moments first.
    var sizeQueue: [SizeRequest]
}

nonisolated struct SizeRequest: Hashable, Sendable {
    var id: PhotoID
    var modified: Date?
}

/// Where each listed moment sits and which moment owns each photo.
nonisolated struct MomentLookup: Sendable {
    var position: [MomentID: Int]
    var owner: [PhotoID: MomentID]

    static let empty = MomentLookup(position: [:], owner: [:])

    /// The lookup after `moment` is taken out of the list.
    func removing(_ moment: Moment) -> MomentLookup {
        guard let removedAt = position[moment.id] else { return self }
        var updated = self
        updated.position[moment.id] = nil
        for (id, offset) in position where offset > removedAt {
            updated.position[id] = offset - 1
        }
        for photo in moment.photos { updated.owner[photo.id] = nil }
        return updated
    }
}

extension LibraryAccess {
    /// Full or limited access: the library can be read.
    nonisolated var allowsReading: Bool {
        self == .full || self == .limited
    }
}
