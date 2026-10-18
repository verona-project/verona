(in-package #:verona.ide)
(export 'discover-project-configuration)
(defun discover-project-configuration (root &key build-target (overrides nil)
                                                  (environment (verona.compiler:resolve-verona-environment)))
  "Reuse build parsing and LLVM target resolution without executing a build.
OVERRIDES is a MAKE-CONFIGURATION keyword plist; explicit keys win."
  (let* ((root (truename (uiop:ensure-directory-pathname root)))
         (path (probe-file (merge-pathnames "verona.build" root)))
         (file (and path (verona.compiler:parse-build-file path)))
         (target (and file
                      (if build-target (verona.compiler:find-build-target file build-target)
                          (let ((targets (verona.compiler:build-file-targets file)))
                            (if (= 1 (length targets)) (first targets)
                                (reject-request "Select a project build target")))))))
    (when (and build-target (null target)) (reject-request "Unknown project build target"))
    (let* ((resolved (if target (verona.compiler::resolve-build-target target)
                         (verona.compiler:resolve-compilation-target)))
           (defaults (list :root root :build-file path
                           :build-target (and target (verona.compiler::build-name-value
                                                     (verona.compiler:build-target-name target)))
                           :search-paths (if target (verona.compiler:build-target-module-paths target) (list root))
                           :package-locations
                           (list (verona.compiler:verona-environment-source-directory environment)
                                 (verona.compiler:verona-environment-library-directory environment))
                           :target (list :triple (verona.compiler:compilation-target-triple resolved)
                                         :platform (verona.compiler:compilation-target-platform resolved)
                                         :pointer-width (verona.compiler:compilation-target-pointer-width resolved))
                           :reader-features (verona:target-feature-names resolved))))
      (when (loop for key in overrides by #'cddr thereis (eq key :root)) (reject-request "Project root cannot be overridden"))
      (apply #'make-configuration (append overrides defaults)))))
