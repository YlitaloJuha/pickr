import Accessibility
import PickrCore
import PickrModels
import SwiftUI

// For screen agents (WP11 Settings, WP7 Moments):
//
//   GroupingForm()                  the Adjust controls (S6, COPY.md). Push it inside any
//                                   NavigationStack, for example from Settings' "Photos taken
//                                   within" and "Look back" rows. It pushes Pick Dates and How
//                                   Pickr. Finds Moments on that same stack with view-based
//                                   destinations, so the stack's path type doesn't matter.
//   window.photosTakenWithinLabel   "10 sec", "1 min", "20 min": the current choice in words,
//   range.lookBackLabel             "Week", "Month", "Everything", "Apr 1 – 18, 2026", for the
//                                   value side of a Settings row (both are `Text`).
//
// Every change writes `settings.grouping`, which regroups the Moments list at once, off the
// main actor and with no PhotoKit call. "Pick Dates…" with no saved dates pushes Pick Dates
// without storing anything; Back puts the picker back, so `.custom` is never stored without
// dates. Only `range.preset` is assigned for the other choices, so saved dates are kept.

/// "Photos taken within", "Look back" and the live summary (§3.3 S6, COPY.md); also pushed
/// from Settings.
struct GroupingForm: View {
    /// The Adjust sheet's detent: pushing Pick Dates or the help page raises it to large.
    /// `nil` when the form is pushed from Settings.
    private let detent: Binding<PresentationDetent>?

    /// "Pick Dates…" was chosen with no saved dates: Pick Dates is pushed and the picker shows
    /// "Pick Dates…" until it applies or goes back.
    @State private var isChoosingDates = false

    init() {
        detent = nil
    }

    init(detent: Binding<PresentationDetent>) {
        self.detent = detent
    }

    var body: some View {
        Form {
            AdjustSummary()
            WindowSection()
            LookBackSection(isChoosingDates: $isChoosingDates, detent: detent)
            Section {
                NavigationLink {
                    HowItWorksScreen(anchor: .grouping)
                        .onAppear { detent?.wrappedValue = .large }
                } label: {
                    Text("How Pickr. Finds Moments", comment: "Adjust: link to the help page about how moments are found.")
                        .foregroundStyle(.tint)
                }
            }
        }
        .navigationTitle(Text("Adjust", comment: "Title of the sheet that changes how moments are found."))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isChoosingDates) {
            CustomRangeScreen()
                .onAppear { detent?.wrappedValue = .large }
        }
    }
}

// MARK: - Summary

/// "7 moments · 48 photos · about 32 MB to free up", updated live as the list regroups.
private struct AdjustSummary: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        Section {
            Group {
                if case .indexing = library.phase {
                    ReadingLibraryLabel()
                } else {
                    MomentsSummaryText(figures: SummaryFigures(library.moments))
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }
}

/// The numbers the summary shows, so the view compares four values instead of the list.
private struct SummaryFigures: Hashable {
    var moments: Int
    var photos: Int
    var savings: ByteEstimate

    init(_ list: MomentList) {
        moments = list.moments.count
        photos = list.photoCount
        savings = list.savings
    }
}

private struct ReadingLibraryLabel: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView()
            Text("Reading your library…", comment: "Adjust summary while the photo library is still being read.")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MomentsSummaryText: View {
    let figures: SummaryFigures

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var announced: SummaryFigures?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Self.oneLine(figures)
                .font(.headline)
                .lineLimit(1)
            VStack(spacing: 2) {
                Self.counts(figures)
                    .font(.headline)
                if let savings = Self.savings(figures) {
                    savings
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
        }
        .contentTransition(.numericText())
        .animation(reduceMotion ? nil : .snappy, value: figures)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.oneLine(figures))
        // A change made behind the sheet is announced, so VoiceOver hears what a choice found.
        .task(id: figures) {
            guard let announced else {
                announced = figures
                return
            }
            guard voiceOverEnabled, announced != figures else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self.announced = figures
            AccessibilityNotification.Announcement(Self.spoken(figures)).post()
        }
    }

    private static func counts(_ figures: SummaryFigures) -> Text {
        if figures.moments == 0 {
            return Text("No moments", comment: "Adjust summary when the current choices find no moments.")
        }
        return Text(
            "\(figures.moments) moments · \(figures.photos) photos",
            comment: "Adjust summary. 1: number of moments. 2: number of photos in them."
        )
    }

