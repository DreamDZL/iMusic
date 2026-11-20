#if os(iOS)
import CoreGraphics
import Testing
@testable import KumoneCore

@MainActor
@Test func artworkCollapseStartsAtTheLiveFrameAndLandsOnTheMiniArtwork() {
    let artwork = CGRect(x: 34, y: 116, width: 322, height: 322)
    let miniArtwork = CGRect(x: 22, y: 710, width: 42, height: 42)
    let liveFrame = NativeNowPlayingCoordinates.interpolate(from: artwork, to: miniArtwork, progress: 0.25)

    #expect(liveFrame == CGRect(x: 31, y: 264.5, width: 252, height: 252))
    #expect(NativeNowPlayingCoordinates.interpolate(from: liveFrame, to: miniArtwork, progress: 0) == liveFrame)
    #expect(NativeNowPlayingCoordinates.interpolate(from: liveFrame, to: miniArtwork, progress: 1) == miniArtwork)
    #expect(NativeNowPlayingCoordinates.interpolate(from: liveFrame, to: artwork, progress: 1) == artwork)
}
#endif
