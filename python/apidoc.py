"""Offline API lookup: Blizzard's API documentation tables, read from the client's own files.

The client ships a load-on-demand addon, Blizzard_APIDocumentationGenerated: one Lua file per system, each ending in
`APIDocumentation:AddDocumentationTable(<table>)` with the functions, events and tables (enumerations, structures,
callback types) of a namespace. This module reads those files without running them (a small parser for Lua table
constructors), from the client's CASC storage or from a folder of copies, and prints signatures.

    wowui.py api C_Map.GetMapInfo --game "<World of Warcraft>/_retail_"
    wowui.py api GetMapInfo --docs <folder with the documentation .lua files>
    wowui.py api --search waypoint --game ...

The files are Blizzard's: they are read at run time and never copied into this repository.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ADDON = "Blizzard_APIDocumentationGenerated"
ADDON_PATH = f"Interface\\AddOns\\{ADDON}\\"
# The addon's table of contents: one name for every flavour so far, flavour-specific names tried after it.
TOC_NAMES = [
    ADDON + suffix + ".toc" for suffix in ("", "_Mainline", "_Vanilla", "_Classic", "_TBC", "_Wrath", "_Cata", "_Mists")
]
CACHE_SCHEMA = "wowui-api-cache/2"  # raise it when the parser or the shape of the parsed tables changes
MAX_DEPTH = 100  # table nesting the parser accepts (the documentation's own is under 10)

EXIT_NOT_FOUND = 1
EXIT_NO_DOCS = 2  # also usage errors and a cache path that is refused
EXIT_AMBIGUOUS = 3

# ---------------------------------------------------------------------------------------------------------------------
# Lua table literals


class LuaError(ValueError):
    pass


_NUMBER = re.compile(r"0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_LONG_OPEN = re.compile(r"\[(=*)\[")
_DECIMAL_ESCAPE = re.compile(r"\d{1,3}")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\\": "\\", '"': '"', "'": "'"}
_OPERATORS = ("...", "..", "==", "~=", "<=", ">=")
_BINARY = {"+", "-", "*", "/", "%", "^", "..", "==", "~=", "<", ">", "<=", ">="}


def _line_of(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def _long_bracket(src: str, i: int, m: re.Match[str], what: str) -> tuple[str, int]:
    """The text of a long bracket whose opener `m` starts at i, and the position after its closer."""
    close = "]" + m.group(1) + "]"
    end = src.find(close, m.end())
    if end < 0:
        raise LuaError(f"line {_line_of(src, i)}: unfinished {what}")
    text = src[m.end() : end]
    return (text[1:] if text.startswith("\r\n") else text[1:] if text.startswith("\n") else text), end + len(close)


def _quoted(src: str, i: int) -> tuple[str, int]:
    """A '...' or "..." string starting at i (Lua escapes; \\ddd bytes are read as UTF-8) and the position after it."""
    quote = src[i]
    start = i
    i += 1
    out = bytearray()
    while True:
        c = src[i : i + 1]
        if c in ("", "\n", "\r"):
            raise LuaError(f"line {_line_of(src, start)}: unfinished string")
        if c == quote:
            return out.decode("utf-8", "replace"), i + 1
        if c != "\\":
            out += c.encode()
            i += 1
            continue
        e = src[i + 1 : i + 2]
        if e in _ESCAPES:
            out += _ESCAPES[e].encode()
            i += 2
        elif e in ("\n", "\r"):  # a backslash before a line break: a newline (CRLF and LFCR count as one break)
            out += b"\n"
            i += 2
            if src[i : i + 1] in ("\n", "\r") and src[i : i + 1] != e:
                i += 1
        elif e == "x":
            out.append(int(src[i + 2 : i + 4], 16))
            i += 4
        elif e == "z":
            i += 2
            while src[i : i + 1].isspace():
                i += 1
        elif m := _DECIMAL_ESCAPE.match(src, i + 1):
            out.append(int(m.group()) & 0xFF)
            i = m.end()
        else:
            raise LuaError(f"line {_line_of(src, i)}: bad escape \\{e}")


def tokenize(src: str) -> list[tuple[str, object, int, int]]:
    """(kind, value, start, end) per token: kind is "str", "num", "name" or "op"; comments and blanks are dropped."""
    toks: list[tuple[str, object, int, int]] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
        elif src.startswith("--", i):
            m = _LONG_OPEN.match(src, i + 2)
            if m:
                i = _long_bracket(src, i, m, "long comment")[1]
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
        elif c in "\"'":
            s, j = _quoted(src, i)
            toks.append(("str", s, i, j))
            i = j
        elif c == "[" and (m := _LONG_OPEN.match(src, i)):
            s, j = _long_bracket(src, i, m, "long string")
            toks.append(("str", s, i, j))
            i = j
        elif m := _NUMBER.match(src, i):
            text = m.group()
            if text[:2].lower() == "0x":
                value: int | float = int(text, 16)
            elif re.fullmatch(r"\d+", text):
                value = int(text)
            else:
                value = float(text)
            toks.append(("num", value, i, m.end()))
            i = m.end()
        elif m := _NAME.match(src, i):
            toks.append(("name", m.group(), i, m.end()))
            i = m.end()
        else:
            op = next((o for o in _OPERATORS if src.startswith(o, i)), c)
            toks.append(("op", op, i, i + len(op)))
            i += len(op)
    return toks


class _Parser:
    def __init__(self, src: str):
        self.src = src
        self.toks = tokenize(src)
        self.i = 0
        self.variables: dict[str, object] = {}
        self.depth = 0

    def peek(self, k: int = 0) -> tuple[str, object, int, int]:
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else ("eof", "", len(self.src), len(self.src))

    def is_op(self, value: str, k: int = 0) -> bool:
        t = self.peek(k)
        return t[0] == "op" and t[1] == value

    def fail(self, message: str):
        raise LuaError(f"line {_line_of(self.src, self.peek()[2])}: {message}")

    def expect(self, value: str):
        if not self.is_op(value):
            self.fail(f"expected {value!r}")
        self.i += 1

    def value(self):
        """A literal, a table, or an earlier variable; any other expression is kept as {"expr": <its source text>}."""
        start = self.i
        kind, v = self.peek()[:2]
        if kind in ("str", "num"):
            self.i += 1
            result = v
        elif kind == "op" and v == "-" and self.peek(1)[0] == "num":
            self.i += 2
            result = -self.toks[self.i - 1][1]
        elif kind == "op" and v == "{":
            return self.table()
        elif kind == "name" and v in ("true", "false", "nil"):
            self.i += 1
            result = {"true": True, "false": False, "nil": None}[v]
        elif kind == "name" and v in self.variables and not any(self.is_op(o, 1) for o in (".", ":", "(")):
            self.i += 1
            result = self.variables[v]
        else:
            return self.expression()
        t = self.peek()
        if t[0] == "op" and t[1] in _BINARY:
            self.i = start
            return self.expression()
        return result

    def expression(self):
        """Skip an expression the parser does not evaluate (Enum.X.Y, a + 1, f(x)) up to its end; keep its text.

        It ends at a ',' or ';', at a closing bracket that is not its own, or where an operand follows an operand (the
        next statement: `local X = Foo` newline `local Y`); a call written without parentheses (`f "x"`) ends it early.
        """
        start, depth, after_operand = self.i, 0, False
        while (t := self.peek())[0] != "eof":
            if t[0] == "op":
                if t[1] in ("(", "[", "{"):
                    depth += 1
                elif t[1] in (")", "]", "}"):
                    if depth == 0:
                        break
                    depth -= 1
                elif t[1] in (",", ";") and depth == 0:
                    break
            operand = t[0] in ("str", "num") or (t[0] == "name" and t[1] not in ("and", "or", "not"))
            if depth == 0 and operand and after_operand:
                break
            after_operand = operand or (t[0] == "op" and t[1] in (")", "]", "}"))
            self.i += 1
        if self.i == start:
            self.fail("expected a value")
        return {"expr": self.src[self.toks[start][2] : self.toks[self.i - 1][3]]}

    def table(self):
        """A table constructor: a list when it has only positional entries, else a dict (positional ones keyed 1..n)."""
        if self.depth >= MAX_DEPTH:
            self.fail(f"tables nested deeper than {MAX_DEPTH}")
        self.depth += 1
        self.expect("{")
        positional: list = []
        keyed: dict = {}
        while not self.is_op("}"):
            kind, v = self.peek()[:2]
            if kind == "eof":
                self.fail("unfinished table")
            if self.is_op("["):
                self.i += 1
                key = self.value()
                self.expect("]")
                self.expect("=")
                item = self.value()
                if isinstance(key, dict) and set(key) == {"expr"}:
                    keyed[key["expr"]] = item  # [Enum.X] = 1: keyed by the expression's text
                elif not isinstance(key, (dict, list)):
                    keyed[key] = item  # a table as a key cannot be a Python key: the entry is dropped
            elif kind == "name" and self.is_op("=", 1):
                self.i += 2
                keyed[v] = self.value()
            else:
                positional.append(self.value())
            if self.is_op(",") or self.is_op(";"):
                self.i += 1
            elif not self.is_op("}"):
                self.fail("expected ',' or '}'")
        self.i += 1
        self.depth -= 1
        if not keyed:
            return positional
        for n, item in enumerate(positional, 1):
            keyed.setdefault(n, item)
        return keyed


def parse_value(src: str):
    """The Lua value (table constructor, string, number, boolean, nil) that `src` is, without running anything."""
    p = _Parser(src)
    value = p.value()
    if p.peek()[0] != "eof":
        p.fail("unexpected text after the value")
    return value


def parse_documentation(src: str) -> list[dict]:
    """The tables a documentation file hands to APIDocumentation:AddDocumentationTable, in order.

    Reads `local X = {...}` / `X = {...}` assignments of literals and the AddDocumentationTable call with a table or a
    name; every other token of the file is skipped (nothing is executed).
    """
    p = _Parser(src)
    out: list[dict] = []
    while p.peek()[0] != "eof":
        kind, v = p.peek()[:2]
        if kind == "name" and v == "local" and p.peek(1)[0] == "name" and p.is_op("=", 2):
            p.i += 1
            kind, v = p.peek()[:2]
        if kind == "name" and p.is_op("=", 1):
            p.i += 2
            p.variables[v] = p.value()
        elif (
            kind == "name"
            and v == "APIDocumentation"
            and p.is_op(":", 1)
            and p.peek(2)[1] == "AddDocumentationTable"
            and p.is_op("(", 3)
        ):
            p.i += 4
            doc = p.value()
            p.expect(")")
            if isinstance(doc, dict):
                out.append(doc)
        else:
            p.i += 1
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Sources: a client's CASC storage, or a folder of the Lua files


class SourceError(Exception):
    """The documentation cannot be read at all (or the cache path is refused); the message says why. Exit code 2."""


@dataclass
class Source:
    docs: list[dict]  # the documentation tables, file by file
    signature: str  # changes when the files may have (the cache key)
    warnings: list[str]

    @property
    def complete(self) -> bool:
        """Something was found and nothing was skipped: the only read worth caching."""
        return bool(self.docs) and not self.warnings


def _parse_files(files: list[tuple[str, str]]) -> tuple[list[dict], list[str]]:
    docs: list[dict] = []
    warnings: list[str] = []
    for name, text in files:
        try:
            docs += parse_documentation(text)
        except (LuaError, ValueError) as e:
            warnings.append(f"{name}: {e}")
    return docs, warnings


def docs_folder(folder: Path) -> Path | None:
    """The folder holding the documentation .lua files: `folder`, or the addon's folder below it (a source checkout)."""
    for rel in ("", ADDON, f"Interface/AddOns/{ADDON}", f"AddOns/{ADDON}"):
        p = folder / rel
        if p.is_dir() and any(p.glob("*.lua")):
            return p
    return None


