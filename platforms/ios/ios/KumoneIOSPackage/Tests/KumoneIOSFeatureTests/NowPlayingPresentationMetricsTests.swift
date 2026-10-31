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

    /// Left swipe on the song page opens lyrics, right swipe on lyrics goes
    /// back; short drags and the opposite direction stay put.
    func testPageSwipeDirectionAndThreshold() {
        XCTAssertEqual(NowPlayingPresentationMetrics.pageSwipeTarget(
            translation: -80, predictedTranslation: -120, showsLyrics: false), true)
        XCTAssertEqual(NowPlayingPresentationMetrics.pageSwipeTarget(
            translation: 80, predictedTranslation: 120, showsLyrics: true), false)
        XCTAssertNil(NowPlayingPresentationMetrics.pageSwipeTarget(
            translation: 80, predictedTranslation: 300, showsLyrics: false))
        XCTAssertNil(NowPlayingPresentationMetrics.pageSwipeTarget(
            translation: -20, predictedTranslation: -40, showsLyrics: false))
        // A quick flick commits even with little travel.
        XCTAssertEqual(NowPlayingPresentationMetrics.pageSwipeTarget(
            translation: -25, predictedTranslation: -260, showsLyrics: false), true)
    }

    /// The pulled-down player is a rounded card; at rest it is square.
    func testDismissCardShape() {
        XCTAssertEqual(NowPlayingPresentationMetrics.dismissCornerRadius(progress: 0), 0)
        XCTAssertEqual(NowPlayingPresentationMetrics.dismissCornerRadius(progress: 1), 40)
        XCTAssertEqual(NowPlayingPresentationMetrics.dismissProgress(dragOffset: 0, height: 900), 0)
        XCTAssertEqual(NowPlayingPresentationMetrics.dismissProgress(dragOffset: 600, height: 900), 1)
    }

    /// Hidden lyric controls come back only from a tap in the lower band;
    /// taps higher up stay available for seeking to a line.
    func testLyricsRevealTapOnlyInLowerBandWhileHidden() {
        let page: CGFloat = 800, band: CGFloat = 228
        XCTAssertTrue(NowPlayingPresentationMetrics.isLyricsControlsRevealTap(
            locationY: 700, pageHeight: page, revealRegionHeight: band, controlsVisible: false))
        XCTAssertTrue(NowPlayingPresentationMetrics.isLyricsControlsRevealTap(
            locationY: 572, pageHeight: page, revealRegionHeight: band, controlsVisible: false))
        XCTAssertFalse(NowPlayingPresentationMetrics.isLyricsControlsRevealTap(
            locationY: 400, pageHeight: page, revealRegionHeight: band, controlsVisible: false))
        XCTAssertFalse(NowPlayingPresentationMetrics.isLyricsControlsRevealTap(
            locationY: 700, pageHeight: page, revealRegionHeight: band, controlsVisible: true))
    }

    /// The cursor switches slightly before the timestamp so the line is in
    /// place when it is sung, but never more than a fraction of a second.
    func testLyricLeadTimeIsShortAndPositive() {
        XCTAssertGreaterThan(PlayerService.lyricLeadTime, 0)
        XCTAssertLessThanOrEqual(PlayerService.lyricLeadTime, 0.25)
        let lyrics = ParsedLyrics(lines: [
            LyricLine(id: 0, time: 1, text: "a"),
            LyricLine(id: 1, time: 3, text: "b"),
        ])
        XCTAssertEqual(lyrics.activeIndex(at: 2.9 + PlayerService.lyricLeadTime), 1)
        XCTAssertEqual(lyrics.activeIndex(at: 2.5 + PlayerService.lyricLeadTime), 0)
    }

    /// The timeline badge must stay short; full wording belongs to the
    /// accessibility label and the quality sheet.
    func testQualityBadgeNamesAreShort() {
        for quality in AudioQuality.allCases {
            XCTAssertLessThanOrEqual(quality.badgeName.count, 11, "\(quality) badge is too long")
            XCTAssertFalse(quality.badgeName.contains("/"), "\(quality) badge should be a single label")
        }
        XCTAssertEqual(AudioQuality(lxType: "320k")?.badgeName, "320K")
        XCTAssertEqual(AudioQuality(lxType: "flac")?.badgeName, "无损")
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
