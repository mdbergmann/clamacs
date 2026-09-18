;;;; minibuffer.lisp -- prompts, completion, history, incremental search.
;;;;
;;;; The minibuffer is one input line per document, reused for every prompt.
;;;; What a prompt is FOR is a continuation: PROMPT takes a function of the
;;;; document and the answer, so a new prompting command is a closure and
;;;; not a case in a switch.  The frontend supplies the input line through
;;;; five generic functions and reports three events -- a key the
;;;; minibuffer may want (MINIBUFFER-KEY), a changed input
;;;; (MINIBUFFER-CHANGED), an accepted input (MINIBUFFER-DONE) -- and
;;;; everything else is here and host-tested.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The frontend's part
;;; ------------------------------------------------------------------

(defgeneric doc-open-minibuffer (doc label initial)
  (:documentation "Show the input line with LABEL before it and INITIAL in
it, and give it the keyboard."))

(defgeneric doc-close-minibuffer (doc)
  (:documentation "Hide the input line, empty it, and give the keyboard
back to the text."))

(defgeneric doc-minibuffer-text (doc)
  (:documentation "What the input line holds."))

(defgeneric doc-set-minibuffer-text (doc text))

(defgeneric doc-set-minibuffer-label (doc label)
  (:documentation "Change the label beside the open input line.  A message
shown while a prompt is open goes here too, which is as close as one line
gets to Emacs's minibuffer-message."))

(defgeneric doc-search (doc pattern backwards again)
  (:documentation "The widget's own search from the cursor, BACKWARDS or
not; AGAIN asks for the next match rather than one at the cursor.  Moves the
cursor and returns true when PATTERN was found."))

;;; ------------------------------------------------------------------
;;; State
;;; ------------------------------------------------------------------

(defstruct (minibuffer (:constructor make-minibuffer
                           (kind label continuation completer history)))
  kind                       ; :PROMPT or :ISEARCH
  label
  continuation               ; function of the document and the answer
  completer                  ; function of the input: matches and common
  history                    ; a HISTORY, or NIL for answers not worth one
  ;; isearch
  (anchor 0)                 ; where the search started
  (backwards nil))

(defun minibuffer-open-p (doc)
  (and (doc-minibuffer doc) t))

;;; A message shown while a prompt is open takes the label's place.
(defmethod doc-message :around ((doc document) text)
  (if (doc-minibuffer doc)
      (doc-set-minibuffer-label doc text)
      (call-next-method)))

(defun prompt (doc label continuation &key (initial "") completer history)
  "Ask for a line of input.  CONTINUATION is called with DOC and the answer
once the user accepts it; C-g abandons it.  COMPLETER, a function of the
input returning what COMPLETE returns (or :HANDLED when it completed and
said so itself), is what TAB uses; HISTORY, a HISTORY, is what M-p and M-n
walk and where the answer is recorded."
  (setf (doc-minibuffer doc)
        (make-minibuffer :prompt label continuation completer history))
  (doc-open-minibuffer doc label initial))

(defun prompt-for-form (doc label continuation)
  "Prompt for a Lisp form to hand to clamiga; the answer is not a command
name, so no completion, and the command history keeps it."
  (prompt doc label continuation
          :history (editor-command-history (doc-editor doc))))

(defun minibuffer-finish (doc)
  (setf (doc-minibuffer doc) nil)
  (doc-close-minibuffer doc))

(defun minibuffer-abort (doc)
  (let ((mini (doc-minibuffer doc)))
    (when mini
      (when (eq (minibuffer-kind mini) :isearch)
        (doc-set-point doc (minibuffer-anchor mini)))
      (minibuffer-finish doc)
      (doc-message doc "Quit"))))

(defun minibuffer-done (doc)
  "The user accepted the input (RET)."
  (let ((mini (doc-minibuffer doc)))
    (when mini
      (cond ((eq (minibuffer-kind mini) :isearch)
             ;; Leaving a search where it found something: the way back is
             ;; the mark, as in Emacs.
             (minibuffer-finish doc)
             (setf (doc-mark doc) (minibuffer-anchor mini))
             (doc-message doc "Mark set"))
            (t
             (let ((answer (copy-seq (doc-minibuffer-text doc))))
               (when (minibuffer-history mini)
                 (hist-add (minibuffer-history mini) answer))
               ;; Closed BEFORE the continuation runs: it may well open the
               ;; next prompt.
               (minibuffer-finish doc)
               (funcall (minibuffer-continuation mini) doc answer)))))))

;;; ------------------------------------------------------------------
;;; Keys
;;; ------------------------------------------------------------------

(defun minibuffer-binds-p (doc key)
  "Whether KEY is one the minibuffer takes away from the input line: C-g
whenever it is open; C-s and C-r in a search; TAB and the history keys at a
prompt.  This is the one place that list lives -- MINIBUFFER-KEY acts on
exactly these, and a frontend whose input line sees keys first (an active
MUI String) asks here before giving one up."
  (let ((mini (doc-minibuffer doc)))
    (and mini
         (or (eql key (make-key 103 +mod-ctrl+)) ; C-g
             (if (eq (minibuffer-kind mini) :isearch)
                 (or (eql key (make-key 115 +mod-ctrl+))  ; C-s
                     (eql key (make-key 114 +mod-ctrl+))) ; C-r
                 (or (eql key +key-tab+)
                     (eql key (make-key 112 +mod-meta+))    ; M-p
                     (eql key (make-key 110 +mod-meta+))))) ; M-n
         t)))

(defun minibuffer-complete (doc mini)
  (let ((completer (minibuffer-completer mini)))
    (if (null completer)
        (doc-beep doc)
        (multiple-value-bind (matches common)
            (funcall completer (doc-minibuffer-text doc))
          (cond ((eq matches :handled)
                 ;; The completer did the whole job itself -- the symbol
                 ;; completer, whose candidates come from clamiga later.
                 )
                ((null matches)
                 (doc-message doc "[No match]"))
                (t
                 (doc-set-minibuffer-text doc common)
                 (if (null (rest matches))
                     (doc-message doc "[Sole completion]")
                     (message doc "[~D completions]" (length matches)))))))))

(defun minibuffer-key (doc key)
  "Act on KEY when it is the minibuffer's.  True when it was, and must not
reach the input line."
  (when (minibuffer-binds-p doc key)
    (let ((mini (doc-minibuffer doc)))
      (cond ((eql key (make-key 103 +mod-ctrl+))
             (minibuffer-abort doc))
            ((eq (minibuffer-kind mini) :isearch)
             ;; C-s or C-r: search again, in that direction.
             (setf (minibuffer-backwards mini)
                   (eql key (make-key 114 +mod-ctrl+)))
             (isearch-step doc mini t))
            ((eql key +key-tab+)
             (minibuffer-complete doc mini))
            (t
             (let* ((history (minibuffer-history mini))
                    (item (and history
                               (if (eql key (make-key 112 +mod-meta+))
                                   (hist-prev history)
                                   (hist-next history)))))
               (doc-set-minibuffer-text doc (or item ""))))))
    t))

;;; ------------------------------------------------------------------
;;; Incremental search
;;; ------------------------------------------------------------------

(defun isearch-label (mini failing)
  (cond (failing "Failing I-search: ")
        ((minibuffer-backwards mini) "Reverse I-search: ")
        (t "I-search: ")))

(defun isearch-step (doc mini again)
  (let ((pattern (doc-minibuffer-text doc)))
    (when (string/= pattern "")
      (doc-set-minibuffer-label
       doc
       (isearch-label mini
                      (not (doc-search doc pattern
                                       (minibuffer-backwards mini) again)))))))

(defun printable-key-p (key)
  "A key that types itself: no modifier, a Latin-1 character, not DEL."
  (and (= (key-mods key) 0)
       (<= #x20 (key-code key) #xFF)
       (/= (key-code key) +key-delete+)))

(defgeneric doc-minibuffer-edit (doc key)
  (:documentation "A key the minibuffer did not take (MINIBUFFER-KEY),
done as the input line itself would do it from the keyboard: a printable
key self-inserts, BS deletes backwards, RET accepts the input.  True when
the key did something.  The port's KEY command types into a prompt with
this; a frontend whose input line changes its contents itself overrides it
so the change is notified once.")
  (:method ((doc document) key)
    (let ((text (doc-minibuffer-text doc)))
      (cond ((eql key +key-return+)
             (minibuffer-done doc)
             t)
            ((printable-key-p key)
             (doc-set-minibuffer-text
              doc (concatenate 'string text (string (code-char (key-code key)))))
             (minibuffer-changed doc)
             t)
            ((and (eql key +key-backspace+) (string/= text ""))
             (doc-set-minibuffer-text doc (subseq text 0 (1- (length text))))
             (minibuffer-changed doc)
             t)
            (t nil)))))

(defun minibuffer-changed (doc)
  "The input line's contents changed.  In a search that IS the command:
start over from the anchor with the longer or shorter pattern."
  (let ((mini (doc-minibuffer doc)))
    (when (and mini (eq (minibuffer-kind mini) :isearch))
      (doc-set-point doc (minibuffer-anchor mini))
      (isearch-step doc mini nil))))

(defun isearch-start (doc backwards)
  (let ((mini (make-minibuffer :isearch nil nil nil nil)))
    (setf (minibuffer-anchor mini) (doc-point doc)
          (minibuffer-backwards mini) backwards
          (minibuffer-label mini) (isearch-label mini nil)
          (doc-minibuffer doc) mini)
    (doc-open-minibuffer doc (minibuffer-label mini) "")))

(define-command isearch-forward (doc arg)
  (declare (ignore arg))
  (isearch-start doc nil))

(define-command isearch-backward (doc arg)
  (declare (ignore arg))
  (isearch-start doc t))

;;; ------------------------------------------------------------------
;;; The prompting commands that need nothing else
;;; ------------------------------------------------------------------

(define-command execute-extended-command (doc arg)
  (declare (ignore arg))
  (prompt doc "M-x "
          (lambda (doc answer)
            (let ((command (find-command answer)))
              (cond (command (run-command doc command 1))
                    (t (doc-message doc "[No match]")
                       (doc-beep doc)))))
          :completer #'complete-command
          :history (editor-command-history (doc-editor doc))))

(define-command goto-line (doc arg)
  (declare (ignore arg))
  (prompt doc "Goto line: "
          (lambda (doc answer)
            (let ((line (parse-integer answer :junk-allowed t)))
              (when (and line (> line 0))
                (doc-set-point doc (doc-line-index doc (1- line))))))))
