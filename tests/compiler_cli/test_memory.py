"""Globals, addressable storage, arrays, pointers, and type aliases."""

import os
import subprocess
import sys

from .support import CompilerTestCase, REPO_ROOT


PACKET_ARRAY_SOURCE = """
(%type Bytes (array u8 8))
(%type Packet (product (bytes Bytes)))
(%function read-byte ((packet Packet) (offset usize)) u8
  (index (field packet bytes) offset))
(%function main () i64
  (%zext-primitive-u8-i64 (read-byte (Packet (array-of 0 1 2 3 42 5 6 7)) 4)))
"""

EXPORTED_GLOBAL_SOURCE = """
(%variable counter i64 1)
(%variable hidden i64 99)
(%function bump () unit (store counter (%+-primitive-i64 counter 1)))
(%export counter bump)
"""

TYPE_ALIAS_SOURCE = """
(%export Scalar Record Alias)
(%type Scalar Hidden)
(%type Hidden i64)
(%type Alias Record)
(%type Record (product (value Scalar)))
"""


class MemoryTests(CompilerTestCase):
    def test_store_updates_parameter(self):
        self.agrees("""
(%function update ((value i64)) i64 (do (store value 42) value))
(%function main () i64 (update 1))
""", 42)

    def test_assign_updates_parameter(self):
        self.agrees("""
(%function update ((value i64)) i64 (do (assign value (%+-primitive-i64 value 2)) value))
(%function main () i64 (update 40))
""", 42)

    def test_store_through_local_pointer_alias(self):
        self.agrees("""
(%function main () i64
  (let ((value i64 40) (first (& value)) (second first))
    (store (dereference second) (%+-primitive-i64 (deref first) 2))
    value))
""", 42)

    def test_callee_mutates_addressed_local(self):
        self.agrees("""
(%function increment ((pointer (pointer i64))) unit
  (store (deref pointer) (%+-primitive-i64 (deref pointer) 2)))
(%function main () i64
  (let ((value i64 40)) (increment (address-of value)) value))
""", 42)

    def test_store_updates_product_field(self):
        self.agrees("""
(%type Record (product (value i32) (flag bool)))
(%function update ((record Record)) i64
  (do (store (field record value) 42) (%sext-primitive-i32-i64 (field record value))))
(%function main () i64 (update (Record 1 false)))
""", 42)

    def test_store_updates_boolean_product_field(self):
        self.agrees("""
(%type Record (product (value i32) (flag bool)))
(%function update ((record Record)) i64
  (do (store (field record flag) true) (match (field record flag) (true 42) (false 0))))
(%function main () i64 (update (Record 1 false)))
""", 42)

    def test_store_through_address_of_product_field(self):
        self.agrees("""
(%type Record (product (value i32) (flag bool)))
(%function update ((record Record)) i64
  (let ((pointer (& (field record value))))
    (store (deref pointer) (%+-primitive-i32 (deref pointer) 2))
    (%sext-primitive-i32-i64 (field record value))))
(%function main () i64 (update (Record 40 false)))
""", 42)

    def test_store_updates_tuple_components(self):
        self.agrees("""
(%function update ((value (tuple i64 bool))) i64
  (do (store (tuple-get value 0) 42) (store (tuple-get value 1) true)
    (match (tuple-get value 1) (true (tuple-get value 0)) (false 0))))
(%function main () i64 (update (tuple (cast i64 0) false)))
""", 42)

    def test_negative_signed_pointer_offset_reaches_previous_array_element(self):
        self.agrees("""
(%function main () i64
  (let ((values (array-of (cast i64 10) 20 30)) (middle (& (index values 1))))
    (store (deref (pointer-offset middle (cast i16 -1))) 42)
    (index values 0)))
""", 42)

    def test_unsigned_pointer_offset_reaches_next_array_element(self):
        self.agrees("""
(%function main () i64
  (let ((values (array-of (cast i64 10) 20 30)) (middle (& (index values 1))))
    (store (deref (pointer-offset middle (cast u8 1))) 42)
    (index values 2)))
""", 42)

    def test_store_updates_array_at_runtime_index(self):
        self.agrees("""
(%function update ((values (array i64 2)) (index u64)) i64
  (do (store (index values index) 42) (index values index)))
(%function main () i64 (update (array-of 1 2) 1))
""", 42)

    def test_product_copy_is_independent_of_pointer_writes(self):
        self.agrees("""
(%type Record (product (flag bool) (value f32) (bytes (array u8 2))))
(%function main () i64
  (let ((record (Record false 1.5 (array-of (cast u8 1) 2))) (pointer (& record))
        (snapshot record))
    (store (field (deref pointer) flag) true)
    (match (field record flag)
      (true (match (field snapshot flag) (true 0) (false 42)))
      (false 0))))
""", 42)

    def test_store_updates_float_field_through_product_pointer(self):
        self.agrees("""
(%type Record (product (flag bool) (value f32) (bytes (array u8 2))))
(%function main () i64
  (let ((record (Record false 1.5 (array-of (cast u8 1) 2))) (pointer (& record)))
    (store (field (deref pointer) value) 42.0)
    (%fptosi-primitive-f32-i64 (field record value))))
""", 42)

    def test_store_updates_nested_array_through_product_pointer(self):
        self.agrees("""
(%type Record (product (flag bool) (value f32) (bytes (array u8 2))))
(%function main () i64
  (let ((record (Record false 1.5 (array-of (cast u8 1) 2))) (pointer (& record)))
    (store (index (field (deref pointer) bytes) 1) 42)
    (%zext-primitive-u8-i64 (index (field record bytes) 1))))
""", 42)

    def test_store_through_pointer_to_pointer(self):
        self.agrees("""
(%function main () i64
  (let ((value i64 0) (pointer (& value)) (indirect (& pointer)))
    (store (deref (deref indirect)) 42)
    value))
""", 42)

    def test_store_through_pointer_replaces_sum_variant(self):
        self.agrees("""
(%type Value (sum (Integer i64) (Real f64)))
(%function main () i64
  (let ((value (Integer (cast i64 1))) (pointer (& value)))
    (store (deref pointer) (Real 42.5))
    (match value ((Integer x) x) ((Real x) (%fptosi-primitive-f64-i64 x)))))
""", 42)

    def test_recursive_product_pointer_can_point_to_self(self):
        self.agrees("""
(%type Node (product (next (pointer Node)) (value i64)))
(%function main () i64
  (let ((node (Node (cast (pointer Node) (cast (pointer void) "")) 42)) (pointer (& node)))
    (store (field (deref pointer) next) pointer)
    (field (deref (field (deref pointer) next)) value)))
""", 42)

    def test_dereference_data_pointer_at_byte_offset(self):
        self.agrees(self.program('(%zext-primitive-u8-i64 (deref (pointer-offset "abc" 2)))'), 99)

    def test_data_pointer_reports_remaining_bytes(self):
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

    def test_evaluator_rejects_store_through_read_only_data_pointer(self):
        evaluated = self.run_core("eval", self.program(r'(do (store (deref "abc") #\z) 42)'))
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("read-only", evaluated.stderr)

    def test_evaluator_rejects_data_pointer_offsets_outside_literal(self):
        for name, expression in (
            ("past-end", '(deref (pointer-offset "abc" 4))'),
            ("negative", '(pointer-offset "abc" -1)'),
            ("unsigned-overflow", '(pointer-offset "abc" (cast u64 18446744073709551615))'),
        ):
            with self.subTest(case=name):
                evaluated = self.run_core("eval", self.program(f"(do {expression} 42)"))
                self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
                self.assertIn("invalid pointer", evaluated.stderr)

    def test_evaluator_rejects_dereference_past_local(self):
        evaluated = self.run_core("eval", self.program(
            "(let ((value (cast i64 1))) (deref (pointer-offset (& value) 1)))"))
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("invalid pointer", evaluated.stderr)

    def test_evaluator_rejects_misaligned_pointer_dereference(self):
        evaluated = self.run_core("eval", self.program(
            '(deref (cast (pointer i64) (cast (pointer void) (pointer-offset "0123456789" 1))))'))
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("invalid pointer", evaluated.stderr)

    def test_evaluator_rejects_pointer_to_expired_local(self):
        escaped = """
(%function escape () (pointer i64) (let ((value i64 1)) (& value)))
(%function main () i64 (deref (escape)))
"""
        evaluated = self.run_core("eval", escaped)
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("expired storage", evaluated.stderr)

    def test_imported_and_forward_constants_resolve_despite_local_shadowing(self):
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

    def test_constant_initializers_preserve_typed_values(self):
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

    def test_base_global_assignment_survives_local_shadowing(self):
        base = REPO_ROOT / "projects/base/src"
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

    def test_returned_global_pointer_stays_writable(self):
        # Writes through returned pointers must outlive the returning frame.
        self.agrees("""
(%function address () (pointer bool) (& flag))
(%variable flag bool true)
(%function main () i64
  (do (store (deref (address)) false) (match flag (true 0) (false 42))))
""", 42)

    def test_store_replaces_global_data_pointer(self):
        self.agrees("""
(%variable text (pointer u8) "old")
(%function replace () unit (store text "*"))
(%function main () i64 (do (replace) (%zext-primitive-u8-i64 (deref text))))
""", 42)

    def test_generic_specializations_share_global_storage(self):
        self.agrees("""
(%variable counter i64 40)
(%function bump (for (T)) ((ignored T)) unit
  (store counter (%+-primitive-i64 counter 1)))
(%function main () i64
  (do (bump (cast i8 0)) (bump (cast f64 0.0)) counter))
""", 42)

    def test_global_initializers_preserve_typed_values(self):
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

    def test_module_aliases_share_exported_global_storage(self):
        (self.root / "state.vrn").write_text(EXPORTED_GLOBAL_SOURCE)
        self.agrees("""
(%import state :as s)
(%import state :as other)
(%variable counter i64 40)
(%function main () i64
  (do
    (store s:counter counter)
    (s:bump)
    (store (deref (& other:counter)) (%+-primitive-i64 s:counter 1))
    (match (%=-primitive-i64 (let ((counter i64 99)) counter) 99) (true other:counter) (false 0))))
""", 42)

    def test_module_hides_unexported_global(self):
        (self.root / "state.vrn").write_text(EXPORTED_GLOBAL_SOURCE)
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
      (match flag (true (match (== value 1.5) (true (%zext-primitive-u8-i64 byte)) (false 0))) (false 0))))
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

    def test_index_fixed_size_array_in_product(self):
        self.agrees(PACKET_ARRAY_SOURCE, 42)

    def test_emit_fixed_size_array_layout(self):
        emitted = self.run_core("emit-llvm", PACKET_ARRAY_SOURCE)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertIn("[8 x i8]", emitted.stdout)

    def test_generic_function_accepts_fixed_size_array(self):
        self.agrees("""
(%function first (for (a)) ((value (array a 2))) a (index value 0))
(%function main () i64 (first (array-of (cast i64 42) 0)))
""", 42)

    def test_report_empty_and_nested_arrays(self):
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

    def test_runtime_index_rejects_out_of_bounds_array_access(self):
        bad_index = PACKET_ARRAY_SOURCE.replace("5 6 7)) 4", "5 6 7)) 8")
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

    def test_check_rejects_invalid_fixed_size_arrays(self):
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

    def test_call_imported_function_pointer_from_product_field(self):
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

    def test_call_function_pointer_after_erasing_and_restoring_type(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function answer () i64 42)
