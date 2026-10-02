import XCTest
@testable import KumoneCore

final class PausedPlaybackStateTests: XCTestCase {
    func testResolutionFailurePausesSystemPlaybackAndPreservesProgress() {
        let state = PausedPlaybackState(elapsed: 42.5)

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.nowPlayingRate, 0)
        XCTAssertEqual(state.elapsed, 42.5)
        XCTAssertFalse(state.preservesCurrentItemForRetry)
    }

    func testRecoverableStartFailureCanPreserveSpectrumTapForRetry() {
        let state = PausedPlaybackState(elapsed: 42.5, preservingCurrentItemForRetry: true)

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.nowPlayingRate, 0)
        XCTAssertEqual(state.elapsed, 42.5)
        XCTAssertTrue(state.preservesCurrentItemForRetry)
    }

    func testResolutionFailureNormalizesInvalidProgress() {
        XCTAssertEqual(PausedPlaybackState(elapsed: -5).elapsed, 0)
        XCTAssertEqual(PausedPlaybackState(elapsed: .infinity).elapsed, 0)
        XCTAssertEqual(PausedPlaybackState(elapsed: .nan).elapsed, 0)
    }
}

@MainActor
final class AudioSpectrumPauseTests: XCTestCase {
    func testResetKeepsRenderingModeForTheCurrentItem() {
        let spectrum = AudioSpectrum.shared
        spectrum.beginPreparing()
        spectrum.markUntappable()
        defer { spectrum.markIdle() }

        spectrum.reset()

        if case .untappable = spectrum.tapState {
            // Expected: the same ready item can resume after audio-session retry.
        } else {
            XCTFail("Reset must keep the rendering mode for a resumable item")
        }
    }
}
