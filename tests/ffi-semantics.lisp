(in-package #:verona/tests)

(in-suite :verona)

(defun compile-malloc-declaration-for-test ()
  (compile-string
   (make-compiler)
   "(external-function allocate \"malloc\" (usize) (pointer void))
     (function main () i32
       (let ((memory (pointer void) (allocate 1)))
         (let ((buffer (pointer u8) (cast (pointer u8) memory))) 0)))"))

(test-cases models-c-external-declarations-and-void-pointers
  (declaration
   (let* ((unit (compile-string
                 (make-compiler)
                 "(external-function allocate \"malloc\" (usize) (pointer void))"))
          (declaration (first (unit-declarations unit)))
          (program (compilation-unit-semantic-program unit))
          (semantic (semantic-program-declaration program declaration)))
     (is (typep declaration 'verona:external-function-declaration))
     (is (string= "malloc"
                  (verona:external-function-declaration-external-name declaration)))
     (is (typep semantic 'verona:semantic-external-function-declaration))))
  (void-pointer-result
   (let* ((unit (compile-malloc-declaration-for-test))
          (declaration (first (unit-declarations unit)))
          (program (compilation-unit-semantic-program unit))
          (semantic (semantic-program-declaration program declaration)))
     (is (typep (verona:semantic-external-function-declaration-result-type semantic)
                'verona:pointer-type))
     (is (typep (verona:pointer-type-pointee
                 (verona:semantic-external-function-declaration-result-type semantic))
                'verona:void-type))))
  (canonical-void-type
   (let* ((unit (compile-malloc-declaration-for-test))
          (context (semantic-program-type-context
                    (compilation-unit-semantic-program unit))))
     (is (typep (verona:type-context-void-type context) 'verona:void-type)))))

(test accepts-bool-in-c-abi-signatures
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function invert \"verona_bool_invert\" (bool) bool)
                 (function invert-export ((value bool)) bool (%not-primitive-bool value))
                 (native-export invert-export \"verona_bool_invert_export\")"))
         (program (compilation-unit-semantic-program unit)))
    (is (eq program (validate-for-backend program)))))

(test-cases rejects-invalid-native-exports
  (non-function-binding
   (signals verona:invalid-native-export
     (compile-string (make-compiler)
                     "(constant value i32 1) (native-export value)")))
  (duplicate-c-name
   (signals verona:invalid-native-export
     (compile-string
      (make-compiler)
      "(function first () i32 1)
       (function second () i32 2)
       (native-export first \"shared_name\")
       (native-export second \"shared_name\")")))
  (non-c-compatible-result
   (signals verona:invalid-native-export
     (compile-string (make-compiler)
                     "(function no-value () unit unit) (native-export no-value)"))))

(test rejects-void-pointer-dereference
  (signals verona:invalid-expression-error
    (compile-string
     (make-compiler)
     "(external-function allocate \"malloc\" (usize) (pointer void))
       (function main () i32
         (let ((memory (pointer void) (allocate 1)))
           (deref memory)))")))

(test-cases models-nominal-opaque-types-for-c-handles
  (opaque-declarations-have-distinct-identities
  (let* ((unit (compile-string
                (make-compiler)
                "(type file-stream)
                 (type directory-stream)
                 (type stream-holder (product (stream (pointer file-stream))))
                 (external-function open-stream \"fopen\" ((pointer i8) (pointer i8)) (pointer file-stream))
                 (external-function close-stream \"fclose\" ((pointer file-stream)) i32)"))
         (program (compilation-unit-semantic-program unit))
         (file-declaration (first (unit-declarations unit)))
         (directory-declaration (second (unit-declarations unit)))
         (holder-declaration (third (unit-declarations unit)))
         (file-type (semantic-type-declaration-type
                     (semantic-program-declaration program file-declaration)))
         (directory-type (semantic-type-declaration-type
                          (semantic-program-declaration program directory-declaration)))
         (holder-type (semantic-type-declaration-type
                       (semantic-program-declaration program holder-declaration))))
    (is (eq :opaque (type-declaration-kind file-declaration)))
    (is (null (type-declaration-body file-declaration)))
    (is (typep file-type 'opaque-type))
    (is (typep directory-type 'opaque-type))
    (is (not (eq file-type directory-type)))))
  (pointers-to-opaque-types-are-sized
   (let* ((unit (compile-string (make-compiler)
                                "(type file-stream)
                                 (type stream-holder (product (stream (pointer file-stream))))"))
          (program (compilation-unit-semantic-program unit))
          (holder (semantic-program-declaration program (second (unit-declarations unit))))
          (holder-type (semantic-type-declaration-type holder)))
    ;; An inline pointer is sized even though its target is not.
    (is (typep (product-field-type (first (product-type-fields holder-type)))
               'pointer-type))
    (is (eq program (validate-for-backend program))))))

(test-cases rejects-opaque-types-as-inline-values
  (parameter
   (signals verona:semantic-error
     (compile-string (make-compiler)
                     "(type handle) (function invalid ((value handle)) i32 0)")))
  (result
   (signals verona:semantic-error
     (compile-string (make-compiler)
                     "(type handle) (function invalid () handle unit)")))
  (product-field
   (signals verona:semantic-error
     (compile-string (make-compiler)
                     "(type handle) (type invalid (product (value handle)))")))
  (array-element
   (signals verona:semantic-error
     (compile-string (make-compiler)
                     "(type handle) (function invalid ((values (array handle 1))) i32 0)")))
  (dereference
   (signals verona:invalid-expression-error
     (compile-string
      (make-compiler)
      "(type handle)
      (external-function acquire \"acquire\" () (pointer handle))
      (function invalid () i32 (deref (acquire)))"))))

(test keeps-void-aliases-transparent
  (let* ((unit (compile-string (make-compiler) "(type legacy-handle void)"))
         (declaration (first (unit-declarations unit)))
         (program (compilation-unit-semantic-program unit))
         (semantic (semantic-program-declaration program declaration)))
    (is (typep declaration 'type-alias-declaration))
    (is (typep (semantic-type-alias-declaration-target-type semantic) 'verona:void-type))))

(test maps-external-void-results-to-unit-at-the-call-boundary
  (let* ((unit (compile-string
                (make-compiler)
                "(external-function allocate \"malloc\" (usize) (pointer void))
                 (external-function release \"free\" ((pointer void)) void)
                 (function release-all () unit
                   (let ((memory (pointer void) (allocate 1))) (release memory)))"))
         (program (compilation-unit-semantic-program unit))
         (function (semantic-program-declaration program (third (unit-declarations unit))))
         (body (semantic-function-declaration-body function))
         (call (verona:let-expression-body body)))
    (is (typep call 'verona:external-call-expression))
    (is (typep (verona:expression-type call) 'verona:unit-type))))