(%function main () i64
  (let ((callback Callback answer)
        (erased (pointer void) (cast (pointer void) callback))
        (temporary (pointer (function (u8) bool)) (cast (pointer (function (u8) bool)) erased)))
    ((cast Callback (cast (pointer void) temporary)))))
""", 42)

    def test_check_rejects_invalid_function_pointer_signatures_and_calls(self):
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

    def test_two_addresses_of_same_local_compare_equal(self):
        self.agrees(self.program("""
(let ((value i64 7) (p (& value)))
  (match (== p (& value)) (true 42) (false 0)))
"""), 42)

    def test_addresses_of_equal_values_in_distinct_locals_compare_unequal(self):
        self.agrees(self.program("""
(let ((value i64 7) (other i64 7))
  (match (!= (& value) (& other)) (true 42) (false 0)))
"""), 42)

    def test_pointer_equality_with_nil(self):
        for expression in (
            "(%/=-primitive-pointer (& value) nil)",
            "(%/=-primitive-pointer nil (& value))",
            "(== nil nil)",
        ):
            with self.subTest(expression=expression):
                self.agrees(self.program(f"""
  (let ((value i64 42))
    (match {expression} (true 42) (false 0)))
"""), 42)

    def test_nil_pointer_initializers(self):
        for form, ty, comparison in (
            ("%constant", "u8", "(%=-primitive-pointer saved nil)"),
            ("%variable", "i64", "(== nil saved)"),
        ):
            with self.subTest(form=form):
                self.agrees(f"({form} saved (pointer {ty}) nil)" +
                            self.program(f"(match {comparison} (true 42) (false 0))"), 42)

    def test_pointer_offset_scales_by_element_size(self):
        for form in ("%pointer-offset-primitive-i64", "%pointer-offset-primitive-T"):
            with self.subTest(form=form):
                self.agrees(self.program(f"""
  (let ((items (array-of (cast i64 20) 42))
        (first (& (index items 0)))
        (second (& (index items 1))))
    (match (%=-primitive-pointer ({form} first 1) second)
      (true 42)
      (false 0)))
