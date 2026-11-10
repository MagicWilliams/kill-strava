#!/usr/bin/env python3
"""Fail CI when tracked source reintroduces an em dash or stock AI phrasing.

The 2026-11-04 decision was "no em dashes anywhere David reads, and no stock AI phrasing"
(docs/decision-log.md). #264 enforced it on coach output and #266 on app copy, but the
~1,230 code comments that still carried the habit were the reason it kept coming back:
agents match surrounding style, so every comment with an em dash in it taught the next one
to write another. Prompt rules and review both failed at that. This is the gate instead.

    check_plain_voice.py            # scan the tracked tree
    check_plain_voice.py a.swift    # scan named files (used by the tests)

What is checked is COMMENT AND DOC PROSE, not string literals. That boundary is deliberate:

  * Comments and markdown are what agents read and copy, which is the whole mechanism above.
  * Several string literals must keep their em dash to stay compatible with builds already
    installed. `coach/history_test.ts` pins "Confirmed - <summary>" with the em dash the app
    wrote before #266, and a tester on an older build still sends exactly that. A guard that
    reached into strings would demand that fixture be "fixed" and quietly drop the
    regression it exists to hold.
  * Visible copy has its own gates: #266 for the app, #265 for the plan function, #264 for
    everything the coach writes.

So a new em dash in a string literal is still caught, by review and by those gates, not here.
"""

from __future__ import annotations

import ast
import subprocess
import sys

EM_DASH = "—"
HORIZONTAL_BAR = "―"
TRIPLE_QUOTE = '"' * 3

# Extensions holding comments or prose. A tracked file outside this set is not scanned.
SCANNED_SUFFIXES = (".swift", ".ts", ".md", ".yml", ".yaml", ".py")

# Left as written, and why. These are records of what was already done, not prose anyone is
# meant to copy, and rewriting them would falsify the record.
NOT_SCANNED = (
    "progress.md",              # dated narrative history
    "supabase/migrations/",     # applied in order against live data
    "supabase/ops/",            # scripts already run against production
    "site/",                    # published copy, with its own review (#250)
)

# Minimum number of files a full scan must reach. A scan that silently stops finding files
# still passes, which is the #172 scar: the unit lint missed Screens/Recorder/ for weeks
# because walking one level deep found nothing there and reported success.
MIN_FILES = 250

# Stock phrasing, from the coach's VOICE rules in supabase/functions/coach/prompts.ts. Only
# the entries that are never a term of art in this codebase are here; the rest of VOICE stays
# a prompt rule, for the reason the decision log gives: a word cannot be swapped inside a
# finished sentence mechanically.
#
# Deliberately NOT checked, because each is load-bearing somewhere in the source:
#   signal, noise      GPSSignalWatcher, "GPS signal", a stop that "reads as noise on screen"
#   elevate            Tokens.Palette.elevated, the raised-surface colour
#   navigate           SwiftUI navigation, "when the athlete navigates back"
#   unlock             LiveRunDisplay.holdToUnlockS, the lock-screen hold
#   rhythm, lands      plain English about a chart's shape and about code landing on main
#   honest, honestly, genuinely, truly
#                      precise here, not a candor announcement: "a genuinely new run",
#                      "reads honestly slow", "its before if one is honestly known". Thirty
#                      odd uses, all meaning what they say.
#   real, actual       banned only as intensifiers, which no regex can tell from "the real
#                      miles HealthKit returned"
BANNED_WORDS = (
    "worth noting",
    "worth flagging",
    "worth respecting",
    "aerobic engine",
    "delve",
    "nuance",
    "testament",
    "journey",
    "landscape",
    "leverage",
    "holistic",
    "crucial",
    "niggle",
    "frankly",
    "to be clear",
)

