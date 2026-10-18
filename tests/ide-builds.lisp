(in-package #:verona/tests)
(in-suite :verona)

(defun ide-build-write (path text)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede) (write-string text out)))

(defmacro with-ide-build-project ((store id root) &body body)
  `(let* ((,root (merge-pathnames (format nil "ide-build-test-~A/" (gensym)) (uiop:temporary-directory)))
          (,store (verona.ide:make-session-store)) (,id nil))
     (unwind-protect
          (progn
            (ide-build-write (merge-pathnames "verona.build" ,root)
                            "(executable app (root main) (module-path \"src\"))
                             (static-library lib (root dep) (module-path \"src\"))")
            (ide-build-write (merge-pathnames "src/main.vrn" ,root)
                            "(import dep) (function main () exit-code (dep:answer))")
            (ide-build-write (merge-pathnames "src/dep.vrn" ,root)
                            "(function answer () exit-code 7) (export answer)")
            (setf ,root (truename ,root)
                  ,id (verona.ide:create-session
                       ,store (verona.ide:make-configuration
                               :root ,root :build-file (merge-pathnames "verona.build" ,root)
                               :build-target "app" :search-paths (list (merge-pathnames "src/" ,root)))))
            ,@body)
       (when ,id (verona.ide:close-session ,store ,id))
       (uiop:delete-directory-tree ,root :validate t :if-does-not-exist :ignore))))

(defun wait-ide-build (store id token &key run)
  (loop repeat 3000 for data = (verona.ide:build-status store id token)
        when (if run (not (eq :running (getf data :run-status)))
                     (not (eq :building (getf data :status)))) return data
        do (sleep 0.02)
        finally (error "Build timeout: ~S" (verona.ide:build-status store id token))))

(test ide-representative-edit-evaluate-build-run-workflow
  ;; Work on a disposable copy: acceptance fixtures must remain repeatable.
  (with-ide-build-project (store id root)
    (let* ((fixture (asdf:system-relative-pathname :verona "projects/ide-workflow/"))
           (main (namestring (merge-pathnames "src/main.vrn" root)))
           (leaf (merge-pathnames "src/leaf.vrn" root)))
      (dolist (relative '("verona.build" "src/main.vrn" "src/model.vrn" "src/leaf.vrn"
                          "src/unrelated.vrn" "src/broken.vrn"))
        (ide-build-write (merge-pathnames relative root)
                         (uiop:read-file-string (merge-pathnames relative fixture))))
      (verona.ide:close-session store id)
      (setf id (verona.ide:create-session store
                 (verona.ide:make-configuration :root root
                   :build-file (merge-pathnames "verona.build" root) :build-target "workflow"
                   :search-paths (list (merge-pathnames "src/" root)))))
      (verona.ide:open-buffer store id "main" (uiop:read-file-string main) :path main)
      (verona.ide:open-buffer store id "leaf" (uiop:read-file-string leaf) :path leaf)
      (is (eq :complete (verona.ide:request-status (verona.ide:evaluate-module store id main))))
      (verona.ide:edit-buffer store id "leaf" "(function answer () exit-code 9) (export answer)")
      (is (eq :complete (verona.ide:request-status (verona.ide:evaluate-module store id main))))
      (let ((evaluated (verona.ide:module-state store id main)))
        (signals verona.ide:request-error (verona.ide:start-build store id))
        ;; Explicitly ignoring the overlay runs the saved 7, not evaluated 9.
        (let* ((token (getf (verona.ide:start-build store id :unsaved-buffers :ignore) :build))
               (built (wait-ide-build store id token)))
          (is (eq :succeeded (getf built :status)))
          (verona.ide:start-program store id token)
          (is (= 7 (getf (wait-ide-build store id token :run t) :run-exit-status))))
        ;; Saving does not replace analysis. IDE and CLI now both run 9.
        (ide-build-write leaf "(function answer () exit-code 9) (export answer)")
        (verona.ide:save-buffer store id "leaf")
        (is (equalp evaluated (verona.ide:module-state store id main)))
        (let* ((token (getf (verona.ide:start-build store id) :build))
               (built (wait-ide-build store id token))
               (cli (verona.compiler:execute-build
                      (verona.compiler:parse-build-file (merge-pathnames "verona.build" root))
                      (verona.compiler:make-build-invocation "workflow" (merge-pathnames "cli/" root)))))
          (is (eq :succeeded (getf built :status)))
          (verona.ide:start-program store id token)
          (multiple-value-bind (out err code)
              (uiop:run-program (list (namestring (verona.compiler:artifact-path cli)))
                                :output :string :error-output :string :ignore-error-status t)
            (is (equal '("" "" 9) (list out err code)))
            (let ((run (wait-ide-build store id token :run t)))
              (is (= code (getf run :run-exit-status)))
              (is (equal out (getf (getf run :stdout) :text)))
              (is (equal err (getf (getf run :stderr) :text)))))
          (is (equalp evaluated (verona.ide:module-state store id main))))
        ;; The other representative targets distinguish semantic and link failures.
        (dolist (target '("analysis-failure" "link-failure"))
          (let ((failure-session
                  (verona.ide:create-session store
                    (verona.ide:make-configuration :root root
                      :build-file (merge-pathnames "verona.build" root) :build-target target
                      :search-paths (list (merge-pathnames "src/" root))))))
            (unwind-protect
                 (let* ((source (merge-pathnames
                                 (if (string= target "analysis-failure") "src/broken.vrn" "src/main.vrn") root))
                        (request (verona.ide:evaluate-module store failure-session source))
                        (token (getf (verona.ide:start-build store failure-session) :build))
                        (failure (wait-ide-build store failure-session token)))
                   (is (eq (if (string= target "analysis-failure") :failed :complete)
                           (verona.ide:request-status request)))
                   (is (eq :failed (getf failure :status)))
                   (is (null (getf failure :artifact)))
                   (is (not (null (getf failure :diagnostics))))
                   (signals verona.ide:request-error
                     (verona.ide:start-program store failure-session token)))
              (verona.ide:close-session store failure-session))))
        (is (equalp evaluated (verona.ide:module-state store id main)))))))

(test ide-build-saved-snapshot-and-analysis-isolation
  (with-ide-build-project (store id root)
    (let* ((main (namestring (merge-pathnames "src/main.vrn" root)))
           (dep (merge-pathnames "src/dep.vrn" root)))
      (verona.ide:open-buffer store id "main" (uiop:read-file-string main) :path main)
      (verona.ide:evaluate-module store id main)
      (let ((state (verona.ide:module-state store id main)))
        (verona.ide:edit-buffer store id "main" "unsaved invalid source")
        (signals verona.ide:request-error (verona.ide:start-build store id))
        (let ((cli (verona.compiler:execute-build
                    (verona.compiler:parse-build-file (merge-pathnames "verona.build" root))
                    (verona.compiler:make-build-invocation "app" (merge-pathnames "cli/" root)))))
          (multiple-value-bind (out err code)
              (uiop:run-program (list (namestring (verona.compiler:artifact-path cli)))
                                :output :string :error-output :string :ignore-error-status t)
            (is (equal '("" "" 7) (list out err code)))))
        (let* ((token (getf (verona.ide:start-build store id :unsaved-buffers :ignore) :build)))
          ;; Both dependency and build metadata change after submission.
          (ide-build-write dep "invalid after snapshot")
          (ide-build-write (merge-pathnames "verona.build" root) "invalid after snapshot")
          (let ((data (wait-ide-build store id token)))
            (is (eq :succeeded (getf data :status)) (getf data :stderr))
            (is (= 2 (length (getf data :inputs))))
            (is (probe-file (getf data :artifact)))
            (is (equalp state (verona.ide:module-state store id main)))
            (verona.ide:start-program store id token)
            (is (= 7 (getf (wait-ide-build store id token :run t) :run-exit-status)))
            (is (string= "unsaved invalid source" (verona.ide:source-text (verona.ide:read-source store id main))))
            (verona.ide:release-build store id token)
            (is (not (probe-file token)))))))))

(test ide-build-failure-cancellation-and-target-selection
  (with-ide-build-project (store id root)
    (let* ((bad (merge-pathnames "src/dep.vrn" root)))
      (ide-build-write bad "(function answer () exit-code missing)")
      (let* ((token (getf (verona.ide:start-build store id) :build))
             (data (wait-ide-build store id token))
             (cli (handler-case
                      (verona.compiler:execute-build
                       (verona.compiler:parse-build-file (merge-pathnames "verona.build" root))
                       (verona.compiler:make-build-invocation "app" (merge-pathnames "cli/" root)))
                    (verona:user-compilation-error (c) (verona:diagnostic-for-condition c)))))
        (is (eq :failed (getf data :status)))
        (is (null (getf data :artifact)))
        (is (equal (verona:diagnostic-code cli) (getf (first (getf data :diagnostics)) :code)))
        (is (equal (namestring bad)
                   (getf (getf (getf (first (getf data :diagnostics)) :location) :start) :source)))
        (signals verona.ide:request-error (verona.ide:start-program store id token)))
      (let ((token (getf (verona.ide:start-build store id) :build)))
        (is (eq :cancelled (verona.ide:cancel-build store id token)))
        (is (null (getf (verona.ide:build-status store id token) :artifact)))
        (signals verona.ide:request-error (verona.ide:start-program store id token)))
      (ide-build-write bad "(function answer () exit-code 0) (export answer)")
      (let* ((library (verona.ide:create-session
                       store (verona.ide:make-configuration :root root
                              :build-file (merge-pathnames "verona.build" root) :build-target "lib"
                              :search-paths (list (merge-pathnames "src/" root)))))
             (token (getf (verona.ide:start-build store library) :build)))
        (is (eq :succeeded (getf (wait-ide-build store library token) :status)))
        (signals verona.ide:request-error (verona.ide:start-program store library token))
        (verona.ide:close-session store library)
        (is (not (probe-file token)))))))

(test ide-program-streams-arguments-environment-directory-and-stop
  (with-ide-build-project (store id root)
    (let* ((token (getf (verona.ide:start-build store id) :build))
           (data (wait-ide-build store id token)))
      (is (eq :succeeded (getf data :status)))
      ;; A shell fixture exercises process controls independently of Verona's ABI.
      (ide-build-write (getf data :artifact)
                      "#!/bin/sh
printf '%s:%s:' \"$1\" \"$IDE_BUILD_TEST\"
pwd
read line
printf '%s' \"$line\"
printf 'error stream' >&2
exit 9
")
      (verona.ide:start-program store id token :arguments '("space ; literal")
                                :directory (namestring root) :environment '("IDE_BUILD_TEST=override"))
      (verona.ide:program-input store id token (format nil "hello~%") :eof t)
      (let ((result (wait-ide-build store id token :run t)))
        (is (= 9 (getf result :run-exit-status)))
        (is (search "space ; literal:override:" (getf (getf result :stdout) :text)))
        (is (search (string-right-trim "/" (namestring root)) (getf (getf result :stdout) :text)))
        (is (search "hello" (getf (getf result :stdout) :text)))
        (is (string= "error stream" (getf (getf result :stderr) :text))))
      (ide-build-write (getf data :artifact) "#!/bin/sh
read line
")
      (verona.ide:start-program store id token)
      (is (eq :stopped (verona.ide:stop-program store id token)))
      (signals verona.ide:request-error (verona.ide:program-input store id token "late"))
      (let ((result (verona.ide:build-status store id token :limit 1)))
        (is (<= (length (getf (getf result :stdout) :text)) 1)))
      (signals verona.ide:request-error (verona.ide:build-status store id token :limit 999999)))))

(test ide-build-linker-failure-never-reuses-successful-artifact
  (with-ide-build-project (store id root)
    (let* ((token (getf (verona.ide:start-build store id) :build))
           (success (wait-ide-build store id token))
           (job (gethash token (verona.ide::session-store-build-jobs store)))
           (triple (verona.ide::build-job-artifact-target job)))
      (is (eq :succeeded (getf success :status)))
      (unwind-protect
           (progn
             (setf (verona.ide::build-job-artifact-target job) "incompatible-test-target")
             (signals verona.ide:request-error (verona.ide:start-program store id token)))
        (setf (verona.ide::build-job-artifact-target job) triple))
      (ide-build-write (merge-pathnames "verona.build" root)
                      "(executable app (root main) (module-path \"src\")
                         (library \"verona_missing_library_for_build_test\"))")
      (let* ((failed-token (getf (verona.ide:start-build store id) :build))
             (failure (wait-ide-build store id failed-token)))
        (is (eq :failed (getf failure :status)))
        (is (null (getf failure :artifact)))
        (is (plusp (length (getf (getf failure :stderr) :text))))
        (is (not (null (getf failure :diagnostics))))
        (is (probe-file (getf success :artifact)))
        (signals verona.ide:request-error (verona.ide:start-program store id failed-token))))))
