import Foundation
import PickrCore
import Testing
@testable import PickrPersistence

@Suite("Settings repository")
struct SettingsRepositoryTests {
    private typealias Keys = PersistedKeys.Settings

    // MARK: Reading

    @Test(arguments: StoreKind.allCases)
    func absentKeysGiveTheDefaults(kind: StoreKind) {
        let box = kind.make()
        let settings = SettingsRepository(store: box.store).load()

        #expect(settings.grouping.window == TimeWindow(seconds: 60, isCustom: false))
        #expect(settings.grouping.range == ScanRange(preset: .d30, custom: nil))
        #expect(settings.grouping.order == .newest)
        #expect(settings.hapticsEnabled)
        #expect(settings.protectFavorites)
        #expect(!settings.onboardingCompleted)
        #expect(settings.whatsNewSeen == nil)
        #expect(box.snapshot.isEmpty, "Reading writes nothing")
    }

    @Test(arguments: StoreKind.allCases)
    func readsTheV1Fixture(kind: StoreKind) throws {
        let box = kind.make(try V1Fixture.values())
        let settings = SettingsRepository(store: box.store).load()

        #expect(settings.grouping.window == TimeWindow(seconds: 1800, isCustom: true))
        #expect(settings.grouping.range.preset == .custom)
        #expect(settings.grouping.range.custom == CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd))
        #expect(settings.grouping.order == .newest)
        #expect(!settings.hapticsEnabled)
        #expect(settings.protectFavorites)
        #expect(settings.onboardingCompleted)
        #expect(settings.whatsNewSeen == nil)
    }

    @Test(arguments: StoreKind.allCases, [nil, true, false] as [Bool?])
    func absentHapticsMeansOn(kind: StoreKind, stored: Bool?) {
        let box = kind.make(stored.map { [Keys.hapticFeedbackEnabled: $0] } ?? [:])
        #expect(SettingsRepository(store: box.store).load().hapticsEnabled == (stored ?? true))
    }

    struct WindowCase: Sendable, CustomTestStringConvertible {
        let stored: Int?
        let flag: Bool?
        let seconds: Int
        let isCustom: Bool

        var testDescription: String { "\(stored.map(String.init) ?? "absent") s, flag \(flag.map(String.init) ?? "absent")" }
    }

    @Test(arguments: [
        WindowCase(stored: nil, flag: nil, seconds: 60, isCustom: false),
        WindowCase(stored: 10, flag: nil, seconds: 10, isCustom: false),
        WindowCase(stored: 30, flag: nil, seconds: 30, isCustom: false),
        WindowCase(stored: 180, flag: nil, seconds: 180, isCustom: false),
        WindowCase(stored: 45, flag: nil, seconds: 45, isCustom: true),
        WindowCase(stored: 1800, flag: nil, seconds: 1800, isCustom: true),
        WindowCase(stored: 99_999, flag: nil, seconds: 7200, isCustom: true),
        WindowCase(stored: 5, flag: nil, seconds: 10, isCustom: false),
        WindowCase(stored: -60, flag: nil, seconds: 10, isCustom: false),
        WindowCase(stored: 60, flag: true, seconds: 60, isCustom: true),
        WindowCase(stored: 180, flag: true, seconds: 180, isCustom: true),
        WindowCase(stored: 60, flag: false, seconds: 60, isCustom: false),
        WindowCase(stored: 45, flag: false, seconds: 45, isCustom: true),
        WindowCase(stored: nil, flag: true, seconds: 60, isCustom: true),
    ])
    func timeWindowIsClampedAndKeepsItsCustomFlag(_ c: WindowCase) {
        var values: [String: Any] = [:]
        values[Keys.timeWindowSeconds] = c.stored
        values[Keys.timeWindowIsCustom] = c.flag
        let window = SettingsRepository(store: InMemoryKeyValueStore(values)).load().grouping.window

        #expect(window.seconds == c.seconds)
        #expect(window.isCustom == c.isCustom)
    }

    @Test(arguments: ["d7", "d14", "d30", "all"])
    func presetsReadAsStored(raw: String) throws {
        let store = InMemoryKeyValueStore([Keys.scanRangePreset: raw])
        let range = SettingsRepository(store: store).load().grouping.range
        #expect(range.preset == ScanRangePreset(rawValue: raw))
        #expect(range.custom == nil)
    }

    @Test(arguments: ["d90", "", "Custom", "D7", "30"])
    func unknownPresetsReadAsD30(raw: String) {
        let store = InMemoryKeyValueStore([Keys.scanRangePreset: raw])
        #expect(SettingsRepository(store: store).load().grouping.range.preset == .d30)
    }

