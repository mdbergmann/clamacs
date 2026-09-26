;;;; test-transport-tcp.lisp -- the wire to a clamiga over TCP
;;;; (lisp/transport-tcp.lisp), against a dev-tcp server in this process.
;;;;
;;;; The "clamiga" is lib/dev-tcp.lisp's port started in the test image --
;;;; the real EXT.DEV commands and the real REPL thread, as test-self.lisp
;;;; uses them -- and the editor is test-transport-host.lisp's port fixture:
;;;; a wired fake with its mailbox pumped by a thread, its own port up, so
;;;; the REPL's way back (clamiga's REPL thread connecting to the editor's
;;;; port with the token REPL-ATTACH handed over) runs end to end over two
;;;; loopback connections.  What is checked: a clamiga found and answered
;;;; through the mailbox; no token, nothing tried; a wrong token, the
;;;; request lost and never answered; a clamiga that went, lost and found
;;;; again; the REPL attached back over the editor's port; the launch of a
;;;; real second clamiga on this binary, and its stop at the editor's exit;
;;;; the wire starting on TCP with the editor's own image on demand.

(in-package :clamacs)

(load (concatenate 'string (cl-user::clamacs-root *load-truename*)
                   "lisp/transport-tcp.lisp"))

;;; The fixtures of two other files: the port fixture and the self REPL's
;;; helpers.  A run of this file alone (CLAMACS_TEST=transport-tcp) loads
;;; them here; the suite has them already.
(unless (fboundp 'start-port-fixture)
  (load (concatenate 'string (cl-user::clamacs-root *load-truename*)
                     "tests/test-transport-host.lisp")))
(unless (fboundp 'repl-idle-p)
  (load (concatenate 'string (cl-user::clamacs-root *load-truename*)
                     "tests/test-self.lisp")))

;;; --- the pieces --------------------------------------------------------------

(defmacro with-clamiga ((server token) &body body)
  "A dev-tcp server in this process, playing clamiga."
  `(let ((,server (ext.dev.tcp:start :port 0 :token ,token)))
     (unwind-protect (progn ,@body)
       (ext.dev.tcp:stop ,server))))

(defun tcp-wait (predicate &optional (seconds *self-wait-seconds*))
  "Until PREDICATE holds (the fixture's pump thread is the editor's task):
true, or NIL on timeout."
  (let ((deadline (+ (get-universal-time) seconds)))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.01))))

(defun on-editor (editor thunk)
  "THUNK on the editor's task -- the pump thread -- and its values: the
wire is one task's, so the test never touches it from its own thread
while a reply is being delivered."
  (call-in-editor editor thunk :wait t))

(defun tcp-fixture-transport (f server token &rest args)
  "The wire of the fixture's editor rehomed on a TCP transport to SERVER."
  (let* ((editor (port-fixture-editor f))
         (tr (apply #'make-tcp-transport editor
                    :configure nil :host "127.0.0.1"
                    :port (and server (ext.dev.tcp:port server))
                    :token token :dir (port-fixture-dir f)
                    args)))
    (make-wire editor tr)
    tr))

(defmacro with-tcp ((f server tr &key (token "clamiga-token")) &body body)
  `(with-port (,f)
     (with-clamiga (,server ,token)
       (let ((,tr (tcp-fixture-transport ,f ,server ,token)))
         (unwind-protect (progn ,@body)
           (stop-tcp-transport ,tr))))))

(defun fixture-doc (f)
  (editor-active-document (port-fixture-editor f)))

(defun last-message-p (doc text)
  (lambda () (equal (fake-last-message doc) text)))

(deftest tcp-address-parsing
  (is-equal (multiple-value-list (parse-address "127.0.0.1:4005")) '("127.0.0.1" 4005))
  (is-equal (multiple-value-list (parse-address "amiga.local:1")) '("amiga.local" 1))
  (is (null (parse-address "127.0.0.1")))
  (is (null (parse-address ":4005")))
  (is (null (parse-address "127.0.0.1:")))
  (is (null (parse-address "127.0.0.1:70000")))
  (is (null (parse-address "127.0.0.1:40x5")))
  (is (null (parse-address nil))))

;;; --- finding and talking --------------------------------------------------------

(deftest tcp-finds-a-clamiga-and-answers-through-the-mailbox
  (with-tcp (f server tr)
    (let* ((editor (port-fixture-editor f))
           (doc (fixture-doc f))
           (wire (editor-wire editor))
           (name (format nil "127.0.0.1:~D" (ext.dev.tcp:port server))))
      (is-equal (on-editor editor (lambda () (wire-find-port wire))) t)
      (is-equal (wire-port-name wire) name)
      (is (wire-connected wire))
      (is-equal (fake-last-message doc) (format nil "clamiga found on ~A" name))
      ;; A request goes out on the client thread, the reply comes back
      ;; through the mailbox.
      (is (on-editor editor (lambda () (wire-request wire doc :ping "PING"))))
      (is (tcp-wait (last-message-p doc (format nil "clamiga answers on ~A" name))))
      (is (on-editor editor (lambda () (wire-request wire doc :version "VERSION"))))
      (is (tcp-wait (lambda () (search "CL-Amiga" (fake-last-message doc)))))
      ;; One request in flight: the second waits for the first's reply.
      (on-editor editor (lambda ()
                          (wire-request wire doc :eval "EVAL (+ 1 2)")
                          (wire-request wire doc :eval "EVAL (* 6 7)")))
      (is (tcp-wait (last-message-p doc "42")))
      (is (null (wire-queue wire)))
      (is (null (wire-inflight wire)))
      ;; The connection is kept.
      (is (tcp-transport-stream tr))
      (is-equal (length (ext.dev.tcp::server-connections server)) 1))))

(deftest tcp-without-a-token-tries-nothing
  (with-port (f)
    (let* ((editor (port-fixture-editor f))
           (tr (tcp-fixture-transport f nil nil :port 1))
           (wire (editor-wire editor)))
      (unwind-protect
           (progn
             (is (null (transport-find-port tr)))
             (is (null (on-editor editor (lambda () (wire-find-port wire)))))
             (is (null (wire-connected wire)))
             ;; A quiet caller just fails.
             (is (null (on-editor editor (lambda () (wire-request wire nil :ping "PING"))))))
        (stop-tcp-transport tr)))))

(deftest tcp-a-wrong-token-is-refused-and-the-request-lost
  (with-tcp (f server tr :token "right")
    (setf (tcp-transport-token tr) "wrong")
    (let* ((editor (port-fixture-editor f))
           (doc (fixture-doc f))
           (wire (editor-wire editor))
           (name (format nil "127.0.0.1:~D" (ext.dev.tcp:port server))))
      ;; Refused: not found.
      (is (null (transport-find-port tr)))
      (is (null (tcp-transport-stream tr)))
      ;; A failed attempt is not repeated at once.
      (is (> (tcp-transport-next-try tr) 0))
      ;; A request that goes out anyway (the wire believed the port was
      ;; there) is lost -- never answered -- and says so.
      (on-editor editor (lambda ()
                          (setf (wire-connected wire) t
                                (wire-port-name wire) name)
                          (wire-request wire doc :ping "PING")))
      (is (tcp-wait (last-message-p doc (format nil "clamiga is not running (port ~A is gone)" name))))
      (is (null (wire-connected wire)))
      (is (null (wire-queue wire)))
      (is-equal (ext.dev.tcp::server-served server) 0))))

(deftest tcp-a-clamiga-that-went-is-lost-and-found-again
  (with-port (f)
    (let* ((editor (port-fixture-editor f))
           (doc (fixture-doc f))
           (server (ext.dev.tcp:start :port 0 :token "tok"))
           (port (ext.dev.tcp:port server))
           (tr (tcp-fixture-transport f server "tok"))
           (wire (editor-wire editor))
           (name (format nil "127.0.0.1:~D" port)))
      (unwind-protect
           (progn
             (on-editor editor (lambda () (wire-request wire doc :ping "PING")))
             (is (tcp-wait (last-message-p doc (format nil "clamiga answers on ~A" name))))
             ;; clamiga goes.
             (ext.dev.tcp:stop server)
             (setq server nil)
             (on-editor editor (lambda () (wire-request wire doc :ping "PING")))
             (is (tcp-wait (last-message-p doc (format nil "clamiga is not running (port ~A is gone)" name))))
             (is (null (wire-connected wire)))
             (is (null (tcp-transport-stream tr)))
             ;; A clamiga on the same port again: found, once the hold-off
             ;; is over, and announced.
             (setq server (ext.dev.tcp:start :port port :token "tok"))
             (setf (tcp-transport-next-try tr) 0)
             (on-editor editor (lambda () (wire-request wire doc :ping "PING")))
             (is (tcp-wait (last-message-p doc (format nil "clamiga answers on ~A" name))))
             (is (wire-connected wire)))
        (stop-tcp-transport tr)
        (when server (ext.dev.tcp:stop server))))))

;;; --- finding on the client thread ------------------------------------------------
;;; A clamiga on another machine can leave a SYN unanswered for seconds: the
;;; editor's task must never wait for it, so finding there only reports the
;;; connection and asks the client thread to make one.

(deftest tcp-loopback-hosts
  (dolist (host '("127.0.0.1" "127.1.2.3" "localhost" "LocalHost" "::1"))
    (is (loopback-host-p host)))
  (dolist (host '("192.168.1.5" "10.0.0.7" "amiga.local" "1270.0.0.1" "::" ""))
    (is (not (loopback-host-p host)))))

(deftest tcp-a-host-that-is-not-this-machine-is-found-in-the-background-by-default
  (with-port (f)
    (let ((editor (port-fixture-editor f)))
      (dolist (entry '(("127.0.0.1" nil) ("localhost" nil)
                       ("amiga.local" t) ("192.168.1.5" t)))
        ;; No token: nothing is tried, whatever the host.
        (let ((tr (make-tcp-transport editor :configure nil :host (first entry) :port 4005
                                             :dir (port-fixture-dir f))))
          (unwind-protect
               (is-equal (tcp-transport-background tr) (second entry))
            (stop-tcp-transport tr)))))))

(deftest tcp-background-find-answers-at-once-and-connects-on-the-client-thread
  (with-port (f)
    (with-clamiga (server "clamiga-token")
      (let* ((editor (port-fixture-editor f))
             (doc (fixture-doc f))
             (tr (tcp-fixture-transport f server "clamiga-token" :background t))
             (wire (editor-wire editor))
             (name (format nil "127.0.0.1:~D" (ext.dev.tcp:port server))))
        (unwind-protect
             (progn
               ;; The caller's thread connects nothing: NIL now, the client
               ;; thread asked.
               (is (null (transport-find-port tr)))
               (is (tcp-wait (lambda () (tcp-transport-stream tr))))
               ;; It told the wire, which found the clamiga on the editor's
               ;; task and announced it, with no second find of ours.
               (is (tcp-wait (lambda () (wire-connected wire))))
               (is-equal (wire-port-name wire) name)
               (is (tcp-wait (last-message-p doc (format nil "clamiga found on ~A" name))))
               (is-equal (transport-find-port tr) name)
               (is (not (tcp-transport-connecting tr)))
               ;; And the connection serves.
               (on-editor editor (lambda () (wire-request wire doc :eval "EVAL (* 6 7)")))
               (is (tcp-wait (last-message-p doc "42"))))
          (stop-tcp-transport tr))))))

(deftest tcp-background-find-that-fails-holds-off-the-next-try
  (with-port (f)
    (with-clamiga (server "right")
      (let ((tr (tcp-fixture-transport f server "wrong" :background t)))
        (unwind-protect
             (progn
               (is (null (transport-find-port tr)))
               (is (tcp-wait (lambda () (not (tcp-transport-connecting tr)))))
               ;; Refused: no connection, and a hold-off (made long here, so
               ;; the check does not depend on how fast this run is).
               (is (null (tcp-transport-stream tr)))
               (is (> (tcp-transport-next-try tr) 0))
               (setf (tcp-transport-next-try tr)
                     (+ (get-internal-real-time) (* 60 internal-time-units-per-second)))
               (is (null (transport-find-port tr)))
               (is (not (tcp-transport-connecting tr)))
               ;; Once the hold-off is over a find asks again.
               (setf (tcp-transport-next-try tr) 0)
               (is (null (transport-find-port tr)))
               (is (tcp-wait (lambda () (not (tcp-transport-connecting tr)))))
               (is (> (tcp-transport-next-try tr) 0))
               (is (null (tcp-transport-stream tr))))
          (stop-tcp-transport tr))))))

;;; --- the REPL's way back ---------------------------------------------------------

(deftest tcp-the-repl-attaches-back-over-the-editors-port
  (with-tcp (f server tr)
    (let* ((editor (port-fixture-editor f))
           (doc (fixture-doc f))
           (wire (editor-wire editor))
           (hp (port-fixture-hp f))
           (name (format nil "127.0.0.1:~D" (ext.dev.tcp:port server))))
      ;; The editor's own port, with its token, is what REPL-ATTACH names.
      (is-equal (transport-own-port tr)
                (format nil "tcp:127.0.0.1:~D/~A" (host-port-number hp) (host-port-token hp)))
      (on-editor editor (lambda () (run-command doc 'clamacs-repl)))
      (is (tcp-wait (lambda () (and (repl-session-attached (repl-session editor))
                                    (repl-idle-p editor)))))
      (let ((repl (repl-doc editor)))
        (is repl)
        (is (search (format nil "REPL attached to ~A" name) (transcript repl)))
        (is (search (format nil "REPL-ATTACH tcp:127.0.0.1:~D/~A DEBUG" (host-port-number hp) (host-port-token hp))
                    (first (wire-sent wire))))
        ;; A form at the prompt: its output streams back over a connection
        ;; clamiga's REPL thread opens to the editor's port on its first
        ;; send (from this process here), then the value and the next
        ;; prompt.
        (on-editor editor (lambda ()
                            (type-text repl "(progn (princ 'hello) (terpri) (+ 1 2))")
                            (type-keys repl "RET")))
        (is (tcp-wait (lambda () (repl-idle-p editor))))
        (is (search (lines "HELLO" "3" "CL-USER> ") (transcript repl)))
        ;; OUTPUT and RESULT came in over the editor's own port, on one
        ;; connection that is kept.
        (is (>= (host-port-served hp) 2))
        (is-equal (length (host-port-connections hp)) 1)
        ;; An error opens the debugger, ABORT returns to the prompt.
        (on-editor editor (lambda ()
                            (type-text repl "(car 1)")
                            (type-keys repl "RET")))
        (is (tcp-wait (lambda () (debugger-active-p editor))))
        (on-editor editor (lambda () (run-command repl 'clamacs-debugger-abort)))
        (is (tcp-wait (lambda () (and (not (debugger-active-p editor)) (repl-idle-p editor)))))
        (is (search "; Aborted" (transcript repl)))
        ;; clamiga goes (its port stops, its connection to the editor's
        ;; port with it): the REPL window learns it from the next request.
        ;; The REPL thread of a real clamiga dies with its process; this
        ;; one is the test image's and is stopped by hand.
        (ext.dev.tcp:stop server)
        (is (tcp-wait (lambda () (null (host-port-connections hp)))))
        (on-editor editor (lambda () (wire-request wire doc :ping "PING")))
        (is (tcp-wait (lambda () (not (repl-session-attached (repl-session editor))))))
        (is (null (wire-connected wire)))
        (ignore-errors (funcall (find-symbol "%REPL-STOP" "EXT.DEV")))
        (is (tcp-wait (lambda () (not (and ext.dev::*repl-thread*
                                           (mp:thread-alive-p ext.dev::*repl-thread*))))))))))

;;; --- starting clamiga ------------------------------------------------------------

(deftest tcp-launch-failure-names-the-reason
  (with-port (f)
    (let* ((editor (port-fixture-editor f))
           (doc (fixture-doc f))
           (tr (tcp-fixture-transport f nil nil :dir nil)))
      (unwind-protect
           (progn
             (setf (tcp-transport-dir tr) nil)
             (on-editor editor (lambda () (run-command doc 'run-lisp)))
             (is (search "Cannot start clamiga: no private directory" (fake-last-message doc)))
             (is (null (tcp-transport-launched tr))))
        (stop-tcp-transport tr)))))

(deftest tcp-launch-preamble-is-private-and-replaces-what-is-there
  ;; A second process LOADs it: it is written for its owner alone, fresh,
  ;; never into a file (or a link) somebody else left at that name.
  (let ((path (temp-file "preamble" "someone else's preamble")))
    (ext:system-command (format nil "chmod 644 '~A'" path))
    (is (not (mode-0600-p path)))       ; the check can fail
    (let ((previous (umask #o022)))
      (unwind-protect
           (is (write-launch-preamble path "/tmp/port-file"))
        (umask previous)))
    (is (mode-0600-p path))
    (is-equal (read-file-text path) (launch-preamble "/tmp/port-file"))
    (delete-file path)))

(deftest tcp-launch-starts-a-clamiga-on-this-binary-and-exit-stops-it
  (cond ((equal (ext:getenv "CLAMIGA_GC_STRESS") "1")
         (format t "  note  the launch of a second clamiga is not run under GC stress (the child would inherit it)~%"))
        ((null (clamiga-binary))
         (format t "  note  no clamiga binary is known here: the launch is not run~%"))
        (t
         (with-port (f)
           (let* ((editor (port-fixture-editor f))
                  (doc (fixture-doc f))
                  (dir (port-fixture-dir f))
                  ;; A background transport, as one to another machine is.
                  (tr (tcp-fixture-transport f nil nil :background t))
                  (wire (editor-wire editor))
                  (log (concatenate 'string dir *launch-log-name*)))
             (unwind-protect
                  (progn
                    (is (null (on-editor editor (lambda () (wire-find-port wire)))))
                    ;; `Start clamiga': the binary this editor runs on, the
                    ;; token in its environment, its port from the file.
                    (on-editor editor (lambda () (run-command doc 'run-lisp)))
                    (is-equal (fake-last-message doc) "Started clamiga")
                    (is (tcp-transport-launched tr))
                    (is-equal (tcp-transport-host tr) "127.0.0.1")
                    ;; It is on this machine now: found without the client thread.
                    (is (not (tcp-transport-background tr)))
                    (is (integerp (tcp-transport-port tr)))
                    (is (tcp-transport-stream tr))
                    (is (wire-connected wire))
                    (is (null (probe-file (concatenate 'string dir *launch-preamble-name*))))
                    (is (null (probe-file (concatenate 'string dir *launch-port-file-name*))))
                    (is (probe-file log))
                    ;; It answers as a clamiga does, in its own process.
                    (on-editor editor (lambda () (wire-request wire doc :version "VERSION")))
                    (is (tcp-wait (lambda () (search "CL-Amiga" (fake-last-message doc)))))
                    (on-editor editor (lambda () (wire-request wire doc :eval "EVAL (ext:executable-path)")))
                    (is (tcp-wait (lambda () (search "clamiga" (fake-last-message doc)))))
                    ;; Its token is not in the editor's environment any more.
                    (is (null (ext:getenv "CLAMIGA_TCP_TOKEN")))
                    ;; The editor's exit stops the clamiga it started.
                    (stop-tcp-transport tr)
                    (is (tcp-wait (lambda () (search "; clamiga stopped" (or (read-file-text log) ""))) 15)))
               (stop-tcp-transport tr)))))))

;;; --- the wire ------------------------------------------------------------------

(deftest host-wire-starts-on-tcp-with-the-editor-itself-on-demand
  (let* ((*host-port* nil)
         (*self-transport* nil)
         (*host-bind* nil)
         (doc (make-fake "(+ 1 2)|"))
         (editor (doc-editor doc))
         (box (make-mailbox))
         (dir (port-temp-dir)))
    (setf (editor-mailbox editor) box)
    (unwind-protect
         (progn
           (make-wire editor (make-tcp-transport editor :configure nil :dir dir))
           (host-port-start editor :dir dir)
           (let ((wire (editor-wire editor)))
             (is (tcp-transport-p (wire-home wire)))
             (is (null (wire-self wire)))
             (is (not (wire-self-p wire)))
             ;; The editor's own image is made on the first switch.
             (run-command doc 'clamacs-connect-self)
             (is (wire-self wire))
             (is (wire-self-p wire))
             (is-equal (fake-last-message doc) "Now talking to the editor itself")
             (is-equal (transport-own-port (wire-transport wire)) *self-own-port*)
             (run-command doc 'clamacs-connect-self)
             (is-equal (fake-last-message doc) "Already talking to the editor itself")
             ;; And back, to a clamiga that is not there.
             (run-command doc 'clamacs-connect-clamiga)
             (is (not (wire-self-p wire)))
             (is-equal (fake-last-message doc)
                       "Now talking to clamiga, which is not running (Start clamiga)")
             (stop-host-wire editor)
             (is (null *host-port*))
             (is (null *self-transport*))))
      (mailbox-close box)
      (setf (editor-mailbox editor) nil))))
