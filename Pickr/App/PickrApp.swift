import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

/// The app entry point and the dependency-injection convention every screen relies on:
///
/// - The `@Observable` models are in the environment by type. Read them with
///   `@Environment(LibraryModel.self)`, `SettingsModel`, `KeptModel`, `ToastCenter`, `Router`.
/// - `Curator`, the only mutation path, is `@Environment(\.curator)`.
/// - The image loader is `@Environment(\.imageLoader)`, one per display scale.
///
/// One window (`UIApplicationSupportsMultipleScenes` = NO, ADAPTIVE D3): the services and the
/// Router are app-wide. The menu bar commands (ADAPTIVE §7) read the focused scene's state.
@main
struct PickrApp: App {
    private let services: AppServices

    init() {
        LaunchSignpost.begin()
        PickrTips.configure()
        services = LiveServices.makeServices()
    }

    var body: some Scene {
        WindowGroup {
            AppScene(services: services)
        }
        .commands {
            PickrCommands()
        }
    }
}

/// The window's content: injects the models and the image loader for the scene's display
/// scale, runs the launch sequence once and refreshes the library when the app comes back
/// to the foreground (access may have changed in Settings, photos in the Photos app).
private struct AppScene: View {
    let services: AppServices

    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    @State private var imageLoaders = ImageLoaders()
    /// `AppServices.launch()` has finished; until then launch itself reads the access.
    @State private var hasLaunched = false
    /// The app went to the background since the last refresh. A Control Center pull or the
    /// iOS photo prompt only makes it inactive and needs no refresh.
    @State private var wasInBackground = false

    var body: some View {
        RootView()
            .environment(services.settings)
            .environment(services.kept)
            .environment(services.library)
            .environment(services.toasts)
            .environment(services.router)
            .environment(\.curator, services.curator)
            .environment(\.imageLoader, imageLoaders.loader(for: displayScale))
            .environment(\.hasFinishedLaunch, hasLaunched)
            #if DEBUG
            .modifier(DemoModeDecorations())
            #endif
            .task {
                await launch()
                hasLaunched = true
            }
            .onChange(of: isSettled, initial: true) { _, settled in
                if settled { LaunchSignpost.end() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    wasInBackground = true
                case .active:
                    guard wasInBackground, hasLaunched else { return }
                    wasInBackground = false
                    Task { await services.library.refresh() }
                default:
                    break
                }
            }
    }

    /// Launch has finished and the library shows something other than a loading state.
    private var isSettled: Bool {
        guard hasLaunched else { return false }
        let library = services.library
        switch library.phase {
        case .ready, .failed: return true
        case .idle, .indexing: return library.access != .full && library.access != .limited
        }
    }

    private func launch() async {
        let defaults = LiveServices.defaults
        // Evaluated before launch() writes the first-use date (§4.5 step 1).
        let isUpgrade = MigrationV1.isUpgrade(defaults)
        await services.launch()
        PickrTips.applyLegacyState(LegacyTips.seen(in: defaults), isUpgrade: isUpgrade)
    }
}

extension EnvironmentValues {
    /// The only path for deletes, Kept changes and stats. `nil` only in previews.
    @Entry var curator: Curator? = nil
    /// `false` until `AppServices.launch()` has read the photo access. Before then the access
    /// is still `.notDetermined`, which means "not read yet", not "never asked", so screens
    /// show a loading state rather than the access primer. `true` in previews.
    @Entry var hasFinishedLaunch = true
}
