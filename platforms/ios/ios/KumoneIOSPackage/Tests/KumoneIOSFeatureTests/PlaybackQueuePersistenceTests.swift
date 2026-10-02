import Foundation
import XCTest
@testable import KumoneCore

final class PlaybackQueuePersistenceTests: XCTestCase {
    func testPlayNextListRoundTripsWithThePersistedQueue() throws {
        let current = track(id: 1, name: "Current")
        let next = track(id: 2, name: "Play next", source: "tx")
        let state = PersistedPlaybackState(
            queue: [current],
            queueItemIDs: ["current-instance"],
            playNextItemIDs: ["next-instance"],
            currentIndex: 0,
            currentItemID: "current-instance",
            currentID: current.id,
            currentKey: current.playbackKey,
            repeatMode: RepeatMode.off.rawValue,
            shuffle: false,
            recentContexts: nil,
            playNextQueue: [next]
        )

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PersistedPlaybackState.self, from: data)

        XCTAssertEqual(restored.queue.map(\.playbackKey), [current.playbackKey])
        XCTAssertEqual(restored.queueItemIDs, ["current-instance"])
        XCTAssertEqual(restored.currentIndex, 0)
        XCTAssertEqual(restored.playNextQueue?.map(\.playbackKey), [next.playbackKey])
        XCTAssertEqual(restored.playNextItemIDs, ["next-instance"])
    }

    func testStartedPlayNextTrackAndShuffleOrderCanBeRestored() throws {
        let first = track(id: 1, name: "First")
        let next = track(id: 2, name: "Play next", source: "tx")
        let repeated = track(id: 1, name: "First")
        let state = PersistedPlaybackState(
            queue: [first, next, repeated],
            queueItemIDs: ["first-copy", "inserted-copy", "repeat-copy"],
            shuffledQueue: [next, first, repeated],
            shuffledItemIDs: ["inserted-copy", "first-copy", "repeat-copy"],
            currentIndex: 2,
            currentItemID: "repeat-copy",
            currentID: first.id,
            currentKey: first.playbackKey,
            currentTrack: repeated,
            repeatMode: RepeatMode.off.rawValue,
            shuffle: true,
            recentContexts: nil,
            playNextQueue: nil
        )

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(PersistedPlaybackState.self, from: data)

        XCTAssertEqual(restored.currentTrack?.playbackKey, first.playbackKey)
        XCTAssertEqual(restored.currentIndex, 2)
        XCTAssertEqual(restored.shuffledQueue?.map(\.playbackKey), [next.playbackKey, first.playbackKey, repeated.playbackKey])
        XCTAssertEqual(
            PlaybackQueuePolicy.restoredIndex(
                persistedIndex: restored.currentIndex,
                currentItemID: restored.currentItemID,
                currentKey: restored.currentKey,
                currentID: restored.currentID,
                in: restored.shuffledQueue ?? [],
                itemIDs: restored.shuffledItemIDs ?? []
            ),
            2,
            "A persisted index distinguishes repeated copies of the same song."
        )
    }

    func testOlderPersistedStateWithoutPlayNextListStillDecodes() throws {
        let data = Data(#"{"queue":[],"repeatMode":"off","shuffle":false}"#.utf8)

        let restored = try JSONDecoder().decode(PersistedPlaybackState.self, from: data)

        XCTAssertTrue(restored.queue.isEmpty)
        XCTAssertNil(restored.playNextQueue)
        XCTAssertNil(restored.currentTrack)
        XCTAssertNil(restored.shuffledQueue)
        XCTAssertNil(restored.currentIndex)
        XCTAssertNil(restored.queueItemIDs)
        XCTAssertNil(restored.shuffledItemIDs)
        XCTAssertNil(restored.playNextItemIDs)
    }

    func testUpcomingIndicesMapIntoTheActiveQueue() {
        XCTAssertEqual(
            PlaybackQueuePolicy.insertionIndex(after: -1, queueCount: 0),
            0
        )
        XCTAssertEqual(
            PlaybackQueuePolicy.insertionIndex(after: 1, queueCount: 4),
            2
        )
        XCTAssertEqual(
            PlaybackQueuePolicy.activeQueueIndex(
                forUpcomingIndex: 3,
                playNextCount: 1,
                currentIndex: 2
            ),
            5
        )
        XCTAssertNil(
            PlaybackQueuePolicy.activeQueueIndex(
                forUpcomingIndex: 0,
                playNextCount: 1,
                currentIndex: 2
            )
        )
    }

    func testStableItemIDsMapShuffledDuplicatesBackToTheirExactQueueRows() {
        let canonicalIDs = ["copy-1", "other", "copy-2"]
        let shuffledIDs = ["other", "copy-2", "copy-1"]
        XCTAssertEqual(
            PlaybackQueuePolicy.canonicalQueueIndex(for: shuffledIDs[1], itemIDs: canonicalIDs),
            2
        )
        XCTAssertNil(
            PlaybackQueuePolicy.canonicalQueueIndex(for: "missing-item", itemIDs: canonicalIDs)
        )
    }

    func testPlayNextPromotionRemainsNextWhenShuffleIsTurnedOff() {
        var canonicalIDs = ["first", "current", "later"]
        let insertionIndex = PlaybackQueuePolicy.canonicalInsertionIndex(
            after: "current",
            itemIDs: canonicalIDs,
            fallbackIndex: 0
        )
        canonicalIDs.insert("play-next", at: insertionIndex)

        let currentIndexAfterPromotion = canonicalIDs.firstIndex(of: "play-next")!
        XCTAssertEqual(currentIndexAfterPromotion, 2)
        XCTAssertEqual(canonicalIDs[currentIndexAfterPromotion + 1], "later")
    }

    private func track(id: Int, name: String, source: String = "wy") -> Track {
        Track(
            id: id,
            name: name,
            artists: [ArtistRef(id: 10, name: "Artist")],
            album: AlbumRef(id: 20, name: "Album", picUrl: nil),
            durationMS: 180_000,
            source: source,
            sourceMetadata: ["songmid": "\(source)-\(id)"]
        )
    }
}
