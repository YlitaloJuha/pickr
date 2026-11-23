import PickrCore
import PickrModels
import SwiftUI

/// A moment as a solid card (§3.3 S3), keeping the v1 identity:
///
/// - line 1: the time span, "13:25:04 – 13:25:16" (seconds when the span is under 60 s);
/// - line 2: "5 photos · 4.2 MB to free up", with a heart when the moment has protected photos;
/// - a strip of 48 pt thumbnails, 6 pt apart, with as many slots as fit the card's own
///   width, 3–6 (ADAPTIVE.md §6.3: a 340 pt sidebar fits 5, an iPhone 6); at most 4 at
///   accessibility text sizes. With more photos than slots the last slot is "+N".
///
/// The card is one accessibility element with the button trait, labelled "April 18, 13:25
/// to 13:31, 5 photos, about 4.2 MB to free up". Pointer hover highlights the card's rounded
/// shape (ADAPTIVE.md §8). Callers add the tap action, the hint ("Opens review"), swipe
/// actions, the context menu and the zoom source (`matchedTransitionSource(id: moment.id,
/// in:)`), and wrap the row with `cardRow()`.
struct MomentCard: View {
    let moment: Moment
    /// `nil` hides the "to free up" part (Kept).
    let savings: ByteEstimate?
    /// Puts the date in line 1 for lists without day sections (Kept).
    let showsDate: Bool

    @Environment(SettingsModel.self) private var settings: SettingsModel?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(moment: Moment, savings: ByteEstimate? = nil, showsDate: Bool = false) {
        self.moment = moment
        self.savings = savings
        self.showsDate = showsDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
                title
                    .font(.headline)
                    .monospacedDigit()
                details
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ThumbnailStrip(
                photos: moment.photoIDs,
                maximumSlots: dynamicTypeSize.isAccessibilitySize
                    ? Theme.Size.stripMaximumTilesAccessibility
                    : Theme.Size.stripMaximumTiles
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .contentShape(Theme.Shapes.card)
        .contentShape(.contextMenuPreview, Theme.Shapes.card)
        .contentShape(.hoverEffect, Theme.Shapes.card)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MomentAccessibility.label(for: moment, savings: savings, showsProtection: showsProtection))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Lines

    private var title: Text {
        let span = PickrFormat.timeSpan(moment.start, moment.end)
        guard showsDate else { return Text(span) }
        let date = moment.start.formatted(.dateTime.month(.abbreviated).day().year())
        return Text(
            "\(date) · \(span)",
            comment: "Moment card title in Kept. 1: the date, for example Apr 18, 2026. 2: the time span."
        )
    }

    private var details: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.extraSmall) {
            countAndSavings
            if showsProtection {
                Image(systemName: "heart.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
        }
    }

    private var countAndSavings: Text {
        let count = moment.count
        guard let savings, savings.bytes > 0 else {
            return Text("\(count) photos", comment: "Moment card: number of photos in the moment.")
        }
        let bytes = PickrFormat.bytes(savings.bytes)
        if savings.isApproximate {
            return Text(
                "\(count) photos · about \(bytes) to free up",
                comment: "Moment card. 1: number of photos. 2: estimated space, for example 4.2 MB, when some sizes are unknown."
            )
        }
        return Text(
            "\(count) photos · \(bytes) to free up",
            comment: "Moment card. 1: number of photos. 2: space freed by keeping only the largest photo, for example 4.2 MB."
        )
    }

    /// The heart appears while "Protect favorites" is on (§2.5); without a settings model
    /// (previews) it follows the default, on.
    private var showsProtection: Bool {
        (settings?.protectFavorites ?? true) && moment.photos.contains(where: \.isProtected)
    }
}

// MARK: - Thumbnail strip

/// As many 48 pt thumbnails as fit the strip's own width (3–6, never more than
/// `maximumSlots`); with more photos than slots the last slot becomes "+N".
private struct ThumbnailStrip: View {
    let photos: [PhotoID]
    let maximumSlots: Int

    /// Slots that fit the measured width; the minimum until the first measurement.
    @State private var fittingSlots = StripLayout.minimumSlots

