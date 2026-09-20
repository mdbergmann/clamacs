;;;; fake-transport.lisp -- the transport protocol over a list.
;;;;
;;;; The second implementation of wire.lisp's three generic functions, and
;;;; the reason the queue discipline and the continuations are host-tested:
;;;; it records what the wire put on it, answers FIND-PORT with whatever the
;;;; test says, and delivers a reply when the test calls FAKE-DELIVER --
;;;; asynchronously, as the real one does, so a test can look at the editor
;;;; between the request and its reply.

(in-package :clamacs)

(defstruct (fake-transport (:constructor make-fake-transport ()))
  (port nil)               ; what FIND-PORT answers
  (sent '())               ; (port . command), newest first
  (launched 0)             ; how often LAUNCH was asked
  (launch-port nil)        ; the port a launch brings up, or NIL: it fails
  wire)

(defmethod transport-find-port ((tr fake-transport))
  (fake-transport-port tr))

(defmethod transport-send ((tr fake-transport) port command)
  (push (cons port command) (fake-transport-sent tr)))

(defmethod transport-launch ((tr fake-transport))
  (incf (fake-transport-launched tr))
  (when (fake-transport-launch-port tr)
    (setf (fake-transport-port tr) (fake-transport-launch-port tr))
    t))

(defmethod transport-own-port ((tr fake-transport))
  "The Lisp editor's first instance owns CLAMACS."
  "CLAMACS")

(defun fake-answer-attach (tr &key (package "CL-USER"))
  "The REPL-ATTACH the first buffer eval (or C-c C-z) put on the wire,
answered with PACKAGE: the prompt's package, as clamiga replies."
  (is-equal (fake-last-sent tr) "REPL-ATTACH CLAMACS DEBUG")
  (fake-deliver tr 0 package))

(defun fake-inbound (editor line)
  "A command clamiga's REPL thread sends to the editor's port, delivered
as the transport would: OUTPUT, READLINE, RESULT, DEBUGGER -- LINE is the
raw command, verbatim after the verb's one blank, as EXT.DEV hands a raw
verb its argument.  The verb's answer, (values RC TEXT)."
  (multiple-value-bind (verb end)
      (let ((end (or (position-if (lambda (c) (member c '(#\Space #\Newline))) line)
                     (length line))))
        (values (string-upcase (subseq line 0 end)) end))
    (port-verb editor verb
               (if (and (< end (length line)) (char= (char line end) #\Space))
                   (subseq line (1+ end))
                   (subseq line end)))))

(defun fake-deliver (tr rc text &key lost)
  "clamiga's reply to the command on the wire."
  (wire-reply (fake-transport-wire tr) rc text :lost lost))

(defun fake-last-sent (tr)
  "The command most recently put on the wire, or NIL."
  (cdr (first (fake-transport-sent tr))))

(defun fake-sent-commands (tr)
  "Every command sent so far, oldest first."
  (reverse (mapcar #'cdr (fake-transport-sent tr))))

(defun make-wired-fake (text &key (port "CLAMIGA"))
  "A fake document whose editor has a wire over a fake transport that finds
PORT.  Three values: the document, the transport, the wire."
  (let* ((editor (make-fake-editor))
         (tr (make-fake-transport))
         (wire (make-wire editor tr)))
    (setf (fake-transport-wire tr) wire
          (fake-transport-port tr) port)
    (values (make-fake text :editor editor) tr wire)))

;;; --- the port (port.lisp): what test-port, test-menu and test-snapshot drive

(defparameter *sample-text*
  (lines "(in-package :cl-user)"
         ""
         "(defun frobnicate (x)"
         "  \"A sample function, so the editor has real Lisp to colour and navigate.\""
         "  (let ((y (* x 2)))"
         "    (when (> y 10)"
         "      (format t \"~a is big~%\" y))"
         "    y))"
         ""
         "(defvar *sample* 42)"
         ""))

(defun sample-doc ()
  "A wired fake showing the sample file, activated, as the boot script
opens it: (values doc transport wire)."
  (multiple-value-bind (doc tr wire) (make-wired-fake *sample-text*)
    (setf (doc-path doc) "Clamacs:verify/realamiga/sample.lisp"
          (doc-name doc) "sample.lisp")
    (doc-activate doc)
    (values doc tr wire)))

(defmacro port (editor line)
  "The port's answer to LINE, as a list: (rc text)."
  `(multiple-value-list (port-command ,editor ,line)))

;;; --- the REPL window (repl.lisp): what test-repl and test-debugger start from

(defun repl-fixture ()
  "A wired fake source buffer (the cursor after a call), its REPL opened
with C-c C-z and attached: (values source repl transport wire)."
  (multiple-value-bind (doc tr wire) (make-wired-fake "(twice 21)|")
    (setf (doc-path doc) "T:intro.lisp"
          (doc-name doc) "intro.lisp")
    (doc-activate doc)
    (wire-find-port wire)
    (run-command doc 'clamacs-repl)
    (fake-answer-attach tr)
    (let ((repl (repl-doc (doc-editor doc))))
      (setf (fake-messages doc) '()
            (fake-messages repl) '())
      (values doc repl tr wire))))

(defun transcript (repl)
  "The REPL window's text with a `|' at the cursor."
  (fake-state repl))

(defun send-input (repl tr text)
  "Type TEXT at the prompt and RET, and answer the REPL-EVAL as clamiga
does at once (rc 0, no text)."
  (type-text repl text)
  (type-keys repl "RET")
  (is-equal (fake-last-sent tr) (concatenate 'string "REPL-EVAL " text))
  (fake-deliver tr 0 ""))
