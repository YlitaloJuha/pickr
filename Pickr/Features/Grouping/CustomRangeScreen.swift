import Accessibility
import Charts
import PickrCore
import PickrModels
import SwiftUI

/// Pick Dates (§3.3 S7, COPY.md): a chart of photos per month (per year for libraries spanning
/// 3 years or more) from the in-memory index, with First day and Last day kept in sync with a
/// drag across it.
///
/// Nothing is stored until the confirm button: it saves the first day from 00:00:00 to the last
/// day at 23:59:59, local time, chooses Pick Dates under Look back, and goes back. Back cancels
/// and leaves Adjust as it was. Pushed from Adjust's "Pick Dates…" and its saved-dates row.
struct CustomRangeScreen: View {
    @Environment(LibraryModel.self) private var library
    @Environment(SettingsModel.self) private var settings
    @Environment(\.calendar) private var calendar
    @State private var buckets: [DensityBucket]?

    var body: some View {
        let index = library.index
        let bounds = PickDatesBounds(index: index, now: .now, calendar: calendar)
        PickDatesForm(
            bounds: bounds,
            initial: bounds.initialSpan(saved: settings.grouping.range.custom, calendar: calendar),
            buckets: buckets,
            hasPhotos: !index.isEmpty
        )
        .task(id: IndexSignature(index: index, calendar: calendar)) {
            buckets = await Self.buckets(for: index, calendar: calendar)
        }
    }

    /// O(library): off the main actor.
    @concurrent nonisolated private static func buckets(for index: [AssetRecord], calendar: Calendar) async -> [DensityBucket] {
        DensityHistogram.buckets(dates: index.map(\.created), calendar: calendar)
    }
}

/// What the chart depends on, cheap to compare: the index is ascending, so its count and ends
/// change whenever it does in a way the chart can show.
private struct IndexSignature: Hashable {
    var count: Int
    var first: Date?
    var last: Date?
    var calendar: Calendar

    init(index: [AssetRecord], calendar: Calendar) {
        count = index.count
        first = index.first?.created
        last = index.last?.created
        self.calendar = calendar
    }
}

/// The first and last day picked, each the start of its day.
private struct PickDatesSpan: Hashable {
    var first: Date
    var last: Date

    func contains(_ bucket: DensityBucket) -> Bool {
        bucket.end > first && bucket.start <= last
    }
}

/// The days the pickers allow: from the first photo's day to today (or the last photo's day,
/// if a camera clock ran ahead).
private struct PickDatesBounds: Hashable {
    let lower: Date
    let upper: Date

    init(index: [AssetRecord], now: Date, calendar: Calendar) {
        let today = calendar.startOfDay(for: now)
        let upper = max(index.last.map { calendar.startOfDay(for: $0.created) } ?? today, today)
        let fallbackLower = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        self.upper = upper
        lower = min(index.first.map { calendar.startOfDay(for: $0.created) } ?? fallbackLower, upper)
    }

    func clamp(_ day: Date) -> Date {
        min(max(day, lower), upper)
    }

    func clamp(_ span: PickDatesSpan) -> PickDatesSpan {
        let first = clamp(span.first)
        let last = clamp(span.last)
        return PickDatesSpan(first: min(first, last), last: max(first, last))
    }

    /// The saved dates, or the month of the last day and the two before it.
    func initialSpan(saved: CustomRange?, calendar: Calendar) -> PickDatesSpan {
        if let saved {
            return clamp(PickDatesSpan(first: calendar.startOfDay(for: saved.start), last: calendar.startOfDay(for: saved.end)))
        }
        let monthStart = calendar.dateInterval(of: .month, for: upper)?.start ?? upper
        let first = calendar.date(byAdding: .month, value: -2, to: monthStart) ?? monthStart
        return clamp(PickDatesSpan(first: first, last: upper))
    }
}

private struct PickDatesForm: View {
    let bounds: PickDatesBounds
    let buckets: [DensityBucket]?
    let hasPhotos: Bool

    @State private var span: PickDatesSpan
    @Environment(SettingsModel.self) private var settings
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss

    init(bounds: PickDatesBounds, initial: PickDatesSpan, buckets: [DensityBucket]?, hasPhotos: Bool) {
        self.bounds = bounds
        self.buckets = buckets
        self.hasPhotos = hasPhotos
        self.span = initial
    }

    var body: some View {
        // The library can change while this is open; the pickers' ranges must stay valid.
        let shown = bounds.clamp(span)
        Form {
            Section {
                if let buckets, !buckets.isEmpty {
                    DensityChart(buckets: buckets, bounds: bounds, span: $span)
                } else {
                    ChartPlaceholder(isLoading: hasPhotos && buckets == nil)
                }
            } footer: {
                Text("Drag across the chart, or set the first and last day.", comment: "Pick Dates: footer under the chart.")
            }
            Section {
                DatePicker(selection: $span.first, in: bounds.lower...shown.last, displayedComponents: .date) {
                    Text("First day", comment: "Pick Dates: the first day to look for moments.")
                }
                DatePicker(selection: $span.last, in: shown.first...bounds.upper, displayedComponents: .date) {
                    Text("Last day", comment: "Pick Dates: the last day to look for moments.")
                }
            }
            PickDatesCount(span: shown)
        }
        .datePickerStyle(.compact)
        .navigationTitle(Text("Pick Dates", comment: "Title of the screen that picks a first and last day."))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(role: .confirm) {
                    apply(shown)
                } label: {
                    Label {
                        Text("Use These Dates", comment: "Pick Dates: confirm button that looks for moments between the picked days.")
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private func apply(_ span: PickDatesSpan) {
        let start = calendar.startOfDay(for: span.first)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: span.last) ?? span.last
        settings.grouping.range = ScanRange(preset: .custom, custom: CustomRange(start, end))
        dismiss()
    }
}

private struct ChartPlaceholder: View {
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text("No photos yet.", comment: "Pick Dates: shown instead of the chart when the library has no photos.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 88)
    }
}

/// "1,234 photos on these dates", an exact count from the index (O(log n)).
private struct PickDatesCount: View {
    let span: PickDatesSpan

    @Environment(LibraryModel.self) private var library
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: span.last) ?? span.last
        let count = library.photoCount(in: ScanRange(preset: .custom, custom: CustomRange(span.first, end)))
        let days = calendar.dateComponents([.day], from: span.first, to: span.last).day ?? 0
        Section {
            Text("\(count) photos on these dates", comment: "Pick Dates: number of photos between the first and last day.")
                .font(.headline)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy, value: count)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        } footer: {
            if days >= 365 {
                Text("A long stretch of time can find many moments.", comment: "Pick Dates: footer when the picked days span more than a year.")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Photos per month or year. A drag (or a tap) selects whole bars and sets First day and Last
/// day; the pickers are the accessible path, and their days colour the bars in turn.
private struct DensityChart: View {
    let buckets: [DensityBucket]
    let bounds: PickDatesBounds
    @Binding var span: PickDatesSpan

    @State private var dragRange: ClosedRange<Date>?
    @Environment(\.calendar) private var calendar
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 160

    var body: some View {
        let isYearly = Self.isYearly(buckets, calendar: calendar)
        let outside = Color.secondary.opacity(contrast == .increased ? 0.5 : 0.25)
        Chart(buckets) { bucket in
            BarMark(
                x: .value(Text("Date", comment: "Pick Dates chart: the time axis."), bucket.start, unit: isYearly ? .year : .month, calendar: calendar),
                y: .value(Text("Photos", comment: "Pick Dates chart: the photo count axis."), bucket.count)
            )
            .foregroundStyle(span.contains(bucket) ? Color.accentColor : outside)
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: isYearly ? .dateTime.year() : .dateTime.month(.abbreviated).year())
            }
        }
        .chartXSelection(range: $dragRange)
        .chartGesture { proxy in
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    proxy.selectXRange(from: value.startLocation.x, to: value.location.x)
                }
                .onEnded { _ in
                    dragRange = nil
                }
        }
        .onChange(of: dragRange) { _, range in
            guard let range else { return }
            let snapped = Self.snap(range, buckets: buckets, bounds: bounds, calendar: calendar)
            if snapped != span { span = snapped }
        }
        .hapticFeedback(.groupingChanged, trigger: span)
        .frame(height: height)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityChartDescriptor(DensityChartDescriptor(buckets: buckets, isYearly: isYearly))
        .accessibilityHint(Text("Set First day and Last day to change the dates.", comment: "VoiceOver hint on the Pick Dates chart."))
    }