def read_folder(folder: Path) -> Source | None:
    base = docs_folder(folder)
    if base is None:
        return None
    paths = sorted(base.glob("*.lua"), key=lambda p: p.name.lower())
    files: list[tuple[str, str]] = []
    unreadable: list[str] = []
    stamp = []
    for p in paths:
        try:
            files.append((p.name, p.read_text(encoding="utf-8", errors="replace")))
            stamp.append(f"{p.name}:{p.stat().st_size}:{p.stat().st_mtime_ns}")
        except OSError as e:
            unreadable.append(f"{p.name} ({e})")
    docs, warnings = _parse_files(files)
    if unreadable:
        warnings.append("unreadable files: " + ", ".join(unreadable[:5]))
    return Source(docs, "folder:" + hashlib.sha1("\n".join(stamp).encode()).hexdigest(), warnings)


def _build_info(game: Path) -> Path | None:
    for d in (game, *game.parents):
        if (d / ".build.info").exists():
            return d / ".build.info"
    return None


def game_signature(game: Path) -> str:
    info = _build_info(game)
    if info is None:
        return ""
    return "game:" + hashlib.sha1(info.read_bytes() + str(game.resolve()).lower().encode()).hexdigest()


def read_game(game: Path) -> Source | None:
    """The documentation tables of a client's CASC storage, or None when its build has no such addon.

    Raises SourceError when the storage cannot be opened; a file that cannot be read is a warning.
    """
    import casc

    try:
        c = casc.Casc(game)
    except Exception as e:  # noqa: BLE001
        raise SourceError(f"cannot read the client's CASC storage at {game}: {e}") from e
    toc = None
    for name in TOC_NAMES:
        try:
            toc = c.read(ADDON_PATH + name)
        except Exception as e:  # noqa: BLE001
            raise SourceError(f"cannot read {name} from the client's CASC storage: {e}") from e
        if toc:
            break
    if not toc:
        return None
    names = []
    for line in toc.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and line.split()[0].lower().endswith(".lua"):
            names.append(line.split()[0].replace("/", "\\"))
    files: list[tuple[str, str]] = []
    missing: list[str] = []
    unreadable: list[str] = []
    for name in sorted(names, key=str.lower):
        try:
            raw = c.read(ADDON_PATH + name)
        except Exception as e:  # noqa: BLE001
            unreadable.append(f"{name} ({e})")
            continue
        if raw is None:
            missing.append(name)
        else:
            files.append((name, raw.decode("utf-8", "replace")))
    docs, warnings = _parse_files(files)
    if missing:
        warnings.append(
            f"{len(missing)} listed files are not in this install (not downloaded): " + ", ".join(missing[:5])
        )
    if unreadable:
        warnings.append(f"{len(unreadable)} files could not be read: " + ", ".join(unreadable[:5]))
    return Source(docs, game_signature(game), warnings)


