;;; editor-live.el --- Real SLIME lifecycle acceptance -*- lexical-binding: t; -*-
;; Opt in: run inside nix develop, with SLIME and editors/emacs on load-path.
(require 'ert)
(require 'verona-ide)
(require 'slime)

(defun verona-live--wait (predicate)
  (let ((deadline (+ (float-time) 120)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate)
      (error "Lifecycle timed out (%s); see *Verona server*" verona-server--state))))

(defun verona-live--rpc (op &optional session args)
  (let (done value)
    (let ((slime-dispatching-connection verona-server--connection))
      (slime-eval-async `(verona.swank:rpc ,op ,session (quote ,args))
                        (lambda (reply) (setq done t value reply))))
    (verona-live--wait (lambda () done))
    (should (eq :ok (car value)))
    (cadr value)))

(ert-deftest verona-live-managed-lifecycle ()
  (let* ((root (expand-file-name "projects/ide-workflow/" verona-server-directory))
         (entry (expand-file-name "src/main.vrn" root))
         (model (expand-file-name "src/model.vrn" root))
         (verona-ide--projects nil)
         (process-environment (copy-sequence process-environment))
         one two owned)
    (setenv "VERONA_SOURCE_DIR" (expand-file-name "projects" verona-server-directory))
    (setenv "VERONA_LIBRARY_DIR" (expand-file-name "build" verona-server-directory))
    (unwind-protect
        (progn
          (verona-start-server)
          (verona-live--wait (lambda () (memq verona-server--state '(ready failed stopped))))
          (should (eq verona-server--state 'ready))
          (setq owned verona-server--process)
          (verona-start-server)
          (should (eq owned verona-server--process))
          (verona-open-project root "workflow")
          (verona-live--wait (lambda () (and verona-ide--projects (get-file-buffer entry))))
          (with-current-buffer (get-file-buffer entry)
            (verona-live--wait (lambda () (and verona-ide--source (not verona-ide--syncing))))
            (message "LIVE synchronized")
            (setq one verona-ide--session)
            ;; Opening and synchronization leave analysis untouched.
            (should (cl-every (lambda (m) (eq :unevaluated (plist-get m :status)))
                              (plist-get (verona-live--rpc :list-modules one) :items)))
            (message "LIVE unevaluated boundary verified")
            (verona-ide-evaluate)
            (verona-live--wait (lambda () verona-ide--request))
            (message "LIVE evaluation submitted %s" verona-ide--request)
            (verona-live--wait
             (lambda () (memq (plist-get (verona-live--rpc :request-status one
                                                         (list verona-ide--request)) :status)
                             '(:complete :failed))))
            (should (eq :complete (plist-get (verona-live--rpc :module-state one
                                                                              (list verona-ide--source)) :status)))
            (message "LIVE evaluated")
            ;; The selected target is reused by the actual editor build/run command.
            (cl-letf (((symbol-function 'save-some-buffers) #'ignore)) (verona-ide-run)))
          (let (build-buffer)
            (verona-live--wait
             (lambda () (setq build-buffer
                              (cl-find-if (lambda (b) (buffer-local-value 'verona-ide--build b))
                                          (buffer-list)))))
            (with-current-buffer build-buffer
              (verona-live--wait (lambda () (string-match-p "Build: " (buffer-string))))
              (message "LIVE saved build/run completed")
              (should (string-match-p "program: :exited; exit: 7" (buffer-string)))))
          ;; Disconnect preserves the project session; start reconnects the owned server.
          (delete-process verona-server--connection)
          (verona-start-server)
          (verona-live--wait (lambda () (eq verona-server--state 'ready)))
          (verona-open-project root "workflow")
          (verona-live--wait
           (lambda () (eq verona-server--connection (plist-get (car verona-ide--projects) :connection))))
          (should (equal one (plist-get (car verona-ide--projects) :session)))
          (verona-open-project root "workflow-library")
          (verona-live--wait (lambda () (= 2 (length verona-ide--projects))))
          (setq two (plist-get (car verona-ide--projects) :session))
          (should-not (equal one two))
          (with-current-buffer (get-file-buffer model)
            (verona-live--wait (lambda () (equal two verona-ide--session)))
            (verona-close-project))
          (should (plist-get (verona-live--rpc :inspect-session one) :id))
          (verona-stop-server)
          (verona-live--wait (lambda () (not (process-live-p owned))))
          (should-not verona-ide--projects)
          (verona-stop-server))
      (when (process-live-p verona-server--process)
        (verona-stop-server)
        (verona-live--wait (lambda () (not (process-live-p verona-server--process))))))))

(ert-deftest verona-live-startup-failure-and-crash ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "VERONA_SOURCE_DIR" (expand-file-name "projects" verona-server-directory))
    (setenv "VERONA_LIBRARY_DIR" (expand-file-name "build" verona-server-directory))
    (let ((verona-server-command '("/nonexistent/verona-sbcl")))
      (should-error (verona-start-server) :type 'user-error)
      (should-not (process-live-p verona-server--process))
      (should (buffer-live-p (get-buffer "*Verona help*"))))
    (let ((verona-server-command (list (expand-file-name "build/verona-server" verona-server-directory))))
      (unwind-protect
          (progn
            (verona-start-server)
            (verona-live--wait (lambda () (eq verona-server--state 'ready)))
            (kill-process verona-server--process)
            (verona-live--wait (lambda () (eq verona-server--state 'stopped)))
            (should-not verona-server--connection)
            (verona-start-server)
            (verona-live--wait (lambda () (eq verona-server--state 'ready))))
        (verona-stop-server)
        (verona-live--wait (lambda () (not (process-live-p verona-server--process))))))))

(ert-deftest verona-live-bootstrap-rejects-invalid-environment ()
  ;; Exercise checks after the launch environment has been established, before
  ;; any listener or compiler system can be initialized.
  (dolist (invalid '(("VERONA_SOURCE_DIR" . nil)
                     ("VERONA_LIBRARY_DIR" . "relative/path")
                     ("VERONA_CL_LLVM" . "/nonexistent/verona-llvm")))
    (let ((process-environment (copy-sequence process-environment))
          (ready (make-temp-file "verona-invalid-ready-")))
      (delete-file ready)
      (setenv "VERONA_SOURCE_DIR" verona-server-directory)
      (setenv "VERONA_LIBRARY_DIR" verona-server-directory)
      (setenv (car invalid) (cdr invalid))
      (with-temp-buffer
        (should-not
         (equal 0 (call-process
                   "sbcl" nil t nil "--noinform" "--disable-debugger" "--script"
                   (expand-file-name "scripts/ide-server.lisp" verona-server-directory)
                   verona-server-directory
                   (expand-file-name "swank-loader.lisp" (file-name-directory (locate-library "slime")))
                   "127.0.0.1" "0" ready)))
        (should (string-match-p (car invalid) (buffer-string)))
        (should-not (file-exists-p ready))))))
