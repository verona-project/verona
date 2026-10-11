(in-package #:verona/tests)

(in-suite :verona)

(test resolves-nominal-product-fields-construction-and-access
  (let* ((unit (compile-string
		(make-compiler)
		"(type point (product (x i64) (y i64)))
                 (type size (product (x i64) (y i64)))
                 (function get-x ((p point)) i64 (field p x))
                 (function main () i64
                   (let ((p point (point 20 22)))
                     (%+-primitive-i64 (field p x) (field p y))))"))
	 (program (compilation-unit-semantic-program unit))
	 (declarations (unit-declarations unit))
	 (point (semantic-program-declaration program (first declarations)))
	 (size (semantic-program-declaration program (second declarations)))
	 (main (semantic-program-declaration program (fourth declarations)))
	 (point-type (semantic-type-declaration-type point))
	 (size-type (semantic-type-declaration-type size))
	 (fields (product-type-fields point-type))
	 (body (semantic-function-declaration-body main))
	 (binding (first (let-expression-bindings body)))
	 (construct (let-binding-initializer binding)))
    (is (typep point-type 'product-type))
    (is (= 2 (length fields)))
    (is (string= "x" (verona-name-value (product-field-name (first fields)))))
    (is (= 0 (product-field-index (first fields))))
    (is (= 1 (product-field-index (second fields))))
    (is (not (eq point-type size-type)))
    (is (typep construct 'construct-expression))
    (is (eq point-type (construct-expression-product-type construct)))
    (let ((left (first (semantic-call-arguments (let-expression-body body)))))
      (is (typep left 'field-expression))
      (is (eq (first fields) (field-expression-field left))))
    (is (eq program (validate-for-backend program)))))

(test resolves-fixed-array-type-identity-and-zero-length-arrays
  (let* ((unit (compile-string
                (make-compiler)
                "(function indexed ((values (array i64 2))) i64 0)"))
         (program (compilation-unit-semantic-program unit))
         (indexed (semantic-program-declaration program (first (unit-declarations unit))))
         (array-type (parameter-binding-type
                      (first (semantic-function-declaration-parameters indexed))))
         (context (semantic-program-type-context program)))
    (is (typep array-type 'verona:array-type))
    (is (= 2 (verona:array-type-length array-type)))
    (is (typep (verona:array-type-element-type array-type) 'integer-type))
    (is (eq array-type
            (verona:type-context-array-type context
                                            (verona:array-type-element-type array-type) 2)))
    (is (not (eq array-type
                 (verona:type-context-array-type context
                                                 (verona:array-type-element-type array-type) 3))))
    (is (typep (verona:type-context-array-type context
                                                (verona:array-type-element-type array-type) 0)
               'verona:array-type))
    (is (eq program (validate-for-backend program)))))

(test-cases resolves-structural-tuples-with-two-through-four-elements
  (two-elements
   (let* ((unit (compile-string
                (make-compiler)
                "(function pair ((value (tuple i32 bool))) (tuple i32 bool) value)
                 (function quartet ((value (tuple i8 i16 i32 i64)))
                   (tuple i8 i16 i32 i64) value)"))
         (program (compilation-unit-semantic-program unit))
         (pair (semantic-program-declaration program (first (unit-declarations unit))))
         (tuple (parameter-binding-type
                 (first (semantic-function-declaration-parameters pair))))
         (context (semantic-program-type-context program)))
    (is (typep tuple 'verona:tuple-type))
    (is (= 2 (length (verona:tuple-type-element-types tuple))))
    (is (eq tuple
            (verona:type-context-tuple-type context
                                            (verona:tuple-type-element-types tuple))))
    (is (eq program (validate-for-backend program)))))
  (one-element
   (signals verona:semantic-error
     (compile-string (make-compiler) "(function invalid ((value (tuple i32))) i32 0)")))
  (five-elements
   (signals verona:semantic-error
     (compile-string (make-compiler)
                     "(function invalid ((value (tuple i8 i16 i32 i64 u8))) i32 0)"))))

(test constructs-accesses-and-matches-tuples
  (let* ((unit (compile-string
                (make-compiler)
                "(function first ((items (tuple i8 i32))) i8 (tuple-get items 0))
                 (function choose ((items (tuple i8 i32))) i8
                   (match items
                     ((tuple first _) first)))
                 (function make-pair () (tuple i8 i32) (tuple 42 1000))"))
         (program (compilation-unit-semantic-program unit))
         (first (semantic-program-declaration program (first (unit-declarations unit))))
         (choose (semantic-program-declaration program (second (unit-declarations unit)))))
    (is (typep (semantic-function-declaration-body first)
               'verona:tuple-element-expression))
    (is (typep (semantic-function-declaration-body choose) 'match-expression))
    (is (typep (match-case-pattern
                (first (match-expression-cases (semantic-function-declaration-body choose))))
               'verona:tuple-pattern))
    (is (eq program (validate-for-backend program)))))

(test contextually-constructs-arrays-in-products-sums-and-nested-results
  (let* ((unit (compile-string
                (make-compiler)
                "(type packet (product (header (array i64 2))))
                 (type message (sum (small (array i64 2))))
                 (function from-product () packet (packet (array-of 1 2)))
                 (function from-sum () message (small (array-of 1 2)))
                 (function nested () (array (array i64 2) 2)
                   (array-of (array-of 1 2) (array-of 3 4)))"))
         (program (compilation-unit-semantic-program unit))
         (nested (semantic-program-declaration program (nth 4 (unit-declarations unit)))))
    (is (typep (semantic-function-declaration-body nested)
               'verona:array-construct-expression))
    (is (eq program (validate-for-backend program)))))

(test synthesizes-array-types-for-generic-dispatch
  (let* ((unit (compile-string
                (make-compiler)
                "(generic choose (value))
                 (implementation choose ((value (array i32 2))) i64 42)
                 (function dispatch () i64 (choose (array-of 1 2)))"))
         (program (compilation-unit-semantic-program unit))
         (dispatch (semantic-program-declaration program (third (unit-declarations unit)))))
    (is (typep (semantic-function-declaration-body dispatch) 'semantic-call))
    (is (eq program (validate-for-backend program)))))

(test indexes-fixed-arrays-as-places
  (let* ((unit (compile-string
                (make-compiler)
                "(function indexed ((values (array i64 2)) (i usize)) i64
                    (index values i))"))
         (program (compilation-unit-semantic-program unit))
         (indexed (semantic-program-declaration program (first (unit-declarations unit))))
         (body (semantic-function-declaration-body indexed)))
    (is (typep body 'load-expression))
    (is (typep (load-expression-place body) 'verona:index-place))
    (is (eq program (validate-for-backend program)))))

(test-cases rejects-invalid-fixed-array-construction-and-indexing
  (cannot-infer-empty-literal
   (signals verona:cannot-infer-array-element-type-error
     (compile-string (make-compiler) "(function bad () unit (do (array-of) unit))")))
  (constant-index-out-of-bounds
   (signals verona:array-index-out-of-bounds-error
     (compile-string (make-compiler)
                     "(function bad () i32 (index (array-of 1 2) 2))")))
  (void-elements
   (signals error
     (compile-string (make-compiler)
                     "(function bad () (array void 1) (array-of unit))")))
  (mixed-element-types
   (signals verona:array-element-type-mismatch-error
     (compile-string (make-compiler)
                     "(function bad () unit (do (array-of 1 true) unit))"))))

(test-cases rejects-invalid-product-definitions-construction-and-fields
  (duplicate-field
   (signals duplicate-field-error
     (compile-string (make-compiler) "(type point (product (x i64) (x i64)))")))
  (recursive-definition
   (signals recursive-type-not-supported-error
     (compile-string (make-compiler) "(type node (product (next (pointer node))))")))
  (wrong-constructor-arity
   (signals wrong-argument-count-error
     (compile-string (make-compiler)
                     "(type point (product (x i64) (y i64))) (function main () i64 (field (point 20) x))")))
  (unknown-field
   (signals unknown-field-error
     (compile-string (make-compiler)
                     "(type point (product (x i64))) (function main () i64 (field (point 20) z))")))
  (field-on-non-product
   (signals field-access-requires-product-error
     (compile-string (make-compiler) "(function main () i64 (field 42 x))")))
  (nominal-type-mismatch
   (signals type-mismatch-error
     (compile-string (make-compiler)
                    "(type point (product (x i64))) (type size (product (x i64)))
                     (function consume ((value size)) i64 0)
                     (function main () i64 (consume (point 42)))"))))

(test resolves-nominal-sums-construction-and-constructor-patterns
  (let* ((unit (compile-string
                (make-compiler)
                "(type option (sum (none) (some i64)))
                 (type other-option (sum (none) (some i64)))
                 (function unwrap ((value option)) i64
                   (match value ((none) 0) ((some x) x)))
                 (function main () i64 (unwrap (some 42)))"))
         (program (compilation-unit-semantic-program unit))
         (declarations (unit-declarations unit))
         (option (semantic-program-declaration program (first declarations)))
         (other-option (semantic-program-declaration program (second declarations)))
         (main (semantic-program-declaration program (fourth declarations)))
         (option-type (semantic-type-declaration-type option))
         (other-option-type (semantic-type-declaration-type other-option))
         (alternatives (sum-type-alternatives option-type))
         (construct (first (semantic-call-arguments
                            (semantic-function-declaration-body main)))))
    (is (typep option-type 'sum-type))
    (is (not (eq option-type other-option-type)))
    (is (= 2 (length alternatives)))
    (is (string= "none" (verona-name-value (sum-alternative-name (first alternatives)))))
    (is (= 0 (sum-alternative-index (first alternatives))))
    (is (null (sum-alternative-payload-types (first alternatives))))
    (is (= 1 (sum-alternative-index (second alternatives))))
    (is (typep construct 'sum-construct-expression))
    (is (eq (second alternatives) (sum-construct-expression-alternative construct)))
    (is (eq program (validate-for-backend program)))))

(test-cases diagnoses-invalid-sum-types-construction-and-matches
  (duplicate-alternative
   (signals duplicate-alternative-error
     (compile-string (make-compiler) "(type bad (sum (ok i64) (ok f64)))")))
  (recursive-definition
   (signals recursive-type-not-supported-error
     (compile-string (make-compiler) "(type list (sum (empty) (node (pointer list))))")))
  (wrong-constructor-arity
   (signals wrong-argument-count-error
     (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main () option (some))")))
  (non-exhaustive-match
   (signals non-exhaustive-match-error
     (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main ((value option)) i64 (match value ((some x) x)))")))
  (unreachable-pattern
   (signals unreachable-pattern-error
     (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main ((value option)) i64
                       (match value ((none) 0) ((none) 1) ((some x) x)))")))
  (literal-payload-followed-by-binding-is-exhaustive
   ;; A literal payload pattern is partial; the following binding completes it.
   (compile-string (make-compiler)
                   "(type option (sum (none) (some i64)))
                   (function main ((value option)) i64
                     (match value ((some 0) 10) ((some x) x) ((none) 0)))")))
