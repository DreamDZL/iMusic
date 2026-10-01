import XCTest
@testable import KumoneCore

final class RenderingBudgetTests: XCTestCase {
    func testNormalPlaybackUsesThirtyFrameVisualBudget() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .nominal),
            1.0 / 30.0,
            accuracy: 0.0001
        )
    }

    func testLowPowerModeAndFairThermalStateReduceVisualRefreshRate() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: true, thermalState: .nominal),
            1.0 / 15.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .fair),
            1.0 / 15.0,
            accuracy: 0.0001
        )
    }

    func testSeriousThermalStateUsesLowestVisualRefreshRate() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .serious),
            1.0 / 10.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: true, thermalState: .critical),
            1.0 / 10.0,
            accuracy: 0.0001
        )
    }
}
