;;;; test-introspect.lisp -- what the editor asks clamiga about a symbol, on
;;;; the fake frontend and the fake transport: the phase-2 leg of
;;;; verify/realamiga/drive.rexx, request by request, plus what only a host
;;;; test can check (the cache, the idle timer's discipline, a lost port).

(in-package :clamacs)

;;; intro.lisp, as the drive loads it: TWICE on line 3 (1-based), the
;;; call on line 7.
(defparameter *intro-text*
  (lines "(in-package :cl-user)"
         ""
         "(defun twice (n)"
         "  \"Twice N.\""
         "  (* n 2))"
         ""
         "(twice 21)"
         "(twice-of 4)"
         ""))

(defun intro-doc (&key (point 0) (port "CLAMIGA"))
  "A wired fake showing intro.lisp, active, the cursor at POINT.  The
editor has found clamiga's port already, as it has by the time the drive
reaches this leg (the idle timer scans for one only now and then)."
  (multiple-value-bind (doc tr wire) (make-wired-fake *intro-text* :port port)
    (setf (doc-path doc) "T:intro.lisp"
          (doc-name doc) "intro.lisp")
    (doc-activate doc)
    (doc-set-point doc point)
    (wire-find-port wire)
    (setf (fake-messages doc) '())
    (values doc tr wire)))

(defun sent-package-p (tr)
  "Whether the command on the wire is the IN-PACKAGE a first request is
preceded by -- spelled as the buffer's (in-package ...) spells it."
  (string-equal (fake-last-sent tr) "IN-PACKAGE CL-USER"))

(defun deliver-package (tr)
  (is (sent-package-p tr))
  (fake-deliver tr 0 "Package is now CL-USER"))

(defun line-start (doc y)
  (doc-line-index doc y))

;;; The cursor inside `(twice 2|1)': line 6, column 8.
(defun inside-twice-call (doc)
  (+ (line-start doc 6) 8))

;;; --- what is at point --------------------------------------------------------

(deftest symbol-and-operator-at-point
  (let ((doc (intro-doc)))
    (doc-set-point doc (inside-twice-call doc))
    (is-equal (operator-at-point doc) "twice")
    (multiple-value-bind (sym start end) (symbol-at-point doc)
      (is-equal sym "21")
      (is-equal (doc-text doc start end) "21"))
    ;; `(|twice 21)': the symbol under the cursor is what `M-.' takes; the
    ;; operator is not answered while the cursor sits in the head atom,
    ;; which is still being typed for all the scanner knows.
    (doc-set-point doc (1+ (line-start doc 6)))
    (is-equal (symbol-at-point doc) "twice")
    (is (null (operator-at-point doc)))
    (doc-set-point doc (+ 6 (line-start doc 6)))
    (is-equal (operator-at-point doc) "twice")
    ;; On the blank line: nothing.
    (doc-set-point doc (line-start doc 5))
    (is (null (symbol-at-point doc)))
    (is (null (operator-at-point doc)))))

(deftest form-at-point-three-ways
  (let ((doc (intro-doc)))
    ;; Starting here.
    (doc-set-point doc (line-start doc 7))
    (is-equal (form-at-point doc) "(twice-of 4)")
    ;; Just closed before point.
    (doc-set-point doc (+ (line-start doc 7) 12))
    (is-equal (form-at-point doc) "(twice-of 4)")
    ;; Around point.
    (doc-set-point doc (+ (line-start doc 7) 5))
    (is-equal (form-at-point doc) "(twice-of 4)")
    ;; A quoted form starts at the quote.
    (let ((doc (make-fake "|'(a b)")))
      (is-equal (form-at-point doc) "'(a b)"))
    (let ((doc (make-fake "|")))
      (is (null (form-at-point doc))))
    (let ((doc (make-fake "(a |")))
      (is (null (form-at-point doc))))))

;;; --- the arglist ---------------------------------------------------------------

