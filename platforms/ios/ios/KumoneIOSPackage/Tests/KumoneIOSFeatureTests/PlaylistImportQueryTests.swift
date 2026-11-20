import Foundation
import Testing
import XCTest
@testable import KumoneCore

final class PlaylistImportQueryTests: XCTestCase {
    func testRepeatedCaseInsensitiveParametersUseFirstNonEmptyValue() throws {
        let url = try XCTUnwrap(URL(string:
            "https://y.qq.com/n/ryqq/playlist?disstid=&DISSTID=first&disstid=second"
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        let values = PlaylistImportQuery.firstNonEmptyValues(from: items)

        XCTAssertEqual(values["disstid"], "first")
    }

    func testDifferentParametersRemainAvailable() throws {
        let url = try XCTUnwrap(URL(string:
            "https://y.qq.com/n/ryqq/playlist?disstid=42&source=share"
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        let values = PlaylistImportQuery.firstNonEmptyValues(from: items)

        XCTAssertEqual(values["disstid"], "42")
        XCTAssertEqual(values["source"], "share")
    }

    func testNetEasePlaylistIDSkipsEmptyRepeatedParameters() throws {
        let url = try XCTUnwrap(URL(string:
            "https://music.163.com/#/playlist?id=&ID=123456&id=789"
        ))
        let fragment = try XCTUnwrap(url.fragment)
        let items = try XCTUnwrap(URLComponents(string: fragment)?.queryItems)

        XCTAssertEqual(PlaylistImportQuery.firstIntegerValue(for: "id", from: items), 123456)
    }
}

struct PlaylistImportRetirementTests {
    @MainActor
    @Test(arguments: [
        "https://music.migu.cn/v3/music/playlist/123",
        "https://music.douyin.com/qishui/share/playlist/123",
        "分享歌单 https://v.douyin.com/s/example/",
    ])
    func retiredPlaylistLinksAreUnsupported(_ input: String) async throws {
        let suite = "PlaylistImportRetirementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalPlaylistStore(defaults: defaults)

        do {
            _ = try await store.importPlaylist(from: input)
            Issue.record("A retired playlist link was imported.")
        } catch PlaylistImportError.unsupportedLink {
            #expect(store.playlists.isEmpty)
        }
    }

    @MainActor
    @Test
    func localJSONWithLegacyProviderTracksAndArtworkRemainsImportable() async throws {
        let suite = "PlaylistImportRetirementTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalPlaylistStore(defaults: defaults)
        let id = try await store.importPlaylist(from: """
        {
          "name": "Legacy mix",
          "coverURL": "https://example.invalid/cover.jpg",
          "tracks": [
            {"id": 101, "name": "Migu track", "source": "migu", "songmid": "migu-mid"},
            {"id": 202, "name": "Qishui track", "source": "qishui", "songmid": "202"}
          ]
        }
        """)

        let reloaded = try #require(LocalPlaylistStore(defaults: defaults).playlist(id: id))
        #expect(reloaded.coverURL == "https://example.invalid/cover.jpg")
        #expect(reloaded.tracks.map(\.id) == [101, 202])
        #expect(reloaded.tracks.compactMap(\.source) == ["migu", "qishui"])
        let tracks = reloaded.tracks.map { $0.normalizedForLXPlayback() }
        #expect(tracks.compactMap(\.source) == ["mg", "sd"])
        #expect(tracks.compactMap { $0.sourceMetadata["songmid"] } == ["migu-mid", "202"])
        #expect(LocalPlaylistSyncPolicy.providerIdentityKey(source: "Migu", id: "123")
                == LocalPlaylistSyncPolicy.providerIdentityKey(source: "mg", id: "123"))
        #expect(LocalPlaylistSyncPolicy.providerIdentityKey(source: "Qishui", id: "123")
                == LocalPlaylistSyncPolicy.providerIdentityKey(source: "sd", id: "123"))
    }
}
