"""Generic dispatch, specialization, and protocol evidence."""

import re
import subprocess

from .support import CompilerTestCase


RESULT_DIRECTED_GENERIC_SOURCE = """
(%export convert)
(%generic convert (value))
(%implementation convert ((value i64)) i64 value)
(%implementation convert ((value i64)) u8 (%trunc-primitive-i64-u8 value))
"""

CONCRETE_ADDITION_SOURCE = """
(%generic + (left right))
(%implementation + ((left i64) (right i64)) i64 (%+-primitive-i64 left right))
(%implementation + ((left u8) (right u8)) u8 (%+-primitive-u8 left right))
"""

CONSTRAINED_ADDITION_SOURCE = """
(%protocol numeric (a) (+ ((x a) (y a)) a))
(%implementation (numeric u8)
  (function + ((x u8) (y u8)) u8 (%+-primitive-u8 x y)))
(%implementation (numeric i64)
  (function + ((x i64) (y i64)) i64 (%+-primitive-i64 x y)))
(%function add (for (a) ((numeric a))) ((x a) (y a)) a (+ x y))
"""

BOUNDED_PROTOCOL_SOURCE = """
(%export bounded minBound)
(%protocol bounded (a)
  (minBound () a)
  (pair ((x a)) (tuple a a)))
(%generic minBound ())
(%implementation (bounded i64)
  (function minBound () i64 40)
  (function pair ((x i64)) (tuple i64 i64) (tuple x x)))
"""