(deftest arglist-is-asked-shown-echoed-and-cached
  (multiple-value-bind (doc tr wire) (intro-doc)
    (doc-set-point doc (inside-twice-call doc))
    (run-command doc 'clamacs-arglist)
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "ARGLIST twice")
    (fake-deliver tr 0 "(n)")
    ;; The status line and the echo area both show it, with the operator
    ;; in front, as the user sees it.
    (is-equal (fake-arglist doc) "(twice n)")
    (is-equal (fake-last-message doc) "(twice n)")
    (is-equal (symcache-get (editor-arglists (doc-editor doc)) "CL-USER|twice") "(n)")
    ;; Asked again: answered from the cache, nothing on the wire.
    (setf (fake-messages doc) '())
    (run-command doc 'clamacs-arglist)
    (is-equal (fake-last-message doc) "(twice n)")
    (is-equal (length (fake-sent-commands tr)) 2)
    (is (null (wire-inflight wire)))))

(deftest arglist-rendering
  (is-equal (render-arglist "foo" "(a &optional b)") "(foo a &optional b)")
  (is-equal (render-arglist "foo" "()") "(foo)")
  (is-equal (render-arglist "if" "(test then &optional else)") "(if test then &optional else)")
  (is-equal (render-arglist "foo" "not a list") "foo: not a list"))

(deftest arglist-without-an-operator
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (line-start doc 5))
    (run-command doc 'clamacs-arglist)
    (is-equal (fake-last-message doc) "No operator at point")
    (is-equal (fake-beeps doc) 1)
    (is (null (fake-transport-sent tr)))))

(deftest a-miss-is-remembered-and-reported
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (inside-twice-call doc))
    (run-command doc 'clamacs-arglist)
    (deliver-package tr)
    ;; rc 10: the text comes through LASTRESULT, and the miss is kept.
    (fake-deliver tr 10 "")
    (is-equal (fake-last-sent tr) "LASTRESULT")
    (fake-deliver tr 0 "ERROR: twice names no function, macro or special operator")
    (is-equal (fake-last-message doc) "ERROR: twice names no function, macro or special operator")
    (is-equal (fake-beeps doc) 1)
    (is-equal (fake-arglist doc) "")
    (is-equal (symcache-get (editor-arglists (doc-editor doc)) "CL-USER|twice") "")
    (run-command doc 'clamacs-arglist)
    (is-equal (fake-last-message doc) "No arglist for twice")
    (is-equal (fake-beeps doc) 2)
    (is-equal (length (fake-sent-commands tr)) 3)))

(deftest the-idle-timer-asks-once-the-cursor-has-rested
  (multiple-value-bind (doc tr wire) (intro-doc)
    (doc-set-point doc (inside-twice-call doc))
    ;; First tick: the cursor has just arrived -- still moving.  A tick
    ;; that looks nothing up says so with NIL: the MUI frontend runs its
    ;; menu update only on a tick that answers T, and keeps its timer up
    ;; only while ARGLIST-IDLE-PENDING-P says a tick could still look.
    (is (arglist-idle-pending-p doc))
    (is (null (arglist-idle doc)))
    (is (null (fake-transport-sent tr)))
    (is (arglist-idle-pending-p doc))
    ;; Second tick at the same place: asked, quietly.
    (is (eq (arglist-idle doc) t))
    (is (null (arglist-idle-pending-p doc)))
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "ARGLIST twice")
    (is (null (fake-messages doc)))
    ;; One question at a time: further ticks send nothing, and the place
    ;; counts as looked at while the answer is on its way.
    (is (null (arglist-idle doc)))
    (arglist-idle doc)
    (is-equal (length (fake-sent-commands tr)) 2)
    (fake-deliver tr 0 "(n)")
    (is-equal (fake-arglist doc) "(twice n)")
    ;; Settled: no tick asks again at this place, and none does anything.
    (is (null (arglist-idle doc)))
    (is (null (arglist-idle doc)))
    (is-equal (length (fake-sent-commands tr)) 2)
    (is (null (arglist-idle-pending-p doc)))
    ;; An edit, or a cursor somewhere else, is work for a tick again.
    (note-text-changed doc)
    (is (arglist-idle-pending-p doc))
    (arglist-idle doc)
    (is (null (arglist-idle-pending-p doc)))
    (doc-set-point doc (1+ (doc-point doc)))
    (is (arglist-idle-pending-p doc))
    (doc-set-point doc (1- (doc-point doc)))
    ;; Moved within the same call: the operator is the one shown, so the
    ;; lookup ends before the cache.
    (doc-set-point doc (1+ (inside-twice-call doc)))
    (arglist-idle doc)
    (arglist-idle doc)
    (is-equal (length (fake-sent-commands tr)) 2)
    (is-equal (fake-arglist doc) "(twice n)")
    ;; Out of every form: the status line is cleared.
    (doc-set-point doc (line-start doc 5))
    (arglist-idle doc)
    (arglist-idle doc)
    (is-equal (fake-arglist doc) "")
    ;; Back inside: from the cache.
    (doc-set-point doc (inside-twice-call doc))
    (arglist-idle doc)
    (arglist-idle doc)
    (is-equal (fake-arglist doc) "(twice n)")
    (is-equal (length (fake-sent-commands tr)) 2)
    (is (null (wire-inflight wire)))))