    private static func savings(_ figures: SummaryFigures) -> Text? {
        guard figures.moments > 0, figures.savings.bytes > 0 else { return nil }
        let bytes = PickrFormat.bytes(figures.savings.bytes)
        if figures.savings.isApproximate {
            return Text("about \(bytes) to free up", comment: "Adjust summary, second line: estimated space, for example 32 MB, when some sizes are unknown.")
        }
        return Text("\(bytes) to free up", comment: "Adjust summary, second line: space to free, for example 32 MB.")
    }

    private static func oneLine(_ figures: SummaryFigures) -> Text {
        guard figures.moments > 0, figures.savings.bytes > 0 else { return counts(figures) }
        let bytes = PickrFormat.bytes(figures.savings.bytes)
        if figures.savings.isApproximate {
            return Text(
                "\(figures.moments) moments · \(figures.photos) photos · about \(bytes) to free up",
                comment: "Adjust summary. 1: moments. 2: photos. 3: estimated space, for example 32 MB, when some sizes are unknown."
            )
        }
        return Text(
            "\(figures.moments) moments · \(figures.photos) photos · \(bytes) to free up",
            comment: "Adjust summary. 1: moments. 2: photos. 3: space to free, for example 32 MB."
        )
    }

    private static func spoken(_ figures: SummaryFigures) -> String {
        if figures.moments == 0 {
            return String(localized: "No moments", comment: "Adjust summary when the current choices find no moments.")
        }
        return String(
            localized: "\(figures.moments) moments · \(figures.photos) photos",
            comment: "Adjust summary. 1: number of moments. 2: number of photos in them."
        )
    }
}

// MARK: - Photos taken within

/// The "Photos taken within" choices. `other` is a custom 1–120 min window.
private enum WindowChoice: Hashable {
    case seconds10, seconds30, minute1, minutes3, other

    init(_ window: TimeWindow) {
        guard !window.isCustom else {
            self = .other
            return
        }
        switch window.seconds {
        case 10: self = .seconds10
        case 30: self = .seconds30
        case 60: self = .minute1
        case 180: self = .minutes3
        default: self = .other
        }
    }

    var presetSeconds: Int? {
        switch self {
        case .seconds10: 10
        case .seconds30: 30
        case .minute1: 60
        case .minutes3: 180
        case .other: nil
        }
    }
}

extension SettingsModel {
    /// The "Photos taken within" picker. Choosing Other… starts a custom window at
    /// `otherMinutes` (unless the window is custom already); a preset replaces it.
    fileprivate subscript(windowChoice otherMinutes: Int) -> WindowChoice {
        get { WindowChoice(grouping.window) }
        set {
            if let seconds = newValue.presetSeconds {
                grouping.window = TimeWindow(seconds: seconds, isCustom: false)
            } else if !grouping.window.isCustom {
                grouping.window = .custom(minutes: otherMinutes)
            }
        }
    }
}

extension TimeWindow {
    /// The window in whole minutes, 1–120, as the Other… slider shows it.
    fileprivate var customMinutes: Int {
        min(max(Int((Double(seconds) / 60).rounded()), 1), 120)
    }

    /// "10 sec", "30 sec", "1 min", "3 min" or "20 min": the "Photos taken within" choice in
    /// words, for a Settings row.
    var photosTakenWithinLabel: Text {
        switch WindowChoice(self) {
        case .seconds10: Text("10 sec", comment: "Photos taken within: 10 seconds.")
        case .seconds30: Text("30 sec", comment: "Photos taken within: 30 seconds.")
        case .minute1: Text("1 min", comment: "Photos taken within: 1 minute.")
        case .minutes3: Text("3 min", comment: "Photos taken within: 3 minutes.")
        case .other: Text("\(customMinutes) min", comment: "Photos taken within a custom number of minutes, for example 20 min.")
        }
    }
}

