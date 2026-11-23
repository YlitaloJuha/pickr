import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Presents the system limited-library picker from a zero-size anchor view controller
/// (blueprint §4.6, C11). The 27.2 SDK has no SwiftUI modifier for it [ARCH B6].
///
/// Call-site contract (WP7): place it as a zero-size background of the Moments screen,
/// set `isPresented` to `true` from the "Manage" button, and refresh the library in
/// `onCompletion`. The binding returns to `false` when the picker closes.
///
/// The picker only opens while access is `.limited` and the anchor is on screen; otherwise
/// the request completes at once. Selection changes also reach the library through
/// `LibraryChangeObserver`.
struct LimitedLibraryPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onCompletion: () -> Void

    init(isPresented: Binding<Bool>, onCompletion: @escaping () -> Void) {
        _isPresented = isPresented
        self.onCompletion = onCompletion
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false
        // An invisible presentation anchor, not a control.
        anchor.view.isAccessibilityElement = false
        anchor.view.accessibilityElementsHidden = true
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCompletion = onCompletion
        guard isPresented, coordinator.presentation == nil else { return }
        let isPresented = $isPresented
        #if DEBUG
        // Demo mode has full access to its own photos; PhotoKit is never asked.
        if DemoMode.isActive {
            Task { @MainActor in isPresented.wrappedValue = false }
            return
        }
        #endif
        // Presents after the current view update, never during it.
        coordinator.presentation = Task { @MainActor in
            let presenter = Self.topmostController(from: anchor)
            let canPresent = presenter.viewIfLoaded?.window != nil
                && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
            if canPresent {
                _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
            }
            coordinator.presentation = nil
            isPresented.wrappedValue = false
            coordinator.onCompletion()
        }
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.onCompletion = {}
    }

    /// The controller currently shown on top of `anchor`, so the picker can open even while
    /// something else is presented.
    private static func topmostController(from anchor: UIViewController) -> UIViewController {
        var presenter = anchor
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        return presenter
    }

    final class Coordinator {
        /// The running presentation; a second request while it runs is ignored.
        var presentation: Task<Void, Never>?
        var onCompletion: () -> Void = {}
    }
}
