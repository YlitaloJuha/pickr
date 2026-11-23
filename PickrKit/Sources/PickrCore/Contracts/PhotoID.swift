import Foundation

/// The identity of one photo: its `PHAsset.localIdentifier`.
///
/// Encodes as a single string, so a `[PhotoID]` round-trips as `[String]`.
public struct PhotoID: Hashable, Comparable, Codable, Sendable {
    /// The `PHAsset.localIdentifier`.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PhotoID, rhs: PhotoID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
