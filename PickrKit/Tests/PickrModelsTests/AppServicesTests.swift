import Foundation
import PickrCore
@testable import PickrModels
import PickrPersistence
import PickrTestSupport
import Testing

private let ids = TestLibrary.ids

/// What a v1 build 8 user has in UserDefaults.
private func v1Defaults() -> InMemoryKeyValueStore {
    InMemoryKeyValueStore([
        PersistedKeys.Settings.timeWindowSeconds: 180,
        PersistedKeys.Settings.scanRangePreset: "d14",
        PersistedKeys.Settings.onboardingCompleted: true,
        PersistedKeys.Settings.hapticFeedbackEnabled: false,
        PersistedKeys.IgnoreList.photoIDs: ["a1", "a2"],
        PersistedKeys.Stats.photosDeleted: 12,
        PersistedKeys.Stats.mbFreed: 1.5,
        PersistedKeys.Stats.clustersCleared: 4,
        PersistedKeys.Stats.firstUseDate: Date(timeIntervalSince1970: 1_750_000_000),
        PersistedKeys.Hint.tapToKeepDismissCount: 1,
    ])
}

private func snapshot(_ store: InMemoryKeyValueStore) -> NSDictionary {
    NSDictionary(dictionary: store.values)
}

@Suite("AppServices: launch (§4.5)")
struct AppServicesLaunchTests {
    @Test func creatingTheServicesWritesNothing() {
        let defaults = v1Defaults()
        let before = snapshot(defaults)

        let h = Harness(defaults: defaults)

        #expect(snapshot(defaults) == before)
        #expect(MigrationV1.isUpgrade(defaults), "upgrade detection still works after init")
        #expect(h.settings.onboardingCompleted, "settings are read at once, so onboarding never flashes")
        #expect(!FileManager.default.fileExists(atPath: h.keptURL.path))
    }

    @Test func aFreshInstall() async throws {
        let h = Harness()
        await h.launch()

        #expect(!h.settings.onboardingCompleted)
        #expect(!h.settings.showsWhatsNew)
        #expect(h.settings.grouping == .default)
        #expect(h.settings.hapticsEnabled)
        #expect(h.settings.protectFavorites)
        #expect(h.settings.stats == LifetimeStats(photosDeleted: 0, bytesFreed: 0, momentsCleared: 0, firstUse: TestLibrary.now))
        #expect(h.defaults.object(forKey: PersistedKeys.App.schemaVersion) as? Int == 2)
        #expect(h.defaults.object(forKey: PersistedKeys.Stats.firstUseDate) as? Date == TestLibrary.now)
        #expect(h.kept.items.isEmpty)
        #expect(h.anchors == ["a1", "b1", "c1"])
    }

    @Test func anUpgraderKeepsEverythingAndSeesWhatsNewOnce() async throws {
        let defaults = v1Defaults()
        let h = Harness(defaults: defaults)
        await h.launch()

        #expect(h.settings.showsWhatsNew)
        #expect(h.settings.onboardingCompleted)
        #expect(!h.settings.hapticsEnabled)
        #expect(h.settings.grouping.window == TimeWindow(seconds: 180, isCustom: false))
        #expect(h.settings.grouping.range.preset == .d14)
        #expect(h.settings.stats.photosDeleted == 12)
        #expect(h.settings.stats.bytesFreed == 1_572_864)
        #expect(h.settings.stats.momentsCleared == 4)
        #expect(h.settings.stats.firstUse == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(h.kept.ids == Set(ids("a1", "a2")))
        #expect(h.kept.items.values.allSatisfy { $0.kind == .legacy && $0.since == nil })
        #expect(h.defaults.object(forKey: PersistedKeys.IgnoreList.photoIDs) as? [String] == ["a1", "a2"])
        #expect(h.anchors == ["b1", "c1"], "v1 Kept photos stay out of moments")

        h.settings.dismissWhatsNew()
        #expect(!h.settings.showsWhatsNew)
        #expect(defaults.object(forKey: PersistedKeys.App.whatsNewSeen) as? String == SettingsModel.whatsNewVersion)

        let relaunch = Harness(defaults: defaults, directory: h.directory)
        await relaunch.launch()
        #expect(!relaunch.settings.showsWhatsNew)
        #expect(relaunch.kept.ids == Set(ids("a1", "a2")))
        withExtendedLifetime(h) {}
    }

    @Test func aFailedMigrationFallsBackToTheV1ListInMemory() async throws {
        let defaults = v1Defaults()
        let directory = Harness.makeTemporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A file where the Pickr folder should be: kept.json can't be saved.
        try Data().write(to: directory.appending(path: "Pickr"))
        let h = Harness(defaults: defaults, directory: directory)

        await h.launch()

        #expect(h.kept.ids == Set(ids("a1", "a2")))
        #expect(h.anchors == ["b1", "c1"])
        #expect(defaults.object(forKey: PersistedKeys.App.schemaVersion) == nil, "the migration retries next launch")
        #expect(h.settings.showsWhatsNew)
    }

