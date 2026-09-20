;;;; repl.lisp -- the REPL window.
;;;;
;;;; A listener in a document window: the transcript above the prompt is
;;;; history, the text after the prompt is the input, RET sends it when the
;;;; parens balance, and what comes back arrives as commands at the editor's
;;;; OWN port -- OUTPUT as it is printed, READLINE when the form reads from
;;;; standard input, RESULT with the values and the package for the next
;;;; prompt, DEBUGGER when a form is parked in the debugger (debugger.lisp).
;;;; The other end is clamiga's REPL thread, lib/dev-repl.lisp in cl-amiga;
;;;; specs/clamacs-ide.md, phase 3, has the protocol and the reason it is
;;;; two-way: a port answers a command the moment the verb returns, so the
;;;; editor can hold no reply until the user has typed.  This is the port of
;;;; src/repl.c.
;;;;
;;;; Bookkeeping is two document indices.  INPUT-START is where the input
;;;; begins -- after the prompt while idle, right after the last output while
;;;; a READLINE is outstanding -- and NIL while a form runs, when there is no
;;;; input at all and output is appended.  PROMPT-START is where the prompt
;;;; begins, so output that arrives while the prompt is showing goes above it
;;;; and both indices move along.  Everything the editor inserts itself
;;;; leaves the modified flag clear: the window never asks to save a
;;;; transcript.
;;;;
;;;; A buffer eval (C-c C-c, C-x C-e, C-c C-r, C-c C-e) runs on the REPL
;;;; thread too, SLIME's model: output streams into the transcript, an error
;;;; parks the thread and opens the debugger, only the values go to the
;;;; buffer's echo area and the prompt's package is left alone.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defparameter *repl-name* "*clamacs-repl*")

;;; What the editor knows about clamiga's REPL thread.
(defstruct (repl-session (:constructor make-repl-session ()))
  (doc nil)                 ; the REPL window, or NIL
  (attached nil)            ; clamiga's REPL thread sends to our port
  (attaching nil)           ; a REPL-ATTACH is on the wire
  (origin nil)              ; the document whose buffer eval is running
  (pending nil)             ; a buffer eval waiting for the attach: its text
  (pending-origin nil))     ; ... and its document

;;; The listener state of the REPL window itself.
(defstruct (repl-window (:constructor make-repl-window ()))
  (prompt-start nil)
  (input-start nil)
  (busy nil)                ; a form typed at the prompt is running
  (reading nil)             ; a READLINE is outstanding
  (bol t)                   ; the transcript ends at a line start
  (package "CL-USER")       ; the prompt's package
  (saved ""))               ; the input left for the history walk

(defun repl-session (editor)
  (or (editor-repl editor)
      (setf (editor-repl editor) (make-repl-session))))

(defun repl-doc (editor)
  "The REPL window, when it is open."
  (let ((doc (repl-session-doc (repl-session editor))))
    (and doc (not (doc-closing doc)) doc)))

(defun repl-mode-p (doc)
  (and (doc-repl doc) t))

;;; ------------------------------------------------------------------
;;; Inserting into the transcript
;;; ------------------------------------------------------------------

