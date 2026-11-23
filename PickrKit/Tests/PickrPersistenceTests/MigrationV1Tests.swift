import Foundation
import PickrCore
import Testing
@testable import PickrPersistence

@Suite("Migration from v1")
struct MigrationV1Tests {
    private static let now = date(1_795_255_200)
    private static let legacyItems = V1Fixture.photoIDs.map { KeptItem(id: PhotoID($0), kind: .legacy, since: nil) }

    // MARK: The fixture

    @Test func theFixtureHoldsEveryV1KeyWithItsExactType() throws {
        let values = try V1Fixture.values()
        #expect(Set(values.keys) == Set(PersistedKeys.legacy))

        #expect(values[PersistedKeys.Settings.timeWindowSeconds] is Int)
        #expect(values[PersistedKeys.Settings.scanRangePreset] is String)
        #expect(values[PersistedKeys.Settings.customRangeStart] is Date)
        #expect(values[PersistedKeys.Settings.customRangeEnd] is Date)
        #expect(values[PersistedKeys.Settings.onboardingCompleted] is Bool)
        #expect(values[PersistedKeys.Settings.hapticFeedbackEnabled] is Bool)
        #expect(values[PersistedKeys.IgnoreList.photoIDs] as? [String] == V1Fixture.photoIDs)
        #expect(values[PersistedKeys.Stats.photosDeleted] is Int)
        #expect(values[PersistedKeys.Stats.mbFreed] as? Double == 1.5)
        #expect(values[PersistedKeys.Stats.clustersCleared] is Int)
        #expect(values[PersistedKeys.Stats.firstUseDate] as? Date == V1Fixture.firstUseDate)
        #expect(values[PersistedKeys.Settings.customRangeStart] as? Date == V1Fixture.customRangeStart)
        #expect(values[PersistedKeys.Settings.customRangeEnd] as? Date == V1Fixture.customRangeEnd)
    }

    // MARK: Upgrade detection

