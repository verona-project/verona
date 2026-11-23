"""LLVM output, native ABI, artifact emission, and linking."""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from .support import CompilerTestCase, FIXTURE_DIR


class NativeTests(CompilerTestCase):
    def test_emit_llvm_includes_source_debug_metadata(self):
        support = self.root / "support.vrn"
        support.write_text("""(%export add-two)
(%function add-two ((value i64)) i64 (%+-primitive-i64 value 2))""")
        source = """(%import support :as s)
(%function main () i64
  (let ((value i64 40))
    (s:add-two value)))"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertNotIn("!llvm.dbg.cu", emitted.stdout)
        self.assertNotIn("!dbg !", emitted.stdout)
        dwarfdump = shutil.which("llvm-dwarfdump")
        if dwarfdump is None:
            self.skipTest("llvm-dwarfdump is required for native debug-info inspection")
        binary = self.root / "debug-info"
        compiled = self.run_core("compile", source, "--debug", "-o", binary, "-O0")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        dsym = binary.with_name(binary.name + ".dSYM") / "Contents" / "Resources" / "DWARF" / binary.name
        debug_artifact = dsym if dsym.exists() else binary
        dump = subprocess.run([dwarfdump, "--debug-info", str(debug_artifact)],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(dump.returncode, 0, dump.stderr)
        self.assertIn(str(self.source), dump.stdout)
        self.assertIn(str(support), dump.stdout)
        self.assertIn('add-two', dump.stdout)
        self.assertRegex(dump.stdout, r'DW_AT_name\s+\("main"\)')
        self.assertRegex(dump.stdout, r'DW_AT_linkage_name\s+\("vrn\.input\.main"\)')
        self.assertRegex(dump.stdout, r'DW_AT_name\s+\("value"\)')

    def test_emit_llvm_uses_module_qualified_function_symbols(self):
        source = """
