"""Source guards for UI compile regressions; not a substitute for Xcode."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / "platforms/ios/Sources/Kumone"


class IOSDesignCompileGuards(unittest.TestCase):
    def test_tab_observer_is_not_inside_disabled_source(self):
        source = (ROOT / "Features/IOSMainWindow.swift").read_text(encoding="utf-8")
        conditions = []
        found = False
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith("#if "):
                conditions.append(stripped[4:])
            elif stripped == "#endif":
                conditions.pop()
            if "private struct NativeTabReselectionObserver:" in line:
                found = True
                self.assertNotIn("false", conditions)
                self.assertIn("os(iOS)", conditions)
        self.assertTrue(found)
        self.assertEqual(conditions, [])
        self.assertNotIn("lazy.compactMap { findTabs(", source)

    def test_content_margin_is_shared_and_roomy(self):
        theme = (ROOT / "DesignSystem/Theme.swift").read_text(encoding="utf-8")
        self.assertNotIn("static let contentInset: CGFloat = 24", theme)
        self.assertIn(">= 414 ? 24 : 20", theme)

    def test_track_rows_do_not_repeat_source_and_quality_line(self):
        rows = (ROOT / "Features/Shared/TrackList.swift").read_text(encoding="utf-8")
        body = rows[rows.index("var body: some View"):rows.index("private var artwork")]
        self.assertNotIn("\u6765\u6e90\uff1a", body)  # "来源："

    def test_player_uses_skip_glyphs_and_cheap_lyric_frames(self):
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        transport = player[player.index("private var primaryTransportControls"):]
        transport = transport[:transport.index("private func classicCompactLayout")]
        self.assertNotIn("backward.end.fill", transport)
        self.assertNotIn("forward.end.fill", transport)
        # Lyric line frames must not be published through @State/preferences
        # on every scroll frame (it re-rendered the whole player).
        self.assertNotIn("LyricsLinePositionPreferenceKey", player)
        self.assertIn("private final class LyricLineFrameStore", player)

    def test_energy_guards(self):
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        backdrop = player[player.index("private var artworkBackdrop"):]
        backdrop = backdrop[:backdrop.index("private func artworkGradient")]
        self.assertIn("!player.isPlaying", backdrop, "backdrop must freeze while paused")
        # Animations follow the device refresh rate (ProMotion 120 Hz);
        # without this key custom animations are capped at 60 Hz.
        plist = (ROOT.parents[1] / "ios/Config/Info.plist").read_text(encoding="utf-8")
        self.assertIn("CADisableMinimumFrameDurationOnPhone", plist)

    def test_player_backdrop_clip_precedes_safe_area_expansion(self):
        # A clip applied after ignoresSafeArea keeps the safe-area frame and
        # cut the backdrop off under the status bar and above the home
        # indicator, showing the app behind the player.
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        backdrop = player[player.index("private var backdrop: some View"):]
        backdrop = backdrop[:backdrop.index("#else")]
        self.assertLess(backdrop.index(".modifier(PlayerCardClip())"),
                        backdrop.index(".ignoresSafeArea()"))

    def test_add_to_playlist_toggles_without_song_row(self):
        sheet = (ROOT / "Features/Shared/TrackList.swift").read_text(encoding="utf-8")
        sheet = sheet[sheet.index("struct AddToPlaylistSheet"):]
        self.assertNotIn("selectionSummary", sheet)
        self.assertIn("localStore.remove(tracks, from: playlist.id)", sheet)
        store = (ROOT / "Core/Storage/LocalPlaylistStore.swift").read_text(encoding="utf-8")
        self.assertNotIn("tracks.append(track)", store, "saved songs go to the top of a playlist")

    def test_phone_uses_native_dismissal(self):
        presentation = (ROOT / "Features/Player/NowPlayingPresentation.swift").read_text(encoding="utf-8")
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        window = (ROOT / "Features/IOSMainWindow.swift").read_text(encoding="utf-8")
        self.assertNotIn(".modifier(NowPlayingDismissDrag(", presentation)
        self.assertNotIn(".modifier(NowPlayingDismissDrag(", player)
        self.assertIn("usesSystemInteractiveDismissal: zooms", window)

    def test_volume_bar_is_not_a_restyled_system_slider(self):
        # Two translucent track images overlapped under the system slider's
        # thumb canvas and showed as a lighter block beside the dot.
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        self.assertNotIn("MPSystemVolumeSlider", player)
        self.assertIn("private struct SystemVolumeBridge", player)
        self.assertNotIn("withAlphaComponent(0.72)", player)

    def test_phone_opening_has_no_opaque_underlay(self):
        window = (ROOT / "Features/IOSMainWindow.swift").read_text(encoding="utf-8")
        self.assertNotIn("NowPlayingOpeningUnderlay", window)
        self.assertIn(".navigationTransition(", window)
        root = window[window.index("private var presentationRoot"):window.index("private var systemNowPlayingRoot")]
        self.assertIn("zoomNowPlayingRoot", root)

    def test_native_zoom_diagnostics_are_nonpersistent_and_debug_only(self):
        window = (ROOT / "Features/IOSMainWindow.swift").read_text(encoding="utf-8")
        diagnostic = window[window.index("enum NowPlayingNativeDiagnostics {"):]
        diagnostic = diagnostic[:diagnostic.index("@available(iOS 26.0, *)")]
        self.assertIn("#if DEBUG", diagnostic)
        self.assertIn('arguments.contains("-imusic-ui-testing")', diagnostic)
        self.assertIn("#else\n        return false", diagnostic)
        self.assertNotIn("UserDefaults", diagnostic)
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        self.assertIn("including: gestureMask", player)
        probe = (ROOT / "Features/Player/NativeZoomRuntimeProbe.swift").read_text(encoding="utf-8")
        self.assertTrue(probe.startswith("#if os(iOS) && DEBUG\n"))
        self.assertIn("interactiveDismissShouldBegin", probe)
        self.assertNotIn("value(forKey:", probe)
        self.assertNotIn("UIPanGestureRecognizer", probe)

    def test_tertiary_token_is_a_concrete_color(self):
        source = (ROOT / "DesignSystem/Theme.swift").read_text(encoding="utf-8")
        self.assertNotIn("= Color.tertiary", source)
        search = (ROOT / "Features/Pages/SearchView.swift").read_text(encoding="utf-8")
        self.assertNotIn("Theme.accent : .tertiary", search)


if __name__ == "__main__":
    unittest.main()
