(in-package #:verona)

(defclass verona-callable () ())

(defun verona-callable-p (object)
  (typep object 'verona-callable))

(defclass verona-function (verona-callable)
  ((implementation :initarg :implementation :reader verona-function-implementation)))

(defun verona-function-p (object)
  (typep object 'verona-function))

(defun make-verona-function (implementation)
  "Wrap IMPLEMENTATION as a callable that receives evaluated Verona values."
  (check-type implementation function)
  (make-instance 'verona-function :implementation implementation))

(defclass verona-macro (verona-callable)
  ((implementation :initarg :implementation :reader verona-macro-implementation)
   ;; A source-defined macro records its declaration syntax.  Bootstrap
   ;; macros have NIL here, but expansion provenance remains useful because
   ;; the invocation itself is always source-aware.
   (source :initarg :source :initform nil :reader verona-macro-source)))

(defun verona-macro-p (object)
  (typep object 'verona-macro))

(defun make-verona-macro (implementation &key source)
  "Wrap IMPLEMENTATION as a callable that receives unevaluated S-expressions.

IMPLEMENTATION returns one S-expression form.  Compiler-owned SYNTAX remains
at the expansion boundary so macro code manipulates ordinary Lisp data."
  (check-type implementation function)
  (make-instance 'verona-macro :implementation implementation :source source))

;; Macro implementations receive plain data.  Retaining the enclosing form
;; during expansion lets the compiler restore source provenance only after a
;; macro has returned its generated S-expression.
(defvar *macro-expansion-syntax* nil)

;; Name-building expressions conventionally use `,parameter` even inside an
;; enclosing unquote.  Preserve that concise macro notation by treating an
;; UNQUOTE evaluated while another unquote is active as a syntax-value lookup.
(defvar *unquote-evaluation-p* nil)

(defun proper-s-expression-list-p (value)
  "Whether VALUE is a finite, proper host list."
  (and (listp value)
       (handler-case
           (let ((length (list-length value)))
             (not (null length)))
         (type-error () nil))))

(defun macro-s-expression-p (value)
  "Whether VALUE belongs to the macro evaluator's plain S-expression model."
  (cond ((null value) t)
        ((consp value)
         (and (proper-s-expression-list-p value)
              (every #'macro-s-expression-p value)))
        ((or (verona-name-p value) (qualified-name-p value)
             (unit-literal-p value) (verona-boolean-literal-p value)
             (stringp value) (characterp value) (numberp value))
         t)
        (t nil)))

(defun syntax->macro-s-expression (syntax)
  "Erase compiler source wrappers from SYNTAX for macro evaluation."
  (check-type syntax syntax)
  (let ((datum (syntax-datum syntax)))
    (if (verona-list-p datum)
        (mapcar #'syntax->macro-s-expression (verona-list-elements datum))
        datum)))

(defun macro-s-expression->syntax (value source)
  "Attach SOURCE's provenance to plain macro VALUE at the compiler boundary."
  (check-type source syntax)
  (unless (macro-s-expression-p value)
    (error "macro result is not an S-expression: ~S" value))
  (make-syntax
   (if (listp value)
       (apply #'make-verona-list
              (mapcar (lambda (element)
                        (macro-s-expression->syntax element source))
                      value))
       value)
   (syntax-source source) (syntax-start source) (syntax-end source)))

(define-condition unbound-name-error (user-compilation-error)
  ((name :initarg :name :reader unbound-name-error-name))
  (:report (lambda (condition stream)
             (format stream "Unbound Verona name ~S"
                     (verona-name-value (unbound-name-error-name condition))))))

(define-condition not-callable-error (user-compilation-error)
  ((value :initarg :value :reader not-callable-error-value))
  (:report (lambda (condition stream)
             (format stream "Verona value ~S is not callable"
                     (not-callable-error-value condition)))))

(define-condition invalid-macro-result-error (user-compilation-error)
  ((value :initarg :value :reader invalid-macro-result-error-value))
  (:report (lambda (condition stream)
             (format stream "A Verona macro returned ~S, not an S-expression"
                     (invalid-macro-result-error-value condition)))))

(define-condition macro-expansion-limit-error (user-compilation-error)
  ((limit :initarg :limit :reader macro-expansion-limit-error-limit)
   (syntax :initarg :syntax :reader macro-expansion-limit-error-syntax))
  (:report (lambda (condition stream)
             (format stream "macro expansion exceeded the limit of ~D steps"
                     (macro-expansion-limit-error-limit condition)))))

(defparameter *macro-expansion-depth-limit* 256
  "Maximum macro-expansion steps for one expansion operation.")
(defvar *macro-expansion-count* 0)

(defmethod diagnostic-code-for ((condition unbound-name-error))
  (declare (ignore condition)) "E0201")
(defmethod diagnostic-code-for ((condition invalid-macro-result-error))
  (declare (ignore condition)) "E0001")
(defmethod diagnostic-code-for ((condition macro-expansion-limit-error))
  (declare (ignore condition)) "E0001")

(defstruct (expansion-origin
            (:constructor make-expansion-origin (invocation macro parent-origin)))
  invocation
  macro
  parent-origin)

(defun annotate-macro-expansion (result invocation macro)
  "Attach a Verona-level expansion chain to macro-generated syntax."
  (check-type result syntax)
  (make-syntax (syntax-datum result) (syntax-source result)
               (syntax-start result) (syntax-end result)
               :expansion-origin
               (make-expansion-origin invocation (verona-macro-source macro)
                                      (syntax-expansion-origin invocation))))

(defun invoke-verona-macro (macro invocation arguments)
  (when (>= *macro-expansion-count* *macro-expansion-depth-limit*)
    (error 'macro-expansion-limit-error :limit *macro-expansion-depth-limit*
           :syntax invocation))
  (incf *macro-expansion-count*)
  (let ((*macro-expansion-syntax* invocation)
        (arguments (mapcar #'syntax->macro-s-expression arguments)))
    (apply (verona-macro-implementation macro) arguments)))

(defun macro-result-syntax (result invocation macro)
  "Rehydrate RESULT at INVOCATION, retaining compatibility with host macros."
  (let ((syntax (if (typep result 'syntax)
                    result
                    (macro-s-expression->syntax result invocation))))
    (annotate-macro-expansion syntax invocation macro)))

(defclass environment ()
  ((parent :initarg :parent :initform nil :reader environment-parent)
   ;; An alist makes name comparison explicit instead of relying on a host
   ;; language hash-table equality predicate.
   (bindings :initform '() :accessor environment-bindings)))

(defun make-environment (&optional parent)
  "Create an environment optionally nested beneath PARENT."
  (when parent
    (check-type parent environment))
  (make-instance 'environment :parent parent))

(defun environment-bind (environment name value)
  "Bind NAME to VALUE in ENVIRONMENT, replacing its local binding if present."
  (check-type environment environment)
  (check-type name verona-name)
  (let ((binding (assoc name (environment-bindings environment)
                        :test #'verona-name=)))
    (if binding
        (setf (cdr binding) value)
        (push (cons name value) (environment-bindings environment)))
    value))

(defun environment-find (environment name)
  "Return VALUE and a found flag for NAME, searching lexical parents."
  (loop for current = environment then (environment-parent current)
        while current
        for binding = (assoc name (environment-bindings current)
                             :test #'verona-name=)
        when binding
          do (return (values (cdr binding) t))
        finally (return (values nil nil))))

(defun environment-lookup (environment name)
  "Resolve NAME through ENVIRONMENT and its lexical parents."
  (check-type environment environment)
  (check-type name verona-name)
  (multiple-value-bind (value foundp) (environment-find environment name)
    (if foundp
        value
        (error 'unbound-name-error :name name))))

(defun environment-child (environment)
  "Create a new lexical child of ENVIRONMENT."
  (check-type environment environment)
  (make-environment environment))

(defun macro-at-head (syntax environment)
  "Return the macro bound by SYNTAX's list head, if it has one."
  (let ((datum (syntax-datum syntax)))
    (when (verona-list-p datum)
      (let ((elements (verona-list-elements datum)))
        (when elements
          (let ((head (syntax-datum (first elements))))
            (when (or (verona-name-p head) (qualified-name-p head))
              ;; Qualified macro names are represented structurally in syntax,
              ;; but evaluator bindings intentionally remain ordinary local
              ;; keys.  The compiler installs this unambiguous local spelling
              ;; only for exported imported macros.
              (when (qualified-name-p head)
                (setf head (make-verona-name (qualified-name-string head))))
              (multiple-value-bind (value foundp)
                  (environment-find environment head)
                (and foundp (verona-macro-p value) value)))))))))

(defun expand (syntax environment)
  "Recursively expand a macro in SYNTAX's outermost position.

Expansion intentionally stops once the outer form is not a macro; definition
forms such as %FUNCTION are therefore left as Verona syntax for later processing."
  (check-type syntax syntax)
  (check-type environment environment)
  (let ((*macro-expansion-count* 0))
    (labels ((expand-one (form)
               (let ((macro (macro-at-head form environment)))
                 (if macro
                     (let* ((arguments (rest (verona-list-elements (syntax-datum form))))
                            (result (invoke-verona-macro macro form arguments)))
                       (unless (or (typep result 'syntax) (macro-s-expression-p result))
                         (error 'invalid-macro-result-error :value result))
                       (expand-one (macro-result-syntax result form macro)))
                     form))))
      (expand-one syntax))))

(defun evaluate-list (syntax environment)
  (let* ((elements (verona-list-elements (syntax-datum syntax)))
         (head (first elements)))
    (unless head
      (error 'not-callable-error :value (syntax-datum syntax)))
    (let ((callable (evaluate head environment)))
      (unless (verona-function-p callable)
        (error 'not-callable-error :value callable))
      (apply (verona-function-implementation callable)
             (mapcar (lambda (argument) (evaluate argument environment))
                     (rest elements))))))

(defun syntax-head-is-p (syntax name)
  "Whether SYNTAX is a list headed by the unqualified NAME."
  (let ((datum (syntax-datum syntax)))
    (and (verona-list-p datum)
         (let ((head (first (verona-list-elements datum))))
           (and head
                (verona-name-p (syntax-datum head))
                (string= name (verona-name-value (syntax-datum head))))))))

(defun special-form-arguments (syntax name)
  "Return NAME's arguments, rejecting malformed reader-sugar expansions."
  (let ((arguments (rest (verona-list-elements (syntax-datum syntax)))))
    (unless (= (length arguments) 1)
      (error "~A requires exactly one argument" name))
    arguments))

(defun quasiquote-value (template environment depth)
  "Evaluate unquotes in TEMPLATE, producing an ordinary S-expression."
  (let ((datum (syntax-datum template)))
    (if (not (verona-list-p datum))
        (syntax->macro-s-expression template)
        (cond
          ((syntax-head-is-p template "quasiquote")
           (let ((arguments (special-form-arguments template "quasiquote")))
             (list (syntax->macro-s-expression (first (verona-list-elements datum)))
                   (quasiquote-value (first arguments) environment (1+ depth)))))
          ((syntax-head-is-p template "unquote")
           (let ((arguments (special-form-arguments template "unquote")))
             (if (= depth 1)
                 (let* ((*unquote-evaluation-p* t)
                        (value (evaluate (first arguments) environment)))
                   (unless (macro-s-expression-p value)
                     (error "unquote expression must evaluate to an S-expression, received ~S" value))
                   value)
                 (list (syntax->macro-s-expression (first (verona-list-elements datum)))
                       (quasiquote-value (first arguments) environment (1- depth))))))
          (t
           (mapcar (lambda (element)
                     (quasiquote-value element environment depth))
                   (verona-list-elements datum)))))))

(defun evaluate (syntax environment)
  "Evaluate source-aware Verona SYNTAX in ENVIRONMENT and return a value."
  (check-type syntax syntax)
  (check-type environment environment)
  (let ((datum (syntax-datum syntax)))
    (cond ((verona-name-p datum)
           (environment-lookup environment datum))
          ((qualified-name-p datum)
           ;; Compile-time library functions, like imported macros, use the
           ;; stable textual qualified spelling as their evaluator key.
           (environment-lookup environment
                               (make-verona-name (qualified-name-string datum))))
          ((verona-list-p datum)
           (cond ((syntax-head-is-p syntax "quote")
                  (syntax->macro-s-expression
                   (first (special-form-arguments syntax "quote"))))
                 ((syntax-head-is-p syntax "quasiquote")
                 (quasiquote-value
                   (first (special-form-arguments syntax "quasiquote")) environment 1))
                 ((syntax-head-is-p syntax "unquote")
                  (if *unquote-evaluation-p*
                      (evaluate (first (special-form-arguments syntax "unquote")) environment)
                      (error "unquote is valid only inside quasiquote")))
                 (t
                  (let ((expanded (expand syntax environment)))
                    (if (eq expanded syntax)
                        (evaluate-list syntax environment)
                        (evaluate expanded environment))))))
          ;; Unit, booleans, characters, numbers, and strings are
          ;; self-evaluating values.
          (t datum))))

(defun bootstrap-generated-name (form name)
  (syntax-with-datum form (make-verona-name name)))

(defun bootstrap-generated-list (form &rest elements)
  (syntax-with-datum form (apply #'make-verona-list elements)))

(defun bootstrap-definition-clause (form name value)
  (bootstrap-generated-list form (bootstrap-generated-name form name) value))

(defun bootstrap-function-type (form parameters result)
  (bootstrap-generated-list form (bootstrap-generated-name form "function")
                            parameters result))

(defun bootstrap-definition-arguments (form primitive-name arguments count)
  (unless (= (length arguments) count)
    (error "~A requires ~D argument~:P" primitive-name count))
  arguments)

(defun bootstrap-definition-expansion (form primitive-name arguments)
  "Translate established surface declarations into named primitive clauses.

Only information expressed by the existing surface forms is generated.  A
later macro package will own documentation and other richer attributes."
  (flet ((clauses (&rest clauses)
           (let ((elements (verona-list-elements (syntax-datum form))))
             (syntax-with-datum form
                                (apply #'make-verona-list
                                       (syntax-with-datum (first elements)
                                                          (make-verona-name primitive-name))
                                       clauses)))))
    (cond
      ((string= primitive-name "%type")
       (unless (member (length arguments) '(1 2))
         (error "%type requires a name and at most one type body"))
       (let ((name (first arguments)))
         (if (null (rest arguments))
             (clauses name
                      (bootstrap-definition-clause form ":type"
                                                   (bootstrap-generated-name form "opaque")))
             (let* ((body (second arguments))
                    (datum (syntax-datum body))
                    (elements (and (verona-list-p datum) (verona-list-elements datum)))
                    (head (and elements (syntax-datum (first elements))))
                    (type (if (and (verona-name-p head)
                                   (member (verona-name-value head) '("product" "sum")
                                           :test #'string=))
                              body
                              (bootstrap-generated-list form
                                                        (bootstrap-generated-name form "alias")
                                                        body))))
               ;; Preserve the old surface diagnostic instead of turning an
               ;; accidental field list into an alias target that fails much
               ;; later during semantic resolution.
               (when (and elements
                          (or (verona-list-p head)
                              (and (= (length elements) 2)
                                   (verona-name-p head)
                                   (not (member (verona-name-value head)
                                                '("pointer" "array" "product" "sum")
                                                :test #'string=)))))
                 (definition-fail form
                                  "implicit product syntax is not supported; use (type ~A (product ...))"
                                  (verona-name-value (syntax-datum name))))
               (clauses name (bootstrap-definition-clause form ":type" type))))))
      ((string= primitive-name "%function")
       (unless (member (length arguments) '(4 5))
         (error "%function requires a name, optional for clause, parameters, return type, and body"))
       (let ((polymorphic-p (= (length arguments) 5)))
         (let ((name (first arguments))
               (for-clause (and polymorphic-p (second arguments)))
               (parameters (if polymorphic-p (third arguments) (second arguments)))
               (result (if polymorphic-p (fourth arguments) (third arguments)))
               (body (if polymorphic-p (fifth arguments) (fourth arguments))))
           (apply #'clauses name
                  (append (list (bootstrap-definition-clause
                                 form ":type"
                                 (bootstrap-function-type form parameters result)))
                          (when for-clause
                            (list (bootstrap-definition-clause form ":for" for-clause)))
                          (list (bootstrap-definition-clause form ":implementation" body)))))))
      ((string= primitive-name "%external-function")
       (bootstrap-definition-arguments form primitive-name arguments 4)
       (destructuring-bind (name external-name parameters result) arguments
         (clauses name
                  (bootstrap-definition-clause form ":type"
                                               (bootstrap-function-type form parameters result))
                  (bootstrap-definition-clause form ":external-name" external-name))))
      ((string= primitive-name "%macro")
       (bootstrap-definition-arguments form primitive-name arguments 3)
       (destructuring-bind (name parameters body) arguments
         (clauses name
                  (bootstrap-definition-clause form ":parameters" parameters)
                  (bootstrap-definition-clause form ":implementation" body))))
      ((or (string= primitive-name "%constant")
           (string= primitive-name "%variable"))
       (bootstrap-definition-arguments form primitive-name arguments 3)
       (destructuring-bind (name type implementation) arguments
         (clauses name
                  (bootstrap-definition-clause form ":type" type)
                  (bootstrap-definition-clause form ":implementation" implementation))))
      ((string= primitive-name "%generic")
       (bootstrap-definition-arguments form primitive-name arguments 2)
       (destructuring-bind (name parameters) arguments
         (clauses name (bootstrap-definition-clause form ":parameters" parameters))))
      ((string= primitive-name "%protocol")
       (when (< (length arguments) 2)
         (error "%protocol requires a name and type parameter list"))
       (let ((name (first arguments))
             (parameters (second arguments))
             (operations (apply #'bootstrap-generated-list form (cddr arguments))))
         (clauses name
                  (bootstrap-definition-clause form ":parameters" parameters)
                  (bootstrap-definition-clause form ":operations" operations))))
      ((string= primitive-name "%implementation")
       (when (< (length arguments) 2)
         (error "%implementation requires a target and payload"))
       (let ((target (first arguments)))
         (if (verona-list-p (syntax-datum target))
             (clauses
              (bootstrap-definition-clause form ":protocol" target)
              (bootstrap-definition-clause
               form ":operations"
               (apply #'bootstrap-generated-list form (rest arguments))))
             (progn
               (bootstrap-definition-arguments form primitive-name arguments 4)
               (destructuring-bind (generic parameters result body) arguments
                 (clauses
                  (bootstrap-definition-clause form ":generic" generic)
                  (bootstrap-definition-clause form ":type"
                                               (bootstrap-function-type form parameters result))
                  (bootstrap-definition-clause form ":implementation" body)))))))
      (t (error "unknown bootstrap primitive ~S" primitive-name)))))

(defun bootstrap-definition-macro (primitive-name)
  "Make a surface definition macro that emits PRIMITIVE-NAME's named clauses."
  (make-verona-macro
   (lambda (&rest arguments)
     (let ((source *macro-expansion-syntax*))
       (syntax->macro-s-expression
        (bootstrap-definition-expansion
         source primitive-name
         (mapcar (lambda (argument)
                   (macro-s-expression->syntax argument source))
                 arguments)))))))

(defun make-bootstrap-environment ()
  "Create the evaluator environment and its standard Verona definition macros."
  (let ((environment (make-environment)))
    ;; This primitive exists solely to prove ordinary and nested calls.  Its
    ;; binding key is a Verona name, never the host's CL:+ symbol.
    (environment-bind environment (make-verona-name "+")
                      (make-verona-function #'+))
    ;; The compiler recognizes only the %... forms.  The ordinary declaration
    ;; vocabulary belongs to this Verona-level environment instead.
    (dolist (definition '( ("type" . "%type")
                           ("function" . "%function")
                           ("external-function" . "%external-function")
                           ("macro" . "%macro")
                           ("constant" . "%constant")
                           ("variable" . "%variable")
                           ("generic" . "%generic")
                           ("protocol" . "%protocol")
                           ("implementation" . "%implementation")))
      (environment-bind environment (make-verona-name (car definition))
                        (bootstrap-definition-macro (cdr definition))))
    environment))
