(in-package #:verona/tests)

(in-suite :verona)

(test syntax-with-datum-preserves-the-reader-source-span
  (let* ((source (make-source "syntax.vrn" "original"))
         (original (first (read-source source)))
         (replacement (syntax-with-datum original (make-verona-name "replacement"))))
    (is (eq source (syntax-source replacement)))
    (is (eq (syntax-start original) (syntax-start replacement)))
    (is (eq (syntax-end original) (syntax-end replacement)))
    (is (string= "replacement" (verona-name-value (syntax-datum replacement))))))

(test module-and-qualified-names-preserve-their-structural-identity
  (let* ((left (verona:make-module-name (make-verona-name "math")
                                        (make-verona-name "integer")))
         (same (verona:make-module-name (make-verona-name "math")
                                        (make-verona-name "integer")))
         (different-case (verona:make-module-name (make-verona-name "Math")
                                                  (make-verona-name "integer")))
         (qualified (verona:make-qualified-name left (make-verona-name "add"))))
    (is (verona:module-name= left same))
    (is (not (verona:module-name= left different-case)))
    (is (string= "math.integer" (module-name-string left)))
    (is (string= "math.integer:add" (verona:qualified-name-string qualified)))))
