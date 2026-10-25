;;; verona-ide.el --- Optional Swank IDE client -*- lexical-binding: t; -*-
;; Package-Requires: ((emacs "28.1") (slime "2.26"))
;;; Commentary:
;; Explicit analysis for verona-mode.  See editors/emacs/README.md.
;;; Code:
(require 'cl-lib)
(require 'verona-mode)
(require 'xref)
(require 'flymake)
(require 'eldoc)
(require 'button)
(require 'pp)
(require 'compile)
(defvar slime-dispatching-connection)
(declare-function slime-connect "slime")
(declare-function slime-current-connection "slime")
(declare-function slime-eval-async "slime")
(defgroup verona-ide nil "Verona analysis." :group 'verona)
(defcustom verona-ide-program-arguments nil "Built program arguments." :type '(repeat string))
(defcustom verona-ide-program-directory nil "Working directory; nil uses project root." :type '(choice (const nil) directory))
(defcustom verona-ide-program-environment nil "Environment overrides as NAME=value." :type '(repeat string))
(defvar-local verona-ide--build nil)
(defvar-local verona-ide--build-timer nil)
(defvar-local verona-ide--build-offset 0)
(defvar-local verona-ide--build-error-offset 0)
(defvar-local verona-ide--build-run nil)
(defvar-local verona-ide--build-options nil)
(defvar verona-ide-mode)
(defvar-local verona-ide--session nil)
(defvar-local verona-ide--connection nil)
(defvar-local verona-ide--operations nil)
(defvar-local verona-ide--root nil)
(defvar-local verona-ide--source nil)
(defvar-local verona-ide--module nil)
(defvar-local verona-ide--buffer-id nil)
(defvar-local verona-ide--text nil)
(defvar-local verona-ide--syncing nil)
(defvar-local verona-ide--waiters nil)
(defvar-local verona-ide--path nil)
(defvar-local verona-ide--epoch 0)
(defvar-local verona-ide--timer nil)
(defvar-local verona-ide--request nil)
(defvar-local verona-ide--evaluation-serial 0)
(defvar-local verona-ide--status "disconnected")
(defvar-local verona-ide--last-error nil)
(defvar-local verona-ide--cache nil)
(defvar-local verona-ide--serials nil)

(defun verona-ide--error-message (data)
  "Describe either an invalid request or a nested compiler diagnostic."
  (or (plist-get data :message)
      (plist-get (plist-get data :diagnostic) :message)
      (format "Server rejected request: %S" data)))

(defun verona-ide-last-error ()
  "Display the last rejected request and complete server error data."
  (interactive)
  (unless verona-ide--last-error (user-error "No recorded Verona error in this buffer"))
  (let ((data verona-ide--last-error))
    (with-current-buffer (get-buffer-create "*Verona error*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pp-to-string data))
        (goto-char (point-min))
        (special-mode)))
    (display-buffer "*Verona error*")))

(defun verona-ide--rpc (operation arguments callback &optional session)
  "Send OPERATION asynchronously, routing replies to the originating buffer."
  (unless (or (eq operation :capabilities) (memq operation verona-ide--operations))
    (user-error "Adapter does not support %s" operation))
  (let ((buffer (current-buffer)) (epoch verona-ide--epoch)
        (connection verona-ide--connection))
    (unless (and connection (process-live-p connection))
      (setq verona-ide--status "disconnected")
      (user-error "Use verona-start-server and verona-open-project first"))
    (let ((slime-dispatching-connection connection))
      (slime-eval-async
       `(verona.swank:rpc ,operation ,(or session verona-ide--session) (quote ,arguments))
       (lambda (reply)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= epoch verona-ide--epoch)
               (if (eq (car reply) :ok) (funcall callback (cadr reply))
                 (setq verona-ide--status "request rejected"
                       verona-ide--syncing nil verona-ide--waiters nil
                       verona-ide--last-error
                       (list :operation operation :session (or session verona-ide--session)
                             :error (cadr reply)))
                 (message "Verona: %s" (verona-ide--error-message (cadr reply))))))))))))

(defun verona-ide--show-project (project)
  "Present discovered PROJECT metadata before selecting a target."
  (with-current-buffer (get-buffer-create "*Verona project*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (format "Project: %s\nBuild file: %s\n\n"
                      (plist-get project :root) (plist-get project :build-file)))
      (dolist (target (plist-get project :targets))
        (insert (format "%s (%s)\n  Root module: %s\n  Target: %s\n  Module paths: %s\n  Features: %s\n  Optimization: %s\n\n"
                        (plist-get target :name) (plist-get target :kind)
                        (plist-get target :root-module) (plist-get target :target)
                        (mapconcat #'identity (plist-get target :search-paths) ", ")
                        (plist-get target :reader-features) (plist-get target :optimization))))
      (goto-char (point-min)) (special-mode)))
  (display-buffer "*Verona project*"))

(defun verona-ide--start-project (root target existing ready)
  "Read ROOT's build file and call READY after creating or attaching its session."
  (require 'slime)
  (setq existing (or existing ""))
  (unless (equal existing verona-ide--session)
    (setq verona-ide--request nil)
    (when verona-ide--source (verona-ide--close)))
  (setq verona-ide--syncing nil verona-ide--waiters nil)
  (cl-incf verona-ide--epoch)
  (setq verona-ide--connection (slime-current-connection)
        verona-ide--root (file-name-as-directory (expand-file-name root))
        verona-ide--cache (make-hash-table :test #'equal)
        verona-ide--serials (make-hash-table :test #'eq))
  (verona-ide--rpc
   :capabilities nil
   (lambda (caps)
     (unless (equal (plist-get caps :protocol-version) 1)
       (user-error "Unsupported Verona protocol"))
     (setq verona-ide--operations (plist-get caps :operations))
     (unless (and (memq :inspect-project verona-ide--operations)
                  (memq :create-project-session verona-ide--operations))
       (setq verona-ide--status "project discovery unavailable")
       (user-error "Load the updated verona/ide/project and verona/swank systems in the server"))
     (verona-ide--rpc
      :inspect-project (list verona-ide--root)
      (lambda (project)
        (verona-ide--show-project project)
        (let* ((names (mapcar (lambda (item) (plist-get item :name)) (plist-get project :targets)))
               (selected (when (equal existing "")
                           (cond ((and target (not (equal target ""))) target)
                                 ((null names) (user-error "verona.build defines no targets"))
                                 ((null (cdr names)) (car names))
                                 (t (completing-read "Build target: " names nil t))))))
          (when (and selected (not (member selected names)))
            (user-error "Unknown build target %s; available: %s" selected (mapconcat #'identity names ", ")))
          (verona-ide--rpc
           (if (equal existing "") :create-project-session :attach-session)
           (when (equal existing "") (list (plist-get project :root) :build-target selected))
           (lambda (id)
             (setq verona-ide--session id verona-ide--status "unevaluated")
             (funcall ready project (or selected target))
             (message "Verona session %s; build target %s" id (or selected "existing session")))
           (unless (equal existing "") existing))))))))

(defvar verona-ide--projects nil
  "Opened project contexts, independent of individual source buffers.")

(defun verona-ide--project-for-file (file)
  (car (sort (cl-remove-if-not
              (lambda (project)
                (and (process-live-p (plist-get project :connection))
                     (file-in-directory-p file (plist-get project :root))))
              (copy-sequence verona-ide--projects))
             (lambda (left right)
               (> (length (plist-get left :root)) (length (plist-get right :root)))))))

(defun verona-ide--use-project (project)
  "Associate this source buffer with PROJECT without prompting or evaluating."
  (unless (and verona-ide-mode
               (equal verona-ide--session (plist-get project :session))
               (eq verona-ide--connection (plist-get project :connection)))
    (let ((same-session (equal verona-ide--session (plist-get project :session))))
      (unless same-session
        (when verona-ide-mode (verona-ide-mode -1))
        (setq verona-ide--request nil)))
    (cl-incf verona-ide--epoch)
    (setq verona-ide--root (plist-get project :root)
          verona-ide--session (plist-get project :session)
          verona-ide--connection (plist-get project :connection)
          verona-ide--operations (plist-get project :operations)
          verona-ide--cache (make-hash-table :test #'equal)
          verona-ide--serials (make-hash-table :test #'eq)
          verona-ide--status "unevaluated"
          verona-ide--syncing nil verona-ide--waiters nil)
    (verona-ide-mode 1)
    (verona-ide--sync (lambda () (verona-ide-refresh)
                              (when verona-ide--request (verona-ide--poll))))))

(defun verona-ide--auto-attach ()
  (when (and buffer-file-name (derived-mode-p 'verona-mode)
             (not (and verona-ide-mode verona-ide--connection
                       (process-live-p verona-ide--connection)))
             (not (equal (file-name-nondirectory buffer-file-name) "verona.build")))
    (let ((project (verona-ide--project-for-file buffer-file-name)))
      (when project (verona-ide--use-project project)))))
(add-hook 'find-file-hook #'verona-ide--auto-attach)

(defun verona-ide--open-project-file (project &optional file)
  (let ((file (or file (read-file-name "Project file: " (plist-get project :root) nil t))))
    (find-file file)
    (when (and (derived-mode-p 'verona-mode)
               (not (equal (file-name-nondirectory file) "verona.build")))
      (verona-ide--use-project project))))

;;;###autoload
(defun verona-open-project (root &optional target)
  "Open ROOT's project, create its session, and visit its root module.
Use the current SLIME connection. Multiple build targets prompt for selection."
  (interactive (list (read-directory-name "Open Verona project: ")
                     (when current-prefix-arg (read-string "Build target: "))))
  (require 'slime)
  (let* ((root (file-name-as-directory (file-truename root)))
         (previous (cl-find-if (lambda (item)
                                 (and (equal root (plist-get item :root))
                                      (or (null target) (equal target (plist-get item :target)))))
                               verona-ide--projects)))
    (with-current-buffer (get-buffer-create (format " *Verona project %s %s*" root (or target "default")))
      (verona-ide--start-project
       root (or target (plist-get previous :target)) (plist-get previous :session)
       (lambda (metadata target)
         (let* ((description (cl-find target (plist-get metadata :targets)
                                      :key (lambda (item) (plist-get item :name)) :test #'equal))
                (project (list :root (plist-get metadata :root) :target target
                               :session verona-ide--session :connection verona-ide--connection
                               :operations verona-ide--operations))
                (entry (cl-loop for path in (plist-get description :search-paths)
                                for file = (expand-file-name
                                            (concat (plist-get description :root-module) ".vrn") path)
                                when (file-exists-p file) return file)))
           (setq verona-ide--projects
                 (cons project (cl-remove-if
                                (lambda (old) (and (equal (plist-get old :root) (plist-get project :root))
                                                   (equal (plist-get old :target) target)))
                                verona-ide--projects)))
           (dolist (buffer (buffer-list))
             (with-current-buffer buffer (verona-ide--auto-attach)))
           (verona-ide--open-project-file project entry)))))))

(defun verona-ide--current-project ()
  "Prefer the buffer's explicit session over root-based discovery."
  (or (cl-find-if (lambda (p) (and (equal verona-ide--session (plist-get p :session))
                                  (eq verona-ide--connection (plist-get p :connection))))
                  verona-ide--projects)
      (and buffer-file-name (verona-ide--project-for-file buffer-file-name))
      (cl-find verona-ide--root verona-ide--projects
               :key (lambda (p) (plist-get p :root)) :test #'equal)))

(defun verona-project-find-file ()
  "Choose another file in the current opened project, reusing its session."
  (interactive)
  (let ((project (verona-ide--current-project)))
    (unless project (user-error "Open a project with verona-open-project first"))
    (verona-ide--open-project-file project)))

(defun verona-close-project ()
  "Close the current project session and release its work and editor state."
  (interactive)
  (let ((project (verona-ide--current-project)))
    (unless project (user-error "No opened Verona project"))
    (let ((session (plist-get project :session)) (connection (plist-get project :connection)))
      (unless (process-live-p connection)
        (user-error "Reconnect SLIME and reopen this project before closing its server session"))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (equal session verona-ide--session)
                     (eq connection verona-ide--connection))
            (when verona-ide-mode (verona-ide-mode -1))
            (when (timerp verona-ide--build-timer) (cancel-timer verona-ide--build-timer))
            (setq verona-ide--build nil)
            (when (derived-mode-p 'special-mode 'compilation-mode)
              (let ((inhibit-read-only t)) (erase-buffer) (insert "Project closed\n")))
            (setq verona-ide--connection nil verona-ide--session nil
                  verona-ide--request nil verona-ide--cache nil
                  verona-ide--status "disconnected"))))
      (when (process-live-p connection)
        (let ((verona-ide--connection connection)
              (verona-ide--session session)
              (verona-ide--operations (plist-get project :operations)))
          (verona-ide--rpc :close-session nil #'ignore)))
      (setq verona-ide--projects (delq project verona-ide--projects)))))

(defun verona-ide--contents ()
  (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))
(defun verona-ide--offset ()
  (1- (point)))
(defun verona-ide--sync (done)
  "Synchronize latest overlay, then call DONE; never evaluate."
  (if verona-ide--syncing
      (push done verona-ide--waiters)
    (verona-ide--sync-start done)))
(defun verona-ide--sync-start (done)
  (let* ((text (verona-ide--contents)) (path (and buffer-file-name (file-truename buffer-file-name)))
         (operation (cond ((null verona-ide--source) :open-buffer)
                          ((not (equal path verona-ide--path)) :rename-buffer)
                          ((not (equal text verona-ide--text)) :edit-buffer))))
    (if (null operation) (funcall done)
      (unless verona-ide--buffer-id
        (setq verona-ide--buffer-id (format "emacs-%s-%s" (emacs-pid) (buffer-name))))
      (setq verona-ide--syncing t)
      (verona-ide--rpc
       operation
       (pcase operation
         (:open-buffer (append (list verona-ide--buffer-id text) (when path (list :path path))))
         (:rename-buffer (list verona-ide--buffer-id path))
         (_ (list verona-ide--buffer-id text)))
       (lambda (source)
         (setq verona-ide--source (plist-get source :id)
               verona-ide--module (list (or (plist-get source :module)
                                          (if path (file-name-base path) (plist-get source :id)))
                                      (plist-get source :id))
               verona-ide--path path)
         (unless (eq operation :rename-buffer) (setq verona-ide--text text))
         (setq verona-ide--syncing nil)
         (let ((waiters (prog1 (nreverse verona-ide--waiters)
                          (setq verona-ide--waiters nil))))
           (verona-ide--sync
            (lambda () (funcall done) (mapc #'funcall waiters)))))))))

(defun verona-ide--changed (&rest _)
  (setq verona-ide--status "unevaluated edits")
  (when verona-ide--cache (clrhash verona-ide--cache))
  (when (timerp verona-ide--timer) (cancel-timer verona-ide--timer))
  (let ((buffer (current-buffer)))
    (setq verona-ide--timer
          (run-with-idle-timer 0.3 nil
                              (lambda () (when (buffer-live-p buffer)
                                           (with-current-buffer buffer
                                             (when verona-ide-mode
                                               (verona-ide--sync #'ignore)))))))))
(defun verona-ide--saved ()
  (verona-ide--sync
   (lambda () (verona-ide--rpc :save-buffer (list verona-ide--buffer-id :path buffer-file-name) #'ignore))))
(defun verona-ide--close ()
  (when (timerp verona-ide--timer) (cancel-timer verona-ide--timer))
  (when (and verona-ide--source verona-ide--connection (process-live-p verona-ide--connection))
    (verona-ide--rpc :close-buffer (list verona-ide--buffer-id) #'ignore))
  (setq verona-ide--source nil verona-ide--text nil))

(defun verona-ide--sync-project (done)
  "Flush all attached project overlays before an explicit request."
  (let ((origin (current-buffer)) (session verona-ide--session)
        (connection verona-ide--connection))
    (cl-labels ((next (buffers)
                  (if (null buffers)
                      (when (buffer-live-p origin) (with-current-buffer origin (funcall done)))
                    (let ((buffer (car buffers)))
                      (if (not (buffer-live-p buffer)) (next (cdr buffers))
                        (with-current-buffer buffer
                          (if (and verona-ide-mode (equal session verona-ide--session)
                                   (eq connection verona-ide--connection))
                              (verona-ide--sync (lambda () (next (cdr buffers))))
                            (next (cdr buffers)))))))))
      (next (buffer-list)))))

(defun verona-ide--query (operation arguments callback)
  "Query cached analysis, rejecting replies superseded by edits or newer requests."
  (unless verona-ide--session (user-error "Open a project with verona-open-project first"))
  (let ((tick (buffer-chars-modified-tick))
        (serial (1+ (gethash operation verona-ide--serials 0))))
    (puthash operation serial verona-ide--serials)
    (verona-ide--sync-project
     (lambda ()
       (verona-ide--rpc operation arguments
        (lambda (data)
          (when (and (= tick (buffer-chars-modified-tick))
                     (= serial (gethash operation verona-ide--serials)))
            (puthash (cons operation arguments) data verona-ide--cache)
            (funcall callback data))))))))

(defun verona-ide-evaluate ()
  "Explicitly analyze this module and dependencies, including compile-time macros.
Application code is not executed."
  (interactive)
  (unless verona-ide--session (user-error "Open a project with verona-open-project first"))
  (let ((serial (cl-incf verona-ide--evaluation-serial)))
    (verona-ide--sync-project
     (lambda ()
       (when (= serial verona-ide--evaluation-serial)
         (verona-ide--rpc :evaluate (list verona-ide--source)
          (lambda (data)
            (when (= serial verona-ide--evaluation-serial)
              (setq verona-ide--request (plist-get data :request))
              (verona-ide--poll)))))))))
(defun verona-ide--poll ()
  (when verona-ide--request
    (let ((request verona-ide--request))
      (verona-ide--rpc :request-status (list request)
       (lambda (data)
         (when (equal request verona-ide--request)
           (setq verona-ide--status (format "%s %s" (plist-get data :status)
                                           (plist-get (plist-get data :current-module) :phase)))
           (force-mode-line-update)
           (if (memq (plist-get data :status) '(:pending :processing))
               (let ((buffer (current-buffer)))
                 (run-at-time 0.2 nil (lambda () (when (buffer-live-p buffer)
                                                   (with-current-buffer buffer
                                                     (when verona-ide-mode (verona-ide--poll)))))))
             (verona-ide--refresh-session))))))))
(defun verona-ide--refresh-session ()
  "Refresh affected editor views after evaluation without starting analysis."
  (let ((origin (current-buffer)) (session verona-ide--session)
        (connection verona-ide--connection))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (or (eq buffer origin)
                  (and verona-ide-mode (equal session verona-ide--session)
                       (eq connection verona-ide--connection)))
          (verona-ide-refresh))))))
(defun verona-ide-cancel ()
  "Cancel the retained evaluation request."
  (interactive)
  (when verona-ide--request
    (verona-ide--rpc :cancel-request (list verona-ide--request) (lambda (_) (verona-ide--poll)))))
(defun verona-ide-refresh ()
  "Refresh cached status and diagnostics without evaluating."
  (interactive)
  (verona-ide--query :inspect-module (list verona-ide--module)
   (lambda (data)
     (setq verona-ide--status
           (format "%s%s" (plist-get data :status)
                   (if (equal (plist-get data :current-source-revision)
                              (plist-get data :evaluation-source-revision)) "" " / unevaluated edits")))
     (force-mode-line-update)))
  (when verona-ide--request (verona-ide--poll-once))
  (when flymake-mode (flymake-start)))
(defun verona-ide--poll-once ()
  (verona-ide--rpc :request-status (list verona-ide--request)
                 (lambda (data) (when (memq (plist-get data :status) '(:pending :processing))
                                 (verona-ide--poll)))))

(defun verona-ide--notice (data)
  (unless (and (plist-get data :exact-p) (eq (plist-get data :availability) :complete))
    (message "Verona: %s; exact input: %s; status: %s"
             (or (plist-get data :availability) "see coverage")
             (plist-get data :exact-p) (plist-get data :status))))
(defun verona-ide--qualified-completion-context ()
  "Return live token bounds and prefix for a qualified name at point."
  (unless (nth 8 (syntax-ppss))
    (let* ((end (point))
           (start (save-excursion (skip-chars-backward "^() \t\n\r\";") (point)))
           (prefix (buffer-substring-no-properties start end)))
      (when (string-match-p "\\`[^:]+:[^:]*\\'" prefix)
        (list :start start
              :end (save-excursion (skip-chars-forward "^() \t\n\r\";") (point))
              :prefix prefix)))))

(defun verona-ide--completion-arguments (&optional context)
  (append (list verona-ide--module (verona-ide--offset))
          (when context (list :prefix (plist-get context :prefix) :limit 1000))))

(defun verona-ide-completion-at-point ()
  "Complete names from cached analysis, using live bounds for qualified names."
  (when (and verona-ide--module (memq :complete-names verona-ide--operations))
    (let* ((context (verona-ide--qualified-completion-context))
           (args (verona-ide--completion-arguments context))
           (data (gethash (cons :complete-names args) verona-ide--cache))
           (items (if context
                      (cl-remove-if (lambda (item) (eq (plist-get item :kind) :module))
                                    (plist-get data :items))
                    (plist-get data :items)))
           (range (plist-get (car items) :replacement-range)))
      (unless data (verona-ide--query :complete-names args #'verona-ide--notice))
      ;; Qualified exports come from cached imports, but insertion positions
      ;; belong to the live token. Never reuse old semantic coordinates.
      (when (and items (or context (and range (plist-get data :exact-p))))
        (list (if context (plist-get context :start) (1+ (plist-get range :start)))
              (if context (plist-get context :end) (1+ (plist-get range :end)))
              (mapcar (lambda (item) (plist-get item :insertion-text)) items)
              :exclusive 'no)))))

(defun verona-ide--complete-after-colon ()
  "Fetch exported members after typing a module qualifier, without evaluating."
  (when (and (eq last-command-event ?:) verona-ide--module
             (memq :complete-names verona-ide--operations))
    (let ((context (verona-ide--qualified-completion-context)) (position (point)))
      (when context
        (verona-ide--query :complete-names (verona-ide--completion-arguments context)
         (lambda (data)
           (when (and verona-ide-mode (= position (point)))
             (verona-ide--notice data)
             (let ((completion-ignore-case nil)) (completion-at-point)))))))))

(defun verona-ide-eldoc (callback &rest _)
  (when (memq :signature-help verona-ide--operations)
    (verona-ide--query :signature-help (list verona-ide--module (verona-ide--offset))
     (lambda (data)
       (funcall callback (format "%s [argument %s; %s; exact %s]"
                                 (plist-get data :signatures) (plist-get data :active-argument)
                                 (plist-get data :availability) (plist-get data :exact-p))))) t))

(defun verona-ide--location (item)
  (when (plist-get item :exact-p)
    (let* ((location (plist-get item :location)) (start (or (plist-get location :start) location)))
      (when (and (stringp (plist-get start :source)) (plist-get start :line)
                 (not (cl-some
                       (lambda (buffer)
                         (with-current-buffer buffer
                           (and verona-ide-mode
                                (equal verona-ide--path (plist-get start :source))
                                (not (equal verona-ide--text (verona-ide--contents))))))
                       (buffer-list)))) start))))
(defun verona-ide--xrefs (data)
  (delq nil (mapcar (lambda (item)
                     (let ((loc (verona-ide--location item)))
                       (when (and loc (file-exists-p (plist-get loc :source)))
                         (xref-make (or (plist-get item :name) "Verona reference")
                                    (xref-make-file-location (plist-get loc :source)
                                                             (plist-get loc :line)
                                                             (1- (plist-get loc :column)))))))
                   (plist-get data :items))))
(defun verona-ide-xref-backend () (when verona-ide--session 'verona))
(cl-defmethod xref-backend-identifier-at-point ((_backend (eql verona)))
  (number-to-string (verona-ide--offset)))
(cl-defmethod xref-backend-definitions ((_backend (eql verona)) identifier)
  (let* ((args (list verona-ide--module (string-to-number identifier)))
         (data (gethash (cons :go-to-definition args) verona-ide--cache)))
    (verona-ide--query :go-to-definition args
     (lambda (result)
       (verona-ide--notice result)
       (let ((items (verona-ide--xrefs result)))
         (when items (xref-show-xrefs (lambda () items) nil)))))
    (verona-ide--xrefs data)))
(cl-defmethod xref-backend-references ((_backend (eql verona)) identifier)
  (verona-ide--query :go-to-definition (list verona-ide--module (string-to-number identifier))
   (lambda (data)
     (if (not (= (length (plist-get data :items)) 1))
         (message "Verona: unresolved or ambiguous definition")
       (verona-ide--query :find-references (list (plist-get (car (plist-get data :items)) :id))
        (lambda (result)
          (message "Verona reference coverage complete: %s" (plist-get result :complete-p))
          (let ((items (verona-ide--xrefs result)))
            (when items (xref-show-xrefs (lambda () items) nil)))))))) nil)

(defun verona-ide-flymake (report &rest _)
  "Report cached diagnostics only."
  (when (memq :module-diagnostics verona-ide--operations)
    (verona-ide--query :module-diagnostics (list verona-ide--module :limit 1000)
     (lambda (data)
       (funcall report
        (delq nil
         (mapcar
          (lambda (item)
            (let* ((diag (plist-get item :diagnostic)) (loc (verona-ide--location diag)))
              (when (and loc (equal (plist-get loc :source) verona-ide--path))
                (let ((pos (min (point-max) (1+ (plist-get loc :offset)))))
                  (flymake-make-diagnostic
                   (current-buffer) pos (min (point-max) (1+ pos))
                   (if (eq (plist-get diag :severity) :warning) :warning :error)
                   (plist-get diag :message)))))) (plist-get data :items))))))))

(define-derived-mode verona-ide-expansion-mode special-mode "Verona Expansion"
  "Read-only Verona syntax for macro expansion results."
  :syntax-table verona-mode-syntax-table
  (setq-local font-lock-defaults '(verona-font-lock-keywords)))

(defun verona-ide--view (title operation arguments &optional renderer)
  (verona-ide--query operation arguments
   (lambda (data)
     (let ((origin (current-buffer)))
       (with-current-buffer (get-buffer-create (format "*Verona %s*" title))
         (setq verona-ide--session (buffer-local-value 'verona-ide--session origin)
               verona-ide--connection (buffer-local-value 'verona-ide--connection origin))
         (let ((inhibit-read-only t))
           (erase-buffer)
           (unless (eq operation :inspect-expansion)
             (insert (format "%s — cached analysis\n\n" title)))
           (if renderer
               (funcall renderer data)
             (insert (pp-to-string data)))
           (cl-labels ((links (value)
                         (when (consp value)
                           (when (and (keywordp (car value)) (plist-get value :id)
                                      (or (plist-get value :source-id) (plist-get value :kind)))
                             (insert-text-button
                              (format "Inspect %s" (or (plist-get value :name) "definition"))
                              'action (lambda (_)
                                        (when (buffer-live-p origin)
                                          (with-current-buffer origin
                                            (verona-ide--view
                                             "Details"
                                             (if (plist-get value :source-id) :inspect-module :inspect-definition)
                                             (list (plist-get value :id)))))))
                             (insert "\n"))
                           (let ((loc (ignore-errors (verona-ide--location value))))
                             (when (and loc (file-exists-p (plist-get loc :source)))
                               (insert-text-button "Visit source"
                                'action (lambda (_) (find-file (plist-get loc :source))
                                          (goto-char (min (point-max) (1+ (plist-get loc :offset))))))
                               (insert "\n")))
                           (mapc #'links value)))) (unless renderer (links data)))
           (when (plist-get data :next-offset)
             (insert-text-button "Next page"
              'action (lambda (_) (with-current-buffer origin
                                    (let ((args (copy-sequence arguments)))
                                      (setq args (plist-put args :offset (plist-get data :next-offset)))
                                      (verona-ide--view title operation args))))))
           (goto-char (point-min))
           (if renderer
               (verona-ide-expansion-mode)
             (special-mode))))
       (display-buffer (format "*Verona %s*" title))))))
(defun verona-ide-session ()
  "Inspect the attached session, including its effective project configuration."
  (interactive)
  (verona-ide--view "Session" :inspect-session nil))
(defun verona-ide-modules () (interactive) (verona-ide--view "Modules" :list-modules '(:limit 100)))
(defun verona-ide-module () (interactive) (verona-ide--view "Module" :inspect-module (list verona-ide--module)))
(defun verona-ide-definition ()
  (interactive)
  (verona-ide--query :go-to-definition (list verona-ide--module (verona-ide--offset))
   (lambda (data)
     (dolist (item (plist-get data :items))
       (verona-ide--view "Definition" :inspect-definition (list (plist-get item :id)))))))
(defun verona-ide-related ()
  "Inspect related implementations and expansion origins."
  (interactive)
  (verona-ide--query :go-to-definition (list verona-ide--module (verona-ide--offset))
   (lambda (data)
     (dolist (item (plist-get data :items))
       (verona-ide--view "Related definitions and origins" :related-definitions (list (plist-get item :id)))))))
(defun verona-ide--expansion-text (form)
  "Render tagged expansion FORM, keeping identifiers distinct from strings."
  (cond
   ((eq form :truncated) "…")
   ((and (consp form) (eq (car form) :kind))
    (pcase (plist-get form :kind)
      (:symbol (plist-get form :value))
      (:unit "unit")
      (:boolean (if (plist-get form :value) "true" "false"))
      (_ (prin1-to-string form))))
   ((listp form)
    (concat "(" (mapconcat #'verona-ide--expansion-text form " ") ")"))
   (t (prin1-to-string form))))

(defun verona-ide--insert-expansion (data)
  "Insert the cached expansion result from DATA."
  (cond
   ((eq (plist-get data :status) :unavailable)
    (insert "No cached form at this position.\n"))
   ((eq (plist-get data :expansion-availability) :unavailable)
    (insert "Unavailable. Evaluate this module first.\n"))
   (t (insert (verona-ide--expansion-text (plist-get data :after)) "\n")))
  (when (plist-get data :truncated-p)
    (insert "\nExpansion output truncated.\n")))

(defun verona-ide-expansion ()
  "Show one macro expansion at point, before compiler lowering."
  (interactive)
  (verona-ide--view "Expansion" :inspect-expansion
                    (list verona-ide--module :offset (verona-ide--offset) :limit 4096 :preserve-names t :mode :once)
                    #'verona-ide--insert-expansion))

(defun verona-ide-expansion-full ()
  "Expand the outer macro chain at point, stopping before compiler lowering."
  (interactive)
  (verona-ide--view "Full expansion" :inspect-expansion
                    (list verona-ide--module :offset (verona-ide--offset)
                          :limit 4096 :preserve-names t :mode :full)
                    #'verona-ide--insert-expansion))

(defun verona-ide-expansion-analysis ()
  "Inspect cached expansion steps and analysis metadata at point."
  (interactive)
  (verona-ide--view "Expansion analysis" :inspect-expansion
                    (list verona-ide--module :offset (verona-ide--offset) :limit 4096)))
(defun verona-ide-type () (interactive)
  (verona-ide--view "Type" :type-at-position (list verona-ide--module (verona-ide--offset))))
(defun verona-ide-project-diagnostics () (interactive)
  (verona-ide--view "Project diagnostics" :project-diagnostics '(:limit 100)))
(defun verona-ide--prepare-build (save run)
  (unless verona-ide--session (user-error "Open a project with verona-open-project first"))
  (unless (memq :start-build verona-ide--operations)
    (user-error "Load verona/ide/project on the server to enable builds"))
  (let* ((root verona-ide--root)
         (session verona-ide--session)
         (predicate (lambda ()
                      (or (and buffer-file-name (file-in-directory-p buffer-file-name root))
                          (and (derived-mode-p 'verona-mode)
                               (equal verona-ide--session session)))))
         (options (list :arguments verona-ide-program-arguments
                        :directory verona-ide-program-directory
                        :environment verona-ide-program-environment)))
    (save-some-buffers save predicate)
    (let ((modified (cl-loop for buffer in (buffer-list)
                             when (with-current-buffer buffer (and (funcall predicate) (buffer-modified-p)))
                             collect (buffer-name buffer))))
      (when (and modified
                 (not (yes-or-no-p (format "Build saved files, omitting unsaved changes in %s? "
                                          (mapconcat #'identity modified ", ")))))
        (user-error "Build cancelled; save project buffers first")))
    (verona-ide--sync-project
     (lambda ()
       (verona-ide--rpc :start-build '(:unsaved-buffers :ignore)
        (lambda (data)
          (let ((session verona-ide--session) (connection verona-ide--connection)
                (operations verona-ide--operations)
                (buffer (generate-new-buffer "*Verona build*")))
            (with-current-buffer buffer
              (compilation-mode)
              (setq-local default-directory root
                          verona-ide--root root verona-ide--session session
                          verona-ide--connection connection verona-ide--operations operations
                          verona-ide--build (plist-get data :build)
                          verona-ide--build-run run verona-ide--build-options options)
              (verona-ide--build-append "Verona project build (saved-file snapshot)\n")
              (verona-ide--poll-build))
            (display-buffer buffer))))))))

(defun verona-ide--build-append (text)
  (let ((inhibit-read-only t)) (goto-char (point-max)) (insert text)))

(defun verona-ide--poll-build ()
  (verona-ide--rpc :build-status
   (list verona-ide--build :offset verona-ide--build-offset :error-offset verona-ide--build-error-offset)
   (lambda (data)
     (dolist (key '(:stdout :stderr))
       (verona-ide--build-append (or (plist-get (plist-get data key) :text) "")))
     (setq verona-ide--build-offset (plist-get (plist-get data :stdout) :next-offset)
           verona-ide--build-error-offset (plist-get (plist-get data :stderr) :next-offset))
     (let ((status (plist-get data :status)) (run-status (plist-get data :run-status)))
       (setq mode-line-process (format " %s/%s" status run-status))
       (cond
        ((or (eq status :building) (eq run-status :running)
             (plist-get (plist-get data :stdout) :truncated)
             (plist-get (plist-get data :stderr) :truncated))
         (let ((buffer (current-buffer)))
           (setq verona-ide--build-timer
                 (run-at-time 0.3 nil (lambda () (when (buffer-live-p buffer)
                                                  (with-current-buffer buffer (verona-ide--poll-build))))))))
        ((and (eq status :succeeded) verona-ide--build-run (eq run-status :not-started))
         (setq verona-ide--build-run nil)
         (verona-ide--build-append (format "\nArtifact: %s\nStarting program\n" (plist-get data :artifact)))
         (verona-ide--rpc :start-program (cons verona-ide--build verona-ide--build-options)
          (lambda (_)
            (setq verona-ide--build-offset 0 verona-ide--build-error-offset 0)
            (verona-ide--poll-build))))
        (t
         (verona-ide--build-append
          (format "\nBuild: %s; artifact: %s; program: %s; exit: %s\n"
                  status (or (plist-get data :artifact) "none") run-status (plist-get data :run-exit-status)))
         (dolist (diagnostic (plist-get data :diagnostics))
           (let ((location (plist-get (plist-get diagnostic :location) :start)))
             (verona-ide--build-append
              (if location
                  (format "%s:%s:%s: %s\n" (plist-get location :source) (plist-get location :line)
                          (plist-get location :column) (plist-get diagnostic :message))
                (format "%s\n" (plist-get diagnostic :message))))))))))))

(defun verona-ide-build ()
  "Offer to save project buffers, then build saved files using the session target."
  (interactive) (verona-ide--prepare-build nil nil))
(defun verona-ide-run ()
  "Offer to save and build; run only the successful executable artifact."
  (interactive) (verona-ide--prepare-build nil t))
(defun verona-ide-save-and-build ()
  "Save project buffers and build the session target."
  (interactive) (verona-ide--prepare-build t nil))
(defun verona-ide-save-build-and-run ()
  "Save project buffers, build, and run after success."
  (interactive) (verona-ide--prepare-build t t))
(defun verona-ide-stop-build ()
  "Cancel the build shown in this build-results buffer."
  (interactive) (verona-ide--rpc :cancel-build (list verona-ide--build) #'ignore))
(defun verona-ide-stop-program ()
  "Stop the program shown in this build-results buffer."
  (interactive) (verona-ide--rpc :stop-program (list verona-ide--build) #'ignore))
(defun verona-ide-program-input (text &optional eof)
  "Send TEXT to the program; with prefix, close its input afterward."
  (interactive (list (concat (read-string "Program input: ") "\n") current-prefix-arg))
  (verona-ide--rpc :program-input (list verona-ide--build text :eof (and eof t)) #'ignore))
(defun verona-ide-release-build ()
  "Stop processes and delete this build's snapshot and artifacts."
  (interactive)
  (verona-ide--rpc :release-build (list verona-ide--build)
   (lambda (_) (when (timerp verona-ide--build-timer) (cancel-timer verona-ide--build-timer))
     (setq verona-ide--build nil) (verona-ide--build-append "\nBuild resources released\n"))))

;;;###autoload
(define-minor-mode verona-ide-mode
  "Optional explicit Verona analysis through SLIME."
  :lighter (:eval (concat " V:" (if (and verona-ide--connection (process-live-p verona-ide--connection))
                                    verona-ide--status "disconnected")))
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-e") #'verona-ide-evaluate)
            (define-key map (kbd "C-c C-k") #'verona-ide-cancel)
            (define-key map (kbd "C-c C-d") #'verona-ide-module) map)
  (if verona-ide-mode
      (progn
        (unless verona-ide--session (setq verona-ide-mode nil) (user-error "Select a Verona session first"))
        (add-hook 'after-change-functions #'verona-ide--changed nil t)
        (add-hook 'post-self-insert-hook #'verona-ide--complete-after-colon nil t)
        (add-hook 'after-save-hook #'verona-ide--saved nil t)
        (add-hook 'kill-buffer-hook #'verona-ide--close nil t)
        (add-hook 'completion-at-point-functions #'verona-ide-completion-at-point nil t)
        (add-hook 'eldoc-documentation-functions #'verona-ide-eldoc nil t)
        (add-hook 'xref-backend-functions #'verona-ide-xref-backend nil t)
        (add-hook 'flymake-diagnostic-functions #'verona-ide-flymake nil t))
    (verona-ide--close)
    (cl-incf verona-ide--epoch)
    (setq verona-ide--syncing nil verona-ide--waiters nil)
    (remove-hook 'after-change-functions #'verona-ide--changed t)
    (remove-hook 'post-self-insert-hook #'verona-ide--complete-after-colon t)
    (remove-hook 'after-save-hook #'verona-ide--saved t)
    (remove-hook 'kill-buffer-hook #'verona-ide--close t)
    (remove-hook 'completion-at-point-functions #'verona-ide-completion-at-point t)
    (remove-hook 'eldoc-documentation-functions #'verona-ide-eldoc t)
    (remove-hook 'xref-backend-functions #'verona-ide-xref-backend t)
    (remove-hook 'flymake-diagnostic-functions #'verona-ide-flymake t)))
(defun verona-ide--refresh-active-modes ()
  "Install current hooks in existing IDE buffers after reloading this file."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when verona-ide-mode (verona-ide-mode 1)))))
(verona-ide--refresh-active-modes)

(require 'verona-server)
(provide 'verona-ide)
;;; verona-ide.el ends here
