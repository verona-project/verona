(in-package #:verona/tests)

(in-suite :verona)

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

(test-cases evaluates-literals-names-and-nested-calls
  (literal
   (is (= 10 (evaluate (first (read-source (make-source "evaluate.vrn" "10")))
                       (make-bootstrap-environment)))))
  (nested-call
   (is (= 6 (evaluate (first (read-source (make-source "evaluate.vrn" "(+ 1 (+ 2 3))")))
                      (make-bootstrap-environment))))))

(defun evaluate-macro-data-form (source)
  (evaluate (first (read-source (make-source "macro-data.vrn" source)))
            (verona::make-compilation-environment)))

(test-cases evaluates-macro-data-as-plain-s-expressions
  (symbol-name
   (is (string= "answer" (evaluate-macro-data-form "(symbol-name 'answer)"))))
  (keyword-concat
   (let ((generated-name (evaluate-macro-data-form
                          "(keyword-concat (keyword \"left-\") (symbol \"i32\"))")))
     (is (verona-name-p generated-name))
     (is (string= "left-i32" (verona-name-value generated-name)))))
  (car
   (let ((head (evaluate-macro-data-form "(car '(first second))")))
     (is (verona-name-p head))
     (is (string= "first" (verona-name-value head)))))
  (append
   (is (equal '("first" "second" "third")
              (mapcar #'verona-name-value
                      (evaluate-macro-data-form "(append '(first) '(second third))"))))))

(test traverses-compile-time-lists-while-constructing-syntax
  (let* ((environment (verona::make-compilation-environment))
         (forms (read-source
                 (make-source
                  "list-traversal.vrn"
                  "(compiler:call 'wrap '(value))
                   (compiler:map 'wrap '((first) (second)))
                   (compiler:map 'pair '(first second) '(left right))
                   (compiler:reduce 'combine '(empty) '((first) (second)))
                   (compiler:reduce-right 'combine '(empty) '((first) (second)))
                   (compiler:reverse '(first second third))")))
         (results (mapcar (lambda (form) (evaluate form environment)) forms)))
    (labels ((names (value)
               (if (listp value)
                   (mapcar #'names value)
                   (if (verona-name-p value)
                       (verona-name-value value)
                       value))))
      (is (equal '("wrap" ("value")) (names (first results))))
      (is (equal '(("wrap" ("first")) ("wrap" ("second")))
                 (names (second results))))
      (is (equal '(("pair" "first" "left") ("pair" "second" "right"))
                 (names (third results))))
      (is (equal '("combine" ("combine" ("empty") ("first")) ("second"))
                 (names (fourth results))))
      (is (equal '("combine" ("first") ("combine" ("second") ("empty")))
                 (names (fifth results))))
      (is (equal '("third" "second" "first") (names (sixth results)))))))

(test does-not-expose-the-compiler-definition-macro-bridge
  (signals unbound-name-error
    (environment-lookup (verona::make-compilation-environment)
                        (make-verona-name "compiler:definition"))))

(test expands-macros-with-unevaluated-syntax-and-recursion
  (let* ((environment (make-environment))
	 (received nil)
	 (forms (read-source (make-source "macro.vrn" "(example foo 42)"))))
    (environment-bind
     environment (make-verona-name "example")
     (make-verona-macro
      (lambda (&rest arguments)
	(setf received arguments)
	(cons (make-verona-name "intermediate") arguments))))
    (environment-bind
     environment (make-verona-name "intermediate")
     (make-verona-macro
      (lambda (&rest arguments)
	(cons (make-verona-name "%test-definition") arguments))))
    (let* ((expanded (expand (first forms) environment))
	   (elements (verona-list-elements (syntax-datum expanded))))
      (is (= 2 (length received)))
      (is (verona-name-p (first received)))
      (is (string= "foo" (verona-name-value (first received))))
      (is (string= "%test-definition"
		   (verona-name-value (syntax-datum (first elements)))))
      (is (string= "foo" (verona-name-value (syntax-datum (second elements))))))))