"""), 42)

    def test_pointer_offset_scales_by_padded_aggregate_size(self):
        self.agrees("""
(%type Cell (product (flag bool) (value i64)))
(%function main () i64
  (let ((cells (array-of (Cell true 20) (Cell false 42)))
        (first (& (index cells 0)))
        (second (& (index cells 1))))
    (match (== (%pointer-offset-primitive-T first 1) second)
      (true 42)
      (false 0))))
""", 42)

    def test_pointer_offset_can_round_trip_outside_object(self):
        self.agrees(self.program("""
  (let ((value i64 42)
        (first (& value))
        (beyond (%pointer-offset-primitive-T first 4)))
    (match (== (%pointer-offset-primitive-T beyond -4) first)
      (true 42)
      (false 0)))
"""), 42)

    def test_pointer_offset_accepts_nil(self):
        offset = """
(%function offset-null ((count i64)) (pointer i64)
  (%pointer-offset-primitive-T nil count))
"""
        for condition in (
            "(%is-null-primitive-pointer (offset-null 0))",
            "(%is-null-primitive-pointer (%pointer-offset-primitive-i64 nil 0))",
            "(%/=-primitive-pointer (offset-null 1) nil)",
            "(== (%pointer-offset-primitive-T (offset-null 1) -1) nil)",
        ):
            with self.subTest(condition=condition):
                self.agrees(offset + self.program(f"(match {condition} (true 42) (false 0))"), 42)

    def test_pointer_dereference_loads_pointee(self):
        self.agrees(self.program("(let ((value i64 42)) (%pointer-dereference (& value)))"), 42)

    def test_pointer_dereference_rejects_null_access(self):
        evaluated = self.run_core("eval", self.program("(%pointer-dereference (cast (pointer i64) nil))"))
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("invalid pointer", evaluated.stderr)

    def test_pointer_index_rejects_access_at_null_derived_address(self):
        evaluated = self.run_core("eval", self.program(
            "(%pointer-index (%pointer-offset-primitive-i64 nil 1) 0)"))
        self.assertEqual(evaluated.returncode, 70, evaluated.stderr)
        self.assertIn("invalid pointer", evaluated.stderr)

    def test_pointer_index_loads_with_negative_offset(self):
        self.agrees(self.program("""
  (let ((items (array-of (cast i64 42) 20))
        (second (& (index items 1))))
    (%pointer-index second -1))
