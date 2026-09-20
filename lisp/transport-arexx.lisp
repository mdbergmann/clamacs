;;;; transport-arexx.lisp -- the wire over ARexx, and the editor's port.
;;;;
;;;; The MUI-era implementation of wire.lisp's transport protocol, and the
;;;; port that answers port.lisp's verbs.  Three threads, one rule between
;;;; them (specs/clamacs-lisp.md, "Architecture"): only the MUI task touches
;;;; MUI, and only it touches the editor's state.
;;;;
;;;;   - The CLIENT thread takes one command at a time from TRANSPORT-SEND,
;;;;     performs the blocking AMIGA.AREXX:SEND to clamiga's port, and posts
;;;;     the reply into the MUI task's mailbox.  That is what keeps the
;;;;     editor live during a long LOAD without an asynchronous send in the
;;;;     runtime; the wire's queue keeps one request in flight, as the
;;;;     protocol demands.
;;;;   - The PORT thread is AMIGA.AREXX:START's: every verb of port.lisp is
;;;;     an EXT.DEV:DEFINE-COMMAND that posts to the mailbox and waits for
;;;;     the MUI task's answer.  The first instance's port is CLAMACS: the
;;;;     application object has no MUIA_Application_Base, so MUI opens no
;;;;     port of its own and the C editor's CLAMACS.1 quirk is gone.
;;;;   - Starting clamiga when no port is found is the C editor's recipe:
;;;;     the binary this editor runs on (PROGDIR:clamiga), through an
;;;;     Execute script that sets the 128K stack, in a console of its own,
;;;;     with a --load file that opens the development port -- no quoting
;;;;     on the DOS command line, where `*' and `"' have meanings of their
;;;;     own.
;;;;
;;;; Amiga only: loaded after frontend-mui.lisp.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "amiga/arexx")
  (require "amiga/raw/exec")
  (require "amiga/raw/dos")
  (require "amiga/mui"))

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Finding clamiga
;;; ------------------------------------------------------------------

;;; The same scan the shipped macros do: the base name, then .1 .. .9, so a
;;; second clamiga instance is reachable.
(defparameter *clamiga-port-names*
  (cons "CLAMIGA" (loop for i from 1 to 9 collect (format nil "CLAMIGA.~D" i))))

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
  thread)

