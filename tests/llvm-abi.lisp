(in-package #:verona/tests)

(in-suite :verona)

(test crosses-the-c-bool-abi
  ;; The C fixture receives and returns C `_Bool`, exercising the ABI in both
  ;; directions rather than merely checking Verona's internal i1 lowering.
  (let* ((source
           "(external-function invert \"verona_bool_invert\" (bool) bool)
            (function main () exit-code
              (match (invert false)
                (true 42)
                (false 1)))")
         (unit (compile-string (make-compiler) source))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    ;; `zeroext` is required at the C ABI boundary even though Verona's
    ;; internal boolean representation is simply i1.
    (is (search "declare zeroext i1 @verona_bool_invert(i1 zeroext)" ir))
    (is (= 42
	   (compile-and-run-native-with-link-arguments
	    source
	    (list (namestring (native-c-fixture "tests/native/c/bool.c"))))))))

(test annotates-all-narrow-c-abi-integers
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function narrow \"verona_narrow\" (i8 i16 u8 u16 char) i8)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "declare signext i8 @verona_narrow(i8 signext, i16 signext, i8 zeroext, i16 zeroext, i8 zeroext)" ir))))

(test crosses-c-aggregate-values-and-callbacks
  (is (= 42
         (compile-and-run-native-with-link-arguments
          "(type pair-value (product (left i32) (right i32)))
           (type choice-value (sum (none) (integer i32) (floating f64)))
           (external-function pair-sum \"verona_pair_value_sum\" (pair-value) i32)
           (external-function pair-make \"verona_pair_value_make\" (i32 i32) pair-value)
           (external-function array-sum \"verona_i32x2_sum\" ((array i32 2)) i32)
           (external-function choice-read \"verona_choice_value_read\" (choice-value) i32)
           (external-function apply \"verona_apply_i32\" ((pointer (function (i32) i32)) i32) i32)
           (function increment ((value i32)) i32 (+ value 1))
           (function main () exit-code
             (apply increment 41))"
          (list (namestring (native-c-fixture "tests/native/c/abi_values.c")))))))

(test calls-verona-functions-through-function-pointers
  ;; A function name decays to the parameter's pointer-to-function type. The
  ;; callee then invokes that parameter indirectly, entirely within Verona.
  (is (= 42
         (compile-and-run-native
          "(function increment ((value i32)) i32 (+ value 1))
           (function apply ((callback (pointer (function (i32) i32))) (value i32)) i32
             (callback value))
           (function main () exit-code
             (apply increment 41))"))))

(test stores-and-executes-function-pointers-in-fixed-arrays
  ;; ARRAY-OF contextually decays both declarations to the same function
  ;; pointer type. INDEX then loads an element before the indirect call.
  (is (= 42
         (compile-and-run-native
          "(function add-one ((value i32)) i32 (+ value 1))
           (function double ((value i32)) i32 (* value 2))
           (function apply-both
             ((callbacks (array (pointer (function (i32) i32)) 2)) (value i32))
             i32
             (let ((first (pointer (function (i32) i32)) (index callbacks 0))
                   (second (pointer (function (i32) i32)) (index callbacks 1)))
               (second (first value))))
           (function main () exit-code
             (apply-both (array-of add-one double) 20))"))))

(test calls-a-private-c-struct-through-an-opaque-handle
  ;; The fixture's struct definition is private to C.  Verona observes only
  ;; its nominal pointer type, so this also exercises native linking.
  (is (= 42
         (compile-and-run-native-with-link-arguments
          "(type hidden)
           (external-function hidden-create \"verona_hidden_create\" () (pointer hidden))
           (external-function hidden-read \"verona_hidden_read\" ((pointer hidden)) i32)
           (external-function hidden-destroy \"verona_hidden_destroy\" ((pointer hidden)) void)
           (function main () exit-code
             (let ((value (pointer hidden) (hidden-create)))
               (let ((answer i32 (hidden-read value)))
                 (do (hidden-destroy value) answer))))"
          (list (namestring (native-c-fixture "tests/native/c/opaque.c")))))))

(test passes-a-known-product-layout-to-native-c
  ;; This is a native-target ABI test.  The C fixture accesses both fields,
  ;; so it detects disagreement in the selected product layout or alignment.
  (is (= 42
         (compile-and-run-native-with-link-arguments
          "(type pair (product (left i64) (right i64)))
           (external-function pair-check \"verona_pair_check\" ((pointer pair)) i32)
           (function verify ((value pair)) i32 (pair-check (& value)))
           (function main () exit-code (verify (pair 20 22)))"
          (list (namestring (native-c-fixture "tests/native/c/layout.c")))))))