(defun repl-insert (doc index text)
  "Insert TEXT at INDEX, moving the cursor and the two bookkeeping indices
along with the text when they sit at or after it."
  (let ((state (doc-repl doc))
        (cursor (doc-point doc))
        (len (length text)))
    (when (> len 0)
      (doc-set-point doc index)
      (doc-insert doc text)
      (when (>= cursor index) (incf cursor len))
      (when (and (repl-window-prompt-start state) (>= (repl-window-prompt-start state) index))
        (incf (repl-window-prompt-start state) len))
      (when (and (repl-window-input-start state) (>= (repl-window-input-start state) index))
        (incf (repl-window-input-start state) len))
      (doc-set-point doc cursor)
      (setf (repl-window-bol state) (char= (char text (1- len)) #\Newline))
      (doc-set-modified doc nil))))

(defun repl-append (doc text)
  (repl-insert doc (doc-end doc) text))

(defun repl-ensure-bol (doc)
  "A prompt starts a line of its own."
  (when (and (not (repl-window-bol (doc-repl doc))) (> (doc-end doc) 0))
    (repl-append doc (string #\Newline))))

(defun repl-prompt (doc)
  (let ((state (doc-repl doc)))
    (repl-ensure-bol doc)
    (let* ((end (doc-end doc))
           (prompt (format nil "~A> " (repl-window-package state))))
      ;; Not through REPL-INSERT: the indices are being set, not moved.
      (setf (repl-window-prompt-start state) nil
            (repl-window-input-start state) nil)
      (doc-set-point doc end)
      (doc-insert doc prompt)
      (setf (repl-window-prompt-start state) end
            (repl-window-input-start state) (+ end (length prompt))
            (repl-window-bol state) nil)
      (doc-set-point doc (repl-window-input-start state))
      (doc-set-modified doc nil))))

(defun repl-note (doc control &rest args)
  "A line of the editor's own: `; ...' in the transcript, as a listener
would print it."
  (repl-ensure-bol doc)
  (repl-append doc (format nil "; ~A~%" (apply #'format nil control args))))

;;; ------------------------------------------------------------------
;;; Packages
;;; ------------------------------------------------------------------

(defun repl-wire-package (editor package)
  "clamiga's *COMMAND-PACKAGE* moved: a buffer eval that follows must not
assume the port is still where it last put it."
  (let ((wire (editor-wire editor)))
    (when (and wire package (string/= package ""))
      (setf (wire-package wire) package))))

(defun repl-set-package (doc package)
  "The prompt's package.  Only a form typed at the prompt moves it: a
buffer eval runs in its buffer's package and leaves the prompt alone, as
in SLIME."
  (when (and package (string/= package ""))
    (setf (repl-window-package (doc-repl doc)) package)
    (repl-wire-package (doc-editor doc) package)))

(defun repl-send-prompt-package (doc)
  "The prompt's package is the form's package, whatever a buffer eval told
the port in between."
  (let ((wire (editor-wire (doc-editor doc))))
    (when wire
      (wire-ensure-package wire doc (repl-window-package (doc-repl doc))))))

;;; ------------------------------------------------------------------
;;; Buffer evals waiting for the attach
;;; ------------------------------------------------------------------

(defun repl-clear-pending (session)
  (setf (repl-session-pending session) nil
        (repl-session-pending-origin session) nil))

(defun repl-set-pending (session from text)
  (setf (repl-session-pending session) text
        (repl-session-pending-origin session) from))

;;; ------------------------------------------------------------------
;;; Attaching
;;; ------------------------------------------------------------------

(defun repl-attach (doc)
  "Ask clamiga to attach its REPL thread to this editor's port, in DEBUG
mode: an unhandled error parks the thread and opens the debugger window
instead of ending the form."
  (let* ((editor (doc-editor doc))
         (session (repl-session editor))
         (wire (require-wire doc)))
    (when (and wire (not (repl-session-attaching session)))
      (let ((own (transport-own-port (wire-transport wire))))
        (cond ((null own)
               (doc-message doc "Cannot find the editor's own ARexx port")
               (doc-beep doc))
              (t
               ;; Marked BEFORE the request goes out: finding the port for
               ;; it announces a (re)connection, which would attach again.
               (setf (repl-session-attaching session) t)
               (cond ((wire-request wire doc :repl-attach (format nil "REPL-ATTACH ~A DEBUG" own))
                      (message doc "Attaching the REPL to ~A ..." (wire-port-name wire)))
                     (t (setf (repl-session-attaching session) nil)))))))))

(defun repl-open (editor from)
  "The REPL window, opened if there is none yet.  Opening puts it in
front; the caller decides whether that is where the user goes."
  (or (repl-doc editor)
      (let ((doc (ensure-scratch-document editor *repl-name* t))
            (session (repl-session editor)))
        (cond ((null doc)
               (when from
                 (doc-message from "Cannot open the REPL window")
                 (doc-beep from))
               nil)
              (t
               (setf (doc-repl doc) (make-repl-window)
                     (doc-keys doc) (make-keystate (global-keymap) (repl-keymap))
                     (repl-session-doc session) doc
                     (repl-session-attached session) nil
                     (repl-session-origin session) nil)
               doc)))))

(defun repl-switch (from)
  (let* ((editor (doc-editor from))
         (doc (repl-open editor from)))
    (when doc
      (doc-activate doc)
      (unless (repl-session-attached (repl-session editor))
        (repl-attach doc)))))

(defun repl-eval-from (from text)
  "A buffer eval on the REPL thread.  Before the REPL is attached the form
waits for the REPL-ATTACH reply; the REPL window opens for that, but the
user stays in the buffer."
  (let* ((editor (doc-editor from))
         (session (repl-session editor))
         (repl (repl-doc editor))
         (wire (require-wire from)))
    (when wire
      (cond
        ((not (repl-session-attached session))
         (when (null repl)
           (setq repl (repl-open editor from))
           (when (null repl)
             (return-from repl-eval-from nil))
           ;; The new window came up in front: the eval came from FROM.
           (doc-activate from))
         (repl-set-pending session from text)
         (repl-attach repl)
         (unless (repl-session-attaching session)
           (repl-clear-pending session)))   ; the attach never left
        ((or (repl-session-origin session)
             (and repl (null (repl-window-input-start (doc-repl repl)))))
         (repl-busy-message from))
        (t
         ;; The buffer's package, not the prompt's.
         (wire-ensure-package wire from)
         (when (wire-request wire from :repl-eval (concatenate 'string "REPL-EVAL " text))
           (setf (repl-session-origin session) from)))))))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun blank-text-p (text)
  (every (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return))) text))

(defun repl-busy-message (doc)
  (let ((editor (doc-editor doc)))
    (cond ((debugger-active-p editor)
           (doc-message doc "The REPL is in the debugger (M-x clamacs-debugger shows it, M-x clamacs-debugger-abort returns to the prompt)"))
          ((repl-mode-p doc)
           (doc-message doc "The REPL is busy (C-c C-c interrupts)"))
          (t
           (doc-message doc "The REPL is busy (C-c C-b interrupts)")))
    (doc-beep doc)))

(defun repl-input-text (doc)
  (doc-text doc (repl-window-input-start (doc-repl doc)) (doc-end doc)))

(defun repl-return (doc)
  (let* ((editor (doc-editor doc))
         (session (repl-session editor))
         (state (doc-repl doc))
         (wire (editor-wire editor)))
    (cond
      ((null (repl-window-input-start state))
       (repl-busy-message doc))
      (t
       (let ((text (repl-input-text doc))
             (end (doc-end doc)))
         (cond
           ((repl-window-reading state)
            ;; The answer to a READLINE: one line, sent as typed.
            (setf (repl-window-reading state) nil
                  (repl-window-input-start state) nil
                  (repl-window-prompt-start state) nil)
            (repl-append doc (string #\Newline))
            (if (and wire (wire-request wire doc :repl-input (concatenate 'string "REPL-INPUT " text)))
                (doc-message doc "")
                (repl-prompt doc)))
           ((blank-text-p text)
            ;; Nothing to send: a fresh prompt, as a listener gives.
            (repl-append doc (string #\Newline))
            (repl-prompt doc))
           ((not (sexp-input-complete-p text))
            ;; Still typing the form: RET does what it does in a source buffer.
            (doc-set-point doc end)
            (run-command doc 'newline-and-indent 1))
           ((repl-session-origin session)
            ;; The thread is running a buffer eval; the prompt stayed up.
            (repl-busy-message doc))
           ((not (repl-session-attached session))
            (doc-message doc "No REPL attached -- C-c C-z attaches one")
            (doc-beep doc))
           (t
            (hist-add (editor-repl-history editor) text)
            (setf (repl-window-input-start state) nil
                  (repl-window-prompt-start state) nil
                  (repl-window-busy state) t)
            (doc-set-point doc end)
            (repl-append doc (string #\Newline))
            (repl-send-prompt-package doc)
            (unless (and wire (wire-request wire doc :repl-eval (concatenate 'string "REPL-EVAL " text)))
              (setf (repl-window-busy state) nil)
              (repl-prompt doc)))))))))

(defun repl-replace-input (doc text)
  (let* ((state (doc-repl doc))
         (start (repl-window-input-start state)))
    (doc-delete doc start (doc-end doc))
    (doc-set-point doc start)
    (doc-insert doc text)
    (doc-set-modified doc nil)))

(defun repl-history-walk (doc back)
  (let* ((editor (doc-editor doc))
         (hist (editor-repl-history editor))
         (state (doc-repl doc)))
    (cond
      ((null (repl-window-input-start state))
       (doc-beep doc))
      (t
       ;; Leaving the input for the history: keep it, so M-n past the
       ;; newest entry brings it back.
       (when (zerop (history-cursor hist))
         (setf (repl-window-saved state) (repl-input-text doc)))
       (let ((item (if back (hist-prev hist) (hist-next hist))))
         (cond ((and (null item) back)
                (doc-message doc "Beginning of history")
                (doc-beep doc))
               (t
                (repl-replace-input doc (or item (repl-window-saved state))))))))))

(defun repl-clear (doc)
  (let ((state (doc-repl doc)))
    (cond ((null (repl-window-input-start state))
           (repl-busy-message doc))
          (t
           (setf (repl-window-prompt-start state) nil
                 (repl-window-input-start state) nil)
           (doc-set-text doc "")
           (setf (repl-window-bol state) t)
           (repl-prompt doc)))))

(defun repl-interrupt (doc)
  (let* ((editor (doc-editor doc))
         (wire (require-wire doc)))
    (when wire
      (cond ((not (repl-session-attached (repl-session editor)))
             (doc-message doc "No REPL attached")
             (doc-beep doc))
            ((wire-request wire doc :repl-interrupt "REPL-INTERRUPT")
             (doc-message doc "Interrupting ..."))))))

(define-command clamacs-repl (doc arg)
  (declare (ignore arg))
  (repl-switch doc))

(define-command clamacs-interrupt (doc arg)
  (declare (ignore arg))
  (repl-interrupt doc))

(defmacro define-repl-command (name (doc) &body body)
  "A command that acts in the REPL window and nowhere else."
  `(define-command ,name (,doc arg)
     (declare (ignore arg))
     (cond ((not (repl-mode-p ,doc))
            (doc-message ,doc "Not in the REPL window (C-c C-z goes there)")
            (doc-beep ,doc))
           (t ,@body))))

(define-repl-command clamacs-repl-return (doc)
  (repl-return doc))

(define-repl-command clamacs-repl-previous-input (doc)
  (repl-history-walk doc t))

(define-repl-command clamacs-repl-next-input (doc)
  (repl-history-walk doc nil))

(define-repl-command clamacs-repl-clear (doc)
  (repl-clear doc))

;;; ------------------------------------------------------------------
;;; Keeping edits inside the input
;;; ------------------------------------------------------------------

(defun repl-unbound-key (doc key)
  "A key the Emacs layer did not take, in the REPL window: true when it
is swallowed.  Only what would edit: a character, Backspace, Delete.
Motion and the widget's other keys pass."
  (let ((code (key-code key))
        (state (doc-repl doc)))
    (cond
      ((/= (key-mods key) 0) nil)
      ((not (or (= code +key-backspace+) (= code +key-delete+)
                (<= +key-space+ code #xFF)))
       nil)
      ((null (repl-window-input-start state))
       (repl-busy-message doc)
       t)
      (t
       (let ((cursor (doc-point doc))
             (start (repl-window-input-start state)))
         (cond ((= code +key-backspace+) (<= cursor start))   ; the prompt stays
               ((= code +key-delete+) (< cursor start))
               (t
                ;; Typing into the transcript lands in the input instead.
                (when (< cursor start)
                  (doc-set-point doc (doc-end doc)))
                nil)))))))

(defparameter *repl-editing-commands*
  '(delete-char backward-delete-char kill-word backward-kill-word kill-line
    kill-region yank yank-pop kill-sexp insert-parentheses
    indent-for-tab-command newline-and-indent indent-region complete-symbol)
  "The commands that change the text: refused while a form runs, and
redirected into the input when the cursor is in the transcript.")

(defun repl-allow-command (doc command)
  "Whether COMMAND may run in the REPL window now.  Undo is never
available (a step could take back an OUTPUT insert), C-a on the prompt
line stops after the prompt as in comint, and an edit is kept inside the
input."
  (let* ((state (doc-repl doc))
         (start (repl-window-input-start state)))
    (cond
      ((member command '(undo redo))
       (doc-message doc "Undo is not available in the REPL")
       (doc-beep doc)
       nil)
      ((and (eq command 'beginning-of-line) start)
       (let ((cursor (doc-point doc)))
         (cond ((and (> cursor start)
                     (= (doc-index-line doc cursor) (doc-index-line doc start)))
                (doc-set-point doc start)
                nil)
               (t t))))
      ((not (member command *repl-editing-commands*)) t)
      ((null start)
       (repl-busy-message doc)
       nil)
      (t
       (when (< (doc-point doc) start)
         (doc-set-point doc (doc-end doc)))
       (when (and (doc-mark doc) (< (doc-mark doc) start))
         (setf (doc-mark doc) start))
       t))))

;;; ------------------------------------------------------------------
;;; What clamiga sends
;;; ------------------------------------------------------------------

(defun repl-output (editor text)
  (let ((doc (repl-doc editor)))
    (when (and doc text (string/= text ""))
      (let ((state (doc-repl doc)))
        (cond ((repl-window-input-start state)
               ;; A prompt (or a READLINE's input) is showing: the output
               ;; goes above it, and the indices follow.
               (let ((at (or (repl-window-prompt-start state)
                             (repl-window-input-start state)))
                     (bol (repl-window-bol state)))
                 (repl-insert doc at text)
                 (setf (repl-window-bol state) bol)))   ; the end did not change
              (t
               (repl-append doc text)))))))

(defun repl-readline (editor)
  (let ((doc (repl-doc editor)))
    (when doc
      (let ((state (doc-repl doc))
            (end (doc-end doc)))
        (setf (repl-window-reading state) t
              (repl-window-prompt-start state) end
              (repl-window-input-start state) end)
        (doc-set-point doc end)
        (doc-message doc "clamiga is reading a line: type it and press RET")))))

(defun repl-result (editor rc package values)
  (let* ((session (repl-session editor))
         (doc (repl-doc editor))
         (origin (repl-session-origin session)))
    (cond
      (origin
       ;; A buffer eval: the values are that buffer's news, the transcript
       ;; keeps its prompt (any output already went above it), and the
       ;; prompt's package is not touched.
       (setf (repl-session-origin session) nil)
       (repl-wire-package editor package)
       (when (debugger-active-p editor)
         (debug-left editor))
       (let ((from (live-doc origin))
             (line (first-line values)))
         (when from
           (cond ((/= rc +rc-ok+)
                  (doc-message from (if (string/= line "") line "Evaluation failed"))
                  (doc-beep from))
                 (t
                  (doc-message from (if (string/= line "") line "; No values")))))))
      ((null doc))
      (t
       (let ((state (doc-repl doc)))
         (setf (repl-window-busy state) nil
               (repl-window-reading state) nil
               (repl-window-prompt-start state) nil
               (repl-window-input-start state) nil)
         (repl-set-package doc package)
         ;; The form is done, so the debugger is too, whatever was announced.
         (when (debugger-active-p editor)
           (debug-left editor))
         (repl-ensure-bol doc)
         (when (and values (string/= values ""))
           (repl-append doc values)
           (unless (repl-window-bol state)
             (repl-append doc (string #\Newline))))
         (cond ((/= rc +rc-ok+)
                (let ((line (first-line values)))
                  (doc-message doc (if (string/= line "") line "Evaluation failed"))
                  (doc-beep doc)))
               (t (doc-message doc "")))
         (repl-prompt doc))))))

(defun repl-debugger (editor level package text)
  "DEBUGGER <level> <pkg>.  The form is still running -- parked in the
debugger -- so the transcript stays as it is; the window is the
debugger's face (debugger.lisp).  The package is the REPL thread's, moved
by a FRAME-EVAL's IN-PACKAGE as a form's would be."
  (let ((session (repl-session editor))
        (doc (repl-doc editor)))
    (cond ((repl-session-origin session) (repl-wire-package editor package))
          (doc (repl-set-package doc package)))
    (if (> level 0)
        (debug-entered editor level text)
        (debug-left editor))))

;;; The four verbs at the editor's port.  The transport registers OUTPUT,
;;; RESULT and DEBUGGER as RAW verbs with EXT.DEV: a chunk of output is
;;; text, not syntax, and keeps its blanks and its newline.
(defparameter *raw-port-verbs* '("OUTPUT" "RESULT" "DEBUGGER"))

(define-port-verb "OUTPUT" (editor arg)
  (repl-output editor arg)
  (values +rc-ok+ ""))

(define-port-verb "READLINE" (editor arg)
  (declare (ignore arg))
  (repl-readline editor)
  (values +rc-ok+ ""))

(define-port-verb "RESULT" (editor arg)
  (multiple-value-bind (rc package body) (parse-result-header arg)
    (cond ((null rc)
           (values +rc-fatal+ "ERROR: RESULT <rc> <package> expected"))
          (t (repl-result editor rc package body)
             (values +rc-ok+ "")))))

(define-port-verb "DEBUGGER" (editor arg)
  (multiple-value-bind (level package body) (parse-result-header arg)
    (cond ((null level)
           (values +rc-fatal+ "ERROR: DEBUGGER <level> <package> expected"))
          (t (repl-debugger editor level package body)
             (values +rc-ok+ "")))))

;;; ------------------------------------------------------------------
;;; The replies to the editor's own REPL commands
;;; ------------------------------------------------------------------

(defun repl-reply (wire kind doc rc text)
  "The reply to a REPL-* request: KIND is the request's, DOC the live
document it was about (NIL once closed)."
  (let* ((editor (wire-editor wire))
         (session (repl-session editor))
         (text (or text ""))
         (line (first-line text)))
    (case kind
      (:repl-attach
       (setf (repl-session-attaching session) nil)
       (cond
         ((/= rc +rc-ok+)
          (let ((from (live-doc (repl-session-pending-origin session)))
                (shown (if (string/= line "") line "REPL-ATTACH failed")))
            (when doc
              (repl-note doc "~A" shown)
              (doc-message doc shown)
              (doc-beep doc)
              ;; A prompt all the same, so RET says what is missing
              ;; instead of calling the REPL busy.
              (repl-prompt doc))
            ;; The buffer eval that waited for this is off.
            (when (and from (not (eq from doc)))
              (doc-message from shown)
              (doc-beep from))
            (repl-clear-pending session)))
         ((or (null doc) (not (eq doc (repl-doc editor))))
          ;; The window went away while the request was out: do not leave
          ;; a REPL thread sending to nobody.
          (wire-request wire nil :repl-detach "REPL-DETACH")
          (repl-clear-pending session))
         (t
          (setf (repl-session-attached session) t
                (repl-session-origin session) nil
                (repl-window-busy (doc-repl doc)) nil
                (repl-window-reading (doc-repl doc)) nil)
          (repl-set-package doc line)
          (repl-note doc "REPL attached to ~A" (wire-port-name wire))
          (message doc "REPL attached to ~A" (wire-port-name wire))
          (repl-prompt doc)
          ;; Now the buffer eval that asked for the attach.
          (let ((form (repl-session-pending session))
                (from (live-doc (repl-session-pending-origin session))))
            (repl-clear-pending session)
            (when (and form from)
              (repl-eval-from from form))))))
      (:repl-eval
       (when (and (/= rc +rc-ok+) doc)
         ;; Refused: the REPL thread is gone (clamiga restarted) or still busy.
         (when (search "no REPL attached" text)
           (setf (repl-session-attached session) nil))
         (doc-message doc (if (string/= line "") line "REPL-EVAL failed"))
         (doc-beep doc)
         (cond ((eq doc (repl-doc editor))
                ;; Typed at the prompt: the prompt comes back.
                (setf (repl-window-busy (doc-repl doc)) nil)
                (repl-prompt doc))
               ((eq (repl-session-origin session) doc)
                ;; A buffer eval that never started.
                (setf (repl-session-origin session) nil)))))
      (:repl-input
       (when (and (/= rc +rc-ok+) doc)
         (doc-message doc (if (string/= line "") line "REPL-INPUT failed"))
         (doc-beep doc)))
      (:repl-interrupt
       (when (and doc (string/= line ""))
         (doc-message doc line)))
      (t nil))))

;;; ------------------------------------------------------------------
;;; Housekeeping
;;; ------------------------------------------------------------------

(defun repl-detach (editor)
  (let ((wire (editor-wire editor)))
    (when wire
      (wire-request wire nil :repl-detach "REPL-DETACH"))))

(defun repl-closed (doc)
  "The REPL window is closing: a transcript is not a file, and closing it
stops clamiga's REPL thread."
  (let* ((editor (doc-editor doc))
         (session (repl-session editor)))
    (when (eq (repl-session-doc session) doc)
      (when (repl-session-attached session)
        (repl-detach editor))
      (setf (repl-session-attached session) nil
            (repl-session-attaching session) nil
            (repl-session-origin session) nil
            (repl-session-doc session) nil)
      (repl-clear-pending session)
      ;; The detach lets a parked REPL thread go; the window goes with it.
      (debug-left editor))))

(defun repl-disconnected (editor)
  "clamiga's port is gone."
  (let* ((session (repl-session editor))
         (doc (repl-doc editor)))
    (when (or (repl-session-attached session) (repl-session-attaching session))
      (setf (repl-session-attached session) nil
            (repl-session-attaching session) nil
            (repl-session-origin session) nil)
      (repl-clear-pending session)
      (debug-left editor)
      (when doc
        (let ((state (doc-repl doc)))
          (setf (repl-window-busy state) nil
                (repl-window-reading state) nil
                (repl-window-prompt-start state) nil
                (repl-window-input-start state) nil))
        (repl-note doc "clamiga is gone (it is attached again when it comes back)")
        (repl-prompt doc)))))

(defun repl-reconnected (editor)
  "The port is back.  A REPL window that lost its thread gets a new one
without being asked: the transcript says so, and the next RET at the
prompt or C-c C-c in a buffer just works."
  (let ((session (repl-session editor))
        (doc (repl-doc editor)))
    (when (and doc
               (not (repl-session-attached session))
               (not (repl-session-attaching session)))
      (repl-note doc "clamiga is back on ~A" (wire-port-name (editor-wire editor)))
      (repl-attach doc))))
