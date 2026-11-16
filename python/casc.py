"""Read-only access to a World of Warcraft client's local CASC storage.

Enough to read a file by its path or by its file data ID from an installed client:
.build.info -> build config -> encoding (content key -> encoded key) and root (name hash / file data ID -> content key),
then .idx -> data.### -> BLTE. Nothing is ever written to the game folder.

    from casc import Casc
    casc = Casc(Path("<World of Warcraft>/_retail_"))   # any folder at or below the one holding .build.info
    raw = casc.read("Fonts\\FRIZQT__.TTF")               # bytes or None
    raw = casc.read_fid(136235)                         # bytes or None
    casc.file_id("Interface\\Icons\\INV_Misc_Map_01.blp")

Encrypted (salsa20) BLTE chunks and unknown chunk modes raise ValueError for that file only.
"""

from __future__ import annotations

import bisect
import struct
import zlib
from pathlib import Path

__all__ = ["Casc", "name_hash"]

# Root locale flags. Files are picked for one locale (enUS by default).
LOCALES = {
    "enUS": 0x2,
    "koKR": 0x4,
    "frFR": 0x10,
    "deDE": 0x20,
    "zhCN": 0x40,
    "esES": 0x80,
    "zhTW": 0x100,
    "enGB": 0x200,
    "esMX": 0x1000,
    "ruRU": 0x2000,
    "ptBR": 0x4000,
    "itIT": 0x8000,
    "ptPT": 0x10000,
}


def _rot(x, k):
    return ((x << k) | (x >> (32 - k))) & 0xFFFFFFFF


def _hashlittle2(data: bytes):
    m = 0xFFFFFFFF
    n = len(data)
    a = b = c = (0xDEADBEEF + n) & m
    i = 0
    while n > 12:
        x, y, z = struct.unpack_from("<III", data, i)
        a, b, c = (a + x) & m, (b + y) & m, (c + z) & m
        a = (a - c) & m
        a ^= _rot(c, 4)
        c = (c + b) & m
        b = (b - a) & m
        b ^= _rot(a, 6)
        a = (a + c) & m
        c = (c - b) & m
        c ^= _rot(b, 8)
        b = (b + a) & m
        a = (a - c) & m
        a ^= _rot(c, 16)
        c = (c + b) & m
        b = (b - a) & m
        b ^= _rot(a, 19)
        a = (a + c) & m
        c = (c - b) & m
        c ^= _rot(b, 4)
        b = (b + a) & m
        n -= 12
        i += 12
    if n == 0:
        return c, b
    x, y, z = struct.unpack_from("<III", data[i:] + b"\0" * (12 - n))
    a, b, c = (a + x) & m, (b + y) & m, (c + z) & m
    c ^= b
    c = (c - _rot(b, 14)) & m
    a ^= c
    a = (a - _rot(c, 11)) & m
    b ^= a
    b = (b - _rot(a, 25)) & m
    c ^= b
    c = (c - _rot(b, 16)) & m
    a ^= c
    a = (a - _rot(c, 4)) & m
    b ^= a
    b = (b - _rot(a, 14)) & m
    c ^= b
    c = (c - _rot(b, 24)) & m
    return c, b


def name_hash(path: str) -> int:
    """Jenkins hashlittle2 of the upper-cased, backslashed path: the key of named root entries."""
    c, b = _hashlittle2(path.upper().replace("/", "\\").encode())
    return (c << 32) | b


def blte(data: bytes) -> bytes:
    """Decode a BLTE container (plain and zlib chunks)."""
    if data[:4] != b"BLTE":
        raise ValueError("not BLTE")
    hsize = struct.unpack_from(">I", data, 4)[0]
    if hsize == 0:
        sizes, pos = [len(data) - 8], 8
    else:
        count = int.from_bytes(data[9:12], "big")
        sizes = [struct.unpack_from(">I", data, 12 + 24 * i)[0] for i in range(count)]
        pos = hsize
    out = []
    for size in sizes:
        chunk = data[pos : pos + size]
        pos += size
        mode = chunk[:1]
        if mode == b"N":
            out.append(chunk[1:])
        elif mode == b"Z":
            out.append(zlib.decompress(chunk[1:]))
        else:
            raise ValueError(f"BLTE chunk mode {mode!r} not supported")
    return b"".join(out)