    @Test(arguments: [(true, false), (false, true), (false, false)])
    func customWithoutBothDatesScansAsD30(hasStart: Bool, hasEnd: Bool) {
        var values: [String: Any] = [Keys.scanRangePreset: "custom"]
        if hasStart { values[Keys.customRangeStart] = V1Fixture.customRangeStart }
        if hasEnd { values[Keys.customRangeEnd] = V1Fixture.customRangeEnd }
        let range = SettingsRepository(store: InMemoryKeyValueStore(values)).load().grouping.range

        #expect(range.preset == .d30)
        #expect(range.custom == nil)
    }

    @Test(arguments: StoreKind.allCases)
    func invertedDatesAreSwapped(kind: StoreKind) {
        let box = kind.make([
            Keys.scanRangePreset: "custom",
            Keys.customRangeStart: V1Fixture.customRangeEnd,
            Keys.customRangeEnd: V1Fixture.customRangeStart,
        ])
        let range = SettingsRepository(store: box.store).load().grouping.range

        #expect(range.preset == .custom)
        #expect(range.custom?.start == V1Fixture.customRangeStart)
        #expect(range.custom?.end == V1Fixture.customRangeEnd)
    }

    @Test func savedDatesSurviveUnderAnotherPreset() {
        let store = InMemoryKeyValueStore([
            Keys.scanRangePreset: "d7",
            Keys.customRangeStart: V1Fixture.customRangeStart,
            Keys.customRangeEnd: V1Fixture.customRangeEnd,
        ])
        let range = SettingsRepository(store: store).load().grouping.range

        #expect(range.preset == .d7)
        #expect(range.custom == CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd))
    }

    @Test(arguments: [("newest", MomentOrder.newest), ("mostSpace", .mostSpace), ("largest", .newest)])
    func momentOrder(raw: String, expected: MomentOrder) {
        let store = InMemoryKeyValueStore([Keys.momentOrder: raw])
        #expect(SettingsRepository(store: store).load().grouping.order == expected)
    }

    @Test func valuesOfTheWrongTypeReadAsAbsent() {
        let store = InMemoryKeyValueStore([
            Keys.timeWindowSeconds: "180",
            Keys.timeWindowIsCustom: "yes",
            Keys.scanRangePreset: 7,
            Keys.customRangeStart: "2026-03-01",
            Keys.customRangeEnd: 1_773_611_999.0,
            Keys.onboardingCompleted: "true",
            Keys.hapticFeedbackEnabled: "no",
            Keys.momentOrder: 1,
            Keys.protectFavorites: Data([0]),
            PersistedKeys.App.whatsNewSeen: 2.0,
        ])
        let settings = SettingsRepository(store: store).load()

        #expect(settings.grouping == GroupingSettings(window: .default, range: .default, order: .newest))
        #expect(settings.hapticsEnabled)
        #expect(settings.protectFavorites)
        #expect(!settings.onboardingCompleted)
        #expect(settings.whatsNewSeen == nil)
    }

    // MARK: Saving

    @Test func savingWhatWasLoadedWritesNothing() throws {
        for values in [try V1Fixture.values(), [:]] {
            let store = RecordingStore(values)
            let repository = SettingsRepository(store: store)
            repository.save(repository.load())
            #expect(store.writtenKeys.isEmpty)
        }
    }

    @Test func savingWritesOnlyTheChangedKey() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.hapticsEnabled = true
        repository.save(settings)

