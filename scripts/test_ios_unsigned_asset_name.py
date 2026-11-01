"""Keep the v2.0 asset name consistent through packaging and publication."""
import unittest
from pathlib import Path

import yaml


class UnsignedAssetNameTests(unittest.TestCase):
    def test_all_asset_steps_use_the_resolved_version(self):
        root = Path(__file__).resolve().parents[1]
        path = root / '.github/workflows/ios-release.yml'
        text = path.read_text(encoding='utf-8')
        steps = {s['name']: s for s in yaml.safe_load(text)['jobs']['build']['steps']}
        for name in ('Package unsigned IPA', 'Inspect IPA contents'):
            self.assertIn('imusic_ios_${RELEASE_VERSION}.ipa', steps[name]['run'])
            self.assertEqual(steps[name]['env']['RELEASE_VERSION'], '${{ steps.version.outputs.marketing_version }}')
        self.assertTrue(steps['Upload IPA']['with']['path'].endswith('imusic_ios_${{ steps.version.outputs.marketing_version }}.ipa'))
        self.assertEqual(steps['Attach IPA to GitHub release']['with']['files'], steps['Upload IPA']['with']['path'])
        self.assertNotIn('iMusic-unsigned.ipa', text)
        self.assertIn('python3 ../../../scripts/verify_ios_ipa.py', steps['Inspect IPA contents']['run'])
        self.assertIn('--expected-version "$RELEASE_VERSION"', steps['Inspect IPA contents']['run'])
        self.assertIn('--expected-bundle-id com.jiajia2222.imusic.ios', steps['Inspect IPA contents']['run'])
        config = (root / 'platforms/ios/ios/Config/Shared.xcconfig').read_text(encoding='utf-8')
        self.assertIn('MARKETING_VERSION = 2.0\n', config)


if __name__ == '__main__':
    unittest.main()
