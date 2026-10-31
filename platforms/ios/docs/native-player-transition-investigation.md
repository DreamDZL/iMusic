# Native player transition investigation

## Release gate

Do not attach `imusic_ios_2.0.ipa` to `v2.0` until the **same commit** passes
both iOS unsigned release and iOS launch smoke test. A successful package build
does not establish visual or interactive correctness.

## Observed evidence

- `22d8a6a`: build passed; song-page and lyrics-page grabber drags both failed.
  This rules out lyrics scrolling as the sole explanation.
- `d81fcd7`: build passed; the same drags failed after replacing the grabber's
  simultaneous tap with a plain Button and removing the native zoom's clear
  presentation override. Those experimental changes did not fix the failures.
- Smoke run `41223865401` recorded light corner luminance 0.75–0.79 at +0.48s,
  then 0.07–0.37 at +0.75s through +5.15s. This run does not show a persistent
  two-second rim, nor does it disprove the reported real-device issue.
- Both grabber targets measured `(111, 62, 180, 82)` on a 402×874pt simulator.
  The tested gesture starts at `(201, 86.6)` and travels down 560pt. Tests use
  no tap fallback. Artwork dismissal in the combined lyrics test is not reached
  after the grabber assertion fails; do not claim artwork dismissal passed.

Build: https://github.com/DreamDZL/iMusic/actions/runs/41223865362

Smoke: https://github.com/DreamDZL/iMusic/actions/runs/41223865401

## Constraints and unresolved questions

- Keep native transitions; no app-owned phone scale/offset animator or masking
  underlay. Preserve the actual app behind interactive dismissal.
- The existing rim test checks physical display corners during zoom, including
  the area outside the expanding rounded destination. It does not distinguish
  exposed light library from a white layer attached to the destination.
- Keep its current strict gate until that distinction is demonstrated. Merely
  waiting longer or raising the luminance threshold is not a repair.
- Isolate artwork and grabber gestures so a first failure does not conceal the
  other result. Establish whether the same gestures work on a minimal native
  destination before changing presentation architecture.
- Windows cannot compile or run iOS. CI uses Xcode 27.1 / iPhone 18 Pro;
  iPhone 17 visual acceptance is still outstanding.

## Diagnostics

Smoke exports `xcresulttool export attachments` alongside the `.xcresult`.
The opening test now finishes its original five-second sample window before
asserting, without changing the 0.4s start or 0.55 luminance threshold. Inspect
the screenshots and recording, not only the final settled screenshot.