class GenericTests(CompilerTestCase):
    def test_default_numeric_generics(self):
        self.named_cases("numeric_generics.vrn", 113)

    def test_default_operator_literal_inference(self):
        self.agrees(self.program("(+ 40 2)"), 42)
        self.agrees("""
(%macro identity (form) form)
(%function narrow () u8 (+ 40 (identity 2)))
(%function main () i64 (%zext-primitive-u8-i64 (narrow)))
""", 42)
        self.agrees(self.program("(%zext-primitive-u8-i64 (+ (cast u8 40) 2))"), 42)
        for expression in ("(+ 1 (cast u8 1))", "(+ (cast u8 1) 1)"):
            with self.subTest(expression=expression):
                result = self.run_core("check", f"(%function main () unit (do {expression} unit))")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_operators_reject_ambiguous_literals(self):
        for expression in ("(+ 1 1)", "(== 1 1)", "(< 1 2)"):
            with self.subTest(expression=expression):
                result = self.run_core("check", f"(%function main () unit (do {expression} unit))")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("ambiguous numeric literal", result.stderr)

    def test_lexical_function_overrides_default_addition(self):
        self.agrees("""
(%function + ((left i64) (right i64)) i64 42)
(%function main () i64 (+ 1 2))
""", 42)

    def test_declared_boolean_addition_generic_is_used(self):
        self.agrees("""
(%generic + (left right))
(%implementation + ((left bool) (right bool)) i64 42)
(%function main () i64 (+ true false))
""", 42)

    def test_default_addition_accepts_product_overload(self):
        self.agrees("""
(%type Point (product (value i64)))
(%implementation + ((left Point) (right Point)) Point (Point (+ (field left value) (field right value))))
(%function main () i64 (field (+ (Point 40) (Point 2)) value))
""", 42)

    def test_expected_result_type_selects_addition_overload(self):
        # Same input types, different results: context selects the implementation.
        self.agrees("""
(%implementation + ((left i64) (right i64)) bool true)
(%function boolean ((value bool)) bool value)
(%function main () i64 (match (boolean (+ (cast i64 1) 2)) (true (+ 40 2)) (false 0)))
""", 42)

    def test_function_pointer_parameter_shadows_default_addition(self):
        self.agrees("""
(%type Callback (pointer (function (i64 i64) i64)))
(%function answer ((left i64) (right i64)) i64 42)
(%function apply ((+ Callback)) i64 (+ 1 2))
(%function main () i64 (apply answer))
""", 42)

    def test_protocol_evidence_overrides_default_addition(self):
        # Protocol evidence overrides the implicit generic, even for numeric types.
        self.agrees("""
(%protocol Custom (a) (+ ((left a) (right a)) a))
(%implementation (Custom i64) (function + ((left i64) (right i64)) i64 42))
(%function apply (for (a) ((Custom a))) ((left a) (right a)) a (+ left right))
(%function main () i64 (apply (cast i64 1) (cast i64 2)))
""", 42)

    def test_qualified_operator_calls_imported_function(self):
        (self.root / "operators.vrn").write_text("(%export +)(%function + ((a i64) (b i64)) i64 42)")
        self.agrees("(%import operators :as op)(%function main () i64 (op:+ 1 2))", 42)

    def test_imported_type_can_extend_default_addition(self):
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

    def test_imported_explicit_generic_preserves_callers_default_addition(self):
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

    def test_default_signed_division_truncates_toward_zero(self):
        self.agrees(self.program("(/ (cast i64 -85) 2)"), -42)

    def test_default_unsigned_comparison_preserves_high_bit(self):
        self.agrees(self.program("(match (> (cast u64 18446744073709551615) 1) (true 42) (false 0))"), 42)

    def test_default_division_reports_runtime_failures(self):
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

    def test_imported_generic_dispatch_uses_expected_result_type(self):
        (self.root / "library.vrn").write_text(RESULT_DIRECTED_GENERIC_SOURCE)
        self.agrees("""
(%import library :as lib)
(%function small ((value i64)) u8 (lib:convert value))
(%function main () i64
  (let ((n i64 (lib:convert 40)))
    (%+-primitive-i64 n (%zext-primitive-u8-i64 (small 2)))))
""", 42)

    def test_concrete_operator_overload_infers_literal_operand_type(self):
        for expression in ("(+ (cast u8 40) 2)", "(+ 40 (cast u8 2))"):
            with self.subTest(expression=expression):
                self.agrees(CONCRETE_ADDITION_SOURCE + self.program(
                    f"(%zext-primitive-u8-i64 {expression})"), 42)

    def test_check_rejects_invalid_concrete_generic_dispatch(self):
        for source, message in (
            (CONCRETE_ADDITION_SOURCE + self.program("(let ((value (+ 40 2))) 0)"),
             "ambiguous numeric literal"),
            (RESULT_DIRECTED_GENERIC_SOURCE.replace("(%export convert)", "") + self.program("(let ((value (convert 2))) 0)"),
             "ambiguous generic implementation"),
            (CONCRETE_ADDITION_SOURCE + self.program("(+ true false)"), "no matching generic implementation"),
            (CONCRETE_ADDITION_SOURCE + self.program("(+ (cast i64 1))"), "wrong generic argument count"),
            (CONCRETE_ADDITION_SOURCE + "(%implementation + ((a i64) (b i64)) i64 a)" + self.program("0"),
             "duplicate generic implementation"),
            ("(%generic f (x))(%implementation f () i64 42)" + self.program("0"),
             "implementation arity does not match generic"),
        ):
            with self.subTest(message=message):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

    def test_constrained_function_specializes_for_each_used_type(self):
        source = CONSTRAINED_ADDITION_SOURCE + self.program("""
(%+-primitive-i64
  (%zext-primitive-u8-i64 (add (cast u8 8) 2))
  (%+-primitive-i64 (%zext-primitive-u8-i64 (add (cast u8 9) 1))
                   (add (cast i64 20) 2)))
""")
        self.agrees(source, 42)
        ir = self.run_core("emit-llvm", source)
        self.assertEqual(ir.returncode, 0, ir.stderr)
        # One u8 method and one u8 specialization despite the two calls.
        self.assertEqual(len(re.findall(r'define internal i8 @"?vrn\.input\.[^"(]+"?\(', ir.stdout)), 2)
        self.assertIn("@vrn.input._2b__impl.input.numeric.u8", ir.stdout)
        self.assertIn("@vrn.input._2b__impl.input.numeric.i64", ir.stdout)
        self.assertIn("@vrn.input.add__g.u8", ir.stdout)
        self.assertIn("@vrn.input.add__g.i64", ir.stdout)

    def test_recursive_constrained_function_reuses_specialization(self):
        self.agrees(CONSTRAINED_ADDITION_SOURCE + """
(%function countdown (for (a) ((numeric a))) ((value a) (depth i64)) a
  (match (%=-primitive-i64 depth 0) (true value) (false (countdown (add value value) (%--primitive-i64 depth 1)))))
(%function main () i64 (countdown (cast i64 21) 1))
""", 42)

    def test_specialize_tuple_projection_for_element_type(self):
        self.agrees("""
(%function first (for (a)) ((value (tuple a))) a (tuple-get value 0))
(%function main () i64 (first (tuple (cast i64 42))))
""", 42)

    def test_check_rejects_invalid_constrained_function_use(self):
        for source, message in (
            (CONSTRAINED_ADDITION_SOURCE + self.program("(add (cast u16 40) 2)"), "missing protocol implementation"),
            (CONSTRAINED_ADDITION_SOURCE + self.program("(add 40 (cast i64 2))"), "ambiguous numeric literal"),
            (CONSTRAINED_ADDITION_SOURCE + self.program("(add (cast u8 40) (cast i64 2))"), "conflicting type argument"),
            (CONSTRAINED_ADDITION_SOURCE + self.program("(add (cast i64 42))"), "wrong parametric function argument count"),
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

    def test_imported_protocol_dispatch_respects_result_type(self):
        (self.root / "library.vrn").write_text(BOUNDED_PROTOCOL_SOURCE)
        self.agrees("""
(%import library :as lib)
(%implementation (lib:bounded u8)
  (function minBound () u8 2)
  (function pair ((x u8)) (tuple u8 u8) (tuple x x)))
(%function small () u8 (lib:minBound))
(%function main () i64
  (%+-primitive-i64 (lib:minBound) (%zext-primitive-u8-i64 (small))))
""", 42)

    def test_protocol_method_is_available_inside_its_module(self):
        self.agrees(BOUNDED_PROTOCOL_SOURCE + """
(%implementation minBound () i64 42)
(%function main () i64 (minBound))
""", 42)

    def test_protocol_accepts_pointer_to_opaque_type(self):
        self.agrees("""
(%type Handle)
(%protocol forwarding (a) (forward ((value (pointer a))) (pointer a)))
(%implementation (forwarding Handle)
  (function forward ((value (pointer Handle))) (pointer Handle) value))
(%function main () i64 42)
""", 42)

    def test_check_rejects_invalid_protocol_declarations_and_use(self):
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
