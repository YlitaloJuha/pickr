import PickrCore
import SwiftUI

/// The Moments tab's count and size lines (COPY.md), shared by the navigation subtitle, the
/// bottom accessory and the split's start view. Sizes are the keep-one estimate ("to free
/// up"); unknown sizes make them "about …", and with no known size the size is left out.
enum MomentsLabels {
    /// "7 moments · 32 MB to free up".
    static func summary(_ list: MomentList) -> Text {
        let count = list.moments.count
        guard list.savings.bytes > 0 else {
            return Text("\(count) moments", comment: "Moments subtitle when no size is known yet. 1: number of moments.")
        }
        let bytes = PickrFormat.bytes(list.savings.bytes)
        if list.savings.isApproximate {
            return Text(
                "\(count) moments · about \(bytes) to free up",
                comment: "Moments subtitle. 1: number of moments. 2: estimated space, for example 32 MB, when some sizes are unknown."
            )
        }
        return Text(
            "\(count) moments · \(bytes) to free up",
            comment: "Moments subtitle. 1: number of moments. 2: space freed by keeping one photo per moment, for example 32 MB."
        )
    }

    /// "Clean Up 7 Moments".
    static func cleanUp(_ count: Int) -> Text {
        Text("Clean Up \(count) Moments", comment: "Button that starts going through the moments. 1: number of moments.")
    }

    /// "Clean Up 7", when the full title doesn't fit.
    static func cleanUpShort(_ count: Int) -> Text {
        Text("Clean Up \(count)", comment: "Short form of Clean Up 7 Moments when space is tight. 1: number of moments.")
    }

    /// "Frees up to 32 MB", or `nil` while no size is known.
    static func freesUpTo(_ savings: ByteEstimate) -> Text? {
        guard savings.bytes > 0 else { return nil }
        let bytes = PickrFormat.bytes(savings.bytes)
        if savings.isApproximate {
            return Text(
                "Frees up to about \(bytes)",
                comment: "Under Clean Up 7 Moments, when some sizes are unknown. 1: estimated space, for example 32 MB."
            )
        }
        return Text(
            "Frees up to \(bytes)",
            comment: "Under Clean Up 7 Moments. 1: space freed by keeping one photo per moment, for example 32 MB."
        )
    }
}
