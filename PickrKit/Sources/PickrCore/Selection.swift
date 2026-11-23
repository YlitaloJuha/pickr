import Foundation

/// What committing the current selection would do.
public enum ReviewOutcome: Hashable, Sendable {
    /// Nothing kept yet.
    case undecided
    /// Keep some photos, delete the rest.
    case partial(keep: [PhotoID], delete: [PhotoID])
    /// Every photo is kept.
    case keepAll
}

/// The photos marked to keep in one moment ("Tap to keep").
///
/// The selection is only a set of IDs. Every operation that needs the moment's members
/// takes the moment, so a selection that outlived a library change can be narrowed with
/// `restrict(to:)`, and `outcome(in:)` ignores IDs that are no longer members.
public struct Selection: Hashable, Sendable {
    public private(set) var kept: Set<PhotoID>

    public init(kept: Set<PhotoID> = []) {
        self.kept = kept
    }

    /// Nothing selected, except protected photos when `protectFavorites` is on.
    public static func initial(for m: Moment, protectFavorites: Bool) -> Selection {
        Selection(kept: protectFavorites ? m.protectedIDs : [])
    }

    /// Keeps the photo if it is not kept, otherwise un-keeps it.
    public mutating func toggle(_ id: PhotoID) {
        if kept.remove(id) == nil {
            kept.insert(id)
        }
    }

    /// Keeps exactly the moment's photos that are not kept now.
    ///
    /// Protected photos are inverted like any other: the user sees their heart and trash
    /// badges, and `Curator` applies the protection rules for whole-moment deletes.
    public mutating func invert(in m: Moment) {
        kept = Set(m.photoIDs).subtracting(kept)
    }

    public mutating func selectAll(in m: Moment) {
        kept = Set(m.photoIDs)
    }

    public mutating func clear() {
        kept = []
    }

    /// Drops kept IDs that are no longer in the moment.
    public mutating func restrict(to m: Moment) {
        kept.formIntersection(m.photoIDs)
    }

    /// The commit this selection describes, with both lists in capture order.
    ///
    /// Only the moment's members count: `.partial` needs at least one kept and at least one
    /// unkept member (§1.5), `.keepAll` means every member is kept.
    public func outcome(in m: Moment) -> ReviewOutcome {
        var keep: [PhotoID] = []
        var delete: [PhotoID] = []
        for id in m.photoIDs {
            if kept.contains(id) {
                keep.append(id)
            } else {
                delete.append(id)
            }
        }
        if keep.isEmpty { return .undecided }
        if delete.isEmpty { return .keepAll }
        return .partial(keep: keep, delete: delete)
    }
}
