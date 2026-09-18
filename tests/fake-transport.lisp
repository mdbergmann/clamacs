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
