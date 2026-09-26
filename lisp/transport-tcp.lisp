;;;; transport-tcp.lisp -- the wire to a clamiga over TCP.
;;;;
;;;; The host's counterpart of transport-arexx.lisp (specs/clamacs-host.md,
;;;; "The wire: the editor's own image first, TCP second"): the wire's HOME
;;;; transport on the host, to a separate clamiga process serving
;;;; lib/dev-tcp.lisp's port, with the self transport (transport-self.lisp)
;;;; as the other side of `Talk to the Editor Itself'.  Three parts, the
;;;; same rule as on the Amiga: only the editor's task touches the editor.
;;;;
;;;;   - The CLIENT thread takes one command at a time from TRANSPORT-SEND,
;;;;     writes it on the authenticated connection to clamiga, reads the
;;;;     reply and posts it into the editor's mailbox.  That keeps the editor
;;;;     live during a long LOAD; the wire's queue keeps one request in
;;;;     flight, as the protocol demands.  A connection that is closed or
;;;;     refused is the port being gone (`wire-reply ... :lost t'), and the
;;;;     next request tries to connect again.
;;;;   - FINDING clamiga is a connect attempt to HOST:PORT with the token,
;;;;     from `CLAMACS_CLAMIGA' (`host:port', default 127.0.0.1:4005) and
;;;;     `CLAMACS_CLAMIGA_TOKEN' in the editor's environment, or from what
;;;;     the launch below settled.  Without a token there is nothing to try.
;;;;     A failed attempt is not repeated for *RETRY-SECONDS*: the idle
;;;;     timer and the menu ask often.  On this machine the attempt is made
;;;;     where it is asked (a connect there is answered at once); to another
;;;;     machine, which may leave a SYN unanswered for seconds, it is made by
;;;;     the client thread, and the find only reports what is connected --
;;;;     the editor's task never waits for the network.
;;;;   - STARTING clamiga (`Start clamiga', M-x run-lisp) is the binary this
;;;;     editor runs on (EXT:EXECUTABLE-PATH, or `CLAMACS_CLAMIGA_BIN')
;;;;     with `--load' of a preamble that starts the TCP port on an ephemeral
;;;;     port and writes the number to a file in the editor's private
;;;;     directory; the token the editor drew goes into the child's
;;;;     ENVIRONMENT (`CLAMIGA_TCP_TOKEN'), never on its command line and in
;;;;     no file.  The preamble ends with (ext.dev.tcp:wait), so the child
;;;;     serves until it is told to stop -- which the editor does at its own
;;;;     exit for a clamiga IT started (`EVAL (ext.dev.tcp:stop)' over the
;;;;     connection), and never for one the user started.  Its output goes
;;;;     to `clamacs-clamiga.log' beside the port files.
;;;;
;;;; The REPL's way back: TRANSPORT-OWN-PORT names the editor's own port as
;;;; `tcp:HOST:PORT/TOKEN' (transport-host.lisp), handed to clamiga on the
;;;; already authenticated connection by REPL-ATTACH; clamiga's REPL thread
;;;; connects back to it for OUTPUT, READLINE, RESULT and DEBUGGER, which
;;;; the port serves through PORT-RAW-COMMAND as it does for a macro.
;;;;
;;;; Portable Lisp: EXT sockets, MP threads, EXT.DEV.TCP's client side, two
;;;; libc calls (setenv, unsetenv) through the FFI for the launch.
;;;; tests/test-transport-tcp.lisp drives it against a dev-tcp server in the
;;;; test process, and verify/host/run-drive.sh against a clamiga the
;;;; editor starts.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "ffi")
  (require "dev-tcp"))

(in-package :clamacs)

(defparameter *clamiga-default-address* "127.0.0.1:4005"
  "Where `Connect' looks when CLAMACS_CLAMIGA says nothing.")

(defparameter *retry-seconds* 2
  "How long a failed connect attempt holds off the next one.")

(defparameter *launch-wait-seconds* 20
  "How long a started clamiga has to write its port file.")

(defparameter *launch-port-file-name* "clamacs-clamiga-port")
(defparameter *launch-preamble-name* "clamacs-clamiga.lisp")
(defparameter *launch-log-name* "clamacs-clamiga.log")

