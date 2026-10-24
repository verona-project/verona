(in-package #:verona/tests)
(in-suite :verona)

(defun workflow-project ()
  (asdf:system-relative-pathname :verona "projects/ide-workflow/"))

(test ide-representative-analysis-workflow
  (let* ((root (workflow-project))
         (store (verona.ide:make-session-store))
         (id (verona.ide:create-session store
               (verona.ide:make-configuration :root root
                 :search-paths (list (merge-pathnames "src/" root)))))
         (main (namestring (truename (merge-pathnames "src/main.vrn" root))))
         (leaf (namestring (truename (merge-pathnames "src/leaf.vrn" root))))
         (model (namestring (truename (merge-pathnames "src/model.vrn" root))))
         (other (merge-pathnames "src/unrelated.vrn" root)))
    (unwind-protect
         (progn
           (verona.ide:open-buffer store id "main" (uiop:read-file-string main) :path main)
           (verona.ide:open-buffer store id "leaf" (uiop:read-file-string leaf) :path leaf)
           (is (null (verona.ide:module-state store id main)))
           (is (eq :complete (verona.ide:request-status (verona.ide:evaluate-module store id main))))
           (dolist (path (list main model leaf))
             (is (eq :complete (getf (verona.ide:module-state store id path) :status))))
           (dolist (kind '(:macro :generic :protocol :implementation))
             (is (plusp (getf (verona.ide:list-definitions store id :kind kind) :total))))
           (verona.ide:evaluate-module store id other)
           (let ((cached (verona.ide:query-result store id leaf))
                 (unrelated (verona.ide:module-state store id (namestring (truename other)))))
             (verona.ide:evaluate-module store id main)
             (is (not (eq cached (verona.ide:query-result store id leaf))))
             ;; Edits and read-only queries preserve all evaluated products.
             (verona.ide:edit-buffer store id "leaf"
               "(function answer () exit-code 9) (export answer)")
             (verona.ide:list-definitions store id)
             (verona.ide:project-diagnostics store id)
             (is (not (eq cached (verona.ide:query-result store id leaf))))
             (is (eq :complete (getf (verona.ide:module-state store id main) :status)))
             (verona.ide:evaluate-module store id leaf)
             (is (eq :needs-evaluation (getf (verona.ide:module-state store id main) :status)))
             (is (eq :needs-evaluation (getf (verona.ide:module-state store id model) :status)))
             (is (equalp unrelated (verona.ide:module-state store id (namestring (truename other)))))
             (is (eq :complete (verona.ide:request-status (verona.ide:evaluate-module store id main)))))
           ;; A failed dependency replaces success, then recovery clears diagnostics.
           (verona.ide:edit-buffer store id "leaf"
             "(function broken () exit-code missing-workflow-value)")
           (is (eq :failed (verona.ide:request-status (verona.ide:evaluate-module store id main))))
           (let ((key (getf (verona.ide:module-state store id leaf) :identity)))
             (is (eq :partial (getf (verona.ide:module-diagnostics store id key) :availability)))
             (is (plusp (getf (verona.ide:module-diagnostics store id key) :total)))
             (is (zerop (getf (verona.ide:module-contents store id key :name "answer") :total)))
             (is (null (verona.ide:query-result store id leaf)))
             (verona.ide:edit-buffer store id "leaf" (uiop:read-file-string leaf))
             (is (eq :complete (verona.ide:request-status (verona.ide:evaluate-module store id main))))
             (is (zerop (getf (verona.ide:module-diagnostics store id key) :total)))))
      (verona.ide:close-session store id))))