    @Test func anUnreadableKeptFileIsRecoveredFromTheV1List() async throws {
        let defaults = v1Defaults()
        let first = Harness(defaults: defaults)
        await first.launch()
        try Data("not json".utf8).write(to: first.keptURL)

        let h = Harness(defaults: defaults, directory: first.directory)
        await h.launch()

        #expect(h.kept.ids == Set(ids("a1", "a2")))
        #expect(try await h.keptFile().items.map(\.id).sorted() == ids("a1", "a2"))
        withExtendedLifetime(first) {}
    }

    @Test func keptSurvivesARelaunch() async throws {
        let h = Harness()
        await h.launch()
        h.curator.keepAside(try h.requireMoment("b1"))
        await h.settle()

        let relaunch = Harness(defaults: h.defaults, directory: h.directory)
        await relaunch.launch()

        #expect(relaunch.kept.items == h.kept.items)
        #expect(relaunch.anchors == ["a1", "c1"])
        withExtendedLifetime(h) {}
    }

    @Test func launchRunsOnce() async {
        let h = Harness()
        async let first: Void = h.services.launch()
        async let second: Void = h.services.launch()
        _ = await (first, second)
        await h.settle()

        #expect(h.fake.calls.access == 1)
        #expect(h.fake.calls.indexEvents == 1)
    }
}

@Suite("SettingsModel")
struct SettingsModelTests {
    @Test func changesAreSavedAndReadBack() async {
        let h = Harness()
        await h.launch()

        h.settings.grouping = GroupingSettings(
            window: .custom(minutes: 3),
            range: ScanRange(preset: .all),
            order: .mostSpace
        )
        h.settings.hapticsEnabled = false
        h.settings.protectFavorites = false
        h.settings.completeOnboarding()

        let relaunch = Harness(defaults: h.defaults, directory: h.directory)
        await relaunch.launch()
        #expect(relaunch.settings.grouping.window == .custom(minutes: 3), "a custom 3 min stays custom")
        #expect(relaunch.settings.grouping.range.preset == .all)
        #expect(relaunch.settings.grouping.order == .mostSpace)
        #expect(!relaunch.settings.hapticsEnabled)
        #expect(!relaunch.settings.protectFavorites)
        #expect(relaunch.settings.onboardingCompleted)
        withExtendedLifetime(h) {}
    }

    @Test func settingTheSameValueWritesNothing() async {
        let h = Harness()
        await h.launch()
        let before = snapshot(h.defaults)

        h.settings.grouping = h.settings.grouping
        h.settings.hapticsEnabled = true
        h.settings.protectFavorites = true

        #expect(snapshot(h.defaults) == before)
    }

    @Test func customRangeIsNeverStoredWithoutDates() async {
        let h = Harness()
        await h.launch()

        h.settings.grouping.range = ScanRange(preset: .custom)

        #expect(h.defaults.object(forKey: PersistedKeys.Settings.scanRangePreset) as? String != "custom")
    }
}

@Suite("ToastCenter")
struct ToastCenterTests {
    @Test func undoRunsOnceAndDismisses() async {
        let toasts = ToastCenter()
        toasts.displayDuration = .seconds(600)
        let runs = Counter()
        toasts.show("Moment kept aside") { _ = runs.next() }

        #expect(toasts.current?.message == "Moment kept aside")
        #expect(toasts.current?.canUndo == true)
        #expect(toasts.current?.isError == false)

        await toasts.performUndo()
        await toasts.performUndo()
        #expect(runs.current == 1)
        #expect(toasts.current == nil)
    }

    @Test func retryRunsOnlyForErrors() async {
        let toasts = ToastCenter()
        toasts.displayDuration = .seconds(600)
        let runs = Counter()

        toasts.show("Restored 2 photos")
        await toasts.performRetry()
        #expect(toasts.current != nil, "a plain toast has no Try Again")

        toasts.showError("Couldn't delete the photos.") { _ = runs.next() }
        #expect(toasts.current?.isError == true)
        #expect(toasts.current?.canUndo == false)
        await toasts.performUndo()
        #expect(runs.current == 0)
        await toasts.performRetry()
        #expect(runs.current == 1)
        #expect(toasts.current == nil)
    }

    @Test func aNewToastReplacesTheOldOneAndItsUndo() async throws {
        let toasts = ToastCenter()
        toasts.displayDuration = .seconds(600)
        let runs = Counter()
        toasts.show("First") { _ = runs.next() }
        let first = toasts.current?.id

        toasts.show("Second")
        await toasts.performUndo()

        #expect(toasts.current?.message == "Second")
        #expect(runs.current == 0)
        toasts.dismiss(try #require(first))
        #expect(toasts.current?.message == "Second", "a stale id never dismisses a newer toast")
    }

    @Test func toastsDismissThemselves() async {
        let toasts = ToastCenter()
        toasts.displayDuration = .milliseconds(20)
        toasts.show("Moved 2 photos to Recently Deleted")

        #expect(await eventually { toasts.current == nil })
    }
}
