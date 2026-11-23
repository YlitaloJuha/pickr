#if DEBUG
import Foundation
import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI
import TipKit

/// Demo mode records the README demos on a real device (`scripts/demo-gifs.sh`,
/// docs/RELEASING.md) without ever touching the person's own photos or data.
///
/// A Debug build launched with `-PickrDemo YES`:
/// - shows the 40 synthetic photos of test-photos/, bundled in Debug builds only;
/// - never touches PhotoKit: `LiveServices` builds `DemoPhotoLibrary` and `DemoImageLoader`
///   instead of the live client and loader, so no authorization request, index cache or
///   change observer exists. Deletes happen in memory with no iOS dialog, and the live
///   classes refuse demo mode as a second guard (`Deleter.refuseInDemoMode`, preconditions);
/// - keeps settings, stats and Kept in memory and in a fresh folder in the app's temporary
///   directory, and TipKit in its own datastore there with every tip hidden;
/// - starts with onboarding done and Look back set to Everything, so the photos show.
///
/// `-PickrDemoAppearance light|dark` forces the colour scheme. The UI tests look for the
/// `pickr.demo-mode` accessibility marker before they touch anything. Release builds contain
/// none of this (policy check 22).
nonisolated enum DemoMode {
    static let isActive = isRequested(in: ProcessInfo.processInfo.arguments)
    static let colorScheme = colorScheme(in: ProcessInfo.processInfo.arguments)
    /// The identifier `DemoRecordingTests` requires before its first tap.
    static let accessibilityMarker = "pickr.demo-mode"

    /// `-PickrDemo YES` (or `1`, `true`) among the launch arguments.
    static func isRequested(in arguments: [String]) -> Bool {
        guard let value = value(after: "-PickrDemo", in: arguments) else { return false }
        return ["yes", "1", "true"].contains(value.lowercased())
    }

    /// `-PickrDemoAppearance light|dark`; anything else follows the system.
    static func colorScheme(in arguments: [String]) -> ColorScheme? {
        switch value(after: "-PickrDemoAppearance", in: arguments)?.lowercased() {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Demo mode's object graph: nothing here reaches PhotoKit, the real settings or real files.
enum DemoServices {
    /// A new folder in the app's temporary directory at every launch, so every demo starts
    /// the same.
    static let scratch = FileManager.default.temporaryDirectory
        .appending(path: "PickrDemo-\(UUID().uuidString)", directoryHint: .isDirectory)

    /// Onboarding done, the migration complete (a fresh install: no What's New) and Look back
    /// Everything, because the test photos were taken on 12 April 2026.
    static func makeDefaults() -> InMemoryKeyValueStore {
        InMemoryKeyValueStore([
            PersistedKeys.Settings.onboardingCompleted: true,
            PersistedKeys.Settings.scanRangePreset: ScanRangePreset.all.rawValue,
            // `MigrationV1`'s completed schema version.
            PersistedKeys.App.schemaVersion: 2,
        ])
    }

    static func makeServices(defaults: any KeyValueStore) -> AppServices {
        AppServices(
            client: DemoPhotoLibrary(),
            defaults: defaults,
            keptURL: scratch.appending(path: "kept.json", directoryHint: .notDirectory),
            now: { .now }
        )
    }

    /// Tips stay out of the recordings, and TipKit's real datastore is never opened.
    static func configureTips() {
        let folder = scratch.appending(path: "Tips", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Tips.hideAllTipsForTesting()
        try? Tips.configure([.datastoreLocation(.url(folder))])
    }
}

/// In demo mode: the forced colour scheme and the accessibility marker the demo UI tests
/// require. Does nothing otherwise.
struct DemoModeDecorations: ViewModifier {
    func body(content: Content) -> some View {
        if DemoMode.isActive {
            content
                .preferredColorScheme(DemoMode.colorScheme)
                .overlay(alignment: .topLeading) {
                    // Invisible, but an accessibility element UI tests can find.
                    Text(verbatim: "Demo mode")
                        .font(.system(size: 1))
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier(DemoMode.accessibilityMarker)
                }
        } else {
            content
        }
    }
}
#endif
