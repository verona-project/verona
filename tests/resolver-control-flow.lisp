(in-package #:verona/tests)

(in-suite :verona)

(test-cases resolves-match-patterns-scopes-and-never
  (boolean-patterns
   (let* ((unit (compile-string (make-compiler)
                                "(function choose ((enabled bool) (x i64)) i64 (match enabled (true x) (false 0)))"))
          (program (compilation-unit-semantic-program unit))
          (body (semantic-function-declaration-body
                 (semantic-program-declaration program (first (unit-declarations unit))))))
     (is (typep body 'match-expression))
     (is (typep (match-case-pattern (first (match-expression-cases body))) 'boolean-pattern))
     (is (typep (match-case-pattern (second (match-expression-cases body))) 'boolean-pattern))
     (is (eq program (validate-for-backend program)))))
  (binding-pattern-scope
   (let* ((unit (compile-string (make-compiler)
                                "(function identity ((value i64)) i64 (match value (bound bound)))"))
          (program (compilation-unit-semantic-program unit))
          (body (semantic-function-declaration-body
                 (semantic-program-declaration program (first (unit-declarations unit)))))
          (pattern (match-case-pattern (first (match-expression-cases body)))))
     (is (typep pattern 'binding-pattern))
     (is (typep (binding-pattern-binding pattern) 'pattern-binding))
     (is (eq program (validate-for-backend program)))))
  (return-produces-never
   (let* ((unit (compile-string (make-compiler)
                                "(function early ((enabled bool)) i64 (match enabled (true (return 10)) (false 20)))"))
          (program (compilation-unit-semantic-program unit))
          (body (semantic-function-declaration-body
                 (semantic-program-declaration program (first (unit-declarations unit)))))
          (expression (match-case-expression (first (match-expression-cases body)))))
     (is (typep expression 'return-expression))
     (is (typep (semantic-expression-type expression) 'never-type))
     (is (eq program (validate-for-backend program))))))

(test-cases diagnoses-match-exhaustiveness-reachability-and-termination
  (non-exhaustive-boolean
   (signals non-exhaustive-match-error
     (compile-string (make-compiler) "(function bad ((x bool)) i64 (match x (true 1)))")))
  (non-exhaustive-integer
   (signals non-exhaustive-match-error
     (compile-string (make-compiler) "(function bad ((x i64)) i64 (match x (0 1) (1 2)))")))
  (unreachable-after-wildcard
   (signals unreachable-pattern-error
     (compile-string (make-compiler) "(function bad ((x i64)) i64 (match x (_ 1) (0 2)))")))
  (duplicate-boolean-pattern
   (signals unreachable-pattern-error
     (compile-string (make-compiler) "(function bad ((x bool)) i64 (match x (true 1) (true 2) (false 3)))")))
  (unreachable-after-return
   (signals unreachable-expression-error
     (compile-string (make-compiler) "(function bad () i64 (do (return 1) 2))"))))

(test resolves-a-basic-let-binding
  (let* ((unit (compile-string (make-compiler)
                               "(function basic () i64 (let ((x i64 42)) x))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (let-expression (semantic-function-declaration-body function))
         (binding (first (let-expression-bindings let-expression))))
    (is (typep let-expression 'let-expression))
    (is (typep binding 'let-binding))
    (is (eq (let-binding-type binding) (semantic-expression-type let-expression)))
    (is (eq binding
            (semantic-reference-binding
             (load-expression-place (let-expression-body let-expression)))))
    (is (eq program (validate-for-backend program)))))

(test resolves-let-bindings-sequentially
  (let* ((unit (compile-string
                (make-compiler)
                "(function sequential () i64 (let ((x i64 20) (y i64 (%+-primitive-i64 x 22))) y))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (let-expression (semantic-function-declaration-body function))
         (bindings (let-expression-bindings let-expression))
         (x (first bindings))
         (y (second bindings)))
    (is (= 2 (length bindings)))
    (is (eq x (semantic-reference-binding
               (load-expression-place
                (first (semantic-call-arguments (let-binding-initializer y)))))))
    (is (eq y (semantic-reference-binding
               (load-expression-place (let-expression-body let-expression)))))
    (is (eq program (validate-for-backend program)))))

(test resolves-nested-let-shadowing-by-binding-identity
  (let* ((unit (compile-string
                (make-compiler)
                "(function shadow () i64 (let ((x i64 10)) (let ((x i64 42)) x)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (outer-let (semantic-function-declaration-body function))
         (inner-let (let-expression-body outer-let))
         (outer-binding (first (let-expression-bindings outer-let)))
         (inner-binding (first (let-expression-bindings inner-let))))
    (is (not (eq outer-binding inner-binding)))
    (is (eq inner-binding
            (semantic-reference-binding
             (load-expression-place (let-expression-body inner-let)))))
    (is (eq program (validate-for-backend program)))))

(test resolves-a-let-initializer-before-its-own-binding
  (let* ((unit (compile-string
                (make-compiler)
                "(function initializer-scope () i64 (let ((x i64 10)) (let ((x i64 x)) x)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (outer-let (semantic-function-declaration-body function))
         (inner-let (let-expression-body outer-let))
         (outer-binding (first (let-expression-bindings outer-let)))
         (inner-binding (first (let-expression-bindings inner-let))))
    ;; The inner initializer is resolved before its own binding is installed.
    (is (eq outer-binding
            (semantic-reference-binding
             (load-expression-place (let-binding-initializer inner-binding)))))
    (is (eq inner-binding
            (semantic-reference-binding
             (load-expression-place (let-expression-body inner-let)))))
    (is (eq program (validate-for-backend program)))))

(test propagates-never-through-let
  (let* ((unit (compile-string
                (make-compiler)
                "(function terminating () i64 (let ((x i64 10)) (return x)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (let-expression (semantic-function-declaration-body function)))
    (is (typep (semantic-expression-type let-expression) 'never-type))
    (is (eq program (validate-for-backend program)))))

(test rejects-duplicate-names-in-one-let-binding-list
  (signals duplicate-local-binding-error
    (compile-string (make-compiler)
                    "(function duplicate () i64 (let ((x i64 10) (x i64 20)) x))")))

(test rejects-recursive-let-initializers
  (signals unresolved-name-error
    (compile-string (make-compiler)
                    "(function recursive () i64 (let ((x i64 x)) x))")))

(test rejects-let-bindings-outside-their-lexical-scope
  (signals unresolved-name-error
    (compile-string (make-compiler)
                    "(function escaped () i64 (do (let ((x i64 10)) x) x))")))

(test rejects-implicitly-converted-let-initializers
  (signals type-mismatch-error
    (compile-string (make-compiler)
                    "(function wrong ((value i32)) i64 (let ((x i64 value)) x))")))

(test rejects-assignment-to-let-bindings
  (signals not-writable-error
    (compile-string (make-compiler)
                    "(function write () i64 (let ((x i64 10)) (assign x 42) x))")))

(test makes-let-bindings-addressable-but-not-writable
  (let* ((unit (compile-string
                (make-compiler)
                "(function address () (pointer i64) (let ((x i64 10)) (& x)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (let-expression (semantic-function-declaration-body function))
         (address (let-expression-body let-expression))
         (binding (first (let-expression-bindings let-expression)))
         (place (verona:address-expression-operand address)))
    (is (typep address 'address-expression))
    (is (eq binding (semantic-reference-binding place)))
    (is (place-expression-addressable-p place))
    (is (not (place-expression-writable-p place)))
    (is (eq program (validate-for-backend program)))))

(test rejects-local-variable-definitions
  (signals invalid-definition-context-error
    (compile-string (make-compiler)
                    "(function local-definition () i64 (variable x i64 10))")))

(test composes-let-with-match-case-scopes
  (let* ((unit (compile-string
                (make-compiler)
                "(function max-plus-ten ((a i64) (b i64)) i64
                    (match (%>-primitive-i64 a b)
                      (true (let ((x i64 (%+-primitive-i64 a 10))) x))
                      (false (let ((x i64 (%+-primitive-i64 b 10))) x))))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (match (semantic-function-declaration-body function))
         (true-let (match-case-expression (first (match-expression-cases match))))
         (false-let (match-case-expression (second (match-expression-cases match)))))
    (is (typep true-let 'let-expression))
    (is (typep false-let 'let-expression))
    (is (not (eq (first (let-expression-bindings true-let))
                 (first (let-expression-bindings false-let)))))
    (is (eq program (validate-for-backend program)))))
