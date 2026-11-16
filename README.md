# wow-ui-harness

See a World of Warcraft addon's UI without playing the game by hand. Version 0.2.0 (`VERSION`), MIT licence.

- **Offline (plain Lua 5.1 + Python):** a WoW client API mock that loads your addon, resolves its layout the way the
  client does (anchors, sizes, scales, scroll frames, text with the real fonts), dumps the frame tree of chosen views as
  JSON, lints it (truncated, clipped or overlapping text, overlapping buttons, things outside the window, missing
  glyphs) and renders it to PNG with the game's own textures, atlases and fonts read from a local install.
- **In game:** `LibUIShots-1.0`, an embeddable library that walks an addon's views one by one and takes a screenshot
  of each, with a manifest that says which file shows what.

Built for addon developers and for coding agents that need to look at a UI they cannot run.

| What | Where | Needs |
|---|---|---|
| Mock, layout, dump, lint, runner | `lua/wowui/` | Lua 5.1 |
| Renderer, lint reader, game data | `python/wowui.py` (`casc.py`, `db2.py`) | Python 3.15+ through [uv](https://docs.astral.sh/uv/), which fetches it, a local game install for textures |
| Screenshot library | `lib/LibUIShots-1.0/` | the game, LibStub (CallbackHandler-1.0 optional) |

## Offline: dump, lint, render

### 1. Load your addon in the mock

`wowui.mock` provides the client's generic API: `CreateFrame` with frames, textures, font strings, lines and mask
textures that remember everything set on them; anchors (with the client's "cannot anchor to a region dependent on it"
error), events (`mock.FireEvent`), timers (`C_Timer`, `mock.Advance`), font objects, BackdropTemplate's API, the common
string and table helpers, units, `C_AddOns`, `C_ChatInfo`, `C_Texture.GetAtlasInfo`, `GetFileIDFromPath`, `MenuUtil`,
`Settings`, and a TOC loader that follows `embeds.xml`. Unknown CamelCase methods do nothing and return nil, so an
addon loads even where the mock is thin. Game data (instances, maps, items, the journal...) is your addon's to stub:

```lua
package.path = "<harness>/lua/?.lua;" .. package.path
local mock = require("wowui.mock")
mock.buildInfo = { "11.0.5", "57000", "Nov 1 2024", 110005 }   -- GetBuildInfo
mock.Install()
_G.C_Map = { GetMapInfo = function(id) return { mapID = id, name = "Somewhere" } end }  -- your stubs
local ns = {}
mock.LoadAddon("path/to/MyAddon", "MyAddon.toc", "MyAddon", ns)
mock.FireEvent("ADDON_LOADED", "MyAddon")
mock.loggedIn = true
mock.FireEvent("PLAYER_LOGIN")
```

The same mock serves ordinary unit tests: without `wowui.layout` geometry getters return fixed placeholders and
nothing is resolved, so test runs stay fast.

### 2. Describe your views and run the dump

```lua
-- my_dump.lua
package.path = "<harness>/lua/?.lua;" .. package.path
local mock = require("wowui.mock")
local ns = {}
os.exit(require("wowui.runner").Main(mock, {
  install = function() mock.Install() --[[ + your stubs ]] end,
  prepare = function() mock.LoadAddon(".", "MyAddon.toc", "MyAddon", ns) --[[ log in, open the window ]] end,
  views = {
    { name = "main", setup = function() MyAddon:ShowTab("main") end, window = function() return MyAddonFrame end },
    { name = "options", setup = function() MyAddon:ShowTab("options") end, window = function() return MyAddonFrame end },
  },
  baseline = "tests/ui_lint_baseline.txt",
  fallbackFont = "Media/MyFont.ttf", fallbackScale = 1.0,   -- for faces not found (CI has no game fonts)
  fontRoots = { { "Interface\\AddOns\\MyAddon\\", "." } },  -- your own font files
}, arg))
```

```sh
lua my_dump.lua --out <work dir>                 # dumps + lint; exit 1 on findings not in the baseline
lua my_dump.lua --out <work dir> --update-baseline
```

The config can also list `lintIgnore` (Lua patterns of finding keys that are by design). Before each view is dumped the
runner settles sizes as the client does between frames: every shown frame whose resolved size changed gets its
`OnSizeChanged` (`wowui.layout.SettleSizes`), so layouts done in those handlers show. `--update-baseline` keeps the
baseline's header comment and the `#` comment lines right above each key that stays (say there why it is accepted). Runner options:
`--font-root <prefix>=<dir>` (repeatable), `--fallback-font`, `--fallback-scale`, `--only a,b`,
`--prefix <text>` (prefix view names, e.g. a locale), `--baseline`, `--update-baseline`, `--all-files`, `--files`,
`--atlases`, `--width`, `--height`. `examples/dump_example.lua` is a complete one for the example addon in
`examples/HarnessExample/`. The JSON format is in [docs/DUMP-FORMAT.md](docs/DUMP-FORMAT.md).

### 3. Render with the game's art

```sh
H=<harness checkout>; G="<World of Warcraft>/_retail_"     # any client folder with its .build.info at or above it
uv run --script $H/python/wowui.py fonts   --game "$G" --out <work>/fonts         # the client's Fonts\*.ttf
uv run --script $H/python/wowui.py atlases --game "$G" --out <work>/atlases.txt   # every atlas name and size
lua my_dump.lua --out <work>/dump --font-root "Fonts\=<work>/fonts" --atlases <work>/atlases.txt --all-files
uv run --script $H/python/wowui.py files   --game "$G" --dump <work>/dump --out <work>/files.txt
lua my_dump.lua --out <work>/dump --font-root "Fonts\=<work>/fonts" --atlases <work>/atlases.txt --files <work>/files.txt
uv run --script $H/python/wowui.py render  --game "$G" --dump <work>/dump --out <work>/png --addon MyAddon=. --lint
```

- `--all-files` makes `GetFileIDFromPath` say yes to every path and records every path asked; `files` then checks
  which of them the client really has, and the second dump answers like the client (an addon that checks files before
  using them takes the same branches as in game).
- `render` draws textures from the client's CASC storage (BLP), addon files from `--addon Name=folder` (else the
  game's `Interface\AddOns`), atlases through the client's `UiTextureAtlas` tables, backdrops (BackdropTemplate's
  edge pieces), masks (round portraits), lines, and text in the dump's font files at the dump's positions, each run
  fitted to the width the layout measured (hinting widens small text). Nine-slice atlases (menus, dropdowns: the
  client's `UiTextureAtlasElementSliceData`) keep their corners. `--lint` writes `<view>.lint.png` with the findings
  outlined and numbered; `--only a,b` draws only those views. Run it from the folder the dump's relative font
  paths start from, or pass `--root`.
- Without `--game` textures are labelled placeholders (colours, text and lines still draw). A file the client knows but
  a streamed install has not downloaded is a grey placeholder; a file the client does not have is magenta; an unknown
  atlas is orange.
- The game folder is only read. Keep work folders outside your repository: fonts and renders contain game files.

### Lint

`wowui.lint` checks a dump (no textures needed, so it runs in CI):

| Rule | Finds |
|---|---|
| `text-truncated` | a font string cut with "..." (too narrow, MaxLines, its height) |
| `text-clipped` | a font string cut sideways by a frame that clips its children (scroll frames are expected to cut) |
| `text-overlap` | two font strings of one window whose drawn lines cross |
| `overlap` | two clickable frames covering each other partly or at about the same size, neither inside the other |
| `outside-window` | something drawn past the view's window (a frame that draws nothing itself, a container or an anchor, is not a piece: what it holds is checked) |
| `missing-glyph` | characters the face has no glyph for (only when the real face was measured) |
| `anchor-conflict` | a region whose anchor points put the same edge or centre in two places (LEFT on one frame, RIGHT on another at another height): the mock takes the last one set, the client need not |

With a window, only that window's tree is linted. `uv run --script python/wowui.py lint --dump <dir> --baseline <file>`
prints the same findings from Python.

## In game: LibUIShots-1.0

Embed it like any LibStub library (`Libs/LibUIShots-1.0/LibUIShots-1.0.xml` in your `embeds.xml`, after LibStub and,
optionally, CallbackHandler-1.0). Register steps and start from a slash command:

```lua
local Shots = LibStub("LibUIShots-1.0")
SLASH_MYADDONSHOTS1 = "/myaddonshots"
SlashCmdList.MYADDONSHOTS = function()
  Shots:Register("MyAddon", {
    { name = "main", setup = function() MyAddon:Open("main") end },
    { name = "options", setup = function() MyAddon:Open("options") end, teardown = function() MyAddon:Close() end },
  }, { store = function() return MyAddonDB end, print = print })
  Shots:Start("MyAddon")
end
```

For each step it calls `setup`, waits (`delay`, default 0.8 s, at least 1.1 s between shots because the game names
screenshot files by the second), calls `Screenshot()`, waits for `SCREENSHOT_SUCCEEDED`, calls `teardown`, and moves on.
A plain backdrop covers the world and everything below the HIGH strata while it runs; Escape stops it; it refuses to
start in combat and stops when combat starts. Afterwards it hides its frames, prints the manifest (index, time, step)
and saves it to `store().shots`, so the files in the game's `Screenshots` folder can be matched to steps by time order.
It hooks nothing, touches no secure frame and hides none of the game's own frames. Options: `store`, `print`, `delay`,
`backdrop` (a colour or `false`), `before`, `after` (gets the manifest), `text` (translated messages, keys in
`lib.TEXT`). Callbacks (with CallbackHandler-1.0): `Started`, `Shot`, `Finished`.

## How faithful it is

Resolved like the client: anchors (all points, offsets, SetAllPoints), sizes, scales down the parent chain, scroll
children and scroll offsets, clipping, strata / frame level / layer / sublevel order, visibility, alpha, button state
textures (normal, disabled, checked; not highlight or pushed), status bar fill, backdrops, mask textures, lines, inline
`|T|t` and `|A|a` pictures and colour codes, word wrap, MaxLines and "..." truncation.

Blizzard templates: the mock builds a template only when your test setup registers it (`mock.templates[name]`), and
then only the parts you add; the dump records every frame's template name and nine-slice layout. The renderer draws
the art of common ones from the client's atlases: ButtonFrameTemplate / PortraitFrameTemplate (background and metal
frame), InsetFrameTemplate, UIPanelButtonTemplate, PanelTabButtonTemplate, PanelTopTabButtonTemplate, and the nine-slice
layouts PortraitFrameTemplate, ButtonFrameTemplateNoPortrait, InsetFrameTemplate and Dialog (`NineSliceUtil`;
piece offsets approximate). A template's font string without anchors is centred on its frame.

Approximate or missing: text has no kerning or shaping and is measured with each face's advance widths (close to the
client, not pixel-exact); other templates draw nothing of their own; texture rotation, gradients and tiling (other than backdrops) are drawn simply;
NineSlice layouts, models, animations and cooldown swipes are not drawn; numeric file IDs from made-up stub data point
at unrelated real files (stub IDs through `mock.SyntheticFileID` instead).

