(in-package #:verona.backend.llvm)

(defun backend-fail (control &rest arguments)
  (error 'llvm-backend-error :message (apply #'format nil control arguments)))

(defclass llvm-backend ()
  ((context :initarg :context :reader llvm-backend-context)
   (module :initarg :module :reader llvm-backend-module)
   (builder :initarg :builder :reader llvm-backend-builder)
   (target-machine :initarg :target-machine :reader llvm-backend-target-machine)
   (target-configuration :initarg :target-configuration
                         :reader llvm-backend-target-configuration)
   (target-triple :initarg :target-triple :reader llvm-backend-target-triple)
   (data-layout :initarg :data-layout :reader llvm-backend-data-layout)
   (target-data :initarg :target-data :reader llvm-backend-target-data)
   (pointer-width :initarg :pointer-width :reader llvm-backend-pointer-width)
   (type-context :initarg :type-context :accessor backend-type-context)
   ;; Semantic identities are keys.  LLVM values/types never escape into the
   ;; Verona semantic objects themselves.
   (bindings :initform (make-hash-table :test #'eq)
             :reader llvm-backend-bindings)
   (types :initform (make-hash-table :test #'eq)
          :reader llvm-backend-types)
   ;; C ABI types are intentionally separate from internal lowering.  Today
   ;; most layouts coincide, but this cache makes the boundary explicit and
   ;; prevents later internal representation changes from leaking to C.
   (c-abi-types :initform (make-hash-table :test #'eq)
                :reader llvm-backend-c-abi-types)
   (string-literal-counter :initform 0 :accessor llvm-backend-string-literal-counter)
   (trap-function :initform nil :accessor llvm-backend-trap-function)))

(defun make-llvm-backend (&key (module-name "verona")
                               (target-configuration (make-target-configuration))
                               (optimization-level :none))
  "Create a backend for an explicit LLVM target description.

DATA-LAYOUT is the authority for target representation.  In particular, the
pointer width is queried from LLVM target data; it is never inferred from the
Common Lisp implementation or the compiler host."
  (check-type target-configuration target-configuration)
  (let* ((context (llvm:global-context))
         (module (llvm:make-module module-name context))
         (builder (llvm:make-builder context))
         (target-machine (create-target-machine target-configuration optimization-level)))
    (setf (llvm:target module) (target-configuration-triple target-configuration))
    (multiple-value-bind (target-data data-layout)
        (attach-target-machine-layout module target-machine)
    (let ((pointer-width (* 8 (llvm:pointer-size target-data))))
      (unless (member pointer-width '(32 64))
        (backend-fail "LLVM target pointer width ~D is unsupported" pointer-width))
      (make-instance 'llvm-backend :context context :module module :builder builder
                      :target-machine target-machine
                      :target-configuration target-configuration
                      :target-triple (target-configuration-triple target-configuration)
                      :data-layout data-layout :target-data target-data
                      :pointer-width pointer-width)))))

(defun backend-binding (backend binding)
  (multiple-value-bind (value presentp)
      (gethash binding (llvm-backend-bindings backend))
    (if presentp value
        (backend-fail "no LLVM value registered for semantic binding ~S" binding))))

(defun (setf backend-binding) (value backend binding)
  (setf (gethash binding (llvm-backend-bindings backend)) value))

(defun llvm-mangle-text (text)
  "Encode TEXT injectively without relying on Lisp symbol/package printing."
  (with-output-to-string (stream)
    (loop for character across text
          do (format stream "~6,'0X" (char-code character)))))

(defun llvm-name (binding)
  "Mangle a semantic name so no source spelling shares generated LLVM symbols.

The spelling is based only on Verona module/declaration identity.  It is
therefore independent of Common Lisp packages, object identity, and table
iteration order."
  (with-output-to-string (stream)
    (write-string "__verona_" stream)
    (let* ((source (cond ((typep binding 'verona:declaration) binding)
                         ((typep binding 'verona:semantic-declaration)
                          (semantic-source-binding binding))))
           (module (and source (verona:declaration-module source))))
      ;; String compilation retains its historic spelling for compatibility;
      ;; every filename-derived module contributes its semantic identity.
      (when (and module (verona:module-identity-explicit-p module))
        (write-string (llvm-mangle-text
                       (verona:module-name-string (verona:module-name module))) stream)
        (write-string "_" stream)))
    (write-string (llvm-mangle-text
                   (verona:verona-name-value (verona:semantic-binding-name binding))) stream)))

(defun llvm-type-mangle (type)
  "Stable, collision-resistant identity spelling for generic implementations." 
  (cond ((typep type 'verona:never-type) "never")
        ((typep type 'verona:unit-type) "unit")
        ((typep type 'verona:void-type) "void")
        ((typep type 'verona:boolean-type) "bool")
        ((typep type 'verona:char-type) "char")
        ((typep type 'verona:integer-type)
         (format nil "~:[u~;i~]~D" (verona:integer-type-signed type)
                 (verona:integer-type-width type)))
        ((typep type 'verona:float-type)
         (format nil "f~D" (verona:float-type-width type)))
        ((typep type 'verona:pointer-type)
         (format nil "p_~A" (llvm-type-mangle (verona:pointer-type-pointee type))))
        ((typep type 'verona:array-type)
         (format nil "a~D_~A" (verona:array-type-length type)
                 (llvm-type-mangle (verona:array-type-element-type type))))
        ((typep type 'verona:defined-type)
         (llvm-name (verona:defined-type-declaration type)))
        ;; Function types cannot currently be generic arguments, but retain a
        ;; deterministic spelling if the type system admits them later.
        ((typep type 'verona:function-type)
         (format nil "fn_~{~A~^_~}_to_~A"
                 (mapcar #'llvm-type-mangle (verona:function-type-parameters type))
                 (llvm-type-mangle (verona:function-type-result type))))
        (t (error 'verona:compiler-bug
                  :message (format nil "cannot mangle unresolved Verona type ~S" type)))))

(defun semantic-source-binding (semantic-declaration)
  (verona:semantic-declaration-source-declaration semantic-declaration))
