;;;; wire.lisp -- the client side of the wire to clamiga.
;;;;
;;;; The rule this file exists to enforce is the C editor's (src/rexxclient.c,
;;;; src/rexx/queue.c): the editor NEVER waits for a reply.  A request is
;;;; queued, one is on the wire at a time, and the reply comes back later
;;;; through WIRE-REPLY -- so a long LOAD does not freeze the editor, and the
;;;; port keeps answering while clamiga compiles.  Two protocol facts shape
;;;; the queue: ARexx carries RESULT only with rc 0, so a failing command's
;;;; text has to be fetched with LASTRESULT, and that LASTRESULT must be the
;;;; very next thing on the wire or a queued command would overwrite
;;;; clamiga's *LAST-RESULT* first; and one message is in flight per port.
;;;;
;;;; Everything here is written against a TRANSPORT object, three generic
;;;; functions the frontend implements: on the Amiga they are AMIGA.AREXX
;;;; on a client thread (transport-arexx.lisp), on the host a list the tests
;;;; drive (tests/fake-transport.lisp), later a socket for a Mac frontend.
;;;; That is what keeps the queue discipline, the continuations, the error
;;;; list and the commands host-tested.
;;;;
;;;; Pure: no MUI, no OS types, no threads.

(in-package :clamacs)

;;; The ARexx severity ladder (lib/dev-commands.lisp).
(defconstant +rc-ok+ 0)
(defconstant +rc-warn+ 5)
(defconstant +rc-error+ 10)
(defconstant +rc-fatal+ 20)

;;; ------------------------------------------------------------------
;;; The transport protocol
;;; ------------------------------------------------------------------