## Libraries and licences

| Used | For | Licence |
|---|---|---|
| [Pillow](https://python-pillow.org/) (dependency, not vendored) | image decoding (BLP through its BlpImagePlugin), drawing, FreeType text | MIT-CMU (HPND) |
| [LibStub](https://www.wowace.com/projects/libstub) (vendored in `tests/vendor/` for the tests) | library versioning | Public domain |
| CallbackHandler-1.0 (optional, not vendored) | the library's callbacks | Ace3 licence (BSD-style) |

Written here, after looking for existing ones: the CASC reader (`python/casc.py`; there is no maintained,
pip-installable CASC package: pyCASCLib must be built from source and the `casc` wheel is Windows-only), the db2
reader (`python/db2.py`, only what the atlas tables need), a ten-line fallback for uncompressed BLP2 that Pillow's
plugin does not read, and the Lua TrueType reader (`lua/wowui/ttf.lua`: layout and lint run in plain Lua in CI, where
fontTools is not available). Considered for generating API stubs and not used yet: the WoW API annotations of the
vscode-wow-api project and the wowless headless client.

## Repository

- `lua/wowui/` the Lua package (`mock`, `layout`, `text`, `ttf`, `dump`, `lint`, `runner`, `json`)
- `python/` the command line (`wowui.py`) and its game readers (`casc.py`, `db2.py`)
- `lib/LibUIShots-1.0/` the in-game library
- `examples/` a tiny addon and its dump script; `tests/` Lua tests (`lua tests/run.lua`) and Python tests
  (`uv run --script tests/test_cli.py`); `docs/` the dump format
- `AGENTS.md` how to work on this repository; `CHANGELOG.md`
