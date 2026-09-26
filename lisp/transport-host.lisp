;;;; transport-host.lisp -- the editor's own port over TCP, and the wire on
;;;; the self transport.
;;;;
;;;; The host has no ARexx.  What the MUI editor's port thread and
;;;; transport-arexx.lisp do there is done here in two parts
;;;; (specs/clamacs-host.md, "The wire" and "Who may connect"):
;;;;
;;;;   - The WIRE's home transport is the TCP one to a separate clamiga
;;;;     (transport-tcp.lisp, phase H5), the self transport
;;;;     (transport-self.lisp) the other side of `Talk to the Editor
;;;;     Itself': the REPL, the debugger, the inspector, introspection and
;;;;     LOAD all work against the editor's own image too.
;;;;   - The editor's OWN PORT (this file) is a TCP listener on 127.0.0.1:
;;;;     what a macro and verify/host/drive.lisp talk to, and what
;;;;     REPL-ATTACH names.  A thread accepts, a thread per connection reads
;;;;     frames, and every verb of port.lisp runs on the editor's task
;;;;     through CALL-IN-EDITOR (the mailbox), as the ARexx port's did on
;;;;     the MUI task.
;;;;
;;;; The protocol, both directions.  <n> counts CHARACTERS and the bytes on
;;;; the wire are UTF-8 (the runtime's socket streams encode every character
;;;; above 127, and the editor's text is 8-bit, so `e-acute' is one
;;;; character and two bytes); WRITE-WIRE-TEXT makes that hold for every
;;;; kind of string:
;;;;
;;;;   request:  "<n>\n" then n characters: the command line  (VERB argument)
;;;;   reply:    "<rc> <n>\n" then n characters: the text
;;;;
;;;; No quoting, no escaping; RC is the ARexx ladder of wire.lisp.  The
;;;; first request on every connection must be `AUTH <token>'; anything
;;;; else -- a wrong token, another verb first, no frame within
;;;; *HOST-AUTH-SECONDS*, a length above +HOST-AUTH-LIMIT+ -- is answered
;;;; `20 <n>\nauthentication required' (nothing of it is run, echoed or
;;;; logged) and the connection is closed.  AUTH is not a verb of port.lisp:
;;;; the listener owns it, so no command can be reached around it.  After
;;;; AUTH a length above *HOST-FRAME-LIMIT* is an error reply, its body is
;;;; read and dropped, and the connection stays.
;;;;
;;;; The token is 128 bits from /dev/urandom, hex, drawn per session; it is
;;;; compared in constant time.  It goes to $XDG_RUNTIME_DIR/clamacs-token
;;;; (or $TMPDIR/ where that is per user), the port beside it in
;;;; clamacs-port, both created with mode 0600 from the start (a umask of
;;;; 077 around the OPEN, never a chmod afterwards) and removed at
;;;; shutdown.  Without a private directory the editor starts WITHOUT its
;;;; port and says so.  The last-started editor owns the two files: a
;;;; second editor on the same machine (the drive's snapshot leg) is given a
;;;; TMPDIR of its own.
;;;;
;;;; `--bind ADDR' (after `--') is parsed by frontend-host.lisp, which
;;;; judges nothing: HOST-PORT-START binds that one address (a Mac driving
;;;; an Amiga clamiga over the LAN needs the clamiga to reach the editor's
;;;; port for the REPL leg), refuses a wildcard or a missing address
;;;; (BIND-REFUSAL) -- no port, a message -- and reports an address no
;;;; interface has as the runtime's error.  The port file still holds the
;;;; number alone; a client on this machine connects to the bound address.
;;;;
;;;; Portable Lisp: EXT sockets, MP threads, one libc call (umask) through
;;;; the FFI.  tests/test-transport-host.lisp drives the port over a real
;;;; loopback socket with the fake editor.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "ffi")
  (require "dev-commands"))

(in-package :clamacs)

;;; frontend-host.lisp defines these with their docstrings; declared here
;;; so this file loads on its own (the tests) in either order.
(defvar *wire-starter* nil)
(defvar *wire-stopper* nil)
(defvar *host-bind* nil)

;;; ------------------------------------------------------------------
;;; Where the token and the port go
;;; ------------------------------------------------------------------

