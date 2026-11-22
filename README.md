# wow-ui-harness

See a World of Warcraft addon's UI without playing the game by hand. Version 0.2.0 (`VERSION`), MIT licence.

- **Offline (plain Lua 5.1 + Python):** a WoW client API mock that loads your addon, resolves its layout the way the
  client does (anchors, sizes, scales, scroll frames, text with the real fonts), dumps the frame tree of chosen views as
  JSON, lints it (truncated, clipped or overlapping text, overlapping buttons, things outside the window, missing
  glyphs) and renders it to PNG with the game's own textures, atlases and fonts read from a local install.
- **Static (Python, standard library):** `wowui check` scans an addon's Lua source for unsafe or forbidden patterns
  (forbidden calls, combat log registration, new globals, unguarded registrations...), configured by a small JSON
  file in the addon's repository: see [Static safety check](#static-safety-check).
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

#### Client behaviour in unit tests

Scripts, sizes and visibility work as in the client, so tests can drive an addon the way a player does:

- **Scripts:** `GetScript` returns the handler `SetScript` set; `HookScript` on a script without a handler sets it,
  otherwise adds a hook that runs after the handler and earlier hooks; `SetScript` drops the script's hooks.
  `mock.FireScript(frame, "OnClick", "LeftButton", false)` runs handler and hooks (events, `OnUpdate`, `OnShow`...
  use it too). Calling `frame:GetScript(name)(frame, ...)` runs the handler only, as in the client.
- **Visibility:** `Show` / `Hide` / `SetShown` / `SetParent` fire `OnShow` / `OnHide` when visibility really changes,
  on the frame and each of its own shown descendants, parent first; `Show` on a shown frame, or on a frame whose parent
  is hidden, fires nothing. `OnUpdate` runs only for visible frames.
