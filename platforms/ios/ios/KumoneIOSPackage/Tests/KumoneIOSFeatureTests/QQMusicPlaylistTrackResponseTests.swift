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
