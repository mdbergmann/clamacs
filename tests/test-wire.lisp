;;;; test-wire.lisp -- the client side of the wire, on the fake transport:
;;;; the queue discipline of tests/test_queue.c, the continuations, the
;;;; error list, and the commands that talk to amilisp.

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
    (is-equal (fake-last-message doc) "amilisp answers on AMILISP")
    (is-equal (fake-sent-commands tr) '("PING" "VERSION"))
    (fake-deliver tr 0 "AmiLisp 0.10 on AmigaOS/m68k")
    (is-equal (fake-last-message doc) "AmiLisp 0.10 on AmigaOS/m68k")
    (is-equal (wire-version wire) "AmiLisp 0.10 on AmigaOS/m68k")
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
    ;; next thing on the wire -- if the queued EVAL ran first, amilisp's
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

;;; --- finding, losing and starting amilisp -----------------------------------

(deftest a-newly-found-port-is-announced-once
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (setf (wire-package wire) "FOO")
    (wire-request wire doc :ping "PING")
    (is-equal (fake-last-message doc) "amilisp found on AMILISP")
    (is-equal (wire-port-name wire) "AMILISP")
    ;; A fresh amilisp starts in CL-USER, whatever the old one was told.
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
    (is-equal (fake-last-message doc) "amilisp is not running (port AMILISP is gone)")
    (is (not (wire-connected wire)))
    (is (null (wire-queue wire)))
    (is-equal (fake-sent-commands tr) '("LOAD a.lisp"))
    ;; Back again: found afresh, announced afresh.
    (wire-request wire doc :ping "PING")
    (is-equal (fake-last-message doc) "amilisp found on AMILISP")))

(deftest without-a-port-the-user-is-asked-and-may-cancel
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (push :cancel (fake-answers doc))
    (is (null (wire-request wire doc :ping "PING")))
    (is-equal (first (fake-asked doc))
              '("No running amilisp was found. Start one?"
                (:start :cancel)))
    (is-equal (fake-transport-launched tr) 0)
    (is (null (fake-transport-sent tr)))))

(deftest without-a-port-start-launches-amilisp
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (setf (fake-transport-launch-port tr) "AMILISP.1")
    (push :start (fake-answers doc))
    (is (wire-request wire doc :ping "PING"))
    (is-equal (fake-transport-launched tr) 1)
    (is-equal (wire-port-name wire) "AMILISP.1")
    (is-equal (fake-last-sent tr) "PING")
    (is-equal (first (fake-transport-sent tr)) '("AMILISP.1" . "PING"))))

(deftest a-failed-launch-is-reported
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (push :start (fake-answers doc))
    (is (null (wire-request wire doc :ping "PING")))
    (is-equal (fake-transport-launched tr) 1)
    (is-equal (fake-last-message doc) "Cannot start amilisp")))

(deftest a-quiet-request-never-asks
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (is (null (wire-request wire nil :ping "PING")))
    (is (null (fake-asked doc)))
    (is (null (fake-transport-sent tr)))))

;;; --- the commands ------------------------------------------------------------

;;; A buffer eval runs on amilisp's REPL thread (repl.lisp, SLIME's model):
;;; the first one attaches the REPL -- its window opens, the buffer keeps
;;; the focus -- and the values come back as a RESULT command at the
;;; editor's port, not as the reply.  tests/test-repl.lisp has the REPL
;;; window itself; here is what the eval commands put on the wire.

