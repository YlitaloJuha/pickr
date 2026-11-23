import Foundation
import Observation
import PickrCore

/// One pass through the review queue, moment by moment (§3.3 S4).
///
/// - The queue is the Moments list as it was when the review started, from the chosen
///   moment to the end. Commit, Keep Moment, Delete Moment and Skip move to the next
///   moment that still exists; after the last one the session finishes and `Router` pops
///   back to the list with a summary toast.
/// - `Router.startReview(at:)` during a review moves this same session to another moment
///   with a fresh queue (`restart`), so views that hold it keep working in the stack and
///   the split, and the summary and the mode carry over.
/// - Moment, selection, mode, photo index and summary live here, not in views, so a stack
///   ↔ split swap, a rotation or a fold keeps them (ADAPTIVE §3.4).
/// - The selection of a moment the user leaves without committing (Skip, Back) is
///   remembered for the rest of the app session and comes back when the moment does.
/// - When the library changes, the session follows its moment by ID, or by its photos if
///   the earliest one is gone, and keeps only selected photos that are still members. A
///   moment that no longer exists is skipped with the toast "This moment changed".
@Observable public final class ReviewSession: Identifiable {
    public nonisolated enum Mode: Hashable, Sendable {
        case grid, single
    }

    public let id: UUID
    public private(set) var current: Moment?
    /// 1-based position of `current` in the queue.
    public private(set) var position: Int
    public private(set) var total: Int
    public var mode: Mode
    /// The photo shown in Single mode, an index into `current.photos`. Writes are clamped
    /// to the current moment's photos, so arrow keys and the pager can't run past the ends.
    public var singleIndex: Int {
        didSet {
            let clamped = Self.clamp(singleIndex, count: current?.count ?? 0)
            if singleIndex != clamped { singleIndex = clamped }
        }
    }
    public private(set) var selection: Selection
    /// Moments cleared by a delete in this session, the photos deleted and the space freed.
    public private(set) var summary: (moments: Int, photos: Int, freed: ByteEstimate)
    public private(set) var isFinished: Bool
    /// `true` while a commit or delete waits for PhotoKit; the bar's actions are disabled.
    public var isCommitting: Bool { commitsInFlight > 0 }

    /// Commits and deletes waiting for PhotoKit, including a Try Again from a toast.
    private var commitsInFlight = 0

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let curator: Curator
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let memory: SelectionMemory
    @ObservationIgnored private let onFinish: () -> Void
    @ObservationIgnored private var queue: [Moment]
    @ObservationIgnored private var cursor: Int
    /// Moments already shown, so a moment that absorbed a later queue entry isn't shown twice.
    @ObservationIgnored private var visited: Set<MomentID> = []
    /// The moments shown, in order. `Router` scrolls the list to the last one still listed.
    @ObservationIgnored private(set) var reviewedMoments: [MomentID] = []
    /// `false` once the user left the review; a late Try Again then changes nothing here.
    @ObservationIgnored private(set) var isActive = true

    init(
        queue: [Moment],
        startingAt start: Int,
        library: LibraryModel,
        curator: Curator,
        settings: SettingsModel,
        toasts: ToastCenter,
        memory: SelectionMemory,
        onFinish: @escaping () -> Void
    ) {
        precondition(queue.indices.contains(start), "The review must start at a queued moment")
        id = UUID()
        self.queue = queue
        cursor = start
        position = start + 1
        total = queue.count
        mode = .grid
        singleIndex = 0
        selection = Selection()
        summary = (0, 0, .zero)
        isFinished = false
        self.library = library
        self.curator = curator
        self.settings = settings
        self.toasts = toasts
        self.memory = memory
        self.onFinish = onFinish
        current = nil
        land(on: queue[start], at: start)
    }

    public var outcome: ReviewOutcome {
        current.map { selection.outcome(in: $0) } ?? .undecided
    }

    /// The exact space the current selection frees: the sum over the photos to delete.
    public var deletionEstimate: ByteEstimate {
        guard case let .partial(_, delete) = outcome else { return .zero }
        return Savings.total(of: delete, sizes: library.sizes)
    }

    /// `false` when every photo is protected, so Delete Moment is disabled.
    public var canDeleteWhole: Bool {
        current.map(curator.canDeleteWhole) ?? false
    }

    /// `true` when Delete Moment needs the bulk confirmation dialog first.
    public var needsBulkConfirmation: Bool {
        current.map { curator.needsBulkConfirmation(wholeMoment: $0) } ?? false
    }

