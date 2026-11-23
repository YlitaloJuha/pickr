import Foundation
import Photos
import PickrCore
import Testing
@testable import Pickr

/// The §4.6 error-mapping table, as a pure test.
@Suite("Photo error mapping")
struct PhotoErrorMappingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let domain: String
        let code: Int
        let expected: LibraryError

        var testDescription: String { "\(domain) \(code) → \(expected)" }
    }

    nonisolated static let table: [Row] = [
        // Both cancel domains are silent.
        Row(domain: PHPhotosErrorDomain, code: 3072, expected: .cancelled),
        Row(domain: NSCocoaErrorDomain, code: NSUserCancelledError, expected: .cancelled),
        Row(domain: NSCocoaErrorDomain, code: 3072, expected: .cancelled),
        // Access.
        Row(domain: PHPhotosErrorDomain, code: 3311, expected: .notAuthorized),
        Row(domain: PHPhotosErrorDomain, code: 3310, expected: .notAuthorized),
        // Library unavailable.
        Row(domain: PHPhotosErrorDomain, code: 3114, expected: .unavailable),
        Row(domain: PHPhotosErrorDomain, code: 3143, expected: .unavailable),
        Row(domain: PHPhotosErrorDomain, code: 3142, expected: .unavailable),
        // Network.
        Row(domain: PHPhotosErrorDomain, code: 3169, expected: .network),
        Row(domain: PHPhotosErrorDomain, code: 3164, expected: .network),
        // Limits.
        Row(domain: PHPhotosErrorDomain, code: 3307, expected: .limitExceeded),
        // Anything else keeps its domain and code.
        Row(domain: PHPhotosErrorDomain, code: -1, expected: .failed(domain: PHPhotosErrorDomain, code: -1)),
        Row(domain: PHPhotosErrorDomain, code: 3301, expected: .failed(domain: PHPhotosErrorDomain, code: 3301)),
        Row(domain: PHPhotosErrorDomain, code: 3105, expected: .failed(domain: PHPhotosErrorDomain, code: 3105)),
        Row(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
            expected: .failed(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
        // The cancel code means nothing in another domain.
        Row(domain: NSURLErrorDomain, code: 3072, expected: .failed(domain: NSURLErrorDomain, code: 3072)),
        Row(domain: "Other", code: 3311, expected: .failed(domain: "Other", code: 3311)),
    ]

    @Test(arguments: table)
    func mapsNSError(_ row: Row) {
        let error = NSError(domain: row.domain, code: row.code)
        #expect(PhotoErrorMapping.libraryError(from: error) == row.expected)
        #expect(PhotoErrorMapping.libraryError(domain: row.domain, code: row.code) == row.expected)
    }

    @Test func mapsSwiftErrorTypes() {
        #expect(PhotoErrorMapping.libraryError(from: PHPhotosError(.userCancelled)) == .cancelled)
        #expect(PhotoErrorMapping.libraryError(from: CocoaError(.userCancelled)) == .cancelled)
        #expect(PhotoErrorMapping.libraryError(from: PHPhotosError(.accessUserDenied)) == .notAuthorized)
        #expect(PhotoErrorMapping.libraryError(from: PHPhotosError(.limitExceeded)) == .limitExceeded)
    }

    @Test func passesLibraryErrorsThrough() {
        for error in [LibraryError.nothingToDelete, .network, .failed(domain: "x", code: 1)] {
            #expect(PhotoErrorMapping.libraryError(from: error) == error)
        }
    }

    @Test func taskCancellationIsACancel() {
        #expect(PhotoErrorMapping.libraryError(from: CancellationError()) == .cancelled)
    }

    @Test func onlyHistoryErrorsRequireARebuild() {
        #expect(PhotoErrorMapping.requiresFullRebuild(NSError(domain: PHPhotosErrorDomain, code: 3105)))
        #expect(PhotoErrorMapping.requiresFullRebuild(NSError(domain: PHPhotosErrorDomain, code: 3210)))
        #expect(PhotoErrorMapping.requiresFullRebuild(PHPhotosError(.persistentChangeTokenExpired)))
        #expect(!PhotoErrorMapping.requiresFullRebuild(NSError(domain: PHPhotosErrorDomain, code: 3072)))
        #expect(!PhotoErrorMapping.requiresFullRebuild(NSError(domain: NSCocoaErrorDomain, code: 3105)))
    }
}

@Suite("Authorization mapping")
struct AuthorizationMappingTests {
    @Test func mapsEveryStatus() {
        #expect(LivePhotoLibrary.access(from: .notDetermined) == .notDetermined)
        #expect(LivePhotoLibrary.access(from: .authorized) == .full)
        #expect(LivePhotoLibrary.access(from: .limited) == .limited)
        #expect(LivePhotoLibrary.access(from: .denied) == .denied)
        #expect(LivePhotoLibrary.access(from: .restricted) == .denied)
    }

    @Test func onlyGrantedAccessHasAnIndexScope() {
        #expect(IndexCache.Scope(.full) == .full)
        #expect(IndexCache.Scope(.limited) == .limited)
        #expect(IndexCache.Scope(.denied) == nil)
        #expect(IndexCache.Scope(.notDetermined) == nil)
    }
}
