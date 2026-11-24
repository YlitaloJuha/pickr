import PickrModels
import SwiftUI

/// First run (§3.3 S1, ADAPTIVE S1, COPY.md): Welcome, then Photo access. It is the root
/// content, so the tabs don't exist yet.
///
/// - The iOS permission prompt appears only when the person taps **Continue** on the photo access step.
///   Whatever they answer, onboarding is done and the tabs show; no access appears there as
///   the Moments tab's "Pickr. needs your photos" state.
/// - A centred column of at most 540 pt; the one prominent button sits in the bottom bar, at
///   most 420 pt wide. With a compact height (a phone in landscape) the hero art hides and the
///   text scrolls.
/// - Plain background (no ambient colour), no gestures. The hero bounces once unless Reduce
///   Motion is on; steps slide, or cross-fade under Reduce Motion.
struct OnboardingView: View {
    nonisolated enum Step: Hashable, Sendable {
        case welcome, access
    }

    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step: Step
    /// The iOS prompt is up; the button waits for its answer.
    @State private var isRequesting = false

    init(step: Step = .welcome) {
        self.step = step
    }

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep {
                    step = .access
                }
                .transition(stepTransition)
            case .access:
                AccessStep(isRequesting: isRequesting, onAllow: requestAccess)
                    .transition(stepTransition)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.45), value: step)
        .background(Theme.Palette.screen)
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private func requestAccess() {
        guard !isRequesting else { return }
        isRequesting = true
        let library = library
        let settings = settings
        // The person's answer must be recorded even though this view goes away with it.
        Task {
            await library.requestAccess()
            settings.completeOnboarding()
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 84
    @State private var bounces = 0

    var body: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                Image(systemName: "photo.on.rectangle.angled.fill")
                    .font(.system(size: heroSize))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: bounces)
                    .padding(.bottom, Theme.Spacing.large * 1.5)
                    .accessibilityHidden(true)
                    .hiddenInCompactHeight()
                Text("Welcome to Pickr.", comment: "Onboarding: the first screen's title.")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Theme.Spacing.large * 2)
                VStack(alignment: .leading, spacing: Theme.Spacing.large * 1.5) {
                    FeatureRow(
                        systemImage: "rectangle.stack",
                        title: Text("Moments", comment: "Onboarding row title: what a moment is."),
                        detail: Text(
                            "Photos taken seconds apart, like a burst or a few tries at the same shot.",
                            comment: "Onboarding row: what a moment is."
                        )
                    )
                    FeatureRow(
                        systemImage: "hand.tap",
                        title: Text("Tap to keep", comment: "Onboarding row title: how to choose photos."),
                        detail: Text(
                            "Tap the photos you want to keep. The rest go to Recently Deleted.",
                            comment: "Onboarding row: tapping marks the photos to keep; the others are deleted."
                        )
                    )
                    FeatureRow(
                        systemImage: "checkmark.shield",
                        title: Text("100% on-device", comment: "Onboarding row title: everything stays on the device."),
                        detail: Text("No accounts, no cloud, no AI.", comment: "Onboarding row: privacy promise.")
                    )
                }
            }
        } action: {
            BottomActionButton(title: Text("Continue", comment: "Onboarding: go to the next step."), action: onContinue)
        }
        .task {
            // Once, a moment after the screen appears, like the mockup.
            guard !reduceMotion, bounces == 0 else { return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { bounces += 1 }
        }
    }
}

private struct AccessStep: View {
    let isRequesting: Bool
    let onAllow: () -> Void

    var body: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                AccessArt()
                    .padding(.bottom, Theme.Spacing.large * 1.5)
                    .hiddenInCompactHeight()
                // The same words as the Moments tab's primer (MomentsStates), so they read the
                // same if access is ever reset.
                Text("Photo access", comment: "Moments tab when photo access was never asked: title.")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, Theme.Spacing.medium)
                Text(
                    "Pickr. looks at when each photo was taken to find moments, and deletes only what you say. Next, iOS asks which photos Pickr. can see. You can change this any time in Settings.",
                    comment: "Moments tab when photo access was never asked: explanation before the iOS prompt."
                )
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        } action: {
            BottomActionButton(
                title: Text("Continue", comment: "Onboarding: go to the next step."),
                isEnabled: !isRequesting,
                action: onAllow
            )
            .accessibilityHint(Text("Shows the iOS question about photo access.", comment: "VoiceOver hint of Continue on the photo access step of onboarding."))
        }
    }
}

