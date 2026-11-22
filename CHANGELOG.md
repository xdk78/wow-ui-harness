# Changelog

## [Unreleased]

- Mock: client behaviour for unit tests. `SetSize` / `SetWidth` / `SetHeight` fire `OnSizeChanged` when the size
  changes; `Show` / `Hide` / `SetParent` fire `OnShow` / `OnHide` on the frame and its shown descendants when
  visibility changes (and only then); `GetScript` returns the handler and `HookScript` / `SetScript` keep hooks as the
  client does (`mock.FireScript` runs both); `FontString:IsTruncated()` without layout; `IsMouseEnabled` as set;
  input driving (`mock.SetCursor`, `SetKeyDown`, `SetMouseButtonDown`, `WithInput`, `GetCursorPosition`,
  `IsMouseButtonDown`, the modifier-key functions) and sequences (`mock.Click`, `Drag`, `Hover`, `Leave`, `Wheel`;
  `RegisterForClicks` and `RegisterForDrag` are honoured); `MenuUtil` with Blizzard_Menu's element descriptions,
  `SetEnabled` predicates, `Pick` and responses, and test helpers (`menu:Click`, `Find`, `Lines`, `IsOpen`);
  `GetItemInfoInstant` / `C_Item.GetItemInfoInstant` with the seven values from `mock.items`; `C_Timer.NewTicker`
  iterations, timers in time order, `mock.Advance(seconds, step)`.
- Behaviour changes an addon's tests may notice: `Show` on a shown frame no longer fires `OnShow`; `OnUpdate` runs only
  for visible frames (not just shown ones); `frame:GetScript(name)(...)` no longer runs hooks (use `mock.FireScript` or
  `mock.Click`); `IsMouseButtonDown` now exists and says false unless a test holds a button; after `SetSize`,
  `wowui.layout.SettleSizes` has nothing left to report for that frame; `MenuUtil.CreateContextMenu` returns the menu
  (it still has the root's `Create*` methods), and its `items` lists every element in order, titles, dividers and
  checkboxes included; `mock.Click` / `mock.Drag` do nothing for a frame that is not visible or has the mouse disabled.
- What an addon's own mock layer can drop: its own `IsMouseEnabled`, `IsTruncated` and `RegisterForClicks` overrides,
  `GetItemInfoInstant` / `C_Item.GetItemInfoInstant` stubs (fill `mock.items`), replacements of `GetCursorPosition`,
  `IsMouseButtonDown` and `IsShiftKeyDown` in tests (`mock.WithInput`), hand-run `OnMouseDown` / `OnDragStart` /
  `OnUpdate` / `OnDragStop` / `OnMouseUp` sequences (`mock.Drag`), and `MenuUtil` fakes.
- `wowui check` (`python/check.py`, standard library only): a static safety lint of an addon's Lua source, configured by
  `.wowui-check.json` in the addon repository. Rules: `forbidden-call`, `combat-log`, `new-global`, `file-length`,
  `test-shell-find`, `unguarded-registration`, `suppression-reason`; `-- wowui-check: ignore <rule> <reason>`
  suppressions; text or JSON output; exit code 1 on findings, 2 on a config error.
- Layout parity in CI: `wowui.py files --sizes <json>` records the file IDs and pixel sizes of the game files a dump
  asked for or drew (and of an addon's own files with `--addon`) and the sizes of the atlases it asked for
  (`wowui-sizes/1`, sizes only, no pixels); the runner's `--sizes` (or the config's `sizes`) answers
  `GetFileIDFromPath` and `C_Texture.GetAtlasInfo` from it, and with `wowui.layout` a texture with no size takes its
  file's recorded size, as the client does. Runs write `atlases-asked.txt`; `mock.SetTextureSize`;
  `GetFileIDFromPath` no longer minds the kind of slash.
- Renderer: textures sample through SetTexCoord's 4 or 8 values (rotations and shears as well as crops, flips and
  quarter turns; coordinates past 0..1 follow the wrap mode) and SetRotation as the client documents it (rotation
  point, the 2^-0.5 scale, empty corners; `SetRotation(0)` around the centre draws unchanged); lines are
  anti-aliased quads with square ends at their thickness, plain or with their texture or atlas stretched along them.
  Textures and lines draw only their visible part, so huge or off-canvas geometry stays cheap.
- Dump: textures record `rotationPoint` and `wrap` (SetTexture's wrap modes), lines `coords`; a line without
  SetThickness is 4 thick, the client's default (also `GetThickness` with `wowui.layout` on).
- `wowui gif`: an animated GIF from rendered frames (files or globs, a `seq-<name>-NN` sequence, or a JSON spec): crop
  (`auto` too), scale or width, per-frame time, captions in a band (from the dumps' `meta.caption`, the spec or the
  command line; drawn in the font Pillow carries), one shared palette without dithering, loop count, and `--max-bytes`
  to reduce colours and then width until the file fits.
- `wowui.views` (`Views.Sequence`): declare an interaction as steps that run cumulatively on one state, as views named
  `seq-<name>-NN` with the caption in the dump's `meta`. The runner accepts a view's `meta` and `needs`; `--only` of a
  later step sets up the earlier ones first. The example dump script has a sequence.
- `wowui compare A B`: A | B | pixel diff in one PNG for two images or two render folders, with `--crop`, `--zoom`,
  `--labels`, `--tolerance` and `--threshold`; exit code 1 when they differ.
- `wowui atlases --search <text>` and `--sheet <png>` (`--filter`, `--columns`, `--cell`, `--max`): find atlases by name
  and draw a labelled contact sheet from the client's textures. `--out` is optional now.

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
