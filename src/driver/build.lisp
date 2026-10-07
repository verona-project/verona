(in-package #:verona.compiler)

;;; The build reader deliberately stops at syntax.  It reuses Verona's
;;; source-aware S-expression reader, but no form is ever expanded or
;;; evaluated: the objects below are configuration data only.

(defstruct (build-name (:constructor make-build-name (value)))
  "A build-target identity, separate from Verona names and modules."
  (value "" :type string))

(defun build-name= (left right)
  (and (build-name-p left) (build-name-p right)
       (string= (build-name-value left) (build-name-value right))))

(define-condition build-error (verona:user-compilation-error)
  ((message :initarg :message :reader build-error-message)
   (syntax :initarg :syntax :initform nil :reader build-error-syntax))
  (:report (lambda (condition stream)
             (let ((syntax (build-error-syntax condition)))
               (if syntax
                   (let ((location (verona:syntax-start syntax)))
                     (format stream "~A:~D:~D: ~A"
                             (verona:source-name (verona:syntax-source syntax))
                             (verona:source-location-line location)
                             (verona:source-location-column location)
                             (build-error-message condition)))
                   (write-string (build-error-message condition) stream))))))

(define-condition build-parse-error (build-error) ())
(define-condition duplicate-build-target-error (build-error) ())
(define-condition unknown-build-option-error (build-parse-error) ())
(define-condition unsupported-build-option-error (build-error) ())

(defmethod verona:diagnostic-code-for ((condition build-parse-error))
  (declare (ignore condition)) "E1101")
(defmethod verona:diagnostic-code-for ((condition duplicate-build-target-error))
  (declare (ignore condition)) "E1102")
(defmethod verona:diagnostic-code-for ((condition unknown-build-option-error))
  (declare (ignore condition)) "E1103")
(defmethod verona:condition-primary-range ((condition build-error))
  (let ((syntax (build-error-syntax condition)))
    (and syntax (verona:syntax-source-range syntax))))

(defclass build-file ()
  ((source :initarg :source :reader build-file-source)
   (targets :initarg :targets :reader build-file-targets)))

(defclass build-target ()
  ((name :initarg :name :reader build-target-name)
   (root-module :initarg :root-module :reader build-target-root-module)
   (module-paths :initarg :module-paths :reader build-target-module-paths)
   ;; :NATIVE is the build-language spelling `native`; strings are LLVM
   ;; target triples.  Resolution is intentionally deferred to execution.
   (compilation-target :initarg :compilation-target
                       :reader build-target-compilation-target)
   (optimization :initarg :optimization :reader build-target-optimization)
   ;; Package versioning belongs to build metadata. It is optional for local
   ;; projects but bundled libraries declare it explicitly for releases.
   (version :initarg :version :initform nil :reader build-target-version)
   (reader-features :initarg :reader-features :initform '()
                    :reader build-target-reader-features)
   (link-options :initarg :link-options :reader build-target-link-options)))

(defclass executable-target (build-target) ())
(defclass static-library-target (build-target) ())
(defclass shared-library-target (build-target) ())

(defclass build-invocation ()
  ((target-name :initarg :target-name :reader build-invocation-target-name)
   (output-directory :initarg :output-directory
                     :reader build-invocation-output-directory)
   ;; Command-line features sit between compiler-provided and package-provided
   ;; features when this invocation resolves its selected target.
   (reader-features :initarg :reader-features :initform '()
                    :reader build-invocation-reader-features)))

(defun make-build-invocation (target-name output-directory &key (reader-features '()))
  (make-instance 'build-invocation
                 :target-name (if (build-name-p target-name)
                                  target-name
                                  (make-build-name target-name))
                 :output-directory
                 (uiop:ensure-directory-pathname
                  (uiop:ensure-absolute-pathname (pathname output-directory)
                                                 (uiop:getcwd)))
                 :reader-features reader-features))

(defun build-fail (class syntax control &rest arguments)
  (error class :syntax syntax :message (apply #'format nil control arguments)))

(defun build-list-elements (syntax description)
  (let ((datum (verona:syntax-datum syntax)))
    (unless (verona:verona-list-p datum)
      (build-fail 'build-parse-error syntax "~A must be an S-expression" description))
    (verona:verona-list-elements datum)))

(defun build-head (syntax description)
  (let ((elements (build-list-elements syntax description)))
    (unless elements
      (build-fail 'build-parse-error syntax "~A must not be empty" description))
    (let ((head (verona:syntax-datum (first elements))))
      (unless (verona:verona-name-p head)
        (build-fail 'build-parse-error syntax "~A head must be a name" description))
      (verona:verona-name-value head))))

(defun build-module-name (syntax)
  (let ((datum (verona:syntax-datum syntax)))
    (unless (verona:verona-name-p datum)
      (build-fail 'build-parse-error syntax "root must be a module name"))
    (let ((text (verona:verona-name-value datum)))
      (when (or (string= text "")
                (some (lambda (piece) (string= piece ""))
                      (uiop:split-string text :separator ".")))
        (build-fail 'build-parse-error syntax "root must be a dotted module name"))
      (apply #'verona:make-module-name
             (mapcar #'verona:make-verona-name
                     (uiop:split-string text :separator "."))))))

(defun build-string (syntax option)
  (let ((datum (verona:syntax-datum syntax)))
    (unless (stringp datum)
      (build-fail 'build-parse-error syntax "~A requires a string" option))
    datum))

(defun build-version (syntax)
  (let ((version (build-string syntax "version")))
    (when (or (string= version "") (find #\Newline version) (find #\Return version))
      (build-fail 'build-parse-error syntax "version requires a non-empty single-line string"))
    version))

(defun build-feature-names (arguments option)
  "Read one non-empty FEATURES clause as Verona identifier spellings."
  (unless arguments
    (build-fail 'build-parse-error option "features requires at least one feature name"))
  (mapcar (lambda (argument)
            (let ((datum (verona:syntax-datum argument)))
              (unless (verona:verona-name-p datum)
                (build-fail 'build-parse-error argument
                            "features requires feature names"))
              (verona:verona-name-value datum)))
          arguments))

(defun resolve-build-directory (value directory)
  (uiop:ensure-directory-pathname (merge-pathnames value directory)))

(defun parse-build-option (option directory root target optimization version reader-features
                           module-paths libraries library-paths frameworks)
  (let* ((elements (build-list-elements option "build option"))
         (head (build-head option "build option"))
         (arguments (rest elements)))
    (labels ((one-argument ()
               (unless (= (length arguments) 1)
                 (build-fail 'build-parse-error option "~A requires exactly one argument" head))
               (first arguments))
             (duplicate-p (value option-name)
               (when value
                 (build-fail 'build-parse-error option "duplicate ~A option" option-name))))
      (cond
        ((string= head "root")
         (duplicate-p root "root")
         (setf root (build-module-name (one-argument))))
        ((string= head "module-path")
         (push (resolve-build-directory (build-string (one-argument) "module-path") directory)
               module-paths))
        ((string= head "target")
         (duplicate-p target "target")
         (let ((value (verona:syntax-datum (one-argument))))
           (setf target
                 (cond ((and (verona:verona-name-p value)
                             (string= (verona:verona-name-value value) "native")) :native)
                       ((stringp value) value)
                       (t (build-fail 'build-parse-error option
                                      "target requires native or a target-triple string"))))))
        ((string= head "optimize")
         (duplicate-p optimization "optimize")
         (let ((value (verona:syntax-datum (one-argument))))
           (unless (and (integerp value) (<= 0 value 3))
             (build-fail 'build-parse-error option "optimize must be an integer from 0 through 3"))
           (setf optimization value)))
        ((string= head "version")
         (duplicate-p version "version")
         (setf version (build-version (one-argument))))
        ((string= head "features")
         (duplicate-p reader-features "features")
         (setf reader-features (build-feature-names arguments option)))
        ((string= head "library")
         (push (build-string (one-argument) "library") libraries))
        ((string= head "library-path")
         (push (resolve-build-directory (build-string (one-argument) "library-path") directory)
               library-paths))
        ((string= head "framework")
         (push (build-string (one-argument) "framework") frameworks))
        (t (build-fail 'unknown-build-option-error option "unknown build option ~A" head))))
    (values root target optimization version reader-features
            module-paths libraries library-paths frameworks)))

(defun artifact-target-class (head syntax)
  (cond ((string= head "executable") 'executable-target)
        ((string= head "static-library") 'static-library-target)
        ((string= head "shared-library") 'shared-library-target)
        (t (build-fail 'build-parse-error syntax "unknown top-level build form ~A" head))))

(defun parse-artifact (syntax directory)
  (let* ((elements (build-list-elements syntax "artifact declaration"))
         (head (build-head syntax "artifact declaration"))
         (class (artifact-target-class head syntax))
         (arguments (rest elements)))
    (unless (>= (length arguments) 1)
      (build-fail 'build-parse-error syntax "~A requires a target name" head))
    (let ((name-datum (verona:syntax-datum (first arguments))))
      (unless (verona:verona-name-p name-datum)
        (build-fail 'build-parse-error (first arguments) "build target name must be a name"))
      (let ((root nil) (target nil) (optimization nil) (version nil) (reader-features nil)
            (module-paths '()) (libraries '()) (library-paths '()) (frameworks '()))
        (dolist (option (rest arguments))
          (multiple-value-setq (root target optimization version reader-features
                                     module-paths libraries library-paths frameworks)
            (parse-build-option option directory root target optimization version reader-features module-paths
                                libraries library-paths frameworks)))
        (unless root
          (build-fail 'build-parse-error syntax "~A target ~A requires exactly one root option"
                      head (verona:verona-name-value name-datum)))
        (make-instance class
                       :name (make-build-name (verona:verona-name-value name-datum))
                       :root-module root
                       :module-paths (or (nreverse module-paths) (list directory))
                       :compilation-target (or target :native)
                       :optimization (or optimization 0)
                       :version version
                       :reader-features reader-features
                       :link-options (make-link-options
                                      :libraries (nreverse libraries)
                                      :library-search-paths (nreverse library-paths)
                                      :frameworks (nreverse frameworks)))))))

(defun parse-build-source (source &key directory)
  "Parse declarative build syntax from SOURCE without Verona evaluation."
  (check-type source verona:source)
  (let* ((directory (uiop:ensure-directory-pathname
                     (or directory
                         (uiop:pathname-directory-pathname
                          (pathname (verona:source-name source))))))
         (targets (mapcar (lambda (form) (parse-artifact form directory))
                          (verona:read-source source))))
    (let ((seen '()))
      (dolist (target targets)
        (when (find (build-target-name target) seen :test #'build-name=
                    :key #'build-target-name)
          (build-fail 'duplicate-build-target-error nil "duplicate build target ~A"
                      (build-name-value (build-target-name target))))
        (push target seen)))
    (make-instance 'build-file :source source :targets targets)))

(defun parse-build-file (pathname)
  (let* ((path (pathname pathname))
         (source (verona:source-from-file path)))
    (parse-build-source source :directory (uiop:pathname-directory-pathname path))))

(defun find-build-target (file name)
  (let ((name (if (build-name-p name) name (make-build-name name))))
    (find name (build-file-targets file) :key #'build-target-name :test #'build-name=)))

(defun build-target-artifact-kind (target)
  (cond ((typep target 'executable-target) :executable)
        ((typep target 'static-library-target) :static-library)
        ((typep target 'shared-library-target) :shared-library)
        (t (error "unknown build target class ~S" (class-of target)))))

(defun llvm-optimization-level (level)
  (ecase level (0 :none) (1 :less) (2 :default) (3 :aggressive)))

(defun resolve-build-target (target &key (reader-features '()))
  (resolve-compilation-target
   :triple (and (stringp (build-target-compilation-target target))
                (build-target-compilation-target target))
   ;; Preserve the public feature layering: compiler features are supplied by
   ;; RESOLVE-COMPILATION-TARGET, then invocation flags, then package flags.
   :reader-features (append reader-features (build-target-reader-features target))))

(defun validate-build-target (target compilation-target)
  (when (and (link-options-frameworks (build-target-link-options target))
             (not (eq (compilation-target-platform compilation-target) :darwin)))
    (error 'unsupported-build-option-error
           :message "frameworks are supported only on Darwin targets"))
  target)

(defun root-module-pathname (target)
  (let ((filename (format nil "~A.vrn"
                         (verona:module-name-string (build-target-root-module target)))))
    (or (find-if #'probe-file
                 (mapcar (lambda (directory) (merge-pathnames filename directory))
                         (build-target-module-paths target)))
        (error 'build-error :message (format nil "cannot find root module ~A"
                                             (verona:module-name-string
                                              (build-target-root-module target)))))))

(defun execute-build (file invocation &key toolchain)
  "Translate FILE and INVOCATION into one CompilerDriver request."
  (check-type file build-file)
  (check-type invocation build-invocation)
  (let ((target (find-build-target file (build-invocation-target-name invocation))))
    (unless target
      (error 'build-error :message (format nil "unknown build target ~A"
                                           (build-name-value
                                            (build-invocation-target-name invocation)))))
    (let* ((compilation-target
             (resolve-build-target target
                                   :reader-features (build-invocation-reader-features invocation)))
           (output-directory (build-invocation-output-directory invocation))
           (kind (build-target-artifact-kind target)))
      (validate-build-target target compilation-target)
      (ensure-directories-exist (merge-pathnames ".vrn-output" output-directory))
      (let* ((root (root-module-pathname target))
             (driver (make-compiler-driver
                      :search-paths (build-target-module-paths target)
                      :target compilation-target
                      :optimization-level (llvm-optimization-level
                                           (build-target-optimization target))
                      :toolchain (or toolchain (make-native-toolchain))))
             (output (default-output-path
                      (merge-pathnames (build-name-value (build-target-name target))
                                       output-directory)
                      kind compilation-target)))
        (compile-root driver root :artifact-kind kind :output output
                      :link-options (build-target-link-options target))))))

(defun locate-build-file (&optional (directory (uiop:getcwd)))
  (let ((path (merge-pathnames "verona.build" (uiop:ensure-directory-pathname directory))))
    (or (probe-file path)
        (error 'build-error :message (format nil "cannot find verona.build in ~A" directory)))))
