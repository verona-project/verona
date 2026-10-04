(in-package #:verona.backend.llvm)

(defun lowered-sum-payload-type (backend alternative)
  (llvm:struct-type
   (mapcar (lambda (payload-type) (lower-type backend payload-type))
           (verona:sum-alternative-payload-types alternative))
   nil :context (llvm-backend-context backend)))

(defun sum-union-storage-type (backend alternatives)
  "Create LLVM storage with the size and alignment of a C union.

LLVM has no union type.  A struct headed by the most-aligned payload type,
with a byte tail when needed, has the same ABI size and alignment as a union
whose members are the alternative payload structs."
  (let ((payload-types
          (remove-if (lambda (type) (zerop (llvm:abi-size-of-type
                                             (llvm-backend-target-data backend) type)))
                     (mapcar (lambda (alternative)
                               (lowered-sum-payload-type backend alternative))
                             alternatives))))
    (when payload-types
      (let* ((target-data (llvm-backend-target-data backend))
             (anchor (reduce (lambda (left right)
                               (if (> (llvm:abi-alignment-of-type target-data left)
                                      (llvm:abi-alignment-of-type target-data right))
                                   left right))
                             payload-types))
             (union-size (reduce #'max payload-types
                                 :key (lambda (type)
                                        (llvm:abi-size-of-type target-data type))))
             (anchor-size (llvm:abi-size-of-type target-data anchor))
             (tail-size (- union-size anchor-size))
             (elements (list anchor)))
        (when (plusp tail-size)
          (setf elements
                (append elements
                        (list (llvm:array-type
                               (llvm:int-type 8 :context (llvm-backend-context backend))
                               tail-size)))))
        (llvm:struct-type elements nil :context (llvm-backend-context backend))))))

(defun lower-type (backend type)
  "Return TYPE's LLVM type, memoized strictly in BACKEND."
  (or (gethash type (llvm-backend-types backend))
      (setf (gethash type (llvm-backend-types backend))
            (cond
              ((typep type 'verona:unit-type)
               (llvm:int-type (llvm-backend-pointer-width backend)
                              :context (llvm-backend-context backend)))
              ((typep type 'verona:void-type)
               (llvm:void-type :context (llvm-backend-context backend)))
              ((typep type 'verona:boolean-type)
               (llvm:int1-type :context (llvm-backend-context backend)))
              ((typep type 'verona:char-type)
               ;; Verona characters are restricted to ASCII code units.
               (llvm:int-type 8 :context (llvm-backend-context backend)))
              ((typep type 'verona:integer-type)
               (llvm:int-type (verona:integer-type-width type)
                              :context (llvm-backend-context backend)))
              ((typep type 'verona:float-type)
               (ecase (verona:float-type-width type)
                 (32 (llvm:float-type :context (llvm-backend-context backend)))
                 (64 (llvm:double-type :context (llvm-backend-context backend)))))
              ((typep type 'verona:pointer-type)
               ;; LLVM opaque pointers carry no pointee representation.  The
               ;; legacy C API still accepts an element type, so use i8 for
               ;; void* rather than attempting to form a pointer-to-void.
               (llvm:pointer-type
                (if (typep (verona:pointer-type-pointee type) 'verona:void-type)
                    (llvm:int-type 8 :context (llvm-backend-context backend))
                    (lower-type backend (verona:pointer-type-pointee type)))))
              ((typep type 'verona:array-type)
               (llvm:array-type
                (lower-type backend (verona:array-type-element-type type))
                (verona:array-type-length type)))
              ((typep type 'verona:function-type)
               (llvm:function-type
                (lower-type backend (verona:function-type-result type))
                (mapcar (lambda (parameter) (lower-type backend parameter))
                        (verona:function-type-parameters type))))
              ((typep type 'verona:product-type)
               ;; Product fields are already complete and acyclic by semantic
               ;; validation.  The named LLVM struct preserves nominal Verona
               ;; identity; setting its body is a one-shot layout operation.
               (let ((struct (llvm:struct-create-named
                              (llvm-backend-context backend)
                              (llvm-name (verona:defined-type-declaration type)))))
                 (llvm:struct-set-body
                  struct
                  (mapcar (lambda (field)
                            (lower-type backend (verona:product-field-type field)))
                          (verona:product-type-fields type)))
                 struct))
              ((typep type 'verona:sum-type)
               ;; C-compatible tagged union: i32 tag followed by shared,
               ;; target-aligned storage for the largest payload.
               (let ((struct (llvm:struct-create-named
                              (llvm-backend-context backend)
                              (llvm-name (verona:defined-type-declaration type)))))
                 (llvm:struct-set-body
                  struct
                  (let ((storage (sum-union-storage-type backend
                                                         (verona:sum-type-alternatives type))))
                    (append (list (llvm:int-type 32 :context (llvm-backend-context backend)))
                            (if storage (list storage) '())))
                  nil)
                 struct))
              ;; Defined types have identity, but their field layout is not
              ;; part of the current semantic model.  An opaque named LLVM
              ;; struct preserves that identity for pointer uses.
              ((typep type 'verona:defined-type)
               (llvm:struct-create-named
                (llvm-backend-context backend)
                (llvm-name (verona:defined-type-declaration type))))
              (t (backend-fail "Verona type ~S has no LLVM representation" type))))))

(defun unit-value (backend expression)
  (declare (ignore expression))
  (llvm:const-int (lower-type backend (verona:type-context-unit-representation-type
                                       (backend-type-context backend)))
                  0))
