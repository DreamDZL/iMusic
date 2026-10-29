import Foundation
import XCTest
@testable import KumoneCore

final class PlaybackStateFileStoreTests: XCTestCase {
    func testWriteCreatesDirectoryAndAtomicallyReplacesPriorState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackStateFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("nested/player-state.json")
        let oldState = Data("old queue".utf8)
        let newState = Data("new queue".utf8)
        try PlaybackStateFileStore.write(oldState, to: file)
        try PlaybackStateFileStore.write(newState, to: file)

        XCTAssertEqual(try Data(contentsOf: file), newState)
    }

    func testWriteFailureKeepsExistingStateAndReportsErrorToCaller() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackStateFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let blockingFile = root.appendingPathComponent("not-a-directory")
        let oldState = Data("recoverable old queue".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try oldState.write(to: blockingFile)

        XCTAssertThrowsError(try PlaybackStateFileStore.write(
            Data("replacement queue".utf8),
            to: blockingFile.appendingPathComponent("player-state.json")
        ))
        XCTAssertEqual(try Data(contentsOf: blockingFile), oldState)
    }
}
