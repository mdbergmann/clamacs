;;;; introspect.lisp -- what the editor asks clamiga about a symbol.
;;;;
;;;; Everything here is a question put to clamiga's port and a place for the
;;;; answer to land: the arglist of the operator at point goes to the status
;;;; line, completions go into the buffer or the minibuffer, a source
;;;; location moves the cursor, and DESCRIBE, APROPOS and MACROEXPAND open a
;;;; scratch window.  The questions are the six commands cl-amiga's
;;;; lib/dev-commands.lisp answers (ARGLIST, COMPLETE, SOURCE-LOCATION,
;;;; DESCRIBE, APROPOS, MACROEXPAND[-1]); the editor adds no logic of its
;;;; own to their replies beyond parsing a `file:line'.  This is the port
;;;; of src/introspect.c.
;;;;
;;;; Two rules from the wire carry over.  Nothing here waits for a reply:
;;;; each request has a continuation in INTRO-REPLY, reached from
;;;; WIRE-DISPATCH when the reply arrives.  And the idle timer never
;;;; prompts: a status-line lookup that found no clamiga port stays quiet,
;;;; where a command the user typed may offer to start one.
;;;;
;;;; The idle timer itself is the frontend's (a MUI input handler that
;;;; fires every 3/10 s); what it calls is ARGLIST-IDLE, so the tests tick
;;;; it by hand.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Per-document state
;;; ------------------------------------------------------------------

(defstruct (intro (:constructor make-intro ()))
  ;; The arglist in the status line.  The idle tick compares the cursor
  ;; and the edit serial with the ones the arglist was last worked out
  ;; for, so a resting cursor costs one comparison per tick.
  (arglist "")                ; shown, "" for none
  (arglist-op "")             ; the operator it is for
  (arglist-want "")           ; the operator at point, last looked
  (arglist-index nil)         ; the cursor ARGLIST-WANT was looked up at
  (arglist-serial -1)         ; the edit serial ditto
  (arglist-inflight 0)        ; quiet ARGLIST requests on the wire
  (idle-index nil)            ; the cursor a tick ago
  (idle-ticks 0)
  ;; The package the buffer is in, as of an edit serial: a lookup on
  ;; every cursor rest must not scan the whole buffer each time.
  (package nil)
  (package-serial -1)
  ;; Completion: the candidates clamiga sent, the prefix they were asked
  ;; for and whether the list was cut at clamiga's cap; the range of the
  ;; buffer a completion replaces; the minibuffer completer over them.
  (completions '())
  (completions-prefix "")
  (completions-capped nil)
  (complete-start 0)
  (complete-end 0)
  (completer nil))

(defun doc-intro (doc)
  (or (%doc-intro doc)
      (setf (%doc-intro doc) (make-intro))))

(defun doc-package-cached (doc)
  "The package the cursor's form is in, scanned once per edit."
  (let ((state (doc-intro doc))
        (serial (doc-edit-serial doc)))
    (unless (and (intro-package state) (= serial (intro-package-serial state)))
      (setf (intro-package state) (doc-current-package doc)
            (intro-package-serial state) serial))
    (intro-package state)))

;;; ------------------------------------------------------------------
;;; What is at point
;;; ------------------------------------------------------------------

(defun symbol-at-point (doc)
  "The symbol under or before the cursor: its text, and its start and end
as document indices, three values; or NIL."
  (multiple-value-bind (text base point) (doc-context doc)
    (when text
      (multiple-value-bind (s e) (sexp-symbol-at-point text point)
        (when s
          (values (subseq text s e) (+ base s) (+ base e)))))))

(defun operator-at-point (doc)
  "The head of the innermost code list around the cursor, or NIL."
  (multiple-value-bind (text base point) (doc-context doc)
    (declare (ignore base))
    (when text
      (multiple-value-bind (s e) (sexp-operator-at-point text point)
        (when s (subseq text s e))))))

(defun form-at-point (doc)
  "The form at point, as text: the one starting here, else the one just
closed before point, else the innermost one around it.  NIL when there is
none or it is unbalanced."
  (multiple-value-bind (text base point) (doc-context-full doc)
    (declare (ignore base))
    (when text
      (let* ((len (length text))
             (start (cond ((and (< point len)
                                (member (char text point) '(#\( #\' #\` #\# #\,)))
                           point)
                          ((and (> point 0) (char= (char text (1- point)) #\)))
                           (sexp-backward text point))
                          (t (sexp-up text point))))
             (stop (and start (sexp-forward text start))))
        (and stop (subseq text start stop))))))

(defun subject-arg (subject)
  "The argument of a command string: what follows the verb and one space,
or \"\" -- `ARGLIST foo' gives `foo'."
  (let ((space (position #\Space subject)))
    (if space (subseq subject (1+ space)) "")))

(defun ask (doc kind command)
  "Queue COMMAND on DOC's wire, in DOC's package.  The request, or NIL."
  (let ((wire (require-wire doc)))
    (when wire
      (wire-ensure-package wire doc (doc-package-cached doc))
      (wire-request wire doc kind command))))

;;; ------------------------------------------------------------------
;;; The arglist in the status line
;;; ------------------------------------------------------------------

(defun arglist-cache-key (package op)
  (format nil "~A|~A" package op))

(defun render-arglist (op reply)
  "`(a &optional b)' from clamiga becomes `(foo a &optional b)' on the
status line: the operator is what the user is looking at."
  (if (and (> (length reply) 0) (char= (char reply 0) #\())
      (format nil "(~A~A~A" op
              (if (and (> (length reply) 1) (char= (char reply 1) #\))) "" " ")
              (subseq reply 1))
      (format nil "~A: ~A" op reply)))

(defun show-arglist (doc op value)
  (let ((state (doc-intro doc)))
    (setf (intro-arglist-op state) op
          (intro-arglist state) (if (and value (string/= value ""))
                                    (render-arglist op value)
                                    ""))
    (doc-show-arglist doc (intro-arglist state))))

(defun clear-arglist (doc)
  "Take the arglist off the status line, if one is there."
  (let ((state (doc-intro doc)))
    (when (or (string/= (intro-arglist state) "")
              (string/= (intro-arglist-op state) ""))
      (setf (intro-arglist state) ""
            (intro-arglist-op state) "")
      (doc-show-arglist doc ""))))

(defun forget-arglist (doc)
  "The arglist shown belongs to a text that is gone: forget it, and let the
idle tick look again from scratch."
  (let ((state (%doc-intro doc)))
    (when state
      (clear-arglist doc)
      (setf (intro-arglist-want state) ""
            (intro-arglist-index state) nil
            (intro-idle-index state) nil
            (intro-package state) nil))))

(defun arglist-lookup (doc echo)
  "Put the arglist of the operator at point in the status line: from the
cache at once, else by asking clamiga.  ECHO is `M-x clamacs-arglist': the
answer is echoed too, and clamiga may be started for it.  True when the
status line is settled -- shown, cleared, or asked for; NIL when a quiet
lookup could not ask (no port known, one already in flight) and the idle
tick should try again."
  (let* ((state (doc-intro doc))
         (op (operator-at-point doc)))
    (cond
      ((null op)
       (setf (intro-arglist-want state) "")
       (clear-arglist doc)
       (when echo
         (doc-message doc "No operator at point")
         (doc-beep doc))
       t)
      (t
       (setf (intro-arglist-want state) op)
       (let* ((package (doc-package-cached doc))
              (cached (symcache-get (editor-arglists (doc-editor doc))
                                    (arglist-cache-key package op)))
              (wire (doc-wire doc)))
         (cond
           ;; Already showing it -- or already known to have none.
           ((and (not echo) (string= op (intro-arglist-op state)))
            t)
           (cached
            (show-arglist doc op cached)
            (when echo
              (cond ((string/= (intro-arglist state) "")
                     (doc-message doc (intro-arglist state)))
                    (t (message doc "No arglist for ~A" op)
                       (doc-beep doc))))
            t)
           ((not echo)
            ;; Quietly: never prompt, and one question at a time.
            (cond ((or (null wire)
                       (not (wire-ready-p wire))
                       (> (intro-arglist-inflight state) 0))
                   nil)
                  ((ask doc :arglist (format nil "ARGLIST ~A" op))
                   (incf (intro-arglist-inflight state))
                   t)
                  (t nil)))
           (t
            ;; The user asked: a declined launch ends it, quietly.
            (ask doc :arglist-echo (format nil "ARGLIST ~A" op))
            t)))))))

(defun arglist-reply (doc kind op rc text)
  (let ((state (doc-intro doc)))
    (when (and (eq kind :arglist) (> (intro-arglist-inflight state) 0))
      (decf (intro-arglist-inflight state)))
    (when (string/= op "")
      ;; A miss is remembered as "".
      (let ((value (if (= rc +rc-ok+) (first-line text) "")))
        (symcache-put (editor-arglists (doc-editor doc))
                      (arglist-cache-key (doc-package-cached doc) op)
                      value)
        ;; Still what the cursor is on?  The idle tick asks again otherwise.
        (when (string= op (intro-arglist-want state))
          (show-arglist doc op value))
        (when (eq kind :arglist-echo)
          (cond ((string/= value "")
                 (doc-message doc (render-arglist op value)))
                (t
                 (let ((line (first-line text)))
                   (doc-message doc (if (string/= line "") line "No arglist"))
                   (doc-beep doc)))))))))

(defun arglist-idle (doc)
  "One tick of the idle timer.  Once the cursor has rested for a tick in
the active Lisp window, and somewhere it has not been looked at since the
last edit, the arglist is looked up quietly."
  (let ((editor (doc-editor doc))
        (state (doc-intro doc)))
    (when (and (not (doc-closing doc))
               (doc-lisp-mode doc)
               (eq (editor-active-document editor) doc)
               (not (minibuffer-open-p doc)))
      (let ((idx (doc-point doc))
            (wire (editor-wire editor)))
        (cond ((not (eql idx (intro-idle-index state)))
               ;; Still moving: look again next tick.
               (setf (intro-idle-index state) idx))
              ((not (and wire (wire-connected wire)))
               ;; A reply that never came is not on the wire any more.
               (setf (intro-arglist-inflight state) 0)
               ;; Without a port every tick would scan for one; every
               ;; couple of seconds is plenty.
               (when (and (not (arglist-settled-p doc state idx))
                          (zerop (mod (incf (intro-idle-ticks state)) 8)))
                 (arglist-idle-lookup doc state idx)))
              ((not (arglist-settled-p doc state idx))
               (arglist-idle-lookup doc state idx)))))))

(defun arglist-settled-p (doc state idx)
  "Whether the arglist was looked up at IDX since the last edit."
  (and (eql idx (intro-arglist-index state))
       (= (doc-edit-serial doc) (intro-arglist-serial state))))

(defun arglist-idle-lookup (doc state idx)
  (when (arglist-lookup doc nil)
    (setf (intro-arglist-index state) idx
          (intro-arglist-serial state) (doc-edit-serial doc))))

(define-command clamacs-arglist (doc arg)
  (declare (ignore arg))
  (arglist-lookup doc t))

;;; ------------------------------------------------------------------
;;; Completion
;;; ------------------------------------------------------------------

(defconstant +complete-shown+ 8)
;;; ext.dev:*max-completions*: a reply this long may have been cut.
(defconstant +complete-cap+ 200)

(defun take-candidates (state prefix text)
  (let ((names (split-lines text)))
    (setf (intro-completions state) names
          (intro-completions-prefix state) prefix
          (intro-completions-capped state) (>= (length names) +complete-cap+))
    names))

(defun completions-cover-p (state text)
  "Whether the candidates on hand answer for TEXT: they were fetched for a
prefix of it, and the list was not cut short by clamiga's cap (past the
cap a longer prefix may match symbols that were never sent)."
  (let ((prefix (intro-completions-prefix state)))
    (and (> (length prefix) 0)
         (prefix-p (coerce prefix 'simple-string) (coerce text 'simple-string))
         (not (and (intro-completions-capped state)
                   (> (length text) (length prefix)))))))

(defun completions-message (matches)
  "`[3 completions: a b c]', the first few by name -- the symbol
completions come from clamiga and the user cannot see the list."
  (let ((n (length matches)))
    (format nil "[~D completions:~{ ~A~}~A]" n
            (subseq matches 0 (min n +complete-shown+))
            (if (> n +complete-shown+) " ..." ""))))

(defun apply-candidates (doc state text)
  "Complete TEXT in the minibuffer from the candidates on hand: as far as
it goes, and say what is left."
  (multiple-value-bind (matches common) (complete (intro-completions state) text)
    (cond ((null matches)
           (doc-message doc "[No match]"))
          ((null (rest matches))
           (doc-set-minibuffer-text doc (first matches))
           (doc-message doc "[Sole completion]"))
          (t
           (doc-set-minibuffer-text doc common)
           (doc-message doc (completions-message matches))))))

(defun ask-completions (doc kind prefix)
  (when (ask doc kind (format nil "COMPLETE ~A" prefix))
    (message doc "Completing ~A ..." prefix)
    t))

(defun symbol-completer (doc)
  "The minibuffer completer for a symbol name.  Symbols come from clamiga,
asynchronously: TAB completes from the candidates on hand when they cover
the input, and asks for more otherwise -- the reply completes the input
then (COMPLETE-MINI-REPLY).  Either way it answers :HANDLED: the message
and the input line are its own business."
  (let ((state (doc-intro doc)))
    (or (intro-completer state)
        (setf (intro-completer state)
              (lambda (text)
                (cond ((string= text "")
                       (doc-beep doc))
                      ((completions-cover-p state text)
                       (apply-candidates doc state text))
                      (t
                       (ask-completions doc :complete-mini text)))
                :handled)))))

(defun replace-range (doc start end text)
  (if (< start end)
      (doc-delete doc start end)
      (doc-set-point doc start))
  (doc-insert doc text))

(define-command complete-symbol (doc arg)
  (declare (ignore arg))
  (let ((point (doc-point doc))
        (state (doc-intro doc)))
    (multiple-value-bind (sym start) (symbol-at-point doc)
      (cond ((or (null sym) (>= start point))
             (doc-message doc "No symbol before point")
             (doc-beep doc))
            (t
             ;; Only the part before point is the prefix; what follows
             ;; stays.
             (setf (intro-complete-start state) start
                   (intro-complete-end state) point)
             (ask-completions doc :complete-buffer (subseq sym 0 (- point start))))))))

(defun complete-buffer-reply (doc prefix rc text)
  (let ((state (doc-intro doc)))
    (cond ((/= rc +rc-ok+)
           (doc-message doc (first-line text))
           (doc-beep doc))
          (t
           (let ((names (take-candidates state prefix text)))
             (cond ((null names)
                    (doc-message doc "[No match]")
                    (doc-beep doc))
                   ((null (rest names))
                    (replace-range doc (intro-complete-start state)
                                   (intro-complete-end state) (first names))
                    (doc-message doc "[Sole completion]"))
                   (t
                    ;; Ambiguous: the minibuffer takes over with the common
                    ;; prefix, TAB there narrows it, RET puts the answer in
                    ;; the buffer.
                    (multiple-value-bind (matches common) (complete names prefix)
                      (declare (ignore matches))
                      (prompt doc "Complete: "
                              (lambda (doc answer)
                                (when (string/= answer "")
                                  (replace-range doc (intro-complete-start state)
                                                 (intro-complete-end state) answer)))
                              :initial (if (string/= common "") common prefix)
                              :completer (symbol-completer doc)
                              :history (editor-symbol-history (doc-editor doc)))))))))))

(defun complete-mini-reply (doc prefix rc text)
  (let ((mini (doc-minibuffer doc))
        (state (doc-intro doc)))
    ;; The prompt may have been abandoned meanwhile, or be another one.
    (when (and mini
               (eq (minibuffer-kind mini) :prompt)
               (eq (minibuffer-completer mini) (intro-completer state)))
      (cond ((/= rc +rc-ok+)
             (doc-message doc (first-line text))
             (doc-beep doc))
            (t
             (take-candidates state prefix text)
             (apply-candidates doc state (doc-minibuffer-text doc)))))))

;;; ------------------------------------------------------------------
;;; Definitions
;;; ------------------------------------------------------------------

(defun prompt-for-symbol (doc label continuation &key (initial ""))
  (prompt doc label continuation
          :initial initial
          :completer (symbol-completer doc)
          :history (editor-symbol-history (doc-editor doc))))

(defun edit-definition-named (doc name)
  (cond ((string= name "") (doc-beep doc))
        (t (ask doc :source-location (format nil "SOURCE-LOCATION ~A" name)))))

(define-command clamacs-edit-definition (doc arg)
  (declare (ignore arg))
  (let ((sym (symbol-at-point doc)))
    (if sym
        (edit-definition-named doc sym)
        (prompt-for-symbol doc "Edit definition of: " #'edit-definition-named))))

(defun definition-reply (wire doc name rc text)
  (multiple-value-bind (file line) (and (= rc +rc-ok+) (parse-location text))
    (cond
      ((null file)
       (when doc
         (let ((shown (first-line text)))
           (doc-message doc (if (string/= shown "")
                                shown
                                (format nil "No source location for ~A" name)))
           (doc-beep doc))))
      (t
       (let ((editor (wire-editor wire)))
         ;; Remember where we were, so `M-,' can come back.
         (when doc
           (locstack-push (editor-locations editor) (doc-path doc) doc (doc-point doc)))
         (let ((target (or (find-document-by-path editor file)
                           (open-document editor file))))
           (cond ((null target)
                  (when doc
                    (message doc "Cannot open ~A" file)
                    (doc-beep doc)))
                 (t
                  (doc-activate target)
                  (goto-line-1 target line)))))))))

(define-command clamacs-pop-definition (doc arg)
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (loc (locstack-pop (editor-locations editor))))
    (cond
      ((null loc)
       (doc-message doc "No previous definition")
       (doc-beep doc))
      (t
       ;; The same window when it is still open, else the file again.
       (let* ((id (location-id loc))
              (path (location-path loc))
              (target (or (and id (member id (live-documents editor)) id)
                          (and path
                               (or (find-document-by-path editor path)
                                   (open-document editor path))))))
         (cond ((null target)
                (message doc "Cannot return to ~A" (or path "a closed window"))
                (doc-beep doc))
               (t
                (doc-activate target)
                (doc-set-point target (location-index loc)))))))))

;;; ------------------------------------------------------------------
;;; Describe, apropos, macroexpand: text into a scratch window
;;; ------------------------------------------------------------------

(defun describe-named (doc name)
  (cond ((string= name "") (doc-beep doc))
        (t (ask doc :describe (format nil "DESCRIBE ~A" name)))))

(define-command clamacs-describe-symbol (doc arg)
  (declare (ignore arg))
  (prompt-for-symbol doc "Describe symbol: " #'describe-named
                     :initial (or (symbol-at-point doc) "")))

(defun apropos-named (doc text)
  (cond ((string= text "") (doc-beep doc))
        (t (ask doc :apropos (format nil "APROPOS ~A" text)))))

(define-command clamacs-apropos (doc arg)
  (declare (ignore arg))
  (prompt doc "Apropos: " #'apropos-named))

(defun macroexpand-at-point (doc full)
  (let ((form (form-at-point doc)))
    (cond ((null form)
           (doc-message doc "No form at point")
           (doc-beep doc))
          (t
           (ask doc :macroexpand
                (concatenate 'string (if full "MACROEXPAND " "MACROEXPAND-1 ") form))))))

(define-command clamacs-macroexpand-1 (doc arg)
  (declare (ignore arg))
  (macroexpand-at-point doc nil))

(define-command clamacs-macroexpand (doc arg)
  (declare (ignore arg))
  (macroexpand-at-point doc t))

(defun show-text-window (editor name lisp-mode text)
  "TEXT in the scratch window NAME, opened if need be, activated, the
cursor at the top.  The window, or NIL when none could be made."
  (let ((doc (ensure-scratch-document editor name lisp-mode)))
    (when doc
      (doc-set-text doc text)
      (forget-arglist doc)
      (when lisp-mode
        (colour-all doc))
      (doc-set-point doc 0)
      (doc-activate doc))
    doc))

(defun text-reply (wire doc window lisp-mode kind subject rc text)
  (cond ((/= rc +rc-ok+)
         (when doc
           (let ((line (first-line text)))
             (doc-message doc (if (string/= line "") line "clamiga could not answer"))
             (doc-beep doc))))
        ((and (eq kind :apropos) (string= text ""))
         (when doc
           (message doc "No symbols matching \"~A\"" subject)))
        ((null (show-text-window (wire-editor wire) window lisp-mode text))
         (when doc
           (message doc "Cannot open ~A" window)))))

;;; ------------------------------------------------------------------
;;; The continuations
;;; ------------------------------------------------------------------

(defun intro-reply (wire kind doc subject rc text)
  "The reply to one of this file's requests: KIND is the request's, DOC
the live document it was about (NIL once closed), SUBJECT the command
that was sent."
  (let ((text (or text ""))
        (arg (subject-arg (or subject ""))))
    (case kind
      ((:arglist :arglist-echo)
       (when doc (arglist-reply doc kind arg rc text)))
      (:complete-buffer
       (when doc (complete-buffer-reply doc arg rc text)))
      (:complete-mini
       (when doc (complete-mini-reply doc arg rc text)))
      (:source-location
       (definition-reply wire doc arg rc text))
      (:describe
       (text-reply wire doc "*clamacs-description*" nil kind arg rc text))
      (:apropos
       (text-reply wire doc "*clamacs-apropos*" nil kind arg rc text))
      (:macroexpand
       (text-reply wire doc "*clamacs-macroexpansion*" t kind arg rc text)))))
