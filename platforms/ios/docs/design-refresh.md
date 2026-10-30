# iOS design refresh

## Contract

Retain iMusic identity, native navigation and system-owned Liquid Glass. Content
uses semantic backgrounds, shared spacing and system typography. Favorite symbols
are stars; the `loveList` identity and “我喜欢的音乐” name are unchanged. No storage
or synchronization migration is part of this visual refresh.

## Delivery gates

1. Consistency: margins, unobscured discovery header, concise search entry,
   monochrome library symbols, player controls, stars and “电台” naming.
2. Composition: portrait 3:4 home features, discovery recommendations, radio
   choices and explicit states, search categories/ranked trends, library sync row.
3. Interaction: shared track actions, tab reselection, mini-player swipe,
   volume treatment, reduced-motion-aware background, available lyric translations.
4. Consolidation: remove unreachable legacy code, align tokens and semantic fonts,
   preserve supported older-system fallbacks and accessibility.

Each batch requires independent review and successful Smoke and unsigned Release
for its exact commit before proceeding. Do not include unrelated staged files.
Do not infer visual acceptance from successful compilation or navigation alone.

## Visual acceptance matrix

Inspect each principal screen in light/dark appearance, largest accessibility
text size, and landscape. Check readable unclipped titles, horizontal breathing
room, VoiceOver labels, 44-point control targets and last-row player clearance.
Capture real simulator screenshots; record any unavailable checks explicitly.
The fixed player accessory, lyric control auto-hide and cancellation-safe source
operations must remain intact.

## Recovery

Changes are split into reversible commits. Revert the affected batch rather than
resetting local user work. No persistence keys, provider identities or credentials
are to be changed. Existing Smoke/Release and playback regression tests remain
required; signed export and physical-device verification are separate gates.
