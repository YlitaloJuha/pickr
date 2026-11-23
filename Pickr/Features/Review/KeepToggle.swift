import SwiftUI

// One of the three files allowed to use explicit glass (§3.2 rule 2).

/// The Keep / Kept button over the photo in One by One: clear interactive glass while the
/// photo isn't kept, accent-tinted glass once it is. Its `glassEffectID` lets the shape and
/// tint morph inside the caller's `GlassEffectContainer`. A real button for VoiceOver
/// ("Keep", selected while kept); the visible alternative to swiping up.
struct KeepToggle: View {
    let isKept: Bool
    let glassNamespace: Namespace.ID
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label {
                isKept
                    ? Text("Kept", comment: "One by One: the photo is marked to keep.")
                    : Text("Keep", comment: "One by One: mark the photo to keep.")
            } icon: {
                Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(.headline)
            .foregroundStyle(isKept ? Theme.Palette.onPhoto : Color.primary)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.vertical, Theme.Spacing.medium)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(isKept ? .regular.tint(Theme.Palette.keep).interactive() : .clear.interactive(), in: .capsule)
        .glassEffectID("keep", in: glassNamespace)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: isKept)
        .accessibilityLabel(Text("Keep", comment: "VoiceOver label of the Keep toggle in One by One."))
        .accessibilityAddTraits(isKept ? .isSelected : [])
    }
}
