import Foundation
import PickrCore

/// The words of every toast the models post (§3.3, §3.4), as `audit/COPY.md` words them.
///
/// PickrModels has no resources: these strings live in the app's String Catalog, so they
/// resolve in the main bundle (named explicitly; the app target is the main bundle). If the
/// package ever gets its own catalog, switch to `bundle: #bundle`.
nonisolated enum ToastMessages {
    /// "Moved 4 photos to Recently Deleted · 5.3 MB freed up".
    static func deleted(count: Int, freed: ByteEstimate) -> String {
        guard freed.bytes > 0 else {
            return String(
                localized: "Moved \(count) photos to Recently Deleted",
                bundle: .main,
                comment: "Toast after a delete when the size is unknown. The variable is the photo count."
            )
        }
        let size = PickrFormat.bytes(freed.bytes)
        if freed.isApproximate {
            return String(
                localized: "Moved \(count) photos to Recently Deleted · about \(size) freed up",
                bundle: .main,
                comment: "Toast after a delete. The first variable is the photo count, the second a lower bound of the space freed, for example 4.2 MB."
            )
        }
        return String(
            localized: "Moved \(count) photos to Recently Deleted · \(size) freed up",
            bundle: .main,
            comment: "Toast after a delete. The first variable is the photo count, the second the space freed, for example 4.2 MB."
        )
    }

    /// "Moment kept.", shown with Undo (Keep All).
    static var keptAside: String {
        String(
            localized: "Moment kept.",
            bundle: .main,
            comment: "Toast after Keep All moved a whole moment to the Kept tab, so it won't come back for cleanup. Shown with an Undo button."
        )
    }

    /// "It will show up in Moments again.", shown with Undo (Show Again on a moment or photo).
    static var shownAgain: String {
        String(
            localized: "It will show up in Moments again.",
            bundle: .main,
            comment: "Toast after Show Again took a moment or a photo out of the Kept tab. Shown with an Undo button."
        )
    }

    /// "They will show up in Moments again." (Show All Again, no Undo).
    static var allShownAgain: String {
        String(
            localized: "They will show up in Moments again.",
            bundle: .main,
            comment: "Toast after Show All Again took every photo out of the Kept tab."
        )
    }

    /// Shown when the moment under review changed so much it can no longer be reviewed.
    static var momentChanged: String {
        String(
            localized: "This moment changed",
            bundle: .main,
            comment: "Toast when the photo library changed during review and the moment on screen no longer exists; review moves on."
        )
    }

    /// Shown when every photo of a delete was already gone or hidden.
    static var nothingToDelete: String {
        String(
            localized: "These photos were already deleted or hidden",
            bundle: .main,
            comment: "Toast when the user deletes photos that another device or app already deleted or hid."
        )
    }

    /// "Done: 5 moments · 23 photos · 1.2 GB freed up."
    static func summary(moments: Int, photos: Int, freed: ByteEstimate) -> String {
        guard freed.bytes > 0 else {
            return String(
                localized: "Done: \(moments) moments · \(photos) photos.",
                bundle: .main,
                comment: "Summary toast at the end of a cleanup when the size is unknown. The first variable is the number of moments cleaned up, the second the number of photos moved to Recently Deleted."
            )
        }
        let size = PickrFormat.bytes(freed.bytes)
        if freed.isApproximate {
            return String(
                localized: "Done: \(moments) moments · \(photos) photos · about \(size) freed up.",
                bundle: .main,
                comment: "Summary toast at the end of a cleanup. Variables: moments cleaned up, photos moved to Recently Deleted, a lower bound of the space freed up (for example 1.2 GB)."
            )
        }
        return String(
            localized: "Done: \(moments) moments · \(photos) photos · \(size) freed up.",
            bundle: .main,
            comment: "Summary toast at the end of a cleanup. Variables: moments cleaned up, photos moved to Recently Deleted, space freed up (for example 1.2 GB)."
        )
    }

    /// The error toast for a failed delete. Cancelling is never reported.
    static func deleteFailed(_ error: LibraryError) -> String {
        switch error {
        case .notAuthorized:
            String(
                localized: "Pickr. isn't allowed to delete photos. Check Photos access in Settings.",
                bundle: .main,
                comment: "Error toast when a delete failed because Photos access was withdrawn. Shown with a Try Again button."
            )
        case .unavailable:
            String(
                localized: "Your photo library isn't available right now.",
                bundle: .main,
                comment: "Error toast when a delete failed because the photo library was offline or switching. Shown with a Try Again button."
            )
        case .network:
            String(
                localized: "Couldn't reach iCloud to delete the photos.",
                bundle: .main,
                comment: "Error toast when a delete failed for lack of network. Shown with a Try Again button."
            )
        case .limitExceeded:
            String(
                localized: "Too many photos to delete at once.",
                bundle: .main,
                comment: "Error toast when Photos refused a delete request as too large. Shown with a Try Again button."
            )
        case .cancelled, .nothingToDelete, .failed:
            String(
                localized: "Couldn't delete the photos.",
                bundle: .main,
                comment: "Error toast when a delete failed. Shown with a Try Again button."
            )
        }
    }
}
