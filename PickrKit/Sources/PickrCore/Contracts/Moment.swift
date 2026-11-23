import Foundation

/// The stable identity of a moment: its earliest photo by `(created, id)`.
///
/// It survives regrouping and rescans as long as that photo stays in the moment, which
/// keeps cards, review sessions and zoom transitions pointing at the same moment.
public struct MomentID: Hashable, Codable, Sendable {
    public let anchor: PhotoID

    public init(anchor: PhotoID) {
        self.anchor = anchor
    }
}

/// Photos taken close together in time, in capture order.
public struct Moment: Identifiable, Hashable, Sendable {
    public let id: MomentID
    /// Ascending by `(created, id)`; never empty.
    public let photos: [AssetRecord]

    /// Creates a moment from at least one photo. The photos are put in capture order
    /// (`AssetRecord.inCaptureOrder`) and the earliest one becomes the anchor.
    public init(photos: [AssetRecord]) {
        precondition(!photos.isEmpty, "A moment needs at least one photo")
        let ordered = photos.sorted(by: AssetRecord.inCaptureOrder)
        self.photos = ordered
        self.id = MomentID(anchor: ordered[0].id)
    }

    /// Capture time of the earliest photo.
    public var start: Date { photos[0].created }
    /// Capture time of the latest photo.
    public var end: Date { photos[photos.count - 1].created }
    public var count: Int { photos.count }
    public var photoIDs: [PhotoID] { photos.map(\.id) }
    /// Favorites and rated photos in this moment.
    public var protectedIDs: Set<PhotoID> { Set(photos.lazy.filter(\.isProtected).map(\.id)) }
}

/// A byte count that may be a lower bound because some sizes are not known yet.
/// The UI shows approximate figures as "about …".
public struct ByteEstimate: Hashable, Sendable {
    public var bytes: Int64
    public var isApproximate: Bool

    public init(bytes: Int64, isApproximate: Bool) {
        self.bytes = bytes
        self.isApproximate = isApproximate
    }

    /// Exactly zero bytes.
    public static let zero = ByteEstimate(bytes: 0, isApproximate: false)
}

/// The grouped, ordered result shown in the Moments list.
public struct MomentList: Hashable, Sendable {
    public let moments: [Moment]
    /// Photos across all moments.
    public let photoCount: Int
    /// The keep-one estimate summed over all moments.
    public let savings: ByteEstimate

    public init(moments: [Moment], photoCount: Int, savings: ByteEstimate) {
        self.moments = moments
        self.photoCount = photoCount
        self.savings = savings
    }

    /// Derives `photoCount` from the moments.
    public init(moments: [Moment], savings: ByteEstimate) {
        self.init(moments: moments, photoCount: moments.reduce(0) { $0 + $1.count }, savings: savings)
    }

    public static let empty = MomentList(moments: [], photoCount: 0, savings: .zero)
}