private struct WindowSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last custom value this session, so Other… comes back to it.
    @State private var lastCustomMinutes: Int?

    /// Other… from a preset starts at the slider's first tick: a visibly longer time.
    private static let firstCustomMinutes = 5

    var body: some View {
        @Bindable var settings = settings
        let window = settings.grouping.window
        Section {
            AdaptivePicker(
                Text("Photos taken within", comment: "Adjust: section title and picker label for the time between photos in one moment."),
                selection: $settings[windowChoice: lastCustomMinutes ?? Self.firstCustomMinutes]
                    .animation(reduceMotion ? nil : .default)
            ) {
                Text("10 sec", comment: "Photos taken within: 10 seconds.").tag(WindowChoice.seconds10)
                Text("30 sec", comment: "Photos taken within: 30 seconds.").tag(WindowChoice.seconds30)
                Text("1 min", comment: "Photos taken within: 1 minute.").tag(WindowChoice.minute1)
                Text("3 min", comment: "Photos taken within: 3 minutes.").tag(WindowChoice.minutes3)
                Text("Other…", comment: "Photos taken within: choose any number of minutes.").tag(WindowChoice.other)
            }
            .hapticFeedback(.groupingChanged, trigger: WindowChoice(window))
            .onChange(of: window, initial: true) { _, newWindow in
                if newWindow.isCustom { lastCustomMinutes = newWindow.customMinutes }
            }
            if window.isCustom {
                CustomWindowSlider(minutes: window.customMinutes)
            }
        } header: {
            Text("Photos taken within", comment: "Adjust: section title and picker label for the time between photos in one moment.")
        } footer: {
            Text(
                "Photos taken close together become one moment. A longer time makes bigger moments.",
                comment: "Adjust: footer under Photos taken within."
            )
        }
    }
}

/// Other…: 1–120 min in whole minutes. Dragging regroups at most every 150 ms and once more on
/// release, so the list behind the sheet follows the finger without regrouping on every step.
private struct CustomWindowSlider: View {
    @Environment(SettingsModel.self) private var settings
    @State private var minutes: Double
    @State private var isEditing = false
    @State private var lastApplied: ContinuousClock.Instant?

    private static let throttle: Duration = .milliseconds(150)
    private static let tickMinutes: Set<Int> = [5, 15, 30, 60, 120]

    init(minutes: Int) {
        self.minutes = Double(minutes)
    }

    var body: some View {
        let shown = Int(minutes.rounded())
        let applied = settings.grouping.window.customMinutes
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            LabeledContent {
                Text("\(shown) min", comment: "Photos taken within a custom number of minutes, for example 20 min.")
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
            } label: {
                Text("Other", comment: "Adjust: label of the custom time slider.")
            }
            .accessibilityHidden(true)
            Slider(
                value: $minutes,
                in: 1...120,
                step: 1,
                label: {
                    Text("Photos taken within", comment: "Adjust: section title and picker label for the time between photos in one moment.")
                },
                tick: { value in
                    Self.tickMinutes.contains(Int(value)) ? SliderTick(value) { Text(Int(value), format: .number) } : nil
                },
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing { apply(Int(minutes.rounded())) }
                }
            )
            .accessibilityValue(Text("\(shown) minutes", comment: "VoiceOver value of the custom time slider."))
        }
        .padding(.vertical, Theme.Spacing.extraSmall)
        .onChange(of: applied) { _, newValue in
            if !isEditing { minutes = Double(newValue) }
        }
        .task(id: shown) {
            // A trailing-edge throttle anchored to the last regroup.
            guard shown != settings.grouping.window.customMinutes || !settings.grouping.window.isCustom else { return }
            if let lastApplied {
                let wait = Self.throttle - (ContinuousClock.now - lastApplied)
                if wait > .zero { try? await Task.sleep(for: wait) }
                guard !Task.isCancelled else { return }
            }
            apply(shown)
        }
    }

    private func apply(_ value: Int) {
        lastApplied = .now
        let window = TimeWindow.custom(minutes: value)
        if settings.grouping.window != window { settings.grouping.window = window }
    }
}

// MARK: - Look back

extension ScanRange {
    /// "Week", "2 Weeks", "Month", "Everything", or the picked dates ("Apr 1 – 18, 2026"): the
    /// "Look back" choice in words, for a Settings row.
    var lookBackLabel: Text {
        switch effectivePreset {
        case .d7: Text("Week", comment: "Look back: the last 7 days.")
        case .d14: Text("2 Weeks", comment: "Look back: the last 14 days.")
        case .d30: Text("Month", comment: "Look back: the last 30 days.")
        case .all: Text("Everything", comment: "Look back: the whole library.")
        case .custom: Text(verbatim: custom.map(Self.datesText) ?? "")
        }
    }