        #expect(store.writtenKeys == [Keys.hapticFeedbackEnabled])
        #expect(store.memory.values[Keys.hapticFeedbackEnabled] as? Bool == true)
    }

    @Test func defaultsStayAbsent() {
        let store = RecordingStore()
        SettingsRepository(store: store).save(
            StoredSettings(
                grouping: GroupingSettings(window: TimeWindow(seconds: 60, isCustom: false), range: ScanRange(preset: .d30)),
                hapticsEnabled: true,
                protectFavorites: true,
                onboardingCompleted: false,
                whatsNewSeen: nil
            )
        )
        #expect(store.writtenKeys.isEmpty)
    }

    static let roundTripCases: [StoredSettings] = [
        StoredSettings(
            grouping: GroupingSettings(window: TimeWindow(seconds: 60, isCustom: true), range: ScanRange(preset: .all), order: .mostSpace),
            hapticsEnabled: false,
            protectFavorites: false,
            onboardingCompleted: true,
            whatsNewSeen: "2.0"
        ),
        StoredSettings(
            grouping: GroupingSettings(
                window: TimeWindow(seconds: 10, isCustom: false),
                range: ScanRange(preset: .custom, custom: CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd))
            ),
            hapticsEnabled: true,
            protectFavorites: true,
            onboardingCompleted: true,
            whatsNewSeen: nil
        ),
        StoredSettings(
            grouping: GroupingSettings(
                window: TimeWindow(seconds: 7200, isCustom: true),
                range: ScanRange(preset: .d14, custom: CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd))
            ),
            hapticsEnabled: false,
            protectFavorites: true,
            onboardingCompleted: false,
            whatsNewSeen: "2.1"
        ),
    ]

    @Test(arguments: StoreKind.allCases, roundTripCases)
    func roundTrip(kind: StoreKind, settings: StoredSettings) throws {
        for values in [try V1Fixture.values(), [:]] {
            let box = kind.make(values)
            SettingsRepository(store: box.store).save(settings)
            #expect(SettingsRepository(store: box.store).load() == settings)
        }
    }

    @Test func everySequenceOfSavesKeepsCustomWithItsDates() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        for settings in Self.roundTripCases + Self.roundTripCases.reversed() {
            repository.save(settings)
            #expect(repository.load() == settings)
        }
        #expect(!store.everStoredCustomWithoutDates)
    }

    @Test(arguments: StoreKind.allCases)
    func savesNativePlistTypes(kind: StoreKind) {
        let box = kind.make()
        // Every key away from its default, so every key is written.
        SettingsRepository(store: box.store).save(
            StoredSettings(
                grouping: GroupingSettings(
                    window: TimeWindow(seconds: 180, isCustom: true),
                    range: ScanRange(preset: .all, custom: CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd)),
                    order: .mostSpace
                ),
                hapticsEnabled: false,
                protectFavorites: false,
                onboardingCompleted: true,
                whatsNewSeen: "2.0"
            )
        )
        let saved = box.snapshot

        #expect(saved[Keys.timeWindowSeconds] as? Int == 180)
        #expect(saved[Keys.timeWindowIsCustom] as? Bool == true)
        #expect(saved[Keys.scanRangePreset] as? String == "all")
        #expect(saved[Keys.customRangeStart] as? Date == V1Fixture.customRangeStart)
        #expect(saved[Keys.customRangeEnd] as? Date == V1Fixture.customRangeEnd)
        #expect(saved[Keys.momentOrder] as? String == "mostSpace")
        #expect(saved[Keys.hapticFeedbackEnabled] as? Bool == false)
        #expect(saved[Keys.protectFavorites] as? Bool == false)
        #expect(saved[Keys.onboardingCompleted] as? Bool == true)
        #expect(saved[PersistedKeys.App.whatsNewSeen] as? String == "2.0")
    }

    /// A custom 1 min must not collapse into the 1 min preset (ARCH A4), even when the flag
    /// was absent and the previous value was a non-preset custom.
    @Test func customOneMinuteAfterACustomValueStaysCustom() {
        let store = InMemoryKeyValueStore([Keys.timeWindowSeconds: 45])
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.window = TimeWindow(seconds: 60, isCustom: true)
        repository.save(settings)

        #expect(repository.load().grouping.window == TimeWindow(seconds: 60, isCustom: true))
    }

    @Test func presetAfterACustomValueIsAPreset() {
        let store = InMemoryKeyValueStore([Keys.timeWindowSeconds: 120])
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.window = TimeWindow(seconds: 180, isCustom: false)
        repository.save(settings)

        #expect(repository.load().grouping.window == TimeWindow(seconds: 180, isCustom: false))
    }

    @Test(arguments: [nil, "d7", "custom", "all"] as [String?])
    func customIsNeverWrittenWithoutDates(storedPreset: String?) {
        var values: [String: Any] = [:]
        values[Keys.scanRangePreset] = storedPreset
        let store = RecordingStore(values)
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.range = ScanRange(preset: .custom, custom: nil)
        repository.save(settings)

        #expect(!store.writes.contains { $0.key == Keys.scanRangePreset && $0.value as? String == "custom" })
        #expect(!store.everStoredCustomWithoutDates)
        #expect(store.memory.values[Keys.customRangeStart] == nil)
        #expect(repository.load().grouping.range.preset == .d30, "It scans as d30, so it is saved as d30")
    }

    @Test func customRangeDatesAreWrittenBeforeThePreset() throws {
        let store = RecordingStore([Keys.scanRangePreset: "d7"])
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.range = ScanRange(
            preset: .custom,
            custom: CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd)
        )
        repository.save(settings)

        let presetWrite = try #require(store.writes.first { $0.key == Keys.scanRangePreset })
        #expect(presetWrite.value as? String == "custom")
        #expect(presetWrite.before[Keys.customRangeStart] as? Date == V1Fixture.customRangeStart)
        #expect(presetWrite.before[Keys.customRangeEnd] as? Date == V1Fixture.customRangeEnd)
        #expect(Set(store.writtenKeys) == [Keys.customRangeStart, Keys.customRangeEnd, Keys.scanRangePreset])
    }

    @Test func applyingACustomRangeAfterTheV1BugStoresIt() {
        // v1 could store `custom` before a range was applied (UX B5).
        let store = InMemoryKeyValueStore([Keys.scanRangePreset: "custom"])
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        #expect(settings.grouping.range.preset == .d30)

        settings.grouping.range = ScanRange(
            preset: .custom,
            custom: CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd)
        )
        repository.save(settings)
        #expect(repository.load().grouping.range == settings.grouping.range)
    }

    @Test func leavingCustomForAPresetKeepsTheDates() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.range.preset = .d7
        repository.save(settings)

        #expect(store.writtenKeys == [Keys.scanRangePreset])
        #expect(repository.load().grouping.range.custom == CustomRange(V1Fixture.customRangeStart, V1Fixture.customRangeEnd))
    }

    @Test func aRangeWithoutDatesRemovesTheStoredDatesAfterThePreset() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.range = ScanRange(preset: .d14, custom: nil)
        repository.save(settings)

        #expect(store.writtenKeys == [Keys.scanRangePreset, Keys.customRangeStart, Keys.customRangeEnd])
        #expect(store.memory.values[Keys.customRangeStart] == nil)
        #expect(store.memory.values[Keys.customRangeEnd] == nil)
        #expect(!store.everStoredCustomWithoutDates)
        #expect(repository.load().grouping.range == settings.grouping.range)
    }

    @Test func aCustomRangeWithoutDatesReplacesAStoredOneWithD30() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        var settings = repository.load()
        settings.grouping.range = ScanRange(preset: .custom, custom: nil)
        repository.save(settings)

        #expect(store.memory.values[Keys.scanRangePreset] as? String == "d30")
        #expect(store.memory.values[Keys.customRangeStart] == nil)
        #expect(!store.everStoredCustomWithoutDates)
    }

    @Test func aV1CustomWithoutDatesIsRepairedByTheFirstSave() {
        // v1 could store `custom` before a range was applied (UX B5). It reads as d30.
        let store = RecordingStore([Keys.scanRangePreset: "custom"])
        let repository = SettingsRepository(store: store)
        repository.save(repository.load())

        #expect(store.writtenKeys == [Keys.scanRangePreset])
        #expect(store.memory.values[Keys.scanRangePreset] as? String == "d30")
    }

    @Test func aLoneStoredDateIsLeftAlone() {
        let store = RecordingStore([Keys.scanRangePreset: "d7", Keys.customRangeStart: V1Fixture.customRangeStart])
        let repository = SettingsRepository(store: store)
        repository.save(repository.load())
        #expect(store.writtenKeys.isEmpty)
    }

    @Test func invertedStoredDatesAreRewrittenInOrderWhenSaved() {
        let store = InMemoryKeyValueStore([
            Keys.scanRangePreset: "custom",
            Keys.customRangeStart: V1Fixture.customRangeEnd,
            Keys.customRangeEnd: V1Fixture.customRangeStart,
        ])
        let repository = SettingsRepository(store: store)
        repository.save(repository.load())

        #expect(store.values[Keys.customRangeStart] as? Date == V1Fixture.customRangeStart)
        #expect(store.values[Keys.customRangeEnd] as? Date == V1Fixture.customRangeEnd)
    }

    @Test func whatsNewSeenIsSetAndCleared() {
        let store = InMemoryKeyValueStore()
        let repository = SettingsRepository(store: store)
        var settings = repository.load()

        settings.whatsNewSeen = "2.0"
        repository.save(settings)
        #expect(store.values[PersistedKeys.App.whatsNewSeen] as? String == "2.0")

        settings.whatsNewSeen = nil
        repository.save(settings)
        #expect(store.values[PersistedKeys.App.whatsNewSeen] == nil)
    }

    @Test func savingNeverTouchesReadOnlyKeys() throws {
        let store = RecordingStore(try V1Fixture.values())
        let repository = SettingsRepository(store: store)
        for settings in Self.roundTripCases {
            repository.save(settings)
        }
        #expect(Set(store.writtenKeys).isDisjoint(with: PersistedKeys.readOnly))
    }
}