(deftest the-idle-timer-looks-again-after-an-edit
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (inside-twice-call doc))
    (arglist-idle doc)
    (arglist-idle doc)
    (deliver-package tr)
    (fake-deliver tr 0 "(n)")
    ;; The operator is retyped under the resting cursor: `(thrice 2|1)'.
    (let ((start (line-start doc 6)))
      (doc-delete doc (1+ start) (+ start 6))
      (doc-set-point doc (1+ start))
      (doc-insert doc "thrice")
      (doc-set-point doc (+ start 9)))
    (note-text-changed doc)
    (arglist-idle doc)
    (arglist-idle doc)
    (is-equal (fake-last-sent tr) "ARGLIST thrice")
    (fake-deliver tr 0 "(a b)")
    (is-equal (fake-arglist doc) "(thrice a b)")))

(deftest the-idle-timer-never-prompts-and-is-quiet-elsewhere
  ;; No port: nothing goes out and nobody is asked to start clamiga.
  (multiple-value-bind (doc tr wire) (intro-doc :port nil)
    (doc-set-point doc (inside-twice-call doc))
    (dotimes (i 20) (arglist-idle doc))
    (is (null (fake-transport-sent tr)))
    (is (null (fake-asked doc)))
    (is (null (fake-messages doc)))
    ;; The port appears: found on one of the sparse ticks, asked.
    (setf (fake-transport-port tr) "CLAMIGA")
    (dotimes (i 8) (arglist-idle doc))
    (is (sent-package-p tr))
    (is (wire-connected wire))
    (is-equal (fake-last-message doc) "clamiga found on CLAMIGA"))
  ;; A prompt open, another window active, a non-Lisp buffer: no lookup.
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (inside-twice-call doc))
    (type-keys doc "M-x")
    (dotimes (i 3) (arglist-idle doc))
    (is (null (fake-transport-sent tr)))
    (type-keys doc "C-g")
    (let ((other (open-document (doc-editor doc) nil)))
      (doc-activate other)
      (dotimes (i 3) (arglist-idle doc))
      (is (null (fake-transport-sent tr)))
      (close-document other nil))
    (set-lisp-mode doc nil)
    (dotimes (i 3) (arglist-idle doc))
    (is (null (fake-transport-sent tr)))
    (set-lisp-mode doc t)
    (dotimes (i 2) (arglist-idle doc))
    (is (sent-package-p tr))))

(deftest a-lost-port-frees-the-idle-lookup
  (multiple-value-bind (doc tr wire) (intro-doc)
    (doc-set-point doc (inside-twice-call doc))
    (arglist-idle doc)
    (arglist-idle doc)
    (is-equal (intro-arglist-inflight (doc-intro doc)) 1)
    (fake-deliver tr 20 "no such port" :lost t)
    (is (not (wire-connected wire)))
    ;; The reply will never come; the next connection asks afresh.
    (arglist-idle doc)
    (is-equal (intro-arglist-inflight (doc-intro doc)) 0)
    (dotimes (i 8) (arglist-idle doc))
    (is (sent-package-p tr))))

(deftest a-late-arglist-reply-is-cached-but-not-shown
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (inside-twice-call doc))
    (arglist-idle doc)
    (arglist-idle doc)
    (deliver-package tr)
    ;; The cursor left the call before the answer came.
    (doc-set-point doc (line-start doc 5))
    (arglist-idle doc)
    (arglist-idle doc)
    (fake-deliver tr 0 "(n)")
    (is-equal (fake-arglist doc) "")
    (is-equal (symcache-get (editor-arglists (doc-editor doc)) "CL-USER|twice") "(n)")))

(deftest loading-a-file-forgets-the-arglist
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (inside-twice-call doc))
    (run-command doc 'clamacs-arglist)
    (deliver-package tr)
    (fake-deliver tr 0 "(n)")
    (is-equal (fake-arglist doc) "(twice n)")
    (let ((path (temp-file "other.lisp" (lines "(defun other ())" ""))))
      (load-file doc path)
      (is-equal (fake-arglist doc) "")
      (delete-file path))))

;;; --- completion ------------------------------------------------------------------

(deftest a-sole-completion-goes-into-the-buffer
  (multiple-value-bind (doc tr wire) (make-wired-fake "twice-a|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "COMPLETE twice-a")
    (is-equal (fake-last-message doc) "Completing twice-a ...")
    (fake-deliver tr 0 "twice-again")
    (is-equal (fake-state doc) "twice-again|")
    (is-equal (fake-last-message doc) "[Sole completion]")
    (is (null (fake-prompt doc)))))

(deftest only-the-part-before-point-is-the-prefix
  (multiple-value-bind (doc tr wire) (make-wired-fake "(twi|ce)")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "COMPLETE twi")
    (fake-deliver tr 0 "twinkle")
    (is-equal (fake-state doc) "(twinkle|ce)")))

(deftest ambiguous-completions-hand-over-to-the-minibuffer
  (multiple-value-bind (doc tr wire) (make-wired-fake "twic|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 (lines "twice" "twice-again" "twice-of"))
    ;; The common prefix is the input; the buffer is untouched.
    (is-equal (fake-prompt doc) "Complete: twice")
    (is-equal (fake-state doc) "twic|")
    ;; TAB lists them, from the candidates on hand, nothing on the wire.
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[3 completions: twice twice-again twice-of]")
    (is-equal (fake-mini-text doc) "twice")
    (is-equal (length (fake-sent-commands tr)) 2)
    ;; Narrowed to one.
    (type-text doc "-a")
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[Sole completion]")
    (is-equal (fake-mini-text doc) "twice-again")
    ;; RET puts it in the buffer, in place of the prefix.
    (type-keys doc "RET")
    (is-equal (fake-state doc) "twice-again|")
    (is (null (fake-prompt doc)))))

(deftest candidates-that-only-contain-the-input-leave-it-as-typed
  ;; No symbol starts with `foo-': clamiga answers the ones that contain
  ;; it.  The minibuffer opens on the input as typed, TAB lists them
  ;; without moving it, narrowing to one completes to that one, and the
  ;; candidates on hand cover what is typed after them.
  (multiple-value-bind (doc tr wire) (make-wired-fake "(foo-|)")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "COMPLETE foo-")
    (fake-deliver tr 0 (lines "get-foo-b" "make-foo-a"))
    (is-equal (fake-prompt doc) "Complete: foo-")
    (is-equal (fake-state doc) "(foo-|)")
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[2 completions: get-foo-b make-foo-a]")
    (is-equal (fake-mini-text doc) "foo-")
    (is-equal (length (fake-sent-commands tr)) 2)
    ;; TAB again cycles, as over prefix matches
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[1/2]get-foo-b")
    (type-keys doc "TAB TAB")
    (is-equal (fake-prompt doc) "[1/2]get-foo-b")
    ;; Back to the typed text, then narrowed to one: complete to it
    (type-keys doc "BS BS BS BS BS BS BS BS BS")
    (type-text doc "foo-a")
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[Sole completion]")
    (is-equal (fake-mini-text doc) "make-foo-a")
    (is-equal (length (fake-sent-commands tr)) 2)
    (type-keys doc "RET")
    (is-equal (fake-state doc) "(make-foo-a|)")))

