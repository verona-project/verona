(defpackage #:verona.compiler
  (:use #:cl)
  (:shadow #:compile-file)
  (:import-from #:verona
                #:make-compiler #:compiler-search-paths
                #:compilation-unit-semantic-program #:program-target)
  (:import-from #:verona.backend.llvm
                #:make-target-configuration #:native-target-triple
                #:target-configuration-triple #:target-configuration-cpu
                #:target-configuration-features #:generate-llvm
                #:verify-llvm-module #:emit-object #:add-platform-entry-wrapper
                #:hide-verona-symbols
                #:generate-c-header
                #:llvm-backend-pointer-width #:llvm-backend-data-layout)
  (:export
   #:compiler-driver #:make-compiler-driver #:compiler-driver-search-paths
   #:compiler-driver-target #:compiler-driver-optimization-level
   #:compiler-driver-toolchain
   #:compilation-target #:resolve-compilation-target
   #:compilation-target-triple #:compilation-target-cpu
   #:compilation-target-features #:compilation-target-data-layout
   #:compilation-target-reader-features
   #:compilation-target-pointer-width #:compilation-target-object-format
   #:compilation-target-platform
   #:artifact #:artifact-kind #:artifact-path #:artifact-target
   #:object-artifact #:executable-artifact #:static-library-artifact
   #:shared-library-artifact
   #:link-options #:make-link-options #:link-options-libraries
   #:link-options-library-search-paths #:link-options-frameworks
   #:toolchain #:native-toolchain #:make-native-toolchain
   #:toolchain-emit-object #:toolchain-link-executable
   #:toolchain-archive-static-library #:toolchain-link-shared-library
   #:compile-root #:compile-file #:default-output-path
   #:verona-version
   #:compiler-driver-error #:unsupported-artifact #:unsupported-target
   #:llvm-verification-failure #:object-emission-failure #:invalid-entry-point
   #:tool-failure #:tool-failure-executable #:tool-failure-arguments
   #:tool-failure-exit-status #:tool-failure-stdout #:tool-failure-stderr
   #:toolchain-failure #:toolchain-failure-tool #:toolchain-failure-arguments
   #:toolchain-failure-exit-status #:toolchain-failure-stdout
   #:toolchain-failure-stderr #:linker-failure #:archiver-failure
   #:shared-library-link-failure
   ;; Verona package installation and discovery environment.
   #:verona-environment #:resolve-verona-environment
   #:verona-environment-source-directory #:verona-environment-library-directory
   #:verona-environment-error #:missing-verona-environment-variable
   #:missing-verona-environment-variable-name
   #:invalid-verona-environment-directory
   #:invalid-verona-environment-directory-variable
   #:invalid-verona-environment-directory-value
   ;; Declarative build configuration.
   #:build-name #:make-build-name #:build-name-p #:build-name-value #:build-name=
   #:build-file #:build-file-source #:build-file-targets
   #:build-target #:build-target-name #:build-target-root-module
   #:build-target-module-paths #:build-target-compilation-target
   #:build-target-optimization #:build-target-version #:build-target-reader-features
   #:build-target-link-options
   #:executable-target #:static-library-target #:shared-library-target
   #:build-invocation #:make-build-invocation #:build-invocation-target-name
   #:build-invocation-output-directory #:build-invocation-reader-features
   #:parse-build-file #:parse-build-source #:find-build-target #:locate-build-file
   #:execute-build #:build-target-artifact-kind
   #:build-error #:build-error-message #:build-error-syntax
   #:build-parse-error #:duplicate-build-target-error #:unknown-build-option-error
   #:unsupported-build-option-error
   #:main))
