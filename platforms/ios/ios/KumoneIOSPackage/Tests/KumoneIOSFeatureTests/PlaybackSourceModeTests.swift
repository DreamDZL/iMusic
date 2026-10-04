import XCTest
@testable import KumoneCore

final class PlaybackSourceModeTests: XCTestCase {
    func testOnlyThirdPartyAudioModeIsSupported() {
        XCTAssertEqual(PlaybackSourceMode.allCases, [.thirdParty])
        XCTAssertNil(PlaybackSourceMode(rawValue: "official"))
        XCTAssertNil(PlaybackSourceMode(rawValue: "automatic"))
        XCTAssertEqual(PlaybackSourceMode(rawValue: "thirdParty"), .thirdParty)
    }
}
