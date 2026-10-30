;;; Acceptance checks for the compiler implemented in Verona, independent of
;;; the Common Lisp frontend/LLVM backend. The native binary is built by Make.
(require :asdf)
(asdf:load-system :fiveam)
(defpackage #:verona/core-tests (:use #:cl #:fiveam))
(in-package #:verona/core-tests)

(def-suite :core)
(in-suite :core)
(defparameter *compiler* (first (uiop:command-line-arguments)))
(unless *compiler* (error "Expected the absolute verona-core executable path"))

(defun invoke (mode source &rest arguments)
  (uiop:with-temporary-file (:pathname path :stream stream :type "vrn")
    (write-string source stream)
    (finish-output stream)
    (uiop:run-program (append (list *compiler* mode (namestring path)) arguments)
                      :output :string :error-output :string :ignore-error-status t)))

(test factorial-evaluation
  (multiple-value-bind (output diagnostics status)
      (invoke "eval" "(%function fact ((n i64)) i64
        (if (%=-primitive-i64 n 0) 1 (%*-primitive-i64 n (fact (%--primitive-i64 n 1)))))
        (%function main () i64 (fact 5))")
    (is (= 0 status))
    (is (string= (format nil "120~%") output))
    (is (string= "" diagnostics))))

(test checks-unused-bodies
  (multiple-value-bind (output diagnostics status)
      (invoke "check" "(%function unused () i64 false)(%function main () i64 0)")
    (is (= 2 status))
    (is (string= "" output))
    (is (not (null (search "type mismatch" diagnostics))))))

(test typed-llvm-output
  (multiple-value-bind (output diagnostics status)
      (invoke "emit-llvm" "(%function plus ((x i64)) i64 (%+-primitive-i64 x 2))(%function main () i64 (plus 1))")
    (is (= 0 status))
    (is (string= "" diagnostics))
    (is (not (null (search "define i32 @main()" output))))
    (is (not (null (search "add i64" output))))))

(test runtime-stack
  (multiple-value-bind (output diagnostics status)
      (invoke "eval" "(%function bad () i64 (%/-primitive-i64 1 0))(%function main () i64 (bad))")
    (is (= 70 status))
    (is (string= "" output))
    (is (not (null (search "division by zero" diagnostics))))
    (is (not (null (search "in bad" diagnostics))))
    (is (not (null (search "in main" diagnostics))))))

(test rejects-unexpanded-surface-declarations
  (multiple-value-bind (output diagnostics status)
      (invoke "check" "(function main () i64 0)")
    (is (= 2 status))
    (is (string= "" output))
    (is (not (null (search "only %function declarations" diagnostics))))))

(test signed-minimum-through-runtime-bindings
  (multiple-value-bind (output diagnostics status)
      (invoke "eval" "(%function identity ((x i64)) i64 (let ((y i64 x)) y))
                     (%function main () i64 (identity -9223372036854775808))")
    (is (= 0 status))
    (is (string= (format nil "-9223372036854775808~%") output))
    (is (string= "" diagnostics))))

(unless (run! :core) (uiop:quit 1))
