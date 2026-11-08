"""End-to-end tests: execute the Verona implementation and its LLVM output."""
import os
import json
import re
import shutil
import shlex
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

COMPILER = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path("build/verona").resolve()


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="verona core tests ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.source = self.root / "input.vrn"

    def run_core(self, mode, source, *args, **kwargs):
        self.source.write_bytes(source.encode() if isinstance(source, str) else source)
        return subprocess.run([str(COMPILER), mode, str(self.source), *map(str, args)],
                              capture_output=True, text=True, timeout=30, **kwargs)

    def program(self, expression):
        return f"(%function main () i64 {expression})"

    def agrees(self, source, expected, *options):
        evaluated = self.run_core("eval", source, *options)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, f"{expected}\n")
        for level in ("-O0", "-O2"):
            binary = self.root / "native executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level, *options)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, f"i64:{expected}\n")
            self.assertEqual(native.stderr, "")

    def test_compile_time_helper_parity(self):
        inventory = json.loads((Path(__file__).parent / "compile_time_parity.json").read_text())
        self.assertEqual(inventory["version"], 1)
        for operation in inventory["operations"]:
            self.assertIn(operation["status"], ("implemented", "pending"))
            if operation["status"] != "implemented":
                continue
            self.assertTrue(operation["positive"], operation["name"])
            for expression in operation["positive"]:
                with self.subTest(operation=operation["name"], expression=expression):
                    self.agrees("(%macro result () (cond (" + expression + " 42) (true 0)))" +
                                self.program("(result)"), 42)
            for case in operation["negative"]:
                source = "(%macro result () " + case["expression"] + ")" + self.program("(result)")
                for mode in ("check", "eval", "emit-llvm", "compile-report"):
                    with self.subTest(operation=operation["name"], invalid=case["expression"], mode=mode):
                        output = self.root / "invalid-helper"
                        options = ("-o", output) if mode == "compile-report" else ()
                        result = self.run_core(mode, source, *options)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assertIn(case["diagnostic"], result.stderr)
                        self.assertIn(str(self.source) + ":", result.stderr)
                        self.assertEqual(result.stdout, "")
                        self.assertFalse(output.exists())

    def test_compile_time_helpers_reference_comparison(self):
        inventory = json.loads((Path(__file__).parent / "compile_time_parity.json").read_text())
        host = Path(__file__).resolve().parents[1] / "build/verona"
        for operation in inventory["operations"]:
            if operation["status"] != "implemented":
                continue
            expression = "(and " + " ".join(operation["positive"]) + ")"
            source = ("(macro result () (cond (" + expression + " 42) (true 0)))"
                      "(function main () exit-code (result))")
            with self.subTest(operation=operation["name"]):
                self.source.write_text(source)
                binary = self.root / "reference-helper"
                compiled = subprocess.run([str(host), "compile", str(self.source), "-o", str(binary)],
                                          capture_output=True, text=True, timeout=30)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, 42, native.stderr)

    def test_compile_time_generated_values_and_empty_access(self):
        self.agrees("(%macro result () (length '(a b c)))" + self.program('(result)'), 3)
        self.agrees('(%macro result () `(let ((,(symbol "true") i64 42)) ,(symbol "true")))' +
                    self.program('(result)'), 42)
        for operation in ("car", "cdr"):
            result = self.run_core("eval", f"(%macro result () ({operation} nil))" + self.program("(result)"))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("non-empty", result.stderr)
        # Declaration batches use the compatibility builder; map constructs code
        # without running an operation, preserving qualified call heads.
        self.agrees("""(%macro declarations ()
          (definitions '(%function helper () i64 40) '(%function main () i64 (+ (helper) 2))))
(declarations)""", 42)

    def test_compile_time_context_foreign_targets(self):
        for triple, platform, architecture, object_format in (
            ("x86_64-unknown-linux-gnu", "linux", "x86_64", "elf"),
            ("aarch64-apple-darwin", "darwin", "aarch64", "macho"),
        ):
            expression = (f'(and (compiler:feature? "{platform}") '
                          f'(compiler:feature? "{architecture}") '
                          '(compiler:feature? "CLIENTFLAG") '
                          f"(equal? (plist-ref (compiler:target-info) ':triple) \"{triple}\") "
                          f"(equal? (plist-ref (compiler:target-info) ':object-format) \"{object_format}\"))")
            source = "(%macro result () (cond (" + expression + " 42) (true 0)))" + self.program("(result)")
            result = self.run_core("emit-llvm", source, "--target", triple, "--feature", "ClientFlag")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ret i64 42", result.stdout)

    def test_macro_reference_capture_contract(self):
        # Plain returned syntax follows the reference invocation context. A new
        # lexical-hygiene design must change this explicit expectation deliberately.
        source = """(%macro capture (value) `(let ((local i64 2)) ,value))
(%function main () i64 (let ((local i64 40)) (capture local)))"""
        self.agrees(source, 2)

    def test_compile_time_arithmetic_independent_values(self):
        import random
        generator = random.Random(1701)
        for index in range(12):
            a = generator.randrange(-(1 << 180), 1 << 180)
            b = generator.randrange(1, 1 << 90) * (-1 if index % 2 else 1)
            quotient = (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1)
            expected = a - quotient * b
            # Reduce a large result to i64 with truncation-based remainder.
            small = (abs(expected) % 97) * (-1 if expected < 0 else 1)
            expression = f"(remainder (remainder {a} {b}) 97)"
            source = "(%macro value () " + expression + ")" + self.program("(value)")
            result = self.run_core("eval", source)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{small}\n")
        self.agrees("(%macro value () (- (* 12345678901234567890 98765432109876543210) "
                    "1219326311370217952237463801111263526858))" + self.program("(value)"), 42)
        result = self.run_core("eval", "(%macro value () (quotient -9223372036854775808 -1))"
                               "(%function main () u64 (value))")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "u64:9223372036854775808\n")

    def test_generated_native_symbol_and_numeric_boundaries(self):
        source = """(%macro declaration ()
  (compiler:call '%external-function 'native_abs (string-concat "a" "bs") '(i32) 'i32))
(declaration)
(%function main () i64 (%sext-primitive-i32-i64 (native_abs -42)))"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("native calls are unavailable", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "generated native symbol"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, "i64:42\n")
        for literal in ("1.", "+.1", "1e2", "1/2"):
            result = self.run_core("eval", '(%%macro value () (string->number "%s"))' % literal +
                                   self.program("(value)"))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("numeric string", result.stderr)
        huge = "1" + "0" * 400 + ".0"
        result = self.run_core("eval", '(%%macro value () (string->number "%s"))' % huge +
                               self.program("(value)"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("floating-point", result.stderr)

    def test_cli_version_and_output_alias(self):
        host = Path(__file__).resolve().parents[1] / "build/verona"
        reference = subprocess.run([str(host), "--version"], capture_output=True, text=True, timeout=10)
        self.assertEqual(reference.returncode, 0, reference.stderr)
        for flag in ("--version", "-V"):
            result = subprocess.run([str(COMPILER), flag], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, reference.stdout)
            self.assertEqual(result.stderr, "")
            invalid = subprocess.run([str(COMPILER), flag, "extra"], capture_output=True, text=True, timeout=10)
            self.assertEqual(invalid.returncode, 2, invalid.stderr)
        binary = self.root / "output alias"
        result = self.run_core("compile-report", self.program("42"), "--output", binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(native.returncode, 0, native.stderr)
        self.assertEqual(native.stdout, "i64:42\n")

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

    def test_compile_time_float_roundtrip_and_arithmetic_limits(self):
        import decimal
        for value in (0.1, -0.0, 1.25, sys.float_info.max, sys.float_info.min, 5e-324):
            text = format(decimal.Decimal.from_float(value), "f")
            if "." not in text:
                text += ".0"
            source = ('(%macro result () (string->number (number->string (string->number "' +
                      text + '"))))(%function main () f64 (result))')
            result = self.run_core("eval", source)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = "f64:" + str(struct.unpack("<Q", struct.pack("<d", value))[0]) + "\n"
            self.assertEqual(result.stdout, expected)
        digits = "9" * 3000
        self.agrees("(%macro result () (length (number->string (+ " + digits + " 1))))" +
                    self.program("(result)"), 3001)
        self.agrees("(%macro result () (length (number->string (* 1 " + digits + "))))" +
                    self.program("(result)"), 3000)
        # Expensive arithmetic consumes the shared macro budget instead of
        # silently wrapping an integer or continuing without a bound.
        digits = "9" * 1000
        result = self.run_core("eval", "(%macro result () (* " + digits + " " + digits + "))" +
                               self.program("(result)"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("step limit", result.stderr)

    def test_source_defined_declaration_macros(self):
        # Reuse the real Base declarations before testing the full module.
        base = Path(__file__).resolve().parents[1] / "projects/base/src/base.vrn"
        source = base.read_text()
        prefix = source.split("(macro external-function", 1)[0]
        (self.root / "base.vrn").write_text(prefix + "(%export function)")
        self.agrees("""(%import base :as b)
