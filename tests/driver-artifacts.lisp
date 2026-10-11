(in-package #:verona/tests)

(in-suite :verona)

(defclass deterministic-failing-toolchain (verona.compiler:toolchain)
  ((failure-kind :initarg :failure-kind :reader deterministic-failing-toolchain-kind)))

(defmethod verona.compiler:toolchain-emit-object
    ((toolchain deterministic-failing-toolchain) backend output)
  (declare (ignore toolchain backend))
  (with-open-file (stream output :direction :output :if-exists :supersede
                                 :element-type '(unsigned-byte 8))
    (write-byte 0 stream))
  output)

(defun signal-deterministic-tool-failure (class tool arguments)
  (error class :message "intentional test tool failure" :tool tool :executable tool
               :arguments arguments :exit-status 73
               :stdout "fake standard output" :stderr "fake standard error"))

(defmethod verona.compiler:toolchain-link-executable
    ((toolchain deterministic-failing-toolchain) object output target options)
  (declare (ignore object output target options))
  (signal-deterministic-tool-failure 'verona.compiler:linker-failure "fake-linker"
                                     (list "fake-object")))

(defmethod verona.compiler:toolchain-archive-static-library
    ((toolchain deterministic-failing-toolchain) object output target)
  (declare (ignore object output target))
  (signal-deterministic-tool-failure 'verona.compiler:archiver-failure "fake-archiver"
                                     (list "rcs" "fake-library" "fake-object")))

(defmethod verona.compiler:toolchain-link-shared-library
    ((toolchain deterministic-failing-toolchain) object output target options)
  (declare (ignore object output target options))
  (signal-deterministic-tool-failure 'verona.compiler:shared-library-link-failure
                                     "fake-linker" (list "-shared" "fake-object")))

(defun assert-structured-tool-failure (class artifact-kind expected-tool)
  (let* ((output (merge-pathnames (format nil "verona-fake-tool-~A" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (toolchain (make-instance 'deterministic-failing-toolchain
                                   :failure-kind artifact-kind))
         (driver (verona.compiler:make-compiler-driver :toolchain toolchain))
         (source (merge-pathnames "tests/compiler-driver-main.vrn"
                                  (asdf:system-source-directory :verona))))
    (unwind-protect
         (handler-case
             (progn
               (verona.compiler:compile-root driver source :artifact-kind artifact-kind :output output)
               (error "expected ~S" class))
           (verona.compiler:toolchain-failure (condition)
             (is (typep condition class))
             (is (string= expected-tool (verona.compiler:toolchain-failure-tool condition)))
             (is (= 73 (verona.compiler:toolchain-failure-exit-status condition)))
             (is (string= "fake standard output"
                          (verona.compiler:toolchain-failure-stdout condition)))
             (is (string= "fake standard error"
                          (verona.compiler:toolchain-failure-stderr condition)))))
      (when (probe-file output) (delete-file output)))))

(test-cases compiler-driver-reports-fake-toolchain-failures
  (linker
   (assert-structured-tool-failure 'verona.compiler:linker-failure :executable "fake-linker"))
  (archiver
   (assert-structured-tool-failure 'verona.compiler:archiver-failure :static-library "fake-archiver")))

(test compiler-driver-produces-native-artifacts
  (let* ((source (merge-pathnames (format nil "verona-driver-~A.vrn" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (object (merge-pathnames (format nil "verona-driver-~A.o" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (driver (verona.compiler:make-compiler-driver)))
    (unwind-protect
         (progn
           (with-open-file (stream source :direction :output :if-exists :supersede)
             (write-string "(function main () exit-code 0)" stream))
           (let ((artifact (verona.compiler:compile-root driver source
                                                          :artifact-kind :object :output object)))
             (is (typep artifact 'verona.compiler:object-artifact))
             (is (probe-file (verona.compiler:artifact-path artifact)))
             (is (= (verona.compiler:compilation-target-pointer-width
                     (verona.compiler:artifact-target artifact))
                    (verona:type-context-pointer-width
                     (verona:semantic-program-type-context
                      (verona:compilation-unit-semantic-program
                       (verona:compile-file (verona:make-compiler) source)))))))
      (when (probe-file source) (delete-file source))
      (when (probe-file object) (delete-file object))))))

(test compiler-driver-links-integer-main
  (let* ((source (merge-pathnames (format nil "verona-driver-~A.vrn" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (executable (merge-pathnames (format nil "verona-driver-~A" (gensym "TEST-"))
                                      (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (stream source :direction :output :if-exists :supersede)
             (write-string "(function main () exit-code 0)" stream))
           (verona.compiler:compile-root (verona.compiler:make-compiler-driver) source
                                         :artifact-kind :executable :output executable)
           (is (zerop (nth-value 2 (uiop:run-program (list (namestring executable))
                                                     :ignore-error-status t)))))
      (when (probe-file source) (delete-file source))
      (when (probe-file executable) (delete-file executable)))))

(test compiler-driver-produces-libraries-without-main
  (let* ((source (merge-pathnames (format nil "verona-driver-~A.vrn" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (static (merge-pathnames (format nil "libverona-driver-~A.a" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (shared (merge-pathnames (format nil "libverona-driver-~A.~A" (gensym "TEST-")
                                          (if (search "darwin" (verona.compiler:compilation-target-triple
                                                                (verona.compiler:resolve-compilation-target))
                                                      :test #'char-equal)
                                              "dylib" "so"))
                                  (uiop:temporary-directory)))
         (driver (verona.compiler:make-compiler-driver)))
    (unwind-protect
         (progn
           (with-open-file (stream source :direction :output :if-exists :supersede)
             (write-string "(function add ((a i32) (b i32)) i32 (+ a b))" stream))
           (is (probe-file (verona.compiler:artifact-path
                            (verona.compiler:compile-root driver source
                                                          :artifact-kind :static-library :output static))))
           (is (probe-file (verona.compiler:artifact-path
                            (verona.compiler:compile-root driver source
                                                          :artifact-kind :shared-library :output shared)))))
      (when (probe-file source) (delete-file source))
      (when (probe-file static) (delete-file static))
      (when (probe-file shared) (delete-file shared)))))

(test compiler-driver-links-an-explicit-c-export-from-a-static-library
  (let* ((directory (uiop:temporary-directory))
         (source (merge-pathnames (format nil "verona-export-~A.vrn" (gensym "TEST-")) directory))
         (library (merge-pathnames (format nil "libverona-export-~A.a" (gensym "TEST-")) directory))
         (shared (merge-pathnames (format nil "libverona-export-~A.~A" (gensym "TEST-")
                                          (if (search "darwin" (verona.compiler:compilation-target-triple
                                                                (verona.compiler:resolve-compilation-target))
                                                      :test #'char-equal)
                                              "dylib" "so")) directory))
         (c-source (merge-pathnames (format nil "verona-export-~A.c" (gensym "TEST-")) directory))
         (executable (merge-pathnames (format nil "verona-export-~A" (gensym "TEST-")) directory))
         (shared-executable (merge-pathnames (format nil "verona-export-shared-~A" (gensym "TEST-")) directory)))
    (unwind-protect
         (progn
           (with-open-file (stream source :direction :output :if-exists :supersede)
             (write-string "(function add ((a i32) (b i32)) i32 (+ a b))
                            (function invert ((value bool)) bool (%not-primitive-bool value))
                            (native-export add)
                            (native-export invert)" stream))
           (verona.compiler:compile-root (verona.compiler:make-compiler-driver) source
                                         :artifact-kind :static-library :output library)
           (verona.compiler:compile-root (verona.compiler:make-compiler-driver) source
                                         :artifact-kind :shared-library :output shared)
           (with-open-file (stream c-source :direction :output :if-exists :supersede)
             (write-string "#include <stdbool.h>
                            int add(int, int);
                            bool invert(bool);
                            int main(void) {
                              return add(20, 22) == 42 && invert(false) && !invert(true) ? 0 : 1;
                            }" stream))
           (multiple-value-bind (stdout stderr status)
               (uiop:run-program (list (or (uiop:getenv "VERONA_LINKER") "clang")
                                       (namestring c-source) (namestring library)
                                       "-o" (namestring executable))
                                 :output :string :error-output :string :ignore-error-status t)
             (declare (ignore stdout))
             (is (zerop status) stderr))
           (is (zerop (nth-value 2 (uiop:run-program (list (namestring executable))
                                                     :ignore-error-status t)))))
           (multiple-value-bind (stdout stderr status)
               (uiop:run-program (list (or (uiop:getenv "VERONA_LINKER") "clang")
                                       (namestring c-source) (namestring shared)
                                       (format nil "-Wl,-rpath,~A" (namestring directory))
                                       "-o" (namestring shared-executable))
                                 :output :string :error-output :string :ignore-error-status t)
             (declare (ignore stdout))
             (is (zerop status) stderr))
           (is (zerop (nth-value 2 (uiop:run-program (list (namestring shared-executable))
                                                     :ignore-error-status t)))))
      (dolist (path (list source library shared c-source executable shared-executable))
        (when (probe-file path) (delete-file path)))))
