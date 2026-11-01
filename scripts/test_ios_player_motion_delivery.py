"""Keep functional motion gates; device visual acceptance belongs to the maintainer."""
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class PlayerMotionDeliveryTests(unittest.TestCase):
    def test_ci_runs_functional_gates_without_a_second_visual_acceptance_pass(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/ios-smoke.yml').read_text(encoding='utf-8'))
        steps = workflow['jobs']['launch']['steps']
        run = next(s for s in steps if s['name'] == 'Run feature and UI navigation tests, then launch on the latest simulator')['run']
        self.assertIn('xcodebuild test', run)
        self.assertFalse(any('recordVideo' in step.get('run', '') for step in steps))
        upload = next(s for s in steps if s['name'] == 'Upload simulator test results and screenshots')
        self.assertIn('smoke-tests.xcresult', upload['with']['path'])
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
