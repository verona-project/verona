(defpackage #:verona.swank
  (:use #:cl)
  (:export #:rpc #:disconnect #:*store*))
(in-package #:verona.swank)

(defvar *store* (verona.ide:make-session-store))
(defvar *attachments* (make-hash-table :test 'eq))
(defvar *connection-ids* (make-hash-table :test 'eq))
(defvar *next-connection* 0)
(defvar *requests* (make-hash-table :test 'equal))
(defvar *next-request* 0)
(defvar *lock* (swank/backend:make-lock :name "Verona RPC"))

(defparameter *queries*
  '(:inspect-session :reset-session :close-session
    :open-buffer :edit-buffer :save-buffer :rename-buffer :close-buffer :read-source
    :source-state :module-state :discover-modules :list-modules :inspect-module
    :module-contents :module-relationships :dependency-graph :dependency-cycles
    :list-definitions :find-definitions :inspect-definition :definition-type-structure
    :definition-relationships :position-context :complete-names :signature-help
    :go-to-definition :find-references :related-definitions :module-diagnostics
    :project-diagnostics :inspect-expansion :type-at-position))

(define-condition invalid-request (error)
  ((message :initarg :message :reader invalid-message)))
(defun invalid (control &rest arguments)
  (error 'invalid-request :message (apply #'format nil control arguments)))

(defun proper-list-p (value)
  (and (listp value) (handler-case (integerp (list-length value)) (type-error () nil))))

(defun validate-value (parameter value)
  (let ((name (symbol-name parameter)))
    (cond
      ((member name '("TEXT" "BUFFER" "ID" "ROOT" "PATH") :test #'string=)
       (unless (or (stringp value) (and (string= name "PATH") (null value)))
         (invalid "~A must be a string" name)))
      ((member name '("OFFSET" "LIMIT") :test #'string=)
       (unless (or (and (null value) (string= name "OFFSET"))
                   (and (integerp value) (>= value 0)))
         (invalid "~A must be a nonnegative integer" name))))))

(defun validate-arguments (function arguments)
  ;; All mapped IDE entry points use required parameters followed by &KEY.
  ;; Validate at the boundary so programming errors inside them still debug.
  (let* ((parameters (swank/backend:arglist function))
         (boundary (position '&key parameters))
         (required (or boundary (length parameters)))
         (keys (and boundary (subseq parameters (1+ boundary)))))
    (when (< (length arguments) required) (invalid "Missing arguments for ~A" function))
    (loop for parameter in parameters for value in arguments repeat required
          do (validate-value parameter value))
    (let ((tail (nthcdr required arguments)))
      (unless (and (or boundary (null tail)) (evenp (length tail)))
        (invalid "Invalid arguments for ~A" function))
      (loop for (key value) on tail by #'cddr
            for spec = (and (keywordp key)
                            (find key keys :test #'string-equal
                                  :key (lambda (spec)
                                         (symbol-name (if (consp spec) (first spec) spec)))))
            do (unless spec (invalid "Unknown keyword ~S for ~A" key function))
               (validate-value (if (consp spec) (first spec) spec) value)))))

(defun ide-call (function &rest arguments)
  (validate-arguments function arguments)
  (handler-case (apply function arguments)
    (verona.ide:request-error (condition) (invalid "~A" condition))
    (file-error (condition) (invalid "~A" condition))))

(defun encode (value)
  "Only wire data escapes the adapter; never print an opaque compiler object."
  (typecase value
    (verona.ide:configuration
     (loop for key in '(:root :build-file :build-target :search-paths :package-locations
                       :target :reader-features)
           append (list key (encode (funcall (find-symbol (format nil "CONFIGURATION-~A" key)
                                                         :verona.ide) value)))))
    (verona.ide:source-record
     (list :id (encode (verona.ide:source-id value))
           :path (encode (verona.ide:source-path value))
           :module (encode (verona.ide:source-module value))
           :revision (verona.ide:source-revision value)))
    (pathname (namestring value))
    (character (string value))
    (cons (cons (encode (car value)) (encode (cdr value))))
    ((or null string number) value)
    (symbol (if (or (keywordp value) (eq value t)) value (symbol-name value)))
    (t (let ((data (verona.ide::query-data value)))
         (if (eq data value) (error "Unsupported wire value") (encode data))))))

(defun disconnect (connection)
  (swank/backend:call-with-lock-held
   *lock*
   (lambda ()
     (dolist (id (gethash connection *attachments*))
       (when (verona.ide:find-session *store* id)
         (verona.ide:detach-session *store* id (gethash connection *connection-ids*))))
     (remhash connection *attachments*)
     (remhash connection *connection-ids*))))
(pushnew 'disconnect swank::*connection-closed-hook*)

(defun attach (connection id)
  (unless connection (invalid "An editor connection is required"))
  (unless (verona.ide:find-session *store* id) (invalid "Unknown session ~A" id))
  (ide-call 'verona.ide:attach-session *store* id
            (or (gethash connection *connection-ids*)
                (setf (gethash connection *connection-ids*)
                      (format nil "connection-~D" (incf *next-connection*)))))
  (pushnew id (gethash connection *attachments*) :test #'equal)
  id)

(defun request-entry (id token)
  (let ((entry (gethash token *requests*)))
    (unless (and entry (equal id (first entry))) (invalid "Unknown request ~A" token))
    entry))

(defun request-info (id token)
  (let* ((entry (request-entry id token)) (request (second entry)))
    (list :request token :session id :status (verona.ide:request-status request)
          :source (verona.ide:request-source-id request)
          :source-revision (verona.ide:request-source-revision request)
          :configuration-revision (verona.ide:request-configuration-revision request)
          :current-module (verona.ide:module-state *store* id (verona.ide:request-source-id request)))))

(defun prune-closed-sessions ()
  (maphash (lambda (token entry)
             (unless (verona.ide:find-session *store* (first entry))
               (remhash token *requests*))) *requests*)
  (maphash (lambda (connection ids)
             (setf (gethash connection *attachments*)
                   (remove-if-not (lambda (id) (verona.ide:find-session *store* id)) ids)))
           *attachments*))

(defun submit (id source)
  (let* ((store *store*)
         (record (if (stringp source) (ide-call 'verona.ide:read-source *store* id source)
                     (verona.ide::serialized (*store*)
                       (gethash source (verona.ide::session-sources
                                        (verona.ide::require-session *store* id))))))
         (request (progn (unless record (invalid "Unknown source ~S" source))
                         (verona.ide:begin-request *store* id record)))
         (token (format nil "request-~D" (incf *next-request*))))
    (setf (gethash token *requests*) (list id request))
    (handler-case
        (swank/backend:spawn
         (lambda ()
           (handler-case
               (when (eq :pending (verona.ide:request-status request))
                 (verona.ide:evaluate-request store id request))
             (verona.ide:request-error (condition)
               ;; Reset can release the request while retaining the session.
               (when (and (verona.ide:find-session store id)
                          (eq :pending (verona.ide:request-status request)))
                 (error condition)))
             (error (condition)
               ;; A session may close before the worker enters the engine.
               (when (verona.ide:find-session store id) (error condition)))))
         :name (format nil "Verona ~A" token))
      (error (condition)
        (verona.ide:cancel-request *store* id request)
        (error condition)))
    (list :request token :session id)))

(defun dispatch (connection operation id arguments)
  (when (and (member operation '(:capabilities :attach-session :detach-session)) arguments)
    (invalid "~A takes no arguments" operation))
  (case operation
    (:capabilities
     (list :protocol-version 1 :adapter-version "0.1.0"
           :features '(:asynchronous-evaluation :reconnect :explicit-evaluation :cached-queries)
           :operations (append (when (fboundp 'verona.ide::discover-project-configuration)
                                 '(:create-project-session))
                               '(:capabilities :create-session :attach-session :detach-session
                                 :configure-session :evaluate :request-status :cancel-request)
                               *queries*)))
    (:create-session
     (attach connection (verona.ide:create-session
                         *store* (apply #'ide-call 'verona.ide:make-configuration arguments))))
    (:create-project-session
     (unless (fboundp 'verona.ide::discover-project-configuration)
       (invalid "Load verona/ide/project to enable project configuration discovery"))
     (attach connection (verona.ide:create-session
                         *store* (apply #'ide-call 'verona.ide::discover-project-configuration arguments))))
    (:attach-session (attach connection id))
    (otherwise
     (unless (member id (gethash connection *attachments*) :test #'equal)
       (invalid "Attach this connection to session ~A first" id))
     (unless (verona.ide:find-session *store* id) (invalid "Unknown session ~A" id))
     (case operation
       (:detach-session
        (verona.ide:detach-session *store* id (gethash connection *connection-ids*))
        (setf (gethash connection *attachments*)
              (remove id (gethash connection *attachments*) :test #'equal)) id)
       (:configure-session
        (ide-call 'verona.ide:configure-session *store* id
                  (apply #'ide-call 'verona.ide:make-configuration arguments)))
       (:evaluate (unless (= 1 (length arguments)) (invalid "Expected one source identifier"))
                  (submit id (first arguments)))
       ((:request-status :cancel-request)
        (unless (= 1 (length arguments)) (invalid "Expected one request identifier"))
        (when (eq operation :cancel-request)
          (verona.ide:cancel-request *store* id (second (request-entry id (first arguments)))))
        (request-info id (first arguments)))
       (otherwise
        (unless (member operation *queries*) (invalid "Unknown operation ~S" operation))
        (when (eq operation :dependency-cycles)
          (return-from dispatch
            (multiple-value-bind (cycles completeness)
                (apply #'ide-call 'verona.ide:dependency-cycles *store* id arguments)
              (list :items cycles :completeness completeness))))
        (let ((result (apply #'ide-call (find-symbol (symbol-name operation) :verona.ide)
                             *store* id arguments)))
          (when (member operation '(:close-session :reset-session))
            (maphash (lambda (token entry)
                       (when (equal id (first entry)) (remhash token *requests*))) *requests*))
          result))))))

(swank::defslimefun rpc (operation &optional session arguments)
  "Verona RPC entry point. ARGUMENTS is a data list, never a form to evaluate."
  (handler-case
      (swank/backend:call-with-lock-held
       *lock* (lambda ()
                (prune-closed-sessions)
                (unless (and (keywordp operation) (proper-list-p arguments))
                  (invalid "Expected an operation keyword and argument list"))
                (list :ok (encode (dispatch swank::*emacs-connection* operation session arguments)))))
    (invalid-request (condition)
      (list :error (list :code :invalid-request :message (invalid-message condition))))
    (verona:user-compilation-error (condition)
      (list :error (list :code :compiler-diagnostic
                         :diagnostic (encode (verona:diagnostic-for-condition condition)))))))
