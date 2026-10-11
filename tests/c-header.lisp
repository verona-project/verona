(in-package #:verona/tests)

(in-suite :verona)

(defun c-header-test-path (type)
  (merge-pathnames (format nil "verona-header-~A.~A" (gensym "TEST-") type)
                   (uiop:temporary-directory)))

(test generates-a-c-header-for-the-full-native-export-abi
  (let* ((header (c-header-test-path "h"))
         (client (c-header-test-path "c"))
         (source
           "(type handle)
            (type point (product (x i32) (enabled bool)))
            (type outcome (sum (empty) (value i32)))
            (function process
              ((resource (pointer handle))
               (location point)
               (state outcome)
               (values (array i32 2))
               (enabled bool)
               (callback (pointer (function (i32) i32))))
              i32
              0)
            (native-export process \"verona_custom_process\")")
         (program (compilation-unit-semantic-program
                   (compile-string (make-compiler) source))))
    (unwind-protect
         (progn
           (verona.backend.llvm:generate-c-header program header)
           (let ((contents (uiop:read-file-string header)))
             (is (search "#include <stdint.h>" contents))
             (is (search "#include <stdbool.h>" contents))
             (is (<= 3 (loop with start = 0
                              for position = (search "struct __verona_" contents :start2 start)
                              while position
                              do (setf start (+ position 1))
                              count position)))
             (is (search "int32_t x;" contents))
             (is (search "_Bool enabled;" contents))
             (is (search "int32_t tag;" contents))
             (is (search "union {" contents))
             (is (search "verona_array_" contents))
             (is (search "int32_t (*arg5)(int32_t)" contents))
             (is (search "verona_custom_process(" contents)))
           (with-open-file (stream client :direction :output :if-exists :supersede)
             (format stream "#include \"~A\"~%int main(void) { return 0; }~%"
                     (namestring header)))
           (multiple-value-bind (stdout stderr status)
               (uiop:run-program (list (or (uiop:getenv "VERONA_LINKER") "clang")
                                       "-fsyntax-only" (namestring client))
                                 :output :string :error-output :string :ignore-error-status t)
             (declare (ignore stdout))
             (is (zerop status) stderr)))
      (dolist (path (list header client))
        (when (probe-file path) (delete-file path))))))
