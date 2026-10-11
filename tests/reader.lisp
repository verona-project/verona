(in-package #:verona/tests)

(in-suite :verona)

(test reads-atoms
  (let ((forms (read-source (make-source "atoms.vrn" "foo 42 -42 3.14 \"hello\" unit"))))
    (is (= 6 (length forms)))
    (is (string= "foo" (verona-symbol-name (syntax-datum (first forms)))))
    (is (= 42 (syntax-datum (second forms))))
    (is (= -42 (syntax-datum (third forms))))
    (is (= 3.14d0 (syntax-datum (fourth forms))))
    (is (string= "hello" (syntax-datum (fifth forms))))
    (is (unit-literal-p (syntax-datum (sixth forms))))))

(test-cases reads-single-line-comments
  (skips-comments
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
    (is (string= "baz" (verona-symbol-name (syntax-datum (second forms)))))))
  (literals-remain-data
   ;; Semicolons remain ordinary data inside literals.
   (let ((forms (read-source (make-source "comments.vrn" "\";\" #\\; ; comment"))))
   (is (= 2 (length forms)))
   (is (string= ";" (syntax-datum (first forms))))
    (is (char= #\; (syntax-datum (second forms)))))))

(test-cases reads-common-lisp-style-character-literals
  (valid-literals
   (let ((forms (read-source (make-source "characters.vrn" "#\\a #\\space #\\newline #\\vertical_tab #\\form_feed #\\)"))))
    (is (= 6 (length forms)))
    (is (char= #\a (syntax-datum (first forms))))
    (is (char= #\Space (syntax-datum (second forms))))
    (is (char= #\Newline (syntax-datum (third forms))))
    (is (= 11 (char-code (syntax-datum (fourth forms)))))
    (is (= 12 (char-code (syntax-datum (fifth forms)))))
    (is (char= #\) (syntax-datum (sixth forms))))))
  (rejects-multi-character-name
   (signals verona-read-error
     (read-source (make-source "characters.vrn" "#\\ab"))))
  (rejects-non-ascii-character
   (signals verona-read-error
     (read-source (make-source "characters.vrn" "#\\λ"))))
  (rejects-non-ascii-string
   (signals verona-read-error
     (read-source (make-source "strings.vrn" "\"λ\"")))))

(test-cases resolves-character-and-string-literals
  (character-literal
   (let* ((unit (compile-string (make-compiler) "(function letter () char #\\a)"))
         (program (compilation-unit-semantic-program unit))
         (letter (semantic-program-declaration program (first (unit-declarations unit))))
         (context (semantic-program-type-context program)))
    (is (typep (semantic-function-declaration-body letter) 'character-literal))
    (is (char= #\a (character-literal-value (semantic-function-declaration-body letter))))
     (is (eq (type-context-char-type context)
            (semantic-function-declaration-return-type letter)))))
  (string-literal
   (let* ((unit (compile-string (make-compiler)
                                "(function greeting () (pointer u8) \"hello\")"))
          (program (compilation-unit-semantic-program unit))
          (greeting (semantic-program-declaration program (first (unit-declarations unit)))))
     (is (typep (semantic-function-declaration-body greeting) 'string-literal)))))

(test-cases resolves-character-match-patterns
  (character-pattern
   (let* ((unit (compile-string
                 (make-compiler)
                 "(function choose ((operator char)) i32 (match operator (#\\+ 1) (_ 0)))"))
         (program (compilation-unit-semantic-program unit))
         (choose (semantic-program-declaration program (first (unit-declarations unit))))
         (choose-pattern (match-case-pattern
                          (first (match-expression-cases (semantic-function-declaration-body choose))))))
     (is (typep choose-pattern 'character-pattern))
    (is (eq program (validate-for-backend program)))))
  (integer-pattern
   (let* ((unit (compile-string
                 (make-compiler)
                 "(function c-input ((operator i32)) i32 (match operator (#\\- 1) (_ 0)))"))
          (program (compilation-unit-semantic-program unit))
          (input (semantic-program-declaration program (first (unit-declarations unit))))
          (pattern (match-case-pattern
                    (first (match-expression-cases (semantic-function-declaration-body input))))))
     (is (typep pattern 'integer-pattern))
     (is (eq program (validate-for-backend program))))))


(test rejects-references-to-discarded-match-values
  ;; Even an outer binding named `_` must not make a wildcard pattern's
  ;; discarded value observable from its match case.
  (signals verona:invalid-expression-error
    (compile-string
     (make-compiler)
     "(function invalid ((_ i32) (value i32)) i32
        (match value
          (_ _)))")))
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

(test-cases rejects-dot-prefixed-floats
  (leading-decimal
   (signals verona-read-error
     (read-source (make-source "invalid.vrn" ".5"))))
  (bare-dot
   (signals verona-read-error
     (read-source (make-source "invalid.vrn" ".")))))

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
