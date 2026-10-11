(in-package #:verona/tests)

(in-suite :verona)

(test retains-multiple-source-forms-in-a-compilation-unit
  (let ((module (compile-string
		 (make-compiler)
		 (format nil "(type Point (product (x f32) (y f32)))~%(function origin () i32 1)")
		 :name "repl.vrn")))
    (is (typep module 'compilation-unit))
    (is (string= "repl.vrn" (source-name (module-source module))))
    (is (= 2 (length (module-forms module))))
    (is (string= "type" (verona-symbol-name
			   (syntax-datum
			    (first (verona-list-elements
				    (syntax-datum (first (module-forms module)))))))))))

(test compiles-a-file-to-a-compilation-unit
  (let* ((pathname #P"/tmp/verona-compilation-unit-test.vrn")
	 (contents "(constant answer i32 42)")
	 (module nil))
    (with-open-file (stream pathname :direction :output :if-exists :supersede)
      (write-string contents stream))
    (setf module (compile-file (make-compiler) pathname))
    (is (search "verona-compilation-unit-test.vrn" (source-name (module-source module))))
    (is (= 1 (length (module-forms module))))))