    /// "Apr 1 – 18, 2026", in the user's locale.
    fileprivate static func datesText(_ range: CustomRange) -> String {
        (range.start..<range.end).formatted(Date.IntervalFormatStyle(date: .abbreviated, time: .omitted))
    }
}

private struct LookBackSection: View {
    @Binding var isChoosingDates: Bool
    let detent: Binding<PresentationDetent>?

    @Environment(SettingsModel.self) private var settings

    var body: some View {
        let range = settings.grouping.range
        Section {
            AdaptivePicker(
                Text("Look back", comment: "Adjust: section title and picker label for how far back to look for moments."),
                selection: selection
            ) {
                Text("Week", comment: "Look back: the last 7 days.").tag(ScanRangePreset.d7)
                Text("2 Weeks", comment: "Look back: the last 14 days.").tag(ScanRangePreset.d14)
                Text("Month", comment: "Look back: the last 30 days.").tag(ScanRangePreset.d30)
                Text("Everything", comment: "Look back: the whole library.").tag(ScanRangePreset.all)
                Text("Pick Dates…", comment: "Look back: choose a first and last day.").tag(ScanRangePreset.custom)
            }
            .hapticFeedback(.groupingChanged, trigger: range.effectivePreset)
            if let custom = range.custom {
                NavigationLink {
                    CustomRangeScreen()
                        .onAppear { detent?.wrappedValue = .large }
                } label: {
                    Text(ScanRange.datesText(custom))
                }
                .accessibilityLabel(Text(
                    "Pick Dates, \(ScanRange.datesText(custom))",
                    comment: "VoiceOver: the row that opens Pick Dates with the saved dates. The variable is the dates, for example Apr 1 – 18, 2026."
                ))
            }
        } header: {
            Text("Look back", comment: "Adjust: section title and picker label for how far back to look for moments.")
        } footer: {
            if range.effectivePreset == .all {
                Text("Looking back further can find many more moments.", comment: "Adjust: footer under Look back when Everything is chosen.")
            }
        }
    }

    /// The picker shows "Pick Dates…" while Pick Dates is open for a first choice; otherwise the
    /// stored choice. Choosing it with no saved dates opens Pick Dates and stores nothing.
    /// A get/set binding because the choice depends on view state as well as the model.
    private var selection: Binding<ScanRangePreset> {
        let settings = settings
        let isChoosingDates = $isChoosingDates
        return Binding {
            isChoosingDates.wrappedValue ? .custom : settings.grouping.range.effectivePreset
        } set: { choice in
            if choice == .custom, settings.grouping.range.custom == nil {
                isChoosingDates.wrappedValue = true
            } else if settings.grouping.range.preset != choice {
                settings.grouping.range.preset = choice
            }
        }
    }
}

// MARK: - Picker

/// A segmented picker that tightens, then turns into a menu picker, when its segments don't
/// fit the width (long labels, large text, a narrow window), as `ViewThatFits` decides from the
/// segments' own size.
private struct AdaptivePicker<Value: Hashable, Options: View>: View {
    let label: Text
    @Binding var selection: Value
    let options: Options

    init(_ label: Text, selection: Binding<Value>, @ViewBuilder options: () -> Options) {
        self.label = label
        _selection = selection
        self.options = options()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker(selection: $selection) {
                options
            } label: {
                label
            }
            .pickerStyle(.segmented)
            Picker(selection: $selection) {
                options
            } label: {
                label
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            Picker(selection: $selection) {
                options
            } label: {
                label
            }
            .pickerStyle(.menu)
        }
    }
}

#if DEBUG
#Preview("Adjust form") {
    let services = AdjustPreview.services()
    NavigationStack {
        GroupingForm()
    }
    .adjustPreviewEnvironment(services)
}

#Preview("Other… and Everything") {
    let services = AdjustPreview.services { settings in
        settings.grouping.window = .custom(minutes: 20)
        settings.grouping.range.preset = .all
    }
    NavigationStack {
        GroupingForm()
    }
    .adjustPreviewEnvironment(services)
}

#Preview("Saved dates, large text") {
    let services = AdjustPreview.services { settings in
        settings.grouping.range = AdjustPreview.savedDates
    }
    NavigationStack {
        GroupingForm()
    }
    .adjustPreviewEnvironment(services)
    .environment(\.dynamicTypeSize, .accessibility2)
}
#endif
