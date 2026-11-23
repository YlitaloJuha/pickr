import Foundation
import PickrCore

/// The words Review shows (audit/COPY.md), built from plain values so they stay testable.
nonisolated enum ReviewLabels {
    /// All: "5 photos · 12 sec · 2 of 7" (the moment's count, its length, its place in the queue).
    static func gridSubtitle(photoCount: Int, start: Date, end: Date, position: Int, total: Int) -> String {
        joined([
            String(localized: "\(photoCount) photos", comment: "Review subtitle in All: the number of photos in the moment."),
            PickrFormat.duration(start, end),
            String(
                localized: "\(position) of \(total)",
                comment: "Review subtitle: the moment's place in the queue. 1: position, 2: number of moments."
            ),
        ])
    }

    /// One by One: "13:25:08 · 4.2 MB · 2 of 5"; the size is left out while it is unknown.
    static func singleSubtitle(captured: Date, bytes: Int64?, index: Int, count: Int) -> String {
        var parts = [captured.formatted(date: .omitted, time: .standard)]
        if let bytes, bytes > 0 {
            parts.append(PickrFormat.bytes(bytes))
        }
        parts.append(String(
            localized: "\(index + 1) of \(count)",
            comment: "Review subtitle in One by One: the photo's place in the moment. 1: position, 2: number of photos."
        ))
        return joined(parts)
    }

    /// "Frees up 6.8 MB", "Frees up about 6.8 MB" while some sizes are unknown, or `nil` for
    /// nothing known.
    static func freesUp(_ estimate: ByteEstimate) -> String? {
        guard estimate.bytes > 0 else { return nil }
        let bytes = PickrFormat.bytes(estimate.bytes)
        return estimate.isApproximate
            ? String(localized: "Frees up about \(bytes)", comment: "Second line of the Delete button when some sizes are unknown. 1: a size.")
            : String(localized: "Frees up \(bytes)", comment: "Second line of the Delete button. 1: a size, for example 6.8 MB.")
    }

    /// VoiceOver for the Delete button: "Delete 4 photos, frees up 6.8 MB".
    static func deleteAccessibilityLabel(count: Int, freed: ByteEstimate) -> String {
        guard freed.bytes > 0 else {
            return String(localized: "Delete \(count) photos", comment: "VoiceOver label of Review's Delete button. 1: number of photos.")
        }
        let bytes = PickrFormat.bytes(freed.bytes)
        return freed.isApproximate
            ? String(
                localized: "Delete \(count) photos, frees up about \(bytes)",
                comment: "VoiceOver label of Review's Delete button when some sizes are unknown. 1: number of photos, 2: a size."
            )
            : String(
                localized: "Delete \(count) photos, frees up \(bytes)",
                comment: "VoiceOver label of Review's Delete button. 1: number of photos, 2: a size."
            )
    }

    static func joined(_ parts: [String]) -> String {
        parts.joined(separator: String(localized: " · ", comment: "Separator between the parts of a subtitle."))
    }
}