# Files that must contain a mark in order to name it. Path -> the marks allowed there. This
# is the whole allowlist: there is no inline escape, so adding one is a reviewable line in
# this file rather than a comment someone drops on a line they did not want to rewrite.
ALLOWED: dict[str, tuple[str, ...]] = {
    # This scanner and its tests have to spell out what they reject.
    ".github/scripts/check_plain_voice.py": (EM_DASH, HORIZONTAL_BAR) + BANNED_WORDS,
    ".github/scripts/test_check_plain_voice.py": (EM_DASH, HORIZONTAL_BAR) + BANNED_WORDS,
    # The dash scrubber on coach output (#264). Its comments quote the mark it removes and
    # the stand-ins a model reaches for when told not to write one.
    "supabase/functions/_shared/plain_text.ts": (EM_DASH,),
    "supabase/functions/_shared/plain_text_test.ts": (EM_DASH,),
    # The rulebook states the rule, so it names the words. Not the dash: it says "em dash".
    "CLAUDE.md": BANNED_WORDS,
    # A dated record of what the coach prompt used to teach the model, quoted as evidence.
    "docs/decision-log.md": ("niggle",),
}


def is_scanned(path: str) -> bool:
    return path.endswith(SCANNED_SUFFIXES) and not path.startswith(NOT_SCANNED)


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], capture_output=True, text=True, check=True
    ).stdout
    return sorted(p for p in out.split("\0") if p and is_scanned(p))


def _strip_c_like(text: str) -> list[tuple[int, str]]:
    """The comments in a Swift or TypeScript file, as (1-based line number, text).

    A real scanner rather than a regex per line, because a slash-slash inside a string
    literal is not a comment, and an em dash inside one is data this check does not touch.
    Handles Swift multi-line and raw strings, TypeScript backticks and single quotes, and the
    nested block comments Swift allows.
    """
    out: list[tuple[int, str]] = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append((_line_at(text, i), text[i + 2:end]))
            i = end
            continue
        if text.startswith("/*", i):
            start_line = _line_at(text, i)
            depth, body_start = 1, i + 2
            i += 2
            while i < n and depth:
                if text.startswith("/*", i):
                    depth += 1
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            body = text[body_start:i - 2 if depth == 0 else n]
            for offset, body_line in enumerate(body.split("\n")):
                out.append((start_line + offset, body_line))
            continue
        hashes = _swift_raw_delim(text, i)
        if hashes:
            i = _skip_raw_string(text, i, hashes)
            continue
        if text.startswith(TRIPLE_QUOTE, i):
            i = _skip_to(text, i + len(TRIPLE_QUOTE), TRIPLE_QUOTE)
            continue
        if text[i] in "\"'`":
            i = _skip_quoted(text, i, text[i])
            continue
        i += 1
    return out


