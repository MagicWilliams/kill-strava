"""The plain-voice gate added with #267.

A lint nobody can see the edges of is a lint people work around. These pin the two edges
that matter: what counts as prose (a comment, a doc, not a string literal) and what the
allowlist can excuse. The string-literal boundary is the load-bearing one. Several
fixtures have to keep an em dash to stay compatible with builds already installed, and a
scanner that reached into strings would demand they be "fixed".

Run: python3 -m unittest discover -s .github/scripts -v
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest

import check_plain_voice as pv

EM = "\u2014"
BAR = "\u2015"
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "check_plain_voice.py")


def found(path: str, text: str) -> list[str]:
    return pv.problems(path, text)


class Swift(unittest.TestCase):
    def test_a_dash_in_a_line_comment_fails(self):
        p = found("a.swift", f"// one thing {EM} another\nlet x = 1\n")
        self.assertEqual(len(p), 1)
        self.assertIn("a.swift:1", p[0])

    def test_a_dash_in_a_doc_comment_fails(self):
        self.assertTrue(found("a.swift", f"/// one thing {EM} another\n"))

    def test_a_dash_in_a_block_comment_fails_on_its_own_line(self):
        p = found("a.swift", f"/*\n  fine\n  one thing {EM} another\n*/\n")
        self.assertEqual(len(p), 1)
        self.assertIn("a.swift:3", p[0])

    def test_a_dash_in_a_string_literal_passes(self):
        # `coach/history_test.ts` pins the turn an older build still sends. The guard must
        # not ask for that fixture to be rewritten.
        self.assertEqual(found("a.swift", f'let s = "Confirmed {EM} go"\n'), [])

    def test_a_slash_slash_inside_a_string_is_not_a_comment(self):
        self.assertEqual(found("a.swift", f'let s = "http://x {EM} y"\n'), [])

    def test_a_dash_in_a_multiline_string_passes(self):
        text = 'let s = """\n  Confirmed ' + EM + ' go\n  """\n'
        self.assertEqual(found("a.swift", text), [])

    def test_a_dash_in_a_raw_string_passes(self):
        self.assertEqual(found("a.swift", f'let s = #"Confirmed {EM} go"#\n'), [])

    def test_a_trailing_comment_after_code_still_fails(self):
        p = found("a.swift", f'let x = 1   // set once {EM} never again\n')
        self.assertEqual(len(p), 1)

    def test_the_horizontal_bar_fails_too(self):
        # A model told not to write an em dash reaches for the next mark along.
        self.assertTrue(found("a.swift", f"// one thing {BAR} another\n"))

    def test_clean_source_passes(self):
        self.assertEqual(found("a.swift", "/// One thing. Then another.\nlet x = 1\n"), [])


class TypeScript(unittest.TestCase):
    def test_a_dash_in_a_comment_fails(self):
        self.assertTrue(found("a.ts", f"// one thing {EM} another\n"))

    def test_a_dash_in_a_template_literal_passes(self):
        # The plan function's session text is #265's, not this gate's.
        self.assertEqual(found("a.ts", "const s = `8 mi " + EM + " goal pace`;\n"), [])

    def test_a_dash_in_a_single_quoted_string_passes(self):
        self.assertEqual(found("a.ts", f"const s = 'a {EM} b';\n"), [])


class Markdown(unittest.TestCase):
    def test_a_dash_in_prose_fails(self):
        self.assertTrue(found("a.md", f"One thing {EM} another.\n"))

    def test_a_dash_in_a_fenced_block_passes(self):
        # Quoted source in the docs is the thing being quoted, not our prose.
        self.assertEqual(found("a.md", f"text\n\n```\nlet x = 1 // a {EM} b\n```\n"), [])

    def test_a_dash_in_an_inline_code_span_passes(self):
        self.assertEqual(found("a.md", f"The placeholder is `{EM}:{EM}:{EM}` today.\n"), [])

    def test_a_dash_in_an_indented_code_block_passes(self):
        self.assertEqual(found("a.md", f"text\n\n    let x = 1 // a {EM} b\n"), [])

    def test_a_dash_in_a_table_cell_fails(self):
        self.assertTrue(found("a.md", f"| Platform | iOS {EM} SwiftUI |\n"))


class Python(unittest.TestCase):
    def test_a_dash_in_a_hash_comment_fails(self):
        self.assertTrue(found("a.py", f"# one thing {EM} another\n"))

    def test_a_dash_in_a_docstring_fails(self):
        p = found("a.py", f'"""One thing {EM} another."""\n')
        self.assertEqual(len(p), 1)

    def test_a_hash_inside_a_string_is_not_a_comment(self):
        self.assertEqual(found("a.py", f'S = "# not a comment {EM} really"\n'), [])

    def test_a_file_that_does_not_parse_still_gets_its_comments_read(self):
        self.assertTrue(found("a.py", f"# a {EM} b\ndef (\n"))


class Yaml(unittest.TestCase):
    def test_a_dash_in_a_comment_fails(self):
        self.assertTrue(found("a.yml", f"# build the thing {EM} then test it\nkey: value\n"))

    def test_a_dash_in_a_value_passes(self):
        # Workflow step output is copy, not a comment.
        self.assertEqual(found("a.yml", f'run: echo "done {EM} see TestFlight"\n'), [])


class BannedWords(unittest.TestCase):
    def test_a_banned_phrase_in_a_comment_fails(self):
        p = found("a.swift", "// Worth noting that the row is already ours.\n")
        self.assertEqual(len(p), 1)
        self.assertIn("worth noting", p[0])

    def test_the_match_is_case_insensitive(self):
        self.assertTrue(found("a.md", "It is CRUCIAL that this holds.\n"))

    def test_a_banned_word_in_a_string_literal_passes(self):
        self.assertEqual(found("a.swift", 'let s = "a long journey"\n'), [])

    def test_a_term_of_art_is_not_banned(self):
        # Each of these is load-bearing somewhere: GPSSignalWatcher, Tokens.Palette.elevated,
        # LiveRunDisplay.holdToUnlockS, "a genuinely new run".
        clean = ("/// The GPS signal, the elevated fill, the hold to unlock, and a genuinely\n"
                 "/// new run that navigates back. Noise is noise.\n")
        self.assertEqual(found("a.swift", clean), [])


class Allowlist(unittest.TestCase):
    def test_an_allowed_file_may_carry_the_mark_it_names(self):
        self.assertEqual(found("supabase/functions/_shared/plain_text.ts", f"// the {EM} mark\n"), [])

    def test_the_allowlist_is_per_file(self):
        self.assertTrue(found("supabase/functions/_shared/usage_gate.ts", f"// the {EM} mark\n"))

    def test_the_rulebook_may_name_the_words_but_not_write_the_dash(self):
        self.assertEqual(found("CLAUDE.md", "Do not write: delve, nuance, crucial.\n"), [])
        self.assertTrue(found("CLAUDE.md", f"One thing {EM} another.\n"))

    def test_every_allowlisted_path_still_exists(self):
        # An allowlist entry for a file that moved is an exemption nobody can see again.
        repo = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=HERE,
                              capture_output=True, text=True).stdout.strip()
        for path in pv.ALLOWED:
            self.assertTrue(os.path.exists(os.path.join(repo, path)),
                            f"ALLOWED names a file that is not there: {path}")


class Scope(unittest.TestCase):
    def test_the_record_is_not_scanned(self):
        for path in ("progress.md", "supabase/migrations/0001_init.sql",
                     "supabase/ops/carry_over_athlete.sql", "site/index.html"):
            self.assertFalse(pv.is_scanned(path), path)

    def test_source_and_docs_are_scanned(self):
        for path in ("ios/Tempo/Engine/LoadModel.swift", "supabase/functions/coach/index.ts",
                     "CLAUDE.md", "docs/ARCHITECTURE.md", ".claude/agents/builder.md",
                     ".github/workflows/ci.yml", ".github/scripts/check_plain_voice.py"):
            self.assertTrue(pv.is_scanned(path), path)


class EndToEnd(unittest.TestCase):
    """Runs the script the way CI runs it, so the exit code and the reporting are proved
    and not just the comparison. The issue asks for exactly this: confirm the check fails
    on a deliberately added em dash before relying on it."""

    def run_on(self, text: str, suffix: str = ".swift"):
        with tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False) as handle:
            handle.write(text)
            name = handle.name
        try:
            return subprocess.run([sys.executable, SCRIPT, name],
                                  capture_output=True, text=True)
        finally:
            os.unlink(name)

    def test_a_deliberate_em_dash_exits_nonzero_and_names_the_line(self):
        done = self.run_on(f"let x = 1\n// deliberately wrong {EM} here\n")
        self.assertEqual(done.returncode, 1)
        self.assertIn(":2:", done.stderr)
        self.assertIn("em dash", done.stderr)

    def test_clean_input_exits_zero(self):
        done = self.run_on("let x = 1\n// deliberately fine. Here.\n")
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_whole_tree_scan_that_finds_too_little_fails(self):
        # The #172 scar: a scan that stops finding files still reports success.
        done = subprocess.run([sys.executable, SCRIPT], cwd=tempfile.gettempdir(),
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 1)


if __name__ == "__main__":
    unittest.main()
