import XCTest
@testable import KumoneCore

@MainActor
final class QishuiSearchTests: XCTestCase {
    func testPublicTrackPreservesStringIDBeyondJavaScriptIntegerPrecision() throws {
        let id = "7676337516358617115"
        let raw: [String: Any] = ["track_entity": [
            "base_info": ["id": id, "name": "测试歌曲", "duration_ms": 237_336],
            "related_info": ["artist_links": [["id": "1", "name": "测试歌手"]],
                             "album_link": ["id": "2", "name": "测试专辑"]]
        ]]
        let track = try XCTUnwrap(QishuiSearch.track(raw))
        XCTAssertEqual(track.source, "sd")
        XCTAssertEqual(track.sourceMetadata["songmid"], id)
        XCTAssertEqual(String(track.id), id)
        XCTAssertEqual(track.artistNames, "测试歌手")
        XCTAssertEqual(track.durationMS, 237_336)
    }

    func testSearchSourceChoicesAndLXAliases() {
        XCTAssertEqual(LXCatalogPlatform.catalogueCases.map(\.rawValue), ["aggregate", "kw", "kg", "tx", "wy", "sd"])
        XCTAssertFalse(LXCatalogPlatform.discoveryCases.contains(.sd))
        XCTAssertEqual(LXCatalogPlatform.displayName(for: "qs"), "汽水音乐")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["qs": ["musicUrl"]]), "qs")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["sd": ["musicUrl"]]), "sd")
    }

    func testMalformedOrNumericIdentityDoesNotLosePrecision() {
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": 7_676_337_516_358_617_115, "name": "x"]]))
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": "not-an-id", "name": "x"]]))
    }
}
