import XCTest
@testable import KumoneCore

#if os(iOS)
final class NowPlayingPresentationMetricsTests: XCTestCase {
    private let uiTesting = "-imusic-ui-testing"
    private let playerFixture = "-imusic-ui-player-fixture"
    private let extendedLyricsControls = "-imusic-ui-extended-lyrics-controls"

    func testLyricsControlsAutoHideDefaultTimingIsThreeSeconds() {
        XCTAssertEqual(
            NowPlayingPresentationMetrics.lyricsControlsAutoHideDelay,
            .seconds(3)
        )
    }

    func testLyricsControlsAutoHideRequiresEveryDebugFixtureArgument() {
        let required = [uiTesting, playerFixture, extendedLyricsControls]

        for mask in 0..<(1 << required.count) {
            let arguments = required.enumerated().compactMap { index, argument in
                mask & (1 << index) == 0 ? nil : argument
            }
            let expected: Duration
            #if DEBUG
            expected = mask == (1 << required.count) - 1 ? .seconds(12) : .seconds(3)
            #else
            expected = .seconds(3)
            #endif

            XCTAssertEqual(
                NowPlayingPresentationMetrics.lyricsControlsAutoHideDelay(arguments: arguments),
                expected,
                "Unexpected auto-hide delay for argument combination mask \(mask)"
            )
        }
    }

    func testMiniPlayerSwipeRequiresHorizontalIntent() {
        XCTAssertEqual(
            MiniPlayerSwipePolicy.trackDirection(
                translation: CGSize(width: -80, height: 8),
                predictedTranslation: CGSize(width: -100, height: 10)
            ),
            -1
        )
        XCTAssertNil(
            MiniPlayerSwipePolicy.trackDirection(
                translation: CGSize(width: -30, height: -40),
                predictedTranslation: CGSize(width: -120, height: -100)
            )
        )
    }
}
#endif