// MARK: - Layout

/// One onboarding step: its content centred in a readable column that scrolls when it
/// doesn't fit, and its button in the bottom bar.
private struct OnboardingPage<Content: View, Action: View>: View {
    private let content: Content
    private let action: Action

    init(@ViewBuilder content: () -> Content, @ViewBuilder action: () -> Action) {
        self.content = content()
        self.action = action()
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Theme.Spacing.large * 2)
                .padding(.vertical, Theme.Spacing.large)
                .readableWidth()
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center, for: .alignment)
        .safeAreaBar(edge: .bottom) {
            action
        }
    }
}

/// The screen's one prominent action, at the bottom (onboarding, What's New): flexible width
/// up to 420 pt, centred.
struct BottomActionButton: View {
    let title: Text
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
        }
        .buttonStyle(.glassProminent)
        .buttonSizing(.flexible)
        .controlSize(.large)
        .disabled(!isEnabled)
        .frame(maxWidth: ReadableWidth.button)
        .padding(.horizontal, Theme.Spacing.large * 1.5)
        .padding(.bottom, Theme.Spacing.medium)
    }
}

/// An accent symbol beside a bold title and a secondary line; one element for VoiceOver
/// (onboarding, What's New).
struct FeatureRow: View {
    let systemImage: String
    let title: Text
    let detail: Text

    @ScaledMetric(relativeTo: .title) private var iconWidth: CGFloat = 36

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.large) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.headline)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Nine tilted squares that stand in for a photo library (synthetic colours, never real
/// photos). Decorative.
private struct AccessArt: View {
    private static let side: CGFloat = 56
    private static let gap: CGFloat = 5

    /// Two colours per square, loosely a dog, a pizza, a sunset, snow, a beach, a city,
    /// tulips, a lake and a forest.
    private static let swatches: [(Color, Color)] = [
        (Color(red: 0.76, green: 0.60, blue: 0.42), Color(red: 0.46, green: 0.33, blue: 0.22)),
        (Color(red: 0.95, green: 0.66, blue: 0.32), Color(red: 0.78, green: 0.26, blue: 0.16)),
        (Color(red: 1.00, green: 0.66, blue: 0.38), Color(red: 0.84, green: 0.34, blue: 0.47)),
        (Color(red: 0.90, green: 0.94, blue: 0.99), Color(red: 0.62, green: 0.72, blue: 0.85)),
        (Color(red: 0.45, green: 0.78, blue: 0.93), Color(red: 0.96, green: 0.87, blue: 0.64)),
        (Color(red: 0.47, green: 0.52, blue: 0.62), Color(red: 0.20, green: 0.24, blue: 0.33)),
        (Color(red: 0.98, green: 0.46, blue: 0.56), Color(red: 0.34, green: 0.64, blue: 0.30)),
        (Color(red: 0.36, green: 0.61, blue: 0.86), Color(red: 0.18, green: 0.40, blue: 0.36)),
        (Color(red: 0.32, green: 0.57, blue: 0.33), Color(red: 0.12, green: 0.30, blue: 0.18)),
    ]

    var body: some View {
        Grid(horizontalSpacing: Self.gap, verticalSpacing: Self.gap) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let colors = Self.swatches[row * 3 + column]
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .top, endPoint: .bottom))
                            .frame(width: Self.side, height: Self.side)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                }
            }
        }
        .rotationEffect(.degrees(-4))
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Welcome") {
    RootPreviewHost(.newUser) {
        OnboardingView()
    }
}

#Preview("Photo access") {
    RootPreviewHost(.newUser) {
        OnboardingView(step: .access)
    }
}

#Preview("Welcome, landscape", traits: .landscapeLeft) {
    RootPreviewHost(.newUser) {
        OnboardingView()
    }
}

#Preview("Photo access, large text, dark") {
    RootPreviewHost(.newUser) {
        OnboardingView(step: .access)
    }
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.dark)
}

#Preview("Welcome, wide window", traits: .fixedLayout(width: 1032, height: 1376)) {
    RootPreviewHost(.newUser) {
        OnboardingView()
    }
    .environment(\.horizontalSizeClass, .regular)
}
#endif
