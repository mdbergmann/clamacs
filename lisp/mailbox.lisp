;;;; mailbox.lisp -- only the editor's task touches the editor.
;;;;
;;;; The other threads -- the port's handler thread, the wire's client
;;;; thread, the self transport's worker, the REPL thread -- never call a
;;;; frontend method.  They post a closure here and the event loop runs it
;;;; between two inputs: a waiting caller (a port verb that needs the
;;;; answer) blocks until the loop has run its closure and takes its
;;;; values; a fire-and-forget one (a reply arriving from clamiga) just
;;;; posts.  Extracted from frontend-mui.lisp so the host frontend
;;;; (specs/clamacs-host.md) drains the same box from its own loop.
;;;;
;;;; What differs between frontends is a function each: WAKE, called after
;;;; a post so the loop stops waiting on the OS (an Exec signal under MUI,
;;;; webview_dispatch on the host); ON-ERROR, given the condition of a
;;;; fire-and-forget closure that failed; and AFTER-DRAIN, run once after
;;;; every non-empty drain, since a posted closure may have moved what the
;;;; menu shows.  Pure otherwise: MP locks and condition variables only.

(in-package :clamacs)

(defstruct (mail (:constructor make-mail (thunk wait)))
  thunk wait (done nil) (values nil))

(defstruct (mailbox (:constructor %make-mailbox))
  lock cv
  (items '())          ; newest first
  (closed nil)
  wake on-error after-drain)

(defun make-mailbox (&key wake on-error after-drain)
  (%make-mailbox :lock (mp:make-lock "clamacs-mailbox")
                 :cv (mp:make-condition-variable "clamacs-mailbox")
                 :wake wake :on-error on-error :after-drain after-drain))

(defun mailbox-post (box thunk &key (wait t))
  "From any thread: have the editor's task call THUNK.  With WAIT, block
until it has run and return its values; a closed box (the editor is
shutting down) answers rc 20 instead.  Without, post and return at once."
  (let ((lock (mailbox-lock box))
        (cv (mailbox-cv box))
        (mail (make-mail thunk wait)))
    (mp:with-lock-held (lock)
      (when (mailbox-closed box)
        (return-from mailbox-post
          (values +rc-fatal+ "ERROR: the editor is shutting down")))
      (push mail (mailbox-items box)))
    (when (mailbox-wake box)
      (funcall (mailbox-wake box)))
    (when wait
      (mp:with-lock-held (lock)
        (loop until (or (mail-done mail) (mailbox-closed box))
              do (mp:condition-wait cv lock 1)))
      (if (mail-done mail)
          (values-list (mail-values mail))
          (values +rc-fatal+ "ERROR: the editor is shutting down")))))

(defun mailbox-drain (box)
  "The editor's task: run everything posted since the last drain, batches
until the box is empty.  True when anything ran."
  (let ((lock (mailbox-lock box))
        (cv (mailbox-cv box))
        (ran nil))
    (loop
      (let ((batch (mp:with-lock-held (lock)
                     (prog1 (nreverse (mailbox-items box))
                       (setf (mailbox-items box) '())))))
        (when (null batch)
          (return ran))
        (setq ran t)
        (dolist (mail batch)
          (let ((values (handler-case (multiple-value-list (funcall (mail-thunk mail)))
                          (error (e)
                            (if (mail-wait mail)
                                (list +rc-fatal+
                                      (format nil "ERROR: ~A"
                                              (handler-case (princ-to-string e)
                                                (error () "(unprintable condition)"))))
                                (progn
                                  (when (mailbox-on-error box)
                                    (funcall (mailbox-on-error box) e))
                                  nil))))))
            (mp:with-lock-held (lock)
              (setf (mail-values mail) values
                    (mail-done mail) t)
              (mp:condition-broadcast cv))))
        (when (mailbox-after-drain box)
          (funcall (mailbox-after-drain box)))))))

(defun mailbox-close (box)
  "No more calls: every waiter is woken with the shutdown answer, and a
later post is refused."
  (when box
    (mp:with-lock-held ((mailbox-lock box))
      (setf (mailbox-closed box) t)
      (mp:condition-broadcast (mailbox-cv box)))))

;;; The editor's box: EDITOR-MAILBOX (frontend.lisp) is set by the
;;; frontend when its loop is about to run, and closed before it leaves.

(defun call-in-editor (editor thunk &key (wait t))
  "From any thread: have the editor's task call THUNK (see MAILBOX-POST).
An editor without a mailbox -- none running -- answers as a closed one."
  (let ((box (editor-mailbox editor)))
    (if box
        (mailbox-post box thunk :wait wait)
        (values +rc-fatal+ "ERROR: the editor is shutting down"))))