def _check_cache_path(game: Path, cache: Path) -> None:
    """The game folder is only read: a cache file in it, or beside the .build.info above it, is refused."""
    info = _build_info(game)
    target = cache.resolve()
    for folder in (game, info.parent if info else game):
        if target.is_relative_to(folder.resolve()):
            raise SourceError(
                f"--cache {cache} is inside the game folder {folder}, which is only read: pick another path"
            )


def _read_cache(cache: Path, sig: str) -> Source | None:
    try:
        data = json.loads(cache.read_text(encoding="utf-8"))
        if data["schema"] == CACHE_SCHEMA and data["signature"] == sig and isinstance(data["docs"], list):
            return Source(data["docs"], sig, [])
    except (OSError, ValueError, KeyError, TypeError):
        pass  # missing or damaged: rebuilt
    return None


def _write_cache(cache: Path, sig: str, docs: list[dict]) -> str | None:
    """Write the cache through a temporary file; the problem as text, or None."""
    tmp = cache.with_name(cache.name + ".tmp")
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps({"schema": CACHE_SCHEMA, "signature": sig, "docs": docs}), encoding="utf-8")
        os.replace(tmp, cache)
    except OSError as e:
        return f"cache {cache} not written: {e}"
    return None


def load(game: Path | None, folder: Path | None, cache: Path | None) -> Source | None:
    """The documentation tables from `folder` (copies of the files) or `game`; `cache` (JSON) saves re-reading it.

    The cache is written only for a complete read (no warnings, something found), so a partial install is not frozen
    into it, and never inside the game folder.
    """
    if folder is not None:
        return read_folder(folder)
    assert game is not None
    sig = game_signature(game)
    if cache is not None:
        _check_cache_path(game, cache)
        if sig and (src := _read_cache(cache, sig)):
            return src
    src = read_game(game)
    if src is not None and cache is not None and sig and src.complete:
        problem = _write_cache(cache, sig, src.docs)
        if problem:
            src.warnings.append(problem)
    return src


