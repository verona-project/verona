(in-package #:verona.backend.llvm)

;;; Generated C declarations -------------------------------------------------

(defun c-identifier (text)
  "Return a conservative C identifier for externally visible generated names."
  (with-output-to-string (stream)
    (loop for character across text
          do (if (or (alphanumericp character) (char= character #\_))
                 (write-char character stream)
                 (format stream "_~2,'0X" (char-code character))))))

(defun c-abi-nominal-name (type)
  (c-identifier (llvm-name (verona:defined-type-declaration type))))

(defun c-abi-array-name (type)
  (format nil "verona_array_~A" (c-identifier (llvm-type-mangle type))))

(defun c-abi-scalar-spelling (type)
  (cond ((typep type 'verona:boolean-type) "_Bool")
        ((typep type 'verona:char-type) "uint8_t")
        ((typep type 'verona:integer-type)
         (format nil "~A~D_t" (if (verona:integer-type-signed type) "int" "uint")
                 (verona:integer-type-width type)))
        ((typep type 'verona:float-type)
         (if (= (verona:float-type-width type) 32) "float" "double"))))

(defun c-abi-type-spelling (type)
  (or (c-abi-scalar-spelling type)
      (cond ((typep type 'verona:void-type) "void")
            ((typep type 'verona:pointer-type)
             ;; The caller adds the star because function pointers need a
             ;; parenthesized declarator rather than a simple suffix.
             (c-abi-type-spelling (verona:pointer-type-pointee type)))
            ((typep type 'verona:array-type) (format nil "struct ~A" (c-abi-array-name type)))
            ((typep type '(or verona:product-type verona:sum-type verona:opaque-type))
             (format nil "struct ~A" (c-abi-nominal-name type)))
            (t (error "no C spelling for ABI type ~S" type)))))

(defun c-abi-declarator (type name)
  "Render TYPE NAME, including C's special function-pointer declarator."
  (cond ((and (typep type 'verona:pointer-type)
              (typep (verona:pointer-type-pointee type) 'verona:function-type))
         (let ((function (verona:pointer-type-pointee type)))
           (format nil "~A (*~A)(~{~A~^, ~})"
                   (c-abi-type-spelling (verona:function-type-result function)) name
                   (mapcar (lambda (parameter) (c-abi-declarator parameter ""))
                           (verona:function-type-parameters function)))))
        ((typep type 'verona:pointer-type)
         (format nil "~A *~A" (c-abi-type-spelling (verona:pointer-type-pointee type)) name))
        (t (format nil "~A~@[ ~A~]" (c-abi-type-spelling type) name))))

(defun c-abi-zero-size-p (type)
  (cond ((typep type 'verona:array-type) (zerop (verona:array-type-length type)))
        ((typep type 'verona:product-type)
         (every (lambda (field) (c-abi-zero-size-p (verona:product-field-type field)))
                (verona:product-type-fields type)))
        (t nil)))

(defun c-abi-child-types (type)
  (cond ((typep type 'verona:pointer-type) (list (verona:pointer-type-pointee type)))
        ((typep type 'verona:array-type) (list (verona:array-type-element-type type)))
        ((typep type 'verona:function-type)
         (append (verona:function-type-parameters type)
                 (list (verona:function-type-result type))))
        ((typep type 'verona:product-type)
         (mapcar #'verona:product-field-type (verona:product-type-fields type)))
        ((typep type 'verona:sum-type)
         (mapcan #'verona:sum-alternative-payload-types (verona:sum-type-alternatives type)))
        (t '())))

(defun collect-c-abi-types (roots)
  (let ((seen (make-hash-table :test #'eq)) (ordered '()))
    (labels ((visit (type)
               (unless (gethash type seen)
                 (setf (gethash type seen) t)
                 (dolist (child (c-abi-child-types type)) (visit child))
                 (when (typep type '(or verona:array-type verona:product-type
                                      verona:sum-type verona:opaque-type))
                   (push type ordered)))))
      (dolist (root roots) (visit root))
      (nreverse ordered))))

(defun emit-c-abi-type-declaration (stream type)
  (cond ((typep type 'verona:opaque-type)
         (format stream "struct ~A;~%" (c-abi-nominal-name type)))
        ((typep type 'verona:array-type)
         (format stream "struct ~A { ~A elements[~D]; };~%"
                 (c-abi-array-name type)
                 (c-abi-type-spelling (verona:array-type-element-type type))
                 (verona:array-type-length type)))
        ((typep type 'verona:product-type)
         (format stream "struct ~A {~%" (c-abi-nominal-name type))
         (dolist (field (verona:product-type-fields type))
           (format stream "  ~A;~%"
                   (c-abi-declarator (verona:product-field-type field)
                                     (c-identifier (verona:verona-name-value
                                                    (verona:product-field-name field))))))
         (write-string "};\n" stream))
        ((typep type 'verona:sum-type)
         (let ((payloads (remove-if (lambda (alternative)
                                      (every #'c-abi-zero-size-p
                                             (verona:sum-alternative-payload-types alternative)))
                                    (verona:sum-type-alternatives type))))
           (format stream "struct ~A {~%  int32_t tag;~%" (c-abi-nominal-name type))
           (when payloads
             (write-string "  union {\n" stream)
             (dolist (alternative payloads)
               (format stream "    struct { ")
               (loop for payload in (verona:sum-alternative-payload-types alternative)
                     for index from 0
                     do (format stream "~A; " (c-abi-declarator payload
                                                            (format nil "field~D" index))))
               (format stream "} case~D;~%" (verona:sum-alternative-index alternative)))
             (write-string "  } payload;\n" stream))
           (write-string "};\n" stream)))))

(defun generate-c-header (program pathname)
  "Write the public C contract for PROGRAM's native exports to PATHNAME."
  (let* ((exports (verona:semantic-program-native-exports program))
         (signatures (mapcar (lambda (export)
                               (verona:semantic-function-declaration-type
                                (verona:native-export-binding-function export)))
                             exports))
         (types (collect-c-abi-types
                 (mapcan (lambda (signature)
                           (append (verona:function-type-parameters signature)
                                   (list (verona:function-type-result signature))))
                         signatures))))
    (with-open-file (stream pathname :direction :output :if-exists :supersede
                                     :if-does-not-exist :create)
      (write-string "/* Generated by Verona.  Do not edit. */\n#pragma once\n#include <stdint.h>\n#include <stdbool.h>\n\n"
                    stream)
      ;; Forward declarations allow products to mention opaque handles.
      (dolist (type types)
        (when (typep type '(or verona:product-type verona:sum-type verona:opaque-type))
          (format stream "struct ~A;~%" (c-abi-nominal-name type))))
      (terpri stream)
      (dolist (type types) (emit-c-abi-type-declaration stream type))
      (when types (terpri stream))
      (dolist (export exports)
        (let ((signature (verona:semantic-function-declaration-type
                          (verona:native-export-binding-function export))))
          (format stream "~A(~{~A~^, ~});~%"
                  (c-abi-declarator (verona:function-type-result signature)
                                    (verona:native-export-binding-external-name export))
                  (loop for parameter in (verona:function-type-parameters signature)
                        for index from 0
                        collect (c-abi-declarator parameter (format nil "arg~D" index)))))))
    pathname))
