(in-package #:verona/tests)

(in-suite :verona)

(defun native-test-path (type)
  (merge-pathnames (format nil "verona-native-~A.~A" (gensym "TEST-") type)
                   (uiop:temporary-directory)))

(defun compile-and-run-native (source)
  (let* ((executable (native-test-path "program"))
         (unit (compile-string (make-compiler) source))
         (program (compilation-unit-semantic-program unit)))
    (unwind-protect
         (progn
           (verona.backend.llvm:build-executable program executable)
           (nth-value 2 (uiop:run-program (list (namestring executable))
                                           :output :string :error-output :string
                                           :ignore-error-status t)))
      (when (probe-file executable)
        (delete-file executable)))))

(defun compile-and-run-native-with-link-arguments (source arguments)
  (let* ((executable (native-test-path "program"))
         (unit (compile-string (make-compiler) source))
         (program (compilation-unit-semantic-program unit))
         (configuration
           (verona.backend.llvm:make-codegen-configuration
            :output-kind :executable
            :linker (verona.backend.llvm:make-linker-configuration :arguments arguments))))
    (unwind-protect
         (progn
           (verona.backend.llvm:build-executable program executable :configuration configuration)
           (nth-value 2 (uiop:run-program (list (namestring executable))
                                           :output :string :error-output :string
                                           :ignore-error-status t)))
      (when (probe-file executable)
        (delete-file executable)))))

(defun native-c-fixture (name)
  (merge-pathnames name (asdf:system-source-directory :verona)))

(test creates-and-prints-an-empty-llvm-module
  (let ((backend (verona.backend.llvm:make-llvm-backend :module-name "empty")))
    (is (search "ModuleID = 'empty'" (verona.backend.llvm:print-llvm-module backend)))
    (is (eq backend (verona.backend.llvm:verify-llvm-module backend)))))

(test lowers-forward-function-calls-through-cl-llvm
  (let* ((unit (compile-string
                (make-compiler)
                (format nil
                        "(function add ((a i64) (b i64)) i64 (%+-primitive-i64 a b))~%(function main () i64 (add 20 22))")))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "define i64 @__verona_000061000064000064" ir))
    (is (search "add i64" ir))
    (is (search "call i64 @__verona_000061000064000064(i64 20, i64 22)" ir))))

