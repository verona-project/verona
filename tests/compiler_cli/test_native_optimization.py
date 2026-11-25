"""Native optimization behavior and artifact checks."""

import re
import shutil
import subprocess
import sys

from .support import CompilerTestCase


class NativeOptimizationTests(CompilerTestCase):
    def test_auto_inline_small_live_helper_with_runtime_effects(self):
        client = self.root / "auto-inline-client.c"
        client.write_text("""
#include <stdint.h>
#include <stdlib.h>
extern int64_t small_api(int64_t);
static int calls;
static int64_t trace;
int64_t heuristic_effect(int64_t n) {
  ++calls;
  trace = trace * 100 + n;
  return n * 2;
}
int main(int argc, char **argv) {
  int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 2;
  int64_t result = small_api(n);
  return result == 4 * n + 4 && calls == 2 && trace == n * 100 + n + 1 ? 0 : 1;
}
""")
        for policy in ("", "(%noinline small)"):
            source = f"""
(%external-function effect "heuristic_effect" (i64) i64)
(%function small ((value i64)) i64 (%+-primitive-i64 (effect value) 1))
{policy}
(%function apply ((value i64)) i64
  (%+-primitive-i64 (small value) (small (%+-primitive-i64 value 1))))
(native-export apply "small_api")
(%function main () i64 0)
"""
            emitted = self.run_core("emit-llvm", source)
            self.assertEqual(emitted.returncode, 0, emitted.stderr)
            functions = re.findall(
                r'define internal i64 @("[^"\n]+"|[\w.]+)\(i64 %[\w.]+\)([^\n]*) \{\n(.*?)\n\}',
                emitted.stdout, re.S)
            helpers = [(name.strip('"'), suffix) for name, suffix, body in functions
                       if "@heuristic_effect(" in body]
            self.assertEqual(len(helpers), 1, emitted.stdout)
            name, suffix = helpers[0]
            if not policy:
                # Automatic inlining must not be implemented as an always request.
                self.assertNotIn("alwaysinline", emitted.stdout)
                self.assertNotIn("noinline", emitted.stdout)
                self.assertNotIn("#", suffix)
            for level in ("-O0", "-O1", "-O2", "-O3"):
                with self.subTest(policy=policy or "auto", level=level):
                    artifact = self.root / "auto-inline.o"
                    compiled = self.run_core("compile", source, "--emit", "object",
                                             "-o", artifact, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    self.assertEqual(compiled.stderr, "")
                    symbols = subprocess.run([shutil.which("llvm-nm") or "nm", str(artifact)],
                                             capture_output=True, text=True, timeout=10)
                    self.assertEqual(symbols.returncode, 0, symbols.stderr)
                    helper = r"(?m)\b[tT] _?" + re.escape(name) + r"$"
                    if policy or level == "-O0":
                        self.assertRegex(symbols.stdout, helper)
                    else:
                        self.assertNotRegex(symbols.stdout, helper)
                    self.assertRegex(symbols.stdout, r"(?m)\bT _?small_api$")
                    binary = self.root / "auto-inline-client"
                    linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(linked.returncode, 0, linked.stderr)
                    for value in ("2", "17"):
                        native = subprocess.run([str(binary), value], capture_output=True,
                                                text=True, timeout=10)
                        self.assertEqual(native.returncode, 0, native.stderr)

    def test_auto_inline_recursion_and_unused_failing_arguments(self):
        self.agrees("""
(%function fib ((n i64)) i64
  (match (%<-primitive-i64 n 2) (true n) (false (%+-primitive-i64 (fib (%--primitive-i64 n 1)) (fib (%--primitive-i64 n 2))))))
(%function main () i64 (fib 10))
""", 55)
        source = """
(%function ignore ((unused i64)) i64 42)
(%function main () i64 (ignore (%/-primitive-i64 1 0)))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        for level in ("-O0", "-O1", "-O2", "-O3"):
            binary = self.root / "auto-inline-failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assert_runtime_diagnostic_matches(native, evaluated)

    def test_inline_directives_and_auto_default(self):
        source = """
(%inline forced)
(%function forced ((value i64)) i64 (%+-primitive-i64 value 1))
(%function forbidden ((value i64)) i64 (%+-primitive-i64 value 2))
(%function automatic ((value i64)) i64 (%+-primitive-i64 value 3))
(%noinline forbidden)
(native-export forced "forced_api")
(native-export forbidden "forbidden_api")
(native-export automatic "automatic_api")
(%function main () i64 (%+-primitive-i64 (forced 20) (forbidden 19)))
"""
        self.agrees(source, 42)
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        attributes = dict(re.findall(r"attributes #(\d+) = \{([^}]+)\}", emitted.stdout))
        functions = re.findall(
            r'define internal i64 @("[^"\n]+"|[\w.]+)\(i64 %[\w.]+\)([^\n]*) \{\n(.*?)\n\}',
            emitted.stdout, re.S)
        names = {}
        for increment, policy in ((1, "alwaysinline"), (2, "noinline"), (3, None)):
            matches = [(name.strip('"'), suffix) for name, suffix, body in functions
                       if re.search(r"add i64 %[\w.]+, " + str(increment) + r"\b", body)]
            self.assertEqual(len(matches), 1, emitted.stdout)
            name, suffix = matches[0]
            names[increment] = name
            group = re.search(r"#(\d+)", suffix)
            flags = attributes[group.group(1)] if group else ""
            if policy:
                self.assertIn(policy, flags)
            else:
                self.assertNotIn("alwaysinline", flags)
                self.assertNotIn("noinline", flags)
        nm = shutil.which("llvm-nm") or shutil.which("nm")
        self.assertIsNotNone(nm)
        for level in ("-O0", "-O1", "-O2", "-O3"):
            with self.subTest(level=level):
                artifact = self.root / "inline.o"
                compiled = self.run_core("compile", source, "--emit", "object",
                                         "-o", artifact, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                symbols = subprocess.run([nm, str(artifact)], capture_output=True,
                                         text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                pattern = r"(?m)\b[tT] _?" + re.escape(names[1]) + r"$"
                if level == "-O0":
                    self.assertRegex(symbols.stdout, pattern)
                    self.assertIn(
                        "note[forced-inlining-disabled]: forced inlining is inactive at -O0",
                        compiled.stderr,
                    )
                    self.assertEqual(compiled.stdout, "")
                else:
                    self.assertNotRegex(symbols.stdout, pattern)
                self.assertRegex(symbols.stdout, r"(?m)\b[tT] _?" + re.escape(names[2]) + r"$")
                self.assertRegex(symbols.stdout, r"(?m)\bT _?forced_api$")

    def test_inline_macros_modules_and_specializations(self):
        options = ("--module-path", "projects/base/src", "--module-path", "projects/foundation/src",
                   "--module-path", "projects/libc/src")
        source = """
(import base :as b)
(b:inline-function pick (for (a)) ((value a)) a value)
(b:noinline-function add ((value i64)) i64 (+ value 1))
(%function main () i64
  (%+-primitive-i64 (add (pick (cast i64 39)))
    (%zext-primitive-u8-i64 (pick (cast u8 2)))))
"""
        self.agrees(source, 42, *options)
        emitted = self.run_core("emit-llvm", source, *options)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        groups = re.findall(r"attributes #(\d+) = \{[^}]*alwaysinline[^}]*\}", emitted.stdout)
        self.assertEqual(len(groups), 1, emitted.stdout)
        self.assertEqual(len(re.findall(r"(?m)^define .* #" + groups[0] + r"(?: !dbg !\d+)? \{", emitted.stdout)), 2)
        (self.root / "library.vrn").write_text("""
(import base :as b)
(export helper)
(b:inline-function helper ((value i64)) i64 (+ value 1))
""")
        self.agrees("""
(import library :as lib)
(%function helper ((value i64)) i64 (%+-primitive-i64 value 2))
(%noinline helper)
(%function main () i64 (%+-primitive-i64 (lib:helper 20) (helper 19)))
""", 42, *options)
        duplicate = "(%inline helper)(%inline helper)(%function helper () i64 42)" + self.program("(helper)")
        compiled = self.run_core("compile", duplicate, "-o", self.root / "duplicates", "-O0")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        self.assertEqual(compiled.stderr.count("forced inlining is inactive at -O0"), 1)

    def test_inline_directive_diagnostics(self):
        cases = [
            ("(%inline missing)", "must name a local Verona function"),
            ("(%inline)", "exactly one"),
            ("(%noinline 42)", "unqualified local function"),
            ("(%inline main auto)", "exactly one"),
            ("(%function helper () i64 42)(%inline helper)(%noinline helper)", "conflicting inline"),
            ("(%function helper () i64 42)(%noinline helper)(%inline helper)", "conflicting inline"),
            ("(%constant value i64 42)(%inline value)", "must name a local Verona function"),
            ('(%external-function foreign "getpid" () i32)(%inline foreign)', "with a body"),
            ("(%inline other:helper)", "unqualified local function"),
            ("(%function helper () i64 missing)(%inline helper)", "unknown local"),
        ]
        for declaration, message in cases:
            for mode in ("check", "eval", "emit-llvm", "compile-report"):
                with self.subTest(declaration=declaration, mode=mode):
                    options = ("-o", self.root / "invalid-inline") if mode == "compile-report" else ()
                    result = self.run_core(mode, declaration + self.program("42"), *options)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(message, result.stderr)

    def test_inline_preserves_argument_evaluation_order(self):
        self.agrees("""
(%variable trace i64 0)
(%function mark ((digit i64)) i64
  (do (store trace (%+-primitive-i64 (%*-primitive-i64 trace 10) digit)) digit))
(%function ignore ((first i64) (second i64)) i64 trace)
(%inline ignore)
(%function main () i64 (ignore (mark 4) (mark 2)))
""", 42)

    def test_inline_preserves_addressable_parameter_snapshot(self):
        self.agrees("""
(%function snapshot ((value i64)) i64
  (let ((pointer (& value)) (copy value)) (store (deref pointer) 2) copy))
(%inline snapshot)
(%function main () i64 (snapshot 42))
""", 42)

    def test_inline_preserves_callback_identity(self):
        self.agrees("""
(%type Callback (pointer (function (i64) i64)))
(%function helper ((value i64)) i64 (%+-primitive-i64 value 1))
(%inline helper)
(%function main () i64
  (let ((callback Callback helper) (same Callback helper))
    (match (== callback same) (true (callback 41)) (false 0))))
""", 42)

    def test_inline_preserves_first_argument_failure(self):
        source = """
(%function ignore ((first i64) (second i64)) i64 42)
(%inline ignore)
(%function main () i64
  (ignore (%/-primitive-i64 1 0) (%/-primitive-i64 -9223372036854775808 -1)))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("division by zero", evaluated.stderr)
        for level in ("-O0", "-O2"):
            binary = self.root / "inline failure"
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(native.returncode, 70, native.stderr)
            self.assert_runtime_diagnostic_matches(native, evaluated)

    def test_inline_recursion_is_bounded_and_reported(self):
        source = """
(%function fib ((n i64)) i64
  (match (%<-primitive-i64 n 2) (true n) (false (%+-primitive-i64 (fib (%--primitive-i64 n 1)) (fib (%--primitive-i64 n 2))))))
(%inline fib)
(native-export fib "fib_api")
(%function main () i64 (fib 4))
"""
        self.agrees(source, 3)
        compiled = self.run_core("compile-report", source, "-o", self.root / "fib", "-O2")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        self.assertIn("forced inlining left direct calls", compiled.stderr)
        self.agrees("""
(%inline even)
(%inline odd)
(%function even ((n i64)) bool (match (%=-primitive-i64 n 0) (true true) (false (odd (%--primitive-i64 n 1)))))
(%function odd ((n i64)) bool (match (%=-primitive-i64 n 0) (true false) (false (even (%--primitive-i64 n 1)))))
(%function main () i64 (match (even 10) (true 42) (false 0)))
""", 42)

    def test_dead_functions_remove_unreachable_chains_and_recursive_groups(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%external-function effect-a "dead_effect_a" (i64) i64)
(%external-function effect-b "dead_effect_b" (i64) i64)
(%external-function effect-c "dead_effect_c" (i64) i64)
(%function first ((value i64)) i64 (do (effect-a value) (second value)))
(%function second ((value i64)) i64 (do (effect-b value) (first value)))
(%function chain ((value i64)) i64
  (let ((callback Callback first)) (do (effect-c value) (callback value))))
(%noinline first)
(%noinline second)
(%noinline chain)
(export first)
(%function live ((value i64)) i64 (%+-primitive-i64 value 1))
(native-export live "live_api")
(%function main () i64 0)
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        functions = re.findall(
            r'define internal i64 @("[^"\n]+"|[\w.]+)\(i64 %[\w.]+\)[^\n]* \{\n(.*?)\n\}',
            emitted.stdout, re.S)
        dead = [name.strip('"') for name, body in functions if "@dead_effect_" in body]
        self.assertEqual(len(dead), 3, emitted.stdout)
        client = self.root / "dead-functions-client.c"
        client.write_text("""
#include <stdint.h>
#include <stdlib.h>
extern int64_t live_api(int64_t);
static int calls;
int64_t dead_effect_a(int64_t n) { ++calls; return n; }
int64_t dead_effect_b(int64_t n) { ++calls; return n; }
int64_t dead_effect_c(int64_t n) { ++calls; return n; }
int main(int argc, char **argv) {
  int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 41;
  return live_api(n) == n + 1 && calls == 0 ? 0 : 1;
}
""")
        for level in ("-O0", "-O1", "-O2", "-O3"):
            with self.subTest(level=level):
                artifact = self.root / "dead-functions.o"
                compiled = self.run_core("compile", source, "--emit", "object",
                                         "-o", artifact, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                symbols = subprocess.run([shutil.which("llvm-nm") or "nm", str(artifact)],
                                         capture_output=True, text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                for name in dead:
                    pattern = r"(?m)\b[tT] _?" + re.escape(name) + r"$"
                    if level == "-O0":
                        self.assertRegex(symbols.stdout, pattern)
                    else:
                        self.assertNotRegex(symbols.stdout, pattern)
                if level != "-O0":
                    self.assertNotIn("dead_effect_", symbols.stdout)
                self.assertRegex(symbols.stdout, r"(?m)\bT _?live_api$")
                binary = self.root / "dead-functions-client"
                linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)],
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(linked.returncode, 0, linked.stderr)
                native = subprocess.run([str(binary), "17"], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)

    def test_dead_functions_preserve_escaping_library_callbacks(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%function original ((value i64)) i64 (%+-primitive-i64 value 1))
(%function forward ((value i64)) i64 (original value))
(%function first () Callback original)
(%function second () Callback forward)
(%function invoke ((callback Callback) (value i64)) i64 (callback value))
(native-export first "first_callback")
(native-export second "second_callback")
(native-export invoke "invoke_callback")
"""
        client = self.root / "callback-roots-client.c"
        client.write_text("""
#include <stdint.h>
#include <stdlib.h>
typedef int64_t (*callback)(int64_t);
extern callback first_callback(void);
extern callback second_callback(void);
extern int64_t invoke_callback(callback, int64_t);
static int64_t twice(int64_t n) { return n * 2; }
int main(int argc, char **argv) {
  int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 41;
  callback a = first_callback(), b = second_callback();
  return a != b && a == first_callback() && b == second_callback()
      && a(n) == n + 1 && b(n) == n + 1
      && invoke_callback(twice, n) == n * 2 ? 0 : 1;
}
""")
        for kind, extension in (("object", ".o"), ("static-library", ".a"),
                                ("shared-library", ".dylib" if sys.platform == "darwin" else ".so")):
            for level in ("-O0", "-O2"):
                with self.subTest(kind=kind, level=level):
                    artifact = self.root / ("callback-roots" + extension)
                    compiled = self.run_core("compile", source, "--emit", kind,
                                             "-o", artifact, level)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    symbols = subprocess.run([shutil.which("llvm-nm") or "nm", str(artifact)],
                                             capture_output=True, text=True, timeout=10)
                    self.assertEqual(symbols.returncode, 0, symbols.stderr)
                    for name in ("first_callback", "second_callback", "invoke_callback"):
                        self.assertRegex(symbols.stdout, r"(?m)\bT _?" + name + r"$")
                    binary = self.root / "callback-roots-client"
                    linked = subprocess.run(["clang", str(client), str(artifact), "-o", str(binary)],
                                            capture_output=True, text=True, timeout=30)
                    self.assertEqual(linked.returncode, 0, linked.stderr)
                    native = subprocess.run([str(binary), "17"], capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(native.returncode, 0, native.stderr)

    def test_dead_functions_keep_diagnostics_in_unreachable_bodies(self):
        source = "(%function unreachable () i64 missing)" + self.program("42")
        for mode in ("check", "eval", "emit-llvm", "compile-report"):
            options = ("-o", self.root / "invalid-dead", "-O2") if mode == "compile-report" else ()
            with self.subTest(mode=mode):
                result = self.run_core(mode, source, *options)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("unknown local name", result.stderr)

    def test_llvm_pipeline_removes_internal_functions(self):
        source = """
(%function unreachable () i64 12345)
(%function answer () i64 42)
(native-export answer "answer")
(%function main () i64 (answer))
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        functions = re.findall(
            r'define internal i64 @("[^"\n]+"|[\w.]+)\(\)(?: !dbg !\d+)? \{\n(.*?)\n\}',
            emitted.stdout, re.S)
        names = [name.strip('"') for name, body in functions
                 if re.search(r"ret i64 12345\b", body)]
        self.assertEqual(len(names), 1, emitted.stdout)
        nm = shutil.which("llvm-nm") or shutil.which("nm")
        self.assertIsNotNone(nm)
        for level in ("-O0", "-O1", "-O2", "-O3"):
            with self.subTest(level=level):
                artifact = self.root / "pipeline.o"
                compiled = self.run_core("compile", source, "--emit", "object",
                                         "-o", artifact, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                symbols = subprocess.run([nm, str(artifact)], capture_output=True,
                                         text=True, timeout=10)
                self.assertEqual(symbols.returncode, 0, symbols.stderr)
                pattern = r"(?m)\b[tT] _?" + re.escape(names[0]) + r"$"
                if level == "-O0":
                    self.assertRegex(symbols.stdout, pattern)
                else:
                    self.assertNotRegex(symbols.stdout, pattern)
                self.assertRegex(symbols.stdout, r"(?m)\bT _?answer$")
                binary = self.root / "pipeline"
                compiled = self.run_core("compile-report", source, "-o", binary, level)
                self.assertEqual(compiled.returncode, 0, compiled.stderr)
                native = subprocess.run([str(binary)], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(native.returncode, 0, native.stderr)
                self.assertEqual(native.stdout, "i64:42\n")

    def test_llvm_pipeline_preserves_divergence(self):
        source = "(%function loop () i64 (loop))" + self.program("(let ((unused (loop))) 42)")
        binary = self.root / "nonterminating"
        compiled = self.run_core("compile-report", source, "-o", binary, "-O2")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        try:
            native = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=0.5)
        except subprocess.TimeoutExpired:
            return
        # Stack exhaustion is possible if recursion remains; returning normally
        # would mean the optimizer incorrectly discarded a potentially diverging call.
        self.assertNotEqual(native.returncode, 0, native.stdout)

    def test_llvm_pipeline_specializes_constant_arguments(self):
        source = """
(%function select ((mode i64) (value i64)) i64
  (match (%=-primitive-i64 mode 0) (true value) (false (%+-primitive-i64 value 1))))
(%function dynamic ((mode i64) (value i64)) i64 (select mode value))
(%function main () i64
  (%+-primitive-i64 (select 0 20) (%+-primitive-i64 (select 1 20) (dynamic 0 0))))
"""
        self.agrees(source, 41)
        for level in ("-O0", "-O2"):
            binary = self.root / ("specialization-" + level[1:])
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True,
                                    timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, "i64:41\n")

    def test_llvm_pipeline_preserves_temporary_product_values(self):
        source = """
(%function project ((value (tuple i64 i64))) i64
  (%+-primitive-i64 (tuple-get value 0) (tuple-get value 1)))
(%function main () i64
  (project (tuple (%+-primitive-i64 19 2) (%+-primitive-i64 20 1))))
"""
        self.agrees(source, 42)
        for level in ("-O0", "-O2"):
            binary = self.root / ("temporary-product-" + level[1:])
            compiled = self.run_core("compile-report", source, "-o", binary, level)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            native = subprocess.run([str(binary)], capture_output=True, text=True,
                                    timeout=10)
            self.assertEqual(native.returncode, 0, native.stderr)
            self.assertEqual(native.stdout, "i64:42\n")

    def test_native_known_function_pointer_arguments(self):
        source = """
(%type Callback (pointer (function (i64) i64)))
(%function increment ((value i64)) i64 (%+-primitive-i64 value 1))
(%noinline increment)
(%function apply ((callback Callback) (value i64)) i64 (callback value))
(%noinline apply)
(%function main () i64 (apply increment 41))
"""
        self.agrees(source, 42)

    def test_native_constant_function_arguments(self):
        source = """
(%function choose ((mode i64) (value i64)) i64
  (match (%=-primitive-i64 mode 0) (true value) (false (%+-primitive-i64 value 1))))
(%function main () i64 (choose 0 42))
"""
        self.agrees(source, 42)

    def test_llvm_pipeline_preserves_callbacks(self):
        source = """
(%type Callback (pointer (function (i32) i32)))
(%function increment ((value i32)) i32 (%+-primitive-i32 value 1))
(%function callback () Callback increment)
(%function apply ((function Callback) (value i32)) i32 (function value))
(native-export callback "get_callback")
(native-export apply "apply_callback")
"""
        library = self.root / "callbacks.a"
        compiled = self.run_core("compile", source, "--emit", "static-library",
                                 "-o", library, "-O2")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        client = self.root / "callbacks.c"
        client.write_text("""
#include <stdint.h>
typedef int32_t (*callback)(int32_t);
extern callback get_callback(void);
extern int32_t apply_callback(callback, int32_t);
static int32_t twice(int32_t x) { return x * 2; }
int main(void) {
  return get_callback()(41) == 42 && apply_callback(twice, 21) == 42 ? 0 : 1;
}
""")
        binary = self.root / "callback client"
        linked = subprocess.run(["clang", str(client), str(library), "-o", str(binary)],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(linked.returncode, 0, linked.stderr)
        native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        self.assertEqual(native.returncode, 0, native.stderr)