"""), 42)

    def test_pointer_index_scales_by_padded_aggregate_size(self):
        self.agrees("""
(%type Cell (product (flag bool) (value i64)))
(%function main () i64
  (let ((cells (array-of (Cell true 20) (Cell false 42)))
        (first (& (index cells 0))))
    (field (%pointer-index first 1) value)))
""", 42)

    def test_pointer_ordering_operators(self):
        for operator, operands in (
            ("%<-primitive-pointer", "first second"),
            ("%<=-primitive-pointer", "first first"),
            ("%>-primitive-pointer", "second first"),
            ("%>=-primitive-pointer", "second second"),
            ("<", "first second"),
            ("<=", "first second"),
            (">", "second first"),
            (">=", "second first"),
        ):
            with self.subTest(operator=operator):
                self.agrees(self.program(f"""
  (let ((items (array-of (cast i64 20) 42))
        (first (& (index items 0)))
        (second (& (index items 1))))
    (match ({operator} {operands}) (true 42) (false 0)))
"""), 42)

    def test_pointer_ordering_accepts_nil(self):
        for condition in (
            "(%=-primitive-bool (< nil (& value)) (> (& value) nil))",
            "(<= nil saved)",
            "(>= saved nil)",
        ):
            with self.subTest(condition=condition):
                self.agrees(self.program(f"""
  (let ((value i64 42) (saved (pointer i64) nil))
    (match {condition} (true 42) (false 0)))
