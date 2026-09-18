;;;; test-wire.lisp -- the client side of the wire, on the fake transport:
;;;; the queue discipline of tests/test_queue.c, the continuations, the
;;;; error list, and the commands that talk to clamiga.

(in-package :clamacs)

(defparameter *two-errors-reply*
  (lines "; loading T:errors.lisp"
         "T:errors.lisp:7: ERROR: first deliberate error"
         "T:errors.lisp:9: ERROR: Undefined function: NO-SUCH-FUNCTION"
         "2 error(s), 0 warning(s)"
         "--- log ---"
         "ERROR: SIMPLE-ERROR: first deliberate error"
         ""))

;;; --- the queue -----------------------------------------------------------

(deftest one-request-in-flight-at-a-time
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (is (wire-request wire doc :ping "PING"))
    (is (wire-request wire doc :version "VERSION"))
    ;; The port serves one message at a time: nothing else may go out
    ;; until the reply comes back.
    (is-equal (fake-sent-commands tr) '("PING"))
    (is-equal (length (wire-queue wire)) 1)
    (fake-deliver tr 0 "PONG")
    (is-equal (fake-last-message doc) "clamiga answers on CLAMIGA")
    (is-equal (fake-sent-commands tr) '("PING" "VERSION"))
    (fake-deliver tr 0 "CL-Amiga 0.10 on AmigaOS/m68k")
    (is-equal (fake-last-message doc) "CL-Amiga 0.10 on AmigaOS/m68k")
    (is-equal (wire-version wire) "CL-Amiga 0.10 on AmigaOS/m68k")
    (is (null (wire-inflight wire)))
    (is (null (wire-queue wire)))))

(deftest fifo-order
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (dotimes (i 5)
      (wire-request wire doc :eval (format nil "EVAL ~D" i)))
    (dotimes (i 5)
      (is-equal (fake-last-sent tr) (format nil "EVAL ~D" i))
      (fake-deliver tr 0 (format nil "~D~%0 error(s), 0 warning(s)" i))
      (is-equal (fake-last-message doc) (princ-to-string i)))))

(deftest lastresult-jumps-the-queue
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD foo.lisp")
    (wire-request wire doc :eval "EVAL (+ 1 2)")
    (is-equal (fake-last-sent tr) "LOAD foo.lisp")
    ;; rc 10 means ARexx dropped the text, so LASTRESULT has to be the very
    ;; next thing on the wire -- if the queued EVAL ran first, clamiga's
    ;; *LAST-RESULT* would already hold ITS output.
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 (lines "foo.lisp:3: ERROR: boom" "1 error(s), 0 warning(s)" ""))
    (is-equal (fake-last-message doc) "1 error(s), 0 warning(s)")
    (is-equal (fake-editor-diag-rows (doc-editor doc)) '("foo.lisp:3: ERROR: boom"))
    (is-equal (fake-last-sent tr) "EVAL (+ 1 2)")
    (fake-deliver tr 0 (lines "3" "0 error(s), 0 warning(s)"))
    (is-equal (fake-last-message doc) "3")
    (is-equal (fake-sent-commands tr) '("LOAD foo.lisp" "LASTRESULT" "EVAL (+ 1 2)"))))

(deftest a-warning-rc-fetches-the-text-too
  ;; rc 5: the command succeeded with warnings, and ARexx still drops RESULT.
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD foo.lisp")
    (fake-deliver tr 5 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 (lines "foo.lisp:3: WARNING: hmm" "0 error(s), 1 warning(s)" ""))
    (is-equal (fake-last-message doc) "0 error(s), 1 warning(s)")))

(deftest a-failing-lastresult-is-not-fetched-again
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :eval "EVAL (boom)")
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 20 "")
    (is-equal (fake-sent-commands tr) '("EVAL (boom)" "LASTRESULT"))
    (is (null (wire-inflight wire)))))

(deftest the-reply-of-a-closed-window-is-dropped-quietly
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :eval "EVAL 1")
    (setf (doc-closing doc) t
          (fake-messages doc) '())
    (fake-deliver tr 0 (lines "1" "0 error(s), 0 warning(s)"))
    (is (null (fake-messages doc)))
    (is (null (wire-inflight wire)))))

(deftest a-reply-with-nothing-in-flight-is-ignored
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore doc))
    (fake-deliver tr 0 "stray")
    (is (null (wire-inflight wire)))))

;;; --- finding, losing and starting clamiga -----------------------------------

(deftest a-newly-found-port-is-announced-once
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (setf (wire-package wire) "FOO")
    (wire-request wire doc :ping "PING")
    (is-equal (fake-last-message doc) "clamiga found on CLAMIGA")
    (is-equal (wire-port-name wire) "CLAMIGA")
    ;; A fresh clamiga starts in CL-USER, whatever the old one was told.
    (is (null (wire-package wire)))
    (fake-deliver tr 0 "PONG")
    (setf (fake-messages doc) '())
    (wire-request wire doc :ping "PING")
    (is (null (fake-messages doc)))))

