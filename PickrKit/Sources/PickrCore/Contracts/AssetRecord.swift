import Foundation

/// The indexed facts about one photo. Only images with a capture date are ever indexed.
public struct AssetRecord: Hashable, Codable, Sendable {
    public let id: PhotoID
    /// `PHAsset.creationDate`. Assets without one are never indexed.
    public var created: Date
    /// `PHAsset.modificationDate`. A change invalidates the cached size.
    public var modified: Date?
    public var isFavorite: Bool
    /// `PHAsset.rating` raw value; 0 means unset.
    public var rating: Int

    public init(id: PhotoID, created: Date, modified: Date? = nil, isFavorite: Bool = false, rating: Int = 0) {
        self.id = id
        self.created = created
        self.modified = modified
        self.isFavorite = isFavorite
        self.rating = rating
    }

    /// Favorites and rated photos. With "Protect favorites" on they start as kept and
    /// bulk deletes skip them.
    public var isProtected: Bool { isFavorite || rating > 0 }

    /// The one capture order used everywhere: ascending by `created`, ties broken by `id`.
    ///
    /// Use it as `records.sorted(by: AssetRecord.inCaptureOrder)`.
    public static func inCaptureOrder(_ lhs: AssetRecord, _ rhs: AssetRecord) -> Bool {
        if lhs.created != rhs.created { return lhs.created < rhs.created }
        return lhs.id < rhs.id
    }
}

/// Library storage per photo, in bytes. A missing key means the size is unknown.
public typealias SizeTable = [PhotoID: Int64]
