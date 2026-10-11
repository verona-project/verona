(in-package #:verona/tests)

(in-suite :verona)

(defun fake-cli-artifact ()
  (make-instance 'verona.compiler:object-artifact :kind :object
                                                  :path #P"/private/tmp/verona-cli-test.o"
                                                  :target :test-target))

(defun run-cli-with-fake-compiler (arguments)
  (let (target-options compile-options)
    (let ((*standard-output* (make-string-output-stream)))
      (verona.compiler:run-cli
       arguments
       :resolve-target-function
       (lambda (&key triple cpu features reader-features)
         (setf target-options (list :triple triple :cpu cpu :features features
                                    :reader-features reader-features))
         :test-target)
       :make-driver-function (lambda (&key target) (list :driver target))
       :compile-function
       (lambda (driver source &key artifact-kind output link-options)
         (setf compile-options (list :driver driver :source source :artifact-kind artifact-kind
                                     :output output :link-options link-options))
         (fake-cli-artifact))))
    (values target-options compile-options)))

(test table-driven-cli-compile-options
  (multiple-value-bind (target invocation)
      (run-cli-with-fake-compiler
       '("compile" "entry.vrn" "--emit" "static-library" "--output" "dist/libentry.a"
         "--target" "x86_64-unknown-linux-gnu" "--cpu" "haswell" "--features" "+avx2"
         "--feature" "feature-a" "--feature" "feature-b"
         "--library" "sqlite3" "-L" "vendor/lib" "--framework" "CoreFoundation"))
    (is (equal '(:triple "x86_64-unknown-linux-gnu" :cpu "haswell" :features "+avx2"
                 :reader-features ("feature-a" "feature-b"))
               target))
    (is (string= "entry.vrn" (getf invocation :source)))
    (is (eq :static-library (getf invocation :artifact-kind)))
    (is (string= "dist/libentry.a" (namestring (getf invocation :output))))
    (let ((options (getf invocation :link-options)))
      (is (equal '("sqlite3") (verona.compiler:link-options-libraries options)))
      (is (equal '("vendor/lib")
                 (mapcar #'namestring (verona.compiler:link-options-library-search-paths options))))
      (is (equal '("CoreFoundation") (verona.compiler:link-options-frameworks options))))))

(test table-driven-cli-build-features
  (let (invocation)
    (with-output-to-string (stream)
      (let ((*standard-output* stream))
        (verona.compiler:run-cli
         '("build" "app" "dist" "--feature" "configured" "--feature" "coverage")
         :locate-build-function (lambda () #P"/private/tmp/verona.build")
         :parse-build-function (lambda (path) (declare (ignore path)) :build-file)
         :build-function (lambda (file value)
                           (declare (ignore file))
                           (setf invocation value)
                           (fake-cli-artifact)))))
    (is (equal '("configured" "coverage")
               (verona.compiler:build-invocation-reader-features invocation)))
    (is (string= "app" (verona.compiler:build-name-value
                          (verona.compiler:build-invocation-target-name invocation))))))

(test-cases rejects-invalid-cli-arguments
  (unknown-artifact
   (signals verona.compiler:compiler-driver-error
     (verona.compiler:run-cli '("compile" "entry.vrn" "--emit" "archive"))))
  (missing-output-path
   (signals verona.compiler:compiler-driver-error
     (verona.compiler:run-cli '("compile" "entry.vrn" "--output"))))
  (empty-feature
   (signals verona.compiler:compiler-driver-error
     (verona.compiler:run-cli '("compile" "entry.vrn" "--feature" ""))))
  (unknown-option
   (signals verona.compiler:compiler-driver-error
     (verona.compiler:run-cli '("compile" "entry.vrn" "--unknown"))))
  (build-without-output-directory
   (signals verona.compiler:compiler-driver-error
     (verona.compiler:run-cli '("build" "app")))))
