import XCTest
@testable import KumoneCore

/// The add-to-playlist sheet marks lists that already hold the selection and
/// keeps itself open instead of pretending to add a duplicate.
@MainActor
final class LocalPlaylistMembershipTests: XCTestCase {
    private func makeStore() -> LocalPlaylistStore {
        let suiteName = "LocalPlaylistMembershipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return LocalPlaylistStore(defaults: defaults)
    }

    private func track(_ mid: String, name: String) -> Track {
        Track(
            id: 1,
            name: name,
            artists: [ArtistRef(id: 2, name: "Artist")],
            album: AlbumRef(id: 3, name: "Album", picUrl: nil),
            durationMS: 200_000,
            source: "tx",
            sourceMetadata: ["songmid": mid]
        )
    }

    func testContainsAllReflectsMembership() throws {
        let store = makeStore()
        let first = track("a", name: "First")
        let second = track("b", name: "Second")
        let id = try XCTUnwrap(store.create(name: "Mix", tracks: [first]))

        XCTAssertTrue(store.containsAll([first], in: id))
        XCTAssertFalse(store.containsAll([second], in: id))
        XCTAssertFalse(store.containsAll([first, second], in: id),
                       "A partly saved selection is not saved")

        XCTAssertEqual(store.add([first, second], to: id), 1, "Duplicates are skipped")
        XCTAssertTrue(store.containsAll([first, second], in: id))
    }

    func testContainsAllIsFalseForEmptySelectionOrUnknownPlaylist() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.create(name: "Empty"))
        XCTAssertFalse(store.containsAll([], in: id))
        XCTAssertFalse(store.containsAll([track("a", name: "First")], in: UUID()))
    }
}
