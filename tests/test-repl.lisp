;;;; test-repl.lisp -- the REPL window on the fake frontend and the fake
;;;; transport: the phase-3 leg of verify/realamiga/drive.rexx step by
;;;; step, plus what only a host test can check (the transcript's
;;;; bookkeeping, a lost port, the window closing with a request out).

(in-package :clamacs)

;;; REPL-FIXTURE, TRANSCRIPT and SEND-INPUT are in fake-transport.lisp:
;;; test-debugger.lisp starts from the same attached REPL.

(defun bound-to (map keys)
  "What KEYS (\"C-c C-c\") runs in MAP, through its prefix maps."
  (dolist (key (split-key-sequence keys) map)
    (setq map (keymap-lookup map key))))

;;; --- opening and attaching -----------------------------------------------------

(deftest c-c-c-z-opens-the-repl-window-and-attaches
  (multiple-value-bind (doc tr wire) (make-wired-fake "(twice 21)|")
    (declare (ignore wire))
    (doc-activate doc)
    (type-keys doc "C-c C-z")
    (let ((repl (repl-doc (doc-editor doc))))
      (is repl)
      (is-equal (doc-name repl) "*clamacs-repl*")
      (is (null (doc-path repl)))
      (is (not (doc-holds-file-p repl)))
      (is (repl-mode-p repl))
      ;; The REPL window is in front, under the REPL keymap.
      (is (eq (editor-active-document (doc-editor doc)) repl))
      (is-equal (bound-to (keystate-local (doc-keys repl)) "RET") 'clamacs-repl-return)
      (is-equal (bound-to (keystate-local (doc-keys repl)) "C-c C-c") 'clamacs-interrupt)
      (is-equal (bound-to (keystate-local (doc-keys repl)) "M-p") 'clamacs-repl-previous-input)
      ;; DEBUG: an error parks the thread and opens the debugger.
      (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")
      (is-equal (fake-last-message repl) "Attaching the REPL to CLAMIGA ...")
      (fake-deliver tr 0 "CL-USER")
      (is (repl-session-attached (repl-session (doc-editor doc))))
      (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> |"))
      (is-equal (fake-last-message repl) "REPL attached to CLAMIGA")
      ;; What the editor inserted never counts as a change.
      (is (not (doc-modified-p repl)))
      ;; A second C-c C-z from the source raises the window, no second attach.
      (doc-activate doc)
      (type-keys doc "C-c C-z")
      (is (eq (editor-active-document (doc-editor doc)) repl))
      (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG")))))

(deftest a-failed-attach-is-reported-and-nothing-is-attached
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (run-command doc 'clamacs-repl)
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: no ARexx transport in this image")
    (let ((repl (repl-doc (doc-editor doc))))
      (is (not (repl-session-attached (repl-session (doc-editor doc)))))
      (is-equal (fake-last-message repl) "ERROR: no ARexx transport in this image")
      (is-equal (transcript repl) (lines "; ERROR: no ARexx transport in this image" "CL-USER> |"))
      ;; RET now says so instead of sending.
      (type-text repl "(+ 1 2)")
      (type-keys repl "RET")
      (is-equal (fake-last-message repl) "No REPL attached -- C-c C-z attaches one"))))

(deftest the-repl-window-closed-during-the-attach-detaches-again
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (run-command doc 'clamacs-repl)
    (let ((repl (repl-doc (doc-editor doc))))
      (run-command repl 'kill-buffer)
      (is (doc-closing repl))
      ;; Not asked about unsaved changes: a transcript is not a file.
      (is (null (fake-asked repl)))
      (fake-deliver tr 0 "CL-USER")
      (is-equal (fake-last-sent tr) "REPL-DETACH")
      (is (not (repl-session-attached (repl-session (doc-editor doc))))))))

;;; --- the prompt ----------------------------------------------------------------

(deftest ret-sends-a-complete-form-and-the-value-comes-back-on-the-next-line
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(+ 1 2)")
    ;; No IN-PACKAGE first: the attach reply said CL-USER, and the port is
    ;; there already.
    (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG" "REPL-EVAL (+ 1 2)"))
    ;; While the form runs there is no input: the indices are off.
    (is (null (repl-window-input-start (doc-repl repl))))
    (is (repl-window-busy (doc-repl repl)))
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "3"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (+ 1 2)" "3" "CL-USER> |"))
    (is (not (repl-window-busy (doc-repl repl))))
    (is (not (doc-modified-p repl)))
    (is-equal (fake-last-message repl) "")
    ;; The input is recorded for M-p.
    (is-equal (hist-nth (editor-repl-history (doc-editor repl)) 0) "(+ 1 2)")))

(deftest output-is-streamed-line-by-line-before-the-value
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(progn (princ 'hello) (terpri) (princ 'there) 42)")
    (fake-inbound (doc-editor repl) (format nil "OUTPUT HELLO~%"))
    (fake-inbound (doc-editor repl) (format nil "OUTPUT THERE~%"))
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "42"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA"
                     "CL-USER> (progn (princ 'hello) (terpri) (princ 'there) 42)"
                     "HELLO" "THERE" "42" "CL-USER> |"))))

(deftest output-without-a-newline-gets-the-value-on-a-line-of-its-own
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(princ 'x)")
    (fake-inbound (doc-editor repl) "OUTPUT X")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "X"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (princ 'x)" "X" "X" "CL-USER> |"))))

(deftest readline-arms-the-input-and-ret-answers-it
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(read-line)")
    (fake-inbound (doc-editor repl) "READLINE")
    (is-equal (fake-last-message repl) "clamiga is reading a line: type it and press RET")
    (is (repl-window-reading (doc-repl repl)))
    (is-equal (repl-window-input-start (doc-repl repl)) (doc-end repl))
    (type-text repl "abc")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "REPL-INPUT abc")
    (fake-deliver tr 0 "")
    (is (not (repl-window-reading (doc-repl repl))))
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "\"abc\"" "NIL"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (read-line)" "abc"
                     "\"abc\"" "NIL" "CL-USER> |"))))

(deftest a-blank-ret-gives-a-fresh-prompt-and-an-unfinished-form-a-newline
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (type-keys repl "RET")
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> " "CL-USER> |"))
    (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG"))
    ;; Still typing the form: RET indents the next line, sends nothing.
    ;; The body indents under the form as it stands on the prompt line
    ;; (column 9, after `CL-USER> '), as the C editor indents it.
    (type-text repl "(defun f (x)")
    (type-keys repl "RET")
    (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG"))
    (is (search (format nil "(defun f (x)~%           |") (transcript repl)))
    (type-text repl "x)")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) (format nil "REPL-EVAL (defun f (x)~%           x)"))))

(deftest c-c-c-c-interrupts-a-running-form
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(loop)")
    (type-keys repl "C-c C-c")
    (is-equal (fake-last-sent tr) "REPL-INTERRUPT")
    (is-equal (fake-last-message repl) "Interrupting ...")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor repl) (lines "RESULT 10 CL-USER" "ERROR: Interrupted"))
    (is-equal (fake-last-message repl) "ERROR: Interrupted")
    (is-equal (fake-beeps repl) 1)
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (loop)" "ERROR: Interrupted" "CL-USER> |"))))

(deftest the-interrupt-from-a-source-buffer-and-without-a-repl
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (type-keys doc "C-c C-b")
    (is-equal (fake-last-message doc) "No REPL attached")
    (is (null (fake-transport-sent tr))))
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore repl wire))
    (type-keys doc "C-c C-b")
    (is-equal (fake-last-sent tr) "REPL-INTERRUPT")
    (fake-deliver tr 0 "the REPL is idle")
    (is-equal (fake-last-message doc) "the REPL is idle")))

(deftest in-package-at-the-prompt-moves-the-prompt
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc))
    (send-input repl tr "(in-package :ext.dev)")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 EXT.DEV" "#<PACKAGE EXT.DEV>"))
    (is (search (format nil "EXT.DEV> |") (transcript repl)))
    (is-equal (repl-window-package (doc-repl repl)) "EXT.DEV")
    ;; The port's package moved with it: the next form says nothing first.
    (is-equal (wire-package wire) "EXT.DEV")
    (send-input repl tr "(in-package :cl-user)")
    (is-equal (fake-sent-commands tr)
              '("REPL-ATTACH CLAMACS DEBUG" "REPL-EVAL (in-package :ext.dev)" "REPL-EVAL (in-package :cl-user)"))
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "#<PACKAGE COMMON-LISP-USER>"))
    (is (search (format nil "CL-USER> |") (transcript repl)))))

(deftest a-buffer-eval-in-between-does-not-move-the-prompt-but-the-form-does
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    ;; The source buffer is in FOO: its eval tells the port so.
    (doc-set-text doc (lines "(in-package :foo)" "(bar)"))
    (doc-set-point doc (doc-end doc))
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "IN-PACKAGE foo")
    (fake-deliver tr 0 "Package is now FOO")
    (is-equal (fake-last-sent tr) "REPL-EVAL (bar)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 FOO" "1"))
    (is-equal (fake-last-message doc) "1")
    (is-equal (repl-window-package (doc-repl repl)) "CL-USER")
    ;; The next form at the prompt re-asserts the prompt's package.
    (type-text repl "(+ 1 1)")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "IN-PACKAGE CL-USER")
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "REPL-EVAL (+ 1 1)")))

;;; --- the history ---------------------------------------------------------------

(deftest m-p-and-m-n-walk-the-input-history
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(in-package :ext.dev)")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 EXT.DEV" "x"))
    (send-input repl tr "(in-package :cl-user)")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "x"))
    (type-keys repl "M-p")
    (is (search "CL-USER> (in-package :cl-user)|" (transcript repl)))
    (type-keys repl "M-p")
    (is (search "CL-USER> (in-package :ext.dev)|" (transcript repl)))
    (type-keys repl "M-p")
    (is-equal (fake-last-message repl) "Beginning of history")
    (type-keys repl "M-n")
    (type-keys repl "M-n")
    (is (search (format nil "CL-USER> |") (transcript repl)))
    ;; What was being typed comes back after the walk.
    (type-text repl "(half")
    (type-keys repl "M-p")
    (is (search "CL-USER> (in-package :cl-user)|" (transcript repl)))
    (type-keys repl "M-n")
    (is (search "CL-USER> (half|" (transcript repl)))
    (is (not (doc-modified-p repl)))))

;;; --- keeping edits inside the input -------------------------------------------

(deftest typing-in-the-transcript-lands-in-the-input
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc tr wire))
    (doc-set-point repl 0)
    (type-text repl "x")
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> x|"))
    ;; Backspace at the input's start is swallowed: the prompt stays.
    (type-keys repl "BS")
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> |"))
    (is-equal (type-keys repl "BS") '())
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> |"))
    ;; Motion into the transcript is free.
    (type-keys repl "M-<")
    (is-equal (doc-point repl) 0)))

(deftest editing-commands-are-refused-while-a-form-runs
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(sleep 6)")
    (type-keys repl "C-k")
    (is-equal (fake-last-message repl) "The REPL is busy (C-c C-c interrupts)")
    (is-equal (fake-beeps repl) 1)
    (type-text repl "x")
    (is-equal (fake-beeps repl) 2)
    (is (search (format nil "(sleep 6)~%|") (transcript repl)))
    ;; RET while busy says so too.
    (type-keys repl "RET")
    (is-equal (fake-beeps repl) 3)
    ;; Undo is never available in the REPL.
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "NIL"))
    (type-keys repl "C-/")
    (is-equal (fake-last-message repl) "Undo is not available in the REPL")))

(deftest c-a-on-the-prompt-line-stops-after-the-prompt
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc tr wire))
    (type-text repl "(+ 1 2)")
    (type-keys repl "C-a")
    (is (search "CL-USER> |(+ 1 2)" (transcript repl)))
    ;; A second C-a goes to the real line start.
    (type-keys repl "C-a")
    (is (search (format nil "~%|CL-USER> (+ 1 2)") (transcript repl)))))

(deftest a-kill-with-the-cursor-in-the-transcript-goes-to-the-input
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc tr wire))
    (type-text repl "abc")
    (doc-set-point repl 0)
    (type-keys repl "C-k")
    ;; The cursor was moved to the end of the input first, where C-k
    ;; finds nothing to kill; the transcript is intact.
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "CL-USER> abc|"))))

(deftest clear-transcript
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "1")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "1"))
    (type-keys repl "C-c M-o")
    (is-equal (transcript repl) "CL-USER> |")
    (is (not (doc-modified-p repl)))))

(deftest the-repl-commands-outside-the-repl-window
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore tr wire))
    (run-command doc 'clamacs-repl-return)
    (is-equal (fake-last-message doc) "Not in the REPL window (C-c C-z goes there)")
    (is-equal (fake-beeps doc) 1)))

;;; --- output while the prompt shows --------------------------------------------

(deftest output-arriving-at-the-prompt-goes-above-it
  ;; A thread other than the REPL's printing later, or a FRAME-EVAL's
  ;; values arriving while a READLINE is armed: the prompt and the input
  ;; move down intact.
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc tr wire))
    (type-text repl "(+ 1")
    (fake-inbound (doc-editor repl) (format nil "OUTPUT late~%"))
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "late" "CL-USER> (+ 1|"))
    (is-equal (repl-window-input-start (doc-repl repl)) (position #\( (transcript repl)))
    (type-text repl " 2)")
    (is-equal (transcript repl) (lines "; REPL attached to CLAMIGA" "late" "CL-USER> (+ 1 2)|"))))

;;; --- buffer evals --------------------------------------------------------------

(deftest a-buffer-eval-while-a-form-runs-is-refused
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (send-input repl tr "(sleep 6)")
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-message doc) "The REPL is busy (C-c C-b interrupts)")
    (is-equal (fake-beeps doc) 1)
    (is-equal (fake-last-sent tr) "REPL-EVAL (sleep 6)")))

(deftest ret-at-the-prompt-while-a-buffer-eval-runs-is-refused
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "REPL-EVAL (twice 21)")
    (fake-deliver tr 0 "")
    ;; The prompt stayed up, but the thread is taken.
    (type-text repl "1")
    (type-keys repl "RET")
    (is-equal (fake-last-message repl) "The REPL is busy (C-c C-c interrupts)")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "42"))
    (is-equal (fake-last-message doc) "42")
    ;; The transcript kept its prompt and the typed input.
    (is (search "CL-USER> 1|" (transcript repl)))))

(deftest a-refused-repl-eval-brings-the-prompt-back
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (type-text repl "(+ 1 2)")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "REPL-EVAL (+ 1 2)")
    ;; The reply is rc 10: clamiga was restarted and has no REPL thread now.
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: no REPL attached (send REPL-ATTACH <port> first)")
    (is-equal (fake-last-message repl) "ERROR: no REPL attached (send REPL-ATTACH <port> first)")
    (is (not (repl-session-attached (repl-session (doc-editor repl)))))
    (is (search (format nil "CL-USER> |") (transcript repl)))))

;;; --- the port going and coming -----------------------------------------------

(deftest losing-the-port-prompts-again-and-the-return-attaches-anew
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc))
    (type-text repl "(+ 1 2)")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "REPL-EVAL (+ 1 2)")
    (fake-deliver tr 20 "no such port" :lost t)
    (is (not (repl-session-attached (repl-session (doc-editor repl)))))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (+ 1 2)"
                     "; clamiga is gone (it is attached again when it comes back)" "CL-USER> |"))
    ;; Back: found by the next scan, and attached without being asked.
    (setf (fake-transport-port tr) "CLAMIGA.1")
    (wire-find-port wire)
    (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")
    (fake-deliver tr 0 "CL-USER")
    (is (repl-session-attached (repl-session (doc-editor repl))))
    (is (search (format nil "; clamiga is back on CLAMIGA.1~%; REPL attached to CLAMIGA.1~%CL-USER> |")
                (transcript repl)))))

(deftest closing-the-repl-window-detaches
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (type-text repl "(unsent")
    (run-command repl 'kill-buffer)
    (is (doc-closing repl))
    (is (null (fake-asked repl)))
    (is-equal (fake-last-sent tr) "REPL-DETACH")
    (is (null (repl-doc (doc-editor repl))))
    (is (not (repl-session-attached (repl-session (doc-editor repl)))))))

;;; --- the verbs at the port ------------------------------------------------------

(deftest the-inbound-verbs-answer-rc-0-and-a-bad-header-is-fatal
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc tr wire))
    (let ((editor (doc-editor repl)))
      (is-equal (multiple-value-list (fake-inbound editor "OUTPUT x")) '(0 ""))
      (is-equal (multiple-value-list (fake-inbound editor "READLINE")) '(0 ""))
      (is-equal (multiple-value-list (fake-inbound editor "RESULT 0 CL-USER")) '(0 ""))
      (is-equal (first (multiple-value-list (fake-inbound editor "RESULT"))) 20)
      (is-equal (first (multiple-value-list (fake-inbound editor "DEBUGGER x"))) 20)
      ;; OUTPUT, RESULT and DEBUGGER are the raw verbs the transport
      ;; registers as such.
      (is-equal *raw-port-verbs* '("OUTPUT" "RESULT" "DEBUGGER"))
      (is (every (lambda (v) (assoc v *port-verbs* :test #'string=)) *raw-port-verbs*)))))
