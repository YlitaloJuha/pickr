import PickrCore
import PickrModels
import PickrPersistence
import SwiftUI

/// The Moments tab's root screen (§3.3 S3, ADAPTIVE S3): large title "Moments", the count
/// and size subtitle, the toolbar (Adjust, Sort, Settings) and, by access × phase, the list,
/// "All clean" or one of the full-width states.
///
/// - **Stack** (`selection == nil`): a tap pushes Review; this screen paints the list's
///   ambient background, the photo strip behind its rows.
/// - **Split sidebar** (`selection` set): `List(selection:)` highlights the moment under
///   review and follows Skip and commits; the background stays clear, because the detail
///   column owns the tab's ambient background.
/// - Adjust is presented from its toolbar button by `adjustPresentation` (GroupingSheet.swift):
///   the S6 sheet in the stack, a popover in the split, both driven by `router.sheet`.
/// - The list reports its rows' frames (`focus`, for the strip), the moment under its focus
///   line (`focusedMoment`, for the split's start view) and its scroll anchor (`anchor`); the
///   last two survive a stack ↔ split swap. After a review it scrolls to `Router.scrollTarget`.
/// - Day sections ("Today", "Yesterday", a weekday, a date) with Newest First; one flat
///   list with Biggest First.
struct MomentsScreen: View {
    /// The split sidebar's selection (`Router.reviewSelection`); `nil` in the stack.
    let selection: Binding<MomentID?>?
    /// The moment at the top of the list, kept above the stack/split switch.
    @Binding var anchor: MomentID?
    /// The moment under the list's focus line, for the ambient background.
    @Binding var focusedMoment: MomentID?
    /// The limited-access banner was hidden for this app session.
    @Binding var bannerDismissed: Bool
    /// The zoom-transition namespace shared with Review and the sheets.
    let namespace: Namespace.ID

    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(Router.self) private var router
    @Environment(\.curator) private var curator
    @Environment(\.columnLayout) private var columnLayout
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.hasFinishedLaunch) private var hasFinishedLaunch
    @Environment(CommandHaptics.self) private var appHaptics: CommandHaptics?

    @State private var sections = MomentSectionCache()
    @State private var today = Calendar.autoupdatingCurrent.startOfDay(for: .now)
    /// Moments whose rows are on screen.
    @State private var visible: Set<MomentID> = []
    /// This list's focus tracking; `focusedMoment` keeps its result across a swap.
    @State private var focus = ScrollFocus<MomentID>()
    @State private var didRestoreAnchor = false
    @State private var showsLimitedPicker = false
    /// Bumped when the limited-library picker closes, to refresh the library.
    @State private var limitedPickerClosings = 0
    /// "Updating…" shows only for refreshes that take a moment, so it never flickers.
    @State private var showsUpdating = false
    @State private var sortChanges = 0
    /// A Keep All or Delete All started from this list: its row leaves with an animation once
    /// the moment is gone (a delete only after the iOS dialog, outside any view transaction).
    @State private var leaving: MomentID? = nil
    /// Adjust was opened from its toolbar button, so the sheet zooms out of it; from the
    /// list's footer or "All clean" it slides up.
    @State private var adjustFromToolbar = true

    init(
        selection: Binding<MomentID?>?,
        anchor: Binding<MomentID?>,
        focusedMoment: Binding<MomentID?>,
        bannerDismissed: Binding<Bool>,
        namespace: Namespace.ID
    ) {
        self.selection = selection
        _anchor = anchor
        _focusedMoment = focusedMoment
        _bannerDismissed = bannerDismissed
        self.namespace = namespace
    }

    var body: some View {
        let state = MomentsState(
            access: library.access,
            phase: library.phase,
            hasMoments: !library.moments.moments.isEmpty
        )
        content(for: displayed(state))
            // The primer, loading, failed, list and "All clean" states replace each other with a
            // cross-fade (progress within a state doesn't animate).
            .animation(Motion.crossFade, value: displayed(state).kind)
            // Not in the split's list column: there the inline title shares a narrow bar with
            // the toolbar and the subtitle was cut off, and the detail column shows the same
            // summary (ReviewStartView).
            .modifier(MomentsSubtitle(text: columnLayout == .split ? nil : subtitle(for: state)))
            .navigationTitle(Text("Moments", comment: "Title of the Moments tab and its screen."))
            .toolbar { toolbar(for: state) }
            .background {
                LimitedLibraryPicker(isPresented: $showsLimitedPicker) {
                    limitedPickerClosings += 1
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .task(id: limitedPickerClosings) {
                guard limitedPickerClosings > 0 else { return }
                await library.refresh()
            }
            .task(id: library.isRefreshing) {
                guard library.isRefreshing else {
                    showsUpdating = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { showsUpdating = true }
            }
            .task(id: today) {
                // Day titles turn over at midnight while the app stays open.
                let calendar = Calendar.autoupdatingCurrent
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return }
                try? await Task.sleep(for: .seconds(max(tomorrow.timeIntervalSinceNow, 1)))
                guard !Task.isCancelled else { return }
                today = calendar.startOfDay(for: .now)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                let day = Calendar.autoupdatingCurrent.startOfDay(for: .now)
                if day != today { today = day }
            }
            .hapticFeedback(.groupingChanged, trigger: sortChanges)
    }

    // MARK: - Content

    /// Until launch has read the access it is still `.notDetermined`, so returning users would
    /// see the access primer flash on every launch: show the loading state instead.
    private func displayed(_ state: MomentsState) -> MomentsState {
        state == .primer && !hasFinishedLaunch ? .loading(done: 0, total: 0) : state
    }

    @ViewBuilder
    private func content(for state: MomentsState) -> some View {
        switch state {
        case .list:
            momentList
        case .allClean:
            allClean
        case .primer, .denied, .loading, .failed:
            MomentsStates(state: state)
                .modifier(MomentsListAmbient(focusedMoment: $focusedMoment, isEnabled: columnLayout == .stack))
        }
    }

    private var showsBanner: Bool {
        library.access == .limited && !bannerDismissed
    }

    private var momentList: some View {
        let order = settings.grouping.order
        let content = sections.content(
            for: library.moments,
            order: order,
            today: today,
            calendar: .autoupdatingCurrent
        )
        let firstID = library.moments.moments.first?.id
        return ScrollViewReader { proxy in
            List(selection: selection) {
                if showsBanner {
                    banner
                        .cardRow()
                        .selectionDisabled()
                }
                switch order {
                case .newest:
                    ForEach(content.sections) { section in
                        Section {
                            rows(section.moments, firstID: firstID, positions: content.positions)
                        } header: {
                            Text(section.title)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        .listSectionSeparator(.hidden)
                    }
                case .mostSpace:
                    rows(library.moments.moments, firstID: firstID, positions: content.positions)
                }
                MomentsFooter { openAdjust(fromToolbar: false) }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(leavingAnimation, value: library.moments)
            .readableContentMargins()
            .scrollFocusContainer(focus)
            .refreshable { await library.refresh() }
            .onChange(of: library.moments) { _, _ in
                if let leaving, library.moment(leaving) == nil { self.leaving = nil }
            }
            .onChange(of: router.scrollTarget, initial: true) { _, target in
                guard let target else { return }
                router.scrollTarget = nil
                guard library.moment(target) != nil else { return }
                // Only as far as it takes to show the card. In the stack this happens behind
                // the popping Review, whose zoom then lands on it, so it doesn't animate; in a
                // split the sidebar visibly follows.
                if columnLayout == .split, !reduceMotion {
                    withAnimation(.smooth) { proxy.scrollTo(target) }
                } else {
                    proxy.scrollTo(target)
                }
            }
            .task {
                // A new list after a stack ↔ split swap starts where the old one was.
                guard !didRestoreAnchor else { return }
                didRestoreAnchor = true
                guard router.scrollTarget == nil, let anchor, library.moment(anchor) != nil,
                      anchor != library.moments.moments.first?.id else { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .onScrollFocusChange(focus) { id in
            if focusedMoment != id { focusedMoment = id }
        }
        .modifier(MomentsListAmbient(focusedMoment: $focusedMoment, isEnabled: columnLayout == .stack, strip: focus))
    }

    private func rows(_ moments: [Moment], firstID: MomentID?, positions: [MomentID: Int]) -> some View {
        ForEach(moments) { moment in
            MomentRow(
                moment: moment,
                showsSwipeTip: moment.id == firstID,
                namespace: namespace,
                onOpen: open,
                onKeepAll: keepAll,
                onDeleteAll: deleteAll
            )
            .scrollFocusItem(moment.id, in: focus)
            .onAppear {
                visible.insert(moment.id)
                reportAnchor(positions: positions)
            }
            .onDisappear {
                visible.remove(moment.id)
                reportAnchor(positions: positions)
            }
            // Again outermost: List reads row traits (clear background, insets, no separator)
            // from the row's outer view; set only inside the wrapped row, they were lost and
            // the default opaque cell background hid the ambient strip.
            .cardRow()
        }
    }

    private var banner: some View {
        LimitedAccessBanner {
            showsLimitedPicker = true
        } onDismiss: {
            withAnimation(reduceMotion ? Motion.reducedFade : Motion.listChange) { bannerDismissed = true }
        }
    }

    private var allClean: some View {
        CenteredScrollView {
            VStack(spacing: Theme.Spacing.large) {
                if showsBanner {
                    banner
                        .readableWidth(ReadableWidth.cards)
                        .padding(.horizontal, Theme.Spacing.large)
                }
                CelebrationView {
                    openAdjust(fromToolbar: false)
                }
            }
        }
        .refreshable { await library.refresh() }
        .modifier(MomentsListAmbient(focusedMoment: $focusedMoment, isEnabled: columnLayout == .stack))
    }

    // MARK: - Subtitle and toolbar

    /// The counts while the list shows ("Updating…" during a refresh that takes a moment);
    /// nothing in every other state.
    private func subtitle(for state: MomentsState) -> Text? {
        guard state == .list else { return nil }
        if showsUpdating {
            return Text("Updating…", comment: "Moments subtitle while the library is checked for changes.")
        }
        return MomentsLabels.summary(library.moments)
    }

    @ToolbarContentBuilder
    private func toolbar(for state: MomentsState) -> some ToolbarContent {
        if state.canReadLibrary {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openAdjust(fromToolbar: true)
                } label: {
                    Label {
                        Text("Adjust", comment: "Toolbar button that opens Adjust (how moments are found).")
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                .adjustPresentation(zoomNamespace: namespace, zooms: adjustFromToolbar)
            }
            .matchedTransitionSource(id: GroupingSheet.zoomSourceID, in: namespace)
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                router.sheet = .settings
            } label: {
                Label {
                    Text("Settings", comment: "Toolbar button that opens Settings.")
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .matchedTransitionSource(id: MomentsTransitionID.settings, in: namespace)
    }

    private var sortMenu: some View {
        let order = Binding<MomentOrder> {
            settings.grouping.order
        } set: { newOrder in
            guard newOrder != settings.grouping.order else { return }
            settings.grouping.order = newOrder
            sortChanges &+= 1
        }
        return Menu {
            Picker(selection: order) {
                Text("Newest First", comment: "Sort menu: newest moments first, in day sections.")
                    .tag(MomentOrder.newest)
                Text("Biggest First", comment: "Sort menu: the moments that free up the most space first.")
                    .tag(MomentOrder.mostSpace)
            } label: {
                Text("Sort", comment: "Title of the Moments sort menu.")
            }
        } label: {
            Label {
                Text("Sort", comment: "Toolbar menu that orders the Moments list.")
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
    }

    // MARK: - Actions

    private func open(_ moment: Moment) {
        router.startReview(at: moment.id)
    }

    private func openAdjust(fromToolbar: Bool) {
        adjustFromToolbar = fromToolbar
        router.sheet = .grouping
    }

    private func keepAll(_ moment: Moment) {
        guard let curator else { return }
        leaving = moment.id
        curator.keepAside(moment)
        appHaptics?.play(.keptAside)
    }

    /// Started in a `Task`, never in `.task`, so a container swap while the iOS dialog is up
    /// can't cancel the delete. The app plays the haptic: the last moment's delete replaces
    /// this screen in a split.
    private func deleteAll(_ moment: Moment) {
        guard let curator else { return }
        leaving = moment.id
        let haptics = appHaptics
        Task {
            let result = await curator.deleteWhole(moment)
            haptics?.play(for: result)
            if leaving == moment.id, library.moment(moment.id) != nil { leaving = nil }
        }
    }

    private var leavingAnimation: Animation? {
        guard let leaving, library.moment(leaving) == nil else { return nil }
        return reduceMotion ? Motion.reducedFade : Motion.listChange
    }

    /// Publishes the first moment on screen, in list order, as the scroll anchor. An empty set
    /// (the screen was covered or torn down) keeps the last report.
    private func reportAnchor(positions: [MomentID: Int]) {
        let first = visible
            .compactMap { id in positions[id].map { (id, $0) } }
            .min { $0.1 < $1.1 }?
            .0
        guard let first else { return }
        if anchor != first { anchor = first }
    }
}

// MARK: - Subtitle

/// The navigation subtitle, or none at all (an empty subtitle would still take a line).
/// The list always has one, so the list's identity never depends on it.
private struct MomentsSubtitle: ViewModifier {
    let text: Text?

    func body(content: Content) -> some View {
        if let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

// MARK: - Footer

/// "Don't see a moment? Adjust" at the end of the list.
private struct MomentsFooter: View {
    let onAdjust: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.extraSmall) {
                prompt
                adjust
            }
            VStack(spacing: Theme.Spacing.extraSmall) {
                prompt
                adjust
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var prompt: some View {
        Text("Don't see a moment?", comment: "End of the Moments list, before the Adjust link.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var adjust: some View {
        Button(action: onAdjust) {
            Text("Adjust", comment: "End of the Moments list: opens Adjust (how moments are found).")
                // A 44 pt tap area around the small inline word (accessibility audit).
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Ambient background

/// The list's ambient background: with `strip`, the photo strip behind the list's rows;
/// otherwise (the split's start view) the first photo of the moment under the list's focus line,
/// or of the first moment until the list reports, which also stands in until the strip's rows
/// report. Plain when there is no list. A modifier, so scrolling re-renders only the background,
/// not the list.
struct MomentsListAmbient: ViewModifier {
    @Binding var focusedMoment: MomentID?
    /// `false` in the split sidebar, which paints nothing of its own.
    let isEnabled: Bool
    /// The list's rows, for the photo strip. `nil` for a single photo.
    var strip: ScrollFocus<MomentID>? = nil

    @Environment(LibraryModel.self) private var library

    func body(content: Content) -> some View {
        if isEnabled {
            content.ambientBackground(source, strip: library.showsMomentList ? strip : nil)
        } else {
            content
        }
    }

    private var source: AmbientSource {
        guard library.showsMomentList,
              let moment = focusedMoment.flatMap(library.moment) ?? library.moments.moments.first
        else { return .plain }
        return .photo(moment.photos[0].id)
    }
}

// MARK: - Day sections

/// The Moments list split into day sections, rebuilt only when the list, the order or the
/// day changes (never on every body evaluation). Also maps each moment to its position, so
/// the visible rows can be put in list order.
final class MomentSectionCache {
    struct DaySection: Identifiable {
        /// The start of the day, in the calendar's time zone.
        let id: Date
        /// "Today", "Yesterday", a weekday within the last 6 days, or a medium date.
        let title: String
        let moments: [Moment]
    }

    struct Content {
        /// Empty unless the order is Newest First.
        let sections: [DaySection]
        let positions: [MomentID: Int]
    }

    private struct Key: Equatable {
        let list: MomentList
        let order: MomentOrder
        let today: Date
        let calendar: Calendar
    }

    private var key: Key?
    private var cached = Content(sections: [], positions: [:])

    func content(for list: MomentList, order: MomentOrder, today: Date, calendar: Calendar) -> Content {
        let newKey = Key(list: list, order: order, today: today, calendar: calendar)
        if newKey == key { return cached }
        key = newKey
        cached = Self.build(list.moments, order: order, today: today, calendar: calendar)
        return cached
    }

    /// Moments are listed newest first by their last photo, so a day's moments are
    /// consecutive; a day seen again still joins its first section, so section IDs stay unique.
    static func build(_ moments: [Moment], order: MomentOrder, today: Date, calendar: Calendar) -> Content {
        var positions: [MomentID: Int] = [:]
        positions.reserveCapacity(moments.count)
        for (offset, moment) in moments.enumerated() {
            positions[moment.id] = offset
        }
        guard order == .newest else { return Content(sections: [], positions: positions) }

        var days: [Date] = []
        var byDay: [Date: [Moment]] = [:]
        for moment in moments {
            let day = calendar.startOfDay(for: moment.end)
            if byDay[day] == nil { days.append(day) }
            byDay[day, default: []].append(moment)
        }
        let sections = days.map { day in
            DaySection(
                id: day,
                title: PickrFormat.dayTitle(day, now: today, calendar: calendar),
                moments: byDay[day] ?? []
            )
        }
        return Content(sections: sections, positions: positions)
    }
}

/// Zoom-transition sources in the Moments toolbar that `MomentsColumns` presents from. Adjust
/// uses `GroupingSheet.zoomSourceID`.
enum MomentsTransitionID: Hashable {
    case settings
}

#if DEBUG
#Preview("Moments") {
    MomentsPreviewHost(.moments)
}

#Preview("Moments, limited access") {
    MomentsPreviewHost(.limited)
}

#Preview("Moments, Biggest First") {
    MomentsPreviewHost(.biggestFirst)
}

#Preview("Moments, dark") {
    MomentsPreviewHost(.moments)
        .preferredColorScheme(.dark)
}

#Preview("Moments, large text") {
    MomentsPreviewHost(.moments)
        .dynamicTypeSize(.accessibility2)
}
#endif
