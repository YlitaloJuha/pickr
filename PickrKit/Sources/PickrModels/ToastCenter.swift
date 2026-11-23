import Foundation
import Observation

/// The one toast on screen, with optional Undo or Try Again (§3.3 S5, §3.4).
///
/// `Curator`, `ReviewSession` and `Router` post toasts; `ToastHost` shows `current`. A new
/// toast replaces the one on screen, and with it that toast's Undo or Try Again. A toast
/// dismisses itself after `displayDuration`.
///
/// Every error toast carries a Try Again action, so `isError` also means "offer Try Again".
@Observable public final class ToastCenter {
    public nonisolated struct Toast: Identifiable, Equatable {
        public let id: UUID
        public let message: String
        public let canUndo: Bool
        public let isError: Bool

        public init(id: UUID = UUID(), message: String, canUndo: Bool, isError: Bool) {
            self.id = id
            self.message = message
            self.canUndo = canUndo
            self.isError = isError
        }
    }

    /// What a toast's button runs: Undo for a reversible change, Try Again for a failure.
    public typealias Action = @MainActor () async -> Void

    public private(set) var current: Toast?

    /// How long a toast stays before it dismisses itself: 5 s (§3.3 S5). This is the only
    /// dismissal timer; `ToastHost` lengthens it while VoiceOver runs so Undo can be
    /// reached. A change applies from the next toast on.
    @ObservationIgnored public var displayDuration: Duration = .seconds(5)

    @ObservationIgnored private var action: Action?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init() {}

    isolated deinit {
        expiry?.cancel()
    }

    /// Shows a confirmation, with Undo when `undo` is given.
    public func show(_ message: String, undo: Action? = nil) {
        present(Toast(message: message, canUndo: undo != nil, isError: false), action: undo)
    }

    /// Shows a failure with a Try Again action that runs `retry`.
    public func showError(_ message: String, retry: @escaping Action) {
        present(Toast(message: message, canUndo: false, isError: true), action: retry)
    }

    /// Dismisses the toast and runs its Undo. Does nothing if the toast has no Undo.
    public func performUndo() async {
        guard let current, current.canUndo, let action else { return }
        dismiss()
        await action()
    }

    /// Dismisses the toast and runs its Try Again. Does nothing if the toast isn't an error.
    public func performRetry() async {
        guard let current, current.isError, let action else { return }
        dismiss()
        await action()
    }

    /// Dismisses the toast on screen, if any. Its Undo or Try Again goes with it.
    public func dismiss() {
        expiry?.cancel()
        expiry = nil
        action = nil
        if current != nil { current = nil }
    }

    /// Dismisses the toast `id` only if it is still the one on screen, so a late timer
    /// never removes a newer toast.
    public func dismiss(_ id: Toast.ID) {
        guard current?.id == id else { return }
        dismiss()
    }

    private func present(_ toast: Toast, action: Action?) {
        expiry?.cancel()
        self.action = action
        current = toast
        let duration = displayDuration
        expiry = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }
}
