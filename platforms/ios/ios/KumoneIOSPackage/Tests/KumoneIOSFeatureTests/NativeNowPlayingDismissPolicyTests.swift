import XCTest
@testable import KumoneCore

#if os(iOS)
import UIKit

final class NativeNowPlayingDismissPolicyTests: XCTestCase {
    private func accepts(_ translation: CGSize, _ predicted: CGSize) -> Bool {
        NativeNowPlayingDismissPolicy.shouldRequestDismiss(translation: translation, predicted: predicted)
    }

    func testFullDownwardPullRequestsTheSystemDismissal() {
        XCTAssertTrue(accepts(CGSize(width: 0, height: 260), CGSize(width: 0, height: 260)))
        XCTAssertTrue(accepts(CGSize(width: 10, height: 560), CGSize(width: 15, height: 700)))
    }

    func testSmallPullCannotDismissEvenWithLargeVelocityPrediction() {
        XCTAssertFalse(accepts(CGSize(width: 0, height: 25), CGSize(width: 0, height: 500)))
        XCTAssertFalse(accepts(.zero, CGSize(width: 0, height: 500)))
        XCTAssertFalse(accepts(CGSize(width: 0, height: 43), CGSize(width: 0, height: 500)))
    }

    func testDeliberateFlickNeedsDownwardTravelAndDirection() {
        XCTAssertTrue(accepts(CGSize(width: 0, height: 60), CGSize(width: 0, height: 250)))
        XCTAssertFalse(accepts(CGSize(width: 0, height: 60), CGSize(width: 400, height: 250)))
        XCTAssertFalse(accepts(CGSize(width: 0, height: 60), CGSize(width: 0, height: -250)))
    }

    func testUpwardHorizontalAndDiagonalDragsDoNotCloseThePlayer() {
        XCTAssertFalse(accepts(CGSize(width: 0, height: -300), CGSize(width: 0, height: -500)))
        XCTAssertFalse(accepts(CGSize(width: 300, height: 80), CGSize(width: 500, height: 200)))
        XCTAssertFalse(accepts(CGSize(width: 200, height: 200), CGSize(width: 400, height: 400)))
    }

    func testNonfiniteGeometryDoesNotRequestDismissal() {
        XCTAssertFalse(accepts(CGSize(width: CGFloat.nan, height: 300), CGSize(width: 0, height: 500)))
        XCTAssertFalse(accepts(CGSize(width: 0, height: 300), CGSize(width: 0, height: CGFloat.infinity)))
    }

    @MainActor
    func testSourceDoesNotRetainTheMiniPlayerView() {
        let source = NativeNowPlayingSource()
        var view: UIView? = UIView()
        source.view = view
        XCTAssertNotNil(source.view)
        view = nil
        XCTAssertNil(source.view)
    }
}
#endif
