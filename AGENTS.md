# AGENTS.md

Guide for contributors and coding agents. wow-ui-harness is tooling for World of Warcraft addons: an offline client
API mock with layout resolution, a frame-tree dump and lint (Lua 5.1), a renderer and game-data readers (Python), and
an in-game screenshot library (LibUIShots-1.0). It must stay usable by any addon: nothing here names or assumes a
particular addon.

## Layout

- `lua/wowui/` the Lua package: `mock` (client API), `layout` (anchors, sizes, scales, text), `text` (markup and line
  layout), `ttf` (font metrics and character maps), `dump` (frame tree as JSON), `lint`, `runner` (command line),
  `json`.
- `python/` `wowui.py` (PEP 723 script: `render`, `lint`, `fonts`, `atlases`, `files`), `casc.py` (CASC storage,
  read-only), `db2.py` (WDC3-5 tables).
- `lib/LibUIShots-1.0/` the in-game library (LibStub; CallbackHandler-1.0 optional).
- `examples/` a small addon with deliberate layout mistakes and its dump script; the tests use both.
- `tests/` `run.lua` (Lua tests), `test_cli.py` (Python tests), `vendor/LibStub.lua`.
- `docs/DUMP-FORMAT.md` the dump schema.

## Commands

```sh
lua tests/run.lua                      # Lua tests (mock, layout, text, dump, lint, library); must pass
uv run --script tests/test_cli.py      # Python tests (needs lua on PATH for the end-to-end case)
luacheck .                             # Lua lint (CI)
uvx ruff check python tests && uvx ruff format --check python tests
lua examples/dump_example.lua --out <dir>   # a dump of the example addon
```

## Rules

- Lua code runs on plain Lua 5.1 (the game's version): no `goto`, no integer division, no `utf8` library.
- The mock stays permissive: an unknown CamelCase method returns nil. Behaviour that changes a getter's answer goes
  behind `wowui.layout.Enable` unless it only records state, so existing addon test suites keep passing.
- Every new recorded property that affects drawing goes into the dump and `docs/DUMP-FORMAT.md` (bump the schema's
  number for incompatible changes).
- Lint rules need stable keys (rule, paths, text): baselines in addon repositories depend on them.
- Output must be deterministic: sort what comes from `pairs`.
- The game folder is read-only. Nothing here writes into it; tools take its path as an argument. Never commit game
  files (textures, fonts, renders) or local paths.
- The library hooks nothing, touches no secure frame and never runs in combat.
- Dependencies: permissive licences only for anything vendored; LGPL only as an unvendored Python dependency; GPL
  tools only as optional external programs, and the README says so. List every library with its licence in README.md.
- Every change that users can see gets a line in `CHANGELOG.md`; the version is in `VERSION`, `lua/wowui/mock.lua`
  (`M.VERSION`), `python/wowui.py` (`__version__`) and the library (`lib.VERSION`; raise its LibStub minor when the
  library changes).

## This repository is public-ready

No secrets, tokens, personal paths, machine names, character names or other projects' names in code, docs or commit
messages. Examples use placeholders (`<World of Warcraft>/_retail_`, `<work dir>`).
