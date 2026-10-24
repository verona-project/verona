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

(test-cases evaluates-reader-sugar-and-macro-errors
  (quote
   (let* ((value (evaluate (first (read-source (make-source "quote.vrn" "'(first second)")))
                           (make-bootstrap-environment))))
     (is (equal '("first" "second") (mapcar #'verona-name-value value)))))
  (quasiquote-with-unquote
   (let* ((value (evaluate
                  (first (read-source
                          (make-source "quasiquote.vrn"
                                       "(quasiquote (pair (unquote (quote answer))))")))
                  (make-bootstrap-environment))))
     (is (equal '("pair" "answer") (mapcar #'verona-name-value value)))))
  (unquote-outside-quasiquote
   (signals error
     (evaluate (first (read-source (make-source "unquote.vrn" "(unquote value)")))
               (make-bootstrap-environment))))
  (non-callable-list-head
   (signals verona:not-callable-error
     (evaluate (first (read-source (make-source "call.vrn" "(42)")))
               (make-bootstrap-environment))))
  (invalid-macro-result
   (let ((environment (make-environment)))
     (environment-bind environment (make-verona-name "invalid")
                       (make-verona-macro (lambda (&rest arguments)
                                            (declare (ignore arguments))
                                            (make-hash-table))))
     (signals verona::invalid-macro-result-error
       (expand (first (read-source (make-source "macro.vrn" "(invalid)"))) environment)))))

(test compile-time-control-and-empty-list-contract
  (dolist (source '("nil" "'nil" "'()" "(cond)" "(cond (false 1))"))
    (is (null (evaluate-macro-data-form source))))
  (is (= 7 (evaluate-macro-data-form
             "(let ((x 3) (y (+ x 4))) x (cond (false missing) (true y)))")))
  (is (verona::compile-time-condition (evaluate-macro-data-form "(and)")))
  (is (not (verona::compile-time-condition (evaluate-macro-data-form "(or)"))))
  (is (not (verona::compile-time-condition (evaluate-macro-data-form "(and false missing)"))))
  (is (verona::compile-time-condition (evaluate-macro-data-form "(or true missing)")))
  (is (verona::compile-time-condition (evaluate-macro-data-form "(not false)")))
  (dolist (source '("(cond (nil 1))" "(and true 1)" "(or false nil)"
                    "(not nil)" "(cond (true))" "(cond (true 1) malformed)"
                    "(let ((x 1) (x 2)) x)" "(let ((x)) x)" "(let ())"
                    "(let ((nil 1)) nil)"))
    (signals verona::evaluator-error (evaluate-macro-data-form source)))
  (let ((environment (verona::make-compilation-environment)))
    (evaluate (first (read-source (make-source "scope.vrn" "(let ((local 1)) local)"))) environment)
    (signals unbound-name-error (environment-lookup environment (make-verona-name "local")))))

