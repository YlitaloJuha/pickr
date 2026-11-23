import Foundation

/// Whole-file reads and atomic, protected writes in the app container (§4.5).
///
/// `KeptStore` calls these from inside its actor, so one file is never written by two
/// callers at once.
enum FileStore {
    /// The file's contents, or `nil` when there is no file. Any other failure throws, for
    /// example reading a protected file before the first unlock.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Replaces the file with `data` and creates its folder when needed.
    ///
    /// The write is atomic: the data goes to a temporary file that is then renamed over the
    /// old one. A reader, or a launch after a crash, sees either the old contents or the new
    /// ones, never a mix. If the write fails, the old file stays as it was. The file is
    /// protected until the first unlock after a restart and is included in backups.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Renames the file to `<name>.<tag>-<UUID>.<extension>` in the same folder, so a later
    /// write can't replace contents that couldn't be read. Returns the new location, or `nil`
    /// if the file couldn't be moved.
    static func moveAside(_ url: URL, tag: String) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let destination = url.deletingLastPathComponent()
            .appending(path: "\(name).\(tag)-\(UUID().uuidString)\(suffix)", directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
