# /// script
# requires-python = ">=3.15"
# dependencies = ["pillow>=11"]
# ///
"""Tests for the Python side, without a game install. From the repository root:

    uv run --script tests/test_cli.py

Needs `lua` (5.1) on PATH: it dumps the example addon first, then renders and lints that dump.
"""

from __future__ import annotations

import io
import json
import math
import os
import argparse
import contextlib
import io
import json
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

import casc  # noqa: E402
import check  # noqa: E402
import db2  # noqa: E402
import visual  # noqa: E402
import wowui  # noqa: E402
from PIL import Image, ImageSequence  # noqa: E402


def test_name_hash():
    # Bob Jenkins' lookup3 test vectors (hashlittle2 with both seeds 0).
    assert casc._hashlittle2(b"") == (0xDEADBEEF, 0xDEADBEEF)
    assert casc._hashlittle2(b"Four score and seven years ago") == (0x17770551, 0xCE7226E6)
    assert casc.name_hash("fonts/frizqt__.ttf") == casc.name_hash("FONTS\\FRIZQT__.TTF")


def test_blte_plain_and_zlib():
    import zlib

    plain = b"BLTE" + struct.pack(">I", 0) + b"Nhello"
    assert casc.blte(plain) == b"hello"
    z = b"Z" + zlib.compress(b"world")
    head = struct.pack(">I", 8 + 4 + 24) + b"\x0f" + (1).to_bytes(3, "big") + struct.pack(">II", len(z), 5) + b"\0" * 16
    assert casc.blte(b"BLTE" + head + z) == b"world"


def _wdc5(rows):
    """A one-section WDC5 file with two 32-bit plain fields per record."""
    fields = 2
    rec = b"".join(struct.pack("<II", a, b) for a, b in rows)
    header = b"WDC5" + struct.pack("<I", 5) + b"\0" * 128
    header += struct.pack(
        "<9I2H7I", len(rows), fields, 8, 0, 0, 0, 1, len(rows), 0, 0, 0, fields, 0, 0, 24 * fields, 0, 0, 1
    )
    section_at = len(header) + 40 + 4 * fields + 24 * fields
    header += struct.pack("<Q8I", 0, section_at, len(rows), 0, 0, 0, 0, 0, 0)
    header += b"".join(struct.pack("<hH", 0, 4 * i) for i in range(fields))
    header += b"".join(struct.pack("<HHIIIII", 32 * i, 32, 0, 0, 0, 0, 0) for i in range(fields))
    return header + rec


def test_db2_plain_fields():
    d = db2.DB2(_wdc5([(7, 100), (9, 200)]))
    assert list(d.rows()) == [(7, [7, 100]), (9, [9, 200])]


RED, BLUE = (255, 0, 0, 255), (0, 0, 255, 255)


