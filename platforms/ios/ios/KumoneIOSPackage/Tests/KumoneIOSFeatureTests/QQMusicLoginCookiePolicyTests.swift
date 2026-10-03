import XCTest
@testable import KumoneCore

final class QQMusicLoginCookiePolicyTests: XCTestCase {
    func testGenericQQWebCookieDoesNotCountAsMusicLogin() {
        XCTAssertFalse(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=o123456; p_skey=qq-session")
        )
        XCTAssertFalse(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=123456; skey=qq-session")
        )
    }

    func testQQMusicTicketAndNumericAccountIdentifierAreRequired() {
        XCTAssertTrue(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=o123456; qm_keyst=music-ticket")
        )
        XCTAssertTrue(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("wxuin=987654; QQMusic_Key=music-ticket")
        )
        XCTAssertFalse(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=0; qm_keyst=music-ticket")
        )
        XCTAssertFalse(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=not-a-number; qqmusic_key=music-ticket")
        )
        XCTAssertFalse(
            QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie("uin=o123456; qm_keyst=; p_skey=qq-session")
        )
    }
}
