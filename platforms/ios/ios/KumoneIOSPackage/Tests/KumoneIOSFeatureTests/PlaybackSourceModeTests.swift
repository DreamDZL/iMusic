import XCTest
@testable import KumoneCore

final class PlaybackSourceModeTests: XCTestCase {
    func testOfficialModeRequiresAnAccountForTheCurrentTrackPlatform() {
        XCTAssertTrue(PlaybackResolutionPolicy.requiresOfficialAccount(
            mode: .official,
            hasMatchingAccount: false
        ))
        XCTAssertFalse(PlaybackResolutionPolicy.requiresOfficialAccount(
            mode: .official,
            hasMatchingAccount: true
        ))
    }

    func testOtherModesCanUseTheirOwnFallbackRulesWithoutAnOfficialAccount() {
        XCTAssertFalse(PlaybackResolutionPolicy.requiresOfficialAccount(
            mode: .automatic,
            hasMatchingAccount: false
        ))
        XCTAssertFalse(PlaybackResolutionPolicy.requiresOfficialAccount(
            mode: .thirdParty,
            hasMatchingAccount: false
        ))
    }
}
