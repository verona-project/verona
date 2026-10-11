(in-package #:verona/tests)

(in-suite :verona)

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

(defun assert-bootstrap-definition-macro (name)
  (is (verona-macro-p
       (environment-lookup (make-bootstrap-environment) (make-verona-name name)))))

(test-cases bootstraps-the-public-definition-vocabulary-as-macros
  (type (assert-bootstrap-definition-macro "type"))
  (function (assert-bootstrap-definition-macro "function"))
  (macro (assert-bootstrap-definition-macro "macro"))
  (constant (assert-bootstrap-definition-macro "constant"))
  (variable (assert-bootstrap-definition-macro "variable"))
  (generic (assert-bootstrap-definition-macro "generic"))
  (implementation (assert-bootstrap-definition-macro "implementation")))

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

(test expands-macros-in-runtime-expression-positions
  (let* ((module (compile-string
                  (make-compiler)
                  "(macro identity (form) form)
                   (function literal () i8 (identity 42))
                   (function nested () i32 (do (identity 0) (identity 7)))"
                  :name "expression-macros.vrn"))
         (declarations (unit-declarations module))
         (program (compilation-unit-semantic-program module))
         (literal (semantic-program-declaration program (second declarations)))
         (nested (semantic-program-declaration program (third declarations)))
         (literal-body (semantic-function-declaration-body literal))
         (nested-body (semantic-function-declaration-body nested))
         (nested-expressions (sequence-expression-expressions nested-body)))
    ;; Declarations retain the source invocation; only the semantic expression
    ;; is replaced by the macro result.
    (is (string= "identity"
                 (verona-name-value
                  (syntax-datum
                   (first (verona-list-elements
                           (syntax-datum (function-declaration-body
                                          (second declarations)))))))))
    (is (typep literal-body 'integer-literal))
    (is (= 42 (integer-literal-value literal-body)))
    (is (typep nested-body 'sequence-expression))
    (is (every (lambda (expression) (typep expression 'integer-literal))
               nested-expressions))
    (is (equal '(0 7) (mapcar #'integer-literal-value nested-expressions)))))

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
