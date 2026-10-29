import XCTest
@testable import KumoneCore

@MainActor
final class LocalPlaylistRecoveryTests: XCTestCase {
    func testCorruptLibraryPayloadIsPreservedForRecovery() {
        let suiteName = "LocalPlaylistRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = Data("{not valid playlist JSON".utf8)
        defaults.set(original, forKey: "moumusic.localPlaylists.v1")

        let store = LocalPlaylistStore(defaults: defaults)

        XCTAssertTrue(store.playlists.isEmpty)
        let recoveryEntries = defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("moumusic.localPlaylists.v1.recovery.")
        }
        XCTAssertEqual(recoveryEntries.count, 1)
        XCTAssertEqual(recoveryEntries.first?.value as? Data, original)
    }

    func testCorruptFavoritesAndRecentsArePreservedForRecovery() {
        let suiteName = "LocalPlaylistRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let favorites = Data("invalid favorites".utf8)
        let recents = Data("invalid recents".utf8)
        defaults.set(favorites, forKey: "imusic.localFavorites.v1")
        defaults.set(recents, forKey: "imusic.recentTracks.v1")

        let store = LocalPlaylistStore(defaults: defaults)

        XCTAssertTrue(store.favoriteTracks.isEmpty)
        XCTAssertTrue(store.recentTracks.isEmpty)
        let values = defaults.dictionaryRepresentation()
        let recoveredFavorites = values.first { $0.key.hasPrefix("imusic.localFavorites.v1.recovery.") }?.value as? Data
        let recoveredRecents = values.first { $0.key.hasPrefix("imusic.recentTracks.v1.recovery.") }?.value as? Data
        XCTAssertEqual(recoveredFavorites, favorites)
        XCTAssertEqual(recoveredRecents, recents)
    }
}