(%constant answer i64 40)
(%variable counter i64 2)
(%function main () i64 (%+-primitive-i64 answer counter))
"""
        emitted = self.run_core("emit-llvm", source)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("define internal i64 @vrn.input.main()", emitted.stdout)
        self.assertIn("@vrn.input.c_answer", emitted.stdout)
        self.assertIn("@vrn.input.v_counter", emitted.stdout)
        self.assertIn("@vrn.runtime.array.failure", emitted.stdout)
        for kind in ("i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64"):
            self.assertIn("@vrn.runtime.div." + kind, emitted.stdout)
        objdump = shutil.which("llvm-objdump")
        if objdump is None:
            self.skipTest("llvm-objdump is required for native symbol inspection")
        binary = self.root / "symbol-names"
        compiled = self.run_core("compile", source, "-o", binary, "-O0")
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        symbols = subprocess.run([objdump, "--syms", str(binary)],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(symbols.returncode, 0, symbols.stderr)
        self.assertRegex(symbols.stdout, r"(?m)\b_?vrn\.input\.main$")

    def test_external_functions_and_native_aggregate_layouts(self):
        fixture = (FIXTURE_DIR / "external.c")
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
(%function invert ((value bool)) bool (match value (true false) (false true)))
(%function bump-quad ((value Quad)) Quad
  (Quad (%+-primitive-f64 (field value a) 1.0) (field value b) (field value c) (field value d)))
"""
        cases = (
            ("(let ((r (record (Record 40 false)))) (match (field r flag) (true (%sext-primitive-i32-i64 (field r value))) (false 0)))", 42),
            ("(let ((r (Record 40 false))) (mutate-record (& r)) (match (field r flag) (true (%sext-primitive-i32-i64 (field r value))) (false 0)))", 42),
            ("(%fptosi-primitive-f32-i64 (field (floats (Floats 1.5 2.5)) y))", 4),
            ("(%fptosi-primitive-f64-i64 (field (quad (Quad 40.0 1.0 2.0 3.0)) a))", 42),
            ("(%fptosi-primitive-f32-i64 (index (float-array (array-of 1.0 2.0 40.0)) 2))", 42),
            ("(%fptosi-primitive-f64-i64 (float 40.5 1.5))", 42),
            ("(match (big-choice (Big (Large (array-of 1 2 3)))) ((Big x) (index (field x elements) 2)) ((Nothing) 0))", 42),
            ("(let ((r (mixed (Mixed 1.5 38)))) (%+-primitive-i64 (%fptosi-primitive-f64-i64 (field r x)) (field r y)))", 43),
            ("(index (field (large (Large (array-of 10 20 30))) elements) 2)", 33),
            ("(%sext-primitive-i16-i64 (index (array (array-of 1 2 3)) 2))", 4),
            ("(match (choice (Small 40 false)) ((Small x flag) (match flag (true (%zext-primitive-u8-i64 x)) (false 0))) ((Real x) 0) ((Wrapped x) 0))", 42),
            ("(match (choice (Real 2.25)) ((Small x flag) 0) ((Real x) (%fptosi-primitive-f64-i64 x)) ((Wrapped x) 0))", 3),
            ("(match (choice (Wrapped (Record 40 true))) ((Small x flag) 0) ((Real x) 0) ((Wrapped x) (%sext-primitive-i32-i64 (field x value))))", 42),
            ("(let ((r (nested (Nested (Record 40 false) (array-of 1 2 3) false)))) (match (field r flag) (true (%sext-primitive-i32-i64 (field (field r record) value))) (false 0)))", 42),
            ("(%sext-primitive-i8-i64 (narrow -1 -2 20 25))", 42),
            ("(%sext-primitive-i32-i64 (field (record-callback bump (Record 40 false)) value))", 42),
            ("(index (field (large-callback bump-large (Large (array-of 41 0 0))) elements) 0)", 42),
            ("(match (choice-callback bump-choice (Small 1 false)) ((Small x flag) 0) ((Real x) (%fptosi-primitive-f64-i64 x)) ((Wrapped x) 0))", 42),
            ("(match (bool-callback invert false) (true 42) (false 0))", 42),
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
  (match true (true 42) (false (%reinterpret-primitive-u64-i64 (lib:length "hello")))))
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
        for declaration, condition in (
            ('(%external-function absent "absent" () (pointer u8))',
             "(== (absent) nil)"),
            ('(%external-function absent "absent" () (pointer u8))',
             "(%is-null-primitive-pointer (absent))"),
            ('(%external-function present "present" () (pointer u8))',
             "(%not-primitive-bool (%is-null-primitive-pointer (present)))"),
        ):
            source = declaration + self.program(f"(match {condition} (true 42) (false 0))")
            for level in ("-O0", "-O2"):
                with self.subTest(condition=condition, level=level):
                    binary = self.root / "null pointer executable"
                    result = self.run_core("compile-report", source, "-o", binary, level,
                                           env=dict(os.environ, VERONA_CORE_CLANG=str(wrapper)))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    native = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(native.returncode, 0, native.stderr)
                    self.assertEqual(native.stdout, "i64:42\n")

    def test_pointer_null_check_lowers_to_null_comparison(self):
        emitted = self.run_core("emit-llvm", """
(%function absent ((value (pointer u8))) bool (%is-null-primitive-pointer value))
(%function main () i64 42)
""")
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"icmp eq ptr %0, null")

    def test_pointer_null_check_requires_one_pointer(self):
        for source, message in (
            ("(%function main () bool (%is-null-primitive-pointer))", "primitive requires one argument"),
            ("(%function main () bool (%is-null-primitive-pointer 0))", "pointer null check requires a pointer"),
        ):
            with self.subTest(source=source):
                checked = self.run_core("check", source)
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_llvm_library_and_linker_boundary(self):
        environment = dict(os.environ, VERONA_CORE_CLANG="/nonexistent/compiler")
        source = "(%function choose ((x i64)) i64 (match (%<-primitive-i64 x 0) (true 7) (false (%+-primitive-i64 x 2))))" + self.program("(choose 40)")
        emitted = self.run_core("emit-llvm", source, env=environment)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("; ModuleID =", emitted.stdout)
        # Direct tail-call lowering emits a return in each branch instead of
        # materializing the conditional result through a merge phi.
        self.assertIn("case:", emitted.stdout)
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
        for level in ("-O0", "-O2"):
            with self.subTest(level=level):
                if level != "-O0":
                    result = self.run_core("compile", source, "--emit", "static-library",
                                           "-o", library, level)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(library.with_suffix(".h").read_text(), header)
                binary = self.root / "aggregate-client"
                linked = subprocess.run(["clang", "-Wall", "-Werror", str(client), str(library),
                                         "-o", str(binary)], capture_output=True, text=True, timeout=30)
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
  (let ((a Callback local) (b Callback imported)) (match (== a b) (true 42) (false 0))))
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
        for path_option, library_option, prefix in (("--library-path", "--native-library", ("dynamic",)),
                                                   ("-L", "-l", ())):
            binary = self.root / "linked executable"
            result = self.run_core("compile-report", program, "-o", binary, path_option, directory,
                                   library_option, *prefix, "answer")
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
        options = ["--native-library", "dynamic", "first", "-L", "path one", "-l", "second", "--library-path", "path two"]
        expected = ["-L", "path one", "-L", "path two", "-lfirst", "-lsecond"]
        if sys.platform == "darwin":
            options += ["--framework", "Core Foundation", "--framework", "Security"]
            expected += ["-framework", "Core Foundation", "-framework", "Security"]
        # Force several reallocations of both option and exec argument arrays.
        libraries = [f"extra{index}" for index in range(80)]
        options += [part for library in libraries for part in ("--native-library", "dynamic", library)]
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
            for option, values in (("--library", ("static", "value")),
                                   ("--native-library", ("dynamic", "value")),
                                   ("-l", ("value",)), ("--library-path", ("value",)),
                                   ("-L", ("value",)), ("--framework", ("value",))):
                result = self.run_core(mode, self.program("0"), option, *values)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
        for option in ("--library", "--native-library", "-l", "--library-path", "-L", "--framework", "-lanswer", "-Ldirectory"):
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
