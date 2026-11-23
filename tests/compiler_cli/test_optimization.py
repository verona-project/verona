"""Verona simplifications and optimization reports."""

import re
import shutil
import subprocess

from .support import CompilerTestCase


class OptimizationTests(CompilerTestCase):
    def test_beta_known_function_binding_eliminates_calls(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%function twice ((value i64)) i64 (%+-primitive-i64 value value))
(%function apply ((value i64)) i64
  (let ((bound Callback twice) (alias bound)) (alias value)))
(%function apply-unknown ((callback Callback) (value i64)) i64 (callback value))
(native-export apply "apply_bound")
(native-export apply-unknown "apply_unknown")
(%function main () i64 (apply 21))
"""
        self.agrees(source, 42)
        nm = shutil.which("llvm-nm") or shutil.which("nm")
        self.assertIsNotNone(nm)
        client = self.root / "beta-client.c"
        client.write_text("""
#include <stdint.h>
#include <stdlib.h>
typedef int64_t (*callback)(int64_t);
extern int64_t apply_bound(int64_t);
extern int64_t apply_unknown(callback, int64_t);
static int64_t triple(int64_t n) { return n * 3; }
int main(int argc, char **argv) {
  int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 21;
  return apply_bound(n) == n * 2 && apply_unknown(triple, 14) == 42 ? 0 : 1;
}
""")
        for level in ("-O0", "-O1", "-O2", "-O3"):
            with self.subTest(level=level):
                artifact = self.root / "beta.o"
                compiled = self.run_core("compile", source, "--emit", "object",
                                         "-o", artifact, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                symbols = subprocess.run([nm, str(artifact)], capture_output=True,
                                         text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                # Private implementations/adapters use the internal Verona namespace. Their
                # removal proves the used bodies were substituted, with exported
                # APIs still accepting runtime inputs from a separately built client.
                pattern = r"(?m)\b[tT] _?vrn\.input\.[\w.]+$"
                if level == "-O0":
                    self.assertRegex(symbols.stdout, pattern)
                else:
                    self.assertNotRegex(symbols.stdout, pattern)
                binary = self.root / "beta-client"
                linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(linked.returncode, 0, linked.stderr)
                native = subprocess.run([str(binary), "21"], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)

    def test_beta_arguments_evaluated_once_and_in_order(self):
        self.agrees("""
(%type Callback (pointer (function (i64 i64) i64)))
(%variable trace i64 0)
(%function mark ((digit i64)) i64
  (do (store trace (%+-primitive-i64 (%*-primitive-i64 trace 10) digit)) digit))
(%function duplicate ((value i64) (ignored i64)) i64 (%+-primitive-i64 value value))
(%function main () i64
  (let ((bound Callback duplicate) (result (bound (mark 4) (mark 2))))
    (%+-primitive-i64 result trace)))
""", 50)

    def test_beta_shadowing_and_repeated_applications(self):
        self.agrees("""
(%type Callback (pointer (function (i64 i64) i64)))
(%function add ((value i64) (other i64)) i64
  (let ((saved value) (value other)) (%+-primitive-i64 saved value)))
(%function main () i64
  (let ((value i64 100) (bound Callback add)
        (first (bound 20 1)) (second (bound 19 2)))
    (match (%=-primitive-i64 value 100) (true (%+-primitive-i64 first second)) (false 0))))
""", 42)

    def test_beta_preserves_callback_snapshot_after_pointer_write(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function twice ((value i64)) i64 (%+-primitive-i64 value value))
(%function other ((value i64)) i64 (%+-primitive-i64 value 11))
(%function main () i64
  (let ((bound Callback twice) (snapshot bound) (pointer (& bound)))
    (store (deref pointer) other)
    (%+-primitive-i64 (snapshot 10) (bound 11))))
""", 42)

    def test_beta_resolves_callee_before_evaluating_arguments(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function twice ((value i64)) i64 (%+-primitive-i64 value value))
(%function other ((value i64)) i64 (%+-primitive-i64 value 1))
(%function replace ((slot (pointer Callback))) i64
  (do (store (deref slot) other) 21))
(%function main () i64
  (let ((bound Callback twice)) ((do bound) (replace (& bound)))))
""", 42)

    def test_beta_preserves_addressable_parameter_snapshot(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function snapshot ((value i64)) i64
  (let ((pointer (& value)) (copy value)) (store (deref pointer) 0) copy))
(%function main () i64 (let ((bound Callback snapshot)) (bound 42)))
""", 42)

    def test_beta_respects_noinline(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%function twice ((value i64)) i64 (%+-primitive-i64 value value))
