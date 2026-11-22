#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.15"
# dependencies = []
# ///
"""Static safety check for a World of Warcraft addon's Lua source: no game, no mock, standard library only.

    uv run --script <harness>/python/wowui.py check [--config FILE] [--root DIR] [--format text|json] [paths...]
    uv run --script <harness>/python/check.py       [same options]

It tokenizes each Lua file (strings, comments and long brackets are skipped, so text inside them never triggers a
rule), follows local scopes closely enough to tell a local from a global, and reports unsafe or forbidden patterns:
one finding per line, `path:line: rule-id: message`. Exit code 0 when there is no unsuppressed finding, 1 when there
is one, 2 for a usage or config error. The rules, the config file (`.wowui-check.json` in the root) and the
suppression comments are described in README.md ("Static safety check").
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

DEFAULT_CONFIG = ".wowui-check.json"

RULES = (
    "forbidden-call",
    "combat-log",
    "new-global",
    "file-length",
    "test-shell-find",
    "unguarded-registration",
    "suppression-reason",
)

# Defaults an addon may override in its config (README: "Static safety check"). They are a starting point, not a
# statement about what every addon must avoid.
DEFAULT_INCLUDE = ["**/*.lua"]
DEFAULT_EXCLUDE = ["Libs/**", "libs/**"]
DEFAULT_FORBIDDEN_CALLS = [
    "OpenWorldMap",
    "SetCVar",
    "SetBinding",
    "SetBindingClick",
    "SaveBindings",
    "loadstring",
    "load",
    "RunScript",
]
DEFAULT_HOOK_TARGETS = ["WorldMapFrame", "PlayerFrame", "TargetFrame", "FocusFrame", "GameMenuFrame"]
DEFAULT_COMBAT_LOG_EVENTS = ["COMBAT_LOG_EVENT", "COMBAT_LOG_EVENT_UNFILTERED"]
DEFAULT_MAX_LINES = 1000
DEFAULT_TEST_GLOBS = ["tests/**"]


class ConfigError(Exception):
    """A problem with the config file or the command line (exit code 2)."""


# ---------------------------------------------------------------------------------------------------------------------
# Lua tokenizer


class Tok(NamedTuple):
    kind: str  # "name", "kw", "str", "num", "op"
    text: str  # a string token holds the decoded content, without quotes or brackets
    line: int  # 1-based line where the token starts


KEYWORDS = frozenset(
    "and break do else elseif end false for function if in local nil not or repeat return then true until while".split()
)
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUM = re.compile(r"0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_LONG_OPEN = re.compile(r"\[(=*)\[")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}
_OPS2 = frozenset(["..", "==", "~=", "<=", ">="])


def tokenize(text: str) -> tuple[list[Tok], list[tuple[int, str]]]:
    """Split Lua 5.1 source into tokens and comments `(line, text without the dashes or brackets)`.

    Never raises: an unterminated string ends at its line, an unterminated long bracket at the end of the file,
    and a character Lua has no token for becomes a one-character operator.
    """
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    toks: list[Tok] = []
    comments: list[tuple[int, str]] = []
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\f\v":
            i += 1
        elif c == "-" and text.startswith("--", i):
            m = _LONG_OPEN.match(text, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                end = text.find(close, m.end())
                stop = n if end < 0 else end + len(close)
                comments.append((line, text[m.end() : n if end < 0 else end]))
                line += text.count("\n", i, stop)
                i = stop
            else:
                end = text.find("\n", i)
                if end < 0:
                    end = n
                comments.append((line, text[i + 2 : end]))
                i = end
        elif c == "[" and (m := _LONG_OPEN.match(text, i)):
            close = "]" + m.group(1) + "]"
            end = text.find(close, m.end())
            stop = n if end < 0 else end + len(close)
            body = text[m.end() : n if end < 0 else end]
            toks.append(Tok("str", body[1:] if body.startswith("\n") else body, line))
            line += text.count("\n", i, stop)
            i = stop
        elif c == '"' or c == "'":
            j, buf, extra = i + 1, [], 0
            while j < n:
                d = text[j]
                if d == c or d == "\n":
                    break
                if d != "\\":
                    buf.append(d)
                    j += 1
                    continue
                j += 1
                if j >= n:
                    break
                e = text[j]
                if e == "\n":
                    buf.append("\n")
                    extra += 1
                    j += 1
                elif e == "z":
                    j += 1
                    while j < n and text[j] in " \t\f\v\n":
                        extra += text[j] == "\n"
                        j += 1
                elif e.isdigit():
                    k = j
                    while k < n and k < j + 3 and text[k].isdigit():
                        k += 1
                    buf.append(chr(min(int(text[j:k]), 255)))
                    j = k
                else:
                    buf.append(_ESCAPES.get(e, e))
                    j += 1
            toks.append(Tok("str", "".join(buf), line))
            if j < n and text[j] == c:
                j += 1
            line += extra
            i = j
        elif c.isalpha() or c == "_":
            m = _NAME.match(text, i)
            if m:
                word = m.group()
                toks.append(Tok("kw" if word in KEYWORDS else "name", word, line))
                i = m.end()
            else:  # a non-ASCII letter: no token in Lua 5.1
                toks.append(Tok("op", c, line))
                i += 1
        elif (c.isdigit() or (c == "." and text[i + 1 : i + 2].isdigit())) and (m := _NUM.match(text, i)):
            toks.append(Tok("num", m.group(), line))
            i = m.end()
        else:
            if text.startswith("...", i):
                op = "..."
            elif text[i : i + 2] in _OPS2:
                op = text[i : i + 2]
            else:
                op = c
            toks.append(Tok("op", op, line))
            i += len(op)
    return toks, comments


# ---------------------------------------------------------------------------------------------------------------------
# Scope tracking: calls and assignments, with the facts the rules need


class Call(NamedTuple):
    chain: str  # "SetCVar", "frame.HookScript" (':' and '.' alike); "?.Name" when the receiver is an expression
    root_local: bool  # the first name of the chain is a local variable
    line: int
    open_idx: int  # index of the token that opens the arguments: '(', a string or '{'
    guarded: bool


class Assign(NamedTuple):
    kind: str  # "global" (Foo = / _G.Foo = / _G["Foo"] =), "func" (function Foo), "member-func" (function Foo.bar /
    #            Foo:bar, name is Foo) or "index" (Foo[...] = / Foo.x = with a single index; name is Foo)
    name: str
    line: int
    guarded: bool


class _Entry:
    """One level of the nesting stack: a scope (chunk, function, block, if, a for/while header) or a bracket group."""

    __slots__ = ("kind", "locals", "guard_seen", "cond_guard", "negated", "in_cond", "first_return")

    def __init__(self, kind: str, locals_=()):
        self.kind = kind
        self.locals = set(locals_)
        self.guard_seen = False  # chunk/func: a guard function was called earlier in it
        self.cond_guard = False  # if: a guard function is called in a condition
        self.negated = False  # if: ... and it is written `not guard(...)`
        self.in_cond = False  # if: between `if`/`elseif` and `then`
        self.first_return = None  # if: the first branch starts with `return`


_OPEN = frozenset("({[")
_CLOSE = frozenset(")}]")
_STMT_PREV = frozenset([")", "]", "}", ";", "end", "do", "then", "else", "repeat", "nil", "true", "false", "..."])
_SCOPE_KINDS = frozenset(["chunk", "func", "block", "if", "header"])
_CALL_OPEN = frozenset(["(", "{"])


class Analysis(NamedTuple):
    calls: list[Call]
    assigns: list[Assign]


def _is_op(t: Tok, *texts: str) -> bool:
    return t.kind == "op" and t.text in texts


def analyze(toks: list[Tok], guards: frozenset[str] = frozenset()) -> Analysis:
    """Walk the tokens once and collect every call and every assignment to a non-local name.

    Scopes: `local` and `local function` names, function parameters (and `self` of `function a:b()`), `for`
    variables, and blocks opened by function / do / then / repeat and closed by end / until. A name counts as local
    from its declaration to the end of the block, in any enclosing function. A statement is "guarded" when one of
    `guards` (normalised call chains such as `MyAddon.CanRegister`) was called before it, see `guarded()` below.
    """
    n = len(toks)
    stack = [_Entry("chunk")]
    calls: list[Call] = []
    assigns: list[Assign] = []

    def is_local(name: str) -> bool:
        return any(name in e.locals for e in stack)

    def scope() -> _Entry:
        return next(e for e in reversed(stack) if e.kind in _SCOPE_KINDS)

    def nearest_block() -> _Entry:
        return next(e for e in reversed(stack) if e.kind != "group")

    def nearest_func() -> _Entry:
        return next(e for e in reversed(stack) if e.kind in ("func", "chunk"))

    def guarded() -> bool:
        # Guarded: an enclosing function (or the chunk) called a guard earlier, or an enclosing `if` has a guard call
        # in its condition (not negated: `if not guard() then <here> end` runs when the guard failed).
        return any(e.guard_seen or (e.cond_guard and not e.negated) for e in stack)

    def skip_group(j: int) -> int:
        depth = 0
        while j < n:
            t = toks[j]
            if t.kind == "op":
                if t.text in _OPEN:
                    depth += 1
                elif t.text in _CLOSE:
                    depth -= 1
                    if depth == 0:
                        return j + 1
            j += 1
        return n

    def pop_block() -> None:
        while stack[-1].kind == "group":
            stack.pop()
        if len(stack) > 1:
            e = stack.pop()
            if e.kind == "if" and e.cond_guard and e.first_return:
                nearest_func().guard_seen = True  # `if [not] guard() then return end`: the guard was consulted

    def begin_function(j: int, method: bool) -> int:
        params = {"self"} if method else set()
        if j < n and toks[j].text == "(":
            j += 1
            while j < n and toks[j].text != ")":
                if toks[j].kind == "name":
                    params.add(toks[j].text)
                j += 1
            j += 1
        stack.append(_Entry("func", params))
        return j

    def statement_start(i: int) -> bool:
        top = stack[-1]
        if top.kind in ("group", "header") or (top.kind == "if" and top.in_cond):
            return False
        if i == 0:
            return True
        p = toks[i - 1]
        return p.kind in ("name", "str", "num") or p.text in _STMT_PREV

    def targets(i: int) -> list[tuple[Tok, list[tuple[str, str | None]]]] | None:
        """The variable list of an assignment statement starting at toks[i], or None when it is not one."""
        out = []
        j = i
        while True:
            if j >= n or toks[j].kind != "name":
                return None
            root = toks[j]
            j += 1
            suffixes: list[tuple[str, str | None]] = []
            while j < n:
                t = toks[j]
                if _is_op(t, ".") and j + 1 < n and toks[j + 1].kind == "name":
                    suffixes.append((".", toks[j + 1].text))
                    j += 2
                elif _is_op(t, "["):
                    end = skip_group(j)
                    key = toks[j + 1].text if end == j + 3 and toks[j + 1].kind == "str" else None
                    suffixes.append(("[", key))
                    j = end
                elif t.kind == "str":
                    suffixes.append(("call", None))
                    j += 1
                elif _is_op(t, *_CALL_OPEN):
                    suffixes.append(("call", None))
                    j = skip_group(j)
                else:
                    break
            out.append((root, suffixes))
            if j < n and _is_op(toks[j], ","):
                j += 1
                continue
            if j < n and _is_op(toks[j], "="):
                return out
            return None

    i = 0
    while i < n:
        t = toks[i]
        k, x = t.kind, t.text
        if k == "kw":
            if x == "local":
                if i + 1 < n and toks[i + 1].kind == "kw" and toks[i + 1].text == "function":
                    if i + 2 < n and toks[i + 2].kind == "name":
                        scope().locals.add(toks[i + 2].text)
                        i = begin_function(i + 3, False)
                        continue
                else:
                    j = i + 1
                    while j < n and toks[j].kind == "name":
                        scope().locals.add(toks[j].text)
                        j += 1
                        if j < n and _is_op(toks[j], ","):
                            j += 1
                        else:
                            break
                    i = j
                    continue
            elif x == "function":
                j, method = i + 1, False
                if j < n and toks[j].kind == "name":
                    names = [toks[j]]
                    j += 1
                    while j + 1 < n and _is_op(toks[j], ".", ":") and toks[j + 1].kind == "name":
                        method = toks[j].text == ":"
                        names.append(toks[j + 1])
                        j += 2
                    root = names[0]
                    if root.text == "_G" and len(names) == 2 and not is_local("_G"):
                        assigns.append(Assign("func", names[1].text, names[1].line, guarded()))  # function _G.Foo()
                    elif not is_local(root.text):
                        kind = "func" if len(names) == 1 else "member-func"
                        assigns.append(Assign(kind, root.text, root.line, guarded()))
                i = begin_function(j, method)
                continue
            elif x == "if":
                e = _Entry("if")
                e.in_cond = True
                stack.append(e)
            elif x == "then":
                b = nearest_block()
                if b.kind == "if" and b.in_cond:
                    b.in_cond = False
                    if b.first_return is None:
                        b.first_return = i + 1 < n and toks[i + 1].kind == "kw" and toks[i + 1].text == "return"
            elif x == "elseif":
                b = nearest_block()
                if b.kind == "if":
                    b.in_cond = True
                    b.locals.clear()
            elif x == "else":
                b = nearest_block()
                if b.kind == "if":
                    b.locals.clear()
            elif x in ("end", "until"):
                pop_block()
            elif x == "do":
                if stack[-1].kind == "header":
                    stack[-1].kind = "block"
                else:
                    stack.append(_Entry("block"))
            elif x == "while":
                stack.append(_Entry("header"))
            elif x == "for":
                j, loop_vars = i + 1, set()
                while j < n and toks[j].kind == "name":
                    loop_vars.add(toks[j].text)
                    j += 1
                    if j < n and _is_op(toks[j], ","):
                        j += 1
                    else:
                        break
                stack.append(_Entry("header", loop_vars))
                i = j
                continue
            elif x == "repeat":
                stack.append(_Entry("block"))
        elif k == "op":
            if x in _OPEN:
                stack.append(_Entry("group"))
            elif x in _CLOSE and stack[-1].kind == "group":
                stack.pop()
        elif k == "name":
            prev = toks[i - 1] if i else None
            member = prev is not None and _is_op(prev, ".", ":")
            if not member and statement_start(i):
                for root, suffixes in targets(i) or ():
                    if is_local(root.text):
                        continue
                    if not suffixes:
                        assigns.append(Assign("global", root.text, root.line, guarded()))
                    elif len(suffixes) == 1 and suffixes[0][0] in (".", "["):
                        key = suffixes[0][1]
                        if root.text == "_G":
                            if key is not None:
                                assigns.append(Assign("global", key, root.line, guarded()))
                        else:
                            assigns.append(Assign("index", root.text, root.line, guarded()))
            nxt = toks[i + 1] if i + 1 < n else None
            if nxt is not None and (nxt.kind == "str" or _is_op(nxt, *_CALL_OPEN)):
                # A call. Walk back over `a.b:c` to its first name; an expression receiver (`f():g()`) gives "?".
                parts, j = [x], i
                while j >= 2 and _is_op(toks[j - 1], ".", ":") and toks[j - 2].kind == "name":
                    parts.insert(0, toks[j - 2].text)
                    j -= 2
                known = not (j >= 1 and _is_op(toks[j - 1], ".", ":"))
                if not known:
                    parts.insert(0, "?")
                chain = ".".join(parts)
                if chain.removeprefix("_G.") in guards:
                    b = nearest_block()
                    if b.kind == "if" and b.in_cond:
                        b.cond_guard = True
                        b.negated = j >= 1 and toks[j - 1].kind == "kw" and toks[j - 1].text == "not"
                    else:
                        nearest_func().guard_seen = True
                calls.append(Call(chain, known and is_local(parts[0]), t.line, i + 1, guarded()))
        i += 1
    return Analysis(calls, assigns)


# ---------------------------------------------------------------------------------------------------------------------
# Config


def glob_regex(pattern: str) -> re.Pattern[str]:
    """A glob over repo-relative paths with '/': `**` any depth, `*` and `?` within one segment. A pattern without
    '/' matches the file name at any depth; one ending in '/' means everything below it."""
    if pattern.endswith("/"):
        pattern += "**"
    if "/" not in pattern:
        pattern = "**/" + pattern
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out), re.DOTALL)


_CLASSES = {"d": r"\d", "a": r"[A-Za-z]", "w": r"[A-Za-z0-9]", "l": r"[a-z]", "u": r"[A-Z]", "x": r"[0-9A-Fa-f]"}


def name_regex(pattern: str) -> re.Pattern[str]:
    """An allowlist entry: a plain name, or a Lua-style pattern. `%d %a %w %l %u %x` are character classes (a `+`,
    `*` or `?` right after one is its quantifier), `%` before another character escapes it, a `*` anywhere else
    matches any characters (`BINDING_*`). The whole name must match."""
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if c == "%" and i + 1 < len(pattern):
            d = pattern[i + 1]
            out.append(_CLASSES.get(d) or re.escape(d))
            i += 2
            if d in _CLASSES and i < len(pattern) and pattern[i] in "+*?":
                out.append(pattern[i])
                i += 1
        elif c == "*":
            out.append(".*")
            i += 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("".join(out))


def _norm_call(name: str) -> str:
    return name.replace(":", ".").removeprefix("_G.")


@dataclass
class Config:
    include: list[re.Pattern[str]]
    exclude: list[re.Pattern[str]]
    disable: list[tuple[re.Pattern[str], frozenset[str]]]
    enabled: dict[str, bool]
    forbidden: dict[str, str] = field(default_factory=dict)  # normalised call -> extra message
    hook_targets: frozenset[str] = frozenset()
    events: frozenset[str] = frozenset()
    allow: list[re.Pattern[str]] = field(default_factory=list)
    max_lines: int = DEFAULT_MAX_LINES
    line_overrides: list[tuple[re.Pattern[str], int]] = field(default_factory=list)
    test_globs: list[re.Pattern[str]] = field(default_factory=list)
    guards: frozenset[str] = frozenset()

    def active(self, rule: str, path: str) -> bool:
        if not self.enabled[rule]:
            return False
        return not any(rule in rules and rx.fullmatch(path) for rx, rules in self.disable)

    def lines_limit(self, path: str) -> int:
        for rx, limit in self.line_overrides:
            if rx.fullmatch(path):
                return limit
        return self.max_lines

    def is_allowed(self, name: str) -> bool:
        return any(rx.fullmatch(name) for rx in self.allow)


def _strings(value, where: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise ConfigError(f"{where}: expected a list of strings")
    return value


def _positive_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 1


def _object(value, where: str, allowed: tuple[str, ...]) -> dict:
    if not isinstance(value, dict):
        raise ConfigError(f"{where}: expected an object")
    for key in value:
        if key not in allowed and not key.startswith("_"):
            raise ConfigError(f"{where}: unknown key '{key}' (known: {', '.join(allowed)})")
    return value


_RULE_PARAMS = {
    "forbidden-call": ("calls", "hookTargets"),
    "combat-log": ("events",),
    "new-global": ("allow",),
    "file-length": ("maxLines", "overrides"),
    "test-shell-find": ("tests",),
    "unguarded-registration": ("guard",),
    "suppression-reason": (),
}


def parse_config(data) -> Config:
    """Validate a decoded config document. Unknown keys and wrong types are errors, so a typo does not silently
    turn a rule off."""
    top = _object(data, "config", ("include", "exclude", "disable", "rules"))
    cfg = Config(
        include=[glob_regex(g) for g in _strings(top.get("include", DEFAULT_INCLUDE), "include")],
        exclude=[glob_regex(g) for g in _strings(top.get("exclude", DEFAULT_EXCLUDE), "exclude")],
        disable=[],
        enabled={r: True for r in RULES},
    )
    disable = top.get("disable", {})
    if not isinstance(disable, dict):
        raise ConfigError("disable: expected an object mapping a glob to a list of rule ids")
    for glob, ids in disable.items():
        for r in _strings(ids, f"disable['{glob}']"):
            if r not in RULES:
                raise ConfigError(f"disable['{glob}']: unknown rule '{r}' (known: {', '.join(RULES)})")
        cfg.disable.append((glob_regex(glob), frozenset(ids)))

    rules = top.get("rules", {})
    if not isinstance(rules, dict):
        raise ConfigError("rules: expected an object")
    for r in rules:
        if r not in RULES:
            raise ConfigError(f"rules: unknown rule '{r}' (known: {', '.join(RULES)})")
    opts: dict[str, dict] = {}
    for rule in RULES:
        value = rules.get(rule, {})
        if isinstance(value, bool):
            cfg.enabled[rule] = value
            opts[rule] = {}
            continue
        opts[rule] = _object(value, f"rules.{rule}", ("enabled", *_RULE_PARAMS[rule]))
        enabled = opts[rule].get("enabled", True)
        if not isinstance(enabled, bool):
            raise ConfigError(f"rules.{rule}.enabled: expected true or false")
        cfg.enabled[rule] = enabled

    fc = opts["forbidden-call"]
    calls = fc.get("calls", DEFAULT_FORBIDDEN_CALLS)
    if isinstance(calls, dict):
        if not all(isinstance(k, str) and isinstance(v, str) for k, v in calls.items()):
            raise ConfigError("rules.forbidden-call.calls: expected a list of names or an object name -> reason")
        cfg.forbidden = {_norm_call(k): v for k, v in calls.items()}
    else:
        cfg.forbidden = {_norm_call(c): "" for c in _strings(calls, "rules.forbidden-call.calls")}
    targets = _strings(fc.get("hookTargets", DEFAULT_HOOK_TARGETS), "rules.forbidden-call.hookTargets")
    cfg.hook_targets = frozenset(targets)
    events = _strings(opts["combat-log"].get("events", DEFAULT_COMBAT_LOG_EVENTS), "rules.combat-log.events")
    cfg.events = frozenset(events)
    cfg.allow = [name_regex(p) for p in _strings(opts["new-global"].get("allow", []), "rules.new-global.allow")]
    fl = opts["file-length"]
    cfg.max_lines = fl.get("maxLines", DEFAULT_MAX_LINES)
    if not _positive_int(cfg.max_lines):
        raise ConfigError("rules.file-length.maxLines: expected a positive integer")
    overrides = fl.get("overrides", {})
    if not isinstance(overrides, dict) or not all(_positive_int(v) for v in overrides.values()):
        raise ConfigError("rules.file-length.overrides: expected an object mapping a glob to a positive integer")
    cfg.line_overrides = [(glob_regex(g), v) for g, v in overrides.items()]
    tests = _strings(opts["test-shell-find"].get("tests", DEFAULT_TEST_GLOBS), "rules.test-shell-find.tests")
    cfg.test_globs = [glob_regex(g) for g in tests]
    guard = opts["unguarded-registration"].get("guard", [])
    if isinstance(guard, str):
        guard = [guard]
    cfg.guards = frozenset(_norm_call(g) for g in _strings(guard, "rules.unguarded-registration.guard") if g)
    return cfg


def load_config(path: Path, required: bool) -> Config:
    """Read the config file. A missing file is an error when it was asked for (`required`), else the defaults."""
    if not path.is_file():
        if required:
            raise ConfigError(f"config file not found: {path}")
        return parse_config({})
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as e:
        raise ConfigError(f"{path}: cannot read config: {e}") from e
    try:
        return parse_config(data)
    except ConfigError as e:
        raise ConfigError(f"{path}: {e}") from e


# ---------------------------------------------------------------------------------------------------------------------
# Files


def list_files(root: Path) -> list[str]:
    """Repo-relative paths with '/': `git ls-files` (tracked and untracked-not-ignored) when `root` is in a git
    working tree, else a walk. Never shells out to find or dir."""
    try:
        r = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            timeout=120,
        )
        if r.returncode == 0:
            names = [p for p in r.stdout.decode("utf-8", errors="replace").split("\0") if p]
            return sorted({p for p in names if (root / p).is_file()})
    except (OSError, subprocess.SubprocessError):
        pass
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != ".git")
        base = Path(dirpath).relative_to(root).as_posix()
        found.extend(f if base == "." else f"{base}/{f}" for f in filenames)
    return sorted(found)


def select_files(root: Path, cfg: Config, paths: list[str]) -> list[str]:
    """The files to check: the listing filtered by the config's include and exclude globs, and by `paths` (files
    or folders, relative to the current folder or the root) when given."""
    wanted = []
    for p in paths:
        cand = Path(p)
        resolved = cand.resolve() if cand.is_absolute() or cand.exists() else (root / cand).resolve()
        if not resolved.exists():
            raise ConfigError(f"path not found: {p}")
        try:
            rel = resolved.relative_to(root.resolve()).as_posix()
        except ValueError:
            raise ConfigError(f"path is outside the root: {p}") from None
        wanted.append("" if rel == "." else rel)
    out = []
    for f in list_files(root):
        if wanted and not any(w == "" or f == w or f.startswith(w + "/") for w in wanted):
            continue
        if any(rx.fullmatch(f) for rx in cfg.include) and not any(rx.fullmatch(f) for rx in cfg.exclude):
            out.append(f)
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Rules


class Finding(NamedTuple):
    path: str
    line: int
    rule: str
    message: str


_SUPPRESS = re.compile(r"wowui-check:[ \t]*ignore[ \t]+([A-Za-z][A-Za-z0-9-]*)[ \t]*([^\n]*)")
_SHELL_FIND = re.compile(r"(?:^|[\s|&;(])(?:find|dir|ls)(?=$|\s)", re.IGNORECASE)
_SLASH_VAR = re.compile(r"SLASH_[A-Za-z0-9_]*\d")
_REGISTER_TARGETS = ("UISpecialFrames", "SlashCmdList")


def _first_arg(toks: list[Tok], open_idx: int) -> tuple[str, str] | None:
    """(kind, text) of a call's first argument: a string literal, or the first name of an expression (`_G.Name`
    counts as Name)."""
    t = toks[open_idx]
    if t.kind == "str":
        return "str", t.text
    if t.text == "(" and open_idx + 1 < len(toks):
        a = toks[open_idx + 1]
        if a.kind == "str":
            return "str", a.text
        if a.kind == "name":
            rest = toks[open_idx + 2 : open_idx + 4]
            if a.text == "_G" and len(rest) == 2 and _is_op(rest[0], ".") and rest[1].kind == "name":
                return "name", rest[1].text
            return "name", a.text
    return None


def _call_strings(toks: list[Tok], open_idx: int) -> list[str]:
    """Every string literal inside a call's parentheses (or the one string argument)."""
    t = toks[open_idx]
    if t.kind == "str":
        return [t.text]
    if t.text != "(":
        return []
    depth, out = 0, []
    for u in toks[open_idx:]:
        if _is_op(u, *_OPEN):
            depth += 1
        elif _is_op(u, *_CLOSE):
            depth -= 1
            if depth == 0:
                break
        elif u.kind == "str":
            out.append(u.text)
    return out


