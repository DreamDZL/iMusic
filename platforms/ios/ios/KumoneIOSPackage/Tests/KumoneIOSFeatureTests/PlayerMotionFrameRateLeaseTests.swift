import XCTest
@testable import KumoneCore

#if os(iOS)
@MainActor
final class PlayerMotionFrameRateLeaseTests: XCTestCase {
    func testProMotionRequestIsNotHardCappedAtSixty() {
        let range = PlayerMotionFrameRateLease.range(maximum: 120, lowPower: false, thermal: .nominal)
        XCTAssertEqual(range.minimum, 80)
        XCTAssertEqual(range.maximum, 120)
        XCTAssertEqual(range.preferred, 120)
    }

    func testSixtyHertzPanelIsRespected() {
        let range = PlayerMotionFrameRateLease.range(maximum: 60, lowPower: false, thermal: .nominal)
        XCTAssertEqual(range.minimum, 60)
        XCTAssertEqual(range.maximum, 60)
    }

    func testPowerAndThermalConstraintsRemainInEffect() {
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            let range = PlayerMotionFrameRateLease.range(maximum: 120, lowPower: true, thermal: state)
            XCTAssertEqual(range.preferred, 60)
        }
        XCTAssertEqual(PlayerMotionFrameRateLease.range(maximum: 120, lowPower: false,
                                                       thermal: .serious).maximum, 60)
    }
}
#endif
