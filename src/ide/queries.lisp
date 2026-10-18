(in-package #:verona.ide)

;; Queries never resolve paths or touch disk. Discovery is a separate mutation.
(defun discover-modules (store id &key paths)
  "Explicitly scan PATHS (default: configured search roots) for .vrn files.
Register identities without reading contents or evaluating modules."
  (serialized (store)
    (let* ((s (require-session store id)) (seen (make-hash-table :test 'equal)) (found nil))
      (labels ((visit (path)
                 (let ((path (canonical-path path (configuration-root (session-configuration s)))))
                   (unless (gethash (namestring path) seen)
                     (setf (gethash (namestring path) seen) t)
                     (if (uiop:directory-pathname-p path)
                         (progn (mapc #'visit (uiop:directory-files path))
                                (mapc #'visit (uiop:subdirectories path)))
                         (when (equal "vrn" (pathname-type path))
                           (let ((key (namestring path)))
                             (setf (gethash key (session-discovered s)) path)
                             (push key found))))))))
        (mapc #'visit (or paths (configuration-search-paths (session-configuration s)))))
      (sort found #'string<))))

(defun query-module-records (s)
  "Each record is (identity path source evaluation). Evaluated context wins."
  (let ((records (make-hash-table :test 'equal)))
    (maphash (lambda (key path)
               (setf (gethash key records) (list (list (pathname-name path) key) path nil nil)))
             (session-discovered s))
    (maphash (lambda (key source)
               (setf (gethash key records)
                     (list (list (or (source-module source)
                                     (and (source-path source) (pathname-name (source-path source))) key) key)
                           (source-path source) source nil))) (session-sources s))
    (maphash (lambda (key state)
               (let* ((source-id (module-evaluation-source-id state))
                      (source (gethash source-id (session-sources s))))
                 (setf (gethash source-id records)
                       (list key (module-evaluation-source-path state) source state)))) (session-modules s))
    (loop for record being the hash-values of records collect record)))

(defun require-query-module (s module)
  (or (find module (query-module-records s) :key #'first :test #'equal)
      (reject-request "Unknown module identity ~S" module)))

(defun query-summary (s record)
  (destructuring-bind (identity path source state) record
    (list :id identity :name (first identity) :source-id (second identity) :source-path path
          :project (configuration-root (session-configuration s))
          :target (configuration-target (session-configuration s))
          :build-target (configuration-build-target (session-configuration s))
          :configuration-revision (session-configuration-revision s)
          :evaluation-configuration-revision (and state (module-evaluation-configuration-revision state))
          :current-source-revision (and source (source-revision source))
          :evaluation-source-revision (and state (module-evaluation-source-revision state))
          :evaluated-p (not (null state)) :status (if state (module-evaluation-status state) :unevaluated)
          :cached-products (and state
                                (loop for key in (module-evaluation-products state) by #'cddr
                                      collect (list :kind key :availability
                                                    (getf (query-product state key) :availability))))
          :phase (and state (module-evaluation-phase state))
          :completed-phases (and state (module-evaluation-completed-phases state))
          :failed-phase (and state (module-evaluation-failed-phase state))
          :needs-evaluation-p (or (null state) (not (null (module-evaluation-reasons state))))
          :needs-evaluation-reasons (and state (module-evaluation-reasons state)))))

(defun query-page (items offset limit)
  (unless (and (integerp offset) (>= offset 0) (integerp limit) (<= 1 limit 1000))
    (reject-request "OFFSET must be nonnegative and LIMIT must be between 1 and 1000"))
  (let* ((total (length items)) (end (min total (+ offset limit))))
    (list :items (subseq items (min offset total) end) :total total
          :offset offset :limit limit :next-offset (and (< end total) end))))

(defun query-matches (filter value)
  (or (null filter) (and value (search (string filter) (princ-to-string value) :test #'char-equal))))

(defun query-order-key (value) (with-standard-io-syntax (prin1-to-string value)))

(defun list-modules (store id &key name source-path status (offset 0) (limit 100))
  "Browse known modules only. Name/path filters are case-insensitive substrings."
  (serialized (store)
    (let* ((s (require-session store id))
           (items (loop for record in (query-module-records s)
                        for summary = (query-summary s record)
                        when (and (query-matches name (getf summary :name))
                                  (query-matches source-path (getf summary :source-path))
                                  (or (null status) (eq status (getf summary :status)))) collect summary)))
      (query-data (query-page (sort items #'string< :key (lambda (x) (query-order-key (getf x :id)))) offset limit)))))

(defun inspect-module (store id module)
  "Return a compact current summary for the full module identity."
  (serialized (store)
    (let ((s (require-session store id)))
      (query-data (query-summary s (require-query-module s module))))))

;; Project compiler objects into portable summaries; never return mutable compiler
;; environments, syntax objects, declarations, or source contents to clients.
(defun query-data (value)
  (typecase value
    (verona::module-name (verona::module-name-string value))
    (verona::verona-name (copy-value (verona::verona-name-value value)))
    (verona::source-location
     (list :source (copy-seq (verona::source-name (verona::source-location-source value)))
           :offset (verona::source-location-offset value) :line (verona::source-location-line value)
           :column (verona::source-location-column value)))
    (verona::source-range (list :start (query-data (verona::source-range-start value))
                                :end (query-data (verona::source-range-end value))))
    (verona::syntax (query-data (verona::syntax-source-range value)))
    (verona::diagnostic
     (list :severity (verona::diagnostic-severity value) :code (query-data (verona::diagnostic-code value))
           :message (query-data (verona::diagnostic-message value))
           :location (query-data (verona::diagnostic-primary-location value))
           :secondary-locations (query-data (verona::diagnostic-secondary-locations value))
           :notes (query-data (verona::diagnostic-notes value)) :data (query-data (verona::diagnostic-data value))))
    (verona::declaration
     (list :name (query-data (verona::declaration-name value)) :kind (class-name (class-of value))
           :location (query-data (verona::declaration-source value))))
    (verona::import
     (list :name (query-data (verona::module-name (verona::import-module value)))
           :source-path (verona::module-pathname (verona::import-module value))
           :alias (query-data (verona::import-alias value)) :location (query-data (verona::import-source value))))
    (cons (cons (query-data (car value)) (query-data (cdr value))))
    (string (copy-seq value))
    ((or null symbol number character pathname) value)
    (t (list :kind (class-name (class-of value))))))

(defun query-product (state key)
  (let* ((phase (car (find key +phase-products+ :key #'cdr :test #'member)))
         (products (and state (module-evaluation-products state)))
         (present (and state (loop for k in products by #'cddr thereis (eq key k))))
         (complete (and state (member phase (module-evaluation-completed-phases state)))))
    (list :phase phase :availability (cond (complete :complete) (present :partial) (t :unavailable))
          :value (and present (getf products key)))))

(defun module-contents (store id module &key (kind :declarations) name (offset 0) (limit 100))
  "Return paginated summaries of one current product, with phase availability."
  (unless (member kind '(:declarations :imports :exports :macros :bindings)) (reject-request "Unknown content kind"))
  (serialized (store)
    (let* ((s (require-session store id)) (record (require-query-module s module))
           (product (query-product (fourth record) kind)) (raw (getf product :value)))
      (when (member kind '(:macros :bindings)) (setf raw (getf raw :definitions)))
      (when (eq kind :exports)
        (setf raw (mapcar (lambda (entry) (list :name (query-data (car entry))
                                              :definition (query-data (cdr entry)))) raw)))
      (when (typep raw 'verona::environment)
        (setf raw (mapcar (lambda (binding) (list :name (query-data (car binding)) :kind :binding))
                         (verona::environment-bindings raw))))
      (let* ((items (loop for value in raw for index from 0
                          for data = (query-data value)
                          for label = (if (listp data) (getf data :name) data)
                          when (query-matches name label)
                            collect (list :id (or (and (typep value 'verona::declaration)
                                                       (first (find value (definition-records s) :key #'third :test #'eq)))
                                                  (list module kind index)) :name label :summary data)))
             (page (query-page (stable-sort items #'string< :key (lambda (x) (query-order-key (getf x :name)))) offset limit)))
        (query-data (append (list :evaluation-source-revision (and (fourth record) (module-evaluation-source-revision (fourth record)))
                                 :evaluation-configuration-revision (and (fourth record) (module-evaluation-configuration-revision (fourth record)))
                                 :module module :kind kind :phase (getf product :phase)
                                 :availability (getf product :availability)) page))))))

(defun module-relationships (store id module &key (direction :dependencies) transitive imports-only
                                                 (offset 0) (limit 100))
  (unless (member direction '(:dependencies :dependents)) (reject-request "Unknown direction"))
  (serialized (store)
    (let ((s (require-session store id)))
      (require-query-module s module)
      (let* ((graph (query-dependency-graph s module nil :module direction transitive imports-only))
             (edges (sort (getf graph :edges) #'string< :key (lambda (e) (query-order-key (query-data e))))))
        (query-data (append (list :module module :direction direction :transitive (not (null transitive))
                                 :complete (getf graph :complete) :incomplete-modules (getf graph :incomplete-modules)
                                 :needs-evaluation-reasons (getf graph :needs-evaluation-reasons))
                           (query-page edges offset limit)))))))