    /// How many photos Delete Moment would delete; protection-aware.
    public var deletableCount: Int {
        current.map { curator.deletableIDs(wholeMoment: $0).count } ?? 0
    }

    // MARK: - State for commands and bars (ADAPTIVE §7)

    /// The photo at `singleIndex`: the one One by One shows and Space keeps.
    public var currentPhoto: AssetRecord? {
        guard let current, current.photos.indices.contains(singleIndex) else { return nil }
        return current.photos[singleIndex]
    }

    /// How many photos a commit would delete ("Delete 4 Photos"); 0 unless some are kept
    /// and some are not.
    public var deleteCount: Int {
        guard case let .partial(_, delete) = outcome else { return 0 }
        return delete.count
    }

    /// `true` while Skip, Keep All and Delete All can act: there is a moment on screen, no
    /// commit is waiting for PhotoKit and the session hasn't finished.
    public var canMoveOn: Bool {
        current != nil && !isCommitting && !isFinished
    }

    /// `true` when `commit()` would act: `canMoveOn`, and at least one photo is kept.
    public var canCommit: Bool {
        canMoveOn && outcome != .undecided
    }

    // MARK: - Selection

    public func toggle(_ id: PhotoID) {
        guard let current, current.photoIDs.contains(id) else { return }
        selection.toggle(id)
    }

    public func invert() {
        guard let current else { return }
        selection.invert(in: current)
    }

    public func selectAll() {
        guard let current else { return }
        selection.selectAll(in: current)
    }

    public func clear() {
        selection.clear()
    }

    /// Space in One by One: keeps or unkeeps `currentPhoto`.
    public func toggleCurrentPhoto() {
        guard let photo = currentPhoto else { return }
        selection.toggle(photo.id)
    }

    /// Keys 1–9: keeps or unkeeps the photo at `index` (0-based) of the current moment.
    /// Out-of-range indexes are ignored.
    public func togglePhoto(at index: Int) {
        guard let current, current.photos.indices.contains(index) else { return }
        selection.toggle(current.photos[index].id)
    }

    /// Return on a tile, or its View action: shows that photo in One by One.
    public func showSingle(_ id: PhotoID) {
        guard let index = current?.photoIDs.firstIndex(of: id) else { return }
        singleIndex = index
        mode = .single
    }

    // MARK: - Moving on

    /// Decide later: the moment stays in the list and keeps its selection.
    public func skip() {
        guard let current, !isCommitting, !isFinished else { return }
        memory.remember(selection, for: current.id)
        advance()
    }

    /// Commits the selection: deletes the unkept photos, or keeps the moment aside when all
    /// are kept. Moves on unless the user cancelled or it failed (then an error toast offers
    /// Try Again).
    @discardableResult
    public func commit() async -> CommitResult {
        guard let moment = current, !isCommitting, !isFinished else { return .cancelled }
        return await commit(moment, selection: selection)
    }

    /// Delete Moment: deletes every unprotected photo. Confirm first when
    /// `needsBulkConfirmation` is `true`.
    @discardableResult
    public func deleteWhole() async -> CommitResult {
        guard let moment = current, !isCommitting, !isFinished else { return .cancelled }
        return await deleteWhole(moment)
    }

    /// Keep Moment from the ⋯ menu: sends the whole moment to Kept and moves on.
    public func keepAside() {
        guard let moment = current, !isCommitting, !isFinished else { return }
        // The moment leaves the list inside this call; that is this session's own doing,
        // not a library change to revalidate against.
        commitsInFlight += 1
        curator.keepAside(moment)
        commitsInFlight -= 1
        handle(.keptAside, for: moment)
    }

    // MARK: - Internal (Router, AppServices)

    /// Follows the current moment after the library or Kept changed.
    func revalidate() {
        guard isActive, !isFinished, !isCommitting, let old = current else { return }
        let fresh = library.moment(old.id) ?? library.moment(containingAnyOf: Set(old.photoIDs))
        guard let fresh, fresh.count >= 2, !(fresh.id != old.id && visited.contains(fresh.id)) else {
            memory.forget(old.id)
            toasts.show(ToastMessages.momentChanged)
            advance()
            return
        }
        guard fresh != old else { return }
        var updated = selection
        updated.restrict(to: fresh)
        if settings.protectFavorites {
            // New members follow the usual rule: protected photos start as kept.
            let oldMembers = Set(old.photoIDs)
            for photo in fresh.photos where photo.isProtected && !oldMembers.contains(photo.id) {
                updated.toggle(photo.id)
            }
        }
        queue[cursor] = fresh
        if visited.insert(fresh.id).inserted { reviewedMoments.append(fresh.id) }
        current = fresh
        selection = updated
        singleIndex = min(singleIndex, fresh.count - 1)
    }

