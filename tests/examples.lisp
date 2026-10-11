(in-package #:verona/tests)

(in-suite :verona)

(defparameter +current-example-files+
  '("01-arithmetic.vrn"
    "02-let-bindings.vrn"
    "03-match.vrn"
    "04-products.vrn"
    "05-sum-types.vrn"
    "06-generics.vrn"
    "07-polymorphism-protocols.vrn"))

(defun assert-example-compiles (name)
  (let ((unit (compile-file (make-compiler) (current-example-pathname name))))
    (is (typep unit 'compilation-unit) name)))

(test-cases compiles-current-examples
  (arithmetic (assert-example-compiles "01-arithmetic.vrn"))
  (let-bindings (assert-example-compiles "02-let-bindings.vrn"))
  (match (assert-example-compiles "03-match.vrn"))
  (products (assert-example-compiles "04-products.vrn"))
  (sum-types (assert-example-compiles "05-sum-types.vrn"))
  (generics (assert-example-compiles "06-generics.vrn"))
  (polymorphism-protocols (assert-example-compiles "07-polymorphism-protocols.vrn")))
