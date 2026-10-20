;;; verona-server.el --- Managed Verona server -*- lexical-binding: t; -*-
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(defvar verona-ide--projects)
(defvar slime-dispatching-connection)
(declare-function slime-connect "slime")
(declare-function slime-current-connection "slime")
(declare-function slime-eval-async "slime")
(declare-function slime-net-close "slime")
(defcustom verona-server-directory
  (expand-file-name "../.." (file-name-directory (or load-file-name buffer-file-name)))
  "Verona checkout containing the development environment." :type 'directory :group 'verona-ide)
(defcustom verona-server-command '("verona-server")
  "Literal server launcher command and arguments; defaults to verona-server."
  :type '(repeat string) :group 'verona-ide)
(defcustom verona-server-startup-arguments '("--noinform" "--disable-debugger")
  "SBCL options before the server script; may include --load settings.lisp."
  :type '(repeat string) :group 'verona-ide)
(defcustom verona-server-environment nil
  "Server environment overrides as NAME=value, including package directories."
  :type '(repeat string) :group 'verona-ide)
(defcustom verona-server-host "127.0.0.1" "Swank listening and connection host."
  :type 'string :group 'verona-ide)
(defcustom verona-server-port 0 "Swank port; zero selects an available port."
  :type 'integer :group 'verona-ide)
(defcustom verona-server-startup-timeout 120 "Seconds allowed for server initialization."
  :type 'number :group 'verona-ide)