- **Sizes:** `SetSize` / `SetWidth` / `SetHeight` fire `OnSizeChanged(self, width, height)` when the size really
  changes (the resolved size with `wowui.layout`; not re-entered from the frame's own handler). Sizes that change
  through anchors are settled by `wowui.layout.SettleSizes(mock)` (the runner does it before each dump).
- **Text and mouse:** `FontString:IsTruncated()` compares the text's width (6 units a character) with a set width,
  over `SetMaxLines` and the lines a set height holds (with layout: the real measurement); `IsMouseEnabled` returns
  what `EnableMouse` set (true until then).
- **Input:** `mock.SetCursor(x, y)` (`GetCursorPosition`), `mock.SetMouseButtonDown(button, down)`
  (`IsMouseButtonDown`), `mock.SetKeyDown(key, down)` (`IsShiftKeyDown`, `IsControlKeyDown`, `IsAltKeyDown`,
  `IsMetaKeyDown`, `IsModifierKeyDown`, the left / right forms, `IsKeyDown`; keys `"SHIFT"`, `"LCTRL"`, `"RALT"`...),
  `mock.ResetInput()`, and `mock.WithInput({ cursor = { x, y }, keys = { "SHIFT" }, buttons = { "LeftButton" } }, fn)`,
  which puts the previous input back afterwards (also on error).
- **Interaction sequences:** `mock.Click(button, "RightButton")` (OnMouseDown, OnMouseUp, then PreClick / OnClick /
  PostClick for an enabled button registered for that click with `RegisterForClicks`, default `"LeftButtonUp"`; a
  check button toggles first), `mock.Drag(frame, { from = { x, y }, to = { x, y }, steps = 4, elapsed = 1 / 60 })`
  (OnMouseDown; OnDragStart after the first move for a frame registered with `RegisterForDrag`; a frame of
  `mock.Advance(elapsed)` per step with the cursor moving; OnDragStop; OnMouseUp), `mock.Hover(frame)` /
  `mock.Leave(frame)` (OnEnter / OnLeave, `IsMouseOver`), `mock.Wheel(frame, delta)`.
- **Time:** `mock.Advance(seconds)` is one frame (OnUpdate, then the due `C_Timer` callbacks, earliest first; a ticker
  fires at most once a frame; `NewTicker`'s iterations count); `mock.Advance(seconds, step)` runs frames of `step`.
- **Menus:** `MenuUtil.CreateContextMenu(owner, generator, ...)` builds Blizzard_Menu's element descriptions
  (`CreateButton`, `CreateCheckbox`, `CreateRadio`, `CreateTitle`, `CreateDivider`, `CreateSpacer`, `CreateTemplate`,
  `CreateColorSwatch`, submenus, `Queue*`, `SetEnabled(boolean or function(description))`, `SetCanSelect`,
  `SetResponse`, `SetTooltip`, `Pick`) and returns the menu, also `mock.lastMenu`. In tests:
  `menu:Click("Sort", "By name")` picks an element by its texts (nothing for a disabled one; the responder gets
  `data, { context, buttonName }, menu`; the response closes the menu as the client's does), `menu:Find(...)`,
  `menu:Lines()` (`"checkbox [x] Show"`, `"button Delete (disabled)"`, indented submenus), `menu:IsOpen()`.
- **Items:** `mock.items[itemID] = { name, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID }` (after
  `Install`); `GetItemInfoInstant` / `C_Item.GetItemInfoInstant` take an ID, a link or a listed name and return the
  client's seven values, or nothing.

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

## Static safety check

`wowui check` scans an addon's Lua source for unsafe or forbidden patterns without the game and without the mock: a
tokenizer that skips strings and comments (long brackets included) plus enough scope tracking to tell a local from a
global. Python standard library only, and `git` when the folder is a git working tree (it lists files with
`git ls-files`; without git it walks the folder).

```sh
uv run --script <harness>/python/wowui.py check [--config FILE] [--root DIR] [--format text|json] [paths...]
uv run --script <harness>/python/check.py       [same options]     # the same, without installing Pillow
```

Output is one finding per line, `path:line: rule-id: message` (repo-relative paths with `/`, sorted), then a summary
line. Exit code 0: no unsuppressed finding; 1: findings; 2: a config or usage error, a file that cannot be read, or
**no files to check** (a typo in `include`, a wrong `--root`: a check that looked at nothing must not pass). `--format
json` prints `{"findings": [{path, line, rule, message}], "summary": {files, findings, suppressed}}`. `paths` limit the
check to files or folders; the config's `include` / `exclude` still apply, and a single file named in `paths` that they
exclude (or that git does not list) is an error naming it. If `git ls-files` fails for a reason other than "not a git
repository" (an ownership check, a broken config), a warning goes to stderr and the folder is walked instead.

### Config

`.wowui-check.json` in the root (or `--config FILE`; an explicit file that does not exist is an error, a missing
default file means the built-in defaults). Unknown keys and wrong types are errors (exit 2), so a typo cannot silently
turn a rule off; keys starting with `_` are ignored (use them for notes: JSON has no comments). Everything is optional:

```json
{
  "include": ["**/*.lua"],
  "exclude": ["Libs/**", "Data/Generated/**"],
  "disable": { "tests/**": ["new-global", "file-length"] },
  "rules": {
    "forbidden-call": {
      "calls": ["OpenWorldMap", "SetCVar", "SetBinding", "SetBindingClick", "SaveBindings", "loadstring", "load", "RunScript"],
      "hookTargets": ["WorldMapFrame", "PlayerFrame", "TargetFrame", "FocusFrame", "GameMenuFrame"]
    },
    "combat-log": { "events": ["COMBAT_LOG_EVENT", "COMBAT_LOG_EVENT_UNFILTERED"] },
    "new-global": { "allow": ["MyAddon", "MyAddonDB", "SLASH_MYADDON%d+", "BINDING_*"] },
    "file-length": { "maxLines": 800, "overrides": { "Data/**": 5000 } },
    "test-shell-find": { "tests": ["tests/**"] },
    "unguarded-registration": { "guard": "MyAddon:CanRegister" },
    "suppression-reason": true
  }
}
```

- `include` / `exclude`: globs over repo-relative paths. `**` is any depth, `*` and `?` stay within one path segment, a
  pattern without `/` matches the file name at any depth, a trailing `/` means everything below; backslashes count as
  `/` and a leading `./` is dropped. Defaults: include `**/*.lua`, exclude `Libs/**` and `libs/**` (vendored
  libraries).
- `disable`: glob to a list of rule ids that are off for the matching files.
- `rules.<id>`: `false` turns a rule off, `true` keeps its defaults, an object sets its parameters (and may carry
  `"enabled": false`). The defaults shown above are starting points, not a statement of what every addon must avoid:
  an addon replaces any list in its config. Setting `calls` or `hookTargets` replaces the default list; `calls` may
  also be an object mapping a name to the reason shown in the message.

### Rules

| Rule | Finds |
|---|---|
| `forbidden-call` | a call to a name in `calls` (a plain global such as `SetCVar` or `load`, also `_G.SetCVar(...)`, or a dotted name such as `C_CVar.SetCVar`; a local variable of the same name is not the global). Also `hooksecurefunc(Target, ...)` where Target is a string or the first name of the first argument and is in `hookTargets` (`hooksecurefunc(WorldMapFrame, ...)`, `hooksecurefunc("SomeGlobalFunc", ...)`, `hooksecurefunc(WorldMapFrame.ScrollContainer, ...)`), and `Frame:HookScript(...)` / `Frame.child:HookScript(...)` where Frame is in `hookTargets`. Add `hooksecurefunc` to `calls` to forbid it altogether. |
| `combat-log` | `x:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")` and the other `events` (also AceEvent's `self:RegisterEvent(...)`); only a string literal first argument can be seen |
| `new-global` | an assignment to a name that is not a local and not in `allow`: `Foo = ...`, `function Foo()`, `function Foo.bar()` / `function Foo:bar()` (defines a member of global `Foo`), `_G.Foo = ...`, `_G["Foo"] = ...`, `function _G.Foo()`. Field assignments such as `Foo.bar = 1` are not checked. `_G[name] = ...` with a computed key cannot be seen. |
| `file-length` | a file over `maxLines` lines (default 1000; `overrides` maps globs to other limits, first match wins), counted by newlines; reported at line 1 with a message that does not contain the current count, so baselines keyed on the text stay stable as the file changes |
| `test-shell-find` | a test file (`tests`, default `tests/**`) whose `io.popen` / `os.execute` runs `find`, `dir` or `ls`: on Windows `find` is `find.exe`, a text search, so such a test passes vacuously; use `git ls-files` |
| `unguarded-registration` | a registration that is not guarded (below): `tinsert(UISpecialFrames, ...)`, `table.insert(UISpecialFrames, ...)`, `UISpecialFrames[...] = ...`, a slash command variable `SLASH_X1 = ...` (also `_G["SLASH_X1"] = ...`), `SlashCmdList[...] = ...`, `SlashCmdList.X = ...`. Off when `guard` (a call such as `MyAddon:CanRegister`, or a list of them) is not set. |
| `suppression-reason` | a suppression comment without a reason, or naming a rule id that does not exist |

**Guarded** (`unguarded-registration`) is decided per `if` branch, not per `if`, and only these two ways count:

1. The statement is inside a branch of an `if` / `elseif` / `else` that only runs after the guard said yes:
   - the branch's own condition calls the guard and contains no `or` and no `not`: `if guard() then`, `if (guard()) then`,
     `if a and guard() then`, `elseif guard() then`; or
   - an earlier condition of the same `if` was exactly `[not] guard(...)` with an odd number of `not`s (`if not guard()
     then ... else <here> end`): the later branches only run once the guard said yes.
2. An earlier `if <a condition that calls the guard> then return ... end` ended before the statement, in the same
   block, function or chunk (or an enclosing one): `if not guard() then return end` at the top of a function guards the
   rest of that function, and the same at the top of the file guards the rest of the file. Either polarity counts
   (`if guard() then return end` as well, and `if x or guard() then return end`) because what is checked is that the
   guard was consulted before registering, not what it answered. An early return inside a nested block guards that
   block only.

Nothing else counts: a guard called as a statement or in an assignment (`local ok = guard()`) guards nothing after it
(branch on it with `if not guard() then return end`), nor does an `if` that does not return, a guard called later, in
another function or in another branch. A condition with `or`, or with `not` that is not the exact form above
(`if not guard() and y then`, `if x or guard() then`), is not known to run only after a yes, so its body is reported.
Calls are matched by their written name with `:` and `.` alike, after local aliases are resolved (below).

**Limits.** The tokenizer follows Lua 5.1 (no `goto`, no integer division). Scope tracking is a heuristic, not a
parser: a `local` counts from its declaration to the end of its block, `if` branches have separate scopes, and a
`local x = function() x = 1 end` treats `x` as local inside the function (Lua treats it as global there). Local
aliases of a global are followed when the local is initialised with exactly a global's name, `_G.Name` or `_G["Name"]`
(`local SetCVar = SetCVar`, `local C_CVar = _G.C_CVar`, `local scv = SetCVar`, also one level through another alias, or
as one of several positional initialisers up to the first one that is not a plain name): calls through it are still
reported under the global's name. `local x = SetCVar or f` or a call result is not an alias, and `hooksecurefunc(alias,
...)` is checked by the name written in the call. Calls through `pcall(SetCVar, ...)`, computed names, a function
stored in a table field, and `loadstring`-ed code are not seen. A file Lua cannot parse is scanned as far as the
tokenizer gets; the check never fails on a syntax error.

### Suppressions

An inline comment on the finding's line, or a comment alone on the line above it (a comment that trails other code
covers only its own line):

```lua
-- wowui-check: ignore new-global the client calls this by name
function MyAddon_OnCompartmentClick() end
SetCVar("foo", 1) -- wowui-check: ignore forbidden-call set once on first run, with the user's consent
```

The reason after the rule id is required: without one the finding is still suppressed, but the comment itself is a
`suppression-reason` finding. A suppression naming an unknown rule id suppresses nothing and is also a
`suppression-reason` finding; one naming a real rule that has no finding there does nothing. Use `disable` in the
config for whole paths, and put the comment on line 1 for `file-length`.

### In CI

It needs only Python and git, no game and no Lua. A GitHub Actions step with [setup-uv](https://github.com/astral-sh/setup-uv):

```yaml
      - uses: actions/checkout@v4
      - uses: astral-sh/setup-uv@v6
      - name: Static safety check
        run: uv run --script path/to/wow-ui-harness/python/check.py
```

`check.py` has no dependencies (`wowui.py check` is the same code, run by a script that also installs Pillow). Run it
from the addon's folder or pass `--root`.

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
- `python/` the command line (`wowui.py`), its game readers (`casc.py`, `db2.py`) and the static check (`check.py`)
- `lib/LibUIShots-1.0/` the in-game library
- `examples/` a tiny addon and its dump script; `tests/` Lua tests (`lua tests/run.lua`) and Python tests
  (`uv run --script tests/test_cli.py`); `docs/` the dump format
- `AGENTS.md` how to work on this repository; `CHANGELOG.md`
