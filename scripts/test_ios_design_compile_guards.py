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

    def test_content_margin_follows_system_layout_margin(self):
        theme = (ROOT / "DesignSystem/Theme.swift").read_text(encoding="utf-8")
        self.assertNotIn("static let contentInset: CGFloat = 24", theme)
        self.assertIn(">= 414 ? 20 : 16", theme)

    def test_track_rows_do_not_repeat_source_and_quality_line(self):
        rows = (ROOT / "Features/Shared/TrackList.swift").read_text(encoding="utf-8")
        body = rows[rows.index("var body: some View"):rows.index("private var artwork")]
        self.assertNotIn("来源：", body)

    def test_player_uses_skip_glyphs_and_unmasked_resume_action(self):
        player = (ROOT / "Features/Player/NowPlayingView.swift").read_text(encoding="utf-8")
        transport = player[player.index("private var primaryTransportControls"):]
        transport = transport[:transport.index("private func classicCompactLayout")]
        self.assertNotIn("backward.end.fill", transport)
        self.assertNotIn("forward.end.fill", transport)
        column = player[player.index("private var lyricsColumn"):]
        self.assertLess(column.index(".mask("), column.index('"resumeCurrentLyrics"'),
                        "the resume action must be overlaid after the fade mask")

    def test_tertiary_token_is_a_concrete_color(self):
        source = (ROOT / "DesignSystem/Theme.swift").read_text(encoding="utf-8")
        self.assertNotIn("= Color.tertiary", source)
        search = (ROOT / "Features/Pages/SearchView.swift").read_text(encoding="utf-8")
        self.assertNotIn("Theme.accent : .tertiary", search)


if __name__ == "__main__":
    unittest.main()