"""), 42)

    def test_pointer_difference_is_absolute_across_pointee_types(self):
        for operands in ("second erased", "erased second"):
            with self.subTest(operands=operands):
                self.agrees(self.program(f"""
  (let ((items (array-of (cast i64 20) 42))
        (first (& (index items 0)))
        (second (& (index items 1)))
        (erased (cast (pointer void) first)))
    (match (== (%pointer-difference-primitive-pointer {operands}) 8)
      (true 42)
      (false 0)))
"""), 42)

    def test_pointer_difference_measures_from_nil(self):
        for operands, expected in (
            ("nil nil", 0),
            ("(%pointer-offset-primitive-i64 nil 1) nil", 8),
        ):
            with self.subTest(operands=operands):
                self.agrees(self.program(f"""
  (match (== (%pointer-difference-primitive-pointer {operands}) {expected})
    (true 42)
    (false 0))
"""), 42)

    def test_pointer_nil_as_value(self):
        source = """
(%function accept ((value (pointer u8))) (pointer u8) value)
(%function main () (pointer u8) (accept nil))
"""
        evaluated = self.run_core("eval", source)
        self.assertEqual(evaluated.returncode, 0, evaluated.stderr)
        self.assertEqual(evaluated.stdout, "pointer\n")
        for level in ("-O0", "-O2"):
            with self.subTest(level=level):
                native = self.run_native_report(source, level)
                self.assertEqual(native.returncode, 0, native.stderr)
                self.assertEqual(native.stdout, "pointer\n")

    def assert_pointer_check_rejects(self, declaration, message):
        result = self.run_core("check", declaration + self.program("0"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(message, result.stderr)

    def test_nil_cannot_initialize_integer(self):
        self.assert_pointer_check_rejects("(%function f () i64 nil)", "expected i64")

    def test_nil_cannot_be_used_as_type(self):
        self.assert_pointer_check_rejects("(%function f () nil unit)", "unknown core type")

    def test_integer_cannot_initialize_pointer(self):
        self.assert_pointer_check_rejects(
            "(%function f () (pointer i64) 0)", "expected (pointer i64)")

    def test_pointer_offset_requires_i64_count(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer i64)) (n u64)) (pointer i64)"
            " (%pointer-offset-primitive-T p n))", "expected i64")

    def test_pointer_offset_suffix_must_match_pointee(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer u8))) (pointer u8)"
            " (%pointer-offset-primitive-i64 p 0))", "match the offset primitive suffix")

    def test_pointer_dereference_requires_complete_pointee(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer void))) i64 (%pointer-dereference p))",
            "complete object type")

    def test_pointer_index_requires_complete_pointee(self):
        for pointee in ("Opaque", "void", "(function () i64)"):
            with self.subTest(pointee=pointee):
                self.assert_pointer_check_rejects(
                    f"(%type Opaque)(%function f ((p (pointer {pointee})))"
                    " i64 (%pointer-index p 0))", "complete object type")

    def test_pointer_equality_requires_matching_pointees(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer i64)) (q (pointer u64))) bool"
            " (%=-primitive-pointer p q))", "matching pointer types")

    def test_pointer_ordering_requires_matching_pointees(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer i64)) (q (pointer u64))) bool"
            " (< p q))", "no matching generic implementation")

    def test_pointer_ordering_rejects_integer_operand(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer i64))) bool (%<=-primitive-pointer p (cast i64 0)))",
            "matching pointer types")

    def test_pointer_difference_rejects_integer_operand(self):
        self.assert_pointer_check_rejects(
            "(%function f ((p (pointer i64))) usize"
            " (%pointer-difference-primitive-pointer p (cast i64 0)))", "pointer operands")

    def test_zero_offset_preserves_local_pointer_identity(self):
        self.agrees(self.program("""
