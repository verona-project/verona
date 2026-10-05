(in-package #:verona)

(defclass compiler ()
  ((search-paths :initarg :search-paths :initform '() :reader compiler-search-paths)
   ;; Timing is opt-in observability.  It does not affect semantic traversal
   ;; or make timing data part of compilation output.
   (phase-timing-p :initarg :phase-timing-p :initform nil :reader compiler-phase-timing-p)
   (phase-timings :initform '() :accessor compiler-phase-timings)))

(defun make-compiler (&key (search-paths '()) (phase-timing-p nil))
  (make-instance 'compiler :search-paths (mapcar #'pathname search-paths)
                 :phase-timing-p phase-timing-p))

(defgeneric target-feature-names (target)
  (:documentation "Return the source-reader features available for TARGET.

Backends specialize this protocol for their target representation.  The
front-end knows only feature names, avoiding a dependency on a native backend."))

(defun host-target-feature-names ()
  "Return source-reader platform features for an implicit native target."
  (cond ((string-equal (software-type) "Darwin") '("darwin"))
        ((string-equal (software-type) "Linux") '("linux"))
        (t '())))

(defmethod target-feature-names ((target null))
  (host-target-feature-names))

(defmethod target-feature-names ((target t))
  (declare (ignore target))
  '())

(defun clear-compiler-phase-timings (compiler)
  (setf (compiler-phase-timings compiler) '()) compiler)

(defun call-with-compiler-phase (compiler phase thunk)
  "Call THUNK and, when enabled, record PHASE's elapsed milliseconds."
  (if (and compiler (compiler-phase-timing-p compiler))
      (let ((start (get-internal-real-time)))
        (multiple-value-prog1 (funcall thunk)
          (setf (compiler-phase-timings compiler)
                (append (compiler-phase-timings compiler)
                        (list (cons phase
                                    (* 1000.0
                                       (/ (- (get-internal-real-time) start)
                                          internal-time-units-per-second))))))))
      (funcall thunk)))

(defclass compilation-unit ()
  ((source :initarg :source
           :reader compilation-unit-source
           :reader module-source)
   ;; FORMS preserves the source program independently of declaration
   ;; discovery.  Later phases may decide what to do with non-definition
   ;; top-level forms without losing the original syntax.
   (forms :initarg :forms
          :reader compilation-unit-forms
          :reader module-forms)
   (declarations :initform '()
                 :accessor compilation-unit-declarations
                 :accessor module-declarations)
   ;; This alist is deliberately separate from DECLARATIONS: registration
   ;; order is meaningful, while lookup needs a single namespace.
   (namespace :initform '()
              :accessor compilation-unit-namespace
              :accessor module-namespace)
   (environment :initarg :environment
                :reader compilation-unit-environment
                :reader compilation-unit-compile-time-environment
                :reader module-environment)
   ;; Populated only after declaration collection.  This is intentionally not
   ;; the compile-time ENVIRONMENT above: it contains resolved compiler
   ;; entities rather than evaluator bindings or macros.
   (semantic-program :initform nil
                     :accessor compilation-unit-semantic-program)))

;; MODULE was the name used by the preceding foundation stages.  Keep the
;; legacy class as a compatibility subclass while new callers use
;; COMPILATION-UNIT, which does not prematurely imply package or import
;; semantics.
(defclass module (compilation-unit)
  ((name :initarg :name :reader module-name)
   (pathname :initarg :pathname :initform nil :reader module-pathname)
   (imports :initform '() :accessor module-imports)
   (import-table :initform '() :accessor module-import-table)
   (export-names :initform '() :accessor module-export-names)
   (exports :initform '() :accessor module-exports)
   ;; Native exports are deliberately separate from VERONA EXPORT forms.
   ;; Each entry is a NATIVE-EXPORT-SPEC retained until semantic resolution.
   (native-export-specs :initform '() :accessor module-native-export-specs)
   (identity-explicit-p :initarg :identity-explicit-p :initform t
                        :reader module-identity-explicit-p)))

(defclass import ()
  ((module :initarg :module :reader import-module)
   (alias :initarg :alias :initform nil :reader import-alias)
   (source :initarg :source :reader import-source)))

(defclass native-export-spec ()
  ((name :initarg :name :reader native-export-spec-name)
   (external-name :initarg :external-name :reader native-export-spec-external-name)
   (source :initarg :source :reader native-export-spec-source)))

(defclass module-loader ()
  ((search-paths :initarg :search-paths :reader module-loader-search-paths)
   (features :initarg :features :initform '() :reader module-loader-features)
   (loaded-modules :initform '() :accessor module-loader-loaded-modules)
   (loading-stack :initform '() :accessor module-loader-loading-stack)))

(defclass module-graph ()
  ((modules :initarg :modules :reader module-graph-modules)
   (edges :initarg :edges :reader module-graph-edges)))

(define-condition module-error (user-compilation-error)
  ((module :initarg :module :initform nil :reader module-error-module)
   (source :initarg :source :initform nil :reader module-error-source)))
(define-condition module-not-found (module-error) ())
(define-condition duplicate-module (module-error) ())
(define-condition circular-module-dependency (module-error)
  ((cycle :initarg :cycle :reader circular-module-dependency-cycle)))
(define-condition duplicate-import-alias (module-error)
  ((alias :initarg :alias :reader duplicate-import-alias-alias)))
(define-condition unknown-export (module-error)
  ((name :initarg :name :reader unknown-export-name)))

(defmethod diagnostic-code-for ((condition module-error))
  (declare (ignore condition)) "E0901")

(defmethod condition-primary-range ((condition module-error))
  (let ((source (module-error-source condition)))
    (and (typep source 'syntax) (syntax-source-range source))))

(defun parse-module-name (syntax)
  "Turn import syntax into a ModuleName without making ordinary names modules."
  (let ((datum (syntax-datum syntax)))
    (unless (verona-name-p datum)
      (error 'module-error :source syntax :module nil))
    (let ((text (verona-name-value datum)))
      (when (or (string= text "")
                (some (lambda (component) (string= component ""))
                      (uiop:split-string text :separator ".")))
        (error 'module-error :source syntax :module nil))
      (apply #'make-module-name
             (mapcar #'make-verona-name (uiop:split-string text :separator "."))))))

(defun module-name-from-pathname (pathname)
  (let ((name (pathname-name (pathname pathname))))
    (unless name (error 'module-error :module nil))
    (parse-module-name
     (make-syntax (make-verona-name name)
                  (make-source (namestring pathname) "")
                  (make-source-location) (make-source-location)))))

(defun import-qualifier-name (import)
  (or (import-alias import)
      (make-verona-name (module-name-string (module-name (import-module import))))))

(defun module-find-import (module qualifier)
  (find qualifier (module-imports module) :key #'import-qualifier-name
        :test #'verona-name=))

(defun module-find-export (module name)
  (cdr (assoc name (module-exports module) :test #'verona-name=)))

(defclass declaration (semantic-binding)
  (;; SOURCE is the original complete top-level form, not a resolved compiler
   ;; type or value.  All declaration-specific content remains source-aware.
   (source :initarg :source :reader declaration-source)
   ;; The primitive definition syntax produced by top-level expansion.  It is
   ;; intentionally distinct from SOURCE when a macro produced the definition.
   (expanded-syntax :initarg :expanded-syntax :reader declaration-expanded-syntax)
   (module :initarg :module
           :reader declaration-module
           :reader declaration-compilation-unit)
   ;; Named primitive-definition clauses are retained independently from a
   ;; declaration's legacy positional fields.  This makes documentation and
   ;; declaration-level type syntax available to compile-time clients without
   ;; forcing every kind of declaration to manufacture a runtime body.
   (documentation :initarg :documentation :initform nil
                  :reader declaration-documentation)
   (documentation-syntax :initarg :documentation-syntax :initform nil
                         :reader declaration-documentation-syntax)
   (type-declaration :initarg :type-declaration :initform nil
                     :reader declaration-type-declaration)))

(defclass type-declaration (declaration)
  ((kind :initarg :kind :reader type-declaration-kind)
   (body :initarg :body :reader type-declaration-body)))

;; TYPE has four explicit surface shapes.  Products, sums, and opaque types
;; retain nominal identity; aliases deliberately do not, and instead resolve to
;; their target type.  Keeping aliases as a distinct declaration avoids
;; treating a spelling such as `(type UserId i64)` as an empty product.
(defclass type-alias-declaration (declaration)
  ((target :initarg :target :reader type-alias-declaration-target)))

(defclass function-declaration (declaration)
  ((for-clause :initarg :for-clause :initform nil
               :reader function-declaration-for-clause)
   (parameters :initarg :parameters :reader function-declaration-parameters)
   (return-type :initarg :return-type :reader function-declaration-return-type)
   (body :initarg :body :reader function-declaration-body)))

;; Foreign declarations retain their linker spelling independently from their
;; Verona binding name.  Their signatures use the ordinary Verona type syntax.
(defclass external-function-declaration (declaration)
  ((external-name :initarg :external-name :reader external-function-declaration-external-name)
   (parameter-types :initarg :parameter-types :reader external-function-declaration-parameter-types)
   (result-type :initarg :result-type :reader external-function-declaration-result-type)))

(defclass macro-declaration (declaration)
  ((parameters :initarg :parameters :reader macro-declaration-parameters)
   (body :initarg :body :reader macro-declaration-body)))

(defclass constant-declaration (declaration)
  ((type :initarg :type :reader constant-declaration-type)
   (value :initarg :value :reader constant-declaration-value)))

(defclass variable-declaration (declaration)
  ((type :initarg :type :reader variable-declaration-type)
   (initializer :initarg :initializer :reader variable-declaration-initializer)))

(defclass generic-declaration (declaration)
  ((parameters :initarg :parameters :reader generic-declaration-parameters)
   (arity :initarg :arity :reader generic-declaration-arity)))

(defclass implementation-declaration (declaration)
  ((generic-name :initarg :generic-name :initform nil
                 :reader implementation-declaration-generic-name)
   (parameters :initarg :parameters :initform nil
               :reader implementation-declaration-parameters)
   (return-type :initarg :return-type :initform nil
                :reader implementation-declaration-return-type)
   (body :initarg :body :initform nil :reader implementation-declaration-body)
   ;; The older concrete generic implementation spelling remains supported;
   ;; a non-NIL application selects the Step 18 protocol form.
   (protocol-application :initarg :protocol-application :initform nil
                         :reader implementation-declaration-protocol-application)
   (operations :initarg :operations :initform '()
               :reader implementation-declaration-operations)))

;; Protocol declarations deliberately retain their operation forms as source
;; syntax.  Their parameter names are type-level bindings, and therefore may
;; only be interpreted after the module's semantic scope has been created.
(defclass protocol-declaration (declaration)
  ((parameters :initarg :parameters :reader protocol-declaration-parameters)
   (operations :initarg :operations :reader protocol-declaration-operations)))

(define-condition definition-error (user-compilation-error)
  ((syntax :initarg :syntax :reader definition-error-syntax)
   (message :initarg :message :reader definition-error-message))
  (:report (lambda (condition stream)
             (let* ((syntax (definition-error-syntax condition))
                    (location (syntax-start syntax)))
               (format stream "~A:~D:~D: ~A"
                       (source-name (syntax-source syntax))
                       (source-location-line location)
                       (source-location-column location)
                       (definition-error-message condition))))))

(define-condition duplicate-declaration-error (definition-error)
  ((name :initarg :name :reader duplicate-declaration-error-name)
   (existing :initarg :existing :reader duplicate-declaration-error-existing))
  (:report (lambda (condition stream)
             (let* ((syntax (definition-error-syntax condition))
                    (location (syntax-start syntax))
                    (existing-source
                      (declaration-source
                       (duplicate-declaration-error-existing condition)))
                    (existing-location (syntax-start existing-source)))
               (format stream "~A:~D:~D: duplicate definition `~A`~%~%previous definition:~%~A:~D:~D"
                       (source-name (syntax-source syntax))
                       (source-location-line location)
                       (source-location-column location)
                       (verona-name-value (duplicate-declaration-error-name condition))
                       (source-name (syntax-source existing-source))
                       (source-location-line existing-location)
                       (source-location-column existing-location))))))

(define-condition non-definition-top-level-error (definition-error) ())

(defmethod diagnostic-code-for ((condition definition-error))
  (declare (ignore condition)) "E0001")

(defmethod diagnostic-code-for ((condition duplicate-declaration-error))
  (declare (ignore condition)) "E0101")

(defmethod condition-primary-range ((condition definition-error))
  (syntax-source-range (definition-error-syntax condition)))

(defmethod diagnostic-for-condition ((condition duplicate-declaration-error))
  (let ((previous (declaration-source
                   (duplicate-declaration-error-existing condition))))
    (make-diagnostic
     :severity +error-severity+ :code "E0101"
     :message (format nil "duplicate declaration `~A`"
                      (verona-name-value (duplicate-declaration-error-name condition)))
     :primary-location (condition-primary-range condition)
     :secondary-locations (list (syntax-source-range previous))
     :notes (list "previous declaration is here"))))

(defstruct (top-level-expansion-result
            (:constructor make-top-level-expansion-result (definitions)))
  "The unambiguous, internal result of expanding one top-level source form.

  DEFINITIONS is a list of primitive definition S-expressions.  A distinct
  result object avoids treating an ordinary list expression as several forms."
  (definitions '() :type list))

(defparameter +definition-form-names+
  '("%type" "%function" "%external-function" "%macro" "%constant" "%variable" "%generic" "%implementation" "%protocol"))

(defun definition-head-name (syntax)
  "Return SYNTAX's definition-form name, or NIL when it is not one."
  (let ((datum (syntax-datum syntax)))
    (when (verona-list-p datum)
      (let ((elements (verona-list-elements datum)))
        (when elements
          (let ((head (syntax-datum (first elements))))
            (and (verona-name-p head)
                 (find (verona-name-value head) +definition-form-names+
                       :test #'string=))))))))

(defun definition-form-p (syntax)
  "Whether SYNTAX has one of the primitive top-level definition heads."
  (check-type syntax syntax)
  (not (null (definition-head-name syntax))))

(defun definition-fail (syntax control &rest arguments)
  (error 'definition-error
         :syntax syntax
         :message (apply #'format nil control arguments)))

(defun definition-name (syntax name-syntax)
  (let ((name (syntax-datum name-syntax)))
    (unless (verona-name-p name)
      (definition-fail syntax "definition name must be a Verona name"))
    name))

(defun definition-elements (syntax expected-name minimum-arguments)
  "Return definition arguments after validating the primitive form's arity."
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (when (< (length arguments) minimum-arguments)
      (definition-fail syntax "%~A requires at least ~D argument~:P"
                       expected-name minimum-arguments))
    arguments))

(defun definition-clause-p (syntax)
  "Whether SYNTAX has the single-value `(:keyword value)` clause shape."
  (let ((datum (syntax-datum syntax)))
    (and (verona-list-p datum)
         (= (length (verona-list-elements datum)) 2)
         (let ((head (syntax-datum (first (verona-list-elements datum)))))
           (and (verona-name-p head)
                (plusp (length (verona-name-value head)))
                (char= (char (verona-name-value head) 0) #\:))))))

(defun parse-definition-clauses (definition clauses allowed required)
  "Validate and index named primitive-definition CLAUSES.

The returned alist maps a clause spelling such as `:type` to its value syntax.
Every accepted clause deliberately has one value; multi-item payloads use an
ordinary Verona list as that value, preserving an unambiguous source span."
  (let ((result '()))
    (dolist (clause clauses)
      (unless (definition-clause-p clause)
        (definition-fail clause "definition clauses must have the shape (:keyword value)"))
      (let* ((elements (verona-list-elements (syntax-datum clause)))
             (name (verona-name-value (syntax-datum (first elements))))
             (value (second elements)))
        (unless (member name allowed :test #'string=)
          (definition-fail clause "~A does not accept the ~A clause" definition name))
        (when (assoc name result :test #'string=)
          (definition-fail clause "duplicate ~A clause" name))
        (push (cons name value) result)))
    (dolist (name required)
      (unless (assoc name result :test #'string=)
        (definition-fail definition "definition requires a ~A clause" name)))
    result))

(defun definition-clause-value (clauses name)
  (cdr (assoc name clauses :test #'string=)))

(defun definition-documentation-initargs (definition clauses)
  "Return constructor arguments for a declaration's optional documentation."
  (let ((syntax (definition-clause-value clauses ":documentation")))
    (if syntax
        (let ((text (syntax-datum syntax)))
          (unless (stringp text)
            (definition-fail syntax "documentation must be a string"))
          (list :documentation text :documentation-syntax syntax))
        '())))

(defun function-type-declaration-components (definition type-syntax)
  "Decode `(:type (function PARAMETERS RESULT))` for callable declarations."
  (unless (verona-list-p (syntax-datum type-syntax))
    (definition-fail type-syntax "function type declaration must be a list"))
  (let ((elements (verona-list-elements (syntax-datum type-syntax))))
    (unless (and (= (length elements) 3)
                 (verona-name-p (syntax-datum (first elements)))
                 (string= (verona-name-value (syntax-datum (first elements)))
                           "function"))
      (definition-fail type-syntax
                       "function type declaration must be (function (parameters...) result)"))
    (values (second elements) (third elements))))

(defun definition-list-clause (definition syntax description)
  (unless (verona-list-p (syntax-datum syntax))
    (definition-fail syntax "~A must be a list" description))
  syntax)

(defun find-declaration (unit name)
  "Look up NAME in MODULE's declaration namespace.

The primary value is the declaration (or NIL); the secondary value says
whether the name was present, so a future NIL-valued representation remains
unambiguous."
  (check-type unit compilation-unit)
  (check-type name verona-name)
  (let ((binding (assoc name (compilation-unit-namespace unit) :test #'verona-name=)))
    (values (cdr binding) (not (null binding)))))

(defun module-lookup (module name)
  "Compatibility name for FIND-DECLARATION."
  (find-declaration module name))

(defun unit-declarations (unit)
  "Return UNIT's declarations in source discovery order."
  (check-type unit compilation-unit)
  (compilation-unit-declarations unit))

(defun register-declaration (unit declaration)
  ;; Implementations belong to a generic's implementation table, not the
  ;; module's single name namespace.  Their declaration name is retained for
  ;; diagnostics only.
  (when (typep declaration 'implementation-declaration)
    (setf (compilation-unit-declarations unit)
          (append (compilation-unit-declarations unit) (list declaration)))
    (return-from register-declaration declaration))
  (let ((name (declaration-name declaration)))
    (multiple-value-bind (existing foundp) (find-declaration unit name)
      (when foundp
        (error 'duplicate-declaration-error
               :syntax (declaration-source declaration)
               :name name
               :existing existing))
      ;; APPEND preserves program order; the namespace is an implementation
      ;; detail optimized for the tiny front end, not the ordered API.
      (setf (compilation-unit-declarations unit)
            (append (compilation-unit-declarations unit) (list declaration)))
      (push (cons name declaration) (compilation-unit-namespace unit))
      declaration)))

(defun macro-parameter-names (definition parameters)
  "Extract required macro parameter names and an optional `&rest` name."
  (unless (verona-list-p (syntax-datum parameters))
    (definition-fail definition "%macro parameters must be a list"))
  (let ((names '())
        (rest-name nil)
        (elements (verona-list-elements (syntax-datum parameters))))
    (loop while elements
          for parameter = (pop elements)
          for name = (syntax-datum parameter)
          do (unless (verona-name-p name)
               (definition-fail definition "%macro parameters must be Verona names"))
             (if (string= (verona-name-value name) "&rest")
                 (progn
                   (when (or rest-name (null elements) (cdr elements))
                     (definition-fail definition
                                      "%macro &rest must be followed by exactly one parameter name"))
                   (let ((rest-parameter (pop elements)))
                     (unless (verona-name-p (syntax-datum rest-parameter))
                       (definition-fail definition
                                        "%macro &rest parameter must be a Verona name"))
                     (setf rest-name (syntax-datum rest-parameter))))
                 (push name names)))
    (values (nreverse names) rest-name)))

(defun generic-parameter-names (definition parameters)
  "Extract the untyped parameter names that establish a generic's arity."
  (unless (verona-list-p (syntax-datum parameters))
    (definition-fail definition "%generic parameters must be a list"))
  (mapcar (lambda (parameter)
            (let ((name (syntax-datum parameter)))
              (unless (verona-name-p name)
                (definition-fail definition "%generic parameters must be Verona names"))
              name))
          (verona-list-elements (syntax-datum parameters))))

(defun declaration-macro (definition parameter-names rest-name body environment)
  "Construct the compile-time macro represented by a %MACRO declaration.

Macro bodies are evaluated only when the macro is invoked.  Discovery itself
never evaluates a declaration body."
  (make-verona-macro
   (lambda (&rest arguments)
     (unless (if rest-name
                 (>= (length arguments) (length parameter-names))
                 (= (length arguments) (length parameter-names)))
       (definition-fail definition
                        "%macro expected ~:[exactly ~;at least ~]~D argument~:P, received ~D"
                        (not (null rest-name))
                        (length parameter-names) (length arguments)))
     (let ((macro-environment (environment-child environment)))
       (loop for name in parameter-names
             for argument in arguments
             do (environment-bind macro-environment name argument))
       (when rest-name
         (environment-bind
          macro-environment rest-name
          (nthcdr (length parameter-names) arguments)))
       (let ((result (evaluate body macro-environment)))
         (unless (or (macro-s-expression-p result)
                     (typep result 'syntax)
                     (typep result 'top-level-expansion-result))
           (definition-fail definition
                            "%macro body must evaluate to an S-expression or top-level definitions"))
         result)))
   :source definition))

(defun named-definition-syntax-p (syntax)
  "Whether SYNTAX uses the named-clause primitive-definition API.

Legacy positional forms remain accepted while the surface macro package is
being designed.  Once a clause appears in the position where this API starts,
the whole form is parsed as named clauses rather than silently mixing styles."
  (let* ((head (definition-head-name syntax))
         (arguments (and head (rest (verona-list-elements (syntax-datum syntax))))))
    (cond ((null head) nil)
          ((string= head "%implementation")
           (and arguments (definition-clause-p (first arguments))))
          (t (and (second arguments) (definition-clause-p (second arguments)))))))

(defun process-named-definition (context unit source expanded-syntax)
  "Collect one named-clause primitive definition into a source declaration."
  (let ((head (definition-head-name expanded-syntax))
        (arguments (rest (verona-list-elements (syntax-datum expanded-syntax)))))
    (flet ((make-declaration (class name &rest initargs)
             (register-declaration
              unit
              (apply #'make-instance class :name name :source source
                     :expanded-syntax expanded-syntax :module unit initargs)))
           (named-arguments (minimum)
             (when (< (length arguments) minimum)
               (definition-fail expanded-syntax "%~A requires named clauses" (subseq head 1)))))
      (cond
        ((string= head "%type")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":type" ":documentation") '(":type")))
                (type-syntax (definition-clause-value clauses ":type"))
                (type-datum (syntax-datum type-syntax))
                (initargs (append (list :type-declaration type-syntax)
                                  (definition-documentation-initargs expanded-syntax clauses))))
           (cond
             ((and (verona-name-p type-datum)
                   (string= (verona-name-value type-datum) "opaque"))
              (apply #'make-declaration 'type-declaration name :kind :opaque :body '() initargs))
             ((verona-list-p type-datum)
              (let* ((elements (verona-list-elements type-datum))
                     (kind-syntax (first elements))
                     (kind (and kind-syntax (syntax-datum kind-syntax))))
                (unless (and kind (verona-name-p kind))
                  (definition-fail type-syntax "type declaration must name a type kind"))
                (cond
                  ((string= (verona-name-value kind) "alias")
                   (unless (= (length elements) 2)
                     (definition-fail type-syntax "alias type declaration must be (alias target)"))
                   (apply #'make-declaration 'type-alias-declaration name
                          :target (second elements) initargs))
                  ((member (verona-name-value kind) '("product" "sum") :test #'string=)
                   (apply #'make-declaration 'type-declaration name
                          :kind (if (string= (verona-name-value kind) "product") :product :sum)
                          :body (list type-syntax) initargs))
                  (t (definition-fail type-syntax "unknown type declaration kind ~A"
                                      (verona-name-value kind))))))
             (t (definition-fail type-syntax
                                 "type declaration must be opaque, (alias ...), (product ...), or (sum ...)")))))
        ((string= head "%function")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":type" ":implementation" ":documentation" ":for")
                                                   '(":type" ":implementation"))))
           (multiple-value-bind (parameters result)
               (function-type-declaration-components expanded-syntax
                                                     (definition-clause-value clauses ":type"))
             (apply #'make-declaration 'function-declaration name
                    :parameters parameters :return-type result
                    :for-clause (definition-clause-value clauses ":for")
                    :body (definition-clause-value clauses ":implementation")
                    :type-declaration (definition-clause-value clauses ":type")
                    (definition-documentation-initargs expanded-syntax clauses)))))
        ((string= head "%external-function")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":type" ":external-name" ":documentation")
                                                   '(":type" ":external-name")))
                (external-name-syntax (definition-clause-value clauses ":external-name"))
                (external-name (syntax-datum external-name-syntax)))
           (unless (stringp external-name)
             (definition-fail external-name-syntax "external function name must be a string"))
           (multiple-value-bind (parameters result)
               (function-type-declaration-components expanded-syntax
                                                     (definition-clause-value clauses ":type"))
             (definition-list-clause expanded-syntax parameters "external function parameter types")
             (apply #'make-declaration 'external-function-declaration name
                    :external-name external-name :parameter-types parameters :result-type result
                    :type-declaration (definition-clause-value clauses ":type")
                    (definition-documentation-initargs expanded-syntax clauses)))))
        ((string= head "%macro")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":parameters" ":implementation" ":documentation")
                                                   '(":parameters" ":implementation")))
                (parameters (definition-list-clause expanded-syntax
                                                     (definition-clause-value clauses ":parameters")
                                                     "macro parameters"))
                (body (definition-clause-value clauses ":implementation")))
           (multiple-value-bind (parameter-names rest-name)
               (macro-parameter-names expanded-syntax parameters)
             (let ((declaration (apply #'make-declaration 'macro-declaration name
                                       :parameters parameters :body body
                                       (definition-documentation-initargs expanded-syntax clauses))))
               (environment-bind context name
                                 (declaration-macro expanded-syntax parameter-names rest-name
                                                    body context))
               declaration))))
        ((or (string= head "%constant") (string= head "%variable"))
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":type" ":implementation" ":documentation")
                                                   '(":type" ":implementation")))
                (type (definition-clause-value clauses ":type"))
                (implementation (definition-clause-value clauses ":implementation"))
                (initargs (append (list :type-declaration type)
                                  (definition-documentation-initargs expanded-syntax clauses))))
           (if (string= head "%constant")
               (apply #'make-declaration 'constant-declaration name
                      :type type :value implementation initargs)
               (apply #'make-declaration 'variable-declaration name
                      :type type :initializer implementation initargs))))
        ((string= head "%generic")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":parameters" ":documentation") '(":parameters")))
                (parameters (definition-list-clause expanded-syntax
                                                     (definition-clause-value clauses ":parameters")
                                                     "generic parameters"))
                (names (generic-parameter-names expanded-syntax parameters)))
           (apply #'make-declaration 'generic-declaration name
                  :parameters names :arity (length names)
                  (definition-documentation-initargs expanded-syntax clauses))))
        ((string= head "%protocol")
         (named-arguments 2)
         (let* ((name (definition-name expanded-syntax (first arguments)))
                (clauses (parse-definition-clauses expanded-syntax (rest arguments)
                                                   '(":parameters" ":operations" ":documentation")
                                                   '(":parameters" ":operations")))
                (parameters (definition-list-clause expanded-syntax
                                                     (definition-clause-value clauses ":parameters")
                                                     "protocol type parameters"))
                (operations (definition-list-clause expanded-syntax
                                                    (definition-clause-value clauses ":operations")
                                                    "protocol operations")))
           (apply #'make-declaration 'protocol-declaration name
                  :parameters parameters :operations (verona-list-elements (syntax-datum operations))
                  (definition-documentation-initargs expanded-syntax clauses))))
        ((string= head "%implementation")
         (let ((clauses (parse-definition-clauses expanded-syntax arguments
                                                  '(":generic" ":protocol" ":type" ":implementation"
                                                    ":operations" ":documentation") '())))
           (let ((generic (definition-clause-value clauses ":generic"))
                 (protocol (definition-clause-value clauses ":protocol")))
             (when (and generic protocol)
               (definition-fail expanded-syntax "%implementation cannot name both a generic and a protocol"))
             (unless (or generic protocol)
               (definition-fail expanded-syntax "%implementation requires a :generic or :protocol clause"))
             (if generic
                 (progn
                   (dolist (required '(":type" ":implementation"))
                     (unless (definition-clause-value clauses required)
                       (definition-fail expanded-syntax "%implementation for a generic requires a ~A clause" required)))
                   (let ((target (syntax-datum generic)))
                     (unless (or (verona-name-p target) (qualified-name-p target))
                       (definition-fail generic "generic implementation target must be a name"))
                     (multiple-value-bind (parameters result)
                         (function-type-declaration-components expanded-syntax
                                                               (definition-clause-value clauses ":type"))
                       (apply #'make-declaration 'implementation-declaration
                              (if (qualified-name-p target) (qualified-name-name target) target)
                              :generic-name target :parameters parameters :return-type result
                              :body (definition-clause-value clauses ":implementation")
                              :type-declaration (definition-clause-value clauses ":type")
                              (definition-documentation-initargs expanded-syntax clauses)))))
                 (progn
                   (unless (definition-clause-value clauses ":operations")
                     (definition-fail expanded-syntax
                                      "%implementation for a protocol requires an :operations clause"))
                   (definition-list-clause expanded-syntax protocol "protocol application")
                   (let ((operations (definition-list-clause expanded-syntax
                                                              (definition-clause-value clauses ":operations")
                                                              "protocol implementation operations")))
                     (apply #'make-declaration 'implementation-declaration
                            (make-verona-name "implementation")
                            :protocol-application protocol
                            :operations (verona-list-elements (syntax-datum operations))
                            :type-declaration protocol
                            (definition-documentation-initargs expanded-syntax clauses))))))))
        (t (definition-fail expanded-syntax "unknown primitive definition form ~A" head))))))

(defun process-definition (context unit source &optional (expanded-syntax source))
  "Turn EXPANDED-SYNTAX into a declaration, retaining its original SOURCE.

CONTEXT is the compile-time evaluator environment.  The evaluator only
expands syntax; this processor is the boundary that creates compiler objects."
  (check-type context environment)
  (check-type unit compilation-unit)
  (check-type source syntax)
  (check-type expanded-syntax syntax)
  (when (named-definition-syntax-p expanded-syntax)
    (return-from process-definition
      (process-named-definition context unit source expanded-syntax)))
  (let ((head (definition-head-name expanded-syntax)))
    (unless head
      (error 'non-definition-top-level-error
             :syntax source
             :message "top-level expansion must produce a definition"))
    (flet ((make-declaration (class name &rest initargs)
             (register-declaration
              unit
              (apply #'make-instance class
                     :name name :source source :expanded-syntax expanded-syntax
                     :module unit initargs))))
      (cond
            ((string= head "%type")
             (let ((arguments (definition-elements expanded-syntax "type" 1)))
               (unless (member (length arguments) '(1 2))
                 (definition-fail expanded-syntax
                                  "%type requires a name and at most one type body"))
               (let ((name (definition-name expanded-syntax (first arguments))))
                 (if (= (length arguments) 1)
                     ;; A body-less type is a nominal, incomplete type.  This
                     ;; is the spelling used for C handles whose layout is
                     ;; deliberately unavailable to Verona.
                     (make-declaration 'type-declaration name :kind :opaque :body '())
                     (let* ((body (second arguments))
                      (body-datum (syntax-datum body))
                      (elements (and (verona-list-p body-datum)
                                     (verona-list-elements body-datum)))
                      (head-syntax (first elements))
                      (head (and head-syntax (syntax-datum head-syntax))))
                 (cond ((and (verona-name-p head)
                             (string= (verona-name-value head) "product"))
                        (make-declaration 'type-declaration name
                                          :kind :product :body (list body)))
                       ((and (verona-name-p head)
                             (string= (verona-name-value head) "sum"))
                        (make-declaration 'type-declaration name
                                          :kind :sum :body (list body)))
		       ;; `(type Point (x i32))` and `(type Point ((x i32)))`
		       ;; used to be accepted as products by shape heuristics.  TYPE
		       ;; now reserves its single type-expression form for aliases.
		       ((and elements
		             (or (verona-list-p head)
			 (and (= (length elements) 2)
			      (verona-name-p head)
			      (not (member (verona-name-value head)
					  '("pointer" "array") :test #'string=)))))
		        (definition-fail expanded-syntax
		                         "implicit product syntax is not supported; use (type ~A (product ...))"
		                         (verona-name-value name)))
                       (t
                        (make-declaration 'type-alias-declaration name
                                          :target body))))))))
            ((string= head "%function")
             (let ((arguments (definition-elements expanded-syntax "function" 4)))
               ;; A FOR clause is declaration syntax, not an expression.  It
               ;; is retained verbatim here and parsed at the semantic
               ;; boundary, where protocol names and type parameters exist.
               (unless (member (length arguments) '(4 5))
                 (definition-fail expanded-syntax "%function requires a name, optional for clause, parameters, return type, and body"))
               (let ((polymorphic-p (= (length arguments) 5)))
                 (make-declaration 'function-declaration
                                   (definition-name expanded-syntax (first arguments))
                                   :for-clause (and polymorphic-p (second arguments))
                                   :parameters (if polymorphic-p (third arguments) (second arguments))
                                   :return-type (if polymorphic-p (fourth arguments) (third arguments))
                                   :body (if polymorphic-p (fifth arguments) (fourth arguments))))))
            ((string= head "%external-function")
             (let ((arguments (definition-elements expanded-syntax "external-function" 4)))
               (unless (= (length arguments) 4)
                 (definition-fail expanded-syntax
                                  "%external-function requires a Verona name, external string name, parameter type list, and result type"))
               (let ((external-name (syntax-datum (second arguments)))
                     (parameter-types (third arguments)))
                 (unless (stringp external-name)
                   (definition-fail expanded-syntax "external function name must be a string"))
                 (unless (verona-list-p (syntax-datum parameter-types))
                   (definition-fail expanded-syntax "external function parameter types must be a list"))
                 (make-declaration 'external-function-declaration
                                   (definition-name expanded-syntax (first arguments))
                                   :external-name external-name
                                   :parameter-types parameter-types
				   :result-type (fourth arguments)))))
            ((string= head "%macro")
             (let ((arguments (definition-elements expanded-syntax "macro" 3)))
              (unless (= (length arguments) 3)
                 (definition-fail expanded-syntax "%macro requires a name, parameters, and body"))
               (let* ((name (definition-name expanded-syntax (first arguments)))
                      (parameters (second arguments))
                      (body (third arguments)))
                 (multiple-value-bind (parameter-names rest-name)
                     (macro-parameter-names expanded-syntax parameters)
                   (let ((declaration (make-declaration 'macro-declaration name
                                                        :parameters parameters :body body)))
                     ;; Bind only after successful registration so a duplicate
                     ;; definition cannot overwrite the existing macro.
                     (environment-bind context name
                                       (declaration-macro expanded-syntax parameter-names rest-name
                                                          body context))
                     declaration)))))
            ((string= head "%constant")
             (let ((arguments (definition-elements expanded-syntax "constant" 3)))
              (unless (= (length arguments) 3)
                 (definition-fail expanded-syntax "%constant requires a name, type, and value"))
               (make-declaration 'constant-declaration
                                 (definition-name expanded-syntax (first arguments))
                                 :type (second arguments) :value (third arguments))))
            ((string= head "%variable")
             (let ((arguments (definition-elements expanded-syntax "variable" 3)))
              (unless (= (length arguments) 3)
                 (definition-fail expanded-syntax "%variable requires a name, type, and initializer"))
               (make-declaration 'variable-declaration
                                 (definition-name expanded-syntax (first arguments))
                                 :type (second arguments) :initializer (third arguments))))
            ((string= head "%generic")
             (let ((arguments (definition-elements expanded-syntax "generic" 2)))
               (unless (= (length arguments) 2)
                 (definition-fail expanded-syntax "%generic requires a name and parameter list"))
               (let* ((name (definition-name expanded-syntax (first arguments)))
                      (parameters (second arguments))
                      (names (generic-parameter-names expanded-syntax parameters)))
                 (make-declaration 'generic-declaration name
                                   :parameters names :arity (length names)))))
            ((string= head "%protocol")
             (let ((arguments (definition-elements expanded-syntax "protocol" 2)))
               (unless (>= (length arguments) 2)
                 (definition-fail expanded-syntax "%protocol requires a name and type parameter list"))
               (let ((parameters (second arguments)))
                 (unless (verona-list-p (syntax-datum parameters))
                   (definition-fail parameters "%protocol type parameters must be a list"))
                 (make-declaration 'protocol-declaration
                                   (definition-name expanded-syntax (first arguments))
                                   :parameters parameters :operations (cddr arguments)))) )
            ((string= head "%implementation")
             (let ((arguments (definition-elements expanded-syntax "implementation" 2)))
               (let ((target (syntax-datum (first arguments))))
                 (if (verona-list-p target)
                     (make-declaration 'implementation-declaration
                                       (make-verona-name "implementation")
                                       :protocol-application (first arguments)
                                       :operations (rest arguments))
                     (progn
                       (unless (= (length arguments) 4)
                         (definition-fail expanded-syntax "%implementation requires a generic name, parameters, return type, and body"))
                       (unless (or (verona-name-p target) (qualified-name-p target))
                         (definition-fail expanded-syntax "implementation target must be a name"))
                 ;; Implementations do not occupy the ordinary declaration
                 ;; namespace.  Keep a local Name for diagnostics while
                 ;; retaining a structured QualifiedName target for the
                 ;; ownership validation in semantic resolution.
                       (make-declaration 'implementation-declaration
                                         (if (qualified-name-p target)
                                             (qualified-name-name target) target)
                                         :generic-name target
                                         :parameters (second arguments) :return-type (third arguments)
				         :body (fourth arguments)))))))))))

(defun expand-top-level (syntax environment)
  "Expand SYNTAX into a TOP-LEVEL-EXPANSION-RESULT.

Unlike ordinary EXPAND, this protocol permits a macro to return an explicit
TOP-LEVEL-EXPANSION-RESULT containing zero or more definition forms."
  (check-type syntax syntax)
  (check-type environment environment)
  (let ((*macro-expansion-count* 0))
    (labels ((expand-one (form)
               (check-type form syntax)
               (let ((macro (macro-at-head form environment)))
                 (if (not macro)
                     (list form)
                     (let ((result (invoke-verona-macro
                                    macro form
                                    (rest (verona-list-elements
                                           (syntax-datum form))))))
                       (cond ((typep result 'syntax) (expand-one result))
                             ((macro-s-expression-p result)
                              (expand-one (macro-result-syntax result form macro)))
                             ((typep result 'top-level-expansion-result)
                              (mapcan #'expand-one
                                      (mapcar (lambda (definition)
                                                (unless (or (typep definition 'syntax)
                                                            (macro-s-expression-p definition))
                                                  (error 'invalid-macro-result-error :value definition))
                                                (macro-result-syntax definition form macro))
                                              (top-level-expansion-result-definitions result))))
                             (t
                              (error 'invalid-macro-result-error :value result))))))))
      (make-top-level-expansion-result (expand-one syntax)))))

(defun make-primitive-definition (primitive-name arguments
                                  &optional (source *macro-expansion-syntax*))
  "Build a named-clause primitive definition from macro ARGUMENTS.

PRIMITIVE-NAME must be one of +DEFINITION-FORM-NAMES+.  ARGUMENTS is a
source-aware Verona list, allowing a source-defined macro to delegate its
established positional contract to the compiler without reconstructing syntax
or inventing attributes that its own surface language does not define."
  (unless (and (stringp primitive-name)
               (member primitive-name +definition-form-names+ :test #'string=))
    (error "unknown primitive definition ~S" primitive-name))
  (check-type arguments syntax)
  (unless (verona-list-p (syntax-datum arguments))
    (error "primitive definition arguments must be a Verona list"))
  (check-type source syntax)
  (bootstrap-definition-expansion source primitive-name
                                  (verona-list-elements (syntax-datum arguments))))

(defun make-primitive-definition-s-expression (primitive-name arguments source)
  "Return a primitive definition S-expression for macro-facing ARGUMENTS."
  (unless (proper-s-expression-list-p arguments)
    (error "primitive definition arguments must be an S-expression list"))
  (syntax->macro-s-expression
   (make-primitive-definition primitive-name
                              (macro-s-expression->syntax arguments source)
                              source)))

(defun compile-time-name-component (value)
  "Extract one identifier spelling from a compile-time VALUE."
  (cond ((stringp value) value)
        ((verona-name-p value) (verona-name-value value))
        ;; Host evaluator clients may still provide syntax, but source macros
        ;; receive plain identifier values.
        ((typep value 'syntax)
         (compile-time-name-component (syntax->macro-s-expression value)))
        (t (error "name construction requires a string or identifier, received ~S" value))))

(defun compile-time-keyword (text)
  "Return an identifier S-expression named by TEXT for macro output."
  (unless (stringp text)
    (error "keyword requires a string, received ~S" text))
  (when (string= text "")
    (error "keyword requires a non-empty string"))
  (make-verona-name text))

(defun compile-time-keyword-concat (&rest parts)
  "Concatenate compile-time identifier values into one identifier."
  (when (null parts)
    (error "keyword-concat requires at least one component"))
  (let ((name (apply #'concatenate 'string (mapcar #'compile-time-name-component parts))))
    (when (string= name "")
      (error "keyword-concat cannot construct an empty name"))
    (make-verona-name name)))

(defun compile-time-symbol (text)
  "Construct a plain Verona symbol from TEXT."
  (compile-time-keyword text))

(defun compile-time-symbol-name (symbol)
  "Return SYMBOL's spelling as a string."
  (unless (verona-name-p symbol)
    (error "symbol-name requires a symbol, received ~S" symbol))
  (verona-name-value symbol))

(defun compile-time-symbol-concat (&rest parts)
  "Construct a symbol by joining string and symbol components."
  (apply #'compile-time-keyword-concat parts))

(defun compile-time-string-concat (&rest strings)
  "Concatenate compile-time strings."
  (dolist (string strings)
    (unless (stringp string)
      (error "string-concat requires strings, received ~S" string)))
  (apply #'concatenate 'string strings))

(defun compile-time-string-length (string)
  "Return STRING's character length."
  (unless (stringp string)
    (error "string-length requires a string, received ~S" string))
  (length string))

(defun compile-time-substring (string start &optional end)
  "Return STRING between START and optional END."
  (unless (stringp string)
    (error "substring requires a string, received ~S" string))
  (unless (and (integerp start) (<= 0 start)
               (or (null end) (and (integerp end) (<= start end))))
    (error "substring requires non-negative integer bounds"))
  (subseq string start end))

(defun compile-time-list (values)
  "Validate VALUES as a proper macro S-expression list."
  (unless (proper-s-expression-list-p values)
    (error "list operation requires a proper list, received ~S" values))
  values)

(defun compile-time-cons (value list)
  "Prepend VALUE to a proper macro list."
  (unless (macro-s-expression-p value)
    (error "cons requires an S-expression value, received ~S" value))
  (cons value (compile-time-list list)))

(defun compile-time-car (list)
  "Return the first value in a non-empty macro list."
  (let ((list (compile-time-list list)))
    (when (null list)
      (error "car requires a non-empty list"))
    (first list)))

(defun compile-time-cdr (list)
  "Return every value but the first in a non-empty macro list."
  (let ((list (compile-time-list list)))
    (when (null list)
      (error "cdr requires a non-empty list"))
    (rest list)))

(defun compile-time-append (&rest lists)
  "Append proper macro lists."
  (apply #'append (mapcar #'compile-time-list lists)))

(defun compile-time-length (value)
  "Return the length of a macro list or string."
  (cond ((stringp value) (length value))
        ((proper-s-expression-list-p value) (length value))
        (t (error "length requires a string or proper list, received ~S" value))))

(defun make-compilation-environment ()
  "Create the compile-time environment used while constructing one unit."
  (let ((environment (make-bootstrap-environment)))
    ;; This internal helper is deliberately available only during compilation.
    ;; It gives source-defined macros a precise way to emit zero or more
    ;; definitions without giving an ordinary Verona list a second meaning.
    (environment-bind
     environment (make-verona-name "definitions")
     (make-verona-function
      (lambda (&rest definitions)
        (dolist (definition definitions)
          (unless (macro-s-expression-p definition)
            (error "definitions requires S-expression forms, received ~S" definition)))
        (make-top-level-expansion-result definitions))))
    ;; BASE is an ordinary, explicitly imported Verona module.  Its macros
    ;; delegate only their positional-to-named syntax conversion through this
    ;; small compiler API; the module remains free to replace the surface
    ;; conventions without changing declaration collection.
    (environment-bind
     environment (make-verona-name "compiler:definition")
     (make-verona-function
      (lambda (primitive-name arguments)
        (make-primitive-definition-s-expression primitive-name arguments
                                                *macro-expansion-syntax*))))
    ;; These are compile-time constructors.  They return ordinary identifier
    ;; values; expansion reattaches source syntax only after a macro returns.
    (environment-bind environment (make-verona-name "keyword")
                      (make-verona-function #'compile-time-keyword))
    (environment-bind environment (make-verona-name "keyword-concat")
                      (make-verona-function #'compile-time-keyword-concat))
    (environment-bind environment (make-verona-name "symbol")
                      (make-verona-function #'compile-time-symbol))
    (environment-bind environment (make-verona-name "symbol-name")
                      (make-verona-function #'compile-time-symbol-name))
    (environment-bind environment (make-verona-name "symbol-concat")
                      (make-verona-function #'compile-time-symbol-concat))
    (environment-bind environment (make-verona-name "string-concat")
                      (make-verona-function #'compile-time-string-concat))
    (environment-bind environment (make-verona-name "string-length")
                      (make-verona-function #'compile-time-string-length))
    (environment-bind environment (make-verona-name "substring")
                      (make-verona-function #'compile-time-substring))
    (environment-bind environment (make-verona-name "list")
                      (make-verona-function
                       (lambda (&rest values) (compile-time-list values))))
    (environment-bind environment (make-verona-name "cons")
                      (make-verona-function #'compile-time-cons))
    (environment-bind environment (make-verona-name "car")
                      (make-verona-function #'compile-time-car))
    (environment-bind environment (make-verona-name "cdr")
                      (make-verona-function #'compile-time-cdr))
    (environment-bind environment (make-verona-name "append")
                      (make-verona-function #'compile-time-append))
    (environment-bind environment (make-verona-name "length")
                      (make-verona-function #'compile-time-length))
    environment))

(defun top-level-form-head (form)
  (let ((datum (syntax-datum form)))
    (when (verona-list-p datum)
      (let ((head (first (verona-list-elements datum))))
        (and head (verona-name-p (syntax-datum head))
             (verona-name-value (syntax-datum head)))))))

(defun parse-import-form (form loader)
  (let ((arguments (rest (verona-list-elements (syntax-datum form)))))
    (unless (or (= (length arguments) 1) (= (length arguments) 3))
      (error 'module-error :source form))
    (let ((name (parse-module-name (first arguments)))
          (alias nil))
      (when (= (length arguments) 3)
        (unless (and (verona-name-p (syntax-datum (second arguments)))
                     (string= (verona-name-value (syntax-datum (second arguments))) ":as")
                     (verona-name-p (syntax-datum (third arguments))))
          (error 'module-error :source form))
        (setf alias (syntax-datum (third arguments))))
      (make-instance 'import :module (module-loader-load loader name)
                            :alias alias :source form))))

(defun parse-export-form (form)
  (let ((names (rest (verona-list-elements (syntax-datum form)))))
    (dolist (name names)
      (unless (verona-name-p (syntax-datum name))
        (error 'module-error :source name)))
    (mapcar #'syntax-datum names)))

(defun parse-native-export-form (form)
  "Parse `(native-export function-name [\"c_name\"])` without conflating it
with a Verona module EXPORT."
  (let ((arguments (rest (verona-list-elements (syntax-datum form)))))
    (unless (member (length arguments) '(1 2))
      (error 'module-error :source form))
    (let ((name (syntax-datum (first arguments))))
      (unless (verona-name-p name) (error 'module-error :source form))
      (let ((external-name (if (second arguments) (syntax-datum (second arguments))
                               (verona-name-value name))))
        (unless (stringp external-name) (error 'module-error :source form))
        (make-instance 'native-export-spec :name name :external-name external-name :source form)))))

(defun install-imported-macros (module import)
  "Only macros cross the evaluator boundary; semantic bindings stay separate."
  (dolist (entry (module-exports (import-module import)))
    (let ((declaration (cdr entry)))
      (when (typep declaration 'macro-declaration)
        (let ((local-name
                (make-verona-name
                 (format nil "~A:~A"
                         (verona-name-value (import-qualifier-name import))
                         (verona-name-value (car entry))))))
          (multiple-value-bind (value foundp)
              (environment-find (module-environment (import-module import))
                                (car entry))
            (when foundp
              (environment-bind (module-environment module) local-name value))))))))

(defun register-import (module import)
  (let ((qualifier (import-qualifier-name import)))
    (when (module-find-import module qualifier)
      (error 'duplicate-import-alias :module module :source (import-source import)
             :alias qualifier))
    (push import (module-imports module))
    (push (cons qualifier import) (module-import-table module))
    (install-imported-macros module import)
    import))

(defun resolve-module-exports (module)
  (dolist (name (module-export-names module))
    (multiple-value-bind (declaration foundp) (find-declaration module name)
      (unless foundp
        (error 'unknown-export :module module :name name))
      (push (cons name declaration) (module-exports module))))
  (setf (module-exports module) (nreverse (module-exports module)))
  module)

(defun collect-module (module loader)
  (let ((environment (module-environment module)))
    ;; Only top-level forms reach the definition processor.  Expansion is
    ;; sequential because a preceding %MACRO can affect a following form.
    (dolist (form (module-forms module))
      (cond ((string= (or (top-level-form-head form) "") "import")
             (register-import module (parse-import-form form loader)))
            ((string= (or (top-level-form-head form) "") "export")
             (setf (module-export-names module)
                   (append (module-export-names module) (parse-export-form form))))
            ((string= (or (top-level-form-head form) "") "native-export")
             (push (parse-native-export-form form) (module-native-export-specs module)))
            (t (dolist (expanded-syntax
                         (top-level-expansion-result-definitions
                          (expand-top-level form environment)))
                 (process-definition environment module form expanded-syntax)))))
    (resolve-module-exports module)
    (setf (module-native-export-specs module) (nreverse (module-native-export-specs module)))
    module))

(defun module-loader-find (loader name)
  (cdr (assoc name (module-loader-loaded-modules loader) :test #'module-name=)))

(defun module-source-pathname (loader name)
  (let ((filename (format nil "~A.vrn" (module-name-string name))))
    (find-if #'probe-file
             (mapcar (lambda (root) (merge-pathnames filename root))
                     (module-loader-search-paths loader)))))

(defun module-loader-load (loader name)
  (let ((position (position name (module-loader-loading-stack loader)
                           :test #'module-name=)))
    (when position
      (error 'circular-module-dependency :module name
             :cycle (append (subseq (module-loader-loading-stack loader) position)
                            (list name))))
    (or (module-loader-find loader name)
        (let ((path (module-source-pathname loader name)))
          (unless path (error 'module-not-found :module name))
          (let* ((source (source-from-file path))
                 (module (make-instance 'module :name name :pathname path
                                         :source source
                                         :forms (read-source source
                                                             :features (module-loader-features loader))
                                         :environment (make-compilation-environment))))
            ;; Cache before collecting dependencies: identity is stable even
            ;; while its declaration namespace is being assembled.
            (push (cons name module) (module-loader-loaded-modules loader))
            (let ((old-stack (module-loader-loading-stack loader)))
              (unwind-protect
                   (progn
                     (setf (module-loader-loading-stack loader) (append old-stack (list name)))
                     (collect-module module loader))
                (setf (module-loader-loading-stack loader) old-stack)))
            module)))))

(defun compile-source (source &key target (pointer-width 64) compiler)
  (let* ((name (make-module-name (make-verona-name "string")))
         (features (target-feature-names target))
         (module (make-instance 'module :name name :identity-explicit-p nil
                                :source source
                                :forms (call-with-compiler-phase compiler :read
                                                                 (lambda () (read-source source :features features)))
                                :environment (make-compilation-environment))))
    (call-with-compiler-phase compiler :declarations
                              (lambda () (collect-module module
                                                         (make-instance 'module-loader
                                                                        :search-paths '()
                                                                        :features features))))
    (call-with-compiler-phase compiler :resolve-and-typecheck
                              (lambda () (resolve-program module (list module)
                                                        :target target :pointer-width pointer-width)))
    module))

;;; Development-stage APIs -------------------------------------------------
;; These deliberately return the real phase products, rather than debug
;; strings, so SBCL's inspector remains useful while evolving the compiler.

(defun read-verona (source-or-contents &key (name "<string>") target)
  "Read Verona source without macro expansion or semantic analysis."
  (read-source (if (typep source-or-contents 'source)
                   source-or-contents
                   (make-source name source-or-contents))
               :features (target-feature-names target)))

(defun macroexpand-verona (syntax-or-contents &key (name "<string>") environment)
  "Expand a top-level Verona form and retain expansion provenance."
  (let ((environment (or environment (make-compilation-environment))))
    (cond ((typep syntax-or-contents 'syntax)
           (expand-top-level syntax-or-contents environment))
          (t (mapcar (lambda (form) (expand-top-level form environment))
                     (read-verona syntax-or-contents :name name))))))

(defun analyze-verona (source-or-contents &key (name "<string>") target
                                          (pointer-width 64))
  "Collect and resolve a source unit, returning its semantic program."
  (let ((unit (compile-source
               (if (typep source-or-contents 'source) source-or-contents
                   (make-source name source-or-contents))
               :target target :pointer-width pointer-width)))
    (compilation-unit-semantic-program unit)))

(defun typecheck-verona (source-or-contents &rest arguments)
  "Alias for ANALYZE-VERONA: resolution currently includes type checking."
  (apply #'analyze-verona source-or-contents arguments))

(defun compile-string (compiler contents &key (name "<string>") target (pointer-width 64))
  "Read and discover primitive top-level declarations in CONTENTS."
  (check-type compiler compiler)
  (clear-compiler-phase-timings compiler)
  (compile-source (make-source name contents) :target target :pointer-width pointer-width
                  :compiler compiler))

(defun compile-file (compiler pathname &key target (pointer-width 64))
  "Read and discover primitive top-level declarations in PATHNAME."
  (check-type compiler compiler)
  (clear-compiler-phase-timings compiler)
  (let* ((path (pathname pathname))
         (entry-name (module-name-from-pathname path))
         (loader (make-instance 'module-loader
                                :search-paths
                                (cons (make-pathname :name nil :type nil :defaults path)
                                      (compiler-search-paths compiler))
                                :features (target-feature-names target)))
         (entry (call-with-compiler-phase compiler :read-and-declarations
                                          (lambda () (module-loader-load loader entry-name))))
         ;; Recursive loading pushes a dependency after its importer has been
         ;; cached, so the cache's final order is already dependencies-first.
         (modules (mapcar #'cdr (module-loader-loaded-modules loader))))
    (call-with-compiler-phase compiler :resolve-and-typecheck
                              (lambda () (resolve-program entry modules :target target
                                                          :pointer-width pointer-width)))
    entry))

(defun compile-module (compiler name &key target (pointer-width 64))
  "Compile module NAME from COMPILER's ordered module search paths."
  (check-type compiler compiler)
  (clear-compiler-phase-timings compiler)
  (let* ((module-name (if (module-name-p name) name
                          (parse-module-name
                           (make-syntax (make-verona-name name)
                                        (make-source "<module>" "")
                                        (make-source-location) (make-source-location)))))
         (loader (make-instance 'module-loader :search-paths (compiler-search-paths compiler)
                                :features (target-feature-names target)))
         (entry (call-with-compiler-phase compiler :read-and-declarations
                                          (lambda () (module-loader-load loader module-name))))
         (modules (mapcar #'cdr (module-loader-loaded-modules loader))))
    (call-with-compiler-phase compiler :resolve-and-typecheck
                              (lambda () (resolve-program entry modules :target target
                                                          :pointer-width pointer-width)))
    entry))
