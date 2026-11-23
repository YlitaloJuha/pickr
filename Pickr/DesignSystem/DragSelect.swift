import PickrCore
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// Drag-select in the Review grid, on every device (ADAPTIVE.md §9, decision D8).
//
// For screen agents (ReviewGrid):
//
//   PhotoGrid(photos: ids, dragSelection: DragSelection(
//       isKept: { session.selection.kept.contains($0) },
//       toggle: { session.toggle($0) }
//   )) { index, id in PhotoTile(…).onTapGesture { session.toggle(id) } … }
//
// - A touch drag whose first 10 pt are clearly horizontal (|dx| > 1.5 |dy|) paints; a
//   vertical drag fails at once and the scroll view scrolls. A pointer click-drag paints in
//   any direction (trackpads and mice scroll with two fingers or the wheel). A drag that
//   starts at the screen edge stays the system's back swipe.
// - Photos-style range painting: the tile under the start point sets the mode (unkept →
//   keep, kept → unkeep). Every tile from the start to the current one, in reading order,
//   takes that state; tiles that leave the range return to their state at drag start.
// - Changes go through `toggle`, only for tiles whose state differs, with one selection
//   haptic per change (respects Vibration). No new model API.
// - Near the top or bottom 60 pt of the visible area the grid auto-scrolls a row at a time.
// - An accelerator only: every tile keeps its tap and its VoiceOver actions, which remain
//   the visible and accessible way to keep a photo.

/// How drag-select reads and changes the keep state. Both closures run on the main actor.
struct DragSelection {
    let isKept: (PhotoID) -> Bool
    let toggle: (PhotoID) -> Void

    init(isKept: @escaping (PhotoID) -> Bool, toggle: @escaping (PhotoID) -> Void) {
        self.isKept = isKept
        self.toggle = toggle
    }
}

// MARK: - Range painting (pure)

/// The state of one drag, by index in reading order. Pure: no views, no model.
nonisolated struct DragSelectRange: Equatable, Sendable {
    /// Where the drag started.
    let anchor: Int
    /// `true` when the drag keeps (it started on an unkept tile), `false` when it unkeeps.
    let makesKept: Bool
    /// The tiles that were kept when the drag started.
    let keptAtStart: Set<Int>
    /// The tile under the finger now.
    private(set) var current: Int

    /// Starts a drag on `anchor`. `keptAtStart` decides the mode: dragging from a kept tile
    /// unkeeps, from an unkept tile keeps.
    init(anchor: Int, keptAtStart: Set<Int>) {
        self.anchor = anchor
        self.makesKept = !keptAtStart.contains(anchor)
        self.keptAtStart = keptAtStart
        self.current = anchor
    }

    /// The tiles between the anchor and the current tile, both included.
    var painted: ClosedRange<Int> {
        min(anchor, current)...max(anchor, current)
    }

    /// What tile `index` should be now: the drag's state inside the range, its state at
    /// drag start outside it.
    func isKept(_ index: Int) -> Bool {
        painted.contains(index) ? makesKept : keptAtStart.contains(index)
    }

    /// Moves the drag to `index` and returns the tiles whose wanted state may have changed:
    /// everything the old or new range covers. The anchor itself is included on the first
    /// call (`current == anchor`), so callers apply the mode to it too.
    mutating func move(to index: Int) -> ClosedRange<Int> {
        let old = painted
        current = index
        let new = painted
        return min(old.lowerBound, new.lowerBound)...max(old.upperBound, new.upperBound)
    }
}

// MARK: - Modifier (used by PhotoGrid)

extension View {
    /// Range-painting on a `PhotoGrid`'s `LazyVGrid`. `PhotoGrid` applies it; a `nil`
    /// selection leaves the recognizer disabled.
    func dragSelect(
        photos: [PhotoID],
        layout: PhotoGridLayout,
        selection: DragSelection?,
        viewport: String,
        scrollMetrics: ScrollMetrics,
        scrollTo: @escaping (PhotoID, UnitPoint) -> Void
    ) -> some View {
        modifier(DragSelectModifier(
            photos: photos,
            layout: layout,
            selection: selection,
            viewport: viewport,
            scrollMetrics: scrollMetrics,
            scrollTo: scrollTo
        ))
    }
}

private struct DragSelectModifier: ViewModifier {
    let photos: [PhotoID]
    let layout: PhotoGridLayout
    let selection: DragSelection?
    let viewport: String
    let scrollMetrics: ScrollMetrics
    let scrollTo: (PhotoID, UnitPoint) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drag: DragState?
    @State private var autoScroll: VerticalEdge?
    /// Bumped once per batch of changed tiles; drives the selection haptic.
    @State private var changes = 0

