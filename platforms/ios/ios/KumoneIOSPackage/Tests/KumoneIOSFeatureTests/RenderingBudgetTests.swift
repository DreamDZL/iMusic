import XCTest
@testable import KumoneCore

final class RenderingBudgetTests: XCTestCase {
    func testNormalPlaybackUsesTwentyFourFrameVisualBudget() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .nominal),
            1.0 / 24.0,
            accuracy: 0.0001
        )
    }

    func testLowPowerModeAndFairThermalStateReduceVisualRefreshRate() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: true, thermalState: .nominal),
            1.0 / 12.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .fair),
            1.0 / 12.0,
            accuracy: 0.0001
        )
    }

    func testSeriousAndCriticalThermalStatesUseProgressivelyLowerVisualRefreshRates() {
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: false, thermalState: .serious),
            1.0 / 8.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            RenderingBudget.interval(lowPowerMode: true, thermalState: .critical),
            1.0 / 6.0,
            accuracy: 0.0001
        )
    }

    func testAudioAnalysisStrideGrowsWhenPowerOrThermalBudgetIsConstrained() {
        XCTAssertEqual(
            RenderingBudget.audioStride(lowPowerMode: false, thermalState: .nominal),
            4
        )
        XCTAssertEqual(
            RenderingBudget.audioStride(lowPowerMode: true, thermalState: .nominal),
            6
        )
        XCTAssertEqual(
            RenderingBudget.audioStride(lowPowerMode: false, thermalState: .fair),
            6
        )
        XCTAssertEqual(
            RenderingBudget.audioStride(lowPowerMode: false, thermalState: .serious),
            12
        )
        XCTAssertEqual(
            RenderingBudget.audioStride(lowPowerMode: true, thermalState: .critical),
            12
        )
    }

    func testContinuousDecorativeEffectsStopWhenPowerOrThermalBudgetIsConstrained() {
        XCTAssertTrue(
            RenderingBudget.permitsContinuousEffects(lowPowerMode: false, thermalState: .nominal)
        )
        XCTAssertFalse(
            RenderingBudget.permitsContinuousEffects(lowPowerMode: true, thermalState: .nominal)
        )
        XCTAssertFalse(
            RenderingBudget.permitsContinuousEffects(lowPowerMode: false, thermalState: .fair)
        )
        XCTAssertFalse(
            RenderingBudget.permitsContinuousEffects(lowPowerMode: false, thermalState: .serious)
        )
    }

    func testAudioAnalysisStopsWhenSceneOrPowerBudgetDoesNotPermitVisualEffects() {
        XCTAssertTrue(RenderingBudget.permitsAudioAnalysis(
            isSceneActive: true,
            lowPowerMode: false,
            thermalState: .nominal
        ))
        XCTAssertFalse(RenderingBudget.permitsAudioAnalysis(
            isSceneActive: false,
            lowPowerMode: false,
            thermalState: .nominal
        ))
        XCTAssertFalse(RenderingBudget.permitsAudioAnalysis(
            isSceneActive: true,
            lowPowerMode: true,
            thermalState: .nominal
        ))
        XCTAssertFalse(RenderingBudget.permitsAudioAnalysis(
            isSceneActive: true,
            lowPowerMode: false,
            thermalState: .fair
        ))
        XCTAssertFalse(RenderingBudget.permitsAudioAnalysis(
            isSceneActive: true,
            lowPowerMode: false,
            thermalState: .critical
        ))
    }

    func testPlaybackProgressObserverSlowsDuringBackgroundAudio() {
        XCTAssertEqual(
            PlayerService.playbackTimeObserverInterval(isSceneActive: true),
            0.2,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlayerService.playbackTimeObserverInterval(isSceneActive: false),
            1.0,
            accuracy: 0.0001
        )
    }
}
