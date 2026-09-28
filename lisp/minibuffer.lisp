;;;; minibuffer.lisp -- prompts, completion, history, incremental search.
;;;;
;;;; The minibuffer is one input line per document, reused for every prompt.
;;;; What a prompt is FOR is a continuation: PROMPT takes a function of the
;;;; document and the answer, so a new prompting command is a closure and
;;;; not a case in a switch.  The frontend supplies the input line through
;;;; five generic functions (and may show what TAB has to offer as a list,
;;;; DOC-SHOW-COMPLETIONS) and reports three events -- a key the
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

(defgeneric doc-show-completions (doc names index)
  (:documentation "Show NAMES, what TAB has to offer, as a list the user
moves a cursor through: INDEX is the entry the cursor is on, -1 for none
(the common prefix is in the line); NIL hides the list.  Called again
with the same NAMES when only the cursor moved.  The default does
nothing, which is the MUI String's lot: its echo row names the first
few candidates anyway, and TAB, <down> and <up> cycle them in the line
with or without a list to look at.")
  (:method ((doc document) names index)
    (declare (ignore names index))
    nil))

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
  ;; What the last TAB offered, for the next TAB to cycle through: the
  ;; matches, what the list shows for them when that differs (a file's
  ;; base name for its path), the one in the line (-1 = the common
  ;; prefix), and the text that TAB left there -- an input that differs
  ;; from it was edited since.
  (candidates '())
  (candidates-shown nil)
  (candidate-index -1)
  (candidates-text nil)
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
once the user accepts it; C-g or ESC abandons it.  COMPLETER, a function of the
input returning what COMPLETE returns -- the matches and their common
prefix, and as an optional third value what to show for each match -- or
:HANDLED when it completed and said so itself, is what TAB uses; HISTORY,
a HISTORY, is what M-p and M-n walk and where the answer is recorded."
  (setf (doc-minibuffer doc)
        (make-minibuffer :prompt label continuation completer history))
  (doc-open-minibuffer doc label initial))

(defun prompt-for-form (doc label continuation)
  "Prompt for a Lisp form to hand to clamiga; the answer is not a command
name, so no completion, and the command history keeps it."
  (prompt doc label continuation
          :history (editor-command-history (doc-editor doc))))

(defun minibuffer-finish (doc)
  (let ((mini (doc-minibuffer doc)))
    (when (and mini (minibuffer-candidates mini))
      (doc-show-completions doc nil -1)))
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

;;; The keys the minibuffer takes away from the input line.  This is the
;;; one place that list lives -- MINIBUFFER-KEY acts on exactly these, and
;;; a frontend whose input line sees keys first (an active MUI String)
;;; asks here before giving one up.
;;; ESC abandons a prompt as C-g does.  In the text ESC is a Meta prefix,
;;; but the input line has no key state to be a prefix in, and an ESC
;;; the minibuffer leaves alone is MUI's: GADGET_OFF and WINDOW_CLOSE,
;;; which closed the window (see *MINI-WINDOW-KEYS* in the MUI frontend).
(defparameter *minibuffer-keys-always* (list (make-key 103 +mod-ctrl+)    ; C-g
                                             +key-esc+)
  "Taken whenever the minibuffer is open.")
(defparameter *minibuffer-keys-isearch* (list (make-key 115 +mod-ctrl+)   ; C-s
                                              (make-key 114 +mod-ctrl+))  ; C-r
  "Taken in a search.")
(defparameter *minibuffer-keys-prompt* (list +key-tab+
                                             (make-key 112 +mod-meta+)    ; M-p
                                             (make-key 110 +mod-meta+)    ; M-n
                                             +key-down+
                                             +key-up+)
  "Taken at a prompt: completion, the history, and the arrows -- which
move through the candidates TAB offered while they are on offer, and
walk the history like M-p and M-n otherwise.")

(defun minibuffer-binds-p (doc key)
  "Whether KEY is one the minibuffer takes away from the input line NOW:
C-g and ESC whenever it is open; C-s and C-r in a search; TAB and the
history keys at a prompt."
  (let ((mini (doc-minibuffer doc)))
    (and mini
         (or (member key *minibuffer-keys-always*)
             (member key (if (eq (minibuffer-kind mini) :isearch)
                             *minibuffer-keys-isearch*
                             *minibuffer-keys-prompt*)))
         t)))

(defun minibuffer-ever-binds-p (key)
  "Whether KEY is one MINIBUFFER-BINDS-P answers T for in some state: the
union of its lists.  A frontend that must decide which keys to take
before the minibuffer is open -- the MUI String's key table, filled once
from the keymap -- takes these, and MINIBUFFER-KEY reports the ones the
current state does not bind as undefined."
  (and (or (member key *minibuffer-keys-always*)
           (member key *minibuffer-keys-isearch*)
           (member key *minibuffer-keys-prompt*))
       t))

(defun minibuffer-offer (doc matches common &optional shown)
  "Put the common prefix COMMON of the ambiguous MATCHES in the line, name
the first few (SHOWN standing in for them when given), show them as a
list where the frontend has one, and keep them for the next TAB to cycle
through.  For a completer that runs the whole show itself (the symbol
completer) as much as for MINIBUFFER-COMPLETE."
  (let ((mini (doc-minibuffer doc)))
    (doc-set-minibuffer-text doc common)
    (doc-message doc (completions-message matches shown))
    (when mini
      (setf (minibuffer-candidates mini) matches
            (minibuffer-candidates-shown mini) shown
            (minibuffer-candidate-index mini) -1
            (minibuffer-candidates-text mini) (copy-seq common))
      (doc-show-completions doc (or shown matches) -1))))

(defun minibuffer-forget-candidates (doc mini)
  "Drop what the last TAB offered, and the list with it."
  (when (minibuffer-candidates mini)
    (setf (minibuffer-candidates mini) '()
          (minibuffer-candidates-shown mini) nil
          (minibuffer-candidate-index mini) -1
          (minibuffer-candidates-text mini) nil)
    (doc-show-completions doc nil -1)))

(defun minibuffer-offering-p (doc mini)
  "Whether the candidates of the last TAB are still on offer: there are
some, and the line is as that TAB (or the cursor) left it."
  (and (minibuffer-candidates mini)
       (equal (doc-minibuffer-text doc) (minibuffer-candidates-text mini))
       t))

(defun minibuffer-select (doc mini index)
  "Candidate INDEX of what the last TAB offered goes into the line, whole,
and the list's cursor onto it; the echo area counts.  RET takes it."
  (let* ((matches (minibuffer-candidates mini))
         (n (length matches))
         (index (mod index n))
         (text (nth index matches)))
    (setf (minibuffer-candidate-index mini) index
          (minibuffer-candidates-text mini) (copy-seq text))
    (doc-set-minibuffer-text doc text)
    (message doc "[~D/~D]" (1+ index) n)
    (doc-show-completions doc (or (minibuffer-candidates-shown mini) matches) index)))

(defun minibuffer-cycle (doc mini &optional (step 1))
  "TAB again on what the last TAB left: the next candidate, round and
round; <down> the same, <up> the previous one -- from the common prefix
(no cursor) the last."
  (let ((index (minibuffer-candidate-index mini)))
    (minibuffer-select doc mini
                       (if (and (< index 0) (< step 0))
                           (+ (length (minibuffer-candidates mini)) step)
                           (+ index step)))))

(defun minibuffer-pick (doc index &optional accept)
  "The user pointed at candidate INDEX of the list on offer (a click in
the frontend's list): it goes into the line as <down> would put it, and
with ACCEPT (a double click) RET follows.  True when there was such a
candidate."
  (let ((mini (doc-minibuffer doc)))
    (when (and mini
               (eq (minibuffer-kind mini) :prompt)
               (integerp index)
               (< -1 index (length (minibuffer-candidates mini))))
      (minibuffer-select doc mini index)
      (when accept
        (minibuffer-done doc))
      t)))

(defun minibuffer-complete (doc mini)
  "TAB: complete the input as far as it goes, and say what is left -- the
first few candidates by name, since the editor has no completions buffer
and the echo area is where the user sees what `M-x' (or a theme, a file
name) has to offer.  TAB again, with the line as the last TAB left it,
cycles through the candidates instead."
  (let ((completer (minibuffer-completer mini))
        (text (doc-minibuffer-text doc)))
    (cond ((null completer)
           (doc-beep doc))
          ((minibuffer-offering-p doc mini)
           (minibuffer-cycle doc mini))
          (t
           (minibuffer-forget-candidates doc mini)
           (multiple-value-bind (matches common shown) (funcall completer text)
             (cond ((eq matches :handled)
                    ;; The completer did the whole job itself -- the symbol
                    ;; completer, whose candidates come from clamiga later
                    ;; and go through MINIBUFFER-OFFER when they are many.
                    )
                   ((null matches)
                    (doc-message doc "[No match]"))
                   ((null (rest matches))
                    (doc-set-minibuffer-text doc common)
                    (doc-message doc "[Sole completion]"))
                   (t
                    (minibuffer-offer doc matches common shown))))))))

(defun minibuffer-key (doc key)
  "Act on KEY when it is the minibuffer's.  True when it was, and must not
reach the input line."
  (when (minibuffer-binds-p doc key)
    (let ((mini (doc-minibuffer doc)))
      (cond ((or (eql key (make-key 103 +mod-ctrl+))
                 (eql key +key-esc+))
             (minibuffer-abort doc))
            ((eq (minibuffer-kind mini) :isearch)
             ;; C-s or C-r: search again, in that direction.
             (setf (minibuffer-backwards mini)
                   (eql key (make-key 114 +mod-ctrl+)))
             (isearch-step doc mini t))
            ((eql key +key-tab+)
             (minibuffer-complete doc mini))
            ((and (or (eql key +key-down+) (eql key +key-up+))
                  (minibuffer-offering-p doc mini))
             ;; The arrows move the cursor through the candidates.
             (minibuffer-cycle doc mini (if (eql key +key-down+) 1 -1)))
            (t
             ;; M-p / <up> and M-n / <down>: the history.
             (let* ((history (minibuffer-history mini))
                    (item (and history
                               (if (or (eql key (make-key 112 +mod-meta+))
                                       (eql key +key-up+))
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
start over from the anchor with the longer or shorter pattern.  At a
prompt an edit ends what the last TAB offered: the list goes, the next
TAB completes what is typed now."
  (let ((mini (doc-minibuffer doc)))
    (cond ((null mini))
          ((eq (minibuffer-kind mini) :isearch)
           (doc-set-point doc (minibuffer-anchor mini))
           (isearch-step doc mini nil))
          ((and (minibuffer-candidates mini)
                (not (minibuffer-offering-p doc mini)))
           (minibuffer-forget-candidates doc mini)))))

(defun isearch-start (doc backwards)
  (let ((mini (make-minibuffer :isearch nil nil nil nil)))
    (setf (minibuffer-anchor mini) (doc-point doc)
          (minibuffer-backwards mini) backwards
          (minibuffer-label mini) (isearch-label mini nil)
          (doc-minibuffer doc) mini)
    (doc-open-minibuffer doc (minibuffer-label mini) "")))

(define-command isearch-forward (doc arg)
  "Search forward incrementally as the pattern is typed; C-s again finds the next."
  (declare (ignore arg))
  (isearch-start doc nil))

(define-command isearch-backward (doc arg)
  "Search backward incrementally; C-r again finds the previous."
  (declare (ignore arg))
  (isearch-start doc t))

;;; ------------------------------------------------------------------
;;; The prompting commands that need nothing else
;;; ------------------------------------------------------------------

(define-command execute-extended-command (doc arg)
  "Run a command by name (M-x); TAB completes and lists the names."
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
  "Move to a line, asked for by its number."
  (declare (ignore arg))
  (prompt doc "Goto line: "
          (lambda (doc answer)
            (let ((line (parse-integer answer :junk-allowed t)))
              (when (and line (> line 0))
                (doc-set-point doc (doc-line-index doc (1- line))))))))