(defmethod transport-find-port ((tr arexx-transport))
  (find-if #'port-exists-p *clamiga-port-names*))

(defmethod transport-own-port ((tr arexx-transport))
  "AMIGA.AREXX's port, CLAMACS on the first instance: what REPL-ATTACH
names.  The C editor had to scan for the port MUI numbered for it; this
one opened its own."
  (and (amiga.arexx:running-p) (amiga.arexx:port-name)))

(defmethod transport-send ((tr arexx-transport) port command)
  (mp:with-lock-held ((arexx-transport-lock tr))
    (setf (arexx-transport-pending tr) (cons port command))
    (mp:condition-notify (arexx-transport-cv tr))))

(defun client-loop (tr)
  "The client thread: send what is pending, post the reply, repeat."
  (let ((lock (arexx-transport-lock tr))
        (cv (arexx-transport-cv tr))
        (editor (arexx-transport-editor tr)))
    (loop
      (let ((job (mp:with-lock-held (lock)
                   (loop until (or (arexx-transport-quit tr)
                                   (arexx-transport-pending tr))
                         do (mp:condition-wait cv lock 1))
                   (prog1 (arexx-transport-pending tr)
                     (setf (arexx-transport-pending tr) nil)))))
        ;; A job pending at the quit still goes out: it is the REPL-DETACH
        ;; the closing REPL window queued, and clamiga's REPL thread must be
        ;; stopped rather than left sending to a port about to vanish.
        (when (and (arexx-transport-quit tr) (null job))
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
;;; Starting clamiga
;;; ------------------------------------------------------------------

;;; clamiga needs a 128K stack, and the stack a shell runs a command on is
;;; inherited from whatever started the editor -- from Workbench the 8000
;;; bytes of an icon -- so the launch is an Execute script that says Stack.
(defconstant +launch-stack-size+ 131072)
(defconstant +launch-wait-seconds+ 20)

(defun own-clamiga-command ()
  "The clamiga this editor runs on -- PROGDIR:clamiga as an absolute path,
since the shell System() starts has a PROGDIR: of its own -- or a bare
`clamiga' for one on the shell path."
  (let ((dir (dos:get-program-dir)))
    (or (and (/= dir 0)
             (let ((buf (ffi:alloc-foreign 512)))
               (unwind-protect
                    (ffi:with-foreign-string (name "clamiga")
                      (and (/= 0 (dos:name-from-lock dir buf 512))
                           (dos:add-part buf name 512)
                           (let ((lock (dos:lock buf dos:+access-read+)))
                             (when (/= lock 0)
                               (dos:un-lock lock)
                               (ffi:foreign-to-string buf)))))
                 (ffi:free-foreign buf))))
        "clamiga")))

(defun launch-file-names ()
  "The script and the preamble, named after this task so two editors (or
two rapid launches) never share a file."
  (let ((tag (format nil "~8,'0X" (ffi:foreign-pointer-address (exec:find-task nil)))))
    (values (format nil "T:clamacs-start-clamiga-~A" tag)
            (format nil "T:clamacs-port-~A.lisp" tag))))

(defun delete-quietly (path)
  (ignore-errors (when (probe-file path) (delete-file path))))

(defmethod transport-launch ((tr arexx-transport))
  (multiple-value-bind (script preamble) (launch-file-names)
    (let ((command (own-clamiga-command)))
      (unless (and (write-file-text
                    preamble
                    (format nil "(require \"amiga/arexx\")~%(unless (amiga.arexx:running-p) (amiga.arexx:start))~%"))
                   (write-file-text
                    script
                    (format nil "Stack ~D~%\"~A\" --load ~A~%" +launch-stack-size+ command preamble)))
        (delete-quietly preamble)
        (delete-quietly script)
        (return-from transport-launch nil))
      ;; clamiga gets a console of its own: it is a REPL in its own right.
      (let ((console (ffi:with-foreign-string (s "CON:0/40/640/220/clamiga/CLOSE/WAIT")
                       (dos:open s dos:+mode-oldfile+))))
        (when (zerop console)
          (delete-quietly preamble)
          (delete-quietly script)
          (return-from transport-launch nil))
        (let ((rc (ffi:with-foreign-string (cmd (format nil "Execute ~A" script))
                    (mui:with-tags (tags dos:+sys-input+ console
                                         dos:+sys-output+ 0
                                         dos:+sys-asynch+ t
                                         dos:+np-name+ "clamiga"
                                         dos:+np-stack-size+ +launch-stack-size+)
                      (dos:system-tag-list cmd tags)))))
          (when (/= rc 0)
            ;; System() only takes the handle once it succeeds.
            (dos:close console)
            (delete-quietly preamble)
            (delete-quietly script)
            (return-from transport-launch nil))
          ;; The port appears once the preamble has run.  This is the one
          ;; place the editor waits, and it waits before there is anything
          ;; to be responsive about.  By then Execute has read the script
          ;; and clamiga the preamble, so both can go.
          (let ((found nil))
            (dotimes (i (* 5 +launch-wait-seconds+))
              (sleep 0.2)
              (when (transport-find-port tr)
                (setq found t)
                (return)))
            (delete-quietly script)
            (delete-quietly preamble)
            found))))))

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
clamiga's.  EVAL replaces EXT.DEV's own: on this port it names an editor
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
the closed mailbox has answered it), then the client thread.  A client
still inside a send to a clamiga that never replies cannot be helped:
that is the ARexx rule, and the editor does not wait for it forever."
  (handler-case (amiga.arexx:stop)
    (error (e) (report-error editor e)))
  (let ((tr (wire-transport (editor-wire editor))))
    (mp:with-lock-held ((arexx-transport-lock tr))
      (setf (arexx-transport-quit tr) t)
      (mp:condition-notify (arexx-transport-cv tr)))
    (let ((thread (arexx-transport-thread tr)))
      (loop repeat 50
            while (and thread (mp:thread-alive-p thread))
            do (sleep 0.1)))))

(setf *wire-starter* #'start-wire
      *wire-stopper* #'stop-wire)