(%macro define (name &rest declaration)
  (cons 'b:function (cons name declaration)))
(define main () i64 42)
""", 42)
        for source, message in (
            ("(define main () i64 42)(%macro define (&rest xs) (cons '%function xs))",
             "only %function declarations"),
            ("(%macro define (x) x)(define)", "missing macro argument"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_default_numeric_generics(self):
        for ty in ("i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"):
            def literal(value):
                return f"{value}.0" if ty.startswith("f") else str(value)
            tests = [
                f"(== (+ left right) {literal(42)})",
                f"(== (- left right) {literal(38)})",
                f"(== (* left right) {literal(80)})",
                f"(== (/ left right) {literal(20)})",
                "(!= left right)", "(< right left)", "(<= right left)",
                "(> left right)", "(>= left right)", "(<= left left)", "(>= left left)",
            ]
            body = "42"
            for test in reversed(tests):
                body = f"(if {test} {body} 0)"
            with self.subTest(type=ty):
                self.agrees(f"""
(%function exercise ((left {ty}) (right {ty})) i64 {body})
(%function main () i64 (exercise {literal(40)} {literal(2)}))
""", 42)
        self.agrees("""
(%function main () i64
  (let ((nan (/ (cast f64 0.0) 0.0)) (infinity (/ (cast f32 1.0) 0.0)))
    (if (!= nan nan) (if (== nan nan) 0 (if (> infinity (cast f32 42.0)) 42 0)) 0)))
""", 42)

    def test_default_operator_literal_inference(self):
        self.agrees(self.program("(+ 40 2)"), 42)
        self.agrees("""
(%macro identity (form) form)
(%function narrow () u8 (+ 40 (identity 2)))
(%function main () i64 (%zext-primitive-u8-i64 (narrow)))
""", 42)
        self.agrees(self.program("(%zext-primitive-u8-i64 (+ (cast u8 40) 2))"), 42)
        for expression in ("(+ 1 (cast u8 1))", "(+ 1 1)", "(== 1 1)", "(< 1 2)"):
            result = self.run_core("check", f"(%function main () unit (do {expression} unit))")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("ambiguous numeric literal", result.stderr)
        result = self.run_core("check", "(%function main () unit (do (+ (cast u8 1) 1) unit))")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_operator_declarations_and_extensions(self):
        self.agrees("""
(%function + ((left i64) (right i64)) i64 42)
(%function main () i64 (+ 1 2))
""", 42)
        self.agrees("""
(%generic + (left right))
(%implementation + ((left bool) (right bool)) i64 42)
(%function main () i64 (+ true false))
""", 42)
        self.agrees("""
(%type Point (product (value i64)))
(%implementation + ((left Point) (right Point)) Point (Point (+ (field left value) (field right value))))
(%function main () i64 (field (+ (Point 40) (Point 2)) value))
""", 42)
        # Same input types, different results: context selects the implementation.
        self.agrees("""
(%implementation + ((left i64) (right i64)) bool true)
(%function main () i64 (if (+ (cast i64 1) 2) (+ 40 2) 0))
""", 42)
        self.agrees("""
(%type Callback (pointer (function (i64 i64) i64)))
(%function answer ((left i64) (right i64)) i64 42)
(%function apply ((+ Callback)) i64 (+ 1 2))
(%function main () i64 (apply answer))
""", 42)
        # Protocol evidence overrides the implicit generic, even for numeric types.
        self.agrees("""
(%protocol Custom (a) (+ ((left a) (right a)) a))
(%implementation (Custom i64) (function + ((left i64) (right i64)) i64 42))
(%function apply (for (a) ((Custom a))) ((left a) (right a)) a (+ left right))
(%function main () i64 (apply (cast i64 1) (cast i64 2)))
""", 42)
        (self.root / "operators.vrn").write_text("(%export +)(%function + ((a i64) (b i64)) i64 42)")
        self.agrees("(%import operators :as op)(%function main () i64 (op:+ 1 2))", 42)
        # Built-in generic implementations extend the shared bootstrap identity.
        (self.root / "points.vrn").write_text("""
(%export Point)
(%type Point (product (value i64)))
(%implementation + ((a Point) (b Point)) Point (Point (+ (field a value) (field b value))))
""")
        self.agrees("""
(%import points :as p)
(%function main () i64 (field (+ (p:Point 40) (p:Point 2)) value))
""", 42)
        # An explicit generic in an imported module does not replace the caller's default.
        (self.root / "custom.vrn").write_text("""
(%export +)
(%generic + (left right))
(%implementation + ((a bool) (b bool)) i64 42)
""")
        self.agrees("""
(%import custom :as c)
(%function main () i64 (+ (c:+ true false) 0))
""", 42)

    def test_default_division_failures(self):
        self.agrees(self.program("(/ (cast i64 -85) 2)"), -42)
        self.agrees(self.program("(if (> (cast u64 18446744073709551615) 1) 42 0)"), 42)
        for ty, expression, message in (
            ("i8", "(/ (cast i8 -128) -1)", "signed division overflow"),
            ("i64", "(/ (cast i64 -9223372036854775808) -1)", "signed division overflow"),
            ("u64", "(/ (cast u64 42) 0)", "division by zero"),
        ):
            with self.subTest(type=ty):
                source = f"(%function main () {ty} {expression})"
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn(message, evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "division failure"
                    compiled = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertEqual(native.stderr.splitlines()[0], evaluated.stderr.splitlines()[0])

    def test_default_operator_errors(self):
        for source, message in (
            (self.program("(+ (cast i32 1) (cast i64 2))"), "no matching generic implementation"),
            (self.program("(+ true false)"), "no matching generic implementation"),
            (self.program("(+ (cast i64 1))"), "wrong generic argument count"),
            (self.program("(%zext-primitive-u8-i64 (+ (cast u8 1) 256))"), "out of range"),
            ("(%generic + (left right))(%implementation + ((a bool) (b bool)) bool true)" + self.program("(+ 40 2)"), "ambiguous numeric literal"),
            ("(%implementation + ((a i64) (b i64)) i64 42)" + self.program("0"), "duplicate generic implementation"),
            ("(%implementation + ((a i64) (b i64)) bool true)(%function main () unit (do (+ (cast i64 1) (cast i64 2)) unit))", "ambiguous generic implementation"),
            ("(%constant + i64 1)" + self.program("(+ 1 2)"), "constant value is not callable"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_runtime_expression_macros(self):
        self.agrees("""
(%macro identity (form) form)
(%function narrow () i8 (identity 40))
(%function main () i64
  (let ((value i64 (identity (cast i64 (identity 2)))))
    (do (identity unit)
      (if (identity true) (%+-primitive-i64 (%sext-primitive-i8-i64 (narrow)) (identity value)) 0))))
""", 42)
        self.agrees("""
(%macro identity (form) form)
(%function answer ((identity i64)) i64 (identity identity))
(%function main () i64 (later (answer 42)))
(%macro later (form) form)
""", 42)
        self.agrees("""
(%macro identity (form) form)
(%function main () i64
  (%zext-primitive-u8-i64 (deref (pointer-offset "abc" (identity 2)))))
""", 99)
        # Expression expansion must remain lazy for unused generic bodies.
        checked = self.run_core("check", """
(%macro broken () (missing))
(%function unused (for (T)) ((value T)) T (broken))
(%function main () i64 42)
""")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.agrees("""
(%macro identity (form) form)
(%function choose (for (T)) ((value i8) (other T)) i8 value)
(%function main () i64 (%sext-primitive-i8-i64 (choose (identity 42) true)))
""", 42)

    def test_macro_compile_time_control_and_lists(self):
        self.agrees("""
(%macro expand-helper (input)
  `(let ((items ,input))
     (cond ((empty? items) 0)
       (true (let ((ignored (car items)) (items (cdr items)))
         (cond ((equal? ignored 'skip) (car items)) (true 0)))))))
(%macro answer (&rest values) (expand-helper values))
(%function main () i64 (answer skip 42))
""", 42)
        self.agrees("""
(%macro answer ()
  (let ((items (list 1 42)) (tail (cdr items)))
    (car items)
    (cond ((or false (and true (not false))) (car tail)) (true (missing)))))
(%function main () i64 (answer))
""", 42)
        for expression, expected in (
            ("(not false)", "bool:1\n"),
            ("(and false (missing))", "bool:0\n"),
            ("(or true (missing))", "bool:1\n"),
            ("(equal? '(a (true nil)) (list 'a (list true '())))", "bool:1\n"),
            ("(equal? 00042 +42)", "bool:1\n"),
            ("(equal? -0 +0)", "bool:1\n"),
            ("(equal? -42 42)", "bool:0\n"),
            ("(equal? unit unit)", "bool:1\n"),
            ('(equal? unit (symbol-concat "unit"))', "bool:0\n"),
            ('(equal? true (symbol-concat "true"))', "bool:0\n"),
            ('(equal? \'lib:name (symbol-concat "lib:name"))', "bool:0\n"),
            ('(equal? \':keyword (symbol-concat ":keyword"))', "bool:1\n"),
            (r'(equal? "a\n" "a\n")', "bool:1\n"),
            ("(equal? #\\Newline #\\newline)", "bool:1\n"),
            ("(equal? 1.0 1.00)", "bool:1\n"),
        ):
            with self.subTest(expression=expression):
                result = self.run_core("eval", f"(%macro value () {expression})(%function main () bool (value))")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
        for parameters, arguments, expression in (
            ("(value)", "nil", "(empty? value)"),
            ("(value)", "(a nil)", "(equal? value '(a ()))"),
            ("(&rest values)", "nil nil", "(equal? values '(() ()))"),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_core("eval", f"(%macro empty {parameters} {expression})(%function main () bool (empty {arguments}))")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "bool:1\n")
        for name in ("true", "false", "unit"):
            with self.subTest(generated_binding=name):
                self.agrees(f"""
(%macro helper () `(let ((,(symbol-concat "{name}") 42)) ,(symbol-concat "{name}")))
(%macro value () (helper))
(%function main () i64 (value))
""", 42)
        # A macro-generated generic keeps computed boolean bits when specialized.
        self.agrees("""
(%macro define ()
  `(%function choose (for (T)) ((value T)) bool ,(not false)))
(define)
(%function main () i64 (if (choose (cast i64 0)) 42 0))
""", 42)

    def test_macro_compile_time_state(self):
        self.agrees("""
(compiler:state-set! 'key nil)
(compiler:state-set! '(nested 1) '(40))
(%macro write () '(compiler:state-set! 'phase 'ready))
(write)
(let ((old (compiler:state-ref '(nested +01))))
  (compiler:state-set! '(nested 1) (cons 2 old)))
(cond ((and (compiler:state-has? 'key)
            (equal? (compiler:state-ref 'key 7) nil)
            (equal? (compiler:state-ref 'phase) 'ready)
            (equal? (compiler:state-ref '(nested 1)) '(2 40)))
       (compiler:state-set! 'answer 42))
      (true (compiler:state-set! 'answer 0)))
(and false (compiler:state-set! 'answer 0))
(or true (compiler:state-set! 'answer 0))
(compiler:state-remove! 'key)
(%macro answer ()
  (cond ((and (not (compiler:state-has? 'key))
              (not (compiler:state-remove! 'key))
              (equal? (compiler:state-ref 'key 9) 9))
         (compiler:state-ref 'answer)) (true 0)))
(%function main () i64 (answer))
""", 42)
        # Top-level statement results are data, even when shaped like declarations.
        self.agrees("""
(compiler:state-set! 'data '((%function main () i64 0)))
(%macro once ()
  (let ((old (compiler:state-ref 'calls nil)))
    (compiler:state-set! 'calls (cons 'call old))
    42))
(%function value () i64 (once))
(%macro result ()
  (cond ((equal? (compiler:state-ref 'calls) '(call)) 42) (true 0)))
(%function main () i64 (if (%=-primitive-i64 (value) 42) (result) 0))
""", 42)
        # Previously returned lists must not change when a key is replaced.
        self.agrees("""
(%macro answer ()
  (let ((stored (compiler:state-set! 'key '(40 2)))
        (borrowed (compiler:state-ref 'key)))
    (compiler:state-set! 'key '(0))
    (cond ((and (equal? stored '(40 2)) (equal? borrowed '(40 2))) 42) (true 0))))
(%function main () i64 (answer))
""", 42)

    def test_macro_state_module_keys(self):
        (self.root / "other.vrn").write_text("(%export)")
        (self.root / "models.vrn").write_text("""
(compiler:state-set! 'models:types '((:name Rectangle :fields ((width i64) (height i64)))))
(compiler:state-set! 'global 40)
(%macro append-kind (key)
  (let ((ignored (compiler:state-set! key '((:name Scale :fields ((factor i64))))))) '()))
(%export append-kind)
""")
        self.agrees("""
(%import models :as m)
(%import models :as n)
(m:append-kind n:other)
(compiler:state-set! 'models:other (compiler:state-ref 'n:other))
(%macro generated ()
  (let ((rectangle (nth 0 (compiler:state-ref 'n:types)))
        (scale (nth 0 (compiler:state-ref 'models:other))))
    `((%type ,(plist-ref rectangle ':name) ,(cons 'product (plist-ref rectangle ':fields)))
      (%type ,(plist-ref scale ':name) ,(cons 'product (plist-ref scale ':fields))))))
(generated)
(%macro shared () (compiler:state-ref 'global))
(%function main () i64 (%+-primitive-i64 (shared) (field (Scale 2) factor)))
""", 42)
        # Alias canonicalization is recursive, and full names work alongside aliases.
        self.agrees("""
(%import models :as m)
(%import models :as n)
(compiler:state-set! '(m:types (n:types)) 42)
(%macro answer () (compiler:state-ref '(models:types (m:types))))
(%function main () i64 (answer))
""", 42)
        self.agrees("""
(%import models :as m)
(%import other :as o)
(compiler:state-set! '(m:types) 42)
(compiler:state-set! '(o:types) 0)
(%macro answer () (compiler:state-ref '(models:types)))
(%function main () i64 (answer))
""", 42)
        (self.root / "other.vrn").write_text("(%export)")
        result = self.run_core("check", """
(%import models :as m)
(%import other :as models)
(compiler:state-ref 'models:key)
(%function main () i64 0)
""")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("ambiguous state module qualifier", result.stderr)

    def test_macro_nth_and_plist_ref(self):
        for expression in (
            "(equal? (nth 1 '(a b c)) 'b)",
            "(equal? (nth -0 '(42)) 42)",
            "(equal? (nth +0001 '(a (b c))) '(b c))",
            "(equal? (plist-ref '(:a nil) ':a 7) nil)",
            "(equal? (plist-ref nil ':a 7) 7)",
            "(equal? (plist-ref nil ':a) nil)",
            "(equal? (plist-ref '((a b) 42) '(a b)) 42)",
            "(equal? (plist-ref '(0.0 1 -0.0 2) -0.0) 2)",
        ):
            with self.subTest(expression=expression):
                self.agrees(f"(%macro answer () (cond ({expression} 42) (true 0)))" + self.program("(answer)"), 42)
        self.agrees("""
(%macro pick ()
  (let ((values '(40 2)))
    `(list ,(nth 0 values) ,(nth 1 values))))
(%macro answer ()
  (let ((values (pick)))
    (cond ((equal? values '(40 2)) (nth 0 (plist-ref '(:answer (42)) ':answer))) (true 0))))
(%function main () i64 (answer))
""", 42)

    def test_macro_state_and_data_errors(self):
        for expression, diagnostic in (
            ("(compiler:state-ref)", "state operation arity"),
            ("(compiler:state-ref 'x nil nil)", "state operation arity"),
            ("(compiler:state-set! 'x)", "state operation arity"),
            ("(compiler:state-has? 'x 1)", "state operation arity"),
            ("(compiler:state-remove!)", "state operation arity"),
            ("(compiler:state-ref 'missing:key)", "unknown state module qualifier"),
            ("(nth)", "nth requires two arguments"),
            ("(nth 1 '(a))", "list index out of bounds"),
            ("(nth -1 '(a))", "list index out of bounds"),
            ("(nth 18446744073709551616 '(a))", "list index out of bounds"),
            ("(nth 1.0 '(a))", "list index out of bounds"),
            ("(nth true '(a))", "list index out of bounds"),
            ("(nth 0 nil)", "list index out of bounds"),
            ("(nth 0 'a)", "requires a list"),
            ("(plist-ref '(:a))", "collection operation arity"),
            ("(plist-ref 'a ':a)", "requires a list"),
            ("(plist-ref '(:a) ':a)", "property list requires key/value pairs"),
            ("(plist-ref '(:a 1 :b 2 :b 3) ':a)", "duplicate collection key"),
            ("(plist-ref '((a) 1 (a) 2) '(a))", "duplicate collection key"),
            ("(plist-ref '(:a 1 :a 2 :b) ':a)", "property list requires key/value pairs"),
        ):
            with self.subTest(expression=expression):
                result = self.run_core("check", f"(%macro bad () {expression})" + self.program("(bad)"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(diagnostic, result.stderr)

    def test_macro_state_once_per_source_form(self):
        self.agrees("""
(compiler:state-set! 'calls nil)
(%macro observe ()
  (let ((old (compiler:state-ref 'calls)))
    (compiler:state-set! 'calls (cons 'call old)) 42))
(%macro wrapper () '(observe))
(%function touch (for (T)) ((value T)) i64 (wrapper))
(%function use () i64 (%+-primitive-i64 (touch (cast i8 0)) (touch (cast i16 0))))
(%macro result () (cond ((equal? (compiler:state-ref 'calls) '(call)) 42) (true 0)))
(%function main () i64 (result))
""", 42)
        # Generated nested calls keep distinct identities within an expansion,
        # but each one is shared across specializations of the containing source.
        self.agrees("""
(compiler:state-set! 'calls nil)
(%macro observe ()
  (let ((old (compiler:state-ref 'calls)))
    (compiler:state-set! 'calls (cons 'call old)) 21))
(%macro wrapper () '(%+-primitive-i64 (observe) (observe)))
(%function touch (for (T)) ((value T)) i64 (wrapper))
(%function use () i64 (%+-primitive-i64 (touch (cast i8 0)) (touch (cast i16 0))))
(%macro result () (cond ((equal? (compiler:state-ref 'calls) '(call call)) 42) (true 0)))
(%function main () i64 (result))
""", 42)
        # Two generated declarations from the same macro template are distinct
        # source forms, even though the generated calls have identical spans.
        self.agrees("""
(compiler:state-set! 'calls nil)
(%macro observe ()
  (let ((old (compiler:state-ref 'calls)))
    (compiler:state-set! 'calls (cons 'call old)) 21))
(%macro define (name) `(%function ,name () i64 (observe)))
(define one)
(define two)
(%macro result () (cond ((equal? (compiler:state-ref 'calls) '(call call)) 42) (true 0)))
(%function main () i64 (result))
""", 42)
        self.agrees("""
(compiler:state-set! 'calls nil)
(%macro observe ()
  (let ((old (compiler:state-ref 'calls)))
    (compiler:state-set! 'calls (cons 'call old)) 21))
(%macro twice (form) `(%+-primitive-i64 ,form ,form))
(%function touch (for (T)) ((value T)) i64 (twice (observe)))
(%function use () i64 (%+-primitive-i64 (touch (cast i8 0)) (touch (cast i16 0))))
(%macro result () (cond ((equal? (compiler:state-ref 'calls) '(call call)) 42) (true 0)))
(%function main () i64 (result))
""", 42)

    def test_macro_state_and_collection_budget(self):
        bindings = " ".join(f"(v{i} (compiler:state-set! 'k{i} {i}))" for i in range(350))
        pairs = " ".join(f":k{i} {i}" for i in range(400))
        for body in (f"(let ({bindings}) 42)", f"(plist-ref '({pairs}) ':k0)"):
            result = self.run_core("check", f"(%macro heavy () {body})" + self.program("(heavy)"))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("compile-time evaluation step limit exceeded", result.stderr)

    def test_macro_reductions(self):
        self.agrees("""
(%macro left (initial &rest values)
  (compiler:reduce '%--primitive-i64 initial values))
(%macro right (initial &rest values)
  (compiler:reduce-right '%--primitive-i64 initial values))
(%function main () i64
  (if (%=-primitive-i64 (left 2 50 10) -58)
    (if (%=-primitive-i64 (right 2 50 10) 42)
      (if (%=-primitive-i64 (left 42) (right 42)) 42 0) 0) 0))
""", 42)
        # Construction must not call or resolve the head, nor mutate shared
        # values when the same input/initial form is used in both directions.
        self.agrees("""
(%macro answer ()
  (let ((initial '(z)) (values '((a) (b))))
    (cond
      ((and
        (equal? (compiler:reduce 'unbound initial values)
          '(unbound (unbound (z) (a)) (b)))
        (equal? (compiler:reduce-right 'unbound initial values)
          '(unbound (a) (unbound (b) (z))))
        (equal? initial '(z))
        (equal? values '((a) (b)))
        (equal? (compiler:reduce 'unbound initial nil) initial)
        (equal? (compiler:reduce-right 'unbound initial '()) initial)
        (equal? (compiler:reduce ':keyword 0 '(1)) '(:keyword 0 1))
        (equal? (compiler:reduce (symbol-concat "true") 0 '(1))
          (list (symbol-concat "true") 0 1))) 42)
      (true 0))))
(%function main () i64 (answer))
""", 42)
        # Large flat inputs are not nested evaluator calls. Each fold still
        # consumes the shared evaluation budget, including inside helper macros.
        items = " ".join("0" for _ in range(1000))
        self.agrees(f"""
(%macro answer ()
  (let ((values '({items})))
    (cond ((and (equal? (car (compiler:reduce 'f 0 values)) 'f)
                (equal? (car (compiler:reduce-right 'f 0 values)) 'f)) 42)
          (true 0))))
(%function main () i64 (answer))
""", 42)

    def test_macro_reduction_modules(self):
        (self.root / "folds.vrn").write_text("""
(%macro left (initial &rest values)
  (compiler:reduce 'ops:subtract initial values))
(%macro helper (head initial values)
  `(compiler:reduce-right ,head ,initial ,values))
(%macro right (initial &rest values)
  (helper 'ops:subtract initial values))
(%export left right)
""")
        (self.root / "arithmetic.vrn").write_text("""
(%function subtract ((left i64) (right i64)) i64 (%--primitive-i64 left right))
(%export subtract)
""")
        self.agrees("""
(%import folds :as f)
(%import arithmetic :as ops)
(%function main () i64 (%+-primitive-i64 (f:left 100 10 3) (f:right 100 10 3)))
""", 194)
        # Preserve the originating input span when a generated call is checked.
        checked = self.run_core("check", """(%macro fold (initial &rest values)
  (compiler:reduce '%--primitive-i64 initial values))
(%function main () i64
  (fold 0
    true))
""")
        self.assertEqual(checked.returncode, 2, checked.stderr)
        self.assertIn(f"{self.source}:5:5:", checked.stderr)
        self.assertIn("type mismatch", checked.stderr)

    def test_macro_reduction_errors_and_budget(self):
        for operation in ("compiler:reduce", "compiler:reduce-right"):
            for arguments, message in (
                ("'f 0", "requires three arguments"),
                ("'f 0 '() 1", "requires three arguments"),
                ("'f 0 42", "requires a list"),
                ("'f 0 'word", "requires a list"),
                *((f"{head} 0 '()", "requires a callable name")
                  for head in ("42", "1.0", '"f"', "#\\a", "true", "false", "unit", "nil", "'(f)")),
            ):
                with self.subTest(operation=operation, arguments=arguments):
                    result = self.run_core("check", f"""
(%macro answer () ({operation} {arguments}))
(%function main () i64 (answer))
""")
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)
            # A shallow helper chain performs many folds without hitting the
            # evaluator depth limit first. Discard results to keep syntax shallow.
            items = " ".join("0" for _ in range(1000))
            source = f"(%macro batch () (let ((values '({items}))) ({operation} 'f 0 values) 0))\n"
            for level in range(7):
                previous = "batch" if level == 0 else f"batch{level - 1}"
                source += f"(%macro batch{level} () (let ((a ({previous})) (b ({previous}))) 0))\n"
            result = self.run_core("check", source + "(%function main () i64 (batch6))")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("compile-time evaluation step limit exceeded", result.stderr)

    def test_expression_macro_modules_and_base(self):
        (self.root / "macros.vrn").write_text("""
(%export select)
(%macro helper (form) `(car (list ,form)))
(%macro select (form) (helper form))
""")
        self.agrees("""
(%import macros :as m)
(%function main () i64 (m:select 42))
""", 42)
        base = Path(__file__).resolve().parents[1] / "projects/base/src"
        self.agrees("""
(%macro identity (form) form)
(%generic add (left right))
(%implementation add ((left u8) (right u8)) u8 (%+-primitive-u8 left right))
(%implementation add ((left i64) (right i64)) i64 (%+-primitive-i64 left right))
(%function main () i64 (%zext-primitive-u8-i64 (add (cast u8 40) (identity 2))))
""", 42)
        self.agrees("""
(import base :as b)
(%function main () i64
  (b:cond (false (%/-primitive-i64 1 0))
    ((b:and-then true (b:or false true)) (cast i64 40) (cast i64 42))
    (true 0)))
""", 42, "--module-path", base)
        self.agrees("""
(import base :as b)
(%function mark ((counter (pointer i64)) (value bool)) bool
  (do (store (deref counter) (%+-primitive-i64 (deref counter) 1)) value))
(%function main () i64
  (let ((counter i64 0))
    (b:and (mark (& counter) false) (mark (& counter) true))
    (b:or (mark (& counter) true) (mark (& counter) false))
    (b:and-then false (mark (& counter) true))
    (b:or-else true (mark (& counter) false))
    counter))
""", 4, "--module-path", base)

    def test_expression_macro_errors_and_limits(self):
        for source, message in (
            ("(%macro identity (x) x)(%function main () i64 (identity))", "missing macro argument"),
            ("(%macro value () (car 42))(%function main () i64 (value))", "requires a list"),
            ("(%macro value () (empty?))(%function main () i64 (value))", "requires one argument"),
            ("(%macro value () (equal? 1))(%function main () i64 (value))", "requires two arguments"),
            ("(%macro value () (cond (1 42)))(%function main () i64 (value))", "requires a boolean"),
            ("(%macro value () (cond (true 42) (false)))(%function main () i64 (value))", "require a test and body"),
            ("(%macro value () (let ((x 1) (x 2)) x))(%function main () i64 (value))", "duplicate or reserved"),
            ("(%macro value () (let ((nil 1)) nil))(%function main () i64 (value))", "duplicate or reserved"),
            ("(%macro loop () `(loop))(%function main () i64 (loop))", "macro expansion limit exceeded"),
            ("(%macro loop () (loop))(%function main () i64 (loop))", "compile-time evaluation depth limit exceeded"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_macro_definition_batches(self):
        self.agrees("""
(%macro skip () `())
(%macro batch ()
  `((%macro emit-helper () `(%function helper () i64 40))
    (emit-helper)
    (%function offset () i64 2)))
(skip)
(batch)
(%function main () i64 (%+-primitive-i64 (helper) (offset)))
""", 42)
        self.agrees("""
(%macro batch ()
  `((%macro result () `(%function main () i64 0))))
(batch)
(%macro result () `(%function main () i64 42))
(result)
""", 42)
        for source, message in (
            ("(%macro bad () '((%function main () i64 42) 7))(bad)",
             "expected a flat list of top-level forms"),
            ("(%macro bad () '(((%function main () i64 42))))(bad)",
             "expected a flat list of top-level forms"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_repeated_macro_templates_fit_syntax_budget(self):
        body = "0"
        for _ in range(12):
            body = f"(%+-primitive-i64 1 {body})"
        template = f"(%macro define (name) `(%function ,name () i64 {body}))"
        calls = "\n".join(f"(define helper{i})" for i in range(130))
        result = self.run_core("check", f"{template}\n{calls}\n{self.program('(helper0)')}")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_macro_symbol_concat(self):
        self.agrees("""
(%macro arithmetic (type)
  `((%function ,(symbol-concat "compute-" type) () ,type
      (,(symbol-concat "%+-primitive-" type) 40 2))
    (%function main () ,type (,(symbol-concat "compute-" type)))))
(arithmetic i64)
""", 42)
        self.agrees("""
(%macro arithmetic ()
  `(%function ,(symbol-concat (symbol-concat "ma") 'in) () i64 42))
(arithmetic)
""", 42)
        for args, message in (
            ("", "requires at least one component"),
            (' "" ""', "cannot construct an empty name"),
            (" 42", "requires data or symbols"),
            (" 'base:function", "requires data or symbols"),
        ):
            with self.subTest(args=args):
                result = self.run_core("check", f"(%macro bad () (symbol-concat{args}))(bad)")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_macro_result_context_is_per_invocation(self):
        (self.root / "defaults.vrn").write_text(
            "(%export value)(%function value () i64 99)"
        )
        definitions = self.root / "definitions.vrn"
        definitions.write_text("""(%import defaults :as lib)
(%export define)
(%macro define (name expression)
  `(%function ,name () i64 (%+-primitive-i64 (lib:value) ,expression)))
""")
        for module, value in (("left", 39), ("right", 1)):
            (self.root / f"{module}_values.vrn").write_text(
                f"(%export value extra)(%function value () i64 {value})"
                "(%function extra () i64 1)"
            )
            (self.root / f"{module}.vrn").write_text(f"""
(%import definitions :as m)
(%import {module}_values :as lib)
(%export answer)
(m:define answer (lib:extra))
""")
        self.agrees("""
(%import left)
(%import right)
(%function main () i64 (%+-primitive-i64 (left:answer) (right:answer)))
""", 42)
        checked = self.run_core("check", """
(%import definitions :as m)
(m:define main (cast i64 0))
""")
        self.assertEqual(checked.returncode, 2, checked.stderr)
        self.assertIn("missing import", checked.stderr)
        self.assertIn(f"{definitions}:4:", checked.stderr)

    def test_generated_macro_names_resolve_in_invocation_module(self):
        (self.root / "types.vrn").write_text("(%export Scalar)(%type Scalar i8)")
        (self.root / "caller_types.vrn").write_text("(%export Scalar)(%type Scalar i64)")
        (self.root / "macros.vrn").write_text("""
(%import types :as lib)
(%export define emit)
(%macro emit (generated caller-type)
  `(%function ,(symbol-concat "get-" generated)
     ((box ,generated) (value ,caller-type)) lib:Scalar
     (%+-primitive-i64 (field box value) value)))
(%macro define (prefix caller-type)
  `((%type ,(symbol-concat prefix "-box") (product (value lib:Scalar)))
    (m:emit ,(symbol-concat prefix "-box") ,caller-type)))
""")
        self.agrees("""
(%import macros :as m)
(%import caller_types :as lib)
(%type Local i64)
(m:define answer Local)
(%function main () i64 (get-answer-box (answer-box 40) 2))
""", 42)

    def test_local_binding_names_follow_reference_compiler(self):
        self.agrees("""
(%macro define ()
  `(%function main () i64
    (let ((,(symbol-concat "true") i64 40)
          (,(symbol-concat "false") i64 1)
          (,(symbol-concat "unit") i64 1))
      (%+-primitive-i64 ,(symbol-concat "true")
        (%+-primitive-i64 ,(symbol-concat "false") ,(symbol-concat "unit"))))))
(define)
""", 42)
        self.agrees("""
(%function read ((tuple i64) (function i64) (cast i64) (i64 i64)) i64
  (%+-primitive-i64 tuple (%+-primitive-i64 function (%+-primitive-i64 cast i64))))
(%function main () i64
  (let ((if i64 10) (let i64 20) (void i64 5) (bool i64 7))
    (read if let void bool)))
""", 42)
        self.agrees("""
(%type Result (sum (Value i64 i64)))
(%function main () i64
  (let ((tuple i64 40) (cast i64 99))
    (match (Value tuple (tuple-get (tuple cast (cast i64 2)) 1))
      ((Value function i64) (%+-primitive-i64 function i64)))))
""", 42)
        names = (
            "if", "let", "function", "void", "bool", "cast", "tuple", "tuple-get",
            "field", "match", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64",
            "f32", "f64", "+", ":local",
        )
        for name in names:
            with self.subTest(name=name):
                source = f"(%function read (({name} i64)) i64 {name})" + self.program("(read 42)")
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_invalid_local_binding_names_and_duplicates(self):
        for name in ("42", "1.5", "true", "false", "unit", '"name"', "#\\a", "lib:name", "(name)"):
            for declaration in (
                f"(%function bad (({name} i64)) i64 0)",
                f"(%function bad () i64 (let (({name} i64 1)) 0))",
            ):
                with self.subTest(name=name, declaration=declaration):
                    checked = self.run_core("check", declaration + self.program("0"))
                    self.assertEqual(checked.returncode, 2, checked.stderr)
                    self.assertIn("expected identifier for local binding", checked.stderr)
        for source, message in (
            ("(%function bad ((tuple i64) (tuple i64)) i64 tuple)", "duplicate parameter"),
            ("(%function bad () i64 (let ((cast i64 1) (cast i64 2)) cast))", "duplicate local binding"),
            ("(%type S (sum (Value i64 i64)))(%function bad ((s S)) i64 (match s ((Value function function) function)))", "duplicate payload binding"),
        ):
            checked = self.run_core("check", source + self.program("0"))
            self.assertEqual(checked.returncode, 2, checked.stderr)
            self.assertIn(message, checked.stderr)

    def test_product_field_labels(self):
        self.agrees("""
(%type Frame (product (function i64) (+ i64)))
(%function main () i64
  (let ((frame (Frame 40 2)))
    (%+-primitive-i64 (field frame function) (field frame +))))
""", 42)
        for label in ("42", "1.5", "true", "unit", "lib:field", '"field"'):
            with self.subTest(label=label):
                for source in (
                    f"(%type Frame (product ({label} i64)))",
                    f"(%type Frame (product (x i64)))(%function main () i64 (field (Frame 42) {label}))",
                ):
                    result = self.run_core("check", source)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("expected product field name", result.stderr)

    def test_scalar_match_patterns(self):
        self.agrees("""
(%function choose ((flag bool)) i64
  (match flag (true 42) (false (%/-primitive-i64 1 0))))
(%function main () i64 (choose true))
""", 42)
        self.agrees(self.program("(match false (false 42) (true (%/-primitive-i64 1 0)))"), 42)
        # The reference accepts a trailing catch-all after both boolean literals.
        self.agrees(self.program("(match true (true 42) (false 0) (_ 1))"), 42)
        for ty, literal in (
            ("i8", "-128"), ("i16", "-32768"), ("i32", "-2147483648"),
            ("i64", "-9223372036854775808"), ("u8", "255"), ("u16", "65535"),
            ("u32", "4294967295"), ("u64", "18446744073709551615"),
        ):
            with self.subTest(ty=ty):
                self.agrees(self.program(f"(match (cast {ty} {literal}) ({literal} 42) (_ 0))"), 42)
        self.agrees(self.program(r"(match (cast i32 65) (#\A 42) (_ 0))"), 42)
        self.agrees(self.program(r"(match #\a (97 42) (_ 0))"), 42)
        self.agrees(self.program(r"(match #\Newline (#\newline 42) (_ 0))"), 42)

    def test_do_and_multiple_expression_let_bodies(self):
        self.agrees(self.program("(do (cast i64 1) (%+-primitive-i64 1 2) 42)"), 42)
        self.agrees(self.program('(do (tuple (cast i64 1) true) (array-of (cast i64 2)) "discard" (cast f64 1.5) 42)'), 42)
        self.agrees(self.program("(do (do) (do (cast i64 1) (do)) 42)"), 42)
        self.agrees("""
(%function main () i64
  (let ((value i64 40) (other i64 (%+-primitive-i64 value 1)))
    (let ((value i64 99)) value value)
    (tuple value other)
    (%+-primitive-i64 value 2)))
""", 42)
        self.agrees(self.program("(let () (cast i64 1) (do) 42)"), 42)
        self.agrees(self.program("(let ((empty unit (do))) 42)"), 42)
        for source in ("(%function main () unit (do))", "(%function main () unit (do (cast i64 1) unit))"):
            evaluated = self.run_core("eval", source)
            self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
            self.assertEqual(evaluated.stdout, "unit\n")
            for level in ("-O0", "-O2"):
                binary = self.root / "unit sequence"
                compiled = self.run_core("compile-report", source, "-o", binary, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)
                self.assertEqual(native.stdout, "unit\n")

    def test_tuple_patterns(self):
        self.agrees("""
(%function choose ((value (tuple bool i64))) i64
  (match value ((tuple false _) 0) ((tuple ok total) (if ok total 1))))
(%function main () i64 (choose (tuple true (cast i64 42))))
""", 42)
        self.agrees("""
(%function choose ((value (tuple u8 bool i64))) i64
  (match value
    ((tuple #\\a true _) 1)
    ((tuple 97 false result) result)
    ((tuple _ _ _) 0)))
(%function main () i64 (choose (tuple #\\a false (cast i64 42))))
""", 42)
        self.agrees("""
(%function choose ((value (tuple i64 bool))) i64
  (match value ((tuple 0 true) 1) (whole (tuple-get whole 0))))
(%function main () i64 (choose (tuple (cast i64 42) false)))
""", 42)
        self.agrees(self.program('(match (tuple) ((tuple) 42))'), 42)
        # The reference permits a whole-value fallback after a complete tuple pattern.
        self.agrees(self.program('(match (tuple true) ((tuple _) 42) (_ 0))'), 42)
        self.agrees("""
(%function make ((counter (pointer i64))) (tuple i64)
  (do (store (deref counter) (%+-primitive-i64 (deref counter) 1)) (tuple (cast i64 42))))
(%function main () i64
  (let ((counter i64 0))
    (match (make (& counter)) ((tuple 0) 0) ((tuple answer) (%*-primitive-i64 answer counter)))))
""", 42)

    def test_sum_component_patterns(self):
        for argument, expected in (("(Some 0)", 10), ("(Some 42)", 42), ("(None)", 0)):
            self.agrees(f"""
(%type Option (sum (Some i64) (None)))
(%function choose ((value Option)) i64
  (match value ((Some 0) 10) ((Some x) x) ((None) 0)))
(%function main () i64 (choose {argument}))
""", expected)
        self.agrees("""
(%type Result (sum (Pair bool u8 i64) (Empty)))
(%function choose ((value Result)) i64
  (match value ((Pair true #\\a _) 1) ((Pair false 97 result) result)
    ((Pair _ _ _) 0) ((Empty) 0)))
(%function main () i64 (choose (Pair false #\\a 42)))
""", 42)

    def test_structured_pattern_errors(self):
        for source, message in (
            ('(%function main () i64 (match (tuple true) ((tuple true) 1) ((tuple false) 2)))', 'non-exhaustive match'),
            ('(%function main () i64 (match (tuple true) ((tuple _) 1) ((tuple false) 2)))', 'unreachable tuple pattern'),
            ('(%function main () i64 (match (tuple true) (_ 1) ((tuple false) 2)))', 'unreachable match arm'),
            ('(%function main () i64 (match (tuple true) ((tuple a b) 1)))', 'too many pattern components'),
            ('(%function main () i64 (match (tuple true) ((tuple) 1)))', 'too few pattern components'),
            ('(%function main () i64 (match (tuple true false) ((tuple x x) 1)))', 'duplicate payload binding'),
            ('(%function main () i64 (match (tuple true) ((tuple 0) 1) (_ 2)))', 'integer pattern requires'),
            ('(%function main () i64 (match (tuple (cast u8 0)) ((tuple 256) 1) (_ 2)))', 'out of range'),
            ('(%function main () i64 (match (tuple (tuple true)) ((tuple (tuple x)) 1)))', 'nested structured patterns'),
            ('(%function main () i64 (match (tuple true) ((tuple false) 1) ((tuple _) missing)))', 'unknown local name'),
            ('(%type S (sum (Some i64)))(%function main () i64 (match (Some 0) ((Some 0) 1)))', 'non-exhaustive match'),
            ('(%type S (sum (Some i64)))(%function main () i64 (match (Some 0) ((Some _) 1) ((Some 0) 2)))', 'duplicate match case'),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_addressable_storage_and_aliases(self):
        self.agrees("""
(%function update ((value i64)) i64 (do (store value 40) (assign value (%+-primitive-i64 value 2)) value))
(%function main () i64 (update 1))
""", 42)
        self.agrees("""
(%function main () i64
  (let ((value i64 40) (first (& value)) (second first))
    (store (dereference second) (%+-primitive-i64 (deref first) 2))
    value))
""", 42)
        self.agrees("""
(%function increment ((pointer (pointer i64))) unit
  (store (deref pointer) (%+-primitive-i64 (deref pointer) 2)))
(%function main () i64
  (let ((value i64 40)) (increment (address-of value)) value))
""", 42)
        self.agrees("""
(%type Record (product (value i32) (flag bool)))
(%function update ((record Record)) i64
  (do (store (field record value) 40) (store (field record flag) true)
    (let ((pointer (& (field record value))))
      (store (deref pointer) (%+-primitive-i32 (deref pointer) 2))
      (if (field record flag) (%sext-primitive-i32-i64 (field record value)) 0))))
(%function main () i64 (update (Record 1 false)))
""", 42)
        self.agrees("""
(%function update ((value (tuple i64 bool))) i64
  (do (store (tuple-get value 0) 42) (store (tuple-get value 1) true)
    (if (tuple-get value 1) (tuple-get value 0) 0)))
(%function main () i64 (update (tuple (cast i64 0) false)))
""", 42)
        self.agrees("""
(%function main () i64
  (let ((values (array-of (cast i64 10) 20 30)) (middle (& (index values 1))))
    (store (deref (pointer-offset middle (cast i16 -1))) 40)
    (store (deref (pointer-offset middle (cast u8 1))) 2)
    (%+-primitive-i64 (index values 0) (index values 2))))
""", 42)
        self.agrees("""
(%function update ((values (array i64 2)) (index u64)) i64
  (do (store (index values index) 42) (index values index)))
(%function main () i64 (update (array-of 1 2) 1))
""", 42)

    def test_pointer_memory_layout_and_data(self):
        self.agrees("""
(%type Record (product (flag bool) (value f32) (bytes (array u8 2))))
(%function main () i64
  (let ((record (Record false 1.5 (array-of (cast u8 1) 2))) (pointer (& record))
        (snapshot record))
    (store (field (deref pointer) flag) true)
    (store (field (deref pointer) value) 40.0)
    (store (index (field (deref pointer) bytes) 1) 2)
    (if (field snapshot flag) 0
      (%+-primitive-i64 (%fptosi-primitive-f32-i64 (field record value))
        (%zext-primitive-u8-i64 (index (field record bytes) 1))))))
""", 42)
        self.agrees("""
(%function main () i64
  (let ((value i64 0) (pointer (& value)) (indirect (& pointer)))
    (store (deref (deref indirect)) 42)
    value))
""", 42)
        self.agrees("""
(%type Value (sum (Integer i64) (Real f64)))
(%function main () i64
  (let ((value (Integer (cast i64 1))) (pointer (& value)))
    (store (deref pointer) (Real 42.5))
    (match value ((Integer x) x) ((Real x) (%fptosi-primitive-f64-i64 x)))))
""", 42)
        self.agrees("""
(%type Node (product (next (pointer Node)) (value i64)))
(%function main () i64
  (let ((node (Node (cast (pointer Node) (cast (pointer void) "")) 42)) (pointer (& node)))
    (store (field (deref pointer) next) pointer)
    (field (deref (field (deref pointer) next)) value)))
""", 42)
        self.agrees(self.program('(%zext-primitive-u8-i64 (deref (pointer-offset "abc" 2)))'), 99)
        for source, expected in (
            ('(%function main () (pointer u8) (pointer-offset "hello" 1))', "data:4:ello\n"),
            ('(%function suffix () (pointer u8) (pointer-offset "hello" 5))(%function main () (pointer u8) (suffix))', "data:0:\n"),
        ):
            evaluated = self.run_core("eval", source)
            self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
            self.assertEqual(evaluated.stdout, expected)
            for level in ("-O0", "-O2"):
                binary = self.root / "data pointer executable"
                compiled = self.run_core("compile-report", source, "-o", binary, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)
                self.assertEqual(native.stdout, expected)

    def test_invalid_places(self):
        for expression, message in (
            ("(let ((value i64 1)) (store value 2))", "not writable"),
            ("(let ((value (array-of (cast i64 1)))) (store (index value 0) 2))", "not writable"),
            ("(& (cast i64 1))", "not addressable"),
            ("(deref (cast i64 1))", "requires a pointer"),
            ('(deref (cast (pointer void) ""))', "complete object type"),
            ('(pointer-offset (cast (pointer void) "") 1)', "complete object type"),
            ('(pointer-offset "abc" true)', "integer offset"),
            ('(store (deref "abc") 256)', "out of range"),
            ("(&)", "exactly one"),
            ("(deref)", "exactly one"),
            ("(store)", "target and a value"),
            ("(pointer-offset)", "pointer and an integer"),
        ):
            with self.subTest(expression=expression):
                checked = self.run_core("check", self.program(f"(do {expression} 42)"))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_managed_pointer_failures(self):
        for source, message in (
            ('(store (deref "abc") #\\z)', "read-only"),
            ('(deref (pointer-offset "abc" 4))', "invalid pointer"),
            ('(pointer-offset "abc" -1)', "invalid pointer"),
            ("(let ((value (cast i64 1))) (deref (pointer-offset (& value) 1)))", "invalid pointer"),
            ('(deref (cast (pointer i64) (cast (pointer void) (pointer-offset "0123456789" 1))))', "invalid pointer"),
            ('(pointer-offset "abc" (cast u64 18446744073709551615))', "invalid pointer"),
        ):
            with self.subTest(source=source):
                evaluated = self.run_core("eval", self.program(f"(do {source} 42)"))
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn(message, evaluated.stderr)
        escaped = """
(%function escape () (pointer i64) (let ((value i64 1)) (& value)))
(%function main () i64 (deref (escape)))
"""
        evaluated = self.run_core("eval", escaped)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("expired storage", evaluated.stderr)

    def test_sequence_static_checks(self):
        for expression, message in (
            ("(do 1 42)", "ambiguous numeric literal"),
            ("(let () 1 42)", "ambiguous numeric literal"),
            ("(do (cast i64 1) missing 42)", "unknown local name"),
            ("(do (%/-primitive-i64 1 0) missing)", "unknown local name"),
            ("(let () (let ((hidden i64 1)) hidden) hidden)", "unknown local name"),
            ("(do)", "type mismatch"),
            ("(let ())", "let requires bindings and a body"),
            ("(let)", "let requires bindings and a body"),
            ("(let true (cast i64 1) 42)", "expected binding list"),
        ):
            with self.subTest(expression=expression):
                checked = self.run_core("check", self.program(expression))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_sequence_runtime_failure_order(self):
        for expression in (
            "(do (%/-primitive-i64 1 0) (%/-primitive-i64 -9223372036854775808 -1))",
            "(let ((value i64 1)) (%/-primitive-i64 value 0) 42)",
        ):
            with self.subTest(expression=expression):
                source = self.program(expression)
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn("division by zero", evaluated.stderr)
                self.assertNotIn("signed division overflow", evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "failing sequence"
                    compiled = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertIn("division by zero", native.stderr)
                    self.assertNotIn("signed division overflow", native.stderr)

    def test_match_catch_all_bindings(self):
        self.agrees(self.program("(match (cast i64 42) (value value))"), 42)
        self.agrees("""
(%type S (sum (Value i64) (Empty)))
(%function main () i64
  (let ((value i64 40))
    (%+-primitive-i64 value
      (match (Value 2)
        (value (match value ((Value x) x) ((Empty) 0)))))))
""", 42)
        self.agrees(self.program("(match (cast f64 42.5) (value (%fptosi-primitive-f64-i64 value)))"), 42)
        self.agrees(self.program("(match unit (_ 42))"), 42)
        self.agrees("""
(%type P (product (value i64)))
(%function main () i64 (match (P 42) (value (field value value))))
""", 42)
        self.agrees(self.program("(match (tuple (cast i64 42)) (value (tuple-get value 0)))"), 42)
        self.agrees(self.program("(match (array-of (cast i64 42)) (value (index value 0)))"), 42)
        self.agrees("""
(%macro define ()
  `(%function main () i64
    (match (cast i64 42)
      (,(symbol-concat "true") ,(symbol-concat "true")))))
(define)
""", 42)

    def test_invalid_scalar_matches(self):
        for source, message in (
            ("(match true (true 1))", "non-exhaustive match"),
            ("(match (cast i8 1) (1 42))", "non-exhaustive match"),
            ("(match true (true 1) (true 2) (false 3))", "duplicate match pattern"),
            ("(match (cast i64 1) (1 1) (+1 2) (_ 3))", "duplicate match pattern"),
            (r"(match (cast i32 65) (#\A 1) (65 2) (_ 3))", "duplicate match pattern"),
            ("(match true (_ 1) (false 2))", "unreachable match arm"),
            ("(match (cast i64 1) (value value) (_ 2))", "unreachable match arm"),
            ("(match (cast u8 1) (256 42) (_ 0))", "out of range"),
            ("(match (cast i8 1) (-129 42) (_ 0))", "out of range"),
            ("(match true (1 42) (_ 0))", "integer pattern requires an integer"),
            ("(match (cast i64 1) (true 42) (_ 0))", "boolean pattern requires a boolean"),
            (r"(match true (#\A 42) (_ 0))", "character pattern requires an integer"),
            ("(match (cast f64 1.5) (1.5 42) (_ 0))", "expected boolean, integer, character"),
            ("(match unit (unit 42) (_ 0))", "expected boolean, integer, character"),
            ("(match true (true 42) (false false))", "type mismatch"),
            ("(match true)", "match requires arms"),
            ("(match true (true 1 2) (false 0))", "match arm requires pattern and body"),
            ("(let ((value (match true (name name)))) name)", "unknown local name"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", self.program(source))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_top_level_constants(self):
        (self.root / "constants.vrn").write_text("""
(%export answer)
(%constant answer i64 40)
(%constant hidden i64 99)
""")
        self.agrees("""
(%import constants :as values)
(%function read () i64 later)
(%constant later i64 2)
(%constant main-value i64 1)
(%function main () i64
  (let ((main-value (cast i64 0)))
    (%+-primitive-i64 values:answer (%+-primitive-i64 (read) main-value))))
""", 42)
        source = r"""
(%type Count u64)
(%constant signed i8 -128)
(%constant unsigned Count 18446744073709551615)
(%constant real32 f32 1.5)
(%constant real64 f64 -0.0)
(%constant flag bool true)
(%constant nothing unit unit)
(%constant character u8 #\Newline)
(%constant text (pointer u8) "hi\n")
(%constant empty (pointer u8) "")
(%constant explicit i16 (cast i16 42))
(%function main () (tuple i8 Count f32 f64 bool unit u8 (pointer u8) (pointer u8) i16)
  (tuple signed unsigned real32 real64 flag nothing character text empty explicit))
"""
        expected = (
            "tuple(i8:-128,u64:18446744073709551615,f32:1069547520,"
            "f64:9223372036854775808,bool:1,unit,u8:10,data:3:hi\n,data:0:,i16:42)\n"
        )
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, expected)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"internal constant i8 -128")
        self.assertRegex(emitted.stdout, r"internal constant ptr @data")
        for level in ("-O0", "-O2"):
            binary = self.root / "constants executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, expected)

    def test_mutable_globals(self):
        base = Path(__file__).resolve().parents[1] / "projects/base/src"
        self.agrees("""
(import base :as b)
(b:function address () (pointer i64) (& counter))
(b:function bump () unit (assign counter (+ counter 1)))
(b:function shadow ((counter i64)) i64 (do (assign counter 99) counter))
(b:variable counter i64 40)
(b:function main () i64
  (do
    (bump)
    (store (deref (address)) (+ (deref (address)) 1))
    (let ((counter i64 0)) (shadow counter))
    counter))
""", 42, "--module-path", base)
        # Writes through returned pointers must outlive the returning frame.
        self.agrees("""
(%function address () (pointer bool) (& flag))
(%variable flag bool true)
(%function main () i64
  (do (store (deref (address)) false) (if flag 0 42)))
""", 42)
        self.agrees("""
(%variable text (pointer u8) "old")
(%function replace () unit (store text "*"))
(%function main () i64 (do (replace) (%zext-primitive-u8-i64 (deref text))))
""", 42)
        self.agrees("""
(%variable counter i64 40)
(%function bump (for (T)) ((ignored T)) unit
  (store counter (%+-primitive-i64 counter 1)))
(%function main () i64
  (do (bump (cast i8 0)) (bump (cast f64 0.0)) counter))
""", 42)
        source = r"""
(%type Count u64)
(%variable signed i8 -128)
(%variable unsigned Count 18446744073709551615)
(%variable real32 f32 1.5)
(%variable real64 f64 -0.0)
(%variable flag bool true)
(%variable nothing unit unit)
(%variable character u8 #\Newline)
(%variable text (pointer u8) "hi\n")
(%function main () (tuple i8 Count f32 f64 bool unit u8 (pointer u8))
  (tuple signed unsigned real32 real64 flag nothing character text))
"""
        expected = ("tuple(i8:-128,u64:18446744073709551615,f32:1069547520,"
                    "f64:9223372036854775808,bool:1,unit,u8:10,data:3:hi\n)\n")
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, expected)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"internal global i8 -128")
        self.assertRegex(emitted.stdout, r"internal global i8 1")
        self.assertRegex(emitted.stdout, r"internal global ptr @data")
        for level in ("-O0", "-O2"):
            binary = self.root / "globals executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, expected)

    def test_global_modules(self):
        (self.root / "state.vrn").write_text("""
(%variable counter i64 1)
(%variable hidden i64 99)
(%function bump () unit (store counter (%+-primitive-i64 counter 1)))
(%export counter bump)
""")
        self.agrees("""
(%import state :as s)
(%import state :as other)
(%variable counter i64 40)
(%function main () i64
  (do
    (store s:counter counter)
    (s:bump)
    (store (deref (& other:counter)) (%+-primitive-i64 s:counter 1))
    (if (%=-primitive-i64 (let ((counter i64 99)) counter) 99) other:counter 0)))
""", 42)
        result = self.run_core("check", """
(%import state :as s)
(%function main () i64 s:hidden)
""")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("private declaration access", result.stderr)

    def test_global_storage_at_c_boundary(self):
        source = self.root / "global storage.c"
        source.write_text("#include <stdbool.h>\n#include <stdint.h>\n"
                          "void change(bool *flag, uint8_t *byte, double *value) { "
                          "*flag = true; *byte = 42; *value = 1.5; }\n")
        obj = self.root / "global storage.o"
        subprocess.run(["clang", "-c", str(source), "-o", str(obj)], check=True, capture_output=True)
        # A wrapper supplies the extra C object without changing the compiler CLI.
        wrapper = self.root / "link globals"
        wrapper.write_text(f"#!{sys.executable}\nimport os,sys\n"
                           f"os.execvp('clang', ['clang', *sys.argv[1:], {str(obj)!r}])\n")
        wrapper.chmod(0o755)
        program = """
(%variable flag bool false)
(%variable byte u8 0)
(%variable value f64 0.0)
(%external-function change "change" ((pointer bool) (pointer u8) (pointer f64)) void)
(%function main () i64
  (do (change (& flag) (& byte) (& value))
      (if flag (if (== value 1.5) (%zext-primitive-u8-i64 byte) 0) 0)))
"""
        binary = self.root / "C global executable"
        result = self.run_core("compile-report", program, "-o", binary,
                               env=dict(os.environ, VERONA_CORE_CLANG=str(wrapper)))
        self.assertEqual(result.returncode, 0, result.stderr)
        executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(executed.returncode, 0, executed.stderr)
        self.assertEqual(executed.stdout, "i64:42\n")

    def test_invalid_global_declarations(self):
        for source, message in (
            ("(%variable value i64)", "%variable requires a name, type, and initializer"),
            ("(%variable value i64 1 2)", "%variable requires a name, type, and initializer"),
            ("(%variable value i64 1)(%variable value i64 2)", "duplicate variable"),
            ("(%variable value i64 1)(%function value () i64 2)", "duplicate function"),
            ("(%function value () i64 1)(%variable value i64 2)", "duplicate variable"),
            ("(%constant value i64 1)(%variable value i64 2)", "duplicate variable"),
            ("(%variable value i64 1)(%constant value i64 2)", "duplicate constant"),
            ("(%type Value i64)(%variable Value i64 1)", "variable conflicts with type"),
            ("(%type T (sum (Case)))(%variable Case i64 1)", "variable conflicts with sum"),
            ("(%variable value i64 true)", "type mismatch"),
            ("(%variable value u8 256)", "out of range"),
            ("(%variable value i64 (%+-primitive-i64 1 2))", "initializer must be"),
            ("(%variable first i64 1)(%variable second i64 first)", "initializer must be"),
            ("(%variable value i64 value)", "initializer must be"),
            ("(%variable value (tuple i64) (tuple 1))", "aggregate variables"),
            ("(%variable value (array i64 1) (array-of 1))", "aggregate variables"),
            ("(%variable value i64 1)(%function use () i64 (value))", "variable value is not callable"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source + self.program("0"))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_invalid_constant_declarations(self):
        (self.root / "constants.vrn").write_text("(%constant hidden i64 1)")
        for source, message in (
            ("(%constant value i64)", "%constant requires a name, type, and value"),
            ("(%constant value i64 1 2)", "%constant requires a name, type, and value"),
            ("(%constant value i64 1)(%constant value i64 2)", "duplicate constant"),
            ("(%constant value i64 1)(%function value () i64 2)", "duplicate function"),
            ("(%function value () i64 1)(%constant value i64 2)", "duplicate constant"),
            ("(%type Value i64)(%constant Value i64 1)", "constant conflicts with type"),
            ("(%type Value (sum (Case)))(%constant Case i64 1)", "constant conflicts with sum"),
            ("(%constant value i64 true)", "type mismatch"),
            ("(%constant value u8 256)", "out of range"),
            ("(%constant value i64 (%+-primitive-i64 1 2))", "initializer must be"),
            ("(%constant first i64 1)(%constant second i64 first)", "initializer must be"),
            ("(%constant value (tuple i64) (tuple 1))", "aggregate constants"),
            ("(%constant value i64 1)(%function use () i64 (value))", "constant value is not callable"),
            ("(%import constants :as c)(%function use () i64 c:hidden)", "private declaration access"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source + self.program("0"))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_external_functions_and_native_aggregate_layouts(self):
        fixture = Path(__file__).with_name("external.c")
        obj = self.root / "external fixture.o"
        built = subprocess.run(["clang", "-std=c11", "-O2", "-c", str(fixture), "-o", str(obj)],
                               capture_output=True, text=True, timeout=30)
        self.assertEqual(built.returncode, 0, built.stderr)
        linker = self.root / "fixture linker"
        linker.write_text(f"#!/bin/sh\nexec clang \"$@\" {shlex.quote(str(obj))}\n")
        linker.chmod(0o755)
        environment = dict(os.environ, VERONA_CORE_CLANG=str(linker))
        declarations = """
(%type Record (product (value i32) (flag bool)))
(%type Floats (product (x f32) (y f32)))
(%type Quad (product (a f64) (b f64) (c f64) (d f64)))
(%type FloatArray (array f32 3))
(%type Mixed (product (x f64) (y i64)))
(%type Large (product (elements (array i64 3))))
(%type Array3 (array i16 3))
(%type Choice (sum (Small u8 bool) (Real f64) (Wrapped Record)))
(%type Nested (product (record Record) (array Array3) (flag bool)))
(%type Empty (product))
(%type BigChoice (sum (Big Large) (Nothing)))
(%type RecordCallback (pointer (function (Record) Record)))
(%type LargeCallback (pointer (function (Large) Large)))
(%type ChoiceCallback (pointer (function (Choice) Choice)))
(%type BoolCallback (pointer (function (bool) bool)))
(%external-function record "fixture_record" (Record) Record)
(%external-function mutate-record "fixture_mutate_record" ((pointer Record)) i64)
(%external-function floats "fixture_floats" (Floats) Floats)
(%external-function quad "fixture_quad" (Quad) Quad)
(%external-function float-array "fixture_float_array" (FloatArray) FloatArray)
(%external-function float "fixture_float" (f64 f32) f64)
(%external-function big-choice "fixture_big_choice" (BigChoice) BigChoice)
(%external-function quad-callback "fixture_quad_callback" ((pointer (function (Quad) Quad)) Quad) Quad)
(%external-function mixed "fixture_mixed" (Mixed) Mixed)
(%external-function large "fixture_large" (Large) Large)
(%external-function array "fixture_array" (Array3) Array3)
(%external-function choice "fixture_choice" (Choice) Choice)
(%external-function nested "fixture_nested" (Nested) Nested)
(%external-function narrow "fixture_narrow" (i8 i16 u8 u16) i8)
(%external-function record-callback "fixture_record_callback" (RecordCallback Record) Record)
(%external-function large-callback "fixture_large_callback" (LargeCallback Large) Large)
(%external-function choice-callback "fixture_choice_callback" (ChoiceCallback Choice) Choice)
(%external-function bool-callback "fixture_bool_callback" (BoolCallback bool) bool)
(%external-function get-record "fixture_get_record" () RecordCallback)
(%external-function crowded "fixture_crowded" (i64 i64 i64 i64 i64 i64 Record) Record)
(%external-function empty "fixture_empty" (Empty) Empty)
(%external-function match-next "fixture_match_next" () i64)
(%external-function match-count "fixture_match_count" () i64)
(%external-function sequence-step "fixture_sequence_step" (i64) i64)
(%external-function sequence-trace "fixture_sequence_trace" () i64)
(%function bump ((value Record)) Record
  (Record (%+-primitive-i32 (field value value) 1) true))
(%function bump-large ((value Large)) Large
  (Large (array-of (%+-primitive-i64 (index (field value elements) 0) 1)
                   (index (field value elements) 1) (index (field value elements) 2))))
(%function bump-choice ((value Choice)) Choice
  (match value ((Small x flag) (Real 42.5)) ((Real x) (Wrapped (Record 42 true)))
               ((Wrapped x) (Small 42 true))))
(%function invert ((value bool)) bool (if value false true))
(%function bump-quad ((value Quad)) Quad
  (Quad (%+-primitive-f64 (field value a) 1.0) (field value b) (field value c) (field value d)))
"""
        cases = (
            ("(let ((r (record (Record 40 false)))) (if (field r flag) (%sext-primitive-i32-i64 (field r value)) 0))", 42),
            ("(let ((r (Record 40 false))) (mutate-record (& r)) (if (field r flag) (%sext-primitive-i32-i64 (field r value)) 0))", 42),
            ("(%fptosi-primitive-f32-i64 (field (floats (Floats 1.5 2.5)) y))", 4),
            ("(%fptosi-primitive-f64-i64 (field (quad (Quad 40.0 1.0 2.0 3.0)) a))", 42),
            ("(%fptosi-primitive-f32-i64 (index (float-array (array-of 1.0 2.0 40.0)) 2))", 42),
            ("(%fptosi-primitive-f64-i64 (float 40.5 1.5))", 42),
            ("(match (big-choice (Big (Large (array-of 1 2 3)))) ((Big x) (index (field x elements) 2)) ((Nothing) 0))", 42),
            ("(let ((r (mixed (Mixed 1.5 38)))) (%+-primitive-i64 (%fptosi-primitive-f64-i64 (field r x)) (field r y)))", 43),
            ("(index (field (large (Large (array-of 10 20 30))) elements) 2)", 33),
            ("(%sext-primitive-i16-i64 (index (array (array-of 1 2 3)) 2))", 4),
            ("(match (choice (Small 40 false)) ((Small x flag) (if flag (%zext-primitive-u8-i64 x) 0)) ((Real x) 0) ((Wrapped x) 0))", 42),
            ("(match (choice (Real 2.25)) ((Small x flag) 0) ((Real x) (%fptosi-primitive-f64-i64 x)) ((Wrapped x) 0))", 3),
            ("(match (choice (Wrapped (Record 40 true))) ((Small x flag) 0) ((Real x) 0) ((Wrapped x) (%sext-primitive-i32-i64 (field x value))))", 42),
            ("(let ((r (nested (Nested (Record 40 false) (array-of 1 2 3) false)))) (if (field r flag) (%sext-primitive-i32-i64 (field (field r record) value)) 0))", 42),
            ("(%sext-primitive-i8-i64 (narrow -1 -2 20 25))", 42),
            ("(%sext-primitive-i32-i64 (field (record-callback bump (Record 40 false)) value))", 42),
            ("(index (field (large-callback bump-large (Large (array-of 41 0 0))) elements) 0)", 42),
            ("(match (choice-callback bump-choice (Small 1 false)) ((Small x flag) 0) ((Real x) (%fptosi-primitive-f64-i64 x)) ((Wrapped x) 0))", 42),
            ("(if (bool-callback invert false) 42 0)", 42),
            ("(%fptosi-primitive-f64-i64 (field (quad-callback bump-quad (Quad 40.0 1.0 2.0 3.0)) a))", 42),
            ("(let ((f (get-record))) (%sext-primitive-i32-i64 (field (f (Record 40 false)) value)))", 42),
            ("(%sext-primitive-i32-i64 (field (record-callback record (Record 39 false)) value))", 42),
            ("(%sext-primitive-i32-i64 (field (crowded 1 2 3 4 5 6 (Record 21 true)) value))", 42),
            ("(let ((value (empty (Empty)))) 42)", 42),
            ("(match (match-next) (1 (%+-primitive-i64 41 (match-count))) (_ 0))", 42),
            ("(do (sequence-step 1) (sequence-step 2) (sequence-step 3) (sequence-trace))", 123),
            ("(let ((first (sequence-step 1))) (sequence-step 2) (sequence-step 3) (%+-primitive-i64 first (sequence-trace)))", 124),
        )
        for expression, expected in cases:
            with self.subTest(expression=expression):
                source = declarations + self.program(expression)
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 0, checked.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "external executable"
                    compiled = self.run_core("compile-report", source, "-o", binary, level, env=environment)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 0, native.stderr)
                    self.assertEqual(native.stdout, f"i64:{expected}\n")

    def test_external_function_visibility_and_evaluation(self):
        (self.root / "native.vrn").write_text("""
(%export length)
(%external-function length "strlen" ((pointer u8)) u64)
(%external-function hidden "strlen" ((pointer u8)) u64)
""")
        source = """
(%import native :as lib)
(%external-function length "strlen" ((pointer u8)) u64)
(%function main () i64
  (if true 42 (%reinterpret-primitive-u64-i64 (lib:length "hello"))))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertEqual(len(re.findall(r"^declare i64 @strlen\(ptr", emitted.stdout, re.M)), 1)
        direct = """(%import native :as lib)
(%function main () u64 (lib:length "hello"))"""
        indirect = """(%import native :as lib)
(%type Length (pointer (function ((pointer u8)) u64)))
(%function main () u64 (let ((f Length lib:length)) (f "hello")))"""
        void = """(%external-function seed "srand" (u32) void)
(%function main () unit (seed 1))"""
        for program, expected in ((direct, "u64:5\n"), (indirect, "u64:5\n"), (void, "unit\n")):
            with self.subTest(program=program):
                evaluated = self.run_core("eval", program)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn("native calls are unavailable in the evaluator", evaluated.stderr)
                self.assertIn("in main", evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "libc executable"
                    compiled = self.run_core("compile-report", program, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 0, native.stderr)
                    self.assertEqual(native.stdout, expected)

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
        fixture = Path(__file__).with_name("external.c")
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

    def test_invalid_external_declarations(self):
        (self.root / "native.vrn").write_text('(%external-function hidden "strlen" ((pointer u8)) u64)')
        for source, message in (
            ('(%external-function f "f" ())', "%external-function requires"),
            ('(%external-function f name () i64)', "%external-function requires"),
            ('(%external-function f "" () i64)', "external symbol cannot be empty"),
            ('(%external-function f "main" () i64)', "reserved for the entry point"),
            ('(%external-function f "f" () unit)', "C-compatible"),
            ('(%external-function f "f" (void) i64)', "void type requires a pointer"),
            ('(%external-function f "f" (unit) i64)', "C-compatible"),
            ('(%external-function f "f" ((tuple i64)) i64)', "C-compatible"),
            ('(%type P (product (x unit)))(%external-function f "f" (P) i64)', "C-compatible"),
            ('(%type P)(%external-function f "f" () P)', "C-compatible"),
            ('(%external-function f "f" ((pointer (function (unit) i64))) i64)', "C-compatible"),
            ('(%external-function f "same" (i8) i64)(%external-function g "same" (u8) i64)', "conflicting declarations"),
            ('(%external-function f "same" () i64)(%external-function g "same" () u64)', "conflicting declarations"),
            ('(%external-function f "f" () i64)(%function f () i64 1)', "duplicate function"),
            ('(%constant f i64 1)(%external-function f "f" () i64)', "duplicate external"),
            ('(%external-function f "f" (i64) i64)(%function use () i64 (f))', "too few arguments"),
            ('(%external-function f "f" () i64)(%function use () i64 (f 1))', "too many arguments"),
            ('(%import native :as lib)(%function use () u64 (lib:hidden ""))', "private declaration access"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source + self.program("0"))
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)
        recursive = """
(%type Node (product (next (pointer Node))))
(%external-function inspect "inspect" ((pointer Node)) i64)
(%function main () i64 42)
"""
        checked = self.run_core("check", recursive)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        conflict = '(%external-function bad "write" () i64)' + self.program("0")
        compiled = self.run_core("emit-llvm", conflict)
        self.assertEqual(compiled.returncode, 2, compiled.stderr)
        self.assertIn("conflicts with a runtime declaration", compiled.stderr)

    def test_quasiquoted_declarations(self):
        self.agrees("""
(%macro define (name &rest body)
  `(%function ,name () i64 (%--primitive-i64 ,@body)))
(define main 44 2)
""", 42)
        self.agrees("""
(%macro define (value)
  `(%macro emit-main ()
     `(%function main () i64 ,,value)))
(define 42)
(emit-main)
""", 42)
        self.agrees("""
(%macro define (&rest args)
  `(%function main () i64 (%+-primitive-i64 ,@args 40 2)))
(define)
""", 42)
        self.agrees("""
(%macro define (value)
  (quasiquote (%function main () i64 (unquote value))))
(define 42)
""", 42)
        for source, message in (
            ("(%macro bad () `(,@42))(bad)", "unquote-splicing requires a list"),
            ("(%macro bad () `,@'())(bad)", "unquote-splicing requires a list element"),
            ("(%macro bad () ,42)(bad)", "unquote is valid only inside quasiquote"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_data_and_character_literals(self):
        source = r"""
(%function choose ((flag bool)) (pointer u8)
  (if flag "a\n\t\"\\%" ""))
(%function main () (tuple (pointer u8) (pointer u8) u8 u8)
  (tuple (choose true) (choose false) #\NeWlInE #\)))
"""
        expected = 'tuple(data:6:a\n\t"\\%,data:0:,u8:10,u8:41)\n'
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, expected)
        for level in ("-O0", "-O2"):
            binary = self.root / "literal executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, expected)
        for spelling, message in (
            (r'"\q"', "unsupported data escape"),
            ('"é"', "non-NUL ASCII"),
            (b'"a\x00b"', "non-NUL ASCII"),
            ("#\\", "invalid ASCII character literal"),
            (r"#\unknown", "invalid ASCII character literal"),
            (r"#\é", "invalid ASCII character literal"),
        ):
            with self.subTest(spelling=spelling):
                result = self.run_core("read", spelling)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
        result = self.run_core("check", r"(%function main () i8 #\a)")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("expected i8, actual u8", result.stderr)

    def test_fixed_size_arrays(self):
        source = """
(%type Bytes (array u8 8))
(%type Packet (product (bytes Bytes)))
(%function read-byte ((packet Packet) (offset usize)) u8
  (index (field packet bytes) offset))
(%function main () i64
  (%zext-primitive-u8-i64 (read-byte (Packet (array-of 0 1 2 3 42 5 6 7)) 4)))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("[8 x i8]", emitted.stdout)
        self.agrees("""
(%function first (for (a)) ((value (array a 2))) a (index value 0))
(%function main () i64 (first (array-of (cast i64 42) 0)))
""", 42)
        report = """
(%function main () (tuple (array u8 0) (array (array i64 2) 2))
  (tuple (array-of) (array-of (array-of 1 2) (array-of 3 4))))
"""
        expected = "tuple(array(),array(array(i64:1,i64:2),array(i64:3,i64:4)))\n"
        evaluated = self.run_core("eval", report)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, expected)
        for level in ("-O0", "-O2"):
            binary = self.root / "array report"
            compiled = self.run_core("compile-report", report, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, expected)

        bad_index = source.replace("5 6 7)) 4", "5 6 7)) 8")
        evaluated = self.run_core("eval", bad_index)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("array index out of bounds", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "bad index"
            compiled = self.run_core("compile", bad_index, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assertIn("array index out of bounds", native.stderr)
        for text, message in (
            (self.program("(index (array-of (cast i64 42)) 1)"), "array index out of bounds"),
            (self.program("(let ((x (array-of))) 0)"), "cannot infer empty array element type"),
            ("(%function main () (array u8 2) (array-of 1))", "array-of element count mismatch"),
            ("(%function main () (array u8 1) (array-of true))", "expected u8, actual bool"),
            ("(%type Bad (array u8 -1))" + self.program("0"), "unsigned integer literal cannot be negative"),
        ):
            with self.subTest(text=text):
                result = self.run_core("check", text)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_function_pointer_calls(self):
        (self.root / "callbacks.vrn").write_text("""
(%export add-two)
(%function add-two ((value i64)) i64 (%+-primitive-i64 value 2))
""")
        self.agrees("""
(import callbacks :as cb)
(%type Callback (pointer (function (i64) i64)))
(%type Holder (product (callback Callback)))
(%function invoke ((holder Holder) (value i64)) i64
  (let ((callback (field holder callback))) (callback value)))
(%function make () Holder (Holder cb:add-two))
(%function main () i64
  (%+-primitive-i64 (invoke (make) 18)
                   ((field (make) callback) 20)))
""", 42)
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function answer () i64 42)
(%function main () i64
  (let ((callback Callback answer)
        (erased (pointer void) (cast (pointer void) callback))
        (temporary (pointer (function (u8) bool)) (cast (pointer (function (u8) bool)) erased)))
    ((cast Callback (cast (pointer void) temporary)))))
""", 42)
        for declaration, message in (
            ("(%function bad ((cb (pointer (function (i64) i64)))) i64 (cb true))",
             "expected i64, actual bool"),
            ("(%function bad ((cb (pointer (function (i64) i64)))) i64 (cb))",
             "wrong function pointer argument count"),
            ("(%function bad () (pointer (function () bool)) main)",
             "function pointer signature mismatch"),
            ("(%function bad ((cb (function () i64))) i64 0)",
             "function type requires a pointer"),
            ("(%type Bad (pointer (function (void) i64)))",
             "void type requires a pointer"),
        ):
            with self.subTest(declaration=declaration):
                result = self.run_core("check", declaration + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_pointer_equality(self):
        self.agrees("""
(%variable total i64 42)
(%function address () (pointer i64) (& total))
(%function main () i64
  (let ((value i64 7) (other i64 7) (p (& value))
        (items (array-of (cast i64 1) 2)) (first (& (index items 0))))
    (if (== p (& value))
      (if (!= p (& other))
        (if (== p (pointer-offset p 0))
          (if (== (pointer-offset first 1) (& (index items 1)))
            (if (== (pointer-offset first 2) (pointer-offset first 2))
              (if (== (address) (& total)) 42 0) 0) 0) 0) 0) 0)))
""", 42)
        self.agrees("""
(%type Opaque)
(%function main () i64
  (let ((text "abc") (p (pointer-offset text 1))
        (back (pointer-offset p -1))
        (opaque (cast (pointer Opaque) (cast (pointer void) text))))
    (if (== text (pointer-offset text 0))
      (if (== text back)
        (if (!= text p)
          (if (== (cast (pointer void) opaque) (cast (pointer void) back)) 42 0) 0) 0) 0)))
""", 42)
        # Argument side effects run once, left to right, before comparison.
        self.agrees("""
(%variable calls i64 0)
(%variable value i64 42)
(%function next ((expected i64)) (pointer i64)
  (do (store calls (if (%=-primitive-i64 calls expected) (%+-primitive-i64 calls 1) 99)) (& value)))
(%function main () i64
  (if (== (next 0) (next 1)) (if (%=-primitive-i64 calls 2) 42 0) 0))
""", 42)
        emitted = self.run_core("emit-llvm", """
(%function same ((left (pointer i64)) (right (pointer i64))) bool (== left right))
(%function different ((left (pointer i64)) (right (pointer i64))) bool (!= left right))
(%function main () i64 42)
""")
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"icmp eq ptr")
        self.assertRegex(emitted.stdout, r"icmp ne ptr")

    def test_function_pointer_identity(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function first () i64 1)
(%function second () i64 2)
(%function get () Callback first)
(%function main () i64
  (let ((a Callback first) (b Callback first) (other Callback second))
    (if (== a b)
      (if (== a (get))
        (if (!= a other)
          (if (== (cast (pointer void) a) (cast (pointer void) b)) 42 0) 0) 0) 0)))
""", 42)

        # Two declarations of one native symbol denote the same function.
        self.agrees("""
(%type Callback (pointer (function () i32)))
(%external-function first "getpid" () i32)
(%external-function second "getpid" () i32)
(%function main () i64
  (let ((a Callback first) (b Callback second)) (if (== a b) 42 0)))
""", 42)

    def test_pointer_equality_dispatch(self):
        for operator, value, body in (("==", "false", "(if (== p p) 0 42)"),
                                      ("!=", "true", "(if (!= p p) 42 0)")):
            self.agrees(f"""
(%implementation {operator} ((left (pointer i64)) (right (pointer i64))) bool {value})
(%function main () i64 (let ((value i64 0) (p (& value))) {body}))
""", 42)
        self.agrees("""
(%function == ((a (pointer i64)) (b (pointer i64))) bool false)
(%function main () i64 (let ((value i64 0)) (if (== (& value) (& value)) 0 42)))
""", 42)
        self.agrees("""
(%protocol Custom (a) (== ((left a) (right a)) bool))
(%implementation (Custom (pointer i64))
  (function == ((left (pointer i64)) (right (pointer i64))) bool false))
(%function apply (for (a) ((Custom a))) ((left a) (right a)) bool (== left right))
(%function main () i64
  (let ((value i64 0)) (if (apply (& value) (& value)) 0 42)))
""", 42)
        # The reference also permits fallback for a source-declared equality generic.
        self.agrees("""
(%generic == (left right))
(%function main () i64 (let ((value i64 0)) (if (== (& value) (& value)) 42 0)))
""", 42)

    def test_invalid_pointer_equality(self):
        for declaration, body, message in (
            ("", '(let ((x i64 0) (y u64 0)) (== (& x) (& y)))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) (cast (pointer void) (& x))))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) (cast i64 0)))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) 0))', "ambiguous numeric literal"),
            ("", '(let ((x i64 0)) (< (& x) (& x)))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x)))', "wrong generic argument count"),
            ("(%function a () i64 1)(%function b () bool true)",
             '(let ((a (pointer (function () i64)) a) (b (pointer (function () bool)) b)) (== a b))',
             "no matching generic implementation"),
        ):
            with self.subTest(body=body):
                checked = self.run_core("check", declaration + f"(%function main () bool {body})")
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_native_null_pointer_equality(self):
        c = self.root / "null pointer fixture.c"
        c.write_text("#include <stdint.h>\nstatic uint8_t byte = 42;\n"
                     "uint8_t *absent(void) { return 0; }\n"
                     "uint8_t *present(void) { return &byte; }\n")
        obj = self.root / "null pointer fixture.o"
        subprocess.run(["clang", "-c", str(c), "-o", str(obj)], check=True, capture_output=True)
        wrapper = self.root / "link pointer fixture"
        wrapper.write_text(f"#!{sys.executable}\nimport os,sys\n"
                           f"os.execvp('clang', ['clang', *sys.argv[1:], {str(obj)!r}])\n")
        wrapper.chmod(0o755)
        source = """
(%external-function absent "absent" () (pointer u8))
(%external-function present "present" () (pointer u8))
(%function main () i64
  (if (== (absent) (absent))
    (if (!= (present) (absent))
      (if (== (present) (present))
        (if (== (cast (pointer void) (absent)) (cast (pointer void) (absent))) 42 0) 0) 0) 0))
"""
        for level in ("-O0", "-O2"):
            binary = self.root / "null pointer executable"
            result = self.run_core("compile-report", source, "-o", binary, level,
                                   env=dict(os.environ, VERONA_CORE_CLANG=str(wrapper)))
            self.assertEqual(result.returncode, 0, result.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, "i64:42\n")

    def test_general_pointer_types_and_casts(self):
        source = """
(%type Node (product (next (pointer Node)) (nested (pointer (tuple Node)))))
(%type Byte u8)
(%type Raw (pointer void))
(%type Box (product (value Raw)))
(%function erase ((value (pointer Byte))) Raw (cast Raw value))
(%function restore ((value Raw)) (pointer Byte)
  (cast (pointer Byte) (cast Raw (cast (pointer (pointer i64)) value))))
(%function main () (pointer u8)
  (restore (field (Box (erase "hello")) value)))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, "data:5:hello\n")
        for level in ("-O0", "-O2"):
            binary = self.root / "pointer executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, evaluated.stdout)
        for declaration, message in (
            ("(%function bad () void unit)", "void type requires a pointer"),
            ("(%type Bad (tuple void))", "void type requires a pointer"),
            ("(%type Bad (product (child (tuple Bad))))", "recursive structured layout"),
            ('(%function bad () (pointer i64) (cast (pointer i64) "x"))',
             "cast permits only (pointer T) to or from (pointer void)"),
            ("(%function bad () (pointer void) (cast (pointer void) (cast i64 1)))",
             "cast permits only (pointer T) to or from (pointer void)"),
            ("(%function bad ((value (pointer i64))) (pointer u64) value)",
             "expected (pointer u64), actual (pointer i64)"),
        ):
            with self.subTest(declaration=declaration):
                result = self.run_core("check", declaration + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_opaque_types(self):
        (self.root / "handles.vrn").write_text("""
(%export Handle HandleAlias)
(%type Handle (:type opaque))
(%type HandleAlias Handle)
""")
        source = """
(%import handles :as lib)
(%type Other)
(%type Wrapper (product (handle (pointer lib:Handle))))
(%function forward ((handle (pointer lib:HandleAlias))) (pointer lib:Handle)
  (field (Wrapper handle) handle))
(%function main () i64 42)
"""
        self.agrees(source, 42)
        ir = self.run_core("emit-llvm", source)
        self.assertEqual(ir.returncode, 0, ir.stderr)
        self.assertRegex(ir.stdout, r"define internal ptr @[^ (]+\(ptr ")
        for source, message in (
            ("(%type Handle)(%function bad ((x Handle)) i64 0)", "opaque type requires a pointer"),
            ("(%type Handle)(%function bad () Handle unit)", "opaque type requires a pointer"),
            ("(%type Handle)(%type Box (product (x Handle)))", "opaque type requires a pointer"),
            ("(%type Handle)(%type Box (tuple Handle))", "opaque type requires a pointer"),
            ("(%type Handle)(%type Box (sum (Value Handle)))", "opaque type requires a pointer"),
            ("(%type A)(%type B)(%function bad ((x (pointer A))) (pointer B) x)",
             "expected (pointer 0:B), actual (pointer 0:A)"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_transparent_type_aliases(self):
        (self.root / "library.vrn").write_text("""
(%export Scalar Record Alias)
(%type Scalar Hidden)
(%type Hidden i64)
(%type Alias Record)
(%type Record (product (value Scalar)))
""")
        self.agrees("""
(%import library :as lib)
(%type Result Number)
(%type Number lib:Scalar)
(%type Pair (tuple Result lib:Alias))
(%function unwrap ((record lib:Alias)) Result (field record value))
(%function main () Result
  (let ((pair Pair (tuple (cast Result 2) (lib:Record 40))))
    (%+-primitive-i64 (tuple-get pair 0) (unwrap (tuple-get pair 1)))))
""", 42)
        for source, message in (
            ("(%type A A)", "type alias cycle"),
            ("(%type A B)(%type B (tuple A))", "type alias cycle"),
            ("(%type A Missing)", "unknown core type"),
            ("(%type A i64)(%type A (product))", "duplicate type"),
            ("(%import library :as lib)(%type A lib:Hidden)", "private declaration access"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_floating_point_primitives(self):
        def bits(format, value):
            return int.from_bytes(struct.pack(format, value), "big")

        source = """
(%type Rational f64)
(%function rounded ((value f32)) f32 (%+-primitive-f32 value 1.0))
(%function main () (tuple f32 Rational i16 u16 f32 f64 bool bool bool f64 f32)
  (tuple
    (rounded 16777216.0)
    (%/-primitive-f64 (%*-primitive-f64 3.0 2.0) (%--primitive-f64 4.0 2.0))
    (%fptosi-primitive-f32-i16 -3.75)
    (%fptoui-primitive-f64-u16 3.75)
    (%sitofp-primitive-i64-f32 -42)
    (%uitofp-primitive-u64-f64 18446744073709551615)
    (%<-primitive-f32 -2.0 -1.0)
    (%/=-primitive-f64 (%/-primitive-f64 0.0 0.0) 1.0)
    (%=-primitive-f64 0.0 -0.0)
    (%fext-primitive-f32-f64 (%ftrunc-primitive-f64-f32 (cast Rational -0.0)))
    (cast f32 1.0000000596046448)))
"""
        expected = (
            f"tuple(f32:{bits('>f', 16777216.0)},f64:{bits('>d', 3.0)},i16:-3,u16:3,"
            f"f32:{bits('>f', -42.0)},f64:{bits('>d', float(2**64))},"
            f"bool:1,bool:1,bool:1,f64:{bits('>d', -0.0)},f32:1065353217)\n"
        )
        result = self.run_core("eval", source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, expected)
        for level in ("-O0", "-O2"):
            binary = self.root / "float executable"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, expected)
        for body, message in (
            ("(let ((value 1.5)) value)", "ambiguous numeric literal"),
            ("(cast i64 1.5)", "requires an integer literal"),
            ("(cast f32 1)", "requires a floating-point literal"),
            ("(cast f32 " + "9" * 40 + ".0)", "floating-point literal out of range"),
            ("1.5.2", "malformed integer literal"),
        ):
            with self.subTest(body=body):
                result = self.run_core("check", f"(%function main () f32 {body})")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_concrete_generic_dispatch(self):
        library = """
(%export convert)
(%generic convert (value))
(%implementation convert ((value i64)) i64 value)
(%implementation convert ((value i64)) u8 (%trunc-primitive-i64-u8 value))
"""
        (self.root / "library.vrn").write_text(library)
        self.agrees("""
(%import library :as lib)
(%function small ((value i64)) u8 (lib:convert value))
(%function main () i64
  (let ((n i64 (lib:convert 40)))
    (%+-primitive-i64 n (%zext-primitive-u8-i64 (small 2)))))
""", 42)
        operators = """
(%generic + (left right))
(%implementation + ((left i64) (right i64)) i64 (%+-primitive-i64 left right))
(%implementation + ((left u8) (right u8)) u8 (%+-primitive-u8 left right))
"""
        self.agrees(operators + self.program("(%zext-primitive-u8-i64 (+ (cast u8 40) 2))"), 42)
        for source, message in (
            (operators + self.program("(let ((value (+ 40 (cast u8 2)))) 0)"),
             "ambiguous numeric literal"),
            (operators + self.program("(let ((value (+ 40 2))) 0)"),
             "ambiguous numeric literal"),
            (library.replace("(%export convert)", "") + self.program("(let ((value (convert 2))) 0)"),
             "ambiguous generic implementation"),
            (operators + self.program("(+ true false)"), "no matching generic implementation"),
            (operators + self.program("(+ (cast i64 1))"), "wrong generic argument count"),
            (operators + "(%implementation + ((a i64) (b i64)) i64 a)" + self.program("0"),
             "duplicate generic implementation"),
            ("(%generic f (x))(%implementation f () i64 42)" + self.program("0"),
             "implementation arity does not match generic"),
        ):
            with self.subTest(message=message):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_boolean_primitives(self):
        cases = []
        for left in (False, True):
            a = str(left).lower()
            cases.append((f"(%not-primitive-bool {a})", not left))
            for right in (False, True):
                b = str(right).lower()
                for op, expected in (("and", left and right), ("or", left or right),
                                     ("=", left == right), ("/=", left != right)):
                    cases.append((f"(%{op}-primitive-bool {a} {b})", expected))
        body = "42"
        for expression, expected in reversed(cases):
            yes, no = (body, "0") if expected else ("0", body)
            body = f"(if {expression} {yes} {no})"
        self.agrees(self.program(body), 42)
        for operation in ("%and-primitive-bool false", "%or-primitive-bool true"):
            source = self.program(f"(if ({operation} (%=-primitive-i64 (%/-primitive-i64 1 0) 0)) 1 0)")
            evaluated = self.run_core("eval", source)
            self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
            for level in ("-O0", "-O2"):
                binary = self.root / "eager executable"
                compiled = self.run_core("compile", source, "-o", binary, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, 70, native.stderr)
        for expression in ("(%not-primitive-bool)", "(%not-primitive-bool true false)",
                           "(%and-primitive-bool true)", "(%=-primitive-bool (cast i64 0) true)"):
            result = self.run_core("check", self.program(f"(if {expression} 42 0)"))
            self.assertEqual(result.returncode, 2, result.stderr)

    def test_base_boolean_operations(self):
        host = Path(__file__).resolve().parents[1] / "build/verona"
        base = Path(__file__).resolve().parents[1] / "projects/base/src"
        source = self.root / "input.vrn"
        manifest = self.root / "verona.build"
        binary = self.root / "out" / "boolean"
        prefix = "(import base :as b)\n"
        body = """
(external-function abort "abort" () void)
(function fail () bool (do (abort) false))
(function record ((trace (pointer i64)) (digit i64) (value bool)) bool
  (do (store (deref trace) (%+-primitive-i64 (%*-primitive-i64 (deref trace) 10) digit))
    value))
(function guarded ((values (pointer bool)) (index u64) (count u64)) bool
  (b:and-then (%<-primitive-u64 index count) (deref (pointer-offset values index))))
(b:macro nested (value) `(b:and-then ,value (b:not false)))
(function main () exit-code
  (let ((trace i64 0) (values bool true) (identity bool true) (primitive bool false)
        (eager-and bool (b:and (record (& trace) 1 false) (record (& trace) 2 true)))
        (eager-or bool (b:or (record (& trace) 3 true) (record (& trace) 4 false)))
        (short-and bool (b:and-then (record (& trace) 5 false) (fail)))
        (short-or bool (b:or-else (record (& trace) 6 true) (fail))))
    (match (b:and-then (b:not eager-and) eager-or (b:not short-and) short-or
             (nested (b:and identity)) (b:not (b:or primitive))
             (b:and-then (guarded (& values) 0 1) (b:not (guarded (& values) 1 1)))
             (b:or-else false (b:or false true false))
             (%=-primitive-i64 trace 123456))
      (true 42) (false 1))))
"""
        def build(text, level):
            source.write_text(prefix + text)
            manifest.write_text(f'(executable boolean (root input) (module-path ".") '
                                f'(module-path "{base}") (target native) (optimize {level}))')
            return subprocess.run([str(host), "build", "boolean", str(binary.parent)],
                                  cwd=self.root, capture_output=True, text=True, timeout=30)

        for level in (0, 2):
            result = build(body, level)
            self.assertEqual(result.returncode, 0, result.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 42, native.stderr)
        for expression in (
            "(b:and)", "(b:or)", "(b:and-then)", "(b:or-else)", "(b:not)", "(b:not true false)",
            "(b:and (cast i64 1))", "(b:or (cast i64 1))", "(b:and-then (cast i64 1))",
            "(b:or-else (cast i64 1))", "(b:and-then false (cast i64 1))",
            "(b:or-else true (cast i64 1))",
        ):
            with self.subTest(expression=expression):
                result = build(f"(function main () exit-code (match {expression} (true 0) (false 1)))", 0)
                self.assertNotEqual(result.returncode, 0)

    def test_constrained_function_specialization(self):
        prelude = """
(%protocol numeric (a) (+ ((x a) (y a)) a))
(%implementation (numeric u8)
  (function + ((x u8) (y u8)) u8 (%+-primitive-u8 x y)))
(%implementation (numeric i64)
  (function + ((x i64) (y i64)) i64 (%+-primitive-i64 x y)))
(%function add (for (a) ((numeric a))) ((x a) (y a)) a (+ x y))
"""
        source = prelude + self.program("""
(%+-primitive-i64
  (%zext-primitive-u8-i64 (add (cast u8 8) 2))
  (%+-primitive-i64 (%zext-primitive-u8-i64 (add (cast u8 9) 1))
                   (add (cast i64 20) 2)))
""")
        self.agrees(source, 42)
        ir = self.run_core("emit-llvm", source)
        self.assertEqual(ir.returncode, 0, ir.stderr)
        # One u8 method and one u8 specialization despite the two calls.
        self.assertEqual(len(re.findall(r'define internal i8 @"[0-9]+"\(', ir.stdout)), 2)
        self.agrees(prelude + """
(%function countdown (for (a) ((numeric a))) ((value a) (depth i64)) a
  (if (%=-primitive-i64 depth 0) value
    (countdown (add value value) (%--primitive-i64 depth 1))))
(%function main () i64 (countdown (cast i64 21) 1))
""", 42)
        self.agrees("""
(%function first (for (a)) ((value (tuple a))) a (tuple-get value 0))
(%function main () i64 (first (tuple (cast i64 42))))
""", 42)
        for source, message in (
            (prelude + self.program("(add (cast u16 40) 2)"), "missing protocol implementation"),
            (prelude + self.program("(add 40 (cast i64 2))"), "ambiguous numeric literal"),
            (prelude + self.program("(add (cast u8 40) (cast i64 2))"), "conflicting type argument"),
            (prelude + self.program("(add (cast i64 42))"), "wrong parametric function argument count"),
            ("""(%function constant (for (a)) () a (cast i64 42))
                (%function main () i64 (constant))""", "cannot infer type parameter"),
            ("""(%function recur (for (a)) ((x a)) i64 (recur (cast u8 0)))
                (%function main () i64 (recur (cast i64 0)))""",
             "recursive specialization changes type arguments"),
        ):
            with self.subTest(message=message):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_concrete_protocols(self):
        library = """
(%export bounded minBound)
(%protocol bounded (a)
  (minBound () a)
  (pair ((x a)) (tuple a a)))
(%generic minBound ())
(%implementation (bounded i64)
  (function minBound () i64 40)
  (function pair ((x i64)) (tuple i64 i64) (tuple x x)))
"""
        (self.root / "library.vrn").write_text(library)
        self.agrees("""
(%import library :as lib)
(%implementation (lib:bounded u8)
  (function minBound () u8 2)
  (function pair ((x u8)) (tuple u8 u8) (tuple x x)))
(%function small () u8 (lib:minBound))
(%function main () i64
  (%+-primitive-i64 (lib:minBound) (%zext-primitive-u8-i64 (small))))
""", 42)
        self.agrees(library + """
(%implementation minBound () i64 42)
(%function main () i64 (minBound))
""", 42)
        self.agrees("""
(%type Handle)
(%protocol forwarding (a) (forward ((value (pointer a))) (pointer a)))
(%implementation (forwarding Handle)
  (function forward ((value (pointer Handle))) (pointer Handle) value))
(%function main () i64 42)
""", 42)
        protocol = "(%protocol sample (a) (value () a))"
        instance = "(%implementation (sample i64) (function value () i64 0))"
        for source, message in (
            (protocol + "(%implementation (sample i64))", "missing protocol operation"),
            (protocol + "(%implementation (sample i64) (function value () u8 0))",
             "protocol operation result type mismatch"),
            (protocol + "(%implementation (sample i64) (function value ((x i64)) i64 x))",
             "protocol operation parameter type mismatch"),
            (protocol + instance + instance, "duplicate protocol implementation"),
            (protocol + "(%implementation (sample) (function value () i64 0))",
             "protocol argument count mismatch"),
            (protocol + "(%implementation (sample i64) (function value () i64 0)"
             "(function extra () i64 0))", "unknown protocol operation"),
            (protocol + "(%implementation (sample i64) (function value () i64 0)"
             "(function value () i64 0))", "duplicate protocol operation"),
        ):
            with self.subTest(message=message):
                result = self.run_core("check", source + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_integer_type_boundaries(self):
        for ty, body, message in (
            ("i8", "128", "out of range"),
            ("i8", "-129", "out of range"),
            ("u8", "256", "out of range"),
            ("u8", "-1", "cannot be negative"),
            ("u8", "(let ((x 1)) x)", "ambiguous numeric literal"),
            ("u8", "(cast u8 256)", "out of range"),
            ("u64", "18446744073709551616", "out of range"),
            ("i32", "(%zext-primitive-i8-i32 1)", "unknown function"),
            ("u8", "(%trunc-primitive-u64-u8 1 2)", "requires one argument"),
            ("u8", "(let ((value i8 1)) (%+-primitive-u8 value 1))", "expected u8, actual i8"),
        ):
            with self.subTest(type=ty, expression=body):
                result = self.run_core("check", f"(%function main () {ty} {body})")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
        binary = self.root / "byte-result"
        result = self.run_core("compile", "(%function main () u8 255)", "-o", binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 255)

    def test_structured_analysis_errors(self):
        invalid = [
            ("(%type A (product (x i64) (x bool)))", "duplicate field"),
            ("(%type P (product))(%function P () i64 0)", "conflicts with type constructor"),
            ("(%type S (sum (X)))(%function X () i64 0)", "conflicts with sum constructor"),
            ("(%type P (product))(%function bad () P (let ((P (cast i64 1))) (P)))", "local value is not callable"),
            ("(%type S (sum (X)))(%function bad () S (let ((X (cast i64 1))) (X)))", "local value is not callable"),
            ("(%type A (sum (X) (X i64)))", "duplicate sum case"),
            ("(%type A (product (x Missing)))", "unknown core type"),
            ("(%type A (product (x A)))", "recursive structured layout"),
            ("(%type A (product (b B)))(%type B (sum (Again (tuple A))))", "recursive structured layout"),
            ("(%type A (sum))", "sum requires at least one case"),
            ("(%type A (product))(%type A (product))", "duplicate type"),
            ("(%type A (product (x i64)))(%function bad () A (A))", "too few constructor arguments"),
            ("(%type A (product))(%function bad () A (A 1))", "too many constructor arguments"),
            ("(%type A (product (x i64)))(%function bad () A (A true))", "type mismatch"),
            ("(%type A (product (x i64)))(%type B (product (x i64)))(%function bad () A (B 1))", "type mismatch"),
            ("(%type A (sum (X)))(%type B (sum (X)))(%function bad () A (B:X))", "type mismatch"),
            ("(%type A (product))(%function bad () i64 (field (A) missing))", "unknown product field"),
            ("(%function bad () i64 (tuple-get (tuple (cast i64 1)) 1))", "tuple index out of range"),
            ("(%function bad () i64 (tuple-get (tuple (cast i64 1)) -1))", "tuple index out of range"),
            ("(%function bad () i64 (tuple-get (tuple (cast i64 1)) true))", "integer literal"),
            ("(%function bad () (tuple i64 bool) (tuple true 1))", "type mismatch"),
            ("(%function bad () (tuple i64) (tuple))", "type mismatch"),
            ("(%type A (sum (X)))(%type B (sum (X)))(%function bad () i64 (let ((x (X))) 0))", "ambiguous sum constructor"),
            ("(%type A (sum (X i64)))(%function bad () A (X))", "too few constructor arguments"),
            ("(%type A (sum (X)))(%function bad () A (X 1))", "too many constructor arguments"),
            ("(%type A (sum (X i64)))(%function bad () A (X true))", "type mismatch"),
            ("(%type A (sum (X) (Y)))(%function bad ((a A)) i64 (match a ((X) 1)))", "non-exhaustive match"),
            ("(%type A (sum (X) (Y)))(%function bad ((a A)) i64 (match a ((X) 1) ((X) 2) ((Y) 3)))", "duplicate match case"),
            ("(%type A (sum (X) (Y)))(%function bad ((a A)) i64 (match a (_ 1) ((Y) 3)))", "unreachable match arm"),
            ("(%type A (sum (X)))(%function bad ((a A)) i64 (match a ((X) 1) (_ 3)))", "unreachable wildcard"),
            ("(%type A (sum (X i64 i64)))(%function bad ((a A)) i64 (match a ((X x x) x)))", "duplicate payload binding"),
            ("(%type A (sum (X i64)))(%function bad ((a A)) i64 (match a ((X) 1)))", "too few pattern components"),
            ("(%type A (sum (X)))(%function bad ((a A)) i64 (match a ((X x) x)))", "too many pattern components"),
            ("(%type A (sum (X i64) (Y)))(%function bad ((a A)) i64 (match a ((X x) x) ((Y) x)))", "unknown local name"),
            ("(%type A (sum (X) (Y)))(%function bad ((a A)) i64 (match a ((X) 1) ((Y) false)))", "type mismatch"),
            ("(%function bad () i64 (match 1 (_ 0)))", "ambiguous numeric literal"),
            ("(%type A (sum (X)))(%type B (sum (Y)))(%function bad ((a A)) i64 (match a ((B:Y) 1)))", "another sum"),
            ("(%type A (sum (X (tuple i64))))(%function bad ((a A)) i64 (match a ((X (tuple x)) 1)))", "nested structured patterns"),
        ]
        for declaration, message in invalid:
            with self.subTest(source=declaration):
                result = self.run_core("check", declaration + self.program("0"))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertRegex(result.stderr, r"input\.vrn:1:[0-9]+:")
                self.assertFalse(result.stdout)

    def test_structured_visibility(self):
        (self.root / "types.vrn").write_text("(%type Private (product))(%type Hidden (sum (X)))(%export Public)(%type Public (product (x i64)))")
        for body in ["(%function bad () t:Private (t:Private))",
                     "(%function bad () i64 (let ((x (t:Hidden:X))) 0))"]:
            result = self.run_core("check", "(%import types :as t)" + body + self.program("0"))
            self.assertEqual(result.returncode, 2, result.stderr)
        self.agrees("(%import types :as t)" + self.program("(field (t:Public 42) x)"), 42)

    def test_surface_directives_with_real_base(self):
        base = Path(__file__).resolve().parents[1] / "projects/base/src"
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
        self.assertEqual(len(re.findall(r'^define internal i64 @"?\d+"?\(', emitted.stdout, re.M)), 6)
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
        # Same module graphs through the existing Common Lisp compiler and the
        # Verona compiler. Only declaration spelling and the native entry ABI differ.
        host = Path(__file__).resolve().parents[1] / "build/verona"
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
                    translated = re.sub(r"\(%(function|type|import|export)\b", r"(\1", source)
                    if module == "input":
                        translated = translated.replace("(function main () i64", "(function entry () i64")
                        translated += "(function main () exit-code (%trunc-primitive-i64-i32 (entry)))"
                    (host_directory / f"{module}.vrn").write_text(translated)
                core = subprocess.run([str(COMPILER), "eval", str(core_directory / "input.vrn")],
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

    def test_factorial(self):
        source = """(%function factorial ((n i64)) i64
  (if (%=-primitive-i64 n 0)
      1
      (%*-primitive-i64 n (factorial (%--primitive-i64 n 1)))))
(%function main () i64
  (let ((input i64 5)) (factorial input)))"""
        self.agrees(source, 120)

    def test_values_and_arithmetic(self):
        examples = {
            "0": 0, "-1": -1, "9223372036854775807": 9223372036854775807,
            "-9223372036854775808": -9223372036854775808,
            "(%+-primitive-i64 9223372036854775807 1)": -9223372036854775808,
            "(%--primitive-i64 -9223372036854775808 1)": 9223372036854775807,
            "(%*-primitive-i64 9223372036854775807 2)": -2,
            "(%/-primitive-i64 -7 3)": -2, "(%/-primitive-i64 7 -3)": -2, "(%/-primitive-i64 -7 -3)": 2,
            "(%+-primitive-i64 (%*-primitive-i64 4 5) (%--primitive-i64 9 3))": 26,
            "(if true 42 (%/-primitive-i64 1 0))": 42,
            "(if false (%/-primitive-i64 1 0) 7)": 7,
            "(if (if true false true) 1 (if false 3 4))": 4,
            "(let ((x i64 7) (y i64 (%+-primitive-i64 x 2))) (%*-primitive-i64 x y))": 63,
            "(let ((x i64 9)) (%+-primitive-i64 (let ((x i64 (%+-primitive-i64 x 1))) x) x))": 19,
            "(let () 13)": 13,
            "(let ((u unit unit) (b bool true)) (if b 17 2))": 17,
        }
        for expression, expected in examples.items():
            with self.subTest(expression=expression):
                self.agrees(self.program(expression), expected)

    def test_comparisons(self):
        for op in ("=", "<", "<=", ">", ">="):
            for left, right in ((-2, 1), (1, -2), (2, 2)):
                expected = int({"=": left == right, "<": left < right,
                                "<=": left <= right, ">": left > right,
                                ">=": left >= right}[op])
                with self.subTest(op=op, left=left, right=right):
                    self.agrees(self.program(f"(if (%{op}-primitive-i64 {left} {right}) 1 0)"), expected)

    def test_calls_and_mutual_recursion(self):
        self.agrees("""(%function main () i64 (%+-primitive-i64 (add 3 5) (add 7 11)))
          (%function add ((a i64) (b i64)) i64 (%+-primitive-i64 a b))""", 26)
        self.agrees("""(%function main () i64 (if (even 10) (id 29) 0))
          (%function even ((n i64)) bool (if (%=-primitive-i64 n 0) true (odd (%--primitive-i64 n 1))))
          (%function odd ((n i64)) bool (if (%=-primitive-i64 n 0) false (even (%--primitive-i64 n 1))))
          (%function id ((x i64)) i64 x)""", 29)
        self.agrees("""(%function noop ((u unit)) unit u)
          (%function main () i64 (let ((u unit (noop unit))) 8))""", 8)
        self.agrees("""(%function identity ((x i64)) i64 x)
          (%function main () i64 (let ((identity i64 9)) identity))""", 9)

    def test_signed_values_through_calls_and_bindings(self):
        identity = "(%function identity ((x i64)) i64 (let ((y i64 x)) y))"
        self.agrees(identity + self.program("(identity -9223372036854775808)"), -9223372036854775808)
        self.agrees(identity + self.program(
            "(let ((x i64 -9223372036854775808)) "
            "(if (%=-primitive-i64 (identity x) x) 41 2))"), 41)

    def test_invalid_programs(self):
        cases = [
            ("", "missing main"), ("(%function main () i64 0", "unclosed list"),
            (")", "unexpected closing"), ("()", "function requires"),
            ("(%function main () i64 0 1)", "function requires"),
            ("(%function main () nope 0)", "unknown core type"),
            ("(%function main ((x i64)) i64 x)", "main must have no parameters"),
            ("(%function main () bool 1)", "type mismatch"),
            ("(%function main () i64 0)(%function main () i64 1)", "duplicate function"),
            ("(%function f ((x i64) (x i64)) i64 x)(%function main () i64 0)", "duplicate parameter"),
            (self.program("9223372036854775808"), "out of range"),
            (self.program("-9223372036854775809"), "out of range"),
            (self.program("12x"), "invalid decimal"), (self.program("missing"), "unknown local"),
            (self.program("(missing)"), "unknown function: missing"),
            (self.program("(%+-primitive-i64 1 true)"), "type mismatch"),
            (self.program("(%+-primitive-i64 1)"), "primitive requires"),
            (self.program("(if 1 2 3)"), "type mismatch"),
            (self.program("(if true 1 false)"), "type mismatch"),
            (self.program("(if true 1)"), "if requires"),
            (self.program("(let ((x bool 1)) 0)"), "type mismatch"),
            (self.program("(let ((x i64 x)) x)"), "unknown local"),
            (self.program("(let ((x i64 1) (x i64 2)) x)"), "duplicate local"),
            (self.program("(let ((x i64 1 2)) x)"), "binding requires"),
            (self.program("(let ((true bool false)) 0)"), "expected identifier"),
            (self.program("(%+-primitive-i64 (let ((x i64 1)) x) x)"), "unknown local"),
            ("(%function f ((x i64)) i64 x)" + self.program("(f)"), "too few arguments"),
            ("(%function f () i64 1)" + self.program("(f 2)"), "too many arguments"),
            ("(%function f () i64 1)" + self.program("(let ((f i64 1)) (f))"), "not callable"),
            ("(%function unused () i64 true)" + self.program("0"), "type mismatch"),
            (self.program("(if true 1 (%+-primitive-i64 false 2))"), "type mismatch"),
            (self.program("0") + "\0", "NUL byte"),
        ]
        for source, message in cases:
            for mode in ("check", "eval", "emit-llvm", "compile", "compile-report"):
                with self.subTest(source=source, mode=mode):
                    args = ("-o", self.root / "should not exist") if mode.startswith("compile") else ()
                    result = self.run_core(mode, source, *args)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)
                    self.assertRegex(result.stderr, r"input\.vrn:\d+:\d+:")
                    self.assertEqual(result.stdout, "")
                    self.assertFalse((self.root / "should not exist").exists())

    def test_inferred_bindings(self):
        self.agrees(self.program(
            "(let ((x (cast i64 3)) (y (%+-primitive-i64 x 4))) "
            "(let ((x (%+-primitive-i64 x y)) (ok true) (u unit)) "
            "(if ok x 0)))"), 10)
        self.agrees("(%function id ((x i64)) i64 x)" + self.program(
            "(let ((id (cast i64 8))) id)"), 8)
        for expression, message in (
            ("(let ((x x)) x)", "unknown local"),
            ("(let ((x (cast i64 1)) (x (cast i64 2))) x)", "duplicate local"),
            ("(let ((f (cast i64 1))) (f))", "not callable"),
        ):
            result = self.run_core("check", self.program(expression))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(message, result.stderr)

    def test_semantic_recovery(self):
        cases = (
            ("(%function bad () nope 1)\n"
             "(%function other () i64 missing)\n" + self.program("(bad)"),
             ("unknown core type", "unknown local"), 2),
            ("(%function bad ((x i64) (x i64)) i64 x)\n"
             "(%function other () bool 1)\n" + self.program("0"),
             ("duplicate parameter", "expected bool, actual i64"), 2),
            ("(%function bad () i64 (%+-primitive-i64 missing 1))\n"
             "(%function other () bool 1)\n" + self.program("0"),
             ("unknown local", "expected bool, actual i64"), 2),
            (self.program("(if true missing absent)"),
             ("unknown local",), 2),
            ("(%function malformed)\n(%function other () i64 missing)\n" + self.program("0"),
             ("%function requires", "unknown local"), 2),
        )
        cases += (
            (self.program("(let ((f (cast i64 1))) (f))"), ("not callable",), 1),
            ("(%function bad () i64 " + "9" * 1000 + ")\n" + self.program("missing"),
             ("out of range", "unknown local"), 2),
        )
        for source, messages, count in cases:
            for mode in ("check", "eval", "emit-llvm", "compile", "compile-report"):
                with self.subTest(source=source, mode=mode):
                    output = self.root / "invalid-recovery"
                    args = ("-o", output) if mode.startswith("compile") else ()
                    result = self.run_core(mode, source, *args)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    for message in messages:
                        self.assertIn(message, result.stderr)
                    diagnostics = [line for line in result.stderr.splitlines()
                                   if "input.vrn:" in line and "note:" not in line]
                    self.assertEqual(len(diagnostics), count, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(output.exists())

    def test_type_diagnostic_origins(self):
        result = self.run_core("check",
            "(%function identity ((x i64)) i64 x)\n" +
            "(%function main () i64 (identity true))")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("input.vrn:2:34: type mismatch: expected i64, actual bool", result.stderr)
        self.assertIn("input.vrn:1:25: note: expected type established here", result.stderr)
        self.assertEqual(result.stderr.count("type mismatch"), 1)

    def test_runtime_failures_and_argument_order(self):
        cases = [
            (self.program("(%/-primitive-i64 1 0)"), "division by zero"),
            (self.program("(%/-primitive-i64 -9223372036854775808 -1)"), "signed division overflow"),
            ("(%function f ((a i64) (b i64)) i64 (%+-primitive-i64 a b))" +
             self.program("(f (%/-primitive-i64 1 0) (%/-primitive-i64 -9223372036854775808 -1))"), "division by zero"),
            (self.program("(%+-primitive-i64 (%/-primitive-i64 -9223372036854775808 -1) (%/-primitive-i64 1 0))"), "signed division overflow"),
            ("(%function bad () i64 (%/-primitive-i64 1 0))" + self.program("(bad)"), "division by zero"),
        ]
        for source, message in cases:
            with self.subTest(source=source):
                result = self.run_core("eval", source)
                self.assertEqual(result.returncode, 70, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertIn("in main", result.stderr)
                if "function bad" in source:
                    self.assertIn("in bad", result.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "failure"
                    result = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertIn(message, native.stderr)
                    self.assertEqual(native.stdout, "")
                    # Both engines must fail at the same expression, even when operands fail differently.
                    self.assertEqual(native.stderr.splitlines()[0],
                                     self.run_core("eval", source).stderr.splitlines()[0])

    def test_runtime_source_locations_and_frames(self):
        source = ("(%function bad () i64\n  (%/-primitive-i64 1 0))\n"
                  "(%function main () i64\n  (bad))")
        result = self.run_core("eval", source)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("input.vrn:2:3: division by zero", result.stderr)
        self.assertIn(f"in bad at {self.source}:4:3:", result.stderr)
        self.assertIn(f"in main at {self.source}:3:1:", result.stderr)
        self.assertLess(result.stderr.index("in bad"), result.stderr.index("in main"))
        self.assertEqual(result.stdout, "")

        for level in ("-O0", "-O2"):
            binary = self.root / "multiline failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(native.returncode, 70)
            self.assertEqual(native.stderr, f"{self.source}:2:3: division by zero\n")

    def test_locations_and_comments(self):
        result = self.run_core("check", "; comment\r\n(%function main () i64\r\n  unknown)\r\n")
        self.assertIn("input.vrn:3:3: unknown local", result.stderr)
        self.agrees("; before\n(%function main () i64 ; inside\n (%+-primitive-i64 2 3)) ; after", 5)

    def test_requires_expanded_compiler_forms(self):
        for mode in ("check", "eval", "emit-llvm", "compile", "compile-report"):
            for source, diagnostic in (
                ("(function main () i64 0)", "only %function declarations"),
                (self.program("(%+ 1 2)"), "unknown function"),
            ):
                with self.subTest(mode=mode, source=source):
                    args = ("-o", self.root / "unexpanded") if mode.startswith("compile") else ()
                    result = self.run_core(mode, source, *args)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(diagnostic, result.stderr)
                    self.assertFalse((self.root / "unexpanded").exists())

    def test_native_platform_conditionals(self):
        source = """
#+darwin (%type Platform u16)
#+linux (%type Platform u32)
#-pointer_64 (%type Platform Missing)
#+unknown-feature (%function broken () Missing invalid)
(%function main () i64
  (%zext-primitive-PLATFORM-i64
    (if true #+darwin (cast Platform 42) #+linux (cast Platform 42) (cast Platform 0))))
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

    def test_llvm_library_and_linker_boundary(self):
        environment = dict(os.environ, VERONA_CORE_CLANG="/nonexistent/compiler")
        source = "(%function choose ((x i64)) i64 (if (%<-primitive-i64 x 0) 7 (%+-primitive-i64 x 2)))" + self.program("(choose 40)")
        emitted = self.run_core("emit-llvm", source, env=environment)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("; ModuleID =", emitted.stdout)
        self.assertIn("phi i64", emitted.stdout)
        evaluated = self.run_core("eval", source, env=environment)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, "42\n")
        linker = shutil.which("clang")
        self.assertIsNotNone(linker)
        log = self.root / "link.json"
        wrapper = self.root / "link spy"
        wrapper.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, subprocess, sys\n"
            f"pathlib.Path({str(log)!r}).write_text(json.dumps({{'args': sys.argv[1:], "
            "'magic': pathlib.Path(sys.argv[1]).read_bytes()[:4].hex()}))\n"
            f"sys.exit(subprocess.run([{linker!r}, *sys.argv[1:]]).returncode)\n")
        wrapper.chmod(0o755)
        environment["VERONA_CORE_CLANG"] = str(wrapper)
        binary = self.root / "from object"
        compiled = self.run_core("compile", source, "-o", binary, env=environment)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        record = json.loads(log.read_text())
        self.assertEqual(record["args"][1:], ["-o", str(binary)])
        self.assertIn(record["magic"], ("cffaedfe", "feedfacf", "7f454c46"))
        self.assertFalse(Path(record["args"][0]).exists(), "temporary object was not removed")
        native = subprocess.run([str(binary)], capture_output=True, timeout=10)
        self.assertEqual(native.returncode, 42, native.stderr)

    def build_project(self, manifest, target="app", output="output directory", *options, env=None):
        (self.root / "verona.build").write_text(manifest)
        return subprocess.run([str(COMPILER), "build", target, str(output), *map(str, options)],
                              cwd=self.root, capture_output=True, text=True, timeout=60, env=env)

    def test_manifest_executable_and_defaults(self):
        (self.root / "main.vrn").write_text('(%function main () i32 42)')
        result = self.build_project('(executable app (root main))', output="nested output/inner")
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.root / "nested output/inner/app"
        self.assertEqual(Path(result.stdout.strip()), binary)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 42)
        for level in ("0", "+01", "2", "3", "-0"):
            result = self.build_project(f'(executable app (root main) (target native) (version "0.2.0") (optimize {level}))')
            self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "blocked").write_text("file")
        result = self.build_project('(executable app (root main))', output="blocked/child")
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot create output directory", result.stderr)

    def test_manifest_paths_features_and_imports(self):
        first = self.root / "first source"
        second = self.root / "second source"
        first.mkdir(); second.mkdir()
        (first / "main.vrn").write_text("""
(import dep)
#+cli (%function first () i32 (dep:value))
#-cli (%function first () i32 0)
#+package (%function main () i32 (first))
#-package (%function main () i32 1)
""")
        (first / "dep.vrn").write_text('#+package (%function value () i32 42) #-package (%function value () i32 0) (export value)')
        (second / "dep.vrn").write_text('(%function value () i32 99)(export value)')
        manifest = '(executable app (root main) (module-path "first source") (module-path "second source") (features PACKAGE))'
        result = self.build_project(manifest, "app", "out", "--feature", "CLI")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "out/app")], timeout=10).returncode, 42)
        result = self.build_project(manifest, "app", "out")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "out/app")], timeout=10).returncode, 0)

    def test_manifest_library_kinds_and_relative_link_paths(self):
        source = '(%function add ((a i32) (b i32)) i32 (+ a b))(native-export add "manifest_add")'
        (self.root / "api.vrn").write_text(source)
        (self.root / "main.vrn").write_text('(%external-function add "manifest_add" (i32 i32) i32)(%function main () i32 (add 20 22))')
        manifest = """
(static-library archive (root api))
(shared-library dynamic (root api) (optimize 2))
(executable app (root main) (library-path "native output") (library "archive"))
"""
        for name, extension in (("archive", "a"), ("dynamic", "dylib" if sys.platform == "darwin" else "so")):
            result = self.build_project(manifest, name, "native output")
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = self.root / f"native output/lib{name}.{extension}"
            self.assertEqual(Path(result.stdout.strip()), artifact)
            self.assertTrue(artifact.exists())
            self.assertTrue(artifact.with_suffix(".h").exists())
        result = self.build_project(manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(self.root / "output directory/app")], timeout=10).returncode, 42)

    def test_manifest_validation_and_no_evaluation(self):
        (self.root / "main.vrn").write_text('(%function main () i32 42)')
        valid = '(executable app (root main))'
        cases = (
            ('(executable app)', "requires exactly one root"),
            ('(executable app (root main) (root main))', "duplicate build option"),
            (valid + valid, "duplicate build target"),
            ('(executable app (root main) (mystery 1))', "unknown build option"),
            ('(executable app (root main) (module-path src))', "requires a data string"),
            ('(executable app (root main) (features))', "at least one feature"),
            ('(executable app (root main) (features 1))', "build name"),
            ('(executable app (root main) (features a) (features b))', "duplicate build option"),
            ('(executable app (root main) (version ""))', "non-empty single-line"),
            ('(executable app (root main) (version "a\\nb"))', "non-empty single-line"),
            ('(executable app (root main) (version "a") (version "b"))', "duplicate build option"),
            ('(executable app (root main) (optimize 0) (optimize 1))', "duplicate build option"),
            ('(executable app (root main) (optimize 4))', "integer from 0 through 3"),
            ('(executable app (root main) (optimize -1))', "integer from 0 through 3"),
            ('(executable app (root main) (optimize 1.0))', "integer from 0 through 3"),
            ('(executable app (root main) (target 1))', "native or a target-triple"),
            ('(executable app (root main) (target native) (target native))', "duplicate build option"),
            ('(executable app (root bad..module))', "dotted module"),
            ('(object app (root main))', "unknown top-level build form"),
            ("(compiler:state-set! 'side-effect 1)" + valid, "unknown top-level build form"),
            (valid + '(executable unselected (root main) (unknown 1))', "unknown build option"),
        )
        for manifest, message in cases:
            with self.subTest(manifest=manifest):
                result = self.build_project(manifest)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertIn("verona.build:", result.stderr)
                self.assertFalse((self.root / "output directory").exists())
        result = self.build_project(valid, "missing")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown build target", result.stderr)
        (self.root / "verona.build").unlink()
        result = subprocess.run([str(COMPILER), "build", "app", "out"], cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot find verona.build", result.stderr)
        for options in (("--feature",), ("--feature", ""), ("--unknown", "x")):
            result = self.build_project(valid, "app", "out", *options)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)

    def test_reader_features_and_cross_target_objects(self):
        source = """
#+requested (%function selected () i32 42)
#-requested (%function selected () i32 0)
#+linux (%function os () i32 1)
#-linux (%function os () i32 2)
#+x86_64 (%function arch () i32 3)
#-x86_64 (%function arch () i32 4)
#+pointer_64 (%function width () i32 64)
#+little_endian (%function endian () i32 1)
(%type Pair (product (a i64) (b i64) (c i64)))
(%function api ((p Pair)) Pair p)
(native-export api)
(%function main () i32 (%+-primitive-i32 (selected) (%+-primitive-i32 (os) (%+-primitive-i32 (arch) (%+-primitive-i32 (width) (endian))))))
"""
        for triple, magic in (("x86_64-unknown-linux-gnu", b"\x7fELF"), ("aarch64-unknown-linux-gnu", b"\x7fELF"),
                              ("x86_64-apple-darwin", b"\xcf\xfa\xed\xfe"), ("arm64-apple-darwin", b"\xcf\xfa\xed\xfe")):
            result = self.run_core("emit-llvm", source, "--target", triple, "--feature", "REQUESTED")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f'target triple = "{triple}"', result.stdout)
            self.assertEqual("byval(" in result.stdout, triple.startswith("x86_64"), result.stdout)
            evaluated = self.run_core("eval", source, "--target", triple, "--feature", "requested")
            self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
            expected = 42 + (1 if "linux" in triple else 2) + (3 if triple.startswith("x86_64") else 4) + 64 + 1
            self.assertEqual(evaluated.stdout, f"i32:{expected}\n")
            artifact = self.root / "cross.o"
            result = self.run_core("compile", source, "--emit", "object", "-o", artifact, "--target", triple, "--feature", "requested", "-O1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(artifact.read_bytes()[:4], magic)
        for triple in ("i386-unknown-linux-gnu", "x86_64-unknown-linux-gnux32", "riscv64-unknown-linux-gnu", "aarch64-unknown-windows", "nonsense"):
            result = self.run_core("compile", source, "--emit", "object", "-o", self.root / "bad.o", "--target", triple)
            self.assertEqual(result.returncode, 2)
            self.assertIn("unsupported target", result.stderr)

    def test_manifest_target_features_and_link_policy(self):
        (self.root / "api.vrn").write_text('#+x86_64 (%function value () i64 42) #-x86_64 (%function value () i64 0) (native-export value)')
        manifest = '(static-library api (root api) (target "x86_64-unknown-linux-gnu"))'
        result = self.build_project(manifest, "api", "out")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "out/libapi.a").exists())
        manifest = '(shared-library api (root api) (target "x86_64-unknown-linux-gnu") (framework "Foundation"))'
        result = self.build_project(manifest, "api", "bad-out")
        self.assertEqual(result.returncode, 2)
        self.assertIn("frameworks are supported only on Darwin", result.stderr)

    def test_native_artifact_outputs(self):
        source = """
(%function hidden ((a i32) (b i32)) i32 (+ a b))
(%function invert ((value bool)) bool (%not-primitive-bool value))
(native-export hidden "answer")
(native-export invert)
"""
        client = self.root / "client.c"
        for kind, extension in (("object", "o"), ("static-library", "a"),
                                ("shared-library", "dylib" if sys.platform == "darwin" else "so")):
            for level in ("-O0", "-O2"):
                artifact = self.root / f"library with spaces.{extension}"
                result = self.run_core("compile", source, "--emit", kind, "-o", artifact, level)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(artifact.exists())
                header = artifact.with_suffix(".h")
                if kind == "object":
                    self.assertFalse(header.exists())
                    declarations = "#include <stdbool.h>\nint answer(int, int); bool invert(bool);"
                else:
                    declarations = f'#include "{header.name}"'
                    self.assertIn("int32_t answer(int32_t arg0, int32_t arg1);", header.read_text())
                client.write_text(declarations + "\nint main(void) { return answer(20,22)==42 && invert(false) && !invert(true) ? 0 : 1; }\n")
                binary = self.root / "client"
                linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)], capture_output=True, text=True, timeout=30)
                self.assertEqual(linked.returncode, 0, linked.stderr)
                executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(executed.returncode, 0, executed.stderr)
                symbols = subprocess.run([shutil.which("llvm-nm") or "nm", "-g", str(artifact)], capture_output=True, text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                self.assertRegex(symbols.stdout, r"[Tt] _?answer\b")
                self.assertNotRegex(symbols.stdout, r"[Tt] _?hidden\b|[Tt] _?main\b")

    def test_native_export_aggregate_headers(self):
        source = """
(%type Pair (product (x i32) (flag bool)))
(%type Choice (sum (none) (some i64)))
(%type Bytes (array u8 3))
(%type Handle)
(%type Large (product (a i64) (b i64) (c i64)))
(%type Floats (product (x f64) (y f64)))
(%type Node (product (next (pointer Node)) (value i32)))
(%type LargeCallback (pointer (function (Large) Large)))
(%type Callback (pointer (function (i32) i32)))
(%function pair ((value Pair)) Pair (Pair (+ (field value x) 1) (%not-primitive-bool (field value flag))))
(%function choice ((value Choice)) Choice value)
(%function bytes ((value Bytes)) Bytes value)
(%function apply ((callback Callback) (value i32)) i32 (callback value))
(%function indirect ((value (pointer (pointer Handle)))) (pointer (pointer Handle)) value)
(%function large ((v Large)) Large (Large (+ (field v a) 1) (field v b) (field v c)))
(%function floats ((v Floats)) Floats (Floats (+ (field v x) 1.0) (field v y)))
(%function node ((v (pointer Node))) (pointer Node) v)
(%function apply-large ((callback LargeCallback) (v Large)) Large (callback v))
(%function getter () LargeCallback large)
(native-export large)
(native-export floats)
(native-export node)
(native-export apply-large "apply_large")
(native-export getter)
(native-export pair)
(native-export choice)
(native-export bytes)
(native-export apply)
(native-export indirect)
"""
        library = self.root / "aggregate.a"
        result = self.run_core("compile", source, "--emit", "static-library", "-o", library)
        self.assertEqual(result.returncode, 0, result.stderr)
        header = library.with_suffix(".h").read_text()
        pair = re.search(r"struct (\w+) pair\(", header).group(1)
        choice = re.search(r"struct (\w+) choice\(", header).group(1)
        array = re.search(r"struct (\w+) bytes\(", header).group(1)
        large = re.search(r"struct (\w+) large\(", header).group(1)
        floats = re.search(r"struct (\w+) floats\(", header).group(1)
        node = re.search(r"struct (\w+) \*node\(", header).group(1)
        self.assertIn("(*arg0)(int32_t)", header)
        self.assertRegex(header, r"struct \w+ \*\*indirect\(struct \w+ \*\*arg0\)")
        client = self.root / "aggregate.c"
        client.write_text(f"""
#include "aggregate.h"
static int32_t increment(int32_t x) {{ return x + 1; }}
static struct {large} callback(struct {large} v) {{ v.a += 1; return v; }}
int main(void) {{
  struct {pair} p = {{41, false}};
  p = pair(p);
  struct {choice} c = {{.tag=1, .payload.case1.field0=42}};
  c = choice(c);
  struct {array} a = {{.elements={{1,2,255}}}};
  a = bytes(a);
  struct {large} l = {{40, 2, 3}};
  l = apply_large(callback, l);
  l = getter()(l);
  struct {floats} f = {{41.0, 2.0}};
  f = floats(f);
  struct {node} n = {{0, 42}};
  return l.a==42 && l.b==2 && l.c==3 && f.x==42.0 && f.y==2.0 && node(&n)==&n && p.x==42 && p.flag && c.tag==1 && c.payload.case1.field0==42 &&
    a.elements[2]==255 && apply(increment,41)==42 && indirect(0)==0 ? 0 : 1;
}}
""")
        binary = self.root / "aggregate-client"
        linked = subprocess.run(["clang", "-Wall", "-Werror", str(client), str(library), "-o", str(binary)], capture_output=True, text=True, timeout=30)
        self.assertEqual(linked.returncode, 0, linked.stderr)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 0)

    def test_native_export_modules_and_identity(self):
        (self.root / "dep.vrn").write_text('(%function answer () i32 42)(native-export answer "dependency_answer")')
        source = """
(import dep)
(%type Callback (pointer (function () i32)))
(%function local () i32 42)
(%external-function imported "local_answer" () i32)
(native-export local "local_answer")
(%function main () i64
  (let ((a Callback local) (b Callback imported)) (if (== a b) 42 0)))
"""
        result = self.run_core("compile", source, "-o", self.root / "exports")
        self.assertEqual(result.returncode, 0, result.stderr)
        executed = subprocess.run([str(self.root / "exports")], capture_output=True, timeout=10)
        self.assertEqual(executed.returncode, 42, executed.stderr)
        result = self.run_core("compile", source + '(native-export local "dependency_answer")', "--emit", "object", "-o", self.root / "bad.o")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("duplicate native C export name", result.stderr)

    def test_invalid_native_exports(self):
        cases = (
            ('(native-export)', "native-export requires"),
            ('(native-export missing)', "must name a Verona function"),
            ('(%constant x i32 1)(native-export x)', "must name a Verona function"),
            ('(%external-function x "getpid" () i32)(native-export x)', "must name a Verona function"),
            ('(%function x () unit unit)(native-export x)', "C-compatible value types"),
            ('(%function x ((a (tuple i32 bool))) i32 1)(native-export x)', "C-compatible value types"),
            ('(%function x () i32 1)(native-export x 1)', "name must be data"),
            ('(%function x () i32 1)(native-export x "")', "name cannot be empty"),
            ('(%function x () i32 1)(native-export x "main")', "reserved"),
            ('(%function x () i32 1)(native-export x)(native-export x)', "duplicate native C export name"),
        )
        for source, message in cases:
            with self.subTest(source=source):
                result = self.run_core("compile", source, "--emit", "static-library", "-o", self.root / "bad.a")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertFalse((self.root / "bad.a").exists())

    def test_artifact_entry_and_options(self):
        library = '(%function main ((ignored bool)) bool ignored)'
        result = self.run_core("compile", library, "--emit", "object", "-o", self.root / "main.o")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_core("compile", library, "-o", self.root / "main")
        self.assertEqual(result.returncode, 2)
        self.assertIn("main must have", result.stderr)
        result = self.run_core("compile", '(%function value () i32 42)', "-o", self.root / "main")
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing main", result.stderr)
        for mode, options in (("compile", ["--emit"]), ("compile", ["--emit", "unknown"]),
                              ("eval", ["--emit", "object"]), ("compile-report", ["--emit", "static-library"])):
            result = self.run_core(mode, self.program("42"), "-o", self.root / "output", *options)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)

    def test_artifact_tool_failure_cleanup(self):
        source = '(%function value () i32 42)(native-export value)'
        log = self.root / "args.json"
        wrapper = self.root / "failing tool"
        wrapper.write_text(f"#!{sys.executable}\nimport json,pathlib,sys\npathlib.Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\nsys.exit(1)\n")
        wrapper.chmod(0o755)
        for kind, key in (("static-library", "VERONA_CORE_AR"), ("shared-library", "VERONA_CORE_CLANG")):
            artifact = self.root / "output.library"
            result = self.run_core("compile", source, "--emit", kind, "-o", artifact, env=dict(os.environ, **{key: str(wrapper)}))
            self.assertEqual(result.returncode, 2, result.stderr)
            args = json.loads(log.read_text())
            if kind == "static-library":
                self.assertEqual(args[:2], ["rcs", str(artifact)])
                temporary = args[2]
            else:
                self.assertEqual(args[0], "-dynamiclib" if sys.platform == "darwin" else "-shared")
                temporary = args[1]
            self.assertFalse(Path(temporary).exists())
            self.assertFalse(artifact.exists())
            self.assertFalse(artifact.with_suffix(".h").exists())

    def test_native_library_linking(self):
        directory = self.root / "library directory with spaces"
        directory.mkdir()
        source = directory / "answer.c"
        source.write_text("#include <stdint.h>\nint64_t native_answer(void) { return 42; }\n")
        obj = directory / "answer.o"
        compiled = subprocess.run(["clang", "-c", str(source), "-o", str(obj)], capture_output=True, text=True, timeout=30)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        archive = directory / "libanswer.a"
        archived = subprocess.run([os.environ.get("VERONA_AR", shutil.which("llvm-ar") or "ar"), "rcs", str(archive), str(obj)], capture_output=True, text=True, timeout=30)
        self.assertEqual(archived.returncode, 0, archived.stderr)
        program = '(%external-function answer "native_answer" () i64)(%function main () i64 (answer))'
        for path_option, library_option in (("--library-path", "--library"), ("-L", "-l")):
            binary = self.root / "linked executable"
            result = self.run_core("compile-report", program, "-o", binary, path_option, directory, library_option, "answer")
            self.assertEqual(result.returncode, 0, result.stderr)
            executed = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(executed.returncode, 0, executed.stderr)
            self.assertEqual(executed.stdout, "i64:42\n")

    def test_link_options_order_and_growth(self):
        log = self.root / "arguments.json"
        wrapper = self.root / "link argument recorder"
        wrapper.write_text(f"#!{sys.executable}\nimport json, pathlib, sys\n"
                           f"pathlib.Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\n"
                           "sys.exit(1)\n")
        wrapper.chmod(0o755)
        environment = dict(os.environ, VERONA_CORE_CLANG=str(wrapper))
        binary = self.root / "output with spaces"
        # Interleave classes; the reference groups paths, libraries, then frameworks.
        options = ["--library", "first", "-L", "path one", "-l", "second", "--library-path", "path two"]
        expected = ["-L", "path one", "-L", "path two", "-lfirst", "-lsecond"]
        if sys.platform == "darwin":
            options += ["--framework", "Core Foundation", "--framework", "Security"]
            expected += ["-framework", "Core Foundation", "-framework", "Security"]
        # Force several reallocations of both option and exec argument arrays.
        libraries = [f"extra{index}" for index in range(80)]
        options += [part for library in libraries for part in ("--library", library)]
        library_end = 6
        expected[library_end:library_end] = ["-l" + library for library in libraries]
        result = self.run_core("compile", self.program("0"), *options, "-o", binary, env=environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("native compilation failed", result.stderr)
        args = json.loads(log.read_text())
        self.assertEqual(args[1:], [*expected, "-o", str(binary)])
        self.assertFalse(Path(args[0]).exists(), "temporary object survived linker failure")
        self.assertFalse(binary.exists())

    def test_invalid_link_options(self):
        for mode in ("read", "check", "eval", "emit-llvm"):
            for option in ("--library", "-l", "--library-path", "-L", "--framework"):
                result = self.run_core(mode, self.program("0"), option, "value")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
        for option in ("--library", "-l", "--library-path", "-L", "--framework", "-lanswer", "-Ldirectory"):
            result = self.run_core("compile", self.program("0"), "-o", self.root / "missing value", option)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("usage:", result.stderr)
        if sys.platform != "darwin":
            result = self.run_core("compile", self.program("0"), "-o", self.root / "framework", "--framework", "Foundation")
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("frameworks are supported only on Darwin", result.stderr)

    def test_link_failure_cleans_up(self):
        log = self.root / "failed.json"
        wrapper = self.root / "failing linker"
        wrapper.write_text(
            f"#!{sys.executable}\n"
            "import json, pathlib, sys\n"
            f"pathlib.Path({str(log)!r}).write_text(json.dumps(sys.argv[1:]))\n"
            "sys.exit(1)\n")
        wrapper.chmod(0o755)
        environment = dict(os.environ, VERONA_CORE_CLANG=str(wrapper))
        binary = self.root / "failed output"
        result = self.run_core("compile", self.program("0"), "-o", binary, env=environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("native compilation failed", result.stderr)
        self.assertFalse(binary.exists())
        args = json.loads(log.read_text())
        self.assertEqual(args[1:], ["-o", str(binary)])
        self.assertFalse(Path(args[0]).exists(), "temporary object was not removed")

    def test_unit_and_nested_control_flow(self):
        self.agrees("(%function noop ((x unit)) unit (if true x unit))" + self.program(
            "(let ((u (if (if true false true) unit (noop unit)))) "
            "(if (if false true (%=-primitive-i64 2 2)) "
            "(if true 1234567890123456789 2) (if false 3 4)))"), 1234567890123456789)
        # A unit argument must still be evaluated, even though it carries no information.
        source = ("(%function use ((x unit)) i64 9)" + self.program(
            "(use (let ((bad (%/-primitive-i64 1 0))) unit))"))
        result = self.run_core("compile-report", source, "-o", self.root / "unit", "-O2")
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(self.root / "unit")], capture_output=True, text=True)
        self.assertEqual(native.returncode, 70)
        self.assertIn("division by zero", native.stderr)
        # Filenames must be encoded as data in IR and must never become format strings.
        self.source = self.root / 'quote" slash\\ percent%s.vrn'
        result = self.run_core("compile-report", source, "-o", self.root / "quoted")
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(self.root / "quoted")], capture_output=True, text=True)
        self.assertIn(str(self.source) + ":1:", native.stderr)

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

    def test_cli_and_limits(self):
        for args in ([], ["unknown"], ["eval"], ["compile", "x", "-bad", "y"],
                     ["eval", "x", "--module-path"], ["eval", "x", "--module-path", ""],
                     ["eval", "x", "-o", "y"]):
            result = subprocess.run([str(COMPILER), *args], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage:", result.stderr)
        result = self.run_core("check", " " * 65537)
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing main function", result.stderr)
        result = self.run_core("check", "(" * 258)
        self.assertEqual(result.returncode, 2)
        self.assertIn("unclosed list", result.stderr)
        result = subprocess.run([str(COMPILER), "eval", str(self.root / "missing")],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn("module not found", result.stderr)
        environment = dict(os.environ, VERONA_CORE_CLANG="/nonexistent/compiler")
        result = self.run_core("compile", self.program("0"), "-o", self.root / "out", env=environment)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("native compilation failed", result.stderr)
        self.assertFalse((self.root / "out").exists())


if __name__ == "__main__":
    unittest.main()
