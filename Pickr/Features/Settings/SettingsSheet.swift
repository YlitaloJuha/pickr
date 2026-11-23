import Accessibility
import PickrCore
import PickrModels
import SwiftUI

/// Settings (§3.3 S9, ADAPTIVE S9, COPY.md): a `NavigationStack` around a `Form`, closed with
/// the close button. MomentsColumns presents it from `router.sheet` (large, form-sized when
/// regular, zooming out of the gear button). Plain system glass and background.
///
/// - **Your progress:** the lifetime stats.
/// - **Adjust:** "Photos taken within" and "Look back" both push the shared `GroupingForm`
///   (v1 users look for these here).
/// - **Safety:** Never delete favorites. Then **Vibration**.
/// - **Help:** How Pickr. Finds Moments, Get Deleted Photos Back, Show Tips Again, Send
///   Feedback (Mail, to the address README.md and privacy.md publish).
/// - **About:** Privacy Policy, Source Code, the version from the bundle, device-neutral copy.
///
/// Links open other apps; the app itself sends nothing.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ProgressSection()
                AdjustSection()
                SafetySection()
                VibrationSection()
                HelpSection()
                AboutSection()
            }
            .navigationTitle(Text("Settings", comment: "Title of the Settings sheet."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Your progress

private struct ProgressSection: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let stats = settings.stats
        Section {
            StatRow(label: Text("Photos deleted", comment: "Settings, Your progress: photos deleted with Pickr.")) {
                Text(stats.photosDeleted, format: .number)
            }
            StatRow(label: Text("Space freed up", comment: "Settings, Your progress: storage freed up by deleting.")) {
                Text(PickrFormat.bytes(stats.bytesFreed))
            }
            StatRow(label: Text("Moments done", comment: "Settings, Your progress: moments cleaned up.")) {
                Text(stats.momentsCleared, format: .number)
            }
            StatRow(label: Text("Using Pickr. since", comment: "Settings, Your progress: the day Pickr. was first used.")) {
                Text(stats.firstUse, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
            }
        } header: {
            Text("Your progress", comment: "Settings section header: lifetime numbers.")
        }
    }
}

/// A label with its value in the primary colour (§3.3 S9: values never fade).
private struct StatRow<Value: View>: View {
    let label: Text
    @ViewBuilder let value: Value

    var body: some View {
        LabeledContent {
            value
                .foregroundStyle(.primary)
                .monospacedDigit()
        } label: {
            label
        }
    }
}

// MARK: - Adjust

private struct AdjustSection: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let grouping = settings.grouping
        Section {
            NavigationLink {
                GroupingForm()
            } label: {
                LabeledContent {
                    grouping.window.photosTakenWithinLabel
                } label: {
                    Text("Photos taken within", comment: "Settings row: how close in time photos must be to form a moment. Opens Adjust.")
                }
            }
            NavigationLink {
                GroupingForm()
            } label: {
                LabeledContent {
                    grouping.range.lookBackLabel
                } label: {
                    Text("Look back", comment: "Settings row: how far back Pickr. looks for moments. Opens Adjust.")
                }
            }
        } header: {
            Text("Adjust", comment: "Settings section header: how moments are found (the same controls as the Adjust sheet).")
        }
    }
}

// MARK: - Safety and vibration

private struct SafetySection: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.protectFavorites) {
                Text("Never delete favorites", comment: "Settings switch: favorite and rated photos are always kept.")
            }
        } header: {
            Text("Safety", comment: "Settings section header: protecting photos from deletion.")
        } footer: {
            Text("Favorites start as kept and Delete All skips them.", comment: "Settings footer under Never delete favorites.")
        }
    }
}

private struct VibrationSection: View {
    @Environment(SettingsModel.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.hapticsEnabled) {
                Text("Vibration", comment: "Settings switch: small vibrations when you keep, delete or change things.")
            }
        }
    }
}

// MARK: - Help

private struct HelpSection: View {
    @State private var tipsReset = false