    private static func isYearly(_ buckets: [DensityBucket], calendar: Calendar) -> Bool {
        guard let bucket = buckets.first else { return false }
        return (calendar.dateComponents([.month], from: bucket.start, to: bucket.end).month ?? 1) >= 12
    }

    /// Whole bars: from the first day of the bar under one end to the last day of the bar under
    /// the other, inside the allowed days.
    private static func snap(
        _ range: ClosedRange<Date>,
        buckets: [DensityBucket],
        bounds: PickDatesBounds,
        calendar: Calendar
    ) -> PickDatesSpan {
        func bucket(at date: Date) -> DensityBucket? {
            buckets.last { $0.start <= date } ?? buckets.first
        }
        guard let lower = bucket(at: range.lowerBound), let upper = bucket(at: range.upperBound) else {
            return bounds.clamp(PickDatesSpan(first: range.lowerBound, last: range.upperBound))
        }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: upper.end) ?? upper.start
        return bounds.clamp(PickDatesSpan(
            first: calendar.startOfDay(for: lower.start),
            last: calendar.startOfDay(for: lastDay)
        ))
    }
}

/// The chart for VoiceOver's audio graph and data table.
private nonisolated struct DensityChartDescriptor: AXChartDescriptorRepresentable {
    let buckets: [DensityBucket]
    let isYearly: Bool

    func makeChartDescriptor() -> AXChartDescriptor {
        let style: Date.FormatStyle = isYearly ? .dateTime.year() : .dateTime.month(.wide).year()
        let names = buckets.map { $0.start.formatted(style) }
        let highest = Double(buckets.map(\.count).max() ?? 0)
        let xAxis = AXCategoricalDataAxisDescriptor(
            title: isYearly
                ? String(localized: "Year", comment: "VoiceOver chart axis: years.")
                : String(localized: "Month", comment: "VoiceOver chart axis: months."),
            categoryOrder: names
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Photos", comment: "Pick Dates chart: the photo count axis."),
            range: 0...max(highest, 1),
            gridlinePositions: []
        ) { value in
            String(localized: "\(Int(value)) photos", comment: "VoiceOver chart value: a number of photos.")
        }
        let points = zip(names, buckets).map { name, bucket in
            AXDataPoint(x: name, y: Double(bucket.count))
        }
        return AXChartDescriptor(
            title: isYearly
                ? String(localized: "Photos per year", comment: "VoiceOver title of the Pick Dates chart with yearly bars.")
                : String(localized: "Photos per month", comment: "VoiceOver title of the Pick Dates chart with monthly bars."),
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            series: [AXDataSeriesDescriptor(
                name: String(localized: "Photos", comment: "Pick Dates chart: the photo count axis."),
                isContinuous: false,
                dataPoints: points
            )]
        )
    }
}

#if DEBUG
#Preview("Pick Dates") {
    let services = AdjustPreview.services()
    NavigationStack {
        CustomRangeScreen()
    }
    .adjustPreviewEnvironment(services)
}

#Preview("Pick Dates, saved dates, dark") {
    let services = AdjustPreview.services { settings in
        settings.grouping.range = AdjustPreview.savedDates
    }
    NavigationStack {
        CustomRangeScreen()
    }
    .adjustPreviewEnvironment(services)
    .preferredColorScheme(.dark)
}

#Preview("Pick Dates, empty library") {
    let services = AdjustPreview.services(library: .empty)
    NavigationStack {
        CustomRangeScreen()
    }
    .adjustPreviewEnvironment(services)
}
#endif