# ---------------------------------------------------------------------------------------------------------------------
# Index and lookup

KIND_ORDER = {"function": 0, "method": 0, "event": 1, "enum": 2, "structure": 3, "callback": 4, "constants": 5}
TABLE_KINDS = {"Enumeration": "enum", "Structure": "structure", "CallbackType": "callback", "Constants": "constants"}


@dataclass
class Entry:
    kind: str  # function, method (of a script object), event, enum, structure, callback, constants
    name: str  # the full name: C_Map.GetMapInfo, SimpleFrameAPI:SetAlpha, PLAYER_MAP_CHANGED, Enum.UIMapType
    short: str  # the name in the table: GetMapInfo, SetAlpha, PlayerMapChanged, UIMapType
    group: str  # the namespace (C_Map) or script object (SimpleFrameAPI) it belongs to; "" for globals
    system: str  # the documentation table's own name ("MapUI")
    raw: dict

    @property
    def key(self) -> tuple:
        return (KIND_ORDER.get(self.kind, 9), self.name.lower(), self.name, self.system)


def build_index(docs: list[dict]) -> list[Entry]:
    out: list[Entry] = []
    for d in docs:
        system = str(d.get("Name") or "")
        is_object = d.get("Type") == "ScriptObject"
        group = system if is_object else str(d.get("Namespace") or "")
        for f in _params(d.get("Functions")):
            short = str(f.get("Name") or "")
            own = str(f["Namespace"]) if "Namespace" in f else group  # a function may name its own namespace
            if is_object:
                out.append(Entry("method", f"{own}:{short}", short, own, system, f))
            else:
                out.append(Entry("function", f"{own}.{short}" if own else short, short, own, system, f))
        for e in _params(d.get("Events")):
            short = str(e.get("Name") or "")
            out.append(Entry("event", str(e.get("LiteralName") or short), short, group, system, e))
        for t in _params(d.get("Tables")):
            short = str(t.get("Name") or "")
            kind = TABLE_KINDS.get(str(t.get("Type")), str(t.get("Type") or "table").lower())
            prefix = {"enum": "Enum.", "constants": "Constants."}.get(kind, "")
            out.append(Entry(kind, prefix + short, short, group, system, t))
    unique: dict[tuple, Entry] = {}
    for e in out:  # the same entry in two files (identical tables) counts once
        unique.setdefault((e.kind, e.name, json.dumps(e.raw, sort_keys=True, default=str)), e)
    return sorted(unique.values(), key=lambda e: e.key)


