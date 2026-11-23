import Observation
import PickrCore
import SwiftUI

// Focus tracking for ambient backgrounds (blueprint §3.5): which item of one list or grid sits
// under the focus line (`FocusLine`, 40 % down the scroll viewport).
//
//   @State private var focus = ScrollFocus<MomentID>()
//
//   List {
//       ForEach(moments) { moment in
//           MomentRow(moment).scrollFocusItem(moment.id, in: focus)
//       }
//   }
//   .scrollFocusContainer(focus)
//
// - Items report their frames in window coordinates as they scroll; the container reports its
//   own frame the same way. `focused` changes only when another item takes the line; `frames`
//   changes on every scroll frame and is read only by the list's photo strip
//   (`AmbientStripLayout`). Read either in a small background modifier, never in the body of
//   the list itself, so scrolling re-renders nothing else.
// - Frames are kept only for items that exist (List rows and lazy grid tiles live only near the
//   screen); an item that disappears is dropped and reports again when it reappears.
// - With nothing reported (the screen is covered or torn down) `focused` keeps its last value.
// - One tracker per scroll container instance; `onScrollFocusChange` copies its focus into state
//   that must outlive the container (a stack ↔ split swap).

/// Tracks the focused item of one scrolling list or grid.
@Observable
final class ScrollFocus<ID: Hashable> {
    /// The item under the focus line, or `nil` until the first report.
    private(set) var focused: ID?
    /// The frames of the items that exist, in window coordinates. Changes as the list scrolls.
    private(set) var frames: [ID: CGRect] = [:]

    @ObservationIgnored private var viewport: CGRect = .null

    func setViewport(_ frame: CGRect) {
        guard frame != viewport else { return }
        viewport = frame
        refocus()
    }

    func setFrame(_ frame: CGRect, for id: ID) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        refocus()
    }

    func remove(_ id: ID) {
        guard frames[id] != nil else { return }
        frames[id] = nil
        refocus()
    }

    /// Writes `focused` only when the item under the line changes.
    private func refocus() {
        guard let id = FocusLine.focusedID(in: frames, viewport: viewport), id != focused else { return }
        focused = id
    }
}

extension ScrollFocus where ID == PhotoID {
    /// A moment grid's focused photo, or the moment's first photo before the grid has reported
    /// (or while the previous moment's grid is still leaving).
    func photo(in moment: Moment) -> PhotoID {
        if let focused, moment.photos.contains(where: { $0.id == focused }) { return focused }
        return moment.photos[0].id
    }
}

extension View {
    /// Makes this `List` or `ScrollView` the viewport `focus` measures against. `nil` tracks
    /// nothing.
    @ViewBuilder
    func scrollFocusContainer<ID: Hashable>(_ focus: ScrollFocus<ID>?) -> some View {
        if let focus {
            // Window coordinates for the viewport and the items alike: a named space declared on a
            // `List` is not guaranteed to resolve inside its rows, the window always is.
            onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                focus.setViewport(frame)
            }
        } else {
            self
        }
    }

    /// Reports this row's or tile's frame to `focus` while it exists. `nil` tracks nothing.
    /// Always the same view type (no `if`), so a List row keeps its identity and its row traits.
    func scrollFocusItem<ID: Hashable>(_ id: ID, in focus: ScrollFocus<ID>?) -> some View {
        modifier(ScrollFocusItem(id: id, focus: focus))
    }

    /// Calls `action` with each new focused item of `focus` (never with `nil`). Only this
    /// modifier re-renders when the focus moves.
    func onScrollFocusChange<ID: Hashable>(
        _ focus: ScrollFocus<ID>,
        perform action: @escaping (ID) -> Void
    ) -> some View {
        modifier(ScrollFocusRelay(focus: focus, action: action))
    }
}

private struct ScrollFocusItem<ID: Hashable>: ViewModifier {
    let id: ID
    let focus: ScrollFocus<ID>?

    /// The last frame measured, outside SwiftUI state: an item that reappears unmoved (after a
    /// push or a tab switch) gets no geometry change, so it reports this one again.
    @State private var last = LastFrame()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                guard let focus else { return }
                last.frame = frame
                focus.setFrame(frame, for: id)
            }
            .onAppear {
                if let focus, let frame = last.frame { focus.setFrame(frame, for: id) }
            }
            .onDisappear {
                focus?.remove(id)
            }
    }
}

private final class LastFrame {
    var frame: CGRect?
}

private struct ScrollFocusRelay<ID: Hashable>: ViewModifier {
    let focus: ScrollFocus<ID>
    let action: (ID) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: focus.focused) { _, newID in
            if let newID { action(newID) }
        }
    }
}
