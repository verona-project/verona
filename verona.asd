(asdf:defsystem #:verona
  :description "The Verona compiler front-end foundation"
  :serial t
  :components ((:file "src/package")
               (:file "src/source")
               (:file "src/syntax")
               (:file "src/reader")
               (:file "src/evaluator")
               (:file "src/semantic")
               (:file "src/compiler")
               (:file "src/resolver")))

(asdf:defsystem #:verona/backend/llvm
  :description "LLVM lowering for LLVM-ready Verona semantic programs"
  :depends-on (#:verona #:llvm)
  :serial t
  :components ((:file "src/backend/llvm/package")
               (:file "src/backend/llvm/target")
               (:file "src/backend/llvm/backend")
               (:file "src/backend/llvm/types")
               (:file "src/backend/llvm/primitives")
               (:file "src/backend/llvm/expressions")
               (:file "src/backend/llvm/functions")
               (:file "src/backend/llvm/module")
               (:file "src/backend/llvm/c-header")
               (:file "src/backend/llvm/codegen")))

(asdf:defsystem #:verona/compiler
  :description "Verona compiler driver and native artifact toolchain"
  :depends-on (#:verona/backend/llvm)
  :serial t
  :components ((:file "src/driver/package")
               (:file "src/driver/driver")
               (:file "src/driver/environment")
               (:file "src/driver/build")
               (:file "src/driver/cli")))

(asdf:defsystem #:verona/tests
  :depends-on (#:verona #:fiveam)
  :serial t
  :components ((:file "tests/foundation")
               (:file "tests/hardening")
               (:file "tests/examples")
               (:file "tests/modules")))

(asdf:defsystem #:verona/llvm-tests
  :description "FiveAM integration tests for the Verona LLVM backend"
  :depends-on (#:verona/tests #:verona/backend/llvm)
  :serial t
  :components ((:file "tests/llvm-backend")
               (:file "tests/examples-llvm")))

(asdf:defsystem #:verona/compiler-tests
  :description "FiveAM tests for the Verona compiler driver"
  :depends-on (#:verona/llvm-tests #:verona/compiler)
  :serial t
  :components ((:file "tests/compiler-driver")
               (:file "tests/build")))
