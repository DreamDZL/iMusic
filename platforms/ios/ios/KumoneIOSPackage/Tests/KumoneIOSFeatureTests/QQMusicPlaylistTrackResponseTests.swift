import XCTest
@testable import KumoneCore

final class QQMusicPlaylistTrackResponseTests: XCTestCase {
    func testNestedBusinessErrorIsNotAcceptedAsAnEmptySuccessfulPage() {
        let response: [String: Any] = [
            "code": 0,
            "req_1": [
                "code": 0,
                "data": [
                    "code": 0,
                    "subcode": "3a44",
                    "msg": "playlist unavailable",
                    "songlist": [],
                ],
            ],
        ]

        let failure = QQMusicAPI.playlistTrackDataFailure(in: response, responseKey: "req_1")

        XCTAssertEqual(failure, "响应码 3a44：playlist unavailable")
    }

    func testSuccessfulNestedPlaylistPayloadHasNoBusinessError() {
        let response: [String: Any] = [
            "req_1": [
                "code": 0,
                "data": ["code": 0, "subcode": 0, "songlist": [["mid": "song"]]],
            ],
        ]

        XCTAssertNil(QQMusicAPI.playlistTrackDataFailure(in: response, responseKey: "req_1"))
    }

    func testWhitespaceCodeDoesNotHideNonzeroNestedSubcode() {
        let response: [String: Any] = [
            "req_1": [
                "code": 0,
                "data": ["code": " \n", "subcode": "3a44", "songlist": []],
            ],
        ]

        XCTAssertEqual(
            QQMusicAPI.playlistTrackDataFailure(in: response, responseKey: "req_1"),
            "响应码 3a44"
        )
    }

    func testNestedBusinessErrorDiagnosticRedactsProviderMessage() {
        let error = QQMusicAPI.APIError.providerRejected(
            "响应码 3a44：private account cookie=must-not-display"
        )

        XCTAssertEqual(QQMusicAPI.safeRouteFailure(error), "响应码 3a44")
    }

    func testDiagnosticDoesNotPromoteCodeMentionedOnlyInProviderMessage() {
        let error = QQMusicAPI.APIError.providerRejected(
            "响应码 42：文案中提到了 3a44，但它不是响应码"
        )

        XCTAssertEqual(QQMusicAPI.safeRouteFailure(error), "响应码 42")
    }

    func testDiagnosticDoesNotPromoteCodePhraseInsideProviderMessage() {
        let error = QQMusicAPI.APIError.providerRejected("提示：响应码 3a44 只是文案")

        XCTAssertEqual(QQMusicAPI.safeRouteFailure(error), "服务端拒绝")
    }

    func testPlaylistTrackCountAcceptsQQSongnumField() {
        XCTAssertEqual(QQMusicAPI.playlistTrackTotalCount(in: ["songnum": "128"]), 128)
    }

    func testMobileFallbackMatchesLXMobileFullPlaylistRequest() throws {
        let payload = QQMusicAPI.mobilePlaylistDetailPayload(
            playlistID: 9_712_417_906,
            offset: 0,
            expectedPlaylistCount: 35,
            pageSize: 100
        )
        let comm = try XCTUnwrap(payload["comm"] as? [String: Any])
        let request = try XCTUnwrap(payload["req_1"] as? [String: Any])
        let parameters = try XCTUnwrap(request["param"] as? [String: Any])

        XCTAssertEqual(comm["cv"] as? Int, 4_747_474)
        XCTAssertEqual(comm["ct"] as? Int, 24)
        XCTAssertEqual(comm["platform"] as? String, "yqq.json")
        XCTAssertEqual(request["module"] as? String, "music.srfDissInfo.aiDissInfo")
        XCTAssertEqual(request["method"] as? String, "uniform_get_Dissinfo")
        XCTAssertEqual(parameters["disstid"] as? Int64, 9_712_417_906)
        XCTAssertEqual(parameters["song_begin"] as? Int, 0)
        XCTAssertEqual(parameters["song_num"] as? Int, 35)
        XCTAssertEqual(parameters["enc_host_uin"] as? String, "")
    }

