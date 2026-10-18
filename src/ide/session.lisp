(defpackage #:verona.ide
  (:use #:cl)
  (:export #:request-error #:make-configuration #:configuration #:configuration-root
           #:configuration-build-file #:configuration-build-target
           #:configuration-search-paths #:configuration-package-locations
           #:configuration-target #:configuration-reader-features
           #:make-session-store #:create-session #:find-session #:inspect-session
           #:configure-session #:reset-session #:close-session #:expire-sessions
           #:attach-session #:detach-session #:session-id
           #:open-buffer #:edit-buffer #:save-buffer #:rename-buffer #:close-buffer
           #:source-record #:source-id #:source-revision #:source-text
           #:source-module #:source-path #:read-source
           #:begin-request #:cancel-request #:publish-result #:query-result
           #:request-status #:request-source-id #:request-source-revision
           #:request-text #:request-module #:request-configuration-revision #:request-session-id
           #:source-state #:module-state #:record-phase #:result-session-id
           #:result-value #:result-source-id #:result-source-revision #:result-module
           #:result-configuration-revision
           #:discover-modules #:list-modules #:inspect-module #:module-contents
           #:module-relationships #:module-diagnostics #:project-diagnostics
           #:inspect-expansion #:type-at-position
           #:list-definitions #:find-definitions #:inspect-definition
           #:definition-type-structure #:definition-relationships
           #:position-context #:complete-names #:signature-help #:go-to-definition
           #:find-references #:related-definitions
           #:evaluate-module #:evaluate-request #:build-inputs #:record-dependencies #:dependency-graph #:dependency-cycles))
(in-package #:verona.ide)

(define-condition request-error (simple-error) ())
(defun reject-request (control &rest arguments)
  "Reject an invalid API request without disguising implementation failures."
  (error 'request-error :format-control control :format-arguments arguments))

(defstruct (configuration (:constructor %configuration))
  (root nil :read-only t) (build-file nil :read-only t)
  (build-target nil :read-only t) (search-paths nil :read-only t)
  (package-locations nil :read-only t) (target nil :read-only t)
  (reader-features nil :read-only t))

(defun canonical-path (path root)
  (let ((absolute (merge-pathnames path root)))
    (or (probe-file absolute)
        (merge-pathnames (file-namestring absolute)
                         (truename (uiop:pathname-directory-pathname absolute))))))

(defun make-configuration (&key (root (uiop:getcwd)) build-file build-target
                                (search-paths nil search-paths-p) package-locations target
                                (reader-features nil reader-features-p))
  "Explicit values replace discovered defaults. TARGET is a portable target descriptor."
  (let ((root (truename (uiop:ensure-directory-pathname root))))
    (%configuration :root root
                    :build-file (and build-file (canonical-path build-file root))
                    :build-target build-target
                    :search-paths (mapcar (lambda (p) (canonical-path p root))
                                         (if search-paths-p search-paths (list root)))
                    :package-locations (copy-tree package-locations)
                    :target (copy-tree target)
                    :reader-features (copy-list (if reader-features-p reader-features
                                                   (verona:target-feature-names target))))))

(defun copy-value (value)
  (typecase value
    (cons (cons (copy-value (car value)) (copy-value (cdr value))))
    (string (copy-seq value))
    (t value)))

(defun configuration-value (configuration)
  (%configuration :root (configuration-root configuration)
                  :build-file (configuration-build-file configuration)
                  :build-target (copy-value (configuration-build-target configuration))
                  :search-paths (copy-list (configuration-search-paths configuration))
                  :package-locations (copy-value (configuration-package-locations configuration))
                  :target (copy-value (configuration-target configuration))
                  :reader-features (copy-value (configuration-reader-features configuration))))

(defstruct (source-record (:constructor %source) (:conc-name %source-))
  id path module (revision 0) (text ""))
(defun source-id (source) (copy-value (%source-id source)))
(defun source-path (source) (%source-path source))
(defun source-module (source) (copy-value (%source-module source)))
(defun source-revision (source) (%source-revision source))
(defun source-text (source) (copy-seq (%source-text source)))

;; Only an explicit evaluation retains its input while it is pending.
;; Results keep revision metadata, not previous source contents.
(defstruct (request (:constructor %request))
  session-id source-id source-path source-revision module module-key text
  configuration-revision generation (status :pending))
(defstruct (result (:constructor %result))
  value source-id source-revision module configuration-revision generation session-id)
(defstruct (session (:constructor %session))
  id configuration (configuration-revision 1) (generation 0) (revision 0)
  (sources (make-hash-table :test 'equal))
  (submitted (make-hash-table :test 'equal))
  (build-sources (make-hash-table :test 'equal))
  (buffers (make-hash-table :test 'equal))
  (discovered (make-hash-table :test 'equal))
  (modules (make-hash-table :test 'equal))
  (dependencies (make-hash-table :test 'equal))
  (reverse-dependencies (make-hash-table :test 'equal))
  (environments (make-hash-table :test 'equal))
  (cache (make-hash-table :test 'equal))
  (requests nil) (connections nil) (detached-at (get-universal-time)) (closed nil))
(defstruct (session-store (:constructor make-session-store ()))
  (sessions (make-hash-table :test 'equal)) (next-id 0)
  #+sb-thread (lock (sb-thread:make-mutex :name "IDE sessions")))

(defmacro serialized ((store) &body body)
  #+sb-thread `(sb-thread:with-mutex ((session-store-lock ,store)) ,@body)
  #-sb-thread `(progn ,@body))

(defvar *session-close-hooks* nil)

(defun require-session (store id)
  (or (gethash id (session-store-sessions store)) (reject-request "Unknown IDE session ~A" id)))
(defun configuration-key (configuration)
  (loop for slot in '(root build-file build-target search-paths package-locations target reader-features)
        collect (slot-value configuration slot)))
(defun create-session (store configuration)
  (serialized (store)
    (or (loop for session being the hash-values of (session-store-sessions store)
              when (equal (configuration-key configuration)
                           (configuration-key (session-configuration session))) return (session-id session))
        (let* ((id (format nil "session-~D" (incf (session-store-next-id store))))
               (session (%session :id id :configuration (configuration-value configuration))))
          (setf (gethash id (session-store-sessions store)) session) id))))
(defun find-session (store id)
  (serialized (store) (and (gethash id (session-store-sessions store)) id)))
(defun inspect-session (store id)
  (serialized (store)
    (let ((s (require-session store id)))
      (list :id id :configuration (configuration-value (session-configuration s))
            :configuration-revision (session-configuration-revision s)
            :sources (hash-table-count (session-sources s))
            :buffers (hash-table-count (session-buffers s))
            :connections (copy-list (session-connections s))))))
(defun invalidate-requests (s)
  (incf (session-generation s))
  (dolist (r (session-requests s))
    (when (eq :pending (request-status r)) (setf (request-status r) :stale (request-text r) nil))))
(defun configure-session (store id configuration)
  (serialized (store)
    (let ((s (require-session store id)))
      (unless (equal (configuration-root configuration)
                     (configuration-root (session-configuration s)))
        (reject-request "A session cannot change project root"))
      ;; Switching targets selects another session; configuring never destroys
      ;; the cached state belonging to the previously selected target.
      (unless (and (equal (configuration-target configuration)
                          (configuration-target (session-configuration s)))
                   (equal (configuration-build-target configuration)
                          (configuration-build-target (session-configuration s))))
        (reject-request "Select or create another session to switch build targets"))
      (when (loop for other being the hash-values of (session-store-sessions store)
                  thereis (and (not (eq other s))
                               (equal (configuration-key configuration)
                                       (configuration-key (session-configuration other)))))
        (reject-request "This configuration already belongs to another session"))
      (unless (equal (configuration-key configuration)
                      (configuration-key (session-configuration s)))
        (invalidate-requests s)
        (mark-modules-needing-evaluation s)
        (setf (session-configuration s) (configuration-value configuration))
        (incf (session-configuration-revision s)))
      (session-configuration-revision s))))
(defun reset-session (store id)
  (serialized (store)
    (let ((s (require-session store id)))
      (invalidate-requests s)
      (dolist (table (list (session-modules s) (session-dependencies s)
                          (session-reverse-dependencies s) (session-environments s) (session-cache s)
                          (session-submitted s))) (clrhash table))
      (setf (session-requests s) nil) id)))
(defun close-session (store id)
  (serialized (store)
    (let ((s (require-session store id)))
      (invalidate-requests s)
      (setf (session-closed s) t)
      (dolist (hook *session-close-hooks*) (funcall hook store id))
      (remhash id (session-store-sessions store)) t)))
(defun attach-session (store id connection)
  (serialized (store)
    (pushnew connection (session-connections (require-session store id)) :test #'equal) id))
(defun detach-session (store id connection)
  (serialized (store)
    (let ((s (require-session store id)))
      (setf (session-connections s) (remove connection (session-connections s) :test #'equal))
      (unless (session-connections s) (setf (session-detached-at s) (get-universal-time))) id)))
(defun expire-sessions (store &key (max-idle-seconds 86400) (now (get-universal-time)))
  "Explicit maintenance operation; detached sessions otherwise persist until close."
  (serialized (store)
    (let ((expired nil))
      (maphash (lambda (id s)
                 (when (and (null (session-connections s))
                            (>= (- now (session-detached-at s)) max-idle-seconds))
                   (invalidate-requests s) (push id expired))) (session-store-sessions store))
      (dolist (id expired)
        (dolist (hook *session-close-hooks*) (funcall hook store id))
        (remhash id (session-store-sessions store))) expired)))

(defun source-key (s path)
  (namestring (canonical-path path (configuration-root (session-configuration s)))))
(defun record-source (s key path module text)
  "Replace the latest contents without touching evaluation state."
  (let ((source (or (gethash key (session-sources s)) (%source))))
    (setf (%source-id source) (copy-value key)
          (%source-path source) path
          (%source-module source) (copy-value module)
          (%source-revision source) (incf (session-revision s))
          (%source-text source) (copy-seq text)
          (gethash key (session-sources s)) source)
    source))
(defun open-buffer (store id buffer text &key path module)
  (serialized (store)
    (let* ((s (require-session store id))
           (key (if path (source-key s path) (list :buffer buffer))))
      (when (or (gethash buffer (session-buffers s))
                (loop for value being the hash-values of (session-buffers s) thereis (equal value key)))
        (reject-request "Buffer or source already open"))
      (setf (gethash buffer (session-buffers s)) key)
      (record-source s key (and path (pathname key)) module text))))
(defun buffer-source (s buffer)
  (let ((key (gethash buffer (session-buffers s))))
    (or (and key (gethash key (session-sources s))) (reject-request "Unknown buffer ~A" buffer))))
(defun edit-buffer (store id buffer text)
  (serialized (store)
    (let* ((s (require-session store id)) (old (buffer-source s buffer)))
      (record-source s (source-id old) (source-path old) (source-module old) text))))
(defun read-source-in-session (s path)
  (let* ((key (source-key s path)) (old (gethash key (session-sources s))))
    (if (loop for value being the hash-values of (session-buffers s) thereis (equal value key))
        old
        (let ((text (uiop:read-file-string key)))
          (if (and old (string= text (source-text old))) old
              (record-source s key (pathname key) (and old (source-module old)) text))))))
(defun read-source (store id path)
  (serialized (store) (read-source-in-session (require-session store id) path)))
(defun rename-buffer-in-session (s buffer path)
  (let* ((old (buffer-source s buffer)) (key (source-key s path)))
    (when (loop for b being the hash-keys of (session-buffers s) using (hash-value value)
                thereis (and (not (equal b buffer)) (equal value key)))
      (reject-request "Destination already open"))
    (remhash (source-id old) (session-sources s))
    (setf (gethash buffer (session-buffers s)) key)
    (record-source s key (pathname key) (source-module old) (source-text old))))
(defun rename-buffer (store id buffer path)
  "Change source identity only; the editor owns filesystem renames."
  (serialized (store) (rename-buffer-in-session (require-session store id) buffer path)))
(defun save-buffer (store id buffer &key path)
  "Notify the session after the editor has saved; never write the filesystem."
  (serialized (store)
    (let* ((s (require-session store id)) (old (buffer-source s buffer))
           (destination (or path (source-path old))))
      (unless destination (reject-request "Saving an unnamed buffer requires a path"))
      (unless (string= (uiop:read-file-string (source-key s destination)) (source-text old))
        (reject-request "Saved file differs from buffer"))
      (if (equal (source-id old) (source-key s destination)) old
          (rename-buffer-in-session s buffer destination)))))
(defun close-buffer (store id buffer)
  (serialized (store)
    (let* ((s (require-session store id)) (old (buffer-source s buffer)))
      (remhash buffer (session-buffers s))
      (remhash (source-id old) (session-sources s)) t)))

(defparameter +module-phases+
  '(:reading :expansion :declarations :resolution :type-checking))
(defparameter +phase-products+
  '((:reading :syntax) (:expansion :expanded-forms :macros :bindings)
    (:declarations :declarations :imports :exports)
    (:resolution :resolved-definitions) (:type-checking :types)))

(defstruct (module-evaluation (:constructor %module-evaluation))
  identity source-id source-path source-revision configuration-revision generation dependency-environments
  (status :pending) phase completed-phases failed-phase products diagnostics diagnostic-phases reasons
  definition-identities navigation-contexts expansion-steps expression-types (dependencies-complete nil))

(defun mark-modules-needing-evaluation (s)
  ;; Configuration changes affect every module. Explicit evaluations instead
  ;; use reverse dependency traversal; source editing never calls either path.
  (maphash (lambda (key state)
             (declare (ignore key))
             (setf (module-evaluation-status state) :needs-evaluation
                   (module-evaluation-reasons state) (list (list :kind :configuration))))
           (session-modules s)))

(defun %begin-request (store id source &key parent)
  "Replace this module's current evaluation with an empty pending state."
  (serialized (store)
    (let ((s (require-session store id)))
      (unless (or parent (eq source (gethash (source-id source) (session-sources s))))
        (reject-request "Evaluation requires a source owned by this session"))
      (if parent
          (unless (current-request-state s parent) (reject-request "Evaluation action is no longer current"))
          (invalidate-requests s))
      (let* ((key (list (or (source-module source)
                           (and (source-path source) (pathname-name (source-path source)))
                           (source-id source))
                       (source-id source)))
             (r (%request :session-id id :source-id (source-id source) :source-path (source-path source)
                          :source-revision (source-revision source)
                          :module (source-module source) :module-key key
                          :text (source-text source)
                          :configuration-revision (session-configuration-revision s)
                          :generation (session-generation s))))
        (replace-module-dependencies s key (source-id source))
        ;; Drop the previous state's products and environments immediately.
        (remhash (source-id source) (session-cache s))
        (remhash (source-id source) (session-environments s))
        (dolist (old (session-requests s))
          (when (equal (request-source-id old) (source-id source))
            (remhash (request-module-key old) (session-modules s))))
        (setf (gethash key (session-modules s))
              (%module-evaluation :identity (copy-value key)
                                  :source-id (source-id source)
                                  :source-path (source-path source)
                                  :source-revision (source-revision source)
                                  :configuration-revision (session-configuration-revision s)
                                  :generation (session-generation s))
              (gethash (source-id source) (session-submitted s)) (source-revision source))
        (push r (session-requests s)) r))))

(defun begin-request (store id source)
  "Replace the selected module immediately and capture its explicit input."
  (%begin-request store id source))

(defun current-request-state (s request)
  (unless (member request (session-requests s)) (reject-request "Unknown request"))
  (when (and (eq :pending (request-status request))
             (= (request-generation request) (session-generation s)))
    (gethash (request-module-key request) (session-modules s))))

(defun record-phase (store id request phase &key (complete t) products diagnostics failed)
  "Publish a phase's current products. PRODUCTS is a plist of phase-specific values.
Partial products of a failed phase are retained and explicitly labelled incomplete."
  (serialized (store)
    (let* ((s (require-session store id)) (state (current-request-state s request)))
      (unless state (return-from record-phase (request-status request)))
      (unless (and (member phase +module-phases+)
                   (eq phase (nth (length (module-evaluation-completed-phases state)) +module-phases+)))
        (reject-request "Phases must run in order, once each"))
      (unless (and (listp products) (evenp (length products)))
        (reject-request "Products must be a property list"))
      (loop for key in products by #'cddr do
        (unless (member key (cdr (assoc phase +phase-products+)))
          (reject-request "Product ~S does not belong to ~S" key phase)))
      (setf (module-evaluation-status state) :processing
            (module-evaluation-phase state) phase)
      (loop for (key value) on products by #'cddr do
        ;; Assign once at publication, so a macro keeps its ID when it later
        ;; appears in the full declaration product. Queries never mutate this.
        (when (member key '(:declarations :macros))
          (dolist (definition value)
            (when (and (typep definition 'verona::declaration)
                       (not (assoc definition (module-evaluation-definition-identities state) :test #'eq)))
              (push (cons definition (length (module-evaluation-definition-identities state)))
                    (module-evaluation-definition-identities state)))))
        (setf (getf (module-evaluation-products state) key)
              (if (member key '(:macros :bindings))
                  (list :module (copy-value (module-evaluation-identity state))
                        :definitions (copy-value value))
                  (copy-value value))))
      (setf (module-evaluation-diagnostics state)
            (append (module-evaluation-diagnostics state) (copy-value diagnostics))
            (module-evaluation-diagnostic-phases state)
            (append (module-evaluation-diagnostic-phases state)
                    (make-list (length diagnostics) :initial-element phase)))
      (when (or failed (not complete))
        (setf (module-evaluation-dependencies-complete state) nil))
      (cond (failed
             (setf (module-evaluation-failed-phase state) phase
                   (module-evaluation-status state) :failed
                   (request-status request) :failed (request-text request) nil))
            (complete
             (setf (module-evaluation-completed-phases state)
                   (append (module-evaluation-completed-phases state) (list phase)))))
      (module-evaluation-status state))))

(defun cancel-request (store id request)
  (serialized (store)
    (let* ((s (require-session store id)) (state (current-request-state s request)))
      (when state
        ;; All pending requests in this generation belong to the same explicit
        ;; action, including prerequisites suspended beneath the selected file.
        (dolist (pending (session-requests s))
          (let ((current (current-request-state s pending)))
            (when current
              (setf (module-evaluation-status current) :cancelled
                    (request-status pending) :cancelled (request-text pending) nil))))))
    (request-status request)))

(defun publish-result (store id request value &key failed diagnostics)
  (serialized (store)
    (let* ((s (require-session store id)) (state (current-request-state s request)))
      (when state
        (when (and (not failed) (module-evaluation-phase state)
                   (not (equal +module-phases+ (module-evaluation-completed-phases state))))
          (reject-request "Complete all reported phases before successful publication"))
        (setf (gethash (request-source-id request) (session-cache s))
              (%result :session-id id :value value
                       :source-id (copy-value (request-source-id request))
                       :source-revision (request-source-revision request)
                       :module (copy-value (request-module request))
                       :configuration-revision (request-configuration-revision request)
                       :generation (session-generation s))
              (module-evaluation-dependencies-complete state)
              (and (not failed) (member :resolution (module-evaluation-completed-phases state)) t)
              (module-evaluation-status state) (if failed :failed :complete)
              (module-evaluation-reasons state) nil
              (module-evaluation-failed-phase state)
              (and failed (or (module-evaluation-phase state) :reading))
              (module-evaluation-diagnostics state)
              (append (module-evaluation-diagnostics state) (copy-value diagnostics))
              (module-evaluation-diagnostic-phases state)
              (append (module-evaluation-diagnostic-phases state)
                      (make-list (length diagnostics)
                                 :initial-element (module-evaluation-phase state)))
              (request-status request) (if failed :failed :complete)
              (request-text request) nil))
      (request-status request))))

(defun query-result (store id source-id)
  "Return only the current evaluation's result; never fall back to an older one."
  (serialized (store)
    (let* ((s (require-session store id)) (result (gethash source-id (session-cache s))))
      (values result
              (cond ((null result) :missing)
                    ((and (loop for state being the hash-values of (session-modules s)
                                thereis (and (equal source-id (module-evaluation-source-id state))
                                             (not (module-evaluation-reasons state))))
                          (= (result-configuration-revision result) (session-configuration-revision s))) :current)
                    (t :stale))))))

(defun module-state (store id source-id)
  "Return a snapshot of the current module evaluation, including partial products."
  (serialized (store)
    (let* ((s (require-session store id))
           (state (loop for state being the hash-values of (session-modules s)
                        when (equal source-id (module-evaluation-source-id state)) return state)))
      (when state
        (copy-value
         (list :identity (module-evaluation-identity state)
               :source-id (module-evaluation-source-id state)
               :source-path (module-evaluation-source-path state)
               :source-revision (module-evaluation-source-revision state)
               :configuration-revision (module-evaluation-configuration-revision state)
               :status (module-evaluation-status state)
               :phase (module-evaluation-phase state)
               :completed-phases (module-evaluation-completed-phases state)
               :failed-phase (module-evaluation-failed-phase state)
               :products (module-evaluation-products state)
               :dependency-complete (module-evaluation-dependencies-complete state)
               :dependency-environments (module-evaluation-dependency-environments state)
               :needs-evaluation-reasons (module-evaluation-reasons state)
               :diagnostics (module-evaluation-diagnostics state)))))))

(defun source-state (store id source-id)
  "Report latest contents and the single current evaluation revision."
  (serialized (store)
    (let* ((s (require-session store id))
           (current (gethash source-id (session-sources s)))
           (latest (find source-id (session-requests s) :test #'equal :key #'request-source-id)))
      (list :session-id id :source-id (copy-value source-id)
            :module (and current (source-module current))
            :current-revision (and current (source-revision current))
            :submitted-revision (gethash source-id (session-submitted s))
            :status (if latest (request-status latest) :unsubmitted)))))

(defun build-inputs (store id &key (unsaved-buffers :reject) paths)
  "Capture disk inputs without compiling. PATHS adds sources not yet read by IDE.
The build integration must discover transitive inputs and consume these values,
not reread mutable files. Capturing a disk input never replaces an IDE overlay."
  (serialized (store)
    (let ((s (require-session store id)))
      (unless (member unsaved-buffers '(:reject :ignore)) (reject-request "Unknown buffer policy"))
      (when (eq unsaved-buffers :reject)
        (maphash (lambda (buffer key)
                   (declare (ignore buffer))
                   (let ((source (gethash key (session-sources s))))
                     (unless (and (source-path source) (probe-file (source-path source))
                                  (string= (source-text source)
                                           (uiop:read-file-string (source-path source))))
                       (reject-request "Build requires saved buffers or explicit :IGNORE policy"))))
                 (session-buffers s)))
      (let* ((keys (remove-duplicates
                    (append (mapcar (lambda (path) (source-key s path)) paths)
                            (loop for source being the hash-values of (session-sources s)
                                  when (and (source-path source) (probe-file (source-path source)))
                                    collect (source-id source))) :test #'equal))
             (inputs
               (loop for key in keys
                     for text = (uiop:read-file-string key)
                     for current = (gethash key (session-sources s))
                     for previous = (gethash key (session-build-sources s))
                     for input =
                       (or (and current (string= text (source-text current))
                                (%source :id key :path (source-path current)
                                         :revision (source-revision current) :text text))
                           (and previous (string= text (source-text previous)) previous)
                           (%source :id key :path (pathname key)
                                      :module (and current (source-module current))
                                      :revision (incf (session-revision s)) :text text))
                     do (setf (gethash key (session-build-sources s)) input)
                     collect (list :source-id (copy-value key) :path (source-path input)
                                   :revision (source-revision input)
                                   :contents (source-text input)))))
        (list :session-id id :configuration (configuration-value (session-configuration s))
              :configuration-revision (session-configuration-revision s)
              :source-policy :disk :unsaved-buffers unsaved-buffers :sources inputs)))))
