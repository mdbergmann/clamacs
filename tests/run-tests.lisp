;;;; run-tests.lisp -- host driver for the Lisp editor's pure-module tests.
;;;;
;;;;   ../build/host/clamiga --no-userinit --script tests/run-tests.lisp
;;;;
;;;; (`make test-lisp' does that, and again under CLAMIGA_GC_STRESS=1.)
;;;; CLAMACS_TEST=keymap runs one file.  The last line is the verdict and
;;;; the only thing a caller may trust: clamiga's LOAD recovers form by form
;;;; and a script's exit code is 0 even after a reader error, so a file that
;;;; failed to load must not pass for a file with no failing tests.

(defparameter cl-user::*clamacs-test-files*
  '("keymap" "rawkey" "command" "bindings"
    "killring" "minihist" "locstack"
    "token" "sexp" "indent" "commands" "minibuffer" "files"))

(let* ((here (or *load-truename* *load-pathname*))
       (only (ext:getenv "CLAMACS_TEST"))
       (failures
         (handler-case
             (progn
               (load (merge-pathnames "../lisp/load.lisp" here))
               (load (merge-pathnames "framework.lisp" here))
               (load (merge-pathnames "fake-frontend.lisp" here))
               (dolist (name (if (and only (string/= only ""))
                                 (list only)
                                 cl-user::*clamacs-test-files*))
                 (load (merge-pathnames
                        (concatenate 'string "test-" name ".lisp") here)))
               (funcall (intern "RUN-TESTS" :clamacs)))
           (error (c)
             (format t "~&LOAD FAILED: ~A~%" c)
             -1))))
  (format t "~&CLAMACS-LISP-TESTS: ~A~%" (if (eql failures 0) "PASS" "FAIL"))
  (finish-output)
  (cl-user::quit (if (eql failures 0) 0 1)))