def groups_of(index: list[Entry]) -> dict[str, list[Entry]]:
    out: dict[str, list[Entry]] = {}
    for e in index:
        if e.group:
            out.setdefault(e.group, []).append(e)
    return out


def lookup(index: list[Entry], query: str) -> tuple[str, list[Entry]]:
    """("group" | "entries", matches): a whole namespace or script object, or the entries the name fits.

    Tried in turn: a namespace or object name; a full name (C_Map.GetMapInfo, Enum.UIMapType, an event's literal name,
    a structure's name, an enum's name without "Enum."); a short function, method or event name (GetMapInfo). The
    same again ignoring case when nothing matched.
    """
    groups = groups_of(index)
    for fold in (False, True):
        norm = str.lower if fold else (lambda s: s)
        q = norm(query)
        group = next((g for g in groups if norm(g) == q), None)
        if group is not None:
            return "group", groups[group]
        hits = [e for e in index if norm(e.name) == q or (e.kind in ("enum", "constants") and norm(e.short) == q)]
        if not hits:
            hits = [e for e in index if e.kind in ("function", "method", "event") and norm(e.short) == q]
        if hits:
            return "entries", hits
    return "entries", []


def search(index: list[Entry], text: str) -> list[Entry]:
    q = text.lower()
    return [e for e in index if q in e.name.lower() or q in e.short.lower()]


# ---------------------------------------------------------------------------------------------------------------------
# Output

_SKIP_META = {
    "Name",
    "Type",
    "Arguments",
    "Returns",
    "Documentation",
    "Payload",
    "Fields",
    "Values",
    "LiteralName",
    "Namespace",
}


def _lua_text(v) -> str:
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "{" + ", ".join(_lua_text(x) for x in v) + "}"
    if isinstance(v, dict):
        if set(v) == {"expr"}:
            return str(v["expr"])
        return "{" + ", ".join(f"{k} = {_lua_text(x)}" for k, x in v.items()) + "}"
    return str(v)


def _type_text(p: dict) -> str:
    t = str(p.get("Type", "?"))
    return f"{t}<{p['InnerType']}>" if p.get("InnerType") else t


def _param_text(p: dict) -> str:
    s = f"{p.get('Name', '?')}: {_type_text(p)}"
    if p.get("Nilable"):
        s += "?"
    if p.get("Default") is not None:
        s += f" = {_lua_text(p['Default'])}"
    return s


def _params(items) -> list[dict]:
    return [p for p in (items or []) if isinstance(p, dict)]


