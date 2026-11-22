"""Visual tools for wowui: animated GIFs from rendered views, image comparison, an atlas search and contact sheet.

Imported by wowui.py, which registers the commands (`gif`, `compare`, `atlases --search/--sheet`). Pillow only: the
captions and labels use the font Pillow carries (Aileron Regular, public domain), never a game font.
"""

from __future__ import annotations

import argparse
import glob
import io
import json
import re
import sys
from collections import Counter
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".bmp", ".webp")
SEQ_FRAME = re.compile(r"^seq-(?P<name>.+)-(?P<n>\d+)$")

# A neutral dark scheme for bands, gaps and transparent areas.
BAND = (24, 24, 28)
BAND_LINE = (70, 70, 80)
TEXT = (232, 232, 236)
TEXT_DIM = (140, 140, 152)
HIGHLIGHT = (255, 40, 120)
PANEL_GAP = 8  # between the panels of a comparison
PANEL_HEAD = 28  # the label row above them


def die(message: str, code: int = 1):
    """Stop with a message on stderr; exit code 1 (a failed check) or, for unusable input, `code`."""
    if code == 1:
        sys.exit(f"wowui: {message}")
    print(f"wowui: {message}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------------------------------------------------------------
# Shared drawing helpers

_fonts: dict[int, ImageFont.FreeTypeFont] = {}


def font(size: float):
    """The open font for captions and labels: Pillow's built-in Aileron Regular, at `size` pixels."""
    size = max(6, round(size))
    if size not in _fonts:
        _fonts[size] = ImageFont.load_default(size)
    return _fonts[size]


def fit_text(draw: ImageDraw.ImageDraw, text: str, size: float, width: float, min_size: int = 10):
    """(font, text): the text shrunk toward `min_size`, then cut with "...", until it fits `width`."""
    s = round(size)
    f = font(s)
    while s > min_size and draw.textlength(text, font=f) > width:
        s -= 1
        f = font(s)
    if draw.textlength(text, font=f) > width:
        while text and draw.textlength(text + "...", font=f) > width:
            text = text[:-1]
        text = text.rstrip() + "..." if text else ""
    return f, text


def flatten(img: Image.Image, background=BAND) -> Image.Image:
    """An RGB copy; transparent areas show `background`."""
    rgba = img.convert("RGBA")
    if rgba.getextrema()[3][0] == 255:
        return rgba.convert("RGB")
    return Image.alpha_composite(Image.new("RGBA", rgba.size, (*background, 255)), rgba).convert("RGB")


def open_rgba(path: Path) -> Image.Image:
    """The image as RGBA, whatever its mode (palette, LA, 16-bit grey, ...); the file is closed again."""
    try:
        with Image.open(path) as im:
            im.load()
            if im.mode == "I" or im.mode.startswith("I;16"):
                im = im.point(lambda v: v / 256, "L")  # 16-bit grey -> 8-bit, not clipped to white
            return im.convert("RGBA")
    except OSError as e:
        die(f"cannot read image {path}: {e}")


def load_flat(path: Path) -> Image.Image:
    return flatten(open_rgba(path))


def parse_box(text, what: str = "--crop"):
    """ "x,y,w,h" (or a list of four numbers) -> (x, y, w, h)."""
    try:
        parts = text if isinstance(text, (list, tuple)) else str(text).split(",")
        x, y, w, h = (int(float(p)) for p in parts)
    except (TypeError, ValueError):
        die(f"{what} wants x,y,w,h (four numbers), got {text!r}")
    if w <= 0 or h <= 0 or x < 0 or y < 0:
        die(f"{what} wants a positive width and height and a position inside the image, got {text!r}")
    return x, y, w, h


def parse_size(text) -> int:
    """A byte count: 3000000, 500k, 500KB, 3MB, 1.5m."""
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([kKmM]?)[bB]?\s*", str(text))
    if not m:
        die(f"cannot read a size from {text!r} (try 3000000, 500KB or 3MB)")
    return int(float(m[1]) * {"": 1, "k": 1024, "m": 1024 * 1024}[m[2].lower()])


def natural_key(text: str):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r"(\d+)", str(text))]


# ---------------------------------------------------------------------------------------------------------------------
# gif

