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

## Apple Music alignment pass (device feedback, 2026-10-30)

Rules that came out of the first on-device review:

- Margins: `Theme.Layout.contentInset` follows the system layout margin that
  positions large titles and search fields (16pt; 20pt on Plus/Max and iPad).
  Section headers, rows and shelves share that edge.
- Player: thumbless timeline that thickens while dragging; short format badge
  (`AudioQuality.badgeName`) with the full wording kept in the accessibility
  label; double-triangle skip glyphs; slim volume track with a small dot;
  monochrome accessory row with a subtle highlight for active toggles;
  translucent neutral title-row buttons instead of palette-tinted glass; paused
  artwork recedes slightly unless Reduce Motion is on.
- Lyrics: one large bold style for every line, emphasis by opacity and blur
  only; blur clears while browsing; tap any line to seek; when controls hide,
  the deck shrinks to the accessory row plus a reveal band, so no lyric line is
  laid out under a transparent tap target.
- Lists: two-line song rows (title, artist) with a trailing "⋯" menu and inset
  separators; source/quality moved into the row menu; count and length footer
  on collection pages only.
- Collection pages: centred artwork, title, accent curator line, Play and
  Shuffle capsules, expandable description (`CollectionHeader`).
- Tabs: Home "Top Picks"-style portrait cards with eyebrow labels; New uses a
  paged featured carousel and solid category tiles; Radio is a station card
  plus live picks; Search lists recent searches, categories and trends in the
  system order; Library uses plain accent-glyph rows and a bold section title.
- Mini player: play/pause and next only, like the system accessory; previous
  is a horizontal swipe and a VoiceOver action.

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
