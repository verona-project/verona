(in-package #:verona/tests)

(in-suite :verona)

(test compiles-a-qualified-module-graph
  (let* ((root (merge-pathnames "tests/modules/" (asdf:system-source-directory :verona)))
         (compiler (make-compiler :search-paths (list root)))
         (entry (compile-module compiler "app"))
         (program (compilation-unit-semantic-program entry)))
    (is (typep entry 'module))
    (is (string= "app" (module-name-string (module-name entry))))
    (is (= 3 (length (program-modules program))))))

(test reader-preserves-qualified-name-structure
  (let* ((form (first (read-source (make-source "qualified.vrn" "math:square"))))
         (name (syntax-datum form)))
    (is (qualified-name-p name))
    (is (string= "math" (module-name-string (qualified-name-qualifier name))))
    (is (string= "square" (verona-name-value (qualified-name-name name))))))

(defun call-with-module-fixture (files thunk)
  "Create FILES as module-name/source pairs for one isolated module test."
  (let ((directory (merge-pathnames (format nil "verona-modules-~A/" (gensym "TEST-"))
                                    (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames ".directory" directory))
           (dolist (file files)
             (with-open-file (stream (merge-pathnames (car file) directory)
                                     :direction :output :if-exists :supersede)
               (write-string (cdr file) stream)))
           (funcall thunk (make-compiler :search-paths (list directory))))
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t)))))

(test-cases rejects-invalid-module-graphs
  (missing-module
   (call-with-module-fixture '()
     (lambda (compiler)
       (signals verona:module-not-found
         (compile-module compiler "missing")))))
  (circular-imports
   (call-with-module-fixture
    '(("a.vrn" . "(import b) (function value () i32 1)")
      ("b.vrn" . "(import a) (function value () i32 2)"))
    (lambda (compiler)
      (signals verona:circular-module-dependency
        (compile-module compiler "a")))))
  (duplicate-import-alias
   (call-with-module-fixture
    '(("root.vrn" . "(import left :as shared) (import right :as shared)")
      ("left.vrn" . "(function value () i32 1)")
      ("right.vrn" . "(function value () i32 2)"))
    (lambda (compiler)
      (signals verona:duplicate-import-alias
        (compile-module compiler "root")))))
  (malformed-import
   (call-with-module-fixture
    '(("root.vrn" . "(import dependency as alias)"))
    (lambda (compiler)
      (signals verona:module-error
        (compile-module compiler "root")))))
  (unknown-export
   (call-with-module-fixture
    '(("root.vrn" . "(import dependency)")
      ("dependency.vrn" . "(export missing)"))
    (lambda (compiler)
      (signals verona:unknown-export
        (compile-module compiler "root"))))))
