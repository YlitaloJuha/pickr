import PickrCore
import PickrModels
import SwiftUI

// The keyboard map (ADAPTIVE §7) as menu commands. They show in the iPadOS menu bar and in the
// overlay that holding ⌘ brings up. Attach them to the window group:
//
//   WindowGroup { RootView() … }
//       .commands { PickrCommands() }
//
// Two focused values drive them:
// - `\.appCommands`, published by RootView once the tabs show (nil during onboarding): the
//   Router, the library and the toasts to act on, plus a snapshot of the state the menus
//   depend on. The snapshot is a value read in a view body, so the menus update whenever it
//   changes.
// - `\.reviewSession` and `\.reviewKeepTarget`, published by ReviewScreen
//   (Features/Review/ReviewKeyboard.swift) while a review is on screen.
//
// Everything is disabled while a sheet or popover is up (`router.sheet`). ReviewScreen handles
// the plain keys itself (arrows, Return, Esc, Space, 1–9); Keep Photo here has no shortcut,
// so a Space press is never applied twice.

extension FocusedValues {
    /// What the menu commands act on and the state they show, published by RootView.
    @Entry var appCommands: AppCommandState?
}

/// The models the menu commands act on and a snapshot of what the menus show.
///
/// RootView builds it in a view body, so any change to the state in it republishes the
/// value and the menus follow.
struct AppCommandState {
    let router: Router
    let library: LibraryModel
    let toasts: ToastCenter
    let haptics: CommandHaptics
    /// The selected tab.
    let tab: Router.Tab
    /// A sheet or popover is up (Adjust, Settings, What's New).
    let isPresenting: Bool
    /// The toast on screen offers Undo.
    let canUndo: Bool
    /// Adjust can open: the library can be read and its button is on screen once the Moments
    /// tab shows (not under a pushed Review).
    let canAdjust: Bool
    /// The open review, or `nil`.
    let review: ReviewCommandState?
}

/// The open review, as the Clean Up menu shows it.
nonisolated struct ReviewCommandState: Equatable, Sendable {
    var mode: ReviewSession.Mode
    /// Skip, Keep All and Swap can act (`ReviewSession.canMoveOn`).
    var canMoveOn: Bool
    /// Photos a commit deletes: the count in **Delete 4 Photos**.
    var deleteCount: Int
    /// The photos marked to keep, for Keep Photo's checkmark.
    var kept: Set<PhotoID>
    /// Previous Moment (⌘↑) has somewhere to go (`Router.previousMoment`).
    var hasPreviousMoment: Bool
}

/// Haptics for actions started from the menu bar, and for commit results from Review and the
/// Moments list (in the environment). Commands can't play feedback themselves, and the screen
/// that started a commit may be gone when it ends, so they post it here and RootView plays it
/// (through `hapticFeedback`, which respects the Vibration setting).
@Observable final class CommandHaptics {
    nonisolated struct Event: Equatable, Sendable {
        let id: Int
        let feedback: SensoryFeedback

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }
    }

    private(set) var event: Event?
    @ObservationIgnored private var count = 0

    func play(_ feedback: SensoryFeedback) {
        count &+= 1
        event = Event(id: count, feedback: feedback)
    }

    /// The feedback for a commit or whole-moment result (§3.4). A cancelled dialog, and photos
    /// that were already gone, play nothing.
    func play(for result: CommitResult) {
        switch result {
        case .committed: play(.committed)
        case .keptAside: play(.keptAside)
        case .cancelled, .failed(.nothingToDelete): break
        case .failed: play(.failed)
        }
    }
}

/// The Clean Up menu, the view and tab switches, Undo, Adjust…, Settings… and Refresh
/// (ADAPTIVE §7).
struct PickrCommands: Commands {
    @FocusedValue(\.appCommands) private var app
    @FocusedValue(\.reviewSession) private var session
    @FocusedValue(\.reviewKeepTarget) private var keepTarget

    var body: some Commands {
        CommandMenu(Text("Clean Up", comment: "Menu bar: the menu with the review commands.")) {
            CleanUpMenu(review: activeReview, keepTarget: keepTarget)
        }
        CommandGroup(before: .sidebar) {
            ViewMenuItems(app: availableApp, review: activeReview)
        }
        CommandGroup(replacing: .undoRedo) {
            Button {
                guard let toasts = availableApp?.toasts else { return }
                Task { await toasts.performUndo() }
            } label: {
                Text("Undo", comment: "Menu bar: undo the last change (the toast's Undo).")
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!(availableApp?.canUndo ?? false))
        }
        CommandGroup(replacing: .appSettings) {
            AppMenuItems(app: availableApp)
        }
    }

    /// The app state while the tabs show and no sheet or popover is up.
    private var availableApp: AppCommandState? {
        guard let app, !app.isPresenting else { return nil }
        return app
    }

    /// The review the Clean Up menu acts on: on screen in the Moments tab, still the Router's
    /// open review (not one a popping stack still shows), no sheet up.
    private var activeReview: ActiveReview? {
        guard let app = availableApp, app.tab == .moments, let session, let state = app.review,
              app.router.review === session
        else { return nil }
        return ActiveReview(session: session, state: state, router: app.router, haptics: app.haptics)
    }
}

/// A review the menu can act on.
private struct ActiveReview {
    let session: ReviewSession
    let state: ReviewCommandState
    let router: Router
    let haptics: CommandHaptics
}

