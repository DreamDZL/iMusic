import XCTest
@testable import KumoneCore

final class LXSyncModelsTests: XCTestCase {
    func testQualityMapDecodesAndRoundTripsLXWireShape() throws {
        let json = #"{"songId":"song-1","albumName":"Album","qualitys":[{"type":"128k","size":"3.56M"}],"_qualitys":{"128k":{"size":"3.56M"},"flac":{"size":"20M","hash":"kg-hash"}}}"#
        let data = Data(json.utf8)

        let decoded = try JSONDecoder().decode(LXSyncMusicMeta.self, from: data)
        XCTAssertEqual(decoded.qualitys?.first?.type, "128k")
        XCTAssertEqual(decoded._qualitys?["128k"]?.size, "3.56M")
        XCTAssertNil(decoded._qualitys?["128k"]?.hash)
        XCTAssertEqual(decoded._qualitys?["flac"]?.hash, "kg-hash")

        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(LXSyncMusicMeta.self, from: encoded)
        XCTAssertEqual(roundTripped._qualitys, decoded._qualitys)
    }

    func testQualityMetadataSurvivesLocalTrackConversion() throws {
        let json = #"{"id":"kg_song-1_kg-hash","name":"Song","singer":"Artist","source":"kg","interval":"03:10","meta":{"songId":"song-1","albumName":"Album","qualitys":[{"type":"128k","size":"3.56M","hash":"kg-hash"}],"_qualitys":{"128k":{"size":"3.56M","hash":"kg-hash"}}}}"#
        let wireTrack = try JSONDecoder().decode(LXSyncMusicInfo.self, from: Data(json.utf8))

        let rebuilt = LXSyncMusicInfo(track: wireTrack.track)

        XCTAssertEqual(rebuilt.meta.qualitys, wireTrack.meta.qualitys)
        XCTAssertEqual(rebuilt.meta._qualitys, wireTrack.meta._qualitys)
    }

    func testLocalCopyFlagSurvivesLXSyncRoundTrip() throws {
        let original = LXSyncUserPlaylist(
            id: "playlist-1",
            name: "My local copy",
            source: "netease",
            sourceListId: "42",
            iMusicLocalCopy: true
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LXSyncUserPlaylist.self, from: encoded)

        XCTAssertEqual(decoded.iMusicLocalCopy, true)
        XCTAssertEqual(decoded.sourceListId, "42")
    }

    func testOlderLXSyncPlaylistDefaultsLocalCopyFlagToNil() throws {
        let json = #"{"id":"playlist-1","name":"Older playlist","list":[]}"#
        let decoded = try JSONDecoder().decode(LXSyncUserPlaylist.self, from: Data(json.utf8))

        XCTAssertNil(decoded.iMusicLocalCopy)
    }
}
