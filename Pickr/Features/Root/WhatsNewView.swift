import SwiftUI

/// What's New (§3.3 S2, ADAPTIVE S2): shown once, to people upgrading from 1.0. A sheet at the
/// medium and large detents, form-sized when regular, with plain system glass.
///
/// RootView presents it from `router.sheet` and records it as seen however it closes
/// (Continue, the close button or a swipe), so it never shows again for this version.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large * 1.25) {
                    Text("What's New in Pickr.", comment: "Title of the sheet that shows what changed since version 1.")
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: Theme.Spacing.large * 1.125) {
                        FeatureRow(
                            systemImage: "checkmark.circle",
                            title: Text("Kept has its own tab", comment: "What's New row title: the new Kept tab."),
                            detail: Text(
                                "See what you kept, and show it again any time.",
                                comment: "What's New row: what the Kept tab does."
                            )
                        )
                        FeatureRow(
                            systemImage: "forward.end",
                            title: Text("The next moment opens by itself", comment: "What's New row title: Review moves on by itself."),
                            detail: Text(
                                "Delete or skip, and the next one is ready.",
                                comment: "What's New row: after deleting or skipping, the next moment shows."
                            )
                        )
                        FeatureRow(
                            systemImage: "bolt",
                            title: Text("Changes show up right away", comment: "What's New row title: Adjust updates the list at once."),
                            detail: Text(
                                "Adjust updates the list as you go.",
                                comment: "What's New row: changes in Adjust update the Moments list immediately."
                            )
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.large * 1.75)
                .padding(.bottom, Theme.Spacing.large)
                .readableWidth()
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaBar(edge: .bottom) {
                BottomActionButton(
                    title: Text("Continue", comment: "What's New: close the sheet and start using the app."),
                    action: { dismiss() }
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationSizing(.form)
    }
}

#if DEBUG
#Preview("What's New") {
    Color(.systemGroupedBackground)
        .sheet(isPresented: .constant(true)) {
            WhatsNewView()
        }
}

#Preview("What's New, large text, dark") {
    Color(.systemGroupedBackground)
        .sheet(isPresented: .constant(true)) {
            WhatsNewView()
                .environment(\.dynamicTypeSize, .accessibility1)
        }
        .preferredColorScheme(.dark)
}

#Preview("What's New, wide window", traits: .fixedLayout(width: 1180, height: 820)) {
    Color(.systemGroupedBackground)
        .sheet(isPresented: .constant(true)) {
            WhatsNewView()
        }
        .environment(\.horizontalSizeClass, .regular)
}
#endif
