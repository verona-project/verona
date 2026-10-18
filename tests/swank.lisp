(in-package #:verona/tests)
(def-suite :verona-swank)
(in-suite :verona-swank)

(defmacro with-swank-test (&body body)
  `(let ((verona.swank:*store* (verona.ide:make-session-store))
         (verona.swank::*attachments* (make-hash-table :test 'eq))
         (verona.swank::*connection-ids* (make-hash-table :test 'eq))
         (verona.swank::*requests* (make-hash-table :test 'equal))
         (swank::*emacs-connection* :editor))
     ,@body))

(defun rpc-value (operation &optional id arguments)
  (let ((reply (verona.swank:rpc operation id arguments)))
    (unless (eq :ok (first reply)) (error "RPC failed: ~S" reply))
    (second reply)))

(test swank-protocol-and-query-agreement
  (with-swank-test
    (let* ((capabilities (rpc-value :capabilities))
           (id (rpc-value :create-session nil (list :root (namestring (uiop:getcwd)))))
           (source (rpc-value :open-buffer id '("scratch" "(function value () i64 42)")))
           (key (getf source :id)))
      (is (= 1 (getf capabilities :protocol-version)))
      (is (member :inspect-expansion (getf capabilities :operations)))
      (is (null (verona.ide:module-state verona.swank:*store* id key)))
      (is (equal (rpc-value :list-modules id)
                 (verona.swank::encode (verona.ide:list-modules verona.swank:*store* id))))
      (is (eq :error (first (verona.swank:rpc :no-such-operation id))))
      (is (eq :error (first (verona.swank:rpc :open-buffer id '("missing-text")))))
      (is (eq :error (first (verona.swank:rpc :list-modules id '(:unknown 1)))))
      (is (eq :error (first (verona.swank:rpc :list-modules id '(:limit)))))
      (is (eq :error (first (verona.swank:rpc :list-modules id '(:limit "bad")))))
      (is (eq :error (first (verona.swank:rpc :list-modules id '(1 . 2)))))
      (is (stringp (getf (getf (rpc-value :inspect-session id) :configuration) :root)))
      (verona.swank:disconnect :editor)
      (is (null (gethash :editor verona.swank::*attachments*)))
      (let ((swank::*emacs-connection* :reconnected))
        (is (eq :error (first (verona.swank:rpc :inspect-session id))))
        (is (equal id (rpc-value :attach-session id)))
        (is (= 1 (getf (rpc-value :inspect-session id) :buffers)))))))

(test swank-pending-cancellation-supersession-and-reconnect
  ;; Hold workers before entry to make pending/cancel/supersede deterministic.
  (with-swank-test
    (let* ((spawn (symbol-function 'swank/backend:spawn)) (workers nil)
           (id (rpc-value :create-session))
           (source (rpc-value :open-buffer id '("scratch" "(function value () i64 42)")))
           (key (getf source :id)))
      (unwind-protect
           (progn
             (setf (symbol-function 'swank/backend:spawn)
                   (lambda (function &key name) (declare (ignore name)) (push function workers)))
             (let ((first (getf (rpc-value :evaluate id (list key)) :request)))
               (is (eq :pending (getf (rpc-value :request-status id (list first)) :status)))
               (rpc-value :edit-buffer id '("scratch" "(function value () i64 43)"))
               (rpc-value :list-modules id)
               (is (eq :pending (getf (rpc-value :request-status id (list first)) :status)))
               (rpc-value :cancel-request id (list first))
               (funcall (pop workers))
               (is (eq :cancelled (getf (rpc-value :request-status id (list first)) :status))))
             (let* ((old (getf (rpc-value :evaluate id (list key)) :request))
                    (current (getf (rpc-value :evaluate id (list key)) :request))
                    (run-current (pop workers)) (run-old (pop workers)))
               (is (eq :stale (getf (rpc-value :request-status id (list old)) :status)))
               (verona.swank:disconnect :editor)
               (funcall run-current)
               (funcall run-old)
               (let ((swank::*emacs-connection* :new-editor))
                 (rpc-value :attach-session id)
                 (is (eq :complete (getf (rpc-value :request-status id (list current)) :status)))
                 (is (equal (rpc-value :list-definitions id)
                            (verona.swank::encode
                             (verona.ide:list-definitions verona.swank:*store* id))))
                 (let* ((module (getf (getf (rpc-value :request-status id (list current))
                                            :current-module) :identity))
                        (definition (getf (first (getf (rpc-value :list-definitions id) :items)) :id)))
                   (dolist (call (list (list :inspect-module module)
                                       (list :module-contents module)
                                       (list :module-relationships module)
                                       (list :module-diagnostics module)
                                       (list :position-context module 12)
                                       (list :complete-names module 12)
                                       (list :signature-help module 12)
                                       (list :go-to-definition module 12)
                                       (list :inspect-expansion module :offset 1 :limit 20)
                                       (list :type-at-position module 12)
                                       (list :inspect-definition definition)
                                       (list :definition-type-structure definition)
                                       (list :find-references definition)))
                     (is (equal (rpc-value (first call) id (rest call))
                                (verona.swank::encode
                                 (apply (find-symbol (symbol-name (first call)) :verona.ide)
                                        verona.swank:*store* id (rest call))))))))))
        (setf (symbol-function 'swank/backend:spawn) spawn)))))

(test swank-real-worker-dependencies-and-failures
  (with-swank-test
    (let* ((root (asdf:system-source-directory :verona))
           (id (rpc-value :create-session nil (list :root (namestring root))))
           (token (getf (rpc-value :evaluate id '("tests/modules/app.vrn")) :request)))
      ;; Real background worker, with bounded waiting; the request survives
      ;; disconnect and publishes all transitive dependencies without a client.
      (verona.swank:disconnect :editor)
      (loop repeat 500
            while (eq :pending (verona.ide:request-status
                                (second (gethash token verona.swank::*requests*))))
            do (sleep 0.01))
      (rpc-value :attach-session id)
      (is (eq :complete (getf (rpc-value :request-status id (list token)) :status)))
      (is (= 3 (getf (rpc-value :list-modules id) :total)))
      (rpc-value :open-buffer id '("broken" "(function broken () i64 missing)"))
      (let ((failed (getf (rpc-value :evaluate id '((:buffer "broken"))) :request)))
        (loop repeat 500
              while (eq :pending (verona.ide:request-status
                                  (second (gethash failed verona.swank::*requests*))))
              do (sleep 0.01))
        (is (eq :failed (getf (rpc-value :request-status id (list failed)) :status)))
        (is (plusp (getf (rpc-value :project-diagnostics id) :total)))))))

(test swank-wire-data
  (with-swank-test
    (let* ((id (rpc-value :create-session))
           (encoded (rpc-value :inspect-session id)))
      (is (equal encoded (swank/rpc::read-form (swank/rpc::prin1-to-string-for-emacs encoded (find-package :keyword)) (find-package :keyword)))))
    (is (equal '("/tmp/example.vrn" "x" "NAME")
               (verona.swank::encode (list #P"/tmp/example.vrn" #\x 'name))))))

#+sbcl
(test swank-socket-rpc
  ;; Use the real Swank dispatcher and framing, including Common Lisp RPCs.
  (let* ((existing-threads (sb-thread:list-all-threads))
         (port (swank:create-server :port 0 :style :spawn :dont-close t))
         (socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
         (stream nil))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
           (setf stream (sb-bsd-sockets:socket-make-stream
                         socket :input t :output t :element-type '(unsigned-byte 8)
                                :buffering :none :timeout 5))
           (labels ((call-rpc (form sequence)
                      (swank/rpc::write-message
                       (list :emacs-rex form "CL-USER" t sequence) (find-package :keyword) stream)
                      (loop repeat 20
                            for reply = (swank/rpc::read-message stream (find-package :keyword))
                            when (and (eq :return (first reply)) (= sequence (third reply)))
                              return (second reply)
                            finally (error "No Swank RPC reply"))))
             (let ((reply (call-rpc '(verona.swank:rpc :capabilities) 1)))
               (is (eq :ok (first reply)))
               (is (= 1 (getf (second (second reply)) :protocol-version))))
             (is (equal '(:ok 3) (call-rpc '(+ 1 2) 2)))
             (let* ((id (second (second (call-rpc '(verona.swank:rpc :create-session) 3))))
                    (token nil))
               (call-rpc `(verona.swank:rpc :open-buffer ,id
                                          '("wire" "(function value () i64 42)")) 4)
               (setf token (getf (second (second
                                         (call-rpc `(verona.swank:rpc :evaluate ,id
                                                                     '((:buffer "wire"))) 5))) :request))
               (close stream)
               (loop repeat 500
                     while (getf (verona.ide:inspect-session verona.swank:*store* id) :connections)
                     do (sleep 0.01))
               (is (null (getf (verona.ide:inspect-session verona.swank:*store* id) :connections)))
               (setf socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp))
               (sb-bsd-sockets:socket-connect socket #(127 0 0 1) port)
               (setf stream (sb-bsd-sockets:socket-make-stream
                             socket :input t :output t :element-type '(unsigned-byte 8)
                                    :buffering :none :timeout 5))
               (is (equal (list :ok (list :ok id))
                          (call-rpc `(verona.swank:rpc :attach-session ,id) 6)))
               (let ((info (loop for sequence from 7 below 507
                                 for reply = (call-rpc `(verona.swank:rpc :request-status ,id '(,token)) sequence)
                                 for info = (second (second reply))
                                 until (not (eq :pending (getf info :status)))
                                 do (sleep 0.01)
                                 finally (return info))))
                 (is (eq :complete (getf info :status))))
               (call-rpc `(verona.swank:rpc :close-session ,id) 508))))
      (when stream (close stream))
      (ignore-errors (sb-bsd-sockets:socket-close socket))
      (swank:stop-server port)
      ;; Swank tears connection threads down after the disconnect hook runs.
      ;; Wait before later tests replace functions used by background threads.
      (dolist (thread (set-difference (sb-thread:list-all-threads) existing-threads))
        (ignore-errors (sb-thread:join-thread thread :timeout 5 :default nil))))))

(test swank-unexpected-errors-remain-debuggable
  (with-swank-test
    (let ((id (rpc-value :create-session))
          (original (symbol-function 'verona.ide:list-modules)))
      (unwind-protect
           (progn
             (setf (symbol-function 'verona.ide:list-modules)
                   (lambda (store id &key name source-path status (offset 0) (limit 100))
                     (declare (ignore store id name source-path status offset limit))
                     (error "Unexpected implementation failure")))
             (signals simple-error (verona.swank:rpc :list-modules id)))
        (setf (symbol-function 'verona.ide:list-modules) original)))))

(test swank-targets-reset-close-and-cycle-completeness
  (with-swank-test
    (let* ((id (rpc-value :create-session))
           (other (rpc-value :create-session nil '(:target (:pointer-width 32))))
           (spawn (symbol-function 'swank/backend:spawn)) (worker nil))
      (is (not (equal id other)))
      (is (eq :error (first (verona.swank:rpc :configure-session id '(:target (:pointer-width 32))))))
      (multiple-value-bind (cycles completeness) (verona.ide:dependency-cycles verona.swank:*store* id)
        (is (equal (rpc-value :dependency-cycles id)
                   (verona.swank::encode (list :items cycles :completeness completeness)))))
      (rpc-value :open-buffer id '("closing" "(function value () i64 42)"))
      (unwind-protect
           (progn
             (setf (symbol-function 'swank/backend:spawn)
                   (lambda (function &key name) (declare (ignore name)) (setf worker function)))
             (let ((token (getf (rpc-value :evaluate id '((:buffer "closing"))) :request)))
               (rpc-value :reset-session id)
               (is (eq :error (first (verona.swank:rpc :request-status id (list token)))))
               (funcall worker))
             (let ((token (getf (rpc-value :evaluate id '((:buffer "closing"))) :request)))
               (rpc-value :close-session id)
               (funcall worker)
               (is (null (gethash token verona.swank::*requests*)))
               (is (eq :error (first (verona.swank:rpc :attach-session id)))))
             (is (not (null (rpc-value :inspect-session other)))))
        (setf (symbol-function 'swank/backend:spawn) spawn)))))

#+sb-thread
(test swank-live-progress-and-cancellation
  (with-swank-test
    (let* ((original (symbol-function 'verona.ide:evaluate-request))
           (ready (sb-thread:make-semaphore)) (resume (sb-thread:make-semaphore))
           (finished (sb-thread:make-semaphore))
           (id (rpc-value :create-session)))
      (rpc-value :open-buffer id '("live" "(function value () i64 42)"))
      (unwind-protect
           (progn
             (setf (symbol-function 'verona.ide:evaluate-request)
                   (lambda (store id request &key progress)
                     (declare (ignore progress))
                     (unwind-protect
                          (funcall original store id request
                                   :progress (lambda (request phase)
                                               (declare (ignore request phase))
                                               (sb-thread:signal-semaphore ready)
                                               (sb-thread:wait-on-semaphore resume :timeout 5)))
                       (sb-thread:signal-semaphore finished))))
             (let ((token (getf (rpc-value :evaluate id '((:buffer "live"))) :request)))
               (is (sb-thread:wait-on-semaphore ready :timeout 5))
               (let ((info (rpc-value :request-status id (list token))))
                 (is (eq :pending (getf info :status)))
                 (is (not (null (getf (getf info :current-module) :phase)))))
               (rpc-value :list-modules id)
               (rpc-value :cancel-request id (list token))
               (sb-thread:signal-semaphore resume)
               (is (sb-thread:wait-on-semaphore finished :timeout 5))
               (is (eq :cancelled (getf (rpc-value :request-status id (list token)) :status)))))
        (sb-thread:signal-semaphore resume)
        (setf (symbol-function 'verona.ide:evaluate-request) original)))))

(test swank-project-inspection-before-session-attachment
  (let* ((inspect-symbol 'verona.ide::inspect-project)
         (discover-symbol 'verona.ide::discover-project-configuration)
         (old-inspect (and (fboundp inspect-symbol) (symbol-function inspect-symbol)))
         (old-discover (and (fboundp discover-symbol) (symbol-function discover-symbol))))
    (unwind-protect
         (progn
           (setf (symbol-function discover-symbol) (lambda (root) root)
                 (symbol-function inspect-symbol)
                 (lambda (root)
                   (when (equal root "/missing/")
                     (verona.ide::reject-request "No verona.build found in ~A" root))
                   (list :root root :build-file (concatenate 'string root "verona.build")
                         :targets '((:name "app" :kind :executable)))))
           (with-swank-test
             (is (member :inspect-project (getf (rpc-value :capabilities) :operations)))
             (is (equal "app" (getf (first (getf (rpc-value :inspect-project nil '("/project/")) :targets)) :name)))
             (is (zerop (hash-table-count verona.swank::*attachments*)))
             (let ((reply (verona.swank:rpc :inspect-project nil '("/missing/"))))
               (is (eq :error (first reply)))
               (is (search "No verona.build" (getf (second reply) :message))))))
      (if old-inspect (setf (symbol-function inspect-symbol) old-inspect) (fmakunbound inspect-symbol))
      (if old-discover (setf (symbol-function discover-symbol) old-discover) (fmakunbound discover-symbol)))))
