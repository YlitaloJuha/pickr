import Foundation
import Photos
import Synchronization

/// Forwards PhotoKit's change callbacks into an `AsyncStream` (blueprint §4.4, §4.6).
///
/// It listens to both the live `PHPhotoLibraryChangeObserver` callback (which also reports
/// limited-selection changes) and the iOS 27 persistent-changes observer
/// (`PHPhotoLibrary.h:159`). Both arrive "on an arbitrary serial queue", so the class is
/// nonisolated and `Sendable`: a main-actor conformance does not compile [ARCH C10].
///
/// The stream keeps only the newest signal, so a burst of callbacks while the consumer is
/// busy collapses into one. `LibraryIndexer` debounces it by 300 ms and then refreshes.
nonisolated final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver,
    PHPhotoLibraryPersistentChangesObserver, Sendable
{
    /// One element per burst of library changes.
    let changes: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let library: PHPhotoLibrary
    private let isRegistered = Mutex(false)

    init(library: PHPhotoLibrary = .shared()) {
        #if DEBUG
        precondition(!DemoMode.isActive, "Demo mode never observes the photo library")
        #endif
        (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.library = library
        super.init()
    }

    deinit {
        stop()
        continuation.finish()
    }

    /// Registers with the photo library. Call it only once access is granted: the
    /// persistent-changes observer requires read-write authorization. Repeated calls do
    /// nothing.
    func start() {
        let shouldRegister = isRegistered.withLock { registered in
            defer { registered = true }
            return !registered
        }
        guard shouldRegister else { return }
        library.register(self as any PHPhotoLibraryChangeObserver)
        library.register(self as any PHPhotoLibraryPersistentChangesObserver)
    }

    /// Unregisters from the photo library. Repeated calls do nothing.
    func stop() {
        let shouldUnregister = isRegistered.withLock { registered in
            defer { registered = false }
            return registered
        }
        guard shouldUnregister else { return }
        library.unregisterChangeObserver(self)
        library.unregisterPersistentChangesObserver(self)
    }

    // MARK: PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        continuation.yield()
    }

    // MARK: PHPhotoLibraryPersistentChangesObserver

    func photoLibraryPersistentChangesDidUpdate(_ photoLibrary: PHPhotoLibrary) {
        continuation.yield()
    }
}
