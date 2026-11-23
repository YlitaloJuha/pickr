import Foundation
import Observation
import PickrCore

/// Tabs, navigation paths, the one sheet and the review session (§3.1).
///
/// - `review` is non-nil exactly while `.review` is on `momentsPath`, in both directions:
///   `startReview` puts `.review` on the path, `endReview` takes it off, a path write that
///   drops it (Back) ends the session, and a stray `.review` with no session is removed.
///   The path is the same in the stack and the split (ADAPTIVE §3.3), so a collapsing split
///   lands on the pushed Review and an expanding one shows it in the detail column.
/// - Popping Review (Back, or the end of the queue) ends the session; its selections are
///   remembered for the app session, so starting a review again brings them back.
/// - `startReview(at:)` while a review is open moves that same session to the new moment
///   (a sidebar tap, Previous Moment): the summary and the mode carry over.
/// - When a review finishes, the Moments list should scroll to `scrollTarget` and a
///   summary toast appears. Leaving mid-review (Back, Esc) sets `scrollTarget` to the moment
///   on screen, so the zoom back finds its card.
/// - `sheet` is the one sheet on screen. `AppServices.launch()` doesn't set it: the root
///   view presents `.whatsNew` while `SettingsModel.showsWhatsNew` is `true`.
/// - Nothing here depends on the layout: views translate this state into whichever
///   container fits (ADAPTIVE §1.3).
@Observable public final class Router {
    public nonisolated enum Tab: Hashable, Sendable {
        case moments, kept
    }

    public nonisolated enum Sheet: String, Identifiable, Sendable {
        case grouping, settings, whatsNew
        public var id: String { rawValue }
    }

    public nonisolated enum MomentsRoute: Hashable, Sendable {
        case review
    }

    public nonisolated enum KeptRoute: Hashable, Sendable {
        case keptMoment(MomentID)
    }

    public var tab: Tab = .moments
    public var momentsPath: [MomentsRoute] = [] {
        didSet {
            if review != nil, !momentsPath.contains(.review) { closeReview() }
            // Only `startReview` opens Review; a `.review` pushed any other way has no session.
            if review == nil, momentsPath.contains(.review) { momentsPath.removeAll { $0 == .review } }
        }
    }
    public var keptPath: [KeptRoute] = []
    public var sheet: Sheet?
    public private(set) var review: ReviewSession?
    /// The moment the Moments list should scroll to after a review: the last one reviewed
    /// that is still listed, or after Back the one that was on screen. The list sets it back
    /// to `nil` once it has scrolled.
    public var scrollTarget: MomentID?

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let curator: Curator
    @ObservationIgnored private let settings: SettingsModel
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private let memory = SelectionMemory()

    init(library: LibraryModel, curator: Curator, settings: SettingsModel, toasts: ToastCenter) {
        self.library = library
        self.curator = curator
        self.settings = settings
        self.toasts = toasts
    }

    /// Starts a review at `id`, or at the first moment in list order.
    ///
    /// The queue runs from that moment to the end of the list as it is now. Does nothing
    /// when the list is empty or `id` is no longer listed. Closes any open sheet.
    ///
    /// With a review already open (a sidebar tap, Previous Moment), the same session moves
    /// to that moment with a fresh queue: the moment it leaves keeps its selection for the
    /// app session, and the summary and the mode carry over. It stays put at its own moment,
    /// and while a commit waits for PhotoKit it does nothing.
    public func startReview(at id: MomentID?) {
        let list = library.moments.moments
        let start: Int
        if let id {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            start = index
        } else {
            guard !list.isEmpty else { return }
            start = 0
        }
        if let session = review {
            guard !session.isCommitting else { return }
            if session.current?.id != list[start].id {
                session.restart(queue: list, startingAt: start)
            }
        } else {
            review = ReviewSession(
                queue: list,
                startingAt: start,
                library: library,
                curator: curator,
                settings: settings,
                toasts: toasts,
                memory: memory
            ) { [weak self] in
                self?.reviewDidFinish()
            }
        }
        sheet = nil
        tab = .moments
        if momentsPath != [.review] { momentsPath = [.review] }
    }

    /// Leaves Review and returns to the Moments list.
    public func endReview() {
        if momentsPath.contains(.review) {
            momentsPath.removeAll { $0 == .review }
        } else {
            closeReview()
        }
    }

    // MARK: - Adaptive layouts (ADAPTIVE §3.2, §3.3, §7)

    /// The Moments list's selection in a split: the moment under review, so the highlight
    /// follows Skip, commits and revalidation.
    ///
    /// Setting a different listed moment starts a review there (`startReview(at:)`), or
    /// moves the open one. Setting the moment already under review, or `nil`, changes
    /// nothing: a list that appears or disappears in a stack ↔ split swap may write either,
    /// and only Back or `endReview()` ends a review.
    public var reviewSelection: MomentID? {
        get { review?.current?.id }
        set {
            guard let newValue, newValue != review?.current?.id else { return }
            startReview(at: newValue)
        }
    }

    /// The Kept list's selection in a split, mapped onto `keptPath` so the same path drives
    /// the stack and the split: the open Kept moment, or `nil`.
    ///
    /// Setting a moment makes `keptPath` `[.keptMoment(id)]`. Setting `nil` changes nothing,
    /// for the same reason as `reviewSelection`; to close the moment, set `keptPath = []`.
    public var keptSelection: MomentID? {
        get {
            guard case let .keptMoment(id)? = keptPath.last else { return nil }
            return id
        }
        set {
            guard let newValue else { return }
            let path: [KeptRoute] = [.keptMoment(newValue)]
            if keptPath != path { keptPath = path }
        }
    }

    /// The moment listed just above the one under review: where Previous Moment (⌘↑) goes.
    /// `nil` without an open review, at the top of the list, or while a commit waits for
    /// PhotoKit, so the command can be disabled.
    public var previousMoment: MomentID? {
        guard let review, !review.isCommitting, let current = review.current else { return nil }
        guard let index = library.position(of: current.id), index > 0 else { return nil }
        return library.moments.moments[index - 1].id
    }

    /// Previous Moment (⌘↑): moves the review to `previousMoment` with its remembered
    /// selection. Does nothing when `previousMoment` is `nil`.
    public func reviewPreviousMoment() {
        guard let id = previousMoment else { return }
        startReview(at: id)
    }

    // MARK: - Private

    private func closeReview() {
        // Back or Esc mid-review: the stack's zoom returns to this moment's card, so the list
        // brings it on screen first. A finished review set its own target.
        if let session = review, !session.isFinished, let current = session.current,
           library.moment(current.id) != nil {
            scrollTarget = current.id
        }
        review?.deactivate()
        review = nil
    }

    private func reviewDidFinish() {
        guard let session = review, session.isFinished else { return }
        scrollTarget = lastListedMoment(of: session)
        let summary = session.summary
        if summary.moments > 0 {
            toasts.show(ToastMessages.summary(moments: summary.moments, photos: summary.photos, freed: summary.freed))
        }
        endReview()
    }

    /// The reviewed moment closest to the end of the queue that is still listed.
    private func lastListedMoment(of session: ReviewSession) -> MomentID? {
        session.reviewedMoments.reversed().first { library.moment($0) != nil }
    }
}
