(defpackage #:verona/tests
  (:use #:cl #:fiveam)
  (:shadowing-import-from #:verona #:compile-file)
  (:import-from #:verona
		#:compile-string #:make-compiler #:make-source
		#:compile-module #:module #:module-name #:module-name-string
		#:program-modules #:qualified-name-p #:qualified-name-qualifier #:qualified-name-name
		#:compilation-unit #:compilation-unit-source #:compilation-unit-forms
		#:compilation-unit-semantic-program
		#:unit-declarations #:find-declaration
		#:module-forms #:module-source #:module-declarations #:module-environment #:module-lookup
		#:read-source #:source-contents #:source-location-offset
		#:source-location-column #:source-location-line #:source-name
		#:syntax-datum #:syntax-end #:syntax-source #:syntax-start
		#:syntax-with-datum #:verona-read-error
		#:verona-name #:verona-name-p #:verona-name-value #:verona-name=
		#:verona-symbol-name #:verona-list-p #:verona-list-elements
		#:make-verona-list #:make-verona-name #:make-verona-function #:make-verona-macro
		#:make-bootstrap-environment #:make-environment #:environment-bind
		#:environment-child #:environment-lookup #:unbound-name-error
		#:evaluate #:expand #:unit-literal-p
		#:declaration-name #:declaration-source #:declaration-expanded-syntax #:declaration-module
		#:declaration-documentation #:declaration-documentation-syntax
		#:declaration-type-declaration
		#:type-declaration #:type-declaration-kind #:type-declaration-body #:type-alias-declaration
		#:type-alias-declaration-target
		#:function-declaration #:function-declaration-parameters
		#:function-declaration-return-type #:function-declaration-body
		#:macro-declaration #:macro-declaration-parameters #:macro-declaration-body
		#:constant-declaration #:constant-declaration-type #:constant-declaration-value
		#:variable-declaration #:variable-declaration-type #:variable-declaration-initializer
		#:generic-declaration #:generic-declaration-arity
		#:implementation-declaration #:implementation-declaration-protocol-application
		#:definition-error #:duplicate-declaration-error #:non-definition-top-level-error #:verona-macro-p
		#:semantic-program-declaration #:semantic-function-declaration
		#:semantic-program-type-context #:semantic-type-declaration
		#:semantic-type-alias-declaration
		#:semantic-type-alias-declaration-target-type
		#:semantic-type-declaration-type #:semantic-type-declaration-fields
		#:semantic-function-declaration-parameters
		#:semantic-function-declaration-return-type-reference
		#:semantic-function-declaration-return-type
		#:semantic-function-declaration-type
		#:semantic-function-declaration-body
		#:semantic-generic-declaration #:semantic-generic-declaration-generic
		#:semantic-generic-implementation #:semantic-generic-implementation-type
		#:generic-arity #:generic-implementations #:generic-implementation-parameter-types
		#:semantic-constant-declaration-initializer
		#:semantic-variable-declaration-initializer
		#:semantic-reference #:semantic-reference-binding
		#:semantic-call #:semantic-call-callee #:semantic-call-arguments
		#:semantic-expression-type #:expression-source
		#:primitive-call #:primitive-call-operation #:conversion-expression
		#:primitive-operation #:primitive-operation-kind #:primitive-operation-parameter-types
		#:primitive-operation-result-type #:primitive-operation-nan-semantics
		#:integer-literal #:boolean-literal #:character-literal #:character-literal-value #:string-literal
		#:sequence-expression #:sequence-expression-expressions
		#:let-expression #:let-expression-bindings #:let-expression-scope #:let-expression-body
		#:let-binding #:let-binding-type #:let-binding-initializer
		#:match-expression #:match-expression-value #:match-expression-cases
		#:match-case #:match-case-pattern #:match-case-scope #:match-case-expression
		#:boolean-pattern #:character-pattern #:integer-pattern #:wildcard-pattern #:binding-pattern
		#:binding-pattern-binding #:pattern-binding #:pattern-binding-type
		#:return-expression #:return-expression-value #:never-type
		#:assignment-expression #:assignment-expression-target
		#:address-expression #:dereference-expression
		#:load-expression #:load-expression-place #:store-expression
		#:place-expression-addressable-p #:place-expression-writable-p
		#:parameter-binding #:parameter-binding-type-reference #:parameter-binding-type
		#:semantic-variable-declaration #:semantic-variable-declaration-type
		#:semantic-constant-declaration #:semantic-constant-declaration-type
		#:unit-type #:boolean-type #:char-type #:integer-type #:integer-type-signed #:integer-type-width
		#:unit-value #:unit-expression #:unit-expression-value
		#:float-type #:float-type-width #:pointer-type #:pointer-type-target
		#:function-type #:function-type-parameters #:function-type-result
		#:make-type-context #:type-context-unit-type #:type-context-unit-value
		#:type-context-char-type
		#:type-context-unit-representation-type #:unit-machine-representation
		#:defined-type #:defined-type-declaration #:opaque-type #:product-type #:product-type-fields
		#:product-field #:product-field-name #:product-field-type #:product-field-index
		#:construct-expression #:construct-expression-product-type #:construct-expression-fields
		#:sum-type #:sum-type-alternatives #:sum-alternative #:sum-alternative-name
		#:sum-alternative-index #:sum-alternative-payload-types
		#:sum-construct-expression #:sum-construct-expression-alternative
		#:sum-construct-expression-arguments #:constructor-pattern
		#:constructor-pattern-alternative #:constructor-pattern-payload-patterns
		#:field-expression #:field-expression-value #:field-expression-field
		#:expected-type-error
		#:type-mismatch-error #:not-writable-error #:not-addressable-error
		#:non-exhaustive-match-error #:unreachable-pattern-error
		#:unreachable-expression-error
		#:make-semantic-scope #:semantic-scope-child #:semantic-scope-bind
		#:semantic-scope-lookup
		#:unresolved-name-error #:duplicate-local-binding-error #:invalid-definition-context-error
		#:duplicate-field-error #:recursive-type-not-supported-error #:type-alias-cycle-error #:unknown-field-error
		#:duplicate-alternative-error
		#:field-access-requires-product-error #:wrong-argument-count-error
		#:generic-arity-mismatch-error #:duplicate-generic-implementation-error
		#:no-generic-implementation-error
		#:validate-for-backend))

(in-package #:verona/tests)

(def-suite :verona)
(in-suite :verona)

(test models-c-external-declarations-and-void-pointers
  (let* ((source
           "(external-function allocate \"malloc\" (usize) (pointer void))
             (function main () i32
               (let ((memory (pointer void) (allocate 1)))
                 (let ((buffer (pointer u8) (cast (pointer u8) memory))) 0)))")
         (unit (compile-string (make-compiler) source))
         (declaration (first (unit-declarations unit)))
         (program (compilation-unit-semantic-program unit))
         (semantic (semantic-program-declaration program declaration))
         (context (semantic-program-type-context program)))
    (is (typep declaration 'verona:external-function-declaration))
    (is (string= "malloc"
                 (verona:external-function-declaration-external-name declaration)))
    (is (typep semantic 'verona:semantic-external-function-declaration))
    (is (typep (verona:semantic-external-function-declaration-result-type semantic)
               'verona:pointer-type))
    (is (typep (verona:pointer-type-pointee
                (verona:semantic-external-function-declaration-result-type semantic))
               'verona:void-type))
    (is (typep (verona:type-context-void-type context) 'verona:void-type))))

(test accepts-bool-in-c-abi-signatures
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function invert \"verona_bool_invert\" (bool) bool)
                 (function invert-export ((value bool)) bool (%not-primitive-bool value))
                 (native-export invert-export \"verona_bool_invert_export\")"))
         (program (compilation-unit-semantic-program unit)))
    (is (eq program (validate-for-backend program)))))

(test rejects-void-pointer-dereference
  (signals verona:invalid-expression-error
    (compile-string
     (make-compiler)
     "(external-function allocate \"malloc\" (usize) (pointer void))
       (function main () i32
         (let ((memory (pointer void) (allocate 1)))
           (load (deref memory))))")))

(test models-nominal-opaque-types-for-c-handles
  (let* ((unit (compile-string
                (make-compiler)
                "(type file-stream)
                 (type directory-stream)
                 (type stream-holder (product (stream (pointer file-stream))))
                 (external-function open-stream \"fopen\" ((pointer i8) (pointer i8)) (pointer file-stream))
                 (external-function close-stream \"fclose\" ((pointer file-stream)) i32)"))
         (program (compilation-unit-semantic-program unit))
         (file-declaration (first (unit-declarations unit)))
         (directory-declaration (second (unit-declarations unit)))
         (holder-declaration (third (unit-declarations unit)))
         (file-type (semantic-type-declaration-type
                     (semantic-program-declaration program file-declaration)))
         (directory-type (semantic-type-declaration-type
                          (semantic-program-declaration program directory-declaration)))
         (holder-type (semantic-type-declaration-type
                       (semantic-program-declaration program holder-declaration))))
    (is (eq :opaque (type-declaration-kind file-declaration)))
    (is (null (type-declaration-body file-declaration)))
    (is (typep file-type 'opaque-type))
    (is (typep directory-type 'opaque-type))
    (is (not (eq file-type directory-type)))
    ;; An inline pointer is sized even though its target is not.
    (is (typep (product-field-type (first (product-type-fields holder-type)))
               'pointer-type))
    (is (eq program (validate-for-backend program)))))

(test rejects-opaque-types-as-inline-values
  (signals verona:semantic-error
    (compile-string (make-compiler)
                    "(type handle) (function invalid ((value handle)) i32 0)"))
  (signals verona:semantic-error
    (compile-string (make-compiler)
                    "(type handle) (function invalid () handle unit)"))
  (signals verona:semantic-error
    (compile-string (make-compiler)
                    "(type handle) (type invalid (product (value handle)))"))
  (signals verona:semantic-error
    (compile-string (make-compiler)
                    "(type handle) (function invalid ((values (array handle 1))) i32 0)"))
  (signals verona:invalid-expression-error
    (compile-string
     (make-compiler)
     "(type handle)
      (external-function acquire \"acquire\" () (pointer handle))
      (function invalid () i32 (load (deref (acquire))))")))

(test keeps-void-aliases-transparent
  (let* ((unit (compile-string (make-compiler) "(type legacy-handle void)"))
         (declaration (first (unit-declarations unit)))
         (program (compilation-unit-semantic-program unit))
         (semantic (semantic-program-declaration program declaration)))
    (is (typep declaration 'type-alias-declaration))
    (is (typep (semantic-type-alias-declaration-target-type semantic) 'verona:void-type))))

(test maps-external-void-results-to-unit-at-the-call-boundary
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function allocate \"malloc\" (usize) (pointer void))
                 (external-function release \"free\" ((pointer void)) void)
                 (function release-all () unit
                   (let ((memory (pointer void) (allocate 1))) (release memory)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (third (unit-declarations unit))))
         (body (semantic-function-declaration-body function))
         (call (verona:let-expression-body body)))
    (is (typep call 'verona:external-call-expression))
    (is (typep (verona:expression-type call) 'verona:unit-type))))

(test reads-atoms
  (let ((forms (read-source (make-source "atoms.vrn" "foo 42 -42 3.14 \"hello\" unit"))))
    (is (= 6 (length forms)))
    (is (string= "foo" (verona-symbol-name (syntax-datum (first forms)))))
    (is (= 42 (syntax-datum (second forms))))
    (is (= -42 (syntax-datum (third forms))))
    (is (= 3.14d0 (syntax-datum (fourth forms))))
    (is (string= "hello" (syntax-datum (fifth forms))))
    (is (unit-literal-p (syntax-datum (sixth forms))))))

(test reads-single-line-comments
  (let* ((source (make-source "comments.vrn"
                              "; a top-level comment~%
(foo; an inner comment~%
  bar) ; a trailing comment~%
; another top-level comment~%
baz"))
         (forms (read-source source))
         (list (syntax-datum (first forms))))
    (is (= 2 (length forms)))
    (is (verona-list-p list))
    (is (= 2 (length (verona-list-elements list))))
    (is (string= "foo"
                 (verona-symbol-name
                  (syntax-datum (first (verona-list-elements list))))))
    (is (string= "bar"
                 (verona-symbol-name
                  (syntax-datum (second (verona-list-elements list))))))
    (is (string= "baz" (verona-symbol-name (syntax-datum (second forms))))))
  ;; Semicolons remain ordinary data inside literals.
  (let ((forms (read-source (make-source "comments.vrn" "\";\" #\\; ; comment"))))
    (is (= 2 (length forms)))
    (is (string= ";" (syntax-datum (first forms))))
    (is (char= #\; (syntax-datum (second forms))))))

(test reads-common-lisp-style-character-literals
  (let ((forms (read-source (make-source "characters.vrn" "#\\a #\\space #\\newline #\\)"))))
    (is (= 4 (length forms)))
    (is (char= #\a (syntax-datum (first forms))))
    (is (char= #\Space (syntax-datum (second forms))))
    (is (char= #\Newline (syntax-datum (third forms))))
    (is (char= #\) (syntax-datum (fourth forms)))))
  (signals verona-read-error
    (read-source (make-source "characters.vrn" "#\\ab")))
  (signals verona-read-error
    (read-source (make-source "characters.vrn" "#\\λ")))
  (signals verona-read-error
    (read-source (make-source "strings.vrn" "\"λ\""))))

(test resolves-character-and-string-literals
  (let* ((unit (compile-string
                (make-compiler)
                "(function letter () char #\\a) (function greeting () (pointer u8) \"hello\")"))
         (program (compilation-unit-semantic-program unit))
         (letter (semantic-program-declaration program (first (unit-declarations unit))))
         (greeting (semantic-program-declaration program (second (unit-declarations unit))))
         (context (semantic-program-type-context program)))
    (is (typep (semantic-function-declaration-body letter) 'character-literal))
    (is (char= #\a (character-literal-value (semantic-function-declaration-body letter))))
    (is (eq (type-context-char-type context)
            (semantic-function-declaration-return-type letter)))
    (is (typep (semantic-function-declaration-body greeting) 'string-literal))))

(test resolves-character-match-patterns
  (let* ((unit (compile-string
                (make-compiler)
                "(function choose ((operator char)) i32 (match operator (#\\+ 1) (_ 0)))\
                 (function c-input ((operator i32)) i32 (match operator (#\\- 1) (_ 0)))"))
         (program (compilation-unit-semantic-program unit))
         (choose (semantic-program-declaration program (first (unit-declarations unit))))
         (c-input (semantic-program-declaration program (second (unit-declarations unit))))
         (choose-pattern (match-case-pattern
                          (first (match-expression-cases (semantic-function-declaration-body choose)))))
         (input-pattern (match-case-pattern
                         (first (match-expression-cases (semantic-function-declaration-body c-input))))))
    (is (typep choose-pattern 'character-pattern))
    (is (typep input-pattern 'integer-pattern))
    (is (eq program (validate-for-backend program)))))

(test reads-nested-lists-with-spans
  (let* ((source (make-source "nested.vrn" (format nil "(foo~%  (bar 10)~%  baz)")))
	 (form (first (read-source source)))
	 (nested (second (verona-list-elements (syntax-datum form)))))
    (is (verona-list-p (syntax-datum form)))
    (is (eq source (syntax-source form)))
    (is (= 1 (source-location-line (syntax-start form))))
    (is (= 1 (source-location-column (syntax-start form))))
    (is (= (length (source-contents source)) (source-location-offset (syntax-end form))))
    (is (= 3 (source-location-line (syntax-end form))))
    (is (= 7 (source-location-column (syntax-end form))))
    (is (= 7 (source-location-offset (syntax-start nested))))
    (is (= 15 (source-location-offset (syntax-end nested))))))

(test rejects-dot-prefixed-floats
  (signals verona-read-error
    (read-source (make-source "invalid.vrn" ".5")))
  (signals verona-read-error
    (read-source (make-source "invalid.vrn" "."))))

(test includes-enabled-platform-feature-conditionals
  (let ((forms (read-source
                (make-source "features.vrn"
                             (format nil "#+darwin (function a () unit unit)~%#-darwin (function a () i32 0)"))
                :features '("darwin"))))
    (is (= 1 (length forms)))
    (is (unit-literal-p
         (syntax-datum (fourth (verona-list-elements (syntax-datum (first forms)))))))))

(test includes-negated-unavailable-platform-conditionals
  (let ((forms (read-source
                (make-source "features.vrn"
                             (format nil "#+darwin (function a () unit unit)~%#-darwin (function a () i32 0)"))
                :features '("linux"))))
    (is (= 1 (length forms)))
    (is (string= "i32" (verona-symbol-name
                          (syntax-datum (fourth (verona-list-elements
                                                  (syntax-datum (first forms))))))))))

(test applies-platform-feature-conditionals-in-lists
  (let* ((form (first (read-source (make-source "features.vrn" "(do #+darwin 1 #-darwin 2)")
                                   :features '("darwin"))))
         (elements (verona-list-elements (syntax-datum form))))
    (is (= 2 (length elements)))
    (is (= 1 (syntax-datum (second elements))))))

(test rejects-feature-conditionals-without-a-name
  (signals verona-read-error
    (read-source (make-source "features.vrn" "#+ (function a () unit unit)"))))

(test retains-multiple-source-forms-in-a-compilation-unit
  (let ((module (compile-string
		 (make-compiler)
		 (format nil "(type Point (product (x f32) (y f32)))~%(function origin () i32 1)")
		 :name "repl.vrn")))
    (is (typep module 'compilation-unit))
    (is (string= "repl.vrn" (source-name (module-source module))))
    (is (= 2 (length (module-forms module))))
    (is (string= "type" (verona-symbol-name
			   (syntax-datum
			    (first (verona-list-elements
				    (syntax-datum (first (module-forms module)))))))))))

(test compiles-a-file-to-a-compilation-unit
  (let* ((pathname #P"/tmp/verona-compilation-unit-test.vrn")
	 (contents "(constant answer i32 42)")
	 (module nil))
    (with-open-file (stream pathname :direction :output :if-exists :supersede)
      (write-string contents stream))
    (setf module (compile-file (make-compiler) pathname))
    (is (search "verona-compilation-unit-test.vrn" (source-name (module-source module))))
    (is (= 1 (length (module-forms module))))))

(test names-are-case-sensitive-and-independent-of-cl-symbols
  (let* ((forms (read-source (make-source "names.vrn" "Foo foo")))
	 (upper (syntax-datum (first forms)))
	 (lower (syntax-datum (second forms))))
    (is (verona-name-p upper))
    (is (not (symbolp upper)))
    (is (string= "Foo" (verona-name-value upper)))
    (is (not (verona-name= upper lower)))
    (is (not (verona-name= (make-verona-name "foo") 'verona/tests::foo)))))

(test resolves-bindings-through-lexical-environments
  (let* ((global (make-environment))
	 (child (environment-child global))
	 (name (make-verona-name "answer")))
    (environment-bind global name 42)
    (is (= 42 (environment-lookup child (make-verona-name "answer"))))
    (environment-bind child (make-verona-name "answer") 7)
    (is (= 7 (environment-lookup child name)))
    (is (= 42 (environment-lookup global name)))
    (signals unbound-name-error
      (environment-lookup child (make-verona-name "missing")))))

(test evaluates-literals-names-and-nested-calls
  (let* ((environment (make-bootstrap-environment))
	 (forms (read-source (make-source "evaluate.vrn" "10 (+ 1 (+ 2 3))"))))
    (is (= 10 (evaluate (first forms) environment)))
    (is (= 6 (evaluate (second forms) environment)))))

(test expands-macros-with-unevaluated-syntax-and-recursion
  (let* ((environment (make-environment))
	 (received nil)
	 (forms (read-source (make-source "macro.vrn" "(example foo 42)"))))
    (environment-bind
     environment (make-verona-name "example")
     (make-verona-macro
      (lambda (&rest arguments)
	(setf received arguments)
	(let ((head (syntax-with-datum (first arguments)
				       (make-verona-name "intermediate"))))
	  (syntax-with-datum (first arguments)
			     (apply #'make-verona-list head arguments))))))
    (environment-bind
     environment (make-verona-name "intermediate")
     (make-verona-macro
      (lambda (&rest arguments)
	(let ((head (syntax-with-datum (first arguments)
				       (make-verona-name "%test-definition"))))
	  (syntax-with-datum (first arguments)
			     (apply #'make-verona-list head arguments))))))
    (let* ((expanded (expand (first forms) environment))
	   (elements (verona-list-elements (syntax-datum expanded))))
      (is (= 2 (length received)))
      (is (verona-name-p (syntax-datum (first received))))
      (is (string= "foo" (verona-name-value (syntax-datum (first received)))))
      (is (string= "%test-definition"
		   (verona-name-value (syntax-datum (first elements)))))
      (is (string= "foo" (verona-name-value (syntax-datum (second elements))))))))

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

(test registers-macros-sequentially-in-the-compile-time-environment
  ;; X evaluates to the original, unevaluated syntax argument, making this a
  ;; minimal executable macro body without defining surface macro syntax yet.
  (let* ((module (compile-string
		  (make-compiler)
		  "(%macro identity (x) x) (identity (%type Later i32))"
		  :name "macros.vrn"))
	 (declarations (module-declarations module))
	 (macro (first declarations))
	 (type (second declarations)))
    (is (= 2 (length declarations)))
    (is (typep macro 'macro-declaration))
    (is (verona-macro-p
	 (environment-lookup (module-environment module)
			     (make-verona-name "identity"))))
    (is (string= "Later" (verona-name-value (declaration-name type))))))

(test bootstraps-the-public-definition-vocabulary-as-macros
  (let ((environment (make-bootstrap-environment)))
    (dolist (name '("type" "function" "macro" "constant" "variable" "generic" "implementation"))
      (is (verona-macro-p
	   (environment-lookup environment (make-verona-name name)))))))

(test bootstrap-definition-macros-emit-named-clauses
  (let ((environment (make-bootstrap-environment)))
	    (dolist (specification '(("type Point i32" "%type" (":type"))
			     ("function add ((value i32)) i32 value" "%function"
                                      (":type" ":implementation"))
			     ("external-function c-abs \"abs\" (i32) i32" "%external-function"
                                      (":type" ":external-name"))
			     ("macro identity (form) form" "%macro"
                                      (":parameters" ":implementation"))
			     ("constant answer i32 42" "%constant" (":type" ":implementation"))
			     ("variable counter i32 0" "%variable" (":type" ":implementation"))
                             ("generic choose (value)" "%generic" (":parameters"))
                             ("protocol measurement (a) (measure ((value a)) i32)" "%protocol"
                              (":parameters" ":operations"))
                             ("implementation choose ((value i32)) i32 value" "%implementation"
                              (":generic" ":type" ":implementation"))
                             ("implementation (measurement i32) (function measure ((value i32)) i32 value)"
                              "%implementation" (":protocol" ":operations"))))
      (let* ((form (first (read-source
			   (make-source "expansion.vrn"
					(format nil "(~A)" (first specification))))))
	     (expanded (expand form environment))
	     (expanded-elements (verona-list-elements (syntax-datum expanded)))
             (clauses (if (string= (second specification) "%implementation")
                          (rest expanded-elements)
                          (cddr expanded-elements))))
	(is (string= (second specification)
		     (verona-name-value (syntax-datum (first expanded-elements)))))
	(is (equal (third specification)
                   (mapcar (lambda (clause)
                             (verona-name-value
                              (syntax-datum
                               (first (verona-list-elements (syntax-datum clause))))))
                           clauses)))))))

(test compiles-surface-definition-macros-without-interpreting-their-content
  (let* ((contents
	   (format nil "(type Point (product (x f64) (y f64)))~%\
 (constant pi f64 3.141592653589793)~%\
 (variable counter u64 0)~%\
 (function calculate ((x i32)) i32 (+ x 1))"))
	 (module (compile-string (make-compiler) contents
				 :name "surface-definitions.vrn"))
	 (declarations (module-declarations module))
	 (function (fourth declarations)))
    (is (= 4 (length declarations)))
    (is (typep (first declarations) 'type-declaration))
    (is (typep (second declarations) 'constant-declaration))
    (is (typep (third declarations) 'variable-declaration))
    (is (typep function 'function-declaration))
    ;; The declaration remains raw syntax even though the resolver also builds a
    ;; separate resolved semantic body.
    (let* ((body (function-declaration-body function))
	   (head (first (verona-list-elements (syntax-datum body)))))
      (is (string= "+"
		   (verona-name-value (syntax-datum head)))))))

(test makes-user-macros-available-after-the-surface-macro-declaration
  (let* ((module (compile-string
		  (make-compiler)
		  "(macro identity (x) x) (identity (type Later (product (value i32))))"
		  :name "surface-macros.vrn"))
	 (declarations (module-declarations module))
	 (macro (first declarations))
	 (type (second declarations)))
    (is (= 2 (length declarations)))
    (is (typep macro 'macro-declaration))
    (is (verona-macro-p
	 (environment-lookup (module-environment module)
			     (make-verona-name "identity"))))
    (is (typep type 'type-declaration))
    (is (string= "Later" (verona-name-value (declaration-name type))))))

(test retains-original-and-expanded-declaration-syntax
  (let* ((module (compile-string
		  (make-compiler)
		  "(macro identity (x) x) (identity (type Later (product (value i32))))"
		  :name "expanded.vrn"))
	 (source (second (module-forms module)))
	 (declaration (second (unit-declarations module)))
	 (expanded (declaration-expanded-syntax declaration)))
    (is (eq source (declaration-source declaration)))
    (is (not (eq source expanded)))
    (is (string= "identity"
		 (verona-name-value
		  (syntax-datum (first (verona-list-elements (syntax-datum source)))))))
    (is (string= "%type"
		 (verona-name-value
		  (syntax-datum (first (verona-list-elements (syntax-datum expanded)))))))))

(test permits-forward-references-and-uses-the-compilation-unit-namespace
  (let* ((module (compile-string
		  (make-compiler)
		  "(function first () i32 (second)) (function second () i32 42)"))
	 (first (first (unit-declarations module)))
	 (second (second (unit-declarations module))))
    (is (= 2 (length (unit-declarations module))))
    (is (eq first (find-declaration module (make-verona-name "first"))))
    (is (eq second (find-declaration module (make-verona-name "second"))))))

(test allows-a-macro-to-generate-multiple-definitions
  (let* ((module (compile-string
		  (make-compiler)
		  "(macro make-pair (left right) (definitions left right))\
		   (make-pair (constant first i32 1) (constant second i32 2))"))
	 (declarations (unit-declarations module)))
    (is (= 3 (length declarations)))
    (is (every (lambda (declaration)
		 (typep declaration 'constant-declaration))
	       (rest declarations)))
    (is (equal '("make-pair" "first" "second")
	       (mapcar (lambda (declaration)
			 (verona-name-value (declaration-name declaration)))
		       declarations)))))

(test macro-generated-macros-affect-following-source-forms
  (let* ((module (compile-string
		  (make-compiler)
		  "(macro define-identity (definition) definition)\
		   (define-identity (%macro identity (x) x))\
		   (identity (constant answer i32 42))"))
	 (declarations (unit-declarations module)))
    (is (= 3 (length declarations)))
    (is (typep (first declarations) 'macro-declaration))
    (is (typep (second declarations) 'macro-declaration))
    (is (typep (third declarations) 'constant-declaration))))

(test rejects-non-definition-top-level-expansion
  (signals non-definition-top-level-error
    (compile-string (make-compiler) "(+ 1 2)")))

(test surface-definition-forms-are-not-compiler-primitives
  (let* ((forms (read-source (make-source "boundary.vrn"
					  "(function foo () i32 1) (%function foo () i32 1)")))
	 (empty-environment (make-environment)))
    (is (eq (first forms) (expand (first forms) empty-environment)))
    (is (eq (second forms) (expand (second forms) empty-environment)))
    (is (= 1 (length (module-declarations
		      (compile-string (make-compiler) "(%function foo () i32 1)")))))))

(test rejects-duplicate-declarations-across-kinds
  (signals duplicate-declaration-error
    (compile-string (make-compiler)
		    "(%function value () i32 1) (%variable value i32 0)")))

(test duplicate-definition-diagnostic-includes-both-locations
  (let ((condition
	  (handler-case
	      (compile-string (make-compiler)
			      (format nil "(constant answer i32 1)~%(variable answer i32 0)")
			      :name "duplicates.vrn")
	    (duplicate-declaration-error (condition) condition))))
    (is (not (null condition)))
    (let ((message (format nil "~A" condition)))
      (is (search "duplicates.vrn:2:1: duplicate definition `answer`" message))
      (is (search "previous definition:" message))
      (is (search "duplicates.vrn:1:1" message)))))

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

(test reports-unresolved-runtime-names-and-duplicate-parameters
  (signals unresolved-name-error
    (compile-string (make-compiler) "(function foo () i32 unknown)"))
  (signals unresolved-name-error
    ;; The macro is available only to expansion, not to semantic lookup.
    (compile-string (make-compiler)
                    "(macro compile-only () 0) (function foo () i32 compile-only)"))
  (signals duplicate-local-binding-error
    (compile-string (make-compiler)
                    "(function foo ((x i32) (x i32)) i32 x)")))

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

(test rejects-type-alias-cycles-and-implicit-product-syntax
  (signals type-alias-cycle-error
    (compile-string (make-compiler) "(type left right) (type right left)"))
  (signals recursive-type-not-supported-error
    (compile-string (make-compiler)
                    "(type node-link (pointer node))
                     (type node (product (next node-link)))"))
  (signals verona:definition-error
    (compile-string (make-compiler) "(type point (x i64))"))
  (signals verona:definition-error
    (compile-string (make-compiler) "(type point ((x i64)))")))

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

(test diagnoses-type-mismatches-and-invalid-places
  (signals type-mismatch-error
    (compile-string (make-compiler) "(function wrong () i32 false)"))
  (signals not-writable-error
    (compile-string (make-compiler)
                    "(constant answer i32 42) (function change () unit (assign answer 1))"))
  (signals not-addressable-error
    (compile-string (make-compiler)
                    "(function address () (pointer i32) (& (+ 1 2)))")))

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

(test enforces-exact-primitive-types-and-explicit-memory-reads
  (signals type-mismatch-error
    (compile-string (make-compiler)
                    "(function wrong ((value i32)) i64 (%+-primitive-i64 value 1))"))
  (let* ((unit (compile-string
		(make-compiler)
		"(function read ((address (pointer i64))) i64 (load (dereference address)))\
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

(test resolves-match-patterns-scopes-and-never
  (let* ((unit (compile-string
		(make-compiler)
		"(function choose ((enabled bool) (x i64)) i64 (match enabled (true x) (false 0)))\
                 (function identity ((value i64)) i64 (match value (bound bound)))\
                 (function early ((enabled bool)) i64 (match enabled (true (return 10)) (false 20)))"))
	 (program (compilation-unit-semantic-program unit))
	 (choose (semantic-program-declaration program (first (unit-declarations unit))))
	 (identity (semantic-program-declaration program (second (unit-declarations unit))))
	 (early (semantic-program-declaration program (third (unit-declarations unit))))
	 (choose-body (semantic-function-declaration-body choose))
	 (identity-body (semantic-function-declaration-body identity))
	 (early-body (semantic-function-declaration-body early)))
    (is (typep choose-body 'match-expression))
    (is (typep (match-case-pattern (first (match-expression-cases choose-body))) 'boolean-pattern))
    (is (typep (match-case-pattern (second (match-expression-cases choose-body))) 'boolean-pattern))
    (is (typep (match-case-pattern (first (match-expression-cases identity-body))) 'binding-pattern))
    (is (typep (binding-pattern-binding
		(match-case-pattern (first (match-expression-cases identity-body)))) 'pattern-binding))
    (is (typep (match-case-expression (first (match-expression-cases early-body)))
	       'return-expression))
    (is (typep (semantic-expression-type
		(match-case-expression (first (match-expression-cases early-body)))) 'never-type))
    (is (eq program (validate-for-backend program)))))

(test diagnoses-match-exhaustiveness-reachability-and-termination
  (signals non-exhaustive-match-error
    (compile-string (make-compiler) "(function bad ((x bool)) i64 (match x (true 1)))"))
  (signals non-exhaustive-match-error
    (compile-string (make-compiler) "(function bad ((x i64)) i64 (match x (0 1) (1 2)))"))
  (signals unreachable-pattern-error
    (compile-string (make-compiler) "(function bad ((x i64)) i64 (match x (_ 1) (0 2)))"))
  (signals unreachable-pattern-error
    (compile-string (make-compiler) "(function bad ((x bool)) i64 (match x (true 1) (true 2) (false 3)))"))
  (signals unreachable-expression-error
    (compile-string (make-compiler) "(function bad () i64 (do (return 1) 2))")))

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

(test rejects-invalid-fixed-array-construction-and-indexing
  (signals verona:cannot-infer-array-element-type-error
    (compile-string (make-compiler) "(function bad () unit (do (array-of) unit))"))
  (signals verona:array-index-out-of-bounds-error
    (compile-string (make-compiler)
                    "(function bad () i32 (index (array-of 1 2) 2))"))
  (signals error
    (compile-string (make-compiler)
                    "(function bad () (array void 1) (array-of unit))")))

(test rejects-invalid-product-definitions-construction-and-fields
  (signals duplicate-field-error
    (compile-string (make-compiler) "(type point (product (x i64) (x i64)))"))
  (signals recursive-type-not-supported-error
    (compile-string (make-compiler) "(type node (product (next (pointer node))))"))
  (signals wrong-argument-count-error
    (compile-string (make-compiler)
                    "(type point (product (x i64) (y i64))) (function main () i64 (field (point 20) x))"))
  (signals unknown-field-error
    (compile-string (make-compiler)
                    "(type point (product (x i64))) (function main () i64 (field (point 20) z))"))
  (signals field-access-requires-product-error
    (compile-string (make-compiler) "(function main () i64 (field 42 x))"))
  (signals type-mismatch-error
    (compile-string (make-compiler)
                    "(type point (product (x i64))) (type size (product (x i64)))
                     (function consume ((value size)) i64 0)
                     (function main () i64 (consume (point 42)))")))

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

(test diagnoses-invalid-sum-types-construction-and-matches
  (signals duplicate-alternative-error
    (compile-string (make-compiler) "(type bad (sum (ok i64) (ok f64)))"))
  (signals recursive-type-not-supported-error
    (compile-string (make-compiler) "(type list (sum (empty) (node (pointer list))))"))
  (signals wrong-argument-count-error
    (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main () option (some))"))
  (signals non-exhaustive-match-error
    (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main ((value option)) i64 (match value ((some x) x)))"))
  (signals unreachable-pattern-error
    (compile-string (make-compiler)
                    "(type option (sum (none) (some i64)))
                     (function main ((value option)) i64
                       (match value ((none) 0) ((none) 1) ((some x) x)))"))
  ;; A literal payload pattern is partial; the following binding completes it.
  (compile-string (make-compiler)
                  "(type option (sum (none) (some i64)))
                   (function main ((value option)) i64
                     (match value ((some 0) 10) ((some x) x) ((none) 0)))"))

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

(defun run-tests ()
  (run! :verona))
