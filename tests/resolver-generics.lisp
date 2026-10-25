(in-package #:verona/tests)

(in-suite :verona)

(test explicit-nullary-generic-implementation-precedes-protocol-method
  (let* ((unit (compile-string
                (make-compiler)
                "(protocol bounded (a) (limit () a))
                 (generic limit ())
                 (implementation (bounded i32) (function limit () i32 7))
                 (implementation limit () i32 42)
                 (function answer () i32 (limit))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (car (last (unit-declarations unit)))))
         (call (semantic-function-declaration-body function)))
    (is (typep (semantic-reference-binding (semantic-call-callee call))
               'semantic-generic-implementation))))

(test nullary-protocol-methods-with-identical-results-remain-ambiguous
  (signals ambiguous-generic-implementation-error
    (compile-string
     (make-compiler)
     "(protocol marker (a) (marked () bool))
      (generic marked ())
      (implementation (marker i8) (function marked () bool true))
      (implementation (marker i16) (function marked () bool false))
      (function answer () bool (marked))")))

(test generic-declarations-and-exact-dispatch
  (let* ((unit (compile-string
                (make-compiler)
                "(generic combine (left right))
                 (implementation combine ((a i64) (b i64)) i64 (+ a b))
                 (implementation combine ((a f64) (b f64)) f64 (+ a b))
                 (function integer-main ((x i64) (y i64)) i64 (combine x y))"))
         (declarations (unit-declarations unit))
         (generic (first declarations))
         (program (compilation-unit-semantic-program unit))
         (semantic-generic (semantic-program-declaration program generic))
         (integer-main (semantic-program-declaration program (fourth declarations)))
         (call (semantic-function-declaration-body integer-main)))
    (is (typep generic 'generic-declaration))
    (is (= 2 (generic-declaration-arity generic)))
    (is (typep (second declarations) 'implementation-declaration))
    (is (typep semantic-generic 'semantic-generic-declaration))
    (is (= 2 (length (generic-implementations
                      (semantic-generic-declaration-generic semantic-generic)))))
    (is (typep call 'semantic-call))
    (is (typep (semantic-reference-binding (semantic-call-callee call))
               'semantic-generic-implementation))))

(test generic-arithmetic-selects-primitive-implementation
  (let* ((unit (compile-string (make-compiler)
                               "(function add ((a i64) (b i64)) i64 (+ a b))"))
         (program (compilation-unit-semantic-program unit))
         (add (semantic-program-declaration program (first (unit-declarations unit))))
         (body (semantic-function-declaration-body add)))
    (is (typep body 'primitive-call))
    (is (eq :integer-add (primitive-operation-kind (primitive-call-operation body))))))

(test generic-mixed-types-require-an-exact-implementation
  (signals no-generic-implementation-error
    (compile-string (make-compiler)
                    "(function mixed ((a i32) (b i64)) i64 (+ a b))")))

(test generic-implementations-must-match-the-declared-arity
  (signals generic-arity-mismatch-error
    (compile-string (make-compiler)
                    "(generic foo (a b)) (implementation foo ((a i64)) i64 a)")))

(test generic-implementation-parameter-names-do-not-affect-dispatch
  (signals duplicate-generic-implementation-error
    (compile-string (make-compiler)
                    "(generic foo (x))
                     (implementation foo ((x i64)) i64 x)
                     (implementation foo ((value i64)) i64 value)")))

(test generic-dispatch-can-use-an-expected-result-type
  (let* ((unit (compile-string
                (make-compiler)
                "(generic convert (value))
                 (implementation convert ((value i32)) u8
                   (%trunc-primitive-i32-u8 value))
                 (implementation convert ((value i32)) i64
                   (%sext-primitive-i32-i64 value))
                 (function narrow ((value i32)) u8 (convert value))
                 (function widen ((value i32)) i64 (convert value))"))
         (program (compilation-unit-semantic-program unit))
         (narrow (semantic-program-declaration program (fourth (unit-declarations unit))))
         (widen (semantic-program-declaration program (fifth (unit-declarations unit))))
         (narrow-body (semantic-function-declaration-body narrow))
         (widen-body (semantic-function-declaration-body widen)))
    (is (typep narrow-body 'semantic-call))
    (is (= 8 (integer-type-width (semantic-expression-type narrow-body))))
    (is (typep widen-body 'semantic-call))
    (is (= 64 (integer-type-width (semantic-expression-type widen-body))))))

(test result-directed-generics-require-an-expected-result-type
  (signals ambiguous-generic-implementation-error
    (compile-string
     (make-compiler)
     "(generic convert (value))
      (implementation convert ((value i32)) u8
        (%trunc-primitive-i32-u8 value))
      (implementation convert ((value i32)) i64
        (%sext-primitive-i32-i64 value))
      (function main ((value i32)) i32
        (do (convert value) 0))")))

(test generic-dispatch-uses-nominal-product-identities
  (let ((unit (compile-string
               (make-compiler)
               "(type point (product (x i64) (y i64)))
                (type vector (product (x i64) (y i64)))
                (generic combine (a b))
                (implementation combine ((a point) (b point)) point
                  (point (+ (field a x) (field b x))
                         (+ (field a y) (field b y))))
                (function first-x ((a point) (b point)) i64
	                  (field (combine a b) x))"))
        (program nil))
    (setf program (compilation-unit-semantic-program unit))
    (let* ((function (semantic-program-declaration program
                                                  (fifth (unit-declarations unit))))
           (field (semantic-function-declaration-body function))
           (call (field-expression-value field)))
      (is (typep call 'semantic-call))
      (is (typep (semantic-reference-binding (semantic-call-callee call))
                 'semantic-generic-implementation)))))

(test resolves-parametric-function-type-parameter-identities
  (let* ((unit (compile-string
                (make-compiler)
                "(function identity
                   (for (a))
                   ((value a))
                   a
                   value)"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (first (unit-declarations unit))))
         (parameter (first (semantic-function-declaration-parameters function)))
         (type-parameter (first (verona:semantic-function-declaration-type-parameters function))))
    (is (typep type-parameter 'verona:type-parameter))
    (is (eq type-parameter (parameter-binding-type parameter)))
    (is (eq type-parameter (semantic-function-declaration-return-type function)))
    (is (typep (semantic-function-declaration-body function) 'verona:load-expression))))

(test infers-parametric-function-arguments-structurally
  (let* ((unit (compile-string
                (make-compiler)
                "(function first
                   (for (a))
                   ((values (array a 2)))
                   a
                   (index values 0))
                 (function main ((values (array i64 2))) i64
                   (first values))"))
         (program (compilation-unit-semantic-program unit))
         (main (semantic-program-declaration program (second (unit-declarations unit))))
         (call (semantic-function-declaration-body main))
         (specialization (first (verona:semantic-program-function-specializations program))))
    (is (typep call 'verona:polymorphic-call))
    (is (typep (semantic-expression-type call) 'integer-type))
    (is (= 64 (integer-type-width (semantic-expression-type call))))
    (is (typep specialization 'verona:semantic-function-specialization))
    (is (null (verona:semantic-function-declaration-type-parameters specialization)))
    (is (typep (semantic-function-declaration-body specialization) 'verona:load-expression))))

(test resolves-protocols-and-for-constraints
  (let* ((unit (compile-string
                (make-compiler)
                "(protocol display (a)
                   (display ((value a)) (pointer u8)))
                 (function show
                   (for (a) ((display a)))
                   ((value a))
                   a
                   value)"))
         (program (compilation-unit-semantic-program unit))
         (protocol-declaration (first (unit-declarations unit)))
         (protocol (semantic-program-declaration program protocol-declaration))
         (function (semantic-program-declaration program (second (unit-declarations unit))))
         (constraint (first (verona:semantic-function-declaration-constraints function))))
    (is (typep protocol 'verona:semantic-protocol-declaration))
    (is (= 1 (length (verona:protocol-operations
                      (verona:semantic-protocol-declaration-protocol protocol)))))
    (is (typep constraint 'verona:protocol-constraint))
    (is (eq (verona:protocol-constraint-protocol constraint)
            (verona:semantic-protocol-declaration-protocol protocol)))))

(test resolves-protocol-results-as-sum-types
  (let* ((unit (compile-string
                (make-compiler)
                "(type order (sum (less) (equal) (greater)))
                 (protocol comparable (a)
                   (compare ((left a) (right a)) order))
                 (implementation (comparable i32)
                   (function compare ((left i32) (right i32)) order
                     (less)))"))
         (program (compilation-unit-semantic-program unit))
         (order-declaration (first (unit-declarations unit)))
         (protocol-declaration (second (unit-declarations unit)))
         (protocol (semantic-program-declaration program protocol-declaration))
         (operation (first (verona:protocol-operations
                            (verona:semantic-protocol-declaration-protocol protocol))))
         (order-type (verona:semantic-type-declaration-type
                      (semantic-program-declaration program order-declaration))))
    (is (typep order-type 'verona:sum-type))
    (is (eq order-type (verona:protocol-operation-result-type operation)))))

(test solves-concrete-protocol-constraints-at-parametric-calls
  (let* ((unit (compile-string
                (make-compiler)
                "(protocol display (a)
                   (display ((value a)) i32))
                 (implementation (display i32)
                   (function display ((value i32)) i32 value))
                 (function print
                   (for (a) ((display a)))
                   ((value a))
                   i32
                   (display value))
                 (function main () i32 (print 42))"))
         (program (compilation-unit-semantic-program unit))
         (main (semantic-program-declaration program (fourth (unit-declarations unit))))
         (call (semantic-function-declaration-body main))
         (specialization (verona:polymorphic-call-function call))
         (specialized-body (semantic-function-declaration-body specialization)))
    (is (typep call 'verona:polymorphic-call))
    (is (typep (verona:polymorphic-call-function call)
               'semantic-function-declaration))
    ;; The template keeps protocol evidence, while Print<i32> has a direct
    ;; call to the one concrete implementation selected at its call site.
    (is (typep specialized-body 'semantic-call))
    (is (typep (semantic-reference-binding
                (semantic-call-callee specialized-body))
               'verona:semantic-protocol-operation-implementation))))

(test-cases rejects-invalid-parametric-and-protocol-semantics
  (duplicate-type-parameter
   (signals verona:duplicate-type-parameter-error
     (compile-string
      (make-compiler)
      "(function invalid
         (for (a a))
         ((value a))
         a
         value)")))
  (unknown-protocol
   (signals verona:unknown-protocol-error
     (compile-string
      (make-compiler)
      "(function invalid
         (for (a) ((missing a)))
         ((value a))
         a
         value)")))
  (protocol-arity-mismatch
   (signals verona:protocol-arity-mismatch-error
     (compile-string
      (make-compiler)
      "(protocol display (a)
          (display ((value a)) i32))
       (function invalid
         (for (a) ((display a a)))
         ((value a))
         a
         value)")))
  (invalid-protocol-constraint
   (signals verona:invalid-protocol-constraint-error
     (compile-string
      (make-compiler)
      "(function invalid
         (for (a) (()))
         ((value a))
         a
         value)")))
  (cannot-infer-unused-type-parameter
   (signals verona:cannot-infer-type-parameter-error
     (compile-string
      (make-compiler)
      "(function ignore-type
         (for (a))
         ((value i32))
         i32
         value)
       (function main () i32 (ignore-type 1))")))
  (conflicting-type-inference
   (signals verona:conflicting-type-inference-error
     (compile-string
      (make-compiler)
      "(function select
         (for (a))
         ((left a) (right a))
         a
         left)
       (function main () i32 (select 1 true))")))
  (recursive-specialization
   (signals verona:recursive-specialization-error
     (compile-string
      (make-compiler)
      "(function expand
         (for (a))
         ((value a))
         a
         (expand (array-of value)))
       (function main () i32 (expand 1))"))))
