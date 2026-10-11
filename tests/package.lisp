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
		#:character-integer-conversion-expression
		#:character-integer-conversion-expression-operand
		#:primitive-operation #:primitive-operation-kind #:primitive-operation-parameter-types
		#:primitive-operation-result-type #:primitive-operation-nan-semantics
		#:integer-literal #:integer-literal-value #:boolean-literal #:character-literal #:character-literal-value #:string-literal
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
		#:no-generic-implementation-error #:ambiguous-generic-implementation-error
		#:validate-for-backend))
