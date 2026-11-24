"""Macro expansion and compile-time evaluation."""

import json
import struct
import subprocess
import sys

from .support import CompilerTestCase, FIXTURE_DIR, REPO_ROOT


class MacroTests(CompilerTestCase):
    def test_base_function_preserves_runtime_nil(self):
        self.agrees("""
(import base)
(base:function absent () (pointer u8) nil)
(%function main () i64
  (match (%is-null-primitive-pointer (absent)) (true 42) (false 0)))
""", 42, "--module-path", REPO_ROOT / "projects/base/src")

    def test_compile_time_helper_parity(self):
        inventory = json.loads((FIXTURE_DIR / "compile_time_parity.json").read_text())
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
        inventory = json.loads((FIXTURE_DIR / "compile_time_parity.json").read_text())
        host = self.reference_compiler
        for operation in inventory["operations"]:
            if operation["status"] != "implemented":
                continue
            expression = "(and " + " ".join(operation["positive"]) + ")"
            source = ("(%macro result () (cond (" + expression + " 42) (true 0)))"
                      "(%function main () exit-code (result))")
            with self.subTest(operation=operation["name"]):
                self.source.write_text(source)
                binary = self.root / "reference-helper"
                compiled = subprocess.run([str(host), "compile", str(self.source), "-o", str(binary)],
                                          capture_output=True, text=True, timeout=30)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                self.assertEqual(native.returncode, 42, native.stderr)

    def test_macro_list_length_expands_to_integer(self):
        self.agrees("(%macro result () (length '(a b c)))" + self.program('(result)'), 3)

    def test_macro_generated_identifier_can_be_named_true(self):
        self.agrees('(%macro result () `(let ((,(symbol "true") i64 42)) ,(symbol "true")))' +
                    self.program('(result)'), 42)

    def test_macro_rejects_access_to_empty_list(self):
        for operation in ("car", "cdr"):
            result = self.run_core("eval", f"(%macro result () ({operation} nil))" + self.program("(result)"))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("non-empty", result.stderr)

    def test_macro_definitions_emit_multiple_declarations(self):
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
        base = REPO_ROOT / "projects/base/src"
        self.agrees("""(%import base :as b)
(%macro define (name &rest declaration)
  (cons 'b:function (cons name declaration)))
(define main () i64 42)
""", 42, "--module-path", base)
        for source, message in (
            ("(define main () i64 42)(%macro define (&rest xs) (cons '%function xs))",
             "only %function declarations"),
            ("(%macro define (x) x)(define)", "missing macro argument"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_expression_macro_expands_in_scalar_contexts(self):
        self.agrees("""
(%macro identity (form) form)
(%function narrow () i8 (identity 40))
(%function main () i64
  (let ((value i64 (identity (cast i64 (identity 2)))))
    (do (identity unit)
      (match (identity true) (true (%+-primitive-i64 (%sext-primitive-i8-i64 (narrow)) (identity value))) (false 0)))))
""", 42)

    def test_expression_macro_head_and_value_resolve_separately(self):
        self.agrees("""
(%macro identity (form) form)
(%function answer ((identity i64)) i64 (identity identity))
(%function main () i64 (later (answer 42)))
(%macro later (form) form)
""", 42)

    def test_expression_macro_expands_pointer_offset(self):
        self.agrees("""
(%macro identity (form) form)
(%function main () i64
  (%zext-primitive-u8-i64 (deref (pointer-offset "abc" (identity 2)))))
""", 99)

    def test_unused_generic_body_does_not_expand_expression_macro(self):
        # Expression expansion must remain lazy for unused generic bodies.
        checked = self.run_core("check", """
(%macro broken () (missing))
(%function unused (for (T)) ((value T)) T (broken))
(%function main () i64 42)
""")
        self.assertEqual(checked.returncode, 0, checked.stderr)

    def test_expression_macro_preserves_contextual_argument_type(self):
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
(%function main () i64 (match (choose (cast i64 0)) (true 42) (false 0)))
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
(%function main () i64 (match (%=-primitive-i64 (value) 42) (true (result)) (false 0)))
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
  (match (%=-primitive-i64 (left 2 50 10) -58) (true (match (%=-primitive-i64 (right 2 50 10) 42) (true (match (%=-primitive-i64 (left 42) (right 42)) (true 42) (false 0))) (false 0))) (false 0)))
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
        base = REPO_ROOT / "projects/base/src"
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

    def test_quasiquote_splices_arguments_into_declaration(self):
        self.agrees("""
(%macro define (name &rest body)
  `(%function ,name () i64 (%--primitive-i64 ,@body)))
(define main 44 2)
""", 42)

    def test_quasiquote_preserves_unquotes_for_generated_macro(self):
        self.agrees("""
(%macro define (value)
  `(%macro emit-main ()
     `(%function main () i64 ,,value)))
(define 42)
(emit-main)
""", 42)

    def test_quasiquote_splices_empty_argument_list(self):
        self.agrees("""
(%macro define (&rest args)
  `(%function main () i64 (%+-primitive-i64 ,@args 40 2)))
(define)
""", 42)

    def test_explicit_quasiquote_and_unquote_expand_declaration(self):
        self.agrees("""
(%macro define (value)
  (quasiquote (%function main () i64 (unquote value))))
(define 42)
""", 42)

    def test_quasiquote_rejects_invalid_splices(self):
        for source, message in (
            ("(%macro bad () `(,@42))(bad)", "unquote-splicing requires a list"),
            ("(%macro bad () `,@'())(bad)", "unquote-splicing requires a list element"),
            ("(%macro bad () ,42)(bad)", "unquote is valid only inside quasiquote"),
        ):
            with self.subTest(source=source):
                result = self.run_core("check", source)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(message, result.stderr)

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

    def test_repeated_macro_templates_fit_syntax_budget(self):
        self.named_cases("macro_templates.vrn", 1)