(test marks-calls-in-tail-position
  (let* ((unit (compile-string
                (make-compiler)
                "(function countdown ((number i64) (total i64)) i64
                    (match (%=-primitive-i64 number 0)
                      (true total)
                      (false
                        (let ((next i64 (%--primitive-i64 number 1)))
                          (do (countdown next (%+-primitive-i64 total 1)))))))
                  (function widen ((number i32)) i64
                    (countdown (%sext-primitive-i32-i64 number) 0))
                  (function read ((address (pointer i64))) i64 (deref address))
                  (function through-address ((value i64)) i64 (read (& value)))"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    ;; COUNTDOWN calls itself from a MATCH/LET/sequence tail position.  Its
    ;; exact ABI matches, so LLVM verifies the stronger MUSTTAIL contract.
    (is (search "musttail call i64 @__verona_00006300006F00007500006E00007400006400006F00007700006E" ir))
    ;; WIDEN returns COUNTDOWN directly but has a different argument ABI.
    ;; It retains LLVM's best-effort TAIL hint rather than claiming MUSTTAIL.
    (is (search "= tail call i64 @__verona_00006300006F00007500006E00007400006400006F00007700006E" ir))
    ;; An address of THROUGH-ADDRESS's local parameter must keep the current
    ;; frame alive through READ, so this tail-position call remains ordinary.
    (is (not (search "tail call i64 @__verona_000072000065000061000064" ir))))
  ;; This depth is deliberately far beyond the ordinary native stack budget.
  ;; It verifies the MUSTTAIL lowering survives object emission and linking.
  (is (= 0
         (compile-and-run-native
          "(function recurse ((number i64)) i64
              (match (%=-primitive-i64 number 0)
                (true 0)
                (false (recurse (%--primitive-i64 number 1)))))
            (function main () exit-code
              (%trunc-primitive-i64-i32 (recurse 1000000)))"))))

(test lowers-and-executes-generic-dispatch
  (let ((source
          "(generic combine (left right))
           (implementation combine ((a i64) (b i64)) i64 (+ a b))
           (function twenty () i64 20)
           (function twenty-two () i64 22)
           (function main () exit-code
             (%trunc-primitive-i64-i32 (combine (twenty) (twenty-two))))"))
    (is (= 42 (compile-and-run-native source)))))

(test monomorphizes-parametric-functions-for-llvm
  (let ((source
          "(function identity
             (for (a))
             ((value a))
             a
             value)
           (function source () i64 42)
           (function main () exit-code
             (%trunc-primitive-i64-i32 (identity (source))))"))
    ;; The template has no LLVM symbol; its i64 specialization is a normal
    ;; concrete function called by MAIN.
    (is (= 42 (compile-and-run-native source)))))

(test resolves-protocol-calls-before-llvm-lowering
  (let ((source
          "(protocol display (a)
             (display ((value a)) i64))
           (implementation (display i64)
             (function display
               ((value i64))
               i64
               value))
           (function print
             (for (a)
               ((display a)))
             ((value a))
             i64
             (display value))
           (function source () i64 42)
           (function main () exit-code
             (%trunc-primitive-i64-i32 (print (source))))"))
    ;; PRINT<i64> contains an ordinary call to this exact Display<i64>
    ;; operation; neither protocol values nor dispatch tables reach LLVM.
    (is (= 42 (compile-and-run-native source)))))

(test lowers-unit-to-the-target-pointer-width
  (let* ((unit (compile-string (make-compiler) "(function noop () unit unit)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (= 64 (verona.backend.llvm:llvm-backend-pointer-width backend)))
    (is (search "define i64 @__verona_00006E00006F00006F000070()" ir))
    (is (search "ret i64 0" ir))))

(test lowers-character-and-ascii-string-literals
  (let* ((unit (compile-string
                (make-compiler)
                "(constant greeting (pointer u8) \"hello\")
                 (function letter () char #\\a)
                 (function greeting-value () (pointer u8) greeting)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    ;; CHAR is always an ASCII code unit, so a lowers to 97.
    (is (search "ret i8 97" ir))
    ;; Text literals are pointers to NUL-terminated ASCII storage, like char*.
    (is (search ".verona.string.1" ir))
    (is (search "[6 x i8]" ir))
    (is (not (search "{ ptr, i64 }" ir)))))

(test strings-are-c-compatible-null-terminated-byte-pointers
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function strlen \"strlen\" ((pointer u8)) usize)
                 (function data () (pointer u8) \"hello\")
                 (function length () usize
                   (let ((phrase (pointer u8) \"a quick fox\"))
                     (strlen phrase)))"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "declare i64 @strlen(ptr)" ir))
    (is (not (search "string.data" ir)))
    (is (not (search "string.length" ir))))
  (is (= 11
         (compile-and-run-native
          "(external-function strlen \"strlen\" ((pointer u8)) usize)
           (function main () exit-code
             (let ((phrase (pointer u8) \"a quick fox\"))
               (%trunc-primitive-u64-i32 (strlen phrase))))"))))

(test lowers-external-c-declarations-with-explicit-linker-names
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function release \"free\" ((pointer void)) void)
                 (external-function strlen \"strlen\" ((pointer i8)) usize)
                 (function main () i64 0)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "declare void @free(" ir))
    (is (search "@strlen(" ir))
    (is (not (search "__verona_000066000072000065000065" ir)))))

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

(test emits-a-native-object-file
  (let* ((object (native-test-path "o"))
         (unit (compile-string (make-compiler) "(function answer () i64 42)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit))))
    (unwind-protect
         (progn
           (verona.backend.llvm:emit-object backend object)
           (is (probe-file object))
           (is (< 0 (with-open-file (stream object :direction :input :element-type '(unsigned-byte 8))
                      (file-length stream)))))
      (when (probe-file object)
        (delete-file object)))))

(test executes-native-verona-programs
  (is (= 0 (compile-and-run-native "(function main () exit-code 0)")))
  (is (= 42 (compile-and-run-native "(function main () exit-code 42)")))
  (is (= 42 (compile-and-run-native
             "(function main () exit-code (+ 20 22))")))
  (is (= 0 (compile-and-run-native
             (format nil "(function noop () unit unit)~%
                          (function main () exit-code (do (noop) 0))")))))

(test executes-explicit-conversions-natively
  (is (= 42 (compile-and-run-native
             (format nil "(function widen ((value i32)) i64 (%sext-primitive-i32-i64 value))~%
                          (function main () exit-code
                            (%trunc-primitive-i64-i32 (widen 42)))")))))

(test lowers-transparent-type-aliases-with-their-target-representations
  (let ((source
          "(type Count CountBase)
           (type CountBase i64)
           (type Pair (product (left Count) (right Count)))
           (type PairAlias Pair)
           (function total ((value PairAlias)) Count
             (+ (field value left) (field value right)))
           (function main () exit-code
             (%trunc-primitive-i64-i32 (total (Pair 20 22))))"))
    (is (= 42 (compile-and-run-native source)))))

(test lowers-addressable-let-bindings-and-executes-them
  (let* ((source (format nil
                         "(function sequential () i64~%
                            (let ((x i64 20)~%
                                  (y i64 (%+-primitive-i64 x 22)))~%
                              y))~%
                          (function shadow () i64~%
                            (let ((x i64 10))~%
                              (let ((x i64 42)) x)))~%
                          (function max-plus-ten ((a i64) (b i64)) i64~%
                            (match (%>-primitive-i64 a b)~%
                              (true (let ((x i64 (%+-primitive-i64 a 10))) x))~%
                              (false (let ((x i64 (%+-primitive-i64 b 10))) x))))~%
                          (function main () exit-code
                            (%trunc-primitive-i64-i32
                              (max-plus-ten (sequential) (shadow))))"))
         (unit (compile-string (make-compiler) source))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "add i64" ir))
    ;; LET bindings have stable local storage because their addresses may be
    ;; taken, including in parameter-free functions.
    (is (search "let.addr" ir))
    (is (= 52 (compile-and-run-native source)))))

(test passes-addresses-of-let-bindings-to-functions
  (let ((source
          "(function write ((address (pointer i64))) unit
              (do (store (deref address) 42) unit))
            (function local () i64
              (let ((x i64 0))
                (do (write (& x)) x)))
            (function main () exit-code
              (%trunc-primitive-i64-i32 (local)))"))
    (is (= 42 (compile-and-run-native source)))))

(test lowers-products-as-ssa-aggregates-and-executes-them
  (let* ((source
	  "(type point (product (x i64) (y i64)))
             (type line (product (start point) (end point)))
             (function make-point ((x i64) (y i64)) point (point x y))
             (function end-y ((value line)) i64 (field (field value end) y))
             (function main () exit-code
               (let ((value line (line (make-point 10 20) (make-point 30 42))))
                 (%trunc-primitive-i64-i32 (end-y value))))")
	 (unit (compile-string (make-compiler) source))
	 (backend (verona.backend.llvm:generate-llvm
		   (compilation-unit-semantic-program unit)))
	 (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "insertvalue" ir))
    (is (search "extractvalue" ir))
    (is (= 42 (compile-and-run-native source)))))

(test lowers-fixed-arrays-indexing-and-runtime-bounds-checks
  (let* ((source
           "(function pick ((values (array i64 4)) (i usize)) i64
               (index values i))
             (function main () exit-code
               (%trunc-primitive-i64-i32 (pick (array-of 10 20 30 40) 2)))")
         (unit (compile-string (make-compiler) source))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "[4 x i64]" ir))
    (is (search "getelementptr [4 x i64]" ir))
    (is (search "llvm.trap" ir))
    (is (= 30 (compile-and-run-native source)))))

(test lowers-and-executes-boolean-matches
  (let* ((source (format nil
			 "(function max ((a i64) (b i64)) i64~%
                            (match (%>-primitive-i64 a b)~%
                              (true a)~%
                              (false b)))~%
                          (function main () exit-code
                            (%trunc-primitive-i64-i32 (max 20 42)))"))
	 (unit (compile-string (make-compiler) source))
	 (backend (verona.backend.llvm:generate-llvm
		   (compilation-unit-semantic-program unit)))
	 (ir (verona.backend.llvm:print-llvm-module backend)))
    (is (search "br i1" ir))
    (is (search "phi i64" ir))
    (is (= 42 (compile-and-run-native source)))))

(test executes-terminating-and-integer-match-cases
  (is (= 0 (compile-and-run-native
	    "(function normalize ((x i64)) i64 (match (%<-primitive-i64 x 0) (true (return 0)) (false x))) (function main () exit-code (%trunc-primitive-i64-i32 (normalize -10)))")))
  (is (= 42 (compile-and-run-native
	    "(function normalize ((x i64)) i64 (match (%<-primitive-i64 x 0) (true (return 0)) (false x))) (function main () exit-code (%trunc-primitive-i64-i32 (normalize 42)))")))
  (is (= 20 (compile-and-run-native
	    "(function classify ((x i64)) i64 (match x (0 10) (1 20) (_ 30))) (function main () exit-code (%trunc-primitive-i64-i32 (classify 1)))"))))

(test validates-the-executable-entry-contract
  (let ((unit (compile-string (make-compiler) "(function main () unit unit)")))
    (signals verona.backend.llvm:entry-point-error
       (verona.backend.llvm:build-executable
       (compilation-unit-semantic-program unit) (native-test-path "program"))))
  (is (= 42 (compile-and-run-native "(function main () exit-code 42)"))))

(test lowers-and-executes-sum-construction-and-constructor-patterns
  (is (= 42 (compile-and-run-native
             "(type option (sum (none) (some i64)))
              (function unwrap ((value option)) i64
                (match value ((none) 0) ((some x) x)))
              (function main () exit-code
                (%trunc-primitive-i64-i32 (unwrap (some 42))))")))
  (is (= 42 (compile-and-run-native
             "(type status (sum (success) (failure)))
              (function value ((state status)) i64
                (match state ((success) 42) ((failure) 0)))
              (function main () exit-code
                (%trunc-primitive-i64-i32 (value (success))))")))
  (is (= 42 (compile-and-run-native
             "(type result (sum (ok i64 i64) (error i64)))
              (function value ((result result)) i64
                (match result
                  ((ok x y) (%+-primitive-i64 x y))
                  ((error _) 0)))
              (function main () exit-code
                (%trunc-primitive-i64-i32 (value (ok 20 22))))")))
  (is (= 42 (compile-and-run-native
             "(type pair (product (left i64) (right i64)))
              (type result (sum (ok pair) (error i64)))
              (function unwrap ((result result)) i64
                (match result
                  ((ok pair) (%+-primitive-i64 (field pair left) (field pair right)))
                  ((error _) 0)))
              (function main () exit-code
                (%trunc-primitive-i64-i32 (unwrap (ok (pair 20 22)))) )")))
  (is (= 10 (compile-and-run-native
             "(type option (sum (none) (some i64)))
              (function classify ((value option)) i64
                (match value ((some 0) 10) ((some x) x) ((none) 0)))
              (function main () exit-code
                (%trunc-primitive-i64-i32 (classify (some 0))))")))
  (is (= 42 (compile-and-run-native
             "(type option (sum (none) (some i64)))
              (type response (product (status i64) (value option)))
              (function unwrap ((value option)) i64
                (match value ((none) 0) ((some x) x)))
              (function main () exit-code
                (%trunc-primitive-i64-i32
                  (unwrap (field (response 0 (some 42)) value))))"))))
