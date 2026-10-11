(in-package #:verona/tests)

(in-suite :verona)

(test discovers-primitive-definition-declarations
  (let* ((module (compile-string
		  (make-compiler)
		  (format nil "(%type Point (product (x f64) (y f64)))~%\
 (%constant pi f64 3.14)~%\
 (%variable counter u64 0)~%\
 (%function add ((a i32) (b i32)) i32 (+ a b))")
		  :name "definitions.vrn"))
	 (declarations (module-declarations module))
	 (type (first declarations))
	 (constant (second declarations))
	 (variable (third declarations))
	 (function (fourth declarations)))
    (is (= 4 (length declarations)))
    (is (typep type 'type-declaration))
    (is (= 1 (length (type-declaration-body type))))
    (is (typep constant 'constant-declaration))
    (is (typep variable 'variable-declaration))
    (is (typep function 'function-declaration))
    (is (eq module (declaration-module function)))
    (is (eq (first (module-forms module)) (declaration-source type)))
    (is (string= "add" (verona-name-value (declaration-name function))))
    (is (verona-list-p (syntax-datum (function-declaration-parameters function))))
    (is (verona-name-p (syntax-datum (function-declaration-return-type function))))
    (is (verona-list-p (syntax-datum (function-declaration-body function))))
    (is (verona-name-p (syntax-datum (constant-declaration-type constant))))
    (is (= 0 (syntax-datum (variable-declaration-initializer variable))))
    (is (eq type (module-lookup module (make-verona-name "Point"))))))

(test collects-named-type-definition-clauses
  (let* ((unit (compile-string
                (make-compiler)
                "(%type Point
                    (:type (product (x i32) (y i32)))
                    (:documentation \"A point.\"))
                  (%type UserId (:type (alias i64)))
                  (%type Handle (:type opaque))"))
         (declarations (unit-declarations unit))
         (point (first declarations)))
    (is (= 3 (length declarations)))
    (is (typep point 'type-declaration))
    (is (string= "A point." (declaration-documentation point)))
    (is (stringp (syntax-datum (declaration-documentation-syntax point))))
    (is (typep (second declarations) 'type-alias-declaration))
    (is (eq :opaque (type-declaration-kind (third declarations))))))

(test collects-named-function-definition-clauses
  (let ((function (first (unit-declarations
                          (compile-string
                           (make-compiler)
                           "(%function add
                               (:type (function ((left i32) (right i32)) i32))
                               (:implementation (+ left right))
                               (:documentation \"Add two integers.\"))")))))
    (is (typep function 'function-declaration))
    (is (typep (declaration-type-declaration function) 'verona:syntax))
    (is (string= "Add two integers." (declaration-documentation function)))))

(test collects-named-external-function-definition-clauses
  (let ((external (first (unit-declarations
                          (compile-string
                           (make-compiler)
                           "(%external-function c-abs
                               (:type (function (i32) i32))
                               (:external-name \"abs\"))")))))
    (is (typep external 'verona:external-function-declaration))
    (is (string= "abs" (verona:external-function-declaration-external-name external)))))

(test collects-named-macro-definition-clauses
  (let ((macro (first (unit-declarations
                       (compile-string
                        (make-compiler)
                        "(%macro identity
                            (:parameters (form))
                            (:implementation form))")))))
    (is (typep macro 'macro-declaration))))

(test collects-named-value-definition-clauses
  (let ((declarations (unit-declarations
                       (compile-string
                        (make-compiler)
                        "(%constant answer (:type i32) (:implementation 42))
                          (%variable counter (:type i32) (:implementation 0))"))))
    (is (typep (first declarations) 'constant-declaration))
    (is (typep (second declarations) 'variable-declaration))))

(test collects-named-generic-implementation-definition-clauses
  (let ((declarations (unit-declarations
                       (compile-string
                        (make-compiler)
                        "(%generic choose (:parameters (value)))
                          (%implementation
                            (:generic choose)
                            (:type (function ((value i32)) i32))
                            (:implementation value))"))))
    (is (typep (first declarations) 'generic-declaration))
    (is (typep (second declarations) 'implementation-declaration))))

(test collects-named-protocol-implementation-definition-clauses
  (let ((declarations (unit-declarations
                       (compile-string
                        (make-compiler)
                        "(%protocol measurement
                            (:parameters (a))
                            (:operations ((measure ((value a)) i32))))
                          (%implementation
                            (:protocol (measurement i32))
                            (:operations ((function measure ((value i32)) i32 value))))"))))
    (is (typep (first declarations) 'verona:protocol-declaration))
    (is (typep (second declarations) 'implementation-declaration))
    (is (implementation-declaration-protocol-application (second declarations)))))

(test rejects-duplicate-named-definition-clauses
  (signals definition-error
    (compile-string
     (make-compiler)
     "(%constant answer
         (:type i32)
         (:type i64)
         (:implementation 42))")))

