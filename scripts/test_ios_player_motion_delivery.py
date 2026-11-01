"""Keep motion evidence available on green CI runs; not a rendering test."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class PlayerMotionDeliveryTests(unittest.TestCase):
    def test_passing_runs_record_the_repeated_interaction(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/ios-smoke.yml').read_text(encoding='utf-8'))
        steps = workflow['jobs']['launch']['steps']
        record = next(s for s in steps if s['name'] == 'Record repeated player transitions including passing runs')
        self.assertNotIn('failure()', record.get('if', ''))
        run = record['run']
        for required in ('recordVideo', 'kill -INT', 'test-without-building',
                         'testRepeatedPlayerPageTransitionsAndCollapse', 'player-transitions.mp4'):
            self.assertIn(required, run)
        upload = next(s for s in steps if s['name'] == 'Upload simulator test results and screenshots')
        self.assertIn('player-transitions.mp4', upload['with']['path'])
        self.assertEqual(upload['if'], 'always()')

    def test_repetition_gate_checks_both_page_removal_and_mini_player_reuse(self):
        source = (ROOT / 'platforms/ios/ios/KumoneIOSUITests/KumoneIOSUITests.swift').read_text(encoding='utf-8')
        body = source.split('func testRepeatedPlayerPageTransitionsAndCollapse()', 1)[1]
        body = body.split('func testLyricsControlsAutoHideWithDefaultTiming()', 1)[0]
        self.assertIn('for cycle in 0..<3', body)
        self.assertIn('for change in 0..<3', body)
        self.assertIn('song.waitForNonExistence', body)
        self.assertIn('lyrics.waitForNonExistence', body)
        self.assertIn('miniPlayer.isHittable', body)
        self.assertIn('thenDragTo:', body)


if __name__ == '__main__':
    unittest.main()