def _halves(size=8):
    """A source texture: the left half red, the right half blue."""
    img = Image.new("RGBA", (size, size), BLUE)
    img.paste(RED, (0, 0, size // 2, size))
    return img


def _render(regions, addons=None, size=(40, 40)):
    """Draw a hand-made dump through the renderer (no game install: addon files only)."""
    doc = {"schema": "wowui-dump/1", "view": "t", "screen": list(size), "regions": regions}
    img, _ = wowui.Renderer(wowui.Game(None, addons or {}), ROOT, 1.0).render(doc, "screen")
    return img


def _texture(rect, **tex):
    return {"id": 1, "kind": "Texture", "path": "t", "rect": rect, "alpha": 1, "texture": tex}


def test_texcoords_flip_and_crop():
    img = Image.new("RGBA", (4, 2))
    img.putpixel((0, 0), (255, 0, 0, 255))
    out = wowui._sample(img, (2, 2), [0, 0.5, 0, 1])
    assert out.size == (2, 2)
    assert out.getpixel((0, 0))[0] > 100, "the crop keeps the red corner"
    flipped = wowui._sample(img, (2, 2), [0.5, 0, 0, 1])
    assert flipped.getpixel((1, 0))[0] > 100, "flipped: the red corner is on the right"


def test_image_size_from_headers():
    blp = b"BLP2" + struct.pack("<I", 1) + bytes([2, 8, 7, 1]) + struct.pack("<II", 256, 128) + bytes(64)
    assert wowui.image_size(blp) == (256, 128), "BLP2 header"
    blp1 = b"BLP1" + struct.pack("<II", 1, 8) + struct.pack("<II", 32, 16) + bytes(64)
    assert wowui.image_size(blp1) == (32, 16), "BLP1 header"
    buf = io.BytesIO()
    Image.new("RGBA", (24, 12)).save(buf, "PNG")
    assert wowui.image_size(buf.getvalue()) == (24, 12)
    buf = io.BytesIO()
    Image.new("RGBA", (5, 7)).save(buf, "TGA")
    assert wowui.image_size(buf.getvalue()) == (5, 7)
    assert wowui.image_size(b"not an image") is None


def test_texcoords_eight_values():
    src = _halves()
    mirror = wowui._sample(src, (16, 16), [1, 0, 1, 1, 0, 0, 0, 1])
    assert mirror.getpixel((3, 8)) == BLUE and mirror.getpixel((12, 8)) == RED, "mirrored left to right"
    # The quad's top edge samples the image's left column, bottom to top: the image turned a quarter clockwise.
    turned = wowui._sample(src, (16, 16), [0, 1, 1, 1, 0, 0, 1, 0])
    assert turned.getpixel((8, 3)) == RED and turned.getpixel((8, 12)) == BLUE, "a quarter turn"
    # A shear: the top edge samples x 0..0.5, the bottom edge x 0.5..1 (the red/blue border runs diagonally).
    sheared = wowui._sample(src, (16, 16), [0, 0, 0.5, 1, 0.5, 0, 1, 1])
    assert sheared.getpixel((12, 1)) == RED and sheared.getpixel((3, 14)) == BLUE, "sheared"
    assert sheared.getpixel((8, 1)) == RED and sheared.getpixel((8, 14)) == BLUE


def test_texcoords_past_one_follow_the_wrap_mode():
    src = _halves()
    wide = [0, 2, 0, 1]  # twice the image across
    rep = wowui._sample(src, (32, 8), wide, wrap=["REPEAT", "CLAMP"])
    assert [rep.getpixel((x, 4)) for x in (4, 12, 20, 28)] == [RED, BLUE, RED, BLUE]
    mirror = wowui._sample(src, (32, 8), wide, wrap=["MIRROR", "CLAMP"])
    assert [mirror.getpixel((x, 4)) for x in (4, 12, 20, 28)] == [RED, BLUE, BLUE, RED]
    clamp = wowui._sample(src, (32, 8), wide)  # the client's default: the edge pixels go on
    assert [clamp.getpixel((x, 4)) for x in (4, 12, 20, 28)] == [RED, BLUE, BLUE, BLUE]
    empty = wowui._sample(src, (32, 8), wide, wrap=["CLAMPTOBLACKADDITIVE", "CLAMP"])
    assert empty.getpixel((28, 4))[3] == 0 and empty.getpixel((4, 4)) == RED


def test_rotation_quarter_turn_lands_in_the_expected_halves():
    with tempfile.TemporaryDirectory() as tmp:
        _halves().save(Path(tmp) / "halves.png")
        tex = {"file": "Interface\\AddOns\\Test\\halves", "rotation": math.pi / 2}
        img = _render([_texture([0, 0, 64, 64], **tex)], {"Test": Path(tmp)}, (64, 64))
        bg = _render([], size=(64, 64))
    # Counter-clockwise a quarter turn: the image's left (red) half goes to the bottom. SetRotation also scales the
    # image by 2^-0.5 around the rect's centre, so the rect's border stays empty.
    assert img.getpixel((32, 42)) == RED and img.getpixel((32, 52)) == RED
    assert img.getpixel((32, 22)) == BLUE and img.getpixel((32, 12)) == BLUE
    assert img.getpixel((3, 3)) == bg.getpixel((3, 3)) and img.getpixel((32, 3)) == bg.getpixel((32, 3))


def test_rotation_45_leaves_the_corners_empty():
    with tempfile.TemporaryDirectory() as tmp:
        Image.new("RGBA", (8, 8), (255, 255, 255, 255)).save(Path(tmp) / "white.png")
        tex = {"file": "Interface\\AddOns\\Test\\white", "rotation": -math.pi / 4, "vertex": [0, 1, 0, 1]}
        img = _render([_texture([0, 0, 64, 64], **tex)], {"Test": Path(tmp)}, (64, 64))
        bg = _render([], size=(64, 64))
    assert img.getpixel((32, 32)) == (0, 255, 0, 255), "the centre is drawn, with the vertex colour"
    assert img.getpixel((32, 3)) == (0, 255, 0, 255), "the turned square reaches the middle of each edge"
    for p in ((2, 2), (61, 2), (2, 61), (61, 61), (8, 8)):
        assert img.getpixel(p) == bg.getpixel(p), f"corner {p} stays empty"
    edge = img.getpixel((16, 15))  # the diamond's edge (x + y = 32) halves this pixel: anti-aliased
    assert bg.getpixel((16, 15))[1] < edge[1] < 255, edge


def test_rotation_point():
    # A zero turn around the image's top-left corner puts that corner at the rect's centre (the client's formula).
    out = wowui._sample(Image.new("RGBA", (8, 8), RED), (64, 64), rotation=0, point=[0, 0])
    # The image (scaled by 2^-0.5) then covers 0.5..1.2 of the rect: its bottom-right part.
    assert out.getpixel((48, 48)) == RED and out.getpixel((62, 62)) == RED
    assert all(out.getpixel(p)[3] == 0 for p in ((16, 16), (48, 16), (16, 48), (30, 30)))


def _line(a, b, thickness, **extra):
    return {
        "id": 1,
        "kind": "Line",
        "path": "l",
        "rect": [0, 0, 1, 1],
        "alpha": 1,
        "line": dict(extra, **{"from": a, "to": b, "thickness": thickness}),
    }


def test_line_one_pixel_covers_its_row():
    img = _render([_line([5, 10.5], [35, 10.5], 1, color=[1, 1, 1, 1])])
    bg = _render([])
    assert all(img.getpixel((x, 10)) == (255, 255, 255, 255) for x in range(5, 35))
    assert img.getpixel((20, 9)) == bg.getpixel((20, 9)) and img.getpixel((20, 11)) == bg.getpixel((20, 11))
    assert img.getpixel((4, 10)) == bg.getpixel((4, 10)) and img.getpixel((35, 10)) == bg.getpixel((35, 10)), (
        "butt ends"
    )


def test_line_diagonal_is_antialiased():
    img = _render([_line([5, 5], [35, 35], 3, color=[1, 1, 1, 1])])
    bg = _render([])
    for p in ((15, 15), (20, 20), (25, 25)):
        assert img.getpixel(p) == (255, 255, 255, 255), f"centre pixel {p} fully covered"
    edge = img.getpixel((20, 22))  # its centre is 1.41 from the line, the half thickness is 1.5: partly covered
    assert bg.getpixel((20, 22))[0] < edge[0] < 255, edge
    assert img.getpixel((20, 26)) == bg.getpixel((20, 26))


def test_line_texture_runs_along_it():
    with tempfile.TemporaryDirectory() as tmp:
        src = Image.new("RGBA", (8, 2), BLUE)
        src.paste(RED, (0, 0, 8, 1))
        src.save(Path(tmp) / "stripe.png")
        img = _render([_line([4, 20], [36, 20], 4, file="Interface\\AddOns\\Test\\stripe")], {"Test": Path(tmp)})
    # Drawn left to right, the texture's top row is the line's upper half.
    assert img.getpixel((20, 18)) == RED and img.getpixel((20, 21)) == BLUE


def test_line_texture_vertical_and_right_to_left():
    with tempfile.TemporaryDirectory() as tmp:
        src = Image.new("RGBA", (8, 2), BLUE)
        src.paste(RED, (0, 0, 8, 1))
        src.save(Path(tmp) / "stripe.png")
        f = "Interface\\AddOns\\Test\\stripe"
        down = _render([_line([20, 4], [20, 36], 4, file=f)], {"Test": Path(tmp)})
        back = _render([_line([36, 20], [4, 20], 4, file=f)], {"Test": Path(tmp)})
    # The texture turns with the line: its top is on the left of the direction of travel.
    assert down.getpixel((21, 20)) == RED and down.getpixel((18, 20)) == BLUE, "drawn downwards: top on the right"
    assert back.getpixel((20, 21)) == RED and back.getpixel((20, 18)) == BLUE, "drawn right to left: top below"


def _atlas_game(sheet, name, slices=None):
    """A Game without a client whose atlas table holds one atlas covering `sheet` (the tables' row layout)."""
    game = wowui.Game(None, {})
    game._atlases = {name: (999, 0, sheet.width, 0, sheet.height, sheet.width, sheet.height, 0, 0, 7)}
    game._images[(None, 999)] = sheet
    if slices:
        game._slices[7] = slices
    return game


def test_line_with_an_atlas():
    sheet = Image.new("RGBA", (16, 4), BLUE)
    sheet.paste(RED, (0, 0, 8, 4))
    game = _atlas_game(sheet, "test-line")
    doc = {"schema": "wowui-dump/1", "screen": [40, 40], "regions": [_line([4, 20], [36, 20], 4, atlas="test-line")]}
    img, _ = wowui.Renderer(game, ROOT, 1.0).render(doc, "screen")
    assert img.getpixel((10, 19)) == RED and img.getpixel((30, 19)) == BLUE, "stretched along the line"


def test_rotated_nine_slice_keeps_its_corners():
    sheet = Image.new("RGBA", (20, 20), RED)
    sheet.paste(BLUE, (4, 4, 16, 16))
    game = _atlas_game(sheet, "test-panel", (4, 4, 4, 4, 0))
    tex = {"atlas": "test-panel", "rotation": math.pi / 2}
    doc = {"schema": "wowui-dump/1", "screen": [64, 64], "regions": [_texture([0, 0, 64, 64], **tex)]}
    img, _ = wowui.Renderer(game, ROOT, 1.0).render(doc, "screen")
    # Sliced at 64 x 64 (a 4 px border), then turned and scaled by 2^-0.5: the border is about 3 px, from y 9.4.
    assert img.getpixel((32, 11)) == RED and img.getpixel((32, 16)) == BLUE


def test_rotation_zero_draws_unchanged():
    src = _halves()
    plain = wowui._sample(src, (16, 16))
    assert wowui._sample(src, (16, 16), rotation=0).tobytes() == plain.tobytes()
    assert wowui._sample(src, (16, 16), rotation=0, point=[0.5, 0.5]).tobytes() == plain.tobytes()


def test_colour_texture_rotation():
    img = _render([_texture([0, 0, 64, 64], color=[1, 1, 0, 1], rotation=math.pi / 4)], size=(64, 64))
    bg = _render([], size=(64, 64))
    assert img.getpixel((32, 32)) == (255, 255, 0, 255) and img.getpixel((3, 3)) == bg.getpixel((3, 3))


def test_wrap_fills_and_vertical_modes():
    src = _halves()
    wide = [0, 2, 0, 1]
    assert wowui._sample(src, (32, 8), wide, wrap=["CLAMPTOBLACK", "CLAMP"]).getpixel((28, 4)) == (0, 0, 0, 255)
    assert wowui._sample(src, (32, 8), wide, wrap=["CLAMPTOWHITE", "CLAMP"]).getpixel((28, 4)) == (255,) * 4
    tall = src.transpose(Image.Transpose.TRANSPOSE)  # red on top, blue below
    rep = wowui._sample(tall, (8, 32), [0, 1, 0, 2], wrap=["CLAMP", "REPEAT"])
    assert [rep.getpixel((4, y)) for y in (4, 12, 20, 28)] == [RED, BLUE, RED, BLUE]
    mirror = wowui._sample(tall, (8, 32), [0, 1, 0, 2], wrap=["CLAMP", "MIRROR"])
    assert [mirror.getpixel((4, y)) for y in (4, 12, 20, 28)] == [RED, BLUE, BLUE, RED]


def test_shrinking_is_filtered_per_axis():
    # One-pixel stripes across, turned a quarter into 64 x 64: 8 source columns per output pixel along one axis, none
    # along the other. Unfiltered, the output would alias to near black or white.
    src = Image.new("RGBA", (512, 64), (0, 0, 0, 255))
    for x in range(0, 512, 2):
        src.paste((255, 255, 255, 255), (x, 0, x + 1, 64))
    out = wowui._sample(src, (64, 64), [0, 1, 1, 1, 0, 0, 1, 0])
    values = [out.getpixel((x, y))[0] for x in range(8, 56, 5) for y in range(8, 56, 5)]
    assert all(90 < v < 165 for v in values), values


def test_near_axis_aligned_coords_take_the_plain_path():
    src = _halves()
    exact = wowui._sample(src, (16, 16), [0, 0.5, 0, 1])
    noisy = wowui._sample(src, (16, 16), [1e-9, 0, 0, 1 - 1e-9, 0.5, 1e-9, 0.5, 1])
    assert noisy.tobytes() == exact.tobytes()


def test_huge_geometry_stays_bounded():
    start = time.perf_counter()
    # A long diagonal mostly off the canvas (e.g. in a scrolled-away child): only the visible part is drawn.
    img = _render([_line([0, 0], [20000, 20000], 3, color=[1, 1, 1, 1])])
    assert img.getpixel((20, 20)) == (255, 255, 255, 255)
    with tempfile.TemporaryDirectory() as tmp:
        _halves().save(Path(tmp) / "halves.png")
        f = "Interface\\AddOns\\Test\\halves"
        # A textured line far longer than the canvas, and a texture rect far larger than it.
        _render([_line([-30000, 20], [30000, 20], 4, file=f)], {"Test": Path(tmp)})
        big = _render([_texture([-20000, -20000, 40040, 40040], file=f, rotation=0.3)], {"Test": Path(tmp)})
        assert big.getpixel((20, 20))[3] == 255
    huge = [0, 1e5, 0, 1e5]
    mean = wowui._sample(_halves(), (64, 64), huge, wrap=["REPEAT", "REPEAT"])
    r, g, b, a = mean.getpixel((32, 32))
    assert 100 < r < 155 and 100 < b < 155 and a == 255, "periods under a pixel average out"
    clamped = wowui._sample(_halves(), (64, 16), [0, 1e5, 0, 1])
    assert clamped.getpixel((32, 8)) == BLUE, "past the image: its right edge, clamped"
    wowui._sample(_halves(), (64, 64), huge, wrap=["MIRROR", "CLAMPTOBLACK"], rotation=1)
    assert time.perf_counter() - start < 10


def test_render_is_deterministic_across_processes():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        _halves().save(tmp / "halves.png")
        f = "Interface\\AddOns\\Test\\halves"
        regions = [
            _texture([2, 2, 30, 20], file=f, rotation=0.7, rotationPoint=[0.3, 0.6]),
            _texture([20, 20, 16, 16], file=f, coords=[0, 0.1, 0.2, 1, 1, 0, 0.9, 0.8], wrap=["MIRROR", "REPEAT"]),
            _line([3, 37], [37, 9], 2.5, color=[1, 0.8, 0, 0.9]),
            _line([2, 30], [38, 34], 3, file=f),
        ]
        doc = {"schema": "wowui-dump/1", "view": "t", "screen": [40, 40], "regions": regions}
        (tmp / "t.json").write_text(json.dumps(doc), encoding="utf-8")
        out = []
        for seed in ("1", "2"):  # separate interpreters, different hash seeds
            dest = tmp / ("png" + seed)
            cmd = [sys.executable, str(ROOT / "python" / "wowui.py"), "render", "--dump", str(tmp / "t.json")]
            cmd += ["--out", str(dest), "--addon", f"Test={tmp}", "--crop", "screen"]
            env = dict(os.environ, PYTHONHASHSEED=seed)
            subprocess.run(cmd, check=True, env=env, stdout=subprocess.DEVNULL)
            out.append((dest / "t.png").read_bytes())
    assert out[0] == out[1]


def test_nine_slice_atlas_keeps_corners():
    piece = Image.new("RGBA", (10, 10), (0, 0, 255, 255))
    for x in range(10):
        for y in range(10):
            if x < 2 or y < 2:
                piece.putpixel((x, y), (255, 0, 0, 255))
    out = wowui._nine_slice(piece, (2, 2, 2, 2), 40, 30, 1.0)
    assert out.size == (40, 30)
    assert out.getpixel((1, 1))[:3] == (255, 0, 0), "the corner stays at its own size"
    assert out.getpixel((3, 3))[:3] == (0, 0, 255), "the centre stretches, not the corner"
    small = wowui._nine_slice(piece, (2, 2, 2, 2), 3, 3, 1.0)
    assert small.size == (3, 3), "margins shrink to fit a small texture"


def test_dump_render_lint_end_to_end():
    lua = shutil.which("lua") or shutil.which("lua5.1")
    if not lua:
        print("   (skipped: no lua on PATH)")
        return
    with tempfile.TemporaryDirectory() as tmp:
        dump = Path(tmp) / "dump"
        dump.mkdir()
        subprocess.run(
            [lua, "examples/dump_example.lua", "--out", str(dump)], cwd=ROOT, check=True, stdout=subprocess.DEVNULL
        )
        out = Path(tmp) / "png"
        assert wowui.main(["render", "--dump", str(dump), "--out", str(out), "--lint"]) == 0
        with Image.open(out / "main.png") as img:
            size = img.size
        assert size[0] > 300 and size[1] > 200
        assert (out / "main.lint.png").exists()
        base = Path(tmp) / "baseline.txt"
        base.write_text("", encoding="utf-8")
        assert wowui.main(["lint", "--dump", str(dump), "--baseline", str(base)]) == 1
        keys = []
        for f in json.loads((dump / "lint.json").read_text(encoding="utf-8"))["findings"]:
            keys.append(f"{f['view']} | {f['key']}")
        base.write_text("\n".join(keys) + "\n", encoding="utf-8")
        assert wowui.main(["lint", "--dump", str(dump), "--baseline", str(base)]) == 0
        # --update-baseline keeps the header and each kept key's comment, and drops keys no longer found.
        noted = ["# Header line.", "", "# Why the first one is fine.", keys[0], *keys[1:], "x | gone | key"]
        base.write_text("\n".join(noted) + "\n", encoding="utf-8")
        subprocess.run(
            [lua, "examples/dump_example.lua", "--out", str(dump), "--baseline", str(base), "--update-baseline"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        lines = base.read_text(encoding="utf-8").splitlines()
        assert lines[0] == "# Header line.", lines
        assert lines[lines.index(keys[0]) - 1] == "# Why the first one is fine.", lines
        assert "x | gone | key" not in lines


def _scan(src, rules=None, path="Core.lua", **top):
    """Findings `[(line, rule)]` of one source text, with a config made of `rules` (and other top-level keys)."""
    cfg = check.parse_config({"rules": rules or {}, **top})
    found, _ = check.check_source(path, src, cfg)
    return sorted((f.line, f.rule) for f in found)


def _only(rule, **params):
    """A rules table with every rule off but `rule`."""
    return {r: (dict(params) if r == rule else False) for r in check.RULES}


def test_check_tokenizer_skips_strings_and_comments():
    triggers = 'SetCVar("a", 1) Foo = 1 loadstring("x")'
    src = "\n".join(
        [
            f"local a = '{triggers}'",
            f'local b = "{triggers}"',
            f"local c = [[{triggers}]]",
            f"local d = [==[ {triggers} ]] still inside ]==]",
            f"-- {triggers}",
            f"--[[ {triggers}",
            f"{triggers} ]]",
            f"--[==[ {triggers} ]] ]==] local e = 1",
            "local f = 'it\\'s SetCVar(1)'",
            'local g = "tab\\\\" -- SetCVar("x")',
            "local h = 'multi \\",
            "SetCVar(1)'",
            "local i = 0x1F + 1e-3 + .5 .. 2",
        ]
    )
    assert _scan(src) == [], _scan(src)
    # The line after all of that is still counted right: one real finding, on the right line.
    assert _scan(src + "\nSetCVar('real', 1)") == [(14, "forbidden-call")]
    toks, comments = check.tokenize("a = [[x\ny]] --[[c\nd]] b\n-- end")
    assert [(t.text, t.line) for t in toks] == [("a", 1), ("=", 1), ("x\ny", 1), ("b", 3)]
    assert [(line, alone) for line, _, alone in comments] == [(2, False), (4, True)]
    # A string escape with a non-ASCII "digit" (superscript two) must not raise.
    toks, _ = check.tokenize("x = 'a\\²b' y = 1")
    assert [t.text for t in toks] == ["x", "=", "a²b", "y", "=", "1"]
    # Broken input does not raise.
    check.tokenize("x = 'unterminated\ny = [[ never closed")
    check.tokenize("--[==[ never closed")
    check.tokenize("a = 1 @ ~ é")


def test_check_forbidden_call():
    rules = _only("forbidden-call")
    src = "\n".join(
        [
            "SetCVar('a', 1)",  # 1
            "_G.SetCVar('a', 1)",  # 2
            "local ok = pcall(loadstring, 'x')",  # reference, not a call: not reported
            "load'return 1'",  # 4: string call form
            "SetBindingClick(1, 2)",  # 5
            "obj:SetCVar(1)",  # method of something else
            "obj.load(1)",
            "function Obj:SaveBindings() end",  # a definition is not a call
            "local function RunScript() end RunScript()",  # a local shadows the global
            "OpenWorldMap()",  # 10
            "local t = { SetCVar = 1 }",
        ]
    )
    assert _scan(src, rules) == [(1, "forbidden-call"), (2, "forbidden-call"), (4, "forbidden-call")] + [
        (5, "forbidden-call"),
        (10, "forbidden-call"),
    ]
    # Overriding the list replaces the defaults; a dict carries a reason.
    only_custom = _only("forbidden-call", calls={"Frobnicate": "use Grobnicate", "C_CVar:SetCVar": ""})
    cfg = check.parse_config({"rules": only_custom})
    found, _ = check.check_source("a.lua", "SetCVar(1)\nFrobnicate()\nC_CVar.SetCVar(1)", cfg)
    assert [(f.line, f.message) for f in found] == [
        (2, "call to forbidden function 'Frobnicate': use Grobnicate"),
        (3, "call to forbidden function 'C_CVar.SetCVar'"),
    ]


def test_check_forbidden_hooks():
    rules = _only("forbidden-call", hookTargets=["WorldMapFrame", "SomeGlobalFunc", "PlayerFrame"])
    src = "\n".join(
        [
            "hooksecurefunc(WorldMapFrame, 'Show', f)",  # 1
            "hooksecurefunc('SomeGlobalFunc', f)",  # 2
            "hooksecurefunc(WorldMapFrame.ScrollContainer, 'Show', f)",  # 3
            "PlayerFrame:HookScript('OnShow', f)",  # 4
            "PlayerFrame.portrait:HookScript('OnShow', f)",  # 5
            "hooksecurefunc('OtherFunc', f)",
            "hooksecurefunc(MyFrame, 'Show', f)",
            "MyFrame:HookScript('OnShow', f)",
            "local PlayerFrame = CreateFrame('Frame') PlayerFrame:HookScript('OnShow', f)",
            "hooksecurefunc(_G.WorldMapFrame, 'Hide', f)",  # 10
        ]
    )
    assert _scan(src, rules) == [(n, "forbidden-call") for n in (1, 2, 3, 4, 5, 10)]
    assert _scan("hooksecurefunc(_G['WorldMapFrame'], 'Hide', f)", rules) == [(1, "forbidden-call")]
    assert _scan("hooksecurefunc(_G['Other'], 'Hide', f)", rules) == []


def test_check_local_aliases_of_globals():
    # The upvalue idiom `local f = f` keeps pointing at the global for forbidden-call and the hook rules.
    calls = [*check.DEFAULT_FORBIDDEN_CALLS, "C_CVar.SetCVar"]
    rules = _only("forbidden-call", calls=calls, hookTargets=["WorldMapFrame", "PlayerFrame"])
    flagged = [
        "local SetCVar = SetCVar\nSetCVar(1)",
        "local SetCVar = _G.SetCVar\nSetCVar(1)",
        "local SetCVar = _G['SetCVar']\nSetCVar(1)",
        "local C_CVar = C_CVar\nC_CVar.SetCVar(1)",
        "local C_CVar = _G.C_CVar\nC_CVar.SetCVar(1)",
        "local hooksecurefunc = hooksecurefunc\nhooksecurefunc(WorldMapFrame, 'Show', f)",
        "local PlayerFrame = PlayerFrame\nPlayerFrame:HookScript('OnShow', f)",
        "local SetCVar, b = SetCVar, 2\nSetCVar(1)",  # positional initialisers
        "local a, SetCVar = Other, SetCVar\nSetCVar(1)",
        "local scv = SetCVar\nscv(1)",  # an alias under another name is reported under the global's
        "local a = SetCVar\nlocal b = a\nb(1)",  # an alias of an alias
        "local SetCVar = SetCVar\ndo local x = 1; SetCVar(1) end\nfunction f() SetCVar(2) end",
    ]
    for src in flagged:
        assert [r for _, r in _scan(src, rules)][:1] == ["forbidden-call"], src
    assert _scan("local scv = SetCVar\nscv(1)", rules)[0][0] == 2
    assert _scan("local SetCVar = SetCVar\nSetCVar(1)\nSetCVar(2)", rules) == [
        (2, "forbidden-call"),
        (3, "forbidden-call"),
    ]
    # Not aliases: a call result, an expression, another local, a shadowing parameter or a later redeclaration.
    clean = [
        "local SetCVar = SetCVar or function() end\nSetCVar(1)",
        "local SetCVar = SetCVar(1)\nSetCVar(2)",
        "local C_CVar = C_CVar.x\nC_CVar.SetCVar(1)",
        "local mine = function() end\nlocal SetCVar = mine\nSetCVar(1)",
        "local SetCVar = SetCVar\nlocal function f(SetCVar) SetCVar(1) end",
        "local SetCVar = SetCVar\nlocal SetCVar = function() end\nSetCVar(1)",
        "local SetCVar = SetCVar\nfor SetCVar in pairs(t) do SetCVar(1) end",
        "local x = 1, SetCVar\nlocal SetCVar\nSetCVar(1)",
        "if a then local SetCVar = SetCVar end\nlocal SetCVar = 1\nSetCVar(1)",
    ]
    for src in clean:
        assert _scan(src, rules) == [], src
    # The alias ends with its block.
    assert _scan("do local SetCVar = SetCVar end\nSetCVar(1)", rules) == [(2, "forbidden-call")]
    assert _scan("do local SetCVar = SetCVar end\nlocal SetCVar = 1\nSetCVar(1)", rules) == []
    # An aliased local is still a local for new-global.
    assert _scan("local SetCVar = SetCVar\nSetCVar = nil", _only("new-global")) == []


def test_check_definitions_are_not_calls():
    rules = _only("forbidden-call")
    assert _scan("function load() end\nfunction SetCVar(a) end", rules) == []
    assert _scan("function load() end\nfunction SetCVar(a) end", _only("new-global")) == [
        (1, "new-global"),
        (2, "new-global"),
    ]
    assert _scan("function M.load() end\nfunction M:SetCVar() end\nlocal function load() end", rules) == []


def test_check_duplicate_findings_are_kept():
    assert _scan("SetCVar(1) SetCVar(2)", _only("forbidden-call")) == [(1, "forbidden-call")] * 2
    assert _scan("A = 1 A = 2", _only("new-global")) == [(1, "new-global")] * 2


def test_check_combat_log():
    rules = _only("combat-log")
    src = "\n".join(
        [
            "frame:RegisterEvent('COMBAT_LOG_EVENT_UNFILTERED')",  # 1
            "self:RegisterEvent(\"COMBAT_LOG_EVENT_UNFILTERED\", 'OnCombatLog')",  # 2: AceEvent
            "frame:RegisterEvent('COMBAT_LOG_EVENT')",  # 3
            "frame:RegisterEvent('PLAYER_LOGIN')",
            "frame:RegisterEvent(name)",
            "frame:RegisterUnitEvent('UNIT_HEALTH', 'player')",
            "local s = 'COMBAT_LOG_EVENT_UNFILTERED' -- RegisterEvent('COMBAT_LOG_EVENT')",
            "CreateFrame('Frame'):RegisterEvent([[COMBAT_LOG_EVENT_UNFILTERED]])",  # 8: receiver is an expression
        ]
    )
    assert _scan(src, rules) == [(1, "combat-log"), (2, "combat-log"), (3, "combat-log"), (8, "combat-log")]
    assert _scan(src, _only("combat-log", events=["PLAYER_LOGIN"])) == [(4, "combat-log")]


def test_check_new_global():
    rules = _only("new-global", allow=["MyAddon", "MyAddonDB", "SLASH_MYADDON%d+", "BINDING_*", "KEY%u+_%w"])
    src = "\n".join(
        [
            "local addonName, ns = ...",  # 1
            "MyAddon = {}",  # allowed
            "Foo = 1",  # 3
            "local Bar = 1; Bar = 2",  # a local
            "function Baz() end",  # 5
            "function MyAddon.Frob() end",  # allowed root
            "function Other.Frob() end",  # 7
            "function Other:Frob() end",  # 8
            "function ns.Frob() end",  # ns is local
            "_G.Quux = 1",  # 10
            '_G["Quuz"] = 1',  # 11
            "_G.Foo2.bar = 1",  # a field of a global, not an assignment to one
            "_G[name] = 1",  # dynamic: not checked
            "SLASH_MYADDON1 = '/x'",  # allowed
            "SLASH_OTHER1 = '/y'",  # 15
            "BINDING_HEADER_MYADDON = 'x'",  # allowed
            "KEYBIND_A = 1",  # allowed: KEY%u+_%w
            "KEYbind_A = 1",  # 18
            "Foo.bar = 1",  # a field, not checked
            "A, B = 1, 2",  # 20 twice
            "local t = { Foo = 1, [2] = 3 }",
            "for i = 1, 3 do Loop1 = i end",  # 22
            "x = 1 y = 2",  # 23 twice
        ]
    )
    expect = [3, 5, 7, 8, 10, 11, 15, 18, 20, 20, 22, 23, 23]
    assert _scan(src, rules) == [(n, "new-global") for n in expect], _scan(src, rules)
    allow_a = _only("new-global", allow=["Allowed"])
    assert _scan("function _G.Allowed() end\nfunction _G.Other() end", allow_a) == [(2, "new-global")]
    found, _ = check.check_source("a.lua", "function A() end\nB = 1\nfunction C.d() end", check.parse_config({}))
    assert [f.message.split(" (")[0] for f in found if f.rule == "new-global"] == [
        "global function 'A'",
        "assignment to undeclared global 'B'",
        "function defined on global 'C'",
    ]


def test_check_new_global_scopes():
    rules = _only("new-global")
    src = "\n".join(
        [
            "local function helper(a, b, ...)",  # 1
            "  a = 1; b = 2",  # params are locals
            "  c = 3",  # 3
            "end",
            "local function rec() rec = nil end",  # the name is a local inside its body
            "local M = {}; function M:method() self.x = 1; self = nil end",  # self is a local
            "for k, v in pairs(t) do k = 1; v = 2 end",
            "for i = 1, 2 do i = 3 end",
            "k = 1",  # 9: loop variables ended with the loop
            "do local d = 1 end",
            "d = 2",  # 11: the block ended
            "if x then local e = 1 else e = 2 end",  # 12: the else branch does not see the then branch's local
            "repeat local r = 1 until r",
            "local f = function(p) p = 1; q = 2 end",  # 14
            "t.cb = function() inner = 1 end",  # 15
            "local g; g = 1",
            "while cond do local w = 1; w = 2 end",
            "outer = function() local o = 1 return function() o = 2; z = 3 end end",  # 18 outer, z
        ]
    )
    expect = [3, 9, 11, 12, 14, 15, 18, 18]
    assert _scan(src, rules) == [(n, "new-global") for n in expect], _scan(src, rules)
    # Shadowing in an inner scope ends with that scope.
    assert _scan("do local Foo end\nFoo = 1", rules) == [(2, "new-global")]
    assert _scan("local Foo\ndo Foo = 1 end\nlocal function f() Foo = 2 end", rules) == []
    assert _scan("local Foo\nfunction f() Foo = 2 end", rules) == [(2, "new-global")]  # f itself is global


def test_check_file_length():
    rules = _only("file-length", maxLines=3, overrides={"Data/**": 10})
    assert _scan("a\nb\nc\n", rules) == []
    assert _scan("a\nb\nc\nd\n", rules) == [(1, "file-length")]
    assert _scan("a\nb\nc\nd", rules) == [(1, "file-length")]
    assert _scan("\n" * 9, rules, path="Data/Big.lua") == []
    assert _scan("\n" * 11, rules, path="Data/Big.lua") == [(1, "file-length")]
    found, _ = check.check_source("X.lua", "a\n" * 5, check.parse_config({"rules": rules}))
    assert found[0].message == "file is longer than 3 lines"  # no count: a baseline keys on the text
    # Counting is by newline: form feeds and other splitlines separators are not line ends.
    assert _scan("a\fb\x1cc\x0bd\x85e f", rules) == []
    assert _scan("a\r\nb\rc\nd", rules) == [(1, "file-length")]
    # A suppression on line 1 works.
    assert _scan("-- wowui-check: ignore file-length generated data\na\nb\nc\n", rules) == []


def test_check_test_shell_find():
    rules = _only("test-shell-find")
    src = "\n".join(
        [
            "local p = io.popen('find . -name \"*.lua\"')",  # 1
            "local q = io.popen('dir /b ' .. dir)",  # 2
            "os.execute('ls ' .. dir)",  # 3
            "io.popen('git ls-files')",
            "os.execute('mkdir out')",
            "io.popen(cmd)",
            "io.popen('cmd /c dir')",  # 7
            "-- io.popen('find')",
        ]
    )
    assert _scan(src, rules, path="tests/a_spec.lua") == [(1, "test-shell-find"), (2, "test-shell-find")] + [
        (3, "test-shell-find"),
        (7, "test-shell-find"),
    ]
    assert _scan(src, rules, path="src/Core.lua") == []  # only test files
    custom = _only("test-shell-find", tests=["spec/*.lua"])
    assert len(_scan(src, custom, path="spec/a.lua")) == 4
    assert _scan(src, custom, path="tests/a.lua") == []
    cfg = check.parse_config({"rules": rules})
    found, _ = check.check_source("tests/a.lua", "io.popen('find .')", cfg)
    assert "git ls-files" in found[0].message


REGISTRATIONS = "\n".join(
    [
        "tinsert(UISpecialFrames, 'MyFrame')",  # 1
        "table.insert(UISpecialFrames, 'MyFrame')",  # 2
        "UISpecialFrames[#UISpecialFrames + 1] = 'MyFrame'",  # 3
        "SLASH_MYADDON1 = '/my'",  # 4
        "SlashCmdList['MYADDON'] = function() end",  # 5
        "SlashCmdList.MYADDON = function() end",  # 6
        "_G['SLASH_MYADDON2'] = '/ma'",  # 7
        "tinsert(OtherList, 'x')",
        "SlashCmdList.A.b = 1",
        "SLASH_MYADDON = 1",  # no trailing digit: not a slash variable
    ]
)


def test_check_unguarded_registration():
    on = _only("unguarded-registration", guard="MyAddon:CanRegister")
    assert _scan(REGISTRATIONS, on) == [(n, "unguarded-registration") for n in range(1, 8)]
    # Off when no guard is configured, or when the rule is off.
    assert _scan(REGISTRATIONS, _only("unguarded-registration")) == []
    assert _scan(REGISTRATIONS, _only("unguarded-registration", guard="G", enabled=False)) == []
    guarded = [
        # inside an if branch whose condition calls the guard (no `or`, no `not`)
        "if MyAddon:CanRegister() then\n  tinsert(UISpecialFrames, 'F')\n  SLASH_X1 = '/x'\nend",
        "if (MyAddon:CanRegister()) then SLASH_X1 = '/x' end",
        "if a and MyAddon.CanRegister() then SlashCmdList.X = f end",
        "if a then x() elseif MyAddon:CanRegister() then SLASH_X1 = '/x' end",
        # nested inside a guarded branch, also through a function defined there
        "if MyAddon:CanRegister() then\nfor i = 1, 2 do SLASH_X1 = 1 end\nlocal f = function() SLASH_X2 = 1 end\nend",
        # the branches after `if not guard()` only run once the guard said yes
        "if not MyAddon:CanRegister() then x() else SLASH_X1 = '/x' end",
        "if not (MyAddon:CanRegister()) then x() elseif y then SLASH_X1 = '/x' end",
        # an earlier `if <condition with the guard> then return end` in the same function, either polarity
        "function f()\n  if not MyAddon:CanRegister() then return end\n  tinsert(UISpecialFrames, 'F')\nend",
        "function f()\n  if x or MyAddon:CanRegister() then return end\n  tinsert(UISpecialFrames, 'F')\nend",
        "function f()\n  if MyAddon:CanRegister() then return end\n  local g = function() SLASH_X1 = 1 end\nend",
        # ... at the top level of the file, and in a nested block
        "if not MyAddon:CanRegister() then return end\nlocal function f() SLASH_X1 = '/x' end",
        "function f()\n  if x then\n    if not MyAddon:CanRegister() then return end\n    SLASH_X1 = 1\n  end\nend",
    ]
    for src in guarded:
        assert _scan(src, on) == [], src
    unguarded = [
        # the guard is called later, or only in a sibling function
        "SLASH_X1 = '/x'\nMyAddon:CanRegister()",
        "function a() MyAddon:CanRegister() end\nfunction b() SLASH_X1 = '/x' end",
        # calling the guard outside an `if` condition, or in an `if` that does not return, guards nothing after it
        "function f()\n  local ok = MyAddon:CanRegister()\n  SLASH_X1 = '/x'\nend",
        "MyAddon:CanRegister()\nlocal function f() SLASH_X1 = '/x' end",
        "if MyAddon:CanRegister() then x() end\nSLASH_X1 = '/x'",
        "if not MyAddon:CanRegister() then x() end\nSLASH_X1 = '/x'",
        # the guard is per branch: another branch of the same if is not guarded
        "if MyAddon:CanRegister() then x() else SLASH_X1 = '/x' end",
        "if MyAddon:CanRegister() then x() elseif y then SLASH_X1 = '/x' end",
        "if not MyAddon:CanRegister() then SLASH_X1 = '/x' end",
        "if not (MyAddon:CanRegister()) then SLASH_X1 = '/x' end",
        "if not MyAddon:CanRegister() and y then SLASH_X1 = '/x' end",
        # `or` / `not` in the condition: the body may run without the guard saying yes
        "if x or MyAddon:CanRegister() then SLASH_X1 = '/x' end",
        "if MyAddon:CanRegister() and not y then SLASH_X1 = '/x' end",
        # an early return inside a nested block ends with that block
        "function f()\n  if x then\n    if not MyAddon:CanRegister() then return end\n  end\n  SLASH_X1 = 1\nend",
        # a guard in an earlier branch's condition does not carry over to the else of a positive one
        "function f()\nif a then\nif not MyAddon:CanRegister() then return end\nelse\nSLASH_X1 = 1\nend\nend",
        "if other() then SLASH_X1 = '/x' end",
        "-- MyAddon:CanRegister()\nSLASH_X1 = '/x'",
        "local s = 'MyAddon:CanRegister()'\nSLASH_X1 = '/x'",
    ]
    for src in unguarded:
        assert [r for _, r in _scan(src, on)] == ["unguarded-registration"], src
    # A list of guards, and a plain function name.
    two = _only("unguarded-registration", guard=["A.ok", "CanRegister"])
    assert _scan("if CanRegister() then SLASH_X1 = 1 end", two) == []
    assert _scan("if A:ok() then SLASH_X1 = 1 end", two) == []
    assert _scan("if B.ok() then SLASH_X1 = 1 end", two) == [(1, "unguarded-registration")]


def test_check_suppressions():
    rules = {"forbidden-call": True, "suppression-reason": True, "combat-log": True}
    only = {r: (rules.get(r, False)) for r in check.RULES}
    src = "\n".join(
        [
            "SetCVar(1)  -- wowui-check: ignore forbidden-call needed for the keybind panel",  # same line
            "-- wowui-check: ignore forbidden-call because reasons",  # previous line
            "SetCVar(2)",
            "SetCVar(3)",  # 4: two lines below its comment? no comment: reported
            "-- wowui-check: ignore forbidden-call",  # 5: no reason -> finding, still suppresses line 6
            "SetCVar(4)",
            "--[[ wowui-check: ignore forbidden-call long comment form ]] SetCVar(5)",  # 7
            "-- wowui-check: ignore combat-log wrong rule",
            "SetCVar(6)",  # 9: other rule's suppression does not help
            "local s = '-- wowui-check: ignore forbidden-call in a string'",
            "SetCVar(7)",  # 11: a string is not a comment
        ]
    )
    assert _scan(src, only) == [(4, "forbidden-call"), (5, "suppression-reason"), (9, "forbidden-call")] + [
        (11, "forbidden-call")
    ]
    cfg = check.parse_config({"rules": only})
    _, hidden = check.check_source("a.lua", src, cfg)
    assert hidden == 4
    # suppression-reason can be switched off.
    off = dict(only, **{"suppression-reason": False})
    assert (5, "suppression-reason") not in _scan(src, off)
    # A comment trailing code covers its own line only; the line-above form is for a comment alone on its line.
    trailing = "SetCVar(1) -- wowui-check: ignore forbidden-call why\nSetCVar(2)\n"
    assert _scan(trailing, only) == [(2, "forbidden-call")]
    alone = "-- wowui-check: ignore forbidden-call why\nSetCVar(1)\nSetCVar(2)\n"
    assert _scan(alone, only) == [(3, "forbidden-call")]
    assert _scan("--[[ wowui-check: ignore forbidden-call why ]] SetCVar(1)\nSetCVar(2)", only) == [
        (2, "forbidden-call")
    ]
    # An unknown rule id is reported (it suppresses nothing); so is a missing reason after an unknown id.
    unknown = "-- wowui-check: ignore forbidden-calls why\nSetCVar(1)"
    assert _scan(unknown, only) == [(1, "suppression-reason"), (2, "forbidden-call")]
    found, _ = check.check_source("a.lua", unknown, check.parse_config({"rules": only}))
    assert "unknown rule 'forbidden-calls'" in [f for f in found if f.rule == "suppression-reason"][0].message
    # The same call twice on a line: both are reported, and one comment covers both.
    assert _scan("SetCVar(1) SetCVar(2) -- wowui-check: ignore forbidden-call why", only) == []


def test_check_per_path_disable_and_glob():
    src = "Foo = 1\nSetCVar(1)"
    both = {"new-global": True, "forbidden-call": True}
    assert [r for _, r in _scan(src, both, path="tests/a.lua")] == ["new-global", "forbidden-call"]
    got = _scan(src, both, path="tests/a.lua", disable={"tests/**": ["new-global"]})
    assert got == [(2, "forbidden-call")]
    assert _scan(src, both, path="Core.lua", disable={"tests/**": ["new-global"]}) == _scan(src, both)
    g = check.glob_regex
    assert g("**/*.lua").fullmatch("a.lua") and g("**/*.lua").fullmatch("x/y/a.lua")
    assert g("*.lua").fullmatch("x/a.lua") and not g("*.lua").fullmatch("a.txt")
    assert g("tests/**").fullmatch("tests/a/b.lua") and not g("tests/**").fullmatch("src/tests/a.lua")
    assert g("Libs/").fullmatch("Libs/x/y.lua") and not g("Libs/").fullmatch("Libs")
    assert g("a/*.lua").fullmatch("a/b.lua") and not g("a/*.lua").fullmatch("a/b/c.lua")
    # Windows-style patterns work: backslashes are separators, a leading ./ is dropped.
    assert g("tests\\**").fullmatch("tests/a/b.lua") and g("Data\\Gen\\*.lua").fullmatch("Data/Gen/x.lua")
    assert g("./Libs/**").fullmatch("Libs/a.lua")
    assert _scan("Foo = 1", _only("new-global"), path="tests/a.lua", disable={"tests\\**": ["new-global"]}) == []
    n = check.name_regex
    assert n("SLASH_MYADDON%d+").fullmatch("SLASH_MYADDON12") and not n("SLASH_MYADDON%d+").fullmatch("SLASH_MYADDON")
    assert n("BINDING_*").fullmatch("BINDING_HEADER_X") and not n("BINDING_*").fullmatch("XBINDING_")
    assert n("A%.B").fullmatch("A.B") and not n("A%.B").fullmatch("AxB")


def test_check_config_errors():
    bad = [
        [],
        {"colour": 1},
        {"rules": {"no-such-rule": True}},
        {"rules": {"new-global": {"alow": []}}},
        {"rules": {"new-global": {"allow": "Foo"}}},
        {"rules": {"file-length": {"maxLines": 0}}},
        {"rules": {"file-length": {"overrides": {"a": "x"}}}},
        {"rules": {"combat-log": {"enabled": "yes"}}},
        {"disable": {"tests/**": ["nope"]}},
        {"disable": []},
        {"include": "**/*.lua"},
    ]
    for doc in bad:
        try:
            check.parse_config(doc)
        except check.ConfigError:
            continue
        raise AssertionError(f"accepted: {doc}")
    cfg = check.parse_config({"_note": "ignored", "rules": {"new-global": False, "file-length": {"_x": 1}}})
    assert not cfg.enabled["new-global"] and cfg.enabled["file-length"]


def _write_tree(base, files):
    for rel, text in files.items():
        p = base / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")


def _cli(*argv):
    """Run `wowui check`; returns (exit code, stdout, stderr)."""
    import contextlib
    import io

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = wowui.main(["check", *argv])
        except SystemExit as e:  # argparse errors
            code = e.code
    return code, out.getvalue(), err.getvalue()


def test_check_cli_exit_codes_and_output():
    import json

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write_tree(
            root,
            {
                "Core.lua": "local x = 1\nFoo = 2\nSetCVar('a', 1)\n",
                "Zeta.lua": "local ok = true\n",
                "Libs/Vendored.lua": "Foo = 1\n",
                "notes.txt": "Foo = 1\n",
                "sub/Alpha.lua": "loadstring('x')\n",
            },
        )
        code, out, _ = _cli("--root", str(root))
        assert code == 1
        lines = out.splitlines()
        assert lines[:3] == [  # sorted by path then line; forward slashes; Libs excluded by default
            "Core.lua:2: new-global: assignment to undeclared global 'Foo' (not local, not in the allowlist)",
            "Core.lua:3: forbidden-call: call to forbidden function 'SetCVar'",
            "sub/Alpha.lua:1: forbidden-call: call to forbidden function 'loadstring'",
        ], lines
        assert lines[3] == "3 finding(s) in 3 file(s) checked"
        # JSON.
        code, out, _ = _cli("--root", str(root), "--format", "json")
        doc = json.loads(out)
        assert code == 1 and doc["summary"] == {"files": 3, "findings": 3, "suppressed": 0}
        assert doc["findings"][0] == {
            "path": "Core.lua",
            "line": 2,
            "rule": "new-global",
            "message": doc["findings"][0]["message"],
        }
        # A config in the root is picked up; with Foo allowed and SetCVar not forbidden only the loadstring is left.
        cfg = {"rules": {"new-global": {"allow": ["Foo"]}, "forbidden-call": {"calls": ["loadstring"]}}}
        (root / ".wowui-check.json").write_text(json.dumps(cfg), encoding="utf-8")
        code, out, _ = _cli("--root", str(root))
        assert code == 1 and out.splitlines()[0].startswith("sub/Alpha.lua:1: forbidden-call")
        # Paths restrict the check; a clean selection exits 0.
        code, out, _ = _cli("--root", str(root), "Zeta.lua")
        assert code == 0 and out == "ok: 1 file(s) checked\n", out
        code, out, _ = _cli("--root", str(root), "sub")
        assert code == 1 and "1 finding(s) in 1 file(s)" in out
        # --config elsewhere, and its errors.
        other = root.parent / (root.name + "-other.json")
        other.write_text(json.dumps({"rules": {"forbidden-call": False, "new-global": False}}), encoding="utf-8")
        try:
            code, out, _ = _cli("--root", str(root), "--config", str(other))
            assert (code, out) == (0, "ok: 3 file(s) checked\n"), (code, out)
        finally:
            other.unlink()
        code, _, err = _cli("--root", str(root), "--config", str(root / "missing.json"))
        assert code == 2 and "config file not found" in err
        (root / "bad.json").write_text("{ not json", encoding="utf-8")
        code, _, err = _cli("--root", str(root), "--config", str(root / "bad.json"))
        assert code == 2 and "bad.json" in err
        (root / "bad.json").write_text('{"rules": {"nope": true}}', encoding="utf-8")
        assert _cli("--root", str(root), "--config", str(root / "bad.json"))[0] == 2
        assert _cli("--root", str(root / "missing"))[0] == 2
        assert _cli("--root", str(root), "no/such/file.lua")[0] == 2
        assert _cli("--root", str(root), str(root.parent))[0] == 2  # outside the root
        assert _cli("--root", str(root), "--format", "xml")[0] == 2
        # Nothing to check is an error, never a pass: a file named on the command line that the config excludes
        # (or that has no Lua), an include that matches nothing, an empty folder.
        code, out, err = _cli("--root", str(root), "Libs/Vendored.lua")
        assert code == 2 and "Libs/Vendored.lua" in err and "excluded" in err and out == "", (code, out, err)
        assert _cli("--root", str(root), "notes.txt")[0] == 2
        typo = root.parent / (root.name + "-typo.json")
        typo.write_text(json.dumps({"include": ["**/*.luaa"]}), encoding="utf-8")
        try:
            code, out, err = _cli("--root", str(root), "--config", str(typo))
            assert code == 2 and "no files to check" in err and out == "", (code, out, err)
        finally:
            typo.unlink()
        with tempfile.TemporaryDirectory() as empty:
            code, _, err = _cli("--root", empty)
            assert code == 2 and "no files to check" in err


def test_check_lists_files_with_git():
    git = shutil.which("git")
    if not git:
        return
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        _write_tree(
            root,
            {"a.lua": "Foo = 1\n", "ignored.lua": "Foo = 1\n", "b/c.lua": "Foo = 1\n", ".gitignore": "ignored.lua\n"},
        )
        assert check.list_files(root) == sorted([".gitignore", "a.lua", "b/c.lua", "ignored.lua"])  # not a repo: a walk
        subprocess.run([git, "init", "-q"], cwd=root, check=True)
        subprocess.run([git, "add", "a.lua"], cwd=root, check=True)
        # Tracked and untracked files, but not ignored ones.
        assert check.list_files(root) == [".gitignore", "a.lua", "b/c.lua"]
        (root / "a.lua").unlink()  # tracked but deleted
        assert check.list_files(root) == [".gitignore", "b/c.lua"]
        code, out, err = _cli("--root", str(root))
        assert code == 1 and out.splitlines()[0].startswith("b/c.lua:1:") and err == "", (code, out, err)
        # A git failure other than "not a repository" is not silent: warn, then walk.
        (root / ".git" / "config").write_text("[broken\n", encoding="utf-8")
        code, out, err = _cli("--root", str(root))
        assert code == 1 and "warning: git ls-files failed" in err and "b/c.lua:1:" in out, (code, out, err)


def test_check_example_addon_is_checkable():
    # The repository's own sources run through the checker: Lua files it ships must at least tokenize and scan.
    cfg = check.parse_config({})
    findings, checked, _ = check.check_tree(ROOT, cfg, ["examples", "lib"])
    assert checked >= 3, checked
    assert all(f.rule in check.RULES for f in findings)
def _quiet(argv):
    """wowui.main(argv) with its output captured: (exit code, stdout)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
        code = wowui.main(argv)
    return code, out.getvalue()


def _frame_png(path: Path, step: int, size=(60, 40)):
    """A dark frame with a coloured block that moves with `step`: every frame differs from the next."""
    img = Image.new("RGB", size, (20, 22, 30))
    colour = [(220, 40, 40), (40, 200, 60), (60, 90, 230), (230, 200, 40), (200, 60, 200)][step % 5]
    for x in range(5 + step % 5 * 8, 17 + step % 5 * 8):
        for y in range(8, 20):
            img.putpixel((x, y), colour)
    img.save(path)
    return colour


def _gif_frames(path: Path):
    with Image.open(path) as im:
        return [(f.convert("RGB"), f.info.get("duration")) for f in ImageSequence.Iterator(im)], im.info.get("loop")


def test_gif_from_frames_keeps_count_durations_and_is_deterministic():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for i in range(4):
            _frame_png(tmp / f"f{i}.png", i)
        out = tmp / "a.gif"
        argv = ["gif", str(tmp / "f*.png"), "--out", str(out), "--ms", "100", "--last-ms", "300"]
        assert _quiet(argv)[0] == 0
        frames, loop = _gif_frames(out)
        assert len(frames) == 4
        assert [d for _, d in frames] == [100, 100, 100, 300], "per-frame time, the last one rests longer"
        assert loop == 0, "loops forever by default"
        assert frames[0][0].size == (60, 40), "no caption, no band"
        first = out.read_bytes()
        out.unlink()
        assert _quiet(argv)[0] == 0
        assert out.read_bytes() == first, "the same input gives the same bytes"
        assert _quiet([*argv[:-4], "--out", str(out), "--no-loop"])[0] == 0
        assert _gif_frames(out)[1] is None, "--no-loop plays once"


def test_gif_orders_sequence_frames_by_number_and_reads_captions_from_dumps():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        png, dump = tmp / "png", tmp / "dump"
        png.mkdir()
        dump.mkdir()
        colours = {}
        for n in (2, 10, 1):  # a plain text sort would put 10 before 2
            colours[n] = _frame_png(png / f"seq-pick-{n:02d}.png", n)
        _frame_png(png / "other.png", 0)
        (dump / "seq-pick-01.json").write_text(json.dumps({"meta": {"caption": "First step"}}), encoding="utf-8")
        plain = tmp / "plain.gif"
        assert _quiet(["gif", "--sequence", "pick", "--png", str(png), "--out", str(plain), "--ms", "50"])[0] == 0
        frames, _ = _gif_frames(plain)
        assert len(frames) == 3 and frames[0][0].size == (60, 40), (
            "frames of the named sequence only, no dumps no captions"
        )
        for (img, _), n in zip(frames, (1, 2, 10), strict=True):
            x = 10 + n % 5 * 8
            assert img.getpixel((x, 12)) == colours[n], f"frame for step {n} is in step order"
        captioned = tmp / "captioned.gif"
        args = ["gif", "--sequence", "pick", "--png", str(png), "--dump", str(dump), "--out", str(captioned)]
        assert _quiet(args)[0] == 0
        frames, _ = _gif_frames(captioned)
        assert frames[0][0].width == 60 and frames[0][0].height > 40, "a caption in the dump adds the band"
        band = frames[0][0].crop((0, 41, 60, frames[0][0].height))
        assert len({band.getpixel((x, y)) for x in range(60) for y in range(band.height)}) > 2, "the caption is drawn"
        assert frames[0][0].getpixel((30, 38)) == (20, 22, 30), "the picture itself is untouched"
        try:
            _quiet(["gif", "--sequence", "missing", "--png", str(png), "--out", str(plain)])
        except SystemExit as e:
            assert "seq-missing-NN" in str(e)
        else:
            raise AssertionError("an unknown sequence is an error")


def test_gif_spec_crop_width_and_frame_options():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for i in range(3):
            _frame_png(tmp / f"v{i}.png", i)
        spec = {
            "name": "demo",
            "frames": [
                {"view": "v0", "caption": "One", "ms": 200},
                {"file": "v1.png", "caption": "Two"},
                "v2.png",
            ],
            "crop": [0, 0, 40, 20],
            "width": 80,
            "ms": 120,
            "lastMs": 500,
        }
        (tmp / "spec.json").write_text(json.dumps(spec), encoding="utf-8")
        out = tmp / "demo.gif"
        assert _quiet(["gif", "--spec", str(tmp / "spec.json"), "--out", str(out)])[0] == 0
        frames, _ = _gif_frames(out)
        assert [d for _, d in frames] == [200, 120, 500]
        assert frames[0][0].width == 80, "the crop is scaled to the width"
        assert frames[0][0].height > 40, "40x20 scaled to 80 wide is 40 high, plus the caption band"
        # Several sequences in one spec go to a folder.
        (tmp / "spec.json").write_text(json.dumps([spec, {**spec, "name": "second"}]), encoding="utf-8")
        assert _quiet(["gif", "--spec", str(tmp / "spec.json"), "--out", str(tmp / "gifs")])[0] == 0
        assert (tmp / "gifs" / "demo.gif").exists() and (tmp / "gifs" / "second.gif").exists()


def test_gif_auto_crop_trims_the_shared_background():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for i in range(2):
            _frame_png(tmp / f"f{i}.png", i, size=(100, 80))  # the blocks sit at x 5..28, y 8..19
        out = tmp / "auto.gif"
        assert _quiet(["gif", str(tmp / "f*.png"), "--out", str(out), "--crop", "auto"])[0] == 0
        assert _gif_frames(out)[0][0][0].size == (20, 12), "the two blocks together span x 5..24"


def test_gif_size_budget_reduces_colours_then_width_and_reports_failure():
    rng = random.Random(7)
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for i in range(3):
            img = Image.new("RGB", (240, 180))
            img.putdata([(rng.randrange(256), rng.randrange(256), rng.randrange(256)) for _ in range(240 * 180)])
            img.save(tmp / f"n{i}.png")
        full = tmp / "full.gif"
        assert _quiet(["gif", str(tmp / "n*.png"), "--out", str(full)])[0] == 0
        budget = full.stat().st_size // 3
        small = tmp / "small.gif"
        argv = ["gif", str(tmp / "n*.png"), "--out", str(small), "--min-width", "60", "--max-bytes", str(budget)]
        code, out = _quiet(argv)
        assert code == 0 and small.stat().st_size <= budget, "the budget is honoured"
        assert "reduced:" in out and "colours" in out, out
        frames, _ = _gif_frames(small)
        assert len(frames) == 3
        nope = tmp / "nope.gif"
        code, _ = _quiet(["gif", str(tmp / "n*.png"), "--out", str(nope), "--min-width", "60", "--max-bytes", "100"])
        assert code == 1 and not nope.exists(), "a budget nothing fits is an error, and nothing is written"


def test_parse_size_and_box():
    assert visual.parse_size("3000") == 3000
    assert visual.parse_size("500KB") == 512000
    assert visual.parse_size("1.5m") == 1572864
    assert visual.parse_box("1, 2,30,40") == (1, 2, 30, 40)


def _solid(path: Path, size=(100, 60), colour=(30, 60, 90)):
    Image.new("RGB", size, colour).save(path)


def test_compare_identical_and_changed_pixels():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        _solid(tmp / "a.png")
        _solid(tmp / "b.png")
        code, out = _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--out", str(tmp / "d.png")])
        assert code == 0 and "0 of 6000 pixels changed" in out, out
        with Image.open(tmp / "d.png") as d:
            assert d.size == (3 * 100 + 2 * visual.PANEL_GAP, 60 + visual.PANEL_HEAD)
        img = Image.open(tmp / "b.png")
        img.putpixel((10, 10), (30, 60, 100))  # one pixel, 10 off in blue
        img.save(tmp / "b.png")
        code, out = _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png")])
        assert code == 1 and "1 of 6000 pixels changed" in out, out
        assert _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--tolerance", "10"])[0] == 0, (
            "10 is within 10"
        )
        assert _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--tolerance", "9"])[0] == 1
        assert _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--threshold", "0.02"])[0] == 0, (
            "1/6000 = 0.017%"
        )
        assert _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--threshold", "0.01"])[0] == 1
        # The changed pixel shows in the diff panel, and the rest of it is A dimmed.
        _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--out", str(tmp / "d.png")])
        with Image.open(tmp / "d.png") as d:
            x0 = 2 * (100 + visual.PANEL_GAP)
            assert d.getpixel((x0 + 10, visual.PANEL_HEAD + 10)) == visual.HIGHLIGHT
            assert d.getpixel((x0 + 50, visual.PANEL_HEAD + 30)) != visual.HIGHLIGHT
        # A change outside the cropped region is not seen; a different size is a difference.
        assert _quiet(["compare", str(tmp / "a.png"), str(tmp / "b.png"), "--crop", "20,20,50,30"])[0] == 0
        _solid(tmp / "wide.png", size=(120, 60))
        code, out = _quiet(["compare", str(tmp / "a.png"), str(tmp / "wide.png")])
        assert code == 1 and "sizes differ" in out, out


def test_compare_crop_zoom_labels_and_folders():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for d in ("one", "two"):
            (tmp / d).mkdir()
            _solid(tmp / d / "same.png")
            _solid(tmp / d / "changed.png")
        img = Image.open(tmp / "two" / "changed.png")
        img.putpixel((15, 12), (255, 255, 255))
        img.save(tmp / "two" / "changed.png")
        _solid(tmp / "two" / "extra.png")
        code, out = _quiet(["compare", str(tmp / "one"), str(tmp / "two"), "--out", str(tmp / "out")])
        assert code == 1, out
        assert "changed.png: 1 of 6000" in out and "same.png: 0 of 6000" in out and "extra.png: only in B" in out, out
        assert (tmp / "out" / "changed.png").exists() and (tmp / "out" / "same.png").exists()
        out_png = tmp / "z.png"
        args = ["compare", str(tmp / "one" / "changed.png"), str(tmp / "two" / "changed.png")]
        code, _ = _quiet(
            [*args, "--crop", "10,10,20,10", "--zoom", "3", "--labels", "before,after", "--out", str(out_png)]
        )
        assert code == 1
        with Image.open(out_png) as z:
            assert z.size == (3 * 60 + 2 * visual.PANEL_GAP, 30 + visual.PANEL_HEAD), (
                "20x10 zoomed 3 times, three panels"
            )
            # Zoom is nearest neighbour: the changed pixel (15, 12) becomes a 3x3 block at (15 - 10) * 3, (12 - 10) * 3.
            x0 = 2 * (60 + visual.PANEL_GAP)
            for dx in range(3):
                for dy in range(3):
                    assert z.getpixel((x0 + 15 + dx, visual.PANEL_HEAD + 6 + dy)) == visual.HIGHLIGHT
        try:
            _quiet([*args, "--labels", "only-one"])
        except SystemExit:
            pass
        else:
            raise AssertionError("--labels wants two names")


def test_atlas_search_sheet_layout_and_sheet():
    # (file data ID, left, right, top, bottom, sheet width, sheet height, override width, override height, element)
    atlases = {
        "ui-b-blue": (1, 16, 32, 0, 16, 32, 32, 0, 0, 0),
        "ui-a-red": (1, 0, 16, 0, 16, 32, 32, 0, 0, 0),
        "other-wide": (1, 0, 32, 16, 20, 32, 32, 64, 8, 0),
    }
    assert visual.search_atlases(atlases, "UI-") == [("ui-a-red", 16, 16), ("ui-b-blue", 16, 16)], "sorted, case-blind"
    assert visual.search_atlases(atlases, "wide") == [("other-wide", 64, 8)], (
        "the override size wins, as in the listing"
    )
    assert visual.search_atlases(atlases, "nothing") == []
    positions, size = visual.sheet_layout(5, 2, 32, pad=4, label_h=10)
    assert positions == [(0, 0), (40, 0), (0, 50), (40, 50), (0, 100)]
    assert size == (80, 150)
    assert visual.sheet_layout(0, 4, 32)[1] == (0, 0)
    # The real Game and Renderer on a synthetic sheet texture: left half red, right half blue.
    game = wowui.Game(None, {})
    game._atlases = atlases
    sheet = Image.new("RGBA", (32, 32), (255, 0, 0, 255))
    for x in range(16, 32):
        for y in range(32):
            sheet.putpixel((x, y), (0, 0, 255, 255))
    game._images[(None, 1)] = sheet
    renderer = wowui.Renderer(game, Path("."), 1.0)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "sheet.png"
        args = argparse.Namespace(search="ui-", sheet=str(out), filter="ui-", columns=2, cell=32, max=0)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(io.StringIO()):
            assert visual.atlas_tools(args, game, renderer) == 0
        assert printed.getvalue().splitlines()[:2] == ["ui-a-red\t16\t16", "ui-b-blue\t16\t16"]
        _, (w, h) = visual.sheet_layout(2, 2, 32)
        with Image.open(out) as s:
            assert s.size == (w, h)
            pad = 6
            assert s.getpixel((pad + 16, pad + 16)) == (255, 0, 0), "the first cell (sorted: ui-a-red) shows red"
            assert s.getpixel((w // 2 + pad + 16, pad + 16)) == (0, 0, 255), "the second shows blue"
            label = s.crop((0, 32 + 2 * pad, w // 2, h))
            assert len(set(label.getdata())) > 2, "the name and size are written under the picture"
        args = argparse.Namespace(search=None, sheet=str(out), filter="nothing", columns=2, cell=32, max=0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert visual.atlas_tools(args, game, renderer) == 1, "nothing to draw is exit 1"
        args = argparse.Namespace(search="wide", sheet=None, filter=None, columns=2, cell=32, max=0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert visual.atlas_tools(args, game, renderer) == 0


def test_example_sequence_to_gif():
    lua = shutil.which("lua") or shutil.which("lua5.1")
    if not lua:
        print("   (skipped: no lua on PATH)")
        return
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        subprocess.run(
            [lua, "examples/dump_example.lua", "--out", str(tmp / "dump")],
            cwd=ROOT,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        metas = [
            json.loads((tmp / "dump" / f"seq-example-0{i}.json").read_text(encoding="utf-8"))["meta"] for i in (1, 2, 3)
        ]
        assert [m["step"] for m in metas] == [1, 2, 3] and metas[1]["caption"] == "Step 2 changes the text"
        assert _quiet(["render", "--dump", str(tmp / "dump"), "--out", str(tmp / "png")])[0] == 0
        gif = tmp / "example.gif"
        code, _ = _quiet(
            ["gif", "--sequence", "example", "--png", str(tmp / "png"), "--dump", str(tmp / "dump"), "--out", str(gif)]
        )
        assert code == 0
        frames, _ = _gif_frames(gif)
        with Image.open(tmp / "png" / "seq-example-01.png") as first:
            assert len(frames) == 3 and frames[0][0].width == first.width and frames[0][0].height > first.height
        # Step 3 differs from step 2 only in the swatch: the compare sees exactly that.
        code, out = _quiet(
            ["compare", str(tmp / "png" / "seq-example-02.png"), str(tmp / "png" / "seq-example-03.png")]
        )
        assert code == 1 and "pixels changed" in out


def main():
    failed = 0
    tests = [(k, v) for k, v in globals().items() if k.startswith("test_") and callable(v)]
    for name, fn in tests:
        try:
            fn()
            print(f"ok   {name}")
        except Exception:  # noqa: BLE001
            failed += 1
            print(f"FAIL {name}")
            traceback.print_exc()
    print(f"\n{len(tests) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