(let ((value i64 7) (p (& value)))
  (match (== p (pointer-offset p 0)) (true 42) (false 0)))
"""), 42)

    def test_offset_pointer_equals_address_of_same_array_element(self):
        self.agrees(self.program("""
(let ((items (array-of (cast i64 1) 2)) (first (& (index items 0))))
  (match (== (pointer-offset first 1) (& (index items 1))) (true 42) (false 0)))
"""), 42)

    def test_one_past_array_pointers_compare_equal(self):
        self.agrees(self.program("""
(let ((items (array-of (cast i64 1) 2)) (first (& (index items 0))))
  (match (== (pointer-offset first 2) (pointer-offset first 2)) (true 42) (false 0)))
"""), 42)

    def test_returned_global_pointer_equals_direct_address(self):
        self.agrees("""
(%variable total i64 42)
(%function address () (pointer i64) (& total))
(%function main () i64 (match (== (address) (& total)) (true 42) (false 0)))
""", 42)

    def test_zero_offset_preserves_data_pointer_identity(self):
        self.agrees(self.program("""
(let ((text "abc"))
  (match (== text (pointer-offset text 0)) (true 42) (false 0)))
"""), 42)

    def test_advancing_and_reversing_data_pointer_offset_preserves_identity(self):
        self.agrees(self.program("""
(let ((text "abc") (p (pointer-offset text 1)))
  (match (== text (pointer-offset p -1)) (true 42) (false 0)))
"""), 42)

    def test_data_pointers_at_different_offsets_compare_unequal(self):
        self.agrees(self.program("""
(let ((text "abc"))
  (match (!= text (pointer-offset text 1)) (true 42) (false 0)))
"""), 42)

    def test_cast_through_opaque_pointer_preserves_data_pointer_identity(self):
        self.agrees("""
(%type Opaque)
(%function main () i64
  (let ((text "abc") (opaque (cast (pointer Opaque) (cast (pointer void) text))))
    (match (== (cast (pointer void) opaque) (cast (pointer void) text)) (true 42) (false 0))))
""", 42)

    def test_pointer_comparison_evaluates_operands_once_in_order(self):
        # Argument side effects run once, left to right, before comparison.
        self.agrees("""
(%variable calls i64 0)
(%variable value i64 42)
(%function next ((expected i64)) (pointer i64)
  (do (store calls (match (%=-primitive-i64 calls expected) (true (%+-primitive-i64 calls 1)) (false 99))) (& value)))
(%function main () i64
  (match (== (next 0) (next 1)) (true (match (%=-primitive-i64 calls 2) (true 42) (false 0))) (false 0)))
""", 42)

    def test_emit_pointer_equality_comparisons(self):
        emitted = self.run_core("emit-llvm", """
(%function same ((left (pointer i64)) (right (pointer i64))) bool (== left right))
(%function different ((left (pointer i64)) (right (pointer i64))) bool (!= left right))
(%function main () i64 42)
""")
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertRegex(emitted.stdout, r"icmp eq ptr")
        self.assertRegex(emitted.stdout, r"icmp ne ptr")

    def test_repeated_designators_of_same_function_compare_equal(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function target () i64 1)
(%function main () i64
  (let ((a Callback target) (b Callback target))
    (match (== a b) (true 42) (false 0))))
""", 42)

    def test_returned_function_pointer_equals_original_designator(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function target () i64 1)
(%function get () Callback target)
(%function main () i64
  (let ((a Callback target)) (match (== a (get)) (true 42) (false 0))))
