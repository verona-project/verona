(in-package #:verona/tests)

(in-suite :verona)

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

(test-cases executes-native-verona-programs
  (zero-exit-code
   (is (= 0 (compile-and-run-native "(function main () exit-code 0)"))))
  (literal-exit-code
   (is (= 42 (compile-and-run-native "(function main () exit-code 42)"))))
  (computed-exit-code
   (is (= 42 (compile-and-run-native "(function main () exit-code (+ 20 22))"))))
  (unit-returning-helper
   (is (= 0 (compile-and-run-native
             (format nil "(function noop () unit unit)~%
                          (function main () exit-code (do (noop) 0))"))))))

(test passes-command-line-arguments-to-verona-main
  (is (= 42
         (compile-and-run-native-with-arguments
          "(external-function strcmp \"strcmp\" ((pointer u8) (pointer u8)) i32)
           (function main ((argc i32) (argv (pointer (pointer u8)))) exit-code
             (match (%=-primitive-i32 argc 2)
               (false 1)
               (true
                (let ((argument (pointer u8)
                                (deref (pointer-offset argv 1))))
                  (match (strcmp argument \"answer\")
                    (0 42)
                    (_ 2))))))"
          '("answer")))))

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

(test-cases executes-terminating-and-integer-match-cases
  (terminating-negative-case
   (is (= 0 (compile-and-run-native
	    "(function normalize ((x i64)) i64 (match (%<-primitive-i64 x 0) (true (return 0)) (false x))) (function main () exit-code (%trunc-primitive-i64-i32 (normalize -10)))"))))
  (non-terminating-case
   (is (= 42 (compile-and-run-native
	    "(function normalize ((x i64)) i64 (match (%<-primitive-i64 x 0) (true (return 0)) (false x))) (function main () exit-code (%trunc-primitive-i64-i32 (normalize 42)))"))))
  (integer-pattern
   (is (= 20 (compile-and-run-native
	    "(function classify ((x i64)) i64 (match x (0 10) (1 20) (_ 30))) (function main () exit-code (%trunc-primitive-i64-i32 (classify 1)))")))))

(test-cases validates-the-executable-entry-contract
  (rejects-unit-main
  (let ((unit (compile-string (make-compiler) "(function main () unit unit)")))
    (signals verona.backend.llvm:entry-point-error
       (verona.backend.llvm:build-executable
       (compilation-unit-semantic-program unit) (native-test-path "program")))))
  (accepts-exit-code-main
   (is (= 42 (compile-and-run-native "(function main () exit-code 42)")))))

(test lowers-and-executes-sum-construction-and-constructor-patterns
  (let* ((unit (compile-string
                (make-compiler)
                "(type status (sum (idle) (count i64) (error i64)))
                 (function identity ((value status)) status value)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    ;; Tag plus one shared i64-aligned payload slot, not one slot per case.
    (is (search "type { i32, { { i64 } } }" ir))
    (is (not (search "type { i32, {}, { i64 }, { i64 } }" ir))))
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