def _unguarded(what: str, cfg: Config) -> str:
    return f"{what} is not guarded by {' / '.join(sorted(cfg.guards))}"


def check_source(path: str, text: str, cfg: Config) -> tuple[list[Finding], int]:
    """All findings for one file (after suppressions) and how many findings the suppression comments removed."""
    toks, comments = tokenize(text)
    suppress: dict[int, list[tuple[str, str]]] = {}
    for line, body in comments:
        m = _SUPPRESS.search(body)
        if m:
            suppress.setdefault(line, []).append((m.group(1), m.group(2).strip()))

    raw: list[Finding] = []

    def add(line: int, rule: str, message: str) -> None:
        raw.append(Finding(path, line, rule, message))

    active = {r: cfg.active(r, path) for r in RULES}

    if active["file-length"]:
        count = len(text.splitlines())
        limit = cfg.lines_limit(path)
        if count > limit:
            add(1, "file-length", f"{count} lines, over the limit of {limit}")

    is_test = active["test-shell-find"] and any(rx.fullmatch(path) for rx in cfg.test_globs)
    guards = cfg.guards if active["unguarded-registration"] else frozenset()
    if active["forbidden-call"] or active["combat-log"] or active["new-global"] or is_test or guards:
        facts = analyze(toks, guards)
        for c in facts.calls:
            norm = c.chain.removeprefix("_G.")
            last = norm.rsplit(".", 1)[-1]
            if active["forbidden-call"] and not c.root_local:
                if norm in cfg.forbidden:
                    extra = cfg.forbidden[norm]
                    add(
                        c.line,
                        "forbidden-call",
                        f"call to forbidden function '{norm}'" + (f": {extra}" if extra else ""),
                    )
                elif norm == "hooksecurefunc":
                    arg = _first_arg(toks, c.open_idx)
                    if arg and arg[1] in cfg.hook_targets:
                        add(c.line, "forbidden-call", f"hooksecurefunc on Blizzard frame or function '{arg[1]}'")
                elif last == "HookScript" and "." in norm and norm.split(".", 1)[0] in cfg.hook_targets:
                    add(c.line, "forbidden-call", f"HookScript on Blizzard frame '{norm.split('.', 1)[0]}'")
            if active["combat-log"] and last == "RegisterEvent":
                arg = _first_arg(toks, c.open_idx)
                if arg and arg[0] == "str" and arg[1] in cfg.events:
                    add(c.line, "combat-log", f"registers {arg[1]}")
            if is_test and norm in ("io.popen", "os.execute"):
                if _SHELL_FIND.search(" ".join(_call_strings(toks, c.open_idx))):
                    add(
                        c.line,
                        "test-shell-find",
                        f"test shells out with {norm} to find/dir/ls; on Windows `find` is find.exe, a text search, "
                        "so the test passes vacuously; list files with `git ls-files`",
                    )
            if guards and not c.guarded and not c.root_local and norm in ("tinsert", "table.insert"):
                arg = _first_arg(toks, c.open_idx)
                if arg and arg[0] == "name" and arg[1] == "UISpecialFrames":
                    add(c.line, "unguarded-registration", _unguarded("UISpecialFrames registration", cfg))
        for a in facts.assigns:
            if active["new-global"] and a.kind != "index" and not cfg.is_allowed(a.name):
                what = {
                    "global": f"assignment to undeclared global '{a.name}'",
                    "func": f"global function '{a.name}'",
                    "member-func": f"function defined on global '{a.name}'",
                }[a.kind]
                add(a.line, "new-global", f"{what} (not local, not in the allowlist)")
            if guards and not a.guarded:
                if a.kind == "global" and _SLASH_VAR.fullmatch(a.name):
                    add(a.line, "unguarded-registration", _unguarded(f"slash command variable {a.name}", cfg))
                elif a.kind == "index" and a.name in _REGISTER_TARGETS:
                    add(a.line, "unguarded-registration", _unguarded(f"{a.name} registration", cfg))

    # Suppressions: on the same line or the line above. One without a reason is a finding of its own.
    kept, suppressed = [], 0
    for f in raw:
        if any(rule == f.rule for ln in (f.line, f.line - 1) for rule, _ in suppress.get(ln, ())):
            suppressed += 1
        else:
            kept.append(f)
    if active["suppression-reason"]:
        for line, entries in sorted(suppress.items()):
            for rule, reason in entries:
                if not reason:
                    msg = f"suppression of '{rule}' has no reason; say why after the rule id"
                    kept.append(Finding(path, line, "suppression-reason", msg))
    return kept, suppressed


