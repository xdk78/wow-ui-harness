# /// script
# requires-python = ">=3.15"
# dependencies = ["pillow>=11"]
# ///
"""wow-ui-harness command line: see a World of Warcraft addon's UI without the game.

Subcommands (run with `uv run --script <harness>/python/wowui.py <command> ...`):

  fonts    --game <client folder> --out <dir> [--file <game path> ...]
           Copy the client's font files (Fonts\\*.TTF) out of its CASC storage, for wowui.layout to measure text with
           (the dump's --font-root "Fonts\\=<dir>").
  atlases  --game <client folder> [--out <file>] [--search <text>] [--sheet <png> [--filter <text>] [--columns 8]]
           Every atlas the client knows, one "name<TAB>width<TAB>height" per line (the dump's --atlases).
  files    --game <client folder> --dump <dir> [--out <file>] [--sizes <json>] [--addon <Name>=<folder> ...]
           Which of the paths a dump asked GetFileIDFromPath about (or drew) the client has, "fileID<TAB>path" per
           line (the dump's --files, for a second dump that answers like the client). --sizes writes facts an addon
           can commit for CI (the dump's --sizes): those files' IDs and pixel sizes and the asked atlases' sizes.
  render   --dump <dir or .json> --out <dir> [--game <client folder>] [--addon <Name>=<folder> ...] [--root <dir>]
           [--scale 1] [--crop window|content|screen] [--lint]
           Draw every dump as a PNG: textures from the client's CASC storage (BLP decoded) or from addon folders,
           atlases through the client's UiTextureAtlas tables, text in the real font files. Without --game, textures
           are labelled placeholders. --lint also writes <view>.lint.png with the lint findings marked.
  lint     --dump <dir> [--baseline <file>]
           Print the lint findings the dump run wrote (lint.json); with a baseline, exit 1 on findings not in it.
  check    [--config <file>] [--root <addon folder>] [--format text|json] [paths ...]
           Static safety check of an addon's Lua source (no game, no mock; check.py, standard library only): forbidden
           calls, combat log registration, new globals, long files, shell-out tests, unguarded registrations. Exit 1
           on findings, 2 on a config or usage error. Rules and config: README.md, "Static safety check".

The game folder is only read. Keep --out outside any repository: renders contain game art.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import struct
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import apidoc  # noqa: E402
import casc as casc_mod  # noqa: E402
import check as check_mod  # noqa: E402
import db2  # noqa: E402
import visual  # noqa: E402

__version__ = "0.2.0"

UI_TEXTURE_ATLAS = 897470  # DBFilesClient/UiTextureAtlas.db2 (file data ID)
UI_TEXTURE_ATLAS_MEMBER = 897532  # DBFilesClient/UiTextureAtlasMember.db2
UI_TEXTURE_ATLAS_SLICES = 5319042  # DBFilesClient/UiTextureAtlasElementSliceData.db2 (10.2 and later)

# The game's nine-slice layouts (NineSliceUtil), as the client's layout table places them: per piece the atlas and,
# for corners, the offset from the frame's corner (x right, y up). Edges run between the corners and tile.
_METAL = {
    "tr": ("UI-Frame-Metal-CornerTopRight-2x", 4, 16),
    "bl": ("UI-Frame-Metal-CornerBottomLeft-2x", -13, -3),
    "br": ("UI-Frame-Metal-CornerBottomRight-2x", 4, -3),
    "top": ("_UI-Frame-Metal-EdgeTop-2x",),
    "bottom": ("_UI-Frame-Metal-EdgeBottom-2x",),
    "left": ("!UI-Frame-Metal-EdgeLeft-2x",),
    "right": ("!UI-Frame-Metal-EdgeRight-2x",),
}
NINE_SLICE = {
    "PortraitFrameTemplate": dict(_METAL, tl=("UI-Frame-PortraitMetal-CornerTopLeft-2x", -13, 16)),
    "ButtonFrameTemplateNoPortrait": dict(
        _METAL,
        tl=("UI-Frame-Metal-CornerTopLeft-2x", -12, 16),
        bl=("UI-Frame-Metal-CornerBottomLeft-2x", -12, -3),
    ),
    "InsetFrameTemplate": {
        "tl": ("UI-Frame-InnerTopLeft", 0, 0),
        "tr": ("UI-Frame-InnerTopRight", 0, 0),
        "bl": ("UI-Frame-InnerBotLeftCorner", 0, -1),
        "br": ("UI-Frame-InnerBotRight", 0, -1),
        "top": ("_UI-Frame-InnerTopTile",),
        "bottom": ("_UI-Frame-InnerBotTile",),
        "left": ("!UI-Frame-InnerLeftTile",),
        "right": ("!UI-Frame-InnerRightTile",),
    },
    "Dialog": {
        "tl": ("UI-Frame-DiamondMetal-CornerTopLeft-2x", -5, 5),
        "tr": ("UI-Frame-DiamondMetal-CornerTopRight-2x", 5, 5),
        "bl": ("UI-Frame-DiamondMetal-CornerBottomLeft-2x", -5, -5),
        "br": ("UI-Frame-DiamondMetal-CornerBottomRight-2x", 5, -5),
        "top": ("_UI-Frame-DiamondMetal-EdgeTop-2x",),
        "bottom": ("_UI-Frame-DiamondMetal-EdgeBottom-2x",),
        "left": ("!UI-Frame-DiamondMetal-EdgeLeft-2x",),
        "right": ("!UI-Frame-DiamondMetal-EdgeRight-2x",),
    },
}

DEFAULT_FONTS = [
    "Fonts\\FRIZQT__.TTF",
    "Fonts\\FRIZQT___CYR.TTF",
    "Fonts\\ARIALN.TTF",
    "Fonts\\skurri.ttf",
    "Fonts\\MORPHEUS.ttf",
    "Fonts\\2002.ttf",
    "Fonts\\2002B.ttf",
    "Fonts\\ARHei.ttf",
    "Fonts\\ARKai_T.ttf",
    "Fonts\\ARKai_C.ttf",
    "Fonts\\blei00d.TTF",
    "Fonts\\bHEI00M.ttf",
    "Fonts\\bHEI01B.ttf",
    "Fonts\\bKAI00M.ttf",
    "Fonts\\FRIENDS.TTF",
    "Fonts\\K_Damage.TTF",
    "Fonts\\K_Pagetext.TTF",
    "Fonts\\NIM_____.ttf",
    "Fonts\\MORPHEUS_CYR.TTF",
    "Fonts\\SKURRI_CYR.TTF",
]


# ---------------------------------------------------------------------------------------------------------------------
# Game data


class Game:
    """Textures and atlases from an installed client (read-only), or nothing when there is no client."""

    def __init__(self, game: Path | None, addons: dict[str, Path]):
        self.game = game
        self.casc = None
        if game:
            try:
                self.casc = casc_mod.Casc(game)
            except Exception as e:  # noqa: BLE001
                print(f"wowui: no CASC storage at {game}: {e}", file=sys.stderr)
        self.addons = {k.lower(): v for k, v in addons.items()}
        self._atlases = None
        self._slices: dict = {}
        self._images: dict = {}
        self.missing: set[str] = set()
        self.not_local: set = set()

    # Atlases ---------------------------------------------------------------------------------------------------------
    def atlases(self) -> dict:
        """name (lower case) -> (file data ID, left, right, top, bottom in pixels, width, height of the sheet)."""
        if self._atlases is not None:
            return self._atlases
        self._atlases = {}
        if not self.casc:
            return self._atlases
        try:
            sheets = {}
            a = db2.DB2(self.casc.read_fid(UI_TEXTURE_ATLAS))
            for rid, row in a.rows():
                # ID, FileDataID, (unused), AtlasWidth, AtlasHeight, UiCanvasID
                sheets[rid] = (row[1], row[3], row[4])
            m = db2.DB2(self.casc.read_fid(UI_TEXTURE_ATLAS_MEMBER))
            for rid, row in m.rows():
                # CommittedName, ID, UiTextureAtlasID, Width, Height, Left, Right, Top, Bottom, ElementID, ...
                sheet = sheets.get(row[2])
                name = m.string(rid, 0)
                if not sheet or not name:
                    continue
                l, r, t, b = row[5], row[6], row[7], row[8]
                if not (0 <= l < r <= sheet[1] and 0 <= t < b <= sheet[2]):
                    continue
                self._atlases[name.lower()] = (sheet[0], l, r, t, b, sheet[1], sheet[2], row[10], row[11], row[9])
        except Exception as e:  # noqa: BLE001
            print(f"wowui: atlas tables unreadable ({e}); atlases draw as placeholders", file=sys.stderr)
        try:
            # ID, UiTextureAtlasElementID, Left, Top, Right, Bottom, SliceMode: nine-slice atlases (menus, dropdowns).
            s = db2.DB2(self.casc.read_fid(UI_TEXTURE_ATLAS_SLICES))
            for _, row in s.rows():
                self._slices[row[1]] = (row[2], row[3], row[4], row[5], row[6])
        except Exception:  # noqa: BLE001, S110
            pass  # older clients have no slice table: their atlases stretch
        return self._atlases

    def atlas_slices(self, name: str):
        """A nine-slice atlas's margins in sheet pixels (left, top, right, bottom, mode), or None."""
        a = self.atlases().get(str(name).lower())
        return self._slices.get(a[9]) if a and len(a) > 9 else None

    # Files -----------------------------------------------------------------------------------------------------------
    def _decode(self, raw: bytes, hint: str) -> Image.Image | None:
        try:
            if raw[:4] == b"BLP2" and raw[8] == 3:
                # Uncompressed BGRA BLP2 (big atlas sheets use it): Pillow's BlpImagePlugin does not read encoding 3.
                w, h = struct.unpack_from("<II", raw, 12)
                off = struct.unpack_from("<I", raw, 20)[0]
                return Image.frombytes("RGBA", (w, h), raw[off : off + w * h * 4], "raw", "BGRA")
            # Pillow reads the other BLPs (BlpImagePlugin: palette, DXT1/3/5), TGA, PNG and JPEG.
            return Image.open(io.BytesIO(raw)).convert("RGBA")
        except Exception:  # noqa: BLE001
            self.missing.add(f"undecodable {hint}")
            return None

    def _addon_file(self, path: str) -> bytes | None:
        norm = path.replace("/", "\\")
        parts = norm.split("\\")
        if len(parts) < 4 or parts[0].lower() != "interface" or parts[1].lower() != "addons":
            return None
        name = parts[2]
        base = self.addons.get(name.lower())
        if base is None and self.game:
            base = self.game / "Interface" / "AddOns" / name
        if base is None:
            return None
        rel = Path(*parts[3:])
        candidates = [rel] if rel.suffix else []
        candidates += [rel.with_name(rel.name + ext) for ext in (".tga", ".blp", ".png", ".jpg")]
        for c in candidates:
            p = base / c
            if p.exists():
                return p.read_bytes()
            # The client is case-insensitive; the disk may not be.
            parent = p.parent
            if parent.exists():
                for q in parent.iterdir():
                    if q.name.lower() == p.name.lower():
                        return q.read_bytes()
        return None

    def image(self, file=None, file_id=None) -> Image.Image | None:
        key = (str(file).lower() if file is not None else None, file_id)
        if key in self._images:
            return self._images[key]
        img = None
        raw = None
        if file_id is not None and self.casc:
            try:
                raw = self.casc.read_fid(int(file_id))
            except Exception:  # noqa: BLE001
                raw = None
            if raw is None and int(file_id) in self.casc.by_fid:
                self.not_local.add(key)
        elif isinstance(file, str) and file:
            raw = self._addon_file(file)
            if raw is None and self.casc:
                p = file.replace("/", "\\")
                tries = [p] if "." in p.rsplit("\\", 1)[-1] else []
                tries += [p + ".blp", p + ".tga"]
                for t in tries:
                    try:
                        raw = self.casc.read(t)
                    except Exception:  # noqa: BLE001
                        raw = None
                    if raw:
                        break
                    if self.casc.file_id(t) is not None:
                        self.not_local.add(key)  # the client has it, this install has not downloaded it
        if raw:
            img = self._decode(raw, str(file or file_id))
        if img is None:
            self.missing.add(str(file if file is not None else file_id))
        self._images[key] = img
        return img


