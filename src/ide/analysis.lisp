(in-package #:verona.ide)

;; A loader belongs to one explicit action. Inputs are copied before compiler
;; code runs, and publication still goes through the session's generation gates.
(defclass analysis-loader (verona::module-loader)
  ((store :initarg :store :reader analysis-store)
   (id :initarg :id :reader analysis-id)
   (request :initarg :request :reader analysis-request)
   (configuration :initarg :configuration :reader analysis-configuration)
   (inputs :initarg :inputs :reader analysis-inputs)
   (entry :initarg :entry :reader analysis-entry)
   (progress :initarg :progress :reader analysis-progress)
   (paths :initform (make-hash-table :test 'equal) :reader analysis-paths)
   (requests :initform nil :accessor analysis-requests)))

(define-condition abandoned-analysis (error) ())

(defun check-analysis (loader)
  (serialized ((analysis-store loader))
    (let ((s (gethash (analysis-id loader)
                      (session-store-sessions (analysis-store loader)))))
      (unless (and s (current-request-state s (analysis-request loader)))
        (error 'abandoned-analysis)))))

(defun analysis-input (loader path)
  (or (gethash (namestring path) (analysis-inputs loader))
      (serialized ((analysis-store loader))
        (let ((source (read-source-in-session
                       (require-session (analysis-store loader) (analysis-id loader)) path)))
          (setf (gethash (source-id source) (analysis-inputs loader))
                (%source :id (source-id source) :path (source-path source)
                         :module (source-module source) :revision (source-revision source)
                         :text (source-text source)))))))

(defun analysis-phase (loader request phase &rest arguments)
  (check-analysis loader)
  (prog1 (apply #'record-phase (analysis-store loader) (analysis-id loader) request phase arguments)
    (when (analysis-progress loader) (funcall (analysis-progress loader) request phase))
    (check-analysis loader)))

(defun analysis-module-key (loader module)
  (let* ((path (verona::module-pathname module))
         (input (gethash (namestring path) (analysis-inputs loader))))
    (list (or (and input (source-module input))
              (and input (null (source-path input)) (source-id input))
              (pathname-name path))
          (if input (source-id input) (namestring path)))))

(defun module-import-edges (loader module)
  (mapcar (lambda (import)
            (let ((target (verona::import-module import)))
              (list :kind :import
                    :target (analysis-module-key loader target)
                    :alias (verona::import-alias import)
                    :location (verona::import-source import) :cycle-policy :forbidden)))
          (verona::module-imports module)))

(defun record-inspection (loader request kind value)
  (check-analysis loader)
  (serialized ((analysis-store loader))
    (let ((state (current-request-state
                  (require-session (analysis-store loader) (analysis-id loader)) request)))
      (when state
        (ecase kind
          (:expansion (push value (module-evaluation-expansion-steps state)))
          (:type (push value (module-evaluation-expression-types state))))))))

(defun record-expansion-step (loader invocation expanded)
  (let* ((name (verona::source-name (verona::syntax-source invocation)))
         (request (find name (analysis-requests loader) :test #'equal
                        :key (lambda (r)
                               (let ((id (request-source-id r)))
                                 (if (stringp id) id (format nil "<buffer ~A>" (second id))))))))
    (when request (record-inspection loader request :expansion (list invocation expanded)))))

(defun analysis-products (module)
  (list :expanded-forms (mapcar #'verona:declaration-expanded-syntax
                               (verona::module-declarations module))
        :macros (remove-if-not (lambda (d) (typep d 'verona::macro-declaration))
                              (verona::module-declarations module))
        :bindings (verona::module-environment module)))

(defun analysis-diagnostic (condition &optional loader request)
  (let* ((diagnostic
           (or (verona:diagnostic-for-condition condition)
               (verona:make-diagnostic :severity :error :code "IDE0001"
                                       :message (princ-to-string condition))))
         (prerequisites
           (and loader
                (loop for other in (analysis-requests loader)
                      when (and (not (eq request other)) (eq :failed (request-status other)))
                        collect (request-source-id other)))))
    (let* ((syntax (ignore-errors (slot-value condition 'verona::syntax)))
           (origin (and (typep syntax 'verona::syntax)
                        (or (verona::syntax-expansion-origin syntax)
                            (and loader request
                                 (serialized ((analysis-store loader))
                                   (let ((state (current-request-state
                                                 (require-session (analysis-store loader) (analysis-id loader)) request)))
                                     (loop for step in (and state (module-evaluation-expansion-steps state))
                                           for expanded = (second step)
                                           when (and (eq (verona::syntax-source expanded) (verona::syntax-source syntax))
                                                     (<= (verona::source-location-offset (verona::syntax-start expanded))
                                                         (verona::source-location-offset (verona::syntax-start syntax)))
                                                     (>= (verona::source-location-offset (verona::syntax-end expanded))
                                                         (verona::source-location-offset (verona::syntax-end syntax))))
                                             return (verona::syntax-expansion-origin expanded)))))))))
      (when origin
        (setf diagnostic (copy-structure diagnostic))
        (setf (verona::diagnostic-secondary-locations diagnostic)
              (append (verona::diagnostic-secondary-locations diagnostic)
                      (loop for current = origin then (verona::expansion-origin-parent-origin current)
                            while current append
                              (remove nil (list (verona::syntax-source-range (verona::expansion-origin-invocation current))
                                                (let ((macro (verona::expansion-origin-macro current)))
                                                  (when (typep macro 'verona::syntax)
                                                    (verona::syntax-source-range macro))))))))))
    (if prerequisites
        (let ((copy (copy-structure diagnostic)))
          (setf (verona:diagnostic-data copy)
                (append (copy-value (verona:diagnostic-data copy))
                        (list :prerequisite-failures (copy-value prerequisites))))
          copy)
        diagnostic)))

(defun analysis-find-path (loader name)
  ;; Freeze misses as well as hits: creating a file midway through an action
  ;; must not silently add a new prerequisite to its captured source view.
  (let ((text (verona::module-name-string name)))
    (multiple-value-bind (path found) (gethash text (analysis-paths loader))
      (if found path
          (setf (gethash text (analysis-paths loader))
                (loop for root in (verona::module-loader-search-paths loader)
                      for path = (merge-pathnames (format nil "~A.vrn" text) root)
                      when (or (gethash (namestring path) (analysis-inputs loader)) (probe-file path))
                        return (canonical-path path (configuration-root (analysis-configuration loader)))))))))

(defun capture-analysis-inputs (loader)
  "Freeze the source closure before invoking compiler callbacks. Import discovery
uses the compiler's reader and import-name parser, including reader features."
  (let ((seen (make-hash-table :test 'equal)))
    (labels ((capture (path)
               (check-analysis loader)
               (let ((input (analysis-input loader path)))
                 (unless (gethash (source-id input) seen)
                   (setf (gethash (source-id input) seen) t)
                   ;; Invalid source is diagnosed by the real reading phase;
                   ;; retaining its input here is sufficient for consistency.
                   (let ((forms (handler-case
                                    (verona:read-source (verona:make-source (namestring path) (source-text input))
                                                        :features (verona::module-loader-features loader))
                                  (verona:user-compilation-error () nil))))
                     (dolist (form forms)
                       (when (string= (or (verona::top-level-form-head form) "") "import")
                         (let ((name (handler-case
                                         (verona::parse-module-name
                                          (second (verona::verona-list-elements (verona:syntax-datum form))))
                                       (verona::module-error () nil)
                                       (type-error () nil))))
                           (when name
                             (let ((dependency (analysis-find-path loader name)))
                               (when dependency (capture dependency))))))))))))
      (capture (analysis-entry loader)))))

(defun record-analysis-environments (loader request)
  (serialized ((analysis-store loader))
    (let* ((s (require-session (analysis-store loader) (analysis-id loader)))
           (state (current-request-state s request)))
      (when state
        (setf (module-evaluation-dependency-environments state)
              (loop for entry in (verona::module-loader-loaded-modules loader)
                    for key = (analysis-module-key loader (cdr entry))
                    for dependency = (gethash key (session-modules s))
                    when (and dependency (not (equal (second key) (request-source-id request)))) collect
                      (list :module key :source-revision (module-evaluation-source-revision dependency)
                            :configuration-revision (module-evaluation-configuration-revision dependency)
                            :generation (module-evaluation-generation dependency))))))))

(defun record-import-attempt (loader request form)
  (let* ((name (verona::parse-module-name
                (second (verona::verona-list-elements (verona:syntax-datum form)))))
         (text (verona::module-name-string name))
         (path (analysis-find-path loader name))
         (input (and path (gethash (namestring path) (analysis-inputs loader))))
         (candidates (if path (list path)
                         (mapcar (lambda (root)
                                   (merge-pathnames (format nil "~A.vrn" text) root))
                                 (verona::module-loader-search-paths loader)))))
    (record-dependencies
     (analysis-store loader) (analysis-id loader) request
     (mapcar (lambda (candidate)
               (list :kind :import
                     :target (list (or (and input (source-module input)) (pathname-name candidate))
                                   (if input (source-id input) (namestring candidate)))
                     :location form :unresolved (null path)
                     :lookup-context (configuration-search-paths (analysis-configuration loader))
                     :cycle-policy :forbidden)) candidates))))

(defun originating-definition (module syntax)
  (find-if (lambda (declaration)
             (let ((form (verona:declaration-source declaration)))
               (and (eq (verona:syntax-source form) (verona:syntax-source syntax))
                    (<= (verona:source-location-offset (verona:syntax-start form))
                        (verona:source-location-offset (verona:syntax-start syntax)))
                    (>= (verona:source-location-offset (verona:syntax-end form))
                        (verona:source-location-offset (verona:syntax-end syntax))))))
           (verona::module-declarations module)))

(defun record-macro-use (loader request module macro syntax)
  (check-analysis loader)
  (let ((source (verona::verona-macro-source macro)))
    (when (and source (eq (verona:syntax-source syntax) (verona::module-source module)))
      (dolist (candidate (cons module (mapcar #'cdr (verona::module-loader-loaded-modules loader))))
        (let ((declaration
                (find-if (lambda (d)
                           (or (eq source (verona:declaration-source d))
                               (eq source (verona:declaration-expanded-syntax d))))
                         (verona::module-declarations candidate))))
          (when declaration
            (record-dependencies
             (analysis-store loader) (analysis-id loader) request
             (list (list :kind :macro :target (analysis-module-key loader candidate)
                         :from (let ((origin (originating-definition module syntax)))
                                 (and origin (verona::verona-name-value (verona::declaration-name origin))))
                         :to (verona::verona-name-value (verona::declaration-name declaration)) :location syntax)))))))))

(defun expanded-reference-p (syntax declaration)
  (or (verona::syntax-expansion-origin syntax)
      (and declaration
           (loop for origin = (verona::syntax-expansion-origin
                               (verona:declaration-expanded-syntax declaration))
                   then (verona::expansion-origin-parent-origin origin)
                 while origin thereis (verona::expansion-origin-macro origin)))))

(defun attribute-macro-origins (loader request module)
  ;; A top-level macro runs before its generated declaration is registered.
  ;; Fill its originating definition once that declaration becomes available.
  (serialized ((analysis-store loader))
    (let ((s (require-session (analysis-store loader) (analysis-id loader))))
      (when (current-request-state s request)
        (dolist (edge (gethash (request-module-key request) (session-dependencies s)))
          (when (and (eq :macro (getf edge :kind)) (null (getf edge :from)))
            (let ((origin (originating-definition module (getf edge :location))))
              (when origin
                (setf (getf edge :from) (verona::verona-name-value (verona::declaration-name origin)))))))))))

(defun record-semantic-use (loader request module scope syntax)
  (check-analysis loader)
  ;; The shared resolver walks dependency bodies too. Their own evaluations
  ;; own those edges; only publish references belonging to this module.
  (when (eq module (verona::semantic-scope-owning-module scope))
    (let* ((name (verona:syntax-datum syntax))
           (qualified (verona::qualified-name-p name))
           (import (and qualified
                        (verona::module-find-import
                         module (verona::make-verona-name
                                 (verona::module-name-string (verona::qualified-name-qualifier name))))))
           (target (if import (verona::import-module import) module))
           (member (if qualified (verona::qualified-name-name name) name))
           (operation (and (not qualified) (verona::verona-name-p member)
                           (verona::find-constrained-protocol-operation scope member)))
           (declaration (if operation
                            (verona::protocol-declaration (verona::protocol-operation-protocol operation))
                            (if import (verona::module-find-export target member)
                            (and (verona::verona-name-p member)
                                 (verona::find-declaration target member)))))
           (origin (originating-definition module syntax))
           (binding (and (not qualified) (verona::verona-name-p member)
                         (verona::semantic-scope-find scope member)))
           (found (and (not qualified) (verona::verona-name-p member)
                       (nth-value 1 (verona::semantic-scope-find scope member)))))
      (when (typep binding '(or verona::parameter-binding verona::let-binding
                               verona::pattern-binding verona::type-parameter))
        (setf declaration nil))
      (when (or declaration qualified (and (verona::verona-name-p member) (not found)))
        (when operation (setf target (verona::declaration-module declaration)))
        (record-dependencies
         (analysis-store loader) (analysis-id loader) request
         (list (list :kind (if (expanded-reference-p syntax origin) :expanded :semantic)
                     :target (analysis-module-key loader target)
                     :from (and origin (verona::verona-name-value (verona::declaration-name origin)))
                     :to (if operation (verona::verona-name-value (verona::declaration-name declaration))
                             (and (verona::verona-name-p member) (verona::verona-name-value member)))
                     :location syntax :unresolved (null declaration)
                     :lookup-context (analysis-module-key loader module))))))))

(defun fail-analysis-module (loader request phase condition &key module program)
  (when module
    (attribute-macro-origins loader request module)
    (record-dependencies (analysis-store loader) (analysis-id loader) request
                         (module-import-edges loader module)))
  (analysis-phase loader request phase :failed t :complete nil
                  :products (case phase
                              (:expansion (and module (analysis-products module)))
                              (:resolution (and program
                                                (list :resolved-definitions
                                                      (analysis-definitions program module))))
                              (:type-checking (list :types program)))
                  :diagnostics (list (analysis-diagnostic condition loader request))))

(defun analysis-definitions (program module)
  (remove-if-not (lambda (entry) (eq module (verona::declaration-module (car entry))))
                 (verona::semantic-program-declarations program)))

(defun collect-analysis-module (loader name path input prerequisite-error)
  (let* ((store (analysis-store loader)) (id (analysis-id loader))
         (request (if (equal (source-id input) (request-source-id (analysis-request loader)))
                      (analysis-request loader)
                      (%begin-request store id input :parent (analysis-request loader))))
         (phase :reading) (module nil) (syntax nil))
    (push request (analysis-requests loader))
    (handler-case
        (let* ((source-id (source-id input))
               (source (verona:make-source (if (stringp source-id) source-id
                                              (format nil "<buffer ~A>" (second source-id)))
                                          (source-text input)))
               (forms (progn
                        (analysis-phase loader request :reading :complete nil)
                        (let ((verona::*read-observer*
                                (lambda (form)
                                  (push form syntax)
                                  (analysis-phase loader request :reading :complete nil
                                                  :products (list :syntax (reverse syntax))))))
                          (verona:read-source source :features (verona::module-loader-features loader))))))
          (analysis-phase loader request :reading :products (list :syntax forms))
          (setf phase :expansion
                module (make-instance 'verona::module :name name :pathname path :source source :forms forms
                                      :environment (verona::make-compilation-environment)))
          (when prerequisite-error (error prerequisite-error))
          (let ((verona::*collection-observer*
                  (lambda (stage current form)
                    (check-analysis loader)
                    (when (eq stage :form)
                      (analysis-phase loader request :expansion :complete nil
                                      :products (analysis-products current)))
                    (when (eq stage :collected)
                      (attribute-macro-origins loader request current)
                      (record-dependencies store id request (module-import-edges loader current)))
                    (when (and (eq stage :form)
                               (string= (or (verona::top-level-form-head form) "") "import"))
                      (handler-case (record-import-attempt loader request form)
                        (verona::module-error () nil)
                        (type-error () nil)))))
                (verona::*expansion-observer*
                  (lambda (before after) (record-expansion-step loader before after)))
                (verona::*macro-observer*
                  (lambda (macro syntax) (record-macro-use loader request module macro syntax))))
            (verona::collect-module module loader))
          (record-dependencies store id request (module-import-edges loader module))
          (analysis-phase loader request :expansion :products (analysis-products module))
          (setf phase :declarations)
          (analysis-phase loader request :declarations
                          :products (list :declarations (verona::module-declarations module)
                                          :imports (verona::module-imports module)
                                          :exports (verona::module-exports module)))
          (push (cons name module) (verona::module-loader-loaded-modules loader))
          module)
      (abandoned-analysis (c) (error c))
      (error (c)
        (fail-analysis-module loader request phase c :module module)
        (error c)))))

(defmethod verona::module-loader-load ((loader analysis-loader) name)
  (check-analysis loader)
  (when (member name (verona::module-loader-loading-stack loader) :test #'verona::module-name=)
    (error 'verona::circular-module-dependency :module name
           :cycle (append (verona::module-loader-loading-stack loader) (list name))))
  (or (verona::module-loader-find loader name)
      (let* ((entry-p (verona::module-name= name (verona::module-name-from-pathname (analysis-entry loader))))
             (path (if entry-p (analysis-entry loader) (analysis-find-path loader name)))
             (input (and path (analysis-input loader path))))
        (unless input (error 'verona::module-not-found :module name))
        (let* ((store (analysis-store loader)) (id (analysis-id loader))
               (cached (serialized (store)
                         (gethash (source-id input) (session-environments (require-session store id)))))
               (prerequisite-error nil)
               (old-stack (verona::module-loader-loading-stack loader)))
          (unwind-protect
               (progn
                 (setf (verona::module-loader-loading-stack loader) (append old-stack (list name)))
                 ;; Every action walks imports, even when their owning module
                 ;; is reusable, so changes anywhere in the closure are seen.
                 (when (and (not entry-p) cached
                            (= (first cached) (source-revision input))
                            (= (second cached) (request-configuration-revision (analysis-request loader)))
                            (eq :complete (getf (module-state store id (source-id input)) :status)))
                   (handler-case
                       (let ((module (third cached)))
                         (when (every (lambda (import)
                                        (eq (verona::import-module import)
                                            (verona::module-loader-load loader
                                             (verona::module-name (verona::import-module import)))))
                                      (verona::module-imports module))
                           (push (cons name module) (verona::module-loader-loaded-modules loader))
                           (return-from verona::module-loader-load module)))
                     (abandoned-analysis (c) (error c))
                     (error (c) (setf prerequisite-error c))))
                 (collect-analysis-module loader name path input prerequisite-error))
            (setf (verona::module-loader-loading-stack loader) old-stack))))))

(defun analysis-module-request (loader module)
  (find (second (analysis-module-key loader module)) (analysis-requests loader)
        :test #'equal :key #'request-source-id))

(defun analysis-graph-order (entry &key dependencies-first)
  (let ((seen nil) (modules nil))
    (labels ((visit (module)
               (unless (member module seen)
                 (push module seen)
                 (unless dependencies-first (push module modules))
                 ;; REGISTER-IMPORT stores imports in reverse source order.
                 (dolist (import (reverse (verona::module-imports module)))
                   (visit (verona::import-module import)))
                 (when dependencies-first (push module modules)))))
      (visit entry))
    (if dependencies-first (nreverse modules) modules)))

(defun resolve-analysis-graph (loader entry)
  ;; Keep one shared semantic/type context, exactly as project compilation does.
  ;; Resolving each dependency in isolation can change generic/protocol semantics.
  (let* ((store (analysis-store loader)) (id (analysis-id loader))
         (modules (analysis-graph-order entry))
         (program nil) (phase :resolution))
    (labels ((scope-context (scope syntax)
               (let* ((module (verona::semantic-scope-owning-module scope))
                      (request (and module (analysis-module-request loader module))))
                 (when request
                   (serialized (store)
                     (let ((state (current-request-state (require-session store id) request)))
                       (when state
                         (push (list syntax
                                     (loop for current = scope then (verona::semantic-scope-parent current)
                                           while current append (copy-list (verona::semantic-scope-bindings current)))
                                     (let ((function (verona::semantic-scope-owning-function scope)))
                                       (when (typep function 'verona::semantic-function-declaration)
                                         (loop for constraint in (verona::semantic-function-declaration-constraints function)
                                               append (verona::protocol-operations (verona::protocol-constraint-protocol constraint))))))
                               (module-evaluation-navigation-contexts state))))))))
             (reference (scope syntax)
               (let* ((module (verona::semantic-scope-owning-module scope))
                      (request (and module (analysis-module-request loader module))))
                 (when request (record-semantic-use loader request module scope syntax))))
             (macro-use (macro syntax)
               (let* ((module (find (verona:syntax-source syntax) modules :key #'verona::module-source))
                      (request (and module (analysis-module-request loader module))))
                 (when request (record-macro-use loader request module macro syntax))))
             (progress (stage value)
               (setf program value)
               (dolist (module modules)
                 (let ((request (analysis-module-request loader module)))
                   (when request
                     (analysis-phase loader request :resolution :complete (eq stage :resolution)
                                     :products (list :resolved-definitions (analysis-definitions program module))))))
               (when (eq stage :resolution)
                 (setf phase :type-checking)
                 (dolist (module modules)
                   (let ((request (analysis-module-request loader module)))
                     (when request
                       (analysis-phase loader request :type-checking :complete nil
                                       :products (list :types program))))))))
      (handler-case
          (progn
            (dolist (request (analysis-requests loader)) (record-analysis-environments loader request))
            (let ((verona::*expansion-observer*
                    (lambda (before after) (record-expansion-step loader before after)))
                  (verona::*expression-observer*
                    (lambda (scope syntax expression)
                      (let ((request (analysis-module-request loader (verona::semantic-scope-owning-module scope))))
                        (when request (record-inspection loader request :type (list syntax expression))))))
                  (verona::*reference-observer* #'reference)
                  (verona::*scope-observer* #'scope-context)
                  (verona::*macro-observer* #'macro-use)
                  (verona::*analysis-observer* #'progress))
              (setf program
                    (verona::resolve-program
                     entry modules :publish-modules nil :target (configuration-target (analysis-configuration loader))
                     :pointer-width (getf (configuration-target (analysis-configuration loader)) :pointer-width 64))))
            ;; Dependency-first publication leaves the requested module current
            ;; against precisely the prerequisite environments in this action.
            (dolist (module (analysis-graph-order entry :dependencies-first t))
              (let ((request (analysis-module-request loader module)))
                (when request
                  (analysis-phase loader request :type-checking :products (list :types program))
                  ;; The compiler's ordinary attachment mutates module objects.
                  ;; Reused modules must stay untouched by a superseded action.
                  (serialized (store)
                    (let ((s (require-session store id)))
                      (when (current-request-state s request)
                        (setf (verona::compilation-unit-semantic-program module) program))))
                  (publish-result store id request module)
                  (serialized (store)
                    (let ((s (require-session store id)))
                      (when (and (= (request-generation request) (session-generation s))
                                 (eq :complete (request-status request)))
                        (setf (gethash (request-source-id request) (session-environments s))
                              (list (request-source-revision request) (request-configuration-revision request) module))))))))
            entry)
        (abandoned-analysis (c) (error c))
        (error (c)
          (dolist (module modules)
            (let ((request (analysis-module-request loader module)))
              (when (and request (eq :pending (request-status request)))
                (fail-analysis-module loader request phase c :module module :program program))))
          (error c))))))

(defun fail-unfinished-analysis (loader condition)
  ;; Collection can fail after another prerequisite has already reached the
  ;; declarations boundary. Release every remaining request in this action.
  (dolist (request (analysis-requests loader))
    (when (eq :pending (request-status request))
      (let* ((state (module-state (analysis-store loader) (analysis-id loader) (request-source-id request)))
             (phase (nth (length (getf state :completed-phases)) +module-phases+)))
        (fail-analysis-module loader request (or phase :type-checking) condition)))))

(defun evaluate-request (store id request &key progress)
  "Run an already submitted evaluation. Returns REQUEST, including on failure.
Cancellation and supersession use the ordinary request API from another thread."
  (let* ((verona::*read-observer* nil) (verona::*collection-observer* nil)
         (verona::*macro-observer* nil) (verona::*reference-observer* nil)
         (verona::*analysis-observer* nil)
         (configuration nil) (inputs (make-hash-table :test 'equal)) (entry nil))
    (serialized (store)
      (let ((s (require-session store id)))
        (unless (current-request-state s request) (return-from evaluate-request request))
        (setf configuration (configuration-value (session-configuration s)))
        (maphash (lambda (key source)
                   (when (or (equal key (request-source-id request))
                             (loop for value being the hash-values of (session-buffers s)
                                   thereis (equal value key)))
                     (setf (gethash key inputs)
                         (%source :id key :path (source-path source) :module (source-module source)
                                  :revision (source-revision source) :text (source-text source)))))
                 (session-sources s))
        (let ((input (or (gethash (request-source-id request) inputs)
                         (%source :id (request-source-id request) :path (request-source-path request)
                                  :module (request-module request)))))
          (setf (%source-text input) (copy-seq (request-text request))
                (%source-revision input) (request-source-revision request)
                entry (or (source-path input)
                          (merge-pathnames "__buffer__.vrn" (configuration-root configuration))))
          (setf (gethash (namestring entry) inputs) input))))
    (let ((loader (make-instance 'analysis-loader :store store :id id :request request
                                :configuration configuration :inputs inputs :entry entry :progress progress
                                :search-paths (remove-duplicates
                                               (cons (uiop:pathname-directory-pathname entry)
                                                     (configuration-search-paths configuration)) :test #'equal)
                                :features (configuration-reader-features configuration))))
      (handler-case
          (progn
            (capture-analysis-inputs loader)
            (resolve-analysis-graph
             loader (verona::module-loader-load loader (verona::module-name-from-pathname entry))))
        (abandoned-analysis () nil)
        (error (c)
          (fail-unfinished-analysis loader c)
          (when (eq :pending (request-status request))
            (publish-result store id request nil :failed t
                            :diagnostics (list (analysis-diagnostic c loader request))))))
      request)))

(defun evaluate-module (store id source)
  "Explicitly analyze SOURCE (a session source record or file path) and imports.
No application bodies are executed and no build artifacts are emitted."
  (let* ((failure nil)
         (path (if (typep source 'source-record) (source-path source) source))
         (input (handler-case
                    (if path (read-source store id path) source)
                  (file-error (condition)
                    (setf failure condition)
                    (serialized (store)
                      (let* ((s (require-session store id)) (key (source-key s path)))
                        (or (gethash key (session-sources s))
                            (record-source s key (pathname key) nil "")))))))
         (request (begin-request store id input)))
    (if failure
        (progn (record-phase store id request :reading :failed t
                             :diagnostics (list (analysis-diagnostic failure)))
               request)
        (evaluate-request store id request))))