(defun private-dir-from (xdg tmpdir)
  "The directory the two files go to, given $XDG_RUNTIME_DIR and $TMPDIR:
the first when set, else a TMPDIR that is not the shared /tmp; NIL when
there is none.  With a trailing slash."
  (flet ((slashed (dir)
           (if (char= (char dir (1- (length dir))) #\/) dir (concatenate 'string dir "/"))))
    (cond ((and xdg (string/= xdg "")) (slashed xdg))
          ((or (null tmpdir) (string= tmpdir "")) nil)
          ((member (string-right-trim "/" tmpdir) '("/tmp" "/var/tmp") :test #'string=) nil)
          (t (slashed tmpdir)))))

(defun private-dir ()
  (private-dir-from (ext:getenv "XDG_RUNTIME_DIR") (ext:getenv "TMPDIR")))

(defparameter *token-file-name* "clamacs-token")
(defparameter *port-file-name* "clamacs-port")

;;; ------------------------------------------------------------------
;;; The token
;;; ------------------------------------------------------------------

(defparameter *entropy-source* "/dev/urandom"
  "Where the token's bits come from.  The OS's, never Lisp's RANDOM.")

(defun random-hex (&optional (bytes 16))
  "BYTES random bytes from the OS entropy source as lower-case hex, or NIL
when there is no such source (the caller refuses to listen then)."
  (handler-case
      (with-open-file (in *entropy-source* :element-type '(unsigned-byte 8))
        (let ((out (make-string (* 2 bytes)))
              (digits "0123456789abcdef"))
          (dotimes (i bytes out)
            (let ((b (read-byte in)))
              (setf (char out (* 2 i)) (char digits (ash b -4))
                    (char out (1+ (* 2 i))) (char digits (logand b 15)))))))
    (error () nil)))

(defun token-equal-p (a b)
  "Whether the two strings are the same, in time that depends on their
length and not on where they first differ."
  (let ((diff (logxor (length a) (length b)))
        (n (min (length a) (length b))))
    (declare (fixnum diff n))
    (dotimes (i n)
      (setq diff (logior diff (logxor (char-code (char a i)) (char-code (char b i))))))
    (zerop diff)))

;;; ------------------------------------------------------------------
;;; Files nobody else may read
;;; ------------------------------------------------------------------

(defun umask (mode)
  "libc's umask: set MODE, answer the previous mask."
  (logand (ffi:call-foreign (ffi:symbol-pointer "umask" nil) :uint32 '(:uint32) (list mode))
          #o777))

(defun write-private-file (path text)
  "TEXT to a fresh PATH readable by its owner alone: an existing file is
removed first, and the file is created under a umask of 077 so there is no
moment in which it is readable.  True when written."
  (ignore-errors (when (probe-file path) (delete-file path)))
  (let ((previous (umask #o077)))
    (unwind-protect
         (handler-case
             (with-open-file (out path :direction :output :if-exists :error
                                       :external-format :latin-1)
               (write-string text out)
               t)
           (error () nil))
      (umask previous))))

(defun read-private-file (path)
  "The file's contents without a trailing newline, or NIL."
  (let ((text (read-file-text path)))
    (and text (string-right-trim '(#\Newline #\Return) text))))

;;; ------------------------------------------------------------------
;;; Frames
;;; ------------------------------------------------------------------

(defconstant +host-auth-limit+ 1024
  "The longest first frame: an AUTH needs 37 bytes.")

(defparameter *host-frame-limit* (* 16 1024 1024)
  "The longest command after AUTH: an INSERT of a big text.")

(defparameter *host-auth-seconds* 5
  "How long a fresh connection has to send its AUTH.")

(defun read-frame-length (stream limit)
  "The `<n>\\n' header: N, or :CLOSED at end of file, :BAD for anything
that is not a number followed by a newline, :TOO-LONG above LIMIT with N as
the second value (read no further than the newline in any case: the body,
if the caller cares, is still on the wire)."
  (let ((n 0) (digits 0))
    (loop
      (let ((c (read-char stream nil nil)))
        (cond ((null c) (return :closed))
              ((char= c #\Newline)
               (cond ((zerop digits) (return :bad))
                     ((> n limit) (return (values :too-long n)))
                     (t (return n))))
              ((and (char<= #\0 c #\9) (< digits 10))
               (setq n (+ (* n 10) (- (char-code c) (char-code #\0))))
               (incf digits))
              (t (return :bad)))))))

(defun read-frame-body (stream n)
  "N characters: the text, or :CLOSED when fewer came."
  (let* ((text (make-string n))
         (got (read-sequence text stream)))
    (if (< got n) :closed text)))

(defun read-frame (stream limit)
  "A frame: its text, or one of READ-FRAME-LENGTH's keywords."
  (let ((n (read-frame-length stream limit)))
    (if (integerp n)
        (read-frame-body stream n)
        n)))

(defun ascii-text-p (text)
  (dotimes (i (length text) t)
    (when (>= (char-code (char text i)) 128)
      (return nil))))

(defun write-wire-text (stream text)
  "TEXT to STREAM as UTF-8, whatever kind of string it is.  WRITE-STRING of
an 8-bit string puts each character out as ONE byte, WRITE-CHAR (and a wide
string) encodes it, and the reader decodes: so a character above 127 goes
out one character at a time, and the frame's <n> stays a count of
characters."
  (if (ascii-text-p text)
      (write-string text stream)
      (dotimes (i (length text))
        (write-char (char text i) stream))))

(defun write-frame (stream rc text)
  "A reply: `<rc> <n>' and the text."
  (format stream "~D ~D~%" rc (length text))
  (write-wire-text stream text)
  (finish-output stream))

(defun write-request (stream line)
  "A request: `<n>' and the command line."
  (format stream "~D~%" (length line))
  (write-wire-text stream line)
  (finish-output stream))

(defun read-reply (stream)
  "A reply frame: (values RC TEXT), or NIL when the connection is gone or
the header is not a reply's."
  (let ((rc 0) (n 0) (rc-digits 0) (n-digits 0) (in-rc t))
    (loop
      (let ((c (read-char stream nil nil)))
        (cond ((null c) (return nil))
              ((char= c #\Newline) (return))
              ((char= c #\Space)
               (if in-rc (setq in-rc nil) (return nil)))
              ((char<= #\0 c #\9)
               (if in-rc
                   (progn (setq rc (+ (* rc 10) (digit-char-p c))) (incf rc-digits))
                   (progn (setq n (+ (* n 10) (digit-char-p c))) (incf n-digits))))
              (t (return nil)))))
    (when (and (plusp rc-digits) (plusp n-digits))
      (let* ((text (make-string n))
             (got (read-sequence text stream)))
        (and (= got n) (values rc text))))))

;;; ------------------------------------------------------------------
;;; The port
;;; ------------------------------------------------------------------

(defstruct (host-port (:constructor %make-host-port (editor)))
  editor
  listener
  (number 0)                ; the port bound
  (host "127.0.0.1")        ; the address bound
  token
  dir                       ; where the two files are, or NIL
  (quit nil)
  thread                    ; the listener's
  (lock (mp:make-lock "clamacs-port"))
  (connections '())         ; the open connections' streams
  (workers '())             ; their threads
  (served 0)                ; frames answered after AUTH, for the tests
  ;; The limits, copied from the specials when the port starts: a
  ;; dynamic binding is the starting thread's alone.
  (auth-seconds *host-auth-seconds*)
  (frame-limit *host-frame-limit*))

(defvar *host-port* nil
  "The running port, or NIL.")

(defun host-port-address (hp)
  (format nil "~A:~D" (host-port-host hp) (host-port-number hp)))

(defun refuse (stream)
  "The one answer an unauthenticated connection gets, then the end of it."
  (ignore-errors (write-frame stream +rc-fatal+ "authentication required"))
  (ignore-errors (close stream)))

(defun auth-frame-p (hp frame)
  "Whether FRAME is `AUTH <token>' with this port's token."
  (and (stringp frame)
       (>= (length frame) 5)
       (string-equal frame "AUTH " :end1 5)
       (token-equal-p (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq frame 5))
                      (host-port-token hp))))

(defun port-verb-of (line)
  "The verb at the start of LINE, upcased."
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (end (or (position-if (lambda (c) (member c '(#\Space #\Tab #\Newline #\Return))) trimmed)
                  (length trimmed))))
    (string-upcase (subseq trimmed 0 end))))

(defun serve-frame (hp frame)
  "The command FRAME run on the editor's task: (values RC TEXT).  A raw
verb keeps its argument as it came, as EXT.DEV hands it over."
  (let ((editor (host-port-editor hp))
        (verb (port-verb-of frame)))
    (call-in-editor editor
                    (if (member verb *raw-port-verbs* :test #'string=)
                        (lambda () (port-raw-command editor frame))
                        (lambda () (port-command editor frame))))))

(defparameter *host-idle-seconds* 1
  "The read timeout between frames: how soon a connection thread notices
a stop.")

(defparameter *host-body-seconds* 30
  "How long a frame's body may take once its header is in.")

(defun skip-frame-body (hp stream n)
  "Read and drop N characters, a chunk at a time under the long timeout:
true when they were all there, NIL when the client went or stalled or the
port is stopping."
  (let ((chunk (make-string 4096)))
    (setf (ext:socket-stream-timeout stream :input) *host-body-seconds*)
    (unwind-protect
         (handler-case
             (loop
               (when (or (<= n 0) (host-port-quit hp))
                 (return (<= n 0)))
               (let ((got (read-sequence chunk stream :end (min n (length chunk)))))
                 (when (zerop got)
                   (return nil))
                 (decf n got)))
           (error () nil))
      (setf (ext:socket-stream-timeout stream :input) *host-idle-seconds*))))

(defun wait-for-frame (hp stream limit)
  "Wait for the next frame's header with the socket's short read timeout,
going round on each timeout while the port is up, then read the body under
the long one: the frame, or a keyword of READ-FRAME-LENGTH.  A frame above
LIMIT has its body dropped first, so that what follows it on the wire is
the next header and not the tail of this one; :CLOSED when it cannot be."
  (loop
    (when (host-port-quit hp)
      (return :closed))
    (multiple-value-bind (n length)
        (handler-case (read-frame-length stream limit)
          (ext:socket-timeout () :again)
          (error () :closed))
      (cond ((eq n :again))
            ((eq n :too-long)
             (return (if (skip-frame-body hp stream length) :too-long :closed)))
            ((not (integerp n)) (return n))
            (t
             (setf (ext:socket-stream-timeout stream :input) *host-body-seconds*)
             (let ((body (handler-case (read-frame-body stream n)
                           (error () :closed))))
               (setf (ext:socket-stream-timeout stream :input) *host-idle-seconds*)
               (return body)))))))

(defun connection-loop (hp stream)
  "One connection: the AUTH gate, then frames until the client goes."
  (unwind-protect
       (progn
         (setf (ext:socket-stream-timeout stream :input) (host-port-auth-seconds hp))
         (let ((first (handler-case (read-frame stream +host-auth-limit+)
                        (error () :closed))))
           (cond ((not (auth-frame-p hp first))
                  (refuse stream)
                  (return-from connection-loop nil))
                 (t (write-frame stream +rc-ok+ "OK"))))
         ;; Authenticated.  A short timeout, so the loop notices a stop.
         (setf (ext:socket-stream-timeout stream :input) *host-idle-seconds*)
         (loop
           (let ((frame (wait-for-frame hp stream (host-port-frame-limit hp))))
             (cond ((stringp frame)
                    (multiple-value-bind (rc text) (serve-frame hp frame)
                      (incf (host-port-served hp))
                      (handler-case (write-frame stream (or rc +rc-fatal+) (or text ""))
                        (error () (return)))))
                   ((eq frame :too-long)
                    (handler-case (write-frame stream +rc-fatal+ "ERROR: the command is too long")
                      (error () (return))))
                   (t (return))))))
    (ignore-errors (close stream))
    (mp:with-lock-held ((host-port-lock hp))
      (setf (host-port-connections hp) (remove stream (host-port-connections hp))))))

(defun listener-loop (hp)
  "Accept until told to stop; a connection gets a thread of its own."
  (loop
    (let ((stream (handler-case (ext:socket-accept (host-port-listener hp))
                    (error () nil))))
      (when (host-port-quit hp)
        (when stream (ignore-errors (close stream)))
        (return))
      (cond ((null stream) (sleep 0.05))
            (t
             (mp:with-lock-held ((host-port-lock hp))
               (push stream (host-port-connections hp))
               (push (mp:make-thread (lambda () (connection-loop hp stream))
                                     :name "clamacs-connection"
                                     :stack-size (* 64 1024))
                     (host-port-workers hp))))))))

(defun bind-refusal (addr)
  "Why the port will not listen where `--bind ADDR' says, as a message, or
NIL for an address worth trying.  ADDR is \"\" when the option came
without an address.  A wildcard is `*' or an address of nothing but zeros
however it is spelled: the runtime's parser takes leading zeros, so
`00.0.0.0' and `0.0.0.000' are INADDR_ANY as much as `0.0.0.0' and `::'."
  (cond ((string= addr "")
         "--bind needs an address")
        ((or (string= addr "*")
             (every (lambda (c) (find c "0.:")) addr))
         (format nil "--bind ~A: a wildcard address is not allowed" addr))
        (t nil)))

(defun host-port-start (editor &key (number (or (parse-integer (or (ext:getenv "CLAMACS_PORT") "")
                                                                :junk-allowed t)
                                                 0))
                                    (dir (private-dir))
                                    (token (random-hex))
                                    (host (or *host-bind* "127.0.0.1")))
  "Listen on HOST (127.0.0.1, or the one address `--bind' named) port
NUMBER (0: one the OS picks), write the token and the port to DIR, and
serve.  Signals when there is no token, no directory or no port, or when
`--bind' named a wildcard, nothing, or an address this machine does not
have."
  (let ((why (and *host-bind* (bind-refusal *host-bind*))))
    (when why
      (error "~A; not started" why)))
  (unless token
    (error "no entropy source for the port's token (~A): not started" *entropy-source*))
  (unless dir
    (error "no private directory for the port's token (set XDG_RUNTIME_DIR, or a TMPDIR of your own): not started"))
  (let ((hp (%make-host-port editor)))
    (setf (host-port-token hp) token
          (host-port-dir hp) dir
          (host-port-host hp) host
          (host-port-listener hp)
          (handler-case (ext:socket-listen number host)
            (error (e)
              (error "cannot listen on ~A: ~A; not started" host e)))
          (host-port-number hp) (ext:socket-local-port (host-port-listener hp)))
    (unless (and (write-private-file (concatenate 'string dir *token-file-name*)
                                     (format nil "~A~%" token))
                 (write-private-file (concatenate 'string dir *port-file-name*)
                                     (format nil "~D~%" (host-port-number hp))))
      (ignore-errors (close (host-port-listener hp)))
      (host-port-remove-files hp)
      (error "cannot write the port's files under ~A: not started" dir))
    (setf (host-port-thread hp)
          (mp:make-thread (lambda () (listener-loop hp))
                          :name "clamacs-port"
                          :stack-size (* 64 1024)))
    (setf *host-port* hp)
    hp))

(defun host-port-remove-files (hp)
  "The two files, when they are still this port's."
  (let ((dir (host-port-dir hp)))
    (when dir
      (let ((token-file (concatenate 'string dir *token-file-name*))
            (port-file (concatenate 'string dir *port-file-name*)))
        (when (equal (read-private-file token-file) (host-port-token hp))
          (ignore-errors (delete-file token-file))
          (ignore-errors (delete-file port-file)))))))

(defun wait-for-threads (threads seconds)
  (let ((deadline (+ (get-internal-real-time) (* seconds internal-time-units-per-second))))
    (loop while (and (some #'mp:thread-alive-p threads)
                     (< (get-internal-real-time) deadline))
          do (sleep 0.05))))

(defun host-port-stop (hp)
  "Stop accepting, end every connection, remove the files."
  (setf (host-port-quit hp) t)
  ;; A connection of our own ends the accept the listener thread is in.
  (ignore-errors (close (ext:open-tcp-stream (host-port-host hp) (host-port-number hp) 1)))
  (when (host-port-thread hp)
    (wait-for-threads (list (host-port-thread hp)) 3))
  (ignore-errors (close (host-port-listener hp)))
  ;; The workers see the flag within their read timeout.
  (wait-for-threads (host-port-workers hp) 3)
  (dolist (stream (mp:with-lock-held ((host-port-lock hp))
                    (prog1 (host-port-connections hp)
                      (setf (host-port-connections hp) '()))))
    (ignore-errors (close stream)))
  (host-port-remove-files hp)
  (when (eq *host-port* hp)
    (setf *host-port* nil))
  t)

;;; ------------------------------------------------------------------
;;; The client side, for the drive and the tests
;;; ------------------------------------------------------------------

(defun host-port-connect (dir &key (seconds 5))
  "A connection to the editor whose files are under DIR, authenticated:
the stream, or NIL with a reason as the second value."
  (let ((port (read-private-file (concatenate 'string dir *port-file-name*)))
        (token (read-private-file (concatenate 'string dir *token-file-name*))))
    (cond ((or (null port) (null token))
           (values nil "no port or token file"))
          (t
           (let ((stream (handler-case (ext:open-tcp-stream "127.0.0.1" (parse-integer port) seconds)
                           (error (e) (return-from host-port-connect
                                        (values nil (princ-to-string e)))))))
             (write-request stream (concatenate 'string "AUTH " token))
             (multiple-value-bind (rc text) (read-reply stream)
               (cond ((and rc (= rc +rc-ok+)) stream)
                     (t (ignore-errors (close stream))
                        (values nil (or text "no answer to AUTH"))))))))))

(defun host-port-request (stream line)
  "LINE to the editor over STREAM: (values RC TEXT), or NIL when the
connection is gone."
  (write-request stream line)
  (read-reply stream))

;;; ------------------------------------------------------------------
;;; The editor's own Lisp
;;; ------------------------------------------------------------------

(defun make-host-self-transport (editor)
  "`clamacs-connect-self': the wire to the editor's own Lisp reaches the
editor's task through the same mailbox as everything else.  The wire's
home is transport-tcp.lisp's, which also starts and stops the port."
  (make-self-transport editor
                       (lambda (thunk wait)
                         (call-in-editor editor thunk :wait wait))))

(setf *self-transport-maker* #'make-host-self-transport)
