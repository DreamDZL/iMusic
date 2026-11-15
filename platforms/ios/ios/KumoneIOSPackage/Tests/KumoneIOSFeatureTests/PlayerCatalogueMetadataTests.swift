import XCTest
@testable import KumoneCore

final class PlayerCatalogueMetadataTests: XCTestCase {
    func testQishuiRefreshPreservesIdentityAndSavedFields() throws {
        let original = try JSONDecoder().decode(Track.self, from: Data(#"{"id":7409001029981636620,"name":"保存的歌名","ar":[{"id":23,"name":"保存的歌手"}],"al":{"id":0,"name":"","picUrl":"https://p3.douyinpic.com/bare"},"dt":0,"alia":["别名"],"tns":["译名"],"fee":1,"mv":7,"no":3,"cd":"2","pc":{},"privilege":{"id":7409001029981636620,"pl":320000},"source":"qs","sourceMetadata":{"songmid":"7409001029981636620","custom":"keep"}}"#.utf8))
        let catalogue = Track(id: original.id, name: "目录歌名", artists: [ArtistRef(id: 99, name: "目录歌手")],
                              album: AlbumRef(id: 31, name: "真实专辑", picUrl: "https://p3.douyinpic.com/cover.jpg"),
                              durationMS: 203000, source: "sd", sourceMetadata: ["songmid": String(original.id)])
        let result = try XCTUnwrap(original.mergingQishuiMetadata(catalogue))
        XCTAssertEqual(result.playbackKey, original.playbackKey)
        XCTAssertEqual(result.sourceMetadata, original.sourceMetadata)
        XCTAssertEqual(result.alias, original.alias)
        XCTAssertEqual(result.transNames, original.transNames)
        XCTAssertEqual(result.fee, original.fee)
        XCTAssertEqual(result.mvID, original.mvID)
        XCTAssertEqual(result.trackNo, original.trackNo)
        XCTAssertEqual(result.disc, original.disc)
        XCTAssertEqual(result.isCloud, original.isCloud)
        XCTAssertEqual(result.embeddedPrivilege, original.embeddedPrivilege)
        XCTAssertEqual(result.album, catalogue.album)
        XCTAssertEqual(result.durationMS, 203000)
    }

    func testRefreshRejectsOtherTracksAndPlatforms() {
        let base = Track(id: 1, name: "A", artists: [], album: AlbumRef(id: 0, name: "", picUrl: nil), durationMS: 0, source: "sd")
        let wrongTrack = Track(id: 2, name: "B", artists: [], album: base.album, durationMS: 1, source: "sd")
        XCTAssertNil(base.mergingQishuiMetadata(wrongTrack))
        XCTAssertNil(base.mergingQishuiMetadata(base.withSource("wy")))
    }

    func testEmptyCatalogueFieldsDoNotEraseExistingMetadata() throws {
        let base = Track(id: 1, name: "A", artists: [], album: AlbumRef(id: 2, name: "专辑", picUrl: "https://example.org/cover.jpg"), durationMS: 120000, source: "sd")
        let empty = Track(id: 1, name: "A", artists: [], album: AlbumRef(id: 0, name: "", picUrl: nil), durationMS: 0, source: "sd")
        let result = try XCTUnwrap(base.mergingQishuiMetadata(empty))
        XCTAssertEqual(result.album, base.album)
        XCTAssertEqual(result.durationMS, base.durationMS)
    }

    func testSourceErrorsNeverPublishSignedURLsOrCredentials() {
        let raw = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://example.org/audio?token=PRIVATE"])
        XCTAssertFalse(PlaybackFailureMessage.source(raw).contains("PRIVATE"))
        #if os(iOS)
        for error in [LXUserAPIService.LXError.javascript("token=PRIVATE"), .resolveFailed(["token=PRIVATE"]), .sourceUnavailable("token=PRIVATE")] {
            XCTAssertFalse(PlaybackFailureMessage.source(error).contains("PRIVATE"))
        }
        XCTAssertTrue(PlaybackFailureMessage.source(LXUserAPIService.LXError.missingCapability("sd", "musicUrl")).contains("汽水音乐"))
        #endif
    }
}
