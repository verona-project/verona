(in-package #:verona/tests)

(def-suite :verona)
(in-suite :verona)

(defmacro test-cases (name &body cases)
  "Define one FiveAM test per independently executable CASE.

Each case has the shape `(case-name form...)`; generated names retain NAME as
their prefix so failures stay easy to locate."
  `(progn
     ,@(loop for (case-name . forms) in cases
             for test-name = (intern (format nil "~A/~A" name case-name) *package*)
             collect `(test ,test-name ,@forms))))

(defun run-tests ()
  (run! :verona))

(defun current-example-pathname (name)
  (merge-pathnames (format nil "examples/~A" name)
                   (asdf:system-source-directory :verona)))
