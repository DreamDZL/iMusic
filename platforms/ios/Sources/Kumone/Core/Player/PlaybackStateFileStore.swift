import Foundation

/// Atomic disk access for the persisted playback queue. Kept separate so disk
/// failures can be exercised with an isolated temporary directory in tests.
enum PlaybackStateFileStore {
    static func write(_ data: Data, to fileURL: URL, fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