(deftest eval-last-sexp-attaches-the-repl-tells-the-package-and-echoes-the-value
  (multiple-value-bind (doc tr wire) (make-wired-fake "(+ 1 2)|")
    (run-command doc 'clamacs-eval-last-sexp)
    ;; The REPL window opened for the attach, and the eval came from DOC.
    (is (repl-doc (doc-editor doc)))
    (is (eq (editor-active-document (doc-editor doc)) doc))
    (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")
    (is-equal (fake-last-message (repl-doc (doc-editor doc))) "Attaching the REPL to AMILISP ...")
    (fake-deliver tr 0 "CL-USER")
    ;; No (in-package ...) in the buffer means CL-USER -- and the attach
    ;; reply just said the port is there, so it is not repeated (a buffer
    ;; in another package says its own first: the test below).
    (is-equal (fake-last-sent tr) "REPL-EVAL (+ 1 2)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "3"))
    (is-equal (fake-last-message doc) "3")
    (is-equal (wire-package wire) "CL-USER")
    ;; The same package is not repeated.
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "REPL-EVAL (+ 1 2)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "3"))
    (is-equal (fake-sent-commands tr)
              '("REPL-ATTACH CLAMACS DEBUG" "REPL-EVAL (+ 1 2)" "REPL-EVAL (+ 1 2)"))))

(deftest the-buffer-package-is-what-in-package-says
  (multiple-value-bind (doc tr wire) (make-wired-fake (lines "(in-package :foo)" "(bar)|"))
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-answer-attach tr)
    (is-equal (fake-last-sent tr) "IN-PACKAGE foo")
    (fake-deliver tr 0 "Package is now FOO")
    (is-equal (fake-last-sent tr) "REPL-EVAL (bar)")))

(deftest a-failing-in-package-is-reported-once-and-not-asked-again
  (multiple-value-bind (doc tr wire) (make-wired-fake (lines "(in-package :nope)" "(bar)|"))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-answer-attach tr)
    (is-equal (fake-last-sent tr) "IN-PACKAGE nope")
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: no such package: NOPE")
    ;; The editor's own line, not amilisp's ERROR: a buffer of a system
    ;; not loaded yet is the normal case.
    (is-equal (fake-last-message doc) "amilisp has no package NOPE yet (load its system first)")
    (is-equal (wire-missing-packages wire) '("NOPE"))
    ;; The port stayed where it was, which the editor does not know.
    (is (null (wire-package wire)))
    ;; The eval still went out, where the port stands.
    (is-equal (fake-last-sent tr) "REPL-EVAL (bar)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "1"))
    ;; A form ran: the package may be there now, so it is asked for again --
    ;; and refused again, which is news again (the form did not define it).
    (is (null (wire-missing-packages wire)))
    (setf (fake-messages doc) '())
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "IN-PACKAGE nope")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no such package: NOPE")
    (is-equal (fake-last-message doc) "amilisp has no package NOPE yet (load its system first)")
    (is-equal (wire-missing-packages wire) '("NOPE"))
    ;; Not asked for again before anything ran: the next eval goes
    ;; straight out, and nothing is said.
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "1"))
    (setf (wire-missing-packages wire) '("NOPE")
          (fake-messages doc) '())
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "REPL-EVAL (bar)")
    (is (null (fake-messages doc)))
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "1"))
    ;; Any other refusal is amilisp's text, as before.
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: something else")
    (is-equal (fake-last-message doc) "ERROR: something else")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "1"))
    ;; A port found afresh starts afresh.
    (setf (wire-missing-packages wire) '("NOPE"))
    (wire-request wire doc :ping "PING")
    (fake-deliver tr 20 "no such port" :lost t)
    (is (not (wire-connected wire)))
    (wire-request wire doc :ping "PING")
    (is (wire-connected wire))
    (is (null (wire-missing-packages wire)))))

(deftest a-missing-package-is-not-asked-for-while-nothing-ran
  (multiple-value-bind (doc tr wire) (make-wired-fake (lines "(in-package :nope)" "(bar)|"))
    (wire-find-port wire)
    (setf (wire-missing-packages wire) '("NOPE"))
    ;; Told where the port stands, so the IN-PACKAGE would have gone.
    (setf (wire-package wire) "CL-USER")
    (wire-ensure-package wire doc)
    (is (null (fake-transport-sent tr)))
    ;; A LOAD's reply, a successful or a failed EVAL's: tried again after.
    (wire-request wire doc :load "LOAD x.lisp")
    (fake-deliver tr 0 (lines "; loading x.lisp" "0 error(s), 0 warning(s)"))
    (is (null (wire-missing-packages wire)))
    (wire-ensure-package wire doc)
    (is-equal (fake-last-sent tr) "IN-PACKAGE nope")))

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
    (fake-answer-attach tr)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) (format nil "REPL-EVAL (defun a ()~%  1)"))
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "A"))
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
    (fake-answer-attach tr)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "REPL-EVAL (list 1)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "(1)"))
    (run-command doc 'clamacs-eval-expression)
    (is-equal (fake-prompt doc) "Eval: ")
    (type-text doc "(* 6 7)")
    (type-keys doc "RET")
    (is-equal (fake-last-sent tr) "REPL-EVAL (* 6 7)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "42"))
    (is-equal (fake-last-message doc) "42")))

