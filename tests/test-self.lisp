;;;; test-self.lisp -- the wire to the editor's own Lisp (transport-self.lisp).
;;;;
;;;; Not a fake on the far side this time: the self transport runs the real
;;;; EXT.DEV commands and the real REPL thread of lib/dev-repl.lisp, in this
;;;; very process -- which IS the editor's image on the host, as it is on
;;;; the Amiga.  The one thing faked is the editor's task: the test thread
;;;; plays it, running what the worker and the REPL thread post through a
;;;; mailbox (SELF-PUMP), as the MUI task drains its own.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The editor's task, played by the test thread
;;; ------------------------------------------------------------------

(defstruct (self-box (:constructor make-self-box ()))
  (lock (mp:make-lock "test-self-box"))
  (items '())               ; posted, newest first
  (errors '()))             ; what a posted closure signalled

(defstruct (self-mail (:constructor make-self-mail (thunk)))
  thunk (done nil) (values nil))

(defun self-box-call (box)
  "The CALL function of a self transport whose editor's task is the test
thread: a waiting caller (the REPL thread) blocks until SELF-PUMP ran it."
  (lambda (thunk wait)
    (let ((mail (make-self-mail thunk)))
      (mp:with-lock-held ((self-box-lock box))
        (push mail (self-box-items box)))
      (when wait
        (loop until (mp:with-lock-held ((self-box-lock box)) (self-mail-done mail))
              do (sleep 0.005))
        (values-list (self-mail-values mail))))))

(defun self-drain (box)
  (let ((batch (mp:with-lock-held ((self-box-lock box))
                 (prog1 (reverse (self-box-items box))
                   (setf (self-box-items box) '())))))
    (dolist (mail batch)
      (let ((values (handler-case (multiple-value-list (funcall (self-mail-thunk mail)))
                      (error (e)
                        (push (princ-to-string e) (self-box-errors box))
                        (list +rc-fatal+ "ERROR: the posted closure failed")))))
        (mp:with-lock-held ((self-box-lock box))
          (setf (self-mail-values mail) values
                (self-mail-done mail) t))))))

;;; Generous: under CLAMIGA_GC_STRESS every allocation compacts, and the
;;; REPL thread compiles each form it is given.
(defparameter *self-wait-seconds* 300)

(defun self-pump (box predicate)
  "Be the editor's task until PREDICATE holds: true, or NIL on timeout."
  (let ((deadline (+ (get-universal-time) *self-wait-seconds*)))
    (loop
      (self-drain box)
      (when (funcall predicate)
        (return t))
      (when (> (get-universal-time) deadline)
        (return nil))
      (sleep 0.01))))

(defun self-stop (box wire)
  "Stop WIRE's self transport (and its REPL thread) while still playing the
editor's task: the REPL thread may be waiting on it to take a RESULT."
  (let ((tr (wire-self wire)))
    (when tr
      (let ((thread (mp:make-thread (lambda () (self-transport-stop tr))
                                    :name "test-self-stop")))
        (self-pump box (lambda () (not (mp:thread-alive-p thread))))))))

(defmacro with-self ((doc tr wire box) &body body)
  "A wired fake source buffer on a fake clamiga (TR, found on CLAMIGA), and
BOX standing in for the editor's task of the self transport that
`clamacs-connect-self' makes.  Everything is stopped afterwards."
  `(multiple-value-bind (,doc ,tr ,wire) (make-wired-fake "(twice 21)|")
     (declare (ignorable ,tr))
     (let* ((,box (make-self-box))
            (*self-transport-maker*
              (lambda (editor) (make-self-transport editor (self-box-call ,box)))))
       (setf (doc-path ,doc) "T:self.lisp"
             (doc-name ,doc) "self.lisp")
       (doc-activate ,doc)
       (wire-find-port ,wire)
       (unwind-protect (progn ,@body)
         (self-stop ,box ,wire)
         (is-equal (self-box-errors ,box) '())))))

(defun repl-idle-p (editor)
  "The REPL window shows its prompt: nothing is running."
  (let ((repl (repl-doc editor)))
    (and repl (repl-window-input-start (doc-repl repl)) t)))

(defun self-repl (doc box)
  "Open the REPL window on the self wire and wait for its prompt: the REPL."
  (let ((editor (doc-editor doc)))
    (run-command doc 'clamacs-repl)
    (is (self-pump box (lambda () (and (repl-session-attached (repl-session editor))
                                       (repl-idle-p editor)))))
    (repl-doc editor)))

(defun self-input (repl box text)
  "Type TEXT at the self REPL's prompt, RET, and wait for the next prompt."
  (type-text repl text)
  (type-keys repl "RET")
  (is (self-pump box (lambda () (repl-idle-p (doc-editor repl))))))

;;; A variable only the REPL thread writes: the proof that its forms run in
;;; the editor's own image and not in some other process.
(defvar *self-test-probe* nil)

;;; ------------------------------------------------------------------
;;; Switching
;;; ------------------------------------------------------------------

(deftest connect-self-switches-the-wire-and-back
  (with-self (doc tr wire box)
    (is (not (wire-self-p wire)))
    (run-command doc 'clamacs-connect-self)
    ;; Nothing was in flight and no REPL attached: at once.
    (is (wire-self-p wire))
    (is (wire-connected wire))
    (is-equal (wire-port-name wire) "the editor itself")
    (is-equal (fake-last-message doc) "Now talking to the editor itself")
    ;; Again: said so, nothing changes.
    (run-command doc 'clamacs-connect-self)
    (is-equal (fake-last-message doc) "Already talking to the editor itself")
    ;; A request goes to the editor's own EXT.DEV and its reply comes back
    ;; through the editor's task.
    (run-command doc 'clamacs-connect)
    (is (self-pump box (lambda () (wire-version wire))))
    (is (search (lisp-implementation-type) (wire-version wire)))
    (is-equal (fake-transport-sent tr) '())
    ;; And back: clamiga's transport, found on its port again.
    (run-command doc 'clamacs-connect-clamiga)
    (is (not (wire-self-p wire)))
    (is (eq (wire-transport wire) (wire-home wire)))
    (is-equal (wire-port-name wire) "CLAMIGA")
    (is (null (wire-version wire)))
    (is-equal (fake-last-message doc) "Now talking to CLAMIGA")
    (run-command doc 'clamacs-connect-clamiga)
    (is-equal (fake-last-message doc) "Already talking to clamiga")))

(deftest connect-self-without-a-maker-says-so
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore tr))
    (let ((*self-transport-maker* nil))
      (run-command doc 'clamacs-connect-self)
      (is-equal (fake-last-message doc) "This editor cannot talk to its own Lisp")
      (is (not (wire-self-p wire))))))

(deftest a-switch-waits-for-the-reply-in-flight
  (with-self (doc tr wire box)
    ;; A request to clamiga is out when the switch is asked for.
    (run-command doc 'clamacs-connect)
    (is-equal (fake-last-sent tr) "VERSION")
    (run-command doc 'clamacs-connect-self)
    (is (not (wire-self-p wire)))
    (is-equal (fake-last-message doc) "Switching to the editor itself ...")
    ;; A second switch while the first waits is refused.
    (run-command doc 'clamacs-connect-clamiga)
    (is-equal (fake-last-message doc) "A switch is already under way")
    ;; The reply goes to the side that was asked; then the switch.
    (fake-deliver tr 0 "clamiga 0.11 on AmigaOS")
    (is (wire-self-p wire))
    (is (null (wire-version wire)))))

(deftest switching-with-the-repl-attached-detaches-and-reattaches
  (multiple-value-bind (doc repl tr wire) (repl-fixture)
    (let* ((box (make-self-box))
           (editor (doc-editor doc))
           (*self-transport-maker*
             (lambda (editor) (make-self-transport editor (self-box-call box)))))
      (unwind-protect
           (progn
             ;; clamiga's REPL thread is told to stop before anything moves.
             (run-command doc 'clamacs-connect-self)
             (is-equal (fake-last-sent tr) "REPL-DETACH")
             (is (not (wire-self-p wire)))
             (fake-deliver tr 0 "REPL detached")
             ;; Switched: the transcript says so and the REPL attaches to
             ;; the editor itself.
             (is (wire-self-p wire))
             (is (search "; Now talking to the editor itself" (transcript repl)))
             (is (self-pump box (lambda () (and (repl-session-attached (repl-session editor))
                                                (repl-idle-p editor)))))
             (is (search "; REPL attached to the editor itself" (transcript repl)))
             ;; And back: the self REPL thread is detached, clamiga's attached.
             (run-command doc 'clamacs-connect-clamiga)
             (is (self-pump box (lambda () (not (wire-self-p wire)))))
             (is (not (self-repl-running-p)))
             (fake-answer-attach tr)
             (is (repl-session-attached (repl-session editor)))
             (is (search "; Now talking to CLAMIGA" (transcript repl))))
        (self-stop box wire)
        (is-equal (self-box-errors box) '())))))

(deftest switching-back-to-a-clamiga-that-is-gone
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    (setf (fake-transport-port tr) nil)
    (run-command doc 'clamacs-connect-clamiga)
    (is (not (wire-self-p wire)))
    (is (not (wire-connected wire)))
    (is (search "not running" (fake-last-message doc)))))

;;; ------------------------------------------------------------------
;;; The REPL in the editor's own image
;;; ------------------------------------------------------------------

(deftest the-self-repl-evaluates-in-the-editors-image
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    (let ((repl (self-repl doc box)))
      (is repl)
      (is (search "REPL attached to the editor itself" (transcript repl)))
      (is-equal (fake-last-sent tr) nil)   ; nothing went to clamiga
      (self-input repl box "(+ 1 2)")
      (is (search (lines "(+ 1 2)" "3" "CL-USER> ") (transcript repl)))
      ;; The same image: the REPL thread's SETQ is this process's variable.
      (setf *self-test-probe* nil)
      (self-input repl box "(setq clamacs::*self-test-probe* 42)")
      (is-equal *self-test-probe* 42)
      ;; ROOM reports this heap, streamed into the transcript.
      (self-input repl box "(room)")
      (is (search "Heap:" (transcript repl)))
      ;; IN-PACKAGE moves the prompt, as on clamiga.
      (self-input repl box "(in-package :clamacs)")
      (is (search "CLAMACS> " (transcript repl)))
      (self-input repl box "(in-package :cl-user)"))))

(deftest a-self-repl-error-opens-the-debugger
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    (let* ((repl (self-repl doc box))
           (editor (doc-editor repl)))
      (type-text repl "(car 1)")
      (type-keys repl "RET")
      (is (self-pump box (lambda () (debugger-active-p editor))))
      (run-command repl 'clamacs-debugger-abort)
      (is (self-pump box (lambda () (and (not (debugger-active-p editor))
                                         (repl-idle-p editor)))))
      (is (search "; Aborted" (transcript repl))))))

(deftest a-buffer-eval-runs-on-the-self-repl
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    (setf *self-test-probe* nil)
    (doc-set-text doc "(setq clamacs::*self-test-probe* :from-buffer)")
    (doc-set-point doc (doc-end doc))
    (run-command doc 'clamacs-eval-last-sexp)
    (is (self-pump box (lambda () (eq *self-test-probe* :from-buffer))))
    (is (self-pump box (lambda () (equal (fake-last-message doc) ":FROM-BUFFER"))))))

(deftest in-editor-runs-on-the-editors-task
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    (let ((repl (self-repl doc box)))
      ;; The REPL thread is not the editor's task; IN-EDITOR's body is,
      ;; and what it prints comes back into the transcript.
      (setf *self-test-probe* (mp:current-thread))
      (self-input repl box "(eq (mp:current-thread) clamacs::*self-test-probe*)")
      (is (search (lines "(eq (mp:current-thread) clamacs::*self-test-probe*)" "NIL")
                  (transcript repl)))
      (self-input repl box
                  "(clamacs:in-editor (princ \"on the task\") (eq (mp:current-thread) clamacs::*self-test-probe*))")
      (is (search (lines "on the task" "T") (transcript repl)))
      ;; Several values come back as they were.
      (self-input repl box "(clamacs:in-editor (values 1 2))")
      (is (search (lines "1" "2" "CL-USER> ") (transcript repl)))
      ;; An error on the task reaches the REPL's debugger.
      (type-text repl "(clamacs:in-editor (error \"boom\"))")
      (type-keys repl "RET")
      (is (self-pump box (lambda () (debugger-active-p (doc-editor repl)))))
      (run-command repl 'clamacs-debugger-abort)
      (is (self-pump box (lambda () (repl-idle-p (doc-editor repl)))))))
  ;; Without a self transport (and on the task itself) it simply runs.
  (let ((*self-transport* nil))
    (is-equal (multiple-value-list (in-editor (values :a :b))) '(:a :b))))

;;; ------------------------------------------------------------------
;;; Introspection and LASTRESULT
;;; ------------------------------------------------------------------

(deftest introspection-asks-the-editors-image
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    ;; DESCRIBE of one of the editor's own functions.
    (wire-request wire doc :describe "DESCRIBE clamacs::wire-swap")
    (is (self-pump box (lambda () (find "*clamacs-description*" (editor-documents (doc-editor doc))
                                        :key #'doc-name :test #'string=))))
    (let ((window (find "*clamacs-description*" (editor-documents (doc-editor doc))
                        :key #'doc-name :test #'string=)))
      (is (search "WIRE-SWAP" (doc-text window 0 (doc-end window)))))))

(deftest a-failing-command-fetches-its-text-from-the-self-transport
  (with-self (doc tr wire box)
    (run-command doc 'clamacs-connect-self)
    ;; ARexx drops RESULT on a failure, so the wire asks LASTRESULT next:
    ;; this transport answers it from its own last reply.
    (wire-request wire doc :describe "DESCRIBE no-such-package-xyz::foo")
    (is (self-pump box (lambda () (and (null (wire-inflight wire)) (null (wire-queue wire))))))
    (is-equal (subseq (first (wire-sent wire)) 0 10) "LASTRESULT")
    (is (search "ERROR" (fake-last-message doc)))))

;;; ------------------------------------------------------------------
;;; The menu and the memory report
;;; ------------------------------------------------------------------

(deftest the-menu-follows-the-side-the-wire-talks-to
  (with-self (doc tr wire box)
    (let ((editor (doc-editor doc)))
      (is (menu-item-enabled-p editor (menu-find 'clamacs-connect-self)))
      (is (not (menu-item-enabled-p editor (menu-find 'clamacs-connect-clamiga))))
      (menu-pick editor (menu-find 'clamacs-connect-self))
      (is (wire-self-p wire))
      (is (not (menu-item-enabled-p editor (menu-find 'clamacs-connect-self))))
      (is (menu-item-enabled-p editor (menu-find 'clamacs-connect-clamiga)))
      (menu-pick editor (menu-find 'clamacs-connect-clamiga))
      (is (not (wire-self-p wire))))))

(deftest clamacs-room-shows-the-editors-heap
  (let* ((doc (make-fake "|"))
         (editor (doc-editor doc)))
    (run-command doc 'clamacs-room)
    (let ((window (find "*clamacs-room*" (editor-documents editor)
                        :key #'doc-name :test #'string=)))
      (is window)
      (let ((text (doc-text window 0 (doc-end window))))
        (is (search "The editor's own Lisp heap (ROOM):" text))
        (is (search "Heap:" text))
        ;; The fake frontend knows no system memory: no such section.
        (is (not (search "System memory:" text)))))
    (is (menu-find 'clamacs-room))))

(defmethod editor-memory-lines ((editor (eql :test-memory)))
  (list "Free: 1 byte"))

(deftest room-text-lists-the-system-memory-when-the-frontend-knows-it
  (let ((text (room-text :test-memory)))
    (is (search (lines "System memory:" "  Free: 1 byte") text))))
