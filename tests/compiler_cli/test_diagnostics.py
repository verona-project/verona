"""Test the diagnostic stream and the public formatter ABI end to end."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .support import CompilerTestCase, FIXTURE_DIR


COMMANDS = (
    "read", "check", "eval", "emit-llvm", "optimization-report",
    "compile", "compile-report", "build",
)


class DiagnosticTests(CompilerTestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="verona diagnostic plugins ")
        cls.addClassCleanup(directory.cleanup)
        cls.plugins = {}
        suffix = ".dylib" if sys.platform == "darwin" else ".so"
        source = FIXTURE_DIR / "diagnostic-formatter.vrn"
        for name, options in (
            ("formatter", ()),
            ("missing entry", ("--feature", "missing_entry")),
            ("bad version", ("--feature", "bad_version")),
        ):
            output = Path(directory.name) / (name + suffix)
            result = subprocess.run(
                [cls.compiler, "compile", source, "--emit", "shared-library",
                 "-o", output, *options],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode:
                raise RuntimeError(f"Could not build {name}: {result.stderr}")
            cls.plugins[name] = output

    def invoke(self, *args, **kwargs):
        return subprocess.run(
            [self.compiler, *args], cwd=self.root, capture_output=True, text=True,
            timeout=30, **kwargs,
        )

    def assert_diagnostic_failure(self, result, code, status=2, plugin=True):
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertEqual(result.stdout, "")
        marker = f"D|error|{code}|" if plugin else f"error[{code}]:"
        self.assertIn(marker, result.stderr)

    def test_diagnostic_formatter_all_commands(self):
        self.source.write_text(")")
        (self.root / "verona.build").write_text("(executable demo (root input))")
        for command in COMMANDS:
            operands = ("demo", "out") if command == "build" else (self.source,)
            code = "unexpected-closing-parenthesis"
            with self.subTest(command=command):
                default = self.invoke(command, *operands)
                self.assert_diagnostic_failure(default, code, plugin=False)
                formatted = self.invoke(command, *operands, "--diagnostic-plugin",
                                        self.plugins["formatter"])
                self.assert_diagnostic_failure(formatted, code)
                self.assertEqual(formatted.stderr, (
                    f"D|error|{code}|{self.source}:1:1|0:1:1|unexpected closing parenthesis\n"
                ))
                self.assertFalse((self.root / "out" / "demo").exists())

        (self.root / "verona.build").write_text(")")
        manifest = self.invoke("build", "--diagnostic-plugin", self.plugins["formatter"],
                               "demo", "out")
        self.assert_diagnostic_failure(manifest, code)
        self.assertIn(f"|{self.root / 'verona.build'}:1:1|", manifest.stderr)

        self.source.write_text("(%function main () i32 0)")
        (self.root / "verona.build").write_text("(executable demo (root input))")
        for command in COMMANDS:
            operands = ("demo", "out") if command == "build" else (self.source,)
            with self.subTest(command=command):
                default = self.invoke(command, *operands)
                formatted = self.invoke(command, "--diagnostic-plugin",
                                        self.plugins["formatter"], *operands)
                self.assertEqual(default.returncode, 0, default.stderr)
                self.assertEqual(formatted.returncode, 0, formatted.stderr)
                self.assertEqual(formatted.stdout, default.stdout)

    def test_diagnostic_formatter_arguments_and_load_errors(self):
        plugin = self.plugins["formatter"]
        for operands, code in (
            (("not-a-command", "--broken"), "unknown-command"),
            (("check", "--target"), "invalid-command-option"),
            (("build", "--broken", "demo", "out"), "invalid-command-option"),
            ((), "missing-command"),
        ):
            with self.subTest(operands=operands):
                formatted = self.invoke(*operands, "--diagnostic-plugin", plugin)
                self.assert_diagnostic_failure(formatted, code)
                self.assertIn("D|note|command-usage|-|-|usage:", formatted.stderr)
                self.assertNotIn(f"error[{code}]", formatted.stderr)

        for flags in (
            ("--diagnostic-plugin", "--diagnostic-plugin", plugin),
            ("--diagnostic-plugin", plugin, "--diagnostic-plugin", "ignored"),
            ("--diagnostic-plugin", plugin, "--diagnostic-plugin", ""),
        ):
            formatted = self.invoke("check", *flags)
            self.assert_diagnostic_failure(formatted, "invalid-command-option")
        missing_path = self.invoke("check", "--diagnostic-plugin")
        self.assert_diagnostic_failure(missing_path, "invalid-command-option", plugin=False)

        for path, code in (
            (self.root / "nonexistent.so", "diagnostic-plugin-open-failed"),
            (self.plugins["missing entry"], "diagnostic-plugin-entry-missing"),
            (self.plugins["bad version"], "diagnostic-plugin-abi-mismatch"),
        ):
            with self.subTest(path=path):
                failure = self.invoke("read", "--invalid", "--diagnostic-plugin", path)
                self.assert_diagnostic_failure(failure, code, plugin=False)
                self.assertIn(str(path), failure.stderr)

        after_separator = self.invoke("read", "--", "--diagnostic-plugin")
        self.assert_diagnostic_failure(after_separator, "source-open-failed", plugin=False)

        local_plugin = self.root / plugin.name
        local_plugin.symlink_to(plugin)
        ok = self.invoke("--diagnostic-plugin", local_plugin.name, "eval", self.source)
        self.assert_diagnostic_failure(ok, "module-not-found")
        self.source.write_text(self.program("42"))
        ok = self.invoke("--diagnostic-plugin", local_plugin.name, "eval", self.source)
        self.assertEqual((ok.returncode, ok.stdout, ok.stderr), (0, "42\n", ""))

    def test_diagnostic_formatter_locations_and_notes(self):
        helper = self.root / "helper.vrn"
        helper_text = b"(export identity)\r\n(%function identity ((value i64)) i64 value)"
        helper.write_bytes(helper_text)
        main_text = b"(import helper :as h)\r\n(%function main () i64\r\n\t(h:identity true))"
        self.source.write_bytes(main_text)
        formatted = self.invoke("check", self.source, "--diagnostic-plugin", self.plugins["formatter"])
        self.assert_diagnostic_failure(formatted, "type-mismatch")
        start = main_text.index(b"true")
        origin = helper_text.index(b"i64")
        lines = formatted.stderr.splitlines()
        self.assertEqual(lines, [
            f"D|error|type-mismatch|{self.source}:3:14|{start}:{start + 4}:{len(main_text)}|"
            "type mismatch: expected i64, actual bool",
            f"R|note|expected-type-origin|{helper}:2:29|{origin}:{origin + 3}:{len(helper_text)}|"
            "expected type established here",
        ])

        default = self.invoke("check", self.source)
        self.assert_diagnostic_failure(default, "type-mismatch", plugin=False)
        self.assertIn("\n\t(h:identity true))\n\t            ^~~~\n", default.stderr)
        self.assertIn(f"{helper}:2:29: note[expected-type-origin]", default.stderr)
        self.assertNotIn("\r", default.stderr)

        helper.write_bytes(b"; helper\r\n\t#+")
        reader = self.invoke("check", self.source)
        self.assert_diagnostic_failure(reader, "missing-reader-feature", plugin=False)
        self.assertTrue(reader.stderr.startswith(f"{helper}:2:4:"), reader.stderr)
        self.assertTrue(reader.stderr.endswith("\n\t#+\n\t  ^\n"), reader.stderr)

        self.source.write_bytes(b"")
        empty = self.invoke("check", self.source, "--diagnostic-plugin", self.plugins["formatter"])
        self.assert_diagnostic_failure(empty, "missing-main-function")
        self.assertIn(f"|{self.source}:1:1|0:0:0|", empty.stderr)
        empty_default = self.invoke("check", self.source)
        self.assertTrue(empty_default.stderr.endswith("\n\n^\n"), empty_default.stderr)

        self.source.write_text(
            '(%macro missing () `(,(symbol "missing-callee")))\n'
            '(%function main () i64 (missing))'
        )
        macro = self.invoke("check", self.source, "--diagnostic-plugin", self.plugins["formatter"])
        self.assert_diagnostic_failure(macro, "unknown-function")
        location = macro.stderr.split("|")[4].split(":")
        self.assertEqual(location[0], location[1], macro.stderr)
        self.assertIn(f"|{self.source}:1:23|", macro.stderr)
        default_macro = self.invoke("check", self.source)
        self.assertTrue(default_macro.stderr.endswith("\n" + " " * 22 + "^\n"),
                        default_macro.stderr)

        self.source.write_text(";" + "a" * 400 + "\n" + " " * 400 + ")" + "b" * 400)
        bounded = self.invoke("read", self.source)
        self.assert_diagnostic_failure(bounded, "unexpected-closing-parenthesis", plugin=False)
        self.assertIn(":2:401:", bounded.stderr)
        self.assertLess(max(map(len, bounded.stderr.splitlines()[1:])), 170)

    def test_diagnostic_formatter_native_and_llvm_output(self):
        self.source.write_text("(%function value () i32 42)(native-export value)")
        tool = self.root / "failing-tool"
        artifact = self.root / "artifact"
        detail = "native detail line 1\nnative detail line 2"
        tool.write_text(f"#!/bin/sh\nprintf '%s' '{detail}' >&2\nexit 1\n")
        tool.chmod(0o755)
        plugin = self.plugins["formatter"]
        for kind, env_name, code in (
            ("shared-library", "VERONA_CORE_CLANG", "native-link-failed"),
            ("static-library", "VERONA_CORE_AR", "native-archive-failed"),
        ):
            with self.subTest(kind=kind):
                failed = self.invoke("compile", self.source, "--emit", kind, "-o", artifact,
                                     "--diagnostic-plugin", plugin,
                                     env=dict(os.environ, **{env_name: str(tool)}))
                self.assert_diagnostic_failure(failed, code)
                self.assertEqual(failed.stderr.count(detail), 1, failed.stderr)
                self.assertIn(f"\nT|{detail}\n", failed.stderr)
                self.assertFalse(artifact.exists())

        self.source.write_text(self.program("0"))
        warned = self.invoke("compile", self.source, "--emit", "object", "-o", artifact,
                             "--features", "+verona-unknown-feature", "--diagnostic-plugin", plugin)
        self.assertEqual((warned.returncode, warned.stdout), (0, ""))
        self.assertIn("D|warning|llvm-stderr|-|-|LLVM wrote to stderr", warned.stderr)
        self.assertIn("T|'+verona-unknown-feature' is not a recognized feature", warned.stderr)
        self.assertTrue(artifact.exists())

        self.source.write_text(
            "(%function bad () i64 (%/-primitive-i64 1 0))\n" + self.program("(bad)")
        )
        evaluated = self.invoke("eval", self.source, "--diagnostic-plugin", plugin)
        self.assert_diagnostic_failure(evaluated, "division-by-zero", status=70)
        self.assertEqual([line.split("|")[0] for line in evaluated.stderr.splitlines()],
                         ["D", "R", "R"])
        self.assertLess(evaluated.stderr.index("|in bad"), evaluated.stderr.index("|in main"))

        self.source.write_text(
            "(%inline value)(%function value () i32 42)(native-export value)"
        )
        compiled = self.invoke("compile", self.source, "--emit", "object", "-o", artifact,
                               "--diagnostic-plugin", plugin)
        self.assertEqual((compiled.returncode, compiled.stdout), (0, ""), compiled.stderr)
        self.assertIn("D|note|forced-inlining-disabled|", compiled.stderr)
