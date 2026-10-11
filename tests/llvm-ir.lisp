(in-package #:verona/tests)

(in-suite :verona)

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

(test lowers-structural-tuple-signatures
  (let* ((unit (compile-string
                (make-compiler)
                "(function identity ((value (tuple i64 bool))) (tuple i64 bool) value)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit))))
    (is (eq backend (verona.backend.llvm:verify-llvm-module backend)))))

(test executes-tuple-access-and-match
  (is (= 42
         (compile-and-run-native
          "(function choose ((items (tuple i32 i32))) i32
              (match items
                ((tuple first _) first)))
            (function main () exit-code
              (choose (tuple 42 0)))"))))

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

(test-cases lowers-character-and-ascii-string-literals
  (character
   (let* ((unit (compile-string (make-compiler) "(function letter () char #\\a)"))
          (backend (verona.backend.llvm:generate-llvm
                    (compilation-unit-semantic-program unit)))
          (ir (verona.backend.llvm:print-llvm-module backend)))
     ;; CHAR is always an ASCII code unit, so a lowers to 97.
     (is (search "ret i8 97" ir))))
  (ascii-string
   (let* ((unit (compile-string
                 (make-compiler)
                 "(constant greeting (pointer u8) \"hello\")
                  (function greeting-value () (pointer u8) greeting)"))
         (backend (verona.backend.llvm:generate-llvm
                   (compilation-unit-semantic-program unit)))
         (ir (verona.backend.llvm:print-llvm-module backend)))
    ;; Text literals are pointers to NUL-terminated ASCII storage, like char*.
    (is (search ".verona.string.1" ir))
    (is (search "[6 x i8]" ir))
    (is (not (search "{ ptr, i64 }" ir))))))

(test-cases strings-are-c-compatible-null-terminated-byte-pointers
  (llvm-c-abi
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
    (is (not (search "string.length" ir)))))
  (native-call
   (is (= 11
          (compile-and-run-native
           "(external-function strlen \"strlen\" ((pointer u8)) usize)
            (function main () exit-code
              (let ((phrase (pointer u8) \"a quick fox\"))
                (%trunc-primitive-u64-i32 (strlen phrase))))")))))

(test compares-exact-pointer-identities
  (is (= 0
         (compile-and-run-native
          "(function main () exit-code
             (let ((value (pointer u8) \"pointer\"))
               (match (== value value)
                 (true (match (!= value value)
                         (true 1)
                         (false 0)))
                 (false 1))))"))))

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
