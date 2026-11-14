;;;; transport-arexx.lisp -- the wire over ARexx, and the editor's port.
;;;;
;;;; The MUI-era implementation of wire.lisp's transport protocol, and the
;;;; port that answers port.lisp's verbs.  Three threads, one rule between
;;;; them (specs/clamacs-lisp.md, "Architecture"): only the MUI task touches
;;;; MUI, and only it touches the editor's state.
;;;;
;;;;   - The CLIENT thread takes one command at a time from TRANSPORT-SEND,
;;;;     performs the blocking AMIGA.AREXX:SEND to amilisp's port, and posts
;;;;     the reply into the MUI task's mailbox.  That is what keeps the
;;;;     editor live during a long LOAD without an asynchronous send in the
;;;;     runtime; the wire's queue keeps one request in flight, as the
;;;;     protocol demands.
;;;;   - The PORT thread is AMIGA.AREXX:START's: every verb of port.lisp is
;;;;     an EXT.DEV:DEFINE-COMMAND that posts to the mailbox and waits for
;;;;     the MUI task's answer.  The first instance's port is CLAMACS: the
;;;;     application object has no MUIA_Application_Base, so MUI opens no
;;;;     port of its own and the C editor's CLAMACS.1 quirk is gone.
;;;;   - Starting amilisp when no port is found is the C editor's recipe:
;;;;     the binary this editor runs on (PROGDIR:amilisp), through an
;;;;     Execute script that sets the 128K stack, in a console of its own,
;;;;     with a --load file that opens the development port -- no quoting
;;;;     on the DOS command line, where `*' and `"' have meanings of their
;;;;     own.  Since 2026-10-20 that amilisp is headless, as the host's
;;;;     is: `--non-interactive', the preamble waiting on a flag once the
;;;;     port is up, and the editor's exit sets the flag over the port
;;;;     (the client thread's farewell), so the child and its console go
;;;;     with the editor.  A console REPL could not be stopped from
;;;;     outside -- its read of the console blocks, nothing interrupts
;;;;     it -- and stayed open on the MorphOS box after every quit.
;;;;     The start is in two halves: TRANSPORT-LAUNCH-BEGIN runs the
;;;;     script and returns, TRANSPORT-LAUNCH-POLL takes the port as ours
;;;;     once it exists.  An editor coming up with *AUTO-START-AMILISP*
;;;;     (MorphOS's default; WIRE-AUTO-START) runs the first and goes on:
;;;;     the client thread watches for the port and tells the wire on the
;;;;     MUI task.  `Start amilisp' runs both and waits in between.
;;;;
;;;; Amiga only: loaded after frontend-mui.lisp.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "amiga/arexx")
  (require "amiga/raw/exec")
  (require "amiga/raw/dos")
  (require "amiga/mui"))

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Finding amilisp
;;; ------------------------------------------------------------------

;;; *amilisp-port-names* (the scan list) lives in wire.lisp.

(defun port-exists-p (name)
  (ffi:with-foreign-string (s name)
    (let ((port (exec:find-port s)))
      (and port (not (ffi:null-pointer-p port)) t))))

;;; ------------------------------------------------------------------
;;; The transport
;;; ------------------------------------------------------------------

(defstruct (arexx-transport (:constructor %make-arexx-transport (editor)))
  editor
  (lock (mp:make-lock "clamacs-client"))
  (cv (mp:make-condition-variable "clamacs-client"))
  (pending nil)             ; (port . command) for the client thread
  (quit nil)
  (launched nil)            ; the port of an amilisp this editor started
  ;; The launch under way (TRANSPORT-LAUNCH-BEGIN), an AREXX-START, or
  ;; NIL; and whether the client thread has told the wire it is settled.
  (starting nil)
  (start-told nil)
  thread)

(defstruct (arexx-start (:constructor make-arexx-start (script preamble deadline)))
  script preamble
  deadline)                 ; internal time after which no port is waited for