    @Test func isUpgradeFollowsTheV1Marks() {
        typealias S = PersistedKeys.Settings
        typealias T = PersistedKeys.Stats
        #expect(!MigrationV1.isUpgrade(InMemoryKeyValueStore()))
        #expect(MigrationV1.isUpgrade(InMemoryKeyValueStore([S.onboardingCompleted: true])))
        #expect(!MigrationV1.isUpgrade(InMemoryKeyValueStore([S.onboardingCompleted: false])))
        #expect(MigrationV1.isUpgrade(InMemoryKeyValueStore([T.firstUseDate: V1Fixture.firstUseDate])))
        #expect(MigrationV1.isUpgrade(InMemoryKeyValueStore([S.onboardingCompleted: false, T.firstUseDate: Self.now])))
        #expect(!MigrationV1.isUpgrade(InMemoryKeyValueStore([S.hapticFeedbackEnabled: true])))
        #expect(!MigrationV1.isUpgrade(InMemoryKeyValueStore([
            S.onboardingCompleted: true,
            T.firstUseDate: Self.now,
            PersistedKeys.App.schemaVersion: 2,
        ])), "A completed migration is no longer an upgrade")
    }

    /// The §4.5 launch order, twice: What's New and the tip mapping need `isUpgrade` to be
    /// true on an upgrader's first v2 launch only, and never true for a fresh install.
    @Test(arguments: [true, false])
    func launchOrder(upgrader: Bool) async throws {
        let folder = try TemporaryDirectory()
        let store = upgrader ? try V1Fixture.inMemory() : InMemoryKeyValueStore()
        let kept = KeptStore(url: folder.keptURL)

        for launch in 1...2 {
            let wasUpgrade = MigrationV1.isUpgrade(store)
            let report = try await MigrationV1.run(store: store, kept: kept, now: Self.now)
            _ = StatsRepository(store: store).load(now: Self.now)
            var settings = SettingsRepository(store: store).load()
            if launch == 1 { settings.onboardingCompleted = true }
            SettingsRepository(store: store).save(settings)

            #expect(wasUpgrade == (upgrader && launch == 1), "Launch \(launch)")
            #expect(report.wasUpgrade == wasUpgrade, "Launch \(launch)")
        }
    }

    // MARK: Upgrading

    @Test(arguments: StoreKind.allCases)
    func upgradesTheV1Fixture(kind: StoreKind) async throws {
        let folder = try TemporaryDirectory()
        let box = kind.make(try V1Fixture.values())
        let before = box.snapshot

        let report = try await MigrationV1.run(store: box.store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: true, importedKeptIDs: 3, bytesFreed: 1_572_864))
        let file = try await KeptStore(url: folder.keptURL).load()
        #expect(file.items == Self.legacyItems)
        #expect(file.orphans.isEmpty)

        let after = box.snapshot
        #expect(after[PersistedKeys.Stats.bytesFreed] as? Int64 == 1_572_864)
        #expect(after[PersistedKeys.Settings.timeWindowIsCustom] as? Bool == true)
        #expect(after[PersistedKeys.App.schemaVersion] as? Int == 2)
        let added: Set = [
            PersistedKeys.Stats.bytesFreed,
            PersistedKeys.Settings.timeWindowIsCustom,
            PersistedKeys.App.schemaVersion,
        ]
        #expect(Set(after.keys) == Set(before.keys).union(added))
        try expectSameValues(after.filter { !added.contains($0.key) }, before)
    }

    @Test func theV1KeptListIsNeverWritten() async throws {
        let folder = try TemporaryDirectory()
        let store = RecordingStore(try V1Fixture.values())
        let before = try plistBytes(store.object(forKey: PersistedKeys.IgnoreList.photoIDs))

        _ = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)
        _ = StatsRepository(store: store).load(now: Self.now)
        _ = StatsRepository(store: store).record(deleted: 2, bytes: 2_000, momentCleared: true)
        var settings = SettingsRepository(store: store).load()
        settings.grouping.window = TimeWindow(seconds: 30, isCustom: false)
        settings.whatsNewSeen = "2.0"
        SettingsRepository(store: store).save(settings)
        _ = LegacyTips.seen(in: store)
        _ = MigrationV1.legacyKeptIDs(in: store)

        #expect(try plistBytes(store.object(forKey: PersistedKeys.IgnoreList.photoIDs)) == before)
        #expect(Set(store.writtenKeys).isDisjoint(with: PersistedKeys.readOnly))
    }

    @Test func theSchemaVersionIsWrittenLast() async throws {
        let folder = try TemporaryDirectory()
        let store = RecordingStore(try V1Fixture.values())
        _ = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(store.writtenKeys == [
            PersistedKeys.Stats.bytesFreed,
            PersistedKeys.Settings.timeWindowIsCustom,
            PersistedKeys.App.schemaVersion,
        ])
    }

    @Test func aFreshInstallOnlyGetsTheSchemaVersion() async throws {
        let folder = try TemporaryDirectory()
        let store = RecordingStore()
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: false, importedKeptIDs: 0, bytesFreed: nil))
        #expect(store.writtenKeys == [PersistedKeys.App.schemaVersion])
        #expect(store.memory.values[PersistedKeys.App.schemaVersion] as? Int == 2)
        #expect(try folder.contents(of: folder.url).isEmpty, "No kept.json without anything to keep")
    }

    @Test func anUpgraderWithoutAKeptListGetsNoFile() async throws {
        let folder = try TemporaryDirectory()
        var values = try V1Fixture.values()
        values[PersistedKeys.IgnoreList.photoIDs] = nil
        let store = InMemoryKeyValueStore(values)
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: true, importedKeptIDs: 0, bytesFreed: 1_572_864))
        #expect(try folder.contents(of: folder.url).isEmpty)
        #expect(store.values[PersistedKeys.App.schemaVersion] as? Int == 2)
    }

    // MARK: Reading the v1 Kept list

    @Test(arguments: StoreKind.allCases)
    func theKeptListAsStringsImportsAsLegacyItems(kind: StoreKind) async throws {
        let folder = try TemporaryDirectory()
        let box = kind.make([
            PersistedKeys.Stats.firstUseDate: V1Fixture.firstUseDate,
            PersistedKeys.IgnoreList.photoIDs: V1Fixture.photoIDs,
        ])
        let report = try await MigrationV1.run(store: box.store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.importedKeptIDs == 3)
        #expect(try await KeptStore(url: folder.keptURL).load().items == Self.legacyItems)
    }

    enum WrongKeptList: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case jsonData, string, integers, mixed, dictionary, misnamedKey

        var testDescription: String { rawValue }

        func values() throws -> [String: Any] {
            let key = PersistedKeys.IgnoreList.photoIDs
            return switch self {
            case .jsonData: [key: try JSONEncoder().encode(V1Fixture.photoIDs)]
            case .string: [key: V1Fixture.photoIDs[0]]
            case .integers: [key: [1, 2, 3]]
            case .mixed: [key: [V1Fixture.photoIDs[0], 2] as [Any]]
            case .dictionary: [key: ["ids": V1Fixture.photoIDs]]
            // The v1 spec's name for the list; v1 never wrote it.
            case .misnamedKey: ["ignoreList.ids": try JSONEncoder().encode(V1Fixture.photoIDs)]
            }
        }
    }

    @Test(arguments: WrongKeptList.allCases)
    func aKeptListOfAnotherTypeIsIgnored(_ wrong: WrongKeptList) async throws {
        let folder = try TemporaryDirectory()
        var values = try wrong.values()
        values[PersistedKeys.Stats.firstUseDate] = V1Fixture.firstUseDate
        let store = InMemoryKeyValueStore(values)
        let original = try plistBytes(values.first { $0.key != PersistedKeys.Stats.firstUseDate }?.value)

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: true, importedKeptIDs: 0, bytesFreed: 0))
        #expect(MigrationV1.legacyKeptIDs(in: store).isEmpty)
        #expect(try folder.contents(of: folder.url).isEmpty)
        #expect(store.values[PersistedKeys.App.schemaVersion] as? Int == 2)
        let kept = try #require(store.values.first { $0.key.hasPrefix("ignoreList.") }?.value)
        #expect(try plistBytes(kept) == original, "Left exactly as it was")
    }

    @Test func duplicateAndEmptyIDsAreDropped() async throws {
        let folder = try TemporaryDirectory()
        let ids = V1Fixture.photoIDs
        let store = InMemoryKeyValueStore([
            PersistedKeys.Settings.onboardingCompleted: true,
            PersistedKeys.IgnoreList.photoIDs: [ids[1], "", ids[0], ids[1], ids[2], ids[0]],
        ])
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.importedKeptIDs == 3)
        #expect(try await KeptStore(url: folder.keptURL).load().items.map(\.id.rawValue) == [ids[1], ids[0], ids[2]])
    }

    @Test(.timeLimit(.minutes(1)))
    func aLargeKeptListImportsInFull() async throws {
        let folder = try TemporaryDirectory()
        let ids = (0..<50_000).map { String(format: "%08lX-0000-4000-8000-%012lX/L0/001", $0, $0) }
        let store = InMemoryKeyValueStore([
            PersistedKeys.Settings.onboardingCompleted: true,
            PersistedKeys.IgnoreList.photoIDs: ids,
        ])
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.importedKeptIDs == 50_000)
        let file = try await KeptStore(url: folder.keptURL).load()
        #expect(file.items.count == 50_000)
        #expect(file.items.allSatisfy { $0.kind == .legacy && $0.since == nil })
    }

    // MARK: Stats and window

    struct WindowFlagCase: Sendable, CustomTestStringConvertible {
        let seconds: Int?
        let isCustom: Bool
        var testDescription: String { seconds.map { "\($0) s" } ?? "absent" }
    }

    @Test(arguments: [
        WindowFlagCase(seconds: nil, isCustom: false),
        WindowFlagCase(seconds: 10, isCustom: false),
        WindowFlagCase(seconds: 60, isCustom: false),
        WindowFlagCase(seconds: 180, isCustom: false),
        WindowFlagCase(seconds: 45, isCustom: true),
        WindowFlagCase(seconds: 120, isCustom: true),
        WindowFlagCase(seconds: 99_999, isCustom: true),
        WindowFlagCase(seconds: 5, isCustom: false),
    ])
    func theWindowFlagIsWrittenFromTheClampedSeconds(_ c: WindowFlagCase) async throws {
        let folder = try TemporaryDirectory()
        var values: [String: Any] = [PersistedKeys.Settings.onboardingCompleted: true]
        values[PersistedKeys.Settings.timeWindowSeconds] = c.seconds
        let store = InMemoryKeyValueStore(values)
        _ = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(store.values[PersistedKeys.Settings.timeWindowIsCustom] as? Bool == c.isCustom)
        #expect((store.values[PersistedKeys.Settings.timeWindowSeconds] as? Int) == c.seconds, "Seconds are left as stored")
    }

    @Test func existingV2KeysAreNotOverwritten() async throws {
        let folder = try TemporaryDirectory()
        var values = try V1Fixture.values()
        values[PersistedKeys.Stats.bytesFreed] = Int64(42)
        values[PersistedKeys.Settings.timeWindowIsCustom] = false
        let store = RecordingStore(values)

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.bytesFreed == nil)
        #expect(store.writtenKeys == [PersistedKeys.App.schemaVersion])
        #expect(store.memory.values[PersistedKeys.Stats.bytesFreed] as? Int64 == 42)
        #expect(store.memory.values[PersistedKeys.Settings.timeWindowIsCustom] as? Bool == false)
    }

    @Test func anUpgraderWithoutMbFreedStartsAtZeroBytes() async throws {
        let folder = try TemporaryDirectory()
        let store = InMemoryKeyValueStore([PersistedKeys.Stats.firstUseDate: V1Fixture.firstUseDate])
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.bytesFreed == 0)
        #expect(store.values[PersistedKeys.Stats.bytesFreed] as? Int64 == 0)
        #expect(store.values[PersistedKeys.Stats.mbFreed] == nil)
    }

    // MARK: Idempotency and crash safety

    @Test func aSecondRunChangesNothing() async throws {
        let folder = try TemporaryDirectory()
        let store = RecordingStore(try V1Fixture.values())
        let kept = KeptStore(url: folder.keptURL)
        _ = try await MigrationV1.run(store: store, kept: kept, now: Self.now)
        let writes = store.writes.count
        let file = try Data(contentsOf: folder.keptURL)

        let second = try await MigrationV1.run(store: store, kept: kept, now: Self.now)

        #expect(second == MigrationV1.Report(wasUpgrade: false, importedKeptIDs: 0, bytesFreed: nil))
        #expect(store.writes.count == writes)
        #expect(try Data(contentsOf: folder.keptURL) == file)
    }

    /// Even when forced to run again (as after a crash just before the schema version was
    /// written), the migration ends in the same state.
    @Test func aRepeatedRunGivesTheSameResult() async throws {
        let folder = try TemporaryDirectory()
        let store = try V1Fixture.inMemory()
        let kept = KeptStore(url: folder.keptURL)
        _ = try await MigrationV1.run(store: store, kept: kept, now: Self.now)
        let values = store.values
        let file = try Data(contentsOf: folder.keptURL)

        store.removeObject(forKey: PersistedKeys.App.schemaVersion)
        let again = try await MigrationV1.run(store: store, kept: kept, now: Self.now)

        #expect(again == MigrationV1.Report(wasUpgrade: true, importedKeptIDs: 0, bytesFreed: nil))
        try expectSameValues(store.values, values)
        #expect(try Data(contentsOf: folder.keptURL) == file)
    }

    @Test func aPartialEarlierRunIsMerged() async throws {
        let folder = try TemporaryDirectory()
        let ids = V1Fixture.photoIDs.map(PhotoID.init)
        let reviewed = PhotoID("D4E5F6A7-B8C9-4D0E-8F1A-2B3C4D5E6F70/L0/001")
        // Left by an earlier run that crashed after saving, and then used: ids[0] was kept
        // aside again, a reviewed item was added, and ids[2] was pruned as gone.
        let earlier = KeptFile(
            items: [
                KeptItem(id: ids[0], kind: .keptAside, since: date(1_795_000_000)),
                KeptItem(id: reviewed, kind: .reviewed, since: date(1_795_000_100)),
            ],
            orphans: [KeptItem(id: ids[2], kind: .legacy)]
        )
        let kept = KeptStore(url: folder.keptURL)
        try await kept.save(earlier)
        let store = try V1Fixture.inMemory()

        let report = try await MigrationV1.run(store: store, kept: kept, now: Self.now)

        #expect(report.importedKeptIDs == 1)
        let file = try await kept.load()
        #expect(file.items == earlier.items + [KeptItem(id: ids[1], kind: .legacy)], "Existing items win")
        #expect(file.orphans == earlier.orphans, "Orphans don't come back")
        #expect(store.values[PersistedKeys.App.schemaVersion] as? Int == 2)
    }

    @Test func aFailedSaveLeavesTheSchemaVersionUnset() async throws {
        let folder = try TemporaryDirectory()
        // A file where the Pickr folder should be: kept.json can't be written.
        try Data("blocker".utf8).write(to: folder.url.appending(path: "Pickr", directoryHint: .notDirectory))
        let store = RecordingStore(try V1Fixture.values())

        await #expect(throws: (any Error).self) {
            try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)
        }
        #expect(store.writtenKeys.isEmpty, "Nothing after the Kept merge, so no schema version")
        #expect(MigrationV1.isUpgrade(store))
        #expect(MigrationV1.legacyKeptIDs(in: store) == V1Fixture.photoIDs.map(PhotoID.init),
                "KeptModel can fall back to the v1 list")

        // The next launch, with a writable folder, retries and completes.
        let retryFolder = try TemporaryDirectory()
        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: retryFolder.keptURL), now: Self.now)
        #expect(report == MigrationV1.Report(wasUpgrade: true, importedKeptIDs: 3, bytesFreed: 1_572_864))
        #expect(store.memory.values[PersistedKeys.App.schemaVersion] as? Int == 2)
    }

    @Test func anUnreadableKeptFileIsPreservedAndTheMigrationCompletes() async throws {
        let folder = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.keptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(to: folder.keptURL)
        let store = try V1Fixture.inMemory()

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report.importedKeptIDs == 3)
        #expect(try await KeptStore(url: folder.keptURL).load().items == Self.legacyItems)
        let names = try folder.contents(of: folder.keptURL.deletingLastPathComponent())
        #expect(names.count == 2)
        #expect(names.contains("kept.json"))
        #expect(names.contains { $0.hasPrefix("kept.unreadable-") })
    }

    @Test func aNewerKeptFileStopsTheMigration() async throws {
        let folder = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: folder.keptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = Data(#"{"version":3,"items":[]}"#.utf8)
        try newer.write(to: folder.keptURL)
        let store = RecordingStore(try V1Fixture.values())

        await #expect(throws: KeptStoreError.unsupportedVersion(3)) {
            try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)
        }
        #expect(store.writtenKeys.isEmpty)
        #expect(try Data(contentsOf: folder.keptURL) == newer)
    }

    @Test func aCompletedMigrationIgnoresTheV1List() async throws {
        let folder = try TemporaryDirectory()
        var values = try V1Fixture.values()
        values[PersistedKeys.App.schemaVersion] = 2
        let store = RecordingStore(values)

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: false, importedKeptIDs: 0, bytesFreed: nil))
        #expect(store.writtenKeys.isEmpty)
        #expect(try folder.contents(of: folder.url).isEmpty)
    }

    @Test func aKeptListWithoutOtherV1MarksIsStillImported() async throws {
        let folder = try TemporaryDirectory()
        let store = RecordingStore([PersistedKeys.IgnoreList.photoIDs: V1Fixture.photoIDs])

        let report = try await MigrationV1.run(store: store, kept: KeptStore(url: folder.keptURL), now: Self.now)

        #expect(report == MigrationV1.Report(wasUpgrade: false, importedKeptIDs: 3, bytesFreed: nil))
        #expect(store.writtenKeys == [PersistedKeys.App.schemaVersion])
        #expect(try await KeptStore(url: folder.keptURL).load().items == Self.legacyItems)
    }
}
