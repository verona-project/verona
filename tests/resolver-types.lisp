(in-package #:verona/tests)

(in-suite :verona)

(test resolves-global-bindings-signatures-and-forward-calls-by-identity
  (let* ((unit (compile-string
                (make-compiler)
                "(type Point (product))\
                 (constant origin i32 0)\
                 (function second ((p Point)) i32 origin)\
                 (function first ((p Point)) i32 (second p))"))
         (declarations (unit-declarations unit))
         (point (first declarations))
         (origin (second declarations))
         (second (third declarations))
         (first (fourth declarations))
         (program (compilation-unit-semantic-program unit))
         (second-semantic (semantic-program-declaration program second))
         (first-semantic (semantic-program-declaration program first))
         (first-parameter (first (semantic-function-declaration-parameters
                                  first-semantic)))
         (first-body (semantic-function-declaration-body first-semantic)))
    ;; Signature type names point at the exact source declaration/builtin.
    (is (eq point
            (semantic-reference-binding
             (parameter-binding-type-reference first-parameter))))
    ;; A bare body name is a reference to the constant declaration itself.
    (is (eq origin
            (semantic-reference-binding
             (semantic-function-declaration-body second-semantic))))
    ;; A forward function call and its parameter use each retain identity.
    (is (typep first-body 'semantic-call))
    (is (eq second
            (semantic-reference-binding (semantic-call-callee first-body))))
    ;; A parameter used as a value carries an explicit semantic load; its
    ;; place identity remains available to address-of and store operations.
    (is (typep (first (semantic-call-arguments first-body)) 'load-expression))
    (is (eq first-parameter
            (semantic-reference-binding
             (load-expression-place
              (first (semantic-call-arguments first-body))))))))

(test resolves-builtins-and-shadows-global-bindings-with-parameters
  (let* ((unit (compile-string
                (make-compiler)
                "(variable x i32 10) (function foo ((x i32)) i32 (+ x 1))"))
         (global (first (unit-declarations unit)))
         (function (second (unit-declarations unit)))
         (semantic (semantic-program-declaration
                    (compilation-unit-semantic-program unit) function))
         (parameter (first (semantic-function-declaration-parameters semantic)))
         (body (semantic-function-declaration-body semantic))
         (argument (first (semantic-call-arguments body))))
    (is (typep argument 'load-expression))
    (is (not (eq global (semantic-reference-binding (load-expression-place argument)))))
    (is (eq parameter (semantic-reference-binding (load-expression-place argument))))
    (is (not (null (semantic-reference-binding
                    (semantic-function-declaration-return-type-reference
                     semantic)))))
    ;; + resolves through the bootstrap semantic scope, not special text.
    (is (typep (semantic-call-callee body) 'semantic-reference))
    (is (not (null (semantic-reference-binding
                    (semantic-call-callee body)))))))

(test semantic-scopes-support-nested-lookup-and-identity-shadowing
  (let* ((global (make-semantic-scope))
         (function (semantic-scope-child global))
         (lexical (semantic-scope-child function))
         (name (make-verona-name "x"))
         (outer (make-instance 'parameter-binding :name name))
         (inner (make-instance 'parameter-binding :name name)))
    (semantic-scope-bind global name outer)
    (is (eq outer (semantic-scope-lookup lexical name)))
    (semantic-scope-bind function name inner)
    (is (eq inner (semantic-scope-lookup lexical name)))
    (is (eq outer (semantic-scope-lookup global name)))))

(test-cases reports-unresolved-runtime-names-and-duplicate-parameters
  (unresolved-name
   (signals unresolved-name-error
     (compile-string (make-compiler) "(function foo () i32 unknown)")))
  (macro-is-not-a-runtime-binding
   ;; The macro is available only to expansion, not to semantic lookup.
   (signals unresolved-name-error
     (compile-string (make-compiler)
                     "(macro compile-only () 0) (function foo () i32 compile-only)")))
  (duplicate-parameter
   (signals duplicate-local-binding-error
     (compile-string (make-compiler)
                     "(function foo ((x i32) (x i32)) i32 x)"))))

(test resolves-canonical-primitive-pointer-and-function-types
  (let* ((unit (compile-string
                (make-compiler)
                "(type Node (product (value i32) (next (pointer i32))))\
                 (variable current (pointer Node) (deref (& current)))\
                 (function distance ((a (pointer Node))\
                                     (b (pointer (pointer i32)))) f64 3.14)\
                 (function another-distance ((a (pointer Node))\
                                             (b (pointer (pointer i32)))) f64 3.14)\
                 (function nothing () unit unit)"))
         (declarations (unit-declarations unit))
         (node (first declarations))
         (current (second declarations))
         (distance (third declarations))
         (another-distance (fourth declarations))
         (nothing (fifth declarations))
         (program (compilation-unit-semantic-program unit))
         (node-semantic (semantic-program-declaration program node))
         (current-semantic (semantic-program-declaration program current))
         (distance-semantic (semantic-program-declaration program distance))
         (another-semantic (semantic-program-declaration program another-distance))
         (nothing-semantic (semantic-program-declaration program nothing))
         (node-type (semantic-type-declaration-type node-semantic))
         (current-type (semantic-variable-declaration-type current-semantic))
         (parameters (semantic-function-declaration-parameters distance-semantic))
         (first-parameter-type (parameter-binding-type (first parameters)))
         (second-parameter-type (parameter-binding-type (second parameters))))
    (is (typep node-type 'defined-type))
    (is (eq node (defined-type-declaration node-type)))
    (is (typep current-type 'pointer-type))
    (is (eq node-type (pointer-type-target current-type)))
    ;; Repeated pointer syntax reuses the same interned object.
    (is (eq current-type first-parameter-type))
    (is (typep second-parameter-type 'pointer-type))
    (is (typep (pointer-type-target second-parameter-type) 'pointer-type))
    (let ((integer (pointer-type-target
                    (pointer-type-target second-parameter-type))))
      (is (typep integer 'integer-type))
      (is (integer-type-signed integer))
      (is (= 32 (integer-type-width integer))))
    (is (typep (semantic-function-declaration-return-type distance-semantic)
               'float-type))
    (is (= 64 (float-type-width
               (semantic-function-declaration-return-type distance-semantic))))
    (is (typep (semantic-function-declaration-type distance-semantic) 'function-type))
    (is (eq (semantic-function-declaration-type distance-semantic)
            (semantic-function-declaration-type another-semantic)))
    (is (typep (semantic-function-declaration-return-type nothing-semantic)
               'unit-type))))

(test resolves-transparent-type-aliases-and-forward-chains
  (let* ((unit (compile-string
                (make-compiler)
                "(type AccountId UserId)
                 (type UserId i64)
                 (type Point (product (x i64)))
                 (type Coordinate Point)
                 (generic identity (value))
                 (implementation identity ((value i64)) i64 value)
                 (function use-id ((value AccountId)) i64 (identity value))
                 (function get-x ((value Coordinate)) i64 (field value x))"))
         (program (compilation-unit-semantic-program unit))
         (declarations (unit-declarations unit))
         (account-id (first declarations))
         (user-id (second declarations))
         (point (third declarations))
         (coordinate (fourth declarations))
         (use-id (nth 6 declarations))
         (account-semantic (semantic-program-declaration program account-id))
         (user-semantic (semantic-program-declaration program user-id))
         (point-semantic (semantic-program-declaration program point))
         (coordinate-semantic (semantic-program-declaration program coordinate))
         (use-id-semantic (semantic-program-declaration program use-id))
         (parameter (first (semantic-function-declaration-parameters use-id-semantic))))
    (is (typep account-id 'type-alias-declaration))
    (is (typep account-semantic 'semantic-type-alias-declaration))
    (is (eq (semantic-type-alias-declaration-target-type account-semantic)
            (semantic-type-alias-declaration-target-type user-semantic)))
    (is (eq (semantic-type-alias-declaration-target-type account-semantic)
            (parameter-binding-type parameter)))
    (is (eq (semantic-type-alias-declaration-target-type coordinate-semantic)
            (semantic-type-declaration-type point-semantic)))
    (is (eq program (validate-for-backend program)))))

(test-cases rejects-type-alias-cycles-and-implicit-product-syntax
  (alias-cycle
   (signals type-alias-cycle-error
     (compile-string (make-compiler) "(type left right) (type right left)")))
  (recursive-alias
   (signals recursive-type-not-supported-error
     (compile-string (make-compiler)
                     "(type node-link (pointer node))
                     (type node (product (next node-link)))")))
  (implicit-field
   (signals verona:definition-error
     (compile-string (make-compiler) "(type point (x i64))")))
  (nested-implicit-field
   (signals verona:definition-error
     (compile-string (make-compiler) "(type point ((x i64)))"))))

(test rejects-resolved-names-that-do-not-denote-types
  (signals expected-type-error
    (compile-string (make-compiler)
                    "(function value () i32 unit) (variable counter value 0)")))

(test bootstraps-a-canonical-boolean-type
  (let* ((unit (compile-string (make-compiler)
                               "(function predicate ((value bool)) bool true)"))
         (semantic (semantic-program-declaration
                    (compilation-unit-semantic-program unit)
                    (first (unit-declarations unit))))
         (parameter (first (semantic-function-declaration-parameters semantic))))
    (is (typep (parameter-binding-type parameter) 'boolean-type))
    (is (eq (parameter-binding-type parameter)
            (semantic-function-declaration-return-type semantic)))))

(test uses-unit-for-the-unit-type-and-value
  (let* ((unit (compile-string (make-compiler)
                               "(function no-op () unit unit)"))
         (semantic (semantic-program-declaration
                    (compilation-unit-semantic-program unit)
                    (first (unit-declarations unit)))))
    (is (typep (semantic-function-declaration-return-type semantic) 'unit-type))))

(test analyzes-typed-expressions-and-contextual-initializers
  (let* ((unit (compile-string
                (make-compiler)
                "(constant initial i32 0)\
                 (variable counter i32 initial)\
                 (function add ((a i32) (b i32)) i32 (+ a b))\
                 (function increment ((value i32)) i32 (add value 1))\
                 (function reset () unit (do (assign counter 0) unit))\
                 (function main () i32 (increment counter))"))
         (declarations (unit-declarations unit))
         (program (compilation-unit-semantic-program unit))
         (initial (semantic-program-declaration program (first declarations)))
         (counter (semantic-program-declaration program (second declarations)))
         (add (semantic-program-declaration program (third declarations)))
         (increment (semantic-program-declaration program (fourth declarations)))
         (reset (semantic-program-declaration program (fifth declarations)))
         (main (semantic-program-declaration program (sixth declarations)))
         (initializer (semantic-constant-declaration-initializer initial))
         (add-body (semantic-function-declaration-body add))
         (increment-body (semantic-function-declaration-body increment))
         (reset-body (semantic-function-declaration-body reset))
         (assignment (first (sequence-expression-expressions reset-body))))
    (is (typep initializer 'integer-literal))
    (is (eq (semantic-constant-declaration-type initial)
            (semantic-expression-type initializer)))
    (is (typep (semantic-variable-declaration-initializer counter) 'semantic-reference))
    (is (typep add-body 'semantic-call))
    (is (eq (semantic-function-declaration-return-type add)
            (semantic-expression-type add-body)))
    (is (typep (second (semantic-call-arguments increment-body)) 'integer-literal))
    (is (typep reset-body 'sequence-expression))
    (is (typep assignment 'assignment-expression))
    (is (eq (semantic-function-declaration-return-type reset)
            (semantic-expression-type reset-body)))
    (is (typep (semantic-function-declaration-body main) 'semantic-call))
    ;; Nested expressions retain the exact syntax that produced them.
    (is (not (null (expression-source assignment))))))

(test-cases diagnoses-type-mismatches-and-invalid-places
  (wrong-return-type
   (signals type-mismatch-error
     (compile-string (make-compiler) "(function wrong () i32 false)")))
  (assignment-to-constant
   (signals not-writable-error
     (compile-string (make-compiler)
                     "(constant answer i32 42) (function change () unit (assign answer 1))")))
  (address-of-temporary
   (signals not-addressable-error
     (compile-string (make-compiler)
                     "(function address () (pointer i32) (& (+ 1 2)))"))))

(test bootstraps-concrete-primitive-identities-and-explicit-conversions
  (let* ((unit (compile-string
		(make-compiler)
		"(function widen ((value i32)) i64 (%sext-primitive-i32-i64 value))\
                 (function compare ((left f64) (right f64)) bool (%<-primitive-f64 left right))"))
	 (program (compilation-unit-semantic-program unit))
	 (widen (semantic-program-declaration program (first (unit-declarations unit))) )
	 (compare (semantic-program-declaration program (second (unit-declarations unit))))
	 (conversion (semantic-function-declaration-body widen))
	 (comparison (semantic-function-declaration-body compare)))
    (is (typep conversion 'conversion-expression))
    (is (typep (primitive-call-operation conversion) 'primitive-operation))
    (is (eq :integer-sign-extend
	    (primitive-operation-kind (primitive-call-operation conversion))))
    (is (typep comparison 'primitive-call))
    (is (eq :float-ordered-less-than
	    (primitive-operation-kind (primitive-call-operation comparison))))
    (is (eq :ordered-false
	    (primitive-operation-nan-semantics (primitive-call-operation comparison))))
    (is (eq program (validate-for-backend program)))))

(test automatically-widens-characters-to-integers
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function putchar \"putchar\" (i32) i32)
                 (function emit ((character char)) i32 (putchar character))"))
         (program (compilation-unit-semantic-program unit))
         (emit (semantic-program-declaration program (second (unit-declarations unit))))
         (call (semantic-function-declaration-body emit))
         (conversion (first (semantic-call-arguments call))))
    (is (typep conversion 'character-integer-conversion-expression))
    (is (typep (character-integer-conversion-expression-operand conversion)
               'load-expression))
    (is (typep (semantic-expression-type conversion) 'integer-type))
    (is (eq program (validate-for-backend program)))))

(test-cases enforces-exact-primitive-types-and-implicit-memory-reads
  (rejects-mismatched-primitive-operands
   (signals type-mismatch-error
     (compile-string (make-compiler)
                     "(function wrong ((value i32)) i64 (%+-primitive-i64 value 1))")))
  (inserts-memory-loads
   (let* ((unit (compile-string
		(make-compiler)
		"(function read ((address (pointer i64))) i64 (dereference address))\
                 (function write ((address (pointer i64)) (value i64)) unit\
                   (do (store (dereference address) value) unit))"))
	 (program (compilation-unit-semantic-program unit))
	 (read-function (semantic-program-declaration program (first (unit-declarations unit))))
	 (write-function (semantic-program-declaration program (second (unit-declarations unit))))
	 (write-body (semantic-function-declaration-body write-function)))
    (is (typep (semantic-function-declaration-body read-function) 'load-expression))
    (is (typep (load-expression-place (semantic-function-declaration-body read-function))
	       'dereference-expression))
    (is (typep (first (sequence-expression-expressions write-body)) 'store-expression))
    (is (eq program (validate-for-backend program))))))

(test treats-load-as-an-ordinary-callable-name
  (let* ((unit (compile-string
                (make-compiler)
                "(function load ((value i64)) i64 value)
                 (function main () i64 (load 42))"))
         (program (compilation-unit-semantic-program unit))
         (main (semantic-program-declaration program (second (unit-declarations unit)))))
    (is (typep (semantic-function-declaration-body main) 'semantic-call))
    (is (eq program (validate-for-backend program)))))

(test models-unit-as-a-distinct-singleton-with-pointer-width-representation
  (let ((context32 (make-type-context :pointer-width 32))
	(context64 (make-type-context :pointer-width 64)))
    (is (typep (type-context-unit-type context32) 'unit-type))
    (is (typep (type-context-unit-value context32) 'unit-value))
    (is (= 32 (integer-type-width (type-context-unit-representation-type context32))))
    (is (= 64 (integer-type-width (type-context-unit-representation-type context64))))
    (is (not (eq (type-context-unit-type context64)
		 (type-context-unit-representation-type context64))))
    (is (= 0 (unit-machine-representation context64 (type-context-unit-value context64))))))
