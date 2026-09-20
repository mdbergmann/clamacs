;;;; debugger.lisp -- the debugger window.
;;;;
;;;; When a form at the REPL signals an unhandled error, clamiga's REPL
;;;; thread (attached with REPL-ATTACH ... DEBUG) does not end the form: it
;;;; stays on the erring stack, sends `DEBUGGER <level>' with the condition
;;;; and the restarts to the editor's port, and waits for its next step over
;;;; the port -- BACKTRACE, FRAME, FRAME-EVAL, RESTART, ABORT, CONTINUE
;;;; (cl-amiga's lib/dev-repl.lisp has the protocol; specs/clamacs-ide.md,
;;;; phase 4).  This is the editor's face for that: the condition, the
;;;; restarts (a double-click invokes one), the backtrace (selecting a frame
;;;; asks for its locals, a double-click opens its source), the locals, and
;;;; a line to evaluate in the selected frame, whose values land in the REPL
;;;; transcript as OUTPUT.  `DEBUGGER 0' -- the thread has left the debugger
;;;; -- closes it; a nested level (an error inside a FRAME-EVAL) refreshes
;;;; it, and leaving that level refreshes it again with the level below.
;;;;
;;;; Everything here is asynchronous, as the rest of the client is: a
;;;; button queues a request and returns, and the reply (or the next
;;;; DEBUGGER message) does the rest.  The state is the DEBUGGER struct on
;;;; the editor; the window is the frontend's, told what to show through
;;;; the generic functions below, so the whole thing runs on the fake
;;;; frontend.  The window's buttons exist as commands too, prompting for
;;;; their number, so `M-x' and the port drive the debugger without a mouse.
;;;; This is the port of src/debugwin.c.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defstruct (debugger (:constructor make-debugger ()))
  (level 0)                 ; 0: not in the debugger
  (frame nil)               ; the selected frame, or NIL
  (condition "")            ; `<type>: <report>'
  (restarts '())            ; the rows, `<n>: <NAME> <report>'
  (has-continue nil)        ; a CONTINUE restart is among them
  (frames '())              ; the backtrace rows, `<n>: <name>  <file>:<line>'
  (locals '()))             ; the selected frame's rows, `<name> = <value>'

(defun editor-debugger-state (editor)
  (or (editor-debugger editor)
      (setf (editor-debugger editor) (make-debugger))))

(defun debugger-active-p (editor)
  (> (debugger-level (editor-debugger-state editor)) 0))

;;; ------------------------------------------------------------------
;;; The frontend's part
;;; ------------------------------------------------------------------

(defgeneric editor-debugger-open (editor debugger)
  (:documentation "Show DEBUGGER's condition and restarts in the debugger
window, its frames and locals cleared, titled with the level, and open it
WITHOUT giving it the keyboard: it arrives asynchronously, while the user
may be typing."))

(defgeneric editor-debugger-close (editor)
  (:documentation "Take the debugger window off the screen."))

(defgeneric editor-debugger-raise (editor)
  (:documentation "Open the debugger window and give it the keyboard."))

(defgeneric editor-debugger-frames (editor rows)
  (:documentation "Fill the backtrace list with ROWS, nothing selected."))

(defgeneric editor-debugger-select-frame (editor n)
  (:documentation "Show frame N as the selected row of the backtrace,
without the selection asking for its locals: this IS that request."))

(defgeneric editor-debugger-locals (editor rows)
  (:documentation "Fill the locals list with ROWS."))

;;; ------------------------------------------------------------------
;;; Where the echo lines go
;;; ------------------------------------------------------------------

(defun debug-doc (editor)
  "The buffer whose eval is in the debugger, else the REPL window, else
wherever the user is."
  (let ((session (editor-repl editor)))
    (or (and session (live-doc (repl-session-origin session)))
        (repl-doc editor)
        (editor-active-document editor))))

(defun debug-active (doc)
  (or (debugger-active-p (doc-editor doc))
      (progn (doc-message doc "The REPL is not in the debugger")
             (doc-beep doc)
             nil)))

(defun debug-request (editor doc kind command)
  (let ((wire (editor-wire editor)))
    (and wire (wire-request wire doc kind command))))

;;; ------------------------------------------------------------------
;;; What clamiga announces
;;; ------------------------------------------------------------------

(defun continue-restart-row-p (row)
  "A row of the form `<n>: CONTINUE ...': what enables the Continue button."
  (let ((colon (position #\: row)))
    (and colon
         (let ((rest (subseq row (1+ colon))))
           (or (string= rest " CONTINUE")
               (and (> (length rest) 10)
                    (string= rest " CONTINUE " :end1 10)))))))

(defun debug-entered (editor level text)
  "DEBUGGER <level>: the condition is the first line, the restarts follow."
  (let* ((dbg (editor-debugger-state editor))
         (doc (debug-doc editor))
         (lines (message-lines text))
         (restarts (remove "" (rest lines) :test #'string=)))
    (setf (debugger-level dbg) level
          (debugger-frame dbg) nil
          (debugger-condition dbg) (or (first lines) "")
          (debugger-restarts dbg) restarts
          (debugger-has-continue dbg) (and (some #'continue-restart-row-p restarts) t)
          (debugger-frames dbg) '()
          (debugger-locals dbg) '())
    (editor-debugger-open editor dbg)
    (when doc
      (message doc "Debugger level ~D: ~A" level (debugger-condition dbg)))
    ;; The frames come separately, and frame 0's locals once they are in.
    (debug-request editor doc :dbg-backtrace "BACKTRACE")))

(defun debug-left (editor)
  (let ((dbg (editor-debugger-state editor)))
    (setf (debugger-level dbg) 0
          (debugger-frame dbg) nil)
    (editor-debugger-close editor)))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun debug-show (doc)
  (when (debug-active doc)
    (editor-debugger-raise (doc-editor doc))))

(defun debug-abort (doc)
  (when (debug-active doc)
    (when (debug-request (doc-editor doc) doc :dbg-restart "ABORT")
      (doc-message doc "Aborting ..."))))

(defun debug-continue (doc)
  (when (debug-active doc)
    (when (debug-request (doc-editor doc) doc :dbg-restart "CONTINUE")
      (doc-message doc "Continuing ..."))))

(defun prompt-for-number (doc label continuation)
  "Prompt for a number; a bad answer beeps."
  (prompt doc label
          (lambda (doc answer)
            (let ((n (parse-integer answer :junk-allowed t)))
              (if (and n (>= n 0))
                  (funcall continuation doc n)
                  (doc-beep doc))))))

(defun debug-restart (doc n)
  "Invoke restart N of the current level; NIL prompts for the number."
  (when (debug-active doc)
    (cond ((null n)
           (prompt-for-number doc "Restart: " #'debug-restart))
          ((debug-request (doc-editor doc) doc :dbg-restart (format nil "RESTART ~D" n))
           (message doc "Invoking restart ~D ..." n)))))

(defun debug-frame (doc n)
  "Select frame N and ask for its locals; NIL prompts for the number."
  (when (debug-active doc)
    (cond ((null n)
           (prompt-for-number doc "Frame: " #'debug-frame))
          (t
           (let* ((editor (doc-editor doc))
                  (dbg (editor-debugger-state editor)))
             (setf (debugger-frame dbg) n
                   (debugger-locals dbg) '())
             (editor-debugger-select-frame editor n)
             (editor-debugger-locals editor '())
             (debug-request editor doc :dbg-frame (format nil "FRAME ~D" n)))))))

(defun debug-eval (doc form)
  "FRAME-EVAL in the selected frame (frame 0 when none is); NIL prompts
for the form."
  (when (debug-active doc)
    (let* ((editor (doc-editor doc))
           (frame (or (debugger-frame (editor-debugger-state editor)) 0)))
      (cond ((null form)
             (prompt-for-form doc (format nil "Eval in frame ~D: " frame) #'debug-eval))
            ((string= form "")
             (doc-beep doc))
            ((debug-request editor doc :dbg-frame-eval
                            (format nil "FRAME-EVAL ~D ~A" frame form))
             (message doc "Evaluating in frame ~D ..." frame))))))

(define-command clamacs-debugger (doc arg)
  (declare (ignore arg))
  (debug-show doc))

(define-command clamacs-debugger-abort (doc arg)
  (declare (ignore arg))
  (debug-abort doc))

(define-command clamacs-debugger-continue (doc arg)
  (declare (ignore arg))
  (debug-continue doc))

(define-command clamacs-debugger-restart (doc arg)
  (declare (ignore arg))
  (debug-restart doc nil))

(define-command clamacs-debugger-frame (doc arg)
  (declare (ignore arg))
  (debug-frame doc nil))

(define-command clamacs-debugger-eval (doc arg)
  (declare (ignore arg))
  (debug-eval doc nil))

;;; ------------------------------------------------------------------
;;; What the window's lists and buttons do
;;; ------------------------------------------------------------------

(defun debug-frame-selected (editor n)
  "The backtrace's selection moved to row N: ask for its locals."
  (let ((dbg (editor-debugger-state editor)))
    (when (and n (> (debugger-level dbg) 0) (not (eql n (debugger-frame dbg))))
      (setf (debugger-frame dbg) n
            (debugger-locals dbg) '())
      (editor-debugger-locals editor '())
      (debug-request editor (debug-doc editor) :dbg-frame (format nil "FRAME ~D" n)))))

(defun debug-frame-clicked (editor n)
  "A double-click on frame N: its source, when the backtrace names one."
  (let* ((dbg (editor-debugger-state editor))
         (row (and n (nth n (debugger-frames dbg))))
         (doc (debug-doc editor)))
    (multiple-value-bind (file line) (dbg-frame-location row)
      (cond ((null file)
             (when doc (doc-message doc "No source location for this frame")))
            (t
             (let ((target (or (find-document-by-path editor file)
                               (open-document editor file))))
               (when target
                 (doc-activate target)
                 (goto-line-1 target line))))))))

(defun debug-restart-clicked (editor n)
  "A double-click on restart N, or the Invoke button with row N selected
(NIL: none is)."
  (let ((doc (debug-doc editor)))
    (when doc
      (cond ((null n)
             (doc-message doc "Select a restart first")
             (doc-beep doc))
            (t (debug-restart doc n))))))

(defun debug-abort-clicked (editor)
  (let ((doc (debug-doc editor)))
    (when doc (debug-abort doc))))

(defun debug-continue-clicked (editor)
  (let ((doc (debug-doc editor)))
    (when doc (debug-continue doc))))

(defun debug-eval-entered (editor text)
  "RET in the window's eval line."
  (let ((doc (debug-doc editor)))
    (when (and doc text (string/= text ""))
      (debug-eval doc text))))

(defun debug-window-closed (editor)
  "Closing the window hides it; the REPL thread stays parked until a
restart is chosen, and `M-x clamacs-debugger' brings the window back."
  (let ((doc (debug-doc editor)))
    (editor-debugger-close editor)
    (when (and doc (debugger-active-p editor))
      (doc-message doc "The REPL is still in the debugger (M-x clamacs-debugger shows it, M-x clamacs-debugger-abort leaves it)"))))

;;; ------------------------------------------------------------------
;;; The replies
;;; ------------------------------------------------------------------

(defun debug-reply (wire kind doc rc text)
  (let* ((editor (wire-editor wire))
         (dbg (editor-debugger-state editor))
         (text (or text ""))
         (line (first-line text)))
    (cond
      ((/= rc +rc-ok+)
       (when doc
         (doc-message doc (if (string/= line "") line "clamiga refused the debugger command"))
         (doc-beep doc)))
      ;; A reply to a level that is already gone is stale.
      ((zerop (debugger-level dbg)) nil)
      (t
       (case kind
         (:dbg-backtrace
          (setf (debugger-frames dbg) (message-rows text))
          (editor-debugger-frames editor (debugger-frames dbg))
          ;; Frame 0 is where the error is: select it, which asks for its
          ;; locals.
          (editor-debugger-select-frame editor 0)
          (debug-frame-selected editor 0))
         (:dbg-frame
          (setf (debugger-locals dbg) (message-rows text))
          (editor-debugger-locals editor (debugger-locals dbg))
          ;; The level is named too: this is the last echo after a DEBUGGER
          ;; message (entry asks BACKTRACE, which selects frame 0, which asks
          ;; this), so it is the state a macro polling STATUS can rely on.
          (when doc
            (message doc "Debugger level ~D, frame ~D: ~A" (debugger-level dbg)
                     (debugger-frame dbg) (if (string/= line "") line "no locals"))))
         ;; FRAME-EVAL and RESTART: taken; what follows comes as OUTPUT, a
         ;; DEBUGGER message or RESULT.
         (t nil))))))