class Casc:
    def __init__(self, game: Path, locale: str = "enUS"):
        game = Path(game)
        root = game
        while not (root / ".build.info").exists():
            if root.parent == root:
                raise FileNotFoundError(f"no .build.info at or above {game}")
            root = root.parent
        self.locale_flag = LOCALES.get(locale, 0x2)
        self.data = root / "Data"
        lines = (root / ".build.info").read_text(encoding="utf-8").splitlines()
        head = [h.split("!")[0] for h in lines[0].split("|")]
        rows = [dict(zip(head, line.split("|"), strict=False)) for line in lines[1:] if line.strip()]
        flavor = game / ".flavor.info"
        product = flavor.read_text(encoding="utf-8").splitlines()[1].strip() if flavor.exists() else None
        row = next((r for r in rows if r.get("Product") == product and r.get("Active") == "1"), rows[0])
        key = row["Build Key"]
        self.cfg = {}
        cfg_path = self.data / "config" / key[:2] / key[2:4] / key
        for line in cfg_path.read_text(encoding="utf-8").splitlines():
            if " = " in line:
                k, v = line.split(" = ", 1)
                self.cfg[k] = v.split()
        self._index()
        self._encoding()
        self._root()

    def _index(self):
        best = {}
        for f in (self.data / "data").glob("*.idx"):
            bucket, version = int(f.name[:2], 16), int(f.name[2:10], 16)
            if bucket not in best or version > best[bucket][0]:
                best[bucket] = (version, f)
        self.index = {}
        for _, f in best.values():
            b = f.read_bytes()
            start = (8 + struct.unpack_from("<I", b, 0)[0] + 15) & ~15
            size = struct.unpack_from("<I", b, start)[0]
            for p in range(start + 8, start + 8 + size - 17, 18):
                k = b[p : p + 9]
                if k not in self.index:
                    off = int.from_bytes(b[p + 9 : p + 14], "big")
                    self.index[k] = (off >> 30, off & 0x3FFFFFFF, struct.unpack_from("<I", b, p + 14)[0])

    def _read_ekey(self, ekey: bytes) -> bytes | None:
        hit = self.index.get(ekey[:9])
        if hit is None:
            return None  # known to the build but not downloaded (a streamed or partial install)
        archive, off, size = hit
        with open(self.data / "data" / f"data.{archive:03d}", "rb") as f:
            f.seek(off)
            return blte(f.read(size)[30:])

    def _encoding(self):
        e = self._read_ekey(bytes.fromhex(self.cfg["encoding"][1]))
        if e[:2] != b"EN":
            raise ValueError("encoding file")
        self.ck, self.ek = e[3], e[4]
        self.page = struct.unpack_from(">H", e, 5)[0] * 1024
        count = struct.unpack_from(">I", e, 9)[0]
        p = 22 + struct.unpack_from(">I", e, 18)[0]
        self.firsts = [e[p + i * 32 : p + i * 32 + self.ck] for i in range(count)]
        self.pages = p + count * 32
        self.enc = e

    def _ekey(self, ckey: bytes):
        i = bisect.bisect_right(self.firsts, ckey) - 1
        p = self.pages + i * self.page
        end, e = p + self.page, self.enc
        while i >= 0 and p < end and e[p]:
            if e[p + 6 : p + 6 + self.ck] == ckey:
                return e[p + 6 + self.ck : p + 6 + self.ck + self.ek]
            p += 6 + self.ck + e[p] * self.ek
        return None

    def _root(self):
        r = self._read_ekey(self._ekey(bytes.fromhex(self.cfg["root"][0])))
        if r[:4] != b"TSFM":
            raise ValueError("root format not supported")
        a, b = struct.unpack_from("<II", r, 4)
        version, p = 0, 12
        total, named = a, b
        if a == 0x18 and b in (1, 2):
            version = b
            total, named = struct.unpack_from("<II", r, 12)
            p = 24
        nameless_ok = total != named
        self.by_hash: dict[int, bytes] = {}
        self.fid_by_hash: dict[int, int] = {}
        self.by_fid: dict[int, bytes] = {}
        want = self.locale_flag
        while p < len(r):
            if version >= 2:
                n, locale, f1, f2 = struct.unpack_from("<IIII", r, p)
                content = f1 | f2 | (r[p + 16] << 17)
                p += 17
            else:
                n, content, locale = struct.unpack_from("<III", r, p)
                p += 12
            deltas = struct.unpack_from(f"<{n}I", r, p)
            p += 4 * n
            ckeys = p
            p += 16 * n
            hashes = None
            if not (nameless_ok and content & 0x10000000):
                hashes = struct.unpack_from(f"<{n}Q", r, p)
                p += 8 * n
            if not (locale & want) or content & 0x80:  # another language, or the low-violence variant
                continue
            fid = -1
            for i in range(n):
                fid += 1 + deltas[i]  # file data IDs: the first delta, then each one past the previous
                ck = r[ckeys + 16 * i : ckeys + 16 * i + 16]
                self.by_fid.setdefault(fid, ck)
                if hashes is not None:
                    self.by_hash.setdefault(hashes[i], ck)
                    self.fid_by_hash.setdefault(hashes[i], fid)

    def _read_ckey(self, ck):
        ek = ck and self._ekey(ck)
        return self._read_ekey(ek) if ek else None

    def read(self, path: str):
        """A file's bytes by its path (case and slash direction do not matter), or None."""
        return self._read_ckey(self.by_hash.get(name_hash(path)))

    def read_fid(self, fid: int):
        """A file's bytes by its file data ID, or None."""
        return self._read_ckey(self.by_fid.get(int(fid)))

    def file_id(self, path: str):
        """The file's data ID (what GetFileIDFromPath returns in game), or None."""
        return self.fid_by_hash.get(name_hash(path))
