import Foundation
import PickrCore
import Testing
@testable import PickrPersistence

/// Pickr. 1.0 preferences as v1 wrote them to the `com.juha.Culler` domain: every legacy
/// key of §1.2 with its exact property-list type (integer, real, string, date, boolean,
/// array of strings). Parsing the XML gives the same Foundation types UserDefaults returns.
enum V1Fixture {
    static let photoIDs = [
        "9F2C1A7E-5B3D-4E8F-A1C2-3D4E5F6A7B8C/L0/001",
        "0B1C2D3E-4F5A-6B7C-8D9E-0F1A2B3C4D5E/L0/001",
        "C3D4E5F6-A7B8-49C0-91E2-F3A4B5C6D7E8/L0/001",
    ]
    /// 00:00:00 on 1 March 2026 in Helsinki (UTC+2).
    static let customRangeStart = Date(timeIntervalSince1970: 1_772_316_000)
    /// 23:59:59 on 15 March 2026 in Helsinki (UTC+2).
    static let customRangeEnd = Date(timeIntervalSince1970: 1_773_611_999)
    /// 14 May 2026 07:41:12 UTC.
    static let firstUseDate = Date(timeIntervalSince1970: 1_778_744_472)

    static let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>settings.timeWindowSeconds</key>
            <integer>1800</integer>
            <key>settings.scanRangePreset</key>
            <string>custom</string>
            <key>settings.customRangeStart</key>
            <date>2026-02-28T22:00:00Z</date>
            <key>settings.customRangeEnd</key>
            <date>2026-03-15T21:59:59Z</date>
            <key>settings.onboardingCompleted</key>
            <true/>
            <key>settings.hapticFeedbackEnabled</key>
            <false/>
            <key>ignoreList.photoIDs</key>
            <array>
                <string>9F2C1A7E-5B3D-4E8F-A1C2-3D4E5F6A7B8C/L0/001</string>
                <string>0B1C2D3E-4F5A-6B7C-8D9E-0F1A2B3C4D5E/L0/001</string>
                <string>C3D4E5F6-A7B8-49C0-91E2-F3A4B5C6D7E8/L0/001</string>
            </array>
            <key>stats.photosDeleted</key>
            <integer>412</integer>
            <key>stats.mbFreed</key>
            <real>1.5</real>
            <key>stats.clustersCleared</key>
            <integer>37</integer>
            <key>stats.firstUseDate</key>
            <date>2026-05-14T07:41:12Z</date>
            <key>hint.tapToKeepDismissCount</key>
            <integer>1</integer>
            <key>hint.swipeUpKeepDismissCount</key>
            <integer>2</integer>
            <key>hint.longPressDismissCount</key>
            <integer>1</integer>
            <key>hint.longPressThumbDismissCount</key>
            <integer>1</integer>
            <key>hint.pendingRestoreRefresh</key>
            <false/>
            <key>hint.refreshDismissCount</key>
            <integer>3</integer>
            <key>hint.swipeDismissCount</key>
            <integer>3</integer>
        </dict>
        </plist>
        """

    /// The fixture as Foundation property-list values.
    static func values() throws -> [String: Any] {
        let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)
        return try #require(parsed as? [String: Any])
    }

    /// The fixture in an `InMemoryKeyValueStore`.
    static func inMemory() throws -> InMemoryKeyValueStore {
        InMemoryKeyValueStore(try values())
    }
}

/// Which store a parameterized test runs against.
enum StoreKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case inMemory
    case userDefaults

    var testDescription: String { rawValue }

    /// A store holding `values`. Keep the returned box alive for the whole test: it removes
    /// the UserDefaults domain when it goes away.
    func make(_ values: [String: Any] = [:]) -> any TestStore {
        switch self {
        case .inMemory: InMemoryTestStore(values)
        case .userDefaults: TestDefaults(values)
        }
    }
}

/// A `KeyValueStore` that tests can also enumerate.
protocol TestStore: AnyObject {
    var store: any KeyValueStore { get }
    var snapshot: [String: Any] { get }
}

final class InMemoryTestStore: TestStore {
    private let memory: InMemoryKeyValueStore

    init(_ values: [String: Any]) {
        memory = InMemoryKeyValueStore(values)
    }

    var store: any KeyValueStore { memory }
    var snapshot: [String: Any] { memory.values }
}

/// A real `UserDefaults` suite with its own domain, removed on deinit.
final class TestDefaults: TestStore {
    let defaults: UserDefaults
    private let name = "PickrPersistenceTests-\(UUID().uuidString)"

    init(_ values: [String: Any] = [:]) {
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName:) failed for \(name)")
        }
        self.defaults = defaults
        defaults.setPersistentDomain(values, forName: name)
    }

    deinit {
        defaults.removePersistentDomain(forName: name)
        // Removing the domain leaves an empty plist behind; delete it too, so test runs don't
        // pile files up in ~/Library/Preferences.
        _ = CFPreferencesAppSynchronize(name as CFString)
        try? FileManager.default.removeItem(at: URL.libraryDirectory.appending(path: "Preferences/\(name).plist"))
    }

    var store: any KeyValueStore { defaults }
    var snapshot: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
}

/// Records every write on top of an `InMemoryKeyValueStore`.
final class RecordingStore: KeyValueStore {
    struct Write {
        let key: String
        /// `nil` for a removal.
        let value: Any?
        /// The whole store just before the write.
        let before: [String: Any]
    }

    let memory: InMemoryKeyValueStore
    private(set) var writes: [Write] = []

    init(_ values: [String: Any] = [:]) {
        memory = InMemoryKeyValueStore(values)
    }

    var writtenKeys: [String] { writes.map(\.key) }

    /// Whether `settings.scanRangePreset` held `custom` without both dates after any write.
    var everStoredCustomWithoutDates: Bool {
        guard !writes.isEmpty else { return false }
        // The state after each write is the state before the next one, then the current one.
        var states = writes.dropFirst().map(\.before)
        states.append(memory.values)
        return states.contains { values in
            values[PersistedKeys.Settings.scanRangePreset] as? String == "custom"
                && (values[PersistedKeys.Settings.customRangeStart] as? Date == nil
                    || values[PersistedKeys.Settings.customRangeEnd] as? Date == nil)
        }
    }

    func object(forKey key: String) -> Any? {
        memory.object(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        writes.append(Write(key: key, value: value, before: memory.values))
        memory.set(value, forKey: key)
    }

    func removeObject(forKey key: String) {
        writes.append(Write(key: key, value: nil, before: memory.values))
        memory.removeObject(forKey: key)
    }
}

/// A fresh folder in the temporary directory, deleted on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "PickrPersistenceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// `Application Support/Pickr/kept.json`, relative to this folder.
    var keptURL: URL { url.appending(path: "Pickr/kept.json", directoryHint: .notDirectory) }

    /// The folders' contents, sorted by name.
    func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }
}

/// The binary property-list encoding of `value`, to compare stored values byte for byte.
func plistBytes(_ value: Any?) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: try #require(value), format: .binary, options: 0)
}

/// Expects the same keys, each with a byte-identical property-list value.
func expectSameValues(
    _ actual: [String: Any],
    _ expected: [String: Any],
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(Set(actual.keys) == Set(expected.keys), sourceLocation: sourceLocation)
    for (key, value) in expected where actual[key] != nil {
        #expect(try plistBytes(actual[key]) == plistBytes(value), "\(key)", sourceLocation: sourceLocation)
    }
}

/// A date with whole seconds, which survives kept.json's ISO 8601 dates unchanged.
func date(_ secondsSince1970: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(secondsSince1970))
}
