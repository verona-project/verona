(in-package #:verona.ide)
(export '(discover-project-configuration inspect-project))

(defun read-project-build-file (root)
  (let* ((root (truename (uiop:ensure-directory-pathname root)))
         (path (probe-file (merge-pathnames "verona.build" root))))
    (unless path (reject-request "No verona.build found in ~A" root))
    (values (verona.compiler:parse-build-file path) root path)))

(defun inspect-project (root)
  "Read required build metadata without resolving targets or creating a session."
  (multiple-value-bind (file root path) (read-project-build-file root)
    (list :root root :build-file path
          :targets
          (loop for target in (verona.compiler:build-file-targets file) collect
            (list :name (verona.compiler::build-name-value (verona.compiler:build-target-name target))
                  :kind (verona.compiler::build-target-artifact-kind target)
                  :root-module (verona::module-name-string (verona.compiler:build-target-root-module target))
                  :search-paths (verona.compiler:build-target-module-paths target)
                  :target (verona.compiler:build-target-compilation-target target)
                  :reader-features (verona.compiler:build-target-reader-features target)
                  :optimization (verona.compiler:build-target-optimization target))))))

(defun discover-project-configuration (root &key build-target overrides environment)
  "Require ROOT's build file and reuse its selected target's build configuration.
OVERRIDES is a MAKE-CONFIGURATION keyword plist; explicit keys win."
  (multiple-value-bind (file root path) (read-project-build-file root)
    (let* ((targets (verona.compiler:build-file-targets file))
           (target (if build-target (verona.compiler:find-build-target file build-target)
                       (if (= 1 (length targets)) (first targets)
                           (reject-request "Select a project build target")))))
      (unless target (reject-request "Unknown project build target ~A" build-target))
      (when (loop for key in overrides by #'cddr thereis (eq key :root))
        (reject-request "Project root cannot be overridden"))
      (let* ((environment (or environment (verona.compiler:resolve-verona-environment)))
             (resolved (verona.compiler::resolve-build-target target))
             (defaults
               (list :root root :build-file path
                     :build-target (verona.compiler::build-name-value
                                    (verona.compiler:build-target-name target))
                     :search-paths (verona.compiler:build-target-module-paths target)
                     :package-locations
                     (list (verona.compiler:verona-environment-source-directory environment)
                           (verona.compiler:verona-environment-library-directory environment))
                     :target (list :triple (verona.compiler:compilation-target-triple resolved)
                                   :cpu (verona.compiler:compilation-target-cpu resolved)
                                   :data-layout (verona.compiler:compilation-target-data-layout resolved)
                                   :object-format (string-downcase
                                                   (symbol-name (verona.compiler:compilation-target-object-format resolved)))
                                   :platform (verona.compiler:compilation-target-platform resolved)
                                   :pointer-width (verona.compiler:compilation-target-pointer-width resolved))
                     :reader-features (verona:target-feature-names resolved))))
        (apply #'make-configuration (append overrides defaults))))))
