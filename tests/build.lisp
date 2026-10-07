(in-package #:verona/tests)

(in-suite :verona)

(test parses-declarative-build-targets
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
         (file (verona.compiler:parse-build-source source :directory #P"/private/tmp/build-config/"))
         (app (verona.compiler:find-build-target file "app"))
         (core (verona.compiler:find-build-target file "core"))
         (plugin (verona.compiler:find-build-target file "plugin")))
    (is (typep app 'verona.compiler:executable-target))
    (is (typep core 'verona.compiler:static-library-target))
    (is (typep plugin 'verona.compiler:shared-library-target))
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
                (verona.compiler:build-target-link-options app))))
    (is (string= "x86_64-unknown-linux-gnu"
                 (verona.compiler:build-target-compilation-target plugin)))
    (is (equal :native (verona.compiler:build-target-compilation-target core)))
    (is (= 0 (verona.compiler:build-target-optimization core)))
    (is (string= "2.3.4" (verona.compiler:build-target-version core)))))

(test standard-library-is-a-base-module-project
  (let* ((root (asdf:system-source-directory :verona))
         (file (verona.compiler:parse-build-file
                (merge-pathnames "base/verona.build" root)))
         (base (verona.compiler:find-build-target file "base")))
    (is (typep base 'verona.compiler:static-library-target))
    (is (string= "base"
                 (module-name-string
                  (verona.compiler:build-target-root-module base))))
    (is (probe-file (first (verona.compiler:build-target-module-paths base))))))

(test validates-build-declarations-before-compilation
  (flet ((parse (contents)
           (verona.compiler:parse-build-source
            (make-source "verona.build" contents) :directory #P"/private/tmp/build-config/")))
    (signals verona.compiler:build-parse-error
      (parse "(executable app (module-path \"src\"))"))
    (signals verona.compiler:build-parse-error
      (parse "(executable app (root app) (target native) (target \"x86_64-unknown-linux-gnu\"))"))
    (signals verona.compiler:build-parse-error
      (parse "(executable app (root app) (features))"))
    (signals verona.compiler:build-parse-error
      (parse "(static-library app (root app) (version \"1.0\") (version \"2.0\"))"))
    (signals verona.compiler:build-parse-error
      (parse "(executable app (root app) (features enabled) (features disabled))"))
    (signals verona.compiler:unknown-build-option-error
      (parse "(executable app (root app) (output \"ignored\"))"))
    (signals verona.compiler:duplicate-build-target-error
      (parse "(executable app (root app)) (static-library app (root core))"))))

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

(test builds-all-native-artifact-kinds-from-a-build-file
  (let* ((directory (merge-pathnames (format nil "verona-build-~A/" (gensym "TEST-"))
                                     (uiop:temporary-directory)))
         (source-directory (merge-pathnames "src/" directory))
         (build-path (merge-pathnames "verona.build" directory))
         (app-output (merge-pathnames "dist/bin/" directory))
         (library-output (merge-pathnames "dist/lib/" directory)))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames ".directory" source-directory))
           (with-open-file (stream (merge-pathnames "app.main.vrn" source-directory)
                                   :direction :output :if-exists :supersede)
             (write-string
              "(import config)
               (function main () exit-code (config:configured))"
              stream))
           (with-open-file (stream (merge-pathnames "config.vrn" source-directory)
                                   :direction :output :if-exists :supersede)
             (write-string
              "#+configured (function configured () exit-code 0)
               #-configured (not-a-declaration)
               (export configured)"
              stream))
           (dolist (name '("core.vrn" "plugin.vrn"))
             (with-open-file (stream (merge-pathnames name source-directory)
                                     :direction :output :if-exists :supersede)
               (write-string "(function add ((a i32) (b i32)) i32 (+ a b))" stream)))
           (with-open-file (stream build-path :direction :output :if-exists :supersede)
             (write-string
              "(executable app (root app.main) (module-path \"src\") (optimize 1) (features configured))
               (static-library core (root core) (module-path \"src\"))
               (shared-library plugin (root plugin) (module-path \"src\"))"
              stream))
           (let* ((file (verona.compiler:parse-build-file build-path))
                  (app (verona.compiler:execute-build
                        file (verona.compiler:make-build-invocation
                              "app" app-output :reader-features '("from-command-line"))))
                  (core (verona.compiler:execute-build
                         file (verona.compiler:make-build-invocation "core" library-output)))
                  (plugin (verona.compiler:execute-build
                           file (verona.compiler:make-build-invocation "plugin" library-output))))
             (is (typep app 'verona.compiler:executable-artifact))
             (is (probe-file (verona.compiler:artifact-path app)))
             (let ((features (verona:target-feature-names
                              (verona.compiler:artifact-target app))))
               (is (equal '("from-command-line" "configured")
                          (subseq features (- (length features) 2)))))
             (is (typep core 'verona.compiler:static-library-artifact))
             (is (string= "libcore.a" (file-namestring (verona.compiler:artifact-path core))))
             (is (probe-file (verona.compiler:artifact-path core)))
             (is (typep plugin 'verona.compiler:shared-library-artifact))
             (is (string= (format nil "libplugin.~A"
                                   (if (eq :darwin
                                           (verona.compiler:compilation-target-platform
                                            (verona.compiler:artifact-target plugin)))
                                       "dylib" "so"))
                          (file-namestring (verona.compiler:artifact-path plugin))))
             (is (probe-file (verona.compiler:artifact-path plugin)))))
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t)))))