    var body: some View {
        Section {
            NavigationLink {
                HowItWorksScreen()
            } label: {
                Text("How Pickr. Finds Moments", comment: "Settings row: opens the help page about how moments are found.")
            }
            NavigationLink {
                HowItWorksScreen(anchor: .recover)
            } label: {
                Text("Get Deleted Photos Back", comment: "Settings row: opens the help about recovering photos from Recently Deleted.")
            }
            Button {
                showTipsAgain()
            } label: {
                Text("Show Tips Again", comment: "Settings button: the hints show again.")
            }
            ExternalLinkRow(
                title: Text("Send Feedback", comment: "Settings row: writes an email to the developer in Mail."),
                destination: SettingsLinks.feedback,
                hint: Text("Opens Mail.", comment: "VoiceOver hint of Send Feedback.")
            )
        } header: {
            Text("Help", comment: "Settings section header: help and feedback.")
        } footer: {
            if tipsReset {
                Text("Tips will show again.", comment: "Settings footer after Show Tips Again was tapped.")
            }
        }
    }

    /// Resets every tip. The confirmation shows under the section (a sheet has no toast) and
    /// is announced to VoiceOver.
    private func showTipsAgain() {
        tipsReset = true
        AccessibilityNotification.Announcement(
            String(localized: "Tips will show again.", comment: "Settings footer after Show Tips Again was tapped.")
        ).post()
        // Quick, and it must finish even if the sheet closes right away.
        Task {
            await PickrTips.showAgain()
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    var body: some View {
        Section {
            ExternalLinkRow(
                title: Text("Privacy Policy", comment: "Settings row: opens the privacy policy web page."),
                destination: SettingsLinks.privacyPolicy,
                hint: Text("Opens in your web browser.", comment: "VoiceOver hint of a Settings row that opens a web page.")
            )
            ExternalLinkRow(
                title: Text("Source Code", comment: "Settings row: opens Pickr.'s source code on GitHub."),
                destination: SettingsLinks.sourceCode,
                hint: Text("Opens in your web browser.", comment: "VoiceOver hint of a Settings row that opens a web page.")
            )
            LabeledContent {
                Text(verbatim: AppVersion.current)
                    .foregroundStyle(.primary)
            } label: {
                Text("Version", comment: "Settings row: the app's version number.")
            }
        } header: {
            Text("About", comment: "Settings section header: about the app.")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text(
                    "Pickr. runs entirely on your device. No accounts, no cloud, no AI.",
                    comment: "Settings footer: the privacy promise."
                )
                if let copyright = AppVersion.copyright {
                    Text(copyright)
                }
            }
        }
    }
}

/// A row that opens another app (Safari, Mail), with the arrow that says so.
private struct ExternalLinkRow: View {
    let title: Text
    let destination: URL
    let hint: Text

    var body: some View {
        Link(destination: destination) {
            HStack {
                title
                Spacer(minLength: Theme.Spacing.small)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .accessibilityHint(hint)
    }
}

/// Where the About and Help links go: the published privacy policy (the App Store Privacy
/// Policy URL), the public repo, and the support address README.md and privacy.md publish.
private nonisolated enum SettingsLinks {
    static let privacyPolicy = URL(string: "https://ylitalojuha.github.io/pickr/privacy")!
    static let sourceCode = URL(string: "https://github.com/YlitaloJuha/pickr")!
    static let feedback = URL(string: "mailto:54-onrush-clones@icloud.com")!
}

/// The version and copyright from the bundle's Info.plist.
private nonisolated enum AppVersion {
    /// "2.0 (9)": `CFBundleShortVersionString` and `CFBundleVersion`.
    static var current: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    /// "© 2026 Juha Ylitalo" (`NSHumanReadableCopyright`).
    static var copyright: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }
}

#if DEBUG
#Preview("Settings") {
    RootPreviewHost(.returning) {
        SettingsSheet()
    }
}

#Preview("Settings, as a sheet") {
    RootPreviewHost(.upgrader) {
        Color(.systemGroupedBackground)
            .sheet(isPresented: .constant(true)) {
                SettingsSheet()
                    .presentationDetents([.large])
                    .presentationSizing(.form)
            }
    }
}

#Preview("Settings, large text, dark") {
    RootPreviewHost(.returning) {
        SettingsSheet()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.dark)
}

#Preview("Settings, wide window", traits: .fixedLayout(width: 1180, height: 820)) {
    RootPreviewHost(.returning) {
        Color(.systemGroupedBackground)
            .sheet(isPresented: .constant(true)) {
                SettingsSheet()
                    .presentationDetents([.large])
                    .presentationSizing(.form)
            }
    }
    .environment(\.horizontalSizeClass, .regular)
}
#endif