(defun parse-address (text)
  "(values HOST PORT) of `host:port', or NIL for anything else."
  (let ((colon (and (stringp text) (position #\: text :from-end t))))
    (and colon (> colon 0)
         (let ((port (parse-integer text :start (1+ colon) :junk-allowed t)))
           (and port (<= 1 port 65535)
                (= (length text) (+ 1 colon (length (princ-to-string port))))
                (values (subseq text 0 colon) port))))))

;;; ------------------------------------------------------------------
;;; The transport
;;; ------------------------------------------------------------------

(defstruct (tcp-transport (:constructor %make-tcp-transport (editor)))
  editor
  (lock (mp:make-lock "clamacs-tcp"))
  (cv (mp:make-condition-variable "clamacs-tcp"))
  (pending nil)             ; the command for the client thread
  (quit nil)
  thread
  ;; The clamiga to talk to.  TOKEN NIL: nothing to authenticate with, so
  ;; nothing to try.
  host
  port
  token
  (stream nil)              ; the authenticated connection, or NIL
  (next-try 0)              ; internal time before which no connect is tried
  (background nil)          ; finding connects on the client thread (a host
                            ; that may not answer: see LOOPBACK-HOST-P)
  (connecting nil)          ; the client thread is to connect, or is at it
  (launched nil)            ; HOST:PORT is a clamiga this editor started
  (log nil)                 ; that clamiga's log file
  (dir nil)                 ; where the launch's files go (the private dir)
  (problem nil))            ; why the last launch failed

(defun tcp-transport-name (tr)
  "What the wire shows as the port: HOST:PORT, never the token."
  (and (tcp-transport-host tr)
       (format nil "~A:~D" (tcp-transport-host tr) (tcp-transport-port tr))))

(defun tcp-transport-configure (tr)
  "The clamiga from the environment: CLAMACS_CLAMIGA (host:port) and
CLAMACS_CLAMIGA_TOKEN.  A malformed address is reported once and ignored."
  (let ((address (or (ext:getenv "CLAMACS_CLAMIGA") *clamiga-default-address*))
        (token (ext:getenv "CLAMACS_CLAMIGA_TOKEN")))
    (multiple-value-bind (host port) (parse-address address)
      (cond ((null host)
             (format *error-output* "clamacs: CLAMACS_CLAMIGA=~A is not host:port; ignored~%" address))
            (t (setf (tcp-transport-host tr) host
                     (tcp-transport-port tr) port))))
    (when (and token (string/= token ""))
      (setf (tcp-transport-token tr) token))))

(defun loopback-host-p (host)
  "Whether HOST is this machine: a connect there is refused or accepted at
once, where one to another machine can wait out a SYN timeout."
  (or (string-equal host "localhost")
      (string= host "::1")
      (and (> (length host) 4) (string= host "127." :end1 4))))

(defun make-tcp-transport (editor &key (configure t) host port token dir
                                       (background :auto))
  "The transport for EDITOR, its client thread running.  CONFIGURE reads
the environment; HOST, PORT and TOKEN override it (the tests).  BACKGROUND
says whether finding clamiga connects on the client thread, so the editor's
task never waits for a machine that does not answer: :AUTO, for a host
that is not this one."
  (let ((tr (%make-tcp-transport editor)))
    (when configure (tcp-transport-configure tr))
    (when host (setf (tcp-transport-host tr) host))
    (when port (setf (tcp-transport-port tr) port))
    (when token (setf (tcp-transport-token tr) token))
    (setf (tcp-transport-background tr)
          (if (eq background :auto)
              (and (tcp-transport-host tr)
                   (not (loopback-host-p (tcp-transport-host tr))))
              background))
    (setf (tcp-transport-dir tr) (or dir (private-dir)))
    (setf (tcp-transport-thread tr)
          (mp:make-thread (lambda () (tcp-client-loop tr))
                          :name "clamacs-tcp"
                          :stack-size (* 64 1024)))
    tr))

(defun tcp-drop-stream (tr)
  "Forget the connection: the next request connects afresh."
  (let ((stream (mp:with-lock-held ((tcp-transport-lock tr))
                  (prog1 (tcp-transport-stream tr)
                    (setf (tcp-transport-stream tr) nil)))))
    (when stream (ignore-errors (close stream)))))

(defun tcp-try-connect (tr &key (seconds 2))
  "An authenticated connection to HOST:PORT, kept in the transport: the
name, or NIL.  No token, or a failure within the last *RETRY-SECONDS*:
nothing is tried.  The lock is not held while connecting: TRANSPORT-SEND
and the client thread take it."
  (multiple-value-bind (name host port token)
      (mp:with-lock-held ((tcp-transport-lock tr))
        (cond ((tcp-transport-stream tr) (values (tcp-transport-name tr)))
              ((or (null (tcp-transport-token tr)) (null (tcp-transport-host tr))) nil)
              ((< (get-internal-real-time) (tcp-transport-next-try tr)) nil)
              (t (values nil (tcp-transport-host tr) (tcp-transport-port tr)
                         (tcp-transport-token tr)))))
    (cond (name name)
          ((null host) nil)
          (t
           (let ((stream (ext.dev.tcp:connect host port token :seconds seconds)))
             (mp:with-lock-held ((tcp-transport-lock tr))
               (cond ((null stream)
                      (setf (tcp-transport-next-try tr)
                            (+ (get-internal-real-time)
                               (* *retry-seconds* internal-time-units-per-second)))
                      nil)
                     ((tcp-transport-stream tr)
                      ;; Another attempt got there first: keep its connection.
                      (ignore-errors (close stream))
                      (tcp-transport-name tr))
                     (t
                      (setf (tcp-transport-stream tr) stream)
                      (tcp-transport-name tr)))))))))

(defun tcp-request-connect (tr)
  "The connection as it stands: its name, or NIL.  With none, and no
failure within *RETRY-SECONDS*, the client thread is asked to connect; the
editor's task never waits for it.  Found, the wire is told (the client
thread posts a WIRE-FIND-PORT), and the next find answers with the name."
  (mp:with-lock-held ((tcp-transport-lock tr))
    (cond ((tcp-transport-stream tr) (tcp-transport-name tr))
          ((or (null (tcp-transport-token tr)) (null (tcp-transport-host tr))) nil)
          ((or (tcp-transport-connecting tr)
               (< (get-internal-real-time) (tcp-transport-next-try tr)))
           nil)
          (t
           (setf (tcp-transport-connecting tr) t)
           (mp:condition-notify (tcp-transport-cv tr))
           nil))))

(defmethod transport-find-port ((tr tcp-transport))
  (if (tcp-transport-background tr)
      (tcp-request-connect tr)
      (tcp-try-connect tr)))

(defmethod transport-own-port ((tr tcp-transport))
  "The editor's own port as clamiga's REPL thread must reach it:
`tcp:HOST:PORT/TOKEN' -- or NIL while the port is not up."
  (let ((hp *host-port*))
    (and hp (ext.dev.tcp:port-name (host-port-host hp) (host-port-number hp) (host-port-token hp)))))

(defmethod transport-send ((tr tcp-transport) port command)
  (declare (ignore port))
  (mp:with-lock-held ((tcp-transport-lock tr))
    (setf (tcp-transport-pending tr) command)
    (mp:condition-notify (tcp-transport-cv tr))))

(defmethod transport-launch-problem ((tr tcp-transport))
  (tcp-transport-problem tr))

(defun tcp-background-connect (tr)
  "The connect a find asked for (TCP-REQUEST-CONNECT), on the client thread.
A clamiga found is announced: the wire looks for it again on the editor's
task, where it now finds the connection."
  (let ((name (ignore-errors (tcp-try-connect tr)))
        (editor (tcp-transport-editor tr)))
    (mp:with-lock-held ((tcp-transport-lock tr))
      (setf (tcp-transport-connecting tr) nil))
    (when name
      (call-in-editor editor
                      (lambda ()
                        (let ((wire (editor-wire editor)))
                          (when (and wire (eq (wire-transport wire) tr))
                            (wire-find-port wire))))
                      :wait nil))))

(defun tcp-client-loop (tr)
  "The client thread: send what is pending, post the reply, connect when a
find asked for it, repeat."
  (let ((lock (tcp-transport-lock tr))
        (cv (tcp-transport-cv tr))
        (editor (tcp-transport-editor tr)))
    (loop
      (multiple-value-bind (job connect)
          (mp:with-lock-held (lock)
            (loop until (or (tcp-transport-quit tr)
                            (tcp-transport-pending tr)
                            (tcp-transport-connecting tr))
                  do (mp:condition-wait cv lock 1))
            (values (prog1 (tcp-transport-pending tr)
                      (setf (tcp-transport-pending tr) nil))
                    (and (tcp-transport-connecting tr)
                         (not (tcp-transport-quit tr)))))
        ;; A job pending at the quit still goes out: it is the REPL-DETACH
        ;; the closing REPL window queued.
        (when (and (tcp-transport-quit tr) (null job))
          (return))
        (when connect
          (tcp-background-connect tr))
        (when job
          (let ((stream (mp:with-lock-held (lock) (tcp-transport-stream tr))))
            (multiple-value-bind (rc text lost)
                (cond ((null stream)
                       (values +rc-fatal+ "no connection to clamiga" t))
                      (t
                       (handler-case
                           (multiple-value-bind (rc text) (ext.dev.tcp:request stream job)
                             (if rc
                                 (values rc text nil)
                                 (values +rc-fatal+ "the connection to clamiga was closed" t)))
                         (error (e)
                           (values +rc-fatal+
                                   (handler-case (princ-to-string e)
                                     (error () "the send failed"))
                                   t)))))
              (when lost (tcp-drop-stream tr))
              (let ((wire (editor-wire editor)))
                (call-in-editor editor
                                (lambda () (wire-reply wire rc text :lost lost))
                                :wait nil)))))))))

;;; ------------------------------------------------------------------
;;; Starting clamiga
;;; ------------------------------------------------------------------

(defun clamiga-binary ()
  "The clamiga to start: CLAMACS_CLAMIGA_BIN, else the binary this editor
runs on; NIL when neither is known."
  (let ((env (ext:getenv "CLAMACS_CLAMIGA_BIN")))
    (if (and env (string/= env ""))
        env
        (let ((f (find-symbol "EXECUTABLE-PATH" "EXT")))
          (and f (fboundp f) (funcall f))))))

(defun setenv (name value)
  "libc's setenv: NAME to VALUE in this process, and so in every child."
  (ffi:with-foreign-string (n name)
    (ffi:with-foreign-string (v value)
      (ffi:call-foreign (ffi:symbol-pointer "setenv" nil) :int32 '(:pointer :pointer :int32)
                        (list n v 1)))))

(defun unsetenv (name)
  (ffi:with-foreign-string (n name)
    (ffi:call-foreign (ffi:symbol-pointer "unsetenv" nil) :int32 '(:pointer) (list n))))

(defun launch-preamble (port-file)
  "The file the started clamiga loads: the port on an ephemeral port with
the token from its environment, the port number to PORT-FILE, then serve
until stopped."
  (concatenate 'string
               "(require \"dev-tcp\")" (string #\Newline)
               "(let ((server (ext.dev.tcp:start :port 0 :token (ext:getenv \"CLAMIGA_TCP_TOKEN\"))))"
               (string #\Newline)
               "  (with-open-file (out " (prin1-to-string port-file)
               " :direction :output :if-exists :supersede)" (string #\Newline)
               "    (format out \"~D~%\" (ext.dev.tcp:port server)))" (string #\Newline)
               "  (ext.dev.tcp:wait server))" (string #\Newline)
               "(format t \"; clamiga stopped~%\")" (string #\Newline)))

(defun write-launch-preamble (path port-file)
  "The preamble to PATH, for the owner alone: a second process LOADs it, so
nobody else may write it in the moments before -- or replace what is there."
  (write-private-file path (launch-preamble port-file)))

(defun shell-quote (text)
  "TEXT in single quotes for sh."
  (with-output-to-string (out)
    (write-char #\' out)
    (loop for c across text
          do (if (char= c #\')
                 (write-string "'\\''" out)
                 (write-char c out)))
    (write-char #\' out)))

(defun log-first-error (log)
  "The first line of LOG that reports an error, or NIL."
  (let ((text (read-file-text log)))
    (and text
         (let ((at (search "ERROR" text)))
           (and at
                (let* ((start (or (position #\Newline text :end at :from-end t) -1))
                       (end (or (position #\Newline text :start at) (length text))))
                  (subseq text (1+ start) end)))))))

(defmethod transport-launch ((tr tcp-transport))
  (let ((bin (clamiga-binary))
        (dir (tcp-transport-dir tr))
        (token (random-hex)))
    (setf (tcp-transport-problem tr) nil)
    (cond ((null bin)
           (setf (tcp-transport-problem tr)
                 "no clamiga binary is known (set CLAMACS_CLAMIGA_BIN)")
           (return-from transport-launch nil))
          ((null dir)
           (setf (tcp-transport-problem tr)
                 "no private directory for its files (set XDG_RUNTIME_DIR, or a TMPDIR of your own)")
           (return-from transport-launch nil))
          ((null token)
           (setf (tcp-transport-problem tr)
                 (format nil "no entropy source for its token (~A)" *entropy-source*))
           (return-from transport-launch nil)))
    (let ((port-file (concatenate 'string dir *launch-port-file-name*))
          (preamble (concatenate 'string dir *launch-preamble-name*))
          (log (concatenate 'string dir *launch-log-name*)))
      (delete-quietly port-file)
      (unless (write-launch-preamble preamble port-file)
        (setf (tcp-transport-problem tr) (format nil "cannot write ~A" preamble))
        (return-from transport-launch nil))
      ;; The token travels in the child's environment.
      (setenv "CLAMIGA_TCP_TOKEN" token)
      (unwind-protect
           (ext:system-command
            (format nil "~A --non-interactive --load ~A </dev/null >~A 2>&1 &"
                    (shell-quote bin) (shell-quote preamble) (shell-quote log)))
        (unsetenv "CLAMIGA_TCP_TOKEN"))
      ;; The port file appears once the preamble has run.  This is the one
      ;; place the editor waits, and it waits before there is anything to
      ;; be responsive about.
      (let ((port nil)
            (deadline (+ (get-internal-real-time)
                         (* *launch-wait-seconds* internal-time-units-per-second))))
        (loop
          (let ((text (read-file-text port-file)))
            (when text
              (setq port (parse-integer text :junk-allowed t))
              (when port (return))))
          (let ((problem (log-first-error log)))
            (when problem
              (setf (tcp-transport-problem tr) (format nil "~A (see ~A)" problem log))
              (return)))
          (when (> (get-internal-real-time) deadline)
            (setf (tcp-transport-problem tr)
                  (format nil "no port within ~D seconds (see ~A)" *launch-wait-seconds* log))
            (return))
          (sleep 0.2))
        (delete-quietly preamble)
        (delete-quietly port-file)
        (when port
          (tcp-drop-stream tr)
          (mp:with-lock-held ((tcp-transport-lock tr))
            (setf (tcp-transport-host tr) "127.0.0.1"
                  (tcp-transport-port tr) port
                  (tcp-transport-token tr) token
                  (tcp-transport-background tr) nil ; this machine now
                  (tcp-transport-launched tr) t
                  (tcp-transport-log tr) log
                  (tcp-transport-next-try tr) 0))
          (and (tcp-try-connect tr :seconds 5) t))))))

(defun stop-launched-clamiga (tr)
  "Ask the clamiga this editor started to stop, over the connection (or a
fresh one); nothing for one the user started."
  (when (tcp-transport-launched tr)
    (let ((stream (or (mp:with-lock-held ((tcp-transport-lock tr))
                        (tcp-transport-stream tr))
                      (ext.dev.tcp:connect (tcp-transport-host tr) (tcp-transport-port tr)
                                           (tcp-transport-token tr) :seconds 2))))
      (when stream
        (ignore-errors
         (setf (ext:socket-stream-timeout stream :input) 5)
         (ext.dev.tcp:request stream "EVAL (ext.dev.tcp:stop)"))
        (mp:with-lock-held ((tcp-transport-lock tr))
          (when (eq stream (tcp-transport-stream tr))
            (setf (tcp-transport-stream tr) nil)))
        (ignore-errors (close stream))))
    (setf (tcp-transport-launched tr) nil)))

(defun stop-tcp-transport (tr)
  "The client thread (a job pending still goes out), the clamiga this
editor started, the connection."
  (mp:with-lock-held ((tcp-transport-lock tr))
    (setf (tcp-transport-quit tr) t)
    (mp:condition-notify (tcp-transport-cv tr)))
  (let ((thread (tcp-transport-thread tr)))
    (when thread
      (wait-for-threads (list thread) 5)))
  (stop-launched-clamiga tr)
  (tcp-drop-stream tr))

;;; ------------------------------------------------------------------
;;; The wire
;;; ------------------------------------------------------------------

(defun start-host-wire (editor)
  "The wire on the TCP transport -- clamiga, found or started -- with the
editor's own image reached through `Talk to the Editor Itself' (the self
transport, made on first use); then the port."
  (let ((tr (make-tcp-transport editor)))
    (make-wire editor tr)
    ;; A clamiga on another machine is looked for at once, on the client
    ;; thread, so it is found before the first command asks for it.
    (when (tcp-transport-background tr)
      (tcp-request-connect tr)))
  (host-port-start editor))

(defun stop-host-wire (editor)
  "The port first (its threads may be parked in CALL-IN-EDITOR; the closed
mailbox has answered them), then the editor's own Lisp, then the TCP
side."
  (when *host-port*
    (handler-case (host-port-stop *host-port*)
      (error (e) (report-error editor e))))
  (let ((wire (editor-wire editor)))
    (when wire
      (let ((self (wire-self wire)))
        (when self
          (self-transport-stop self)))
      (let ((home (wire-home wire)))
        (when (tcp-transport-p home)
          (handler-case (stop-tcp-transport home)
            (error (e) (report-error editor e))))))))

(setf *wire-starter* #'start-host-wire
      *wire-stopper* #'stop-host-wire)
