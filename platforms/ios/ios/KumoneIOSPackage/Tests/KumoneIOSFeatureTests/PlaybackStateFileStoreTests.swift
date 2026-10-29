import Foundation
import XCTest
@testable import KumoneCore

final class PlaybackStateFileStoreTests: XCTestCase {
    func testWriteReplacesTheCompletePriorPayload() throws {
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

    func testWriteFailureKeepsExistingState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackStateFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let file = root.appendingPathComponent("player-state.json")
        let oldState = Data("recoverable old queue".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try oldState.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: root.path
        )

        XCTAssertThrowsError(try PlaybackStateFileStore.write(
            Data("replacement queue".utf8),
            to: file
        ))
        XCTAssertEqual(try Data(contentsOf: file), oldState)
    }
}
