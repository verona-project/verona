(require :asdf)
(let* ((script (or *load-truename* *compile-file-truename*))
       (root (merge-pathnames "../../../" (uiop:pathname-directory-pathname script))))
  (asdf:load-asd (merge-pathnames "verona.asd" root))
  (asdf:load-system :verona/test-support))

(defpackage #:verona/formatter-tests
  (:use #:cl #:fiveam))
(in-package #:verona/formatter-tests)

(defparameter *root*
  (truename (merge-pathnames "../../../" (uiop:pathname-directory-pathname *load-truename*))))
(defparameter *formatter*
  (let ((arguments (uiop:command-line-arguments)))
    (unless (= (length arguments) 1)
      (error "usage: run-integration.lisp /absolute/path/to/verona-fmt"))
    (namestring (truename (first arguments)))))
(def-suite :formatter)
(in-suite :formatter)

(defun invoke (input &rest arguments)
  (uiop:run-program (cons *formatter* arguments)
                    :input (make-string-input-stream input)
                    :output :string :error-output :string :ignore-error-status t))

(test stdin-default
  (multiple-value-bind (output error status) (invoke " ( a  b ) ")
    (is (= 0 status)) (is (string= (format nil "(a b)~%") output)) (is (string= "" error))))
(test stdin-explicit
  (multiple-value-bind (output error status) (invoke "(a)" "-")
    (is (= 0 status)) (is (string= (format nil "(a)~%") output)) (is (string= "" error))))
(test empty-stdin
  (multiple-value-bind (output error status) (invoke "")
    (is (= 0 status)) (is (string= "" output)) (is (string= "" error))))
(test help
  (multiple-value-bind (output error status) (invoke "(" "--help")
    (is (= 0 status)) (is (search "usage: verona-fmt" output)) (is (string= "" error))))
(test check-formatted
  (multiple-value-bind (output error status) (invoke (format nil "(a)~%") "--check")
    (is (= 0 status)) (is (string= "" output)) (is (string= "" error))))
(test check-unformatted
  (multiple-value-bind (output error status) (invoke " (a)" "--check")
    (is (= 1 status)) (is (string= "" output)) (is (search "formatting differs" error))))
(test syntax-error-has-no-partial-output
  (multiple-value-bind (output error status) (invoke (format nil "(a)~%("))
    (is (= 2 status)) (is (string= "" output)) (is (search "-:2:1:" error))
    (is (search "unterminated list" error))))
(test check-syntax-error-is-not-a-formatting-difference
  (multiple-value-bind (output error status) (invoke "(" "--check")
    (is (= 2 status)) (is (string= "" output)) (is (search "unterminated list" error))))
(test width-changes-layout
  (multiple-value-bind (output error status)
      (invoke "(call abcdefghij klmnopqrst uvwxyz)" "--width" "24")
    (is (= 0 status)) (is (string= "" error))
    (is (string= (format nil "(call~%  abcdefghij~%  klmnopqrst~%  uvwxyz)~%") output))))

(defmacro option-cases (&rest cases)
  `(progn
     ,@(loop for (name . arguments) in cases collect
       `(test ,name
          (multiple-value-bind (output error status) (invoke "(a)" ,@arguments)
            (is (= 2 status)) (is (string= "" output)) (is (search "usage:" error)))))))
(option-cases
  (unknown-option "--unknown")
  (write-is-not-silently-accepted "--write")
  (missing-width "--width")
  (width-too-small "--width" "19")
  (width-too-large "--width" "241")
  (width-negative "--width" "-20")
  (width-nonnumeric "--width" "abc")
  (width-overflow "--width" "18446744073709551616")
  (multiple-inputs "one.vrn" "two.vrn"))

(test end-of-options
  (multiple-value-bind (output error status) (invoke "" "--" "--help")
    (is (= 2 status)) (is (string= "" output)) (is (search "cannot open input" error))
    (is (not (search "usage:" error)))))
(test file-input-never-modifies-source
  (uiop:with-temporary-file (:pathname path :stream stream :prefix "verona-fmt-input-")
    (write-string " ( a b ) " stream) (finish-output stream)
    (multiple-value-bind (output error status) (invoke "" (namestring path))
      (is (= 0 status)) (is (string= "" error)) (is (string= (format nil "(a b)~%") output))
      (is (string= " ( a b ) " (uiop:read-file-string path))))))
(test missing-file
  (uiop:with-temporary-file (:pathname path :stream stream :prefix "verona-fmt-missing-")
    (close stream) (delete-file path)
    (multiple-value-bind (output error status) (invoke "" (namestring path))
      (is (= 2 status)) (is (string= "" output)) (is (search "cannot open input" error)))))
(test directory-input
  (multiple-value-bind (output error status) (invoke "" (namestring *root*))
    (is (= 2 status)) (is (string= "" output)) (is (search "cannot read input" error))))
(test invalid-utf8-file
  (uiop:with-temporary-file (:pathname path :stream stream :prefix "verona-fmt-invalid-"
                            :element-type '(unsigned-byte 8))
    (write-sequence #(192 128) stream) (finish-output stream)
    (multiple-value-bind (output error status) (invoke "" (namestring path))
      (is (= 2 status)) (is (string= "" output)) (is (search "UTF-8" error)))))
(test crlf-location
  (multiple-value-bind (output error status) (invoke (format nil "(a)~C~C)" #\Return #\Newline))
    (is (= 2 status)) (is (string= "" output)) (is (search "-:2:1:" error))))
(test many-top-level-forms-across-read-boundaries
  (let* ((count 4096)
         (input (format nil "~{~A~}" (make-list count :initial-element "(a)")))
         (expected (format nil "~{~A~^~%~}" (make-list count :initial-element (format nil "(a)~%")))))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error)) (is (string= expected output)))))
(test nesting-limit
  (let ((input (concatenate 'string (make-string 257 :initial-element #\() "a"
                                   (make-string 257 :initial-element #\)))))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 2 status)) (is (string= "" output)) (is (search "nesting limit" error)))))
(test quote-nesting-limit
  (multiple-value-bind (output error status)
      (invoke (concatenate 'string (make-string 257 :initial-element #\') "a"))
    (is (= 2 status)) (is (string= "" output)) (is (search "nesting limit" error))))
(test nesting-at-limit
  (let ((input (concatenate 'string (make-string 256 :initial-element #\() "a"
                                   (make-string 256 :initial-element #\)))))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error))
      (multiple-value-bind (second ignored second-status) (invoke output)
        (declare (ignore ignored)) (is (= 0 second-status)) (is (string= output second))))))
(test input-size-limit
  ;; A sparse temporary file tests the boundary without a giant fixture string.
  (uiop:with-temporary-file (:pathname path :stream stream :prefix "verona-fmt-large-"
                            :element-type '(unsigned-byte 8))
    (file-position stream 16777216) (write-byte 32 stream) (finish-output stream)
    (multiple-value-bind (output error status) (invoke "" (namestring path))
      (is (= 2 status)) (is (string= "" output)) (is (search "input limit" error)))))

(test large-whitespace-input
  (multiple-value-bind (output error status) (invoke (make-string 1000000 :initial-element #\Space))
    (is (= 0 status)) (is (string= "" output)) (is (string= "" error))))
(test long-atom
  (let ((input (make-string 100000 :initial-element #\a)))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error)) (is (string= (format nil "~A~%" input) output))
      (multiple-value-bind (checked ignored checked-status) (invoke output "--check")
        (declare (ignore ignored)) (is (= 0 checked-status)) (is (string= "" checked))))))
(test long-comment
  (let ((input (concatenate 'string "; " (make-string 100000 :initial-element #\a))))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error)) (is (string= (format nil "~A~%" input) output)))))
(test long-string-literal
  (let ((input (concatenate 'string "\"" (make-string 100000 :initial-element #\a) "\"")))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error)) (is (string= (format nil "~A~%" input) output)))))
(test very-wide-list
  (let* ((count 50000)
         (input (concatenate 'string "(array-of" (format nil "~{~A~}" (make-list count :initial-element " 0")) ")"))
         (expected (concatenate 'string "(array-of"
           (format nil "~{~A~}" (make-list count :initial-element (format nil "~%  0"))) (format nil ")~%"))))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error)) (is (string= expected output)))))
(test many-comments-after-reader-prefix
  (let* ((comments (format nil "~{~A~}" (make-list 20000 :initial-element (format nil "; c~%"))))
         (input (concatenate 'string "' " comments "a")))
    (multiple-value-bind (output error status) (invoke input)
      (is (= 0 status)) (is (string= "" error))
      (multiple-value-bind (second ignored second-status) (invoke output)
        (declare (ignore ignored)) (is (= 0 second-status)) (is (string= output second))))))

(test argument-count-limit
  (multiple-value-bind (output error status)
      (apply #'invoke "(a)" (make-list 128 :initial-element "--check"))
    (is (= 2 status)) (is (string= "" output)) (is (search "too many arguments" error))))
(test argument-count-at-limit
  (multiple-value-bind (output error status)
      (apply #'invoke (format nil "(a)~%") (make-list 127 :initial-element "--check"))
    (is (= 0 status)) (is (string= "" output)) (is (string= "" error))))

(defun canonical (value)
  (typecase value
    (verona:syntax (canonical (verona:syntax-datum value)))
    (verona:verona-list (mapcar #'canonical (verona:verona-list-elements value)))
    (verona:verona-name (list :name (verona:verona-name-value value)))
    (verona:qualified-name (list :qualified (verona:qualified-name-string value)))
    (verona:unit-literal (list :unit))
    (verona:verona-boolean-literal (list :bool (verona:verona-boolean-literal-value value)))
    (character (list :character (char-code value)))
    (string (list :string value))
    (number (list :number value))
    (t (error "unexpected reader value ~S" value))))
(defun read-canonical (text features)
  (mapcar #'canonical (verona:read-source (verona:make-source "formatter-corpus.vrn" text)
                                       :features features)))
(defun verify-corpus (path)
  (let ((input (uiop:read-file-string path)))
    (multiple-value-bind (output error status) (invoke "" (namestring path))
      (is (= 0 status) "formatter rejected ~A: ~A" path error)
      (is (string= "" error))
      (when (zerop status)
        (dolist (features '(() ("darwin" "pointer_64") ("linux" "pointer_64")))
          (is (equal (read-canonical input features) (read-canonical output features))
              "reader meaning changed for ~A, features ~S" path features))
        (multiple-value-bind (second ignored second-status) (invoke output)
          (declare (ignore ignored))
          (is (= 0 second-status)) (is (string= output second)))
        (multiple-value-bind (checked ignored checked-status) (invoke output "--check")
          (declare (ignore ignored))
          (is (= 0 checked-status)) (is (string= "" checked)))))))
(defun source-files (directory)
  (append (directory (merge-pathnames "*.vrn" directory))
          (let ((build (merge-pathnames "verona.build" directory)))
            (when (probe-file build) (list build)))
          (mapcan #'source-files (uiop:subdirectories directory))))
;; Each corpus file is a separate named test, with the compiler reader as oracle.
(dolist (path (source-files (merge-pathnames "projects/" *root*)))
  (let ((name (intern (string-upcase (format nil "CORPUS/~A" (enough-namestring path *root*))))))
    (eval `(test ,name (verify-corpus ,(namestring path))))))
(unless (run! :formatter) (uiop:quit 1))
