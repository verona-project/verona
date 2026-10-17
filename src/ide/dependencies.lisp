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
    ;; Unresolved imports may have been recorded before their module context
    ;; was known. Canonical source identity still recognizes their arrival.
    (maphash (lambda (owner edges)
               (declare (ignore owner))
               (dolist (edge edges)
                 (when (and (getf edge :unresolved)
                            (equal source-id (second (getf edge :target))))
                   (pushnew (getf edge :target) roots :test #'equal))))
             (session-dependencies s))
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
    (query-dependency-graph (require-session store id) module definition level direction transitive imports-only)))

(defun query-dependency-graph (s module definition level direction transitive imports-only)
  (let* ((start (graph-node module definition))
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
                        (and state (module-evaluation-reasons state)))))))

(defun cycle-graph-snapshot (store id)
  "Copy edges and completeness under the mutex; traversal uses only this copy."
  (serialized (store)
    (let* ((s (require-session store id)) (edges nil)
           (incomplete (make-hash-table :test 'equal)))
      (labels ((check-module (module)
                 (let ((state (gethash module (session-modules s))))
                   (unless (and state (module-evaluation-dependencies-complete state))
                     (setf (gethash module incomplete) t)))))
        (maphash (lambda (module state)
                   (declare (ignore state))
                   (check-module module)) (session-modules s))
        (maphash (lambda (module outgoing)
                   (check-module module)
                   (dolist (edge outgoing)
                     (push (copy-value edge) edges)
                     (check-module (getf edge :target))
                     ;; Unknown edges cannot establish cycles or prove their
                     ;; absence, even if discovery of their owner completed.
                     (when (getf edge :unresolved)
                       (setf (gethash module incomplete) t))))
                 (session-dependencies s)))
      (values edges
              (list :complete (zerop (hash-table-count incomplete))
                    :incomplete-modules
                    (loop for module being the hash-keys of incomplete collect (copy-value module)))))))

(defstruct cycle-component nodes edges forbidden)

(defun cyclic-components (edges level)
  "Iterative Kosaraju traversal: O(V + E) time and space, including parallel edges.
Return one cyclic component, rather than enumerate every elementary cycle."
  (let ((forward (make-hash-table :test 'equal))
        (reverse (make-hash-table :test 'equal))
        (nodes (make-hash-table :test 'equal))
        (seen (make-hash-table :test 'equal))
        (component-of (make-hash-table :test 'equal))
        (order nil) (components nil))
    (dolist (edge edges)
      (unless (getf edge :unresolved)
        (let ((from (edge-origin edge level)) (to (edge-destination edge level)))
          (setf (gethash from nodes) t (gethash to nodes) t)
          (push to (gethash from forward))
          (push from (gethash to reverse)))))
    ;; Each frame stores a node and the remaining adjacency list. Explicit
    ;; stacks also avoid exhausting the Lisp call stack on long import chains.
    (maphash
     (lambda (root present)
       (declare (ignore present))
       (unless (gethash root seen)
         (setf (gethash root seen) t)
         (let ((stack (list (cons root (gethash root forward)))))
           (loop while stack do
             (let ((frame (first stack)))
               (if (cdr frame)
                   (let ((next (pop (cdr frame))))
                     (unless (gethash next seen)
                       (setf (gethash next seen) t)
                       (push (cons next (gethash next forward)) stack)))
                   (progn (push (car frame) order) (pop stack))))))))
     nodes)
    (dolist (root order)
      (unless (gethash root component-of)
        (let ((component (make-cycle-component)) (stack (list root)))
          (push component components)
          (setf (gethash root component-of) component)
          (loop while stack do
            (let ((node (pop stack)))
              (push node (cycle-component-nodes component))
              (dolist (next (gethash node reverse))
                (unless (gethash next component-of)
                  (setf (gethash next component-of) component)
                  (push next stack))))))))
    ;; Every internal edge of an SCC lies on a cycle. This includes self-loops,
    ;; parallel edges and forbidden edges not selected by a DFS spanning tree.
    (dolist (edge edges)
      (unless (getf edge :unresolved)
        (let ((component (gethash (edge-origin edge level) component-of)))
          (when (eq component (gethash (edge-destination edge level) component-of))
            (push edge (cycle-component-edges component))
            (when (eq :forbidden (getf edge :cycle-policy))
              (setf (cycle-component-forbidden component) t))))))
    (loop for component in components
          when (cycle-component-edges component)
            collect (list :status (if (cycle-component-forbidden component) :invalid :allowed)
                          :nodes (cycle-component-nodes component)
                          :edges (nreverse (cycle-component-edges component))))))

(defun dependency-cycles (store id &key (level :module))
  "Return cyclic strongly connected components with :NODES, :EDGES and :STATUS.
Any forbidden internal edge makes its component :INVALID; otherwise :ALLOWED.
A second value reports :COMPLETE and :INCOMPLETE-MODULES for this graph snapshot.
Unresolved edges cannot establish cycles. Traversal runs outside the session lock."
  (unless (member level '(:module :definition)) (error "Unknown graph level"))
  (multiple-value-bind (edges completeness) (cycle-graph-snapshot store id)
    (values (cyclic-components edges level) completeness)))
