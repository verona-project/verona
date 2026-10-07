(in-package #:verona.compiler)

;;; Verona package locations are deliberately separate from native C-library
;;; lookup.  The latter remains an explicit build invocation concern (-L,
;;; --library, or pkg-config); these paths are reserved for Verona's own
;;; source and installed artifacts.

(define-condition verona-environment-error (compiler-driver-error) ())

(define-condition missing-verona-environment-variable (verona-environment-error)
  ((variable :initarg :variable :reader missing-verona-environment-variable-name)))

(define-condition invalid-verona-environment-directory (verona-environment-error)
  ((variable :initarg :variable :reader invalid-verona-environment-directory-variable)
   (value :initarg :value :reader invalid-verona-environment-directory-value)))

(defclass verona-environment ()
  ((source-directory :initarg :source-directory :reader verona-environment-source-directory)
   (library-directory :initarg :library-directory :reader verona-environment-library-directory))
  (:documentation "The canonical source and artifact roots for Verona packages."))

(defun environment-directory (variable getenv)
  "Read one required absolute Verona package directory from GETENV."
  (let ((value (funcall getenv variable)))
    (when (or (null value) (string= value ""))
      (error 'missing-verona-environment-variable
             :variable variable
             :message (format nil "~A must name an absolute directory" variable)))
    (let ((pathname (pathname value)))
      (unless (uiop:absolute-pathname-p pathname)
        (error 'invalid-verona-environment-directory
               :variable variable :value value
               :message (format nil "~A must be an absolute directory, not ~S" variable value)))
      (uiop:ensure-directory-pathname pathname))))

(defun resolve-verona-environment (&key (getenv #'uiop:getenv))
  "Resolve Verona package roots from VERONA_SOURCE_DIR and VERONA_LIBRARY_DIR.

Both variables are required and deliberately independent.  This is the
environment-override layer of the future user configuration: callers that
install or discover Verona packages use the same resulting paths."
  (make-instance 'verona-environment
                 :source-directory (environment-directory "VERONA_SOURCE_DIR" getenv)
                 :library-directory (environment-directory "VERONA_LIBRARY_DIR" getenv)))
