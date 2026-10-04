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
