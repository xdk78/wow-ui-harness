"""A minimal reader for the client's WDC3 / WDC4 / WDC5 database files (DBFilesClient/*.db2).

Only what UI tooling needs: unencrypted sections, inline fields of every storage kind (plain, bit-packed, common
data, pallet, pallet arrays, signed), the ID list, the copy table and string fields. Sparse (offset-map) tables and
relationship columns are not decoded (`DB2.sparse` tells).

    db = DB2(raw_bytes)
    for rid, row in db.rows():          # row: list of ints, one per field (arrays give their first value)
        name = db.string(rid, 0)        # field 0 read as a string
"""

from __future__ import annotations

import struct

__all__ = ["DB2"]


class DB2:
    def __init__(self, raw: bytes):
        self.raw = raw
        magic = raw[:4]
        if magic not in (b"WDC3", b"WDC4", b"WDC5"):
            raise ValueError(f"unsupported db2 format {magic!r}")
        p = 4
        if magic == b"WDC5":
            p += 4 + 128  # version, schema string
        (
            self.record_count,
            self.field_count,
            self.record_size,
            self.string_table_size,
            self.table_hash,
            self.layout_hash,
            self.min_id,
            self.max_id,
            self.locale,
            self.flags,
            self.id_index,
            self.total_field_count,
            self.bitpacked_offset,
            self.lookup_columns,
            self.storage_info_size,
            self.common_size,
            self.pallet_size,
            self.section_count,
        ) = struct.unpack_from("<9I2H7I", raw, p)
        p += 9 * 4 + 4 + 7 * 4
        self.sparse = bool(self.flags & 0x1)
        self.sections = []
        for _ in range(self.section_count):
            s = struct.unpack_from("<Q8I", raw, p)
            p += 40
            self.sections.append(
                dict(
                    tact=s[0],
                    offset=s[1],
                    records=s[2],
                    strings=s[3],
                    records_end=s[4],
                    id_list=s[5],
                    relationship=s[6],
                    offset_map_ids=s[7],
                    copies=s[8],
                )
            )
        self.structure = [struct.unpack_from("<hH", raw, p + 4 * i) for i in range(self.field_count)]
        p += 4 * self.field_count
        self.storage = []
        for i in range(self.storage_info_size // 24):
            off_bits, size_bits, extra, kind, v1, v2, v3 = struct.unpack_from("<HHIIIII", raw, p + 24 * i)
            self.storage.append(dict(off=off_bits, size=size_bits, extra=extra, kind=kind, v1=v1, v2=v2, v3=v3))
        p += self.storage_info_size
        # Pallet and common data: one block each, every field's part in field order.
        self.pallet = {}
        self.common = {}
        pal_at = p
        com_at = p + self.pallet_size
        for i, st in enumerate(self.storage):
            if st["kind"] in (3, 4):
                self.pallet[i] = raw[pal_at : pal_at + st["extra"]]
                pal_at += st["extra"]
            elif st["kind"] == 2:
                block = raw[com_at : com_at + st["extra"]]
                self.common[i] = {
                    struct.unpack_from("<I", block, j)[0]: struct.unpack_from("<I", block, j + 4)[0]
                    for j in range(0, len(block), 8)
                }
                com_at += st["extra"]
        self._load_sections()

    def _load_sections(self):
        raw = self.raw
        self._records = []  # (id, record bytes, global index)
        self._strings = {}  # global string offset -> bytes start position in raw
        total = sum(s["records"] for s in self.sections)
        string_base = 0
        index = 0
        self._copies = []
        for s in self.sections:
            if s["tact"] and s["records"] and all(b == 0 for b in raw[s["offset"] : s["offset"] + 16]):
                index += s["records"]
                string_base += s["strings"]
                continue  # an encrypted section the client has no key for: zero-filled
            p = s["offset"]
            if self.sparse:
                raise ValueError("sparse db2 tables are not supported")
            recs = []
            for i in range(s["records"]):
                recs.append(raw[p + i * self.record_size : p + (i + 1) * self.record_size])
            p += s["records"] * self.record_size
            strings_at = p
            p += s["strings"]
            ids = []
            if s["id_list"]:
                ids = list(struct.unpack_from(f"<{s['id_list'] // 4}I", raw, p))
                p += s["id_list"]
            for _ in range(s["copies"]):
                new, old = struct.unpack_from("<II", raw, p)
                self._copies.append((new, old))
                p += 8
            for i, rec in enumerate(recs):
                rid = ids[i] if ids else self._field(rec, self.id_index)
                self._records.append((rid, rec, index + i))
            self._string_blocks = getattr(self, "_string_blocks", [])
            self._string_blocks.append((string_base, strings_at, s["strings"]))
            string_base += s["strings"]
            index += s["records"]
        self._total = total
        self._by_id = {rid: (rec, gi) for rid, rec, gi in self._records}
        for new, old in self._copies:
            if old in self._by_id and new not in self._by_id:
                self._by_id[new] = self._by_id[old]

    def _bits(self, rec: bytes, off: int, size: int) -> int:
        if size <= 0:
            return 0
        start, end = off >> 3, (off + size + 7) >> 3
        v = int.from_bytes(rec[start:end], "little") >> (off & 7)
        return v & ((1 << size) - 1)

    def _field(self, rec: bytes, i: int, rid: int | None = None) -> int:
        st = self.storage[i]
        kind = st["kind"]
        if kind == 0:
            size = min(st["size"], 32)
            return self._bits(rec, st["off"], size)
        if kind in (1, 5):
            v = self._bits(rec, st["off"], st["size"])
            if kind == 5 and v & (1 << (st["size"] - 1)):
                v -= 1 << st["size"]
            return v
        if kind == 2:
            return self.common.get(i, {}).get(rid, st["v1"]) if rid is not None else st["v1"]
        if kind in (3, 4):
            idx = self._bits(rec, st["off"], st["size"])
            width = 4 * (st["v3"] if kind == 4 else 1)
            pal = self.pallet.get(i, b"")
            if (idx + 1) * width > len(pal):
                return 0
            return struct.unpack_from("<I", pal, idx * width)[0]
        return 0

    def rows(self):
        """(id, [field values]) for every record and copy, in file order (copies last)."""
        for rid, rec, _ in self._records:
            yield rid, [self._field(rec, i, rid) for i in range(len(self.storage))]
        for new, old in self._copies:
            if old in self._by_id:
                rec, _ = self._by_id[old]
                yield new, [self._field(rec, i, old) for i in range(len(self.storage))]

    def string(self, rid: int, field: int) -> str | None:
        """Field `field` of record `rid` read as a string (an offset into the string tables), or None."""
        hit = self._by_id.get(rid)
        if not hit:
            return None
        rec, gi = hit
        st = self.storage[field]
        value = self._bits(rec, st["off"], 32)
        pos = gi * self.record_size - self._total * self.record_size + (st["off"] >> 3) + value
        for base, at, size in getattr(self, "_string_blocks", []):
            if base <= pos < base + size:
                start = at + (pos - base)
                end = self.raw.index(b"\0", start)
                return self.raw[start:end].decode("utf-8", "replace")
        return None
