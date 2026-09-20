;;;; test-debugger.lisp -- the debugger window on the fake frontend and the
;;;; fake transport: the phase-4 leg of verify/realamiga/drive.rexx step by
;;;; step -- an error at the prompt, the frame eval, the nested level, the
;;;; restarts, a buffer eval's error -- plus what only a host test can
;;;; check (a stale reply, the window closed while parked, the frame click).

(in-package :clamacs)

(defparameter *dbg-announce*
  (lines "DEBUGGER 1 CL-USER"
         "SIMPLE-ERROR: bad 12"
         "0: ABORT Return to the REPL"))

(defun dbg-fixture ()
  "The REPL fixture with (dbg-fn 3 4) sent from the prompt and clamiga's
DEBUGGER 1 delivered, the BACKTRACE asked: (values source repl tr wire)."
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (send-input repl tr "(dbg-fn 3 4)")
    (fake-inbound (doc-editor repl) *dbg-announce*)
    (values doc repl tr wire)))

(defun dbg-answer-entry (repl tr &key (frames (lines "0: dbg-fn  T:dbg.lisp:27" "1: <anonymous>"))
                                     (locals (lines "ARG0 = 3" "ARG1 = 4")))
  "The two replies an announcement asks for: the backtrace, then frame 0's
locals."
  (is-equal (fake-last-sent tr) "BACKTRACE")
  (fake-deliver tr 0 frames)
  (is-equal (fake-last-sent tr) "FRAME 0")
  (fake-deliver tr 0 locals)
  repl)

;;; --- entering ------------------------------------------------------------------

(deftest an-error-at-the-prompt-opens-the-debugger-and-asks-for-the-frames
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (let ((editor (doc-editor repl)))
      (is (debugger-active-p editor))
      (is (fake-editor-dbg-open editor))
      ;; Opened, not activated: it arrives while the user may be typing.
      (is-equal (fake-editor-dbg-raised editor) 0)
      (is-equal (fake-editor-dbg-shown editor)
                '(1 "SIMPLE-ERROR: bad 12" ("0: ABORT Return to the REPL") nil))
      (is-equal (fake-last-message repl) "Debugger level 1: SIMPLE-ERROR: bad 12")
      (dbg-answer-entry repl tr)
      (is-equal (fake-editor-dbg-frames editor) '("0: dbg-fn  T:dbg.lisp:27" "1: <anonymous>"))
      (is-equal (fake-editor-dbg-selected editor) 0)
      (is-equal (fake-editor-dbg-locals editor) '("ARG0 = 3" "ARG1 = 4"))
      ;; The last echo after an announcement: what a macro polls for.
      (is-equal (fake-last-message repl) "Debugger level 1, frame 0: ARG0 = 3")
      ;; The transcript stays as it is while the form is parked.
      (is (search (format nil "CL-USER> (dbg-fn 3 4)~%|") (transcript repl))))))

(deftest ret-at-the-prompt-is-refused-while-debugging
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (type-keys repl "RET")
    (is (search "in the debugger" (fake-last-message repl)))
    (is-equal (fake-beeps repl) 1)
    ;; So is a buffer eval, with the same words.
    (run-command (first (live-documents (doc-editor repl))) 'clamacs-eval-last-sexp)
    (is (search "in the debugger" (fake-last-message (first (live-documents (doc-editor repl))))))))

(deftest a-frame-without-locals-and-an-empty-restart-list
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(dbg-fn 3 4)")
    (fake-inbound (doc-editor repl) (lines "DEBUGGER 1 CL-USER" "SIMPLE-ERROR: bad 12"))
    (is-equal (third (fake-editor-dbg-shown (doc-editor repl))) '())
    (dbg-answer-entry repl tr :locals "; no locals")
    (is-equal (fake-last-message repl) "Debugger level 1, frame 0: ; no locals")))

;;; --- the frame eval and the nested level ---------------------------------------

(deftest the-frame-eval-prints-into-the-transcript
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-eval)
    (is-equal (fake-prompt repl) "Eval in frame 0: ")
    (type-text repl "(list arg0 arg1)")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "FRAME-EVAL 0 (list arg0 arg1)")
    (is-equal (fake-last-message repl) "Evaluating in frame 0 ...")
    (fake-deliver tr 0 "")
    ;; The values come as OUTPUT, appended after the input line.
    (fake-inbound (doc-editor repl) (format nil "OUTPUT (3 4)~%"))
    (is (search (format nil "CL-USER> (dbg-fn 3 4)~%(3 4)~%|") (transcript repl)))
    ;; An empty form is nothing to send.
    (run-command repl 'clamacs-debugger-eval)
    (type-keys repl "RET")
    (is-equal (fake-beeps repl) 1)
    (is-equal (fake-last-sent tr) "FRAME-EVAL 0 (list arg0 arg1)")))

