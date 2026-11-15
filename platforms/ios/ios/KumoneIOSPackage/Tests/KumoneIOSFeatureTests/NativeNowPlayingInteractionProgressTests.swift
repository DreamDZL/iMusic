import XCTest
@testable import KumoneCore

#if os(iOS)
import UIKit

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

    func testFingerFollowOffsetIsOneToOneBeforeCommitAndReturnsToRest() {
        for distance in [CGFloat(14), 25, 60, 100, 260] {
            XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: distance, height: 800), distance)
        }
        // Cancellation uses zero travel/prediction, never the last fling's
        // velocity. The same presentation must return to identity and stay open.
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: 0, height: 800), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveProgress(translation: 0, height: 800), 0)
        XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldRequestDismiss(translation: .zero, predicted: .zero))
    }

    func testFingerFollowOffsetClampsOverscrollAndRejectsInvalidGeometry() {
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: 2000, height: 800), 600)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: -20, height: 800), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: .nan, height: 800), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: 20, height: .infinity), 0)
        XCTAssertEqual(NativeNowPlayingDismissPolicy.interactiveOffset(translation: 20, height: 0), 0)
    }

    func testUIKitPanDoesNotClaimHorizontalPageSwipesOrUpwardMotion() {
        XCTAssertTrue(NativeNowPlayingDismissPolicy.shouldBeginPan(velocity: CGPoint(x: 20, y: 200)))
        for velocity in [CGPoint(x: 200, y: 20), CGPoint(x: -200, y: 20),
                         CGPoint(x: 100, y: 100), CGPoint(x: 0, y: -200), .zero,
                         CGPoint(x: CGFloat.nan, y: 200), CGPoint(x: 0, y: CGFloat.infinity)] {
            XCTAssertFalse(NativeNowPlayingDismissPolicy.shouldBeginPan(velocity: velocity))
        }
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

    func testCollapseScaleIsMonotonicBoundedAndVisibleBeforeRelease() throws {
        let geometry = try portraitCollapse()
        let end = geometry.pose(translation: geometry.travel)
        var previous: CGFloat = 1
        for distance in stride(from: 0, through: 1400, by: 7) {
            let pose = geometry.pose(translation: CGFloat(distance))
            XCTAssertLessThanOrEqual(pose.scale, previous + 0.000001)
            XCTAssertGreaterThanOrEqual(pose.scale, end.scale - 0.000001)
            XCTAssertGreaterThan(pose.scale, 0)
            XCTAssertTrue(pose.offset.x.isFinite && pose.offset.y.isFinite)
            XCTAssertEqual(pose.transform.a, pose.transform.d)
            XCTAssertEqual(pose.transform.b, 0)
            XCTAssertEqual(pose.transform.c, 0)
            previous = pose.scale
        }
        // A 100pt pull used to shrink by only a few percent. This is a real
        // interactive zoom, independent of the older policy's progress cap.
        XCTAssertLessThan(geometry.pose(translation: 100).scale, 0.9)
        XCTAssertLessThan(geometry.pose(translation: 260).scale, 0.75)
        XCTAssertEqual(geometry.pose(translation: 1400).transform, end.transform)
    }

    func testUpperTouchPointFollowsFingerWhileScalingTowardMiniPlayer() throws {
        let grip: CGFloat = 80
        let geometry = try portraitCollapse(grabY: grip)
        for distance in [CGFloat(0), 25, 100, 260] {
            let pose = geometry.pose(translation: distance)
            let contactY = geometry.baseFrame.midY + pose.offset.y
                + (grip - geometry.baseFrame.midY) * pose.scale
            XCTAssertEqual(contactY, grip + distance, accuracy: 0.00001)
        }
        let end = geometry.pose(translation: geometry.travel)
        XCTAssertEqual(geometry.baseFrame.midX + end.offset.x, geometry.targetFrame.midX, accuracy: 0.00001)
        XCTAssertEqual(geometry.baseFrame.midY + end.offset.y, geometry.targetFrame.midY, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(geometry.baseFrame.width * end.scale, geometry.targetFrame.width + 0.00001)
        XCTAssertLessThanOrEqual(geometry.baseFrame.height * end.scale, geometry.targetFrame.height + 0.00001)
    }

    func testReturningFingerUpRestoresExactPoseWithoutAccumulatedDrift() throws {
        let geometry = try portraitCollapse()
        let initial = geometry.pose(translation: 25)
        for distance in [CGFloat(300), 60, 400, 25, 0, 260, 25] {
            _ = geometry.pose(translation: distance)
        }
        XCTAssertEqual(geometry.pose(translation: 25).transform, initial.transform)
        XCTAssertEqual(geometry.pose(translation: 0).transform, .identity)
        XCTAssertEqual(geometry.pose(translation: -20).transform, .identity)
        XCTAssertEqual(geometry.pose(translation: .nan).transform, .identity)
        XCTAssertEqual(geometry.pose(translation: .infinity).transform, .identity)
    }

    func testRegrabbingAReboundStartsFromLiveTransformInsteadOfJumpingToIdentity() throws {
        let original = try portraitCollapse(grabY: 80)
        let live = original.pose(translation: 140)
        let geometry = try portraitCollapse(grabY: 220, initialTransform: live.transform)
        let zero = geometry.pose(translation: 0)
        XCTAssertEqual(zero.scale, live.scale, accuracy: 0.00001)
        XCTAssertEqual(zero.offset.x, live.offset.x, accuracy: 0.00001)
        XCTAssertEqual(zero.offset.y, live.offset.y, accuracy: 0.00001)
        let next = geometry.pose(translation: 25)
        XCTAssertLessThan(next.scale, zero.scale)
        let originalGrip = (220 - original.baseFrame.midY - live.offset.y) / live.scale
        let movedGrip = geometry.baseFrame.midY + next.offset.y + originalGrip * next.scale
        XCTAssertEqual(movedGrip, 245, accuracy: 0.00001)
    }

    func testTransientMissingOrInvalidMiniAnchorsUseSameVisibleFallback() throws {
        let base = CGRect(x: 0, y: 0, width: 390, height: 800)
        let invalid: [CGRect?] = [nil, .zero,
            CGRect(x: 12, y: 700, width: 0, height: 64),
            CGRect(x: 12, y: 700, width: 366, height: 1),
            CGRect(x: 12, y: 900, width: 366, height: 64),
            CGRect(x: 12, y: 700, width: 800, height: 64),
            CGRect(x: 12, y: 40, width: 366, height: 64), base,
            CGRect(x: CGFloat.nan, y: 700, width: 366, height: 64),
            CGRect(x: 12, y: 700, width: CGFloat.infinity, height: 64)]
        let fallback = try XCTUnwrap(PlayerCollapseGeometry(baseFrame: base, viewport: base, sourceFrame: nil))
        for source in invalid {
            let geometry = try XCTUnwrap(PlayerCollapseGeometry(baseFrame: base, viewport: base, sourceFrame: source))
            XCTAssertTrue(geometry.usesFallback)
            XCTAssertEqual(geometry.targetFrame, fallback.targetFrame)
            XCTAssertTrue(base.contains(geometry.targetFrame))
            XCTAssertTrue(geometry.pose(translation: 260).scale.isFinite)
        }
    }

    func testLandscapeAndOffsetViewportKeepAnAspectPreservingInWindowLanding() throws {
        let viewport = CGRect(x: 20, y: 30, width: 844, height: 390)
        let source = CGRect(x: 100, y: 320, width: 650, height: 50)
        let geometry = try XCTUnwrap(PlayerCollapseGeometry(baseFrame: viewport, viewport: viewport, sourceFrame: source))
        XCTAssertFalse(geometry.usesFallback)
        XCTAssertEqual(geometry.targetFrame, source)
        let end = geometry.pose(translation: 1000)
        XCTAssertEqual(end.transform.a, end.transform.d)
        XCTAssertEqual(viewport.midX + end.offset.x, source.midX, accuracy: 0.00001)
        XCTAssertEqual(viewport.midY + end.offset.y, source.midY, accuracy: 0.00001)
        XCTAssertEqual(viewport.height * end.scale, source.height, accuracy: 0.00001)
        // A stale portrait anchor cannot send a rotated card outside its window.
        let stale = try XCTUnwrap(PlayerCollapseGeometry(baseFrame: viewport, viewport: viewport,
            sourceFrame: CGRect(x: 12, y: 700, width: 366, height: 64)))
        XCTAssertTrue(stale.usesFallback)
        XCTAssertTrue(viewport.contains(stale.targetFrame))
    }

    func testInvalidBaseGeometryAndNonUniformInitialTransformsAreRejectedSafely() throws {
        let base = CGRect(x: 0, y: 0, width: 390, height: 800)
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: 390, height: 0),
                        CGRect(x: CGFloat.nan, y: 0, width: 390, height: 800),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800),
                        CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 800)] {
            XCTAssertNil(PlayerCollapseGeometry(baseFrame: invalid, viewport: base, sourceFrame: nil))
            XCTAssertNil(PlayerCollapseGeometry(baseFrame: base, viewport: invalid, sourceFrame: nil))
        }
        for transform in [CGAffineTransform(scaleX: 0.5, y: 0.8),
                          CGAffineTransform(rotationAngle: 0.1),
                          CGAffineTransform(translationX: CGFloat.nan, y: 0),
                          CGAffineTransform(translationX: 0, y: CGFloat.greatestFiniteMagnitude)] {
            let geometry = try portraitCollapse(initialTransform: transform)
            XCTAssertEqual(geometry.pose(translation: 0).transform, .identity)
        }
    }

    func testReduceMotionDisablesInteractiveZoomAndBoundsSpatialTravel() throws {
        let geometry = try portraitCollapse()
        for distance in [CGFloat(0), 25, 100, 260, 2000] {
            let pose = geometry.pose(translation: distance, reduceMotion: true)
            XCTAssertEqual(pose.scale, 1)
            XCTAssertEqual(pose.offset.x, 0)
            XCTAssertGreaterThanOrEqual(pose.offset.y, 0)
            XCTAssertLessThanOrEqual(pose.offset.y, 24)
        }
        XCTAssertEqual(geometry.pose(translation: 0, reduceMotion: true).transform, .identity)
        XCTAssertEqual(geometry.collapsedTransform(reduceMotion: true), CGAffineTransform(translationX: 0, y: 24))
    }

    func testStableBaseFrameUsesBoundsAndCenterNotTheTransformedFrame() throws {
        let frame = try XCTUnwrap(PlayerCollapseGeometry.untransformedFrame(
            bounds: CGRect(x: 17, y: 23, width: 390, height: 800), center: CGPoint(x: 215, y: 430)))
        XCTAssertEqual(frame, CGRect(x: 20, y: 30, width: 390, height: 800))
        XCTAssertNil(PlayerCollapseGeometry.untransformedFrame(bounds: .zero, center: .zero))
        XCTAssertNil(PlayerCollapseGeometry.untransformedFrame(bounds: frame, center: CGPoint(x: CGFloat.nan, y: 430)))
    }

    func testFrozenGeometryMustBeCancelledWhenWindowOrLayoutChanges() throws {
        let geometry = try portraitCollapse()
        let base = geometry.baseFrame
        XCTAssertTrue(geometry.canContinue(baseFrame: base, viewport: geometry.viewport))
        XCTAssertTrue(geometry.canContinue(baseFrame: base.offsetBy(dx: 0.1, dy: 0.1), viewport: geometry.viewport))
        XCTAssertFalse(geometry.canContinue(baseFrame: base.offsetBy(dx: 0, dy: 20), viewport: geometry.viewport))
        XCTAssertFalse(geometry.canContinue(baseFrame: CGRect(x: 0, y: 0, width: 800, height: 390), viewport: geometry.viewport))
        XCTAssertFalse(geometry.canContinue(baseFrame: base, viewport: CGRect(x: 0, y: 0, width: 800, height: 390)))
        XCTAssertFalse(geometry.canContinue(baseFrame: .zero, viewport: geometry.viewport))
    }

    @MainActor
    func testWindowAndScaledContainerTransformConversionDoesNotAccumulateOffset() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let container = UIView(frame: CGRect(x: 20, y: 30, width: 350, height: 740))
        window.addSubview(container)
        container.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        let local = CGAffineTransform(translationX: 20, y: 40).scaledBy(x: 0.7, y: 0.7)
        let converted = try XCTUnwrap(NativeNowPlayingCoordinates.transform(local, from: container, to: window))
        XCTAssertEqual(converted.tx, 16, accuracy: 0.00001)
        XCTAssertEqual(converted.ty, 32, accuracy: 0.00001)
        XCTAssertEqual(converted.a, 0.7, accuracy: 0.00001)
        let returned = try XCTUnwrap(NativeNowPlayingCoordinates.transform(converted, from: window, to: container))
        XCTAssertEqual(returned.tx, local.tx, accuracy: 0.00001)
        XCTAssertEqual(returned.ty, local.ty, accuracy: 0.00001)
        XCTAssertEqual(returned.a, local.a, accuracy: 0.00001)
        let otherWindow = UIWindow(frame: window.bounds)
        XCTAssertNil(NativeNowPlayingCoordinates.transform(local, from: container, to: otherWindow))
        XCTAssertNil(NativeNowPlayingCoordinates.transform(CGAffineTransform(scaleX: 0.7, y: 0.8), from: container, to: window))
    }

    @MainActor
    func testAnchorConversionUsesOnlyCommonWindowAndFreezesTheGestureTarget() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let library = UIView(frame: window.bounds)
        let container = UIView(frame: CGRect(x: 20, y: 30, width: 350, height: 740))
        window.addSubview(library)
        window.addSubview(container)
        let marker = UIView(frame: CGRect(x: 12, y: 700, width: 366, height: 64))
        library.addSubview(marker)
        marker.bounds.origin = CGPoint(x: 5, y: 7)
        let source = NativeNowPlayingSource()
        source.view = marker
        XCTAssertEqual(source.frame(in: container), CGRect(x: -8, y: 670, width: 366, height: 64))
        let geometry = try XCTUnwrap(PlayerCollapseGeometry(baseFrame: window.bounds, viewport: window.bounds,
                                                           sourceFrame: source.frame(in: window)))
        let frozen = geometry.pose(translation: 100).transform
        marker.frame = .zero
        source.view = nil
        XCTAssertEqual(geometry.targetFrame, CGRect(x: 12, y: 700, width: 366, height: 64))
        XCTAssertEqual(geometry.pose(translation: 100).transform, frozen)
        source.view = marker
        let otherWindow = UIWindow(frame: window.bounds)
        XCTAssertNil(source.frame(in: otherWindow))
        marker.removeFromSuperview()
        XCTAssertNil(source.frame(in: container))
    }

    private func portraitCollapse(grabY: CGFloat? = nil,
                                  initialTransform: CGAffineTransform = .identity) throws -> PlayerCollapseGeometry {
        let base = CGRect(x: 0, y: 0, width: 390, height: 800)
        return try XCTUnwrap(PlayerCollapseGeometry(baseFrame: base, viewport: base,
            sourceFrame: CGRect(x: 12, y: 700, width: 366, height: 64),
            grabY: grabY, initialTransform: initialTransform))
    }
}
#endif
