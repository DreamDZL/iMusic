"""Source regression guards; rendering/performance still require iOS testing."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "platforms/ios/Sources/Kumone/Features/Player/NowPlayingView.swift"


class PlayerPageTransitionGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = PLAYER.read_text(encoding="utf-8")

    def section(self, start, end):
        source = self.source[self.source.index(start):]
        return source[:source.index(end)]

    def test_artwork_does_not_share_geometry_between_two_page_branches(self):
        for token in ("matchedGeometryEffect", "MatchedArtwork", "playerPageNamespace", "matched: true"):
            self.assertNotIn(token, self.source)
        artwork = self.section("private func artworkView(", "private static func makeUITestArtwork")
        self.assertIn(".clipped()", artwork)
        self.assertIn(".frame(width: size, height: size)", artwork)

    def test_portrait_has_one_persistent_artwork_owner_and_identity_page_replacement(self):
        layout = self.section("private func appleMusicCompactLayout", "private func artworkPlaceholder")
        pages, overlay = layout.split(".overlayPreferenceValue(PlayerArtworkAnchorKey.self)", 1)
        self.assertEqual(pages.count(".transition(.identity)"), 2)
        self.assertNotIn("Self.playerPageTransition", pages)
        self.assertNotIn("artworkView(", pages)
        self.assertIn("artworkPlaceholder(size: artworkSize)", pages)
        self.assertIn("usesSharedArtwork: true", pages)
        self.assertEqual(overlay.count("artworkView("), 1)
        self.assertIn("let rect = proxy[anchor]", overlay)
        self.assertIn(".position(x: rect.midX, y: rect.midY)", overlay)
        self.assertLess(overlay.index(".modifier(pageSwipe)"), overlay.index(".position("))
        self.assertIn(".animation(pageAnimation, value: showLyricsOnMobile)", overlay)
        self.assertIn('showLyricsOnMobile ? "lyricsHeaderArtwork" : "nowPlayingArtworkImage"', overlay)
        for token in (".scaleEffect(", ".offset(", "NowPlayingMotion.page"):
            self.assertNotIn(token, layout)

    def test_swipe_recognizes_but_does_not_animate_the_page(self):
        swipe = self.section("private struct PlayerPageSwipe:", "private final class LyricLineFrameStore")
        self.assertIn(".simultaneousGesture(", swipe)
        self.assertIn("NowPlayingPresentationMetrics.pageSwipeTarget(", swipe)
        self.assertIn("dx > dy * 1.4", swipe)
        self.assertIn("guard wasHorizontal", swipe)
        for token in (".offset(", ".opacity(", "withAnimation(", "@Binding", "pageSwipeOffset"):
            self.assertNotIn(token, swipe)

    def test_button_and_swipe_use_one_page_state_update(self):
        setter = self.section("private func setLyricsPage(", "private static let deckAccessoryHeight")
        self.assertIn("resumeTask?.cancel()", setter)
        self.assertIn("isUserScrolling = false", setter)
        self.assertIn("isLyricsDragActive = false", setter)
        self.assertEqual(setter.count("withAnimation(pageAnimation)"), 1)
        self.assertIn("onCommit: setLyricsPage", setter)
        accessory = self.section("private var songPageAccessoryControls", "private func accessoryGlyph")
        self.assertIn("setLyricsPage(!showLyricsOnMobile)", accessory)
        self.assertIn("reduceMotion ? nil : .spring(response: 0.48, dampingFraction: 0.9)", self.source)

    def test_deck_uses_native_opacity_and_keeps_accessible_auto_hide(self):
        layout = self.section("private func appleMusicCompactLayout", "private static let playerPageTransition")
        self.assertIn("!showLyricsOnMobile || lyricsControlsVisible", layout)
        self.assertIn(".transition(.opacity)", layout)
        hide = self.section("private func scheduleLyricsControlsAutoHide", "private var songPageAccessoryControls")
        self.assertIn("lyricsControlsTask?.cancel()", hide)
        self.assertIn("NowPlayingPresentationMetrics.lyricsControlsAutoHideDelay(", hide)
        self.assertIn("!Task.isCancelled, showLyricsOnMobile, !isLyricsDragActive", hide)
        self.assertIn("!UIAccessibility.isVoiceOverRunning", hide)
        self.assertNotIn(".spring(", hide)

    def test_backdrop_only_ticks_during_palette_changes(self):
        backdrop = self.section("private var artworkBackdrop", "private func artworkGradient")
        self.assertIn("|| !artworkPalette.isTransitioning", backdrop)
        self.assertIn("!renderingBudget.isSceneActive", backdrop)
        self.assertIn("!renderingBudget.allowsContinuousEffects", backdrop)
        self.assertNotIn("sin(", backdrop)
        self.assertNotIn("cos(", backdrop)

    def test_skip_feedback_is_system_symbol_effect_not_custom_animator(self):
        self.assertNotIn("keyframeAnimator", self.source)
        self.assertNotIn("SkipNudge", self.source)
        self.assertIn(".symbolEffect(.bounce, value: reduceMotion ? 0 : skipBackTrigger)", self.source)
        self.assertIn(".symbolEffect(.bounce, value: reduceMotion ? 0 : skipForwardTrigger)", self.source)

    def test_anchors_are_layout_derived_and_header_uses_a_placeholder_only_in_portrait(self):
        placeholder = self.section("private func artworkPlaceholder", "private static let playerPageTransition")
        self.assertIn(".anchorPreference(key: PlayerArtworkAnchorKey.self, value: .bounds)", placeholder)
        self.assertIn(".accessibilityHidden(true)", placeholder)
        self.assertIn(".allowsHitTesting(false)", placeholder)
        header = self.section("private func appleMusicLyricsPage(", "private func revealLyricsControls")
        self.assertIn("usesSharedArtwork: Bool = false", header)
        self.assertIn("if usesSharedArtwork {", header)
        self.assertIn("artworkPlaceholder(size: 56)", header)
        self.assertIn('artworkView(size: 56, identifier: "lyricsHeaderArtwork")', header)
        key = self.section("private struct PlayerArtworkAnchorKey:", "private final class LyricLineFrameStore")
        self.assertIn("static var defaultValue: Anchor<CGRect>? { nil }", key)
        self.assertNotIn("@State", key)

    def test_landscape_and_regular_layout_keep_local_artwork(self):
        layouts = self.section("private func phoneLandscapeLayout", "private func compactLayout")
        self.assertIn("artworkView(size: artworkSize)", layouts)
        self.assertIn("leftColumn(artworkSize: artworkSize)", layouts)
        self.assertNotIn("usesSharedArtwork: true", layouts)
        self.assertNotIn(".overlayPreferenceValue(PlayerArtworkAnchorKey.self)", layouts)

    def test_sync_navigation_and_stale_artwork_guards_remain(self):
        lyrics = self.section("private var lyricsColumn:", "private func lyricBlurRadius")
        self.assertIn(".onChange(of: lyricsCursor.activeIndex)", lyrics)
        self.assertIn("guard !isUserScrolling, let index", lyrics)
        self.assertIn("adoptCursor(proxy: proxy)", lyrics)
        self.assertIn("AppRouter.shared.openArtist(named: artist.name, avatarURL: artist.picUrl)", self.source)
        artwork = self.section("private func loadArtwork()", "private func setArtwork(")
        self.assertIn("!Task.isCancelled, player.currentTrack?.playbackKey == playbackKey", artwork)


if __name__ == "__main__":
    unittest.main()