(deftest a-sole-candidate-containing-the-input-goes-into-the-buffer
  (multiple-value-bind (doc tr wire) (make-wired-fake "foo-a|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 "make-foo-a")
    (is-equal (fake-state doc) "make-foo-a|")
    (is-equal (fake-last-message doc) "[Sole completion]")))

(deftest tab-again-cycles-through-the-symbol-candidates
  ;; The candidates clamiga sent are the minibuffer's to cycle through,
  ;; nothing more on the wire.
  (multiple-value-bind (doc tr wire) (make-wired-fake "twic|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 (lines "twice" "twice-again" "twice-of"))
    ;; The hand-over shows the prompt; the first TAB lists.
    (is-equal (fake-prompt doc) "Complete: twice")
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[3 completions: twice twice-again twice-of]")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[1/3]twice")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[2/3]twice-again")
    (type-keys doc "TAB TAB")
    (is-equal (fake-prompt doc) "[1/3]twice")
    (is-equal (length (fake-sent-commands tr)) 2)
    (type-keys doc "TAB RET")
    (is-equal (fake-state doc) "twice-again|")))

(deftest the-minibuffer-asks-again-when-the-candidates-do-not-cover
  (multiple-value-bind (doc tr wire) (make-wired-fake "twic|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 (lines "twice" "twice-again" "twice-of"))
    ;; Shortened below the prefix the candidates were fetched for.
    (type-keys doc "BS BS BS")
    (is-equal (fake-mini-text doc) "tw")
    (type-keys doc "TAB")
    (is-equal (fake-last-sent tr) "COMPLETE tw")
    (is-equal (fake-mini-label doc) "Completing tw ...")
    (fake-deliver tr 0 (lines "twice" "twice-again" "twice-of" "twist"))
    (is-equal (fake-mini-label doc) "[4 completions: twice twice-again twice-of twist]")
    (is-equal (fake-mini-text doc) "twi")
    ;; A miss.
    (type-text doc "zz")
    (type-keys doc "TAB")
    (is-equal (fake-mini-label doc) "[No match]")
    ;; Empty input just beeps.
    (type-keys doc "BS BS BS BS BS")
    (is-equal (fake-mini-text doc) "")
    (let ((beeps (fake-beeps doc)))
      (type-keys doc "TAB")
      (is-equal (fake-beeps doc) (1+ beeps)))
    (is-equal (length (fake-sent-commands tr)) 3)))

(deftest a-capped-candidate-list-does-not-cover-a-longer-input
  (multiple-value-bind (doc tr wire) (make-wired-fake "m|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 (format nil "~{m~D~^~%~}" (loop for i below +complete-cap+ collect i)))
    (is-equal (fake-prompt doc) "Complete: m")
    (is (intro-completions-capped (doc-intro doc)))
    (type-keys doc "TAB")
    ;; Many: the first few are listed, in clamiga's order.
    (is-equal (fake-mini-label doc) "[200 completions: m0 m1 m2 m3 m4 m5 m6 m7 ...]")
    (type-text doc "1")
    (type-keys doc "TAB")
    (is-equal (fake-last-sent tr) "COMPLETE m1")))

(deftest a-reply-for-an-abandoned-prompt-is-dropped
  (multiple-value-bind (doc tr wire) (make-wired-fake "twic|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 (lines "twice" "twice-again"))
    (type-keys doc "BS BS BS")
    (type-keys doc "TAB")
    (is-equal (fake-last-sent tr) "COMPLETE tw")
    (type-keys doc "C-g")
    (setf (fake-messages doc) '())
    (fake-deliver tr 0 (lines "twice" "twice-again"))
    (is (null (fake-prompt doc)))
    (is (null (fake-messages doc)))
    ;; And one that finds another prompt open.
    (type-keys doc "TAB")
    (is (null (fake-prompt doc)))
    (run-command doc 'complete-symbol)
    (fake-deliver tr 0 (lines "twice" "twice-again"))
    (is-equal (fake-prompt doc) "Complete: twice")
    (type-keys doc "BS BS BS TAB")
    (is-equal (fake-last-sent tr) "COMPLETE tw")
    (type-keys doc "C-g")
    (type-keys doc "M-x")
    (fake-deliver tr 0 (lines "twice" "twice-again"))
    (is-equal (fake-prompt doc) "M-x ")
    (type-keys doc "C-g")))

(deftest completion-with-nothing-before-point-and-with-no-match
  (multiple-value-bind (doc tr wire) (make-wired-fake "|twice")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (is-equal (fake-last-message doc) "No symbol before point")
    (is-equal (fake-beeps doc) 1)
    (is (null (fake-transport-sent tr))))
  (multiple-value-bind (doc tr wire) (make-wired-fake "zzz|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 0 "")
    (is-equal (fake-last-message doc) "[No match]")
    (is-equal (fake-beeps doc) 1)
    (is-equal (fake-state doc) "zzz|"))
  (multiple-value-bind (doc tr wire) (make-wired-fake "foo:b|")
    (declare (ignore wire))
    (run-command doc 'complete-symbol)
    (deliver-package tr)
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no such package: foo")
    (is-equal (fake-last-message doc) "ERROR: no such package: foo")
    (is-equal (fake-beeps doc) 1)))

;;; --- definitions -----------------------------------------------------------------

(deftest edit-definition-jumps-and-pop-comes-back
  (multiple-value-bind (doc tr wire) (intro-doc)
    (let ((from (1+ (line-start doc 6))))
      (doc-set-point doc from)
      (run-command doc 'clamacs-edit-definition)
      (deliver-package tr)
      (is-equal (fake-last-sent tr) "SOURCE-LOCATION twice")
      ;; The file is this one -- spelled as clamiga spells it.
      (fake-deliver tr 0 "t:INTRO.lisp:3")
      (is-equal (doc-point doc) (line-start doc 2))
      (is-equal (editor-active-document (doc-editor doc)) doc)
      (is-equal (locstack-depth (editor-locations (doc-editor doc))) 1)
      (run-command doc 'clamacs-pop-definition)
      (is-equal (doc-point doc) from)
      (is-equal (locstack-depth (editor-locations (doc-editor doc))) 0)
      (run-command doc 'clamacs-pop-definition)
      (is-equal (fake-last-message doc) "No previous definition")
      (is-equal (fake-beeps doc) 1)
      (is (null (wire-inflight wire))))))

(deftest edit-definition-opens-the-other-file
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (let ((path (temp-file "defs.lisp" (lines "(defun a ())" "(defun b ())" ""))))
      (doc-set-point doc (1+ (line-start doc 6)))
      (run-command doc 'clamacs-edit-definition)
      (deliver-package tr)
      (fake-deliver tr 0 (format nil "~A:2" path))
      (let ((target (editor-active-document (doc-editor doc))))
        (is (not (eq target doc)))
        (is-equal (doc-path target) path)
        (is-equal (doc-index-line target (doc-point target)) 1)
        ;; Back: the window that asked is still open.
        (run-command target 'clamacs-pop-definition)
        (is-equal (editor-active-document (doc-editor doc)) doc)
        ;; Closed meanwhile: the file is reopened.
        (run-command doc 'clamacs-edit-definition)
        (fake-deliver tr 0 (format nil "~A:1" path))
        (close-document doc nil)
        (let ((target (editor-active-document (doc-editor doc))))
          (run-command target 'clamacs-pop-definition)
          (let ((again (editor-active-document (doc-editor doc))))
            (is (not (eq again doc)))
            (is-equal (doc-path again) "T:intro.lisp"))))
      (delete-file path))))

(deftest edit-definition-without-a-location-or-a-symbol
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (1+ (line-start doc 6)))
    (run-command doc 'clamacs-edit-definition)
    (deliver-package tr)
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no source location recorded for twice")
    (is-equal (fake-last-message doc) "ERROR: no source location recorded for twice")
    (is-equal (fake-beeps doc) 1)
    (is-equal (locstack-depth (editor-locations (doc-editor doc))) 0)
    ;; An rc 0 reply that is not a location.
    (run-command doc 'clamacs-edit-definition)
    (fake-deliver tr 0 "")
    (is-equal (fake-last-message doc) "No source location for twice")
    ;; No symbol at point: asked for one.
    (doc-set-point doc (line-start doc 5))
    (run-command doc 'clamacs-edit-definition)
    (is-equal (fake-prompt doc) "Edit definition of: ")
    (type-text doc "twice-of")
    (type-keys doc "RET")
    (is-equal (fake-last-sent tr) "SOURCE-LOCATION twice-of")
    (fake-deliver tr 0 "T:intro.lisp:8")
    (is-equal (doc-point doc) (line-start doc 7))))

;;; --- describe, apropos, macroexpand ------------------------------------------------

(deftest describe-opens-a-scratch-window
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (1+ (line-start doc 6)))
    (run-command doc 'clamacs-describe-symbol)
    (is-equal (fake-prompt doc) "Describe symbol: twice")
    (type-keys doc "RET")
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "DESCRIBE twice")
    (fake-deliver tr 0 (lines "TWICE is a SYMBOL in CL-USER." "Function: #<function TWICE>"
                              "Documentation: Twice N."))
    (let ((out (editor-active-document (doc-editor doc))))
      (is (not (eq out doc)))
      (is-equal (doc-name out) "*clamacs-description*")
      (is (null (doc-path out)))
      (is (not (doc-lisp-mode out)))
      (is-equal (doc-point out) 0)
      (is (not (doc-modified-p out)))
      (is-equal (doc-lines-text out 2 2) "Documentation: Twice N.")
      ;; A second description reuses the window.
      (doc-activate doc)
      (run-command doc 'clamacs-describe-symbol)
      (type-keys doc "RET")
      (fake-deliver tr 0 "TWICE is a SYMBOL in CL-USER.")
      (is-equal (editor-active-document (doc-editor doc)) out)
      (is-equal (doc-text out 0 (doc-end out)) "TWICE is a SYMBOL in CL-USER.")
      (is-equal (length (live-documents (doc-editor doc))) 2))))

(deftest describe-of-nothing-and-of-an-error
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (line-start doc 5))
    (run-command doc 'clamacs-describe-symbol)
    (is-equal (fake-prompt doc) "Describe symbol: ")
    (type-keys doc "RET")
    (is-equal (fake-beeps doc) 1)
    (is (null (fake-transport-sent tr)))
    (run-command doc 'clamacs-describe-symbol)
    (type-text doc "nope")
    (type-keys doc "RET")
    (deliver-package tr)
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: no such symbol: nope")
    (is-equal (fake-last-message doc) "ERROR: no such symbol: nope")
    (is-equal (length (live-documents (doc-editor doc))) 1)))

(deftest apropos-lists-or-says-there-is-nothing
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (run-command doc 'clamacs-apropos)
    (is-equal (fake-prompt doc) "Apropos: ")
    (type-text doc "twice")
    (type-keys doc "RET")
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "APROPOS twice")
    (fake-deliver tr 0 "")
    (is-equal (fake-last-message doc) "No symbols matching \"twice\"")
    (is-equal (length (live-documents (doc-editor doc))) 1)
    (run-command doc 'clamacs-apropos)
    (type-text doc "twice")
    (type-keys doc "RET")
    (fake-deliver tr 0 (lines "twice function" "twice-of macro"))
    (let ((out (editor-active-document (doc-editor doc))))
      (is-equal (doc-name out) "*clamacs-apropos*")
      (is-equal (doc-lines-text out 1 1) "twice-of macro"))))

(deftest macroexpand-once-and-fully
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (line-start doc 7))
    (run-command doc 'clamacs-macroexpand-1)
    (deliver-package tr)
    (is-equal (fake-last-sent tr) "MACROEXPAND-1 (twice-of 4)")
    (fake-deliver tr 0 "(with-twice z 4 z)")
    (let ((out (editor-active-document (doc-editor doc))))
      (is-equal (doc-name out) "*clamacs-macroexpansion*")
      (is (doc-lisp-mode out))
      (is-equal (doc-text out 0 (doc-end out)) "(with-twice z 4 z)")
      ;; Coloured as Lisp: the number is a number.
      (is (member '(14 15 :number) (fake-line-colours out 0) :test #'equal))
      (doc-activate doc)
      (run-command doc 'clamacs-macroexpand)
      (is-equal (fake-last-sent tr) "MACROEXPAND (twice-of 4)")
      (fake-deliver tr 0 "(let ((z (twice 4))) z)")
      (is-equal (editor-active-document (doc-editor doc)) out)
      (is-equal (doc-text out 0 (doc-end out)) "(let ((z (twice 4))) z)"))
    ;; A multi-line form travels whole.
    (doc-set-point doc (line-start doc 2))
    (run-command doc 'clamacs-macroexpand-1)
    (is-equal (fake-last-sent tr)
              (format nil "MACROEXPAND-1 (defun twice (n)~%  \"Twice N.\"~%  (* n 2))"))
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: boom")
    (is-equal (fake-last-message doc) "ERROR: boom")
    ;; No form.
    (doc-set-point doc (line-start doc 5))
    (run-command doc 'clamacs-macroexpand-1)
    (is-equal (fake-last-message doc) "No form at point")))

(deftest a-text-reply-for-a-closed-window-still-opens-its-window
  (multiple-value-bind (doc tr wire) (intro-doc)
    (declare (ignore wire))
    (doc-set-point doc (line-start doc 7))
    (run-command doc 'clamacs-macroexpand-1)
    (deliver-package tr)
    (let ((other (open-document (doc-editor doc) nil)))
      (close-document doc nil)
      (fake-deliver tr 0 "(with-twice z 4 z)")
      (let ((out (editor-active-document (doc-editor doc))))
        (is (not (eq out other)))
        (is-equal (doc-name out) "*clamacs-macroexpansion*")))))

(deftest introspection-without-a-wire-says-so
  (let ((doc (make-fake "(twice 2|1)")))
    (dolist (command '(clamacs-arglist complete-symbol clamacs-edit-definition
                       clamacs-macroexpand-1))
      (run-command doc command)
      (is-equal (fake-last-message doc) "No connection to clamiga in this editor"))
    ;; The idle tick without a wire is silent.
    (dotimes (i 3) (arglist-idle doc))
    (is (null (fake-asked doc)))))

;;; --- the package, kept with where it came from -------------------------------

(defparameter *package-text*
  (lines "(in-package :alpha)"
         ""
         "(defun one ()"
         "  1)"
         ""
         "(in-package :beta)"
         ""
         "(defun two ()"
         "  2)"
         ""
         "(defun three ()"
         "  3)"
         ""))

(defun package-doc (&optional (y 8))
  "A fake showing *PACKAGE-TEXT*, the cursor at the start of line Y."
  (let ((doc (make-fake *package-text*)))
    (doc-set-point doc (doc-line-index doc y))
    doc))

(defun package-scans (doc)
  (intro-package-scans (doc-intro doc)))

(defun package-agrees-p (doc)
  "The cache's answer is the scanner's, wherever the cursor is."
  (string= (doc-package-cached doc) (doc-current-package doc)))

(defun type-at (doc y text)
  "TEXT inserted at the start of line Y and reported as the widget does."
  (doc-set-point doc (doc-line-index doc y))
  (doc-insert doc text)
  (note-text-changed doc))

(deftest package-is-scanned-once-while-nothing-changes-it
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 1)
    ;; asked again, here and elsewhere below the form that names it
    (is-equal (doc-package-cached doc) "beta")
    (doc-set-point doc (doc-line-index doc 7))
    (is-equal (doc-package-cached doc) "beta")
    ;; further down than it was scanned from: those lines are read, the
    ;; buffer is not
    (doc-set-point doc (doc-line-index doc 11))
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 1)))

(deftest package-follows-the-cursor-across-in-package-forms
  ;; The answer was once kept per edit alone: a cursor moved above the
  ;; form that named it went on answering that form's package.
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    (doc-set-point doc (doc-line-index doc 3))
    (is-equal (doc-package-cached doc) "alpha")
    (doc-set-point doc (doc-line-index doc 11))
    (is-equal (doc-package-cached doc) "beta")
    (doc-set-point doc 0)
    (is-equal (doc-package-cached doc) "CL-USER")
    ;; on the form's own line the scanner decides
    (doc-set-point doc (doc-line-index doc 5))
    (is (package-agrees-p doc))
    (doc-set-point doc (1- (doc-line-index doc 6)))
    (is-equal (doc-package-cached doc) "beta")))

(deftest package-survives-typing-that-does-not-touch-it
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    (type-at doc 8 "  (print 2)")
    (is-equal (doc-package-cached doc) "beta")
    ;; a new line: the buffer grew by one
    (doc-insert doc (string #\Newline))
    (note-text-changed doc)
    (type-at doc 9 "  (print 3)")
    (is-equal (doc-package-cached doc) "beta")
    ;; and a line above the cursor, below the form
    (type-at doc 7 ";; two")
    (doc-set-point doc (doc-line-index doc 9))
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 1)
    (is (package-agrees-p doc))))

(deftest package-sees-a-form-typed-between
  (let ((doc (package-doc 11)))
    (is-equal (doc-package-cached doc) "beta")
    (type-at doc 9 "(in-package :gamma)")
    (doc-set-point doc (doc-line-index doc 11))
    (is-equal (doc-package-cached doc) "gamma")
    (is-equal (package-scans doc) 2)))

(deftest package-sees-its-own-form-renamed-and-removed
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    ;; `:beta' becomes `:xbeta'
    (doc-set-point doc (+ (doc-line-index doc 5) 13))
    (doc-insert doc "x")
    (note-text-changed doc)
    (doc-set-point doc (doc-line-index doc 8))
    (is-equal (doc-package-cached doc) "xbeta")
    ;; the line killed whole, the report coming from the line that is
    ;; there now, which never mentioned it
    (doc-delete doc (doc-line-index doc 5) (doc-line-index doc 6))
    (doc-set-point doc (doc-line-index doc 5))
    (note-text-changed doc)
    (doc-set-point doc (doc-line-index doc 7))
    (is-equal (doc-package-cached doc) "alpha")))

(deftest package-sees-a-form-in-a-block-brought-in-above-the-cursor
  ;; A yank ends below what it brought in, and the report names the
  ;; cursor's line alone: the lines the buffer grew by are read too.
  (let ((doc (package-doc 11)))
    (is-equal (doc-package-cached doc) "beta")
    (doc-set-point doc (doc-line-index doc 9))
    (doc-insert doc (lines "(in-package :delta)" "" "(defun four ()" "  4)" ""))
    (note-text-changed doc)
    (is-equal (doc-package-cached doc) "delta")))

(deftest package-is-scanned-when-an-edit-above-moved-its-form
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    (type-at doc 2 (lines ";; one" ""))
    (doc-set-point doc (doc-line-index doc 10))
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 2)
    (is (package-agrees-p doc))))

(deftest package-is-scanned-when-an-edit-was-counted-and-not-reported
  ;; The MUI frontend counts an edit in its hook and reports the lines
  ;; when the keys rest: a lookup in between must not believe the cache.
  (let ((doc (package-doc 8)))
    (is-equal (doc-package-cached doc) "beta")
    (incf (doc-edit-serial doc))
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 2)
    (package-note-edit doc 8 8)
    (is-equal (doc-package-cached doc) "beta")
    (is-equal (package-scans doc) 2)))

(deftest sexp-mentions-in-package
  (is (sexp-mentions-in-package-p "  (IN-Package :x)"))
  (is (sexp-mentions-in-package-p ";; see in-package"))
  (is (null (sexp-mentions-in-package-p "(in-packag")))
  (is (null (sexp-mentions-in-package-p "")))
  (is (null (sexp-mentions-in-package-p "(defun in-pack age ())"))))
