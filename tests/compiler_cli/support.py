"""Shared fixture and subprocess helpers for compiler CLI tests."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

FIXTURE_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = FIXTURE_DIR.parent

CASE_ROW = re.compile(r"tuple\(data:(\d+):([a-z0-9/-]+),bool:([01])\)")
CASE_ARRAY = rf"array\({CASE_ROW.pattern}(?:,{CASE_ROW.pattern})*\)"
CASE_REPORT = re.compile(rf"(?:{CASE_ARRAY}|tuple\({CASE_ARRAY}(?:,{CASE_ARRAY})*\))\n")


class CompilerTestCase(unittest.TestCase):
    compiler = (REPO_ROOT / "build/verona").resolve()
    reference_compiler = Path(os.environ.get("VERONA_REFERENCE", str(compiler))).resolve()

    @classmethod
    def configure(cls, compiler):
        cls.compiler = Path(compiler).resolve()
        cls.reference_compiler = Path(
            os.environ.get("VERONA_REFERENCE", str(cls.compiler))
        ).resolve()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="verona core tests ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.source = self.root / "input.vrn"

    def run_core(self, mode, source, *args, **kwargs):
        if isinstance(source, Path):
            path = source
        else:
            path = self.source
            path.write_bytes(source.encode() if isinstance(source, str) else source)
        return subprocess.run([str(self.compiler), mode, str(path), *map(str, args)],
                              capture_output=True, text=True, timeout=30, **kwargs)

    def program(self, expression):
        return f"(%function main () i64 {expression})"

    def agrees(self, source, expected, *options):
        with self.subTest(mode="eval"):
            evaluated = self.run_core("eval", source, *options)
            self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
            self.assertEqual(evaluated.stdout, f"{expected}\n")
        for level in ("-O0", "-O2"):
            with self.subTest(mode=level):
                native = self.run_native_report(source, level, *options)
                self.assertEqual(native.returncode, 0, native.stderr)
                self.assertEqual(native.stdout, f"i64:{expected}\n")
                self.assertEqual(native.stderr, "")

    def run_native_report(self, source, level, *options):
        binary = self.root / "native executable"
        compiled = self.run_core("compile-report", source, "-o", binary, level, *options)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)

    def named_cases(self, program, expected_count):
        source = FIXTURE_DIR / "programs" / program
        case_names = None
        for mode in ("eval", "-O0", "-O2"):
            with self.subTest(mode=mode):
                result = (self.run_core("eval", source) if mode == "eval"
                          else self.run_native_report(source, mode))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                rows = CASE_ROW.findall(result.stdout)
                self.assertIsNotNone(CASE_REPORT.fullmatch(result.stdout), result.stdout)
                names = [name for _, name, _ in rows]
                self.assertEqual(len(names), expected_count)
                self.assertEqual(len(set(names)), len(names), names)
                if case_names is None:
                    case_names = names
                else:
                    self.assertCountEqual(names, case_names)
                for length, name, passed in rows:
                    with self.subTest(case=name):
                        self.assertEqual(int(length), len(name))
                        self.assertEqual(passed, "1")
