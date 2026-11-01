# v2.0 device installation investigation

## Observed report and package

- Device reports iOS 27.2; signing tool: 全能签. Re-signing reports success,
  installation fails. The installation error and tool version are not yet supplied.
- Original asset: `imusic_ios_2.0.ipa`, 5,300,272 bytes.
- SHA-256: `343043aa73b097b80c77522647602f61efd08e76e101a6a2ada963441cd254c7`.
- Source: `f238f8628a3c484c3831abacafea660ceec937f4`.
- Local inspection: valid ZIP CRC, thin arm64 device executable, iPhoneOS
  platform, minimum 27.0 in both plist and Mach-O, SDK 27.1, cryptid 0,
  executable permission 0755, no embedded frameworks/extensions, valid
  resource-only bundle. No confirmed install-blocking structural defect found.
- Original executable has no LC_CODE_SIGNATURE; no provisioning profile or
  resource seal is included. This is deliberately unsigned re-signing input,
  not a package that can be installed without a valid device signature/profile.

iOS 27.2 satisfies this package's minimum version. Do not attribute this report
to the deployment target, tool incompatibility, or a bad certificate without
the device installer error or analysis of the re-signed output.

## CI results are not device-installation results

The main build and Smoke passed for this SHA (runs 41312543324 and
41312543340). A later tag-triggered run 41319876628 failed its UI test at
`testAppleMusicPlayerSongAndLyricsPages`: the window did not become landscape
within the five-second assertion window. It failed before building/replacing
the IPA. The tag UI failure is real, but does not establish an installation
failure or a Swift compile error. Both issues remain separate investigations.

## Evidence to request safely

1. Exact 全能签 version and signing options; full installation error screenshot.
2. Nested `MIInstallerErrorDomain` / `IXUserPresentableErrorDomain`, `0xe800…`,
   failure reason, and bundle/path named by the installer if available.
3. Whether another known-good IPA installs with the same signing setup, and
   whether an existing iMusic is installed. Do not delete it as a first test.
4. If necessary, a private copy of the exported re-signed IPA for comparison.
   It may contain device identifiers/profile metadata. Never request certificate
   passwords, private keys, or public uploads of profiles.

## Verification limits

`scripts/verify_ios_ipa.py` checks package metadata and executable structure.
It does not validate CMS signatures, certificate revocation, provisioning
eligibility, device inclusion, or installer transport. On macOS, verify the
extracted re-signed app with `codesign --verify --deep --strict --verbose=2`,
then check its entitlements against its profile and capture the device's actual
installation log. Even successful codesign verification is not a device test.

Do not replace the release with a speculative repackage or claim it installs
until the relevant failure is understood and the replacement has been tested.
