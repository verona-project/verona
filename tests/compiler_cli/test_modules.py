"""Module discovery, visibility, and import ordering."""

import re
import subprocess

from .support import CompilerTestCase, REPO_ROOT


class ModuleTests(CompilerTestCase):
    def test_structured_visibility(self):
        (self.root / "types.vrn").write_text("(%type Private (product))(%type Hidden (sum (X)))(%export Public)(%type Public (product (x i64)))")
        for body in ["(%function bad () t:Private (t:Private))",
                     "(%function bad () i64 (let ((x (t:Hidden:X))) 0))"]:
            result = self.run_core("check", "(%import types :as t)" + body + self.program("0"))
            self.assertEqual(result.returncode, 2, result.stderr)
        self.agrees("(%import types :as t)" + self.program("(field (t:Public 42) x)"), 42)

    def test_surface_directives_with_real_base(self):
        base = REPO_ROOT / "projects/base/src"
        source = """
(import base :as b)
(export main)
(b:function main () i64
  (let ((zero u8 (b:minBound)))
    (%+-primitive-i64 (b:convert zero) (b:convert (cast u8 42)))))
"""
        self.agrees(source, 42, "--module-path", base)
        (self.root / "library.vrn").write_text("""
(import base :as b)
(export answer)
(b:function answer () i64 (hidden))
(b:function hidden () i64 42)
""")
        self.agrees("(import library :as lib)" + self.program("(lib:answer)"),
                    42, "--module-path", base)
        for source, message in (
            ("(b:function main () i64 42)(import base :as b)", "only %function declarations"),
            ("(import library :as lib)" + self.program("(lib:hidden)"), "not exported"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source, "--module-path", base)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_modules(self):
        library = self.root / "math.vrn"
        library.write_text("""(%export answer)
          (%function hidden ((x i64)) i64 (%+-primitive-i64 x 1))
          (%function answer () i64 (hidden 41))
          (%function main () i64 99)""")
        self.agrees("""(%import math :as math)
          (%function main () i64 (math:answer))""", 42)
        # Same module name through multiple aliases and a diamond has one identity.
        (self.root / "package.bridge.vrn").write_text("""
          (%import math :as m) (%export answer)
          (%function answer () i64 (m:answer))""")
        repeated = """(%import math :as first)
          (%import math :as second) (%import math :as third)
          (%import package.bridge :as bridge)
          (%function answer () i64 3)
          (%function main () i64 (%+-primitive-i64 (answer)
            (%+-primitive-i64 (first:answer)
              (%+-primitive-i64 (second:answer)
                (%+-primitive-i64 (third:answer) (bridge:answer))))))"""
        self.agrees(repeated, 171)
        emitted = self.run_core("emit-llvm", repeated)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertEqual(len(re.findall(r'^define internal i64 @"?vrn\.(?:input|math|package\.bridge)\.[^"(]+"?\(', emitted.stdout, re.M)), 6)
        invalid = [
            ("(import math.vrn :as m)" + self.program("0"), "module not found"),
            ("(export missing)" + self.program("0"), "unknown function"),
            ("(%import math :as m)" + self.program("(m:hidden 1)"), "not exported"),
            ("(%import math :as m)" + self.program("(m:missing)"), "unknown module member"),
            (self.program("(m:answer)"), "missing import"),
            ("(%import math :as m)" + self.program("(answer)"), "unknown function"),
            ("(%import math :as m) (%import math :as m)" + self.program("0"), "duplicate import alias"),
            ("(%import missing :as m)" + self.program("0"), "cannot resolve module path"),
            ("(%import math as m)" + self.program("0"), "requires :as"),
            ("(%export missing)" + self.program("0"), "unknown function"),
            ("(%import math :as m)", "missing main"),
        ]
        for source, message in invalid:
            for mode in ("check", "eval", "emit-llvm"):
                with self.subTest(source=source, mode=mode):
                    result = self.run_core(mode, source)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)
        library.write_text("(%import input :as root) (%export answer) (%function answer () i64 1)")
        result = self.run_core("check", "(%import math :as math)" + self.program("0"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("import cycle", result.stderr)
        self.assertIn("math.vrn:1:", result.stderr)

    def test_named_module_search_paths(self):
        first, second = self.root / "first", self.root / "second"
        first.mkdir()
        second.mkdir()
        for directory, value in ((first, 42), (second, 17)):
            (directory / "package.values.vrn").write_text(
                f"(%export answer)(%function answer () i64 {value})")
        source = "(%import package.values)" + self.program("(package.values:answer)")
        self.agrees(source, 42, "--module-path", first, "--module-path", second)
        self.agrees(source, 17, "--module-path", second, "--module-path", first)
        # Export declarations append, and repeating an export is accepted by the reference.
        self.agrees("(%export main)(%export)(%export main main)" + self.program("42"), 42)
        # The entry directory is first, and dots stay in filenames.
        (self.root / "package.values.vrn").write_text("(%export answer)(%function answer () i64 99)")
        self.agrees(source, 99, "--module-path", first)
        # A dependency in another directory uses the session path, not its own parent.
        (first / "bridge.vrn").write_text("(%import package.values)(%export answer)(%function answer () i64 (package.values:answer))")
        self.agrees("(%import bridge)" + self.program("(bridge:answer)"), 99, "--module-path", first)
        # A missing first directory is skipped; argv preserves spaces in directories.
        spaced = self.root / "directory with spaces"
        spaced.mkdir()
        (spaced / "only.vrn").write_text("(%export answer)(%function answer () i64 42)")
        self.agrees("(%import only)" + self.program("(only:answer)"), 42,
                    "--module-path", self.root / "missing-directory", "--module-path", spaced)

    def test_default_qualifiers_and_module_identity(self):
        (self.root / "values.vrn").write_text("(%export P)(%type P (product (x i64)))")
        (self.root / "other.vrn").symlink_to(self.root / "values.vrn")
        source = """(%import values)(%import values :as alias)(%import other)
          (%function identity ((p values:P)) values:P p)
          (%function main () i64 (field (identity (alias:P 42)) x))"""
        self.agrees(source, 42)
        result = self.run_core("check", source.replace("(alias:P 42)", "(other:P 42)"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("type mismatch", result.stderr)
        # Qualifier lookup cannot implicitly access a transitive import.
        (self.root / "bridge.vrn").write_text("(%import values)")
        result = self.run_core("check", "(%import bridge)" + self.program("(values:missing)"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("module not imported", result.stderr)
        result = self.run_core("check", "(%import values)(%import values :as values)" + self.program("0"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("duplicate import alias", result.stderr)
        for name in (".values", "values.", "values..more", "true", "1"):
            result = self.run_core("check", f"(%import {name})" + self.program("0"))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertRegex(result.stderr, "expected.*module name|empty component")

    def test_dependency_first_declaration_order(self):
        (self.root / "leaf.vrn").write_text("(%function leaf () i64 11)")
        (self.root / "left.vrn").write_text("(%import leaf)(%function left () i64 22)")
        (self.root / "right.vrn").write_text("(%import leaf)(%function right () i64 33)")
        result = self.run_core("emit-llvm", "(%import left)(%import right)" + self.program("42"))
        self.assertEqual(result.returncode, 0, result.stderr)
        positions = [result.stdout.index(f"ret i64 {value}") for value in (11, 22, 33, 42)]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(result.stdout.count("ret i64 11"), 1)

    def test_module_reference_parity(self):
        # Same module graphs through the configured reference seed and the
        # compiler under test. Only declaration spelling and the native entry ABI differ.
        host = self.reference_compiler
        cases = [
            ("aliases-and-diamond", {
                "input": "(%import bridge)(%import library :as other)" + self.program("(%+-primitive-i64 (bridge:answer) (other:answer))"),
                "bridge": "(%import library)(%export answer)(%function answer () i64 (library:answer))",
                "library": "(%export answer)(%function answer () i64 21)",
            }, True, 42),
            ("default-dotted-qualifier", {
                "input": "(%import package.values)" + self.program("(package.values:answer)"),
                "package.values": "(%export answer)(%function answer () i64 42)",
            }, True, 42),
            ("appended-exports", {
                "input": "(%import library)" + self.program("(library:answer)"),
                "library": "(%export answer)(%export)(%export answer answer)(%function answer () i64 42)",
            }, True, 42),
            ("private-member", {"input": "(%import library)" + self.program("(library:secret)"),
                                "library": "(%function secret () i64 42)"}, False, 0),
            ("unknown-member", {"input": "(%import library)" + self.program("(library:missing)"),
                                "library": "(%export)"}, False, 0),
            ("missing-import", {"input": "(%import bridge)" + self.program("(library:answer)"),
                                "bridge": "(%import library)",
                                "library": "(%export answer)(%function answer () i64 42)"}, False, 0),
            ("unknown-qualifier", {"input": self.program("(missing:answer)")}, False, 0),
            ("duplicate-alias", {"input": "(%import library)(%import library :as library)" + self.program("0"),
                                 "library": ""}, False, 0),
            ("cycle", {"input": "(%import library)" + self.program("0"),
                       "library": "(%import input)"}, False, 0),
        ]
        for name, files, accepted, expected in cases:
            with self.subTest(case=name):
                core_directory, host_directory = self.root / name / "core", self.root / name / "host"
                core_directory.mkdir(parents=True)
                host_directory.mkdir(parents=True)
                for module, source in files.items():
                    (core_directory / f"{module}.vrn").write_text(source)
                    translated = source
                    if module == "input":
                        translated = translated.replace("(%function main () i64", "(%function entry () i64")
                        translated += "(%function main () exit-code (%trunc-primitive-i64-i32 (entry)))"
                    (host_directory / f"{module}.vrn").write_text(translated)
                core = subprocess.run([str(self.compiler), "eval", str(core_directory / "input.vrn")],
                                      capture_output=True, text=True, timeout=30)
                binary = host_directory / "program"
                reference = subprocess.run([str(host), "compile", str(host_directory / "input.vrn"), "-o", str(binary)],
                                           capture_output=True, text=True, timeout=30)
                self.assertEqual(core.returncode == 0, accepted, core.stderr)
                self.assertEqual(reference.returncode == 0, accepted, reference.stderr)
                if accepted:
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, expected, native.stderr)
                    self.assertEqual(core.stdout, f"{expected}\n")
                else:
                    self.assertFalse(binary.exists())
                    self.assertFalse(core.stdout)

    def test_module_resource_limits(self):
        for i in range(65):
            (self.root / f"depth{i}.vrn").write_text(
                f"(%import depth{i + 1} :as child)" if i < 64 else "")
        result = self.run_core("check", "(%import depth0 :as child)" + self.program("0"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("dependency depth limit", result.stderr)
        for i in range(256):
            (self.root / f"empty{i}.vrn").write_text("")
        source = "".join(f"(%import empty{i} :as alias{i})" for i in range(256))
        result = self.run_core("check", source + self.program("0"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("module count limit", result.stderr)

    def test_module_diagnostics(self):
        library = self.root / "failure.vrn"
        library.write_text("(%export fail)\n(%function fail () i64 (%/-primitive-i64 1 0))")
        source = "(%import failure :as lib)" + self.program("(lib:fail)")
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn(f"{library}:2:24:", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "failing native"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assertIn(f"{library}:2:24:", native.stderr)
            self.assertEqual(native.stdout, "")
        library.write_text("(%export fail)\n(%function fail () i64 true)")
        result = self.run_core("check", source)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(f"{library}:2:", result.stderr)
        self.assertIn("type mismatch", result.stderr)
