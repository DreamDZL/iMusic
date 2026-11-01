# Player motion recovery after device feedback

## Acceptance contract

The maintainer clarified that “native animation” means the iOS/Apple Music
interaction and motion quality, not a restriction to one UIKit transition API.
The earlier cross-dissolve opening and release-only zoom request do not meet
that contract. UIKit/SwiftUI public animation and interaction APIs may be used
to provide continuous motion. This is not an exact reproduction of Apple's
private player implementation.

- Pulling the grabber or artwork should visibly track the finger toward the
  mini-player; a short/cancelled pull returns to the expanded state.
- Completing a pull or using the accessible close action returns to a usable
  mini-player. Reopening and repeating must not leave a stale presentation.
- Switching song/lyrics must have one coherent artwork owner: no retained
  large cover over lyrics, thumbnail with old song metadata, or orphaned layer.
- Horizontal page switching must not steal vertical lyric scrolling, dismissal,
  scrubbing, or system-volume gestures.
- Respect Reduce Motion, maintain lyrics synchronization and the default
  three-second controls policy, and avoid continuous full-screen blur redraws
  for static artwork.

## Validation discipline

The previous same-commit green tests did not establish actual device motion
quality. Keep the existing rim, default-timing, artwork/grabber, tap and
cancel-then-close assertions. Add repeated page-change/collapse/reopen coverage,
and retain the normal XCTest results for diagnosis. The maintainer now owns
visual acceptance on their physical device; do not block delivery on assistant
recording downloads or a second simulator video pass.

Python/source guards only characterize structure and policy; they cannot prove
smoothness or render correctness. Xcode compilation and functional simulator
interaction remain required, followed by the maintainer's iOS device acceptance.
Windows development cannot provide those device results locally.

No persistence/schema changes are needed. Keep the existing Release asset until
the replacement's own build and functional/UI gates have passed. Clearly label
its visual acceptance as pending maintainer testing. The earlier installation investigation remains separate; a transition
change is not evidence that re-signing/install eligibility has been fixed.

## Follow-up device report

The maintainer reports that `30cc1c5` still does not track a downward song-page
pull, page changes appear limited to 60 fps, and rapid horizontal reversals can
retain overlapping content. The preceding green simulator tests do not refute
those observations.

Follow-up work keeps artwork ownership stable even during an empty anchor
handoff, separates artwork geometry animation from page-tree replacement, and
rejects swipe completions superseded by a newer page revision. The song's empty
upper surface also needs explicit dismissal hit testing; only testing the
grabber and artwork missed that path.

Page interaction now requests the attached display's supported refresh rate
for a bounded time via `CADisplayLink.preferredFrameRateRange`. The built
Release plist must retain the ProMotion timing opt-in. These are scheduling
hints, **not measured device FPS or a guarantee of 120 Hz**; system power,
thermal, accessibility, and panel limits remain authoritative. Decorative
background timelines retain their separate lower-power rendering budget.
