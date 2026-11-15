import XCTest
@testable import KumoneCore

final class PlayerTrackSwipeTests: XCTestCase {
    func testLeftAdvancesAndRightSelectsPreviousTrack() {
        XCTAssertEqual(direction(-80, 2, -100), 1)
        XCTAssertEqual(direction(80, 2, 100), -1)
    }

    func testFlickRequiresRealHorizontalTravelAndSameDirection() {
        XCTAssertEqual(direction(-25, 2, -200), 1)
        XCTAssertNil(direction(-8, 0, -300))
        XCTAssertNil(direction(-25, 2, 200))
        XCTAssertNil(direction(30, 50, 300))
        XCTAssertNil(direction(.nan, 0, 200))
        XCTAssertNil(direction(80, 0, .infinity))
    }

    func testVerticalGestureCannotTurnIntoTrackSwipe() {
        var session = PlayerTrackSwipeSession(revision: 1)
        session.update(translation: CGSize(width: 4, height: 20))
        session.update(translation: CGSize(width: -100, height: 22))
        XCTAssertNil(session.direction(translation: CGSize(width: -100, height: 22), predicted: CGSize(width: -200, height: 22), currentRevision: 1))
    }

    func testTrackOrPageRevisionInvalidatesInFlightSwipeIncludingABA() {
        var session = PlayerTrackSwipeSession(revision: 4)
        session.update(translation: CGSize(width: -80, height: 0))
        let translation = CGSize(width: -80, height: 0)
        XCTAssertNil(session.direction(translation: translation, predicted: translation, currentRevision: 5))
        session.isInvalidated = true
        XCTAssertNil(session.direction(translation: translation, predicted: translation, currentRevision: 4))
    }

    func testTitleLanesKeepAConstantGutterForBothSwipeDirections() {
        let width: CGFloat = 240
        let gap: CGFloat = 36

        let next = TrackTitleSwipeLayout(width: width, gap: gap, direction: 1, translation: -72)
        let nextTitleX = width + gap + next.stripOffset
        XCTAssertEqual(nextTitleX - next.stripOffset, width + gap)

        let previous = TrackTitleSwipeLayout(width: width, gap: gap, direction: -1, translation: 72)
        let previousTitleX = previous.stripOffset
        let currentTitleX = width + gap + previous.stripOffset
        XCTAssertEqual(currentTitleX - previousTitleX, width + gap)
        XCTAssertEqual(currentTitleX, 72)
    }

    private func direction(_ x: CGFloat, _ y: CGFloat, _ predicted: CGFloat) -> Int? {
        PlayerTrackSwipePolicy.direction(translation: CGSize(width: x, height: y), predicted: CGSize(width: predicted, height: y))
    }
}