(%noinline twice)
(%function apply ((value i64)) i64 (let ((bound Callback twice)) (bound value)))
(native-export apply "apply_bound")
(%function main () i64 (apply 21))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        functions = re.findall(
            r'define internal i64 @("[^"\n]+"|[\w.]+)\(i64 %[\w.]+\)[^\n]* \{\n(.*?)\n\}',
            emitted.stdout, re.S)
        names = [name.strip('"') for name, body in functions
                 if re.search(r"add i64 (%[\w.]+), \1", body)]
        self.assertEqual(len(names), 1, emitted.stdout)
        artifact = self.root / "no-beta.o"
        compiled = self.run_core("compile", source, "--emit", "object", "-o", artifact, "-O2")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        symbols = subprocess.run([shutil.which("llvm-nm") or "nm", str(artifact)],
                                 capture_output=True, text=True, timeout=10)
        self.assertEqual(symbols.returncode, 0, symbols.stderr)
        self.assertRegex(symbols.stdout, r"(?m)\b[tT] _?" + re.escape(names[0]) + r"$")

    def test_beta_preserves_unused_argument_failures(self):
        source = """
(%type Callback (pointer (function (i64 i64) i64)))
(%function ignore ((first i64) (second i64)) i64 42)
(%function main () i64
  (let ((bound Callback ignore))
    (bound (%/-primitive-i64 1 0) (%/-primitive-i64 -9223372036854775808 -1))))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("division by zero", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "beta failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assertEqual(native.stdout, "")
            self.assertEqual(native.stderr.splitlines()[0], evaluated.stderr.splitlines()[0])

    def test_constant_propagation_aliases_select_branches_and_matches(self):
        source = """
