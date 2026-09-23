;;;; transport-self.lisp -- the wire to the editor's own Lisp.
;;;;
;;;; The editor is a clamiga instance of its own, so everything the wire
;;;; asks of clamiga -- the REPL, the debugger, the inspector, arglist,
;;;; completion, describe, apropos, `M-.', LOAD -- can be asked of the
;;;; editor instead: `M-x clamacs-connect-self' switches the wire over to
;;;; this transport (wire.lisp, WIRE-SWITCH), `M-x clamacs-connect-clamiga'
;;;; switches it back.  That is how the running editor is hacked and
;;;; measured from inside, with the tools already written for clamiga and
;;;; no second implementation of any of them.
;;;;
;;;; The command set is clamiga's own: EXT.DEV (lib/dev-commands.lisp and,
;;;; on the first REPL-ATTACH, lib/dev-repl.lisp) is already in the editor,
;;;; because its ARexx port is served from the same table.  What changes is
;;;; only the route:
;;;;
;;;;   - A command goes to a WORKER thread, which runs
;;;;     EXT.DEV:HANDLE-COMMAND and posts the reply back to the editor's task
;;;;     -- the client thread's shape in transport-arexx.lisp, and for the
;;;;     same reason: the editor never waits, and a LOAD of a big file (or a
;;;;     FRAME waiting for the REPL thread) must not freeze it.
;;;;   - The REPL thread sends OUTPUT, READLINE, RESULT and DEBUGGER through
;;;;     EXT.DEV:*REPL-SEND*.  This transport wraps that function: the port
;;;;     name it hands to REPL-ATTACH (+SELF-OWN-PORT+) is delivered to the
;;;;     editor's own verbs in-process, anything else goes on to the
;;;;     function it replaced (AMIGA.AREXX:SEND on the Amiga).
;;;;   - LASTRESULT is answered here, from this transport's own last reply:
;;;;     the global *LAST-RESULT* is also written by every macro talking to
;;;;     the editor's port.
;;;;
;;;; A form typed at the self REPL runs on the REPL thread, NOT on the
;;;; editor's task: it can be interrupted (C-c C-c), an error opens the
;;;; debugger, and output streams into the transcript.  Code that touches
;;;; a document or a window must run on the editor's task, which is what
;;;; IN-EDITOR is for -- `(clamacs:in-editor (doc-name (editor-active-document
;;;; clamacs::*editor*)))'.  It is not the default because the REPL thread
;;;; needs the editor's task to deliver its OUTPUT: a form running there
;;;; could never print.
;;;;
;;;; Portable: MP and EXT.DEV, no MUI, no OS types.  The frontend supplies
;;;; the one thing that is its own -- how a closure gets run on the editor's
;;;; task -- as the CALL function; tests/test-self.lisp drives all of it on
;;;; the host.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "dev-commands"))

(in-package :clamacs)