(deftest an-eval-error-comes-back-as-a-failed-result
  ;; Without the debugger (a phase-3 amilisp, or a form that is refused
  ;; before it runs) the form ends with RESULT 10: the error text is the
  ;; buffer's message, with a beep.
  (multiple-value-bind (doc tr wire) (make-wired-fake "(boom)|")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-answer-attach tr)
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 10 CL-USER" "ERROR: Undefined function: BOOM"))
    (is-equal (fake-last-message doc) "ERROR: Undefined function: BOOM")
    (is-equal (fake-beeps doc) 1)))

(deftest an-eval-value-with-no-values
  (multiple-value-bind (doc tr wire) (make-wired-fake "(values)|")
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-answer-attach tr)
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "; No values"))
    (is-equal (fake-last-message doc) "; No values")))

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
      ;; Saved first, so amilisp loads what is on screen.
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
        ;; What the load printed opened the REPL window behind the buffer
        ;; (test-repl.lisp has the rest), and its attach went out.
        (is (eq (editor-active-document editor) doc))
        (is-equal (transcript (repl-doc editor))
                  (lines (format nil "; loading ~A" path)
                         "ERROR: SIMPLE-ERROR: first deliberate error"
                         "|"))
        (fake-answer-attach tr)
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
    (is-equal (fake-prompt doc) "Load file (TAB: browse): ")
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

