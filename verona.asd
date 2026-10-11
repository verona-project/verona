(asdf:defsystem #:verona
  :description "The Verona compiler front-end foundation"
  :version "0.1.0"
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
  :version "0.1.0"
  :depends-on (#:verona/backend/llvm)
  :serial t
  :components ((:file "src/driver/package")
               (:file "src/driver/driver")
               (:file "src/driver/environment")
               (:file "src/driver/build")
               (:file "src/driver/cli")))

(asdf:defsystem #:verona/test-support
  :depends-on (#:verona #:fiveam)
  :serial t
  :components ((:file "tests/package")
               (:file "tests/support")))

(asdf:defsystem #:verona/frontend-tests
  :description "FiveAM tests for the Verona front end"
  :depends-on (#:verona/test-support)
  :serial t
  :components ((:file "tests/ffi-semantics")
               (:file "tests/reader")
               (:file "tests/compilation")
               (:file "tests/evaluator")
               (:file "tests/declarations")
               (:file "tests/base-integration")
               (:file "tests/macro-expansion")
               (:file "tests/resolver-types")
               (:file "tests/resolver-control-flow")
               (:file "tests/resolver-data")
               (:file "tests/resolver-generics")
               (:file "tests/hardening")
               (:file "tests/examples")
               (:file "tests/modules")))

;; Retain the original system name for callers that use the front-end suite.
(asdf:defsystem #:verona/tests
  :depends-on (#:verona/frontend-tests))

(asdf:defsystem #:verona/llvm-tests
  :description "FiveAM integration tests for the Verona LLVM backend"
  :depends-on (#:verona/test-support #:verona/backend/llvm)
  :serial t
  :components ((:file "tests/llvm-support")
               (:file "tests/llvm-ir")
               (:file "tests/llvm-abi")
               (:file "tests/c-header")
               (:file "tests/llvm-native")
               (:file "tests/examples-llvm")))

(asdf:defsystem #:verona/compiler-tests
  :description "FiveAM tests for the Verona compiler driver"
  :depends-on (#:verona/test-support #:verona/compiler)
  :serial t
  :components ((:file "tests/driver-target")
               (:file "tests/driver-artifacts")
               (:file "tests/cli")
               (:file "tests/build-parser")
               (:file "tests/build-integration")))