    var body: some View {
        let slots = min(fittingSlots, maximumSlots)
        let overflows = photos.count > slots
        let shown = overflows ? slots - 1 : photos.count
        HStack(spacing: Theme.Size.stripSpacing) {
            ForEach(photos.prefix(shown), id: \.self) { id in
                ThumbnailView(id: id, size: .card)
                    .frame(width: Theme.Size.stripThumbnail, height: Theme.Size.stripThumbnail)
                    .clipShape(Theme.Shapes.thumbnail)
            }
            if overflows {
                OverflowTile(count: photos.count - shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { proxy in
            StripLayout.slots(forWidth: proxy.size.width)
        } action: { newSlots in
            fittingSlots = newSlots
        }
    }
}

/// How many strip slots fit a width (ADAPTIVE.md §6.3).
nonisolated enum StripLayout {
    static let minimumSlots = 3

    /// `min(6, max(3, Int((width + 6) / 54)))` for 48 pt tiles 6 pt apart.
    static func slots(forWidth width: CGFloat) -> Int {
        let step = Theme.Size.stripThumbnail + Theme.Size.stripSpacing
        guard width.isFinite, width > 0 else { return minimumSlots }
        return min(Theme.Size.stripMaximumTiles, max(minimumSlots, Int((width + Theme.Size.stripSpacing) / step)))
    }
}

/// The "+N" tile for photos the strip doesn't show.
private struct OverflowTile: View {
    let count: Int

    var body: some View {
        Theme.Palette.overflow
            .frame(width: Theme.Size.stripThumbnail, height: Theme.Size.stripThumbnail)
            .overlay {
                Text("+\(count)", comment: "Moment card: the number of photos not shown in the thumbnail strip.")
                    .font(.caption.bold())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(Theme.Spacing.extraSmall)
            }
            .clipShape(Theme.Shapes.thumbnail)
            .accessibilityHidden(true)
    }
}

// MARK: - Context-menu preview

/// The long-press preview of a moment (§3.3 S3): up to nine thumbnails in a grid of at most
/// three columns, at the `tile` size class.
struct MomentPreview: View {
    let moment: Moment

    private static let side: CGFloat = 104
    private static let spacing: CGFloat = 2

    var body: some View {
        let ids = Array(moment.photoIDs.prefix(9))
        let columns = Self.columnCount(for: ids.count)
        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
            ForEach(Array(stride(from: 0, to: ids.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(ids[start..<min(start + columns, ids.count)], id: \.self) { id in
                        ThumbnailView(id: id, size: .tile)
                            .frame(width: Self.side, height: Self.side)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MomentAccessibility.label(for: moment, savings: nil, showsProtection: false))
    }

    /// One column for one photo, two for two or four, otherwise three.
    private static func columnCount(for count: Int) -> Int {
        switch count {
        case ...1: 1
        case 2, 4: 2
        default: 3
        }
    }
}

// MARK: - Accessibility

/// What VoiceOver says about a moment card (§3.3 S3 accessibility).
enum MomentAccessibility {
    /// "April 18, 13:25 to 13:31, 5 photos, about 4.2 MB to free up". The year is added for
    /// moments outside the current year; seconds when the span is under a minute.
    static func label(for moment: Moment, savings: ByteEstimate?, showsProtection: Bool, now: Date = .now) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let sameYear = calendar.isDate(moment.start, equalTo: now, toGranularity: .year)
        let day = sameYear
            ? moment.start.formatted(.dateTime.month(.wide).day())
            : moment.start.formatted(.dateTime.month(.wide).day().year())

        let timeStyle: Date.FormatStyle.TimeStyle = moment.end.timeIntervalSince(moment.start) < 60 ? .standard : .shortened
        let start = moment.start.formatted(date: .omitted, time: timeStyle)
        let end = moment.end.formatted(date: .omitted, time: timeStyle)
        let time = start == end
            ? start
            : String(localized: "\(start) to \(end)", comment: "VoiceOver: a moment's time span. 1: first photo's time. 2: last photo's time.")

        var parts = [
            day,
            time,
            String(localized: "\(moment.count) photos", comment: "VoiceOver: number of photos in a moment."),
        ]
        if let savings, savings.bytes > 0 {
            let bytes = PickrFormat.bytes(savings.bytes)
            parts.append(
                savings.isApproximate
                    ? String(localized: "about \(bytes) to free up", comment: "VoiceOver: estimated space to free up, for example 4.2 MB.")
                    : String(localized: "\(bytes) to free up", comment: "VoiceOver: space to free up, for example 4.2 MB.")
            )
        }
        if showsProtection {
            parts.append(String(localized: "includes favorites", comment: "VoiceOver: the moment has protected (favorite or rated) photos."))
        }
        return PhotoAccessibility.joined(parts)
    }
}

#if DEBUG
#Preview("Moment cards") {
    let records = PreviewPhotos.records(count: 9)
    List {
        MomentCard(
            moment: Moment(photos: records),
            savings: ByteEstimate(bytes: 4_200_000, isApproximate: true)
        )
        .cardRow()
        MomentCard(
            moment: Moment(photos: Array(records.prefix(2))),
            savings: ByteEstimate(bytes: 1_800_000, isApproximate: false)
        )
        .cardRow()
        MomentCard(moment: Moment(photos: Array(records.suffix(4))), showsDate: true)
            .cardRow()
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Theme.Palette.screen)
    .environment(\.imageLoader, SwatchImageLoader())
}

#Preview("Strip widths") {
    let moment = Moment(photos: PreviewPhotos.records(count: 9))
    // A 340 pt sidebar fits 5 slots (4 photos and "+5"); an iPhone-wide card fits 6.
    VStack(spacing: Theme.Spacing.large) {
        ForEach([280, 340, 402], id: \.self) { width in
            MomentCard(moment: moment)
                .padding(.horizontal, Theme.Spacing.large)
                .frame(width: CGFloat(width))
        }
    }
    .padding(.vertical)
    .background(Theme.Palette.screen)
    .environment(\.imageLoader, SwatchImageLoader())
}
#endif