# ---------------------------------------------------------------------------------------------------------------------
# Drawing


def _rgba(c, alpha=1.0):
    if not c:
        return (255, 255, 255, int(255 * alpha))
    r, g, b = (max(0.0, min(1.0, float(v))) for v in c[:3])
    a = float(c[3]) if len(c) > 3 else 1.0
    return (round(r * 255), round(g * 255), round(b * 255), round(max(0.0, min(1.0, a * alpha)) * 255))


def _tint(img: Image.Image, color, alpha: float) -> Image.Image:
    """Multiply RGB by a colour and alpha by colour alpha * alpha (the client's vertex colour)."""
    r, g, b, a = (c / 255 for c in _rgba(color, 1.0))
    a *= alpha
    if (r, g, b, a) == (1, 1, 1, 1):
        return img
    ch = img.split()
    rr = ch[0].point(lambda v, f=r: round(v * f))
    gg = ch[1].point(lambda v, f=g: round(v * f))
    bb = ch[2].point(lambda v, f=b: round(v * f))
    aa = ch[3].point(lambda v, f=a: round(v * f))
    return Image.merge("RGBA", (rr, gg, bb, aa))


def _placeholder(w: int, h: int, label: str, color=(255, 0, 255)) -> Image.Image:
    img = Image.new("RGBA", (max(1, w), max(1, h)), color + (60,))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, img.width - 1, img.height - 1], outline=color + (200,))
    if w > 12 and h > 12:
        d.line([0, 0, img.width - 1, img.height - 1], fill=color + (120,))
        d.line([0, img.height - 1, img.width - 1, 0], fill=color + (120,))
    if w > 40 and h > 10 and label:
        d.text((2, 1), label[: max(1, w // 6)], fill=(255, 255, 255, 230))
    return img


def _nine_slice(piece: Image.Image, margins, w: int, h: int, k: float) -> Image.Image:
    """A nine-slice atlas drawn at w x h: corners at their own size (times k), edges and centre stretched."""
    ml, mt, mr, mb = (round(v) for v in margins)
    pw, ph = piece.size
    if ml + mr >= pw or mt + mb >= ph:
        return piece.resize((w, h), Image.Resampling.BILINEAR)
    dl, dt, dr, db = (max(0, round(v * k)) for v in (ml, mt, mr, mb))
    f = min(1.0, w / max(1, dl + dr), h / max(1, dt + db))
    dl, dt, dr, db = (round(v * f) for v in (dl, dt, dr, db))
    out = Image.new("RGBA", (w, h))
    xs, dxs = (0, ml, pw - mr, pw), (0, dl, w - dr, w)
    ys, dys = (0, mt, ph - mb, ph), (0, dt, h - db, h)
    for i in range(3):
        for j in range(3):
            sw, sh = xs[i + 1] - xs[i], ys[j + 1] - ys[j]
            tw, th = dxs[i + 1] - dxs[i], dys[j + 1] - dys[j]
            if sw > 0 and sh > 0 and tw > 0 and th > 0:
                cell = piece.crop((xs[i], ys[j], xs[i + 1], ys[j + 1])).resize((tw, th), Image.Resampling.BILINEAR)
                out.paste(cell, (dxs[i], dys[j]))
    return out


# What SetTexture's wrap modes draw outside the image (CLAMP repeats the edge pixels, REPEAT and MIRROR tile).
_WRAP_FILL = {
    "CLAMPTOBLACK": (0, 0, 0, 255),
    "CLAMPTOWHITE": (255, 255, 255, 255),
    "CLAMPTOBLACKADDITIVE": (0, 0, 0, 0),
}


def _tex_corners(coords):
    """SetTexCoord as image coordinates of the rect's corners: upper left, lower left, upper right, lower right."""
    if not coords:
        return (0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)
    c = [float(v) for v in coords]
    if len(c) == 4:
        l, r, t, b = c
        return (l, t), (l, b), (r, t), (r, b)
    return (c[0], c[1]), (c[2], c[3]), (c[4], c[5]), (c[6], c[7])


def _bilerp(corners, x: float, y: float):
    """The image coordinate at (x, y) of the rect (0..1, y down) for the corners of _tex_corners."""
    ul, ll, ur, lr = corners
    return tuple(ul[i] * (1 - x) * (1 - y) + ur[i] * x * (1 - y) + ll[i] * (1 - x) * y + lr[i] * x * y for i in (0, 1))


def _rotation(radians: float, point=None):
    """SetRotation as two maps in normalised coordinates (y down): rect -> image and image -> rect.

    The client (warcraft.wiki.gg, API TextureBase SetRotation) moves the image by -point, scales it by 2^-0.5, turns it
    counter-clockwise on screen by `radians` and moves it by (0.5, 0.5), so the point lands on the rect's centre ("a
    zero-radian rotation around (-1, 0) makes the image vanish"): a square image turned 45 degrees around its centre
    just fits the rect, and the rect outside the turned image is empty.
    """
    cx, cy = (float(point[0]), float(point[1])) if point else (0.5, 0.5)
    cs, sn = math.cos(radians), math.sin(radians)
    k = 2**0.5

    def to_image(x, y):
        dx, dy = (x - 0.5) * k, (y - 0.5) * k
        return cx + cs * dx - sn * dy, cy + sn * dx + cs * dy

    def to_rect(x, y):
        dx, dy = (x - cx) / k, (y - cy) / k
        return 0.5 + cs * dx + sn * dy, 0.5 - sn * dx + cs * dy

    return to_image, to_rect


def _coverage(size, points, ss: int = 4) -> Image.Image:
    """Anti-aliased coverage ("L") of a convex polygon in pixel coordinates (pixel i spans i..i+1): ss x ss samples.
    Computed in bands of rows, so memory follows the output size."""
    w, h = size
    out = Image.new("L", (w, h), 0)
    pts = [(x * ss, y * ss) for x, y in points]
    edges = list(zip(pts, pts[1:] + pts[:1], strict=True))
    top, bottom = min(p[1] for p in pts), max(p[1] for p in pts)
    band = 64
    for b0 in range(0, h, band):
        b1 = min(h, b0 + band)
        if b1 * ss <= top or b0 * ss >= bottom:
            continue
        big = Image.new("L", (w * ss, (b1 - b0) * ss), 0)
        d = ImageDraw.Draw(big)
        # One span per sample row: the samples whose centres (j + 0.5) lie in [left, right) of the polygon there.
        for row in range(b0 * ss, b1 * ss):
            sy = row + 0.5
            xs = [
                p[0] + (sy - p[1]) * (q[0] - p[0]) / (q[1] - p[1])
                for p, q in edges
                if min(p[1], q[1]) <= sy < max(p[1], q[1])
            ]
            if len(xs) >= 2:
                j0 = max(0, math.ceil(round(min(xs), 6) - 0.5))
                j1 = min(w * ss - 1, math.ceil(round(max(xs), 6) - 0.5) - 1)
                if j1 >= j0:
                    d.rectangle([j0, row - b0 * ss, j1, row - b0 * ss], fill=255)
        out.paste(big.resize((w, b1 - b0), Image.Resampling.BOX), (0, b0))
    return out


def _intersect(a, b):
    """The overlap of two boxes (x0, y0, x1, y1), or None."""
    box = (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))
    return box if box[2] > box[0] and box[3] > box[1] else None


def _extend(img: Image.Image, lo: int, hi: int, mode: str, axis: int) -> Image.Image:
    """img over pixels lo..hi along an axis (0 across, 1 down), drawn past its edges the way a wrap mode samples."""
    size = img.size[axis]
    n = hi - lo
    out_size = (n, img.height) if axis == 0 else (img.width, n)

    def at(o):
        return (o, 0) if axis == 0 else (0, o)

    def strip(a, b, length):
        box = (a, 0, b, img.height) if axis == 0 else (0, a, img.width, b)
        return img.crop(box).resize(
            (length, img.height) if axis == 0 else (img.width, length), Image.Resampling.NEAREST
        )

    if mode in ("REPEAT", "MIRROR"):
        out = Image.new("RGBA", out_size)
        flipped = img.transpose(Image.Transpose.FLIP_LEFT_RIGHT if axis == 0 else Image.Transpose.FLIP_TOP_BOTTOM)
        k = lo // size
        while k * size < hi:
            out.paste(flipped if mode == "MIRROR" and k % 2 else img, at(k * size - lo))
            k += 1
        return out
    out = Image.new("RGBA", out_size, _WRAP_FILL.get(mode, (0, 0, 0, 0)))
    out.paste(img, at(-lo))
    if mode not in _WRAP_FILL:  # CLAMP: the edge pixels go on
        if lo < 0:
            out.paste(strip(0, 1, -lo), at(0))
        if hi > size:
            out.paste(strip(size - 1, size, hi - size), at(size - lo))
    return out


def _wrap_modes(wrap):
    """The dump's wrap pair as (horizontal, vertical) mode names; CLAMP when not set."""
    out = []
    for i in (0, 1):
        v = wrap[i] if wrap and len(wrap) > i else None
        v = "REPEAT" if v is True else str(v or "CLAMP").upper()
        out.append(v if v in ("REPEAT", "MIRROR", *_WRAP_FILL) else "CLAMP")
    return out


def _turn(rotation, point):
    """SetRotation's maps, or None when nothing turns: no rotation, or 0 around the default centre (drawn unchanged:
    addons reset with SetRotation(0), and the documentation shows no shrink at angle 0)."""
    if rotation is None:
        return None
    centred = not point or (abs(float(point[0]) - 0.5) < 1e-9 and abs(float(point[1]) - 0.5) < 1e-9)
    if float(rotation) == 0 and centred:
        return None
    return _rotation(float(rotation), point)


def _sample(img: Image.Image, size, coords=None, rotation=None, point=None, wrap=None, window=None) -> Image.Image:
    """img drawn into a w x h rect as the client samples it: SetTexCoord's 4 or 8 values (crop, flip, turn, skew),
    SetRotation (radians, rotation point) and, for coordinates past 0..1, the wrap modes of SetTexture. Only `window`
    (x0, y0, x1, y1 within the rect; default all of it) is drawn and returned, so memory follows what is visible.

    Corners are mapped exactly and the inside bilinearly (Pillow's QUAD: exact for every parallelogram, which covers
    crops, flips, rotations and shears); the client splits a non-parallelogram into two triangles instead.
    """
    w, h = size
    x0, y0, x1, y1 = window or (0, 0, w, h)
    ww, wh = x1 - x0, y1 - y0
    corners = _tex_corners(coords)
    turn = _turn(rotation, point)
    ul, ll, ur, lr = corners

    def same(a, b):
        return abs(a - b) < 1e-6

    inside = all(-1e-6 <= v <= 1 + 1e-6 for p in corners for v in p)
    if turn is None and inside and same(ul[0], ll[0]) and same(ur[0], lr[0]) and same(ul[1], ur[1]):
        if same(ll[1], lr[1]):
            # Crop and flips only: a plain resize of the window's box (antialiased when it shrinks).
            sw, sh = img.size
            u0, u1 = (ul[0] + (ur[0] - ul[0]) * x / w for x in (x0, x1))
            v0, v1 = (ul[1] + (ll[1] - ul[1]) * y / h for y in (y0, y1))
            box = tuple(min(max(v, 0.0), 1.0) * s for v, s in ((min(u0, u1), sw), (min(v0, v1), sh)))
            box += tuple(min(max(v, 0.0), 1.0) * s for v, s in ((max(u0, u1), sw), (max(v0, v1), sh)))
            if box[2] > box[0] and box[3] > box[1]:
                out = img.resize((ww, wh), Image.Resampling.BILINEAR, box=box)
                if u0 > u1:
                    out = out.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                if v0 > v1:
                    out = out.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
                return out

    def uv(x, y):
        x, y = x / w, y / h
        return _bilerp(corners, *(turn[0](x, y) if turn else (x, y)))

    quad = [list(uv(x0, y0)), list(uv(x0, y1)), list(uv(x1, y1)), list(uv(x1, y0))]  # Pillow's QUAD: UL, LL, LR, UR
    modes = _wrap_modes(wrap)
    sw, sh = img.size
    # Shrinking: scale the source down per axis first (the transform samples without averaging). The factor is the
    # most source pixels one output pixel spans along that source axis, from the quad's four edges.
    edges = [(quad[3], quad[0], ww), (quad[2], quad[1], ww), (quad[1], quad[0], wh), (quad[2], quad[3], wh)]
    size_now = [sw, sh]
    for axis in (0, 1):
        per_px = max(abs(a[axis] - b[axis]) * size_now[axis] / n for a, b, n in edges)
        if per_px > 2:
            # Keep a few pixels across a clamped axis so its edge colours survive.
            least = 1 if modes[axis] in ("REPEAT", "MIRROR") else min(size_now[axis], 4)
            size_now[axis] = max(least, round(size_now[axis] * 2 / per_px))
    if tuple(size_now) != (sw, sh):
        img = img.resize(tuple(size_now), Image.Resampling.LANCZOS)
        sw, sh = img.size
    cap = 4 * (ww + wh) + 64  # source pixels per axis: enough for anything the window can show
    for axis, n in ((0, sw), (1, sh)):
        lo, hi = min(p[axis] for p in quad), max(p[axis] for p in quad)
        if modes[axis] in ("REPEAT", "MIRROR"):
            period = 1 if modes[axis] == "REPEAT" else 2
            shift = math.floor(lo / period) * period  # whole periods change nothing
            for p in quad:
                p[axis] -= shift
            lo, hi = lo - shift, hi - shift
            if (hi - lo) * n > cap:
                # Periods smaller than an output pixel: the average colour along that axis.
                img = img.resize((1, sh) if axis == 0 else (sw, 1), Image.Resampling.BOX)
                sw, sh = img.size
                for p in quad:
                    p[axis] = 0.5
        elif (hi - lo) * n > cap:
            # Past its edges a clamped axis is constant: keep at most `cap` pixels of it (the image is then under
            # about two output pixels across, and may move by about one).
            k = max(1.0, (cap / n - 1) / 2)
            for p in quad:
                p[axis] = min(max(p[axis], -k), 1 + k)
    xs = [p[0] * sw for p in quad]
    ys = [p[1] * sh for p in quad]
    lox, hix = math.floor(min(xs)) - 2, math.ceil(max(xs)) + 2
    loy, hiy = math.floor(min(ys)) - 2, math.ceil(max(ys)) + 2
    src = _extend(_extend(img, lox, hix, modes[0], 0), loy, hiy, modes[1], 1)
    data = [round(v, 6) for x, y in zip(xs, ys, strict=True) for v in (x - lox, y - loy)]
    out = src.transform((ww, wh), Image.Transform.QUAD, data, Image.Resampling.BICUBIC, fillcolor=(0, 0, 0, 0))
    if turn:
        out.putalpha(ImageChops.multiply(out.getchannel("A"), _rotation_mask((w, h), turn, (x0, y0, x1, y1))))
    return out


def _rotation_mask(size, turn, window=None) -> Image.Image:
    """Where SetRotation's turned image lies in a w x h rect (the rest draws nothing), over `window` of it."""
    w, h = size
    x0, y0, x1, y1 = window or (0, 0, w, h)
    pts = [turn[1](x, y) for x, y in ((0, 0), (1, 0), (1, 1), (0, 1))]
    return _coverage((x1 - x0, y1 - y0), [(x * w - x0, y * h - y0) for x, y in pts])


class Renderer:
    def __init__(self, game: Game, root: Path, scale: float = 1.0):
        self.game = game
        self.root = root
        self.scale = scale
        self.fonts: dict = {}
        self.placeholders: list = []

    def px(self, v):
        return v * self.scale

    def font(self, path, size):
        key = (path, round(size * 2) / 2)
        if key in self.fonts:
            return self.fonts[key]
        f = None
        if path:
            p = Path(path)
            if not p.is_absolute():
                p = self.root / p
            try:
                f = ImageFont.truetype(str(p), max(1, round(size * self.scale)))
            except OSError:
                f = None
        if f is None:
            f = ImageFont.load_default(max(1, round(size * self.scale)))
        self.fonts[key] = f
        return f

    def texture_image(self, tex: dict, w: int, h: int, path_label: str, window=None) -> Image.Image | None:
        """The texture drawn into a w x h rect; only `window` (x0, y0, x1, y1 within it, default all) is returned."""
        win = window or (0, 0, w, h)
        size = (win[2] - win[0], win[3] - win[1])
        rotation, point = tex.get("rotation"), tex.get("rotationPoint")

        def whole(img):  # something drawn at the full size, cut to the window
            return img if win == (0, 0, w, h) else img.crop(win)

        def placeholder(label, color):
            if w * h <= 4_000_000:
                return whole(_placeholder(w, h, label, color))
            return Image.new("RGBA", size, color + (60,))

        if tex.get("color") and not (tex.get("file") or tex.get("fileID") or tex.get("atlas")):
            img = Image.new("RGBA", size, _rgba(tex["color"]))
            turn = _turn(rotation, point)
            if turn:
                img.putalpha(ImageChops.multiply(img.getchannel("A"), _rotation_mask((w, h), turn, win)))
        else:
            img = None
            coords = tex.get("coords")
            if tex.get("atlas"):
                a = self.game.atlases().get(str(tex["atlas"]).lower())
                if a:
                    sheet = self.game.image(file_id=a[0])
                    if sheet:
                        sx, sy = sheet.width / a[5], sheet.height / a[6]
                        img = sheet.crop((round(a[1] * sx), round(a[3] * sy), round(a[2] * sx), round(a[4] * sy)))
                        coords = tex.get("coords") if tex.get("coords") else None
                        sl = self.game.atlas_slices(tex["atlas"])
                        plain = not coords or list(coords) in ([0, 1, 0, 1], [0, 0, 0, 1, 1, 0, 1, 1])
                        if sl and plain and w * h <= 16_000_000:
                            # Sliced at the rect's size first; a rotation then turns the sliced picture.
                            k = self.scale / (2 if str(tex["atlas"]).lower().endswith("-2x") else 1)
                            img = _nine_slice(img, (sl[0] * sx, sl[1] * sy, sl[2] * sx, sl[3] * sy), w, h, k)
                            if _turn(rotation, point) is None:
                                return whole(img)
                            coords = None
                if img is None:
                    self.placeholders.append(("atlas", tex["atlas"], path_label))
                    return placeholder("atlas " + str(tex["atlas"]), (255, 150, 0))
            else:
                img = self.game.image(file=tex.get("file"), file_id=tex.get("fileID"))
                if img is None:
                    name = str(tex.get("file") or tex.get("fileID"))
                    key = (str(tex.get("file")).lower() if tex.get("file") is not None else None, tex.get("fileID"))
                    if key in self.game.not_local:
                        # Exists in the client but not downloaded here: grey, it is not a bug.
                        self.placeholders.append(("not downloaded", name, path_label))
                        return placeholder(name.rsplit("\\", 1)[-1], (110, 110, 120))
                    self.placeholders.append(("file", name, path_label))
                    return placeholder(name.rsplit("\\", 1)[-1], (255, 0, 255))
            if tex.get("desaturated"):
                a = img.getchannel("A")
                img = img.convert("L").convert("RGBA")
                img.putalpha(a)
            img = _sample(img, (w, h), coords, rotation, point, tex.get("wrap"), win)
        return img

    def paste(self, canvas: Image.Image, img: Image.Image, x: int, y: int, clip, additive=False):
        """Composite img at x, y (canvas pixels), limited to clip (canvas pixels: x0, y0, x1, y1)."""
        x0, y0, x1, y1 = 0, 0, canvas.width, canvas.height
        if clip:
            x0, y0, x1, y1 = max(x0, clip[0]), max(y0, clip[1]), min(x1, clip[2]), min(y1, clip[3])
        bx0, by0 = max(x, x0), max(y, y0)
        bx1, by1 = min(x + img.width, x1), min(y + img.height, y1)
        if bx1 <= bx0 or by1 <= by0:
            return
        part = img.crop((bx0 - x, by0 - y, bx1 - x, by1 - y))
        if additive:
            base = canvas.crop((bx0, by0, bx1, by1))
            rgb = Image.merge("RGB", part.split()[:3])
            a = part.getchannel("A")
            black = Image.new("RGB", part.size, (0, 0, 0))
            add = Image.composite(rgb, black, a)

            out = ImageChops.add(base.convert("RGB"), add)
            out.putalpha(base.getchannel("A"))
            canvas.paste(out, (bx0, by0))
        else:
            canvas.alpha_composite(part, (bx0, by0))

    def clip_px(self, e):
        c = e.get("clip")
        if not c:
            return None
        s = self.scale
        return (math.floor(c[0] * s), math.floor(c[1] * s), math.ceil((c[0] + c[2]) * s), math.ceil((c[1] + c[3]) * s))

    # The game's templates, drawn from their atlases (the mock builds templates without their art) ---------------------

    def atlas_image(self, name: str, w: int, h: int, tile: str | None = None) -> Image.Image | None:
        """An atlas drawn at w x h: stretched, or tiled at its own size ("h" across, "v" down)."""
        a = self.game.atlases().get(name.lower())
        if not a:
            return None
        sheet = self.game.image(file_id=a[0])
        if sheet is None:
            return None
        sx, sy = sheet.width / a[5], sheet.height / a[6]
        piece = sheet.crop((round(a[1] * sx), round(a[3] * sy), round(a[2] * sx), round(a[4] * sy)))
        w, h = max(1, round(w)), max(1, round(h))
        if tile == "h":
            pw = max(1, round(piece.width * h / max(1, piece.height)))
            unit = piece.resize((pw, h), Image.Resampling.BILINEAR)
            out = Image.new("RGBA", (w, h))
            for x in range(0, w, pw):
                out.paste(unit, (x, 0))
            return out
        if tile == "v":
            ph = max(1, round(piece.height * w / max(1, piece.width)))
            unit = piece.resize((w, ph), Image.Resampling.BILINEAR)
            out = Image.new("RGBA", (w, h))
            for y in range(0, h, ph):
                out.paste(unit, (0, y))
            return out
        return piece.resize((w, h), Image.Resampling.BILINEAR)

    def atlas_size(self, name: str):
        """An atlas's size in UI units (a "-2x" atlas has twice the pixels)."""
        a = self.game.atlases().get(name.lower())
        if not a:
            return None
        w, h = a[2] - a[1], a[4] - a[3]
        if name.lower().endswith("-2x"):
            w, h = w / 2, h / 2
        return w, h

    def draw_nine_slice(self, canvas, e, layout: str) -> bool:
        spec = NINE_SLICE.get(layout)
        if not spec:
            return False
        s = e.get("scale", 1)
        x, y, w, h = e["rect"]
        clip = self.clip_px(e)
        alpha = e.get("alpha", 1)
        sizes = {k: self.atlas_size(v[0]) for k, v in spec.items()}
        if any(v is None for v in sizes.values()):
            return False
        corners = {}
        for key, (ax, ay) in (("tl", (0, 0)), ("tr", (1, 0)), ("bl", (0, 1)), ("br", (1, 1))):
            cw, ch = (v * s for v in sizes[key])
            ox, oy = spec[key][1] * s, spec[key][2] * s
            px = x + ax * w + ox - ax * cw
            py = y + ay * h - oy - ay * ch
            corners[key] = (px, py, cw, ch)
        tl, tr, bl, br = corners["tl"], corners["tr"], corners["bl"], corners["br"]
        th, bh = sizes["top"][1] * s, sizes["bottom"][1] * s
        lw, rw = sizes["left"][0] * s, sizes["right"][0] * s
        pieces = [
            ("top", tl[0] + tl[2], tl[1], tr[0] - (tl[0] + tl[2]), th, "h"),
            ("bottom", bl[0] + bl[2], bl[1] + bl[3] - bh, br[0] - (bl[0] + bl[2]), bh, "h"),
            ("left", tl[0], tl[1] + tl[3], lw, bl[1] - (tl[1] + tl[3]), "v"),
            ("right", tr[0] + tr[2] - rw, tr[1] + tr[3], rw, br[1] - (tr[1] + tr[3]), "v"),
        ]
        for key, px, py, pw, ph, tile in pieces:
            if pw > 0 and ph > 0:
                img = self.atlas_image(spec[key][0], self.px(pw), self.px(ph), tile)
                if img:
                    self.paste(canvas, _tint(img, None, alpha), round(self.px(px)), round(self.px(py)), clip)
        for key in ("tl", "tr", "bl", "br"):
            px, py, cw, ch = corners[key]
            img = self.atlas_image(spec[key][0], self.px(cw), self.px(ch))
            if img:
                self.paste(canvas, _tint(img, None, alpha), round(self.px(px)), round(self.px(py)), clip)
        return True

    def draw_three(self, canvas, e, left: str, center: str, right: str, native_h: float) -> bool:
        """A horizontal three-piece (button, tab): end pieces scaled to the frame's height, the middle tiled."""
        x, y, w, h = e["rect"]
        sl, sc, sr = self.atlas_size(left), self.atlas_size(center), self.atlas_size(right)
        if not (sl and sc and sr) or w <= 0 or h <= 0:
            return False
        k = h / native_h
        lw, rw = sl[0] * k, sr[0] * k
        if lw + rw > w:
            f = w / (lw + rw)
            lw, rw = lw * f, rw * f
        clip = self.clip_px(e)
        alpha = e.get("alpha", 1)
        for name, px, pw, tile in (
            (left, x, lw, None),
            (center, x + lw, w - lw - rw, "h"),
            (right, x + w - rw, rw, None),
        ):
            if pw > 0.5:
                img = self.atlas_image(name, self.px(pw), self.px(h), tile)
                if img:
                    self.paste(canvas, _tint(img, None, alpha), round(self.px(px)), round(self.px(y)), clip)
        return True

    def draw_template(self, canvas, e) -> bool:
        t = e.get("template")
        if not t or not self.game.casc:
            return False
        if t == "UIPanelButtonTemplate":
            suffix = "" if e.get("enabled", True) else "-disabled"
            return self.draw_three(
                canvas,
                e,
                "128-RedButton-Left" + suffix,
                "_128-RedButton-Center" + suffix,
                "128-RedButton-Right" + suffix,
                128 / 4.2,
            )
        if t in ("PanelTabButtonTemplate", "PanelTopTabButtonTemplate"):
            if e.get("enabled", True):
                return self.draw_three(canvas, e, "uiframe-tab-left", "_uiframe-tab-center", "uiframe-tab-right", 36)
            return self.draw_three(
                canvas, e, "uiframe-activetab-left", "_uiframe-activetab-center", "uiframe-activetab-right", 42
            )
        if t in ("ButtonFrameTemplate", "PortraitFrameTemplate"):
            x, y, w, h = e["rect"]
            s = e.get("scale", 1)
            bg = self.game.image(file="Interface\\FrameGeneral\\UI-Background-Rock")
            if bg is not None and w > 4 * s and h > 23 * s:
                bw, bh = round(self.px(w - 4 * s)), round(self.px(h - 23 * s))
                ts = max(1, round(self.px(256 * s)))
                tile = bg.resize((ts, ts), Image.Resampling.BILINEAR)
                img = Image.new("RGBA", (bw, bh))
                for ty in range(0, bh, ts):
                    for tx in range(0, bw, ts):
                        img.paste(tile, (tx, ty))
                self.paste(
                    canvas,
                    _tint(img, None, e.get("alpha", 1)),
                    round(self.px(x + 2 * s)),
                    round(self.px(y + 21 * s)),
                    self.clip_px(e),
                )
            layout = "ButtonFrameTemplateNoPortrait" if e.get("noPortrait") else "PortraitFrameTemplate"
            return self.draw_nine_slice(canvas, e, layout)
        if t == "InsetFrameTemplate":
            return self.draw_nine_slice(canvas, e, "InsetFrameTemplate")
        return False

    def draw_backdrop(self, canvas, e):
        bd = e["backdrop"]
        x, y, w, h = (self.px(v) for v in e["rect"])
        ins = [self.px(v) for v in bd.get("insets", [0, 0, 0, 0])]
        clip = self.clip_px(e)
        alpha = e.get("alpha", 1)
        if bd.get("bgFile"):
            bw, bh = round(w - ins[0] - ins[1]), round(h - ins[2] - ins[3])
            if bw > 0 and bh > 0:
                src = self.game.image(file=bd["bgFile"])
                if src is None:
                    if str(bd["bgFile"]).lower().endswith("white8x8"):
                        src = Image.new("RGBA", (8, 8), (255, 255, 255, 255))
                if src is None:
                    img = _placeholder(bw, bh, str(bd["bgFile"]).rsplit("\\", 1)[-1])
                    self.placeholders.append(("file", bd["bgFile"], e["path"]))
                elif bd.get("tile") and bd.get("tileSize"):
                    ts = max(1, round(self.px(bd["tileSize"]) / self.scale * self.scale))
                    tile = src.resize((ts, ts), Image.Resampling.BILINEAR)
                    img = Image.new("RGBA", (bw, bh))
                    for ty in range(0, bh, ts):
                        for tx in range(0, bw, ts):
                            img.paste(tile, (tx, ty))
                else:
                    img = src.resize((bw, bh), Image.Resampling.BILINEAR)
                img = _tint(img, bd.get("color"), alpha)
                self.paste(canvas, img, round(x + ins[0]), round(y + ins[2]), clip)
        edge = bd.get("edgeFile")
        es = round(self.px(bd.get("edgeSize") or 0))
        if edge and es > 0 and w >= 2 * es and h >= 2 * es:
            src = self.game.image(file=edge)
            if src is None and str(edge).lower().endswith("white8x8"):
                src = Image.new("RGBA", (64, 8), (255, 255, 255, 255))
            if src is None:
                self.placeholders.append(("file", edge, e["path"]))
                return
            # The backdrop edge file: 8 cells side by side - left, right, top, bottom, and the four corners
            # (top-left, top-right, bottom-left, bottom-right); the top and bottom cells are stored turned.
            cw = src.width / 8
            cells = [src.crop((round(i * cw), 0, round((i + 1) * cw), src.height)) for i in range(8)]
            W, H = round(w), round(h)
            img = Image.new("RGBA", (W, H))

            def vstrip(cell, length):
                c = cell.resize((es, es), Image.Resampling.BILINEAR)
                out = Image.new("RGBA", (es, max(1, length)))
                for yy in range(0, length, es):
                    out.paste(c, (0, yy))
                return out

            lv = H - 2 * es
            lh = W - 2 * es
            img.paste(vstrip(cells[0], lv), (0, es))
            img.paste(vstrip(cells[1], lv), (W - es, es))
            top = vstrip(cells[2], lh).transpose(Image.Transpose.ROTATE_270)
            bottom = vstrip(cells[3], lh).transpose(Image.Transpose.ROTATE_270)
            img.paste(top, (es, 0))
            img.paste(bottom, (es, H - es))
            for i, (cx, cy) in zip(range(4, 8), [(0, 0), (W - es, 0), (0, H - es), (W - es, H - es)], strict=False):
                img.paste(cells[i].resize((es, es), Image.Resampling.BILINEAR), (cx, cy))
            img = _tint(img, bd.get("borderColor"), alpha)
            self.paste(canvas, img, round(x), round(y), clip)

    def draw_texture(self, canvas, e):
        tex = e["texture"]
        x, y, w, h = (self.px(v) for v in e["rect"])
        X, Y = round(x), round(y)
        W, H = round(x + w) - X, round(y + h) - Y
        if W <= 0 or H <= 0:
            return
        # Only the part on the canvas and inside the clip is drawn (a rect can be far larger than the canvas).
        vis = _intersect((X, Y, X + W, Y + H), (0, 0, canvas.width, canvas.height))
        clip = self.clip_px(e)
        vis = vis and (_intersect(vis, clip) if clip else vis)
        if not vis:
            return
        img = self.texture_image(tex, W, H, e["path"], (vis[0] - X, vis[1] - Y, vis[2] - X, vis[3] - Y))
        if img is None:
            return
        vertex = tex.get("vertex")
        if tex.get("gradient") and not vertex:
            vertex = None
        img = _tint(img, vertex, e.get("alpha", 1))
        for m in tex.get("masks") or []:
            mimg = self.game.image(file=m.get("file")) if m.get("file") else None
            if mimg is None:
                continue
            mx, my, mw, mh = (self.px(v) for v in m["rect"])
            MX, MY = round(mx), round(my)
            MW, MH = max(1, round(mw)), max(1, round(mh))
            full = Image.new("L", img.size, 0)
            part = _intersect(vis, (MX, MY, MX + MW, MY + MH))
            if part:
                alpha = mimg.getchannel("A")
                kx, ky = alpha.width / MW, alpha.height / MH
                box = ((part[0] - MX) * kx, (part[1] - MY) * ky, (part[2] - MX) * kx, (part[3] - MY) * ky)
                size = (part[2] - part[0], part[3] - part[1])
                full.paste(alpha.resize(size, Image.Resampling.BILINEAR, box=box), (part[0] - vis[0], part[1] - vis[1]))
            img.putalpha(ImageChops.multiply(img.getchannel("A"), full))
        self.paste(canvas, img, vis[0], vis[1], clip, additive=tex.get("blend") == "ADD")

    def draw_text(self, canvas, e):
        t = e["text"]
        clip = self.clip_px(e)
        layer = Image.new("RGBA", canvas.size)
        d = ImageDraw.Draw(layer)
        size = t["size"]
        font = self.font(t.get("fontLocal"), size)
        alpha = e.get("alpha", 1)
        lh = self.px(t.get("lineHeight", size))
        asc, desc = font.getmetrics()
        shadow = t.get("shadow")
        outline = "OUTLINE" in str(t.get("flags") or "")
        for line in t.get("lines", []):
            x = self.px(line["x"])
            base = self.px(line["y"]) + (lh - (asc + desc)) / 2 + asc
            for part in line.get("parts", []):
                if part.get("s"):
                    color = _rgba(part.get("color") or t.get("color"), alpha)
                    want = self.px(part.get("w") or 0)
                    have = font.getlength(part["s"])
                    if want > 0 and abs(have - want) > 1:
                        # Hinting rounds each glyph's advance at small sizes, so the drawn run can be wider than the
                        # layout measured (and linted); draw it apart and fit it to the measured width.
                        self._fitted_text(layer, font, part["s"], x, base, want, have, color, shadow, outline)
                        x += self.px(part["w"])
                        continue
                    if shadow:
                        ox, oy = shadow.get("offset") or [1, -1]
                        sc = _rgba(shadow.get("color"), alpha * (color[3] / 255))
                        d.text(
                            (x + ox * self.scale, base - oy * self.scale), part["s"], font=font, fill=sc, anchor="ls"
                        )
                    d.text(
                        (x, base),
                        part["s"],
                        font=font,
                        fill=color,
                        anchor="ls",
                        stroke_width=1 if outline else 0,
                        stroke_fill=(0, 0, 0, color[3]),
                    )
                elif part.get("icon") or part.get("atlas"):
                    pw = max(1, round(self.px(part["w"])))
                    ph = max(1, round(self.px(part.get("h") or size)))
                    tex = {"file": part.get("icon"), "atlas": part.get("atlas")}
                    img = self.texture_image(tex, pw, ph, e["path"])
                    if img:
                        layer.alpha_composite(img, (round(x), round(self.px(line["y"]) + (lh - ph) / 2)))
                x += self.px(part["w"])
        if clip:
            mask = Image.new("L", canvas.size, 0)
            ImageDraw.Draw(mask).rectangle([clip[0], clip[1], clip[2] - 1, clip[3] - 1], fill=255)

            layer.putalpha(ImageChops.multiply(layer.getchannel("A"), mask))
        canvas.alpha_composite(layer)

    def _fitted_text(self, layer, font, text, x, base, want, have, color, shadow, outline):
        """Draw one run of text squeezed (or stretched) horizontally to `want` pixels from its own `have`."""
        asc, desc = font.getmetrics()
        pad = 2 + round(self.scale)
        w, h = max(1, round(have) + 2 * pad), asc + desc + 2 * pad
        run = Image.new("RGBA", (w, h))
        rd = ImageDraw.Draw(run)
        if shadow:
            ox, oy = shadow.get("offset") or [1, -1]
            sc = _rgba(shadow.get("color"), color[3] / 255)
            rd.text((pad + ox * self.scale, pad + asc - oy * self.scale), text, font=font, fill=sc, anchor="ls")
        rd.text(
            (pad, pad + asc),
            text,
            font=font,
            fill=color,
            anchor="ls",
            stroke_width=1 if outline else 0,
            stroke_fill=(0, 0, 0, color[3]),
        )
        k = want / max(1.0, have)
        run = run.resize((max(1, round(w * k)), h), Image.Resampling.LANCZOS)
        dx, dy = round(x - pad * k), round(base - asc - pad)
        sx, sy = max(0, -dx), max(0, -dy)
        if sx < run.width and sy < run.height:
            layer.alpha_composite(run.crop((sx, sy, run.width, run.height)), (dx + sx, dy + sy))

    def draw_line(self, canvas, e):
        """A Line as the client draws it: a quad from the start to the end point (square ends there), `thickness`
        across, its texture or atlas stretched along the length; edges anti-aliased."""
        ln = e["line"]
        ax, ay = (self.px(v) for v in ln["from"])
        bx, by = (self.px(v) for v in ln["to"])
        t = self.px(ln.get("thickness") or 0)
        length = math.hypot(bx - ax, by - ay)
        if length < 1e-6 or t <= 0:
            return
        ux, uy = (bx - ax) / length, (by - ay) / length
        nx, ny = uy, -ux  # the texture's top side: up for a line drawn left to right
        hx, hy = nx * t / 2, ny * t / 2
        quad = [(ax + hx, ay + hy), (bx + hx, by + hy), (bx - hx, by - hy), (ax - hx, ay - hy)]
        box = (
            math.floor(min(p[0] for p in quad)),
            math.floor(min(p[1] for p in quad)),
            math.ceil(max(p[0] for p in quad)),
            math.ceil(max(p[1] for p in quad)),
        )
        # Only the part on the canvas and inside the clip is drawn (a line can run far past the canvas).
        vis = _intersect(box, (0, 0, canvas.width, canvas.height))
        clip = self.clip_px(e)
        vis = vis and (_intersect(vis, clip) if clip else vis)
        if not vis:
            return
        x0, y0 = vis[0], vis[1]
        size = (vis[2] - x0, vis[3] - y0)
        local = [(x - x0, y - y0) for x, y in quad]
        alpha = e.get("alpha", 1)
        f = ln.get("file")
        if f or ln.get("atlas"):
            # The strip's coordinates: s along the line from its top-left corner, r down across it. Only the part
            # of the strip the visible window can show is drawn, through the matching texture coordinates.
            tx, ty = local[0]
            ss = [(x - tx) * ux + (y - ty) * uy for x in (0, size[0]) for y in (0, size[1])]
            rs = [-(x - tx) * nx - (y - ty) * ny for x in (0, size[0]) for y in (0, size[1])]
            s0, s1 = max(0.0, min(ss)), min(length, max(ss))
            r0, r1 = max(0.0, min(rs)), min(t, max(rs))
            if s1 <= s0 or r1 <= r0:
                return
            corners = _tex_corners(ln.get("coords"))
            a, b, c, d = s0 / length, s1 / length, r0 / t, r1 / t
            sub = [*_bilerp(corners, a, c), *_bilerp(corners, a, d), *_bilerp(corners, b, c), *_bilerp(corners, b, d)]
            sw, sh = max(1, round(s1 - s0)), max(1, round(r1 - r0))
            tex = {
                "file": f if isinstance(f, str) else None,
                "fileID": f if isinstance(f, int | float) else None,
                "atlas": ln.get("atlas"),
                "coords": sub,
            }
            strip = self.texture_image(tex, sw, sh, e["path"])
            strip = _extend(_extend(strip, -2, sw + 2, "CLAMP", 0), -2, sh + 2, "CLAMP", 1)
            # Output pixel (x, y) -> strip pixel.
            kx, ky = sw / (s1 - s0), sh / (r1 - r0)
            data = (
                ux * kx,
                uy * kx,
                -(tx * ux + ty * uy + s0) * kx + 2,
                -nx * ky,
                -ny * ky,
                (tx * nx + ty * ny - r0) * ky + 2,
            )
            img = strip.transform(
                size, Image.Transform.AFFINE, tuple(round(v, 6) for v in data), Image.Resampling.BILINEAR
            )
            img = _tint(img, ln.get("vertex"), alpha)
        else:
            color = ln.get("color") or [1, 1, 1, 1]
            vertex = ln.get("vertex") or [1, 1, 1, 1]
            img = Image.new("RGBA", size, _rgba([color[i] * vertex[i] for i in range(4)], alpha))
        img.putalpha(ImageChops.multiply(img.getchannel("A"), _coverage(size, local)))
        self.paste(canvas, img, x0, y0, clip)

    def render(self, doc: dict, crop: str = "window") -> tuple[Image.Image, tuple]:
        sw, sh = doc["screen"]
        canvas = Image.new("RGBA", (round(sw * self.scale), round(sh * self.scale)), (24, 26, 30, 255))
        # A quiet checker so transparent parts of the UI read as such.
        d = ImageDraw.Draw(canvas)
        step = round(16 * self.scale)
        for yy in range(0, canvas.height, step):
            for xx in range((yy // step) % 2 * step, canvas.width, 2 * step):
                d.rectangle([xx, yy, xx + step - 1, yy + step - 1], fill=(30, 32, 37, 255))
        bounds = None
        for e in doc.get("regions", []):
            skinned = self.draw_template(canvas, e)
            if e.get("backdrop"):
                self.draw_backdrop(canvas, e)
            if e.get("nineSlice"):
                skinned = self.draw_nine_slice(canvas, e, e["nineSlice"]) or skinned
            if skinned:
                e = dict(e, texture=None, skinned=True)
            if e.get("texture"):
                self.draw_texture(canvas, e)
            if e.get("text"):
                self.draw_text(canvas, e)
            if e.get("line"):
                self.draw_line(canvas, e)
            if e.get("texture") or e.get("text") or e.get("backdrop") or e.get("line") or e.get("skinned"):
                r = e["rect"]
                if e.get("clip"):
                    c = e["clip"]
                    r = [
                        max(r[0], c[0]),
                        max(r[1], c[1]),
                        min(r[0] + r[2], c[0] + c[2]) - max(r[0], c[0]),
                        min(r[1] + r[3], c[1] + c[3]) - max(r[1], c[1]),
                    ]
                if r[2] > 0 and r[3] > 0:
                    b = (r[0], r[1], r[0] + r[2], r[1] + r[3])
                    bounds = (
                        b
                        if bounds is None
                        else (min(bounds[0], b[0]), min(bounds[1], b[1]), max(bounds[2], b[2]), max(bounds[3], b[3]))
                    )
        box = (0, 0, sw, sh)
        if crop == "window" and doc.get("window"):
            wr = doc["window"]["rect"]
            box = (wr[0], wr[1], wr[0] + wr[2], wr[1] + wr[3])
            if bounds:  # popups and pieces outside the window are part of the picture
                box = (min(box[0], bounds[0]), min(box[1], bounds[1]), max(box[2], bounds[2]), max(box[3], bounds[3]))
        elif crop in ("content", "window") and bounds:
            box = bounds
        m = 12
        box = (max(0, box[0] - m), max(0, box[1] - m), min(sw, box[2] + m), min(sh, box[3] + m))
        px = tuple(round(v * self.scale) for v in box)
        return canvas.crop(px), box


def lint_overlay(img: Image.Image, box, findings, scale: float) -> Image.Image:
    out = img.copy()
    d = ImageDraw.Draw(out)
    colors = {
        "text-truncated": (255, 200, 0),
        "text-overlap": (255, 80, 80),
        "overlap": (255, 0, 255),
        "outside-window": (0, 200, 255),
        "missing-glyph": (120, 255, 120),
    }
    for i, f in enumerate(findings, 1):
        r = f.get("rect")
        if not r:
            continue
        x0, y0 = (r[0] - box[0]) * scale, (r[1] - box[1]) * scale
        x1, y1 = x0 + r[2] * scale, y0 + r[3] * scale
        c = colors.get(f.get("rule"), (255, 255, 255))
        d.rectangle([x0, y0, max(x0 + 1, x1), max(y0 + 1, y1)], outline=c + (255,), width=2)
        d.text((x0 + 2, y0 - 11), str(i), fill=c + (255,))
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Commands


def _dumps(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(p for p in path.glob("*.json") if not p.stem.endswith("lint"))


def _lint_findings(dump_dir: Path) -> list[dict]:
    out = []
    for p in sorted(dump_dir.glob("*lint.json")):
        out += json.loads(p.read_text(encoding="utf-8")).get("findings", [])
    return out


def cmd_fonts(a):
    c = casc_mod.Casc(Path(a.game))
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for name in DEFAULT_FONTS + (a.file or []):
        raw = c.read(name)
        if raw:
            (out / name.replace("/", "\\").rsplit("\\", 1)[-1]).write_bytes(raw)
            n += 1
    print(f"wowui: {n} fonts written to {out}")


def cmd_atlases(a):
    g = Game(Path(a.game), {})
    if not (a.out or a.search is not None or a.sheet):
        sys.exit("wowui: atlases wants --out, --search or --sheet")
    code = 0
    if a.out:
        atl = g.atlases()
        lines = []
        for name, v in sorted(atl.items()):
            w, h = (v[7] or (v[2] - v[1])), (v[8] or (v[4] - v[3]))
            lines.append(f"{name}	{w}	{h}")
        Path(a.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wowui: {len(lines)} atlases written to {a.out}")
    if a.search is not None or a.sheet:
        code = visual.atlas_tools(a, g, Renderer(g, Path("."), 1.0))
    return code


SIZES_SCHEMA = "wowui-sizes/1"


def image_size(raw: bytes) -> tuple[int, int] | None:
    """Width and height from an image file's header (BLP1/BLP2, TGA, PNG, JPEG...), without decoding its pixels."""
    if raw[:4] in (b"BLP1", b"BLP2") and len(raw) >= 20:
        return struct.unpack_from("<II", raw, 12)
    try:
        with Image.open(io.BytesIO(raw)) as img:
            return img.size
    except Exception:  # noqa: BLE001
        return None


def cmd_files(a):
    """Which of the paths a dump run asked GetFileIDFromPath about (and drew) exist in the client: fileID<TAB>path.
    With --sizes, also a JSON of facts for CI: those files' IDs and pixel sizes and the asked atlases' sizes."""
    if not a.out and not a.sizes:
        print("wowui files: give --out, --sizes or both", file=sys.stderr)
        return 2
    c = casc_mod.Casc(Path(a.game))
    dump = Path(a.dump)
    paths, atlas_names = set(), set()
    for p in dump.glob("*files-asked.txt"):
        paths.update(x.strip() for x in p.read_text(encoding="utf-8").splitlines() if x.strip())
    for p in dump.glob("*atlases-asked.txt"):
        atlas_names.update(x.strip() for x in p.read_text(encoding="utf-8").splitlines() if x.strip())
    for p in _dumps(dump):
        doc = json.loads(p.read_text(encoding="utf-8"))
        for e in doc.get("regions", []):
            tex = e.get("texture") or {}
            for f in (
                tex.get("file"),
                (e.get("line") or {}).get("file"),
                (e.get("backdrop") or {}).get("bgFile"),
                (e.get("backdrop") or {}).get("edgeFile"),
            ):
                if isinstance(f, str) and f:
                    paths.add(f)
            for name in (tex.get("atlas"), (e.get("line") or {}).get("atlas")):
                if isinstance(name, str) and name:
                    atlas_names.add(name)
    addons = {}
    for spec in a.addon or []:
        k, _, v = spec.partition("=")
        addons[k] = Path(v)
    game = Game(None, addons) if addons else None
    lines, files = [], {}
    for path in sorted(paths):
        if path.lower().replace("/", "\\").startswith("interface\\addons\\"):
            # An addon's own files are not in the client's storage; their sizes come from --addon folders.
            raw = game._addon_file(path) if game else None
            size = image_size(raw) if raw else None
            if size:
                files[path.replace("/", "\\")] = {"size": list(size)}
            continue
        p = path.replace("/", "\\")
        tries = [p] if "." in p.rsplit("\\", 1)[-1] else []
        tries += [p + ".blp", p + ".tga"]
        hit = next((t for t in tries if c.file_id(t) is not None), None)
        if hit is None:
            continue
        fid = c.file_id(hit)
        lines.append(f"{fid}\t{path}")
        entry = {"id": fid}
        if a.sizes:
            try:
                raw = c.read(hit)
            except Exception:  # noqa: BLE001
                raw = None
            size = image_size(raw) if raw else None  # None: streamed and not downloaded yet
            if size:
                entry["size"] = list(size)
        files[p] = entry
    if a.out:
        Path(a.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"wowui: {len(lines)} of {len(paths)} paths exist in the client; written to {a.out}")
    if a.sizes:
        g = Game(None, {})
        g.casc = c  # the storage opened above
        known = g.atlases()
        if atlas_names and not known:
            print("wowui files: the client's atlas tables could not be read; no sizes file written", file=sys.stderr)
            return 2
        atlases = {}
        for name in sorted(atlas_names):
            v = known.get(name.lower())
            if v:
                atlases[name] = [v[7] or (v[2] - v[1]), v[8] or (v[4] - v[3])]
        doc = {"schema": SIZES_SCHEMA, "files": files, "atlases": atlases}
        Path(a.sizes).write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        sized = sum(1 for v in files.values() if "size" in v)
        print(
            f"wowui: sizes of {sized} files and {len(atlases)} of {len(atlas_names)} atlases written to {a.sizes}"
            + (f" ({len(files) - sized} files without a size: not downloaded)" if len(files) > sized else "")
        )
    return 0


def cmd_render(a):
    addons = {}
    for spec in a.addon or []:
        k, _, v = spec.partition("=")
        addons[k] = Path(v)
    game = Game(Path(a.game) if a.game else None, addons)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    dump = Path(a.dump)
    findings = _lint_findings(dump if dump.is_dir() else dump.parent) if a.lint else []
    only = {v.strip() for v in (a.only or "").split(",") if v.strip()}
    for p in _dumps(dump):
        doc = json.loads(p.read_text(encoding="utf-8"))
        if doc.get("schema") != "wowui-dump/1":
            continue
        if only and doc.get("view") not in only and p.stem not in only:
            continue
        r = Renderer(game, Path(a.root), a.scale)
        img, box = r.render(doc, a.crop)
        img.convert("RGB").save(out / (p.stem + ".png"), optimize=True)
        line = f"wowui: {p.stem}.png {img.width}x{img.height}"
        if r.placeholders:
            kinds = {}
            for kind, name, _ in r.placeholders:
                kinds.setdefault(kind, set()).add(str(name))
            line += " placeholders: " + ", ".join(f"{len(v)} {k}" for k, v in kinds.items())
        print(line)
        if a.lint:
            mine = [f for f in findings if f.get("view") == doc.get("view")]
            lint_overlay(img, box, mine, a.scale).convert("RGB").save(out / (p.stem + ".lint.png"), optimize=True)
            for i, f in enumerate(mine, 1):
                print(f"   {i}. [{f['rule']}] {f['message']}")
    if game.missing and a.verbose:
        print("wowui: not found: " + ", ".join(sorted(game.missing)[:40]))


def cmd_lint(a):
    findings = _lint_findings(Path(a.dump))
    keys = set()
    if a.baseline:
        for line in Path(a.baseline).read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                keys.add(line.strip())
    fresh = []
    for f in findings:
        k = f"{f.get('view')} | {f['key']}"
        mark = "  " if k in keys else "+ "
        if k not in keys:
            fresh.append(f)
        print(f"{mark}{f.get('view')}: [{f['rule']}] {f['message']}")
    print(
        f"wowui: {len(findings)} findings, {len(fresh)} not in the baseline"
        if a.baseline
        else f"wowui: {len(findings)} findings"
    )
    return 1 if (a.baseline and fresh) else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="wowui", description=__doc__.split("\n")[0])
    ap.add_argument("--version", action="version", version=__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fonts", help="copy the client's fonts out of CASC")
    p.add_argument("--game", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--file", action="append", help="another game path to copy")
    p.set_defaults(fn=cmd_fonts)
    p = sub.add_parser("atlases", help="list, search or draw the client's atlases")
    p.add_argument("--game", required=True)
    p.add_argument("--out", help="write every atlas name and size to this file")
    visual.add_atlas_options(p)
    p.set_defaults(fn=cmd_atlases)
    p = sub.add_parser("files", help="which files a dump asked for exist in the client")
    p.add_argument("--game", required=True)
    p.add_argument("--dump", required=True)
    p.add_argument("--out", help="fileID<TAB>path list for the dump's --files")
    p.add_argument("--sizes", help="JSON of file IDs and pixel sizes and atlas sizes for the dump's --sizes")
    p.add_argument("--addon", action="append", help="Name=folder: also record the sizes of an addon's own files")
    p.set_defaults(fn=cmd_files)
    p = sub.add_parser("render", help="draw dumps as PNG")
    p.add_argument("--dump", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--game")
    p.add_argument("--addon", action="append", help="Name=folder: an addon's files (default: the game's AddOns)")
    p.add_argument("--root", default=".", help="folder relative font paths in the dump start from")
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--crop", choices=["window", "content", "screen"], default="window")
    p.add_argument("--lint", action="store_true", help="also write <view>.lint.png")
    p.add_argument("--only", help="comma-separated view names (or dump file names) to draw; default all")
    p.add_argument("--verbose", action="store_true")
    p.set_defaults(fn=cmd_render)
    p = sub.add_parser("lint", help="print the dump's lint findings")
    p.add_argument("--dump", required=True)
    p.add_argument("--baseline")
    p.set_defaults(fn=cmd_lint)
    p = sub.add_parser("check", help="static safety check of an addon's Lua source")
    check_mod.add_arguments(p)
    p.set_defaults(fn=check_mod.run)
    visual.add_commands(sub)
    p = sub.add_parser("api", help="look a function, event, enum or structure up in the client's API documentation")
    apidoc.add_arguments(p)
    p.set_defaults(fn=apidoc.run)
    a = ap.parse_args(argv)
    return a.fn(a) or 0


if __name__ == "__main__":
    sys.exit(main())
