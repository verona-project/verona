(in-package #:verona/tests)

(in-suite :verona)

(defun assert-example-executes (name)
  (is (= 42
         (compile-and-run-native
          (uiop:read-file-string (current-example-pathname name))))
      name))

(test-cases executes-current-examples
  (arithmetic (assert-example-executes "01-arithmetic.vrn"))
  (let-bindings (assert-example-executes "02-let-bindings.vrn"))
  (match (assert-example-executes "03-match.vrn"))
  (products (assert-example-executes "04-products.vrn"))
  (sum-types (assert-example-executes "05-sum-types.vrn"))
  (generics (assert-example-executes "06-generics.vrn"))
  (polymorphism-protocols (assert-example-executes "07-polymorphism-protocols.vrn")))
