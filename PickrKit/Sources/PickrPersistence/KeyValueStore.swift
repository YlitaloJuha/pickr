import Foundation

/// The slice of `UserDefaults` the persistence layer uses, so tests can substitute an
/// in-memory store. Values are plist primitives (`Int`, `Double`, `Bool`, `String`,
/// `Date`, `Data`, arrays and dictionaries of those).
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// A `KeyValueStore` in memory, for tests and previews.
///
/// Like `UserDefaults`, setting `nil` removes the key. Values are stored as given, so a
/// fixture can hold exactly the types v1 wrote.
public final class InMemoryKeyValueStore: KeyValueStore {
    /// Every stored value, by key.
    public private(set) var values: [String: Any]

    public init(_ values: [String: Any] = [:]) {
        self.values = values
    }

    public func object(forKey key: String) -> Any? {
        values[key]
    }

    public func set(_ value: Any?, forKey key: String) {
        values[key] = value
    }

    public func removeObject(forKey key: String) {
        values[key] = nil
    }
}
