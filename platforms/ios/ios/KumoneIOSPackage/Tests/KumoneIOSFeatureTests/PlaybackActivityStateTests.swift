import XCTest
@testable import KumoneCore

final class PlaybackActivityStateTests: XCTestCase {
    @available(iOS 16.1, *)
    func testLegacyActivityStateDefaultsToNormalPlaybackRate() throws {
        let legacyState = #"{"title":"Song","artist":"Artist","elapsed":15,"duration":100,"isPlaying":true,"updatedAt":0}"#
        let state = try JSONDecoder().decode(
            MoumusicPlaybackActivityAttributes.ContentState.self,
            from: Data(legacyState.utf8)
        )

        XCTAssertEqual(state.playbackRate, 1)
    }

    @available(iOS 16.1, *)
    func testPlaybackIntervalTracksElapsedAndDurationAtSelectedRate() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let state = MoumusicPlaybackActivityAttributes.ContentState(
            title: "Song",
            artist: "Artist",
            artworkURL: nil,
            elapsed: 20,
            duration: 100,
            isPlaying: true,
            playbackRate: 2,
            updatedAt: updatedAt
        )
        let restored = try JSONDecoder().decode(
            MoumusicPlaybackActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertEqual(restored.playbackRate, 2)
        XCTAssertEqual(
            restored.playbackInterval.lowerBound.timeIntervalSince(updatedAt),
            -10,
            accuracy: 0.001
        )
        XCTAssertEqual(
            restored.playbackInterval.upperBound.timeIntervalSince(updatedAt),
            40,
            accuracy: 0.001
        )
    }
}
