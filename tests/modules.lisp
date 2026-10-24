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

(test-cases rejects-invalid-qualified-module-references
  (unknown-module-qualifier
   (call-with-module-fixture
    '(("app.vrn" . "(function main () i32 (missing:value))"))
    (lambda (compiler)
      (signals verona:unknown-module-qualifier
        (compile-module compiler "app")))))
  (module-not-imported
   (call-with-module-fixture
    '(("app.vrn" . "(import bridge) (function main () i32 (library:value))")
      ("bridge.vrn" . "(import library) (function bridge () i32 (library:value)) (export bridge)")
      ("library.vrn" . "(function value () i32 1) (export value)"))
    (lambda (compiler)
      (signals verona:module-not-imported
        (compile-module compiler "app")))))
  (unknown-module-member
   (call-with-module-fixture
    '(("app.vrn" . "(import library) (function main () i32 (library:missing))")
      ("library.vrn" . "(function value () i32 1) (export value)"))
    (lambda (compiler)
      (signals verona:unknown-module-member
        (compile-module compiler "app")))))
  (private-declaration-access
   (call-with-module-fixture
    '(("app.vrn" . "(import library) (function main () i32 (library:secret))")
      ("library.vrn" . "(function secret () i32 1)"))
    (lambda (compiler)
      (signals verona:private-declaration-access
        (compile-module compiler "app"))))))

(test compiler-state-cross-module-aliases-and-fresh-sessions
  (call-with-module-fixture
   '(("models.vrn" . "
      (macro initialize ()
        (let ((old (compiler:state-ref 'models:types nil)))
          (compiler:state-set! 'models:types (cons 'Point old))
          (compiler:state-set! 'global 10)
          (definitions)))
      (initialize)
      (macro add (key item)
        (let ((items (compiler:state-ref key nil)))
          (compiler:state-set! key (append items (list item)))
          (definitions)))
      (export add)")
     ("other.vrn" . "
      (macro initialize ()
        (let ((ignored (compiler:state-set! 'other:types '(Other)))) (definitions)))
      (initialize)")
     ("app.vrn" . "
      (import models :as m)
      (import models :as n)
      (import other)
      (m:add m:types Extra)
      (macro check ()
        (let ((entries (compiler:state-ref 'models:types)))
          (cond ((and (equal? entries '(Point Extra))
                      (equal? (compiler:state-ref 'n:types) entries)
                      (= (compiler:state-ref 'global) 10)
                      (equal? (compiler:state-ref 'other:types) '(Other)))
                 (compiler:state-set! 'verified true)
                 (definitions))
                (true missing))))
      (check)"))
   (lambda (compiler)
     (let* ((first (compile-module compiler "app"))
            (second (compile-module compiler "app"))
            (one (verona::module-expansion-context first))
            (two (verona::module-expansion-context second)))
       (is (not (eq (verona::expansion-context-session one) (verona::expansion-context-session two))))
       (dolist (context (list one two))
         (let ((verona::*expansion-context* context))
           (is (verona::compile-time-condition
                (verona::compile-time-state-ref (make-verona-name "verified")))))
         (let ((verona::*expansion-context* context))
           (is (verona::compile-time-equal
                (list (make-verona-name "Point") (make-verona-name "Extra"))
                (verona::compile-time-state-ref
                 (verona:make-qualified-name (verona:make-module-name (make-verona-name "m"))
                                      (make-verona-name "types")))))))))))

(test compiler-state-expression-expansion-is-once-per-source-form
  (let* ((unit (verona:compile-source
                (make-source "expression-state.vrn"
                  "(macro tick ()
                     (let ((n (compiler:state-ref 'count 0)))
                       (compiler:state-set! 'count (+ n 1))
                       7))
                   (function identity (for (T)) ((x T)) T (let ((ignored i32 (tick))) x))
                   (function a () i32 (identity 1))
                   (function b ((value i64)) i64 (identity value))")))
         (verona::*expansion-context* (verona::module-expansion-context unit)))
    (is (= 1 (verona::compile-time-state-ref (make-verona-name "count"))))))

(test compiler-state-unknown-qualifier-and-runtime-nil-diagnostics
  (signals verona::evaluator-error
    (verona:compile-source (make-source "bad-state.vrn"
      "(macro invalid () (compiler:state-ref 'unknown:types)) (invalid)")))
  (dolist (source '("(function bad () i32 nil)"
                    "(macro empty () nil) (function bad () i32 (empty))"))
    (signals verona::semantic-error (verona:compile-source (make-source "runtime-nil.vrn" source)))))

(test compiler-state-statements-run-at-top-level-in-source-order
  (call-with-module-fixture
   '(("registry.vrn" . "(compiler:state-set! 'registry:items '(first))")
     ("app.vrn" . "
      (compiler:state-set! 'count 0)
      (import registry :as r)
      (let ((items (compiler:state-ref 'r:items)))
        (compiler:state-set! 'r:items (append items '(second)))
        (compiler:state-set! 'count (+ (compiler:state-ref 'count) 1)))
      (macro update () '(compiler:state-set! 'count 2))
      (update)
      (cond ((= (compiler:state-ref 'count) 2)
             (compiler:state-set! 'verified true))
            (true missing))
      (compiler:state-set! 'temporary nil)
      (compiler:state-remove! 'temporary)
      (macro value () (length (compiler:state-ref 'registry:items)))
      (function main () i32 (value))"))
   (lambda (compiler)
     (dotimes (iteration 2)
       (let* ((unit (compile-module compiler "app"))
              (verona::*expansion-context* (verona::module-expansion-context unit)))
         (is (= 2 (verona::compile-time-state-ref (make-verona-name "count"))))
         (is (verona::compile-time-condition (verona::compile-time-state-ref (make-verona-name "verified"))))
         (is (not (verona::compile-time-condition (verona::compile-time-state-has (make-verona-name "temporary"))))))))))
