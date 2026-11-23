import PickrCore
import PickrModels
import SwiftUI

/// The app's root (§3.1, ADAPTIVE §3.1): onboarding for new users, otherwise the Moments and
/// Kept tabs.
///
/// - Onboarding is the root content, not an overlay, so the tabs and their bars don't exist
///   until it is done. `onboardingCompleted` is right from the first frame (AppServices reads
///   the settings when it is created), so upgraders never see it flash.
/// - The tabs: `.tabBarOnly` (a bottom tab bar when compact, a top tab bar when regular,
///   no sidebar mode), never minimizing. Each tab is a column container that measures itself.
/// - The bottom accessory (Clean Up 7 Moments) shows on both tabs while the Moments tab is
///   stacked, at its root, with its list showing, so switching tabs never resizes the tab bar
///   (owner feedback 2026-11-22: a Moments-only accessory made the bar jump). From Kept it
///   switches to Moments and starts there. The split shows `ReviewStartView` instead.
/// - What's New is presented once to upgraders, from `router.sheet` (the one sheet); any way
///   of closing it records it as seen. Settings and Adjust are presented by the Moments tab.
/// - Publishes the menu bar's state (`\.appCommands`, PickrCommands.swift) and plays the
///   haptics of actions started there, and of commits started in Review or the Moments list.
struct RootView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if settings.onboardingCompleted {
                MainTabs()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                OnboardingView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.04)))
            }
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.22) : .smooth(duration: 0.45),
            value: settings.onboardingCompleted
        )
    }
}

// MARK: - Tabs

private struct MainTabs: View {
    @Environment(Router.self) private var router
    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings

    /// The Moments tab's layout, reported by `MomentsColumns` from its own measurement.
    @State private var momentsLayout: ColumnLayout = .stack
    /// What's New was presented in this app session; it never comes back by itself.
    @State private var didPresentWhatsNew = false
    @State private var haptics = CommandHaptics()

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab(value: Router.Tab.moments) {
                MomentsColumns(layout: $momentsLayout)
            } label: {
                Label {
                    Text("Moments", comment: "Tab: the moments to clean up.")
                } icon: {
                    Image(systemName: "rectangle.stack")
                }
            }
            Tab(value: Router.Tab.kept) {
                KeptColumns()
            } label: {
                Label {
                    Text("Kept", comment: "Tab: the moments and photos you kept.")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
        }
        // A tab bar only (bottom when compact, top when regular): with two tabs the sidebar
        // mode adds nothing, and its button looked like the list column's own sidebar button.
        .tabViewStyle(.tabBarOnly)
        // Never minimizes: minimizing on scroll collapsed the bar and moved the accessory inline
        // differently per tab, so the selection jumped on every switch (owner feedback).
        .tabBarMinimizeBehavior(.never)
        .tabViewBottomAccessory(isEnabled: showsAccessory) {
            ReviewAccessory()
        }
        .sheet(isPresented: whatsNewSheet, onDismiss: { settings.dismissWhatsNew() }) {
            WhatsNewView()
        }
        .onChange(of: settings.showsWhatsNew, initial: true) { _, _ in
            presentWhatsNewIfNeeded()
        }
        .onChange(of: router.sheet) { _, _ in
            presentWhatsNewIfNeeded()
        }
        // Commit results play here, not in the screen that started them: the last moment's
        // commit can take that screen away (a split's detail, a stack ↔ split swap).
        .environment(haptics)
        .modifier(AppCommandPublisher(momentsLayout: momentsLayout, haptics: haptics))
        .hapticFeedback(trigger: haptics.event) { _, event in event?.feedback }
    }

    /// The Moments tab is stacked, at its root, and its list shows (ADAPTIVE §3.1), and no
    /// screen is pushed on either tab: the accessory outlives a hidden tab bar, so a pushed
    /// Review or Kept moment would get it over its own bottom bar. It does not depend on the
    /// selected tab: an accessory that comes and goes with the tab resizes the tab bar on every
    /// switch.
    private var showsAccessory: Bool {
        momentsLayout == .stack
            && router.momentsPath.isEmpty
            && router.keptPath.isEmpty
            && library.showsMomentList
    }

    // MARK: What's New

    /// Shows What's New while `router.sheet == .whatsNew`. Closing it any way (Continue, the
    /// close button, a swipe) records it as seen before the sheet slot frees up, so it can't
    /// come straight back.
    private var whatsNewSheet: Binding<Bool> {
        Binding {
            router.sheet == .whatsNew
        } set: { isPresented in
            guard !isPresented, router.sheet == .whatsNew else { return }
            settings.dismissWhatsNew()
            router.sheet = nil
        }
    }

    /// Launch decides `showsWhatsNew` after the first frame; another sheet that is already up
    /// goes first.
    private func presentWhatsNewIfNeeded() {
        guard settings.showsWhatsNew, !didPresentWhatsNew, router.sheet == nil else { return }
        didPresentWhatsNew = true
        router.sheet = .whatsNew
    }
}

// MARK: - Menu bar state

/// Publishes `\.appCommands` for the menu bar. Its body reads every value the menus show, so
/// a change republishes the snapshot; the tabs inside are not re-evaluated.
private struct AppCommandPublisher: ViewModifier {
    let momentsLayout: ColumnLayout
    let haptics: CommandHaptics

    @Environment(Router.self) private var router
    @Environment(LibraryModel.self) private var library
    @Environment(ToastCenter.self) private var toasts

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.appCommands, state)
    }

    private var state: AppCommandState {
        let canReadLibrary = library.access == .full || library.access == .limited
        // In the stack a pushed Review covers the Moments toolbar, where Adjust opens from.
        let adjustButtonShows = momentsLayout == .split || router.momentsPath.isEmpty
        return AppCommandState(
            router: router,
            library: library,
            toasts: toasts,
            haptics: haptics,
            tab: router.tab,
            isPresenting: router.sheet != nil,
            canUndo: toasts.current?.canUndo ?? false,
            canAdjust: canReadLibrary && adjustButtonShows,
            review: router.review.map(reviewState)
        )
    }

    private func reviewState(_ session: ReviewSession) -> ReviewCommandState {
        let canMoveOn = session.canMoveOn
        return ReviewCommandState(
            mode: session.mode,
            canMoveOn: canMoveOn,
            deleteCount: session.deleteCount,
            kept: session.selection.kept,
            hasPreviousMoment: router.previousMoment != nil
        )
    }
}

#if DEBUG
#Preview("New user: onboarding") {
    RootPreviewHost(.newUser) {
        RootView()
    }
}

#Preview("Moments") {
    RootPreviewHost(.returning) {
        RootView()
    }
}

#Preview("Upgrader: What's New") {
    RootPreviewHost(.upgrader) {
        RootView()
    }
}

#Preview("Photo access off, dark") {
    RootPreviewHost(.denied) {
        RootView()
    }
    .preferredColorScheme(.dark)
}

#Preview("Side by side", traits: .fixedLayout(width: 1180, height: 820)) {
    RootPreviewHost(.returning) {
        RootView()
    }
    .environment(\.horizontalSizeClass, .regular)
}

#Preview("iPhone landscape", traits: .landscapeLeft) {
    RootPreviewHost(.returning) {
        RootView()
    }
}
#endif