(deftest a-lost-port-drops-the-queue-and-disconnects
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD a.lisp")
    (wire-request wire doc :load "LOAD b.lisp")
    (fake-deliver tr 20 "no such port" :lost t)
    (is-equal (fake-last-message doc) "clamiga is not running (port CLAMIGA is gone)")
    (is (not (wire-connected wire)))
    (is (null (wire-queue wire)))
    (is-equal (fake-sent-commands tr) '("LOAD a.lisp"))
    ;; Back again: found afresh, announced afresh.
    (wire-request wire doc :ping "PING")
    (is-equal (fake-last-message doc) "clamiga found on CLAMIGA")))

(deftest without-a-port-the-user-is-asked-and-may-cancel
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (push :cancel (fake-answers doc))
    (is (null (wire-request wire doc :ping "PING")))
    (is-equal (first (fake-asked doc))
              '("No clamiga ARexx port was found. Start clamiga in its own console window?"
                (:start :cancel)))
    (is-equal (fake-transport-launched tr) 0)
    (is (null (fake-transport-sent tr)))))

(deftest without-a-port-start-launches-clamiga
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (setf (fake-transport-launch-port tr) "CLAMIGA.1")
    (push :start (fake-answers doc))
    (is (wire-request wire doc :ping "PING"))
    (is-equal (fake-transport-launched tr) 1)
    (is-equal (wire-port-name wire) "CLAMIGA.1")
    (is-equal (fake-last-sent tr) "PING")
    (is-equal (first (fake-transport-sent tr)) '("CLAMIGA.1" . "PING"))))

(deftest a-failed-launch-is-reported
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (push :start (fake-answers doc))
    (is (null (wire-request wire doc :ping "PING")))
    (is-equal (fake-transport-launched tr) 1)
    (is-equal (fake-last-message doc) "Cannot start clamiga")))

(deftest a-quiet-request-never-asks
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (is (null (wire-request wire nil :ping "PING")))
    (is (null (fake-asked doc)))
    (is (null (fake-transport-sent tr)))))

;;; --- the commands ------------------------------------------------------------

(deftest eval-last-sexp-tells-the-package-first-and-echoes-the-value
  (multiple-value-bind (doc tr wire) (make-wired-fake "(+ 1 2)|")
    (run-command doc 'clamacs-eval-last-sexp)
    ;; No (in-package ...) in the buffer means CL-USER, which is also where
    ;; a fresh clamiga starts -- but not where it stays once another buffer
    ;; has spoken, so it is said explicitly.
    (is-equal (fake-last-sent tr) "IN-PACKAGE CL-USER")
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "EVAL (+ 1 2)")
    (fake-deliver tr 0 (lines "3" "0 error(s), 0 warning(s)"))
    (is-equal (fake-last-message doc) "3")
    (is-equal (wire-package wire) "CL-USER")
    ;; The same package is not repeated.
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "EVAL (+ 1 2)")
    (fake-deliver tr 0 (lines "3" "0 error(s), 0 warning(s)"))
    (is-equal (fake-sent-commands tr)
              '("IN-PACKAGE CL-USER" "EVAL (+ 1 2)" "EVAL (+ 1 2)"))))

(deftest the-buffer-package-is-what-in-package-says
  (multiple-value-bind (doc tr wire) (make-wired-fake (lines "(in-package :foo)" "(bar)|"))
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "IN-PACKAGE foo")
    (fake-deliver tr 0 "Package is now FOO")
    (is-equal (fake-last-sent tr) "EVAL (bar)")))

(deftest a-failing-in-package-is-reported
  (multiple-value-bind (doc tr wire) (make-wired-fake (lines "(in-package :nope)" "(bar)|"))
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: no such package: NOPE")
    (is-equal (fake-last-message doc) "ERROR: no such package: NOPE")))

(deftest eval-last-sexp-without-an-expression
  (multiple-value-bind (doc tr wire) (make-wired-fake "|   ")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-message doc) "No expression before point")
    (is-equal (fake-beeps doc) 1)
    (is (null (fake-transport-sent tr)))))

(deftest eval-defun-sends-the-whole-defun
  (multiple-value-bind (doc tr wire)
      (make-wired-fake (lines "(defun a ()" "  1|)" "" "(defun b () 2)"))
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-defun)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) (format nil "EVAL (defun a ()~%  1)"))
    (fake-deliver tr 0 (lines "A" "0 error(s), 0 warning(s)"))
    (is-equal (fake-last-message doc) "A")))

