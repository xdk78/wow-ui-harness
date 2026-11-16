# /// script
# requires-python = ">=3.15"
# dependencies = ["pillow>=11"]
# ///
"""Tests for the Python side, without a game install. From the repository root:

    uv run --script tests/test_cli.py

Needs `lua` (5.1) on PATH: it dumps the example addon first, then renders and lints that dump.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))

import casc  # noqa: E402
import db2  # noqa: E402
import wowui  # noqa: E402
from PIL import Image  # noqa: E402


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


def test_texcoords_flip_and_crop():
    img = Image.new("RGBA", (4, 2))
    img.putpixel((0, 0), (255, 0, 0, 255))
    out = wowui._crop_coords(img, [0, 0.5, 0, 1])
    assert out.size == (2, 2)
    flipped = wowui._crop_coords(img, [0.5, 0, 0, 1])
    assert flipped.getpixel((1, 0)) == (255, 0, 0, 255)


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
        import json

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
