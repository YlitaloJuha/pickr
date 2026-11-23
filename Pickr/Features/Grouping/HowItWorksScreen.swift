import PickrCore
import SwiftUI

// For screen agents (WP11 Settings): push `HowItWorksScreen()` for "How Pickr. Finds Moments"
// and `HowItWorksScreen(anchor: .recover)` for "Get Deleted Photos Back". Adjust pushes it at
// `.grouping`. It is content only (no glass) and works inside any NavigationStack.

/// "How Pickr. Finds Moments" (§3.3 S10, COPY.md, ADAPTIVE §4 S10), scrolled to an optional
/// anchor. The text column is at most 640 pt wide.
struct HowItWorksScreen: View {
    nonisolated enum Anchor: Hashable, Sendable {
        case grouping, recover
    }

    let anchor: Anchor?

    init(anchor: Anchor? = nil) {
        self.anchor = anchor
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large * 1.5) {
                    HowMomentsFormSection()
                        .id(Anchor.grouping)
                    SinglePhotosSection()
                    BiggerMomentsSection()
                    ShorterOrLongerSection()
                    LookBackHelpSection()
                    KeptHelpSection()
                    RecoverSection()
                        .id(Anchor.recover)
                    KeyboardAndPointerSection()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.medium)
                .readableWidth(ReadableWidth.text)
            }
            // After the first layout, so the anchor's position is known.
            .task(id: anchor) {
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
        }
        .navigationTitle(Text("How Pickr. Finds Moments", comment: "Title of the help page about how moments are found."))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sections

/// A titled block of help text. The title is a heading for VoiceOver's rotor.
private struct HelpSection<Content: View>: View {
    let title: Text
    let systemImage: String
    let content: Content

    init(_ title: Text, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
            }
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct HowMomentsFormSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(
                "Pickr. looks at your photos in the order you took them. When a photo was taken soon enough after the one before it, the two belong to the same moment.",
                comment: "Help: how photos become a moment."
            )
            TimelineExample(window: 60)
            TimelineExample(window: 600)
        }
    }
}

private struct SinglePhotosSection: View {
    var body: some View {
        HelpSection(
            Text("What about single photos?", comment: "Help heading: photos that aren't part of a moment."),
            systemImage: "photo"
        ) {
            Text(
                "A photo with no other photo close to it isn't part of any moment. It stays in your library, untouched.",
                comment: "Help: photos on their own."
            )
        }
    }
}

private struct BiggerMomentsSection: View {
    var body: some View {
        HelpSection(
            Text("Bigger moments", comment: "Help heading: how to make moments bigger."),
            systemImage: "slider.horizontal.3"
        ) {
            Text(
                "Tap **Adjust** on the Moments screen and pick a longer time under **Photos taken within** — 10 sec, 30 sec, 1 min, 3 min — or choose **Other…** for up to 2 hours.",
                comment: "Help: where to change the time between photos. Bold words are button and section names."
            )
        }
    }
}

private struct ShorterOrLongerSection: View {
    var body: some View {
        HelpSection(
            Text("Shorter or longer?", comment: "Help heading: choosing a shorter or longer time."),
            systemImage: "lightbulb"
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
                BulletText(Text("A shorter time finds more moments, with fewer photos in each", comment: "Help bullet: effect of a shorter time."))
                BulletText(Text("A longer time finds fewer moments, with more photos in each", comment: "Help bullet: effect of a longer time."))
            }
        }
    }
}

private struct LookBackHelpSection: View {
    var body: some View {
        HelpSection(
            Text("How far back", comment: "Help heading: how far back Pickr. looks for moments."),
            systemImage: "calendar"
        ) {
            Text(
                "Under **Look back** in **Adjust**, choose Week, 2 Weeks, Month or Everything, or **Pick Dates…** for any stretch of time. Looking back further can find many more moments.",
                comment: "Help: choosing how far back to look. Bold words are section and button names."
            )
        }
    }
}

private struct KeptHelpSection: View {
    var body: some View {
        HelpSection(
            Text("Moments you keep", comment: "Help heading: what happens to kept moments."),
            systemImage: "checkmark.circle"
        ) {
            Text(
                "Moments you keep show up in **Kept** and won't come back for cleanup. Tap **Show Again** there to put one back in Moments.",
                comment: "Help: kept moments. Bold words are the tab and button names."
            )
        }
    }
}

