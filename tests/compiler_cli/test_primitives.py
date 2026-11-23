"""Primitive operations, literals, and numeric boundaries."""

import struct
import subprocess

from .support import CompilerTestCase, REPO_ROOT


class PrimitiveTests(CompilerTestCase):
    def test_data_and_character_literals(self):
        source = r"""
(%function choose ((flag bool)) (pointer u8)
  (match flag (true "a\n\t\"\\%") (false "")))
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

    def test_reader_rejects_invalid_data_and_character_literals(self):
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

    def test_character_literal_has_unsigned_type(self):
        result = self.run_core("check", r"(%function main () i8 #\a)")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("expected i8, actual u8", result.stderr)

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

    def test_check_rejects_invalid_floating_point_literals(self):
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

    def test_boolean_primitives(self):
        self.named_cases("boolean.vrn", 18)

    def test_boolean_primitives_evaluate_both_operands(self):
        for operation in ("%and-primitive-bool false", "%or-primitive-bool true"):
            source = self.program(f"(match ({operation} (%=-primitive-i64 (%/-primitive-i64 1 0) 0)) (true 1) (false 0))")
            with self.subTest(operation=operation, mode="eval"):
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
            for level in ("-O0", "-O2"):
                with self.subTest(operation=operation, mode=level):
                    binary = self.root / "eager executable"
                    compiled = self.run_core("compile", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)

    def test_boolean_primitives_reject_invalid_operands(self):
        for expression in ("(%not-primitive-bool)", "(%not-primitive-bool true false)",
                           "(%and-primitive-bool true)", "(%=-primitive-bool (cast i64 0) true)"):
            with self.subTest(expression=expression):
                result = self.run_core("check", self.program(f"(match {expression} (true 42) (false 0))"))
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_base_boolean_operations(self):
        host = self.reference_compiler
        base = REPO_ROOT / "projects/base/src"
        source = self.root / "input.vrn"
        manifest = self.root / "verona.build"
        binary = self.root / "out" / "boolean"
        prefix = "(import base :as b)\n"
        body = """
(%external-function abort "abort" () void)
(%function fail () bool (do (abort) false))
(%function record ((trace (pointer i64)) (digit i64) (value bool)) bool
  (do (store (deref trace) (%+-primitive-i64 (%*-primitive-i64 (deref trace) 10) digit))
    value))
(%function guarded ((values (pointer bool)) (index u64) (count u64)) bool
  (b:and-then (%<-primitive-u64 index count) (deref (pointer-offset values index))))
(b:macro nested (value) `(b:and-then ,value (b:not false)))
(%function main () exit-code
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
                result = build(f"(%function main () exit-code (match {expression} (true 0) (false 1)))", 0)
                self.assertNotEqual(result.returncode, 0)

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

    def test_unsigned_byte_main_preserves_native_exit_status(self):
        binary = self.root / "byte-result"
        result = self.run_core("compile", "(%function main () u8 255)", "-o", binary)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(subprocess.run([str(binary)], timeout=10).returncode, 255)

    def test_numeric_program(self):
        self.named_cases("numeric.vrn", 13)

    def test_signed_comparisons(self):
        self.named_cases("signed_comparisons.vrn", 15)
