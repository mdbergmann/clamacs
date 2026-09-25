;;;; test-transport-host.lisp -- the editor's own port over TCP
;;;; (lisp/transport-host.lisp), on a real loopback socket.
;;;;
;;;; The fake editor stands behind the port, with a mailbox a pump thread
;;;; drains as the host editor's loop would, so a verb arriving on a
;;;; connection thread runs on "the editor's task" and its answer goes back
;;;; over the socket.  What is checked is "Who may connect" of
;;;; specs/clamacs-host.md: a connection that skips AUTH, one with a wrong
;;;; token, an oversized first frame and a silent one are refused and
;;;; closed, a side effect they asked for did not happen, and a right token
;;;; is served; the token and port files exist while the port is up, are
;;;; mode 0600 (`find -perm' through EXT:SYSTEM-COMMAND: the runtime has no
;;;; stat; verify/host/run-drive.sh checks it again on the real editor) and
;;;; are gone after it stops.  The frame's encoding is checked byte by byte
;;;; with READ-BYTE / WRITE-BYTE.

(in-package :clamacs)

(load (concatenate 'string (cl-user::clamacs-root *load-truename*)
                   "lisp/transport-host.lisp"))

;;; --- the editor's task, played by a pump thread ----------------------

(defstruct (port-fixture (:constructor %make-port-fixture ()))
  editor box hp dir (stop nil) thread)

(defun port-temp-dir ()
  "A directory of this test's own for the two files, with a trailing slash."
  (let ((dir (concatenate 'string (temp-path "port") "/")))
    (ensure-directories-exist dir)
    (dolist (name (list *token-file-name* *port-file-name*))
      (let ((path (concatenate 'string dir name)))
        (when (probe-file path) (delete-file path))))
    dir))

(defun start-port-fixture (&rest start-args)
  "A wired fake editor showing the sample, its mailbox pumped, its port
up under a temporary directory."
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let* ((f (%make-port-fixture))
           (editor (doc-editor doc))
           (box (make-mailbox)))
      (setf (editor-mailbox editor) box
            (port-fixture-editor f) editor
            (port-fixture-box f) box
            (port-fixture-dir f) (port-temp-dir))
      (setf (port-fixture-thread f)
            (mp:make-thread (lambda ()
                              (loop until (port-fixture-stop f)
                                    do (mailbox-drain box)
                                       (sleep 0.005)))
                            :name "test-port-pump"))
      (setf (port-fixture-hp f)
            (apply #'host-port-start editor :dir (port-fixture-dir f) start-args))
      f)))

(defun stop-port-fixture (f)
  (when (port-fixture-hp f)
    (host-port-stop (port-fixture-hp f)))
  (mailbox-close (port-fixture-box f))
  (setf (port-fixture-stop f) t)
  (wait-for-threads (list (port-fixture-thread f)) 3)
  (setf (editor-mailbox (port-fixture-editor f)) nil))

(defmacro with-port ((f &rest start-args) &body body)
  `(let ((,f (start-port-fixture ,@start-args)))
     (unwind-protect (progn ,@body)
       (stop-port-fixture ,f))))

(defun raw-connect (f)
  "A connection to the fixture's port that has said nothing yet."
  (ext:open-tcp-stream "127.0.0.1" (host-port-number (port-fixture-hp f)) 5))

(defun closed-after-p (stream)
  "Whether the far side closed STREAM: a read answers end of file, and
within a bounded time."
  (setf (ext:socket-stream-timeout stream :input) 5)
  (handler-case (null (read-char stream nil nil))
    (error () nil)))

(defun request (stream line)
  "(rc text) of LINE, as a list, or NIL."
  (multiple-value-bind (rc text) (host-port-request stream line)
    (and rc (list rc text))))

