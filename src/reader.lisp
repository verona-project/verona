(in-package #:verona)

(define-condition verona-read-error (user-compilation-error)
  ((source :initarg :source :reader verona-read-error-source)
   (location :initarg :location :reader verona-read-error-location)
   (message :initarg :message :reader verona-read-error-message))
  (:report (lambda (condition stream)
             (let ((location (verona-read-error-location condition)))
               (format stream "~A:~D:~D: ~A"
                       (source-name (verona-read-error-source condition))
                       (source-location-line location)
                       (source-location-column location)
                       (verona-read-error-message condition))))))

(defmethod diagnostic-code-for ((condition verona-read-error))
  (declare (ignore condition)) "E0001")

(defmethod condition-primary-range ((condition verona-read-error))
  (let ((location (verona-read-error-location condition)))
    (make-source-range location location)))

(defstruct (reader-state (:constructor make-reader-state (source features)))
  source
  ;; Feature names are normalized once at the reader boundary.  The syntax
  ;; itself remains free of host or target-specific reader objects.
  (features '() :type list)
  (offset 0 :type (integer 0 *))
  (nesting-depth 0 :type (integer 0 *)))

(defparameter *reader-nesting-depth-limit* 1024
  "Maximum balanced list nesting accepted from one Verona source file.")

(defun reader-contents (state)
  (source-contents (reader-state-source state)))

(defun reader-at-end-p (state)
  (>= (reader-state-offset state) (length (reader-contents state))))

(defun reader-peek (state)
  (unless (reader-at-end-p state)
    (char (reader-contents state) (reader-state-offset state))))

(defun reader-advance (state)
  (prog1 (reader-peek state)
    (incf (reader-state-offset state))))

(defun reader-location (state)
  (source-location-at (reader-state-source state) (reader-state-offset state)))

(defun reader-fail (state message &optional (offset (reader-state-offset state)))
  (error 'verona-read-error
         :source (reader-state-source state)
         :location (source-location-at (reader-state-source state) offset)
         :message message))

(defun verona-whitespace-p (character)
  (and character
       (member character '(#\Space #\Tab #\Newline #\Return) :test #'char=)))

(defun verona-delimiter-p (character)
  (or (null character)
      (verona-whitespace-p character)
      (member character '(#\( #\) #\; #\" #\' #\` #\,)
              :test #'char=)))

(defun feature-name-string (feature)
  "Return FEATURE's case-insensitive external spelling.

Feature conditionals deliberately use a separate namespace from ordinary
Verona identifiers.  This matches Common Lisp's conventional lower-case
feature spelling while preserving the language's case-sensitive identifiers."
  (string-downcase
   (etypecase feature
     (string feature)
     (symbol (symbol-name feature))
     (verona-name (verona-name-value feature)))))

(defun feature-available-p (state feature)
  (member (feature-name-string feature) (reader-state-features state)
          :test #'string=))

(defun skip-whitespace (state)
  (loop while (verona-whitespace-p (reader-peek state))
        do (reader-advance state)))

(defun skip-line-comment (state)
  "Consume a semicolon comment, leaving its line ending for whitespace handling."
  (loop for character = (reader-peek state)
        while (and character
                   (not (member character '(#\Newline #\Return) :test #'char=)))
        do (reader-advance state)))

(defun skip-layout (state)
  "Consume whitespace and semicolon-to-end-of-line comments."
  (loop do (skip-whitespace state)
            (if (and (reader-peek state)
                     (char= (reader-peek state) #\;))
                (skip-line-comment state)
                (return))))

(defun decimal-digits-p (text start end)
  (and (< start end)
       (loop for index from start below end
             always (digit-char-p (char text index)))))

(defun integer-literal-p (text)
  (let ((start (if (and (> (length text) 0)
                        (find (char text 0) "+-" :test #'char=))
                   1
                   0)))
    (decimal-digits-p text start (length text))))

(defun float-literal-p (text)
  (let* ((sign-end (if (and (> (length text) 0)
                            (find (char text 0) "+-" :test #'char=))
                       1
                       0))
         (dot (position #\. text :start sign-end)))
    (and dot
         (null (position #\. text :start (1+ dot)))
         (decimal-digits-p text sign-end dot)
         (decimal-digits-p text (1+ dot) (length text)))))

(defun read-module-name-text (state text start)
  "Parse dotted module spelling only where the grammar requests it."
  (let ((components '()) (component-start 0))
    (labels ((finish-component (end)
               (when (= component-start end)
                 (reader-fail state "module name contains an empty component" start))
               (push (make-verona-name (subseq text component-start end)) components)))
      (loop for index from 0 below (length text)
            when (char= (char text index) #\.)
              do (finish-component index) (setf component-start (1+ index)))
      (finish-component (length text)))
    (apply #'make-module-name (nreverse components))))

(defun read-qualified-name-text (state text start)
  (let ((separator (position #\: text)))
    (when (or (null separator)
              (= separator 0)
              (= separator (1- (length text)))
              (position #\: text :start (1+ separator)))
      (reader-fail state "qualified names use exactly one ':'" start))
    (let ((member (subseq text (1+ separator))))
      (when (find #\. member)
        (reader-fail state "the member of a qualified name must be a name" start))
      (make-qualified-name
       (read-module-name-text state (subseq text 0 separator) start)
       (make-verona-name member)))))

(defun read-atom (state start)
  (let ((text (with-output-to-string (output)
                (loop for character = (reader-peek state)
                      until (verona-delimiter-p character)
                      do (write-char (reader-advance state) output)))))
    (when (string= text "")
      (reader-fail state "expected a form" start))
    (cond ((string= text "unit")
           ;; UNIT is the one source spelling shared by UnitType and its
           ;; only inhabitant.  The semantic phase assigns its meaning from
           ;; context; the reader records the atom without host symbols.
           (make-unit-literal))
          ((string= text "true") (make-verona-boolean-literal t))
          ((string= text "false") (make-verona-boolean-literal nil))
          ((integer-literal-p text)
           (handler-case
               (parse-integer text)
             (error () (reader-fail state "integer literal is out of range" start))))
          ((float-literal-p text)
           ;; The grammar has no exponent notation; appending D0 makes the
           ;; resulting Common Lisp number the language's f64 representation.
           (read-from-string (concatenate 'string text "d0")))
          ;; Leading-colon names are declaration clauses.  `:as` predates
          ;; the general form as IMPORT's alias clause; retaining all of them
          ;; as ordinary Verona names keeps clause parsing in the compiler.
          ((and (plusp (length text)) (char= (char text 0) #\:))
           (make-verona-name text))
          ((find #\: text) (read-qualified-name-text state text start))
          ((find #\. text)
           ;; Dots are meaningful only when an enclosing grammar production
           ;; asks for a module name.  Keep the atom opaque here; IMPORT
           ;; validates it as a ModuleName later.
           (if (some #'digit-char-p text)
               (reader-fail state "invalid numeric literal" start)
               (make-verona-name text)))
          (t (make-verona-name text)))))

(defun read-string-literal (state start)
  (reader-advance state)
  (let ((value (with-output-to-string (output)
                 (loop for character = (reader-peek state)
                       do (when (null character)
                            (reader-fail state "unterminated string literal" start))
                          (reader-advance state)
                          (cond ((char= character #\") (return))
                                ((char= character #\\)
                                 (let ((escaped (reader-peek state)))
                                   (when (null escaped)
                                     (reader-fail state "unterminated string literal" start))
                                   (reader-advance state)
                                   (case escaped
                                     (#\n (write-char #\Newline output))
                                     (#\t (write-char #\Tab output))
                                     (#\" (write-char #\" output))
                                     (#\\ (write-char #\\ output))
                                     (otherwise (reader-fail state "unsupported string escape")))))
                                (t
                                 (unless (<= (char-code character) #x7f)
                                   (reader-fail state
                                                "string literals are ASCII-only; Unicode strings will use #ustring"
                                                start))
                                 (write-char character output)))))))
    value))

(defun read-character-literal (state start)
  "Read a Common Lisp-style #\\CHARACTER literal.

The source representation deliberately stays a host CHARACTER, just as a
string literal stays a host string.  Semantic analysis gives it Verona's
distinct CHAR type later."
  ;; Consume #\\.  The first character is consumed before looking for a
  ;; delimiter so spellings such as #\\) and #\\Space work naturally.
  (reader-advance state)
  (reader-advance state)
  (let ((first (reader-peek state)))
    (when (null first)
      (reader-fail state "character literal requires one character" start))
    (let ((text (with-output-to-string (output)
                  (write-char (reader-advance state) output)
                  (loop for character = (reader-peek state)
                        until (verona-delimiter-p character)
                        do (write-char (reader-advance state) output)))))
      (let ((character
              (cond ((= (length text) 1) (char text 0))
                    ((string-equal text "space") #\Space)
                    ((string-equal text "newline") #\Newline)
                    ((string-equal text "tab") #\Tab)
    ((string-equal text "vertical_tab")
     (code-char 11))
    ((string-equal text "form_feed")
     (code-char 12))
                    ((string-equal text "return") #\Return)
                    (t (reader-fail state
                                    "character literal must name exactly one character"
                                    start)))))
        (unless (<= (char-code character) #x7f)
          (reader-fail state
                       "character literals are ASCII-only; Unicode characters are not supported yet"
                       start))
        character))))

(defun read-list (state start)
  (when (>= (reader-state-nesting-depth state) *reader-nesting-depth-limit*)
    (reader-fail state "reader nesting limit exceeded" start))
  (reader-advance state)
  (incf (reader-state-nesting-depth state))
  (unwind-protect
       (let ((elements '()))
         (loop do (skip-layout state)
                   (when (reader-at-end-p state)
                     (reader-fail state "unterminated list" start))
                   (when (char= (reader-peek state) #\))
                     (reader-advance state)
                     (return (apply #'make-verona-list (nreverse elements))))
                   (multiple-value-bind (form present-p) (read-form state)
                     (when present-p
                       (push form elements)))))
    (decf (reader-state-nesting-depth state))))

(defun read-feature-conditional (state start)
  "Read #+FEATURE FORM or #-FEATURE FORM, returning FORM only when selected."
  (reader-advance state)
  (let ((operator (reader-peek state)))
    (unless (member operator '(#\+ #\-) :test #'char=)
      (reader-fail state "expected '+' or '-' after '#'" start))
    (reader-advance state)
    (let* ((feature-start (reader-state-offset state))
           (feature (with-output-to-string (output)
                      (loop for character = (reader-peek state)
                            until (verona-delimiter-p character)
                            do (write-char (reader-advance state) output)))))
      (when (string= feature "")
        (reader-fail state "expected a feature name after reader conditional" feature-start))
      ;; Always read the controlled form, including an unselected one.  That
      ;; keeps delimiters and source-location accounting correct while letting
      ;; unavailable platform code contain otherwise invalid declarations.
      (multiple-value-bind (form present-p) (read-form state)
        (values form
                (and present-p
                     (if (char= operator #\+)
                         (feature-available-p state feature)
                         (not (feature-available-p state feature)))))))))

(defun read-prefixed-form (state start name)
  "Read reader sugar such as `FORM or ,FORM as an ordinary syntax list."
  (reader-advance state)
  (when (reader-at-end-p state)
    (reader-fail state (format nil "~A requires a following form" name) start))
  (multiple-value-bind (form present-p) (read-form state)
    (unless present-p
      (reader-fail state (format nil "~A requires a selected following form" name) start))
    (make-verona-list
     (make-syntax (make-verona-name name) (reader-state-source state)
                  (source-location-at (reader-state-source state) start)
                  (reader-location state))
     form)))

(defun read-form (state)
  (skip-layout state)
  (when (reader-at-end-p state)
    (reader-fail state "unexpected end of input"))
  (let* ((start (reader-state-offset state))
         (character (reader-peek state))
         (datum
           (cond ((char= character #\()
                  (read-list state start))
                 ((char= character #\))
                  (reader-fail state "unexpected ')'"))
                 ((char= character #\")
                  (read-string-literal state start))
                 ((char= character #\')
                  (read-prefixed-form state start "quote"))
                 ((char= character #\`)
                  (read-prefixed-form state start "quasiquote"))
                 ((char= character #\,)
                  (read-prefixed-form state start "unquote"))
                 ((char= character #\.)
                  (if (and (< (1+ start) (length (reader-contents state)))
                           (digit-char-p (char (reader-contents state) (1+ start))))
                      (reader-fail state "floating-point literals must start with a digit")
                      (reader-fail state "'.' is not valid Verona syntax; use `unit`" start)))
                 ((char= character #\#)
                  (if (and (< (1+ start) (length (reader-contents state)))
                           (char= (char (reader-contents state) (1+ start)) #\\))
                      (read-character-literal state start)
                      (return-from read-form (read-feature-conditional state start))))
                 (t (read-atom state start)))))
    (values (make-instance 'syntax
                           :datum datum
                           :source (reader-state-source state)
                           :start (source-location-at (reader-state-source state) start)
                           :end (reader-location state))
            t)))

(defun read-source (source &key (features '()))
  "Read selected forms in SOURCE without interpreting any form head.

FEATURES controls #+FEATURE and #-FEATURE reader conditionals.  Feature
spelling is case-insensitive; ordinary Verona identifiers remain case-sensitive."
  (check-type source source)
  (let ((state (make-reader-state source (mapcar #'feature-name-string features)))
        (forms '()))
    (loop do (skip-layout state)
              (when (reader-at-end-p state)
                (return (nreverse forms)))
              (multiple-value-bind (form present-p) (read-form state)
                (when present-p
                  (push form forms))))))