(deftest eval-defun-of-an-unbalanced-form
  (multiple-value-bind (doc tr wire) (make-wired-fake "(defun a (|")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-defun)
    (is-equal (fake-last-message doc) "Unbalanced expression")
    (is (null (fake-transport-sent tr)))))

(deftest eval-region-and-eval-expression
  (multiple-value-bind (doc tr wire) (make-wired-fake "(list 1)| (list 2)")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-region)
    (is-equal (fake-last-message doc) "No mark set in this buffer")
    (setf (doc-mark doc) 0)
    (run-command doc 'clamacs-eval-region)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "EVAL (list 1)")
    (fake-deliver tr 0 (lines "(1)" "0 error(s), 0 warning(s)"))
    (run-command doc 'clamacs-eval-expression)
    (is-equal (fake-prompt doc) "Eval: ")
    (type-text doc "(* 6 7)")
    (type-keys doc "RET")
    (is-equal (fake-last-sent tr) "EVAL (* 6 7)")
    (fake-deliver tr 0 (lines "42" "0 error(s), 0 warning(s)"))
    (is-equal (fake-last-message doc) "42")))

(deftest an-eval-error-goes-to-the-error-list
  (multiple-value-bind (doc tr wire) (make-wired-fake "(boom)|")
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 (lines "ERROR: Undefined function: BOOM" "1 error(s), 0 warning(s)" ""))
    (is-equal (fake-last-message doc) "1 error(s), 0 warning(s)")
    (is-equal (fake-editor-diag-rows (doc-editor doc)) '("ERROR: Undefined function: BOOM"))
    (is (fake-editor-diag-open (doc-editor doc)))
    ;; An unlocated diagnostic has nowhere to jump: its text is the message.
    (run-command doc 'clamacs-next-error)
    (is-equal (fake-last-message doc) "Undefined function: BOOM")
    (is-equal (wire-error-row wire) 0)))

(deftest an-eval-value-with-no-values
  (multiple-value-bind (doc tr wire) (make-wired-fake "(values)|")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 0 "0 error(s), 0 warning(s)")
    (is-equal (fake-last-message doc) "0 error(s), 0 warning(s)")
    (fake-deliver tr 0 "")))

(deftest load-buffer-needs-a-file
  (multiple-value-bind (doc tr wire) (make-wired-fake "(x)|")
    (declare (ignore wire))
    (run-command doc 'clamacs-load-buffer)
    (is-equal (fake-last-message doc) "Save the buffer to a file first")
    (is-equal (fake-beeps doc) 1)
    (is (null (fake-transport-sent tr)))))

(deftest load-buffer-saves-loads-and-walks-the-diagnostics
  (let ((path (temp-file "errors.lisp"
                         (lines ";;; errors.lisp -- deliberately broken" ";;;" ""
                                "(defvar *errors-start* t)" ""
                                "(error \"first deliberate error\")" ""
                                "(no-such-function-in-this-image)" ""
                                "(defvar *errors-end* t)" ""))))
    (multiple-value-bind (doc tr wire) (make-wired-fake "")
      (load-file doc path)
      (doc-insert doc ";; edited")
      (run-command doc 'clamacs-load-buffer)
      ;; Saved first, so clamiga loads what is on screen.
      (is (not (doc-modified-p doc)))
      (is (starts-with-p ";; edited;;; errors.lisp" (read-file-text path)))
      (is-equal (fake-last-sent tr) (format nil "LOAD ~A" path))
      (is-equal (fake-last-message doc) "Loading clamacs-test-errors.lisp ...")
      ;; The reply: rc 10, the text through LASTRESULT.
      (fake-deliver tr 10 "")
      (is-equal (fake-last-sent tr) "LASTRESULT")
      (fake-deliver tr 0 (lines (format nil "; loading ~A" path)
                                (format nil "~A:7: ERROR: first deliberate error" path)
                                (format nil "~A:9: ERROR: Undefined function: NO-SUCH-FUNCTION" path)
                                "2 error(s), 0 warning(s)"
                                "--- log ---"
                                "ERROR: SIMPLE-ERROR: first deliberate error"
                                ""))
      (is-equal (fake-last-message doc) "2 error(s), 0 warning(s)")
      (let ((editor (doc-editor doc)))
        (is-equal (length (fake-editor-diag-rows editor)) 2)
        (is (fake-editor-diag-open editor))
        ;; `C-x `' shares its position and its jump with the list.
        (run-command doc 'clamacs-next-error)
        (is-equal (doc-index-line doc (doc-point doc)) 6)
        (is-equal (fake-last-message doc) "first deliberate error")
        (is-equal (fake-editor-diag-selected editor) 0)
        (run-command doc 'clamacs-next-error)
        (is-equal (doc-index-line doc (doc-point doc)) 8)
        (is-equal (fake-editor-diag-selected editor) 1)
        (run-command doc 'clamacs-next-error)
        (is-equal (fake-last-message doc) "No further diagnostic")
        (is-equal (wire-error-row wire) 1)
        (run-command doc 'clamacs-previous-error)
        (is-equal (doc-index-line doc (doc-point doc)) 6)
        (run-command doc 'clamacs-previous-error)
        (is-equal (fake-last-message doc) "No previous diagnostic")
        ;; A fresh load starts a fresh list; the window shows it with the
        ;; reply.
        (run-command doc 'clamacs-load-buffer)
        (is-equal (diaglist-count (wire-diags wire)) 0)
        (is-equal (wire-error-row wire) -1)
        (fake-deliver tr 0 (lines (format nil "; loading ~A" path) "0 error(s), 0 warning(s)"))
        (is-equal (fake-last-message doc) "0 error(s), 0 warning(s)")
        (is-equal (fake-editor-diag-rows editor) '())))
    (delete-file path)))

(deftest the-jump-opens-the-file-when-it-has-no-window
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD T:other.lisp")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 (lines "T:other.lisp:2: ERROR: boom" "1 error(s), 0 warning(s)" ""))
    (run-command doc 'clamacs-next-error)
    (let ((other (find-document-by-path (doc-editor doc) "T:other.lisp")))
      (is other)
      (is (not (eq other doc)))
      (is-equal (editor-active-document (doc-editor doc)) other)
      (is-equal (fake-last-message other) "boom"))))

(deftest next-error-with-nothing-to-walk
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore tr wire))
    (run-command doc 'clamacs-next-error)
    (is-equal (fake-last-message doc) "No diagnostics")
    (is-equal (fake-beeps doc) 1)))

(deftest a-summary-marks-an-aborted-or-truncated-reply
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD a.lisp")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 (lines "a.lisp:1: ERROR: boom" "1 error(s), 0 warning(s)"
                              "; aborted -- the remaining forms were not processed"
                              "[truncated at 8192 characters]"))
    (is-equal (fake-last-message doc) "1 error(s), 0 warning(s) (aborted) (reply truncated)")))

(deftest a-reply-without-a-summary-shows-its-first-line
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD")
    (fake-deliver tr 20 "")
    (fake-deliver tr 0 (lines "ERROR: LOAD requires a file name" "more"))
    (is-equal (fake-last-message doc) "ERROR: LOAD requires a file name")))

(deftest load-file-prompts-and-compile-file-needs-a-file
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (run-command doc 'clamacs-load-file)
    (is-equal (fake-prompt doc) "Load file: ")
    (type-text doc "T:x.lisp")
    (type-keys doc "RET")
    (is-equal (fake-last-sent tr) "LOAD T:x.lisp")
    (is-equal (fake-last-message doc) "Loading T:x.lisp ...")
    (fake-deliver tr 0 "; loading T:x.lisp
0 error(s), 0 warning(s)")
    (run-command doc 'clamacs-compile-file)
    (is-equal (fake-last-message doc) "Save the buffer to a file first")
    (setf (doc-path doc) "T:y.lisp")
    (run-command doc 'clamacs-compile-file)
    (is-equal (fake-last-sent tr) "COMPILE-FILE T:y.lisp")
    (is-equal (fake-last-message doc) "Compiling (unnamed) ...")))

(deftest connect-and-run-lisp
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (run-command doc 'clamacs-connect)
    (is-equal (fake-last-message doc) "No clamiga port found")
    (is (null (fake-transport-sent tr)))
    (run-command doc 'run-lisp)
    (is-equal (fake-last-message doc) "Cannot start clamiga")
    (setf (fake-transport-launch-port tr) "CLAMIGA")
    (run-command doc 'run-lisp)
    (is-equal (fake-last-message doc) "Started clamiga")
    (is-equal (wire-port-name wire) "CLAMIGA")
    (setf (fake-messages doc) '())
    ;; Connected already: no second launch.
    (run-command doc 'run-lisp)
    (is-equal (fake-transport-launched tr) 2)
    (run-command doc 'clamacs-connect)
    (is-equal (fake-last-sent tr) "VERSION")
    (fake-deliver tr 0 "CL-Amiga 0.10")
    (is-equal (fake-last-message doc) "CL-Amiga 0.10")))

(deftest show-errors-opens-the-list-even-when-empty
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore tr wire))
    (run-command doc 'clamacs-show-errors)
    (is (fake-editor-diag-open (doc-editor doc)))
    (is-equal (fake-editor-diag-rows (doc-editor doc)) '())))

(deftest without-a-wire-the-commands-say-so
  (let ((doc (make-fake "(+ 1 2)|")))
    (dolist (command '(clamacs-eval-last-sexp clamacs-connect run-lisp
                       clamacs-show-errors clamacs-next-error))
      (run-command doc command)
      (is-equal (fake-last-message doc) "No connection to clamiga in this editor"))))