# ---------------------------------------------------------------------------------------------------------------------
# Command line


def check_tree(root: Path, cfg: Config, paths: list[str]) -> tuple[list[Finding], int, int]:
    """Check the selected files under `root`: (sorted findings, files checked, findings suppressed)."""
    files = select_files(root, cfg, paths)
    findings: set[Finding] = set()
    suppressed = 0
    for f in files:
        text = (root / f).read_bytes().decode("utf-8", errors="replace").removeprefix("﻿")
        got, hidden = check_source(f, text, cfg)
        findings.update(got)
        suppressed += hidden
    return sorted(findings), len(files), suppressed


def add_arguments(p: argparse.ArgumentParser) -> None:
    p.add_argument("paths", nargs="*", help="files or folders to check (default: everything the config includes)")
    p.add_argument("--root", default=".", help="the addon's folder (default: the current folder)")
    p.add_argument(
        "--config", help=f"config file (default: {DEFAULT_CONFIG} in the root; built-in defaults without it)"
    )
    p.add_argument("--format", choices=["text", "json"], default="text")


def run(args: argparse.Namespace) -> int:
    try:
        root = Path(args.root).resolve()
        if not root.is_dir():
            raise ConfigError(f"root is not a folder: {args.root}")
        cfg = load_config(Path(args.config) if args.config else root / DEFAULT_CONFIG, required=bool(args.config))
        findings, checked, suppressed = check_tree(root, cfg, args.paths)
    except ConfigError as e:
        print(f"wowui check: error: {e}", file=sys.stderr)
        return 2
    if args.format == "json":
        doc = {
            "findings": [f._asdict() for f in findings],
            "summary": {"files": checked, "findings": len(findings), "suppressed": suppressed},
        }
        print(json.dumps(doc, indent=2))
    else:
        for f in findings:
            print(f"{f.path}:{f.line}: {f.rule}: {f.message}")
        note = f", {suppressed} suppressed" if suppressed else ""
        if findings:
            print(f"{len(findings)} finding(s) in {checked} file(s) checked{note}")
        else:
            print(f"ok: {checked} file(s) checked{note}")
    return 1 if findings else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="check.py", description=__doc__.split("\n")[0])
    add_arguments(ap)
    return run(ap.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