(test compile-time-data-library
  (dolist (source '("(equal? '(a (b) m:c) '(a (b) m:c))"
                    "(equal? '(nil) '(()))" "(equal? true true)"
                    "(not (equal? false nil))" "(not (equal? unit nil))"
                    "(number? 1.5)" "(integer? 999999999999999999999999)"
                    "(string? \"x\")" "(symbol? 'm:x)" "(keyword? ':name)"
                    "(not (keyword? (keyword \"name\")))" "(list? nil)" "(empty? nil)"
                    "(boolean? false)" "(= (+) 0)" "(= (*) 1)"
                    "(= (- 4) -4)" "(= (/ 4 2) 2)" "(= (/ 1 2) 0.5)"
                    "(= (quotient -7 3) -2)" "(= (remainder -7 3) -1)"
                    "(= (abs -3) (min 3 9))" "(= (max 3 9) 9)"
                    "(< 1 2 3)" "(<= 1 1 2)" "(> 3 2 1)" "(>= 2 2 1)"
                    "(/= 1 2 3)" "(not (/= 1 2 1))"
                    "(equal? (take 2 '(a b c)) '(a b))"
                    "(equal? (drop 2 '(a b c)) '(c))"
                    "(equal? (nth 1 '(a b)) 'b)" "(equal? (reverse '(a b)) '(b a))"
                    "(equal? (take 0 nil) nil)" "(equal? (drop 0 nil) nil)"
                    "(plist-has? '(:a nil) ':a)" "(not (plist-has? '(:a nil) ':b))"
                    "(equal? (plist-ref '(:a nil) ':a 7) nil)"
                    "(= (plist-ref nil ':a 7) 7)"
                    "(equal? (plist-set '(:a 1 :b 2) ':a 3) '(:a 3 :b 2))"
                    "(equal? (plist-set '(:a 1) ':b 2) '(:a 1 :b 2))"
                    "(equal? (plist-remove '(:a 1 :b 2) ':a) '(:b 2))"
                    "(equal? (plist-keys '(:a 1 :b 2)) '(:a :b))"
                    "(alist-has? '((key nil)) 'key)"
                    "(equal? (alist-ref '((key nil)) 'key 7) nil)"
                    "(equal? (alist-set '((a 1) (b 2)) 'a 3) '((a 3) (b 2)))"
                    "(equal? (alist-remove '((a 1) (b 2)) 'a) '((b 2)))"
                    "(equal? (alist-keys '((a 1) (b 2))) '(a b))"
                    "(equal? (alist-values '((a 1) (b 2))) '(1 2))"
                    "(string= (string-join (string-split \"a,,b,\" \",\") \",\") \"a,,b,\")"
                    "(string= (string-replace \"aaaaa\" \"aa\" \"x\") \"xxa\")"
                    "(string-prefix? \"ab\" \"abc\")" "(string-suffix? \"bc\" \"abc\")"
                    "(not (string-prefix? \"A\" \"abc\"))"
                    "(string= (keyword-name ':name) \"name\")"
                    "(equal? (symbol->keyword 'name) ':name)"
                    "(equal? (symbol->keyword ':name) ':name)"
                    "(equal? (keyword->symbol ':name) 'name)"
                    "(= (string->number (number->string 12345678901234567890)) 12345678901234567890)"
                    "(= (string->number (number->string 1.25)) 1.25)"))
    (is (verona::compile-time-condition (evaluate-macro-data-form source)) "~A" source))
  (dolist (source '("(/ 1 0)" "(quotient 1.5 2)" "(+ true 1)" "(min)"
                    "(nth -1 '(a))" "(nth 1 '(a))" "(take 2 '(a))"
                    "(plist-ref '(:a 1 :a 2) ':a)" "(plist-keys '(:a))"
                    "(alist-values '((a 1 2)))" "(alist-keys '((a 1) (a 2)))"
                    "(string-split \"abc\" \"\")" "(string->number \"1/2\")"
                    "(string->number \"1 2\")" "(keyword-name 'name)"))
    (signals verona::evaluator-error (evaluate-macro-data-form source))))

(test compile-time-errors-retain-source
  (handler-case (evaluate-macro-data-form "(let ((x 1)) (+ x nil))")
    (verona::evaluator-error (condition)
      (is (not (null (verona::condition-primary-range condition)))))))

(test compile-time-state-copies-and-presence
  (let* ((verona::*expansion-context*
           (verona::make-expansion-context :session (verona::make-compilation-session)))
         (key (make-verona-name "key"))
         (input (list (copy-seq "hello"))))
    (verona::compile-time-state-set key input)
    (setf (char (first input) 0) #\X)
    (let ((output (verona::compile-time-state-ref key)))
      (is (string= "hello" (first output)))
      (setf (char (first output) 0) #\Y)
      (is (string= "hello" (first (verona::compile-time-state-ref key)))))
    (verona::compile-time-state-set key nil)
    (is (verona::compile-time-condition (verona::compile-time-state-has key)))
    (is (null (verona::compile-time-state-ref key 7)))
    (is (verona::compile-time-condition (verona::compile-time-state-remove key)))
    (is (not (verona::compile-time-condition (verona::compile-time-state-remove key))))
    (is (= 7 (verona::compile-time-state-ref key 7))))
  (signals verona::evaluator-error (evaluate-macro-data-form "(compiler:state-ref 'key)")))

(test malformed-host-lists-produce-source-aware-diagnostics
  (let ((environment (verona::make-compilation-environment))
        (cycle (list 1)))
    (setf (cdr cycle) cycle)
    (dolist (value (list cycle (cons 1 2)))
      (environment-bind environment (make-verona-name "malformed") value)
      (dolist (source '("(length malformed)" "(reverse malformed)" "(take 1 malformed)"))
        (let ((form (first (read-source (make-source "host-list.vrn" source)))))
          (handler-case (progn (evaluate form environment) (fail "expected an evaluator diagnostic"))
            (verona::evaluator-error (condition)
              (is (typep (verona::condition-primary-range condition) 'verona:source-range)))))))))
