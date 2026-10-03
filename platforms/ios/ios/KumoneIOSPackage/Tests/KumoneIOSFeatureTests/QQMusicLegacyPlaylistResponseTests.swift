import Foundation
import XCTest
@testable import KumoneCore

final class QQMusicLegacyPlaylistResponseTests: XCTestCase {
    func testLegacyDesktopEndpointUsesThePublicPlaylistRequestShape() throws {
        let url = try XCTUnwrap(QQMusicLegacyPlaylistResponse.endpointURL(playlistID: 7_217_720_898))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "c.y.qq.com")
        XCTAssertEqual(url.path, "/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg")
        XCTAssertEqual(values["disstid"], "7217720898")
        XCTAssertEqual(values["new_format"], "1")
        XCTAssertEqual(values["platform"], "yqq.json")
        XCTAssertNil(QQMusicLegacyPlaylistResponse.endpointURL(playlistID: 0))
    }

    func testDecodeSlicesPagesAndUsesReportedSongCount() throws {
        let response: [String: Any] = [
            "code": 0,
            "subcode": 0,
            "cdlist": [[
                "songnum": 3,
                "songlist": [
                    ["mid": "first"],
                    ["mid": "second"],
                    ["mid": "third"],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        let firstPage = try QQMusicLegacyPlaylistResponse.decode(data, offset: 0, pageSize: 2)
        XCTAssertEqual(firstPage.rows.compactMap { $0["mid"] as? String }, ["first", "second"])
        XCTAssertEqual(firstPage.totalCount, 3)
        XCTAssertTrue(firstPage.hasMore)

        let secondPage = try QQMusicLegacyPlaylistResponse.decode(data, offset: 2, pageSize: 2)
        XCTAssertEqual(secondPage.rows.compactMap { $0["mid"] as? String }, ["third"])
        XCTAssertEqual(secondPage.totalCount, 3)
        XCTAssertFalse(secondPage.hasMore)
    }

    func testDecodeAcceptsJSONPResponse() throws {
        let json = #"{"code":0,"subcode":0,"cdlist":[{"songnum":1,"songlist":[{"mid":"song-mid"}]}]}"#
        let data = Data("playlistInfoCallback(\(json));".utf8)

        let page = try QQMusicLegacyPlaylistResponse.decode(data, offset: 0, pageSize: 100)
        XCTAssertEqual(page.rows.first?["mid"] as? String, "song-mid")
        XCTAssertEqual(page.totalCount, 1)
        XCTAssertFalse(page.hasMore)
    }

    func testProviderRejectionCodeIsPreserved() throws {
        let response: [String: Any] = [
            "code": 0,
            "subcode": "3a44",
            "cdlist": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: response)

        XCTAssertThrowsError(try QQMusicLegacyPlaylistResponse.decode(data, offset: 0, pageSize: 100)) { error in
            guard let responseError = error as? QQMusicLegacyPlaylistResponse.ResponseError,
                  case let .providerRejected(message) = responseError else {
                return XCTFail("Expected a provider rejection, got \(error)")
            }
            XCTAssertTrue(message.contains("3a44"))
        }
    }
}