# Setting name -> JSON key in a sequence spec. Everything else a spec may set has the same name in both.
SPEC_KEYS = {
    "crop": "crop",
    "scale": "scale",
    "width": "width",
    "ms": "ms",
    "last_ms": "lastMs",
    "colors": "colors",
    "min_colors": "minColors",
    "min_width": "minWidth",
    "dither": "dither",
    "loop": "loop",
    "captions": "captions",
    "counter": "counter",
    "max_bytes": "maxBytes",
}
GIF_DEFAULTS = {
    "crop": None,
    "scale": None,
    "width": None,
    "ms": 800,
    "last_ms": None,  # the last frame rests twice as long as the others unless told
    "colors": 256,
    "min_colors": 64,
    "min_width": None,
    "dither": False,
    "loop": 0,  # 0 = forever, N = N more times, None = play once
    "captions": True,
    "counter": False,
    "max_bytes": None,
}


def find_sequences(png_dir: Path) -> dict[str, list[Path]]:
    """{name: frame files in step order} for every seq-<name>-NN image in the folder."""
    found: dict[str, list[tuple[int, Path]]] = {}
    for path in png_dir.iterdir():
        m = SEQ_FRAME.match(path.stem)
        if m and path.suffix.lower() in IMAGE_SUFFIXES:
            found.setdefault(m["name"], []).append((int(m["n"]), path))
    return {name: [p for _, p in sorted(items)] for name, items in sorted(found.items())}


def dump_caption(dump_dir: Path | None, stem: str) -> str | None:
    """The caption `wowui.views` recorded in the view's dump (meta.caption), if the dump is there."""
    if dump_dir is None:
        return None
    path = dump_dir / f"{stem}.json"
    if not path.is_file():
        return None
    try:
        meta = json.loads(path.read_text(encoding="utf-8")).get("meta") or {}
    except (OSError, ValueError):
        return None
    caption = meta.get("caption") if isinstance(meta, dict) else None
    return caption if isinstance(caption, str) and caption else None


def _frame(path: Path, caption=None, ms=None, dumps: Path | None = None) -> dict:
    if not path.is_file():
        die(f"frame not found: {path}")
    return {"path": path, "caption": caption or dump_caption(dumps, path.stem), "ms": ms}


def _spec_settings(entry: dict) -> dict:
    return {k: entry[key] for k, key in SPEC_KEYS.items() if key in entry}


