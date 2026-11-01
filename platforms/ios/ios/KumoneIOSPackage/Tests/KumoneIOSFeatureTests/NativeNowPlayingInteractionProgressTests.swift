import XCTest
@testable import KumoneCore

#if os(iOS)
final class NativeNowPlayingInteractionProgressTests: XCTestCase {
    func testPullContinuouslyAdvancesBeforeTheDismissThreshold() {
        let short = NativeNowPlayingDismissPolicy.interactiveProgress(translation: 25, height: 800)
        let medium = NativeNowPlayingDismissPolicy.interactiveProgress(translation: 100, height: 800)
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(medium, short)
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldRequestDismiss(
            translation: CGSize(width: 0, height: 25), predicted: CGSize(width: 0, height: 500)
        ))
    }

    func testDraggingBackUpReversesProgressInsteadOfCommitting() {
        let down = NativeNowPlayingDismissPolicy.interactiveProgress(translation: 260, height: 800)
        let returned = NativeNowPlayingDismissPolicy.interactiveProgress(translation: 25, height: 800)
        XCTAssertLessThan(returned, down)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: 0, height: 800), 0)
    }

    func testFullPullCommitsWithoutATapOnTheGrabber() {
        XCTAssertTrue(NativeNowPlayingDismissPolicy.shouldRequestDismiss(
            translation: CGSize(width: 0, height: 260), predicted: CGSize(width: 0, height: 260)
        ))
    }

    func testProgressIsBoundedAndRejectsInvalidGeometry() {
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: -20, height: 800), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: 2000, height: 800), 1)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: 20, height: 0), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: .nan, height: 800), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: 20, height: .infinity), 0)
    }

    func testBindingOnlyClosesAfterAnUninterruptedCompletedUserDismissal() {
        XCTAssertTrue(NativeNowPlayingDismissPolicy.shouldCloseBinding(
            completed: true, active: true, requestedDismissal: false,
            dismissalRevision: 4, currentRevision: 4
        ))
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldCloseBinding(
            completed: false, active: true, requestedDismissal: false,
            dismissalRevision: 4, currentRevision: 4
        ))
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldCloseBinding(
            completed: true, active: true, requestedDismissal: false,
            dismissalRevision: 4, currentRevision: 6
        ))
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldCloseBinding(
            completed: true, active: false, requestedDismissal: false,
            dismissalRevision: 4, currentRevision: 4
        ))
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldCloseBinding(
            completed: true, active: true, requestedDismissal: true,
            dismissalRevision: 4, currentRevision: 4
        ))
    }
}
#endif