def _line_at(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def _swift_raw_delim(text: str, i: int) -> int:
    """How many `#` open a Swift raw string here, or 0 when this is not one."""
    hashes = 0
    while i + hashes < len(text) and text[i + hashes] == "#":
        hashes += 1
    return hashes if hashes and text.startswith('"', i + hashes) else 0


def _skip_raw_string(text: str, i: int, hashes: int) -> int:
    close = '"' + "#" * hashes
    end = text.find(close, i + hashes + 1)
    return len(text) if end < 0 else end + len(close)


def _skip_to(text: str, i: int, close: str) -> int:
    end = text.find(close, i)
    return len(text) if end < 0 else end + len(close)


def _skip_quoted(text: str, i: int, quote: str) -> int:
    i += 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == quote:
            return i + 1
        # An unescaped newline ends a Swift or TypeScript single-line string. Stopping here
        # keeps one unbalanced quote from swallowing the rest of the file.
        if text[i] == "\n" and quote != "`":
            return i
        i += 1
    return len(text)


def _python_prose(text: str) -> list[tuple[int, str]]:
    """A Python file's `#` comments plus its docstrings.

    Docstrings are read with `ast` rather than by scanning for quotes: the alternative is a
    second string scanner, and the one in `_strip_c_like` is already the fiddliest part of
    this file. A file that does not parse contributes its comments only.
    """
    out = _strip_hash_comments(text)
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return out
    for node in ast.walk(tree):
        if not isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        doc = ast.get_docstring(node, clean=False)
        if doc is None:
            continue
        first = node.body[0].lineno          # the docstring expression
        for offset, line in enumerate(doc.split("\n")):
            out.append((first + offset, line))
    return sorted(out)


def _strip_hash_comments(text: str) -> list[tuple[int, str]]:
    """The `#` comments in a YAML or Python file. A `#` inside quotes is not one."""
    out: list[tuple[int, str]] = []
    for line_no, line in enumerate(text.split("\n"), 1):
        quote = ""
        for index, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = ""
            elif ch in "\"'":
                quote = ch
            elif ch == "#" and (index == 0 or line[index - 1] in " \t"):
                out.append((line_no, line[index + 1:]))
                break
    return out


def _markdown_prose(text: str) -> list[tuple[int, str]]:
    """Markdown prose, with code removed: fenced blocks, indented blocks and `code spans`.

    Code in the docs is quoted source, so holding it to the voice rules would ask for a
    rewrite of the thing being quoted.
    """
    out: list[tuple[int, str]] = []
    fence = ""
    for line_no, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if fence:
            if stripped.startswith(fence):
                fence = ""
            continue
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fence = stripped[:3]
            continue
        if line.startswith("    ") and not stripped.startswith(("-", "*", "|", "+")):
            continue
        out.append((line_no, _drop_code_spans(line)))
    return out


def _drop_code_spans(line: str) -> str:
    out, chunks = [], line.split("`")
    for index, chunk in enumerate(chunks):
        if index % 2 == 0:
            out.append(chunk)
    # An odd number of backticks means the span is unclosed on this line; keep the text so
    # a stray backtick cannot hide prose from the scan.
    return line if len(chunks) % 2 == 0 else "".join(out)


def prose(path: str, text: str) -> list[tuple[int, str]]:
    """The lines of `path` this check reads: comment bodies, or markdown outside code."""
    if path.endswith((".swift", ".ts")):
        return _strip_c_like(text)
    if path.endswith(".py"):
        return _python_prose(text)
    if path.endswith((".yml", ".yaml")):
        return _strip_hash_comments(text)
    if path.endswith(".md"):
        return _markdown_prose(text)
    return []


def problems(path: str, text: str) -> list[str]:
    allowed = ALLOWED.get(path, ())
    found = []
    for line_no, line in prose(path, text):
        lowered = line.lower()
        for mark, name in ((EM_DASH, "em dash"), (HORIZONTAL_BAR, "horizontal bar")):
            if mark in line and mark not in allowed:
                found.append(f"{path}:{line_no}: {name}: {line.strip()[:120]}")
        for word in BANNED_WORDS:
            if word in lowered and word not in allowed:
                found.append(f'{path}:{line_no}: "{word}": {line.strip()[:120]}')
    return found


def main(argv: list[str]) -> int:
    paths = argv[1:]
    whole_tree = not paths
    if whole_tree:
        paths = tracked_files()

    found: list[str] = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            found += problems(path, handle.read())

    if whole_tree and len(paths) < MIN_FILES:
        print(
            f"check_plain_voice: scanned only {len(paths)} files, expected at least "
            f"{MIN_FILES}. The scan is not reaching the tree (#172).",
            file=sys.stderr,
        )
        return 1

    if found:
        print(
            "Plain voice (#267). Use a period, a comma or a colon instead of an em dash, and\n"
            "say the plain thing instead of the listed phrases. A mark that has to stay goes\n"
            "in ALLOWED in .github/scripts/check_plain_voice.py.\n",
            file=sys.stderr,
        )
        print("\n".join(found), file=sys.stderr)
        print(f"\n{len(found)} problem(s) in {len(paths)} scanned files.", file=sys.stderr)
        return 1

    print(f"check_plain_voice: {len(paths)} files clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