(defun mode-0600-p (path)
  "Whether PATH is a file of exactly mode 0600.  `find -perm 600' takes the
same octal spelling on the BSDs and on GNU, where `stat' does not."
  (zerop (ext:system-command
          (format nil "test -n \"$(find '~A' -perm 600)\"" path))))

(defun read-reply-header (stream)
  "The `<rc> <n>' line of a reply, read as characters: (values RC N)."
  (let* ((line (with-output-to-string (out)
                 (loop for c = (read-char stream)
                       until (char= c #\Newline)
                       do (write-char c out))))
         (blank (position #\Space line)))
    (values (parse-integer line :end blank)
            (parse-integer line :start (1+ blank)))))

(defun read-utf8-bytes (stream chars)
  "The bytes of the next CHARS UTF-8 characters, read with READ-BYTE so that
no decoding hides what is on the wire."
  (let ((bytes '()))
    (dotimes (i chars (nreverse bytes))
      (let* ((b (read-byte stream))
             (extra (cond ((< b #x80) 0)
                          ((= (logand b #xE0) #xC0) 1)
                          ((= (logand b #xF0) #xE0) 2)
                          (t 3))))
        (push b bytes)
        (dotimes (j extra)
          (push (read-byte stream) bytes))))))

(defun utf8-octets (text)
  "TEXT's UTF-8 encoding as a list of bytes (code points up to #xFFFF)."
  (loop for c across text
        for code = (char-code c)
        append (cond ((< code #x80)
                      (list code))
                     ((< code #x800)
                      (list (logior #xC0 (ash code -6))
                            (logior #x80 (logand code #x3F))))
                     (t
                      (list (logior #xE0 (ash code -12))
                            (logior #x80 (logand (ash code -6) #x3F))
                            (logior #x80 (logand code #x3F)))))))

;;; A variable only a served EVAL sets: whether a refused connection's
;;; command ran.
(defvar cl-user::*port-test-probe* nil)

(defun probe-form ()
  "The EVAL that sets it."
  "EVAL (setq cl-user::*port-test-probe* :ran)")

;;; --- the pieces --------------------------------------------------------

(deftest port-token-is-128-random-bits-in-hex
  (let ((a (random-hex)) (b (random-hex)))
    (is-equal (length a) 32)
    (is (every (lambda (c) (find c "0123456789abcdef")) a))
    (is (string/= a b)))
  ;; No entropy source: no token, and the port refuses to start.
  (let ((*entropy-source* "/no/such/device"))
    (is (null (random-hex)))
    (let ((editor (make-fake-editor)))
      (is (handler-case (progn (host-port-start editor :dir "/tmp/x/") nil)
            (error (e) (search "no entropy source" (princ-to-string e))))))))

(deftest port-token-compare-is-constant-time-and-exact
  (is (token-equal-p "abc" "abc"))
  (is (not (token-equal-p "abc" "abd")))
  (is (not (token-equal-p "abc" "ab")))
  (is (not (token-equal-p "" "a")))
  (is (token-equal-p "" "")))

(deftest port-private-dir-prefers-xdg-and-refuses-the-shared-tmp
  (is-equal (private-dir-from "/run/user/1000" "/tmp") "/run/user/1000/")
  (is-equal (private-dir-from "/run/user/1000/" nil) "/run/user/1000/")
  (is-equal (private-dir-from nil "/var/folders/xy/T/") "/var/folders/xy/T/")
  (is-equal (private-dir-from nil "/var/folders/xy/T") "/var/folders/xy/T/")
  (is-equal (private-dir-from "" "/tmp") nil)
  (is-equal (private-dir-from nil "/tmp/") nil)
  (is-equal (private-dir-from nil "/var/tmp") nil)
  (is-equal (private-dir-from nil nil) nil)
  (is-equal (private-dir-from nil "") nil))

(deftest port-private-file-is-written-fresh
  (let ((path (temp-file "private" "old contents, old mode")))
    (is (write-private-file path "secret"))
    (is-equal (read-private-file path) "secret")
    ;; The umask is put back.
    (let ((before (umask #o022)))
      (umask before)
      (is-equal before #o022))
    (delete-file path)))

(deftest port-private-files-are-mode-0600
  ;; A file that exists with a looser mode is replaced, not reused.
  (let ((path (temp-file "private-mode" "old contents, old mode")))
    (ext:system-command (format nil "chmod 644 '~A'" path))
    (is (not (mode-0600-p path)))       ; the check can fail
    (is (write-private-file path "secret"))
    (is (mode-0600-p path))
    (delete-file path))
  ;; The two files a port creates, under a permissive umask of the editor's.
  (let ((previous (umask #o022)))
    (unwind-protect
         (with-port (f)
           (dolist (name (list *token-file-name* *port-file-name*))
             (is (mode-0600-p (concatenate 'string (port-fixture-dir f) name)))))
      (umask previous))))

(deftest port-frames-round-trip
  (let ((out (make-string-output-stream)))
    (write-frame out 10 (lines "two" "lines"))
    (write-frame out 0 "")
    (let ((in (make-string-input-stream (get-output-stream-string out))))
      (is-equal (multiple-value-list (read-reply in)) (list 10 (lines "two" "lines")))
      (is-equal (multiple-value-list (read-reply in)) '(0 ""))
      (is (null (read-reply in)))))
  (is-equal (read-frame (make-string-input-stream (format nil "5~%hellorest")) 100) "hello")
  (is-equal (read-frame (make-string-input-stream (format nil "5~%hel")) 100) :closed)
  (is-equal (read-frame (make-string-input-stream (format nil "2000~%")) 1024) :too-long)
  (is-equal (read-frame (make-string-input-stream (format nil "x~%")) 1024) :bad)
  (is-equal (read-frame (make-string-input-stream (format nil "~%")) 1024) :bad)
  (is-equal (read-frame (make-string-input-stream "") 1024) :closed)
  (is-equal (read-frame (make-string-input-stream (format nil "0~%")) 1024) "")
  ;; A malformed reply header is no reply.
  (is (null (read-reply (make-string-input-stream (format nil "0~%")))))
  (is (null (read-reply (make-string-input-stream (format nil "a 1~%x"))))))

;;; --- the port, over the socket ----------------------------------------------

(deftest port-serves-a-right-token
  (with-port (f)
    (let ((dir (port-fixture-dir f)))
      ;; The two files are there, the port file names the port, the token
      ;; file the token.
      (is-equal (read-private-file (concatenate 'string dir *port-file-name*))
                (princ-to-string (host-port-number (port-fixture-hp f))))
      (is-equal (read-private-file (concatenate 'string dir *token-file-name*))
                (host-port-token (port-fixture-hp f)))
      (let ((stream (host-port-connect dir)))
        (is stream)
        (unwind-protect
             (progn
               (is-equal (request stream "GETFILE") '(0 "Clamacs:verify/realamiga/sample.lisp"))
               (is-equal (request stream "GOTOLINE 3") '(0 ""))
               (is-equal (request stream "TE GETCURSOR LINE") '(0 "2"))
               ;; A reply with newlines inside: the text's own.
               (is-equal (request stream "TE GETLINE") (list 0 (format nil "(defun frobnicate (x)~%")))
               ;; A form is evaluated on the editor's task, side effect and all.
               (setf cl-user::*port-test-probe* nil)
               (is-equal (request stream (probe-form)) '(0 ":RAN"))
               (is-equal cl-user::*port-test-probe* :ran)
               ;; The ARexx ladder comes back as rc.
               (let ((answer (request stream "NOSUCHVERB")))
                 (is-equal (first answer) 20)
                 (is (search "unknown command" (second answer))))
               (is-equal (first (request stream "GOTOLINE 0")) 10)
               ;; A raw verb goes through PORT-RAW-COMMAND: OUTPUT with no
               ;; REPL window is refused by the verb, not lost.
               (is (integerp (first (request stream "OUTPUT   two blanks kept"))))
               ;; An empty command is fine.
               (is-equal (request stream "") '(0 ""))
               (is (>= (host-port-served (port-fixture-hp f)) 8)))
          (close stream))))))

(deftest port-serves-two-connections-at-once
  (with-port (f)
    (let ((a (host-port-connect (port-fixture-dir f)))
          (b (host-port-connect (port-fixture-dir f))))
      (is (and a b))
      (unwind-protect
           (progn
             (is-equal (request a "GOTOLINE 2") '(0 ""))
             (is-equal (request b "TE GETCURSOR LINE") '(0 "1"))
             (is-equal (request a "GETNAME") '(0 "sample.lisp")))
        (close a) (close b)))))

(deftest port-frames-count-characters-and-carry-utf-8
  ;; <n> is a count of CHARACTERS and the bytes are UTF-8: the editor's text
  ;; is 8-bit, so a character of 128..255 is one in <n> and two on the wire,
  ;; in both directions and whatever kind of string carries it.
  (with-port (f)
    (let ((text (coerce (list (code-char 233) #\x (code-char 252) (code-char 223)) 'string))
          (e-acute (string (code-char 233)))
          (stream (host-port-connect (port-fixture-dir f))))
      (is stream)
      (unwind-protect
           (progn
             (is-equal (request stream "GOTOLINE 3") '(0 ""))
             ;; A request from this runtime: the characters come in whole.
             (is-equal (request stream (concatenate 'string "INSERT " text)) '(0 ""))
             ;; One from a client of another kind: the header counts the 8
             ;; characters, the bytes after it are UTF-8 (C3 A9 is one).
             (format stream "~D~%" 8)
             (write-string "INSERT " stream)
             (write-byte #xC3 stream)
             (write-byte #xA9 stream)
             (finish-output stream)
             (is-equal (multiple-value-list (read-reply stream)) '(0 ""))
             (let ((line (second (request stream "TE GETLINE"))))
               (is (search (concatenate 'string text e-acute) line))
               ;; The reply, byte by byte: <n> is the line's length in
               ;; characters, the body its UTF-8.
               (write-request stream "TE GETLINE")
               (multiple-value-bind (rc n) (read-reply-header stream)
                 (is-equal rc 0)
                 (is-equal n (length line))
                 (is (> (length (utf8-octets line)) n))
                 (is-equal (read-utf8-bytes stream n) (utf8-octets line))))
             ;; Nothing is left over on the wire: the next frame is in step.
             (is-equal (request stream "GETNAME") '(0 "sample.lisp")))
        (close stream)))))

(deftest port-refuses-a-connection-that-skips-auth
  (with-port (f)
    (setf cl-user::*port-test-probe* nil)
    (let ((stream (raw-connect f)))
      (write-request stream (probe-form))
      (is-equal (multiple-value-list (read-reply stream)) '(20 "authentication required"))
      (is (closed-after-p stream))
      (close stream))
    (sleep 0.1)
    (is (null cl-user::*port-test-probe*))
    (is-equal (host-port-served (port-fixture-hp f)) 0)
    ;; The port is still up for a right token afterwards.
    (let ((stream (host-port-connect (port-fixture-dir f))))
      (is stream)
      (is-equal (request stream "GETNAME") '(0 "sample.lisp"))
      (close stream))))

(deftest port-refuses-a-wrong-token
  (with-port (f)
    (dolist (bad (list "AUTH 00000000000000000000000000000000"
                       "AUTH "
                       "AUTH"
                       (concatenate 'string "AUTH " (host-port-token (port-fixture-hp f)) "0")
                       (concatenate 'string "auth " (subseq (host-port-token (port-fixture-hp f)) 1))
                       ""))
      (let ((stream (raw-connect f)))
        (write-request stream bad)
        (is-equal (multiple-value-list (read-reply stream)) '(20 "authentication required"))
        (is (closed-after-p stream))
        (close stream)))
    ;; The verb is case-insensitive and the token may carry a newline.
    (let ((stream (raw-connect f)))
      (write-request stream (format nil "auth ~A~%" (host-port-token (port-fixture-hp f))))
      (is-equal (multiple-value-list (read-reply stream)) '(0 "OK"))
      (is-equal (request stream "GETNAME") '(0 "sample.lisp"))
      (close stream))))

(deftest port-refuses-an-oversized-or-malformed-first-frame
  (with-port (f)
    (setf cl-user::*port-test-probe* nil)
    ;; Above the AUTH limit: refused on the header alone, the body unread.
    (let ((stream (raw-connect f)))
      (format stream "~D~%" 2000)
      (finish-output stream)
      (is-equal (multiple-value-list (read-reply stream)) '(20 "authentication required"))
      (is (closed-after-p stream))
      (close stream))
    ;; Not a frame at all.
    (let ((stream (raw-connect f)))
      (write-string (format nil "EVAL (setq cl-user::*port-test-probe* :ran)~%") stream)
      (finish-output stream)
      (is-equal (multiple-value-list (read-reply stream)) '(20 "authentication required"))
      (is (closed-after-p stream))
      (close stream))
    (sleep 0.1)
    (is (null cl-user::*port-test-probe*))
    (is-equal (host-port-served (port-fixture-hp f)) 0)))

(deftest port-refuses-a-silent-connection
  (let ((*host-auth-seconds* 1))
    (with-port (f)
      (let ((stream (raw-connect f))
            (start (get-internal-real-time)))
        ;; Nothing sent: the refusal comes on its own, after the timeout.
        (is-equal (multiple-value-list (read-reply stream)) '(20 "authentication required"))
        (is (>= (- (get-internal-real-time) start) (* 0.9 internal-time-units-per-second)))
        (is (closed-after-p stream))
        (close stream)))))

(deftest port-after-auth-a-too-long-command-is-an-error-not-the-end
  (let ((*host-frame-limit* 64))
    (with-port (f)
      (let ((stream (host-port-connect (port-fixture-dir f))))
        (is stream)
        ;; A real body, 100 characters, that STARTS like a frame ("5", a
        ;; newline, a word): were it left on the wire it would be read as
        ;; the next request and answered.
        (write-request stream (format nil "5~%hello~A" (make-string 100 :initial-element #\x)))
        (is-equal (multiple-value-list (read-reply stream)) '(20 "ERROR: the command is too long"))
        ;; The body was dropped, so the next reply is the next request's.
        (is-equal (request stream "GETNAME") '(0 "sample.lisp"))
        (is-equal (host-port-served (port-fixture-hp f)) 1)
        ;; Bodies of more than one chunk (4096) are dropped whole too.
        (write-request stream (make-string 10000 :initial-element #\y))
        (is-equal (multiple-value-list (read-reply stream)) '(20 "ERROR: the command is too long"))
        (is-equal (request stream "GETNAME") '(0 "sample.lisp"))
        (close stream)))))

(deftest port-a-too-long-command-with-a-short-body-ends-the-connection
  ;; The header promises 100 characters and the client goes after 3: the
  ;; body cannot be dropped, so there is no frame to answer and the end.
  (let ((*host-frame-limit* 64))
    (with-port (f)
      (let ((stream (host-port-connect (port-fixture-dir f))))
        (is stream)
        (format stream "~D~%abc" 100)
        (finish-output stream)
        (close stream))
      ;; The connection thread is gone from the port's books soon after.
      (let ((n 0))
        (loop while (and (host-port-connections (port-fixture-hp f)) (< n 100))
              do (sleep 0.05) (incf n))
        (is (null (host-port-connections (port-fixture-hp f))))))))

(deftest port-stop-removes-the-files-and-closes-the-listener
  (let ((f (start-port-fixture)) dir number)
    (setq dir (port-fixture-dir f)
          number (host-port-number (port-fixture-hp f)))
    (let ((stream (host-port-connect dir)))
      (is stream)
      (stop-port-fixture f)
      ;; The open connection was closed by the stop.
      (is (closed-after-p stream))
      (close stream))
    (is (null (probe-file (concatenate 'string dir *token-file-name*))))
    (is (null (probe-file (concatenate 'string dir *port-file-name*))))
    (is (null *host-port*))
    (is (handler-case (progn (close (ext:open-tcp-stream "127.0.0.1" number 1)) nil)
          (error () t)))
    ;; Without the files a client cannot connect.
    (multiple-value-bind (stream reason) (host-port-connect dir)
      (is (null stream))
      (is (search "no port or token file" reason)))))

(deftest port-stop-leaves-another-editors-files-alone
  (with-port (f)
    ;; Another editor took the files over meanwhile.
    (let ((token-file (concatenate 'string (port-fixture-dir f) *token-file-name*)))
      (write-private-file token-file "someone-elses-token")
      (host-port-stop (port-fixture-hp f))
      (setf (port-fixture-hp f) nil)
      (is-equal (read-private-file token-file) "someone-elses-token")
      (delete-file token-file))))

(deftest port-refuses-to-start-without-a-private-dir
  (let ((editor (make-fake-editor)))
    (is (handler-case (progn (host-port-start editor :dir nil) nil)
          (error (e) (search "no private directory" (princ-to-string e)))))
    (is (null *host-port*))))

(deftest port-refuses-every-bind-with-a-message-and-starts-nothing
  ;; Until the runtime can bind a named address (R1) `--bind' is refused
  ;; whatever it names, or when it names nothing: never a port on loopback
  ;; as though the option had not been given.
  (let ((editor (make-fake-editor)))
    (dolist (entry '(("" "needs an address")
                     ("0.0.0.0" "wildcard address is not allowed")
                     ("::" "wildcard address is not allowed")
                     ("*" "wildcard address is not allowed")
                     ("192.168.1.5" "only listen on 127.0.0.1")))
      (let* ((*host-bind* (first entry))
             (message (handler-case (progn (host-port-start editor :dir "/tmp/x/") nil)
                        (error (e) (princ-to-string e)))))
        (is (stringp message))
        (is (and (stringp message) (search "--bind" message)))
        (is (and (stringp message) (search (second entry) message)))
        (is (and (stringp message) (search "not started" message)))
        (is (null *host-port*))))))

(deftest port-connect-reports-a-wrong-token-file
  (with-port (f)
    (let ((token-file (concatenate 'string (port-fixture-dir f) *token-file-name*))
          (token (host-port-token (port-fixture-hp f))))
      (write-private-file token-file "wrong")
      (multiple-value-bind (stream reason) (host-port-connect (port-fixture-dir f))
        (is (null stream))
        (is-equal reason "authentication required"))
      (write-private-file token-file token))))

;;; --- the wire on the self transport ------------------------------------------

(deftest host-wire-starts-on-the-self-transport
  (let* ((*host-port* nil)
         (doc (make-fake "(+ 1 2)|"))
         (editor (doc-editor doc))
         (box (make-mailbox)))
    (setf (editor-mailbox editor) box)
    (let ((dir (port-temp-dir)))
      (unwind-protect
           (progn
             (let ((*self-transport* nil))
               (make-wire editor (make-host-self-transport editor))
               (setf (wire-self (editor-wire editor)) (wire-home (editor-wire editor)))
               (host-port-start editor :dir dir)
               (let ((wire (editor-wire editor)))
                 (is (eq (wire-home wire) (wire-self wire)))
                 (is (wire-self-p wire))
                 ;; Both menu items say the same transport twice.
                 (run-command doc 'clamacs-connect-self)
                 (is-equal (fake-last-message doc) "Already talking to the editor itself")
                 (run-command doc 'clamacs-connect-clamiga)
                 (is-equal (fake-last-message doc) "Already talking to clamiga")
                 (is-equal (transport-own-port (wire-transport wire)) *self-own-port*)
                 (stop-host-wire editor)
                 (is (null *host-port*))
                 (is (null *self-transport*)))))
        (mailbox-close box)
        (setf (editor-mailbox editor) nil)))))
