import PickrCore
import PickrModels
import SwiftUI
import UIKit

/// What the Moments tab shows, from `LibraryModel.access × phase` (§3.3 S3 States).
///
/// `.list` is exactly `LibraryModel.showsMomentList`, so the column container splits only
/// while the list shows. Every other state is one full-width column (ADAPTIVE §3.2).
nonisolated enum MomentsState: Equatable, Sendable {
    /// Access was never asked (privacy settings reset after onboarding): an inline primer.
    case primer
    /// Access is off: "Pickr. needs your photos to find moments." with Open Settings.
    case denied
    /// Reading the library with no data yet. `total == 0` until the first progress event.
    case loading(done: Int, total: Int)
    /// Reading failed before any data arrived.
    case failed(LibraryError)
    /// Ready, with no moments: the "All clean" celebration.
    case allClean
    /// Ready, with at least one moment.
    case list

    init(access: LibraryAccess, phase: LoadPhase, hasMoments: Bool) {
        switch access {
        case .notDetermined:
            self = .primer
        case .denied:
            self = .denied
        case .full, .limited:
            switch phase {
            case .ready:
                self = hasMoments ? .list : .allClean
            case let .indexing(done, total):
                self = .loading(done: done, total: total)
            case .idle:
                self = .loading(done: 0, total: 0)
            case let .failed(error):
                self = .failed(error)
            }
        }
    }

    nonisolated enum Kind: Hashable, Sendable {
        case primer, denied, loading, failed, allClean, list
    }

    /// The state without its figures: what a screen animates on (progress doesn't).
    var kind: Kind {
        switch self {
        case .primer: .primer
        case .denied: .denied
        case .loading: .loading
        case .failed: .failed
        case .allClean: .allClean
        case .list: .list
        }
    }

    /// Full or limited access: the library can be read, so Adjust and Sort make sense.
    var canReadLibrary: Bool {
        switch self {
        case .primer, .denied: false
        case .loading, .failed, .allClean, .list: true
        }
    }
}

/// The full-width states of the Moments tab that aren't the list or the celebration:
/// the access primer, no access, reading the library and a failed read.
struct MomentsStates: View {
    let state: MomentsState

    @Environment(LibraryModel.self) private var library
    @Environment(\.openURL) private var openURL

    var body: some View {
        CenteredScrollView {
            VStack {
                switch state {
                case .primer:
                    primer
                case .denied:
                    denied
                case let .loading(done, total):
                    MomentsLoadingView(done: done, total: total)
                case .failed:
                    failed
                case .allClean, .list:
                    EmptyView()
                }
            }
            .padding(Theme.Spacing.large)
            .readableWidth()
        }
    }

    private var primer: some View {
        ContentUnavailableView {
            Label {
                Text("Photo access", comment: "Moments tab when photo access was never asked: title.")
            } icon: {
                Image(systemName: "photo.on.rectangle.angled")
            }
        } description: {
            Text(
                "Pickr. looks at when each photo was taken to find moments, and deletes only what you say. Next, iOS asks which photos Pickr. can see. You can change this any time in Settings.",
                comment: "Moments tab when photo access was never asked: explanation before the iOS prompt."
            )
        } actions: {
            Button {
                // A user action that must finish even if this view goes away.
                Task { await library.requestAccess() }
            } label: {
                Text("Continue", comment: "Onboarding: go to the next step.")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private var denied: some View {
        ContentUnavailableView {
            Label {
                Text("Pickr. needs your photos to find moments.", comment: "Moments tab when photo access is off: title.")
            } icon: {
                Image(systemName: "lock.shield")
            }
        } description: {
            Text("You can turn on photo access in Settings.", comment: "Moments tab when photo access is off: explanation.")
        } actions: {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("Open Settings", comment: "Button that opens Pickr.'s page in the iOS Settings app.")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private var failed: some View {
        ContentUnavailableView {
            Label {
                Text("Couldn't read your library", comment: "Moments tab when reading the photo library failed: title.")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
        } description: {
            Text("Nothing in your photos was changed.", comment: "Moments tab when reading the photo library failed: reassurance.")
        } actions: {
            Button {
                Task { await library.refresh() }
            } label: {
                Text("Try Again", comment: "Button that reads the photo library again after a failure.")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }
}

/// "Reading your library…" with a bar once the total is known (builds over 1,000 photos),
/// and an indeterminate spinner before that.
private struct MomentsLoadingView: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if total > 0 {
                ProgressView(value: Double(min(done, total)), total: Double(total)) {
                    title
                } currentValueLabel: {
                    Text(
                        "\(done, format: .number) of \(total, format: .number)",
                        comment: "Reading the library: progress. 1: photos read so far. 2: photos in the library."
                    )
                    .monospacedDigit()
                }
            } else {
                ProgressView {
                    title
                }
            }
        }
        .frame(maxWidth: ReadableWidth.button)
    }

    private var title: Text {
        Text("Reading your library…", comment: "Moments tab while the photo library is read for the first time.")
    }
}

/// A vertically centred column that scrolls when it doesn't fit (large text, a landscape
/// phone). Used by the full-width states, the celebration and the split's start view.
struct CenteredScrollView<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

#if DEBUG
#Preview("State: no access") {
    MomentsPreviewHost(.denied)
}

#Preview("State: allow access") {
    MomentsPreviewHost(.primer)
}

#Preview("State: reading, starting") {
    MomentsPreviewHost(.readingStarted)
}

#Preview("State: reading, with progress") {
    MomentsPreviewHost(.reading)
}

#Preview("State: couldn't read") {
    MomentsPreviewHost(.failed)
}

#Preview("State: no access, large text") {
    MomentsPreviewHost(.denied)
        .dynamicTypeSize(.accessibility3)
}
#endif
