import Observation
import PickrCore

/// The Kept tab's view state, shared by the list and the Kept moment and held above the
/// stack/split switch (`KeptColumns`), so a resize, rotation or fold keeps the sections, the
/// open moment, All / One by One and the photo index (ADAPTIVE §3.4).
///
/// - `KeptColumns` fills it from `KeptModel.groups(index:window:)` and `liveIDs(in:)` in a
///   `.task(id:)`, never in a body (both are O(library)).
/// - The open moment comes from `Router.keptPath` (the route). Show Photo Again can take away
///   a moment's first photo, which changes its `MomentID`; the board then follows the moment
///   by its photos, so the screen stays on it while the route keeps the ID it was opened with.
/// - Holds no layout: the containers read it and decide for themselves.
@Observable final class KeptBoard {
    /// How the open Kept moment shows its photos: **All** or **One by One**.
    enum Mode: Hashable {
        case grid, single
    }

    /// "Moments you kept" (kinds `keptAside` and `legacy`), newest first.
    private(set) var aside: [Moment] = []
    /// "Photos you picked" (kind `reviewed`), newest first.
    private(set) var reviewed: [Moment] = []
    /// Photos in "Photos you picked", for its header.
    private(set) var reviewedPhotoCount = 0
    /// Kept photos that are in the library index: what Show All Again shows again.
    private(set) var liveCount = 0
    /// `false` until the first computation, so the list never flashes "Nothing kept yet".
    private(set) var isLoaded = false

    /// "Photos you picked" is collapsed until the person opens it.
    var reviewedExpanded = false
    /// The open moment's mode. Kept across moments in a split; back to All for the next moment
    /// after one closes.
    var mode: Mode = .grid
    /// The photo One by One shows; clamp it to the open moment's photos when reading.
    var singleIndex = 0
    /// Bumped for every Show Again, so the tab plays one light impact (§3.4).
    private(set) var showAgainCount = 0

    /// The moment under the list's focus line, reported by the list (`KeptScreen`) and kept
    /// here, above the stack/split switch. Read only by the ambient layer.
    var listFocus: MomentID?
    private var momentsByID: [MomentID: Moment] = [:]
    private var reviewedIDs: Set<MomentID> = []
    /// Route ID → the ID the open moment has now, after its first photo was shown again.
    private var followed: [MomentID: MomentID] = [:]
    /// The open moment's photos, to follow it when its ID changes.
    @ObservationIgnored private var openMembers: Set<PhotoID> = []
    /// The last route was closed; the next moment opened starts in All.
    @ObservationIgnored private var wasClosed = false

    var isEmpty: Bool { aside.isEmpty && reviewed.isEmpty }
    var momentCount: Int { aside.count + reviewed.count }
    /// The list shows (so a wide, regular container may split).
    var showsList: Bool { isLoaded && !isEmpty }

    // MARK: - Reading

    /// The moment the route `id` points at now, following it across ID changes.
    func moment(for id: MomentID?) -> Moment? {
        guard let id else { return nil }
        if let moment = momentsByID[id] { return moment }
        return followed[id].flatMap { momentsByID[$0] }
    }

    /// Whether the moment is in "Photos you picked".
    func isPicked(_ id: MomentID) -> Bool {
        reviewedIDs.contains(id)
    }

    /// The list's background (blueprint §3.5): the first photo of the moment under the focus
    /// line, or of the first moment listed before the list has reported.
    var listAmbient: AmbientSource {
        let focused = listFocus.flatMap { id in
            reviewedExpanded || !reviewedIDs.contains(id) ? momentsByID[id] : nil
        }
        guard let moment = focused ?? aside.first ?? (reviewedExpanded ? reviewed.first : nil) else {
            return .plain
        }
        return .photo(moment.photos[0].id)
    }

    // MARK: - Writing

    /// Replaces the sections with a fresh computation and keeps following the open moment.
    func update(aside: [Moment], reviewed: [Moment], liveCount: Int, route: MomentID?) {
        self.aside = aside
        self.reviewed = reviewed
        self.liveCount = liveCount
        reviewedPhotoCount = reviewed.reduce(0) { $0 + $1.count }
        momentsByID = Dictionary((aside + reviewed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        reviewedIDs = Set(reviewed.map(\.id))
        isLoaded = true
        follow(route)
    }

    /// A different moment opened (or none): One by One starts at its first photo, and the
    /// first moment opened after a close starts in All. A close changes neither, so the screen
    /// that is leaving keeps its photo and mode while the stack pops.
    func open(_ route: MomentID?) {
        followed = [:]
        openMembers = moment(for: route).map { Set($0.photoIDs) } ?? []
        guard route != nil else {
            wasClosed = true
            return
        }
        singleIndex = 0
        if wasClosed {
            mode = .grid
            wasClosed = false
        }
    }

    /// Takes a moment off the list at once, before the next computation confirms it, so a
    /// full swipe doesn't bounce the row back.
    func dismiss(_ id: MomentID) {
        aside.removeAll { $0.id == id }
        reviewed.removeAll { $0.id == id }
        momentsByID[id] = nil
    }

    /// Plays the Show Again haptic.
    func didShowAgain() {
        showAgainCount &+= 1
    }

    // MARK: - Private

    private func follow(_ route: MomentID?) {
        guard let route else {
            followed = [:]
            openMembers = []
            return
        }
        if momentsByID[route] != nil {
            if followed[route] != nil { followed[route] = nil }
        } else {
            followed[route] = successor(of: openMembers)?.id
        }
        if let moment = moment(for: route) {
            openMembers = Set(moment.photoIDs)
        }
    }

    /// The moment that shares the most photos with `members`; ties go to the one listed first.
    private func successor(of members: Set<PhotoID>) -> Moment? {
        guard !members.isEmpty else { return nil }
        var best: Moment?
        var bestShared = 0
        for moment in aside + reviewed {
            let shared = moment.photos.reduce(0) { members.contains($1.id) ? $0 + 1 : $0 }
            if shared > bestShared {
                best = moment
                bestShared = shared
            }
        }
        return best
    }
}
