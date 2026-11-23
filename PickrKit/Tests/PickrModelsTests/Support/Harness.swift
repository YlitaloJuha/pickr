import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Synchronization
import Testing

/// Test data on a fixed clock and calendar.
nonisolated enum TestLibrary {
    /// 2026-09-21 14:13:20 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// `count` photos named `<prefix>1…`, `spacing` seconds apart, the first `daysAgo` days
    /// before `now`. `favorites` and `ratings` are 1-based photo numbers.
    static func burst(
        _ prefix: String,
        count: Int,
        daysAgo: Double,
        spacing: TimeInterval = 5,
        favorites: Set<Int> = [],
        ratings: [Int: Int] = [:]
    ) -> [AssetRecord] {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return (1...count).map { number in
            AssetRecord(
                id: PhotoID("\(prefix)\(number)"),
                created: start.addingTimeInterval(TimeInterval(number - 1) * spacing),
                isFavorite: favorites.contains(number),
                rating: ratings[number] ?? 0
            )
        }
    }

    /// Three moments at a 1 min window, newest first: a (3 photos, 1 day ago),
    /// b (4 photos, 2 days ago), c (2 photos, 3 days ago).
    static var standard: [AssetRecord] {
        burst("a", count: 3, daysAgo: 1) + burst("b", count: 4, daysAgo: 2) + burst("c", count: 2, daysAgo: 3)
    }

    static func ids(_ raw: String...) -> [PhotoID] {
        raw.map(PhotoID.init)
    }

    static func id(_ raw: String) -> PhotoID {
        PhotoID(raw)
    }

    /// The same size for every record.
    static func sizes(_ records: [AssetRecord], bytes: Int64 = 1_000_000) -> SizeTable {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, bytes) })
    }
}

/// A full model graph over a `FakePhotoLibrary`, an in-memory UserDefaults and a temporary
/// kept.json.
@MainActor
final class Harness {
    let fake: FakePhotoLibrary
    let defaults: InMemoryKeyValueStore
    let directory: URL
    let services: AppServices
    /// Only the harness that created the directory deletes it.
    private let ownsDirectory: Bool

    var library: LibraryModel { services.library }
    var settings: SettingsModel { services.settings }
    var kept: KeptModel { services.kept }
    var curator: Curator { services.curator }
    var router: Router { services.router }
    var toasts: ToastCenter { services.toasts }
    var keptURL: URL { Self.keptURL(in: directory) }

    init(
        records: [AssetRecord] = TestLibrary.standard,
        access: LibraryAccess = .full,
        sizes: SizeTable = [:],
        defaults: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        directory: URL? = nil,
        now: Date = TestLibrary.now
    ) {
        fake = FakePhotoLibrary(records: records, access: access, sizes: sizes)
        self.defaults = defaults
        ownsDirectory = directory == nil
        self.directory = directory ?? Self.makeTemporaryDirectoryURL()
        services = AppServices(
            client: fake,
            defaults: defaults,
            keptURL: Self.keptURL(in: self.directory),
            now: { now }
        )
        services.library.calendar = TestLibrary.calendar
        services.library.sizeRegroupDelay = .zero
        services.toasts.displayDuration = .seconds(600)
    }

    deinit {
        if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A new, unique path under the temporary directory (not created).
    nonisolated static func makeTemporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "PickrModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    nonisolated static func keptURL(in directory: URL) -> URL {
        directory.appending(path: "Pickr/kept.json", directoryHint: .notDirectory)
    }

    /// Launches and waits until the first events are handled and grouped.
    func launch() async {
        await services.launch()
        await settle()
    }

    /// Waits until every index event sent so far is handled and the models are idle.
    func settle(sourceLocation: SourceLocation = #_sourceLocation) async {
        let handled = await eventually { self.library.handledEvents >= self.fake.yieldedEvents }
        if !handled {
            Issue.record("Index events were not handled in time", sourceLocation: sourceLocation)
        }
        await library.settle()
        await kept.flush()
        await library.settle()
    }

    /// The anchors of the listed moments, in list order.
    var anchors: [String] {
        library.moments.moments.map(\.id.anchor.rawValue)
    }

    /// The listed moment anchored at `raw`.
    func moment(_ raw: String) -> Moment? {
        library.moment(MomentID(anchor: PhotoID(raw)))
    }

    /// The listed moment anchored at `raw`; records an issue when it isn't listed.
    func requireMoment(_ raw: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> Moment {
        try #require(moment(raw), "moment \(raw) is not listed", sourceLocation: sourceLocation)
    }

    /// The kept.json on disk now.
    func keptFile() async throws -> KeptFile {
        try await KeptStore(url: keptURL).load()
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// A one-shot gate that async code can wait on until a test opens it.
nonisolated final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state in
                guard !state.isOpen else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }
}

/// A thread-safe counter.
nonisolated final class Counter: Sendable {
    private let value = Mutex(0)

    /// Adds one and returns the new value.
    func next() -> Int {
        value.withLock { value in
            value += 1
            return value
        }
    }

    var current: Int {
        value.withLock { $0 }
    }
}
