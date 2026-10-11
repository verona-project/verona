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

(test reports-the-primary-asdf-release-version
  (is (string= "0.1.0" (verona.compiler:verona-version)))
  (is (string= "0.1.0" (verona.compiler:main (list "--version")))))

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

(test-cases requires-both-verona-package-directory-environment-variables
  (missing-library-directory
   (signals verona.compiler:missing-verona-environment-variable
     (verona.compiler:resolve-verona-environment
      :getenv (lambda (variable)
                (and (string= variable "VERONA_SOURCE_DIR") "/private/tmp/verona-source")))))
  (relative-source-directory
   (signals verona.compiler:invalid-verona-environment-directory
     (verona.compiler:resolve-verona-environment
      :getenv (lambda (variable)
                (if (string= variable "VERONA_SOURCE_DIR") "relative/source"
                    "/private/tmp/verona-library"))))))

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
