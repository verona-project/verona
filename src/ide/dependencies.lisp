(in-package #:verona.ide)

;; Edges belong to the evaluation that discovered them. Index the same edge
;; objects in both directions, removing by identity when their owner is replaced.
(defun remove-outgoing-dependencies (s module)
  (dolist (edge (gethash module (session-dependencies s)))
    (let* ((target (getf edge :target))
           (remaining (remove edge (gethash target (session-reverse-dependencies s)))))
      (if remaining
          (setf (gethash target (session-reverse-dependencies s)) remaining)
          (remhash target (session-reverse-dependencies s)))))
  (remhash module (session-dependencies s)))

(defun dependent-module-paths (s root)
  "Return each reachable dependent once with an edge path back to ROOT."
  (let ((seen (list root)) (queue (list (list root nil))) (found nil))
    (loop while queue do
      (destructuring-bind (module path) (pop queue)
        (dolist (edge (gethash module (session-reverse-dependencies s)))
          (let ((owner (getf edge :module)))
            (unless (member owner seen :test 'equal)
              (push owner seen)
              (let ((entry (list owner (cons edge path))))
                (push entry found)
                (setf queue (nconc queue (list entry)))))))))
    found))

(defun replace-module-dependencies (s key source-id)
  ;; A changed module context at the same source also replaces the old owner.
  (let ((roots (remove-duplicates
                (cons key (loop for state being the hash-values of (session-modules s)
                                when (equal source-id (module-evaluation-source-id state))
                                  collect (module-evaluation-identity state))) :test 'equal)))
    (dolist (root roots)
      (dolist (entry (dependent-module-paths s root))
        (destructuring-bind (module path) entry
          (let ((state (gethash module (session-modules s))))
            (when (and state (not (member module roots :test 'equal)))
              (setf (module-evaluation-status state) :needs-evaluation)
              (pushnew (list :kind :dependency :changed-module root :path path)
                       (module-evaluation-reasons state) :test 'equal)))))
      (remove-outgoing-dependencies s root))))

(defun validate-dependency (edge)
  (unless (and (listp edge) (evenp (length edge))
               (member (getf edge :kind) '(:import :semantic :macro :binding :expanded))
               (listp (getf edge :target)) (= 2 (length (getf edge :target)))
               (every 'identity (getf edge :target))
               (member (getf edge :cycle-policy :allowed) '(:allowed :forbidden)))
    (error "Invalid dependency descriptor ~S" edge))
  (when (and (getf edge :unresolved) (not (getf edge :lookup-context)))
    (error "Unresolved dependencies require lookup context")))

(defun record-dependencies (store id request edges)
  "Add discovered edges to the current request. No application code is evaluated.
Each edge has :KIND and :TARGET (module identity), and optional :FROM/:TO
(definition identities), :LOCATION, :ALIAS, :SELECTED, :UNRESOLVED,
:LOOKUP-CONTEXT and :CYCLE-POLICY. Calls append discoveries without duplicates."
  (serialized (store)
    (let* ((s (require-session store id)) (state (current-request-state s request)))
      (unless state (return-from record-dependencies (request-status request)))
      ;; Validate the whole batch before changing either index.
      (mapc 'validate-dependency edges)
      (dolist (descriptor edges)
        (let* ((edge (copy-value descriptor)) (owner (request-module-key request)))
          (setf (getf edge :module) (copy-value owner))
          (unless (member edge (gethash owner (session-dependencies s)) :test 'equal)
            (push edge (gethash owner (session-dependencies s)))
            (push edge (gethash (getf edge :target) (session-reverse-dependencies s))))))
      (request-status request))))

(defun graph-node (module definition) (list module definition))
(defun edge-origin (edge level)
  (graph-node (getf edge :module) (and (eq level :definition) (getf edge :from))))
(defun edge-destination (edge level)
  (graph-node (getf edge :target) (and (eq level :definition) (getf edge :to))))

(defun graph-edges (s node direction level)
  (let ((edges (gethash (first node)
                        (if (eq direction :dependencies) (session-dependencies s)
                            (session-reverse-dependencies s)))))
    (if (eq level :module) edges
        (remove-if-not (lambda (edge)
                         (equal node (if (eq direction :dependencies)
                                         (edge-origin edge level) (edge-destination edge level))))
                       edges))))

(defun dependency-graph (store id module &key definition (level :module)
                                             (direction :dependencies) transitive imports-only)
  "Return a copied relationship snapshot. MODULE is the full module identity.
Completeness covers every visited module, including missing target modules."
  (unless (member level '(:module :definition)) (error "Unknown graph level"))
  (unless (member direction '(:dependencies :dependents)) (error "Unknown direction"))
  (serialized (store)
    (let* ((s (require-session store id)) (start (graph-node module definition))
           (queue (list start)) (seen nil) (edges nil) (incomplete nil))
      (loop while queue do
        (let* ((node (pop queue)) (state (gethash (first node) (session-modules s))))
          (unless (member node seen :test 'equal)
            (push node seen)
            (unless (and state (module-evaluation-dependencies-complete state))
              (pushnew (first node) incomplete :test 'equal))
            (dolist (edge (graph-edges s node direction level))
              (when (or (not imports-only) (eq :import (getf edge :kind)))
                (pushnew edge edges :test 'eq)
                (when transitive
                  (push (if (eq direction :dependencies)
                            (edge-destination edge level) (edge-origin edge level)) queue)))))))
      (copy-value (list :edges (nreverse edges) :complete (null incomplete)
                        :incomplete-modules incomplete
                        :needs-evaluation-reasons
                        (let ((state (gethash module (session-modules s))))
                          (and state (module-evaluation-reasons state))))))))

(defun dependency-cycles (store id &key (level :module))
  "Return cycles with their edges and source locations. A cycle is invalid when
an analysis caller marks any participating edge :CYCLE-POLICY :FORBIDDEN.
Language-specific legality is supplied by the resolver, not inferred from names."
  (unless (member level '(:module :definition)) (error "Unknown graph level"))
  (serialized (store)
    (let ((s (require-session store id)) (cycles nil) (signatures nil))
      (labels ((visit (node nodes path)
                 (dolist (edge (graph-edges s node :dependencies level))
                   (unless (getf edge :unresolved)
                     (let* ((target (edge-destination edge level))
                            (position (position target nodes :test 'equal)))
                       (if position
                           (let ((cycle (append (nthcdr position path) (list edge))))
                             (unless (some (lambda (signature)
                                             (and (= (length signature) (length cycle))
                                                  (every (lambda (e) (member e signature :test 'eq)) cycle)))
                                           signatures)
                               (push cycle signatures)
                               (push (list :status (if (some (lambda (e) (eq :forbidden (getf e :cycle-policy))) cycle)
                                                       :invalid :allowed)
                                           :edges cycle) cycles)))
                           (visit target (append nodes (list target)) (append path (list edge)))))))))
        (maphash (lambda (module edges)
                   (declare (ignore module))
                   (dolist (edge edges)
                     (let ((node (edge-origin edge level))) (visit node (list node) nil))))
                 (session-dependencies s)))
      (copy-value (nreverse cycles)))))
