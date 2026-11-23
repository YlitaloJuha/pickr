import Accessibility
import PickrModels
import SwiftUI

// Toasts (§3.3 S5). This is the only design-system file allowed to use explicit glass
// (§3.2 rule 2): one capsule of regular interactive glass. The Undo and Try Again buttons
// inside it are plain borderless text buttons, so there is never glass inside glass.

/// Shows `ToastCenter.current` as one glass capsule at the bottom of the screen's content,
/// above its toolbars and the tab bar.
///
/// - It auto-dismisses after 5 s (10 s while VoiceOver runs, so Undo can be reached). The
///   timer is `ToastCenter`'s; the host only sets `displayDuration` from VoiceOver.
/// - Its message is announced to VoiceOver once, however many screens host toasts.
/// - Swiping it down, or the VoiceOver escape gesture, dismisses it.
/// - Error toasts add a warning icon and Try Again.
/// - While `isRaised`, it sits above whatever the screen on top marked with
///   `toastsStayAbove(_:)`: Review's and the Kept moment's bottom bar, and in One by One the
///   filmstrip. The host is on the column, outside the pushed screen's toolbar, so without this
///   the capsule covered Skip, the main button and the ⋯ menu.
struct ToastHost: ViewModifier {
    let isRaised: Bool

    @State private var floors = ToastFloors()

    func body(content: Content) -> some View {
        content
            .environment(floors)
            .overlay(alignment: .bottom) {
                ToastOverlay(floors: floors, isRaised: isRaised)
            }
    }
}

extension View {
    /// Hosts the app's toasts over this content. Apply it once per tab container
    /// (ADAPTIVE.md S5): on the `NavigationStack` in the stack, on the detail column in a
    /// split, so a toast appears once. `isRaised`: the column shows a screen with a bottom bar
    /// (from model state, so the toast drops back the moment that screen starts to leave).
    func toastHost(isRaised: Bool = false) -> some View {
        modifier(ToastHost(isRaised: isRaised))
    }

    /// Toasts of the enclosing host stay above this view's `edge` while it is on screen: the
    /// bottom of a screen's content (the top of its bottom bar) or the top of floating controls.
    func toastsStayAbove(_ edge: VerticalEdge) -> some View {
        modifier(ToastsStayAbove(edge: edge))
    }
}

/// The lines, in window coordinates, that the screens under one host want toasts above.
@Observable private final class ToastFloors {
    private var floors: [UUID: CGFloat] = [:]

    /// The highest line, or `nil` when no screen asks.
    var highest: CGFloat? { floors.values.min() }

    func set(_ y: CGFloat, for id: UUID) {
        if floors[id] != y { floors[id] = y }
    }

    func remove(_ id: UUID) {
        floors[id] = nil
    }
}

private struct ToastsStayAbove: ViewModifier {
    let edge: VerticalEdge

    @Environment(ToastFloors.self) private var floors: ToastFloors?
    @State private var id = UUID()
    /// The last line measured: a screen that reappears unmoved (a tab switch) gets no geometry
    /// change, so it reports this one again.
    @State private var last = LastFloor()

    func body(content: Content) -> some View {
        let edge = edge
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                let frame = proxy.frame(in: .global)
                return edge == .top ? frame.minY : frame.maxY
            } action: { y in
                last.y = y
                floors?.set(y, for: id)
            }
            .onAppear {
                if let y = last.y { floors?.set(y, for: id) }
            }
            .onDisappear {
                floors?.remove(id)
            }
    }
}

private final class LastFloor {
    var y: CGFloat?
}

// MARK: - Overlay

private struct ToastOverlay: View {
    let floors: ToastFloors
    let isRaised: Bool

    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// The bottom of this overlay (the column's safe area), in window coordinates.
    @State private var bottom: CGFloat = 0

    var body: some View {
        // How far the capsule rises to clear the screen's bar or floating controls.
        let lift = isRaised ? floors.highest.map { max(0, bottom - $0) } ?? 0 : 0
        ZStack {
            if let toasts, let toast = toasts.current {
                ToastCapsule(
                    toast: toast,
                    undo: { Task { await toasts.performUndo() } },
                    retry: { Task { await toasts.performRetry() } },
                    dismiss: { dismiss(toast) }
                )
                .id(toast.id)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    ToastAnnouncer.announce(toast)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.small + lift)
        .animation(reduceMotion ? nil : Motion.chrome, value: lift)
        .animation(reduceMotion ? Motion.reducedFade : .snappy, value: toasts?.current?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).maxY
        } action: { newBottom in
            bottom = newBottom
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, isEnabled in
            // ToastCenter owns the dismissal timer; a second one here would be overruled.
            toasts?.displayDuration = isEnabled ? .seconds(10) : .seconds(5)
        }
    }

    private func dismiss(_ toast: ToastCenter.Toast) {
        guard let toasts, toasts.current?.id == toast.id else { return }
        toasts.dismiss()
    }
}

/// Every screen that hosts toasts sees the same toast; only the first announces it.
private enum ToastAnnouncer {
    private static var lastAnnounced: UUID?

    static func announce(_ toast: ToastCenter.Toast) {
        guard lastAnnounced != toast.id else { return }
        lastAnnounced = toast.id
        AccessibilityNotification.Announcement(toast.message).post()
    }
}

// MARK: - Capsule

private struct ToastCapsule: View {
    let toast: ToastCenter.Toast
    let undo: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.small))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.medium))

        layout {
            message
            action
        }
        .padding(.horizontal, Theme.Spacing.large + Theme.Spacing.extraSmall)
        .padding(.vertical, Theme.Spacing.medium)
        .frame(maxWidth: ReadableWidth.toast)
        .glassEffect(.regular.interactive(), in: isStacked ? AnyShape(Theme.Shapes.card) : AnyShape(Capsule()))
        .offset(y: dragOffset)
        .gesture(swipeDown)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
        .accessibilityAction(named: Text("Dismiss", comment: "VoiceOver action that hides a toast message."), dismiss)
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            if toast.isError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var action: some View {
        if toast.isError {
            Button(action: retry) {
                Text("Try Again", comment: "Toast button that repeats an action that failed.")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .tint(Theme.Palette.keep)
        } else if toast.canUndo {
            Button(action: undo) {
                Text("Undo", comment: "Toast button that reverses the action the toast describes.")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
            .tint(Theme.Palette.keep)
        }
    }

    /// Follows the finger downwards; far or fast enough dismisses, otherwise it springs back.
    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 32 || value.predictedEndTranslation.height > 96 {
                    dismiss()
                } else {
                    withAnimation(.snappy) { dragOffset = 0 }
                }
            }
    }
}
