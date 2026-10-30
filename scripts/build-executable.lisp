(require :asdf)

(defparameter *output-path*
  (let ((arguments (uiop:command-line-arguments)))
    (unless (= (length arguments) 1)
      (error "usage: build-executable.lisp OUTPUT-PATH"))
    (first arguments)))

(let* ((script (or *load-truename* *compile-file-truename*))
       (root (merge-pathnames "../" (uiop:pathname-directory-pathname script)))
       (cl-llvm-root (uiop:getenv "VERONA_CL_LLVM")))
  (unless cl-llvm-root
    (error "VERONA_CL_LLVM is required; build the executable from the Verona development shell"))
  (asdf:load-asd (merge-pathnames "llvm.asd" (uiop:ensure-directory-pathname cl-llvm-root)))
  (asdf:load-asd (merge-pathnames "verona.asd" root))
  (asdf:load-system :verona/compiler))

(defun verona-image-main ()
  (verona.compiler:main))

;; Pass flags such as --version to Verona rather than the SBCL runtime.
(sb-ext:save-lisp-and-die *output-path* :executable t :save-runtime-options t :toplevel #'verona-image-main)
