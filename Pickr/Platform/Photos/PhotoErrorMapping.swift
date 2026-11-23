import Foundation
import Photos
import PickrCore

/// Maps PhotoKit and Cocoa errors to `LibraryError` (blueprint §4.6, error-mapping table).
///
/// | Source | `LibraryError` |
/// |---|---|
/// | `PHPhotosErrorDomain` `userCancelled` (3072) | `.cancelled` |
/// | `NSCocoaErrorDomain` `NSUserCancelledError` (also 3072) | `.cancelled` |
/// | `accessUserDenied`, `accessRestricted` | `.notAuthorized` |
/// | `libraryVolumeOffline`, `switchingSystemPhotoLibrary`, `relinquishingLibraryBundleToWriter` | `.unavailable` |
/// | `networkError`, `networkAccessRequired` | `.network` |
/// | `limitExceeded` (3307) | `.limitExceeded` |
/// | anything else | `.failed(domain:code:)` |
///
/// Which domain the system delete dialog uses for its Cancel button has to be checked on a
/// device, so both cancel domains map to the silent `.cancelled`.
nonisolated enum PhotoErrorMapping {
    /// Maps PhotoKit and Cocoa errors to `LibraryError`; both cancel domains map to `.cancelled`.
    ///
    /// A `LibraryError` passes through unchanged, and Swift task cancellation is a cancel too.
    static func libraryError(from error: any Error) -> LibraryError {
        if let error = error as? LibraryError { return error }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        return libraryError(domain: nsError.domain, code: nsError.code)
    }

    /// The table above for a raw `NSError` domain and code.
    static func libraryError(domain: String, code: Int) -> LibraryError {
        switch domain {
        case PHPhotosErrorDomain:
            switch PHPhotosError.Code(rawValue: code) {
            case .userCancelled?:
                return .cancelled
            case .accessUserDenied?, .accessRestricted?:
                return .notAuthorized
            case .libraryVolumeOffline?, .switchingSystemPhotoLibrary?, .relinquishingLibraryBundleToWriter?:
                return .unavailable
            case .networkError?, .networkAccessRequired?:
                return .network
            case .limitExceeded?:
                return .limitExceeded
            default:
                return .failed(domain: domain, code: code)
            }
        case NSCocoaErrorDomain where code == NSUserCancelledError:
            return .cancelled
        default:
            return .failed(domain: domain, code: code)
        }
    }

    /// Whether a persistent-history error means the index must be rebuilt from scratch:
    /// the token is older than the kept history (3105), or the details of a change are gone
    /// (3210) (`PHError.h:42-43`).
    static func requiresFullRebuild(_ error: any Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == PHPhotosErrorDomain else { return false }
        switch PHPhotosError.Code(rawValue: nsError.code) {
        case .persistentChangeTokenExpired?, .persistentChangeDetailsUnavailable?:
            return true
        default:
            return false
        }
    }
}
