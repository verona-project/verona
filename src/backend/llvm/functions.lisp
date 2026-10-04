(in-package #:verona.backend.llvm)

(cffi:defcfun ("LLVMGetEnumAttributeKindForName" llvm-enum-attribute-kind) :unsigned-int
  (name :string)
  (length :size))

(cffi:defcfun ("LLVMCreateEnumAttribute" llvm-create-enum-attribute) :pointer
  (context :pointer)
  (kind :unsigned-int)
  (value :uint64))

(cffi:defcfun ("LLVMAddAttributeAtIndex" llvm-add-attribute-at-index) :void
  (function :pointer)
  (index :unsigned-int)
  (attribute :pointer))

(cffi:defcfun ("LLVMAddCallSiteAttribute" llvm-add-call-site-attribute) :void
  (call :pointer)
  (index :unsigned-int)
  (attribute :pointer))

(defun c-abi-zero-extension-attribute (backend)
  (let ((kind (llvm-enum-attribute-kind "zeroext" 7)))
    (when (zerop kind)
      (backend-fail "LLVM does not provide the zeroext ABI attribute"))
    (llvm-create-enum-attribute (llvm-backend-context backend) kind 0)))

(defun add-c-abi-boolean-signature-attributes (backend function parameter-types result-type)
  "Annotate C `_Bool` positions so LLVM applies their target ABI extensions.

LLVM represents bool as i1, while several target C ABIs extend `_Bool` in
register arguments and results.  Zero-extension is part of that boundary
contract, not Verona's internal calling convention."
  (when (typep result-type 'verona:boolean-type)
    (llvm-add-attribute-at-index function 0 (c-abi-zero-extension-attribute backend)))
  (loop for index from 1
        for parameter-type in parameter-types
        when (typep parameter-type 'verona:boolean-type)
          do (llvm-add-attribute-at-index function index
                                          (c-abi-zero-extension-attribute backend)))
  function)

(defun add-c-abi-boolean-call-attributes (backend call parameter-types result-type)
  "Make an external call site agree with its C `_Bool` declaration."
  (when (typep result-type 'verona:boolean-type)
    (llvm-add-call-site-attribute call 0 (c-abi-zero-extension-attribute backend)))
  (loop for index from 1
        for parameter-type in parameter-types
        when (typep parameter-type 'verona:boolean-type)
          do (llvm-add-call-site-attribute call index
                                            (c-abi-zero-extension-attribute backend)))
  call)

(defun protocol-operation-implementation-llvm-name (declaration)
  (let ((implementation
          (verona:semantic-protocol-operation-implementation-implementation declaration)))
    (format nil "~A_protocol_~A_~{~A~^_~}"
            (llvm-name (semantic-source-binding declaration))
            (verona:verona-name-value
             (verona:protocol-operation-name
              (verona:semantic-protocol-operation-implementation-operation declaration)))
            (mapcar #'llvm-type-mangle
                    (verona:protocol-implementation-arguments implementation)))))

(defun declare-function (backend declaration)
  (let* ((source (semantic-source-binding declaration))
         (function (llvm:add-function
                    (llvm-backend-module backend)
                    (cond ((typep declaration 'verona:semantic-function-specialization)
                           (format nil "~A_spec_~{~A~^_~}"
                                   (llvm-name source)
                                   (mapcar #'llvm-type-mangle
                                           (verona:semantic-function-specialization-type-arguments
                                            declaration))))
                          ((typep declaration 'verona:semantic-protocol-operation-implementation)
                           (protocol-operation-implementation-llvm-name declaration))
                          (t (llvm-name source)))
                    (lower-type backend (verona:semantic-function-declaration-type declaration)))))
    ;; A template can have many concrete instances; never attach a
    ;; specialization to its source declaration's backend key.
    (unless (typep declaration 'verona:semantic-function-specialization)
      (setf (backend-binding backend source) function))
    (setf (backend-binding backend declaration) function)
    function))

(defun declare-external-function (backend declaration)
  "Declare a C ABI function under its explicit linker name."
  (let* ((source (semantic-source-binding declaration))
         (function (llvm:add-function
                    (llvm-backend-module backend)
                    (verona:semantic-external-function-declaration-external-name declaration)
                    (lower-type backend
                                (verona:semantic-external-function-declaration-type declaration)))))
    (add-c-abi-boolean-signature-attributes
     backend
     function
     (verona:semantic-external-function-declaration-parameter-types declaration)
     (verona:semantic-external-function-declaration-result-type declaration))
    (setf (backend-binding backend source) function
          (backend-binding backend declaration) function)
    function))

(defun generic-implementation-llvm-name (declaration)
  "A generic has no public symbol; each selected implementation does."
  (format nil "~A_impl_~{~A~^_~}"
          (llvm-name declaration)
          (mapcar #'llvm-type-mangle
                  (verona:generic-implementation-parameter-types declaration))))

(defun declare-generic-implementation (backend declaration)
  (let ((function (llvm:add-function
                   (llvm-backend-module backend)
                   (generic-implementation-llvm-name declaration)
                   (lower-type backend (verona:semantic-generic-implementation-type declaration)))))
    (setf (backend-binding backend declaration) function)
    function))

(defun declare-global (backend declaration constantp)
  (let* ((source (semantic-source-binding declaration))
         (global (llvm:add-global (llvm-backend-module backend)
                                  (lower-type backend
                                              (if constantp
                                                  (verona:semantic-constant-declaration-type declaration)
                                                  (verona:semantic-variable-declaration-type declaration)))
                                  (llvm-name source))))
    (when constantp
      (setf (llvm:global-constant-p global) t))
    (setf (backend-binding backend source) global
          (backend-binding backend declaration) global)
    global))

(defun define-native-export-wrapper (backend export)
  "Expose one explicit C symbol while retaining Verona ABI internally."
  (let* ((verona-function (backend-binding backend
                                           (verona:native-export-binding-function export)))
         (function-type (verona:semantic-function-declaration-type
                         (verona:native-export-binding-function export)))
         (wrapper (llvm:add-function (llvm-backend-module backend)
                                     (verona:native-export-binding-external-name export)
                                     (lower-type backend function-type)))
         (block (llvm:append-basic-block wrapper "entry" :context (llvm-backend-context backend))))
    ;; Exported functions are the first symbols with an explicit visibility
    ;; contract.  Their Verona ABI implementation is local to this module;
    ;; only the wrapper has the public C symbol.
    (setf (llvm:linkage verona-function) :internal
          (llvm:visibility verona-function) :hidden)
    (setf (llvm:linkage wrapper) :external
          (llvm:visibility wrapper) :default)
    (add-c-abi-boolean-signature-attributes
     backend
     wrapper
     (verona:function-type-parameters function-type)
     (verona:function-type-result function-type))
    (llvm:position-builder-at-end (llvm-backend-builder backend) block)
    (llvm:build-ret (llvm-backend-builder backend)
                    (llvm:build-call (llvm-backend-builder backend)
                                     verona-function (llvm:params wrapper) "verona.export"))
    wrapper))

(defun emit-global-constant (backend expression)
  "Lower the constant subset permitted in an LLVM global initializer."
  (cond ((typep expression 'verona:unit-expression)
         (llvm:const-int (lower-type backend (verona:expression-type expression)) 0))
        ((typep expression 'verona:boolean-literal)
         (llvm:const-int (lower-type backend (verona:expression-type expression))
                         (if (verona:boolean-literal-value expression) 1 0)))
        ((typep expression 'verona:character-literal)
         (llvm:const-int (lower-type backend (verona:expression-type expression))
                         (char-code (verona:character-literal-value expression))))
        ((typep expression 'verona:integer-literal)
         (llvm:const-int (lower-type backend (verona:expression-type expression))
                         (verona:integer-literal-value expression)))
        ((typep expression 'verona:float-literal)
         (llvm:const-real (lower-type backend (verona:expression-type expression))
                          (verona:float-literal-value expression)))
        ((typep expression 'verona:string-literal)
         (emit-string-literal backend expression))
        (t (backend-fail "global initializer ~S is not an LLVM constant" expression))))

(defun define-function (backend declaration)
  (let* ((function (backend-binding backend declaration))
         (entry (llvm:append-basic-block function "entry" :context (llvm-backend-context backend)))
         (parameters (verona:semantic-function-declaration-parameters declaration))
         (llvm-parameters (llvm:params function)))
    (llvm:position-builder-at-end (llvm-backend-builder backend) entry)
    ;; Parameters are writable places.  Keep the calling convention
    ;; values distinct from their allocated semantic storage.
    (loop for parameter in parameters
          for llvm-parameter in llvm-parameters
          do (setf (llvm:value-name llvm-parameter) (llvm-name parameter))
             (let ((address (llvm:build-alloca
                             (llvm-backend-builder backend)
                             (lower-type backend (verona:parameter-binding-type parameter))
                             (format nil "~A.addr" (llvm-name parameter)))))
               (llvm:build-store (llvm-backend-builder backend) llvm-parameter address)
               (setf (backend-binding backend parameter) address)))
    (let ((body (verona:semantic-function-declaration-body declaration)))
      ;; Emit the result position directly so an eligible final call can be
      ;; annotated as LLVM tail/musttail and remain adjacent to its return.
      (emit-tail-return backend body declaration))
    function))

(defun define-generic-implementation (backend declaration)
  (let* ((function (backend-binding backend declaration))
         (entry (llvm:append-basic-block function "entry" :context (llvm-backend-context backend)))
         (parameters (verona:generic-implementation-parameters declaration))
         (llvm-parameters (llvm:params function)))
    (llvm:position-builder-at-end (llvm-backend-builder backend) entry)
    (loop for parameter in parameters
          for llvm-parameter in llvm-parameters
          do (setf (llvm:value-name llvm-parameter) (llvm-name parameter))
             (let ((address (llvm:build-alloca
                             (llvm-backend-builder backend)
                             (lower-type backend (verona:parameter-binding-type parameter))
                             (format nil "~A.addr" (llvm-name parameter)))))
               (llvm:build-store (llvm-backend-builder backend) llvm-parameter address)
               (setf (backend-binding backend parameter) address)))
    (let ((body (verona:generic-implementation-body declaration)))
      (emit-tail-return backend body declaration))
    function))
