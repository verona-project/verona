(in-package #:verona/tests)

(in-suite :verona)

(defun native-test-path (type)
  (merge-pathnames (format nil "verona-native-~A.~A" (gensym "TEST-") type)
                   (uiop:temporary-directory)))

(defun compile-and-run-native (source)
  (let* ((executable (native-test-path "program"))
         (unit (compile-string (make-compiler) source))
         (program (compilation-unit-semantic-program unit)))
    (unwind-protect
         (progn
           (verona.backend.llvm:build-executable program executable)
           (nth-value 2 (uiop:run-program (list (namestring executable))
                                           :output :string :error-output :string
                                           :ignore-error-status t)))
      (when (probe-file executable)
        (delete-file executable)))))

(defun compile-and-run-native-with-arguments (source arguments)
  (let* ((executable (native-test-path "program"))
         (unit (compile-string (make-compiler) source))
         (program (compilation-unit-semantic-program unit)))
    (unwind-protect
         (progn
           (verona.backend.llvm:build-executable program executable)
           (nth-value 2 (uiop:run-program (cons (namestring executable) arguments)
                                           :output :string :error-output :string
                                           :ignore-error-status t)))
      (when (probe-file executable)
        (delete-file executable)))))

(defun compile-and-run-native-with-link-arguments (source arguments)
  (let* ((executable (native-test-path "program"))
         (unit (compile-string (make-compiler) source))
         (program (compilation-unit-semantic-program unit))
         (configuration
           (verona.backend.llvm:make-codegen-configuration
            :output-kind :executable
            :linker (verona.backend.llvm:make-linker-configuration :arguments arguments))))
    (unwind-protect
         (progn
           (verona.backend.llvm:build-executable program executable :configuration configuration)
           (nth-value 2 (uiop:run-program (list (namestring executable))
                                           :output :string :error-output :string
                                           :ignore-error-status t)))
      (when (probe-file executable)
        (delete-file executable)))))

(defun native-c-fixture (name)
  (merge-pathnames name (asdf:system-source-directory :verona)))