(deftest an-error-in-the-frame-eval-nests-and-abort-returns-to-the-level-below
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-eval)
    (type-text repl "(dbg-fn 1 2)")
    (type-keys repl "RET")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor repl)
                  (lines "DEBUGGER 2 CL-USER" "SIMPLE-ERROR: bad 3"
                         "0: ABORT Return to debugger level 1" "1: ABORT Return to the REPL"))
    (is-equal (first (fake-editor-dbg-shown (doc-editor repl))) 2)
    (dbg-answer-entry repl tr :frames (lines "0: dbg-fn  T:dbg.lisp:27" "1: <anonymous>")
                              :locals (lines "ARG0 = 1" "ARG1 = 2"))
    (is-equal (fake-last-message repl) "Debugger level 2, frame 0: ARG0 = 1")
    (run-command repl 'clamacs-debugger-abort)
    (is-equal (fake-last-sent tr) "ABORT")
    (is-equal (fake-last-message repl) "Aborting ...")
    (fake-deliver tr 0 "")
    ;; Level 1 is announced again, with its own frame 0.
    (fake-inbound (doc-editor repl) *dbg-announce*)
    (dbg-answer-entry repl tr)
    (is-equal (fake-last-message repl) "Debugger level 1, frame 0: ARG0 = 3")))

;;; --- the restarts ----------------------------------------------------------------

(deftest restart-0-ends-the-form-with-aborted-and-a-fresh-prompt
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-restart)
    (is-equal (fake-prompt repl) "Restart: ")
    (type-text repl "0")
    (type-keys repl "RET")
    (is-equal (fake-last-sent tr) "RESTART 0")
    (is-equal (fake-last-message repl) "Invoking restart 0 ...")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor repl) "DEBUGGER 0 CL-USER")
    (is (not (debugger-active-p (doc-editor repl))))
    (is (not (fake-editor-dbg-open (doc-editor repl))))
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" "; Aborted"))
    (is (search (format nil "CL-USER> (dbg-fn 3 4)~%; Aborted~%CL-USER> |") (transcript repl)))
    ;; A number that is not one beeps.
    (send-input repl tr "(dbg-fn 3 4)")
    (fake-inbound (doc-editor repl) *dbg-announce*)
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-restart)
    (type-text repl "x")
    (type-keys repl "RET")
    (is-equal (fake-beeps repl) 1)))

(deftest continue-is-offered-only-with-a-continue-restart
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore doc wire))
    (send-input repl tr "(dbg-go-on)")
    (fake-inbound (doc-editor repl)
                  (lines "DEBUGGER 1 CL-USER" "SIMPLE-ERROR: stop here"
                         "0: CONTINUE Go on anyway" "1: ABORT Return to the REPL"))
    (is (fourth (fake-editor-dbg-shown (doc-editor repl))))
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-continue)
    (is-equal (fake-last-sent tr) "CONTINUE")
    (is-equal (fake-last-message repl) "Continuing ...")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor repl) "DEBUGGER 0 CL-USER")
    (fake-inbound (doc-editor repl) (lines "RESULT 0 CL-USER" ":WENT-ON"))
    (is (search (format nil "~%:WENT-ON~%CL-USER> |") (transcript repl)))
    (is (not (debugger-active-p (doc-editor repl))))))