    /// Distance from the visible top or bottom edge that starts auto-scrolling.
    private static let autoScrollZone: CGFloat = 60
    /// Time between auto-scroll steps of one row.
    private static let autoScrollInterval: Duration = .milliseconds(220)

    private struct DragState {
        var range: DragSelectRange
        /// The photos when the drag began; a change in between ends the drag.
        let photos: [PhotoID]
        /// The finger, in grid coordinates and in the scroll view's visible frame.
        var location: CGPoint
        var viewportLocation: CGPoint
        /// The scroll offset when `location` was measured.
        var offset: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(DragSelectGesture(
                isEnabled: selection != nil && !photos.isEmpty,
                viewport: viewport,
                onBegan: began,
                onChanged: changed,
                onEnded: ended
            ))
            .hapticFeedback(.keepToggled, trigger: changes)
            .onChange(of: photos) { _, _ in
                ended()
            }
            .task(id: autoScroll) {
                guard let edge = autoScroll else { return }
                await runAutoScroll(toward: edge)
            }
    }

    // MARK: Gesture phases

    private func began(start: CGPoint, location: CGPoint, viewportLocation: CGPoint) {
        guard let selection, let anchor = layout.index(at: start, count: photos.count) else { return }
        let keptAtStart = Set(photos.indices.filter { selection.isKept(photos[$0]) })
        var state = DragState(
            range: DragSelectRange(anchor: anchor, keptAtStart: keptAtStart),
            photos: photos,
            location: location,
            viewportLocation: viewportLocation,
            offset: currentOffset
        )
        let affected = state.range.move(to: anchor)
        apply(affected, of: state, selection: selection)
        drag = state
        changed(location: location, viewportLocation: viewportLocation)
    }

    private func changed(location: CGPoint, viewportLocation: CGPoint) {
        guard var state = drag else { return }
        state.location = location
        state.viewportLocation = viewportLocation
        state.offset = currentOffset
        drag = state
        paint()
        autoScroll = edge(for: viewportLocation)
    }

    private func ended() {
        drag = nil
        autoScroll = nil
    }

    /// Moves the range to the tile under the finger and applies the difference.
    private func paint() {
        guard var state = drag, let selection, state.photos == photos,
              let index = layout.index(at: state.location, count: photos.count)
        else { return }
        guard index != state.range.current else { return }
        let affected = state.range.move(to: index)
        drag = state
        apply(affected, of: state, selection: selection)
    }

    /// Toggles every tile in `indices` whose state differs from what the range wants.
    private func apply(_ indices: ClosedRange<Int>, of state: DragState, selection: DragSelection) {
        var changed = false
        for index in indices where state.photos.indices.contains(index) {
            let id = state.photos[index]
            if selection.isKept(id) != state.range.isKept(index) {
                selection.toggle(id)
                changed = true
            }
        }
        if changed { changes &+= 1 }
    }

    // MARK: Auto-scroll

    private var currentOffset: CGFloat {
        scrollMetrics.geometry?.contentOffset.y ?? 0
    }

    /// The edge the finger is near, inside the visible (inset) area, or `nil`.
    private func edge(for viewportLocation: CGPoint) -> VerticalEdge? {
        guard let geometry = scrollMetrics.geometry else { return nil }
        let top = geometry.contentInsets.top + Self.autoScrollZone
        let bottom = geometry.containerSize.height - geometry.contentInsets.bottom - Self.autoScrollZone
        guard bottom > top else { return nil }
        if viewportLocation.y < top { return .top }
        if viewportLocation.y > bottom { return .bottom }
        return nil
    }

    /// Scrolls one row at a time toward `edge` while the finger stays near it, moving the
    /// next row under the finger and painting it.
    private func runAutoScroll(toward edge: VerticalEdge) async {
        while !Task.isCancelled, let state = drag,
              let index = layout.index(at: state.location, count: photos.count) {
            let rows = layout.rows(for: photos.count)
            let row = index / layout.columns + (edge == .bottom ? 1 : -1)
            guard (0..<rows).contains(row), let height = scrollMetrics.geometry?.containerSize.height, height > 0 else { return }

            // Line the target row up with the finger: its point at the finger's fraction of
            // the visible height goes to the same fraction of the scroll view.
            let fraction = min(max(state.viewportLocation.y / height, 0), 1)
            let target = photos[min(row * layout.columns + index % layout.columns, photos.count - 1)]
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                scrollTo(target, UnitPoint(x: 0.5, y: fraction))
            }

            try? await Task.sleep(for: Self.autoScrollInterval)
            guard !Task.isCancelled, var moved = drag else { return }
            // The content moved under a still finger by however far it actually scrolled.
            let offset = currentOffset
            moved.location.y += offset - moved.offset
            moved.offset = offset
            drag = moved
            paint()
        }
    }
}

