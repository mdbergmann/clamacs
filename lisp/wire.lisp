;;;; wire.lisp -- the client side of the wire to amilisp.
;;;;
;;;; The rule this file exists to enforce is the C editor's (src/rexxclient.c,
;;;; src/rexx/queue.c): the editor NEVER waits for a reply.  A request is
;;;; queued, one is on the wire at a time, and the reply comes back later
;;;; through WIRE-REPLY -- so a long LOAD does not freeze the editor, and the
;;;; port keeps answering while amilisp compiles.  Two protocol facts shape
;;;; the queue: ARexx carries RESULT only with rc 0, so a failing command's
;;;; text has to be fetched with LASTRESULT, and that LASTRESULT must be the
;;;; very next thing on the wire or a queued command would overwrite
;;;; amilisp's *LAST-RESULT* first; and one message is in flight per port.
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
  (:documentation "The name of an amilisp port that exists now -- AMILISP,
AMILISP.1, ... -- or NIL."))

(defgeneric transport-send (transport port command)
  (:documentation "Put COMMAND on the wire to PORT and return at once.  The
reply arrives later as a call of WIRE-REPLY on the transport's wire, from
the frontend's event loop; a port that is gone by then is reported with
:LOST."))

(defgeneric transport-launch (transport)
  (:documentation "Start an amilisp with its development port, and wait a
bounded time for the port to appear.  True when it did."))

(defgeneric transport-own-port (transport)
  (:documentation "The name of the editor's OWN port -- what amilisp's REPL
thread is told to send to (REPL-ATTACH) -- or NIL while there is none."))

(defgeneric transport-launch-problem (transport)
  (:documentation "Why the last TRANSPORT-LAUNCH failed, as text for the
echo area, or NIL when it has nothing to add to `Cannot start amilisp'.")
  (:method (transport) (declare (ignore transport)) nil))

(defgeneric transport-log (transport)
  (:documentation "The file the amilisp this transport started writes its
output to -- where an error that took a thread of it with it is found --
or NIL when there is none.")
  (:method (transport) (declare (ignore transport)) nil))

;;; How an amilisp the editor starts is started: the init file's to set.

(defvar *amilisp-heap* :default
  "The heap of an amilisp the editor starts, as its `--heap' takes it
(\"256M\", \"8M\"): what a loaded system and everything it depends on has
to fit in.  :DEFAULT is 256M on macOS, Linux and Windows and amilisp's own
default on an Amiga, where the memory is the machine's; NIL is amilisp's
own default everywhere.")

(defvar *amilisp-options* '()
  "More command line options for an amilisp the editor starts, a list of
strings: (\"--no-userinit\"), (\"--no-jit\").")

(defparameter *host-amilisp-heap* "256M")

;;; The names before 0.12, so an init file's (setq *clamiga-heap* ...)
;;; still takes effect: a symbol macro makes SETQ and SETF of the old name
;;; the new variable's.
(define-symbol-macro *clamiga-heap* *amilisp-heap*)
(define-symbol-macro *clamiga-options* *amilisp-options*)
(define-symbol-macro *host-clamiga-heap* *host-amilisp-heap*)

;;; The same scan the shipped macros do: the base name, then .1 .. .9, so a
;;; second amilisp instance is reachable; then the same under CLAMIGA, the
;;; port's name on a runtime older than 0.12, so an old one is still found.
;;; Here rather than in transport-arexx.lisp (Amiga only) so the host tests
;;; can pin the list.
(defparameter *amilisp-port-names*
  (loop for base in '("AMILISP" "CLAMIGA")
        collect base
        nconc (loop for i from 1 to 9 collect (format nil "~A.~D" base i))))

(define-symbol-macro *clamiga-port-names* *amilisp-port-names*)

(defun amilisp-heap ()
  "The heap to ask for, a string, or NIL for amilisp's own default."
  (let ((heap *amilisp-heap*))
    (cond ((eq heap :default)
           ;; Asked at run time: the FASLs are compiled on the host.
           (if (or (member :amigaos *features*) (member :morphos *features*))
               nil
               *host-amilisp-heap*))
          ((and (stringp heap) (string/= heap "")) heap)
          ((and (integerp heap) (> heap 0)) (format nil "~D" heap))
          (t nil))))

(defun amilisp-launch-options (&optional (heap (amilisp-heap)))
  "The options a started amilisp gets before the editor's own, a list of
strings: the heap, then *AMILISP-OPTIONS*."
  (append (and heap (list "--heap" heap))
          (remove-if-not #'stringp *amilisp-options*)))

(defun launch-failure-text (wire)
  (format nil "Cannot start amilisp~@[: ~A~]"
          (transport-launch-problem (wire-transport wire))))

;;; ------------------------------------------------------------------
;;; Requests and the wire
;;; ------------------------------------------------------------------

(defstruct (request (:constructor make-request (command kind doc)))
  command
  kind                      ; :ping :version :in-package :load :compile-file
                            ; :eval :lastresult :tell-root, and introspect.lisp's
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
  ;; The package amilisp's port was last told (IN-PACKAGE), so a request
  ;; from a buffer in the same package does not repeat it.  NIL when a port
  ;; is (re)found: a fresh amilisp starts in CL-USER.
  (package nil)
  (diags (make-diaglist))
  ;; The diagnostic `C-x `' last visited: -1 for a fresh list.
  (error-row -1)
  ;; What was sent, newest first: the tests read it.
  (sent '())
  ;; The transport the wire was made with -- amilisp's -- and the one to
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
  "Scan for an amilisp port.  Newly found -- at startup, or back after it was
gone -- it is announced, and the package is forgotten."
  (let ((name (transport-find-port (wire-transport wire)))
        (was (wire-connected wire)))
    (cond (name
           (setf (wire-port-name wire) name
                 (wire-connected wire) t)
           (unless was
             (setf (wire-package wire) nil)
             (wire-message wire nil "amilisp found on ~A" name)
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
  "A port is known afterwards: it was there, or an amilisp was started and
its port came up."
  (or (wire-find-port wire)
      (and (transport-launch (wire-transport wire))
           (wire-find-port wire))))

(defun wire-connect (wire doc)
  "Make sure a port is known before queuing.  Without one, DOC is asked
whether to start amilisp; a quiet caller (DOC NIL) just fails.  A
refusal answers :CANCELLED as second value; a launch that failed was
reported to DOC."
  (cond ((wire-ready-p wire) t)
        ((null doc) nil)
        ((not (eq (doc-ask doc
                           "No running amilisp was found. Start one?"
                           '(:start :cancel))
                  :start))
         (values nil :cancelled))
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
                           "amilisp is not running (port ~A is gone)"
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
;;; Switching between amilisp and the editor's own Lisp
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
                      "Now talking to amilisp, which is not running (Start amilisp)")))
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
       (when doc (message doc "amilisp answers on ~A" (wire-port-name wire))))
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
      (:tell-root
       ;; A perspective's project directory told to amilisp
       ;; (perspective.lisp): nobody waits for the answer.
       nil)
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
tests' bare fake) cannot talk to amilisp."
  (or (doc-wire doc)
      (progn (doc-message doc "No connection to amilisp in this editor")
             (doc-beep doc)
             nil)))

(defun doc-current-package (doc)
  "The package the form at the cursor is in: the nearest (in-package ...)
before it, else CL-USER -- where a fresh amilisp starts, but not where it
stays once another buffer has spoken, so it is always said."
  (multiple-value-bind (text base point) (doc-context-full doc)
    (declare (ignore base))
    (or (and text (sexp-current-package text point)) "CL-USER")))

(defun wire-ensure-package (wire doc &optional package)
  "Tell amilisp's port DOC's package (PACKAGE when the caller has it
already), unless it was told already."
  (let ((package (or package (doc-current-package doc))))
    (unless (and (wire-package wire) (string-equal package (wire-package wire)))
      (when (wire-request wire doc :in-package (format nil "IN-PACKAGE ~A" package))
        (setf (wire-package wire) package)))))

(defun wire-eval (doc text &optional package)
  "Send TEXT, one or more forms, for evaluation in DOC's package (in
PACKAGE when given) -- on amilisp's REPL thread (repl.lisp), so output
streams into the transcript and an error opens the debugger; the first
line of the values lands in DOC's echo area.  The handler thread's EVAL
is for macros and the port, not for keys.  True when the text was sent
or waits for the REPL to attach."
  (when (require-wire doc)
    (repl-eval-from doc text package)))

(defun wire-load (doc path)
  (let ((wire (require-wire doc)))
    (when wire
      (diaglist-clear (wire-diags wire))
      (setf (wire-error-row wire) -1)
      (wire-request wire doc :load (format nil "LOAD ~A" path)))))

(define-command clamacs-load-buffer (doc arg)
  "Save the buffer and LOAD its file in amilisp."
  (declare (ignore arg))
  (cond ((null (doc-path doc))
         (doc-message doc "Save the buffer to a file first")
         (doc-beep doc))
        ((not (save-file doc (doc-path doc)))
         (doc-beep doc))
        ((wire-load doc (doc-path doc))
         (message doc "Loading ~A ..." (doc-name doc)))))

(defun load-file-into-lisp (doc path)
  (when (wire-load doc path)
    (message doc "Loading ~A ..." path)))

(define-command clamacs-load-file (doc arg)
  "LOAD a file in amilisp, asked for in the minibuffer."
  (declare (ignore arg))
  (prompt-for-file doc "Load file: " #'load-file-into-lisp :title "Load File"))

(define-command clamacs-load-file-requester (doc arg)
  "Load a file chosen in the requester into amilisp: the menu's Load File..."
  (declare (ignore arg))
  (ask-file-then doc "Load File" nil (doc-directory doc) #'load-file-into-lisp))

(define-command clamacs-compile-file (doc arg)
  "COMPILE-FILE the buffer's file in amilisp and list the diagnostics."
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

;;; ------------------------------------------------------------------
;;; Systems
;;; ------------------------------------------------------------------

;;; A system is loaded by its definition file, the .asd: the one in the
;;; window, or the nearest one above the window's file -- a project's root
;;; is where its .asd sits.  amilisp does the rest (EXT.DEV:LOAD-ASD-SYSTEM
;;; loads ASDF on first use, the file, and the system named after it -- or
;;; the one named as its second argument), on the REPL thread: a system is
;;; minutes of compiling on an Amiga, which wants its output as it
;;; happens, the interrupt and the debugger.
;;;
;;; A file that defines several systems (foo and foo/tests, as a rule) is
;;; asked about in a requester, one button per system: the editor reads
;;; the file's DEFSYSTEM names off the sexp walker (TEXT-SYSTEMS), never
;;; through the reader, since a .asd names packages the editor's image
;;; does not have.  A file that defines one system loads that one, even
;;; when it is not named after the file.
;;;
;;; The ASDF menu is left out on a 68k machine (menu.lisp), where ASDF
;;; is more than most can carry; the commands are there all the same.

(defvar *last-system-file* nil
  "The .asd the last Load System or Test System named: what a window
with no system above it (the REPL's, a scratch buffer) falls back to.")

(defparameter *system-search-depth* 12
  "How many directories above a file FIND-SYSTEM-FILES looks in.")

(defun system-path-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot (string-equal (subseq path dot) ".asd"))))

(defun path-parent-directory (dir)
  "The directory above DIR, a path ending in `/'; NIL when DIR is a root
(`/', an AmigaDOS volume or assign) or has nothing above it."
  (let ((n (length dir)))
    (and (> n 1)
         (char= (char dir (1- n)) #\/)
         (let ((up (path-directory (subseq dir 0 (1- n)))))
           (and (string/= up "") up)))))

(defun directory-system-files (dir)
  "The .asd files in DIR, sorted."
  (sort (remove-if-not #'system-path-p
                       (ignore-errors
                        (mapcar #'namestring
                                (directory (concatenate 'string dir "*.asd")))))
        #'string<))

(defun find-system-files (path)
  "The system definitions PATH belongs to: PATH itself when it is one,
else the .asd files of the nearest directory above it that has any."
  (cond ((null path) '())
        ((system-path-p path) (list path))
        (t
         (loop for dir = (path-directory path) then (path-parent-directory dir)
               repeat *system-search-depth*
               while (and dir (string/= dir ""))
               do (let ((found (directory-system-files dir)))
                    (when found (return found)))))))

(defun system-name (path)
  "The system PATH defines, as ASDF names it after the file."
  (let ((base (path-basename path)))
    (string-downcase (subseq base 0 (position #\. base :from-end t)))))

(defun sx-defsystem-p (buf start end)
  "Whether the atom at START..END of BUF is DEFSYSTEM, with or without a
package prefix (asdf:defsystem, asdf::defsystem), in any case."
  (declare (simple-string buf) (fixnum start end))
  (let ((tail (- end 9)))
    (declare (fixnum tail))
    (and (>= tail start)
         (string-equal "defsystem" buf :start2 tail :end2 end)
         (or (= tail start)
             (char= (schar buf (1- tail)) #\:)))))

(defun sx-system-name (buf len pos)
  "The name a DEFSYSTEM at POS of BUF gives its system, as ASDF takes it:
a string as it is, a symbol (foo, :foo, #:foo) downcased without its
package marker.  NIL when what follows is neither."
  (declare (simple-string buf) (fixnum len pos))
  (loop
    (multiple-value-bind (kind start end) (sx-next buf len pos)
      (declare (fixnum start end))
      (case kind
        (:quote (setq pos end))                ; the # of #:foo, a '
        (:string
         (return (and (>= (- end start) 2)
                      (char= (schar buf (1- end)) #\")
                      (subseq buf (1+ start) (1- end)))))
        (:atom
         (loop while (and (< start end) (char= (schar buf start) #\:))
               do (incf start))
         (return (and (< start end) (string-downcase (subseq buf start end)))))
        (t (return nil))))))

(defun text-systems (text)
  "The names of the systems TEXT, a system definition file's contents,
defines: what every DEFSYSTEM form names, in the file's order -- a
walk over the tokens, so a file the editor's reader could not take (its
packages are amilisp's) still names its systems."
  (let* ((buf (sx-simple text))
         (len (length buf))
         (names '()))
    (declare (simple-string buf) (fixnum len))
    (do-sx-tokens (kind start end buf len)
      (when (eq kind :open)
        (multiple-value-bind (hkind hstart hend) (sx-next buf len end)
          (declare (fixnum hstart hend))
          (when (and (eq hkind :atom) (sx-defsystem-p buf hstart hend))
            (let ((name (sx-system-name buf len hend)))
              (when name
                (push name names)))))))
    (nreverse names)))

(defun file-systems (path)
  "The systems the definition file PATH defines, by name; NIL when it
cannot be read."
  (let ((text (read-file-text path)))
    (and text (text-systems text))))

(defun choose-system (doc verb path continuation)
  "Call CONTINUATION with the name of the system of PATH that VERB (Load,
Test) is to act on: the one the file defines, or the one the user picks
in a requester when it defines several -- not at all when the user
cancels.  NIL when the file names none, for the one named after the file."
  (let ((systems (file-systems path)))
    (if (null (rest systems))
        (funcall continuation (first systems))
        (let ((choice (doc-ask doc (format nil "~A which system of ~A?"
                                           verb (path-basename path))
                               (append systems (list :cancel)))))
          (unless (eq choice :cancel)
            (funcall continuation choice))))))

(defun system-eval (doc function verb path &optional name)
  "Have amilisp call EXT.DEV's FUNCTION on the system definition PATH --
on its system NAME when that is not the one the file is named after."
  (setq *last-system-file* path)
  (let ((own (system-name path)))
    ;; In CL-USER: the buffer's package may be one the system makes.
    (when (wire-eval doc (if (and name (string/= name own))
                             (format nil "(ext.dev:~A ~S ~S)" function path name)
                             (format nil "(ext.dev:~A ~S)" function path))
                     "CL-USER")
      (message doc "~A system ~A ..." verb (or name own)))))

(defun system-command (doc function verb question path)
  "Load or test (FUNCTION, VERB as in `Loading', QUESTION as in `Load')
a system of the definition file PATH, asked about when it has several."
  (cond ((not (system-path-p path))
         (message doc "Not a system definition (.asd): ~A" path)
         (doc-beep doc))
        (t
         (choose-system doc question path
                        (lambda (name)
                          (system-eval doc function verb path name))))))

(defun load-system-file (doc path)
  (system-command doc "load-asd-system" "Loading" "Load" path))

(defun test-system-file (doc path)
  (system-command doc "test-asd-system" "Testing" "Test" path))

(defun with-system-file (doc label continuation)
  "Call CONTINUATION with DOC and the system definition DOC belongs to.
Several in one directory, or none and no system loaded before, are asked
for in the minibuffer."
  (when (require-wire doc)
    (when (and (doc-path doc) (doc-modified-p doc))
      ;; ASDF reads the files, not the windows.
      (unless (save-file doc (doc-path doc))
        (doc-beep doc)
        (return-from with-system-file nil)))
    ;; A buffer without a file looks from its perspective's project
    ;; directory (perspective.lisp), when it has one.
    (let ((found (find-system-files (or (doc-path doc)
                                        (let ((dir (doc-directory doc)))
                                          (and (string/= dir "") dir))))))
      (cond ((and found (null (rest found)))
             (funcall continuation doc (first found)))
            (found
             (prompt-for-file doc label continuation
                              :initial (path-directory (first found))))
            (*last-system-file*
             (funcall continuation doc *last-system-file*))
            (t
             (prompt-for-file doc label continuation
                              :initial (doc-directory doc)))))))

(define-command clamacs-load-system (doc arg)
  "Load the ASDF system the buffer belongs to (the nearest .asd) in amilisp."
  (declare (ignore arg))
  (with-system-file doc "Load system (.asd): " #'load-system-file))

(define-command clamacs-test-system (doc arg)
  "Run the tests of the ASDF system the buffer belongs to in amilisp."
  (declare (ignore arg))
  (with-system-file doc "Test system (.asd): " #'test-system-file))

(define-command clamacs-load-system-from (doc arg)
  "Load an ASDF system in amilisp, its .asd asked for in the minibuffer."
  (declare (ignore arg))
  (when (require-wire doc)
    (prompt-for-file doc "Load system (.asd): " #'load-system-file
                     :title "Load System")))

(define-command clamacs-load-system-from-requester (doc arg)
  "Load an ASDF system chosen in the requester: the menu's Load System From..."
  (declare (ignore arg))
  (when (require-wire doc)
    (ask-file-then doc "Load System" nil (doc-directory doc) #'load-system-file)))

(define-command clamacs-eval-defun (doc arg)
  "Evaluate the top-level form at the cursor in amilisp."
  (declare (ignore arg))
  (multiple-value-bind (text base point) (doc-context-full doc)
    (let* ((start (or (sexp-defun-start text point) 0))
           (stop (sexp-forward text start)))
      (cond ((null stop)
             (doc-message doc "Unbalanced expression")
             (doc-beep doc))
            (t (wire-eval doc (doc-text doc (+ base start) (+ base stop))))))))

(define-command clamacs-eval-last-sexp (doc arg)
  "Evaluate the expression before the cursor in amilisp."
  (declare (ignore arg))
  (multiple-value-bind (text base point) (doc-context-full doc)
    (multiple-value-bind (start stop) (sexp-last-sexp text point)
      (cond ((null start)
             (doc-message doc "No expression before point")
             (doc-beep doc))
            (t (wire-eval doc (doc-text doc (+ base start) (+ base stop))))))))

(define-command clamacs-eval-region (doc arg)
  "Evaluate the region in amilisp."
  (declare (ignore arg))
  (multiple-value-bind (start stop) (region-bounds doc)
    (when start
      (let ((text (take-region doc start stop nil)))
        (if text
            (wire-eval doc text)
            (doc-beep doc))))))

(define-command clamacs-eval-expression (doc arg)
  "Evaluate a form typed in the minibuffer in amilisp."
  (declare (ignore arg))
  (prompt-for-form doc "Eval: "
                   (lambda (doc answer)
                     (when (string/= answer "")
                       (wire-eval doc answer)))))

(define-command clamacs-connect (doc arg)
  "Find amilisp's port and connect to it; without one, offer to start amilisp."
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      ;; Connect is the user asking whether amilisp is there, so look,
      ;; rather than trust WIRE-CONNECTED: an amilisp that quit leaves it
      ;; set until a request fails on the vanished port, and with it set
      ;; WIRE-CONNECT would skip the scan, send VERSION into the void and
      ;; only report "port is gone" -- the offer to start one came on the
      ;; SECOND Connect.  A port still there changes nothing (the find
      ;; path's "newly found" announcement and REPL re-attach stay off).
      (unless (transport-find-port (wire-transport wire))
        (setf (wire-connected wire) nil))
      ;; WIRE-CONNECT finds the port, or asks whether to start amilisp
      ;; and reports a launch that failed; a cancel is answered here.
      (multiple-value-bind (connected why) (wire-connect wire doc)
        (cond (connected (wire-request wire doc :version "VERSION"))
              ((eq why :cancelled) (doc-message doc "No amilisp port found")))))))

(define-command run-lisp (doc arg)
  "Start an amilisp of our own and connect to it."
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (if (wire-launch wire)
          (doc-message doc "Started amilisp")
          (doc-message doc (launch-failure-text wire))))))

(define-command clamacs-show-errors (doc arg)
  "Show the diagnostics of the last load or compile."
  (declare (ignore arg))
  (let ((wire (require-wire doc)))
    (when wire
      (editor-show-diagnostics (wire-editor wire)
                               (diaglist-rendered (wire-diags wire))
                               :open t))))

(define-command clamacs-next-error (doc arg)
  "Go to the next diagnostic's line."
  (declare (ignore arg))
  (when (require-wire doc)
    (step-diagnostic doc 1)))

(define-command clamacs-previous-error (doc arg)
  "Go to the previous diagnostic's line."
  (declare (ignore arg))
  (when (require-wire doc)
    (step-diagnostic doc -1)))
