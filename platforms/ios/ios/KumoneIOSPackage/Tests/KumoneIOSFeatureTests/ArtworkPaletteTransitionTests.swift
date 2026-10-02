import XCTest
import SwiftUI
@testable import KumoneCore

@MainActor
final class ArtworkPaletteTransitionTests: XCTestCase {
    func testRapidTrackChangeStartsFromTheCurrentlyVisibleMixture() {
        var transition = ArtworkPaletteTransition()
        let firstLayer = transition.visibleLayers(at: 100).first!
        let second = palette(.red, .orange)
        let third = palette(.blue, .cyan)

        transition.transition(to: second, at: 100, allowsAnimation: true)
        let halfwayThroughSecond = transition.visibleLayers(at: 100.4)
        XCTAssertEqual(halfwayThroughSecond.count, 2)
        XCTAssertEqual(totalWeight(halfwayThroughSecond), 1, accuracy: 0.000_001)

        let visibleWeights = Dictionary(uniqueKeysWithValues: halfwayThroughSecond.map { ($0.id, $0.weight) })
        let secondLayerID = transition.currentLayerID
        transition.transition(to: third, at: 100.4, allowsAnimation: true)

        let immediatelyAfterSkip = transition.visibleLayers(at: 100.4)
        XCTAssertEqual(Set(immediatelyAfterSkip.map(\.id)), Set(visibleWeights.keys))
        for layer in immediatelyAfterSkip {
            XCTAssertEqual(layer.weight, visibleWeights[layer.id]!, accuracy: 0.000_001)
        }

        let halfwayThroughThird = transition.visibleLayers(at: 100.8)
        XCTAssertEqual(halfwayThroughThird.count, 3)
        XCTAssertEqual(halfwayThroughThird.first { $0.id == firstLayer.id }?.weight ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(halfwayThroughThird.first { $0.id == secondLayerID }?.weight ?? -1, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(halfwayThroughThird.first { $0.id == transition.currentLayerID }?.weight ?? -1, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(totalWeight(halfwayThroughThird), 1, accuracy: 0.000_001)
    }

    func testReducedMotionUsesTheNewPaletteImmediately() {
        var transition = ArtworkPaletteTransition()
        let next = palette(.green, .mint)

        transition.transition(to: next, at: 5, allowsAnimation: false)

        XCTAssertFalse(transition.isTransitioning)
        let layers = transition.visibleLayers(at: 5)
        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].id, transition.currentLayerID)
        XCTAssertEqual(layers[0].weight, 1, accuracy: 0.000_001)
        XCTAssertEqual(layers[0].colors, next)
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

    func testRapidTransitionsKeepAStableBoundedLayerSetAndNormalizedWeights() {
        var transition = ArtworkPaletteTransition()

        for index in 0..<40 {
            let instant = Double(index) * 0.4
            transition.transition(
                to: palette(Color(hue: Double(index) / 40, saturation: 0.7, brightness: 0.48), .black),
                at: instant,
                allowsAnimation: true
            )
            let sampleTime = instant + 0.4
            let layers = transition.visibleLayers(at: sampleTime)
            let repeatedSample = transition.visibleLayers(at: sampleTime)

            XCTAssertLessThanOrEqual(layers.count, ArtworkPaletteTransition.maximumVisibleLayers)
            XCTAssertEqual(totalWeight(layers), 1, accuracy: 0.000_001)
            XCTAssertEqual(layers.map(\.id), repeatedSample.map(\.id))
            XCTAssertEqual(layers.map(\.weight), repeatedSample.map(\.weight))
        }
    }

    private func totalWeight(_ layers: [ArtworkPaletteLayer]) -> Double {
        layers.reduce(0) { $0 + $1.weight }
    }

    private func palette(_ primary: Color, _ secondary: Color) -> ArtworkColors {
        ArtworkColors(primary: primary, secondary: secondary)
    }
}
