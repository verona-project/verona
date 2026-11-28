"""Bindings, control flow, patterns, and diagnostics."""

import subprocess

from .support import CompilerTestCase


class SemanticTests(CompilerTestCase):
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

    def test_do_and_multiple_expression_let_bodies(self):
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

    def test_match_catch_all_binds_integer(self):
        self.agrees(self.program("(match (cast i64 42) (value value))"), 42)

    def test_match_catch_all_shadows_outer_sum_binding(self):
        self.agrees("""
(%type S (sum (Value i64) (Empty)))
(%function main () i64
  (let ((value i64 40))
    (%+-primitive-i64 value
      (match (Value 2)
        (value (match value ((Value x) x) ((Empty) 0)))))))
""", 42)

    def test_match_catch_all_binds_float(self):
        self.agrees(self.program("(match (cast f64 42.5) (value (%fptosi-primitive-f64-i64 value)))"), 42)

    def test_match_wildcard_accepts_unit(self):
        self.agrees(self.program("(match unit (_ 42))"), 42)

    def test_match_catch_all_binds_product(self):
        self.agrees("""
(%type P (product (value i64)))
(%function main () i64 (match (P 42) (value (field value value))))
""", 42)

    def test_match_catch_all_binds_tuple(self):
        self.agrees(self.program("(match (tuple (cast i64 42)) (value (tuple-get value 0)))"), 42)

    def test_match_catch_all_binds_array(self):
        self.agrees(self.program("(match (array-of (cast i64 42)) (value (index value 0)))"), 42)

    def test_match_catch_all_accepts_generated_literal_spelling(self):
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
            (self.program("(match 1 (true 2) (false 3))"), "ambiguous numeric literal"),
            (self.program("(match true (true 1) (false false))"), "type mismatch"),
            (self.program("(if true 1)"), "unknown function: if"),
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
            (self.program("(match true (true 1) (false (%+-primitive-i64 false 2)))"), "type mismatch"),
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
            "(match ok (true x) (false 0))))"), 10)
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
            (self.program("(match true (true missing) (false absent))"),
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
                                   if "input.vrn:" in line and "error[" in line]
                    self.assertEqual(len(diagnostics), count, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(output.exists())

    def test_type_diagnostic_origins(self):
        result = self.run_core("check",
            "(%function identity ((x i64)) i64 x)\n" +
            "(%function main () i64 (identity true))")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stdout, "")
        lines = result.stderr.splitlines()
        self.assertEqual([line for line in lines if line.startswith(str(self.source))], [
            f"{self.source}:2:34: error[type-mismatch]: type mismatch: expected i64, actual bool",
            f"{self.source}:1:25: note[expected-type-origin]: expected type established here",
        ])

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
                    self.assert_runtime_diagnostic_matches(native, self.run_core("eval", source))

    def test_runtime_source_locations_and_frames(self):
        source = ("(%function bad () i64\n  (%/-primitive-i64 1 0))\n"
                  "(%function main () i64\n  (bad))")
        result = self.run_core("eval", source)
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn("input.vrn:2:3: error[division-by-zero]: division by zero", result.stderr)
        self.assertIn(f"{self.source}:4:3: note[evaluator-call-frame]: in bad", result.stderr)
        self.assertIn(f"{self.source}:3:1: note[evaluator-call-frame]: in main", result.stderr)
        self.assertLess(result.stderr.index("in bad"), result.stderr.index("in main"))
        self.assertEqual(result.stdout, "")

        for level in ("-O0", "-O2"):
            binary = self.root / "multiline failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(native.returncode, 70)
            self.assertEqual(native.stderr, f"{self.source}:2:3: division by zero\n")

    def test_unit_argument_is_evaluated(self):
        # A unit argument must still be evaluated, even though it carries no information.
        source = ("(%function use ((x unit)) i64 9)" + self.program(
            "(use (let ((bad (%/-primitive-i64 1 0))) unit))"))
        result = self.run_core("compile-report", source, "-o", self.root / "unit", "-O2")
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(self.root / "unit")], capture_output=True, text=True)
        self.assertEqual(native.returncode, 70)
        self.assertIn("division by zero", native.stderr)

    def test_native_diagnostic_preserves_quoted_source_path(self):
        self.source = self.root / 'quote" slash\\ percent%s.vrn'
        source = self.program("(%/-primitive-i64 1 0)")
        result = self.run_core("compile-report", source, "-o", self.root / "quoted")
        self.assertEqual(result.returncode, 0, result.stderr)
        native = subprocess.run([str(self.root / "quoted")], capture_output=True, text=True)
        self.assertEqual(native.returncode, 70, native.stderr)
        self.assertIn(str(self.source) + ":1:", native.stderr)

    def test_control_flow_program(self):
        self.named_cases("control_flow.vrn", 20)

    def test_scalar_match_patterns(self):
        self.named_cases("scalar_patterns.vrn", 11)

    def test_aggregate_patterns_program(self):
        self.named_cases("aggregate_patterns.vrn", 10)