    /// Moves the open session to `queue[start]` with `queue` as the new queue (a sidebar
    /// tap, Previous Moment). The moment it leaves keeps its selection for the app session;
    /// the summary, the mode and the reviewed moments carry over. Any queued moment may be
    /// shown again, including ones already shown.
    func restart(queue newQueue: [Moment], startingAt start: Int) {
        precondition(newQueue.indices.contains(start), "The review must start at a queued moment")
        guard isActive, !isFinished, !isCommitting else { return }
        if let current { memory.remember(selection, for: current.id) }
        queue = newQueue
        total = newQueue.count
        visited = []
        land(on: newQueue[start], at: start)
    }

    /// The user left the review: remember the selection and stop reacting to changes.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        if let current, !isFinished {
            memory.remember(selection, for: current.id)
        }
    }

    // MARK: - Private

    /// Commits `moment` as selected. A Try Again from the error toast comes back here while
    /// the review is open, so a successful retry also moves the review on; after the user
    /// left, it goes to `Curator` directly.
    private func commit(_ moment: Moment, selection: Selection) async -> CommitResult {
        commitsInFlight += 1
        let result = await curator.commit(moment, selection: selection) { [weak self, weak curator = self.curator] in
            if let self, self.isActive {
                _ = await self.commit(moment, selection: selection)
            } else {
                _ = await curator?.commit(moment, selection: selection)
            }
        }
        commitsInFlight -= 1
        handle(result, for: moment)
        return result
    }

    /// Delete Moment for `moment`, with Try Again handled like `commit(_:selection:)`.
    private func deleteWhole(_ moment: Moment) async -> CommitResult {
        commitsInFlight += 1
        let result = await curator.deleteWhole(moment) { [weak self, weak curator = self.curator] in
            if let self, self.isActive {
                _ = await self.deleteWhole(moment)
            } else {
                _ = await curator?.deleteWhole(moment)
            }
        }
        commitsInFlight -= 1
        handle(result, for: moment)
        return result
    }

    private func handle(_ result: CommitResult, for moment: Moment) {
        switch result {
        case let .committed(deleted, freed):
            summary.moments += 1
            summary.photos += deleted
            summary.freed = ByteEstimate(
                bytes: summary.freed.bytes + freed.bytes,
                isApproximate: summary.freed.isApproximate || freed.isApproximate
            )
            finishMoment(moment)
        case .keptAside, .failed(.nothingToDelete):
            finishMoment(moment)
        case .cancelled, .failed:
            // Library changes that arrived while PhotoKit waited were not applied yet.
            if current?.id == moment.id { revalidate() }
        }
    }

    /// The moment left the list; move on if it is still the one on screen.
    private func finishMoment(_ moment: Moment) {
        memory.forget(moment.id)
        guard isActive, !isFinished, current?.id == moment.id else { return }
        advance()
    }

    private func advance() {
        var next = cursor + 1
        while next < queue.count {
            let queued = queue[next]
            let resolved = library.moment(queued.id) ?? library.moment(containingAnyOf: Set(queued.photoIDs))
            if let resolved, resolved.count >= 2, !visited.contains(resolved.id) {
                land(on: resolved, at: next)
                return
            }
            next += 1
        }
        finish()
    }

    private func land(on moment: Moment, at index: Int) {
        cursor = index
        position = index + 1
        queue[index] = moment
        visited.insert(moment.id)
        reviewedMoments.append(moment.id)
        current = moment
        singleIndex = 0
        if var remembered = memory.selection(for: moment.id) {
            remembered.restrict(to: moment)
            selection = remembered
        } else {
            selection = .initial(for: moment, protectFavorites: settings.protectFavorites)
        }
    }

    private func finish() {
        current = nil
        selection = Selection()
        singleIndex = 0
        isFinished = true
        onFinish()
    }

    private nonisolated static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

/// Selections of moments the user left without committing, for the rest of the app session
/// (§3.4 "Leave Review: the selection is kept for the session"). In memory only.
final class SelectionMemory {
    private var selections: [MomentID: Selection] = [:]

    func selection(for id: MomentID) -> Selection? {
        selections[id]
    }

    func remember(_ selection: Selection, for id: MomentID) {
        selections[id] = selection
    }

    func forget(_ id: MomentID) {
        selections[id] = nil
    }
}
