(in-package #:verona)

;;; This file is the syntax-to-semantics boundary.  It first records binding
;;; identity, then turns executable syntax into typed runtime expressions.

(defclass builtin-binding (semantic-binding) ())
(defclass builtin-type-binding (builtin-binding)
  ((type :initarg :type :reader builtin-type-binding-type)))
;; Builtins are declarations/entities in the semantic namespace, but unlike
;; source TYPE-DECLARATIONs they have no source form to retain.
(defclass builtin-type-declaration (builtin-type-binding) ())

;;; Types are compiler semantics, deliberately independent from any lowering
;;; target.  In particular, BOOLEAN-TYPE does not imply an LLVM integer type.
(defclass verona-type () ())

(defclass unit-type (verona-type) ())
(defclass void-type (verona-type) ())
(defclass never-type (verona-type) ())
;; UNIT-VALUE is deliberately an object rather than the host value NIL.  A
;; type context allocates exactly one of these objects, making the singleton
;; nature of Verona unit visible to later compiler stages without conflating it
;; with void or an integer zero.
(defclass unit-value () ())
(defclass boolean-type (verona-type) ())
(defclass char-type (verona-type) ())
(defclass integer-type (verona-type)
  ((signed :initarg :signed :reader integer-type-signed)
   (width :initarg :width :reader integer-type-width)))
(defclass float-type (verona-type)
  ((width :initarg :width :reader float-type-width)))
(defclass pointer-type (verona-type)
  ((target :initarg :target :reader pointer-type-target :reader pointer-type-pointee)))
(defclass array-type (verona-type)
  ((element-type :initarg :element-type :reader array-type-element-type)
   (length :initarg :length :reader array-type-length)))
(defclass function-type (verona-type)
  ((parameters :initarg :parameters :reader function-type-parameters)
   (result :initarg :result :reader function-type-result)))
(defclass defined-type (verona-type)
  ((declaration :initarg :declaration :reader defined-type-declaration)))

;; Opaque types name values owned by another ABI.  They intentionally have no
;; Verona layout and can therefore be used only behind a pointer.
(defclass opaque-type (defined-type) ())

;; Type parameters are semantic identities.  They are intentionally types in
;; their own right rather than source names, which keeps independently bound
;; `a`s distinct and makes substitution structural instead of textual.
(defclass type-parameter (verona-type semantic-binding)
  ((declaration :initarg :declaration :reader type-parameter-declaration)
   (index :initarg :index :reader type-parameter-index)
   (source :initarg :source :reader type-parameter-source)))

(defclass type-substitution ()
  ((entries :initarg :entries :initform '() :accessor type-substitution-entries)))

(defun make-type-substitution (&optional entries)
  (make-instance 'type-substitution :entries entries))

(defun type-substitution-find (substitution parameter)
  (cdr (assoc parameter (type-substitution-entries substitution) :test #'eq)))

(defun type-substitution-bind (substitution parameter type)
  (let ((entry (assoc parameter (type-substitution-entries substitution) :test #'eq)))
    (if entry (setf (cdr entry) type)
        (push (cons parameter type) (type-substitution-entries substitution)))
    type))

;; A product retains its declaration identity through DEFINED-TYPE while also
;; carrying the complete, ordered value layout needed by later stages.
(defclass product-type (defined-type)
  ((fields :initarg :fields :reader product-type-fields)))

;; Sums, like products, are nominal through their TypeDeclaration.  Their
;; alternatives are semantic entities; a backend never has to recover them
;; from source spellings.
(defclass sum-type (defined-type)
  ((alternatives :initarg :alternatives :reader sum-type-alternatives)))

(defclass sum-alternative ()
  ((sum-type :initarg :sum-type :reader sum-alternative-sum-type)
   (name :initarg :name :reader sum-alternative-name)
   (index :initarg :index :reader sum-alternative-index)
   (payload-types :initarg :payload-types :reader sum-alternative-payload-types)
   (source :initarg :source :reader sum-alternative-source)))

(defclass product-field ()
  ((name :initarg :name :reader product-field-name)
   (type :initarg :type :reader product-field-type)
   (index :initarg :index :reader product-field-index)
   (source :initarg :source :reader product-field-source)))

(defclass type-context ()
  ((unit-type :reader type-context-unit-type)
   (void-type :reader type-context-void-type)
   (never-type :reader type-context-never-type)
   (unit-value :reader type-context-unit-value)
   (pointer-width :initarg :pointer-width :reader type-context-pointer-width)
   (boolean-type :reader type-context-boolean-type)
   (char-type :reader type-context-char-type)
   ;; C's `int` is the platform process-exit representation.  It is distinct
   ;; from pointer-sized ISIZE and remains a signed 32-bit integer on the
   ;; targets Verona currently supports.
   (c-int-type :reader type-context-c-int-type)
   (integer-types :initform '() :accessor type-context-integer-types)
   (float-types :initform '() :accessor type-context-float-types)
   (pointer-types :initform '() :accessor type-context-pointer-types)
   (array-types :initform '() :accessor type-context-array-types)
   (function-types :initform '() :accessor type-context-function-types)
   ;; This association uses declaration object identity, never its spelling.
   (defined-types :initform '() :accessor type-context-defined-types)))

(defun make-type-context (&key (pointer-width 64))
  "Create the canonical Verona types for one semantic program."
  (unless (member pointer-width '(32 64))
    (error "Verona currently supports 32-bit and 64-bit pointer targets, not ~S"
           pointer-width))
  (let ((context (make-instance 'type-context)))
    (setf (slot-value context 'unit-type) (make-instance 'unit-type)
	  (slot-value context 'void-type) (make-instance 'void-type)
	  (slot-value context 'never-type) (make-instance 'never-type)
	  (slot-value context 'unit-value) (make-instance 'unit-value)
	  (slot-value context 'pointer-width) pointer-width
	  (slot-value context 'boolean-type) (make-instance 'boolean-type)
	  (slot-value context 'char-type) (make-instance 'char-type))
    (dolist (specification '((t 8) (t 16) (t 32) (t 64)
			     (nil 8) (nil 16) (nil 32) (nil 64)))
      (destructuring-bind (signed width) specification
	(push (cons (cons signed width)
		    (make-instance 'integer-type :signed signed :width width))
	      (type-context-integer-types context))))
    (setf (slot-value context 'c-int-type)
          (type-context-integer-type context t 32))
    (dolist (width '(32 64))
      (push (cons width (make-instance 'float-type :width width))
	    (type-context-float-types context)))
    context))

(defun type-context-unit-representation-type (context)
  "The target-dependent machine representation of semantic UnitType.

This is intentionally an IntegerType only at the representation boundary;
the semantic type of a unit expression remains UnitType."
  (check-type context type-context)
  (type-context-integer-type context nil (type-context-pointer-width context)))

(defun unit-machine-representation (context value)
  "Return the canonical machine representation for VALUE, the sole UnitValue."
  (check-type context type-context)
  (unless (eq value (type-context-unit-value context))
    (error "not this type context's UnitValue"))
  0)

(defun type-context-integer-type (context signed width)
  (or (cdr (assoc (cons signed width) (type-context-integer-types context)
		  :test #'equal))
      (error "No builtin integer type with signedness ~S and width ~S" signed width)))

(defun type-context-float-type (context width)
  (or (cdr (assoc width (type-context-float-types context)))
      (error "No builtin float type with width ~S" width)))

(defun type-context-pointer-type (context target)
  "Return the canonical pointer-to-TARGET type in CONTEXT."
  (check-type target verona-type)
  (or (cdr (assoc target (type-context-pointer-types context) :test #'eq))
      (let ((type (make-instance 'pointer-type :target target)))
	(push (cons target type) (type-context-pointer-types context))
	type)))

(defun type-context-array-type (context element-type length)
  "Return the canonical fixed array type for ELEMENT-TYPE and LENGTH."
  (check-type element-type verona-type)
  (unless (and (integerp length) (<= 0 length))
    (error "array length must be a non-negative integer, not ~S" length))
  (let ((key (cons element-type length)))
    (or (cdr (assoc key (type-context-array-types context) :test #'equal))
        (let ((type (make-instance 'array-type :element-type element-type :length length)))
          (push (cons key type) (type-context-array-types context))
          type))))

(defun type-context-function-type (context parameters result)
  "Return the canonical function type with PARAMETERS and RESULT in CONTEXT."
  (dolist (parameter parameters)
    (check-type parameter verona-type))
  (check-type result verona-type)
  (let ((key (cons parameters result)))
    (or (cdr (assoc key (type-context-function-types context) :test #'equal))
	(let ((type (make-instance 'function-type
				   :parameters parameters :result result)))
	  (push (cons key type) (type-context-function-types context))
	  type))))

(defun type-context-defined-type (context declaration)
  "Return DECLARATION's nominal type, creating its identity at most once."
  (or (cdr (assoc declaration (type-context-defined-types context) :test #'eq))
      (let ((type (make-instance 'defined-type :declaration declaration)))
	(push (cons declaration type) (type-context-defined-types context))
	type)))

(defun type-context-opaque-type (context declaration)
  "Return DECLARATION's nominal incomplete type, creating it at most once."
  (or (cdr (assoc declaration (type-context-defined-types context) :test #'eq))
      (let ((type (make-instance 'opaque-type :declaration declaration)))
	(push (cons declaration type) (type-context-defined-types context))
	type)))

(defun type-context-product-type (context declaration fields)
  "Install DECLARATION's complete nominal product type exactly once."
  (or (cdr (assoc declaration (type-context-defined-types context) :test #'eq))
      (let ((type (make-instance 'product-type :declaration declaration :fields fields)))
	(push (cons declaration type) (type-context-defined-types context))
	type)))

(defun type-context-sum-type (context declaration alternatives)
  "Install DECLARATION's complete nominal sum type exactly once."
  (or (cdr (assoc declaration (type-context-defined-types context) :test #'eq))
      (let ((type (make-instance 'sum-type :declaration declaration
                                 :alternatives alternatives)))
	(push (cons declaration type) (type-context-defined-types context))
	type)))

;;; Concrete primitive operations -----------------------------------------

;; A primitive operation is a Verona semantic entity.  Its KIND is the
;; complete operation selection the LLVM backend will later translate; it is
;; never reconstructed from NAME or from operand types.
(defclass primitive-operation ()
  ((identity :initarg :identity :initform (gensym "PRIMITIVE-")
	     :reader primitive-operation-identity)
   (name :initarg :name :reader primitive-operation-name)
   (parameter-types :initarg :parameter-types
		    :reader primitive-operation-parameter-types)
   (result-type :initarg :result-type :reader primitive-operation-result-type)
   (kind :initarg :kind :reader primitive-operation-kind)
   ;; Floating comparisons are explicitly ordered: any NaN operand yields
   ;; false, including for equality.  This is semantic policy, not an LLVM
   ;; default the backend is allowed to choose.
   (nan-semantics :initarg :nan-semantics :initform nil
		  :reader primitive-operation-nan-semantics)))

(defclass primitive-binding (builtin-binding)
  ((operation :initarg :operation :reader primitive-binding-operation)
   (context :initarg :context :reader primitive-binding-context)))

;; Keep the previous public class operational for clients from the preceding
;; milestone.  It is now a primitive binding, so even legacy '+' resolves to
;; an operation identity rather than a backend-facing textual convention.
(defclass builtin-intrinsic-binding (primitive-binding) ())

(defun builtin-intrinsic-binding-type (binding)
  (type-context-function-type
   (primitive-operation-context binding)
   (primitive-operation-parameter-types (primitive-binding-operation binding))
   (primitive-operation-result-type (primitive-binding-operation binding))))

;; The operation already owns canonical type objects.  Recover their context
;; through a compact association on the binding so compatibility callers can
;; still ask for its FunctionType.
(defgeneric primitive-operation-context (binding))
(defmethod primitive-operation-context ((binding primitive-binding))
  (primitive-binding-context binding))

;;; Compile-time generic dispatch -----------------------------------------

(defclass generic ()
  ((declaration :initarg :declaration :initform nil :reader generic-declaration)
   (name :initarg :name :reader generic-name)
   (arity :initarg :arity :reader generic-arity)
   ;; Keys are lists of canonical VERONA-TYPE objects.  EQUAL is intentional:
   ;; standard objects compare by identity, never by their printed spelling.
   (implementations :initform '() :accessor generic-implementations)))

(defclass generic-binding (semantic-binding)
  ((generic :initarg :generic :reader generic-binding-generic)))

(defclass generic-implementation ()
  ((declaration :initarg :declaration :initform nil
                :reader generic-implementation-declaration)
   (generic :initarg :generic :reader generic-implementation-generic)
   (parameters :initarg :parameters :initform '()
               :accessor generic-implementation-parameters)
   (parameter-types :initarg :parameter-types :initform '()
                    :accessor generic-implementation-parameter-types)
   (result-type :initarg :result-type :initform nil
                :accessor generic-implementation-result-type)
   (body :initarg :body :initform nil :accessor generic-implementation-body)
   (primitive-operation :initarg :primitive-operation :initform nil
                        :reader generic-implementation-primitive-operation)
   (source :initarg :source :initform nil :reader generic-implementation-source)))

(defun generic-find-implementation (generic parameter-types)
  (cdr (assoc parameter-types (generic-implementations generic) :test #'equal)))

(defun generic-add-implementation (generic implementation &optional syntax)
  (let ((key (generic-implementation-parameter-types implementation)))
    (when (generic-find-implementation generic key)
      (error 'duplicate-generic-implementation-error :syntax syntax
             :generic generic :parameter-types key
             :original (generic-find-implementation generic key)
             :duplicate implementation
             :original-source (generic-implementation-source
                               (generic-find-implementation generic key))
             :duplicate-source syntax))
    (push (cons key implementation) (generic-implementations generic))
    implementation))

(defun make-primitive-binding (context name parameter-types result-type kind
				     &key nan-semantics class)
  (let* ((operation (make-instance 'primitive-operation
					  :name (make-verona-name name)
					  :parameter-types parameter-types
					  :result-type result-type :kind kind
					  :nan-semantics nan-semantics))
	 (binding (make-instance (or class 'primitive-binding)
				 :name (primitive-operation-name operation)
				 :operation operation :context context)))
    ;; CONTEXT is not semantic operation state; it only preserves the legacy
    ;; builtin-intrinsic-binding-type accessor.
    binding))

;;; These nodes retain the resolved structure of compound type syntax until
;;; the type pass turns them into VERONA-TYPE objects.  A bare type name stays
;;; a SEMANTIC-REFERENCE, preserving the established representation and API.
(defclass semantic-type-syntax ()
  ((syntax :initarg :syntax :reader semantic-type-syntax-syntax)))
(defclass semantic-unit-type-syntax (semantic-type-syntax) ())
(defclass semantic-pointer-type-syntax (semantic-type-syntax)
  ((target :initarg :target :reader semantic-pointer-type-syntax-target)))
(defclass semantic-array-type-syntax (semantic-type-syntax)
  ((element-type :initarg :element-type :reader semantic-array-type-syntax-element-type)
   (length :initarg :length :reader semantic-array-type-syntax-length)))

(defclass for-clause ()
  ((syntax :initarg :syntax :reader for-clause-syntax)
   (type-parameters :initarg :type-parameters :initform '()
                    :reader for-clause-type-parameters)
   (constraint-syntaxes :initarg :constraint-syntaxes :initform '()
                        :reader for-clause-constraint-syntaxes)))

(defclass protocol ()
  ((declaration :initarg :declaration :reader protocol-declaration)
   (name :initarg :name :reader protocol-name)
   (type-parameters :initarg :type-parameters :initform '()
                    :accessor protocol-type-parameters)
   (operations :initarg :operations :initform '() :accessor protocol-operations)
   (implementations :initform '() :accessor protocol-implementations)))

(defclass protocol-binding (semantic-binding)
  ((protocol :initarg :protocol :reader protocol-binding-protocol)))

(defclass protocol-operation ()
  ((protocol :initarg :protocol :reader protocol-operation-protocol)
   (name :initarg :name :reader protocol-operation-name)
   (parameters :initarg :parameters :reader protocol-operation-parameters)
   (result-type :initarg :result-type :reader protocol-operation-result-type)
   (source :initarg :source :reader protocol-operation-source)))

(defclass protocol-constraint ()
  ((protocol :initarg :protocol :reader protocol-constraint-protocol)
   (arguments :initarg :arguments :reader protocol-constraint-arguments)
   (source :initarg :source :reader protocol-constraint-source)))

(defclass protocol-implementation ()
  ((protocol :initarg :protocol :reader protocol-implementation-protocol)
   (arguments :initarg :arguments :reader protocol-implementation-arguments)
   (operations :initarg :operations :initform '()
               :accessor protocol-implementation-operations)
   (source :initarg :source :reader protocol-implementation-source)))

(defun protocol-implementation-find-operation (implementation operation)
  (cdr (assoc operation (protocol-implementation-operations implementation) :test #'eq)))

(defclass parameter-binding (semantic-binding)
  ((syntax :initarg :syntax :reader parameter-binding-syntax)
   (type-syntax :initarg :type-syntax :reader parameter-binding-type-syntax)
   (type-reference :initform nil :accessor parameter-binding-type-reference)
   (type :initform nil :accessor parameter-binding-type)))

(defclass pattern-binding (semantic-binding)
  ((syntax :initarg :syntax :reader pattern-binding-syntax)
   (type :initarg :type :reader pattern-binding-type)))

;; A LET-BINDING is an immutable semantic identity.  It is nevertheless
;; addressable: taking its address materializes stable local storage in the
;; backend.  Its initializer is resolved before the binding enters its
;; lexical scope.
(defclass let-binding (semantic-binding)
  ((syntax :initarg :syntax :reader let-binding-syntax :reader let-binding-source)
   (type-syntax :initarg :type-syntax :reader let-binding-type-syntax)
   (type-reference :initarg :type-reference :reader let-binding-type-reference)
   (type :initarg :type :reader let-binding-type)
   (initializer :initarg :initializer :reader let-binding-initializer)))

(defclass semantic-program ()
  ((bootstrap-scope :initarg :bootstrap-scope
                    :reader semantic-program-bootstrap-scope)
   (module-scope :initarg :module-scope :reader semantic-program-module-scope)
   (type-context :initarg :type-context :reader semantic-program-type-context)
   ;; Entries map source declarations to their resolved counterpart.  Macro
   ;; declarations deliberately have no entry: they belong to expansion.
   (declarations :initform '() :accessor semantic-program-declarations)
   (entry-module :initarg :entry-module :initform nil :reader program-entry-module)
   (modules :initarg :modules :initform '() :reader program-modules)
   (module-graph :initarg :module-graph :initform nil :reader program-module-graph)
   (target :initarg :target :initform nil :reader program-target)
   (native-exports :initform '() :accessor semantic-program-native-exports)
   (module-scopes :initform '() :accessor semantic-program-module-scopes)
   ;; Concrete instances are not source declarations: they are generated from
   ;; a polymorphic template and are the only representation sent to LLVM.
   (function-specializations :initform '()
                             :accessor semantic-program-function-specializations)))

;; PROGRAM is the multi-module semantic root.  It remains a SemanticProgram so
;; existing lowering clients continue to accept the returned object.
(defclass program (semantic-program) ())

(defclass native-export-binding ()
  ((function :initarg :function :reader native-export-binding-function)
   (external-name :initarg :external-name :reader native-export-binding-external-name)
   (source :initarg :source :reader native-export-binding-source)))

(defun semantic-program-module-scope-for (program module)
  (or (cdr (assoc module (semantic-program-module-scopes program) :test #'eq))
      (error "no semantic scope for module ~S" module)))

(defun semantic-scope-owning-module (scope)
  (loop for current = scope then (semantic-scope-parent current)
        while current
        for module = (semantic-scope-module current)
        when module return module))

(defclass semantic-declaration ()
  ((source-declaration :initarg :source-declaration
                       :reader semantic-declaration-source-declaration)))

(defclass semantic-type-declaration (semantic-declaration)
  ((type :initform nil :accessor semantic-type-declaration-type)
   (fields :initform '() :accessor semantic-type-declaration-fields)
   (alternatives :initform '() :accessor semantic-type-declaration-alternatives)))

(defclass semantic-type-alias-declaration (semantic-declaration)
  ((target-reference :initform nil
                     :accessor semantic-type-alias-declaration-target-reference)
   (target-type :initform nil
                :accessor semantic-type-alias-declaration-target-type)
   ;; This state permits forward chains while diagnosing cycles directly.
   (state :initform :unresolved :accessor semantic-type-alias-declaration-state)))

(defclass type-alias-binding (semantic-binding)
  ((declaration :initarg :declaration :reader type-alias-binding-declaration)
   (semantic-declaration :initarg :semantic-declaration
                         :reader type-alias-binding-semantic-declaration)))

(defun type-alias-binding-type (binding)
  (semantic-type-alias-declaration-target-type
   (type-alias-binding-semantic-declaration binding)))

(defclass semantic-constant-declaration (semantic-declaration)
  ((type-reference :initform nil
                   :accessor semantic-constant-declaration-type-reference)
   (type :initform nil :accessor semantic-constant-declaration-type)
   (initializer :initform nil
                :accessor semantic-constant-declaration-initializer)))

(defclass semantic-variable-declaration (semantic-declaration)
  ((type-reference :initform nil
                   :accessor semantic-variable-declaration-type-reference)
   (type :initform nil :accessor semantic-variable-declaration-type)
   (initializer :initform nil
                :accessor semantic-variable-declaration-initializer)))

(defclass semantic-function-declaration (semantic-declaration)
  ((scope :initform nil :accessor semantic-function-declaration-scope)
   (type-parameters :initform '()
                    :accessor semantic-function-declaration-type-parameters)
   (constraints :initform '() :accessor semantic-function-declaration-constraints)
   (parameters :initform '() :accessor semantic-function-declaration-parameters)
   (return-type-reference :initform nil
                          :accessor semantic-function-declaration-return-type-reference)
   (return-type :initform nil
                :accessor semantic-function-declaration-return-type)
   (type :initform nil :accessor semantic-function-declaration-type)
   (body :initform nil :accessor semantic-function-declaration-body)))

(defclass semantic-function-specialization (semantic-function-declaration)
  ((template :initarg :template :reader semantic-function-specialization-template)
   (type-arguments :initarg :type-arguments
                   :reader semantic-function-specialization-type-arguments)
   (resolving-p :initform nil :accessor semantic-function-specialization-resolving-p)))

(defclass semantic-protocol-declaration (semantic-declaration)
  ((protocol :initarg :protocol :reader semantic-protocol-declaration-protocol)))

(defclass semantic-protocol-implementation (semantic-declaration)
  ((implementation :initarg :implementation
                   :reader semantic-protocol-implementation-implementation)))

;; An operation implementation has an ordinary, fully concrete function body.
;; Keeping its protocol identity here lets the backend give it a deterministic
;; private symbol without placing its source spelling in the module namespace.
(defclass semantic-protocol-operation-implementation (semantic-function-declaration)
  ((implementation :initarg :implementation
                   :reader semantic-protocol-operation-implementation-implementation)
   (operation :initarg :operation
              :reader semantic-protocol-operation-implementation-operation)))

(defclass semantic-external-function-declaration (semantic-declaration)
  ((external-name :initarg :external-name :reader semantic-external-function-declaration-external-name)
   (parameter-type-references :initform '()
                              :accessor semantic-external-function-declaration-parameter-type-references)
   (parameter-types :initform '() :accessor semantic-external-function-declaration-parameter-types)
   (result-type-reference :initform nil
                          :accessor semantic-external-function-declaration-result-type-reference)
   (result-type :initform nil :accessor semantic-external-function-declaration-result-type)
   (type :initform nil :accessor semantic-external-function-declaration-type)))

(defclass semantic-generic-declaration (semantic-declaration)
  ((generic :initarg :generic :reader semantic-generic-declaration-generic)))

;; A source implementation is both a declaration retained by the program and
;; the selected concrete callable.  Primitive-backed implementations use the
;; base GENERIC-IMPLEMENTATION class instead.
(defclass semantic-generic-implementation (generic-implementation semantic-declaration semantic-binding)
  ((scope :initform nil :accessor semantic-generic-implementation-scope)
   (return-type-reference :initform nil
                          :accessor semantic-generic-implementation-return-type-reference)
   (type :initform nil :accessor semantic-generic-implementation-type)))

;; EXPRESSION is the typed runtime semantic model.  The SEMANTIC-* classes
;; remain concrete compatibility names for clients of the earlier passes.
(defclass expression ()
  ((syntax :initarg :syntax :reader expression-syntax :reader expression-source
	   :reader semantic-expression-syntax)
   (type :initarg :type :initform nil
	 :reader expression-type :reader semantic-expression-type)))
(defclass semantic-expression (expression) ())

(defclass semantic-literal (semantic-expression) ())
(defclass unit-expression (semantic-literal)
  ((value :initarg :value :reader unit-expression-value)))
(defclass boolean-literal (semantic-literal)
  ((value :initarg :value :reader boolean-literal-value)))
(defclass character-literal (semantic-literal)
  ((value :initarg :value :reader character-literal-value)))
(defclass integer-literal (semantic-literal)
  ((value :initarg :value :reader integer-literal-value)))
(defclass float-literal (semantic-literal)
  ((value :initarg :value :reader float-literal-value)))
(defclass string-literal (semantic-literal)
  ((value :initarg :value :reader string-literal-value)))

(defclass place-expression ()
  ((addressable :initarg :addressable :initform nil :reader place-expression-addressable-p)
   (writable :initarg :writable :initform nil :reader place-expression-writable-p)))

(defclass reference-expression (semantic-expression place-expression)
  ((name :initarg :name :reader semantic-reference-name)
   (binding :initarg :binding :reader semantic-reference-binding)))
(defclass semantic-reference (reference-expression) ())

(defclass call-expression (semantic-expression)
  ((callee :initarg :callee :reader semantic-call-callee)
   (arguments :initarg :arguments :reader semantic-call-arguments)))
(defclass semantic-call (call-expression) ())
(defclass polymorphic-call (semantic-call)
  ((function :initarg :function :reader polymorphic-call-function)
   (substitution :initarg :substitution :reader polymorphic-call-substitution)))
(defclass external-call-expression (semantic-call)
  ((external-function :initarg :external-function
                      :reader external-call-expression-external-function)))
(defclass primitive-call (semantic-call)
  ((operation :initarg :operation :reader primitive-call-operation)))
(defclass protocol-operation-call (semantic-call)
  ((operation :initarg :operation :reader protocol-operation-call-operation)
   (constraint :initarg :constraint :reader protocol-operation-call-constraint)))
;; Conversion calls are a distinct semantic class so a backend can lower
;; them mechanically without inspecting primitive names or argument types.
(defclass conversion-expression (primitive-call) ())
(defclass pointer-cast-expression (semantic-expression)
  ((operand :initarg :operand :reader pointer-cast-expression-operand)))
(defclass construct-expression (semantic-expression)
  ((product-type :initarg :product-type :reader construct-expression-product-type)
   (fields :initarg :fields :reader construct-expression-fields)))
(defclass sum-construct-expression (semantic-expression)
  ((alternative :initarg :alternative :reader sum-construct-expression-alternative)
   (arguments :initarg :arguments :reader sum-construct-expression-arguments)))
(defclass array-construct-expression (semantic-expression)
  ((elements :initarg :elements :reader array-construct-expression-elements)))
(defclass index-expression (semantic-expression)
  ((base :initarg :base :reader index-expression-base)
   (index :initarg :index :reader index-expression-index)
   (element-type :initarg :element-type :reader index-expression-element-type)))
(defclass index-place (index-expression place-expression) ())
(defclass field-expression (semantic-expression)
  ((value :initarg :value :reader field-expression-value)
   (field :initarg :field :reader field-expression-field)))
(defclass sequence-expression (semantic-expression)
  ((expressions :initarg :expressions :reader sequence-expression-expressions)))
(defclass let-expression (semantic-expression)
  ((bindings :initarg :bindings :reader let-expression-bindings)
   (scope :initarg :scope :reader let-expression-scope)
   (body :initarg :body :reader let-expression-body)))
(defclass address-expression (semantic-expression)
  ((operand :initarg :operand :reader address-expression-operand)))
(defclass dereference-expression (semantic-expression place-expression)
  ((operand :initarg :operand :reader dereference-expression-operand)))
(defclass load-expression (semantic-expression)
  ((place :initarg :place :reader load-expression-place)))
(defclass assignment-expression (semantic-expression)
  ((target :initarg :target :reader assignment-expression-target)
   (value :initarg :value :reader assignment-expression-value)))
(defclass store-expression (assignment-expression) ())
(defclass return-expression (semantic-expression)
  ((value :initarg :value :reader return-expression-value)))

;;; The source representation is resolved before reaching the backend.
(defclass pattern ()
  ((syntax :initarg :syntax :reader pattern-syntax)
   (type :initarg :type :reader pattern-type)))
(defclass literal-pattern (pattern)
  ((value :initarg :value :reader literal-pattern-value)))
(defclass boolean-pattern (literal-pattern) ())
(defclass character-pattern (literal-pattern) ())
(defclass integer-pattern (literal-pattern) ())
(defclass wildcard-pattern (pattern) ())
(defclass binding-pattern (pattern)
  ((binding :initarg :binding :reader binding-pattern-binding)))
(defclass constructor-pattern (pattern)
  ((alternative :initarg :alternative :reader constructor-pattern-alternative)
   (payload-patterns :initarg :payload-patterns
                     :reader constructor-pattern-payload-patterns)))
(defclass match-case ()
  ((syntax :initarg :syntax :reader match-case-syntax)
   (pattern :initarg :pattern :reader match-case-pattern)
   (scope :initarg :scope :reader match-case-scope)
   (expression :initarg :expression :reader match-case-expression)))
(defclass match-expression (semantic-expression)
  ((value :initarg :value :reader match-expression-value)
   (cases :initarg :cases :reader match-expression-cases)))

(defun semantic-program-declaration (program declaration)
  "Return DECLARATION's resolved semantic node, or NIL for macro declarations."
  (check-type program semantic-program)
  (check-type declaration declaration)
  (cdr (assoc declaration (semantic-program-declarations program) :test #'eq)))

(defun make-bootstrap-semantic-scope (&optional (type-context (make-type-context)))
  "Create compiler-provided semantic bindings for TYPE-CONTEXT.

Builtin names are bindings in the same semantic environment as user
declarations.  Their canonical type object is attached to that binding rather
than recovered later through ad-hoc string comparisons."
  (let ((scope (make-semantic-scope)))
    (setf (semantic-scope-type-context scope) type-context)
    (flet ((bind-type (name type)
	     (semantic-scope-bind scope (make-verona-name name)
				  (make-instance 'builtin-type-declaration
						 :name (make-verona-name name)
						 :type type))))
      (bind-type "bool" (type-context-boolean-type type-context))
	  (bind-type "char" (type-context-char-type type-context))
	  (bind-type "void" (type-context-void-type type-context))
      (dolist (specification '(("i8" t 8) ("i16" t 16)
			       ("i32" t 32) ("i64" t 64)
			       ("u8" nil 8) ("u16" nil 16)
			       ("u32" nil 32) ("u64" nil 64)))
	(destructuring-bind (name signed width) specification
	  (bind-type name (type-context-integer-type type-context signed width))))
	(bind-type "exit-code" (type-context-c-int-type type-context))
	(bind-type "isize" (type-context-integer-type type-context t
						     (type-context-pointer-width type-context)))
	(bind-type "usize" (type-context-integer-type type-context nil
						     (type-context-pointer-width type-context)))
      (dolist (specification '(("f32" 32) ("f64" 64)))
	(destructuring-bind (name width) specification
	  (bind-type name (type-context-float-type type-context width)))))
    (labels ((bind (name parameters result kind &key nan-semantics class)
	       (let ((binding (make-primitive-binding type-context name parameters result kind
							 :nan-semantics nan-semantics :class class)))
		 (semantic-scope-bind scope (make-verona-name name) binding)))
	     (integer-name (type)
	       (format nil "~:[u~;i~]~D" (integer-type-signed type)
		       (integer-type-width type)))
	     (float-name (type) (format nil "f~D" (float-type-width type))))
      ;; Arithmetic retains signedness in the operation's concrete identity,
      ;; including the cases where LLVM eventually uses the same instruction.
      (dolist (signed '(t nil))
	(dolist (width '(8 16 32 64))
	  (let* ((type (type-context-integer-type type-context signed width))
		 (suffix (integer-name type)))
	    (dolist (spec '(("%+" :integer-add) ("%-" :integer-subtract)
			    ("%*" :integer-multiply) ("%/" :integer-divide)))
	      (bind (format nil "~A-primitive-~A" (first spec) suffix)
		    (list type type) type
		    (if (eq (second spec) :integer-divide)
			(if signed :signed-integer-divide :unsigned-integer-divide)
			(second spec))))
	    (dolist (spec '(("%=" :integer-equal) ("%/=" :integer-not-equal)
			    ("%<" :integer-less-than) ("%<=" :integer-less-than-or-equal)
			    ("%>" :integer-greater-than) ("%>=" :integer-greater-than-or-equal)))
	      (bind (format nil "~A-primitive-~A" (first spec) suffix)
		    (list type type) (type-context-boolean-type type-context)
		    (intern (format nil "~A-~A" (if signed "SIGNED" "UNSIGNED")
				    (symbol-name (second spec))) :keyword))))))
      (dolist (width '(32 64))
	(let* ((type (type-context-float-type type-context width))
	       (suffix (float-name type)))
	  (dolist (spec '(("%+" :float-add) ("%-" :float-subtract)
			  ("%*" :float-multiply) ("%/" :float-divide)))
	    (bind (format nil "~A-primitive-~A" (first spec) suffix)
		  (list type type) type (second spec)))
	  (dolist (spec '(("%=" :float-ordered-equal) ("%/=" :float-ordered-not-equal)
			  ("%<" :float-ordered-less-than)
			  ("%<=" :float-ordered-less-than-or-equal)
			  ("%>" :float-ordered-greater-than)
			  ("%>=" :float-ordered-greater-than-or-equal)))
	    (bind (format nil "~A-primitive-~A" (first spec) suffix)
		  (list type type) (type-context-boolean-type type-context) (second spec)
		  :nan-semantics :ordered-false))))
      (let ((bool (type-context-boolean-type type-context)))
	(bind "%not-primitive-bool" (list bool) bool :boolean-not)
	(bind "%and-primitive-bool" (list bool bool) bool :boolean-and)
	(bind "%or-primitive-bool" (list bool bool) bool :boolean-or)
	(bind "%=-primitive-bool" (list bool bool) bool :boolean-equal)
	(bind "%/=-primitive-bool" (list bool bool) bool :boolean-not-equal))
      ;; Every conversion is a concrete operation.  The source spelling is
      ;; deliberately descriptive, so there is no generic conversion rule for
      ;; a backend to recover or invent.
      (dolist (source-signed '(t nil))
	(dolist (source-width '(8 16 32 64))
	  (let ((source (type-context-integer-type type-context source-signed source-width)))
	    (dolist (destination-signed '(t nil))
	      (dolist (destination-width '(8 16 32 64))
		(let ((destination (type-context-integer-type type-context destination-signed destination-width)))
		  (cond ((< source-width destination-width)
			 (bind (format nil "%~A-primitive-~A-~A"
				       (if source-signed "sext" "zext")
				       (integer-name source) (integer-name destination))
			       (list source) destination
			       (if source-signed :integer-sign-extend :integer-zero-extend)))
			((> source-width destination-width)
			 (bind (format nil "%trunc-primitive-~A-~A"
				       (integer-name source) (integer-name destination))
			       (list source) destination :integer-truncate))))))
	    (dolist (float-width '(32 64))
	      (let ((float (type-context-float-type type-context float-width)))
		(bind (format nil "%~A-primitive-~A-~A"
			      (if source-signed "sitofp" "uitofp")
			      (integer-name source) (float-name float))
		      (list source) float
		      (if source-signed :signed-integer-to-float :unsigned-integer-to-float)))))))
      (dolist (source-width '(32 64))
	(let ((source (type-context-float-type type-context source-width)))
	  (dolist (destination-signed '(t nil))
	    (dolist (destination-width '(8 16 32 64))
	      (let ((destination (type-context-integer-type type-context destination-signed destination-width)))
		(bind (format nil "%~A-primitive-~A-~A"
			      (if destination-signed "fptosi" "fptoui")
			      (float-name source) (integer-name destination))
		      (list source) destination
		      (if destination-signed :float-to-signed-integer :float-to-unsigned-integer)))))
	  (dolist (destination-width '(32 64))
	    (let ((destination (type-context-float-type type-context destination-width)))
	      (cond ((< source-width destination-width)
		     (bind (format nil "%fext-primitive-~A-~A" (float-name source) (float-name destination))
			   (list source) destination :float-extend))
		    ((> source-width destination-width)
		     (bind (format nil "%ftrunc-primitive-~A-~A" (float-name source) (float-name destination))
			   (list source) destination :float-truncate)))))))
      ;; Transitional aliases preserve the established surface spelling while
      ;; resolving to concrete i32 operations, never generic dispatch.
      (let ((i32 (type-context-integer-type type-context t 32)))
	(dolist (spec '(("+" :integer-add) ("-" :integer-subtract)
			("*" :integer-multiply) ("/" :integer-divide)))
	  (bind (first spec) (list i32 i32) i32 (second spec)
		:class 'builtin-intrinsic-binding)))
      ;; Surface arithmetic and comparison are compile-time generics.  The
      ;; older concrete i32 aliases above remain available as primitives for
      ;; bootstrap code and backwards compatibility.
      (labels ((install (name arity)
                 (let ((generic (make-instance 'generic :name (make-verona-name name)
                                                 :arity arity)))
                   (semantic-scope-bind scope (generic-name generic)
                                        (make-instance 'generic-binding
                                                       :name (generic-name generic)
                                                       :generic generic))
                   generic))
               (primitive (name)
                 (primitive-binding-operation
                  (semantic-scope-lookup scope (make-verona-name name))))
               (add (generic name)
                 (let ((operation (primitive name)))
                   (generic-add-implementation
                    generic
                    (make-instance 'generic-implementation :generic generic
                                   :parameter-types (primitive-operation-parameter-types operation)
                                   :result-type (primitive-operation-result-type operation)
                                   :primitive-operation operation)))))
        (dolist (operator '("+" "-" "*" "/" "==" "!=" "<" "<=" ">" ">="))
          (let ((generic (install operator 2)))
            (dolist (signed '(t nil))
              (dolist (width '(8 16 32 64))
                (let ((suffix (format nil "~:[u~;i~]~D" signed width)))
                  (add generic
                       (format nil "~A-primitive-~A"
                               (cond ((string= operator "+") "%+")
                                     ((string= operator "-") "%-")
                                     ((string= operator "*") "%*")
                                     ((string= operator "/") "%/")
                                     ((string= operator "==") "%=")
                                     ((string= operator "!=") "%/=")
                                     (t (format nil "%~A" operator)))
                               suffix)))))
            (when (member operator '("+" "-" "*" "/" "==" "!=" "<" "<=" ">" ">=")
                          :test #'string=)
              (dolist (width '(32 64))
                (let ((suffix (format nil "f~D" width)))
                  (add generic
                       (format nil "~A-primitive-~A"
                               (cond ((string= operator "+") "%+")
                                     ((string= operator "-") "%-")
                                     ((string= operator "*") "%*")
                                     ((string= operator "/") "%/")
                                     ((string= operator "==") "%=")
                                     ((string= operator "!=") "%/=")
                                     (t (format nil "%~A" operator)))
                               suffix))))))))
      scope)))

(define-condition unknown-module-qualifier (semantic-error)
  ((qualifier :initarg :qualifier :reader unknown-module-qualifier-qualifier)))
(define-condition module-not-imported (semantic-error)
  ((current-module :initarg :current-module :reader module-not-imported-current-module)
   (referenced-module :initarg :referenced-module :reader module-not-imported-referenced-module)))
(define-condition unknown-module-member (semantic-error)
  ((module :initarg :module :reader unknown-module-member-module)
   (name :initarg :name :reader unknown-module-member-name)))
(define-condition private-declaration-access (semantic-error)
  ((module :initarg :module :reader private-declaration-access-module)
   (name :initarg :name :reader private-declaration-access-name)))

(defun imported-binding (program imported declaration)
  (let ((semantic (semantic-program-declaration program declaration)))
    (if (or (typep semantic 'semantic-generic-declaration)
            (typep semantic 'semantic-type-alias-declaration))
        (let ((scope (semantic-program-module-scope-for program imported)))
          (semantic-scope-lookup scope (declaration-name declaration)))
        declaration)))

(defun resolve-qualified-name (scope syntax name)
  (let* ((current (semantic-scope-owning-module scope))
         (program (semantic-scope-owning-program scope))
         (qualifier (make-verona-name (module-name-string
                                       (qualified-name-qualifier name))))
         (import (and current (module-find-import current qualifier))))
    (unless import
      (let ((known (find (qualified-name-qualifier name) (program-modules program)
                         :key #'module-name :test #'module-name=)))
        (if known
            (error 'module-not-imported :syntax syntax :message "ModuleNotImported"
                   :current-module current :referenced-module known)
            (error 'unknown-module-qualifier :syntax syntax :message "UnknownModuleQualifier"
                   :qualifier (qualified-name-qualifier name)))))
    (let* ((imported (import-module import))
           (member (qualified-name-name name))
           (declaration (module-find-export imported member)))
      (unless declaration
        (multiple-value-bind (private presentp) (find-declaration imported member)
          (if presentp
              (error 'private-declaration-access :syntax syntax
                     :message "PrivateDeclarationAccess" :module imported :name member)
              (error 'unknown-module-member :syntax syntax
                     :message "UnknownModuleMember" :module imported :name member))))
      (make-instance 'semantic-reference :syntax syntax :name name
                     :binding (imported-binding program imported declaration)))))

(defun resolve-name (scope syntax)
  "Resolve local and qualified names through deliberately separate paths."
  (let ((name (syntax-datum syntax)))
    (cond ((qualified-name-p name) (resolve-qualified-name scope syntax name))
          ((verona-name-p name)
           (multiple-value-bind (binding foundp) (semantic-scope-find scope name)
             (unless foundp
               (error 'unresolved-name-error :name name :syntax syntax))
             (make-instance 'semantic-reference :syntax syntax :name name :binding binding)))
          (t (error 'semantic-error :syntax syntax :message "expected a Verona name")))))

(defun build-semantic-expression (scope syntax)
  "Build a resolved expression from syntax in SCOPE.

This is intentionally small: atoms become literals, names become references,
and lists become calls.  Future expression forms can introduce child scopes
without changing the scope or binding model established here."
  (check-type scope semantic-scope)
  (check-type syntax syntax)
  (let ((datum (syntax-datum syntax)))
    (cond ((or (verona-name-p datum) (qualified-name-p datum)) (resolve-name scope syntax))
	  ((verona-list-p datum)
	   (let ((elements (verona-list-elements datum)))
	     (unless elements
	       (error 'semantic-error :syntax syntax
				      :message "an empty list is not an expression"))
	     (make-instance 'semantic-call
			    :syntax syntax
			    :callee (build-semantic-expression scope (first elements))
			    :arguments (mapcar (lambda (element)
						 (build-semantic-expression scope element))
					       (rest elements)))))
	  (t (make-instance 'semantic-literal :syntax syntax)))))

(define-condition unknown-type-error (semantic-error)
  ((name :initarg :name :reader unknown-type-error-name))
  (:default-initargs :message "unknown type"))

(defun resolve-type-syntax (scope syntax)
  "Resolve the names embedded in a restricted type-language syntax tree.

This is deliberately distinct from BUILD-SEMANTIC-EXPRESSION: POINTER is a
type constructor, never a runtime call.  The result is still syntax-shaped so
the following type pass can turn it into canonical VERONA-TYPE objects."
  (check-type scope semantic-scope)
  (check-type syntax syntax)
  (let ((datum (syntax-datum syntax)))
    (cond ((or (verona-name-p datum) (qualified-name-p datum))
           (handler-case (resolve-name scope syntax)
             (unresolved-name-error ()
               (error 'unknown-type-error :syntax syntax :name datum))))
	  ((unit-literal-p datum)
	   (make-instance 'semantic-unit-type-syntax :syntax syntax))
	  ((verona-list-p datum)
	   (let* ((elements (verona-list-elements datum))
	          (head-syntax (first elements))
	          (head (and head-syntax (syntax-datum head-syntax))))
	     (unless (and head (verona-name-p head))
	       (error 'semantic-error :syntax syntax :message "expected a type constructor"))
	     (cond
	       ((string= (verona-name-value head) "pointer")
	        (unless (= (length elements) 2)
	          (error 'semantic-error :syntax syntax
	                 :message "pointer requires exactly one argument"))
	        (make-instance 'semantic-pointer-type-syntax
	                       :syntax syntax
	                       :target (resolve-type-syntax scope (second elements))))
	       ((string= (verona-name-value head) "array")
	        (unless (= (length elements) 3)
	          (error 'semantic-error :syntax syntax
	                 :message "array requires an element type and length"))
	        (let ((length (syntax-datum (third elements))))
	          (unless (and (integerp length) (<= 0 length))
	            (error 'semantic-error :syntax (third elements)
	                   :message "array length must be a non-negative integer"))
	          (make-instance 'semantic-array-type-syntax :syntax syntax
	                         :element-type (resolve-type-syntax scope (second elements))
	                         :length length)))
	       (t (error 'semantic-error :syntax head-syntax
	                 :message "unknown type constructor")))))
	  (t (error 'semantic-error :syntax syntax :message "expected a type")))))

(define-condition expected-type-error (semantic-error)
  ((binding :initarg :binding :reader expected-type-error-binding))
  (:default-initargs :message "expected a type")
  (:report (lambda (condition stream)
	     (let* ((syntax (semantic-error-syntax condition))
		    (name (and (typep syntax 'syntax)
			       (syntax-datum syntax))))
	       (if (verona-name-p name)
		   (format stream "~A is not a type"
			   (verona-name-value name))
           (format stream "expected a type"))))))

(define-condition duplicate-field-error (semantic-error)
  ((name :initarg :name :reader duplicate-field-error-name)
   (existing :initarg :existing :reader duplicate-field-error-existing)))

(define-condition duplicate-alternative-error (semantic-error)
  ((name :initarg :name :reader duplicate-alternative-error-name)
   (existing :initarg :existing :reader duplicate-alternative-error-existing)))

(define-condition recursive-type-not-supported-error (semantic-error) ())

(define-condition type-alias-cycle-error (semantic-error) ()
  (:default-initargs :message "TypeAliasCycle"))

(define-condition unknown-field-error (semantic-error)
  ((product-type :initarg :product-type :reader unknown-field-error-product-type)
   (name :initarg :name :reader unknown-field-error-name)))

(define-condition field-access-requires-product-error (semantic-error)
  ((actual :initarg :actual :reader field-access-requires-product-error-actual)))

(defun product-type-find-field (product-type name)
  "Return PRODUCT-TYPE's field named NAME, plus a presence flag."
  (check-type product-type product-type)
  (check-type name verona-name)
  (let ((field (find name (product-type-fields product-type)
                     :key #'product-field-name :test #'verona-name=)))
    (values field (not (null field)))))

(defun sum-type-find-alternative (sum-type name)
  "Return SUM-TYPE's alternative named NAME, plus a presence flag."
  (check-type sum-type sum-type)
  (check-type name verona-name)
  (let ((alternative (find name (sum-type-alternatives sum-type)
                           :key #'sum-alternative-name :test #'verona-name=)))
    (values alternative (not (null alternative)))))

(defun resolve-type (type-context resolved-type-syntax &optional program)
  "Turn resolved type syntax into a canonical, backend-independent type."
  (check-type type-context type-context)
  (cond ((typep resolved-type-syntax 'semantic-reference)
	 (let ((binding (semantic-reference-binding resolved-type-syntax)))
	   (cond ((typep binding 'builtin-type-binding)
		  (builtin-type-binding-type binding))
		 ((typep binding 'type-parameter) binding)
		 ((typep binding 'type-alias-binding)
                  (when program
                    (resolve-type-alias
                     program (type-alias-binding-semantic-declaration binding)))
                  (or (type-alias-binding-type binding)
                      (error 'semantic-error
                             :syntax (semantic-expression-syntax resolved-type-syntax)
                             :message "type alias has not been resolved")))
		 ((typep binding 'type-declaration)
		  (if (eq (type-declaration-kind binding) :opaque)
		      (type-context-opaque-type type-context binding)
		      (type-context-defined-type type-context binding)))
		 (t (error 'expected-type-error
			   :syntax (semantic-expression-syntax resolved-type-syntax)
			   :binding binding)))))
	((typep resolved-type-syntax 'semantic-unit-type-syntax)
	 (type-context-unit-type type-context))
	((typep resolved-type-syntax 'semantic-pointer-type-syntax)
	  (type-context-pointer-type
	   type-context
	  (resolve-type type-context
		(semantic-pointer-type-syntax-target resolved-type-syntax) program)))
	((typep resolved-type-syntax 'semantic-array-type-syntax)
	 (let ((element-type (resolve-type type-context
			   (semantic-array-type-syntax-element-type resolved-type-syntax) program)))
	   (unless (sized-type-p element-type)
	     (error 'semantic-error :syntax (semantic-type-syntax-syntax resolved-type-syntax)
	            :message "array element type must be sized"))
	   (type-context-array-type type-context element-type
	                            (semantic-array-type-syntax-length resolved-type-syntax))))
	(t (error "Unknown resolved type syntax ~S" resolved-type-syntax))))

(define-condition duplicate-type-parameter-error (semantic-error) ()
  (:default-initargs :message "DuplicateTypeParameter"))
(define-condition unknown-protocol-error (semantic-error) ()
  (:default-initargs :message "UnknownProtocol"))
(define-condition protocol-arity-mismatch-error (semantic-error) ()
  (:default-initargs :message "ProtocolArityMismatch"))
(define-condition invalid-protocol-constraint-error (semantic-error) ()
  (:default-initargs :message "InvalidProtocolConstraint"))
(define-condition cannot-infer-type-parameter-error (semantic-error) ()
  (:default-initargs :message "CannotInferTypeParameter"))
(define-condition conflicting-type-inference-error (semantic-error) ()
  (:default-initargs :message "ConflictingTypeInference"))

(defun parse-type-parameter-list (declaration syntax)
  (unless (verona-list-p (syntax-datum syntax))
    (error 'semantic-error :syntax syntax :message "type parameters must be a list"))
  (let ((parameters '()))
    (loop for parameter-syntax in (verona-list-elements (syntax-datum syntax))
          for index from 0
          for name = (syntax-datum parameter-syntax)
          do (unless (verona-name-p name)
               (error 'semantic-error :syntax parameter-syntax
                      :message "type parameter must be a Verona name"))
             (when (find name parameters :key #'semantic-binding-name :test #'verona-name=)
               (error 'duplicate-type-parameter-error :syntax parameter-syntax))
             (push (make-instance 'type-parameter :name name :declaration declaration
                                  :index index :source parameter-syntax)
                   parameters))
    (nreverse parameters)))

(defun parse-for-clause (declaration syntax)
  (unless (verona-list-p (syntax-datum syntax))
    (error 'semantic-error :syntax syntax :message "for clause must be a list"))
  (let ((elements (verona-list-elements (syntax-datum syntax))))
    (unless (and (>= (length elements) 2)
                 (verona-name-p (syntax-datum (first elements)))
                 (string= (verona-name-value (syntax-datum (first elements))) "for")
                 (<= (length elements) 3))
      (error 'semantic-error :syntax syntax :message "expected (for (type-parameter*) (constraint*))"))
    (let ((constraints (if (third elements) (third elements)
                           (syntax-with-datum syntax (make-verona-list)))))
      (unless (verona-list-p (syntax-datum constraints))
        (error 'semantic-error :syntax constraints :message "for constraints must be a list"))
      (make-instance 'for-clause :syntax syntax
                     :type-parameters (parse-type-parameter-list declaration (second elements))
                     :constraint-syntaxes (verona-list-elements (syntax-datum constraints))))))

(defun resolve-protocol-constraint (scope syntax)
  (unless (verona-list-p (syntax-datum syntax))
    (error 'invalid-protocol-constraint-error :syntax syntax))
  (let ((elements (verona-list-elements (syntax-datum syntax))))
    (unless elements (error 'invalid-protocol-constraint-error :syntax syntax))
    (let* ((head (resolve-name scope (first elements)))
           (binding (semantic-reference-binding head)))
      (unless (typep binding 'protocol-binding)
        (error 'unknown-protocol-error :syntax (first elements)))
      (let* ((protocol (protocol-binding-protocol binding))
             (arguments (mapcar (lambda (argument)
                                  (resolve-type (semantic-scope-owning-type-context scope)
                                                (resolve-type-syntax scope argument)))
                                (rest elements))))
        (unless (= (length arguments) (length (protocol-type-parameters protocol)))
          (error 'protocol-arity-mismatch-error :syntax syntax))
        (make-instance 'protocol-constraint :protocol protocol :arguments arguments :source syntax)))))

(defun protocol-find-implementation (protocol arguments)
  (cdr (assoc arguments (protocol-implementations protocol) :test #'equal)))

(defun protocol-add-implementation (protocol implementation syntax)
  (when (protocol-find-implementation protocol (protocol-implementation-arguments implementation))
    (error 'semantic-error :syntax syntax :message "DuplicateProtocolImplementation"))
  (push (cons (protocol-implementation-arguments implementation) implementation)
        (protocol-implementations protocol))
  implementation)

(defun resolve-protocol-operation-implementation
    (program declaration implementation operation syntax)
  "Resolve one implementation operation as a concrete private function."
  (unless (verona-list-p (syntax-datum syntax))
    (error 'semantic-error :syntax syntax :message "InvalidProtocolImplementation"))
  (let ((parts (verona-list-elements (syntax-datum syntax))))
    (unless (and (= (length parts) 5)
                 (verona-name-p (syntax-datum (first parts)))
                 (string= (verona-name-value (syntax-datum (first parts))) "function")
                 (verona-name-p (syntax-datum (second parts)))
                 (verona-list-p (syntax-datum (third parts))))
      (error 'semantic-error :syntax syntax :message "InvalidProtocolImplementation"))
    (let* ((context (semantic-program-type-context program))
           (module-scope (semantic-program-module-scope-for
                          program (declaration-module declaration)))
           (scope (semantic-scope-child module-scope))
           (substitution
             (make-type-substitution
              (mapcar #'cons
                      (protocol-type-parameters (protocol-implementation-protocol implementation))
                      (protocol-implementation-arguments implementation))))
           (expected-parameter-types
             (mapcar (lambda (parameter)
                       (apply-type-substitution context (parameter-binding-type parameter)
                                                substitution))
                     (protocol-operation-parameters operation)))
           (expected-result-type
             (apply-type-substitution context (protocol-operation-result-type operation)
                                      substitution))
           (source-declaration
             (make-instance 'function-declaration
                            :name (syntax-datum (second parts)) :source syntax
                            :expanded-syntax syntax :module (declaration-module declaration)
                            :parameters (third parts) :return-type (fourth parts)
                            :body (fifth parts)))
           (parameters
             (mapcar (lambda (parameter-syntax)
                       (parse-parameter source-declaration parameter-syntax))
                     (verona-list-elements (syntax-datum (third parts))))))
      (unless (= (length parameters) (length expected-parameter-types))
        (error 'semantic-error :syntax syntax :message "ProtocolOperationTypeMismatch"))
      (loop for parameter in parameters
            for expected-type in expected-parameter-types
            do (let ((actual-type
                       (resolve-type context
                                     (resolve-type-syntax module-scope
                                                          (parameter-binding-type-syntax parameter)))))
                 (unless (same-type-p actual-type expected-type)
                   (error 'semantic-error :syntax (parameter-binding-syntax parameter)
                          :message "ProtocolOperationTypeMismatch"))
                 (setf (parameter-binding-type parameter) actual-type))
               (multiple-value-bind (existing foundp)
                   (semantic-scope-local-find scope (semantic-binding-name parameter))
                 (declare (ignore existing))
                 (when foundp
                   (error 'duplicate-local-binding-error
                          :syntax (parameter-binding-syntax parameter)
                          :name (semantic-binding-name parameter))))
               (semantic-scope-bind scope (semantic-binding-name parameter) parameter))
      (let ((actual-result-type
              (resolve-type context (resolve-type-syntax module-scope (fourth parts)))))
        (unless (same-type-p actual-result-type expected-result-type)
          (error 'semantic-error :syntax (fourth parts) :message "ProtocolOperationTypeMismatch")))
      (let ((operation-function
              (make-instance 'semantic-protocol-operation-implementation
                             :source-declaration source-declaration
                             :implementation implementation :operation operation)))
        (setf (semantic-function-declaration-scope operation-function) scope
              (semantic-scope-function scope) operation-function
              (semantic-function-declaration-parameters operation-function) parameters
              (semantic-function-declaration-return-type operation-function) expected-result-type
              (semantic-function-declaration-type operation-function)
              (type-context-function-type context expected-parameter-types expected-result-type))
        operation-function))))

(defun resolve-protocol-implementation-signature (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
         (scope (semantic-program-module-scope-for program (declaration-module declaration)))
         (application (implementation-declaration-protocol-application declaration)))
    (unless (and application (verona-list-p (syntax-datum application)))
      (error 'semantic-error :syntax (declaration-source declaration)
             :message "InvalidProtocolImplementation"))
    (let* ((elements (verona-list-elements (syntax-datum application)))
           (head (and elements (resolve-name scope (first elements))))
           (binding (and head (semantic-reference-binding head))))
      (unless (typep binding 'protocol-binding)
        (error 'unknown-protocol-error :syntax (first elements)))
      (let* ((protocol (protocol-binding-protocol binding))
             (arguments (mapcar (lambda (argument)
                                  (resolve-type (semantic-program-type-context program)
                                                (resolve-type-syntax scope argument)))
                                (rest elements))))
        (unless (= (length arguments) (length (protocol-type-parameters protocol)))
          (error 'protocol-arity-mismatch-error :syntax application))
        ;; Validate names and coverage now.  Function bodies are deliberately
        ;; retained for the specialization stage, where their concrete target
        ;; operation is available.
        (let ((operation-names
                (mapcar (lambda (operation-syntax)
                          (unless (verona-list-p (syntax-datum operation-syntax))
                            (error 'semantic-error :syntax operation-syntax
                                   :message "MissingProtocolOperation"))
                          (let ((parts (verona-list-elements (syntax-datum operation-syntax))))
                            (unless (and (>= (length parts) 2)
                                         (verona-name-p (syntax-datum (first parts)))
                                         (string= (verona-name-value (syntax-datum (first parts))) "function")
                                         (verona-name-p (syntax-datum (second parts))))
                              (error 'semantic-error :syntax operation-syntax
                                     :message "InvalidProtocolImplementation"))
                            (syntax-datum (second parts))))
                        (implementation-declaration-operations declaration))))
          (dolist (operation (protocol-operations protocol))
            (unless (find (protocol-operation-name operation) operation-names :test #'verona-name=)
              (error 'semantic-error :syntax (declaration-source declaration)
                     :message "MissingProtocolOperation")))
          (when (/= (length operation-names) (length (remove-duplicates operation-names :test #'verona-name=)))
            (error 'semantic-error :syntax (declaration-source declaration)
                   :message "DuplicateProtocolOperation"))
          (dolist (name operation-names)
            (unless (find name (protocol-operations protocol)
                          :key #'protocol-operation-name :test #'verona-name=)
              (error 'semantic-error :syntax (declaration-source declaration)
                     :message "InvalidProtocolImplementation")))
          (let ((implementation
                  (make-instance 'protocol-implementation :protocol protocol :arguments arguments
                                 :source (declaration-source declaration))))
            (setf (protocol-implementation-operations implementation)
                  (mapcar (lambda (operation-syntax)
                            (let* ((name (syntax-datum
                                          (second (verona-list-elements
                                                   (syntax-datum operation-syntax)))))
                                   (operation (find name (protocol-operations protocol)
                                                    :key #'protocol-operation-name
                                                    :test #'verona-name=)))
                              (cons operation
                                    (resolve-protocol-operation-implementation
                                     program declaration implementation operation operation-syntax))))
                          (implementation-declaration-operations declaration)))
            (protocol-add-implementation protocol implementation (declaration-source declaration))
            (setf (slot-value semantic-declaration 'implementation) implementation)
            implementation))))))

(defun parse-parameter (function parameter-syntax)
  "Create a parameter entity from one (name type) syntax form."
  (declare (ignore function))
  (unless (verona-list-p (syntax-datum parameter-syntax))
    (error 'semantic-error :syntax parameter-syntax
			   :message "function parameter must be a (name type) list"))
  (let ((elements (verona-list-elements (syntax-datum parameter-syntax))))
    (unless (= (length elements) 2)
      (error 'semantic-error :syntax parameter-syntax
			     :message "function parameter must contain a name and type"))
    (let ((name (syntax-datum (first elements))))
      (unless (verona-name-p name)
	(error 'semantic-error :syntax (first elements)
			       :message "function parameter name must be a Verona name"))
      (make-instance 'parameter-binding
		     :name name :syntax (first elements) :type-syntax (second elements)))))

(defun resolve-function-signature (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
	 (module-scope (semantic-program-module-scope-for program (declaration-module declaration)))
	 (parameters-syntax (function-declaration-parameters declaration)))
    (unless (verona-list-p (syntax-datum parameters-syntax))
      (error 'semantic-error :syntax parameters-syntax
			     :message "function parameters must be a list"))
    (let* ((scope (semantic-scope-child module-scope))
	   (for-clause (and (function-declaration-for-clause declaration)
			    (parse-for-clause declaration (function-declaration-for-clause declaration))))
	   (type-parameters (and for-clause (for-clause-type-parameters for-clause)))
	  (parameters
	    (mapcar (lambda (syntax) (parse-parameter declaration syntax))
		    (verona-list-elements (syntax-datum parameters-syntax)))))
      ;; Type parameters precede every signature component and are bindings,
      ;; not text substitutions.  Resolve interface types through this child
      ;; scope so ordinary module types remain visible while parameter names
      ;; retain their declaration identity.
      (dolist (type-parameter type-parameters)
        (semantic-scope-bind scope (semantic-binding-name type-parameter) type-parameter))
      (dolist (parameter parameters)
	(setf (parameter-binding-type-reference parameter)
	      (resolve-type-syntax scope
				   (parameter-binding-type-syntax parameter))))
      (dolist (parameter parameters)
	(multiple-value-bind (existing foundp)
	    (semantic-scope-local-find scope (semantic-binding-name parameter))
	  (when foundp
	    (error 'duplicate-local-binding-error
		   :syntax (parameter-binding-syntax parameter)
		   :name (semantic-binding-name parameter) :existing existing))
	  (semantic-scope-bind scope (semantic-binding-name parameter) parameter)))
      (setf (semantic-function-declaration-scope semantic-declaration) scope
	    (semantic-scope-function scope) semantic-declaration
	    (semantic-function-declaration-parameters semantic-declaration) parameters
	    (semantic-function-declaration-type-parameters semantic-declaration) type-parameters
	    (semantic-function-declaration-constraints semantic-declaration)
	    (if for-clause
		(mapcar (lambda (constraint) (resolve-protocol-constraint scope constraint))
			(for-clause-constraint-syntaxes for-clause))
		'())
	    (semantic-function-declaration-return-type-reference semantic-declaration)
	    (resolve-type-syntax scope
			 (function-declaration-return-type declaration))))))

(defun resolve-protocol-signature (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
         (module-scope (semantic-program-module-scope-for program (declaration-module declaration)))
         (protocol (semantic-protocol-declaration-protocol semantic-declaration))
         (scope (semantic-scope-child module-scope))
         (type-parameters (parse-type-parameter-list declaration
                                                      (protocol-declaration-parameters declaration))))
    (dolist (parameter type-parameters)
      (semantic-scope-bind scope (semantic-binding-name parameter) parameter))
    (setf (protocol-type-parameters protocol) type-parameters
          (protocol-operations protocol)
          (mapcar
           (lambda (operation-syntax)
             (unless (verona-list-p (syntax-datum operation-syntax))
               (error 'semantic-error :syntax operation-syntax
                      :message "protocol operation must be a (name parameters result) list"))
             (let ((elements (verona-list-elements (syntax-datum operation-syntax))))
               (unless (= (length elements) 3)
                 (error 'semantic-error :syntax operation-syntax
                        :message "protocol operation must have a name, parameters, and result type"))
               (let ((name (syntax-datum (first elements))))
                 (unless (verona-name-p name)
                   (error 'semantic-error :syntax (first elements)
                          :message "protocol operation name must be a Verona name"))
                 (let ((parameters
                         (mapcar (lambda (parameter-syntax)
                                   (let ((parameter (parse-parameter declaration parameter-syntax)))
                                     (setf (parameter-binding-type-reference parameter)
                                           (resolve-type-syntax scope (parameter-binding-type-syntax parameter))
                                           (parameter-binding-type parameter)
                                           (resolve-type (semantic-program-type-context program)
                                                         (parameter-binding-type-reference parameter)))
                                     parameter))
                                 (verona-list-elements (syntax-datum (second elements))))))
                   (make-instance 'protocol-operation :protocol protocol :name name
                                  :parameters parameters
                                  :result-type (resolve-type (semantic-program-type-context program)
                                                             (resolve-type-syntax scope (third elements)))
                                  :source operation-syntax)))))
           (protocol-declaration-operations declaration)))
    protocol))

(defun resolve-external-function-signature (program semantic-declaration)
  "Resolve an external declaration with ordinary Verona types only."
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
         (module-scope (semantic-program-module-scope-for program
                                                            (declaration-module declaration)))
         (parameter-syntax (external-function-declaration-parameter-types declaration)))
    (setf (semantic-external-function-declaration-parameter-type-references semantic-declaration)
          (mapcar (lambda (syntax) (resolve-type-syntax module-scope syntax))
                  (verona-list-elements (syntax-datum parameter-syntax)))
          (semantic-external-function-declaration-result-type-reference semantic-declaration)
          (resolve-type-syntax module-scope
                               (external-function-declaration-result-type declaration)))))

(defun resolve-generic-implementation-signature (program semantic-implementation)
  (let* ((declaration (semantic-declaration-source-declaration semantic-implementation))
         (module-scope (semantic-program-module-scope-for program (declaration-module declaration)))
         (target-reference (resolve-name module-scope
                                         (syntax-with-datum
                                          (declaration-source declaration)
                                          (implementation-declaration-generic-name declaration))))
         (target (semantic-reference-binding target-reference)))
    (unless (typep target 'generic-binding)
      (error 'semantic-error :syntax (declaration-source declaration)
             :message "implementation target is not a generic"))
    (let* ((generic (generic-binding-generic target))
           (parameters-syntax (implementation-declaration-parameters declaration)))
      (unless (eq (declaration-module declaration)
                  (declaration-module (generic-declaration generic)))
        (error 'semantic-error :syntax (declaration-source declaration)
               :message "generic implementations must belong to the defining module"))
      (unless (verona-list-p (syntax-datum parameters-syntax))
        (error 'semantic-error :syntax parameters-syntax
               :message "implementation parameters must be a list"))
      (let ((parameter-syntaxes (verona-list-elements (syntax-datum parameters-syntax))))
        (unless (= (length parameter-syntaxes) (generic-arity generic))
          (error 'generic-arity-mismatch-error :syntax parameters-syntax
                 :generic generic :actual (length parameter-syntaxes)))
        (let ((scope (semantic-scope-child module-scope))
              (parameters (mapcar (lambda (syntax) (parse-parameter declaration syntax))
                                  parameter-syntaxes)))
          (dolist (parameter parameters)
            (setf (parameter-binding-type-reference parameter)
                  (resolve-type-syntax module-scope
                                       (parameter-binding-type-syntax parameter))))
          (dolist (parameter parameters)
            (multiple-value-bind (existing foundp)
                (semantic-scope-local-find scope (semantic-binding-name parameter))
              (when foundp
                (error 'duplicate-local-binding-error :syntax (parameter-binding-syntax parameter)
                       :name (semantic-binding-name parameter) :existing existing))
              (semantic-scope-bind scope (semantic-binding-name parameter) parameter)))
          (setf (slot-value semantic-implementation 'generic) generic
                (semantic-generic-implementation-scope semantic-implementation) scope
                (semantic-scope-function scope) semantic-implementation
                (generic-implementation-parameters semantic-implementation) parameters
                (semantic-generic-implementation-return-type-reference semantic-implementation)
                (resolve-type-syntax module-scope
                                     (implementation-declaration-return-type declaration))))))))

(defun make-semantic-declaration (declaration)
  (cond ((typep declaration 'type-declaration)
	 (make-instance 'semantic-type-declaration :source-declaration declaration))
	((typep declaration 'type-alias-declaration)
         (make-instance 'semantic-type-alias-declaration :source-declaration declaration))
	((typep declaration 'constant-declaration)
	 (make-instance 'semantic-constant-declaration :source-declaration declaration))
	((typep declaration 'variable-declaration)
	 (make-instance 'semantic-variable-declaration :source-declaration declaration))
	((typep declaration 'function-declaration)
	 (make-instance 'semantic-function-declaration :source-declaration declaration))
	((typep declaration 'protocol-declaration)
	 (let ((protocol (make-instance 'protocol :declaration declaration
                                        :name (declaration-name declaration))))
           (make-instance 'semantic-protocol-declaration :source-declaration declaration
                          :protocol protocol)))
	((typep declaration 'external-function-declaration)
	 (make-instance 'semantic-external-function-declaration
                        :source-declaration declaration
                        :external-name (external-function-declaration-external-name declaration)))
	((typep declaration 'generic-declaration)
         (let ((generic (make-instance 'generic :declaration declaration
                                        :name (declaration-name declaration)
                                        :arity (generic-declaration-arity declaration))))
           (make-instance 'semantic-generic-declaration :source-declaration declaration
                          :generic generic)))
	((typep declaration 'implementation-declaration)
         (if (implementation-declaration-protocol-application declaration)
             (make-instance 'semantic-protocol-implementation :source-declaration declaration)
             (make-instance 'semantic-generic-implementation :source-declaration declaration
                            :declaration declaration :source (declaration-source declaration)
                            :name (declaration-name declaration))))
	;; Macro declarations have already been handled by the evaluator.
	((typep declaration 'macro-declaration) nil)
	(t (error "Unknown Verona declaration ~S" declaration))))

(defun resolve-declaration-signature (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
	(scope (semantic-program-module-scope-for program (declaration-module declaration))))
    (cond ((typep semantic-declaration 'semantic-function-declaration)
	   (resolve-function-signature program semantic-declaration))
	  ((typep semantic-declaration 'semantic-protocol-declaration)
	   (resolve-protocol-signature program semantic-declaration))
	  ((typep semantic-declaration 'semantic-external-function-declaration)
	   (resolve-external-function-signature program semantic-declaration))
	  ((typep semantic-declaration 'semantic-generic-implementation)
           (resolve-generic-implementation-signature program semantic-declaration))
	  ((typep semantic-declaration 'semantic-protocol-implementation)
	   (resolve-protocol-implementation-signature program semantic-declaration))
	  ((typep semantic-declaration 'semantic-constant-declaration)
	   (setf (semantic-constant-declaration-type-reference semantic-declaration)
		 (resolve-type-syntax scope (constant-declaration-type declaration))))
	  ((typep semantic-declaration 'semantic-variable-declaration)
	   (setf (semantic-variable-declaration-type-reference semantic-declaration)
		 (resolve-type-syntax scope (variable-declaration-type declaration)))))))

(defun product-field-syntaxes (declaration)
  "Return explicit PRODUCT fields from DECLARATION.

Products are deliberately explicit: aliases own the `(type Name Type)`
shape, so accepting field-list shorthand would make declarations ambiguous."
  (let ((body (type-declaration-body declaration)))
    (unless (and (= (length body) 1) (verona-list-p (syntax-datum (first body))))
      (error 'semantic-error :syntax (declaration-source declaration)
             :message "product type body must be a (product ...) form"))
    (let ((elements (verona-list-elements (syntax-datum (first body)))))
      (unless (and elements (verona-name-p (syntax-datum (first elements)))
                   (string= (verona-name-value (syntax-datum (first elements))) "product"))
        (error 'semantic-error :syntax (first body)
               :message "product type body must begin with product"))
      (rest elements))))

(defun parse-product-field-syntax (field-syntax)
  (unless (verona-list-p (syntax-datum field-syntax))
    (error 'semantic-error :syntax field-syntax
           :message "product field must be a (name type) list"))
  (let ((elements (verona-list-elements (syntax-datum field-syntax))))
    (unless (= (length elements) 2)
      (error 'semantic-error :syntax field-syntax
             :message "product field must contain a name and type"))
    (let ((name (syntax-datum (first elements))))
      (unless (verona-name-p name)
        (error 'semantic-error :syntax (first elements)
               :message "product field name must be a Verona name"))
      (values name (second elements)))))

(defun ensure-type-is-complete (program resolved-type-syntax syntax &optional seen-aliases)
  "Reject self and forward references before a finite type gets a layout."
  (cond ((typep resolved-type-syntax 'semantic-reference)
         (let ((binding (semantic-reference-binding resolved-type-syntax)))
           (cond ((typep binding 'type-alias-binding)
                  (when (member binding seen-aliases :test #'eq)
                    (error 'type-alias-cycle-error :syntax syntax))
                  (ensure-type-is-complete
                   program
                   (or (semantic-type-alias-declaration-target-reference
                        (type-alias-binding-semantic-declaration binding))
                       (prepare-type-alias-reference
                        program (type-alias-binding-semantic-declaration binding)))
                   syntax (cons binding seen-aliases)))
                 ((typep binding 'type-declaration)
                  (let ((semantic (semantic-program-declaration program binding)))
                    (unless (and (typep semantic 'semantic-type-declaration)
                                 (typep (semantic-type-declaration-type semantic)
                                        '(or product-type sum-type)))
                      (error 'recursive-type-not-supported-error :syntax syntax
                             :message "RecursiveTypeNotSupported: type members may reference only earlier complete types")))))))
        ((typep resolved-type-syntax 'semantic-pointer-type-syntax)
         ;; A pointer to an opaque C handle needs no pointee layout.  Other
         ;; pointers retain the existing recursive-layout restriction.
         (let ((pointee (semantic-pointer-type-syntax-target resolved-type-syntax)))
           (unless (typep (resolve-type (semantic-program-type-context program)
                                         pointee program)
                          'opaque-type)
             (ensure-type-is-complete program pointee syntax seen-aliases))))
        ((typep resolved-type-syntax 'semantic-array-type-syntax)
         (ensure-type-is-complete
          program (semantic-array-type-syntax-element-type resolved-type-syntax) syntax seen-aliases))))

(defun resolve-product-type-declaration (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
         (scope (semantic-program-module-scope-for program (declaration-module declaration)))
         (context (semantic-program-type-context program))
         (fields '()))
    (dolist (field-syntax (product-field-syntaxes declaration))
      (multiple-value-bind (name type-syntax) (parse-product-field-syntax field-syntax)
        (let ((existing (find name fields :key #'product-field-name :test #'verona-name=)))
          (when existing
            (error 'duplicate-field-error :syntax (first (verona-list-elements
                                                           (syntax-datum field-syntax)))
                   :message "DuplicateField" :name name :existing existing)))
        (let ((reference (resolve-type-syntax scope type-syntax)))
          (ensure-type-is-complete program reference type-syntax)
          (push (make-instance 'product-field :name name
                               :type (resolve-type context reference program)
                               :index (length fields) :source field-syntax)
                fields))))
    (setf fields (nreverse fields))
    ;; Indexes were assigned while accumulating in declaration order.  Repair
    ;; them after reversal so backend indexes always equal source order.
    (loop for field in fields for index from 0
          do (setf (slot-value field 'index) index))
    (setf (semantic-type-declaration-fields semantic-declaration) fields
          (semantic-type-declaration-type semantic-declaration)
          (type-context-product-type context declaration fields))))

(defun resolve-opaque-type-declaration (program semantic-declaration)
  "Install the identity of a body-less nominal type without inventing a layout."
  (let ((declaration (semantic-declaration-source-declaration semantic-declaration)))
    (setf (semantic-type-declaration-type semantic-declaration)
          (type-context-opaque-type (semantic-program-type-context program) declaration))))

(defun sum-alternative-syntaxes (declaration)
  (let ((body (type-declaration-body declaration)))
    (unless (and (= (length body) 1) (verona-list-p (syntax-datum (first body))))
      (error 'semantic-error :syntax (declaration-source declaration)
             :message "sum type body must be a (sum ...) form"))
    (let ((elements (verona-list-elements (syntax-datum (first body)))))
      (unless (and elements (verona-name-p (syntax-datum (first elements)))
                   (string= (verona-name-value (syntax-datum (first elements))) "sum"))
        (error 'semantic-error :syntax (first body)
               :message "type body must begin with product or sum"))
      (rest elements))))

(defun parse-sum-alternative-syntax (alternative-syntax)
  (unless (verona-list-p (syntax-datum alternative-syntax))
    (error 'semantic-error :syntax alternative-syntax
           :message "sum alternative must be a (name type...) list"))
  (let ((elements (verona-list-elements (syntax-datum alternative-syntax))))
    (unless elements
      (error 'semantic-error :syntax alternative-syntax
             :message "sum alternative requires a name"))
    (let ((name (syntax-datum (first elements))))
      (unless (verona-name-p name)
        (error 'semantic-error :syntax (first elements)
               :message "sum alternative name must be a Verona name"))
      (values name (rest elements)))))

(defun resolve-sum-type-declaration (program semantic-declaration)
  (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
         (scope (semantic-program-module-scope-for program (declaration-module declaration)))
         (context (semantic-program-type-context program))
         ;; Install identity before alternatives, but only after all previous
         ;; declarations are complete.  A reference to this declaration is
         ;; still rejected by ENSURE-TYPE-IS-COMPLETE.
         (sum-type (type-context-sum-type context declaration '()))
         (alternatives '()))
    (dolist (alternative-syntax (sum-alternative-syntaxes declaration))
      (multiple-value-bind (name payload-syntaxes)
          (parse-sum-alternative-syntax alternative-syntax)
        (let ((existing (find name alternatives :key #'sum-alternative-name
                              :test #'verona-name=)))
          (when existing
            (error 'duplicate-alternative-error :syntax alternative-syntax
                   :message "DuplicateAlternative" :name name :existing existing)))
        (let ((payload-types
                (mapcar (lambda (payload-syntax)
                          (let ((reference (resolve-type-syntax scope payload-syntax)))
                            (ensure-type-is-complete program reference payload-syntax)
                            (resolve-type context reference program)))
                        payload-syntaxes)))
          (push (make-instance 'sum-alternative :sum-type sum-type :name name
                               :index (length alternatives)
                               :payload-types payload-types :source alternative-syntax)
                alternatives))))
    (setf alternatives (nreverse alternatives))
    (loop for alternative in alternatives for index from 0
          do (setf (slot-value alternative 'index) index))
    (setf (slot-value sum-type 'alternatives) alternatives
          (semantic-type-declaration-alternatives semantic-declaration) alternatives
          (semantic-type-declaration-type semantic-declaration) sum-type)))

(defun prepare-type-alias-reference (program semantic-declaration)
  "Resolve an alias target's names without forcing its canonical type yet."
  (or (semantic-type-alias-declaration-target-reference semantic-declaration)
      (let* ((declaration (semantic-declaration-source-declaration semantic-declaration))
             (scope (semantic-program-module-scope-for program (declaration-module declaration)))
             (reference (resolve-type-syntax scope (type-alias-declaration-target declaration))))
        (setf (semantic-type-alias-declaration-target-reference semantic-declaration) reference)
        reference)))

(defun resolve-type-alias (program semantic-declaration)
  "Resolve one alias, recursively resolving aliases in its target first."
  (case (semantic-type-alias-declaration-state semantic-declaration)
    (:resolved (return-from resolve-type-alias
                 (semantic-type-alias-declaration-target-type semantic-declaration)))
    (:resolving
     (error 'type-alias-cycle-error
            :syntax (type-alias-declaration-target
                     (semantic-declaration-source-declaration semantic-declaration))))
    (:unresolved))
  (setf (semantic-type-alias-declaration-state semantic-declaration) :resolving)
  (let* ((reference (prepare-type-alias-reference program semantic-declaration))
         (type (resolve-type (semantic-program-type-context program) reference program)))
    (setf (semantic-type-alias-declaration-target-reference semantic-declaration) reference
          (semantic-type-alias-declaration-target-type semantic-declaration) type
          (semantic-type-alias-declaration-state semantic-declaration) :resolved)
    type))

(defun resolve-declaration-types (program semantic-declaration)
  "Attach canonical types to the already name-resolved declaration interface."
  (let ((context (semantic-program-type-context program)))
    (cond
      ((typep semantic-declaration 'semantic-function-declaration)
       (let ((parameter-types
	       (mapcar (lambda (parameter)
		 (setf (parameter-binding-type parameter)
		       (resolve-type context
			     (parameter-binding-type-reference parameter))))
		       (semantic-function-declaration-parameters semantic-declaration))))
	 (loop for parameter in (semantic-function-declaration-parameters semantic-declaration)
	       for type in parameter-types
	       do (ensure-not-opaque-value-type type (parameter-binding-syntax parameter)
	                                        "function parameter"))
	 (setf (semantic-function-declaration-return-type semantic-declaration)
	       (resolve-type context
		     (semantic-function-declaration-return-type-reference
		      semantic-declaration))
	       (semantic-function-declaration-type semantic-declaration)
	       (type-context-function-type
		context parameter-types
		(semantic-function-declaration-return-type semantic-declaration)))
	 (ensure-not-opaque-value-type
	  (semantic-function-declaration-return-type semantic-declaration)
	  (function-declaration-return-type
	   (semantic-declaration-source-declaration semantic-declaration))
	  "function result")))
	  ((typep semantic-declaration 'semantic-external-function-declaration)
	   (let ((parameter-types
		   (mapcar (lambda (reference) (resolve-type context reference))
			   (semantic-external-function-declaration-parameter-type-references
			    semantic-declaration)))
	     (result-type
	       (resolve-type context
			     (semantic-external-function-declaration-result-type-reference
			      semantic-declaration))))
	     (setf (semantic-external-function-declaration-parameter-types semantic-declaration)
		   parameter-types
		   (semantic-external-function-declaration-result-type semantic-declaration)
		   result-type
		   (semantic-external-function-declaration-type semantic-declaration)
		   (type-context-function-type context parameter-types result-type))
	     (validate-external-function-signature semantic-declaration)))
      ((typep semantic-declaration 'semantic-generic-implementation)
       (let ((parameter-types
               (mapcar (lambda (parameter)
                         (setf (parameter-binding-type parameter)
                               (resolve-type context
                                             (parameter-binding-type-reference parameter))))
                       (generic-implementation-parameters semantic-declaration))))
         (loop for parameter in (generic-implementation-parameters semantic-declaration)
               for type in parameter-types
               do (ensure-not-opaque-value-type type (parameter-binding-syntax parameter)
                                                "generic implementation parameter"))
         (setf (generic-implementation-parameter-types semantic-declaration) parameter-types
               (generic-implementation-result-type semantic-declaration)
               (resolve-type context
                             (semantic-generic-implementation-return-type-reference
                              semantic-declaration))
               (semantic-generic-implementation-type semantic-declaration)
               (type-context-function-type context parameter-types
                                           (generic-implementation-result-type semantic-declaration)))
         (ensure-not-opaque-value-type
          (generic-implementation-result-type semantic-declaration)
          (generic-implementation-declaration semantic-declaration)
          "generic implementation result")
         (generic-add-implementation (generic-implementation-generic semantic-declaration)
                                     semantic-declaration
                                     (declaration-source
                                      (semantic-declaration-source-declaration semantic-declaration)))))
      ((typep semantic-declaration 'semantic-constant-declaration)
       (setf (semantic-constant-declaration-type semantic-declaration)
	     (resolve-type context
		   (semantic-constant-declaration-type-reference
		    semantic-declaration)))
       (ensure-not-opaque-value-type
        (semantic-constant-declaration-type semantic-declaration)
        (constant-declaration-type (semantic-declaration-source-declaration semantic-declaration))
        "constant declaration"))
      ((typep semantic-declaration 'semantic-variable-declaration)
       (setf (semantic-variable-declaration-type semantic-declaration)
	     (resolve-type context
		   (semantic-variable-declaration-type-reference
		    semantic-declaration)))
       (ensure-not-opaque-value-type
        (semantic-variable-declaration-type semantic-declaration)
        (variable-declaration-type (semantic-declaration-source-declaration semantic-declaration))
        "variable declaration")))))

(defun resolve-types (program)
  "Run the type representation/resolution stage for PROGRAM.

Expression bodies are intentionally untouched: this pass establishes only
declaration signatures and nominal type identities for the later expression
type checker."
  (check-type program semantic-program)
  ;; Resolve alias names first, without manufacturing types for a product or
  ;; sum whose layout has not been installed yet.  The references also let the
  ;; completeness pass look through an alias used in a member declaration.
  (dolist (entry (semantic-program-declarations program))
    (let ((declaration (cdr entry)))
      (when (typep declaration 'semantic-type-alias-declaration)
        (prepare-type-alias-reference program declaration))))
  ;; Finite product and sum definitions are resolved in source order.  Members
  ;; can use only a previously completed type; recursion is deferred.
  (dolist (entry (semantic-program-declarations program))
    (let ((declaration (cdr entry)))
      (when (typep declaration 'semantic-type-declaration)
        (ecase (type-declaration-kind
                (semantic-declaration-source-declaration declaration))
          (:product (resolve-product-type-declaration program declaration))
          (:sum (resolve-sum-type-declaration program declaration))
          (:opaque (resolve-opaque-type-declaration program declaration))))))
  ;; Now all nominal layouts exist, so an alias to one receives its complete
  ;; canonical ProductType or SumType rather than a provisional DefinedType.
  (dolist (entry (semantic-program-declarations program))
    (let ((declaration (cdr entry)))
      (when (typep declaration 'semantic-type-alias-declaration)
        (resolve-type-alias program declaration))))
  (dolist (entry (semantic-program-declarations program))
    (resolve-declaration-types program (cdr entry)))
  program)

;;; Expression analysis ----------------------------------------------------

(define-condition type-mismatch-error (semantic-error)
  ((actual :initarg :actual :reader type-mismatch-error-actual)
   (expected :initarg :expected :reader type-mismatch-error-expected))
  (:default-initargs :message "type mismatch")
  (:report (lambda (condition stream)
	     (let ((syntax (semantic-error-syntax condition)))
	       (when syntax
		 (let ((location (syntax-start syntax)))
		   (format stream "~A:~D:~D: "
			   (source-name (syntax-source syntax))
			   (source-location-line location)
			   (source-location-column location))))
	       (format stream "type mismatch~%expected: ~A~%actual:   ~A"
		       (verona-type-name (type-mismatch-error-expected condition))
		       (verona-type-name (type-mismatch-error-actual condition)))))))

(define-condition semantic-not-callable-error (semantic-error)
  ((actual :initarg :actual :reader semantic-not-callable-error-actual))
  (:default-initargs :message "expression is not callable"))

(define-condition wrong-argument-count-error (semantic-error)
  ((expected :initarg :expected :reader wrong-argument-count-error-expected)
   (actual :initarg :actual :reader wrong-argument-count-error-actual))
  (:default-initargs :message "wrong argument count"))

(define-condition generic-arity-mismatch-error (semantic-error)
  ((generic :initarg :generic :reader generic-arity-mismatch-error-generic)
   (actual :initarg :actual :reader generic-arity-mismatch-error-actual))
  (:default-initargs :message "GenericArityMismatch"))

(define-condition duplicate-generic-implementation-error (semantic-error)
  ((generic :initarg :generic :reader duplicate-generic-implementation-error-generic)
   (parameter-types :initarg :parameter-types
                    :reader duplicate-generic-implementation-error-parameter-types)
   (original :initarg :original :reader duplicate-generic-implementation-error-original)
   (duplicate :initarg :duplicate :reader duplicate-generic-implementation-error-duplicate)
   (original-source :initarg :original-source
                    :reader duplicate-generic-implementation-error-original-source)
   (duplicate-source :initarg :duplicate-source
                     :reader duplicate-generic-implementation-error-duplicate-source))
  (:default-initargs :message "DuplicateGenericImplementation"))

(define-condition no-generic-implementation-error (semantic-error)
  ((generic :initarg :generic :reader no-generic-implementation-error-generic)
   (argument-types :initarg :argument-types
                   :reader no-generic-implementation-error-argument-types))
  (:default-initargs :message "NoGenericImplementation"))

(define-condition not-addressable-error (semantic-error) ())
(define-condition not-writable-error (semantic-error) ())
(define-condition invalid-expression-error (semantic-error) ())
(define-condition cannot-infer-array-element-type-error (semantic-error) ()
  (:default-initargs :message "CannotInferArrayElementType"))
(define-condition array-element-type-mismatch-error (type-mismatch-error) ()
  (:default-initargs :message "ArrayElementTypeMismatch"))
(define-condition array-index-out-of-bounds-error (semantic-error) ()
  (:default-initargs :message "ArrayIndexOutOfBounds"))

(defun verona-type-name (type)
  "A compact stable spelling used in semantic diagnostics."
  (cond ((typep type 'never-type) "never")
	((typep type 'unit-type) "unit")
	((typep type 'void-type) "void")
	((typep type 'boolean-type) "bool")
	((typep type 'char-type) "char")
	((typep type 'integer-type)
	 (format nil "~:[u~;i~]~D" (integer-type-signed type)
		 (integer-type-width type)))
	((typep type 'float-type) (format nil "f~D" (float-type-width type)))
	((typep type 'pointer-type)
	 (format nil "(pointer ~A)" (verona-type-name (pointer-type-target type))))
	((typep type 'array-type)
	 (format nil "(array ~A ~D)" (verona-type-name (array-type-element-type type))
		 (array-type-length type)))
	((typep type 'function-type) "function")
	((typep type 'defined-type)
	 (verona-name-value (declaration-name (defined-type-declaration type))))
	(t "<unknown type>")))

(defun same-type-p (left right)
  "Whether LEFT and RIGHT are the same canonical Verona type."
  (eq left right))

(defun apply-type-substitution (context type substitution)
  "Apply SUBSTITUTION structurally, preserving canonical compound types."
  (cond ((typep type 'type-parameter)
         (or (type-substitution-find substitution type) type))
        ((typep type 'pointer-type)
         (type-context-pointer-type context
                                    (apply-type-substitution context
                                                             (pointer-type-target type) substitution)))
        ((typep type 'array-type)
         (type-context-array-type context
                                  (apply-type-substitution context
                                                           (array-type-element-type type) substitution)
                                  (array-type-length type)))
        ((typep type 'function-type)
         (type-context-function-type context
                                     (mapcar (lambda (parameter)
                                               (apply-type-substitution context parameter substitution))
                                             (function-type-parameters type))
                                     (apply-type-substitution context
                                                              (function-type-result type) substitution)))
        (t type)))

(defun unify-types (expected actual substitution)
  "Restricted local call-site unification.  EXPECTED owns the variables."
  (cond ((typep expected 'type-parameter)
         (let ((existing (type-substitution-find substitution expected)))
           (cond ((null existing) (type-substitution-bind substitution expected actual) t)
                 ((same-type-p existing actual) t)
                 (t nil))))
        ((and (typep expected 'pointer-type) (typep actual 'pointer-type))
         (unify-types (pointer-type-target expected) (pointer-type-target actual) substitution))
        ((and (typep expected 'array-type) (typep actual 'array-type)
              (= (array-type-length expected) (array-type-length actual)))
         (unify-types (array-type-element-type expected) (array-type-element-type actual) substitution))
        (t (same-type-p expected actual))))

(define-condition recursive-specialization-error (semantic-error) ()
  (:default-initargs :message "RecursiveSpecialization"))

(defun find-function-specialization (program template type-arguments)
  (find-if (lambda (specialization)
             (and (eq template (semantic-function-specialization-template specialization))
                  (equal type-arguments
                         (semantic-function-specialization-type-arguments specialization))))
           (semantic-program-function-specializations program)))

(defun ensure-function-specialization (program template substitution)
  "Create or retrieve TEMPLATE instantiated with SUBSTITUTION.

The specialization is registered before its body is resolved, so a direct
recursive call can refer to the same concrete LLVM function."
  (let* ((context (semantic-program-type-context program))
         (type-parameters (semantic-function-declaration-type-parameters template))
         (type-arguments (mapcar (lambda (parameter)
                                   (apply-type-substitution context parameter substitution))
                                 type-parameters))
         (existing (find-function-specialization program template type-arguments)))
    (when existing (return-from ensure-function-specialization existing))
    (when (find-if (lambda (specialization)
                     (eq template (semantic-function-specialization-template specialization)))
                   (remove-if-not #'semantic-function-specialization-resolving-p
                                  (semantic-program-function-specializations program)))
      ;; A changing recursive instantiation would otherwise construct an
      ;; unbounded set during semantic resolution.  Direct same-type recursion
      ;; takes the existing-specialization branch above.
      (error 'recursive-specialization-error
             :syntax (declaration-source
                      (semantic-declaration-source-declaration template))))
    (let* ((source (semantic-declaration-source-declaration template))
           (module-scope (semantic-program-module-scope-for program
                                                              (declaration-module source)))
           (scope (semantic-scope-child module-scope))
           (parameters
             (loop for parameter in (semantic-function-declaration-parameters template)
                   collect (make-instance 'parameter-binding
                                          :name (semantic-binding-name parameter)
                                          :syntax (parameter-binding-syntax parameter)
                                          :type-syntax (parameter-binding-type-syntax parameter))))
           (specialization
             (make-instance 'semantic-function-specialization
                            :source-declaration source :template template
                            :type-arguments type-arguments)))
      (setf (semantic-program-function-specializations program)
            (append (semantic-program-function-specializations program)
                    (list specialization))
            (semantic-function-declaration-scope specialization) scope
            (semantic-scope-function scope) specialization
            (semantic-function-declaration-parameters specialization) parameters
            (semantic-function-declaration-return-type specialization)
            (apply-type-substitution context
                                     (semantic-function-declaration-return-type template)
                                     substitution)
            (semantic-function-declaration-constraints specialization)
            (mapcar (lambda (constraint)
                      (make-instance 'protocol-constraint
                                     :protocol (protocol-constraint-protocol constraint)
                                     :arguments
                                     (mapcar (lambda (type)
                                               (apply-type-substitution context type substitution))
                                             (protocol-constraint-arguments constraint))
                                     :source (protocol-constraint-source constraint)))
                    (semantic-function-declaration-constraints template))
            (semantic-function-declaration-type specialization)
            (type-context-function-type
             context
             (mapcar (lambda (parameter)
                       (apply-type-substitution context
                                                (parameter-binding-type parameter)
                                                substitution))
                     (semantic-function-declaration-parameters template))
             (semantic-function-declaration-return-type specialization))
            (semantic-function-specialization-resolving-p specialization) t)
      (loop for specialized in parameters
            for template-parameter in (semantic-function-declaration-parameters template)
            do (setf (parameter-binding-type specialized)
                     (apply-type-substitution context
                                              (parameter-binding-type template-parameter)
                                              substitution))
               (semantic-scope-bind scope (semantic-binding-name specialized) specialized))
      (unwind-protect
           (setf (semantic-function-declaration-body specialization)
                 (check-expression (function-declaration-body source) scope
                                   (semantic-function-declaration-return-type specialization)))
        (setf (semantic-function-specialization-resolving-p specialization) nil))
      specialization)))

(defun sized-type-p (type)
  "Whether TYPE can be stored inline in a fixed Verona array."
  (not (typep type '(or void-type never-type function-type opaque-type))))

(defun ensure-not-opaque-value-type (type syntax context)
  "Reject an opaque type wherever Verona would need its inline representation."
  (when (typep type 'opaque-type)
    (error 'semantic-error :syntax syntax
           :message (format nil "~A cannot use opaque type ~A by value"
                            context (verona-type-name type))))
  type)

(defun c-abi-value-type-p (type)
  "Whether TYPE is passed or returned as a first-stage C ABI value.

BOOL maps to the target C ABI's `_Bool` representation."
  (or (typep type 'boolean-type)
      (typep type 'integer-type)
      (typep type 'float-type)
      (typep type 'pointer-type)))

(defun validate-external-function-signature (declaration)
  "Reject unsupported C ABI shapes before backend lowering."
  (unless (every #'c-abi-value-type-p
                 (semantic-external-function-declaration-parameter-types declaration))
    (error 'semantic-error
           :syntax (declaration-source
                    (semantic-declaration-source-declaration declaration))
           :message "external function parameters must use C ABI value types"))
  (unless (or (typep (semantic-external-function-declaration-result-type declaration)
                     'void-type)
              (c-abi-value-type-p
               (semantic-external-function-declaration-result-type declaration)))
    (error 'semantic-error
           :syntax (declaration-source
                    (semantic-declaration-source-declaration declaration))
           :message "external function result must use a C ABI value type or void"))
  declaration)

(defun resolve-native-exports (program modules)
  "Resolve explicit C exports after function signatures are fully typed."
  (let ((seen '()))
    (dolist (module modules)
      (dolist (spec (module-native-export-specs module))
        (let* ((declaration (find-declaration module (native-export-spec-name spec)))
               (semantic (and declaration (semantic-program-declaration program declaration))))
          (unless (typep semantic 'semantic-function-declaration)
            (error 'invalid-native-export :syntax (native-export-spec-source spec)
                   :message "native-export must name a Verona function"))
          (when (member (native-export-spec-external-name spec) seen :test #'string=)
            (error 'invalid-native-export :syntax (native-export-spec-source spec)
                   :message "duplicate native C export name"))
          (let ((signature (semantic-function-declaration-type semantic)))
            ;; This is the same scalar/pointer rule used by external-function,
            ;; in the reverse direction. Unit, products, and sums have no C
            ;; ABI contract yet.
            (unless (and (every #'c-abi-value-type-p (function-type-parameters signature))
                         (c-abi-value-type-p (function-type-result signature)))
              (error 'invalid-native-export :syntax (native-export-spec-source spec)
                     :message "native export must use C ABI value types")))
          (push (native-export-spec-external-name spec) seen)
          (push (make-instance 'native-export-binding :function semantic
                               :external-name (native-export-spec-external-name spec)
                               :source (native-export-spec-source spec))
                (semantic-program-native-exports program)))))
    (setf (semantic-program-native-exports program)
          (nreverse (semantic-program-native-exports program)))
    program))

(defun compatible-p (actual expected)
  "Whether ACTUAL can be used where EXPECTED is required."
  (same-type-p actual expected))

(defun expression-special-form-name (syntax)
  (let ((datum (syntax-datum syntax)))
    (when (verona-list-p datum)
      (let ((head (first (verona-list-elements datum))))
	(when (and head (verona-name-p (syntax-datum head)))
	  (verona-name-value (syntax-datum head)))))))

(defun binding-expression-type (scope binding syntax)
  "Return BINDING's runtime type without changing its identity."
  (cond ((typep binding 'parameter-binding) (parameter-binding-type binding))
	((typep binding 'pattern-binding) (pattern-binding-type binding))
	((typep binding 'let-binding) (let-binding-type binding))
	((typep binding 'primitive-binding)
	 (builtin-intrinsic-binding-type binding))
	((typep binding 'generic-binding)
         (error 'invalid-expression-error :syntax syntax
                :message "a generic is only callable in call position"))
	((or (typep binding 'builtin-type-binding)
	     (typep binding 'type-declaration))
	 (error 'invalid-expression-error :syntax syntax
					  :message "a type is not a runtime value"))
	((typep binding 'declaration)
	 (let* ((program (semantic-scope-owning-program scope))
		(semantic (and program (semantic-program-declaration program binding))))
	   (cond ((typep semantic 'semantic-constant-declaration)
		  (semantic-constant-declaration-type semantic))
		 ((typep semantic 'semantic-variable-declaration)
		  (semantic-variable-declaration-type semantic))
		 ((typep semantic 'semantic-function-declaration)
		  (semantic-function-declaration-type semantic))
		 ((typep semantic 'semantic-external-function-declaration)
		  (semantic-external-function-declaration-type semantic))
		 (t (error 'invalid-expression-error :syntax syntax
						     :message "declaration has no runtime type")))))
	(t (error 'invalid-expression-error :syntax syntax
					    :message "unknown runtime binding"))))

(defun binding-place-properties (binding)
  "Return addressable and writable flags for a reference binding.

Parameters are deliberately addressable and writable in this initial model;
they represent parameter storage rather than C's accidental value category.
LET bindings are addressable but remain immutable through their source name."
  (cond ((typep binding 'parameter-binding) (values t t))
	((typep binding 'variable-declaration) (values t t))
	((typep binding 'let-binding) (values t nil))
	(t (values nil nil))))

(defun infer-reference-expression (syntax scope)
  (let* ((untyped (resolve-name scope syntax))
	 (binding (semantic-reference-binding untyped)))
    (multiple-value-bind (addressable writable) (binding-place-properties binding)
      (make-instance 'semantic-reference :syntax syntax
					 :name (semantic-reference-name untyped) :binding binding
					 :type (binding-expression-type scope binding syntax)
					 :addressable addressable :writable writable))))

(defun product-constructor-type (scope syntax)
  "Return the resolved ProductType selected by constructor head SYNTAX, if any."
  (when (or (verona-name-p (syntax-datum syntax))
            (qualified-name-p (syntax-datum syntax)))
    (handler-case
        (let ((binding (semantic-reference-binding (resolve-name scope syntax))))
          (when (typep binding 'type-declaration)
            (let* ((program (semantic-scope-owning-program scope))
                   (semantic (semantic-program-declaration program binding)))
              (and (typep semantic 'semantic-type-declaration)
                   (semantic-type-declaration-type semantic)))))
      ;; An operation supplied only by protocol evidence is not a product
      ;; constructor.  Leave its lookup to INFER-CALL-EXPRESSION.
      (unresolved-name-error () nil))))

(defun infer-construct-expression (syntax scope product-type argument-syntax)
  (let ((fields (product-type-fields product-type)))
    (unless (= (length argument-syntax) (length fields))
      (error 'wrong-argument-count-error :syntax syntax
             :expected (length fields) :actual (length argument-syntax)))
    (make-instance 'construct-expression :syntax syntax :product-type product-type
                   :fields (loop for argument in argument-syntax
                                 for field in fields
                                 collect (check-expression argument scope
                                                           (product-field-type field)))
                   :type product-type)))

(defun infer-sum-construct-expression (syntax scope sum-type alternative argument-syntax)
  (let ((payload-types (sum-alternative-payload-types alternative)))
    (unless (= (length argument-syntax) (length payload-types))
      (error 'wrong-argument-count-error :syntax syntax
             :expected (length payload-types) :actual (length argument-syntax)))
    (make-instance 'sum-construct-expression :syntax syntax
                   :alternative alternative
                   :arguments (loop for argument in argument-syntax
                                    for payload-type in payload-types
                                    collect (check-expression argument scope payload-type))
                   :type sum-type)))

(defun infer-array-construct-expression (syntax scope argument-syntax &optional expected-type)
  "Resolve ARRAY-OF in synthesis mode or against an expected ArrayType."
  (let ((length (length argument-syntax)))
    (cond
      (expected-type
       (unless (typep expected-type 'array-type)
         (error 'semantic-error :syntax syntax
                :message "array-of requires an expected array type"))
       (unless (= length (array-type-length expected-type))
         (error 'wrong-argument-count-error :syntax syntax
                :expected (array-type-length expected-type) :actual length))
       (make-instance 'array-construct-expression :syntax syntax
                      :elements (mapcar (lambda (argument)
                                          (check-expression argument scope
                                                            (array-type-element-type expected-type)))
                                        argument-syntax)
                      :type expected-type))
      ((zerop length)
       (error 'cannot-infer-array-element-type-error :syntax syntax))
      (t
       (let* ((first (infer-value-expression (first argument-syntax) scope))
              (element-type (expression-type first))
              (elements (cons first
                              (mapcar (lambda (argument)
                                        (handler-case
                                            (check-expression argument scope element-type)
                                          (type-mismatch-error (condition)
                                            (error 'array-element-type-mismatch-error
                                                   :syntax argument :actual (type-mismatch-error-actual condition)
                                                   :expected element-type))))
                                      (rest argument-syntax))))
              (type (type-context-array-type (semantic-scope-owning-type-context scope)
                                             element-type length)))
         (make-instance 'array-construct-expression :syntax syntax :elements elements :type type))))))

(defun constant-array-index-p (expression)
  (and (typep expression 'integer-literal) (integer-literal-value expression)))

(defun validate-array-index (syntax array-type index-expression)
  (let ((constant (constant-array-index-p index-expression)))
    (when (and constant
               (or (< constant 0) (>= constant (array-type-length array-type))))
      (error 'array-index-out-of-bounds-error :syntax syntax
             :message "array index is out of bounds"))))

(defun infer-index-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 2)
      (error 'invalid-expression-error :syntax syntax
             :message "index requires an array and index"))
    (let* ((base (infer-expression (first arguments) scope))
           (array-type (expression-type base)))
      (unless (typep array-type 'array-type)
        (error 'invalid-expression-error :syntax (first arguments)
               :message "index requires an array"))
      (let ((index (check-expression
                    (second arguments) scope
                    (type-context-integer-type (semantic-scope-owning-type-context scope) nil
                                               (type-context-pointer-width
                                                (semantic-scope-owning-type-context scope))))))
        (validate-array-index (second arguments) array-type index)
        (if (and (typep base 'place-expression)
                 (place-expression-addressable-p base))
            (make-instance 'index-place :syntax syntax :base base :index index
                           :element-type (array-type-element-type array-type)
                           :type (array-type-element-type array-type)
                           :addressable t :writable (place-expression-writable-p base))
            (make-instance 'index-expression :syntax syntax :base base :index index
                           :element-type (array-type-element-type array-type)
                           :type (array-type-element-type array-type)))))))

(defun expected-sum-constructor (syntax expected-type)
  "Resolve a constructor name only in the supplied expected sum type."
  (when (and (typep expected-type 'sum-type) (verona-list-p (syntax-datum syntax)))
    (let ((head (first (verona-list-elements (syntax-datum syntax)))) )
      (when (and head (verona-name-p (syntax-datum head)))
        (sum-type-find-alternative expected-type (syntax-datum head))))))

(defun find-constrained-protocol-operation (scope name)
  "Find protocol-operation evidence for NAME in the enclosing function."
  (let ((function (semantic-scope-owning-function scope)))
    (when (and function (typep name 'verona-name)
               (typep function 'semantic-function-declaration))
      (loop for constraint in (semantic-function-declaration-constraints function)
            for operation = (find name (protocol-operations
                                        (protocol-constraint-protocol constraint))
                                :key #'protocol-operation-name :test #'verona-name=)
            when operation return (values operation constraint)))))

(defun infer-protocol-operation-call (syntax scope operation constraint)
  (let* ((elements (verona-list-elements (syntax-datum syntax)))
         (arguments-syntax (rest elements))
         (context (semantic-scope-owning-type-context scope))
         (substitution (make-type-substitution
                        (mapcar #'cons (protocol-type-parameters
                                       (protocol-constraint-protocol constraint))
                                (protocol-constraint-arguments constraint))))
         (parameter-types
           (mapcar (lambda (parameter)
                     (apply-type-substitution context (parameter-binding-type parameter)
                                              substitution))
                   (protocol-operation-parameters operation))))
    (unless (= (length arguments-syntax) (length parameter-types))
      (error 'wrong-argument-count-error :syntax syntax :expected (length parameter-types)
             :actual (length arguments-syntax)))
    (let ((arguments (loop for argument in arguments-syntax
                           for parameter-type in parameter-types
                           collect (check-expression argument scope parameter-type))))
      (let* ((result-type (apply-type-substitution context
                                                    (protocol-operation-result-type operation)
                                                    substitution))
             (implementation
               (and (every (lambda (type) (not (typep type 'type-parameter)))
                           (protocol-constraint-arguments constraint))
                    (protocol-find-implementation
                     (protocol-constraint-protocol constraint)
                     (protocol-constraint-arguments constraint))))
             (operation-function
               (and implementation
                    (protocol-implementation-find-operation implementation operation))))
        ;; A specialized body has concrete evidence, so erase the protocol
        ;; call now.  The resulting ordinary semantic call is entirely
        ;; backend-ready and LLVM never needs a protocol runtime object.
        (if operation-function
            (make-instance 'semantic-call :syntax syntax
                           :callee (make-instance 'semantic-reference
                                                  :syntax (first elements)
                                                  :name (syntax-datum (first elements))
                                                  :binding operation-function
                                                  :type (semantic-function-declaration-type
                                                         operation-function))
                           :arguments arguments :type result-type)
            (make-instance 'protocol-operation-call :syntax syntax
                           :callee (make-instance 'semantic-reference :syntax (first elements)
                                                  :name (syntax-datum (first elements))
                                                  :binding operation
                                                  :type (type-context-function-type
                                                         context parameter-types result-type))
                           :arguments arguments :operation operation :constraint constraint
                           :type result-type))))))

(defun infer-call-expression (syntax scope)
  (let* ((elements (verona-list-elements (syntax-datum syntax)))
	 (head (first elements))
	 (product-type (product-constructor-type scope head)))
    (when (typep product-type 'product-type)
      (return-from infer-call-expression
        (infer-construct-expression syntax scope product-type (rest elements))))
    ;; An unconstrained operation name remains an ordinary unresolved name.
    ;; Only when no lexical binding exists may protocol evidence supply it.
    (when (verona-name-p (syntax-datum head))
      (multiple-value-bind (binding foundp)
          (semantic-scope-find scope (syntax-datum head))
        (when (or (not foundp) (typep binding 'protocol-binding))
          (multiple-value-bind (operation constraint)
              (find-constrained-protocol-operation scope (syntax-datum head))
            (when operation
              (return-from infer-call-expression
                (infer-protocol-operation-call syntax scope operation constraint)))))))
    ;; Generics are resolved here, after arguments have concrete semantic
    ;; types, and are immediately replaced by a primitive or ordinary call.
    (when (or (verona-name-p (syntax-datum head))
              (qualified-name-p (syntax-datum head)))
      (let ((head-binding (semantic-reference-binding (resolve-name scope head))))
        (when (typep head-binding 'generic-binding)
          (return-from infer-call-expression
	    (let* ((generic (generic-binding-generic head-binding))
                   (argument-syntax (rest elements)))
              (unless (= (length argument-syntax) (generic-arity generic))
                (error 'wrong-argument-count-error :syntax syntax
                       :expected (generic-arity generic) :actual (length argument-syntax)))
              (let* ((arguments (mapcar (lambda (argument)
                                          (infer-value-expression argument scope))
                                        argument-syntax))
                     (argument-types (mapcar #'expression-type arguments))
                     (implementation (generic-find-implementation generic argument-types)))
                (unless implementation
                  (error 'no-generic-implementation-error :syntax syntax
                         :generic generic :argument-types argument-types))
                (let ((operation (generic-implementation-primitive-operation implementation)))
                  (if operation
                      (make-instance 'primitive-call :syntax syntax
                                     :callee (make-instance 'semantic-reference :syntax head
                                                            :name (syntax-datum head)
                                                            :binding head-binding)
                                     :arguments arguments :operation operation
                                     :type (generic-implementation-result-type implementation))
                      (let ((callee (make-instance 'semantic-reference :syntax head
                                                   :name (syntax-datum head)
                                                   :binding implementation
                                                   :type (semantic-generic-implementation-type implementation))))
                        (make-instance 'semantic-call :syntax syntax :callee callee
                                       :arguments arguments
                                       :type (generic-implementation-result-type implementation))))))))))
    ;; Parametric functions infer only from value arguments.  This is local
    ;; unification, not global Hindley--Milner inference.
    (when (or (verona-name-p (syntax-datum head))
              (qualified-name-p (syntax-datum head)))
      (let* ((head-reference (resolve-name scope head))
             (binding (semantic-reference-binding head-reference))
             (program (semantic-scope-owning-program scope))
             (function (and (typep binding 'function-declaration)
                            (semantic-program-declaration program binding))))
        (when (and (typep function 'semantic-function-declaration)
                   (semantic-function-declaration-type-parameters function))
          (let ((argument-syntax (rest elements))
                (parameters (semantic-function-declaration-parameters function)))
            (unless (= (length argument-syntax) (length parameters))
              (error 'wrong-argument-count-error :syntax syntax
                     :expected (length parameters) :actual (length argument-syntax)))
            (let* ((arguments (mapcar (lambda (argument)
                                        (infer-value-expression argument scope))
                                      argument-syntax))
                   (substitution (make-type-substitution)))
              (loop for parameter in parameters
                    for argument in arguments
                    unless (unify-types (parameter-binding-type parameter)
                                        (expression-type argument) substitution)
                      do (error 'conflicting-type-inference-error :syntax syntax))
              (dolist (parameter (semantic-function-declaration-type-parameters function))
                (unless (type-substitution-find substitution parameter)
                  (error 'cannot-infer-type-parameter-error :syntax syntax)))
              (let* ((context (semantic-scope-owning-type-context scope)))
                ;; Constraint solving is deliberately exact and concrete:
                ;; instantiate each application, then look up one registered
                ;; implementation.  There is no recursive search or ranking.
                (dolist (constraint (semantic-function-declaration-constraints function))
                  (let ((arguments (mapcar (lambda (type)
                                             (apply-type-substitution context type substitution))
                                           (protocol-constraint-arguments constraint))))
                    (unless (every (lambda (type) (not (typep type 'type-parameter))) arguments)
                      (error 'cannot-infer-type-parameter-error :syntax syntax))
                    (unless (protocol-find-implementation
                             (protocol-constraint-protocol constraint) arguments)
                      (error 'semantic-error :syntax syntax
                             :message "ProtocolConstraintNotSatisfied"))))
	              (let* ((specialization
                               (ensure-function-specialization
                                (semantic-scope-owning-program scope) function substitution))
	                     (parameter-types
                       (mapcar (lambda (parameter)
                                 (apply-type-substitution context
                                                          (parameter-binding-type parameter)
                                                          substitution))
                               parameters))
                     (result-type (apply-type-substitution
                                   context
                                   (semantic-function-declaration-return-type function)
                                   substitution))
	                     (callee-type (semantic-function-declaration-type specialization))
	                     (callee (make-instance 'semantic-reference :syntax head
	                                            :name (syntax-datum head) :binding specialization
	                                            :type callee-type)))
                (return-from infer-call-expression
                  (make-instance 'polymorphic-call :syntax syntax :callee callee
	                                 :arguments arguments :function specialization
                                 :substitution substitution :type result-type)))))))))
    (let* ((callee (infer-expression head scope))
	 (callee-type (expression-type callee)))
    (unless (typep callee-type 'function-type)
      (error 'semantic-not-callable-error :syntax (first elements)
					  :actual callee-type))
    (let ((parameter-types (function-type-parameters callee-type))
	  (argument-syntax (rest elements)))
      (unless (= (length argument-syntax) (length parameter-types))
	(error 'wrong-argument-count-error :syntax syntax
					   :expected (length parameter-types) :actual (length argument-syntax)))
      (let* ((arguments (loop for argument in argument-syntax
				     for parameter-type in parameter-types
				     collect (check-expression argument scope parameter-type)))
	     (binding (and (typep callee 'semantic-reference)
			   (semantic-reference-binding callee))))
	(if (typep binding 'primitive-binding)
	    (let* ((operation (primitive-binding-operation binding))
		   (kind (primitive-operation-kind operation))
		   (conversion-p (member kind '(:integer-sign-extend :integer-zero-extend
						 :integer-truncate :signed-integer-to-float
						 :unsigned-integer-to-float :float-to-signed-integer
						 :float-to-unsigned-integer :float-extend
						 :float-truncate))))
	      (make-instance (if conversion-p 'conversion-expression 'primitive-call)
			     :syntax syntax :callee callee :arguments arguments
			     :operation operation :type (function-type-result callee-type)))
	    (let ((external (and (typep binding 'external-function-declaration)
				 (semantic-program-declaration
				  (semantic-scope-owning-program scope) binding))))
	      (if (typep external 'semantic-external-function-declaration)
		  ;; C void has no Verona value.  Only this external call boundary
		  ;; materializes the ordinary Verona unit value.
		  (make-instance 'external-call-expression :syntax syntax :callee callee
				 :arguments arguments :external-function external
				 :type (if (typep (function-type-result callee-type) 'void-type)
					  (type-context-unit-type (semantic-scope-owning-type-context scope))
					  (function-type-result callee-type)))
		  (make-instance 'semantic-call :syntax syntax :callee callee
				 :arguments arguments :type (function-type-result callee-type)))))))))))

(defun infer-field-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 2)
      (error 'invalid-expression-error :syntax syntax
             :message "field requires a product value and field name"))
    (let ((value (infer-value-expression (first arguments) scope))
          (name (syntax-datum (second arguments))))
      (unless (verona-name-p name)
        (error 'invalid-expression-error :syntax (second arguments)
               :message "field name must be a Verona name"))
      (let ((product-type (expression-type value)))
        (unless (typep product-type 'product-type)
          (error 'field-access-requires-product-error :syntax (first arguments)
                 :message "field access requires a product value" :actual product-type))
        (multiple-value-bind (field foundp) (product-type-find-field product-type name)
          (unless foundp
            (error 'unknown-field-error :syntax (second arguments) :message "UnknownField"
                   :product-type product-type :name name))
          (make-instance 'field-expression :syntax syntax :value value :field field
                         :type (product-field-type field)))))))

(defun infer-sequence-expression (syntax scope)
  (let ((expressions '()))
    (dolist (form (rest (verona-list-elements (syntax-datum syntax))))
      (when (and expressions (typep (expression-type (car (last expressions))) 'never-type))
        (error 'unreachable-expression-error :syntax form
               :message "expression follows terminating control flow"))
      (push (infer-value-expression form scope) expressions))
    (setf expressions (nreverse expressions))
    (make-instance 'sequence-expression :syntax syntax :expressions expressions
					:type (if expressions
						  (expression-type (car (last expressions)))
						  (type-context-unit-type
						   (semantic-scope-owning-type-context scope))))))

(defun let-definition-name-p (name)
  "Whether NAME is a top-level definition spelling used in executable code."
  (and name
       (member name '("constant" "variable" "%constant" "%variable")
               :test #'string=)))

(defun parse-let-binding (binding-syntax scope)
  "Resolve one LET binding, installing it only after its initializer.

SCOPE is the child scope owned by the enclosing LET.  Earlier bindings are
therefore visible, while the binding being built cannot see itself."
  (unless (verona-list-p (syntax-datum binding-syntax))
    (error 'invalid-expression-error :syntax binding-syntax
           :message "let binding must be a (name type initializer) list"))
  (let ((elements (verona-list-elements (syntax-datum binding-syntax))))
    (unless (= (length elements) 3)
      (error 'invalid-expression-error :syntax binding-syntax
             :message "let binding must contain a name, type, and initializer"))
    (let ((name (syntax-datum (first elements))))
      (unless (verona-name-p name)
        (error 'invalid-expression-error :syntax (first elements)
               :message "let binding name must be a Verona name"))
      (multiple-value-bind (existing foundp) (semantic-scope-local-find scope name)
        (when foundp
          (error 'duplicate-local-binding-error :syntax (first elements)
                 :name name :existing existing)))
      (let* ((type-reference (resolve-type-syntax scope (second elements)))
             (type (resolve-type (semantic-scope-owning-type-context scope)
                                 type-reference))
             (initializer (check-expression (third elements) scope type))
             (binding (make-instance 'let-binding :name name :syntax (first elements)
                                     :type-syntax (second elements)
                                     :type-reference type-reference :type type
                                     :initializer initializer)))
        (semantic-scope-bind scope name binding)
        binding))))

(defun infer-let-body (syntax body-syntaxes scope expected-type)
  "Resolve a LET body as a non-empty expression sequence."
  (unless body-syntaxes
    (error 'invalid-expression-error :syntax syntax :message "let requires a body"))
  (let ((expressions '())
        (last-syntax (car (last body-syntaxes))))
    (dolist (form body-syntaxes)
      (when (and expressions (typep (expression-type (car (last expressions))) 'never-type))
        (error 'unreachable-expression-error :syntax form
               :message "expression follows terminating control flow"))
      (push (if (and expected-type (eq form last-syntax))
                (check-expression form scope expected-type)
                (infer-value-expression form scope))
            expressions))
    (setf expressions (nreverse expressions))
    ;; Preserve the direct body node for the common one-expression form.  A
    ;; multi-form body uses the established sequence representation.
    (if (null (cdr expressions))
        (first expressions)
        (make-instance 'sequence-expression :syntax syntax :expressions expressions
                       :type (expression-type (car (last expressions)))))))

(defun infer-let-expression (syntax scope &optional expected-type)
  "Analyze a sequential, immutable lexical LET expression."
  (let ((elements (verona-list-elements (syntax-datum syntax))))
    (unless (>= (length elements) 3)
      (error 'invalid-expression-error :syntax syntax
             :message "let requires bindings and a body"))
    (let ((bindings-syntax (second elements)))
      (unless (verona-list-p (syntax-datum bindings-syntax))
        (error 'invalid-expression-error :syntax bindings-syntax
               :message "let bindings must be a list"))
      (let ((let-scope (semantic-scope-child scope))
            (bindings '()))
        (dolist (binding-syntax (verona-list-elements (syntax-datum bindings-syntax)))
          (push (parse-let-binding binding-syntax let-scope) bindings))
        (let ((body (infer-let-body syntax (cddr elements) let-scope expected-type)))
          (make-instance 'let-expression :syntax syntax :scope let-scope
                         :bindings (nreverse bindings) :body body
                         :type (expression-type body)))))))

(defun analyze-pattern (syntax scope scrutinee-type)
  "Resolve one source pattern and install a binding in the case scope." 
  (let ((datum (syntax-datum syntax)))
    (cond ((verona-list-p datum)
           (unless (typep scrutinee-type 'sum-type)
             (error 'invalid-expression-error :syntax syntax
                    :message "constructor patterns require a sum scrutinee"))
           (let ((elements (verona-list-elements datum)))
             (unless elements
               (error 'invalid-expression-error :syntax syntax
                      :message "constructor pattern requires an alternative name"))
             (let ((name (syntax-datum (first elements))))
               (unless (verona-name-p name)
                 (error 'invalid-expression-error :syntax (first elements)
                        :message "constructor pattern name must be a Verona name"))
               (multiple-value-bind (alternative foundp)
                   (sum-type-find-alternative scrutinee-type name)
                 (unless foundp
                   (error 'invalid-expression-error :syntax (first elements)
                          :message "unknown sum alternative"))
                 (let ((payload-syntaxes (rest elements))
                       (payload-types (sum-alternative-payload-types alternative)))
                   (unless (= (length payload-syntaxes) (length payload-types))
                     (error 'wrong-argument-count-error :syntax syntax
                            :expected (length payload-types) :actual (length payload-syntaxes)))
                   (make-instance 'constructor-pattern :syntax syntax :type scrutinee-type
                                  :alternative alternative
                                  :payload-patterns
                                  (loop for payload-syntax in payload-syntaxes
                                        for payload-type in payload-types
                                        do (when (verona-list-p (syntax-datum payload-syntax))
                                             (error 'invalid-expression-error :syntax payload-syntax
                                                    :message "nested constructor patterns are not supported yet"))
                                        collect (analyze-pattern payload-syntax scope payload-type))))))))
	  ((verona-boolean-literal-p datum)
	   (unless (typep scrutinee-type 'boolean-type)
	     (error 'type-mismatch-error :syntax syntax
		    :actual (type-context-boolean-type (semantic-scope-owning-type-context scope))
		    :expected scrutinee-type))
	   (make-instance 'boolean-pattern :syntax syntax :type scrutinee-type
			  :value (verona-boolean-literal-value datum)))
	  ((characterp datum)
	   (let ((character-type (type-context-char-type
				  (semantic-scope-owning-type-context scope))))
	     (cond ((typep scrutinee-type 'char-type)
		    (make-instance 'character-pattern :syntax syntax :type scrutinee-type
				   :value (char-code datum)))
		   ;; getchar returns C int.  Accept character syntax here so clients can
		   ;; match its ASCII result without an ABI-unsafe narrowing declaration.
		   ((typep scrutinee-type 'integer-type)
		    (make-instance 'integer-pattern :syntax syntax :type scrutinee-type
				   :value (char-code datum)))
		   (t (error 'type-mismatch-error :syntax syntax :actual character-type
			     :expected scrutinee-type)))))
	  ((integerp datum)
	   (unless (typep scrutinee-type 'integer-type)
	     (error 'type-mismatch-error :syntax syntax
		    :actual (type-context-integer-type (semantic-scope-owning-type-context scope) t 32)
		    :expected scrutinee-type))
	   (make-instance 'integer-pattern :syntax syntax :type scrutinee-type :value datum))
	  ((verona-name-p datum)
	   (if (string= (verona-name-value datum) "_")
	       (make-instance 'wildcard-pattern :syntax syntax :type scrutinee-type)
	       (let ((binding (make-instance 'pattern-binding :name datum :syntax syntax
					    :type scrutinee-type)))
		 (semantic-scope-bind scope datum binding)
		 (make-instance 'binding-pattern :syntax syntax :type scrutinee-type
				:binding binding))))
	  (t (error 'invalid-expression-error :syntax syntax
		    :message "match patterns must be a literal, binding, or _")))))

(defun pattern-catches-all-p (pattern)
  (or (typep pattern 'wildcard-pattern) (typep pattern 'binding-pattern)))

(defun constructor-pattern-complete-p (pattern)
  (and (typep pattern 'constructor-pattern)
       (every #'pattern-catches-all-p (constructor-pattern-payload-patterns pattern))))

(defun pattern-already-covered-p (pattern covered)
  (or (and (pattern-catches-all-p covered) t)
      (and (typep pattern 'constructor-pattern)
           (typep covered 'constructor-pattern)
           (eq (constructor-pattern-alternative pattern)
               (constructor-pattern-alternative covered))
           (constructor-pattern-complete-p covered))
      (and (typep pattern 'boolean-pattern) (typep covered 'boolean-pattern)
	   (eql (literal-pattern-value pattern) (literal-pattern-value covered)))
	  (and (typep pattern 'character-pattern) (typep covered 'character-pattern)
	   (= (literal-pattern-value pattern) (literal-pattern-value covered)))
      (and (typep pattern 'integer-pattern) (typep covered 'integer-pattern)
	   (= (literal-pattern-value pattern) (literal-pattern-value covered)))))

(defun validate-match-coverage (syntax scrutinee-type cases)
  (let ((covered '()))
    (dolist (case cases)
      (let ((pattern (match-case-pattern case)))
	(when (find-if (lambda (prior) (pattern-already-covered-p pattern prior)) covered)
	  (error 'unreachable-pattern-error :syntax (pattern-syntax pattern)
		 :message "pattern is unreachable"
		 :covering-pattern (find-if (lambda (prior) (pattern-already-covered-p pattern prior)) covered)))
	(push pattern covered)))
    (labels ((complete-alternative-p (alternative)
               (find-if (lambda (pattern)
                          (and (typep pattern 'constructor-pattern)
                               (eq (constructor-pattern-alternative pattern) alternative)
                               (constructor-pattern-complete-p pattern)))
                        covered)))
      (unless (or (find-if #'pattern-catches-all-p covered)
                  (and (typep scrutinee-type 'sum-type)
                       (every #'complete-alternative-p
                              (sum-type-alternatives scrutinee-type)))
                  (and (typep scrutinee-type 'boolean-type)
                       (find-if (lambda (p)
                                  (and (typep p 'boolean-pattern)
                                       (literal-pattern-value p)))
                                covered)
                       (find-if (lambda (p)
                                  (and (typep p 'boolean-pattern)
                                       (not (literal-pattern-value p))))
                                covered)))
        (error 'non-exhaustive-match-error :syntax syntax
               :message "match is not exhaustive"
               :uncovered
               (cond ((typep scrutinee-type 'boolean-type) "true or false")
                     ((typep scrutinee-type 'sum-type)
                      (format nil "~{~A~^, ~}"
                              (mapcar (lambda (alternative)
                                        (verona-name-value
                                         (sum-alternative-name alternative)))
                                      (remove-if #'complete-alternative-p
                                                 (sum-type-alternatives scrutinee-type)))))
                     (t "a catch-all pattern")))))))

(defun parse-match-cases (syntax scope scrutinee-type)
  (let ((case-syntaxes (cddr (verona-list-elements (syntax-datum syntax)))))
    (unless case-syntaxes
      (error 'invalid-expression-error :syntax syntax :message "match requires at least one case"))
    (let ((cases
	    (mapcar (lambda (case-syntax)
		      (let ((elements (and (verona-list-p (syntax-datum case-syntax))
				   (verona-list-elements (syntax-datum case-syntax)))))
			(unless (= (length elements) 2)
			  (error 'invalid-expression-error :syntax case-syntax
				 :message "match case must be a (pattern expression) list"))
			(let ((case-scope (semantic-scope-child scope)))
			  (make-instance 'match-case :syntax case-syntax :scope case-scope
				 :pattern (analyze-pattern (first elements) case-scope scrutinee-type)
				 :expression (second elements)))))
		    case-syntaxes)))
      (validate-match-coverage syntax scrutinee-type cases)
      cases)))

(defun infer-match-expression (syntax scope &optional expected-type)
  (let* ((elements (verona-list-elements (syntax-datum syntax)))
	 (value (infer-value-expression (second elements) scope))
	 (cases (parse-match-cases syntax scope (expression-type value))))
    ;; Analyse all branch scopes before choosing contextual literal types.
    (let ((result-type expected-type))
      (unless result-type
	(dolist (case cases)
	  (let ((expression (infer-value-expression (match-case-expression case)
							 (match-case-scope case))))
	    (setf (slot-value case 'expression) expression)
	    (unless (typep (expression-type expression) 'never-type)
	      (setf result-type (expression-type expression))
	      (return))))
	(unless result-type
	  (setf result-type (type-context-never-type (semantic-scope-owning-type-context scope)))))
      (dolist (case cases)
	(let ((expression (match-case-expression case)))
	  (setf (slot-value case 'expression)
		(if (typep expression 'expression)
		    (if (or (typep (expression-type expression) 'never-type)
			    (same-type-p (expression-type expression) result-type)) expression
			(check-expression (match-case-expression case) (match-case-scope case) result-type))
		    (check-expression expression (match-case-scope case) result-type)))))
      (make-instance 'match-expression :syntax syntax :value value :cases cases
			     :type result-type))))

(defun infer-return-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax))))
	(function (semantic-scope-owning-function scope)))
    (unless function
      (error 'return-outside-function-error :syntax syntax :message "return is only valid inside a function"))
    (unless (= (length arguments) 1)
      (error 'invalid-expression-error :syntax syntax :message "return requires exactly one value"))
    (make-instance 'return-expression :syntax syntax
		   :value (check-expression (first arguments) scope
				    (if (typep function 'semantic-generic-implementation)
                                        (generic-implementation-result-type function)
                                        (semantic-function-declaration-return-type function)))
		   :type (type-context-never-type (semantic-scope-owning-type-context scope)))))

(defun infer-address-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 1)
      (error 'invalid-expression-error :syntax syntax
				       :message "& requires exactly one operand"))
    (let ((operand (infer-expression (first arguments) scope)))
      (unless (and (typep operand 'place-expression)
		   (place-expression-addressable-p operand))
	(error 'not-addressable-error :syntax (first arguments)
				      :message "expression is not addressable"))
      (make-instance 'address-expression :syntax syntax :operand operand
					 :type (type-context-pointer-type
						(semantic-scope-owning-type-context scope)
						(expression-type operand))))))

(defun infer-dereference-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 1)
      (error 'invalid-expression-error :syntax syntax
				       :message "deref requires exactly one operand"))
    (let* ((operand (infer-value-expression (first arguments) scope))
	   (operand-type (expression-type operand)))
      (unless (typep operand-type 'pointer-type)
	(error 'invalid-expression-error :syntax (first arguments)
					 :message "dereference requires a pointer"))
      (when (typep (pointer-type-pointee operand-type) '(or void-type opaque-type))
	(error 'invalid-expression-error :syntax (first arguments)
					 :message "cannot dereference a pointer to an incomplete type"))
      (make-instance 'dereference-expression :syntax syntax :operand operand
					     :type (pointer-type-target operand-type)
			     :addressable t :writable t))))

(defun infer-pointer-cast-expression (syntax scope)
  "Apply the only initial pointer conversion: T* <-> void*."
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 2)
      (error 'invalid-expression-error :syntax syntax
             :message "cast requires a target type and one operand"))
    (let* ((context (semantic-scope-owning-type-context scope))
           (target (resolve-type context (resolve-type-syntax scope (first arguments))))
           (operand (infer-value-expression (second arguments) scope))
           (source (expression-type operand)))
      (unless (and (typep target 'pointer-type) (typep source 'pointer-type)
                   (or (typep (pointer-type-pointee target) 'void-type)
                       (typep (pointer-type-pointee source) 'void-type)))
        (error 'invalid-expression-error :syntax syntax
               :message "cast permits only (pointer T) to or from (pointer void)"))
      (make-instance 'pointer-cast-expression :syntax syntax :operand operand :type target))))

(defun load-place-expression (syntax place)
  "Make a read from PLACE explicit in the resolved semantic program."
  (unless (and (typep place 'place-expression)
	       (place-expression-addressable-p place))
    (error 'not-addressable-error :syntax syntax :message "load requires an addressable place"))
  (make-instance 'load-expression :syntax syntax :place place :type (expression-type place)))

(defun infer-load-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 1)
      (error 'invalid-expression-error :syntax syntax :message "load requires exactly one operand"))
    (load-place-expression syntax (infer-expression (first arguments) scope))))

(defun infer-value-expression (syntax scope)
  "Infer SYNTAX in a value context, preserving reads as explicit LOAD nodes."
  (let ((expression (infer-expression syntax scope)))
    (if (and (typep expression 'place-expression)
	     (place-expression-addressable-p expression))
	(load-place-expression syntax expression)
	expression)))

(defun infer-assignment-expression (syntax scope)
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 2)
      (error 'invalid-expression-error :syntax syntax
				       :message "assign requires a target and a value"))
    (let ((target (infer-expression (first arguments) scope)))
      (unless (and (typep target 'place-expression)
		   (place-expression-writable-p target))
	(error 'not-writable-error :syntax (first arguments)
				   :message "expression is not writable"))
	      (make-instance 'store-expression :syntax syntax :target target
			    :value (check-expression (second arguments) scope
								     (expression-type target))
					    :type (type-context-unit-type
						   (semantic-scope-owning-type-context scope))))))

(defun infer-expression (syntax scope)
  "Analyze SYNTAX in SCOPE and return a fully typed semantic expression."
  (check-type syntax syntax)
  (check-type scope semantic-scope)
  (let ((datum (syntax-datum syntax))
	(context (semantic-scope-owning-type-context scope)))
    (cond ((unit-literal-p datum)
	   (make-instance 'unit-expression :syntax syntax
					   :value (type-context-unit-value context)
					   :type (type-context-unit-type context)))
	  ((verona-boolean-literal-p datum)
	   (make-instance 'boolean-literal :syntax syntax :value (verona-boolean-literal-value datum)
					   :type (type-context-boolean-type context)))
	  ((characterp datum)
	   ;; Reader-produced characters are ASCII-only.  Keep this check here too
	   ;; because macros can manufacture character syntax directly.
	   (unless (<= (char-code datum) #x7f)
	     (error 'invalid-expression-error :syntax syntax
		    :message "character literals are ASCII-only; Unicode characters are not supported yet"))
	   (make-instance 'character-literal :syntax syntax :value datum
					     :type (type-context-char-type context)))
	  ((integerp datum)
	   (make-instance 'integer-literal :syntax syntax :value datum
					   :type (type-context-integer-type context t 32)))
	  ((floatp datum)
	   (make-instance 'float-literal :syntax syntax :value datum
					 :type (type-context-float-type context 64)))
	  ((stringp datum)
	   ;; Reader-produced strings are ASCII-only.  Keep the semantic boundary
	   ;; just as strict because macros can manufacture string syntax directly.
	   (unless (every (lambda (character) (<= (char-code character) #x7f)) datum)
	     (error 'invalid-expression-error :syntax syntax
		    :message "string literals are ASCII-only; Unicode strings will use #ustring"))
	   (when (position #\Null datum)
	     (error 'invalid-expression-error :syntax syntax
		    :message "string literals cannot contain NUL bytes"))
	   (make-instance 'string-literal :syntax syntax :value datum
			  :type (type-context-pointer-type
				 context (type-context-integer-type context nil 8))))
	  ((or (verona-name-p datum) (qualified-name-p datum))
           (infer-reference-expression syntax scope))
	  ((verona-list-p datum)
	   (let ((elements (verona-list-elements datum)))
	     (unless elements
	       (error 'invalid-expression-error :syntax syntax
						:message "an empty list is not an expression"))
	     (let ((special (expression-special-form-name syntax)))
	       (cond ((and special (string= special "do"))
		      (infer-sequence-expression syntax scope))
		     ((and special (string= special "array-of"))
		      (infer-array-construct-expression syntax scope (rest elements)))
		     ((and special (string= special "index"))
		      (infer-index-expression syntax scope))
		     ((and special (string= special "field"))
		      (infer-field-expression syntax scope))
		     ((and special (string= special "let"))
		      (infer-let-expression syntax scope))
		     ((let-definition-name-p special)
		      (error 'invalid-definition-context-error :syntax syntax
			     :message "constant and variable definitions are only valid at top level"))
		     ((and special (string= special "match"))
		      (let ((elements (verona-list-elements datum)))
			(unless (>= (length elements) 3)
			  (error 'invalid-expression-error :syntax syntax
				 :message "match requires a value and at least one case"))
			(infer-match-expression syntax scope)))
		     ((and special (string= special "return"))
		      (infer-return-expression syntax scope))
		     ((and special (string= special "assign"))
		      (infer-assignment-expression syntax scope))
		     ((and special (string= special "store"))
		      (infer-assignment-expression syntax scope))
		     ((and special (string= special "&"))
		      (infer-address-expression syntax scope))
		     ((and special (string= special "address-of"))
		      (infer-address-expression syntax scope))
		     ((and special (string= special "deref"))
		      (infer-dereference-expression syntax scope))
		     ((and special (string= special "dereference"))
		      (infer-dereference-expression syntax scope))
		     ((and special (string= special "load"))
		      (infer-load-expression syntax scope))
		     ((and special (string= special "cast"))
		      (infer-pointer-cast-expression syntax scope))
		     (t (infer-call-expression syntax scope))))))
	  (t (error 'invalid-expression-error :syntax syntax
					      :message "unsupported expression")))))

(defun check-expression (syntax scope expected-type)
  "Analyze SYNTAX with EXPECTED-TYPE, contextually typing numeric literals."
  (check-type expected-type verona-type)
  (let ((datum (syntax-datum syntax)))
	(cond ((and (verona-list-p datum)
		    (expression-special-form-name syntax)
		    (string= (expression-special-form-name syntax) "array-of"))
	       (infer-array-construct-expression syntax scope
					 (rest (verona-list-elements datum)) expected-type))
	      ((and (verona-list-p datum)
		(expected-sum-constructor syntax expected-type))
	   (multiple-value-bind (alternative foundp)
	       (expected-sum-constructor syntax expected-type)
	     (declare (ignore foundp))
	     (infer-sum-construct-expression
	      syntax scope expected-type alternative
	      (rest (verona-list-elements datum)))))
	  ((and (verona-list-p datum)
		(expression-special-form-name syntax)
		(string= (expression-special-form-name syntax) "match"))
	   (let ((expression (infer-match-expression syntax scope expected-type)))
	     expression))
	  ((and (verona-list-p datum)
		(expression-special-form-name syntax)
		(string= (expression-special-form-name syntax) "let"))
	   (infer-let-expression syntax scope expected-type))
	  ((and (integerp datum) (typep expected-type 'integer-type))
	   (make-instance 'integer-literal :syntax syntax :value datum :type expected-type))
	  ((and (floatp datum) (typep expected-type 'float-type))
	   (make-instance 'float-literal :syntax syntax :value datum :type expected-type))
	  (t (let ((expression (infer-value-expression syntax scope)))
	       (unless (or (typep (expression-type expression) 'never-type)
		   (compatible-p (expression-type expression) expected-type))
		 (error 'type-mismatch-error :syntax syntax
				     :actual (expression-type expression) :expected expected-type))
	       expression)))))

;;; Backend-readiness validation ------------------------------------------

(define-condition backend-validation-error (compiler-bug)
  ((syntax :initarg :syntax :initform nil :reader backend-validation-error-syntax))
  (:documentation "A frontend invariant reached the backend gate."))

;; Stable identities are intentionally assigned near the specialised
;; conditions, not inferred from their reports.  Wording can now evolve
;; without invalidating editor integrations or semantic tests.
(defmethod diagnostic-code-for ((condition expected-type-error))
  (declare (ignore condition)) "E0301")
(defmethod diagnostic-code-for ((condition unknown-type-error))
  (declare (ignore condition)) "E0301")
(defmethod diagnostic-code-for ((condition type-mismatch-error))
  (declare (ignore condition)) "E0401")
(defmethod diagnostic-code-for ((condition wrong-argument-count-error))
  (declare (ignore condition)) "E0501")
(defmethod diagnostic-code-for ((condition generic-arity-mismatch-error))
  (declare (ignore condition)) "E0501")
(defmethod diagnostic-code-for ((condition no-generic-implementation-error))
  (declare (ignore condition)) "E0501")
(defmethod diagnostic-code-for ((condition not-addressable-error))
  (declare (ignore condition)) "E0701")
(defmethod diagnostic-code-for ((condition not-writable-error))
  (declare (ignore condition)) "E0701")

(defmethod diagnostic-for-condition ((condition type-mismatch-error))
  (make-diagnostic
   :severity +error-severity+ :code "E0401" :message (princ-to-string condition)
   :primary-location (condition-primary-range condition)
   :data (list :expected-type (type-mismatch-error-expected condition)
               :actual-type (type-mismatch-error-actual condition))))

(defun backend-validation-fail (object control &rest arguments)
  (error 'backend-validation-error
	 :syntax (and (typep object 'expression) (expression-syntax object))
	 :message (apply #'format nil control arguments)))

(defun backend-representable-type-p (type)
  "Whether TYPE has a complete backend representation contract.

Defined types retain their declaration identity and may be used behind a
pointer.  Their layout is a later type-definition concern.  CHAR is an ASCII
byte value; text literals are NUL-terminated pointers to U8."
  (cond ((or (typep type 'unit-type) (typep type 'boolean-type)
             (typep type 'char-type)) t)
	((typep type 'integer-type) (member (integer-type-width type) '(8 16 32 64)))
	((typep type 'float-type) (member (float-type-width type) '(32 64)))
	((typep type 'pointer-type) (or (typep (pointer-type-pointee type) 'void-type)
				   (backend-representable-type-p (pointer-type-pointee type))))
	((typep type 'array-type)
	 (and (integerp (array-type-length type)) (<= 0 (array-type-length type))
	      (sized-type-p (array-type-element-type type))
	      (backend-representable-type-p (array-type-element-type type))))
	((typep type 'function-type)
	 (and (every #'backend-representable-type-p (function-type-parameters type))
	      (backend-representable-type-p (function-type-result type))))
	((typep type 'product-type)
	 (every (lambda (field)
		  (and (typep field 'product-field)
		       (typep (product-field-type field) 'verona-type)
		       (backend-representable-type-p (product-field-type field))))
		(product-type-fields type)))
	((typep type 'sum-type)
	 (every (lambda (alternative)
		  (and (typep alternative 'sum-alternative)
		       (every #'backend-representable-type-p
			      (sum-alternative-payload-types alternative))))
		(sum-type-alternatives type)))
	((typep type 'defined-type) t)
	(t nil)))

(defun validate-primitive-operation (operation expression)
  (unless (typep operation 'primitive-operation)
    (backend-validation-fail expression "primitive call has no PrimitiveOperation identity"))
  (unless (and (every (lambda (type) (typep type 'verona-type))
		      (primitive-operation-parameter-types operation))
	       (typep (primitive-operation-result-type operation) 'verona-type))
    (backend-validation-fail expression "primitive operation has an unresolved type"))
  (unless (backend-representable-type-p (primitive-operation-result-type operation))
    (backend-validation-fail expression "primitive operation result is not backend representable")))

(defun validate-expression-for-backend (expression)
  (unless (and (typep expression 'expression) (typep (expression-type expression) 'verona-type))
    (backend-validation-fail expression "expression is missing a resolved semantic type"))
  (unless (or (typep (expression-type expression) 'never-type)
	      (backend-representable-type-p (expression-type expression))
	      ;; An external function with a void result is callable but is not a
	      ;; Verona value type.  Its call node supplies unit at the boundary.
	      (and (typep expression 'semantic-reference)
		   (typep (semantic-reference-binding expression)
			  'external-function-declaration)))
    (backend-validation-fail expression "expression type ~A is not backend representable"
			     (verona-type-name (expression-type expression))))
  (cond
    ((typep expression 'array-construct-expression)
     (let ((type (expression-type expression))
           (elements (array-construct-expression-elements expression)))
       (unless (and (typep type 'array-type)
                    (= (length elements) (array-type-length type)))
         (backend-validation-fail expression "array construction is incomplete"))
       (dolist (element elements)
         (validate-expression-for-backend element)
         (unless (compatible-p (expression-type element) (array-type-element-type type))
           (backend-validation-fail expression "array constructor has an incompatible element type")))))
    ((typep expression 'index-expression)
     (let ((base (index-expression-base expression))
           (index (index-expression-index expression)))
       (validate-expression-for-backend base)
       (validate-expression-for-backend index)
       (unless (and (typep (expression-type base) 'array-type)
                    (same-type-p (expression-type expression)
                                 (array-type-element-type (expression-type base)))
                    (same-type-p (index-expression-element-type expression)
                                 (array-type-element-type (expression-type base)))
                    (typep (expression-type index) 'integer-type)
                    (not (integer-type-signed (expression-type index))))
         (backend-validation-fail expression "array index is not fully typed"))
       (when (typep expression 'index-place)
         (unless (and (typep base 'place-expression)
                      (place-expression-addressable-p base)
                      (eq (place-expression-writable-p expression)
                          (place-expression-writable-p base)))
           (backend-validation-fail expression "array index place does not propagate place properties")))))
    ((typep expression 'construct-expression)
     (let ((product-type (construct-expression-product-type expression))
	   (values (construct-expression-fields expression)))
       (unless (and (typep product-type 'product-type)
		    (same-type-p (expression-type expression) product-type)
		    (= (length values) (length (product-type-fields product-type))))
	 (backend-validation-fail expression "product construction is incomplete"))
       (loop for value in values
	     for field in (product-type-fields product-type)
	     do (validate-expression-for-backend value)
		(unless (compatible-p (expression-type value) (product-field-type field))
		  (backend-validation-fail expression "product constructor has an incompatible field type")))))
    ((typep expression 'sum-construct-expression)
     (let* ((alternative (sum-construct-expression-alternative expression))
	    (sum-type (and (typep alternative 'sum-alternative)
			   (sum-alternative-sum-type alternative)))
	    (arguments (sum-construct-expression-arguments expression)))
       (unless (and (typep sum-type 'sum-type)
		    (member alternative (sum-type-alternatives sum-type) :test #'eq)
		    (same-type-p (expression-type expression) sum-type)
		    (= (length arguments) (length (sum-alternative-payload-types alternative))))
	 (backend-validation-fail expression "sum construction is incomplete"))
       (loop for argument in arguments
	     for payload-type in (sum-alternative-payload-types alternative)
	     do (validate-expression-for-backend argument)
		(unless (compatible-p (expression-type argument) payload-type)
		  (backend-validation-fail expression "sum constructor has an incompatible payload type")))))
    ((typep expression 'field-expression)
     (let* ((value (field-expression-value expression))
	    (field (field-expression-field expression))
	    (product-type (expression-type value)))
       (validate-expression-for-backend value)
       (unless (and (typep product-type 'product-type)
		    (typep field 'product-field)
		    (member field (product-type-fields product-type) :test #'eq)
		    (same-type-p (expression-type expression) (product-field-type field)))
	 (backend-validation-fail expression "field access is unresolved or has the wrong type"))))
    ((typep expression 'return-expression)
     (validate-expression-for-backend (return-expression-value expression))
     (unless (and (typep (expression-type expression) 'never-type)
		  (typep (return-expression-value expression) 'expression))
       (backend-validation-fail expression "return is not fully resolved")))
    ((typep expression 'match-expression)
     (validate-expression-for-backend (match-expression-value expression))
	     (unless (or (typep (expression-type (match-expression-value expression)) 'boolean-type)
		 (typep (expression-type (match-expression-value expression)) 'char-type)
		 (typep (expression-type (match-expression-value expression)) 'integer-type)
			 (typep (expression-type (match-expression-value expression)) 'sum-type))
	       (backend-validation-fail expression "match scrutinee has no LLVM comparison lowering"))
     (dolist (case (match-expression-cases expression))
       (let ((pattern (match-case-pattern case))
	     (branch (match-case-expression case)))
	   (unless (and (typep pattern 'pattern)
			(typep (pattern-type pattern) 'verona-type)
			(same-type-p (pattern-type pattern)
				     (expression-type (match-expression-value expression))))
	     (backend-validation-fail expression "match pattern is unresolved or incompatible"))
	   (when (typep pattern 'binding-pattern)
	     (unless (and (typep (binding-pattern-binding pattern) 'pattern-binding)
			  (same-type-p (pattern-binding-type (binding-pattern-binding pattern))
				       (pattern-type pattern)))
	       (backend-validation-fail expression "match binding is unresolved")))
	   (when (typep pattern 'constructor-pattern)
	     (let ((alternative (constructor-pattern-alternative pattern)))
	       (unless (and (typep alternative 'sum-alternative)
			    (eq (sum-alternative-sum-type alternative)
				(expression-type (match-expression-value expression)))
			    (= (length (constructor-pattern-payload-patterns pattern))
			       (length (sum-alternative-payload-types alternative))))
		 (backend-validation-fail expression "constructor pattern is unresolved"))
	       (loop for payload-pattern in (constructor-pattern-payload-patterns pattern)
		     for payload-type in (sum-alternative-payload-types alternative)
		     do (unless (same-type-p (pattern-type payload-pattern) payload-type)
			  (backend-validation-fail expression "constructor payload pattern has the wrong type")))))
	   (validate-expression-for-backend branch)
	   (unless (or (typep (expression-type branch) 'never-type)
		       (same-type-p (expression-type branch) (expression-type expression)))
	     (backend-validation-fail expression "match branch has a different result type")))))
	    ((typep expression 'let-expression)
	     (dolist (binding (let-expression-bindings expression))
	       (unless (and (typep binding 'let-binding)
			    (typep (let-binding-type binding) 'verona-type)
			    (typep (let-binding-initializer binding) 'expression))
		 (backend-validation-fail expression "let binding is incomplete"))
	       (validate-expression-for-backend (let-binding-initializer binding))
       (unless (compatible-p (expression-type (let-binding-initializer binding))
                             (let-binding-type binding))
         (backend-validation-fail expression "let initializer is not representable by its binding type")))
	     (validate-expression-for-backend (let-expression-body expression))
	     (unless (same-type-p (expression-type expression)
			  (expression-type (let-expression-body expression)))
	       (backend-validation-fail expression "let result type is not its body type")))
    ((typep expression 'unit-expression)
     (unless (typep (expression-type expression) 'unit-type)
       (backend-validation-fail expression "UnitValue does not have UnitType")))
    ((typep expression 'semantic-reference)
     (unless (semantic-reference-binding expression)
       (backend-validation-fail expression "reference is unresolved")))
    ((typep expression 'load-expression)
     (let ((place (load-expression-place expression)))
       (validate-expression-for-backend place)
       (unless (and (typep place 'place-expression)
		    (place-expression-addressable-p place)
		    (same-type-p (expression-type place) (expression-type expression)))
	 (backend-validation-fail expression "load does not read its exactly typed place"))))
    ((typep expression 'address-expression)
     (let ((place (address-expression-operand expression)))
       (validate-expression-for-backend place)
       (unless (and (typep place 'place-expression)
		    (place-expression-addressable-p place)
		    (typep (expression-type expression) 'pointer-type)
		    (same-type-p (pointer-type-pointee (expression-type expression))
			 (expression-type place)))
	 (backend-validation-fail expression "address-of is not fully typed"))))
    ((typep expression 'dereference-expression)
     (validate-expression-for-backend (dereference-expression-operand expression))
     (unless (and (typep (expression-type (dereference-expression-operand expression)) 'pointer-type)
		  (not (typep (pointer-type-pointee
			       (expression-type (dereference-expression-operand expression)))
			      'void-type))
		  (same-type-p (expression-type expression)
		       (pointer-type-pointee (expression-type (dereference-expression-operand expression)))))
	(backend-validation-fail expression "dereference is not fully typed")))
    ((typep expression 'pointer-cast-expression)
     (validate-expression-for-backend (pointer-cast-expression-operand expression))
     (unless (and (typep (expression-type expression) 'pointer-type)
		  (typep (expression-type (pointer-cast-expression-operand expression)) 'pointer-type)
		  (or (typep (pointer-type-pointee (expression-type expression)) 'void-type)
		      (typep (pointer-type-pointee
			      (expression-type (pointer-cast-expression-operand expression))) 'void-type)))
	(backend-validation-fail expression "pointer cast is not a void pointer conversion")))
    ((typep expression 'store-expression)
     (validate-expression-for-backend (assignment-expression-target expression))
     (validate-expression-for-backend (assignment-expression-value expression))
     (unless (and (typep (assignment-expression-target expression) 'place-expression)
		  (place-expression-writable-p (assignment-expression-target expression))
		  (compatible-p (expression-type (assignment-expression-value expression))
		                (expression-type (assignment-expression-target expression)))
		  (typep (expression-type expression) 'unit-type))
	(backend-validation-fail expression "store is not exactly typed")))
    ((typep expression 'sequence-expression)
     (let ((children (sequence-expression-expressions expression)))
       (dolist (child children)
	 (validate-expression-for-backend child))
       (if children
	   (unless (same-type-p (expression-type expression)
			      (expression-type (car (last children))))
	     (backend-validation-fail expression "sequence result type is not its final value"))
	   (unless (typep (expression-type expression) 'unit-type)
	     (backend-validation-fail expression "empty sequence does not produce unit")))))
    ((typep expression 'primitive-call)
     (let ((operation (primitive-call-operation expression))
	   (arguments (semantic-call-arguments expression)))
       (validate-primitive-operation operation expression)
       (unless (= (length arguments) (length (primitive-operation-parameter-types operation)))
	 (backend-validation-fail expression "primitive call has an invalid argument count"))
       (loop for argument in arguments
	     for parameter in (primitive-operation-parameter-types operation)
	     do (validate-expression-for-backend argument)
		(unless (compatible-p (expression-type argument) parameter)
		  (backend-validation-fail expression "primitive call has an incompatible argument type")))
       (unless (same-type-p (expression-type expression) (primitive-operation-result-type operation))
	 (backend-validation-fail expression "primitive call result type disagrees with its operation"))))
    ((typep expression 'external-call-expression)
     (validate-expression-for-backend (semantic-call-callee expression))
     (let* ((external (external-call-expression-external-function expression))
	    (callee-type (expression-type (semantic-call-callee expression))))
       (unless (and (typep external 'semantic-external-function-declaration)
		    (typep callee-type 'function-type)
		    (eq (semantic-reference-binding (semantic-call-callee expression))
			(semantic-declaration-source-declaration external)))
	 (backend-validation-fail expression "external call has no resolved external declaration"))
       (loop for argument in (semantic-call-arguments expression)
	     for parameter in (function-type-parameters callee-type)
	     do (validate-expression-for-backend argument)
		(unless (compatible-p (expression-type argument) parameter)
		  (backend-validation-fail expression "external call has an incompatible argument type")))
       (unless (= (length (semantic-call-arguments expression))
		  (length (function-type-parameters callee-type)))
	 (backend-validation-fail expression "external call has an invalid argument count"))
       (unless (if (typep (function-type-result callee-type) 'void-type)
		   (typep (expression-type expression) 'unit-type)
		   (same-type-p (expression-type expression)
				(function-type-result callee-type)))
	 (backend-validation-fail expression "external call result has the wrong Verona type"))))
    ((typep expression 'semantic-call)
     (validate-expression-for-backend (semantic-call-callee expression))
     (let ((callee-type (expression-type (semantic-call-callee expression))))
       (unless (typep callee-type 'function-type)
	 (backend-validation-fail expression "call target is not callable"))
       (unless (= (length (semantic-call-arguments expression))
		  (length (function-type-parameters callee-type)))
	 (backend-validation-fail expression "call has an invalid argument count"))
       (loop for argument in (semantic-call-arguments expression)
	     for parameter in (function-type-parameters callee-type)
	     do (validate-expression-for-backend argument)
		(unless (compatible-p (expression-type argument) parameter)
		  (backend-validation-fail expression "call has an incompatible argument type")))
       (unless (same-type-p (expression-type expression) (function-type-result callee-type))
	 (backend-validation-fail expression "call result type disagrees with callee type"))))))

(defun validate-concrete-function-for-backend (declaration)
  "Validate one non-template function declaration for LLVM lowering."
  (unless (null (semantic-function-declaration-type-parameters declaration))
    (backend-validation-fail nil "LLVM received a polymorphic function template"))
  (let ((type (semantic-function-declaration-type declaration)))
    (unless (and (typep type 'function-type)
                 (equal (function-type-parameters type)
                        (mapcar #'parameter-binding-type
                                (semantic-function-declaration-parameters declaration)))
                 (same-type-p (function-type-result type)
                              (semantic-function-declaration-return-type declaration)))
      (backend-validation-fail nil "function signature is incomplete"))
    (validate-expression-for-backend (semantic-function-declaration-body declaration))
    (unless (or (typep (expression-type (semantic-function-declaration-body declaration)) 'never-type)
                (compatible-p (expression-type (semantic-function-declaration-body declaration))
                              (semantic-function-declaration-return-type declaration)))
      (backend-validation-fail (semantic-function-declaration-body declaration)
                               "function result is not exactly typed"))))

(defun validate-for-backend (program)
  "Final frontend gate: return PROGRAM only when LLVM lowering is mechanical."
  (check-type program semantic-program)
  (let ((context (semantic-program-type-context program)))
    (unless (member (type-context-pointer-width context) '(32 64))
      (backend-validation-fail nil "target pointer width is not representable"))
    (unless (and (typep (type-context-unit-type context) 'unit-type)
		 (typep (type-context-unit-value context) 'unit-value)
		 (= (unit-machine-representation context (type-context-unit-value context)) 0))
      (backend-validation-fail nil "unit does not have its canonical zero representation"))
    ;; Validate the entire bootstrapped primitive environment, not merely the
    ;; subset reached by this program's source.  A backend therefore has one
    ;; closed, representable primitive vocabulary to implement.
    (dolist (entry (semantic-scope-bindings (semantic-program-bootstrap-scope program)))
      (let ((binding (cdr entry)))
	(when (typep binding 'primitive-binding)
	  (validate-primitive-operation (primitive-binding-operation binding) nil))))
    (dolist (entry (semantic-program-declarations program))
      (let ((declaration (cdr entry)))
	(cond ((typep declaration 'semantic-function-declaration)
	       ;; A polymorphic declaration is a template.  Its body contains
	       ;; TypeParameter identities by design and becomes LLVM-ready only
	       ;; after a concrete specialization has been selected.
	       (unless (semantic-function-declaration-type-parameters declaration)
	         (validate-concrete-function-for-backend declaration)))
	      ((typep declaration 'semantic-external-function-declaration)
	       (let ((type (semantic-external-function-declaration-type declaration)))
		 (unless (and (typep type 'function-type)
			      (equal (function-type-parameters type)
				     (semantic-external-function-declaration-parameter-types declaration))
			      (same-type-p (function-type-result type)
				   (semantic-external-function-declaration-result-type declaration)))
		   (backend-validation-fail nil "external function signature is incomplete"))
		 (validate-external-function-signature declaration)))
	      ((typep declaration 'semantic-generic-declaration)
               (let ((generic (semantic-generic-declaration-generic declaration)))
                 (unless (and (typep generic 'generic)
                              (= (generic-arity generic)
                                 (generic-declaration-arity
                                  (semantic-declaration-source-declaration declaration))))
                   (backend-validation-fail nil "generic declaration is incomplete"))))
	      ((typep declaration 'semantic-generic-implementation)
               (let ((type (semantic-generic-implementation-type declaration))
                     (body (generic-implementation-body declaration)))
                 (unless (and (typep type 'function-type)
                              (= (length (generic-implementation-parameters declaration))
                                 (generic-arity (generic-implementation-generic declaration)))
                              (equal (function-type-parameters type)
                                     (generic-implementation-parameter-types declaration))
                              (same-type-p (function-type-result type)
                                           (generic-implementation-result-type declaration)))
                   (backend-validation-fail nil "generic implementation signature is incomplete"))
                 (validate-expression-for-backend body)
                 (unless (or (typep (expression-type body) 'never-type)
                             (compatible-p (expression-type body)
                                           (generic-implementation-result-type declaration)))
                   (backend-validation-fail body "generic implementation result is incompatible"))))
	      ((typep declaration 'semantic-type-declaration)
	       (let ((type (semantic-type-declaration-type declaration)))
		 (unless (or (and (typep type 'opaque-type)
				  (eq (defined-type-declaration type)
				      (semantic-declaration-source-declaration declaration)))
			     (and (typep type '(or product-type sum-type))
				  (eq (defined-type-declaration type)
				      (semantic-declaration-source-declaration declaration))
				  (if (typep type 'product-type)
				      (loop for field in (product-type-fields type)
					    for index from 0
					    always (and (typep field 'product-field)
							(typep (product-field-name field) 'verona-name)
							(= (product-field-index field) index)
							(backend-representable-type-p (product-field-type field))))
				      (loop for alternative in (sum-type-alternatives type)
					    for index from 0
					    always (and (typep alternative 'sum-alternative)
							(eq (sum-alternative-sum-type alternative) type)
							(typep (sum-alternative-name alternative) 'verona-name)
							(= (sum-alternative-index alternative) index)
							(every #'backend-representable-type-p
							       (sum-alternative-payload-types alternative)))))))
		   (backend-validation-fail nil "type declaration is incomplete"))))
	      ((typep declaration 'semantic-constant-declaration)
	       (let ((initializer (semantic-constant-declaration-initializer declaration)))
	       (when (typep (semantic-constant-declaration-type declaration) '(or product-type sum-type array-type))
		   (backend-validation-fail initializer
			    "top-level aggregate constants are not supported yet"))
		 (validate-expression-for-backend initializer)
		 (unless (compatible-p (expression-type initializer)
			      (semantic-constant-declaration-type declaration))
		   (backend-validation-fail initializer "constant initializer is incompatible"))))
	      ((typep declaration 'semantic-variable-declaration)
	       (let ((initializer (semantic-variable-declaration-initializer declaration)))
	       (when (typep (semantic-variable-declaration-type declaration) '(or product-type sum-type array-type))
		   (backend-validation-fail initializer
			    "top-level aggregate variables are not supported yet"))
		 (validate-expression-for-backend initializer)
		 (unless (compatible-p (expression-type initializer)
			      (semantic-variable-declaration-type declaration))
		   (backend-validation-fail initializer "variable initializer is incompatible"))))))
	;; Generated instances are not source declarations, so validate their
	;; complete substituted bodies separately.  This is the final guarantee
	;; that LLVM never observes a TypeParameter or unresolved protocol call.
	(dolist (entry (semantic-program-declarations program))
	  (let ((declaration (cdr entry)))
	    (when (typep declaration 'semantic-protocol-implementation)
	      (dolist (operation (protocol-implementation-operations
	                          (semantic-protocol-implementation-implementation declaration)))
	        (validate-concrete-function-for-backend (cdr operation))))))
	(dolist (specialization (semantic-program-function-specializations program))
	  (validate-concrete-function-for-backend specialization)))
  program))

(defun resolve-declaration-body (program semantic-declaration)
  (let ((declaration (semantic-declaration-source-declaration semantic-declaration)))
    (cond ((typep semantic-declaration 'semantic-function-declaration)
	   (setf (semantic-function-declaration-body semantic-declaration)
		 (check-expression
		  (function-declaration-body declaration)
		  (semantic-function-declaration-scope semantic-declaration)
		  (semantic-function-declaration-return-type semantic-declaration))))
	  ((typep semantic-declaration 'semantic-generic-implementation)
           (setf (generic-implementation-body semantic-declaration)
                 (check-expression
                  (implementation-declaration-body declaration)
                  (semantic-generic-implementation-scope semantic-declaration)
                  (generic-implementation-result-type semantic-declaration))))
	  ((typep semantic-declaration 'semantic-protocol-implementation)
           (dolist (entry (protocol-implementation-operations
                           (semantic-protocol-implementation-implementation semantic-declaration)))
             (let ((operation-function (cdr entry)))
               (setf (semantic-function-declaration-body operation-function)
                     (check-expression
                      (function-declaration-body
                       (semantic-declaration-source-declaration operation-function))
                      (semantic-function-declaration-scope operation-function)
                      (semantic-function-declaration-return-type operation-function))))))
	  ((typep semantic-declaration 'semantic-constant-declaration)
	   (setf (semantic-constant-declaration-initializer semantic-declaration)
		 (check-expression
		  (constant-declaration-value declaration)
		  (semantic-program-module-scope-for program (declaration-module declaration))
		  (semantic-constant-declaration-type semantic-declaration))))
	  ((typep semantic-declaration 'semantic-variable-declaration)
	   (setf (semantic-variable-declaration-initializer semantic-declaration)
		 (check-expression
		  (variable-declaration-initializer declaration)
		  (semantic-program-module-scope-for program (declaration-module declaration))
		  (semantic-variable-declaration-type semantic-declaration)))))))

(defun resolve-program (entry-module modules &key target (pointer-width 64))
  "Resolve a graph of already-loaded modules into one semantic Program.

Every module has an isolated semantic scope; only QualifiedName resolution
crosses the import/export boundary.  The shared type context makes the result
ready for lowering as one LLVM module."
  (check-type entry-module module)
  (let* ((type-context (make-type-context :pointer-width pointer-width))
	 (bootstrap (make-bootstrap-semantic-scope type-context))
         (entry-scope (semantic-scope-child bootstrap))
	 (program (make-instance 'program :bootstrap-scope bootstrap
						   :module-scope entry-scope
						   :type-context type-context
                           :target target
                           :entry-module entry-module :modules modules
                           :module-graph
                           (make-instance 'module-graph :modules modules
                                          :edges (mapcar (lambda (module)
                                                           (cons module (mapcar #'import-module
                                                                                (module-imports module))))
                                                         modules)))))
    (setf (semantic-scope-program bootstrap) program)
    (dolist (module modules)
      (let ((scope (if (eq module entry-module) entry-scope
                       (semantic-scope-child bootstrap))))
        (setf (semantic-scope-module scope) module)
        (push (cons module scope) (semantic-program-module-scopes program))))
    ;; Establish every semantic identity before publishing runtime names.
    ;; Implementations deliberately do not occupy the module namespace.
    (dolist (module modules)
      (dolist (declaration (unit-declarations module))
        (unless (typep declaration 'macro-declaration)
          (let ((semantic-declaration (make-semantic-declaration declaration)))
            (push (cons declaration semantic-declaration)
                  (semantic-program-declarations program))))))
    (setf (semantic-program-declarations program)
	  (nreverse (semantic-program-declarations program)))
    (dolist (entry (semantic-program-declarations program))
      (let* ((declaration (car entry))
             (semantic-declaration (cdr entry))
             (module-scope (semantic-program-module-scope-for
                            program (declaration-module declaration))))
        (cond ((typep semantic-declaration 'semantic-generic-declaration)
               (let ((generic (semantic-generic-declaration-generic semantic-declaration)))
                 (semantic-scope-bind module-scope (declaration-name declaration)
                                      (make-instance 'generic-binding
                                                     :name (declaration-name declaration)
                                                     :generic generic))))
              ((typep semantic-declaration 'semantic-protocol-declaration)
               (semantic-scope-bind module-scope (declaration-name declaration)
                                    (make-instance 'protocol-binding
                                                   :name (declaration-name declaration)
                                                   :protocol (semantic-protocol-declaration-protocol
                                                              semantic-declaration))))
	      ((typep semantic-declaration 'semantic-type-alias-declaration)
               (semantic-scope-bind module-scope (declaration-name declaration)
                                    (make-instance 'type-alias-binding
                                                   :name (declaration-name declaration)
                                                   :declaration declaration
                                                   :semantic-declaration semantic-declaration)))
              ((not (typep declaration 'implementation-declaration))
               (semantic-scope-bind module-scope (declaration-name declaration) declaration)))))
    (dolist (entry (semantic-program-declarations program))
      (resolve-declaration-signature program (cdr entry)))
    (resolve-types program)
    (dolist (entry (semantic-program-declarations program))
      (resolve-declaration-body program (cdr entry)))
    (resolve-native-exports program modules)
    (validate-for-backend program)
    (dolist (module modules)
      (setf (compilation-unit-semantic-program module) program))
    program))

(defun resolve-compilation-unit (unit)
  "Compatibility entry point for the original single-file compiler API."
  (check-type unit compilation-unit)
  (if (typep unit 'module)
      (resolve-program unit (list unit))
      (error "compilation units must now be modules")))