(defgeneric transport-find-port (transport)
  (:documentation "The name of a clamiga port that exists now -- CLAMIGA,
CLAMIGA.1, ... -- or NIL."))

(defgeneric transport-send (transport port command)
  (:documentation "Put COMMAND on the wire to PORT and return at once.  The
reply arrives later as a call of WIRE-REPLY on the transport's wire, from
the frontend's event loop; a port that is gone by then is reported with
:LOST."))

(defgeneric transport-launch (transport)
  (:documentation "Start a clamiga with its development port, and wait a
bounded time for the port to appear.  True when it did."))

(defgeneric transport-own-port (transport)
  (:documentation "The name of the editor's OWN port -- what clamiga's REPL
thread is told to send to (REPL-ATTACH) -- or NIL while there is none."))

(defgeneric transport-launch-problem (transport)
  (:documentation "Why the last TRANSPORT-LAUNCH failed, as text for the
echo area, or NIL when it has nothing to add to `Cannot start clamiga'.")
  (:method (transport) (declare (ignore transport)) nil))

(defun launch-failure-text (wire)
  (format nil "Cannot start clamiga~@[: ~A~]"
          (transport-launch-problem (wire-transport wire))))

;;; ------------------------------------------------------------------
;;; Requests and the wire
;;; ------------------------------------------------------------------

(defstruct (request (:constructor make-request (command kind doc)))
  command
  kind                      ; :ping :version :in-package :load :compile-file
                            ; :eval :lastresult, and introspect.lisp's
  doc                       ; the document the reply is about, or NIL
  (auto nil)                ; an automatic LASTRESULT
  (origin nil)              ; ... standing in for a request of this kind
  (origin-rc 0)             ; ... that answered with this rc
  (context nil))            ; ... and was about this (its command)

(defun request-subject (req)
  "What the request is about: the failing command, for an automatic
LASTRESULT; else the command itself."
  (or (request-context req) (request-command req)))

(defstruct (wire (:constructor %make-wire (editor transport)))
  editor
  transport
  (queue '())               ; requests waiting, oldest first
  (inflight nil)            ; the one on the wire
  (port-name nil)           ; the port last found
  (connected nil)
  (version nil)
  ;; The package clamiga's port was last told (IN-PACKAGE), so a request
  ;; from a buffer in the same package does not repeat it.  NIL when a port
  ;; is (re)found: a fresh clamiga starts in CL-USER.
  (package nil)
  (diags (make-diaglist))
  ;; The diagnostic `C-x `' last visited: -1 for a fresh list.
  (error-row -1)
  ;; What was sent, newest first: the tests read it.
  (sent '())
  ;; The transport the wire was made with -- clamiga's -- and the one to
  ;; the editor's own Lisp once `clamacs-connect-self' has made it
  ;; (transport-self.lisp).  TRANSPORT is whichever of the two is in use;
  ;; SWITCH-TO the one WIRE-SWITCH is waiting to change to.
  (home nil)
  (self nil)
  (switch-to nil))

(defun make-wire (editor transport)
  (let ((wire (%make-wire editor transport)))
    (setf (wire-home wire) transport
          (editor-wire editor) wire)))

(defun doc-wire (doc)
  (editor-wire (doc-editor doc)))

(defun wire-message (wire doc control &rest args)
  "A message to DOC, or to the active document when there is none."
  (let ((doc (or (and doc (not (doc-closing doc)) doc)
                 (editor-active-document (wire-editor wire)))))
    (when doc
      (doc-message doc (apply #'format nil control args)))))

(defun first-line (text)
  (let ((text (or text "")))
    (subseq text 0 (or (position #\Newline text) (length text)))))

;;; ------------------------------------------------------------------
;;; Finding, starting and connecting
;;; ------------------------------------------------------------------

(defun wire-find-port (wire)
  "Scan for a clamiga port.  Newly found -- at startup, or back after it was
gone -- it is announced, and the package is forgotten."
  (let ((name (transport-find-port (wire-transport wire)))
        (was (wire-connected wire)))
    (cond (name
           (setf (wire-port-name wire) name
                 (wire-connected wire) t)
           (unless was
             (setf (wire-package wire) nil)
             (wire-message wire nil "clamiga found on ~A" name)
             ;; A REPL window that lost its thread gets a new one.
             (repl-reconnected (wire-editor wire)))
           t)
          (t
           (setf (wire-connected wire) nil)
           nil))))

(defun wire-ready-p (wire)
  "Whether a request can go out without asking the user anything."
  (or (wire-connected wire) (wire-find-port wire)))

(defun wire-launch (wire)
  "A port is known afterwards: it was there, or a clamiga was started and
its port came up."
  (or (wire-find-port wire)
      (and (transport-launch (wire-transport wire))
           (wire-find-port wire))))

(defun wire-connect (wire doc)
  "Make sure a port is known before queuing.  Without one, DOC is asked
whether to start clamiga; a quiet caller (DOC NIL) just fails."
  (cond ((wire-ready-p wire) t)
        ((null doc) nil)
        ((not (eq (doc-ask doc
                           "No running clamiga was found. Start one?"
                           '(:start :cancel))
                  :start))
         nil)
        ((wire-launch wire) t)
        (t (doc-message doc (launch-failure-text wire))
           nil)))

;;; ------------------------------------------------------------------
;;; The queue
;;; ------------------------------------------------------------------

(defun wire-pump (wire)
  "Put the head of the queue on the wire, if nothing is in flight -- or,
with nothing in flight or queued, make the switch WIRE-SWITCH asked for."
  (when (and (wire-switch-to wire) (null (wire-inflight wire)) (null (wire-queue wire)))
    (wire-swap wire))
  (when (and (null (wire-inflight wire)) (wire-queue wire))
    (let ((req (pop (wire-queue wire))))
      (setf (wire-inflight wire) req)
      (push (request-command req) (wire-sent wire))
      (transport-send (wire-transport wire) (wire-port-name wire)
                      (request-command req)))))

(defun wire-request (wire doc kind command)
  "Queue COMMAND, connecting first (with DOC's consent to a launch).  The
request, or NIL when nothing went out."
  (when (wire-connect wire doc)
    (let ((req (make-request command kind doc)))
      (setf (wire-queue wire) (append (wire-queue wire) (list req)))
      (wire-pump wire)
      req)))

(defun wire-reply (wire rc text &key lost)
  "The transport delivers the reply to the request in flight: RC and the
RESULT text (\"\" when ARexx dropped it).  LOST: the port was gone, and
TEXT says so.  Called from the frontend's event loop, never from another
thread."
  (let ((req (wire-inflight wire)))
    (setf (wire-inflight wire) nil)
    (when req
      (cond (lost
             ;; The rest of the queue would fail the same way, one reply
             ;; at a time; a reconnect starts afresh.
             (setf (wire-connected wire) nil
                   (wire-queue wire) '())
             (wire-message wire (request-doc req)
                           "clamiga is not running (port ~A is gone)"
                           (wire-port-name wire))
             (repl-disconnected (wire-editor wire)))
            ((and (/= rc +rc-ok+)
                  (not (request-auto req))
                  (not (eq (request-kind req) :lastresult)))
             ;; Fetch the text ARexx dropped -- next on the wire, ahead of
             ;; everything queued, carrying what it stands in for.
             (let ((fetch (make-request "LASTRESULT" :lastresult (request-doc req))))
               (setf (request-auto fetch) t
                     (request-origin fetch) (request-kind req)
                     (request-origin-rc fetch) rc
                     (request-context fetch) (request-subject req))
               (push fetch (wire-queue wire))))
            (t
             (wire-dispatch wire req rc text)))))
  (wire-pump wire))

;;; ------------------------------------------------------------------
;;; Switching between clamiga and the editor's own Lisp
;;; ------------------------------------------------------------------

(defun wire-self-p (wire)
  "Whether WIRE talks to the editor's own Lisp now."
  (and wire (wire-self wire) (eq (wire-transport wire) (wire-self wire)) t))

(defun wire-switch (wire transport)
  "Talk to TRANSPORT from now on.  The switch waits until nothing is on
the wire or queued -- a reply always goes back to the transport that was
asked -- and a REPL attached to the old side is detached first, so its
thread does not go on sending to a window that now belongs to the other
side.  True when the switch was made at once."
  (setf (wire-switch-to wire) transport)
  (let ((editor (wire-editor wire)))
    (when (and (wire-connected wire)
               (repl-session-attached (repl-session editor)))
      (repl-detach editor)))
  (wire-pump wire)
  (null (wire-switch-to wire)))

(defun wire-swap (wire)
  "Make the switch: forget everything learned from the old side (its
package, its version, its arglists) and attach an open REPL window to the
new one."
  (let ((editor (wire-editor wire))
        (to (wire-switch-to wire)))
    (setf (wire-transport wire) to
          (wire-switch-to wire) nil
          (wire-connected wire) nil
          (wire-port-name wire) nil
          (wire-package wire) nil
          (wire-version wire) nil)
    (symcache-clear (editor-arglists editor))
    (let ((name (transport-find-port to)))
      (when name
        (setf (wire-port-name wire) name
              (wire-connected wire) t))
      (let ((news (if name
                      (format nil "Now talking to ~A" name)
                      "Now talking to clamiga, which is not running (Start clamiga)")))
        (wire-message wire nil "~A" news)
        (repl-switched editor news)))))

;;; ------------------------------------------------------------------
;;; Continuations
;;; ------------------------------------------------------------------

(defun live-doc (doc)
  (and doc (not (doc-closing doc)) doc))

(defun wire-dispatch (wire req rc text)
  (let ((kind (request-kind req))
        (doc (live-doc (request-doc req)))
        (rc rc))
    ;; An automatic LASTRESULT carries the text of the command that
    ;; failed: handled as that command's own reply, with ITS rc.
    (when (and (eq kind :lastresult) (request-auto req))
      (setq kind (request-origin req)
            rc (request-origin-rc req)))
    (case kind
      (:ping
       (when doc (message doc "clamiga answers on ~A" (wire-port-name wire))))
      (:version
       (when text (setf (wire-version wire) text))
       (when doc (doc-message doc (or (wire-version wire) ""))))
      (:in-package
       (when (and (/= rc +rc-ok+) doc)
         (doc-message doc (if (and text (string/= text "")) text "IN-PACKAGE failed"))))
      ((:load :compile-file)
       (wire-diagnostics wire doc text))
      (:eval
       (cond ((= rc +rc-ok+)
              (when doc
                (let ((line (first-line text)))
                  (doc-message doc (if (string= line "") "; no values" line)))))
             (t (wire-diagnostics wire doc text))))
      ((:arglist :arglist-echo :complete-buffer :complete-mini
        :source-location :describe :apropos :macroexpand)
       ;; The questions about a symbol (introspect.lisp).
       (intro-reply wire kind doc (request-subject req) rc text))
      ((:repl-attach :repl-eval :repl-input :repl-interrupt :repl-detach)
       ;; The REPL window's own requests (repl.lisp).
       (repl-reply wire kind doc rc text))
      ((:dbg-backtrace :dbg-frame :dbg-frame-eval :dbg-restart)
       ;; The debugger's (debugger.lisp).
       (debug-reply wire kind doc rc text))
      (:inspect
       (inspect-reply wire doc rc text))
      (t
       (when (and doc text) (doc-message doc text))))))

(defun wire-diagnostics (wire doc text)
  "A LOAD, COMPILE-FILE or failed EVAL replied: the rows go to the error
list, the summary to the echo area, and what the command printed to the
REPL transcript (repl-log) under the reply's first line, `; loading
Work:foo.lisp'."
  (let ((list (wire-diags wire))
        (text (or text "")))
    (parse-diagnostics list text)
    (setf (wire-error-row wire) -1)
    (editor-show-diagnostics (wire-editor wire) (diaglist-rendered list))
    (when (diaglist-log list)
      ;; A failed EVAL's reply starts with a row, not with `; ...'.
      (let ((line (first-line text)))
        (repl-log (wire-editor wire) doc
                  (and (starts-with-p "; " line) (subseq line 2))
                  (diaglist-log list))))
    (when doc
      (doc-message doc
                   (if (diaglist-summary-seen list)
                       (format nil "~A~:[~; (aborted)~]~:[~; (reply truncated)~]"
                               (diaglist-summary list)
                               (diaglist-aborted list)
                               (diaglist-truncated list))
                       (first-line text))))))

;;; ------------------------------------------------------------------
;;; The error list
;;; ------------------------------------------------------------------

(defun diagnostic-jump (wire row)
  "Visit diagnostic ROW: the file in its window (opened if need be), the
cursor on the line, the message in the echo area.  Selecting a row in the
list and `C-x `' both come here."
  (let ((list (wire-diags wire)))
    (when (< -1 row (diaglist-count list))
      (setf (wire-error-row wire) row)
      (let* ((d (diaglist-ref list row))
             (editor (wire-editor wire))
             (file (diagnostic-file d)))
        (if (null file)
            (let ((doc (editor-active-document editor)))
              (when doc (doc-message doc (diagnostic-text d))))
            (let ((doc (or (find-document-by-path editor file)
                           (open-document editor file))))
              (when doc
                (doc-activate doc)
                (when (> (diagnostic-line d) 0)
                  (doc-set-point doc (doc-line-index doc (1- (diagnostic-line d)))))
                (doc-message doc (diagnostic-text d)))))))))

(defun step-diagnostic (doc step)
  (let* ((wire (doc-wire doc))
         (n (diaglist-count (wire-diags wire)))
         (row (+ (wire-error-row wire) step)))
    (cond ((zerop n)
           (doc-message doc "No diagnostics")
           (doc-beep doc))
          ((or (< row 0) (>= row n))
           (message doc "~A diagnostic" (if (> step 0) "No further" "No previous"))
           (doc-beep doc))
          (t
           (diagnostic-jump wire row)
           (editor-select-diagnostic (wire-editor wire) row)))))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun require-wire (doc)
  "The wire, or NIL with a complaint: a frontend without one (the host
tests' bare fake) cannot talk to clamiga."
  (or (doc-wire doc)
      (progn (doc-message doc "No connection to clamiga in this editor")
             (doc-beep doc)
             nil)))

(defun doc-current-package (doc)
  "The package the form at the cursor is in: the nearest (in-package ...)
before it, else CL-USER -- where a fresh clamiga starts, but not where it
stays once another buffer has spoken, so it is always said."
  (multiple-value-bind (text base point) (doc-context-full doc)
    (declare (ignore base))
    (or (and text (sexp-current-package text point)) "CL-USER")))

(defun wire-ensure-package (wire doc &optional package)
  "Tell clamiga's port DOC's package (PACKAGE when the caller has it
already), unless it was told already."
  (let ((package (or package (doc-current-package doc))))
    (unless (and (wire-package wire) (string-equal package (wire-package wire)))
      (when (wire-request wire doc :in-package (format nil "IN-PACKAGE ~A" package))
        (setf (wire-package wire) package)))))

(defun wire-eval (doc text)
  "Send TEXT, one or more forms, for evaluation in DOC's package -- on
clamiga's REPL thread (repl.lisp), so output streams into the transcript
and an error opens the debugger; the first line of the values lands in
DOC's echo area.  The handler thread's EVAL is for macros and the port,
not for keys."
  (when (require-wire doc)
    (repl-eval-from doc text)))

(defun wire-load (doc path)
  (let ((wire (require-wire doc)))
    (when wire
      (diaglist-clear (wire-diags wire))
      (setf (wire-error-row wire) -1)
      (wire-request wire doc :load (format nil "LOAD ~A" path)))))

(define-command clamacs-load-buffer (doc arg)
  (declare (ignore arg))
  (cond ((null (doc-path doc))
         (doc-message doc "Save the buffer to a file first")
         (doc-beep doc))
        ((not (save-file doc (doc-path doc)))
         (doc-beep doc))
        ((wire-load doc (doc-path doc))
         (message doc "Loading ~A ..." (doc-name doc)))))

(define-command clamacs-load-file (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Load file: "
                   (lambda (doc path)
                     (when (wire-load doc path)
                       (message doc "Loading ~A ..." path)))))

(define-command clamacs-compile-file (doc arg)
  (declare (ignore arg))
  (cond ((null (doc-path doc))
         (doc-message doc "Save the buffer to a file first")
         (doc-beep doc))
        (t
         (let ((wire (require-wire doc)))
           (when wire
             (diaglist-clear (wire-diags wire))
             (setf (wire-error-row wire) -1)
             (when (wire-request wire doc :compile-file
                                 (format nil "COMPILE-FILE ~A" (doc-path doc)))
               (message doc "Compiling ~A ..." (doc-name doc))))))))

(define-command clamacs-eval-defun (doc arg)
  (declare (ignore arg))
  (multiple-value-bind (text base point) (doc-context-full doc)
    (let* ((start (or (sexp-defun-start text point) 0))
           (stop (sexp-forward text start)))
      (cond ((null stop)
             (doc-message doc "Unbalanced expression")
             (doc-beep doc))
            (t (wire-eval doc (doc-text doc (+ base start) (+ base stop))))))))

(define-command clamacs-eval-last-sexp (doc arg)
  (declare (ignore arg))
  (multiple-value-bind (text base point) (doc-context-full doc)
    (multiple-value-bind (start stop) (sexp-last-sexp text point)
      (cond ((null start)
             (doc-message doc "No expression before point")
             (doc-beep doc))
            (t (wire-eval doc (doc-text doc (+ base start) (+ base stop))))))))

(define-command clamacs-eval-region (doc arg)
  (declare (ignore arg))
  (multiple-value-bind (start stop) (region-bounds doc)
    (when start
      (let ((text (take-region doc start stop nil)))
        (if text
            (wire-eval doc text)
            (doc-beep doc))))))

(define-command clamacs-eval-expression (doc arg)
  (declare (ignore arg))
  (prompt-for-form doc "Eval: "
                   (lambda (doc answer)
                     (when (string/= answer "")
                       (wire-eval doc answer)))))

(define-command clamacs-connect (doc arg)
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (if (wire-find-port wire)
          (wire-request wire doc :version "VERSION")
          (doc-message doc "No clamiga port found")))))

(define-command run-lisp (doc arg)
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (if (wire-launch wire)
          (doc-message doc "Started clamiga")
          (doc-message doc (launch-failure-text wire))))))

(define-command clamacs-show-errors (doc arg)
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (editor-show-diagnostics (wire-editor wire)
                               (diaglist-rendered (wire-diags wire))
                               :open t))))

(define-command clamacs-next-error (doc arg)
  (declare (ignore arg))
  (when (require-wire doc)
    (step-diagnostic doc 1)))

(define-command clamacs-previous-error (doc arg)
  (declare (ignore arg))
  (when (require-wire doc)
    (step-diagnostic doc -1)))