    func testMobileFallbackBoundsUnknownAndOversizedPlaylistRequests() throws {
        let unknownCountPayload = QQMusicAPI.mobilePlaylistDetailPayload(
            playlistID: 7_217_720_898,
            offset: 0,
            expectedPlaylistCount: nil,
            pageSize: 100
        )
        let unknownRequest = try XCTUnwrap(unknownCountPayload["req_1"] as? [String: Any])
        let unknownParameters = try XCTUnwrap(unknownRequest["param"] as? [String: Any])
        XCTAssertEqual(unknownParameters["song_num"] as? Int, 10_000)

        let oversizedPayload = QQMusicAPI.mobilePlaylistDetailPayload(
            playlistID: 7_217_720_898,
            offset: 0,
            expectedPlaylistCount: 100_001,
            pageSize: 100
        )
        let oversizedRequest = try XCTUnwrap(oversizedPayload["req_1"] as? [String: Any])
        let oversizedParameters = try XCTUnwrap(oversizedRequest["param"] as? [String: Any])
        XCTAssertEqual(oversizedParameters["song_num"] as? Int, 10_000)
        XCTAssertFalse(QQMusicAPI.canAppendPlaylistTracks(currentCount: 10_000, incomingCount: 1))
        XCTAssertTrue(QQMusicAPI.canAppendPlaylistTracks(currentCount: 9_999, incomingCount: 1))
    }

    func testLikedSongsOnlyUseAuthenticatedDirectoryRoute() throws {
        let routes = try QQMusicAPI.playlistTrackRoutes(
            playlistID: 0, isLikedSongs: true, profileID: "12345", musicTicket: "fixture-ticket",
            encryptedHostUin: "fixture-encrypted-uin", offset: 100, pageSize: 100,
            expectedPlaylistCount: 215
        )
        XCTAssertEqual(routes.count, 1)
        let route = try XCTUnwrap(routes.first)
        XCTAssertTrue(route.authenticated)
        XCTAssertEqual(route.responseKey, "music.srfDissInfo.DissInfo")
        XCTAssertNil(route.payload["req_1"])
        let block = try XCTUnwrap(route.payload[route.responseKey] as? [String: Any])
        let param = try XCTUnwrap(block["param"] as? [String: Any])
        XCTAssertEqual(block["method"] as? String, "CgiGetDiss")
        XCTAssertEqual(param["disstid"] as? Int64, 0)
        XCTAssertEqual(param["dirid"] as? Int, 201)
        XCTAssertEqual(param["enc_host_uin"] as? String, "fixture-encrypted-uin")
        XCTAssertEqual(param["song_begin"] as? Int, 100)
        XCTAssertEqual(param["song_num"] as? Int, 100)
    }

    func testLikedSongsRejectMissingOrPlainAccountIdentifier() {
        for value in [nil, "", "   ", "12345"] as [String?] {
            XCTAssertThrowsError(try QQMusicAPI.playlistTrackRoutes(
                playlistID: 0, isLikedSongs: true, profileID: "12345", musicTicket: "fixture-ticket",
                encryptedHostUin: value, offset: 0, pageSize: 100, expectedPlaylistCount: 30
            ))
        }
    }

    func testEncryptedIdentifierComesFromSuccessfulProfileCreator() {
        XCTAssertEqual(QQMusicAPI.encryptedHostUin(in: [
            "code": 0, "data": ["creator": ["encrypt_uin": "fixture-encrypted-uin"]]
        ], profileID: "12345"), "fixture-encrypted-uin")
        XCTAssertNil(QQMusicAPI.encryptedHostUin(in: [
            "code": -100008, "data": ["creator": ["encrypt_uin": "fixture-encrypted-uin"]]
        ], profileID: "12345"))
        XCTAssertNil(QQMusicAPI.encryptedHostUin(in: [
            "code": 0, "data": ["creator": ["encrypt_uin": "12345"]]
        ], profileID: "12345"))
    }