def jobs_from_spec(spec_path: Path, png_dir: Path | None, dump_dir: Path | None, only: set[str]) -> list[dict]:
    try:
        data = json.loads(spec_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        die(f"cannot read the spec {spec_path}: {e}")
    entries = data if isinstance(data, list) else [data]
    base = png_dir or spec_path.parent
    dumps = dump_dir or base
    jobs = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("name"):
            die(f"{spec_path}: every sequence needs a name")
        name = str(entry["name"])
        if only and name not in only:
            continue
        raw = entry.get("frames")
        if raw is None:
            # No frame list: the rendered seq-<sequence>-NN images, with the spec's captions when it has them.
            files = find_sequences(base).get(str(entry.get("sequence", name)))
            if not files:
                die(f"{name}: no seq-{entry.get('sequence', name)}-NN images in {base}")
            captions = entry.get("captions") if isinstance(entry.get("captions"), list) else []
            if captions and len(captions) != len(files):
                die(f"{name}: {len(files)} frames but {len(captions)} captions")
            frames = [_frame(p, captions[i] if captions else None, None, dumps) for i, p in enumerate(files)]
        else:
            frames = []
            for item in raw:
                item = {"file": item} if isinstance(item, str) else item
                if "view" in item:
                    path = base / f"{item['view']}.png"
                elif "file" in item:
                    path = Path(item["file"])
                    path = path if path.is_absolute() else base / path
                else:
                    die(f"{name}: a frame needs a file or a view")
                frames.append(_frame(path, item.get("caption"), item.get("ms"), dumps))
        if not frames:
            die(f"{name}: no frames")
        settings = _spec_settings(entry)
        if isinstance(entry.get("captions"), list):
            settings.pop("captions", None)  # a captions list is the texts, not the on/off switch
        jobs.append({"name": name, "frames": frames, "settings": settings})
    if only and {j["name"] for j in jobs} != only:
        die(f"not in {spec_path}: {', '.join(sorted(only - {j['name'] for j in jobs}))}")
    return jobs


def pad_to_common(images: list[Image.Image]) -> list[Image.Image]:
    """Frames of different sizes are centred on a canvas as large as the largest, in their own corner colour."""
    w = max(i.width for i in images)
    h = max(i.height for i in images)
    out = []
    for img in images:
        if img.size == (w, h):
            out.append(img)
            continue
        canvas = Image.new("RGB", (w, h), img.getpixel((0, 0)))
        canvas.paste(img, ((w - img.width) // 2, (h - img.height) // 2))
        out.append(canvas)
    return out


def auto_crop_box(images: list[Image.Image]):
    """The box around everything that is not the background (the first frame's corner colour) in any frame."""
    w, h = images[0].size
    background = Image.new("RGB", (w, h), images[0].getpixel((0, 0)))
    box = None
    for img in images:
        b = ImageChops.difference(img, background).getbbox()
        if b:
            box = b if box is None else (min(box[0], b[0]), min(box[1], b[1]), max(box[2], b[2]), max(box[3], b[3]))
    return box


def crop_box(images: list[Image.Image], crop):
    """The crop rectangle (left, top, right, bottom) for a "crop" setting, or None for the whole frame."""
    if not crop:
        return None
    if crop == "auto":
        return auto_crop_box(images)
    x, y, w, h = parse_box(crop, "crop")
    full = images[0].size
    box = (min(x, full[0] - 1), min(y, full[1] - 1), min(x + w, full[0]), min(y + h, full[1]))
    return box


def caption_band(frame: Image.Image, text: str, index: int, total: int, counter: bool) -> Image.Image:
    """The frame with a dark band along the bottom: the caption at the left, "n/total" at the right."""
    width, height = frame.size
    size = max(14, round(width / 34))
    pad = round(size * 0.6)
    band = size + pad * 2
    out = Image.new("RGB", (width, height + band), BAND)
    out.paste(frame, (0, 0))
    draw = ImageDraw.Draw(out)
    draw.line([(0, height), (width, height)], fill=BAND_LINE, width=2)
    middle = height + band / 2
    room = width - 2 * pad
    if counter:
        count = f"{index}/{total}"
        cf = font(size)
        draw.text((width - pad, middle), count, font=cf, fill=TEXT_DIM, anchor="rm")
        room -= draw.textlength(count, font=cf) + pad
    f, text = fit_text(draw, text, size, room)
    draw.text((pad, middle), text, font=f, fill=TEXT, anchor="lm")
    return out


def resample_to(img: Image.Image, width: int) -> Image.Image:
    """Resized to `width`: smooth when shrinking, hard pixels when enlarging (UI art stays crisp)."""
    if width == img.width:
        return img
    height = max(1, round(img.height * width / img.width))
    method = Image.Resampling.LANCZOS if width < img.width else Image.Resampling.NEAREST
    return img.resize((width, height), method)


def encode_gif(frames: list[Image.Image], durations: list[int], colors: int, dither: bool, loop) -> bytes:
    """One palette made from all frames, so colours stay put between frames; no dithering unless asked."""
    w, h = frames[0].size
    sheet = Image.new("RGB", (w, h * len(frames)))
    for i, f in enumerate(frames):
        sheet.paste(f, (0, i * h))
    palette = sheet.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    mode = Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE
    paletted = [f.quantize(palette=palette, dither=mode) for f in frames]
    options = {"loop": loop} if loop is not None else {}
    buf = io.BytesIO()
    paletted[0].save(
        buf,
        format="GIF",
        save_all=True,
        append_images=paletted[1:],
        duration=durations,
        optimize=True,
        disposal=1,
        **options,
    )
    return buf.getvalue()


class GifTooBig(Exception):
    """No combination of palette and width fit the size budget."""


def _durations(frames: list[dict], st: dict) -> list[int]:
    ms = [f["ms"] if f["ms"] is not None else st["ms"] for f in frames]
    if frames[-1]["ms"] is None:
        ms[-1] = st["last_ms"] if st["last_ms"] is not None else st["ms"] * 2
    return [max(20, round(v / 10) * 10) for v in ms]  # a GIF counts in hundredths of a second


def build_gif(frames: list[dict], st: dict) -> tuple[bytes, dict]:
    """The GIF for frames [{path, caption, ms}] and settings `st`; (bytes, what was done)."""
    images = pad_to_common([load_flat(f["path"]) for f in frames])
    box = crop_box(images, st["crop"])
    if box:
        images = [i.crop(box) for i in images]
    w0 = images[0].width
    if st["width"]:
        w0 = int(st["width"])
    elif st["scale"]:
        w0 = max(1, round(w0 * float(st["scale"])))
    captions = st["captions"] and (st["counter"] or any(f["caption"] for f in frames))
    durations = _durations(frames, st)
    loop = None if st["loop"] is None or st["loop"] is False else int(st["loop"])

    def render(width: int) -> list[Image.Image]:
        out = []
        for i, (img, f) in enumerate(zip(images, frames, strict=True), 1):
            img = resample_to(img, width)
            out.append(caption_band(img, f["caption"] or "", i, len(frames), st["counter"]) if captions else img)
        return out

    budget = st["max_bytes"]
    widths = [w0]
    if budget:
        floor = max(1, min(w0, st["min_width"] or 240))
        while widths[-1] > floor:
            # Each step is strictly narrower, so a tiny floor cannot stall the ladder.
            widths.append(max(floor, min(widths[-1] - 1, round(widths[-1] * 0.9))))
    ladder = [st["colors"]] + [c for c in (128, 64, 32, 16) if st["min_colors"] <= c < st["colors"]]
    smallest = None
    for width in widths:
        shown = render(width)
        for colors in ladder:
            data = encode_gif(shown, durations, colors, st["dither"], loop)
            smallest = len(data) if smallest is None else min(smallest, len(data))
            if not budget or len(data) <= budget:
                notes = []
                if colors != st["colors"]:
                    notes.append(f"colours {st['colors']} -> {colors}")
                if width != w0:
                    notes.append(f"width {w0} -> {width}")
                info = {
                    "frames": len(frames),
                    "size": shown[0].size,
                    "colors": colors,
                    "bytes": len(data),
                    "notes": notes,
                }
                return data, info
    raise GifTooBig(
        f"no size within {budget} bytes down to {widths[-1]} px and {ladder[-1]} colours; smallest {smallest}"
    )


def collect_gif_jobs(a) -> list[dict]:
    png = Path(a.png) if a.png else None
    dump = Path(a.dump) if a.dump else None
    only = {n.strip() for n in (a.only or "").split(",") if n.strip()}
    sources = [bool(a.frames), bool(a.sequence), bool(a.spec)]
    if sum(sources) != 1:
        die("gif: give frames (files or globs), --sequence <name>, or --spec <file.json>")
    if a.spec:
        return jobs_from_spec(Path(a.spec), png, dump, only)
    if a.sequence:
        if png is None:
            die("gif: --sequence needs --png <folder with the rendered seq-<name>-NN images>")
        found = find_sequences(png)
        names = sorted(found) if a.sequence == ["all"] else [n for v in a.sequence for n in v.split(",") if n]
        jobs = []
        for name in names:
            if name not in found:
                die(f"no seq-{name}-NN images in {png}")
            jobs.append({"name": name, "frames": [_frame(p, dumps=dump or png) for p in found[name]], "settings": {}})
        return jobs
    paths = []
    for pattern in a.frames:
        hits = sorted(glob.glob(pattern), key=natural_key)
        if not hits:
            die(f"no files match {pattern}")
        paths += [Path(h) for h in hits]
    return [{"name": Path(a.out).stem, "frames": [_frame(p, dumps=dump) for p in paths], "settings": {}}]


def cmd_gif(a):
    out = Path(a.out)
    jobs = collect_gif_jobs(a)
    if not jobs:
        die("gif: nothing to build")
    single = out.suffix.lower() == ".gif"
    if single and len(jobs) > 1:
        die(f"gif: {len(jobs)} sequences, so --out must be a folder, not {out}")
    cli = {
        "crop": a.crop,
        "scale": a.scale,
        "width": a.width,
        "ms": a.ms,
        "last_ms": a.last_ms,
        "colors": a.colors,
        "min_colors": a.min_colors,
        "min_width": a.min_width,
        "dither": a.dither or None,
        "loop": None if a.no_loop else a.loop,
        "captions": False if a.no_captions else None,
        "counter": a.counter or None,
        "max_bytes": parse_size(a.max_bytes) if a.max_bytes else None,
    }
    code = 0
    for job in jobs:
        st = dict(GIF_DEFAULTS)
        st.update({k: v for k, v in cli.items() if v is not None})
        if a.no_loop:
            st["loop"] = None
        st.update(job["settings"])
        if "max_bytes" in job["settings"]:
            st["max_bytes"] = parse_size(job["settings"]["max_bytes"])
        target = out if single else out / f"{job['name']}.gif"
        try:
            data, info = build_gif(job["frames"], st)
        except GifTooBig as e:
            print(f"wowui: {job['name']}: {e}", file=sys.stderr)
            code = 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        line = (
            f"wowui: {target}: {info['frames']} frames, {info['size'][0]}x{info['size'][1]}, "
            f"{info['colors']} colours, {info['bytes'] / 1024:.0f} KB"
        )
        if st["max_bytes"]:
            line += f" (budget {st['max_bytes'] / 1024:.0f} KB" + (
                f"; reduced: {', '.join(info['notes'])})" if info["notes"] else ")"
            )
        print(line)
    return code


# ---------------------------------------------------------------------------------------------------------------------
# compare


def to_common_rgba(a: Image.Image, b: Image.Image) -> tuple[Image.Image, Image.Image]:
    """Both as RGBA on a canvas as large as the larger; what an image does not cover is transparent."""
    w, h = max(a.width, b.width), max(a.height, b.height)
    out = []
    for img in (a, b):
        canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        canvas.paste(img.convert("RGBA"), (0, 0))
        out.append(canvas)
    return out[0], out[1]


def changed_mask(a: Image.Image, b: Image.Image, tolerance: int = 0) -> tuple[Image.Image, int]:
    """(mask, count): 255 where any channel differs by more than `tolerance`, and how many pixels that is.

    Pixels that are fully transparent in both images are equal, whatever colour they hide."""
    r, g, bl, al = ImageChops.difference(a, b).split()
    biggest = ImageChops.lighter(ImageChops.lighter(r, g), ImageChops.lighter(bl, al))
    mask = biggest.point([0] * (tolerance + 1) + [255] * (255 - tolerance))
    visible = ImageChops.lighter(a.getchannel("A"), b.getchannel("A")).point([0] + [255] * 255)
    mask = ImageChops.darker(mask, visible)
    return mask, mask.histogram()[255]


def compose_comparison(a, b, mask, labels: tuple[str, str], diff_label: str, zoom: int = 1) -> Image.Image:
    """A | B | diff in one image: the diff is the changed pixels highlighted over a dimmed A."""
    pa, pb = flatten(a), flatten(b)
    dim = pa.point(lambda v: round(v * 0.3))
    diff = Image.composite(Image.new("RGB", pa.size, HIGHLIGHT), dim, mask)
    panels = [pa, pb, diff]
    if zoom > 1:
        panels = [p.resize((p.width * zoom, p.height * zoom), Image.Resampling.NEAREST) for p in panels]
    w, h = panels[0].size
    gap, head = PANEL_GAP, PANEL_HEAD
    if 3 * w + 2 * gap > 30000 or h + head > 30000:
        die(f"the comparison would be {3 * w + 2 * gap} x {h + head} px; use --crop or a smaller --zoom")
    canvas = Image.new("RGB", (3 * w + 2 * gap, h + head), BAND)
    draw = ImageDraw.Draw(canvas)
    for i, (panel, label) in enumerate(zip(panels, (*labels, diff_label), strict=True)):
        x = i * (w + gap)
        canvas.paste(panel, (x, head))
        draw.rectangle([x - 1, head - 1, x + w, head + h], outline=BAND_LINE)
        f, text = fit_text(draw, label, 15, w - 8)
        draw.text((x + 4, head / 2), text, font=f, fill=TEXT, anchor="lm")
    return canvas


def compare_images(path_a: Path, path_b: Path, a) -> dict:
    """Compare two image files; the result has the counts, whether it differs and the composed image."""
    ia, ib = open_rgba(path_a), open_rgba(path_b)
    sizes = (ia.size, ib.size)
    ia, ib = to_common_rgba(ia, ib)
    if a.crop:
        x, y, w, h = parse_box(a.crop)
        if x >= ia.width or y >= ia.height:
            die(f"--crop starts outside the images ({ia.width}x{ia.height})")
        box = (x, y, min(x + w, ia.width), min(y + h, ia.height))
        ia, ib = ia.crop(box), ib.crop(box)
    mask, count = changed_mask(ia, ib, a.tolerance)
    total = ia.width * ia.height
    pct = 100.0 * count / total
    size_differs = sizes[0] != sizes[1] and not a.crop
    labels = a.labels.split(",") if a.labels else ["A", "B"]
    if len(labels) != 2:
        die("--labels wants two names: before,after")
    diff_label = f"diff: {count} px changed ({pct:.4g}%)"
    image = compose_comparison(ia, ib, mask, (labels[0].strip(), labels[1].strip()), diff_label, a.zoom)
    return {
        "count": count,
        "total": total,
        "percent": pct,
        "sizes": sizes,
        "different": size_differs or pct > a.threshold,
        "size_differs": size_differs,
        "image": image,
    }


def _report(name: str, r: dict, a) -> str:
    line = f"wowui: {name}: {r['count']} of {r['total']} pixels changed ({r['percent']:.4g}%)"
    if r["size_differs"]:
        line += f"; sizes differ ({r['sizes'][0][0]}x{r['sizes'][0][1]} vs {r['sizes'][1][0]}x{r['sizes'][1][1]})"
    return line + (" -> different" if r["different"] else " -> same")


def _images_in(folder: Path) -> dict[str, Path]:
    return {p.name.lower(): p for p in sorted(folder.iterdir()) if p.suffix.lower() in IMAGE_SUFFIXES}


def cmd_compare(a):
    pa, pb = Path(a.a), Path(a.b)
    if a.zoom < 1:
        die("--zoom wants 1 or more")
    if not 0 <= a.tolerance <= 255:
        die("--tolerance wants 0 to 255")
    if not pa.exists() or not pb.exists():
        die(f"not found: {pa if not pa.exists() else pb}")
    out = Path(a.out) if a.out else None
    if pa.is_file() and pb.is_file():
        r = compare_images(pa, pb, a)
        print(_report(f"{pa.name} vs {pb.name}", r, a))
        if out:
            if out.suffix.lower() not in IMAGE_SUFFIXES:
                die(f"--out must be an image file ({', '.join(IMAGE_SUFFIXES)}), got {out}")
            out.parent.mkdir(parents=True, exist_ok=True)
            r["image"].save(out, optimize=True)
            print(f"wowui: written {out}")
        return 1 if r["different"] else 0
    if not (pa.is_dir() and pb.is_dir()):
        die("compare: give two images or two folders")
    left, right = _images_in(pa), _images_in(pb)
    if not set(left) & set(right):
        # Nothing to compare is not "same": exit 2, so a wrong folder cannot pass a CI check.
        die(
            f"no image has the same name in both folders ({len(left)} in A, {len(right)} in B; "
            "files are matched by full name, extension included)",
            2,
        )
    stems = Counter(Path(k).stem for k in set(left) & set(right))
    used: set[str] = set()
    different = 0
    for key in sorted(set(left) | set(right), key=natural_key):
        if key not in right or key not in left:
            print(f"wowui: {key}: only in {'A' if key in left else 'B'} -> different")
            different += 1
            continue
        r = compare_images(left[key], right[key], a)
        print(_report(left[key].name, r, a))
        different += r["different"]
        if out:
            out.mkdir(parents=True, exist_ok=True)
            # a.png and a.jpg are two images: the second extension stays in the name so one cannot overwrite the other.
            name = Path(key).stem if stems[Path(key).stem] == 1 else left[key].name
            while f"{name}.png".lower() in used:
                name += "_"
            used.add(f"{name}.png".lower())
            r["image"].save(out / f"{name}.png", optimize=True)
    names = len(set(left) | set(right))
    print(f"wowui: {different} of {names} images differ" + (f"; comparisons written to {out}" if out else ""))
    return 1 if different else 0


# ---------------------------------------------------------------------------------------------------------------------
# atlases --search / --sheet


def atlas_size(v) -> tuple[int, int]:
    """An atlas's width and height as the atlas listing (and C_Texture.GetAtlasInfo) gives them."""
    return (v[7] or (v[2] - v[1])), (v[8] or (v[4] - v[3]))


def search_atlases(atlases: dict, text: str) -> list[tuple[str, int, int]]:
    """(name, width, height) of every atlas whose name contains `text` (case-insensitive), sorted by name."""
    needle = text.lower()
    return [(name, *atlas_size(v)) for name, v in sorted(atlases.items()) if needle in name.lower()]


def sheet_layout(count: int, columns: int, cell: int, pad: int = 6, label_h: int = 44):
    """([(x, y) of each item's cell], (width, height)) of a contact sheet: `cell` px for the image, a label under it."""
    columns = max(1, min(columns, count)) if count else 0
    box_w, box_h = cell + 2 * pad, cell + 2 * pad + label_h
    rows = -(-count // columns) if count else 0
    return [((i % columns) * box_w, (i // columns) * box_h) for i in range(count)], (columns * box_w, rows * box_h)


def wrap_chars(draw: ImageDraw.ImageDraw, text: str, f, width: float, lines: int) -> list[str]:
    """`text` broken anywhere (atlas names have no spaces) into at most `lines` lines, the last one cut with "..."."""
    out: list[str] = []
    while text and len(out) < lines:
        n = len(text)
        while n > 1 and draw.textlength(text[:n], font=f) > width:
            n -= 1
        out.append(text[:n])
        text = text[n:]
    if text:
        last = out[-1] + text
        while last and draw.textlength(last + "...", font=f) > width:
            last = last[:-1]
        out[-1] = last + "..."
    return out


def build_sheet(items: list[tuple[str, int, int]], image_of, columns: int = 8, cell: int = 96) -> Image.Image:
    """A contact sheet of atlases: each image fitted to a cell (small ones enlarged up to 4x) with its name and size.

    `image_of(name, width, height)` returns the atlas drawn at that size (RGBA) or None when it cannot be drawn.
    """
    pad, label_h = 6, 44
    positions, (w, h) = sheet_layout(len(items), columns, cell, pad, label_h)
    sheet = Image.new("RGBA", (max(w, 1), max(h, 1)), (*BAND, 255))
    draw = ImageDraw.Draw(sheet)
    lf = font(11)
    for (name, aw, ah), (x, y) in zip(items, positions, strict=True):
        draw.rectangle([x + 2, y + 2, x + cell + 2 * pad - 3, y + cell + 2 * pad - 3], fill=(40, 40, 46, 255))
        k = min(cell / max(aw, 1), cell / max(ah, 1), 4.0)
        tw, th = max(1, round(aw * k)), max(1, round(ah * k))
        img = image_of(name, tw, th)
        ox, oy = x + pad + (cell - tw) // 2, y + pad + (cell - th) // 2
        if img is None:
            draw.rectangle([ox, oy, ox + tw - 1, oy + th - 1], fill=(70, 30, 30, 255))
        else:
            sheet.alpha_composite(img.convert("RGBA"), (ox, oy))
        text_y = y + cell + 2 * pad
        for line in [*wrap_chars(draw, name, lf, cell + pad, 2), f"{aw}x{ah}"][:3]:
            draw.text((x + pad, text_y), line, font=lf, fill=TEXT if line != f"{aw}x{ah}" else TEXT_DIM)
            text_y += 13
    return sheet.convert("RGB")


def atlas_tools(a, game, renderer) -> int:
    """`atlases --search` and `--sheet`: `game` has the atlas table, `renderer` cuts an atlas out of its texture."""
    code = 0
    if a.search is not None:
        found = search_atlases(game.atlases(), a.search)
        for name, w, h in found:
            print(f"{name}\t{w}\t{h}")
        print(f"wowui: {len(found)} atlases match {a.search!r}", file=sys.stderr)
        code = 0 if found else 1
    if a.sheet:
        found = search_atlases(game.atlases(), a.filter or "")
        if not found:
            print("wowui: no atlases to draw", file=sys.stderr)
            return 1
        shown = found[: a.max] if a.max else found
        sheet = build_sheet(shown, renderer.atlas_image, a.columns, a.cell)
        out = Path(a.sheet)
        out.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(out, optimize=True)
        more = f" (of {len(found)}; --max raises the limit)" if len(shown) < len(found) else ""
        print(f"wowui: {len(shown)} atlases{more} drawn on {out} ({sheet.width}x{sheet.height})")
    return code


# ---------------------------------------------------------------------------------------------------------------------
# Command line


def add_atlas_options(p: argparse.ArgumentParser):
    p.add_argument("--search", help="print the atlases whose name contains this text (case-insensitive) with sizes")
    p.add_argument("--sheet", help="draw a contact sheet of the atlases to this PNG (needs --game)")
    p.add_argument("--filter", help="with --sheet: only atlases whose name contains this text")
    p.add_argument("--columns", type=int, default=8, help="with --sheet: cells per row (default 8)")
    p.add_argument("--cell", type=int, default=96, help="with --sheet: cell size in px (default 96)")
    p.add_argument(
        "--max", type=int, default=200, help="with --sheet: at most this many atlases (default 200, 0 = all)"
    )


def add_commands(sub):
    p = sub.add_parser("gif", help="build an animated GIF from rendered frames")
    p.add_argument("frames", nargs="*", help="image files or globs, in order (or use --sequence / --spec)")
    p.add_argument("--out", required=True, help="the .gif to write (a folder when several sequences are built)")
    p.add_argument(
        "--sequence", action="append", help="build the rendered seq-<name>-NN images in --png (name, a,b or all)"
    )
    p.add_argument("--spec", help="a JSON sequence spec (see the README)")
    p.add_argument("--png", help="folder of rendered images (default for a spec: the spec's folder)")
    p.add_argument("--dump", help="folder of dump .json files whose meta.caption gives each frame's caption")
    p.add_argument("--only", help="with --spec: comma-separated sequence names to build")
    p.add_argument("--crop", help="x,y,w,h in pixels, or auto (trim the background around everything that changes)")
    p.add_argument("--scale", type=float, help="scale factor (shrinking is smooth, enlarging keeps hard pixels)")
    p.add_argument("--width", type=int, help="output width in px before the caption band (wins over --scale)")
    p.add_argument("--ms", type=int, help="time per frame in ms (default 800)")
    p.add_argument("--last-ms", type=int, help="time of the last frame (default: twice --ms)")
    p.add_argument("--colors", type=int, help="palette size, 2-256 (default 256)")
    p.add_argument("--dither", action="store_true", help="dither the palette (off by default: cleaner UI art)")
    p.add_argument("--loop", type=int, default=0, help="0 = loop forever (default), N = repeat N more times")
    p.add_argument("--no-loop", action="store_true", help="play once")
    p.add_argument("--no-captions", action="store_true", help="no caption band")
    p.add_argument("--counter", action="store_true", help="show n/total in the caption band")
    p.add_argument(
        "--max-bytes", help="size budget (3000000, 500KB, 3MB): fewer colours, then less width, until it fits"
    )
    p.add_argument("--min-colors", type=int, help="with --max-bytes: never fewer colours than this (default 64)")
    p.add_argument("--min-width", type=int, help="with --max-bytes: never narrower than this (default 240)")
    p.set_defaults(fn=cmd_gif)
    p = sub.add_parser("compare", help="side by side and pixel diff of two images or two folders")
    p.add_argument("a", help="image or folder")
    p.add_argument("b", help="image or folder (folders: files with the same name are compared)")
    p.add_argument("--out", help="the PNG to write: A | B | diff (a folder when comparing folders)")
    p.add_argument("--labels", help="two names for the panels, e.g. before,after")
    p.add_argument("--crop", help="compare only x,y,w,h")
    p.add_argument("--zoom", type=int, default=1, help="enlarge the panels n times, hard pixels")
    p.add_argument(
        "--tolerance", type=int, default=0, help="a pixel counts as changed above this channel difference (0-255)"
    )
    p.add_argument("--threshold", type=float, default=0.0, help="percent of changed pixels still counted as the same")
    p.set_defaults(fn=cmd_compare)
