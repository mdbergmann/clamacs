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
    ;; The transcript keeps the record of the buffer eval, above the prompt.
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "; Evaluated: 1" "CL-USER> |"))
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
    ;; The transcript kept its prompt and the typed input, the outcome
    ;; noted above them.
    (is (search (lines "; Evaluated: 42" "CL-USER> 1|") (transcript repl)))))

(deftest a-buffer-eval-is-noted-in-the-transcript
  ;; What the echo area shows for a moment, the transcript keeps: the
  ;; values, on a line of their own after output that ended without a
  ;; newline; every value; clamiga's own note not doubled; a failure.
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (flet ((eval-from-buffer (values)
             (setf (fake-messages doc) '())
             (run-command doc 'clamacs-eval-last-sexp)
             (is-equal (fake-last-sent tr) "REPL-EVAL (twice 21)")
             (fake-deliver tr 0 "")
             (fake-inbound (doc-editor repl) values)))
      (fake-deliver tr 0 "Package is now CL-USER")   ; the IN-PACKAGE of the first
      (eval-from-buffer (lines "RESULT 0 CL-USER" "FOO"))
      (is-equal (fake-last-message doc) "FOO")
      (is-equal (transcript repl)
                (lines "; REPL attached to CLAMIGA" "; Evaluated: FOO" "CL-USER> |"))
      ;; Output without a newline, then two values
      (run-command doc 'clamacs-eval-last-sexp)
      (fake-deliver tr 0 "")
      (fake-inbound (doc-editor repl) "OUTPUT hello")
      (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "1" "2"))
      (is-equal (transcript repl)
                (lines "; REPL attached to CLAMIGA" "; Evaluated: FOO" "hello"
                       "; Evaluated: 1" ";   2" "CL-USER> |"))
      ;; clamiga's `; No values'
      (eval-from-buffer (lines "RESULT 0 CL-USER" "; No values"))
      (is-equal (fake-last-message doc) "; No values")
      (is (search (lines ";   2" "; Evaluated: No values" "CL-USER> |") (transcript repl)))
      ;; A failure: what clamiga said, the buffer beeped
      (eval-from-buffer (lines "RESULT 10 CL-USER" "ERROR: The variable X is unbound."))
      (is-equal (fake-last-message doc) "ERROR: The variable X is unbound.")
      (is (search (lines "; Evaluation failed: ERROR: The variable X is unbound." "CL-USER> |")
                  (transcript repl)))
      (is (not (doc-modified-p repl)))
      ;; The prompt and its indices are where they were: typing lands after it
      (type-text repl "(+ 1 1)")
      (is (search "CL-USER> (+ 1 1)|" (transcript repl))))))

(deftest a-note-above-the-prompt-is-coloured
  ;; The widget's own change notification colours the cursor's line only
  ;; -- the prompt's, after an insert above it -- so the transcript
  ;; colours the lines it inserted itself: a note is a comment, painted in
  ;; the comment colour and not left in the class's own text pen (black
  ;; on a dark theme on MUI).
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (fake-deliver tr 0 "Package is now CL-USER")
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "")
    (setf (fake-colours repl) '())
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "1" "2"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "; Evaluated: 1" ";   2" "CL-USER> |"))
    (is-equal (fake-line-colours repl 1) '((0 14 :comment)))
    (is-equal (fake-line-colours repl 2) '((0 5 :comment)))))

(deftest the-eval-note-text
  (is-equal (repl-eval-note-text 0 "FOO") (lines "; Evaluated: FOO" ""))
  (is-equal (repl-eval-note-text 0 (lines "1" "2" "3")) (lines "; Evaluated: 1" ";   2" ";   3" ""))
  (is-equal (repl-eval-note-text 0 "; No values") (lines "; Evaluated: No values" ""))
  (is-equal (repl-eval-note-text 0 "") (lines "; Evaluated: no values" ""))
  (is-equal (repl-eval-note-text 10 "ERROR: x") (lines "; Evaluation failed: ERROR: x" ""))
  (is-equal (repl-eval-note-text 10 "") (lines "; Evaluation failed: no message" "")))

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

(deftest an-interrupt-that-finds-the-thread-gone-brings-the-prompt-back
  ;; The heap exhausted under a form ends clamiga's REPL thread with no
  ;; RESULT sent: the editor learns it from the interrupt's refusal.
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(load-everything)")
    (type-keys repl "RET")
    (is-equal (fake-last-message repl) "The REPL is busy (C-c C-c interrupts)")
    (type-keys repl "C-c C-c")
    (is-equal (fake-last-sent tr) "REPL-INTERRUPT")
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: no REPL attached")
    (is-equal (fake-last-message repl)
              "The REPL thread is gone, and what it ran with it -- C-c C-z attaches a new one")
    (is (not (repl-session-attached (repl-session (doc-editor repl)))))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "CL-USER> (load-everything)"
                     "; The REPL thread is gone, and what it ran with it" "CL-USER> |"))
    ;; The prompt is one again: RET says what is missing, C-c C-z gets it.
    (type-text repl "1")
    (type-keys repl "RET")
    (is-equal (fake-last-message repl) "No REPL attached -- C-c C-z attaches one")
    (type-keys repl "C-c C-z")
    (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")))

(deftest an-interrupt-that-finds-the-thread-gone-ends-a-buffer-eval
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "REPL-EVAL (twice 21)")
    (fake-deliver tr 0 "")
    (type-keys doc "C-c C-b")
    (is-equal (fake-last-sent tr) "REPL-INTERRUPT")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no REPL attached")
    (is-equal (fake-last-message doc)
              "The REPL thread is gone, and what it ran with it -- C-c C-z attaches a new one")
    (is (null (repl-session-origin (repl-session (doc-editor repl)))))
    ;; The prompt stayed up; the news is above it.
    (is (search (lines "; The REPL thread is gone, and what it ran with it" "CL-USER> |")
                (transcript repl)))
    ;; The next buffer eval attaches a new thread and runs on it.
    (run-command doc 'clamacs-eval-last-sexp)
    (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")))

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

;;; --- what a LOAD printed ---------------------------------------------------
;;;
;;; A LOAD or COMPILE-FILE runs on clamiga's handler thread, so what the
;;; file prints is not streamed: it comes back as the `--- log ---' section
;;; of the reply (diag.lisp), and the transcript is where it is shown.

(defparameter *hello-load-reply*
  (lines "; loading T:hello.lisp"
         "0 error(s), 0 warning(s)"
         "--- log ---"
         "hello from the file"
         "and again"
         ""))

(deftest a-load-s-output-lands-in-the-transcript-above-the-prompt
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (doc-activate doc)
    (wire-request wire doc :load "LOAD T:hello.lisp")
    (fake-deliver tr 0 *hello-load-reply*)
    (is-equal (fake-last-message doc) "0 error(s), 0 warning(s)")
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA"
                     "; loading T:hello.lisp"
                     "hello from the file"
                     "and again"
                     "CL-USER> |"))
    ;; The buffer keeps the focus, and the editor's insertion is no change.
    (is (eq (editor-active-document (doc-editor doc)) doc))
    (is (not (doc-modified-p repl)))
    ;; No second attach for it.
    (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG" "LOAD T:hello.lisp"))
    ;; The prompt still works: its indices moved with the text.
    (doc-activate repl)
    (send-input repl tr "(+ 1 2)")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "3"))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA"
                     "; loading T:hello.lisp"
                     "hello from the file"
                     "and again"
                     "CL-USER> (+ 1 2)"
                     "3"
                     "CL-USER> |"))
    ;; A reply with nothing printed leaves the transcript alone.
    (wire-request wire doc :load "LOAD T:quiet.lisp")
    (fake-deliver tr 0 (lines "; loading T:quiet.lisp" "0 error(s), 0 warning(s)" ""))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA"
                     "; loading T:hello.lisp"
                     "hello from the file"
                     "and again"
                     "CL-USER> (+ 1 2)"
                     "3"
                     "CL-USER> |"))))

(deftest a-load-s-output-opens-the-repl-window-behind-the-buffer
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (doc-activate doc)
    (wire-request wire doc :load "LOAD T:hello.lisp")
    (fake-deliver tr 0 *hello-load-reply*)
    (let* ((editor (doc-editor doc))
           (repl (repl-doc editor)))
      (is repl)
      (is (eq (editor-active-document editor) doc))
      (is-equal (transcript repl)
                (lines "; loading T:hello.lisp" "hello from the file" "and again" "|"))
      (is-equal (fake-last-message doc) "0 error(s), 0 warning(s)")
      ;; Attached as a buffer eval's window is, so RET at it works.
      (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")
      (fake-deliver tr 0 "CL-USER")
      (is (repl-session-attached (repl-session editor)))
      (is-equal (transcript repl)
                (lines "; loading T:hello.lisp" "hello from the file" "and again"
                       "; REPL attached to CLAMIGA" "CL-USER> |"))
      (is (eq (editor-active-document editor) doc)))))

(deftest a-quiet-load-opens-no-repl-window
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (wire-request wire doc :load "LOAD T:quiet.lisp")
    (fake-deliver tr 0 (lines "; loading T:quiet.lisp" "0 error(s), 0 warning(s)" ""))
    (is (null (repl-doc (doc-editor doc))))
    (is-equal (fake-sent-commands tr) '("LOAD T:quiet.lisp"))))

(deftest a-load-s-output-while-the-repl-is-busy-goes-to-the-end
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (doc-activate repl)
    (send-input repl tr "(sleep 6)")
    (is (null (repl-window-input-start (doc-repl repl))))
    ;; A load in between (the port answers while the REPL thread runs):
    ;; its log follows the input line, and the RESULT's prompt follows it.
    (wire-request wire doc :load "LOAD T:hello.lisp")
    (fake-deliver tr 0 *hello-load-reply*)
    (fake-inbound (doc-editor repl) "RESULT 0 CL-USER")
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA"
                     "CL-USER> (sleep 6)"
                     "; loading T:hello.lisp"
                     "hello from the file"
                     "and again"
                     "CL-USER> |"))))

(deftest a-failed-eval-s-output-has-no-header-line
  ;; A handler-thread EVAL (the port's, a macro's) that failed answers with
  ;; its rows first, not with `; ...': the log goes in as it is.
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (wire-request wire doc :eval "EVAL (boom)")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 (lines "T:x.lisp:1: ERROR: boom" "1 error(s), 0 warning(s)"
                              "--- log ---" "printed before the error" ""))
    (is-equal (transcript repl)
              (lines "; REPL attached to CLAMIGA" "printed before the error" "CL-USER> |"))))