    func testPublicPlaylistsKeepAnonymousLXFallbackAndAccountAlternative() throws {
        let routes = try QQMusicAPI.playlistTrackRoutes(
            playlistID: 9_712_417_906, isLikedSongs: false, profileID: "12345",
            musicTicket: "fixture-ticket", encryptedHostUin: nil,
            offset: 0, pageSize: 100, expectedPlaylistCount: 35
        )
        XCTAssertEqual(routes.map(\.authenticated), [false, true])
        XCTAssertEqual(routes.map(\.responseKey), ["req_1", "music.srfDissInfo.DissInfo"])
        let comm = try XCTUnwrap(routes[0].payload["comm"] as? [String: Any])
        XCTAssertNil(comm["authst"])
        XCTAssertEqual(comm["uin"] as? Int, 0)
    }

    func testAccountDirectoryIsNotMisidentifiedAsPublicDissID() throws {
        let directory = QQMusicAPI.mapPlaylist([
            "dirid": 206, "dissid": 0, "dirname": "本地上传", "songnum": 8
        ], kind: .created)
        XCTAssertEqual(directory.id, "qq-directory:206")
        XCTAssertEqual(QQMusicAPI.mapPlaylist(["dirid": 206, "id": 206], kind: .created).id,
                       "qq-directory:206")
        XCTAssertEqual(QQMusicAPI.mapPlaylist(["dirid": 0], kind: .created).id, "")
        let routes = try QQMusicAPI.playlistTrackRoutes(
            playlistID: 0, isLikedSongs: false, directoryID: 206,
            profileID: "12345", musicTicket: "fixture-ticket", encryptedHostUin: "fixture-euin",
            offset: 0, pageSize: 100, expectedPlaylistCount: 8
        )
        XCTAssertEqual(routes.count, 1)
        XCTAssertTrue(routes[0].authenticated)
        let block = try XCTUnwrap(routes[0].payload[routes[0].responseKey] as? [String: Any])
        let param = try XCTUnwrap(block["param"] as? [String: Any])
        XCTAssertEqual(param["dirid"] as? Int, 206)
        XCTAssertEqual(param["disstid"] as? Int64, 0)
        let published = QQMusicAPI.mapPlaylist([
            "dirid": 206, "dissid": "987654321", "dirname": "正常歌单"
        ], kind: .created)
        XCTAssertEqual(published.id, "987654321")
    }

    func testPlaylistScoped3a44DoesNotAbortRemainingPlaylistSync() {
        let error = QQMusicAPI.APIError.providerRejected("响应码 3a44")

        XCTAssertFalse(QQMusicPlaylistSyncPolicy.shouldStopAfterPlaylistFailure(error))
    }

    func testSessionCredentialFailureStopsRemainingPlaylistSync() {
        let error = QQMusicAPI.APIError.sessionCredentialRejected(
            "QQ 会话凭据未通过验证",
            ticketMissing: false
        )

        XCTAssertTrue(QQMusicPlaylistSyncPolicy.shouldStopAfterPlaylistFailure(error))
    }

    func testBareForbiddenResponseIsPlaylistScopedRatherThanLoginFailure() {
        XCTAssertFalse(QQMusicPlaylistErrorPolicy.isSessionCredentialFailure(
            statusCode: 403,
            diagnostic: "HTTP 403"
        ))
    }

    func testExplicitExpiredCookieResponseInvalidatesSession() {
        XCTAssertTrue(QQMusicPlaylistErrorPolicy.isSessionCredentialFailure(
            statusCode: 403,
            diagnostic: "cookie expired"
        ))
    }
}
