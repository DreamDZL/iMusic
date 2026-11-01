"""Source checks for interaction-only ProMotion requests, not measured FPS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'platforms/ios/Sources/Kumone/Features/Player'


class PlayerRefreshRateTests(unittest.TestCase):
    def test_page_motion_has_a_temporary_panel_aware_request(self):
        lease = (SOURCE / 'PlayerMotionFrameRateLease.swift').read_text(encoding='utf-8')
        for token in ('preferredFrameRateRange', 'maximumFramesPerSecond',
                      'isLowPowerModeEnabled', 'thermalState', 'deadline',
                      'link?.invalidate()', 'forMode: .common', 'weak var owner:'):
            self.assertIn(token, lease)
        self.assertNotIn('@Published', lease, 'display ticks must not redraw the SwiftUI player')

    def test_lease_is_not_a_permanent_refresh_loop(self):
        lease = (SOURCE / 'PlayerMotionFrameRateLease.swift').read_text(encoding='utf-8')
        self.assertIn('CACurrentMediaTime() >= deadline', lease)
        self.assertIn('window == nil', lease)
        self.assertIn('lease?.stop()', lease)
        self.assertIn('activationState != .foregroundActive', lease)

    def test_page_requests_and_built_app_opt_in_are_wired(self):
        page = (SOURCE / 'NowPlayingView.swift').read_text(encoding='utf-8')
        self.assertIn('PlayerMotionFrameRateAnchor(lease: motionFrameRate)', page)
        switch = page.split('private func setLyricsPage(', 1)[1].split('private var pageSwipe:', 1)[0]
        self.assertIn('motionFrameRate.request()', switch)
        workflow = (ROOT / '.github/workflows/ios-release.yml').read_text(encoding='utf-8')
        self.assertIn("Print :CADisableMinimumFrameDurationOnPhone", workflow)


if __name__ == '__main__':
    unittest.main()
