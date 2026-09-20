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
    "killring" "minihist" "locstack" "symcache"
    "token" "sexp" "indent" "commands" "minibuffer" "files"
    "diag" "wire" "port" "introspect"
    "replmsg" "repl" "debugger" "inspector"))

;;; The checkout's root, as text: `..' is not a directory on AmigaDOS, and
;;; the suite also runs on a real Amiga (`Clamacs:tests/run-tests.lisp').
(defun cl-user::clamacs-root (here)
  (let* ((s (namestring here))
         (cut (search "tests/" s :from-end t)))
    (if cut (subseq s 0 cut) "")))

(let* ((here (or *load-truename* *load-pathname*))
       (root (cl-user::clamacs-root here))
       (only (ext:getenv "CLAMACS_TEST"))
       (failures
         (handler-case
             (progn
               (load (concatenate 'string root "lisp/load.lisp"))
               (load (concatenate 'string root "tests/framework.lisp"))
               (load (concatenate 'string root "tests/fake-frontend.lisp"))
               (load (concatenate 'string root "tests/fake-transport.lisp"))
               (dolist (name (if (and only (string/= only ""))
                                 (list only)
                                 cl-user::*clamacs-test-files*))
                 (load (concatenate 'string root "tests/test-" name ".lisp")))
               (funcall (intern "RUN-TESTS" :clamacs)))
           (error (c)
             (format t "~&LOAD FAILED: ~A~%" c)
             -1))))
  (format t "~&CLAMACS-LISP-TESTS: ~A~%" (if (eql failures 0) "PASS" "FAIL"))
  (finish-output)
  (cl-user::quit (if (eql failures 0) 0 1)))
