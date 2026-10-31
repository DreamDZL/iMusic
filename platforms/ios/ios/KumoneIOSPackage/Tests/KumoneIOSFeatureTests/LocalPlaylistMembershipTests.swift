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

    /// Saved songs lead the playlist, keeping their own order among
    /// themselves; a second toggle takes them out again.
    func testAddedTracksGoToTheTopAndRemoveUndoes() throws {
        let store = makeStore()
        let old = track("old", name: "Old")
        let first = track("a", name: "First")
        let second = track("b", name: "Second")
        let id = try XCTUnwrap(store.create(name: "Mix", tracks: [old]))

        XCTAssertEqual(store.add([first, second], to: id), 2)
        XCTAssertEqual(store.playlist(id: id)?.tracks.map(\.name), ["First", "Second", "Old"])

        let third = track("c", name: "Third")
        store.add(third, to: id)
        XCTAssertEqual(store.playlist(id: id)?.tracks.first?.name, "Third",
                       "The single-track path saves to the top as well")

        store.remove([first], from: id)
        XCTAssertFalse(store.containsAll([first], in: id))
        XCTAssertEqual(store.playlist(id: id)?.tracks.map(\.name), ["Third", "Second", "Old"])
    }

    func testContainsAllIsFalseForEmptySelectionOrUnknownPlaylist() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.create(name: "Empty"))
        XCTAssertFalse(store.containsAll([], in: id))
        XCTAssertFalse(store.containsAll([track("a", name: "First")], in: UUID()))
    }
}
