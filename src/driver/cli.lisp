(in-package #:verona.compiler)

(defun cli-fail (control &rest arguments)
  (error 'compiler-driver-error :message (apply #'format nil control arguments)))

(defun parse-artifact-kind (value)
  (cond ((string= value "object") :object)
        ((string= value "executable") :executable)
        ((string= value "static-library") :static-library)
        ((string= value "shared-library") :shared-library)
        (t (cli-fail "unknown artifact kind ~A" value))))

(defun run-cli (&optional (arguments (uiop:command-line-arguments))
                &key (resolve-target-function #'resolve-compilation-target)
                  (make-driver-function #'make-compiler-driver)
                  (compile-function #'compile-root)
                  (locate-build-function #'locate-build-file)
                  (parse-build-function #'parse-build-file)
                  (build-function #'execute-build))
  "Run a CLI invocation without rendering errors or terminating the process.

The injectable boundary functions make argument parsing independently testable
while MAIN remains the process-oriented public entry point."
  (let ((command (pop arguments)))
        (when (and command (or (string= command "--version") (string= command "-V")))
          (unless (null arguments)
            (cli-fail "--version does not accept arguments"))
          (format t "~A~%" (verona-version))
          (return-from run-cli (verona-version)))
        (when (and command (string= command "build"))
          (let ((target (pop arguments)) (output-directory (pop arguments))
                (reader-features '()))
            (unless target (cli-fail "usage: verona build TARGET OUTPUT-DIRECTORY [--feature NAME]"))
            (unless output-directory (cli-fail "verona build requires an output directory"))
            (loop while arguments
                  for option = (pop arguments)
                  do (cond ((string= option "--feature")
                           (let ((feature (or (pop arguments)
                                              (cli-fail "--feature requires a feature name"))))
                             (when (string= feature "")
                               (cli-fail "--feature requires a non-empty feature name"))
                             (push feature reader-features)))
                          (t (cli-fail "usage: verona build TARGET OUTPUT-DIRECTORY [--feature NAME]"))))
            (let ((artifact (funcall build-function
                                      (funcall parse-build-function
                                               (funcall locate-build-function))
                                           (make-build-invocation target output-directory
                                                                  :reader-features
                                                                  (nreverse reader-features)))))
              (format t "~A~%" (artifact-path artifact))
              (return-from run-cli artifact))))
        (unless (and command (string= command "compile"))
          (cli-fail "usage: verona compile SOURCE [-o OUTPUT] [--emit KIND] [--feature NAME]~%       verona build TARGET OUTPUT-DIRECTORY [--feature NAME]"))
        (let ((source (pop arguments)) (output nil) (kind :executable)
              (triple nil) (cpu "generic") (features "") (libraries '())
              (reader-features '()) (paths '()) (frameworks '()))
          (unless source (cli-fail "compile requires a root Verona source file"))
          (loop while arguments
                for option = (pop arguments)
                do (cond ((or (string= option "-o") (string= option "--output"))
                          (setf output (or (pop arguments) (cli-fail "~A requires a path" option))))
                         ((string= option "--emit")
                          (setf kind (parse-artifact-kind
                                      (or (pop arguments) (cli-fail "--emit requires a kind")))))
                         ((string= option "--target")
                          (setf triple (or (pop arguments) (cli-fail "--target requires a triple"))))
                         ((string= option "--cpu")
                          (setf cpu (or (pop arguments) (cli-fail "--cpu requires a value"))))
                         ((string= option "--features")
                          (setf features (or (pop arguments) (cli-fail "--features requires a value"))))
                         ((string= option "--feature")
                          (let ((feature (or (pop arguments)
                                             (cli-fail "--feature requires a feature name"))))
                            (when (string= feature "")
                              (cli-fail "--feature requires a non-empty feature name"))
                            (push feature reader-features)))
                         ((or (string= option "-l") (string= option "--library"))
                          (push (or (pop arguments) (cli-fail "~A requires a library" option)) libraries))
                         ((or (string= option "-L") (string= option "--library-path"))
                          (push (or (pop arguments) (cli-fail "~A requires a path" option)) paths))
                         ((string= option "--framework")
                          (push (or (pop arguments) (cli-fail "--framework requires a name")) frameworks))
                         (t (cli-fail "unknown option ~A" option))))
          (let* ((target (funcall resolve-target-function
                                  :triple triple :cpu cpu :features features
                                  :reader-features (nreverse reader-features)))
                 (driver (funcall make-driver-function :target target))
                 (artifact (funcall compile-function driver source :artifact-kind kind :output output
                                    :link-options (make-link-options :libraries (nreverse libraries)
                                                                     :library-search-paths (nreverse paths)
                                                                     :frameworks (nreverse frameworks)))))
            (format t "~A~%" (artifact-path artifact))
            artifact))))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  "Command line entry point for `verona compile` and `verona build`."
  (handler-case
      (run-cli arguments)
    (error (condition)
      (let ((diagnostic (and (typep condition 'verona:user-compilation-error)
                             (verona:diagnostic-for-condition condition))))
        (if diagnostic
            (verona:render-diagnostic diagnostic *error-output*)
            (format *error-output* "verona: ~A~%" condition)))
      (uiop:quit 1))))
