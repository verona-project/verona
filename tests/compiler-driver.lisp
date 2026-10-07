(in-package #:verona/tests)

(in-suite :verona)

(test compiler-target-selects-platform-reader-features
  (let* ((target (verona.compiler:resolve-compilation-target))
         (platform (verona.compiler:compilation-target-platform target))
         (unit (verona:compile-string
                (verona:make-compiler)
                "#+darwin (function platform-value () unit unit)
                 #-darwin (function platform-value () i32 0)"
                :target target))
         (declaration (first (verona:unit-declarations unit)))
         (return-type (verona:syntax-datum
                       (verona:function-declaration-return-type declaration))))
    (is (= 1 (length (verona:unit-declarations unit))))
    (if (eq platform :darwin)
        (is (verona:unit-literal-p return-type))
        (is (string= "i32" (verona:verona-name-value return-type))))))

(test resolves-independent-verona-package-directories-from-environment
  (let ((environment
          (verona.compiler:resolve-verona-environment
           :getenv (lambda (variable)
                     (cond ((string= variable "VERONA_SOURCE_DIR") "/private/tmp/verona-source")
                           ((string= variable "VERONA_LIBRARY_DIR") "/private/tmp/verona-library"))))))
    (is (string= "/private/tmp/verona-source/"
                 (namestring (verona.compiler:verona-environment-source-directory environment))))
    (is (string= "/private/tmp/verona-library/"
                 (namestring (verona.compiler:verona-environment-library-directory environment))))))

(test requires-both-verona-package-directory-environment-variables
  (signals verona.compiler:missing-verona-environment-variable
    (verona.compiler:resolve-verona-environment
     :getenv (lambda (variable)
               (and (string= variable "VERONA_SOURCE_DIR") "/private/tmp/verona-source"))))
  (signals verona.compiler:invalid-verona-environment-directory
    (verona.compiler:resolve-verona-environment
     :getenv (lambda (variable)
               (if (string= variable "VERONA_SOURCE_DIR") "relative/source"
                   "/private/tmp/verona-library")))))

(test compiler-target-provides-platform-and-explicit-reader-features
  (let* ((target (verona.compiler:resolve-compilation-target
                  :reader-features '("project-switch")))
         (features (verona:target-feature-names target))
         (unit (verona:compile-string
                (verona:make-compiler)
                "#+project-switch (function enabled () i32 42)
                 #-project-switch (function enabled () i32 0)"
                :target target)))
    (is (member "project-switch" features :test #'string=))
    (is (member (string-downcase
                 (symbol-name (verona.compiler:compilation-target-platform target)))
                features :test #'string=))
    (is (= 1 (length (verona:unit-declarations unit))))))

(test compiler-target-provides-architecture-layout-and-abi-features
  (let* ((target (verona.compiler:resolve-compilation-target))
         (features (verona:target-feature-names target)))
    (is (member (format nil "pointer_~D"
                        (verona.compiler:compilation-target-pointer-width target))
                features :test #'string=))
    (is (member (string-downcase
                 (symbol-name (verona.compiler:compilation-target-object-format target)))
                features :test #'string=))
    (is (or (member "little_endian" features :test #'string=)
            (member "big_endian" features :test #'string=)))
    (is (or (member "x86_64" features :test #'string=)
            (member "aarch64" features :test #'string=)
            (member "arm" features :test #'string=)
            (member "riscv64" features :test #'string=)))))

(test canonicalizes-target-architecture-feature-names
  (is (string= "x86_64"
               (verona.compiler::target-architecture-feature "amd64-unknown-linux-gnu")))
  (is (string= "aarch64"
               (verona.compiler::target-architecture-feature "arm64-apple-darwin")))
  (is (string= "arm"
               (verona.compiler::target-architecture-feature "thumbv7-unknown-linux-gnueabihf")))
  (is (string= "riscv64"
               (verona.compiler::target-architecture-feature "riscv64-unknown-linux-musl"))))

(test command-line-feature-enables-reader-conditional
  (let* ((source (merge-pathnames (format nil "verona-feature-~A.vrn" (gensym "TEST-"))
                                  (uiop:temporary-directory)))
         (object (merge-pathnames (format nil "verona-feature-~A.o" (gensym "TEST-"))
                                  (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (stream source :direction :output :if-exists :supersede)
             (write-string
              "#+cli-switch (function selected () i32 42)
               #-cli-switch (not-a-declaration)"
              stream))
           (let ((artifact (verona.compiler:main
                            (list "compile" (namestring source) "--emit" "object"
                                  "--output" (namestring object)
                                  "--feature" "cli-switch"))))
             (is (typep artifact 'verona.compiler:object-artifact))
             (is (probe-file object))))
      (when (probe-file source) (delete-file source))
      (when (probe-file object) (delete-file object)))))

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
