;;;; framework.lisp -- the test framework of the Lisp editor's pure modules,
;;;; in the shape of tests/test.h so the C cases port line by line:
;;;;
;;;;   (deftest name (is (foo)) (is-equal (bar) 42))
;;;;
;;;; IS-EQUAL takes (actual expected), the order of ASSERT_EQ_INT and
;;;; ASSERT_STR_EQ, and compares with EQUAL.  A condition escaping a test
;;;; fails it and is reported; it never stops the run.  tests/run-tests.lisp
;;;; is the driver.

(in-package :clamacs)

(defvar *tests* '()
  "Test names in definition order (newest first until RUN-TESTS reverses).")
(defvar *test-failed* nil)

(defun test-function-name (name)
  (intern (concatenate 'string "TEST/" (symbol-name name))
          (symbol-package name)))

(defvar *test-files* (make-hash-table :test 'eq)
  "Test name to the file that defined it.")

(defun note-test (name)
  ;; Every test file shares this package, and a second DEFTEST of a name
  ;; would silently replace the first: that is an error, not a redefinition.
  (let ((file *load-truename*)
        (before (gethash name *test-files*)))
    (when (and before file (not (equal before file)))
      (error "Test ~S is defined in ~A and again in ~A." name before file))
    (setf (gethash name *test-files*) file)
    (unless (member name *tests*)
      (push name *tests*))
    name))

(defmacro deftest (name &body body)
  ;; The function is TEST/NAME, so a test named after the function it tests
  ;; -- both live in CLAMACS -- cannot redefine it.
  `(progn
     (defun ,(test-function-name name) () ,@body)
     (note-test ',name)))

(defun test-failure (form &optional (detail ""))
  (format t "  ASSERT FAILED: ~S~A~%" form detail)
  (setq *test-failed* t))

(defmacro is (form)
  `(unless ,form
     (test-failure ',form)))

(defmacro is-equal (actual expected)
  (let ((a (gensym "ACTUAL")) (e (gensym "EXPECTED")))
    `(let ((,a ,actual) (,e ,expected))
       (unless (equal ,a ,e)
         (test-failure ',actual (format nil " = ~S, expected ~S" ,a ,e))))))

(defun run-tests ()
  "Run every test defined so far.  Returns the number of failures."
  (let ((pass 0) (fail 0))
    (dolist (name (reverse *tests*))
      (setq *test-failed* nil)
      (handler-case (funcall (test-function-name name))
        (error (c)
          (format t "  ERROR: ~A~%" c)
          (setq *test-failed* t)))
      (cond (*test-failed*
             (format t "FAIL  ~(~A~)~%" name)
             (incf fail))
            (t
             (format t "  ok  ~(~A~)~%" name)
             (incf pass))))
    (format t "~%~D passed, ~D failed, ~D total~%" pass fail (+ pass fail))
    fail))

;;; Helpers several test files share (CLAMACS_TEST=name loads one file only).

(defun k (spelling)
  "The key spelled SPELLING: (k \"C-x\")."
  (key-from-string spelling))

(defun temp-path (name)
  (let ((dir (or (ext:getenv "TMPDIR") #+amigaos "T:" #-amigaos "/tmp/")))
    (concatenate 'string dir
                 (if (and (> (length dir) 0)
                          (member (char dir (1- (length dir))) '(#\/ #\:)))
                     ""
                     "/")
                 "clamacs-test-" name)))

(defun temp-file (name &optional contents)
  "A path under TMPDIR; holding CONTENTS, or not existing."
  (let ((path (temp-path name)))
    (when (probe-file path)
      (delete-file path))
    (when contents
      (is (write-file-text path contents)))
    path))