// MARK: - Clean Up

private struct CleanUpMenu: View {
    let review: ActiveReview?
    let keepTarget: PhotoID?

    var body: some View {
        let state = review?.state
        let canMoveOn = state?.canMoveOn ?? false
        let target = review == nil ? nil : keepTarget

        Toggle(isOn: keepBinding(target: target)) {
            Text("Keep Photo", comment: "Menu bar: keep or unmark the current photo (Space).")
        }
        // No `.keyboardShortcut(.space)`: Review handles Space itself (ReviewKeyboard.swift),
        // because the focusable review content takes Space before a menu shortcut sees it.
        .disabled(target == nil || !canMoveOn)

        Button {
            commit()
        } label: {
            deleteTitle(count: state?.deleteCount ?? 0)
        }
        .keyboardShortcut(.delete, modifiers: .command)
        .disabled(!canMoveOn || (state?.deleteCount ?? 0) == 0)

        Button {
            guard let review else { return }
            review.session.keepAside()
            review.haptics.play(.keptAside)
        } label: {
            Text("Keep All", comment: "Menu bar: keep the whole moment and go to the next one.")
        }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(!canMoveOn)

        Button {
            review?.session.skip()
        } label: {
            Text("Skip", comment: "Menu bar: leave this moment for later and go to the next one.")
        }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .disabled(!canMoveOn)

        Button {
            review?.router.reviewPreviousMoment()
        } label: {
            Text("Previous Moment", comment: "Menu bar: go back to the moment listed above this one.")
        }
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(!(state?.hasPreviousMoment ?? false))

    }

    /// Keep Photo's checkmark: whether the photo Space acts on is kept. Choosing it toggles
    /// that photo.
    private func keepBinding(target: PhotoID?) -> Binding<Bool> {
        let review = review
        return Binding {
            guard let target else { return false }
            return review?.state.kept.contains(target) ?? false
        } set: { _ in
            guard let review, let target else { return }
            review.session.toggle(target)
            review.haptics.play(.keepToggled)
        }
    }

    /// **Delete 4 Photos**, the same words as Review's main button.
    private func deleteTitle(count: Int) -> Text {
        count > 0
            ? Text("Delete \(count) Photos", comment: "Menu bar: delete the photos that aren't kept. 1: number of photos.")
            : Text("Delete Photos", comment: "Menu bar: Delete, while no photo would be deleted (disabled).")
    }

    /// ⌘⌫. Started in a `Task`, never in `.task`, so it can't be cancelled by a view going
    /// away while the system dialog is up.
    private func commit() {
        guard let review, review.state.canMoveOn, review.state.deleteCount > 0 else { return }
        let session = review.session
        let haptics = review.haptics
        Task {
            haptics.play(for: await session.commit())
        }
    }
}

// MARK: - View menu

private struct ViewMenuItems: View {
    let app: AppCommandState?
    let review: ActiveReview?

    var body: some View {
        Toggle(isOn: modeBinding(.grid)) {
            Text("All", comment: "Menu bar: see every photo of the moment at once.")
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(review == nil)

        Toggle(isOn: modeBinding(.single)) {
            Text("One by One", comment: "Menu bar: see the photos one at a time.")
        }
        .keyboardShortcut("2", modifiers: .command)
        .disabled(review == nil)

        Divider()

        Toggle(isOn: tabBinding(.moments)) {
            Text("Moments", comment: "Menu bar: show the Moments tab.")
        }
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(app == nil)

        Toggle(isOn: tabBinding(.kept)) {
            Text("Kept", comment: "Menu bar: show the Kept tab.")
        }
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(app == nil)

        Divider()
    }

    /// Checked for the current mode; choosing the other one switches.
    private func modeBinding(_ mode: ReviewSession.Mode) -> Binding<Bool> {
        let review = review
        return Binding {
            review?.state.mode == mode
        } set: { isOn in
            guard isOn, let session = review?.session, session.mode != mode else { return }
            session.mode = mode
        }
    }

    /// Checked for the selected tab; choosing the other one switches.
    private func tabBinding(_ tab: Router.Tab) -> Binding<Bool> {
        let app = app
        return Binding {
            app?.tab == tab
        } set: { isOn in
            guard isOn, let router = app?.router, router.tab != tab else { return }
            router.tab = tab
        }
    }
}

// MARK: - App menu

private struct AppMenuItems: View {
    let app: AppCommandState?

    var body: some View {
        Button {
            // Adjust opens from its button in the Moments toolbar.
            guard let router = app?.router else { return }
            router.tab = .moments
            router.sheet = .grouping
        } label: {
            Text("Adjust…", comment: "Menu bar: open Adjust (how moments are found).")
        }
        .keyboardShortcut("a", modifiers: [.command, .option])
        .disabled(!(app?.canAdjust ?? false))

        Button {
            // Settings is presented by the Moments tab.
            guard let router = app?.router else { return }
            router.tab = .moments
            router.sheet = .settings
        } label: {
            Text("Settings…", comment: "Menu bar: open Settings.")
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(app == nil)

        Button {
            guard let library = app?.library else { return }
            Task { await library.refresh() }
        } label: {
            Text("Refresh", comment: "Menu bar: look for new and changed photos.")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(app == nil)
    }
}
