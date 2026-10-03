import XCTest
@testable import KumoneCore

final class QQMusicAccountRequestEnvelopeTests: XCTestCase {
    func testAuthenticatedPlaylistEnvelopeUsesTicketBearingQQClientMode() {
        let common = QQMusicAccountRequestEnvelope.common(
            userID: "123456789",
            musicTicket: "private-test-ticket"
        )

        XCTAssertEqual(common["uin"] as? String, "123456789")
        XCTAssertEqual(common["format"] as? String, "json")
        XCTAssertEqual(common["ct"] as? Int, 19)
        XCTAssertEqual(common["cv"] as? Int, 0)
        XCTAssertEqual(common["authst"] as? String, "private-test-ticket")
        XCTAssertNil(common["platform"])
        XCTAssertNil(common["g_tk"])
    }
}