(defparameter *self-port-name* "the editor itself"
  "What the wire shows as the port it talks to: `REPL attached to the
editor itself'.")

(defparameter *self-own-port* "CLAMACS-SELF"
  "The port name REPL-ATTACH is given.  Never a real ARexx port: the
wrapped *REPL-SEND* recognises it and delivers in-process.")

(defvar *self-worker-stack-size* (* 256 1024)
  "The worker compiles code (LOAD, COMPILE-FILE): the REPL thread's size.")

(defstruct (self-transport (:constructor %make-self-transport (editor call)))
  editor
  ;; A function of (THUNK WAIT): run THUNK on the editor's task.  With
  ;; WAIT, return its values; without, return at once.
  call
  (lock (mp:make-lock "clamacs-self"))
  (cv (mp:make-condition-variable "clamacs-self"))
  (pending nil)             ; the command for the worker
  (quit nil)
  (thread nil)
  (last "")                 ; the text LASTRESULT answers
  ;; The thread the transport was made on: the editor's task.  IN-EDITOR
  ;; called there runs its body directly.
  (home-thread (mp:current-thread))
  ;; The *REPL-SEND* this transport wrapped, put back by SELF-TRANSPORT-STOP.
  (previous-send nil)
  (wrapped nil))

(defvar *self-transport* nil
  "The live self transport, or NIL: what IN-EDITOR reaches the editor's
task through.")

(defmethod transport-find-port ((tr self-transport))
  *self-port-name*)

(defmethod transport-launch ((tr self-transport))
  "Nothing to start: the editor is running."
  t)

(defmethod transport-own-port ((tr self-transport))
  *self-own-port*)

(defmethod transport-send ((tr self-transport) port command)
  (declare (ignore port))
  (mp:with-lock-held ((self-transport-lock tr))
    (setf (self-transport-pending tr) command)
    (mp:condition-notify (self-transport-cv tr))))

;;; ------------------------------------------------------------------
;;; The worker
;;; ------------------------------------------------------------------

(defun self-handle (tr command)
  "COMMAND run on the editor's own EXT.DEV table: (values RC TEXT)."
  (if (string-equal (string-trim '(#\Space #\Tab) command) "LASTRESULT")
      (values +rc-ok+ (self-transport-last tr))
      (multiple-value-bind (rc text) (ext.dev:handle-command command)
        (setf (self-transport-last tr) text)
        (values rc text))))

(defun self-worker-loop (tr)
  (let ((lock (self-transport-lock tr))
        (cv (self-transport-cv tr))
        (editor (self-transport-editor tr)))
    (loop
      (let ((command (mp:with-lock-held (lock)
                       (loop until (or (self-transport-quit tr)
                                       (self-transport-pending tr))
                             do (mp:condition-wait cv lock 1))
                       (prog1 (self-transport-pending tr)
                         (setf (self-transport-pending tr) nil)))))
        ;; A command pending at the quit still runs: it is the REPL-DETACH
        ;; that stops the REPL thread.
        (when (and (self-transport-quit tr) (null command))
          (return))
        (when command
          (multiple-value-bind (rc text) (self-handle tr command)
            (funcall (self-transport-call tr)
                     (lambda () (wire-reply (editor-wire editor) rc text))
                     nil)))))))

;;; ------------------------------------------------------------------
;;; The REPL thread's way back
;;; ------------------------------------------------------------------

(defun self-inbound (tr command)
  "What the REPL thread sends (OUTPUT, READLINE, RESULT, DEBUGGER), run on
the editor's task as the port would run it: (values RC TEXT)."
  (let ((editor (self-transport-editor tr)))
    (funcall (self-transport-call tr)
             (lambda () (port-raw-command editor command))
             t)))

(defun self-wrap-send (tr)
  (unless (self-transport-wrapped tr)
    (let ((previous ext.dev:*repl-send*))
      (setf (self-transport-previous-send tr) previous
            (self-transport-wrapped tr) t
            ext.dev:*repl-send*
            (lambda (port command)
              (cond ((string= port *self-own-port*)
                     (self-inbound tr command))
                    (previous (funcall previous port command))
                    (t (error "No ARexx transport to reach port ~A" port))))))))

;;; ------------------------------------------------------------------
;;; Making and stopping
;;; ------------------------------------------------------------------

(defun make-self-transport (editor call)
  "The self transport for EDITOR, its worker running.  CALL is the
frontend's way onto the editor's task, a function of (THUNK WAIT)."
  (let ((tr (%make-self-transport editor call)))
    (self-wrap-send tr)
    (setf (self-transport-thread tr)
          (mp:make-thread (lambda () (self-worker-loop tr))
                          :name "clamacs-self"
                          :stack-size *self-worker-stack-size*))
    (setf *self-transport* tr)
    tr))

(defun self-repl-running-p ()
  "Whether EXT.DEV's REPL thread is running for this transport.  Read by
name: dev-repl is loaded on the first REPL-ATTACH, not before."
  (let ((alive (find-symbol "%REPL-ALIVE-P" "EXT.DEV"))
        (port (find-symbol "*REPL-PORT*" "EXT.DEV")))
    (and alive port (fboundp alive) (funcall alive)
         (equal (symbol-value port) *self-own-port*))))

(defun self-transport-stop (tr)
  "Stop the REPL thread when it is this transport's, then the worker, and
put *REPL-SEND* back.  For the editor's exit and the tests."
  (when (self-repl-running-p)
    (ignore-errors (funcall (find-symbol "%REPL-STOP" "EXT.DEV"))))
  (mp:with-lock-held ((self-transport-lock tr))
    (setf (self-transport-quit tr) t)
    (mp:condition-notify (self-transport-cv tr)))
  (let ((thread (self-transport-thread tr)))
    (loop repeat 50
          while (and thread (mp:thread-alive-p thread))
          do (sleep 0.1)))
  (when (self-transport-wrapped tr)
    (setf ext.dev:*repl-send* (self-transport-previous-send tr)
          (self-transport-wrapped tr) nil))
  (when (eq *self-transport* tr)
    (setf *self-transport* nil)))

;;; ------------------------------------------------------------------
;;; IN-EDITOR
;;; ------------------------------------------------------------------

(defun call-in-editor-task (thunk)
  "THUNK's values, THUNK run on the editor's task.  What it prints comes
back and is printed here, on the calling thread, so the REPL transcript
shows it; an error there is signalled again here, so it reaches the
REPL's debugger instead of the editor's error report."
  (let ((tr *self-transport*))
    (if (or (null tr) (eq (mp:current-thread) (self-transport-home-thread tr)))
        (funcall thunk)
        (let ((answer
                (funcall (self-transport-call tr)
                         (lambda ()
                           (let* ((values '())
                                  (problem nil)
                                  (output
                                    (with-output-to-string (s)
                                      (let ((*standard-output* s)
                                            (*error-output* s)
                                            (*trace-output* s))
                                        (handler-case
                                            (setq values (multiple-value-list (funcall thunk)))
                                          (error (e)
                                            (setq problem
                                                  (handler-case (princ-to-string e)
                                                    (error () "(unprintable condition)")))))))))
                             (list output problem values)))
                         t)))
          (unless (listp answer)
            (error "The editor is shutting down"))
          (destructuring-bind (output problem values) answer
            (write-string output)
            (when problem
              (error "In the editor's task: ~A" problem))
            (values-list values))))))

(defmacro in-editor (&body body)
  "Run BODY on the editor's task, where documents and windows may be
touched, and return its values.  From the self REPL: the REPL thread
waits, what BODY prints lands in the transcript, an error opens the
debugger.  On the editor's task itself it just runs BODY."
  `(call-in-editor-task (lambda () ,@body)))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defvar *self-transport-maker* nil
  "A function of (EDITOR) that makes the self transport, installed by the
frontend (transport-arexx.lisp: CALL is CALL-IN-EDITOR).  NIL: this
editor cannot talk to itself.")

(defun wire-self-transport (wire)
  "WIRE's self transport, made on first use, or NIL."
  (or (wire-self wire)
      (and *self-transport-maker*
           (setf (wire-self wire)
                 (funcall *self-transport-maker* (wire-editor wire))))))

(define-command clamacs-connect-self (doc arg)
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (let ((tr (wire-self-transport wire)))
        (cond ((null tr)
               (doc-message doc "This editor cannot talk to its own Lisp")
               (doc-beep doc))
              ((wire-switch-to wire)
               (doc-message doc "A switch is already under way")
               (doc-beep doc))
              ((eq (wire-transport wire) tr)
               (doc-message doc "Already talking to the editor itself"))
              (t
               (wire-switch wire tr)
               (unless (eq (wire-transport wire) tr)
                 (doc-message doc "Switching to the editor itself ..."))))))))

(define-command clamacs-connect-clamiga (doc arg)
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (let ((home (wire-home wire)))
        (cond ((wire-switch-to wire)
               (doc-message doc "A switch is already under way")
               (doc-beep doc))
              ((eq (wire-transport wire) home)
               (doc-message doc "Already talking to clamiga"))
              (t
               (wire-switch wire home)
               (unless (eq (wire-transport wire) home)
                 (doc-message doc "Switching back to clamiga ..."))))))))

;;; ------------------------------------------------------------------
;;; The editor's memory
;;; ------------------------------------------------------------------

(defgeneric editor-memory-lines (editor)
  (:documentation "The system's free memory, one string per line, for
`clamacs-room': ROOM sees only the Lisp heap, and on an Amiga the number
that decides whether the next program starts is exec's AvailMem.")
  (:method ((editor editor)) '()))

(defun room-text (editor)
  (let ((heap (with-output-to-string (*standard-output*) (room)))
        (system (editor-memory-lines editor)))
    (format nil "The editor's own Lisp heap (ROOM):~%~%~A~%~@[~%System memory:~%~{  ~A~%~}~]"
            (string-right-trim '(#\Newline) heap)
            system)))

(define-command clamacs-room (doc arg)
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (unless (show-text-window editor "*clamacs-room*" nil (room-text editor))
      (doc-message doc "Cannot open *clamacs-room*")
      (doc-beep doc))))
