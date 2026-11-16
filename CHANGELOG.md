# Changelog

## [0.2.0] - 2026-11-16

- Lint: `anchor-conflict`, a region whose anchor points put the same edge or centre in two places (the dump records
  `anchorConflict`); `outside-window` skips frames that draw nothing themselves (containers, anchors) and checks what
  they hold instead.
- Runner: sizes settle before each dump (`wowui.layout.SettleSizes`: `OnSizeChanged` for every shown frame whose size
  changed, cascading), as the client's do between frames; `--update-baseline` keeps the header and each kept key's
  comment.
- Renderer: nine-slice atlases keep their corners (the client's slice table); text runs are fitted to the width the
  layout measured; `render --only <views>`.

## [0.1.0] - 2026-11-16

First version.

- `wowui.mock`: a WoW client API mock for plain Lua 5.1 (frames, regions, anchors, fonts, textures, lines, backdrops,
  events, timers, the common client functions), extensible with an addon's own game-data stubs and frame templates
  (`mock.templates`).
- `wowui.layout`: anchor, size, scale, scroll and text resolution as the client does it; text measured with the real
  font files (`wowui.ttf`, `wowui.text`).
- `wowui.dump`: the visible frame tree as JSON (`docs/DUMP-FORMAT.md`), in draw order.
- `wowui.lint`: truncated, clipped and overlapping text, overlapping clickable frames, things outside the window, missing
  glyphs; baselines.
- `wowui.runner`: a command line for "build these views, dump, lint, compare with a baseline".
- `python/wowui.py`: `render` (PNG from a dump, with the client's textures, atlases and fonts read from its CASC
  storage), `lint`, `fonts`, `atlases`, `files`.
- `LibUIShots-1.0`: an embeddable in-game library that walks an addon's views and takes a screenshot of each.
- The renderer draws common Blizzard templates and nine-slice layouts from the client's atlases (window frames,
  insets, red panel buttons, tabs); the mock records nine-slice layouts and centres template text without anchors.
