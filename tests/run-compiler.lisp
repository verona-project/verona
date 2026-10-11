(require :asdf)

(let* ((script (or *load-truename* *compile-file-truename*))
       (root (merge-pathnames "../" (uiop:pathname-directory-pathname script)))
       (cl-llvm-root (uiop:getenv "VERONA_CL_LLVM")))
  ;; The compiler driver uses the LLVM backend and therefore shares the
  ;; pinned Nix dependency setup with the LLVM integration suite.
  (unless cl-llvm-root
    (error "VERONA_CL_LLVM is set by nix develop and is required for compiler tests"))
  (asdf:load-asd (merge-pathnames "llvm.asd"
                                 (uiop:ensure-directory-pathname cl-llvm-root)))
  (asdf:load-asd (merge-pathnames "verona.asd" root))
  (asdf:load-system :verona/compiler-tests)
  (unless (uiop:symbol-call :verona/tests :run-tests)
    (uiop:quit 1)))