def _call_text(name: str, args, returns) -> str:
    s = f"{name}({', '.join(_param_text(p) for p in _params(args))})"
    rets = _params(returns)
    return s + (" -> " + ", ".join(_param_text(p) for p in rets) if rets else "")


def signature(e: Entry) -> str:
    r = e.raw
    if e.kind in ("function", "method", "callback"):
        return _call_text(e.name, r.get("Arguments"), r.get("Returns"))
    if e.kind == "event":
        return _call_text(e.name, r.get("Payload"), None)
    return e.name


def _align(rows: list[list[str]], indent: str = "  ") -> list[str]:
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return [indent + "  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)).rstrip() for r in rows]


def _param_rows(items) -> list[str]:
    rows = []
    for p in _params(items):
        notes = []
        if p.get("Nilable"):
            notes.append("nilable")
        if p.get("Default") is not None:
            notes.append(f"default {_lua_text(p['Default'])}")
        if p.get("Mixin"):
            notes.append(f"mixin {p['Mixin']}")
        doc = p.get("Documentation")
        if doc:
            notes.append(" ".join(doc) if isinstance(doc, list) else str(doc))
        rows.append([str(p.get("Name", "?")), _type_text(p), "; ".join(notes)])
    return _align(rows) if rows else []


def _value_rows(e: Entry) -> list[str]:
    """An enumeration's names with their numbers, or a constants table's names with type and value."""
    if e.kind == "enum":
        rows = [[str(f.get("Name")), "= " + _lua_text(f.get("EnumValue"))] for f in _params(e.raw.get("Fields"))]
    else:
        rows = [
            [str(v.get("Name")), _type_text(v), "= " + _lua_text(v.get("Value"))] for v in _params(e.raw.get("Values"))
        ]
    return _align(rows) if rows else []


def _referenced_types(e: Entry) -> list[str]:
    """Type names an entry's parameters, payload, fields and returns mention (in order, once each)."""
    out: list[str] = []
    for key in ("Arguments", "Returns", "Payload", "Fields"):
        if e.kind == "enum" and key == "Fields":
            continue
        for p in _params(e.raw.get(key)):
            for t in (p.get("Type"), p.get("InnerType")):
                if isinstance(t, str) and t not in out:
                    out.append(t)
    return out


def render(e: Entry) -> list[str]:
    r = e.raw
    where = f"{e.kind} in {e.system}" if e.system else e.kind
    if e.group and e.kind not in ("function", "method"):
        where += f" ({e.group})"
    if e.kind == "event":
        where += f", {e.short}"
    meta = [
        f"{k}: {v if isinstance(v, str) else _lua_text(v)}"
        for k, v in sorted(r.items(), key=lambda kv: str(kv[0]))
        if k not in _SKIP_META
    ]
    lines = [signature(e), "  " + "; ".join([where, *meta])]
    doc = r.get("Documentation")
    for d in doc if isinstance(doc, list) else [doc] if doc else []:
        lines.append(f"  {d}")
    if e.kind in ("enum", "constants"):
        sections = [("Values", _value_rows(e))]
    else:
        sections = [(k, _param_rows(r.get(k))) for k in ("Arguments", "Payload", "Returns", "Fields")]
    for title, rows in sections:
        if rows:
            lines += ["", f"{title}:", *rows]
    return lines


def _camel(v):
    """The doc's CamelCase keys as lowerCamel, all the way down (the JSON output's naming)."""
    if isinstance(v, dict):
        return {(k[:1].lower() + k[1:] if isinstance(k, str) else str(k)): _camel(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_camel(x) for x in v]
    return v


def describe(e: Entry) -> dict:
    body = _camel(e.raw)
    body.pop("name", None)  # the entry's full name replaces the table's short one
    return {"kind": e.kind, "name": e.name, "system": e.system, "group": e.group, **body}


def expand_types(index: list[Entry], entries: list[Entry]) -> list[Entry]:
    """The structures, enums and callback types the entries refer to, and those they refer to, each once."""
    by_name: dict[str, list[Entry]] = {}
    for e in index:
        if e.kind in ("enum", "structure", "callback"):
            by_name.setdefault(e.short, []).append(e)
    seen = {id(e) for e in entries}
    out: list[Entry] = []
    queue = list(entries)
    while queue:
        e = queue.pop(0)
        for t in _referenced_types(e):
            for hit in by_name.get(t.removeprefix("Enum."), []):
                if id(hit) not in seen:
                    seen.add(id(hit))
                    out.append(hit)
                    queue.append(hit)
    return sorted(out, key=lambda e: e.key)


def _list_line(e: Entry) -> str:
    return f"{e.kind:<9} {signature(e)}" + (f"  [{e.system}]" if e.system else "")


def _brief(e: Entry) -> dict:
    return {"kind": e.kind, "name": e.name, "system": e.system}


def run(a) -> int:
    """The `api` subcommand (a: the parsed command line, see add_arguments). Exit code: 0 found, 1 nothing found,
    2 usage error, no documentation to read or a refused --cache path, 3 the name fits several entries."""
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    if a.docs is None and a.game is None:
        print("wowui: api needs --game <client folder> or --docs <folder of the documentation files>", file=sys.stderr)
        return EXIT_NO_DOCS
    if a.name is None and a.search is None:
        print("wowui: api needs a name to look up, or --search <text>", file=sys.stderr)
        return EXIT_NO_DOCS
    if a.docs is not None and a.cache is not None:
        print("wowui: --cache applies to --game only; ignored with --docs", file=sys.stderr)
    try:
        src = load(
            Path(a.game) if a.game else None, Path(a.docs) if a.docs else None, Path(a.cache) if a.cache else None
        )
    except SourceError as e:
        print(f"wowui: {e}", file=sys.stderr)
        return EXIT_NO_DOCS
    for w in src.warnings if src else []:
        print(f"wowui: warning: {w}", file=sys.stderr)
    if src is None or not src.docs:
        where = f"in {a.docs}" if a.docs else f"in the client at {a.game}"
        print(
            f"wowui: no {ADDON} documentation {where}. Older clients do not ship it: "
            "point --docs at a copy of its .lua files (a wow-ui-source checkout works).",
            file=sys.stderr,
        )
        return EXIT_NO_DOCS
    index = build_index(src.docs)

    if a.search is not None:
        hits = search(index, a.search)
        if a.json:
            print(json.dumps([_brief(e) for e in hits], indent=2, ensure_ascii=False))
        else:
            for e in hits:
                print(_list_line(e))
            print(f"wowui: {len(hits)} matches for {a.search!r}", file=sys.stderr)
        return 0 if hits else EXIT_NOT_FOUND

    mode, hits = lookup(index, a.name)
    if not hits:
        print(f"wowui: nothing named {a.name!r}; try --search {a.name}", file=sys.stderr)
        return EXIT_NOT_FOUND
    if mode == "entries" and len(hits) > 1:
        if a.json:
            print(json.dumps({"ambiguous": [_brief(e) for e in hits]}, indent=2, ensure_ascii=False))
        else:
            print(f"{a.name!r} fits {len(hits)} entries; ask for one by its full name:")
            for e in hits:
                print("  " + _list_line(e))
        return EXIT_AMBIGUOUS

    extra = expand_types(index, hits) if a.expand else []
    if a.json:
        doc = {"kind": "group", "name": hits[0].group, "entries": [describe(e) for e in hits]}
        if mode == "entries":
            doc = describe(hits[0])
        if extra:
            doc["expanded"] = [describe(e) for e in extra]
        print(json.dumps(doc, indent=2, ensure_ascii=False))
        return 0
    if mode == "group":
        kind = "script object" if hits[0].kind == "method" else "namespace"
        print(f"{hits[0].group}  ({kind}; {', '.join(sorted({e.system for e in hits}))})")
        for e in hits:
            print("  " + _list_line(e))
    else:
        print("\n".join(render(hits[0])))
    for e in extra:
        print()
        print("\n".join(render(e)))
    return 0


def add_arguments(p) -> None:
    p.add_argument(
        "name", nargs="?", help="C_Map.GetMapInfo, GetMapInfo, C_Map, PLAYER_LOGIN, Enum.UIMapType, UiMapDetails"
    )
    p.add_argument("--game", help="client folder to read the documentation from (CASC storage, read-only)")
    p.add_argument("--docs", help="folder with the documentation .lua files instead (a wow-ui-source checkout works)")
    p.add_argument("--search", metavar="TEXT", help="list every function, event and table whose name contains TEXT")
    p.add_argument("--expand", action="store_true", help="also print the structures and enums the entry refers to")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument(
        "--cache", help="JSON file to keep the parsed documentation in (with --game; never in the game folder)"
    )
