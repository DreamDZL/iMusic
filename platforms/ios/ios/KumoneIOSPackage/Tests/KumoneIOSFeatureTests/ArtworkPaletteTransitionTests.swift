import XCTest
import SwiftUI
@testable import KumoneCore

@MainActor
final class ArtworkPaletteTransitionTests: XCTestCase {
    func testRapidTrackChangeContinuesFromCurrentlyDisplayedPalette() {
        var transition = ArtworkPaletteTransition()
        let second = palette(.red, .orange)
        let third = palette(.blue, .cyan)

        transition.transition(to: second, at: 100, allowsAnimation: true)
        let halfwayThroughSecond = transition.displayedColors(at: 100.4)
        XCTAssertGreaterThan(paletteDistance(halfwayThroughSecond, second), 0.01)

        transition.transition(to: third, at: 100.4, allowsAnimation: true)

        XCTAssertLessThan(paletteDistance(transition.displayedColors(at: 100.4), halfwayThroughSecond), 0.000_001)
        XCTAssertLessThan(paletteDistance(transition.displayedColors(at: 101.2), third), 0.000_001)
    }

    func testReducedMotionUsesTheNewPaletteImmediately() {
        var transition = ArtworkPaletteTransition()
        let next = palette(.green, .mint)

        transition.transition(to: next, at: 5, allowsAnimation: false)

        XCTAssertFalse(transition.isTransitioning)
        XCTAssertLessThan(paletteDistance(transition.displayedColors(at: 5), next), 0.000_001)
    }

    func testStaleCompletionCannotFinishANewerTransition() {
        var transition = ArtworkPaletteTransition()
        transition.transition(to: palette(.red, .orange), at: 0, allowsAnimation: true)
        let staleRevision = transition.revision
        transition.transition(to: palette(.blue, .cyan), at: 0.2, allowsAnimation: true)

        transition.finishTransition(revision: staleRevision)

        XCTAssertTrue(transition.isTransitioning)
        XCTAssertEqual(transition.revision, staleRevision + 1)
    }

    func testRepeatedRapidSkipsKeepOneStableTransitionAndLatestTarget() {
        var transition = ArtworkPaletteTransition()

        for index in 0..<40 {
            let instant = Double(index) * 0.05
            let next = palette(
                Color(hue: Double(index) / 40, saturation: 0.7, brightness: 0.48),
                .black
            )
            let visibleBeforeSkip = transition.displayedColors(at: instant)

            transition.transition(to: next, at: instant, allowsAnimation: true)

            XCTAssertLessThan(paletteDistance(transition.displayedColors(at: instant), visibleBeforeSkip), 0.000_001)
            XCTAssertLessThan(paletteDistance(
                transition.displayedColors(at: instant + ArtworkPaletteTransition.duration), next
            ), 0.000_001)
        }
    }

    private func paletteDistance(_ lhs: ArtworkColors, _ rhs: ArtworkColors) -> Double {
        colorDistance(lhs.primary, rhs.primary) + colorDistance(lhs.secondary, rhs.secondary)
    }

    private func colorDistance(_ lhs: Color, _ rhs: Color) -> Double {
        let environment = EnvironmentValues()
        let lhs = lhs.resolve(in: environment)
        let rhs = rhs.resolve(in: environment)
        return abs(Double(lhs.linearRed - rhs.linearRed))
            + abs(Double(lhs.linearGreen - rhs.linearGreen))
            + abs(Double(lhs.linearBlue - rhs.linearBlue))
            + abs(Double(lhs.opacity - rhs.opacity))
    }

    private func palette(_ primary: Color, _ secondary: Color) -> ArtworkColors {
        ArtworkColors(primary: primary, secondary: secondary)
    }
}
