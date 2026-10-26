(require :asdf)
(let ((root (merge-pathnames "../../../" (uiop:pathname-directory-pathname *load-truename*))))
  (asdf:load-asd (merge-pathnames "verona.asd" root))
  (asdf:load-system :verona/test-support))

(defpackage #:verona/project-tests (:use #:cl #:fiveam))
(in-package #:verona/project-tests)
(defparameter *executable*
  (namestring (truename (merge-pathnames "../../../build/project/verona-project"
                                        (uiop:pathname-directory-pathname *load-truename*)))))
(def-suite :project-libraries)
(in-suite :project-libraries)

(defun invoke (root &rest arguments)
  (uiop:run-program
   (append (list "env" "-u" "VERONA_SOURCE_DIR" "-u" "VERONA_LIBRARY_DIR")
           (when root (list (concatenate 'string "VERONA_SOURCE_DIR=" (namestring (pathname root)))))
           (list *executable*) arguments)
   :output :string :error-output :string :ignore-error-status t))

(defmacro with-directory ((root) &body body)
  `(let ((,root (merge-pathnames (format nil "verona libraries ~A/" (gensym))
                                 (uiop:temporary-directory))))
     (ensure-directories-exist ,root)
     (unwind-protect (progn ,@body)
       (uiop:delete-directory-tree ,root :validate t))))

(test inventory
  (with-directory (root)
    (dolist (name '("base-1.1.0/" "base-1.2.0/"))
      (ensure-directories-exist (merge-pathnames name root)))
    (with-open-file (stream (merge-pathnames "ordinary-file" root) :direction :output)
      (write-string "ignored" stream))
    (uiop:run-program (list "ln" "-s" "base-1.1.0" (namestring (merge-pathnames "alias-1.1.0" root))))
    (uiop:run-program (list "ln" "-s" "missing" (namestring (merge-pathnames "broken" root))))
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "alias: 1.1.0~%base: 1.1.0, 1.2.0~%") output)))))

(test grouped-versions
  (with-directory (root)
    ;; Deliberately unsorted, with names and release suffixes containing hyphens.
    (dolist (name '("my-library-2.0.0/" "base-2.0.0/" "base-extra-1.0.0/"
                    "base-1.0.0-rc.1/" "base-1.0.0+local/" "base-1.0.0/"
                    "my-library-1.0.0/" "unversioned/" "base/" "tool-2/"))
      (ensure-directories-exist (merge-pathnames name root)))
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "base: (unversioned), 1.0.0, 1.0.0+local, 1.0.0-rc.1, 2.0.0~%base-extra: 1.0.0~%my-library: 1.0.0, 2.0.0~%tool-2: (unversioned)~%unversioned: (unversioned)~%") output)))))

(defun write-manifest (root directory contents)
  (let ((path (merge-pathnames (concatenate 'string directory "/verona.build") root)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output :if-exists :supersede)
      (write-string contents stream))))

(test manifest-version-fallback
  (with-directory (root)
    (write-manifest root "base" (format nil "(static-library base (root base) (version \"1.1.0\"))~%"))
    (write-manifest root "my-library" "(shared-library my-library (version \"2.0.0-rc.1+local\") (root main))")
    (write-manifest root "base-1.2.0" "(static-library base (version \"9.9.9\") (root base))")
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "base: 1.1.0*, 1.2.0~%my-library: 2.0.0-rc.1+local*~%") output)))))

(test manifest-matching-target-and-comments
  (with-directory (root)
    (write-manifest root "base"
      (format nil "; (version \"9.9.9\")~%(executable base (version \"8.8.8\") (root main))~%(static-library other (version \"7.7.7\") (root other))~%(static-library base~% (root base)~% (module-path \"fake (version \\\"6.6.6\\\")\")~% ; (version \"5.5.5\")~% (version ; metadata~% \"1.3.0\"))"))
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "base: 1.3.0*~%") output)))))

(test missing-or-unusable-manifest-version
  (with-directory (root)
    (write-manifest root "absent" "(static-library absent (root main))")
    (write-manifest root "other" "(static-library different (version \"1.0.0\") (root main))")
    (write-manifest root "empty" "(static-library empty (version \"\") (root main))")
    (write-manifest root "invalid" "(static-library invalid (version 123) (root main))")
    (write-manifest root "unterminated" "(static-library unterminated (version \"1.0.0")
    (write-manifest root "nested" "(static-library nested (features (version \"9.9.9\")) (root main))")
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "absent: (unversioned)~%empty: (unversioned)~%invalid: (unversioned)~%nested: (unversioned)~%other: (unversioned)~%unterminated: (unversioned)~%") output)))))

(test repeated-version-shown-once
  (with-directory (root)
    (ensure-directories-exist (merge-pathnames "base-1.1.0/" root))
    (write-manifest root "base" "(static-library base (version \"1.1.0\") (root base))")
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" error))
      (is (string= (format nil "base: 1.1.0*~%") output)))))

(test empty-directory
  (with-directory (root)
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (= 0 status)) (is (string= "" output)) (is (string= "" error)))))

(test invalid-roots
  (dolist (root '(nil "" "relative" "/nonexistent-verona-source-directory"))
    (multiple-value-bind (output error status) (invoke root "libraries")
      (is (/= 0 status)) (is (string= "" output))
      (is (search "VERONA_SOURCE_DIR" error))))
  (uiop:with-temporary-file (:pathname file)
    (multiple-value-bind (output error status) (invoke file "libraries")
      (is (/= 0 status)) (is (string= "" output))
      (is (search "VERONA_SOURCE_DIR" error)))))

(test extra-arguments
  (multiple-value-bind (output error status) (invoke nil "libraries" "extra")
    (is (/= 0 status)) (is (string= "" output)) (is (search "extra arguments" error))))

(test help
  (multiple-value-bind (output error status) (invoke nil "--help")
    (is (= 0 status)) (is (string= "" error)) (is (search "libraries" output))))

(test new-project-still-works
  (with-directory (root)
    (let ((destination (merge-pathnames "example/" root)))
      (multiple-value-bind (output error status)
          (uiop:run-program (list *executable* "new" "example") :directory root
                            :output :string :error-output :string :ignore-error-status t)
        (is (= 0 status)) (is (string= "" error)) (is (search "Created example" output))
        (is (not (null (probe-file (merge-pathnames "verona.build" destination)))))))))

(unless (run! :project-libraries) (uiop:quit 1))
