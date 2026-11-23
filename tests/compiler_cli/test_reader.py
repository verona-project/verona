"""Source syntax, reader features, and parsing limits."""

import sys

from .support import CompilerTestCase


class ReaderTests(CompilerTestCase):
    def test_locations_and_comments(self):
        result = self.run_core("check", "; comment\r\n(%function main () i64\r\n  unknown)\r\n")
        self.assertIn("input.vrn:3:3: unknown local", result.stderr)
        self.agrees("; before\n(%function main () i64 ; inside\n (%+-primitive-i64 2 3)) ; after", 5)

    def test_native_platform_conditionals(self):
        source = """
#+darwin (%type Platform u16)
#+linux (%type Platform u32)
#-pointer_64 (%type Platform Missing)
#+unknown-feature (%function broken () Missing invalid)
(%function main () i64
  (%zext-primitive-PLATFORM-i64
    (match true
      (true #+darwin (cast Platform 42) #+linux (cast Platform 42))
      (false (cast Platform 0)))))
""".replace("PLATFORM", "u16" if sys.platform == "darwin" else "u32")
        self.agrees(source, 42)
        for text, message in (
            ("#+ (example)", "expected a feature name"),
            ("#+unknown-feature", "requires an operand"),
            ("#+unknown-feature (example", "unclosed list"),
            ("'#+unknown-feature example", "requires a selected operand"),
        ):
            with self.subTest(text=text):
                result = self.run_core("read", text)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_large_files_and_syntax_tapes(self):
        # Each dependency exceeds the former file byte and node limits.
        # Together they exceed the former combined session node limit.
        body = "(%macro unused () '((" + "0 " * 4096 + ")(" + "0 " * 4096 + ")))"
        for index in range(8):
            (self.root / f"large{index}.vrn").write_text(" " * 70000 + body)
        imports = "".join(f"(import large{i})" for i in range(8))
        evaluated = self.run_core("eval", imports + " " * 150000 + self.program("42"))
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, "42\n")
        read = self.run_core("read", " " * 150000 + "(example)")
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertIn("spelling=example", read.stdout)

    def test_resource_boundaries(self):
        for source in (" " * 65000 + self.program("7"),
                       ";" + "x" * 65000 + "\n" + self.program("7"),
                       "(%function " + "x" * 60000 + " () i64 0)" + self.program("7"),
                       self.program("(%+-primitive-i64 " + "0" * 60000 + " 7)")):
            result = self.run_core("eval", source)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "7\n")
        result = self.run_core("eval", "(%function loop () i64 (loop))" + self.program("(loop)"))
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("call depth limit", result.stderr)
        for source, message in (
            ("(%function main () i64 (f " + "0 " * 4096 + "))", "form count limit"),
            ("(%function f (" + " ".join(f"(x{i} i64)" for i in range(65)) + ") i64 0)" + self.program("0"),
             "parameter limit"),
        ):
            result = self.run_core("check", source)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(message, result.stderr)

    def test_reader(self):
        result = self.run_core("read", "(a (a -12) ()) true 9223372036854775808")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("roots=[ 5 6 7 ]", result.stdout)
        self.assertIn("2 integer file=1 bytes=6..9 name=0 at=1:7 spelling=-12", result.stdout)
        self.assertIn("children=[ 0 3 4 ]", result.stdout)
        for source in ("", " ; trailing comment", "- + -x +x true false unit",
                       "-9223372036854775809 +9223372036854775808", "; quote ' and backslash \\ allowed\n()"):
            result = self.run_core("read", source)
            self.assertEqual(result.returncode, 0, result.stderr)
        # Both dimensions exceed the old reader's recursive resource limits.
        for source in ("(" * 12000 + "x" + ")" * 12000, "a " * 12000):
            result = self.run_core("read", source)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("identifier", result.stdout)
        for source, location in ((")", ":1:1:"), ("\r\n  (", ":2:3:"),
                                 ("\r x\n)", ":3:1:"), ("1x", ":1:1:"),
                                 ("a\x00b", ":1:2:"), ("é", ":1:1:"),
                                 ("a\v", ":1:2:")):
            result = self.run_core("read", source)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(location, result.stderr)
        for source, message in (('"-', "unterminated data literal"),
                                ("'", "reader prefix requires an operand"),
                                (",@", "reader prefix requires an operand"),
                                ("(,)", "reader prefix requires an operand")):
            result = self.run_core("read", source)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(message, result.stderr)
            self.assertNotIn("only ASCII", result.stderr)
        result = self.run_core("check", self.program("(" * 300 + "x" + ")" * 300))
        self.assertEqual(result.returncode, 2)
        self.assertIn("nesting limit", result.stderr)
        self.agrees(self.program("+7"), 7)
