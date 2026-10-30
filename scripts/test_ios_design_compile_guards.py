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

    def test_tertiary_token_is_a_concrete_color(self):
        source = (ROOT / "DesignSystem/Theme.swift").read_text(encoding="utf-8")
        self.assertNotIn("= Color.tertiary", source)
        search = (ROOT / "Features/Pages/SearchView.swift").read_text(encoding="utf-8")
        self.assertNotIn("Theme.accent : .tertiary", search)


if __name__ == "__main__":
    unittest.main()