(%function main () i64
  (let ((seed i64 40) (alias seed) (answer (%+-primitive-i64 alias 2))
        (ready (%=-primitive-i64 answer 42)) (unused (%/-primitive-i64 answer 1)))
    (match ready (true (match answer (42 answer) (_ 0))) (false 0))))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertNotIn("then", emitted.stdout)
        self.assertNotIn("match.end", emitted.stdout)
        self.assertNotIn("add i64", emitted.stdout)
        self.assertNotIn("call i64 @core.div", emitted.stdout)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        for rule in ("constant-propagation", "known-match", "dead-binding"):
            self.assertIn(f"optimization: {rule} node=", report.stderr)

    def test_constant_propagation_shadowing_and_specializations(self):
        self.agrees("""
(%function pick (for (a)) ((value a)) a
  (let ((copy value)) (let ((value copy)) value)))
(%function main () i64
  (let ((value i64 40) (saved value)
        (other (let ((value u8 2) (alias value)) (pick alias))))
    (%+-primitive-i64 (pick saved) (%zext-primitive-u8-i64 other))))
""", 42)
        source = """
(%function choose ((flag bool)) i64 (let ((alias flag)) (match alias (true 42) (false 0))))
(%function main () i64 (choose true))
"""
        self.agrees(source, 42)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertNotIn("optimization: known-branch", report.stderr)

    def test_constant_propagation_integer_widths(self):
        for ty, initial, expression, expected in (
                ("i8", "127", "(%sext-primitive-i8-i64 (%+-primitive-i8 alias 1))", -128),
                ("u8", "255", "(%zext-primitive-u8-i64 (%+-primitive-u8 alias 1))", 0),
                ("u64", "18446744073709551615",
                 "(%reinterpret-primitive-u64-i64 (%/-primitive-u64 alias 2))", 9223372036854775807)):
            with self.subTest(ty=ty):
                self.agrees(self.program(
                    f"(let ((value {ty} {initial}) (alias value)) {expression})"), expected)

    def test_constant_propagation_preserves_local_snapshot_after_pointer_write(self):
        self.agrees("""
(%function replace ((place (pointer i64))) unit (store (deref place) 2))
(%function main () i64
  (let ((value i64 40) (pointer (& value)) (snapshot value))
    (replace pointer)
    (%+-primitive-i64 snapshot value)))
""", 42)

    def test_constant_propagation_preserves_global_snapshot_after_store(self):
        self.agrees("""
(%variable total i64 40)
(%function replace () unit (store total 2))
(%function main () i64
  (let ((snapshot total)) (replace) (%+-primitive-i64 snapshot total)))
""", 42)

    def test_constant_propagation_does_not_replace_effectful_call_result(self):
        source = """
(%variable calls i64 0)
(%function obtain () i64 (do (store calls (%+-primitive-i64 calls 1)) 21))
(%function main () i64
  (let ((value (obtain)) (alias value))
    (match (%=-primitive-i64 calls 1) (true (%+-primitive-i64 value alias)) (false 0))))
"""
        self.agrees(source, 42)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertNotIn("optimization: constant-propagation", report.stderr)
        self.assertNotIn("optimization: known-branch", report.stderr)

    def test_constant_propagation_preserves_failures(self):
        for numerator, denominator, message in (
                ("1", "0", "division by zero"),
                ("-9223372036854775808", "-1", "division overflow")):
            with self.subTest(message=message):
                source = self.program(f"""
(let ((top i64 {numerator}) (bottom i64 {denominator})
      (unused (%/-primitive-i64 top bottom))) 42)
""")
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn(message, evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "propagation-failure"
                    compiled = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertEqual(native.stderr.splitlines()[0], evaluated.stderr.splitlines()[0])

    def test_constant_propagation_alias_budget(self):
        bindings = ["(v0 bool true)"] + [f"(v{i} v{i - 1})" for i in range(1, 40)]
        source = self.program(f"(let ({' '.join(bindings)}) (match v39 (true 42) (false 0)))")
        self.agrees(source, 42)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertNotIn("optimization: known-branch", report.stderr)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("next.case", emitted.stdout)

    def test_local_cse_reuses_safe_sibling_primitive_tree(self):
        source = """
(%function square ((value i64)) i64 (%*-primitive-i64 value value))
(%function helper ((value i64)) i64
  (%+-primitive-i64 (square value) (square value)))
(%function main () i64 (helper 21))
"""
        self.agrees(source, 882)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # Calls are deliberately excluded from the initial CSE domain.
        self.assertEqual(len(re.findall(r'call i64 @vrn\.input\.square\b', emitted.stdout)), 2)

        direct = """
(%function helper ((value i64)) i64
  (%+-primitive-i64
    (%*-primitive-i64 value value)
    (%*-primitive-i64 value value)))
(%function main () i64 (helper 21))
"""
        self.agrees(direct, 882)
        emitted = self.run_core("emit-llvm", direct)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertEqual(len(re.findall(r'mul i64', emitted.stdout)), 1, emitted.stdout)
        report = self.run_core("optimization-report", direct)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertIn("optimization: local-cse node=", report.stderr)

    def test_local_cse_rejects_memory_and_control_flow(self):
        source = """
(%function helper ((flag bool) (value i64)) i64
  (%+-primitive-i64
    (match flag (true (%*-primitive-i64 value value)) (false 0))
    (match flag (true (%*-primitive-i64 value value)) (false 0))))
(%function main () i64 (helper true 21))
"""
        self.agrees(source, 882)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertNotIn("optimization: local-cse", report.stderr)

    def test_self_tail_recursion_elimination(self):
        source = """
(%function count ((value i64) (total i64)) i64
  (match (%=-primitive-i64 value 0) (true total) (false (count (%--primitive-i64 value 1) (%+-primitive-i64 total 1)))))
(%function main () i64 (count 1000000 0))
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("musttail call i64", emitted.stdout)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertIn("optimization: tail-call node=", report.stderr)

        binary = self.root / "self-tail"
        compiled = self.run_core("compile-report", source, "-o", binary, "-O1")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(native.returncode, 0, native.stderr)
        self.assertEqual(native.stdout, "i64:1000000\n")

        addressable = """
(%function blocked ((value i64)) i64
  (match (%=-primitive-i64 value 0) (true 0) (false (let ((address (pointer i64) (address-of value)))
        (blocked (%--primitive-i64 (deref address) 1))))))
(%function main () i64 (blocked 2))
"""
        rejected = self.run_core("optimization-report", addressable)
        self.assertEqual(rejected.returncode, 0, rejected.stderr)
        self.assertNotIn("optimization: tail-call", rejected.stderr)
        emitted = self.run_core("emit-llvm", addressable)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertNotIn("musttail call", emitted.stdout)

    def test_general_tail_calls_same_signature_mutual_recursion(self):
        source = """
(%function even ((value i64)) i64
  (match (%=-primitive-i64 value 0) (true 1) (false (odd (%--primitive-i64 value 1)))))
(%function odd ((value i64)) i64
  (match (%=-primitive-i64 value 0) (true 0) (false (even (%--primitive-i64 value 1)))))
(%function main () i64 (even 1000000))
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertGreaterEqual(emitted.stdout.count("musttail call i64"), 2)
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertIn("optimization: tail-call node=", report.stderr)
        binary = self.root / "mutual-tail"
        compiled = self.run_core("compile-report", source, "-o", binary, "-O1")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(native.returncode, 0, native.stderr)
        self.assertEqual(native.stdout, "i64:1\n")

    def test_optimization_report_decisions_and_stable_tape(self):
        source = """
(%function main () i64
  (let ((unused (%+-primitive-i64 1 2)))
    (match (%=-primitive-i64 1 1) (true (match (cast i64 42) (42 (%+-primitive-i64 40 2)) (_ 0))) (false 0))))
"""
        first = self.run_core("optimization-report", source)
        self.assertEqual(first.returncode, 0, first.stderr)
        before, after = first.stdout.removeprefix("before-lowering\n").split("after-lowering\n")
        self.assertEqual(before, after)
        rows = before.splitlines()
        ids = [int(re.match(r"node (\d+) ", row).group(1)) for row in rows]
        self.assertEqual(ids, list(range(1, len(ids) + 1)))
        for rule in ("dead-binding", "known-match", "constant-fold"):
            self.assertIn(f"optimization: {rule} node=", first.stderr)
        self.assertRegex(first.stderr, r"input\.vrn:\d+:\d+: optimization:")
        second = self.run_core("optimization-report", source)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((first.stdout, first.stderr), (second.stdout, second.stderr))
        self.agrees(source, 42)
        ordinary = self.run_core("emit-llvm", source)
        self.assertEqual(ordinary.returncode, 0, ordinary.stderr)
        self.assertEqual(ordinary.stderr, "")

    def test_optimization_report_checks_before_passes(self):
        result = self.run_core("optimization-report", self.program("(match true (true 42) (false missing))"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unknown local name", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn("optimization:", result.stderr)
        for option in ("-O0", "-o", "--emit"):
            rejected = self.run_core("optimization-report", self.program("42"), option)
            self.assertEqual(rejected.returncode, 2, rejected.stderr)

    def test_optimization_report_preserves_specializations_and_callbacks(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%function increment ((value i64)) i64 (%+-primitive-i64 value 1))
(%function choose (for (a)) ((value a)) a value)
(%function main () i64
  (let ((callback Callback increment) (unused (choose (cast u8 0))))
    (callback (choose (cast i64 41)))))
"""
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        before, after = report.stdout.removeprefix("before-lowering\n").split("after-lowering\n")
        self.assertEqual(before, after)
        self.agrees(source, 42)

    def test_optimization_report_locations_and_budget_fallback(self):
        (self.root / "dep.vrn").write_text(
            "(%function answer () i64 (%+-primitive-i64 40 2)) (export answer)")
        imported = self.run_core("optimization-report", "(import dep)" + self.program("(dep:answer)"))
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertRegex(imported.stderr, r"dep\.vrn:1:\d+: optimization: constant-fold")
        arms = " ".join(f"({value} 0)" for value in range(130))
        source = self.program(f"(match (cast i64 130) {arms} (_ 42))")
        report = self.run_core("optimization-report", source)
        self.assertEqual(report.returncode, 0, report.stderr)
        self.assertNotIn("optimization: known-match", report.stderr)
        self.agrees(source, 42)

    def test_eta_forwarder_preserves_identity(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function target ((value i64)) i64 (%+-primitive-i64 value 1))
(%function forward ((value i64)) i64 (target value))
(%function main () i64
  (let ((original Callback target) (wrapper Callback forward) (again Callback forward))
    (match (!= original wrapper) (true (match (== wrapper again) (true (wrapper 41)) (false 0))) (false 0))))
""", 42)

    def test_eta_dynamic_target_and_effects(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%variable calls i64 0)
(%function first ((value i64)) i64 (%+-primitive-i64 value 1))
(%function second ((value i64)) i64 (%+-primitive-i64 value 2))
(%function forward ((callback Callback) (value i64)) i64
  (do (store calls (%+-primitive-i64 calls 1)) (callback value)))
(%function main () i64
  (let ((a Callback first) (b Callback second))
    (do (forward a 0)
      (match (== (forward b 40) 42) (true (match (== calls 2) (true 42) (false 0))) (false 0)))))
""", 42)

    def test_eta_forwarder_optimization_keeps_export(self):
        source = """
(%function target ((value i64)) i64 (%+-primitive-i64 value 1))
(%function forward ((value i64)) i64 (target value))
(native-export forward "forward_api")
(%function main () i64 (forward 41))
"""
        self.agrees(source, 42)
        client = self.root / "eta-client.c"
        client.write_text("""
#include <stdint.h>
#include <stdlib.h>
extern int64_t forward_api(int64_t);
int main(int argc, char **argv) {
  int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 41;
  return forward_api(n) == n + 1 ? 0 : 1;
}
""")
        for level in ("-O0", "-O1", "-O2", "-O3"):
            with self.subTest(level=level):
                artifact = self.root / "eta.o"
                compiled = self.run_core("compile", source, "--emit", "object",
                                         "-o", artifact, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                symbols = subprocess.run([shutil.which("llvm-nm") or "nm", str(artifact)],
                                         capture_output=True, text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                self.assertRegex(symbols.stdout, r"(?m)\bT _?forward_api$")
                private = r"(?m)\b[tT] _?vrn\.input\.[\w.-]+$"
                if level == "-O0":
                    self.assertRegex(symbols.stdout, private)
                else:
                    self.assertNotRegex(symbols.stdout, private)
                binary = self.root / "eta-client"
                linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(linked.returncode, 0, linked.stderr)
                native = subprocess.run([str(binary), "123"], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)

    def test_dead_bindings_remove_safe_computations(self):
        source = """
(%type Option (sum (Some i64)))
(%function identity ((value i64)) i64
  (let ((unused (%*-primitive-i64 value value))
        (aggregate (tuple value true))
        (constructor (Some value))
        (branch (match (%<-primitive-i64 value 0) (true (%+-primitive-i64 value 1)) (false (%--primitive-i64 value 1))))
        (sequence (do (%+-primitive-i64 value 1) (%*-primitive-i64 value 2)))
        (division (%/-primitive-i64 84 2)))
    value))
(%function main () i64 (identity 42))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        bodies = re.findall(
            r"define internal i64 @[^\n]+\(i64 (%[\w.]+)\)(?: !dbg !\d+)? \{\n(.*?)\n\}",
            emitted.stdout, re.S)
        self.assertEqual(len(bodies), 1, emitted.stdout)
        parameter, body = bodies[0]
        instructions = [re.sub(r", !dbg !\d+$", "", line.strip()) for line in body.splitlines()
                        if line.strip() and not line.strip().endswith(":") and not line.lstrip().startswith("#dbg_")]
        self.assertEqual(instructions, [f"ret i64 {parameter}"])

    def test_dead_binding_elimination_preserves_shadowed_outer_value(self):
        self.agrees(self.program("""
(let ((value i64 40) (outer value))
  (let ((value i64 2) (unused (%*-primitive-i64 value value)))
    (%+-primitive-i64 outer value)))
"""), 42)

    def test_dead_binding_elimination_preserves_transitive_dependencies(self):
        self.agrees(self.program("""
(let ((first i64 20) (second (%*-primitive-i64 first 2)) (unused i64 99))
  (%+-primitive-i64 second 2))
"""), 42)

    def test_dead_binding_elimination_preserves_generic_specializations(self):
        self.agrees("""
(%function pick (for (a)) ((value a)) a
  (let ((copy value) (unused (tuple value))) (let ((value copy)) value)))
(%function main () i64
  (%+-primitive-i64 (pick (cast i64 40))
    (%zext-primitive-u8-i64 (pick (cast u8 2)))))
""", 42)

    def test_dead_binding_elimination_preserves_live_callback(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function answer ((value i64)) i64 value)
(%function invoke ((callback Callback)) i64
  (let ((alias callback) (unused i64 0)) (alias 42)))
(%function main () i64 (invoke answer))
""", 42)

    def test_dead_binding_elimination_preserves_store_order(self):
        self.agrees("""
(%function mark ((trace (pointer i64)) (digit i64)) i64
  (do (store (deref trace)
        (%+-primitive-i64 (%*-primitive-i64 (deref trace) 10) digit)) digit))
(%function main () i64
  (let ((trace i64 0) (first (mark (& trace) 4))
        (pure (%*-primitive-i64 9 9)) (second (mark (& trace) 2))) trace))
""", 42)

    def test_dead_binding_elimination_preserves_reads_from_addressable_locals(self):
        source = """
(%function main () i64
  (let ((value i64 42) (pointer (& value)) (snapshot value)
        (unused value) (write (store (deref pointer) 2))) snapshot))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # Both the live snapshot and the unused stored-local read are retained.
        self.assertGreaterEqual(emitted.stdout.count("load i64"), 2)

    def test_dead_binding_elimination_preserves_global_reads(self):
        global_read = """
(%variable total i64 42)
(%function main () i64 (let ((unused total)) 42))
"""
        self.agrees(global_read, 42)
        emitted = self.run_core("emit-llvm", global_read)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("load i64", emitted.stdout)

    def test_effect_analysis_keeps_unknown_calls_and_memory_reads(self):
        source = """
(%external-function observe "effect_observe" (i64) i64)
(%variable mutable i64 17)
(%function main () i64
  (let ((call (observe 1)) (load mutable) (known (%+-primitive-i64 20 22)))
    known))
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("@effect_observe", emitted.stdout)
        self.assertIn("load i64", emitted.stdout)
        self.assertNotIn("add i64 20, 22", emitted.stdout)

        safe = self.run_core("emit-llvm", self.program(
            "(let ((unused (%+-primitive-i64 (%*-primitive-i64 6 7) 0))) 42)"))
        self.assertEqual(safe.returncode, 0, safe.stderr)
        self.assertNotIn("mul i64", safe.stdout)
        self.assertNotIn("add i64", safe.stdout)

    def test_dead_bindings_preserve_failures_and_diagnostics(self):
        cases = [
            (self.program("(let ((unused (%/-primitive-i64 1 0))) 42)"),
             "division by zero"),
            (self.program("(let ((unused (%/-primitive-i64 -9223372036854775808 -1))) 42)"),
             "signed division overflow"),
            ("""(%function probe ((at u64)) i64
  (let ((unused (index (array-of (cast i64 42)) at))) 42))
(%function main () i64 (probe 1))""", "array index out of bounds"),
        ]
        for source, message in cases:
            with self.subTest(message=message):
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn(message, evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "dead binding failure"
                    compiled = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertEqual(native.stdout, "")
                    self.assertEqual(native.stderr.splitlines()[0],
                                     evaluated.stderr.splitlines()[0])
        invalid = self.run_core("emit-llvm", self.program("(let ((unused missing)) 42)"))
        self.assertEqual(invalid.returncode, 2, invalid.stderr)
        self.assertIn("unknown local", invalid.stderr)

    def test_dead_bindings_keep_potential_divergence(self):
        source = """
(%function loop () i64 (loop))
(%function main () i64 (let ((unused (loop))) 42))
"""
        # Do not execute an infinite program. The recursive call and unused
        # initializer call must both remain, alongside the native entry call.
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertGreaterEqual(len(re.findall(r"call i64 @", emitted.stdout)), 3)

    def test_dead_bindings_proof_budget(self):
        expression = "value"
        for _ in range(40):
            expression = f"(%+-primitive-i64 {expression} 1)"
        source = (f"(%function probe ((value i64)) i64 (let ((unused {expression})) value))"
                  "(%function main () i64 (probe 42))")
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("add i64", emitted.stdout)

    def test_known_match_eliminates_dispatch(self):
        cases = [
            self.program("(match (%/-primitive-i64 84 2) (0 0) (42 42) (_ 1))"),
            self.program("(match false (true 0) (false 42))"),
            self.program("(match (%/-primitive-i64 84 2) (0 0) (value value))"),
            self.program("(match (cast i8 -128) (-128 42) (_ 0))"),
            self.program("(match (cast u64 18446744073709551615) (0 0) (_ 42))"),
            self.program("(match (tuple) ((tuple) 42))"),
            """(%function pick (for (a)) ((value a)) a
  (match (tuple value) ((tuple selected) selected)))
(%function main () i64
  (%+-primitive-i64 (pick (cast i64 40))
    (%zext-primitive-u8-i64 (pick (cast u8 2)))))""",
            self.program("""(match (tuple (%/-primitive-i64 84 2) false)
              ((tuple 0 _) 0) ((tuple value _) value))"""),
            """(%type Option (sum (Some i64) (None)))
(%function main () i64
  (match (Some 42) ((None) 0) ((Some 0) 1) ((Some result) result)))""",
            """(%type Option (sum (Some i64) (None)))
(%function main () i64
  (match (None) ((Some result) result) ((None) 42)))""",
            """(%type Option (sum (Some i64) (None)))
(%function main () i64
  (match (Some 40)
    ((None) 0)
    ((Some outer)
      (match (Some 2) ((None) 0) ((Some inner) (%+-primitive-i64 outer inner))))))""",
        ]
        for source in cases:
            with self.subTest(source=source):
                self.agrees(source, 42)
                emitted = self.run_core("emit-llvm", source)
                self.assertEqual(emitted.returncode, 0, emitted.stderr)
                self.assertNotIn("match.end", emitted.stdout)
                self.assertNotIn("next.case", emitted.stdout)
                self.assertNotIn("phi i64", emitted.stdout)

    def test_known_match_preserves_payload_evaluation_order(self):
        source = """
(%type Bundle (sum (Pair i64 i64) (Empty)))
(%function mark ((trace (pointer i64)) (digit i64)) i64
  (do (store (deref trace)
        (%+-primitive-i64 (%*-primitive-i64 (deref trace) 10) digit)) digit))
(%function main () i64
  (let ((trace i64 0))
    (match (Pair (mark (& trace) 4) (mark (& trace) 2))
      ((Empty) 0) ((Pair _ _) trace))))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertNotIn("match.end", emitted.stdout)

    def test_known_sum_match_binds_whole_sum(self):
        self.agrees("""
(%type Bundle (sum (Pair i64 i64) (Empty)))
(%function main () i64
  (match (Pair 40 2) ((Empty) 0)
    (whole (match whole ((Pair a b) (%+-primitive-i64 a b)) ((Empty) 1)))))
""", 42)

    def test_known_tuple_match_binds_whole_tuple(self):
        self.agrees(self.program("""
(match (tuple (cast i64 40) (cast i64 2))
  ((tuple 0 _) 0)
  (whole (%+-primitive-i64 (tuple-get whole 0) (tuple-get whole 1))))
"""), 42)

    def test_known_match_keeps_unknown_patterns(self):
        for argument, expected in ((0, 99), (42, 42)):
            source = f"""
(%type Option (sum (Some i64) (None)))
(%function choose ((value i64)) i64
  (match (Some value) ((Some 0) 99) ((Some result) result) ((None) 0)))
(%function main () i64 (choose {argument}))
"""
            with self.subTest(argument=argument):
                self.agrees(source, expected)
                emitted = self.run_core("emit-llvm", source)
                self.assertEqual(emitted.returncode, 0, emitted.stderr)
                self.assertIn("next.case", emitted.stdout)
                self.assertIn("case", emitted.stdout)
        self.agrees("""
(%type Option (sum (Some i64) (None)))
(%function make ((value i64)) Option (Some value))
(%function main () i64
  (match (make 42) ((Some result) result) ((None) 0)))
""", 42)

    def test_known_match_preserves_failures_and_diagnostics(self):
        source = """
(%type Bundle (sum (Pair i64 i64) (Empty)))
(%function main () i64
  (match (Pair (%/-primitive-i64 1 0) (%/-primitive-i64 -9223372036854775808 -1))
    ((Empty) 0) ((Pair _ _) 42)))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("division by zero", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "match failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assertEqual(native.stdout, "")
            self.assertEqual(native.stderr.splitlines()[0], evaluated.stderr.splitlines()[0])
        invalid = """
(%type Option (sum (Some i64) (None)))
(%function main () i64 (match (Some 42) ((Some value) value) ((None) missing)))
"""
        result = self.run_core("emit-llvm", invalid)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unknown local", result.stderr)

    def test_known_match_arm_budget(self):
        arms = " ".join(f"({value} 0)" for value in range(130))
        source = self.program(f"(match (cast i64 130) {arms} (_ 42))")
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("next.case", emitted.stdout)

    def test_constant_folding_integer_semantics(self):
        cases = {
            "(%/-primitive-i64 84 2)": 42,
            "(%/-primitive-i64 -85 2)": -42,
            "(%/-primitive-i64 85 -2)": -42,
            "(%+-primitive-i64 9223372036854775807 1)": -9223372036854775808,
            "(%--primitive-i64 -9223372036854775808 1)": 9223372036854775807,
            "(%*-primitive-i64 9223372036854775807 2)": -2,
            "(%sext-primitive-i8-i64 (%+-primitive-i8 127 1))": -128,
            "(%zext-primitive-u8-i64 (%+-primitive-u8 255 1))": 0,
            "(%zext-primitive-u16-i64 (%sext-primitive-i8-u16 -1))": 65535,
            "(%zext-primitive-u8-i64 (%trunc-primitive-i64-u8 -1))": 255,
            "(%reinterpret-primitive-u64-i64 (%/-primitive-u64 18446744073709551615 2))": 9223372036854775807,
            "(%sext-primitive-i8-i64 (%shr-primitive-i8 -3 1))": -2,
            "(%sext-primitive-i8-i64 (%shr-primitive-i8 -128 -1))": -1,
            "(%zext-primitive-u8-i64 (%shr-primitive-u8 255 8))": 255,
            "(%zext-primitive-u8-i64 (%shl-primitive-u8 255 1))": 254,
            "(%and-primitive-i64 -1 42)": 42,
            "(%or-primitive-i64 40 2)": 42,
            "(%xor-primitive-i64 63 21)": 42,
            "(match (%>-primitive-u64 18446744073709551615 0) (true 42) (false 0))": 42,
            "(match (%<-primitive-i64 -1 0) (true 42) (false 0))": 42,
            "(match (%=-primitive-i8 (%+-primitive-i8 127 1) -128) (true 42) (false 0))": 42,
            "(match (%not-primitive-bool (%and-primitive-bool true false)) (true 42) (false 0))": 42,
        }
        for expression, expected in cases.items():
            with self.subTest(expression=expression):
                self.agrees(self.program(expression), expected)

    def test_constant_folding_removes_guarded_division(self):
        source = self.program("""
(match (%=-primitive-i64 (%/-primitive-i64 84 2) 42) (true (%/-primitive-i64 (%+-primitive-i64 80 4) 2)) (false (%/-primitive-i64 1 0)))
""")
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # Runtime helpers remain declared; no user expression calls division.
        self.assertNotRegex(emitted.stdout, r"call i64 @core\.div")
        self.assertNotIn("phi i64", emitted.stdout)
        invalid = self.run_core("emit-llvm", self.program(
            "(match (%=-primitive-i64 (%/-primitive-i64 84 2) 42) (true 42) (false missing))"))
        self.assertEqual(invalid.returncode, 2, invalid.stderr)
        self.assertIn("unknown local", invalid.stderr)

    def test_constant_folding_preserves_lexical_division_overload(self):
        self.agrees("""
(%function / ((left i64) (right i64)) i64 42)
(%function main () i64 (/ 1 0))
""", 42)

    def test_constant_folding_preserves_effectful_operand_of_multiply_by_zero(self):
        self.agrees("""
(%function mark ((trace (pointer i64))) i64
  (do (store (deref trace) 42) 7))
(%function main () i64
  (let ((trace i64 0))
    (%+-primitive-i64 (%*-primitive-i64 (mark (& trace)) 0) trace)))
""", 42)

    def test_constant_folding_preserves_float_division(self):
        self.agrees(self.program("""
(match (%=-primitive-f64 (%/-primitive-f64 84.0 2.0) 42.0) (true 42) (false 0))
"""), 42)

    def test_constant_folding_preserves_failures(self):
        cases = [
            (f"(match (%=-primitive-{ty} (%/-primitive-{ty} {minimum} -1) 0) (true 42) (false 0))",
             "signed division overflow")
            for ty, minimum in (("i8", -128), ("i16", -32768),
                                ("i32", -2147483648), ("i64", -9223372036854775808))
        ]
        cases.append(("(%/-primitive-i64 42 (%--primitive-i64 2 2))", "division by zero"))
        for expression, message in cases:
            with self.subTest(expression=expression):
                source = self.program(expression)
                evaluated = self.run_core("eval", source)
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn(message, evaluated.stderr)
                for level in ("-O0", "-O2"):
                    binary = self.root / "folding failure"
                    compiled = self.run_core("compile-report", source, "-o", binary, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    native = subprocess.run([str(binary)], capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(native.returncode, 70, native.stderr)
                    self.assertEqual(native.stdout, "")
                    self.assertEqual(native.stderr.splitlines()[0],
                                     evaluated.stderr.splitlines()[0])

    def test_constant_folding_depth_budget(self):
        expression = "42"
        for _ in range(40):
            expression = f"(%/-primitive-i64 {expression} 1)"
        source = self.program(expression)
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # Exceeding the folding depth leaves an ordinary runtime expression.
        self.assertRegex(emitted.stdout, r"call i64 @vrn\.runtime\.div\.i64")

    def test_copy_propagation_reuses_parameter_value(self):
        source = """
(%function copied ((value i64)) i64
  (let ((first value) (second first) (third second)) third))
(%function main () i64 (copied 42))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # Ignore generated symbol names. The one-parameter identity function
        # must contain only a return: no loads, stores, or copy instructions.
        bodies = re.findall(
            r"define internal i64 @[^\n]+\(i64 (%[\w.]+)\)(?: !dbg !\d+)? \{\n(.*?)\n\}",
            emitted.stdout, re.S)
        self.assertEqual(len(bodies), 1, emitted.stdout)
        parameter, body = bodies[0]
        instructions = [re.sub(r", !dbg !\d+$", "", line.strip()) for line in body.splitlines()
                        if line.strip() and not line.strip().endswith(":") and not line.lstrip().startswith("#dbg_")]
        self.assertEqual(instructions, [f"ret i64 {parameter}"])
        self.agrees(self.program("""
(let ((value i64 40) (copy value))
  (let ((value i64 2) (second copy)) (%+-primitive-i64 second value)))
"""), 42)

    def test_copy_propagation_preserves_effect_order(self):
        source = """
(%function mark ((trace (pointer i64)) (digit i64)) i64
  (do (store (deref trace)
        (%+-primitive-i64 (%*-primitive-i64 (deref trace) 10) digit)) digit))
(%function main () i64
  (let ((trace i64 0)
        (first (mark (& trace) 4))
        (first-copy first)
        (second (mark (& trace) 2))
        (second-copy second)
        (unused-copy first-copy))
    (%+-primitive-i64 trace (%--primitive-i64 second-copy second))))
"""
        # Re-evaluating an initializer, omitting it, or changing its order
        # changes trace. Unused aliases must not drop their initializer effects.
        self.agrees(source, 42)

    def test_copy_propagation_preserves_storage_snapshots(self):
        for expression in (
            """(let ((value i64 40) (copy value) (alias copy))
              (store (deref (& value)) 2) (%+-primitive-i64 alias value))""",
            """(let ((value i64 40) (copy value) (alias copy))
              (store (deref (& copy)) 2) (%+-primitive-i64 alias copy))""",
            """(let ((value i64 40) (pointer (& value))
                     (copy value) (alias copy))
              (store (deref pointer) 2) (%+-primitive-i64 alias value))""",
            """(let ((value i64 40) (copy value) (pointer (& copy)))
              (store (deref pointer) 2) (%+-primitive-i64 value copy))""",
        ):
            with self.subTest(expression=expression):
                self.agrees(self.program(expression), 42)

    def test_known_boolean_branch_elimination(self):
        for expression in (
            "(match true (true 42) (false (%/-primitive-i64 1 0)))",
            "(match false (true (%/-primitive-i64 1 0)) (false 42))",
            "(match true (true (match false (true 0) (false 42))) (false 0))",
        ):
            with self.subTest(expression=expression):
                source = self.program(expression)
                self.agrees(source, 42)
                emitted = self.run_core("emit-llvm", source)
                self.assertEqual(emitted.returncode, 0, emitted.stderr)
                self.assertNotIn("then:", emitted.stdout)
                self.assertNotIn("else:", emitted.stdout)
                self.assertNotIn("phi i64", emitted.stdout)

        # A call condition must still execute, even when its body returns true.
        source = """
(%function mark ((p (pointer i64))) bool (do (store (deref p) 42) true))
(%function main () i64
  (let ((value i64 0)) (do (match (mark (& value)) (true (cast i64 0)) (false (cast i64 1))) value)))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        # This conditional is followed by VALUE, so it is not in tail position
        # and ordinary lowering still merges its branch results through a phi.
        self.assertIn("phi i64", emitted.stdout)

        # Optimization cannot conceal an error in the unused branch.
        for expression in ("(match true (true 42) (false missing))", "(match false (true missing) (false 42))"):
            result = self.run_core("emit-llvm", self.program(expression))
            self.assertEqual(result.returncode, 2, result.stderr)