(deftest load-file-requester-loads-the-chosen-file
  ;; The menu's Load File...: the requester, no prompt, then LOAD.
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    ;; A buffer without a file has no directory to start in.
    (setf (fake-answers doc) (list "T:chosen.lisp"))
    (run-command doc 'clamacs-load-file-requester)
    (is-equal (fake-asked doc) '((:file "Load File" nil "")))
    (is (not (minibuffer-open-p doc)))
    (is-equal (fake-sent-commands tr) '("LOAD T:chosen.lisp"))
    (is-equal (fake-last-message doc) "Loading T:chosen.lisp ...")
    (fake-deliver tr 0 "0 error(s), 0 warning(s)")
    ;; A named buffer starts the requester in its own directory.
    (setf (doc-path doc) "Work:src/a.lisp"
          (fake-answers doc) (list "T:second.lisp"))
    (run-command doc 'clamacs-load-file-requester)
    (is-equal (first (fake-asked doc)) '(:file "Load File" nil "Work:src/"))
    (is-equal (fake-last-sent tr) "LOAD T:second.lisp")
    (is-equal (fake-last-message doc) "Loading T:second.lisp ...")
    (fake-deliver tr 0 "0 error(s), 0 warning(s)")
    ;; Both choices are in the file history, the newest first.
    (let ((history (editor-file-history (doc-editor doc))))
      (is-equal (history-items history) '("T:second.lisp" "T:chosen.lisp"))
      ;; Cancelled: nothing is sent and nothing is remembered.
      (setf (fake-answers doc) (list nil))
      (run-command doc 'clamacs-load-file-requester)
      (is (not (minibuffer-open-p doc)))
      (is-equal (length (fake-asked doc)) 3)
      (is-equal (fake-sent-commands tr) '("LOAD T:chosen.lisp" "LOAD T:second.lisp"))
      (is-equal (history-items history) '("T:second.lisp" "T:chosen.lisp")))))

(deftest connect-and-run-lisp
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    ;; Connect without a port offers to start amilisp: refused, it says
    ;; there is none; taken, the launch that failed is reported ...
    (push :cancel (fake-answers doc))
    (run-command doc 'clamacs-connect)
    (is-equal (first (fake-asked doc))
              '("No running amilisp was found. Start one?" (:start :cancel)))
    (is-equal (fake-last-message doc) "No amilisp port found")
    (is (null (fake-transport-sent tr)))
    (is-equal (fake-transport-launched tr) 0)
    (push :start (fake-answers doc))
    (run-command doc 'clamacs-connect)
    (is-equal (fake-last-message doc) "Cannot start amilisp")
    (is-equal (fake-transport-launched tr) 1)
    (is (null (fake-transport-sent tr)))
    ;; ... and one that worked is connected to, VERSION asked as after a find
    (setf (fake-transport-launch-port tr) "AMILISP")
    (push :start (fake-answers doc))
    (run-command doc 'clamacs-connect)
    (is-equal (fake-transport-launched tr) 2)
    (is-equal (wire-port-name wire) "AMILISP")
    (is-equal (fake-last-sent tr) "VERSION")
    (fake-deliver tr 0 "AmiLisp 0.11")
    (is-equal (fake-last-message doc) "AmiLisp 0.11")
    (is (null (fake-answers doc))))
  ;; amilisp quit (QUIT, console closed) while the editor thought it was
  ;; connected: Connect notices the port is gone and offers to start one
  ;; at ONCE -- not after a VERSION sent into the void (2026-10-06: the
  ;; requester came on the second Connect, the first only flipped the
  ;; menu to "Start amilisp").
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port "AMILISP")
    (run-command doc 'clamacs-connect)
    (fake-deliver tr 0 "AmiLisp 0.11")
    (is (wire-connected wire))
    (setf (fake-transport-port tr) nil
          (fake-transport-sent tr) '()
          (fake-transport-launch-port tr) "AMILISP")
    (push :start (fake-answers doc))
    (run-command doc 'clamacs-connect)
    (is-equal (first (fake-asked doc))
              '("No running amilisp was found. Start one?" (:start :cancel)))
    (is-equal (fake-transport-launched tr) 1)
    (is (wire-connected wire))
    (is-equal (fake-sent-commands tr) '("VERSION"))
    (is (null (fake-answers doc))))
  ;; A port still there: Connect asks nothing and does not treat it as
  ;; newly found (no "amilisp found" message, no REPL re-attach).
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port "AMILISP")
    (run-command doc 'clamacs-connect)
    (fake-deliver tr 0 "AmiLisp 0.11")
    (setf (fake-messages doc) '())
    (run-command doc 'clamacs-connect)
    (is (null (fake-asked doc)))
    (is (wire-connected wire))
    (is-equal (fake-last-sent tr) "VERSION")
    (is (notany (lambda (m) (search "amilisp found" m)) (fake-messages doc))))
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (run-command doc 'run-lisp)
    (is-equal (fake-last-message doc) "Cannot start amilisp")
    (setf (fake-transport-launch-port tr) "AMILISP")
    (run-command doc 'run-lisp)
    (is-equal (fake-last-message doc) "Started amilisp")
    (is-equal (wire-port-name wire) "AMILISP")
    (setf (fake-messages doc) '())
    ;; Connected already: no second launch, and Connect asks nothing.
    (run-command doc 'run-lisp)
    (is-equal (fake-transport-launched tr) 2)
    (run-command doc 'clamacs-connect)
    (is (null (fake-asked doc)))
    (is-equal (fake-last-sent tr) "VERSION")
    (fake-deliver tr 0 "AmiLisp 0.10")
    (is-equal (fake-last-message doc) "AmiLisp 0.10")))

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
      (is-equal (fake-last-message doc) "No connection to amilisp in this editor"))))

;;; --- systems ---------------------------------------------------------------

(deftest a-system-is-named-by-its-asd
  (is (system-path-p "Work:src/foo/foo.asd"))
  (is (system-path-p "/home/me/foo/FOO.ASD"))
  (is (not (system-path-p "Work:src/foo/foo.lisp")))
  (is (not (system-path-p "Work:src/foo/asd")))
  (is-equal (system-name "Work:src/foo/foo.asd") "foo")
  (is-equal (system-name "/home/me/Foo-Bar.asd") "foo-bar")
  (is-equal (system-name "cl.ppcre.asd") "cl.ppcre"))

(deftest the-directory-above
  (is-equal (path-parent-directory "/a/b/") "/a/")
  (is-equal (path-parent-directory "/a/") "/")
  (is (null (path-parent-directory "/")))
  (is-equal (path-parent-directory "Work:src/foo/") "Work:src/")
  (is-equal (path-parent-directory "Work:src/") "Work:")
  (is (null (path-parent-directory "Work:")))       ; a volume is a root
  (is (null (path-parent-directory "a/")))          ; nothing known above
  (is (null (path-parent-directory ""))))

(defun system-fixture ()
  "A project on disk: root/foo.asd and root/src/deep/a.lisp.  Three
values: the .asd, the source file, and everything to delete."
  (let* ((root (concatenate 'string (temp-path "system") "/"))
         (asd (concatenate 'string root "foo.asd"))
         (source (concatenate 'string root "src/deep/a.lisp")))
    (ensure-directories-exist source)
    (is (write-file-text asd "(asdf:defsystem \"foo\")"))
    (is (write-file-text source "(in-package :foo)"))
    (values asd source (list asd source))))

(deftest the-system-of-a-file-is-the-nearest-asd-above-it
  (multiple-value-bind (asd source files) (system-fixture)
    (unwind-protect
         (let ((second (concatenate 'string (path-directory asd) "bar.asd")))
           ;; The .asd itself, asked of no disk at all.
           (is-equal (find-system-files "Nowhere:x/y.asd") '("Nowhere:x/y.asd"))
           (is (null (find-system-files nil)))
           (let ((found (find-system-files source)))
             (is-equal (length found) 1)
             (is-equal (path-basename (first found)) "foo.asd"))
           ;; Too far below: the search gives up.
           (let ((*system-search-depth* 2))
             (is (null (find-system-files source))))
           ;; Two in one directory are both answered, sorted.
           (is (write-file-text second "(asdf:defsystem \"bar\")"))
           (push second files)
           (is-equal (mapcar #'path-basename (find-system-files source))
                     '("bar.asd" "foo.asd")))
      (mapc #'delete-quietly files))))

(deftest load-system-loads-the-asd-above-the-buffer
  (multiple-value-bind (asd source files) (system-fixture)
    (unwind-protect
         (multiple-value-bind (doc tr wire)
             (make-wired-fake (lines "(in-package :foo)" "(bar)|"))
           (declare (ignore wire))
           (let ((*last-system-file* nil))
             (setf (doc-path doc) source
                   (doc-name doc) "a.lisp")
             (run-command doc 'clamacs-load-system)
             (fake-answer-attach tr)
             ;; On the REPL thread, and in CL-USER: the buffer's package
             ;; is one the system has yet to make.
             (let ((sent (fake-last-sent tr)))
               (is (eql (search "REPL-EVAL (progn (require \"asdf\")" sent) 0))
               (is (search "foo.asd\"" sent))
               (is (search "(asdf \"LOAD-SYSTEM\" \"foo\")" sent)))
             (is (notany (lambda (line) (search "IN-PACKAGE" line))
                         (fake-sent-commands tr)))
             (is-equal (path-basename *last-system-file*) "foo.asd")
             (fake-deliver tr 0 "")
             (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "\"foo\""))
             (is-equal (fake-last-message doc) "\"foo\"")
             ;; Test System, of the same file.
             (run-command doc 'clamacs-test-system)
             (is (search "(asdf \"TEST-SYSTEM\" \"foo\")" (fake-last-sent tr)))
             (is-equal (fake-last-message doc) "Testing system foo ...")))
      (mapc #'delete-quietly files)
      (ignore-errors (delete-quietly asd)))))

(deftest a-window-without-a-system-uses-the-last-one-or-asks
  (multiple-value-bind (doc tr wire) (make-wired-fake "(+ 1 2)|")
    (declare (ignore wire))
    (let ((*last-system-file* nil))
      ;; Nothing above the buffer and nothing loaded before: a prompt.
      (run-command doc 'clamacs-load-system)
      (is (minibuffer-open-p doc))
      (is (null (fake-transport-sent tr)))
      (minibuffer-abort doc)
      ;; A file that is no .asd is refused, and nothing is sent.
      (load-system-file doc "Work:src/foo.lisp")
      (is-equal (fake-last-message doc) "Not a system definition (.asd): Work:src/foo.lisp")
      (is (null (fake-transport-sent tr)))
      (is (null *last-system-file*))
      ;; The last system is what such a window loads.
      (setq *last-system-file* "Work:src/foo/foo.asd")
      (run-command doc 'clamacs-load-system)
      (is (not (minibuffer-open-p doc)))
      (fake-answer-attach tr)
      (is-equal (fake-last-sent tr)
                (concatenate 'string "REPL-EVAL "
                             (system-form "LOAD-SYSTEM" "Loading" "Work:src/foo/foo.asd" "foo")))
      (is-equal (fake-last-message doc) "Loading system foo ..."))))

(deftest the-system-form-is-plain-cl-and-loads-the-asd-once
  ;; What amilisp evaluates: no ASDF symbol read before ASDF is loaded,
  ;; the .asd loaded only when ASDF has no system of that name from it,
  ;; the transcript's line, the operation and the name as the value.
  (let ((form (system-form "LOAD-SYSTEM" "Loading" "Work:src/foo/foo.asd" "foo/tests")))
    (is (eql (search "(progn (require \"asdf\") " form) 0))
    (is (null (search "asdf:" form)))
    (is (null (search "ASDF:" form)))
    (is (search "(asdf \"REGISTERED-SYSTEM\" \"foo/tests\")" form))
    (is (search "(probe-file \"Work:src/foo/foo.asd\")" form))
    (is (search "(asdf \"LOAD-ASD\" \"Work:src/foo/foo.asd\")" form))
    (is (search "(format t \"~&; loading system ~a from ~a~%\" \"foo/tests\" \"Work:src/foo/foo.asd\")" form))
    (is (search "(asdf \"LOAD-SYSTEM\" \"foo/tests\") \"foo/tests\"))" form))
    (is (null (find #\Newline form)))
    ;; The editor's own reader takes it as one form.
    (is (= (length (read-from-string (concatenate 'string "(" form ")"))) 1)))
  (let ((form (system-form "TEST-SYSTEM" "Testing" "Work:src/foo/foo.asd" "foo")))
    (is (search "; testing system ~a from ~a~%\" \"foo\" " form))
    (is (search "(asdf \"TEST-SYSTEM\" \"foo\") \"foo\"))" form))))

(deftest the-systems-a-definition-file-names
  ;; What ASDF takes as the name: a string as it is, a symbol downcased.
  (is-equal (text-systems "(asdf:defsystem \"foo\" :components ())") '("foo"))
  (is-equal (text-systems "(defsystem foo)") '("foo"))
  (is-equal (text-systems "(ASDF::DEFSYSTEM :Foo-Bar)") '("foo-bar"))
  (is-equal (text-systems "(defsystem #:foo)") '("foo"))
  ;; Several, in the file's order -- and a defsystem in a comment, a
  ;; string or a component's name is none.
  (is-equal (text-systems (lines "(in-package :asdf-user)"
                                 ";; (defsystem \"old\")"
                                 "(defsystem \"foo\""
                                 "  :description \"(defsystem \\\"no\\\")\""
                                 "  :components ((:file \"defsystem\")))"
                                 "#+sbcl (defsystem \"foo/sbcl\")"
                                 "(defsystem \"foo/tests\" :depends-on (\"foo\"))"))
            '("foo" "foo/sbcl" "foo/tests"))
  ;; Nothing, and nothing readable, name nothing; an unfinished file
  ;; names what it has.
  (is (null (text-systems "")))
  (is (null (text-systems "(defpackage :foo)")))
  (is (null (text-systems "(defsystem)")))
  (is (null (text-systems "(defsystem (\"foo\"))")))
  (is-equal (text-systems "(defsystem \"foo\" :components (") '("foo"))
  (is (null (text-systems "(defsystem \"fo")))
  (is (null (file-systems "Nowhere:x/y.asd"))))

(deftest a-file-with-several-systems-asks-which
  (let* ((root (concatenate 'string (temp-path "systems") "/"))
         (asd (concatenate 'string root "foo.asd"))
         (bar (concatenate 'string root "other/bar.asd")))
    (ensure-directories-exist bar)
    (is (write-file-text asd (lines "(asdf:defsystem \"foo\")"
                                    "(asdf:defsystem \"foo/tests\" :depends-on (\"foo\"))")))
    ;; One system, not named after its file: that one, by name.
    (is (write-file-text bar "(asdf:defsystem \"baz\")"))
    (unwind-protect
         (multiple-value-bind (doc tr wire) (make-wired-fake "|")
           (declare (ignore wire))
           (let ((*last-system-file* nil))
             ;; A source beside the .asd: the system above it is foo.asd.
             (setf (doc-path doc) (concatenate 'string root "a.lisp")
                   (doc-name doc) "a.lisp")
             ;; The requester: one button per system, Cancel last.
             (push "foo/tests" (fake-answers doc))
             (run-command doc 'clamacs-load-system)
             (is-equal (first (fake-asked doc))
                       (list "Load which system of foo.asd?" '("foo" "foo/tests" :cancel)))
             (fake-answer-attach tr)
             (is-equal (fake-last-sent tr)
                       (concatenate 'string "REPL-EVAL "
                                    (system-form "LOAD-SYSTEM" "Loading" asd "foo/tests")))
             (is-equal (fake-last-message doc) "Loading system foo/tests ...")
             (is-equal *last-system-file* asd)
             (fake-deliver tr 0 "")
             (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "\"foo/tests\""))
             ;; The file's own system, picked, is tested.
             (push "foo" (fake-answers doc))
             (run-command doc 'clamacs-test-system)
             (is-equal (first (first (fake-asked doc))) "Test which system of foo.asd?")
             (is-equal (fake-last-sent tr)
                       (concatenate 'string "REPL-EVAL "
                                    (system-form "TEST-SYSTEM" "Testing" asd "foo")))
             (is-equal (fake-last-message doc) "Testing system foo ...")
             (fake-deliver tr 0 "")
             (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "\"foo\""))
             ;; Cancel: nothing is sent, and the last system stays.
             (setq *last-system-file* nil)
             (let ((before (length (fake-sent-commands tr))))
               (push :cancel (fake-answers doc))
               (run-command doc 'clamacs-load-system)
               (is-equal (length (fake-sent-commands tr)) before)
               (is (null *last-system-file*)))
             ;; One system of another name: no question, that name.
             (let ((asked (length (fake-asked doc))))
               (load-system-file doc bar)
               (is-equal (length (fake-asked doc)) asked)
               (is-equal (fake-last-sent tr)
                         (concatenate 'string "REPL-EVAL "
                                      (system-form "LOAD-SYSTEM" "Loading" bar "baz")))
               (is-equal (fake-last-message doc) "Loading system baz ..."))))
      (delete-quietly asd)
      (delete-quietly bar))))

;;; --- how amilisp is started ----------------------------------------------------

(deftest the-started-amilisp-s-heap-and-options-are-the-init-file-s
  (let ((*amilisp-options* '()))
    ;; The default is the platform's: the tests run on a host.
    (let ((*amilisp-heap* :default)
          (*features* (remove :morphos (remove :amigaos *features*))))
      (is-equal (amilisp-launch-options) '("--heap" "256M")))
    ;; An Amiga keeps amilisp's own default: the memory is the machine's.
    (let ((*amilisp-heap* :default)
          (*features* (cons :amigaos *features*)))
      (is-equal (amilisp-heap) nil)
      (is-equal (amilisp-launch-options) '()))
    (let ((*amilisp-heap* :default)
          (*features* (cons :morphos *features*)))
      (is-equal (amilisp-launch-options) '()))
    ;; What the init file says goes on every platform.
    (let ((*amilisp-heap* "24M")
          (*features* (cons :amigaos *features*)))
      (is-equal (amilisp-launch-options) '("--heap" "24M")))
    (let ((*amilisp-heap* 8388608))
      (is-equal (amilisp-launch-options) '("--heap" "8388608")))
    ;; NIL, and anything that is no size, is amilisp's own default.
    (dolist (none '(nil "" 0 -1 :big))
      (let ((*amilisp-heap* none))
        (is-equal (amilisp-launch-options) '())))
    ;; The options follow the heap; what is no string is left out.
    (let ((*amilisp-heap* "64M")
          (*amilisp-options* '("--no-userinit" 42 "--no-jit")))
      (is-equal (amilisp-launch-options) '("--heap" "64M" "--no-userinit" "--no-jit")))))

(deftest the-init-file-s-old-names-still-set-the-heap-and-options
  ;; An init file written before 0.12 says *clamiga-heap*: a SETQ of the
  ;; old name is the new variable's.
  (let ((*amilisp-heap* :default)
        (*amilisp-options* '()))
    (setq *clamiga-heap* "48M")
    (setq *clamiga-options* '("--no-jit"))
    (is-equal *amilisp-heap* "48M")
    (is-equal *clamiga-heap* "48M")
    (is-equal (amilisp-launch-options) '("--heap" "48M" "--no-jit"))
    (setf *clamiga-heap* nil)
    (is-equal (amilisp-launch-options) '("--no-jit"))))

(deftest the-port-scan-tries-amilisp-before-the-old-clamiga-names
  (is-equal (length *amilisp-port-names*) 20)
  (is-equal (subseq *amilisp-port-names* 0 3) '("AMILISP" "AMILISP.1" "AMILISP.2"))
  (is-equal (nth 9 *amilisp-port-names*) "AMILISP.9")
  (is-equal (nth 10 *amilisp-port-names*) "CLAMIGA")
  (is-equal (car (last *amilisp-port-names*)) "CLAMIGA.9")
  (is (eq *clamiga-port-names* *amilisp-port-names*))
  (let ((*amilisp-port-names* '("X")))
    (is-equal *clamiga-port-names* '("X"))))
