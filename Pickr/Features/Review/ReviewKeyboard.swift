import PickrCore
import PickrModels
import SwiftUI

// Keyboard in Review (ADAPTIVE §7). Two layers:
//
// - The Clean Up menu (`App/PickrCommands.swift`, WP11) reads the focused values below, which
//   `ReviewScreen` publishes in the stack and in the split. Space (Keep Photo), ⌘⌫, ⌘K, ⌘↓,
//   ⌘↑ and ⌘1 / ⌘2 live there; see audit/contract-changes/WP8-review-focus.md.
// - `ReviewKeyHandling` (here) handles the plain keys while the review content has focus:
//   ← / → photos (One by One) or the focus ring (All), ↑ / ↓ ring rows, Return (All → One by
//   One at the ring), Esc (One by One → All, All → leave Review in the stack) and 1–9. Keys
//   with ⌘, ⌥ or ⌃ pass through, so the menu's shortcuts are never shadowed.

extension FocusedValues {
    /// The review on screen, for the Clean Up menu.
    @Entry var reviewSession: ReviewSession?
    /// What Keep Photo (Space) toggles: the current photo in One by One, the tile under the
    /// focus ring in All, or `nil` while no ring shows.
    @Entry var reviewKeepTarget: PhotoID?
}

/// Where an arrow key moves the All focus ring. Pure.
nonisolated enum ReviewRingMove: Equatable, Sendable {
    case previous, next, up, down

    /// The ring's index after the move, clamped to the photos (a row move off the grid stays
    /// put). `nil` when there are no photos.
    func apply(to index: Int, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let columns = max(columns, 1)
        let current = min(max(index, 0), count - 1)
        switch self {
        case .previous: return max(current - 1, 0)
        case .next: return min(current + 1, count - 1)
        case .up: return current - columns >= 0 ? current - columns : current
        case .down: return current + columns < count ? current + columns : current
        }
    }
}

/// The plain keys of Review (ADAPTIVE §7), on the review content: it becomes focusable, takes
/// focus when it appears and shows no system focus effect (the ring is drawn by the grid).
struct ReviewKeyHandling: ViewModifier {
    let session: ReviewSession
    /// Esc in All leaves Review only in the stack; the split has no Back.
    let canLeave: Bool
    /// The All focus ring: the tile index, or `nil` while hidden.
    @Binding var ring: Int?
    let columns: Int
    let onLeave: () -> Void
    /// A number key toggled a photo (the caller plays the keep haptic).
    let onToggled: () -> Void

    @FocusState private var isFocused: Bool

    private static let keys: Set<KeyEquivalent> = Set(
        [.leftArrow, .rightArrow, .upArrow, .downArrow, .return, .escape, .space] + "123456789".map { KeyEquivalent($0) }
    )

    func body(content: Content) -> some View {
        content
            .focusable(interactions: .activate)
            .focusEffectDisabled()
            .focused($isFocused)
            .defaultFocus($isFocused, true)
            .onAppear { isFocused = true }
            .onKeyPress(keys: Self.keys) { press in
                handle(press)
            }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        guard let moment = session.current else { return .ignored }
        let isArrow = [KeyEquivalent.leftArrow, .rightArrow, .upArrow, .downArrow].contains(press.key)
        // Only arrows repeat while held; a held digit must not flip its photo back and forth.
        guard press.phase != .repeat || isArrow else { return .handled }
        switch press.key {
        case .leftArrow, .rightArrow:
            let forward = press.key == .rightArrow
            if session.mode == .single {
                // `singleIndex` is clamped by the session.
                session.singleIndex += forward ? 1 : -1
            } else {
                moveRing(forward ? .next : .previous, count: moment.count)
            }
            return .handled
        case .upArrow, .downArrow:
            guard session.mode == .grid else { return .ignored }
            moveRing(press.key == .downArrow ? .down : .up, count: moment.count)
            return .handled
        case .return:
            guard session.mode == .grid else { return .ignored }
            if let ring, moment.photos.indices.contains(ring) {
                session.showSingle(moment.photos[ring].id)
            } else {
                session.mode = .single
            }
            return .handled
        case .space:
            // Handled here, not by the menu's Keep Photo: the focusable review content takes
            // Space as "activate" before a menu shortcut sees it (found by the iPad UI test).
            guard press.phase != .repeat else { return .handled }
            if session.mode == .single {
                session.toggleCurrentPhoto()
            } else if let ring, moment.photos.indices.contains(ring) {
                session.togglePhoto(at: ring)
            } else {
                return .ignored
            }
            onToggled()
            return .handled
        case .escape:
            if session.mode == .single {
                session.mode = .grid
                return .handled
            }
            guard canLeave else { return .ignored }
            onLeave()
            return .handled
        default:
            guard press.modifiers.isDisjoint(with: .shift),
                  let digit = press.characters.first?.wholeNumberValue, (1...9).contains(digit),
                  moment.photos.indices.contains(digit - 1)
            else { return .ignored }
            session.togglePhoto(at: digit - 1)
            onToggled()
            return .handled
        }
    }

    /// The first arrow press only shows the ring (where One by One last was); later ones move it.
    private func moveRing(_ move: ReviewRingMove, count: Int) {
        guard let ring else {
            ring = min(session.singleIndex, max(count - 1, 0))
            return
        }
        self.ring = move.apply(to: ring, columns: columns, count: count)
    }
}
