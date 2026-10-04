(in-package #:verona.compiler)

;;; The driver owns orchestration only.  Frontend analysis remains in VERONA,
;;; LLVM lowering remains in VERONA.BACKEND.LLVM, and native commands live in
;;; the Toolchain protocol below.

(define-condition compiler-driver-error (verona:user-compilation-error)
  ((message :initarg :message :reader compiler-driver-error-message))
  (:report (lambda (condition stream)
             (write-string (compiler-driver-error-message condition) stream))))

(define-condition unsupported-artifact (compiler-driver-error) ())
(define-condition unsupported-target (compiler-driver-error) ())
(define-condition llvm-verification-failure (compiler-driver-error) ())
(define-condition object-emission-failure (compiler-driver-error) ())
(define-condition invalid-entry-point (compiler-driver-error) ())

(define-condition tool-failure (compiler-driver-error)
  ((executable :initarg :executable :reader tool-failure-executable)
   (arguments :initarg :arguments :reader tool-failure-arguments)
   (exit-status :initarg :exit-status :reader tool-failure-exit-status)
   (stdout :initarg :stdout :reader tool-failure-stdout)
   (stderr :initarg :stderr :reader tool-failure-stderr))
  (:documentation "Structured failure from an external native tool."))

;; Keep the Step 23 spelling as a compatibility subtype while presenting the
;; uniform ToolFailure shape to diagnostics and embedding callers.
(define-condition toolchain-failure (tool-failure)
  ((tool :initarg :tool :reader toolchain-failure-tool))
  (:default-initargs :executable nil))
(define-condition linker-failure (toolchain-failure) ())
(define-condition archiver-failure (toolchain-failure) ())
(define-condition shared-library-link-failure (linker-failure) ())

(defmethod verona:diagnostic-code-for ((condition unsupported-artifact))
  (declare (ignore condition)) "E1001")
(defmethod verona:diagnostic-code-for ((condition unsupported-target))
  (declare (ignore condition)) "E1002")
(defmethod verona:diagnostic-code-for ((condition toolchain-failure))
  (declare (ignore condition)) "E1003")

(defclass compilation-target ()
  ((triple :initarg :triple :reader compilation-target-triple)
   (cpu :initarg :cpu :reader compilation-target-cpu)
   (features :initarg :features :reader compilation-target-features)
   ;; These are Verona source-reader conditions, deliberately separate from
   ;; LLVM CPU features above.
   (reader-features :initarg :reader-features :initform '()
                    :reader compilation-target-reader-features)
   (data-layout :initarg :data-layout :reader compilation-target-data-layout)
   (pointer-width :initarg :pointer-width :reader compilation-target-pointer-width)
   (object-format :initarg :object-format :reader compilation-target-object-format)
   (platform :initarg :platform :reader compilation-target-platform)))

(defun target-architecture-feature (triple)
  "Return the canonical reader feature for TRIPLE's CPU architecture."
  (let ((architecture (string-downcase
                       (subseq triple 0 (or (position #\- triple) (length triple))))))
    (cond ((member architecture '("x86_64" "amd64") :test #'string=) "x86_64")
          ((member architecture '("aarch64" "arm64") :test #'string=) "aarch64")
          ((or (string= architecture "arm")
               (and (>= (length architecture) 3)
                    (string= "arm" architecture :end2 3))
               (and (>= (length architecture) 5)
                    (string= "thumb" architecture :end2 5)))
           "arm")
          ((string= architecture "riscv64") "riscv64")
          (t nil))))

(defun target-endianness-feature (data-layout)
  "Read the target byte order from LLVM's canonical data-layout spelling."
  (when (> (length data-layout) 0)
    (case (char data-layout 0)
      (#\e "little_endian")
      (#\E "big_endian"))))

(defmethod verona:target-feature-names ((target compilation-target))
  ;; Feature composition is ordered and append-only.  Compiler-provided
  ;; target facts come first, then explicit command-line/package flags.
  (let ((platform (compilation-target-platform target)))
    (append (and platform (list (string-downcase (symbol-name platform))))
            (let ((architecture (target-architecture-feature
                                 (compilation-target-triple target))))
              (and architecture (list architecture)))
            (list (format nil "pointer_~D" (compilation-target-pointer-width target)))
            (let ((endianness (target-endianness-feature
                               (compilation-target-data-layout target))))
              (and endianness (list endianness)))
            (list (string-downcase (symbol-name (compilation-target-object-format target))))
            (mapcar #'verona::feature-name-string
                    (compilation-target-reader-features target)))))

(defun target-platform (triple)
  (cond ((search "darwin" triple :test #'char-equal) :darwin)
        ((or (search "linux" triple :test #'char-equal)
             (search "gnu" triple :test #'char-equal)) :linux)
        (t nil)))

(defun target-object-format (platform)
  (ecase platform (:darwin :macho) (:linux :elf)))

(defun resolve-compilation-target (&key triple (cpu "generic") (features "")
                                        (reader-features '()))
  "Resolve NATIVE or an explicit triple once, before semantic analysis.

The LLVM target machine is the authority for data layout and pointer width;
neither value is taken from the Common Lisp host.  READER-FEATURES adds
explicit #+/#- conditions without changing LLVM's CPU FEATURES."
  (let* ((triple (or triple (native-target-triple)))
         (platform (target-platform triple)))
    (unless platform
      (error 'unsupported-target :message (format nil "unsupported target ~A" triple)))
    (handler-case
        (let* ((backend (verona.backend.llvm:make-llvm-backend
                         :module-name "verona.target-probe"
                         :target-configuration
                         (make-target-configuration :triple triple :cpu cpu :features features)))
               (width (llvm-backend-pointer-width backend)))
          (make-instance 'compilation-target :triple triple :cpu cpu :features features
                         :reader-features reader-features
                         :data-layout (llvm-backend-data-layout backend)
                         :pointer-width width :platform platform
                         :object-format (target-object-format platform)))
      (error (condition)
        (if (typep condition 'compiler-driver-error)
            (error condition)
            (error 'unsupported-target :message (format nil "cannot resolve target ~A: ~A"
                                                        triple condition)))))))

(defclass link-options ()
  ((libraries :initarg :libraries :initform '() :reader link-options-libraries)
   (library-search-paths :initarg :library-search-paths :initform '()
                         :reader link-options-library-search-paths)
   (frameworks :initarg :frameworks :initform '() :reader link-options-frameworks)))

(defun make-link-options (&key (libraries '()) (library-search-paths '()) (frameworks '()))
  (make-instance 'link-options :libraries libraries
               :library-search-paths (mapcar #'pathname library-search-paths)
               :frameworks frameworks))

(defclass artifact ()
  ((kind :initarg :kind :reader artifact-kind)
   (path :initarg :path :reader artifact-path)
   (target :initarg :target :reader artifact-target)))
(defclass object-artifact (artifact) ())
(defclass executable-artifact (artifact) ())
(defclass static-library-artifact (artifact) ())
(defclass shared-library-artifact (artifact) ())

(defclass toolchain () ())
(defgeneric toolchain-emit-object (toolchain backend output))
(defgeneric toolchain-link-executable (toolchain object output target options))
(defgeneric toolchain-archive-static-library (toolchain object output target))
(defgeneric toolchain-link-shared-library (toolchain object output target options))

(defclass native-toolchain (toolchain)
  ((compiler :initarg :compiler :reader native-toolchain-compiler)
   (archiver :initarg :archiver :reader native-toolchain-archiver)))

(defun make-native-toolchain (&key (compiler (or (uiop:getenv "VERONA_LINKER") "clang"))
                                   (archiver (or (uiop:getenv "VERONA_AR") "ar")))
  (make-instance 'native-toolchain :compiler compiler :archiver archiver))

(defun run-tool (failure-class tool arguments)
  (multiple-value-bind (stdout stderr status)
      (uiop:run-program (cons tool arguments) :output :string :error-output :string
                         :ignore-error-status t)
    (unless (zerop status)
      (error failure-class :message (format nil "~A failed" tool) :tool tool
             :executable tool :arguments arguments :exit-status status
             :stdout stdout :stderr stderr))))

(defun native-link-arguments (object output target options)
  (when (and (link-options-frameworks options)
             (not (eq (compilation-target-platform target) :darwin)))
    (error 'unsupported-target :message "frameworks are supported only on Darwin targets"))
  (append (list (namestring (pathname object)))
          (loop for directory in (link-options-library-search-paths options)
                append (list "-L" (namestring directory)))
          (loop for library in (link-options-libraries options)
                collect (format nil "-l~A" library))
          (loop for framework in (link-options-frameworks options)
                append (list "-framework" framework))
          (list "-o" (namestring (pathname output)))))

(defmethod toolchain-emit-object ((toolchain native-toolchain) backend output)
  (declare (ignore toolchain))
  (handler-case (emit-object backend output)
    (error (condition)
      (error 'object-emission-failure :message (princ-to-string condition)))))

(defmethod toolchain-link-executable ((toolchain native-toolchain) object output target options)
  (run-tool 'linker-failure (native-toolchain-compiler toolchain)
            (native-link-arguments object output target options))
  output)

(defmethod toolchain-archive-static-library ((toolchain native-toolchain) object output target)
  (declare (ignore target))
  (run-tool 'archiver-failure (native-toolchain-archiver toolchain)
            (list "rcs" (namestring (pathname output)) (namestring (pathname object))))
  output)

(defmethod toolchain-link-shared-library ((toolchain native-toolchain) object output target options)
  (let ((arguments (native-link-arguments object output target options)))
    ;; The compiler driver supplies platform startup differences; LLVM only
    ;; produced a PIC object, and no linker knowledge leaks into semantics.
    (setf arguments
          (append (ecase (compilation-target-platform target)
                    (:darwin (list "-dynamiclib"))
                    (:linux (list "-shared")))
                  arguments))
    (run-tool 'shared-library-link-failure (native-toolchain-compiler toolchain) arguments))
  output)

(defclass compiler-driver ()
  ((search-paths :initarg :search-paths :reader compiler-driver-search-paths)
   (target :initarg :target :reader compiler-driver-target)
   ;; LLVM's four target-machine optimization choices are intentionally kept
   ;; at the driver boundary.  Frontend semantics remain independent of build
   ;; policy, while clients such as the build-file layer can select it.
   (optimization-level :initarg :optimization-level :initform :none
                       :reader compiler-driver-optimization-level)
   (toolchain :initarg :toolchain :reader compiler-driver-toolchain)))

(defun make-compiler-driver (&key (search-paths '()) target
                                   (optimization-level :none)
                                   (toolchain (make-native-toolchain)))
  (make-instance 'compiler-driver :search-paths (mapcar #'pathname search-paths)
               :target (or target (resolve-compilation-target))
               :optimization-level optimization-level :toolchain toolchain))

(defun artifact-class (kind)
  (ecase kind
    (:object 'object-artifact) (:executable 'executable-artifact)
    (:static-library 'static-library-artifact) (:shared-library 'shared-library-artifact)))

(defun default-output-path (root kind target)
  (let* ((path (pathname root)) (base (or (pathname-name path) "a.out"))
         (directory (make-pathname :name nil :type nil :defaults path)))
    (merge-pathnames
     (ecase kind
       (:object (format nil "~A.o" base))
       (:executable base)
       (:static-library (format nil "lib~A.a" base))
       (:shared-library (format nil "lib~A.~A" base
                                        (ecase (compilation-target-platform target)
                                          (:darwin "dylib") (:linux "so")))))
     directory)))

(defun library-header-path (output)
  "Place a generated C header beside a static or shared library artifact."
  (make-pathname :type "h" :defaults (pathname output)))

(defun temporary-object-path ()
  (merge-pathnames (format nil "verona-~A.o" (gensym "OBJECT-"))
                   (uiop:temporary-directory)))

(defun driver-target-configuration (target &optional relocation-model)
  (make-target-configuration :triple (compilation-target-triple target)
                             :cpu (compilation-target-cpu target)
                             :features (compilation-target-features target)
                             :relocation-model (or relocation-model :default)))

(defun compile-root (driver root &key (artifact-kind :executable) output
                                      (link-options (make-link-options)))
  "Compile ROOT and return an explicit native Artifact.

The frontend receives the already-resolved target, then the driver owns the
in-memory LLVM module, verification, object emission, and toolchain handoff."
  (check-type driver compiler-driver)
  (unless (member artifact-kind '(:object :executable :static-library :shared-library))
    (error 'unsupported-artifact :message (format nil "unsupported artifact ~S" artifact-kind)))
  (let* ((target (compiler-driver-target driver))
         (output (pathname (or output (default-output-path root artifact-kind target))))
         (frontend (make-compiler :search-paths (compiler-driver-search-paths driver)))
         (unit (verona:compile-file frontend root :target target
                                     :pointer-width (compilation-target-pointer-width target)))
         (program (compilation-unit-semantic-program unit))
         (picp (eq artifact-kind :shared-library))
         (backend (handler-case
                      (generate-llvm program
                                     :target-configuration
                                     (driver-target-configuration target (and picp :pic))
                                     :optimization-level
                                     (compiler-driver-optimization-level driver))
                    (error (condition)
                      (if (typep condition 'verona:compiler-bug)
                          (error condition)
                          (error 'llvm-verification-failure :message (princ-to-string condition)))))))
    (when (eq artifact-kind :executable)
      (handler-case (add-platform-entry-wrapper backend program)
        (error (condition)
          (error 'invalid-entry-point :message (princ-to-string condition)))))
    (hide-verona-symbols backend program)
    (handler-case (verify-llvm-module backend)
      (error (condition)
        (if (typep condition 'verona:compiler-bug)
            (error condition)
            (error 'llvm-verification-failure :message (princ-to-string condition)))))
    (if (eq artifact-kind :object)
        (toolchain-emit-object (compiler-driver-toolchain driver) backend output)
        (let ((object (temporary-object-path)))
          (unwind-protect
               (progn
                 (toolchain-emit-object (compiler-driver-toolchain driver) backend object)
                 (ecase artifact-kind
                   (:executable (toolchain-link-executable (compiler-driver-toolchain driver)
                                                           object output target link-options))
                   (:static-library (toolchain-archive-static-library (compiler-driver-toolchain driver)
                                                                       object output target))
                   (:shared-library (toolchain-link-shared-library (compiler-driver-toolchain driver)
                                                                   object output target link-options))))
            (when (probe-file object) (delete-file object)))))
    (when (member artifact-kind '(:static-library :shared-library))
      (generate-c-header program (library-header-path output)))
    (make-instance (artifact-class artifact-kind) :kind artifact-kind :path output :target target)))

(defun compile-file (driver pathname &rest arguments)
  (apply #'compile-root driver pathname arguments))