private struct RecoverSection: View {
    var body: some View {
        HelpSection(
            Text("Get deleted photos back", comment: "Help heading: recovering deleted photos."),
            systemImage: "arrow.uturn.backward"
        ) {
            Text(
                "Changed your mind? Open **Photos** → **Albums** → **Recently Deleted** and choose the photos you want back. iOS keeps them for **30 days**.",
                comment: "Help: how to recover deleted photos in the Photos app. Photos, Albums and Recently Deleted are the Photos app's own names."
            )
        }
    }
}

private struct BulletText: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            text
        }
    }
}

// MARK: - Worked examples

/// Six photos with fixed gaps between them, grouped with one time window: which ones form a
/// moment and which stay on their own.
private struct TimelineModel {
    /// Seconds between consecutive photos.
    static let gaps = [20, 40, 180, 30, 300]

    let window: Int
    /// Whether each gap is too long to join the photos on either side.
    let breaks: [Bool]
    /// Photos with no neighbour close enough.
    let solo: Set<Int>
    let moments: Int

    var photoCount: Int { Self.gaps.count + 1 }

    init(window: Int) {
        self.window = window
        breaks = Self.gaps.map { $0 > window }
        var groups: [[Int]] = [[0]]
        for (offset, isBreak) in breaks.enumerated() {
            if isBreak {
                groups.append([offset + 1])
            } else {
                groups[groups.count - 1].append(offset + 1)
            }
        }
        solo = Set(groups.filter { $0.count == 1 }.flatMap { $0 })
        moments = groups.count(where: { $0.count > 1 })
    }

    /// "20 sec", "3 min", in the user's locale.
    static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}

private struct TimelineExample: View {
    let model: TimelineModel

    init(window: Int) {
        model = TimelineModel(window: window)
    }