// MARK: - Gesture

/// Wraps `DragSelectRecognizer` for SwiftUI and reports locations in the grid's own
/// coordinates and in the scroll view's visible frame.
private struct DragSelectGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let viewport: String
    let onBegan: (_ start: CGPoint, _ location: CGPoint, _ viewportLocation: CGPoint) -> Void
    let onChanged: (_ location: CGPoint, _ viewportLocation: CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> DragSelectRecognizer {
        DragSelectRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: DragSelectRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: DragSelectRecognizer, context: Context) {
        let location = context.converter.localLocation
        let viewportLocation = context.converter.location(in: .named(viewport))
        switch recognizer.state {
        case .began:
            // The recognizer begins 10 pt after touch-down; the start is where the finger
            // went down. Window and grid coordinates differ only by a translation.
            let now = recognizer.location(in: nil)
            let start = CGPoint(
                x: location.x - (now.x - recognizer.startLocation.x),
                y: location.y - (now.y - recognizer.startLocation.y)
            )
            onBegan(start, location, viewportLocation)
        case .changed:
            onChanged(location, viewportLocation)
        default:
            onEnded()
        }
    }
}

/// A one-finger drag that begins only when its first 10 pt are clearly horizontal, or for
/// any pointer click-drag (4 pt). Scroll views and the content back swipe wait for it to
/// fail, so a vertical drag still scrolls; the screen-edge back swipe always wins over it.
final class DragSelectRecognizer: UIGestureRecognizer {
    static let touchDecisionDistance: CGFloat = 10
    static let pointerDecisionDistance: CGFloat = 4
    /// A touch drag counts as horizontal when |dx| > 1.5 |dy|.
    static let horizontalBias: CGFloat = 1.5

    /// Where the tracked touch went down, in window coordinates.
    private(set) var startLocation: CGPoint = .zero
    private var trackedTouch: UITouch?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer, .pencil].map { NSNumber(value: $0.rawValue) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            // A second finger: give up before beginning, ignore it while painting.
            if state == .possible {
                state = .failed
            } else {
                touches.filter { $0 !== trackedTouch }.forEach { ignore($0, for: event) }
            }
            return
        }
        trackedTouch = touch
        startLocation = touch.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            let location = touch.location(in: nil)
            let dx = location.x - startLocation.x
            let dy = location.y - startLocation.y
            let isPointer = touch.type == .indirectPointer
            let threshold = isPointer ? Self.pointerDecisionDistance : Self.touchDecisionDistance
            guard dx * dx + dy * dy >= threshold * threshold else { return }
            state = isPointer || abs(dx) > Self.horizontalBias * abs(dy) ? .began : .failed
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
        startLocation = .zero
    }

    /// Pans that receive the same touch (the scroll view, the content back swipe) wait
    /// until this recognizer fails, which it does within 10 pt of a vertical drag.
    /// A disabled recognizer (a read-only grid) asks nothing of anyone.
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled
            && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
    }

    /// The screen-edge back swipe goes first.
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled && otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
    }
}

#if DEBUG
private struct DragSelectPreview: View {
    @State private var kept: Set<PhotoID> = []
    private let records = PreviewPhotos.records(count: 30)

    var body: some View {
        NavigationStack {
            PhotoGrid(
                photos: records.map(\.id),
                dragSelection: DragSelection(
                    isKept: { kept.contains($0) },
                    toggle: { id in if kept.remove(id) == nil { kept.insert(id) } }
                )
            ) { index, id in
                PhotoTile(
                    record: records[index],
                    index: index,
                    total: records.count,
                    isKept: kept.contains(id),
                    willDelete: !kept.isEmpty && !kept.contains(id)
                )
                .onTapGesture { if kept.remove(id) == nil { kept.insert(id) } }
            }
            .navigationTitle(Text(verbatim: "Drag to keep"))
        }
        .environment(\.imageLoader, SwatchImageLoader())
    }
}

#Preview("Drag-select") {
    DragSelectPreview()
}
#endif
