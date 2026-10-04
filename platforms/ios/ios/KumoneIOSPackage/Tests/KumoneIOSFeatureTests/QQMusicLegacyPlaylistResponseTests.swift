import Foundation
import XCTest
@testable import KumoneCore

final class QQMusicLegacyPlaylistResponseTests: XCTestCase {
    func testCreatedAndCollectedPlaylistTitleFieldVariantsKeepQQPlaylistNames() {
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: ["diss_name": "我的私人歌单"]),
            "我的私人歌单"
        )
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: ["dissname": "收藏的公开歌单"]),
            "收藏的公开歌单"
        )
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: ["dissName": "另一个收藏歌单"]),
            "另一个收藏歌单"
        )
    }

    func testQQPlaylistTitleUsesProviderTitleBeforeGenericName() {
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: [
                "name": "QQ音乐歌单",
                "dissname": "公开歌单真实名称",
            ]),
            "公开歌单真实名称"
        )
        XCTAssertNil(QQMusicAPI.playlistName(in: ["diss_name": "   "]))
    }

    func testCollectedPlaylistKeepsListTitleWhenDetailOnlyHasGenericQQLabel() {
        XCTAssertEqual(
            QQMusicAPI.resolvedPlaylistName(detailName: "QQ歌单", listName: "收藏的公开歌单真实名称"),
            "收藏的公开歌单真实名称"
        )
        XCTAssertEqual(
            QQMusicAPI.resolvedPlaylistName(detailName: "QQ 音乐歌单", listName: "QQ 音乐歌单"),
            "QQ 音乐歌单"
        )
        XCTAssertEqual(
            QQMusicAPI.resolvedPlaylistName(detailName: "详情中的正确名称", listName: "列表名称"),
            "详情中的正确名称"
        )
        XCTAssertNil(QQMusicAPI.playlistName(in: ["title": "QQ歌单"]))
    }

    func testCollectedPlaylistTitleCanBeReadFromNestedQQMetadata() {
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: [
                "cdlist": [["dirinfo": ["title": "嵌套公开歌单名"]]],
            ]),
            "嵌套公开歌单名"
        )
        XCTAssertEqual(
            QQMusicAPI.playlistName(in: ["data": ["cdlist": [["dissname": "收藏接口歌单名"]]]]),
            "收藏接口歌单名"
        )
        XCTAssertNil(QQMusicAPI.playlistName(in: ["songlist": [["name": "歌曲名"]]]))
    }

    func testLegacyDesktopEndpointUsesThePublicPlaylistRequestShape() throws {
        let url = try XCTUnwrap(QQMusicLegacyPlaylistResponse.endpointURL(playlistID: 7_217_720_898))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.host, "c.y.qq.com")
        XCTAssertEqual(url.path, "/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg")
        XCTAssertEqual(values["disstid"], "7217720898")
        XCTAssertEqual(values["new_format"], "1")
        XCTAssertEqual(values["platform"], "yqq.json")
        XCTAssertEqual(values["loginUin"], "0")
        XCTAssertEqual(values["hostUin"], "0")
        XCTAssertEqual(values["g_tk"], "5381")
        XCTAssertNil(QQMusicLegacyPlaylistResponse.endpointURL(playlistID: 0))
    }

    func testLegacyEndpointCanCarryAccountAndCSRFContext() throws {
        let url = try XCTUnwrap(QQMusicLegacyPlaylistResponse.endpointURL(
            playlistID: 7_217_720_898,
            loginUin: "123456789",
            hostUin: "123456789",
            gTk: "987654321"
        ))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(values["loginUin"], "123456789")
        XCTAssertEqual(values["hostUin"], "123456789")
        XCTAssertEqual(values["g_tk"], "987654321")
    }

    func testDecodeSlicesPagesAndUsesReportedSongCount() throws {
        let response: [String: Any] = [
            "code": 0,
            "subcode": 0,
            "cdlist": [[
                "dissname": "收藏接口返回的真实名称",
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
        XCTAssertEqual(firstPage.playlistName, "收藏接口返回的真实名称")

        let secondPage = try QQMusicLegacyPlaylistResponse.decode(data, offset: 2, pageSize: 2)
        XCTAssertEqual(secondPage.rows.compactMap { $0["mid"] as? String }, ["third"])
        XCTAssertEqual(secondPage.totalCount, 3)
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertEqual(secondPage.playlistName, "收藏接口返回的真实名称")
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
