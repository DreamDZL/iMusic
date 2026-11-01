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
and retain a dedicated simulator recording even when the test passes.

Python/source guards only characterize structure and policy; they cannot prove
smoothness or render correctness. Xcode compilation, simulator interaction and
recording inspection remain required, followed by actual iOS device acceptance.
Windows development cannot provide those device results locally.

No persistence/schema changes are needed. Keep the existing Release asset until
the replacement's own build, functional/UI gates and visual evidence have been
reviewed. The earlier installation investigation remains separate; a transition
change is not evidence that re-signing/install eligibility has been fixed.
