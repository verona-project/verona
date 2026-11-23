"""Compiler command-line options, entry points, and usage errors."""

import os
import shlex
import subprocess
import sys

from .support import CompilerTestCase, FIXTURE_DIR


class CliTests(CompilerTestCase):
    def test_cli_version_and_output_alias(self):
        host = self.reference_compiler
        reference = subprocess.run([str(host), "--version"], capture_output=True, text=True, timeout=10)
        self.assertEqual(reference.returncode, 0, reference.stderr)
        for flag in ("--version", "-V"):
            result = subprocess.run([str(self.compiler), flag], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, reference.stdout)
            self.assertEqual(result.stderr, "")
            invalid = subprocess.run([str(self.compiler), flag, "extra"], capture_output=True, text=True, timeout=10)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
        binary = self.root / "output alias"
        result = self.run_core("compile-report", self.program("42"), "--output", binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(native.returncode, 0, native.stderr)
        self.assertEqual(native.stdout, "i64:42\n")

    def test_cli_help_and_flexible_option_placement(self):
        for flag in ("--help", "-h", "help"):
            top = subprocess.run([str(self.compiler), flag], capture_output=True, text=True, timeout=10)
            self.assertEqual(top.returncode, 0, top.stderr)
            self.assertIn("compile FILE", top.stdout)
            self.assertEqual(top.stderr, "")
        for command in ("read", "check", "eval", "emit-llvm", "optimization-report",
                        "compile", "compile-report", "build"):
            for flag in ("--help", "-h", "help"):
                help_result = subprocess.run([str(self.compiler), command, flag],
                                             capture_output=True, text=True, timeout=10)
                self.assertEqual(help_result.returncode, 0, help_result.stderr)
                self.assertIn("usage: verona " + command, help_result.stdout)
                self.assertEqual(help_result.stderr, "")

        self.source.write_text(self.program("42"))
        before = subprocess.run(
            [str(self.compiler), "check", "--target", "native", str(self.source)],
            capture_output=True, text=True, timeout=10)
        after = subprocess.run(
            [str(self.compiler), "check", str(self.source), "--target", "native"],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(before.returncode, 0, before.stderr)
        self.assertEqual(after.returncode, 0, after.stderr)
        malformed = subprocess.run(
            [str(self.compiler), "check", "--target=native", str(self.source)],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(malformed.returncode, 2, malformed.stderr)

        # Output is a single, nonempty value.  An empty value must not be
        # mistaken for the default-output sentinel or bypass duplicate checks.
        for arguments in (("--output", ""), ("-o", "", "-o", "second"),
                          ("-o", "first", "--output", "second")):
            invalid = self.run_core("compile", self.program("42"), *arguments)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
            self.assertIn("usage:", invalid.stderr)

        # Compilation-only options and compile-report artifact conflicts are
        # diagnosed by the parser, before a source is processed.
        for command, arguments in (("check", ("-O2",)),
                                   ("check", ("--output", "out")),
                                   ("compile-report", ("--emit", "object"))):
            invalid = self.run_core(command, self.program("42"), *arguments)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
            self.assertIn("usage:", invalid.stderr)

    def test_cli_cpu_features_and_default_outputs(self):
        source = """
(%macro selected-cpu ()
  (cond ((equal? (plist-ref (compiler:target-info) ':cpu) "x86-64") 42)
        (true 0)))
(%function main () i64 (selected-cpu))
"""
        foreign = self.run_core(
            "compile", source, "--emit", "object",
            "--target", "x86_64-unknown-linux-gnu",
            "--cpu", "x86-64", "--features", "+sse2")
        self.assertEqual(foreign.returncode, 0, foreign.stderr)
        default_object = self.root / "input.o"
        self.assertTrue(default_object.exists())
        self.assertEqual(default_object.read_bytes()[:4], b"\x7fELF")

        # An explicitly empty feature string is LLVM's default configuration;
        # a missing value and an empty CPU are malformed CLI invocations.
        empty_features = self.run_core(
            "compile", source, "--emit", "object", "--features", "")
        self.assertEqual(empty_features.returncode, 0, empty_features.stderr)
        for arguments in (("--cpu",), ("--cpu", ""), ("--features",)):
            invalid = self.run_core("compile", source, *arguments)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
            self.assertIn("usage:", invalid.stderr)

        default_object.unlink()
        native_source = self.program("42")
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        for kind, name in (
            ("executable", "input"),
            ("object", "input.o"),
            ("static-library", "libinput.a"),
            ("shared-library", "libinput" + suffix),
        ):
            with self.subTest(kind=kind):
                result = self.run_core("compile", native_source, "--emit", kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                artifact = self.root / name
                self.assertTrue(artifact.exists(), artifact)
                artifact.unlink()
                if "library" in kind:
                    header = self.root / "libinput.h"
                    self.assertTrue(header.exists(), header)
                    header.unlink()

    def test_command_line_entry_points(self):
        source = """
(%type Int i32)
(%type Data (pointer u8))
(%type Arguments (pointer Data))
(%function main ((count Int) (values Arguments)) exit-code count)
"""
        checked = self.run_core("check", source)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 2, evaluated.stderr)
        self.assertIn("eval requires a parameterless main", evaluated.stderr)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"define i32 @main\(i32 [^,]+, ptr ")
        for level in ("-O0", "-O2"):
            binary = self.root / "argument executable"
            compiled = self.run_core("compile", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            for arguments in ([], ["space value", "", "omega"]):
                native = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, len(arguments) + 1, native.stderr)
            reported = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(reported.returncode, 0, reported.stderr)
            native = subprocess.run([str(binary), "one", "two"], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, "i32:3\n")
            negative = source.replace("exit-code count)", "exit-code -1)")
            compiled = self.run_core("compile", negative, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 255, native.stderr)

    def test_command_line_argument_vector_forwarding(self):
        fixture = (FIXTURE_DIR / "external.c")
        obj = self.root / "argument fixture.o"
        built = subprocess.run(["clang", "-std=c11", "-O2", "-c", str(fixture), "-o", str(obj)],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        linker = self.root / "argument linker"
        linker.write_text(f"#!/bin/sh\nexec clang \"$@\" {shlex.quote(str(obj))}\n")
        linker.chmod(0o755)
        environment = dict(os.environ, VERONA_CORE_CLANG=str(linker))
        source = """
(%external-function verify "fixture_arguments" (i32 (pointer (pointer u8))) i32)
(%function main ((argc i32) (argv (pointer (pointer u8)))) exit-code
  (verify argc argv))
"""
        for level in ("-O0", "-O2"):
            binary = self.root / "argument vector executable"
            compiled = self.run_core("compile", source, "-o", binary, level, env=environment)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary), "space value", "", "omega"],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 42, native.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 1, native.stderr)

    def test_invalid_command_line_entry_signatures(self):
        for source, message in (
            ("(%function main ((argc i32)) i32 argc)", "main must have no parameters"),
            ("(%function main ((argc u32) (argv (pointer (pointer u8)))) i32 0)", "main must have no parameters"),
            ("(%function main ((argc i32) (argv (pointer u8))) i32 0)", "main must have no parameters"),
            ("(%function main ((argc i32) (argv (pointer (pointer i8)))) i32 0)", "main must have no parameters"),
            ("(%function main ((argc i32) (argv (pointer (pointer u8))) (extra i32)) i32 0)", "main must have no parameters"),
            ("(%function main ((argc i32) (argv (pointer (pointer u8)))) i64 0)", "command-line main must return exit-code"),
            ("(%function main ((argc i32) (argv (pointer (pointer u8)))) u32 0)", "command-line main must return exit-code"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_cli_and_limits(self):
        for args in ([], ["unknown"], ["eval"], ["compile", "x", "-bad", "y"],
                     ["eval", "x", "--module-path"], ["eval", "x", "--module-path", ""],
                     ["eval", "x", "-o", "y"]):
            result = subprocess.run([str(self.compiler), *args], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)
        result = self.run_core("check", " " * 65537)
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing main function", result.stderr)
        result = self.run_core("check", "(" * 258)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unclosed list", result.stderr)
        result = subprocess.run([str(self.compiler), "eval", str(self.root / "missing")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("module not found", result.stderr)
        environment = dict(os.environ, VERONA_CORE_CLANG="/nonexistent/compiler")
        result = self.run_core("compile", self.program("0"), "-o", self.root / "out", env=environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("native compilation failed", result.stderr)
        self.assertFalse((self.root / "out").exists())
