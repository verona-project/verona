(in-package #:verona/tests)

(in-suite :verona)

(defun parse-declarative-build-targets-fixture ()
  (let* ((source
           (make-source
            "verona.build"
            "(executable app
                (root app.main)
                (module-path \"src\")
                (module-path \"dependencies\")
                (target native)
                (optimize 2)
                (features sqlite telemetry)
                (library \"sqlite3\")
                (library-path \"vendor/lib\")
                (framework \"CoreFoundation\"))
              (static-library core (root core) (version \"2.3.4\"))
              (shared-library plugin (root plugin) (target \"x86_64-unknown-linux-gnu\"))"))
         (file (verona.compiler:parse-build-source source :directory #P"/private/tmp/build-config/")))
    file))

(test-cases parses-declarative-build-targets
  (executable
   (let* ((file (parse-declarative-build-targets-fixture))
          (app (verona.compiler:find-build-target file "app")))
     (is (typep app 'verona.compiler:executable-target))
     (is (string= "app" (verona.compiler:build-name-value
                           (verona.compiler:build-target-name app))))
     (is (string= "app.main" (module-name-string
                                (verona.compiler:build-target-root-module app))))
     (is (eq :native (verona.compiler:build-target-compilation-target app)))
     (is (= 2 (verona.compiler:build-target-optimization app)))
     (is (equal '("sqlite" "telemetry")
                (verona.compiler:build-target-reader-features app)))
     (is (= 2 (length (verona.compiler:build-target-module-paths app))))
     (is (equal '("sqlite3")
                (verona.compiler:link-options-libraries
                 (verona.compiler:build-target-link-options app))))
     (is (equal '("CoreFoundation")
                (verona.compiler:link-options-frameworks
                 (verona.compiler:build-target-link-options app))))))
  (static-library
   (let ((core (verona.compiler:find-build-target
                (parse-declarative-build-targets-fixture) "core")))
     (is (typep core 'verona.compiler:static-library-target))
     (is (equal :native (verona.compiler:build-target-compilation-target core)))
     (is (= 0 (verona.compiler:build-target-optimization core)))
     (is (string= "2.3.4" (verona.compiler:build-target-version core)))))
  (shared-library
   (let ((plugin (verona.compiler:find-build-target
                  (parse-declarative-build-targets-fixture) "plugin")))
     (is (typep plugin 'verona.compiler:shared-library-target))
     (is (string= "x86_64-unknown-linux-gnu"
                  (verona.compiler:build-target-compilation-target plugin))))))

(test standard-library-is-a-base-module-project
  (let* ((root (asdf:system-source-directory :verona))
         (file (verona.compiler:parse-build-file
                (merge-pathnames "projects/base/verona.build" root)))
         (base (verona.compiler:find-build-target file "base")))
    (is (typep base 'verona.compiler:static-library-target))
    (is (string= "base"
                 (module-name-string
                  (verona.compiler:build-target-root-module base))))
    (is (probe-file (first (verona.compiler:build-target-module-paths base))))))

(defun parse-build-for-test (contents)
  (verona.compiler:parse-build-source
   (make-source "verona.build" contents) :directory #P"/private/tmp/build-config/"))

(test-cases validates-build-declarations-before-compilation
  (missing-root
   (signals verona.compiler:build-parse-error
     (parse-build-for-test "(executable app (module-path \"src\"))")))
  (duplicate-target
   (signals verona.compiler:build-parse-error
     (parse-build-for-test "(executable app (root app) (target native) (target \"x86_64-unknown-linux-gnu\"))")))
  (empty-features
   (signals verona.compiler:build-parse-error
     (parse-build-for-test "(executable app (root app) (features))")))
  (duplicate-version
   (signals verona.compiler:build-parse-error
     (parse-build-for-test "(static-library app (root app) (version \"1.0\") (version \"2.0\"))")))
  (duplicate-features
   (signals verona.compiler:build-parse-error
     (parse-build-for-test "(executable app (root app) (features enabled) (features disabled))")))
  (unknown-option
   (signals verona.compiler:unknown-build-option-error
     (parse-build-for-test "(executable app (root app) (output \"ignored\"))")))
  (duplicate-build-target-name
   (signals verona.compiler:duplicate-build-target-error
     (parse-build-for-test "(executable app (root app)) (static-library app (root core))"))))

(test keeps-build-invocation-output-and-features-separate-from-target
  (let ((invocation (verona.compiler:make-build-invocation
                     "app" "/private/tmp/verona-build-output"
                     :reader-features '("from-command-line"))))
    (is (typep (verona.compiler:build-invocation-target-name invocation)
               'verona.compiler:build-name))
    (is (search "verona-build-output"
                (namestring (verona.compiler:build-invocation-output-directory invocation))))
    (is (equal '("from-command-line")
               (verona.compiler:build-invocation-reader-features invocation)))))


(test ide-discovers-build-configuration
  (let* ((root (merge-pathnames "projects/base/" (asdf:system-source-directory :verona)))
         (environment (verona.compiler:resolve-verona-environment
                       :getenv (lambda (name) (declare (ignore name)) (namestring root))))
         (config (verona.ide:discover-project-configuration root :environment environment))
         (overridden (verona.ide:discover-project-configuration
                      root :environment environment :overrides '(:reader-features ("editor")))))
    (is (equal (truename root) (verona.ide:configuration-root config)))
    (is (not (null (verona.ide:configuration-build-file config))))
    (is (not (null (verona.ide:configuration-build-target config))))
    (is (member (getf (verona.ide:configuration-target config) :pointer-width) '(32 64)))
    (is (not (null (verona.ide:configuration-search-paths config))))
    (is (equal '("editor") (verona.ide:configuration-reader-features overridden)))))


(test ide-project-configuration-overrides
  (let* ((root (merge-pathnames "projects/base/" (asdf:system-source-directory :verona)))
         (environment (verona.compiler:resolve-verona-environment
                       :getenv (lambda (name) (declare (ignore name)) (namestring root))))
         (file (verona.compiler:parse-build-file (merge-pathnames "verona.build" root)))
         (target (first (verona.compiler:build-file-targets file)))
         (resolved (verona.compiler::resolve-build-target target))
         (configuration (verona.ide:discover-project-configuration root :environment environment)))
    (is (equal (mapcar #'truename (verona.compiler:build-target-module-paths target))
               (verona.ide:configuration-search-paths configuration)))
    (is (equal (verona:target-feature-names resolved)
               (verona.ide:configuration-reader-features configuration)))
    (is (equal (verona.compiler:compilation-target-platform resolved)
               (getf (verona.ide:configuration-target configuration) :platform)))
    (is (= (verona.compiler:compilation-target-pointer-width resolved)
           (getf (verona.ide:configuration-target configuration) :pointer-width)))
    (is (equal (list (verona.compiler:verona-environment-source-directory environment)
                     (verona.compiler:verona-environment-library-directory environment))
               (verona.ide:configuration-package-locations configuration)))
    (is (null (verona.ide:configuration-search-paths
               (verona.ide:discover-project-configuration
                root :environment environment :overrides '(:search-paths nil)))))
    (signals error (verona.ide:discover-project-configuration
                    root :environment environment :overrides '(:root nil)))
    (signals error (verona.ide:discover-project-configuration
                    root :environment environment :build-target "missing"))))
