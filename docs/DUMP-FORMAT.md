# Dump format: `wowui-dump/1`

`wowui.dump.Capture` writes one JSON document per view. Keys are sorted; numbers have at most three decimals.
Coordinates are in UIParent units (the screen at UI scale 1) with the origin at the **top left** and y growing
down (the client uses bottom-left; the dump converts). A rect is `[x, y, width, height]`.

```jsonc
{
  "schema": "wowui-dump/1",
  "harness": "0.3.0",              // wowui.mock's version
  "view": "home",                  // the view's name (with the runner's --prefix, e.g. "plPL/home")
  "meta": { ... },                 // whatever the caller passed; a sequence step (wowui.views) adds sequence, step, steps, caption
  "screen": [1920, 1080],          // UIParent's size
  "window": {                      // the view's window, when the caller named one
    "path": "MyAddonFrame", "rect": [460, 200, 1000, 680], "id": 1
  },
  "regions": [ ... ]               // every visible frame and region, in draw order
}
```

## Regions

Entries come in the order the client draws them: frames sorted by strata, frame level and creation; after each frame,
its own regions sorted by draw layer (BACKGROUND, BORDER, ARTWORK, OVERLAY), sublevel and creation. The HIGHLIGHT
layer, button pushed and highlight textures, hidden objects, objects without a resolved rect and objects clipped away
entirely are left out.

Every entry:

| Key | Meaning |
|---|---|
| `id` | 1-based position in `regions` |
| `kind` | `Frame`, `Button`, `CheckButton`, `EditBox`, `ScrollFrame`, `StatusBar`, ..., or `Texture`, `FontString`, `Line` |
| `path` | a stable name: the global name, else the field that holds it on an ancestor (`MyFrame.list.rows[3]`), else `Parent/Kind#n` |
| `parent`, `parentPath` | the parent frame's `id` (when dumped earlier) and path |
| `top` | path of the top-level frame (the child of UIParent) the entry belongs to |
| `rect` | resolved rectangle |
| `scale` | effective scale (sizes in the entry are already multiplied by it) |
| `alpha` | effective alpha (own times every parent's) |
| `clip` | the rect the entry is clipped to (frames that clip their children, scroll frames), or absent |
| `scrolled` | true when one of the clipping frames is a scroll frame |
| `strata`, `level` | the frame's (a region's frame's) strata and frame level |
| `layer`, `sublevel` | draw layer and sublevel (`FRAME` / 0 for frames) |
| `template` | the template name given to CreateFrame (templates are not built by the mock) |
| `anchorConflict` | optional: `{ axis = "x" or "y", delta }` when two anchor points put the same edge or centre `delta` px apart (lint rule `anchor-conflict`) |

Frames also have `clickable` (a button, check button, edit box or slider, or a mouse-enabled frame with a click
script), `mouse`, `enabled`, and optionally:

- `nineSlice`: the nine-slice layout applied with `NineSliceUtil.ApplyLayoutByName`; `noPortrait`: true after
  `ButtonFrameTemplate_HidePortrait`;

- `backdrop`: `{ bgFile, edgeFile, tile, tileSize, edgeSize, insets: [l, r, t, b], color, borderColor }` (BackdropTemplate);
- `text`: an edit box's text (same shape as a font string's);
- `bar`: a status bar's `{ min, max, value }`.

Textures have `texture`:

| Key | Meaning |
|---|---|
| `file` | a path (a file ID made up by `--all-files` is turned back into its path) |
| `fileID` | a numeric file data ID |
| `atlas` | an atlas name |
| `color` | SetColorTexture's colour `[r, g, b, a]` |
| `coords` | SetTexCoord's 4 (`l, r, t, b`) or 8 (`ULx, ULy, LLx, LLy, URx, URy, LRx, LRy`) values |
| `vertex` | vertex colour `[r, g, b, a]` |
| `rotation` | SetRotation's radians (counter-clockwise) |
| `rotationPoint` | SetRotation's `normalizedRotationPoint` as `[x, y]` in image space, when given (the client's default is the centre) |
| `wrap` | SetTexture's wrap modes `[horizontal, vertical]` (`CLAMP`, `REPEAT`, `MIRROR`, `CLAMPTOBLACK`, `CLAMPTOWHITE`, `CLAMPTOBLACKADDITIVE`; `true` is `REPEAT`, an omitted one `CLAMP`), when given |
| `blend`, `desaturated`, `tile`, `gradient` | as set |
| `masks` | mask textures: `[{ file, atlas, rect }]` |

Font strings (and edit boxes) have `text`:

| Key | Meaning |
|---|---|
| `raw`, `plain` | the text with markup, and its visible characters |
| `font`, `size`, `flags` | the face's game path, size (already scaled) and flags |
| `fontLocal`, `fontHow`, `fontScale` | the local file measured with, `exact` / `fallback` / `none`, and the fallback's width factor |
| `color`, `shadow` | text colour; `{ color, offset }` |
| `justifyH`, `justifyV`, `wrap`, `maxLines` | as set (through the font object chain) |
| `lineHeight` | line height (already scaled) |
| `lines` | `[{ x, y, w, parts: [{ s, color?, w } or { icon?, atlas?, w, h }] }]`: every laid-out line with its top-left corner |
| `width`, `full` | the widest laid-out line; the text's single-line width |
| `truncated` | the text was cut with "..." |

Lines have `line`: `{ from: [x, y], to: [x, y], thickness, color, vertex, file, atlas, coords }`. `thickness` is
already scaled; a line without SetThickness has the client's default, 4. `coords` is SetTexCoord's values, as for
textures.

## Lint output

The runner writes `<prefix>lint.json` next to the dumps: `{ "findings": [{ rule, key, message, rect, path, view }] }`,
`<prefix>files-asked.txt` (every path the addon passed to GetFileIDFromPath) and `<prefix>atlases-asked.txt` (every
atlas name passed to C_Texture.GetAtlasInfo or SetAtlas), sorted, one per line. A baseline file holds one
`<view> | <key>` per line.

## Recorded sizes: `wowui-sizes/1`

`wowui.py files --sizes <file>` writes, and the runner's `--sizes <file>` reads, facts about the game files a run used
(keys sorted):

```jsonc
{
  "schema": "wowui-sizes/1",
  "files": {                                   // every path asked or drawn that the client (or an --addon folder) has
    "Interface\\Buttons\\WHITE8X8": { "id": 130871, "size": [8, 8] },   // file data ID, width and height in pixels
    "Interface\\Streamed\\NotYet":  { "id": 123456 },                   // known, not downloaded: no size
    "Interface\\AddOns\\MyAddon\\Media\\Logo": { "size": [128, 64] }    // an addon's own file: no ID
  },
  "atlases": { "common-icon-checkmark": [18, 16] }  // the asked atlases the client has: width and height
}
```