""", 42)

    def test_pointers_to_distinct_functions_compare_unequal(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function first () i64 1)
(%function second () i64 2)
(%function main () i64
  (let ((a Callback first) (b Callback second))
    (match (!= a b) (true 42) (false 0))))
""", 42)

    def test_cast_to_void_pointer_preserves_function_identity(self):
        self.agrees("""
(%type Callback (pointer (function () i64)))
(%function target () i64 1)
(%function main () i64
  (let ((a Callback target) (b Callback target))
    (match (== (cast (pointer void) a) (cast (pointer void) b)) (true 42) (false 0))))
""", 42)

    def test_native_declarations_of_same_symbol_have_equal_function_pointers(self):
        # Two declarations of one native symbol denote the same function.
        self.agrees("""
(%type Callback (pointer (function () i32)))
(%external-function first "getpid" () i32)
(%external-function second "getpid" () i32)
(%function main () i64
  (let ((a Callback first) (b Callback second)) (match (== a b) (true 42) (false 0))))
""", 42)

    def test_explicit_implementation_overrides_default_pointer_comparison(self):
        for operator, value, body in (("==", "false", "(match (== p p) (true 0) (false 42))"),
                                      ("!=", "true", "(match (!= p p) (true 42) (false 0))")):
            with self.subTest(operator=operator):
                self.agrees(f"""
(%implementation {operator} ((left (pointer i64)) (right (pointer i64))) bool {value})
(%function main () i64 (let ((value i64 0) (p (& value))) {body}))
""", 42)

    def test_lexical_function_overrides_default_pointer_equality(self):
        self.agrees("""
(%function == ((a (pointer i64)) (b (pointer i64))) bool false)
(%function main () i64 (let ((value i64 0)) (match (== (& value) (& value)) (true 0) (false 42))))
""", 42)

    def test_protocol_evidence_overrides_default_pointer_equality(self):
        self.agrees("""
(%protocol Custom (a) (== ((left a) (right a)) bool))
(%implementation (Custom (pointer i64))
  (function == ((left (pointer i64)) (right (pointer i64))) bool false))
(%function apply (for (a) ((Custom a))) ((left a) (right a)) bool (== left right))
(%function main () i64
  (let ((value i64 0)) (match (apply (& value) (& value)) (true 0) (false 42))))
""", 42)

    def test_declared_generic_falls_back_to_default_pointer_equality(self):
        # The reference also permits fallback for a source-declared equality generic.
        self.agrees("""
(%generic == (left right))
(%function main () i64 (let ((value i64 0)) (match (== (& value) (& value)) (true 42) (false 0))))
""", 42)

    def test_pointer_ordering_prefers_explicit_implementation(self):
        self.agrees("""
(%implementation < ((left (pointer i64)) (right (pointer i64))) bool true)
(%function main () i64
  (let ((value i64 0) (p (& value))) (match (< p p) (true 42) (false 0))))
""", 42)

    def test_invalid_pointer_equality(self):
        for declaration, body, message in (
            ("", '(let ((x i64 0) (y u64 0)) (== (& x) (& y)))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) (cast (pointer void) (& x))))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) (cast i64 0)))', "no matching generic implementation"),
            ("", '(let ((x i64 0)) (== (& x) 0))', "ambiguous numeric literal"),
            ("", '(let ((x i64 0)) (== (& x)))', "wrong generic argument count"),
            ("(%function a () i64 1)(%function b () bool true)",
             '(let ((a (pointer (function () i64)) a) (b (pointer (function () bool)) b)) (== a b))',
             "no matching generic implementation"),
        ):
            with self.subTest(body=body):
                checked = self.run_core("check", declaration + f"(%function main () bool {body})")
                self.assertEqual(checked.returncode, 2, checked.stderr)
                self.assertIn(message, checked.stderr)

    def test_restore_data_through_aliased_void_pointer(self):
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

    def test_check_rejects_invalid_pointer_types_and_casts(self):
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

    def test_opaque_type_alias_uses_native_pointer_abi(self):
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

    def test_check_rejects_invalid_opaque_type_uses(self):
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

    def test_imported_aliases_are_interchangeable_with_underlying_types(self):
        (self.root / "library.vrn").write_text(TYPE_ALIAS_SOURCE)
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

    def test_check_rejects_invalid_transparent_aliases(self):
        (self.root / "library.vrn").write_text(TYPE_ALIAS_SOURCE)
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