(defmethod transport-find-port ((tr arexx-transport))
  (find-if #'port-exists-p *amilisp-port-names*))

(defmethod transport-own-port ((tr arexx-transport))
  "AMIGA.AREXX's port, CLAMACS on the first instance: what REPL-ATTACH
names.  The C editor had to scan for the port MUI numbered for it; this
one opened its own."
  (and (amiga.arexx:running-p) (amiga.arexx:port-name)))

(defmethod transport-send ((tr arexx-transport) port command)
  (mp:with-lock-held ((arexx-transport-lock tr))
    (setf (arexx-transport-pending tr) (cons port command))
    (mp:condition-notify (arexx-transport-cv tr))))

(defun arexx-launch-status (tr)
  "How the launch under way stands, changing nothing: (values :UP PORT),
:FAILED or :PENDING.  The client thread asks too."
  (let ((start (arexx-transport-starting tr)))
    (if (null start)
        :failed
        (let ((port (transport-find-port tr)))
          (cond (port (values :up port))
                ((> (get-internal-real-time) (arexx-start-deadline start)) :failed)
                (t :pending))))))

(defun watch-launch (tr)
  "The client thread's look at a launch under way: once it is settled --
the port there, or the time over -- the wire is told, once, on the MUI
task, where TRANSPORT-LAUNCH-POLL acts on it."
  (when (and (arexx-transport-starting tr)
             (not (arexx-transport-start-told tr))
             (not (eq (arexx-launch-status tr) :pending)))
    (setf (arexx-transport-start-told tr) t)
    (let ((editor (arexx-transport-editor tr)))
      (call-in-editor editor
                      (lambda ()
                        (let ((wire (editor-wire editor)))
                          (when wire (wire-launch-poll wire)))
                        ;; Still under way after all: look again.
                        (setf (arexx-transport-start-told tr) nil))
                      :wait nil))))

(defun client-loop (tr)
  "The client thread: send what is pending, post the reply, watch a launch
under way, repeat."
  (let ((lock (arexx-transport-lock tr))
        (cv (arexx-transport-cv tr))
        (editor (arexx-transport-editor tr)))
    (loop
      (let ((job (mp:with-lock-held (lock)
                   (loop until (or (arexx-transport-quit tr)
                                   (arexx-transport-pending tr))
                         do (mp:condition-wait cv lock (if (arexx-transport-starting tr) 0.5 1))
                            ;; A launch is looked at twice a second.
                            (when (arexx-transport-starting tr)
                              (return)))
                   (prog1 (arexx-transport-pending tr)
                     (setf (arexx-transport-pending tr) nil)))))
        (unless (arexx-transport-quit tr)
          (watch-launch tr))
        ;; A job pending at the quit still goes out: it is the REPL-DETACH
        ;; the closing REPL window queued, and amilisp's REPL thread must be
        ;; stopped rather than left sending to a port about to vanish.
        ;; After it the farewell to an amilisp this editor started -- the
        ;; one message at a time, on the thread that sends them.
        (when (and (arexx-transport-quit tr) (null job))
          (let ((launched (arexx-transport-launched tr)))
            (when launched
              (setf (arexx-transport-launched tr) nil)
              (ignore-errors (amiga.arexx:send launched *launched-stop-command*))))
          (return))
        (when job
          (multiple-value-bind (rc text lost)
              (handler-case
                  (multiple-value-bind (rc text) (amiga.arexx:send (car job) (cdr job))
                    (values rc text nil))
                ;; No such port, no rexxsyslib, no memory: the wire treats
                ;; every one as the port being gone, with the reason.
                (error (e)
                  (values +rc-fatal+
                          (handler-case (princ-to-string e)
                            (error () "the send failed"))
                          t)))
            (let ((wire (editor-wire editor)))
              (call-in-editor editor
                              (lambda () (wire-reply wire rc text :lost lost))
                              :wait nil))))))))

;;; ------------------------------------------------------------------
;;; Starting amilisp
;;; ------------------------------------------------------------------

;;; amilisp needs a 128K stack, and the stack a shell runs a command on is
;;; inherited from whatever started the editor -- from Workbench the 8000
;;; bytes of an icon -- so the launch is an Execute script that says Stack.
(defconstant +launch-stack-size+ 131072)
(defconstant +launch-wait-seconds+ 20)

(defparameter *launch-console* "CON:0/40/640/220/amilisp/AUTO/CLOSE/INACTIVE"
  "The console of an amilisp the editor starts: opened with the first line
printed (AUTO), and never taking the keyboard from the editor (INACTIVE)
-- the keys typed into an editor that had just come up went to this
window otherwise.")

;;; The started amilisp runs the preamble's wait loop on its main thread
;;; (SLEEP a half second at a time) until this variable is set -- which
;;; the editor's farewell does over the port; the EVAL is answered first,
;;; the loop ends within the half second, and amilisp's exit hooks take
;;; the port down cleanly behind it.
(defparameter *launched-stop-variable* "cl-user::*clamacs-launched-stop*")
(defparameter *launched-stop-command*
  (format nil "EVAL (setq ~A t)" *launched-stop-variable*))

(defun launch-preamble-text ()
  "What the started amilisp loads: the port, then the wait.  The port's
library is loaded without LOAD's `; Loading' lines: they were the only
thing a fresh amilisp printed, and enough to open its console window in
front of an editor that had just come up."
  (format nil "(let ((*load-verbose* nil)) (require \"amiga/arexx\"))~%~
               (unless (amiga.arexx:running-p) (amiga.arexx:start))~%~
               (defvar ~A nil)~%~
               (loop until ~A do (sleep 0.5))~%"
          *launched-stop-variable* *launched-stop-variable*))

(defun own-amilisp-command ()
  "The amilisp this editor runs on -- PROGDIR:amilisp as an absolute path,
since the shell System() starts has a PROGDIR: of its own (PROGDIR:clamiga,
the runtime's name before 0.12, is probed second so an old installation
still starts) -- or a bare `amilisp' for one on the shell path."
  (let ((dir (dos:get-program-dir)))
    (or (and (/= dir 0)
             (let ((buf (ffi:alloc-foreign 512)))
               (unwind-protect
                    (dolist (binary '("amilisp" "clamiga") nil)
                      (let ((found
                              (ffi:with-foreign-string (name binary)
                                (and (/= 0 (dos:name-from-lock dir buf 512))
                                     (dos:add-part buf name 512)
                                     (let ((lock (dos:lock buf dos:+access-read+)))
                                       (when (/= lock 0)
                                         (dos:un-lock lock)
                                         (ffi:foreign-to-string buf)))))))
                        (when found (return found))))
                 (ffi:free-foreign buf))))
        "amilisp")))

(defun launch-file-names ()
  "The script and the preamble, named after this task so two editors (or
two rapid launches) never share a file."
  (let ((tag (format nil "~8,'0X" (ffi:foreign-pointer-address (exec:find-task nil)))))
    (values (format nil "T:clamacs-start-amilisp-~A" tag)
            (format nil "T:clamacs-port-~A.lisp" tag))))

(defmethod transport-launch-begin ((tr arexx-transport))
  (when (arexx-transport-starting tr)
    ;; One is coming up: that is the launch.
    (return-from transport-launch-begin t))
  (multiple-value-bind (script preamble) (launch-file-names)
    (let ((command (own-amilisp-command)))
      (unless (and (write-file-text preamble (launch-preamble-text))
                   (write-file-text
                    script
                    ;; The init file's heap and options (wire.lisp) first.
                    (format nil "Stack ~D~%\"~A\"~{ ~A~} --non-interactive --load ~A~%"
                            +launch-stack-size+ command (amilisp-launch-options) preamble)))
        (delete-quietly preamble)
        (delete-quietly script)
        (return-from transport-launch-begin nil))
      ;; amilisp gets a console of its own for what it prints -- it reads
      ;; nothing from it -- which closes with it (no WAIT: the farewell
      ;; at the editor's exit ends it, and a window left behind was the
      ;; complaint).  *LAUNCH-CONSOLE* says how it opens: with the first
      ;; line printed, so an amilisp that says nothing -- the one an
      ;; editor starts as it comes up, most days -- puts no window on the
      ;; screen, and without the keyboard.
      (let ((console (ffi:with-foreign-string (s *launch-console*)
                       (dos:open s dos:+mode-oldfile+))))
        (when (zerop console)
          (delete-quietly preamble)
          (delete-quietly script)
          (return-from transport-launch-begin nil))
        (let ((rc (ffi:with-foreign-string (cmd (format nil "Execute ~A" script))
                    (mui:with-tags (tags dos:+sys-input+ console
                                         dos:+sys-output+ 0
                                         dos:+sys-asynch+ t
                                         dos:+np-name+ "amilisp"
                                         dos:+np-stack-size+ +launch-stack-size+)
                      (dos:system-tag-list cmd tags)))))
          (when (/= rc 0)
            ;; System() only takes the handle once it succeeds.
            (dos:close console)
            (delete-quietly preamble)
            (delete-quietly script)
            (return-from transport-launch-begin nil))
          ;; The port appears once the preamble has run: the client thread
          ;; watches for it, and TRANSPORT-LAUNCH-POLL takes it as ours.
          (mp:with-lock-held ((arexx-transport-lock tr))
            (setf (arexx-transport-start-told tr) nil
                  (arexx-transport-starting tr)
                  (make-arexx-start script preamble
                                    (+ (get-internal-real-time)
                                       (* +launch-wait-seconds+
                                          internal-time-units-per-second))))
            (mp:condition-notify (arexx-transport-cv tr)))
          t)))))

(defmethod transport-launch-poll ((tr arexx-transport))
  (let ((start (arexx-transport-starting tr)))
    (multiple-value-bind (status port) (arexx-launch-status tr)
      (case status
        (:pending :pending)
        (t
         (when start
           (setf (arexx-transport-starting tr) nil)
           ;; By now Execute has read the script and amilisp the preamble
           ;; (or neither ever will), so both can go.
           (delete-quietly (arexx-start-script start))
           (delete-quietly (arexx-start-preamble start)))
         (cond ((and start (eq status :up))
                ;; Ours to stop at the exit (STOP-WIRE's client thread).
                (setf (arexx-transport-launched tr) port)
                :up)
               (t :failed)))))))

;;; ------------------------------------------------------------------
;;; The editor's port
;;; ------------------------------------------------------------------

(defparameter *editor-port-name* "CLAMACS")

(defun editor-port-call (verb arg)
  "A verb arriving on the port thread: run on the MUI task, answer here."
  (let ((editor *editor*))
    (if (null editor)
        (values +rc-fatal+ "ERROR: no editor is running")
        (call-in-editor editor (lambda () (port-verb editor verb arg))))))

(defun register-port-verbs ()
  "Every verb of port.lisp as an EXT.DEV command -- the same table the
handler thread dispatches from, so the editor's port is served exactly as
amilisp's.  EVAL replaces EXT.DEV's own: on this port it names an editor
command, or a form for the editor's Lisp when it starts with `('.  The
REPL thread's OUTPUT, RESULT and DEBUGGER (repl.lisp) are RAW verbs: a
chunk of output keeps its blanks and its newline, where every other
argument is trimmed."
  (dolist (verb (port-verb-names))
    (let ((verb verb))
      (if (member verb *raw-port-verbs* :test #'string=)
          (ext.dev:define-raw-command verb (arg)
            (editor-port-call verb arg))
          (ext.dev:define-command verb (arg)
            (editor-port-call verb arg))))))

(defun start-wire (editor)
  (let ((tr (%make-arexx-transport editor)))
    (make-wire editor tr)
    (setf (arexx-transport-thread tr)
          (mp:make-thread (lambda () (client-loop tr))
                          :name "clamacs-client"
                          :stack-size (* 64 1024)))
    (register-port-verbs)
    (amiga.arexx:start :name *editor-port-name*)))

(defun stop-wire (editor)
  "The port first (its handler thread may be parked in CALL-IN-EDITOR;
the closed mailbox has answered it), then the client thread, which sends
the farewell to an amilisp this editor started on its way out.  A client
still inside a send to an amilisp that never replies cannot be helped:
that is the ARexx rule, and the editor does not wait for it forever."
  (handler-case (amiga.arexx:stop)
    (error (e) (report-error editor e)))
  ;; The editor's own Lisp first: its REPL thread sends through the
  ;; mailbox, which is closed by now, and its worker may be in a LOAD.
  (let ((self (wire-self (editor-wire editor))))
    (when self
      (self-transport-stop self)))
  (let ((tr (wire-home (editor-wire editor))))
    ;; An amilisp still coming up is waited for: the farewell needs its
    ;; port, and one left behind would wait on its flag for good.
    (when (arexx-transport-starting tr)
      (transport-launch-wait tr))
    (mp:with-lock-held ((arexx-transport-lock tr))
      (setf (arexx-transport-quit tr) t)
      (mp:condition-notify (arexx-transport-cv tr)))
    (let ((thread (arexx-transport-thread tr)))
      (loop repeat 50
            while (and thread (mp:thread-alive-p thread))
            do (sleep 0.1)))))

(setf *wire-starter* #'start-wire
      *wire-stopper* #'stop-wire
      ;; `clamacs-connect-self': the wire to the editor's own Lisp reaches
      ;; the MUI task through the same mailbox as everything else.
      *self-transport-maker*
      (lambda (editor)
        (make-self-transport editor
                             (lambda (thunk wait)
                               (call-in-editor editor thunk :wait wait)))))
