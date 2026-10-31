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
- Temporary diagnostics in `92f3991` and `e570840` reproduced failed native
  interactive zoom dismissal with minimal source/destination views, both through
  SwiftUI and through an owned UIKit presentation. The owned UIKit zoom probe
  reported `callbackCount=0`; the sheet control dismissed with the same drag.
  Removing the player page's horizontal swipe did not establish a repair.
  This evidence makes lyric scrolling or the full player view insufficient as
  the sole explanation; it does not definitively establish an OS bug.
- At `e570840`, unsigned release build `41227933874` passed and smoke run
  `41227933850` failed. Packaging success is not product acceptance.

Build: https://github.com/DreamDZL/iMusic/actions/runs/41223865362

Smoke: https://github.com/DreamDZL/iMusic/actions/runs/41223865401

Latest diagnostic build: https://github.com/DreamDZL/iMusic/actions/runs/41227933874

Latest diagnostic smoke: https://github.com/DreamDZL/iMusic/actions/runs/41227933850

## Chosen native transition path (validation pending)

- The approved implementation direction is native UIKit `crossDissolve` opening
  and native UIKit zoom closing. A downward gesture requests dismissal only once
  its threshold is met; UIKit owns the closing animation. There is no custom
  animator, interactive scale/offset, or app-owned shrinking card.
- A subthreshold pull cancels the request and leaves the player visible and
  usable. The regression test performs a 25pt normal-speed grabber pull, checks
  that the page stays open and the grabber remains in place, then performs the
  full dismissal pull on that same page, without any tap fallback.
- This is an implementation decision, not a claim that dismissal or the rim is
  fixed. Record the exact candidate SHA and require both release-build and smoke
  gates on that SHA before release; that candidate and its results are pending.

## Constraints and unresolved questions

- Keep native transitions; no app-owned phone scale/offset animator or masking
  underlay. Preserve the actual app behind interactive dismissal.
- The existing rim test checks physical display corners during opening, including
  the area outside the expanding rounded destination. It does not distinguish
  exposed light library from a white layer attached to the destination.
- Keep its current strict gate until that distinction is demonstrated. Merely
  waiting longer or raising the luminance threshold is not a repair.
- Keep independent artwork and grabber product regressions so a first failure
  does not conceal the other result. The minimal-destination hypothesis has now
  been tested; its failure is recorded above, not treated as shipping acceptance.
- Windows cannot compile or run iOS. CI uses Xcode 27.1 / iPhone 18 Pro;
  iPhone 17 visual acceptance is still outstanding.

## Diagnostics

Temporary probe helpers/tests from `92f3991` and `e570840` are retired after
answering that isolation hypothesis: `assertIsolatedNativeDismissal`, the
gesture-free accessory/stable-source zoom tests, the no-page-swipe grabber/artwork
tests, the minimal system-swipe test, and `assertOwnedUIKitDismissal` with its
owned UIKit zoom/sheet tests. They are no longer product acceptance probes.
This does not weaken shipping assertions: the independent artwork test now uses
the normal player launch directly with its original normalized start `(0.5, 0.4)`,
260pt travel, and velocity 2400. The independent grabber test and the complete
default-timing lyrics test (grabber, reopen, artwork, no fallback) remain intact.

Smoke exports `xcresulttool export attachments` alongside the `.xcresult`.
The opening test now finishes its original five-second sample window before
asserting, without changing the 0.4s start or 0.55 luminance threshold. Inspect
the screenshots and recording, not only the final settled screenshot.
