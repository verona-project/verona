(in-package #:verona/tests)

(in-suite :verona)

(test unrelated-protocol-cannot-supply-an-imported-bound-generic
  (signals no-generic-implementation-error
    (compile-file
     (make-compiler :search-paths (list #P"projects/base/src/"))
     #P"tests/modules/bounded-unrelated.vrn")))

(test base-bounded-resolves-a-concrete-result-statically
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"tests/modules/bounded-concrete.vrn"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (call (semantic-function-declaration-body function)))
    (is (typep call 'semantic-call))
    (is (typep (semantic-reference-binding (semantic-call-callee call))
               'verona:semantic-protocol-operation-implementation))))

(test base-bounded-requires-result-type-context
  (signals ambiguous-generic-implementation-error
    (compile-file
     (make-compiler :search-paths (list #P"projects/base/src/"))
     #P"tests/modules/bounded-ambiguous.vrn")))

(test base-bounded-has-no-floating-point-instance
  (signals no-generic-implementation-error
    (compile-file
     (make-compiler :search-paths (list #P"projects/base/src/"))
     #P"tests/modules/bounded-float.vrn")))

(test base-bounded-has-no-pointer-instance
  (signals no-generic-implementation-error
    (compile-file
     (make-compiler :search-paths (list #P"projects/base/src/"))
     #P"tests/modules/bounded-pointer.vrn")))

(test imports-the-explicit-base-macro-module
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"tests/modules/base-client.vrn"))
         (function (second (unit-declarations unit))))
    (is (typep function 'function-declaration))
    (is (string= "identity" (verona-name-value (declaration-name function))))))

(test expands-quasiquoted-base-macros-into-compilable-definitions
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"tests/modules/base-macro-client.vrn"))
         (function (second (unit-declarations unit)))
         (constant (fourth (unit-declarations unit))))
    (is (typep function 'function-declaration))
    (is (string= "generated-i32"
                 (verona-name-value (declaration-name function))))
    (is (typep constant 'constant-declaration))
    (is (string= "answer" (verona-name-value (declaration-name constant))))))

(defun base-protocol-client-primitive-kinds ()
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"projects/base/tests/base-protocol-client.vrn"))
         (program (compilation-unit-semantic-program unit))
         (main (semantic-program-declaration program (car (last (unit-declarations unit)))))
         (body (semantic-function-declaration-body main))
         (primitive-kinds '()))
    (unless (and (typep body 'match-expression)
                 (typep (match-expression-value body) 'verona:polymorphic-call))
      (error "The base protocol client no longer has its expected polymorphic match body."))
    (dolist (specialization (verona:semantic-program-function-specializations program))
      (let ((operation-call (semantic-function-declaration-body specialization)))
        (when (typep operation-call 'semantic-call)
          (let ((implementation (semantic-reference-binding
                                 (semantic-call-callee operation-call))))
            (when (typep implementation 'verona:semantic-protocol-operation-implementation)
              (let ((primitive-body (semantic-function-declaration-body implementation)))
                (is (typep primitive-body 'primitive-call))
                (push (primitive-operation-kind (primitive-call-operation primitive-body))
                      primitive-kinds)))))))
    primitive-kinds))

(test-cases imports-base-numeric-equality-and-ordering-protocols
  (addition
   (is (= 1 (count :integer-add (base-protocol-client-primitive-kinds)))))
  (equality
   (is (= 1 (count :signed-integer-equal (base-protocol-client-primitive-kinds)))))
  (less-than
   (is (= 1 (count :signed-integer-less-than (base-protocol-client-primitive-kinds)))))
  (less-than-or-equal
   (is (= 1 (count :signed-integer-less-than-or-equal (base-protocol-client-primitive-kinds)))))
  (greater-than
   (is (= 1 (count :signed-integer-greater-than (base-protocol-client-primitive-kinds)))))
  (greater-than-or-equal
   (is (= 1 (count :signed-integer-greater-than-or-equal (base-protocol-client-primitive-kinds))))))

(test imports-base-core-protocols
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"projects/base/tests/base-core-protocol-client.vrn"))
         (program (compilation-unit-semantic-program unit)))
    ;; Each constrained function body resolves through its matching imported
    ;; base protocol.  No concrete instance is needed until a client calls
    ;; one of these polymorphic functions with a particular type.
    (dolist (declaration (unit-declarations unit))
      (when (typep declaration 'function-declaration)
        (is (typep (semantic-function-declaration-body
                    (semantic-program-declaration program declaration))
                   'verona:protocol-operation-call))))))

(test imports-the-base-convert-generic
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/base/src/"))
                #P"projects/base/tests/base-convert-client.vrn"))
         (program (compilation-unit-semantic-program unit))
         (base-module (find "base" (program-modules program)
                            :key (lambda (module)
                                   (module-name-string (module-name module)))
                            :test #'string=))
         (convert-declaration
           (verona:module-find-export base-module (make-verona-name "convert")))
         (convert (semantic-generic-declaration-generic
                   (semantic-program-declaration program convert-declaration)))
         (main (semantic-program-declaration program (first (unit-declarations unit))))
         (body (semantic-function-declaration-body main)))
    ;; Ten numeric types, each convertible to every numeric destination.
    (is (= 100 (length (generic-implementations convert))))
    (is (typep body 'let-expression))
    (is (= 32 (integer-type-width (semantic-expression-type body))))))

(test imports-the-verona-testing-library
  (let* ((unit (compile-file
                (make-compiler :search-paths (list #P"projects/testing/src/"
                                                   #P"projects/base/src/"))
                #P"projects/testing/tests/testing-client.vrn"))
         (program (compilation-unit-semantic-program unit))
         (main (semantic-program-declaration program (car (last (unit-declarations unit)))))
         (body (semantic-function-declaration-body main)))
    (is (typep body 'semantic-call))
    (is (typep (semantic-call-callee body) 'semantic-reference))))