(deftest a-result-closes-the-debugger-whatever-was-announced
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (fake-inbound (doc-editor repl) (lines "RESULT 10 CL-USER" "ERROR: Interrupted"))
    (is (not (debugger-active-p (doc-editor repl))))
    (is (not (fake-editor-dbg-open (doc-editor repl))))
    ;; A reply to the level that is gone is stale, and changes nothing.
    (fake-deliver tr 0 "0: late")
    (is-equal (fake-editor-dbg-frames (doc-editor repl)) '("0: dbg-fn  T:dbg.lisp:27" "1: <anonymous>"))))

(deftest clamiga-refusing-a-debugger-command-is-reported
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (run-command repl 'clamacs-debugger-continue)
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no CONTINUE restart at this level")
    (is-equal (fake-last-message repl) "ERROR: no CONTINUE restart at this level")
    (is-equal (fake-beeps repl) 1)))

;;; --- the window --------------------------------------------------------------------

(deftest selecting-a-frame-asks-for-its-locals-and-clicking-opens-its-source
  (let ((path (temp-file "dbg.lisp" (lines "(defun dbg-fn (a b)" "  (error \"bad ~a\" (+ a b)))" ""))))
    (multiple-value-bind (doc repl tr wire) (dbg-fixture)
      (declare (ignore doc wire))
      (dbg-answer-entry repl tr :frames (lines (format nil "0: dbg-fn  ~A:2" path) "1: <anonymous>"))
      (let ((editor (doc-editor repl)))
        ;; The list's selection moved to row 1: FRAME 1.
        (debug-frame-selected editor 1)
        (is-equal (fake-last-sent tr) "FRAME 1")
        (is-equal (fake-editor-dbg-locals editor) '())
        (fake-deliver tr 0 "; no locals")
        (is-equal (fake-last-message repl) "Debugger level 1, frame 1: ; no locals")
        ;; The same row again asks nothing.
        (debug-frame-selected editor 1)
        (is-equal (fake-sent-commands tr)
                  '("REPL-ATTACH CLAMACS DEBUG" "REPL-EVAL (dbg-fn 3 4)" "BACKTRACE" "FRAME 0" "FRAME 1"))
        ;; M-x clamacs-debugger-frame prompts, and selects the row itself.
        (run-command repl 'clamacs-debugger-frame)
        (is-equal (fake-prompt repl) "Frame: ")
        (type-text repl "0")
        (type-keys repl "RET")
        (is-equal (fake-last-sent tr) "FRAME 0")
        (is-equal (fake-editor-dbg-selected editor) 0)
        (fake-deliver tr 0 (lines "ARG0 = 3" "ARG1 = 4"))
        ;; A double-click on frame 0 opens the file at its line.
        (debug-frame-clicked editor 0)
        (let ((target (editor-active-document editor)))
          (is-equal (doc-path target) path)
          (is-equal (doc-index-line target (doc-point target)) 1))
        ;; And on a frame without a location says so.
        (debug-frame-clicked editor 1)
        (is-equal (fake-last-message repl) "No source location for this frame")))))

(deftest the-restart-list-and-the-buttons
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (let ((editor (doc-editor repl)))
      (debug-restart-clicked editor nil)
      (is-equal (fake-last-message repl) "Select a restart first")
      (debug-restart-clicked editor 0)
      (is-equal (fake-last-sent tr) "RESTART 0")
      (fake-deliver tr 0 "")
      (debug-eval-entered editor "(+ arg0 1)")
      (is-equal (fake-last-sent tr) "FRAME-EVAL 0 (+ arg0 1)")
      (fake-deliver tr 0 "")
      (debug-eval-entered editor "")
      (is-equal (fake-last-sent tr) "FRAME-EVAL 0 (+ arg0 1)")
      (debug-abort-clicked editor)
      (is-equal (fake-last-sent tr) "ABORT")
      (fake-deliver tr 0 "")
      (debug-continue-clicked editor)
      (is-equal (fake-last-sent tr) "CONTINUE")
      ;; Closing the window hides it; the thread stays parked.
      (debug-window-closed editor)
      (is (not (fake-editor-dbg-open editor)))
      (is (debugger-active-p editor))
      (is (search "still in the debugger" (fake-last-message repl)))
      ;; M-x clamacs-debugger brings it back, with the keyboard.
      (run-command repl 'clamacs-debugger)
      (is (fake-editor-dbg-open editor))
      (is-equal (fake-editor-dbg-raised editor) 1))))

(deftest the-debugger-commands-outside-the-debugger
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore repl wire))
    (dolist (command '(clamacs-debugger clamacs-debugger-abort clamacs-debugger-continue
                       clamacs-debugger-restart clamacs-debugger-frame clamacs-debugger-eval))
      (run-command doc command)
      (is-equal (fake-last-message doc) "The REPL is not in the debugger"))
    (is-equal (fake-beeps doc) 6)
    (is-equal (fake-sent-commands tr) '("REPL-ATTACH CLAMACS DEBUG"))))

;;; --- a buffer eval's error ------------------------------------------------------

(deftest an-error-in-a-buffer-eval-opens-the-debugger-and-echoes-in-that-buffer
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (doc-set-text doc "(dbg-fn 5 6)")
    (doc-set-point doc (doc-end doc))
    (run-command doc 'clamacs-eval-last-sexp)
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "REPL-EVAL (dbg-fn 5 6)")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) (lines "DEBUGGER 1 CL-USER" "SIMPLE-ERROR: bad 11" "0: ABORT Return to the REPL"))
    ;; The echo lines go to the buffer that asked, not the transcript.
    (is-equal (fake-last-message doc) "Debugger level 1: SIMPLE-ERROR: bad 11")
    (is (null (fake-messages repl)))
    (dbg-answer-entry repl tr :locals (lines "ARG0 = 5" "ARG1 = 6"))
    (is-equal (fake-last-message doc) "Debugger level 1, frame 0: ARG0 = 5")
    ;; The prompt stayed up in the transcript.
    (is (search (format nil "CL-USER> |") (transcript repl)))
    (run-command doc 'clamacs-debugger-abort)
    (is-equal (fake-last-sent tr) "ABORT")
    (fake-deliver tr 0 "")
    (fake-inbound (doc-editor doc) "DEBUGGER 0 CL-USER")
    (fake-inbound (doc-editor doc) (lines "RESULT 0 CL-USER" "; Aborted"))
    (is-equal (fake-last-message doc) "; Aborted")
    (is (not (debugger-active-p (doc-editor doc))))
    (is (null (repl-session-origin (repl-session (doc-editor doc)))))))

(deftest closing-the-repl-window-leaves-the-debugger-too
  (multiple-value-bind (doc repl tr wire) (dbg-fixture)
    (declare (ignore doc wire))
    (dbg-answer-entry repl tr)
    (run-command repl 'kill-buffer)
    (is-equal (fake-last-sent tr) "REPL-DETACH")
    (is (not (debugger-active-p (doc-editor repl))))
    (is (not (fake-editor-dbg-open (doc-editor repl))))))