(defvar verona-server--process nil)
(defvar verona-server--connection nil)
(defvar verona-server--timer nil)
(defvar verona-server--ready-file nil)
(defvar verona-server--deadline nil)
(defvar verona-server--state 'stopped)
(defvar verona-server--address nil)
(defvar verona-server--host nil)

(defun verona-server--resolved-command ()
  "Resolve the configured launcher without changing the saved setting.
For the default command, also check beside Verona, common installation
locations, and the configured checkout's build directory."
  (let* ((program (car verona-server-command))
         (exec-path (append exec-path (parse-colon-path (or (getenv "PATH") ""))))
         (found (and program (executable-find program))))
    (when (and (not found) (equal program "verona-server"))
      (let* ((compiler (executable-find "verona"))
             (candidates
              (append (when compiler
                        (list (expand-file-name "verona-server" (file-name-directory compiler))))
                      (list "/usr/local/bin/verona-server" "/opt/homebrew/bin/verona-server"
                            (expand-file-name "~/.local/bin/verona-server")
                            (expand-file-name "build/verona-server" verona-server-directory)))))
        (setq found (cl-find-if (lambda (file) (and (file-regular-p file) (file-executable-p file)))
                                candidates))))
    (when found (cons found (cdr verona-server-command)))))

(defun verona-server--startup-checklist ()
  "Describe environment settings and launcher availability."
  (let ((command (verona-server--resolved-command)))
    (append (verona-server--environment-checklist)
            (list (list :name "Server launcher" :value (and command (car command))
                        :status (if command 'ok 'missing)
                        :detail (if command "Executable launcher found"
                                  "is unavailable; run make build or make install, or set verona-server-command to its absolute path"))))))

(defun verona-server--environment-checklist ()
  "Describe every environment requirement using the current environment."
  (mapcar
   (lambda (name)
     (let* ((value (getenv name))
            (deferred (and (null value) (equal name "VERONA_CL_LLVM")))
            (problem
             (cond
              ((or (null value) (string-empty-p value)) "is missing")
              ((or (not (file-name-absolute-p value)) (file-remote-p value)
                   (string-prefix-p "~" value)) "must name an absolute local directory")
              ((not (and (file-directory-p value) (file-readable-p value)
                         (file-accessible-directory-p value)))
               "must name an existing readable directory")
              ((and (equal name "VERONA_CL_LLVM")
                    (let ((asd (expand-file-name "llvm.asd" value)))
                      (not (and (file-regular-p asd) (file-readable-p asd)))))
               "must contain a readable llvm.asd"))))
       (list :name name :value value
             :status (cond (deferred 'deferred)
                           ((and problem (or (null value) (string-empty-p value))) 'missing)
                           (problem 'invalid) (t 'ok))
             :detail (cond (deferred "Checked inside the launch environment; Nix normally supplies this value")
                           (problem problem)
                           (t "Existing readable absolute directory")))))
   '("VERONA_SOURCE_DIR" "VERONA_LIBRARY_DIR" "VERONA_CL_LLVM")))

(defun verona-server--show-help (checklist)
  "Display CHECKLIST with setup instructions and lifecycle commands."
  (let ((buffer (get-buffer-create "*Verona help*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Verona setup checklist\n\n")
        (insert "Settings below combine inherited variables and verona-server-environment overrides.\n\n")
        (dolist (item checklist)
          (insert (format "[%s] %s\n  Value: %s\n  %s\n\n"
                          (pcase (plist-get item :status)
                            ('ok "OK") ('missing "MISSING") ('invalid "INVALID")
                            (_ "CHECK ON START"))
                          (plist-get item :name) (or (plist-get item :value) "<unset>")
                          (plist-get item :detail))))
        (insert "Fix MISSING or INVALID items before starting the server.\n"
                "Set absolute directory paths in your environment or customize\n"
                "verona-server-environment (entries use NAME=/absolute/path).\n"
                "VERONA_CL_LLVM must contain llvm.asd. An unset LLVM path is\n"
                "checked after the development shell starts, before Swank loads.\n\n")
        (insert (format "Checkout: %s\nLaunch command: %S\nServer: %s\n\n"
                        verona-server-directory verona-server-command verona-server--state))
        (insert "Developer workflow\n\n"
                "1. M-x verona-start-server — wait for the readiness message.\n"
                "2. M-x verona-open-project — select a project and target.\n"
                "3. C-c C-e — explicitly evaluate the current module.\n"
                "   M-x verona-ide-build / verona-ide-run — build saved files.\n"
                "4. M-x verona-close-project — release the current session.\n"
                "5. M-x verona-stop-server — stop the managed server.\n\n"
                "Startup and project opening never evaluate or build.\n"
                "Server output and initialization failures: *Verona server*.\n"
                "Press g to refresh this checklist, or q to close this view.\n")
        (goto-char (point-min))
        (special-mode)
        (local-set-key (kbd "g") #'verona-help)))
    (display-buffer buffer)))

;;;###autoload
(defun verona-help ()
  "Show the current startup checklist and Verona development commands.
This command does not start a server, evaluate sources, or build a project."
  (interactive)
  (let ((process-environment (append verona-server-environment process-environment)))
    (verona-server--show-help (verona-server--startup-checklist))))

(defun verona-server--validate-environment ()
  "Reject invalid paths and show the complete setup checklist on failure."
  (let* ((checklist (verona-server--startup-checklist))
         (errors (cl-remove-if-not
                  (lambda (item) (memq (plist-get item :status) '(missing invalid))) checklist)))
    (when errors
      (verona-server--show-help checklist)
      (user-error "Cannot start Verona: %s. See *Verona help*"
                  (mapconcat (lambda (item) (format "%s %s" (plist-get item :name)
                                                   (plist-get item :detail))) errors "; ")))))

(defun verona-server--cancel-wait ()
  (when (timerp verona-server--timer) (cancel-timer verona-server--timer))
  (setq verona-server--timer nil)
  (when (and verona-server--ready-file (file-exists-p verona-server--ready-file))
    (delete-file verona-server--ready-file))
  (setq verona-server--ready-file nil))

(defun verona-server--forget-connection ()
  (let ((connection verona-server--connection))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and connection (eq verona-ide--connection connection))
          (setq verona-ide--connection nil)
          (when verona-ide-mode (verona-ide-mode -1))
          (when (timerp verona-ide--build-timer) (cancel-timer verona-ide--build-timer))
          (setq verona-ide--session nil verona-ide--connection nil
                verona-ide--request nil verona-ide--cache nil
                verona-ide--status "disconnected"))))
    (setq verona-ide--projects
          (cl-remove-if (lambda (p) (eq connection (plist-get p :connection)))
                        verona-ide--projects))
    (when (and connection (process-live-p connection)) (slime-net-close connection))
    (setq verona-server--connection nil)))

(defun verona-server--failed (reason)
  (verona-server--cancel-wait)
  (setq verona-server--state 'failed)
  (when (process-live-p verona-server--process) (delete-process verona-server--process))
  (verona-server--forget-connection)
  (with-current-buffer (get-buffer-create "*Verona server*")
    (goto-char (point-max)) (insert (format "\nStartup failed: %s\n" reason)))
  (display-buffer "*Verona server*")
  (message "Verona server: %s; see *Verona server*" reason))

(defun verona-server--connected ()
  ;; SLIME invokes this only after its own initialization and contrib loading.
  (when (and (eq verona-server--state 'connecting)
             (eq (slime-current-connection) verona-server--connection))
    (let ((slime-dispatching-connection verona-server--connection))
      (slime-eval-async
       '(verona.swank:rpc :capabilities)
       (lambda (reply)
         (when (eq verona-server--state 'connecting)
           (let ((caps (cadr reply)))
             (if (and (eq (car reply) :ok)
                      (equal (plist-get caps :protocol-version) 1)
                      (cl-every (lambda (op) (memq op (plist-get caps :operations)))
                                '(:inspect-project :create-project-session :close-session :start-build)))
                 (progn (verona-server--cancel-wait)
                        (setq verona-server--state 'ready)
                        (message "Verona ready at %s; use verona-open-project" verona-server--address))
               (verona-server--failed "adapter capability check failed")))))))))

(defun verona-server--poll ()
  (condition-case err
      (cond
       ((not (process-live-p verona-server--process))
        (verona-server--failed "process exited during startup"))
       ((> (float-time) verona-server--deadline)
        (verona-server--failed "initialization timed out"))
       ((and (eq verona-server--state 'starting)
             (file-exists-p verona-server--ready-file))
        (let ((port (with-temp-buffer
                      (insert-file-contents verona-server--ready-file)
                      (string-to-number (buffer-string)))))
          (when (> port 0)
            (setq verona-server--state 'connecting
                  verona-server--address (format "%s:%s" verona-server-host port)
                  verona-server--connection (slime-connect verona-server--host port)))))
       ((and (eq verona-server--state 'connecting) verona-server--connection
             (not (process-live-p verona-server--connection)))
        (verona-server--failed "SLIME connection closed")))
    (error (verona-server--failed (error-message-string err)))))

;;;###autoload
(defun verona-start-server ()
  "Start a managed server asynchronously, then connect and check SLIME."
  (interactive)
  (require 'slime)
  (if (process-live-p verona-server--process)
      (if (and (eq verona-server--state 'ready)
               (not (process-live-p verona-server--connection)))
          (progn
            (setq verona-server--state 'connecting
                  verona-server--deadline (+ (float-time) verona-server-startup-timeout))
            (let* ((parts (split-string verona-server--address ":"))
                   (port (string-to-number (car (last parts)))))
              (setq verona-server--connection (slime-connect verona-server--host port)))
            (setq verona-server--timer (run-at-time 0.1 0.1 #'verona-server--poll)))
        (message "Verona server %s (%s)" verona-server--state verona-server--address))
    (verona-server--cancel-wait)
    (let* ((process-environment (append verona-server-environment process-environment))
           (default-directory (file-name-as-directory (expand-file-name verona-server-directory)))
           (loader (expand-file-name "swank-loader.lisp" (file-name-directory (locate-library "slime")))))
      (verona-server--validate-environment)
      (setq verona-server--ready-file (make-temp-file "verona-ready-")
            verona-server--deadline (+ (float-time) verona-server-startup-timeout)
            verona-server--state 'starting
            verona-server--host verona-server-host)
      (add-hook 'slime-connected-hook #'verona-server--connected)
      (condition-case err
          (progn
            (setq verona-server--process
                  (make-process
                   :name "Verona server" :buffer (get-buffer-create "*Verona server*")
                   :connection-type 'pipe :noquery t
                   :command (append (verona-server--resolved-command) verona-server-startup-arguments
                                    (list "--" default-directory loader verona-server-host
                                          (number-to-string verona-server-port) verona-server--ready-file))
                   :sentinel (lambda (process event)
                               (when (and (eq process verona-server--process)
                                          (not (process-live-p process)))
                                 (verona-server--cancel-wait)
                                 (verona-server--forget-connection)
                                 (setq verona-server--state 'stopped)
                                 (message "Verona server %s; output in *Verona server*" (string-trim event))))))
            (setq verona-server--timer (run-at-time 0.1 0.1 #'verona-server--poll))
            (message "Starting Verona; output in *Verona server*"))
        (error (verona-server--failed (error-message-string err)))))))

;;;###autoload
(defun verona-stop-server ()
  "Release all sessions and stop only the process started by this editor."
  (interactive)
  (verona-server--cancel-wait)
  (if (process-live-p verona-server--process)
      (progn
        (setq verona-server--state 'stopping)
        (verona-server--forget-connection)
        (process-send-string verona-server--process "STOP\n")
        (message "Stopping Verona and releasing its project resources"))
    (verona-server--forget-connection)
    (setq verona-server--state 'stopped)
    (message "Verona server already stopped")))
(provide 'verona-server)
;;; verona-server.el ends here