    var body: some View {
        let window = TimelineModel.duration(model.window)
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title(window)
                    Spacer(minLength: Theme.Spacing.small)
                    outcome
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
                    title(window)
                    outcome
                }
            }
            ViewThatFits(in: .horizontal) {
                TimelineDiagram(model: model)
                TimelineList(model: model)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Theme.Spacing.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(window))
    }

    private func title(_ window: String) -> some View {
        Text("Within \(window)", comment: "Help example title. The variable is a time, for example 1 min.")
            .font(.subheadline.bold())
    }

    private var outcome: some View {
        Group {
            if model.solo.isEmpty {
                Text("\(model.moments) moments", comment: "Help example result: number of moments.")
            } else {
                Text(
                    "\(model.moments) moments · \(model.solo.count) on its own",
                    comment: "Help example result. 1: number of moments. 2: number of photos left on their own."
                )
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func accessibilityText(_ window: String) -> Text {
        if model.solo.isEmpty {
            return Text(
                "Example, photos taken within \(window): \(model.moments) moments.",
                comment: "VoiceOver: help example. 1: a time, for example 1 min. 2: number of moments."
            )
        }
        return Text(
            "Example, photos taken within \(window): \(model.moments) moments, \(model.solo.count) photos on their own.",
            comment: "VoiceOver: help example. 1: a time, for example 1 min. 2: number of moments. 3: photos on their own."
        )
    }
}

/// Photos as squares joined by a solid line when close enough and a dashed one when not, with
/// each gap's length underneath.
private struct TimelineDiagram: View {
    let model: TimelineModel

    @ScaledMetric(relativeTo: .caption2) private var side: CGFloat = 16

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: Theme.Spacing.extraSmall) {
            GridRow {
                ForEach(0..<model.photoCount, id: \.self) { index in
                    PhotoMark(isOnItsOwn: model.solo.contains(index), side: side)
                    if index < TimelineModel.gaps.count {
                        GapLine(isBreak: model.breaks[index])
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            GridRow {
                ForEach(0..<model.photoCount, id: \.self) { index in
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    if index < TimelineModel.gaps.count {
                        Text(TimelineModel.duration(TimelineModel.gaps[index]))
                            .font(.caption2)
                            .fontWeight(model.breaks[index] ? .semibold : .regular)
                            .foregroundStyle(model.breaks[index] ? .primary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, Theme.Spacing.extraSmall)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct PhotoMark: View {
    let isOnItsOwn: Bool
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side / 4, style: .continuous)
            .fill(isOnItsOwn ? Color.secondary.opacity(0.4) : Color.accentColor)
            .frame(width: side, height: side)
    }
}

private struct GapLine: View {
    let isBreak: Bool

    var body: some View {
        HorizontalLine()
            .stroke(
                isBreak ? Color.secondary : Color.accentColor,
                style: StrokeStyle(lineWidth: isBreak ? 1.5 : 2, lineCap: .round, dash: isBreak ? [3, 3] : [])
            )
            .frame(height: 2)
    }
}

private nonisolated struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// The same example as sentences, for text sizes where the diagram doesn't fit.
private struct TimelineList: View {
    let model: TimelineModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
            ForEach(0..<TimelineModel.gaps.count, id: \.self) { index in
                let gap = TimelineModel.duration(TimelineModel.gaps[index])
                Label {
                    if model.breaks[index] {
                        Text("\(gap) later — too far apart", comment: "Help example, large text: the next photo was taken too long after. The variable is a time, for example 3 min.")
                    } else {
                        Text("\(gap) later — same moment", comment: "Help example, large text: the next photo joins the moment. The variable is a time, for example 20 sec.")
                    }
                } icon: {
                    Image(systemName: model.breaks[index] ? "scissors" : "link")
                        .foregroundStyle(model.breaks[index] ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .font(.footnote)
            }
        }
    }
}

// MARK: - Keyboard and pointer

/// One keyboard shortcut (ADAPTIVE §7): the keys as printed, as spoken, and what they do.
private struct KeyCommand: Identifiable {
    let id: Int
    let keys: LocalizedStringResource
    let spokenKeys: LocalizedStringResource
    let action: LocalizedStringResource

    static let all: [KeyCommand] = [
        KeyCommand(
            id: 1,
            keys: LocalizedStringResource("Space", comment: "Keyboard key name, as printed on the key."),
            spokenKeys: LocalizedStringResource("Space", comment: "Keyboard key name, as printed on the key."),
            action: LocalizedStringResource("Keep or unmark the photo", comment: "Help: what the Space key does.")
        ),
        KeyCommand(
            id: 2,
            keys: LocalizedStringResource("1 – 9", comment: "Keyboard keys 1 to 9, as printed."),
            spokenKeys: LocalizedStringResource("1 to 9", comment: "VoiceOver: keyboard keys 1 to 9."),
            action: LocalizedStringResource("Keep or unmark photos 1 to 9", comment: "Help: what the number keys do.")
        ),
        KeyCommand(
            id: 3,
            keys: "⌘⌫",
            spokenKeys: LocalizedStringResource("Command Delete", comment: "VoiceOver: the keyboard shortcut Command-Delete."),
            action: LocalizedStringResource("Delete the photos you didn't keep", comment: "Help: what Command-Delete does.")
        ),
        KeyCommand(
            id: 4,
            keys: "⌘K",
            spokenKeys: LocalizedStringResource("Command K", comment: "VoiceOver: the keyboard shortcut Command-K."),
            action: LocalizedStringResource("Keep All", comment: "Help: what Command-K does (the Keep All button).")
        ),
        KeyCommand(
            id: 5,
            keys: "⌘↓",
            spokenKeys: LocalizedStringResource("Command Down Arrow", comment: "VoiceOver: the keyboard shortcut Command-Down Arrow."),
            action: LocalizedStringResource("Skip", comment: "Help: what Command-Down Arrow does (the Skip button).")
        ),
        KeyCommand(
            id: 6,
            keys: "⌘↑",
            spokenKeys: LocalizedStringResource("Command Up Arrow", comment: "VoiceOver: the keyboard shortcut Command-Up Arrow."),
            action: LocalizedStringResource("Previous Moment", comment: "Help: what Command-Up Arrow does.")
        ),
        KeyCommand(
            id: 7,
            keys: "← →",
            spokenKeys: LocalizedStringResource("Left and Right Arrows", comment: "VoiceOver: the left and right arrow keys."),
            action: LocalizedStringResource("Previous or next photo", comment: "Help: what the left and right arrow keys do.")
        ),
        KeyCommand(
            id: 8,
            keys: LocalizedStringResource("Return", comment: "Keyboard key name, as printed on the key."),
            spokenKeys: LocalizedStringResource("Return", comment: "Keyboard key name, as printed on the key."),
            action: LocalizedStringResource("Open One by One", comment: "Help: what the Return key does.")
        ),
        KeyCommand(
            id: 9,
            keys: LocalizedStringResource("Esc", comment: "Keyboard key name for Escape, as printed on the key."),
            spokenKeys: LocalizedStringResource("Escape", comment: "VoiceOver: the Escape key."),
            action: LocalizedStringResource("Go back", comment: "Help: what the Escape key does.")
        ),
        KeyCommand(
            id: 13,
            keys: "⌘1  ⌘2",
            spokenKeys: LocalizedStringResource("Command 1, Command 2", comment: "VoiceOver: the keyboard shortcuts Command-1 and Command-2."),
            action: LocalizedStringResource("All or One by One", comment: "Help: what Command-1 and Command-2 do.")
        ),
        KeyCommand(
            id: 14,
            keys: "⌥⌘1  ⌥⌘2",
            spokenKeys: LocalizedStringResource("Option Command 1, Option Command 2", comment: "VoiceOver: the keyboard shortcuts Option-Command-1 and Option-Command-2."),
            action: LocalizedStringResource("Moments or Kept", comment: "Help: what Option-Command-1 and Option-Command-2 do (the two tabs).")
        ),
        KeyCommand(
            id: 15,
            keys: "⌘Z",
            spokenKeys: LocalizedStringResource("Command Z", comment: "VoiceOver: the keyboard shortcut Command-Z."),
            action: LocalizedStringResource("Undo", comment: "Help: what Command-Z does.")
        ),
        KeyCommand(
            id: 16,
            keys: "⌥⌘A",
            spokenKeys: LocalizedStringResource("Option Command A", comment: "VoiceOver: the keyboard shortcut Option-Command-A."),
            action: LocalizedStringResource("Adjust…", comment: "Help: what Option-Command-A does (opens Adjust).")
        ),
        KeyCommand(
            id: 17,
            keys: "⌘,",
            spokenKeys: LocalizedStringResource("Command Comma", comment: "VoiceOver: the keyboard shortcut Command-Comma."),
            action: LocalizedStringResource("Settings…", comment: "Help: what Command-Comma does (opens Settings).")
        ),
        KeyCommand(
            id: 18,
            keys: "⌘R",
            spokenKeys: LocalizedStringResource("Command R", comment: "VoiceOver: the keyboard shortcut Command-R."),
            action: LocalizedStringResource("Refresh", comment: "Help: what Command-R does.")
        ),
    ]
}

private struct KeyboardAndPointerSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HelpSection(
            Text("Keyboard and pointer", comment: "Help heading: keyboard shortcuts and trackpad or mouse use."),
            systemImage: "keyboard"
        ) {
            Text(
                "In All, drag sideways across photos to keep or unmark several at once. With a trackpad or mouse, point at a photo and click the circle to keep it, or secondary-click a moment or photo for more choices.",
                comment: "Help: drag across photos, and pointer use."
            )
            Text("With a keyboard:", comment: "Help: introduces the list of keyboard shortcuts.")
                .padding(.top, Theme.Spacing.extraSmall)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    ForEach(KeyCommand.all) { command in
                        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
                            KeyCaps(command: command)
                            Text(command.action)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.medium, verticalSpacing: Theme.Spacing.small) {
                    ForEach(KeyCommand.all) { command in
                        GridRow {
                            KeyCaps(command: command)
                            Text(command.action)
                        }
                    }
                }
            }
        }
    }
}

/// Keys drawn as solid key caps (content, never glass), read out by name.
private struct KeyCaps: View {
    let command: KeyCommand

    var body: some View {
        Text(command.keys)
            .font(.callout.monospaced())
            .padding(.horizontal, Theme.Spacing.small - 2)
            .padding(.vertical, 2)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(Text(command.spokenKeys))
    }
}

#if DEBUG
#Preview("How Pickr. Finds Moments") {
    NavigationStack {
        HowItWorksScreen()
    }
}

#Preview("Get deleted photos back") {
    NavigationStack {
        HowItWorksScreen(anchor: .recover)
    }
}

#Preview("Large text, dark") {
    NavigationStack {
        HowItWorksScreen(anchor: .grouping)
    }
    .environment(\.dynamicTypeSize, .accessibility3)
    .preferredColorScheme(.dark)
}
#endif
