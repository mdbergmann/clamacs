;;;; iedit.lisp -- edit every occurrence of a symbol at once (Emacs's
;;;; iedit-mode).
;;;;
;;;; `C-;' on a symbol finds its occurrences -- in the defun the cursor is
;;;; in, with a prefix argument in the whole buffer -- and marks them.  From
;;;; then on an edit made INSIDE the occurrence under the cursor is repeated
;;;; in the others at the same place: typing, Backspace, Delete, `M-d',
;;;; `C-y', anything that changes the text within the symbol.  An edit
;;;; outside it (the cursor moved away first) is nobody else's.  `M-n' and
;;;; `M-p' go to the next and previous occurrence, `M-;' drops the one at
;;;; point out of the set, `C-g' or `C-;' end it.
;;;;
;;;; This is iedit's model, not multiple-cursors': there is ONE cursor and
;;;; the other positions follow from it, so the state is the occurrence
;;;; list and nothing more.  The edit itself is found by DIFFING -- the
;;;; cursor's line before the key against the line after it (the whole
;;;; buffer is never read on a key) -- so no command needs to know about
;;;; this file: RUN-COMMAND and HANDLE-KEY run inside IEDIT-AROUND, and
;;;; whatever changed the text, the one replacement it made is what is
;;;; mirrored.  An edit that adds or removes a line, or lands somewhere
;;;; other than the cursor's line, cannot be placed that cheaply and ends
;;;; the session instead, saying so.
;;;;
;;;; The occurrences are symbol TOKENS (token.lisp), so `foo' inside a
;;;; string or a comment is not one and `foobar' never matches, and the
;;;; match is case-insensitive, since the reader folds case: FOO is foo.
;;;; Outside Lisp mode a plain word match stands in.
;;;;
;;;; Undo: every mirrored edit is a few of the widget's undo steps.  The
;;;; session keeps a log of how many, with the occurrence list as it was,
;;;; so `undo' inside it takes back the whole edit everywhere and the set
;;;; is as before; `redo' the same forwards.  An undo past the log's start
;;;; ends the session.
;;;;
;;;; Pure: no MUI, no OS types.  The marks reach the frontend through
;;;; DOC-STYLE (frontend.lisp); a recolour of a line (COLOUR-LINES) wipes
;;;; them, and IEDIT-AFTER-RECOLOUR puts them back.

(in-package :clamacs)

(defstruct (iedit (:constructor %make-iedit (starts length text scope)))
  ;; The occurrences' start indices, ascending; every one has LENGTH
  ;; characters and reads as TEXT (case aside)
  (starts '())
  (length 0)
  (text "")
  ;; :DEFUN or :BUFFER, for the messages
  scope
  ;; The position in STARTS of the occurrence under the cursor, or NIL
  (current nil)
  ;; The undo log, newest first: (steps starts length text) per mirrored
  ;; edit, STEPS the widget's undo steps it took; and the redo log, what
  ;; `undo' popped
  (undo-log '())
  (redo-log '()))

(defvar *iedit-inside* nil
  "True while IEDIT-AROUND runs its body: a command that runs another
runs it inside the outer one's accounting.")

;;; ------------------------------------------------------------------
;;; Finding the occurrences
;;; ------------------------------------------------------------------

(defun iedit-token-occurrences (text base symbol)
  "The starts of the symbol tokens of TEXT that read as SYMBOL, as document
indices (TEXT starts at BASE).  TEXT's offset 0 is outside any string and
comment, the tokenizer's contract."
  (let ((state (make-tok-state))
        (n (length symbol))
        (offset 0)
        (starts '()))
    (declare (fixnum n offset))
    (do-text-lines (line text)
      (dolist (token (tokenize-line line state))
        (when (and (= (token-len token) n)
                   (member (token-kind token) '(:symbol :keyword :defining))
                   (string-equal line symbol
                                 :start1 (token-start token)
                                 :end1 (+ (token-start token) n)))
          (push (+ base offset (token-start token)) starts)))
      (incf offset (1+ (length line))))
    (nreverse starts)))

(defun iedit-word-occurrences (text base word)
  "The starts of the whole words of TEXT that read as WORD -- runs of
symbol characters, as SEXP-SYMBOL-AT-POINT delimits them -- as document
indices.  For a buffer that is not Lisp."
  (declare (simple-string text))
  (let ((n (length word))
        (len (length text))
        (i 0)
        (starts '()))
    (declare (fixnum n len i))
    (loop
      (when (>= i len)
        (return (nreverse starts)))
      (cond ((sx-symbol-char-p (schar text i))
             (let ((start i))
               (loop while (and (< i len) (sx-symbol-char-p (schar text i)))
                     do (incf i))
               (when (and (= (- i start) n)
                          (string-equal text word :start1 start :end1 i))
                 (push (+ base start) starts))))
            (t (incf i))))))

(defun iedit-scope-text (doc point scope)
  "The text the occurrences are looked for in and its base index: the
defun around POINT for :DEFUN (the whole buffer when POINT is in none),
else the whole buffer."
  (multiple-value-bind (text base) (doc-context-full doc)
    (declare (ignore base))
    (let ((text (or text (doc-text doc 0 (doc-end doc)))))
      (if (eq scope :defun)
          (let* ((start (sexp-defun-start text point))
                 (end (and start (sexp-defun-end text point))))
            (if (and start end (<= start point end))
                (values (subseq text start end) start)
                (values text 0)))
          (values text 0)))))

(defun iedit-find (doc scope)
  "The occurrences of the symbol at point within SCOPE: the symbol's
text and the sorted list of starts, or NIL and a reason when there is
nothing to edit."
  (multiple-value-bind (symbol s0) (symbol-at-point doc)
    (cond ((null symbol)
           (values nil "No symbol at point"))
          (t
           (multiple-value-bind (text base) (iedit-scope-text doc s0 scope)
             (let ((starts (if (doc-lisp-mode doc)
                               (iedit-token-occurrences text base symbol)
                               (iedit-word-occurrences text base symbol))))
               (cond ((not (member s0 starts))
                      ;; In a string or a comment: a symbol for `M-.',
                      ;; not an occurrence.
                      (values nil (format nil "~A here is not code" symbol)))
                     ((null (rest starts))
                      (values nil (format nil "~A occurs once in the ~(~A~)" symbol scope)))
                     (t (values symbol starts)))))))))

;;; ------------------------------------------------------------------
;;; The state
;;; ------------------------------------------------------------------

(defun iedit-end-index (st start)
  (+ start (iedit-length st)))

(defun iedit-index-at (st point)
  "The position in the set of the occurrence POINT is in -- its ends
included, as an insertion at either end extends the symbol -- or NIL."
  (position-if (lambda (start) (<= start point (iedit-end-index st start)))
               (iedit-starts st)))

(defun iedit-scope-name (st)
  (if (eq (iedit-scope st) :defun) "defun" "buffer"))

(defun iedit-describe (doc st)
  (message doc "iedit: ~D occurrences of ~A in the ~A"
           (length (iedit-starts st)) (iedit-text st) (iedit-scope-name st)))

(defun iedit-start (doc scope)
  "Begin on the symbol at point.  True when it began."
  (multiple-value-bind (symbol starts) (iedit-find doc scope)
    (cond ((null symbol)
           (doc-message doc starts)
           (doc-beep doc)
           nil)
          (t
           (let ((st (%make-iedit starts (length symbol) symbol scope)))
             (setf (iedit-current st) (iedit-index-at st (doc-point doc))
                   (doc-iedit doc) st)
             (iedit-paint doc st)
             (iedit-describe doc st)
             t)))))

(defun iedit-end (doc &optional why)
  "End the session, taking the marks down; WHY, when given, is said."
  (let ((st (doc-iedit doc)))
    (when st
      (setf (doc-iedit doc) nil)
      (iedit-unpaint doc st)
      (if why
          (message doc "iedit ended: ~A" why)
          (doc-message doc "iedit off")))))

(defun iedit-active-p (doc)
  (and (doc-iedit doc) t))

;;; ------------------------------------------------------------------
;;; The marks
;;; ------------------------------------------------------------------

(defun iedit-paint (doc st &optional y0 y1)
  "Mark every occurrence, or those on lines Y0 to Y1, the one under the
cursor distinctly."
  (let ((k 0))
    (dolist (start (iedit-starts st))
      (multiple-value-bind (y x) (doc-index-line doc start)
        (when (or (null y0) (<= y0 y y1))
          (doc-style doc y x (+ x (iedit-length st))
                     (if (eql k (iedit-current st)) :occurrence-current :occurrence))))
      (incf k))))

(defun iedit-unpaint (doc st)
  "Take the marks down and give the lines their token colours back."
  (let ((lines '()))
    (dolist (start (iedit-starts st))
      (multiple-value-bind (y x) (doc-index-line doc start)
        (doc-style doc y x (+ x (iedit-length st)) nil)
        (pushnew y lines)))
    (dolist (y lines)
      (colour-lines doc y y))))

(defun iedit-after-recolour (doc y0 y1)
  "COLOUR-LINES repainted lines Y0 to Y1 whole: the marks on them again."
  (let ((st (doc-iedit doc)))
    (when st
      (iedit-paint doc st y0 y1))))

(defun iedit-after-recolour-all (doc)
  "COLOUR-ALL repainted the buffer -- after a file was loaded into it,
or for a new theme: the set checked against the text first, since the
text may be another one now."
  (let ((st (doc-iedit doc)))
    (when st
      (iedit-validate doc st)
      (let ((st (doc-iedit doc)))
        (when st
          (iedit-paint doc st))))))

(defun iedit-note-point (doc)
  "The cursor moved: the mark of the occurrence it left and the one it
entered follow."
  (let ((st (doc-iedit doc)))
    (when st
      (let ((was (iedit-current st))
            (now (iedit-index-at st (doc-point doc))))
        (unless (eql was now)
          (setf (iedit-current st) now)
          (dolist (k (list was now))
            (when k
              (let ((start (nth k (iedit-starts st))))
                (multiple-value-bind (y x) (doc-index-line doc start)
                  (doc-style doc y x (+ x (iedit-length st))
                             (if (eql k now) :occurrence-current :occurrence)))))))))))

;;; ------------------------------------------------------------------
;;; Keeping the set true to the text
;;; ------------------------------------------------------------------

(defun iedit-occurrence-reads-p (doc st start)
  "Whether the text at START still reads as the set's text."
  (let ((end (iedit-end-index st start)))
    (and (<= end (doc-end doc))
         (string-equal (doc-text doc start end) (iedit-text st)))))

(defun iedit-validate (doc st)
  "Drop every occurrence that no longer reads as the set's text -- an
edit the session did not see -- and end when fewer than two remain."
  (let ((starts (remove-if-not (lambda (start) (iedit-occurrence-reads-p doc st start))
                               (iedit-starts st))))
    (unless (equal starts (iedit-starts st))
      ;; The marks of the dropped ones taken down where the text still
      ;; reaches (a frontend whose marks outlive a recolour keeps them)
      (dolist (start (set-difference (iedit-starts st) starts))
        (when (<= (iedit-end-index st start) (doc-end doc))
          (multiple-value-bind (y x) (doc-index-line doc start)
            (doc-style doc y x (+ x (iedit-length st)) nil))))
      (setf (iedit-starts st) starts
            (iedit-current st) (iedit-index-at st (doc-point doc))))
    (when (null (rest starts))
      (iedit-end doc "the other occurrences changed"))))

(defun iedit-drop (doc st k)
  "Occurrence K out of the set; the session ends when one is left."
  (let ((start (nth k (iedit-starts st))))
    ;; Out of the set first: the recolour below puts the marks of the
    ;; set back on the line.
    (setf (iedit-starts st) (append (subseq (iedit-starts st) 0 k)
                                    (nthcdr (1+ k) (iedit-starts st)))
          (iedit-current st) (iedit-index-at st (doc-point doc)))
    (multiple-value-bind (y x) (doc-index-line doc start)
      (doc-style doc y x (+ x (iedit-length st)) nil)
      (colour-lines doc y y))
    (when (null (rest (iedit-starts st)))
      (iedit-end doc "one occurrence left"))))

;;; ------------------------------------------------------------------
;;; Mirroring an edit
;;; ------------------------------------------------------------------

(defun iedit-mirror (doc st k from to insert)
  "The replacement FROM..TO -> INSERT (document indices, in the text
before it) was made inside occurrence K: the same in every other one.
The cursor is put back where the user's edit left it."
  (let* ((starts (iedit-starts st))
         (base (nth k starts))
         (delta (- (length insert) (- to from)))
         (rel-from (- from base))
         (rel-to (- to base))
         (point (doc-point doc))
         (steps 1)
         (kept '()))
    (with-quiet-display (doc)
      ;; From the end of the buffer backwards, so the positions of the
      ;; ones still to do hold; an occurrence above K has shifted by
      ;; DELTA already, K's own edit did that.
      (loop for j from (1- (length starts)) downto 0
            do (let ((start (+ (nth j starts) (if (> j k) delta 0))))
                 (cond ((= j k) (push j kept))
                       ((not (iedit-occurrence-reads-p doc st start))
                        ;; Changed behind the session's back: dropped.
                        nil)
                       (t
                        (when (> rel-to rel-from)
                          (doc-delete doc (+ start rel-from) (+ start rel-to))
                          (incf steps))
                        (when (> (length insert) 0)
                          (doc-set-point doc (+ start rel-from))
                          (doc-insert doc insert)
                          (incf steps))
                        (push j kept))))))
    ;; The user's cursor, moved by the mirrors below it.
    (let ((below (count-if (lambda (j) (< j k)) kept)))
      (doc-set-point doc (+ point (* below delta))))
    ;; The set after: the kept ones, each moved by the edits above it.
    (let ((new-starts '())
          (n 0))
      (dolist (j kept)
        (push (+ (nth j starts) (* n delta)) new-starts)
        (incf n))
      (push (list steps (iedit-starts st) (iedit-length st) (iedit-text st))
            (iedit-undo-log st))
      (setf (iedit-redo-log st) '()
            (iedit-starts st) (nreverse new-starts)
            (iedit-length st) (+ (iedit-length st) delta)
            (iedit-text st) (concatenate 'string
                                         (subseq (iedit-text st) 0 rel-from)
                                         insert
                                         (subseq (iedit-text st) rel-to))
            (iedit-current st) (iedit-index-at st (doc-point doc))))
    (if (null (rest (iedit-starts st)))
        (iedit-end doc "the other occurrences changed")
        ;; The marks where the occurrences are now; a frontend that
        ;; recolours the edited lines afterwards paints them again.
        (iedit-paint doc st))))

(defun iedit-shift (doc st from to delta)
  "The replacement FROM..TO, DELTA characters longer, was made outside
every occurrence: the ones after it move, one it overlaps is dropped."
  (let ((starts '()))
    (dolist (start (iedit-starts st))
      (let ((end (iedit-end-index st start)))
        (cond ((<= end from) (push start starts))
              ((>= start to) (push (+ start delta) starts)))))
    (setf (iedit-starts st) (nreverse starts)
          (iedit-current st) (iedit-index-at st (doc-point doc)))
    (if (null (rest (iedit-starts st)))
        (iedit-end doc "the other occurrences changed")
        (iedit-paint doc st))))

(defun iedit-apply-change (doc st from to insert mirror)
  "The one replacement a key made, in the indices of the text before
it: mirrored when it lies inside the occurrence under the cursor and
MIRROR, else only accounted for."
  (let ((k (and mirror (iedit-index-at st from))))
    (if (and k
             (<= (nth k (iedit-starts st)) from)
             (<= to (iedit-end-index st (nth k (iedit-starts st)))))
        (iedit-mirror doc st k from to insert)
        (iedit-shift doc st from to (- (length insert) (- to from))))))

;;; ------------------------------------------------------------------
;;; Undo inside the session
;;; ------------------------------------------------------------------

(defun iedit-restore (st entry)
  (destructuring-bind (steps starts length text) entry
    (declare (ignore steps))
    (setf (iedit-starts st) starts
          (iedit-length st) length
          (iedit-text st) text)))

(defun iedit-undo (doc st redo)
  "`undo' (or `redo' when REDO) while the session is on: the last
mirrored edit taken back everywhere -- as many of the widget's steps as
it took -- and the set as it was.  With nothing of the session's left to
undo the session ends and the key is the widget's."
  (let ((entry (if redo (pop (iedit-redo-log st)) (pop (iedit-undo-log st)))))
    (cond ((null entry)
           (iedit-end doc (if redo "nothing of it to redo" "undone past its start"))
           (doc-edit doc (if redo :redo :undo)))
          (t
           (let ((after (list (first entry) (iedit-starts st) (iedit-length st) (iedit-text st))))
             (with-quiet-display (doc)
               (dotimes (i (first entry))
                 (doc-edit doc (if redo :redo :undo))))
             (if redo
                 (push after (iedit-undo-log st))
                 (push after (iedit-redo-log st)))
             (iedit-restore st entry)
             (setf (iedit-current st) (iedit-index-at st (doc-point doc)))
             (iedit-validate doc st)
             (let ((st (doc-iedit doc)))
               (when st
                 (iedit-paint doc st))))))))

;;; ------------------------------------------------------------------
;;; Around a key or a command
;;; ------------------------------------------------------------------

(defun iedit-around (doc command function)
  "Call FUNCTION, what a key or COMMAND (a symbol, or NIL for a typed
key) does, and when a session is on, place the edit it made and mirror
it.  Undo and redo are the session's own.  The outermost call does the
accounting; a command run from inside another is part of it."
  (let ((st (doc-iedit doc)))
    (cond ((or (null st) *iedit-inside*)
           (funcall function))
          ((member command '(undo redo))
           (let ((*iedit-inside* t))
             (iedit-undo doc st (eq command 'redo))))
          (t
           (let* ((*iedit-inside* t)
                  (y (doc-index-line doc (doc-point doc)))
                  (lines (doc-line-count doc))
                  (end (doc-end doc))
                  (line (doc-lines-text doc y y)))
             (funcall function)
             (when (eq (doc-iedit doc) st)
               (iedit-after doc st y lines end line)))))))

(defun iedit-after (doc st y lines end line)
  "What the key did to the text, from the cursor's LINE as it was: a
change on that line is placed and mirrored; one that changed the line
count, or happened elsewhere, ends the session."
  (let ((end-now (doc-end doc)))
    (cond ((/= (doc-line-count doc) lines)
           (iedit-end doc "the edit added or removed a line"))
          (t
           (let ((now (doc-lines-text doc y y)))
             (cond ((and (= end-now end) (string= line now))
                    (iedit-note-point doc))
                   ((/= (- (length now) (length line)) (- end-now end))
                    (iedit-end doc "the text changed off the cursor's line"))
                   (t
                    (multiple-value-bind (from to insert) (text-diff line now)
                      (let ((base (doc-line-index doc y)))
                        (iedit-marks-down doc st y base (length line) (+ base to)
                                          (- (length now) (length line)))
                        (iedit-apply-change doc st (+ base from) (+ base to) insert t))))))))))

(defun iedit-marks-down (doc st y base old-length to delta)
  "The marks as they were painted BEFORE the edit, taken down, so that
the ones painted after it do not sit beside them: for an occurrence on
the edited line Y (which started at BASE and was OLD-LENGTH long) its
old column, for one on any other line the place it has now -- that line
has not changed -- which is its index moved by DELTA when it was at or
after TO."
  (dolist (start (iedit-starts st))
    (multiple-value-bind (yy x)
        (if (and (>= start base) (< start (+ base old-length)))
            (values y (- start base))
            (doc-index-line doc (if (>= start to) (+ start delta) start)))
      (doc-style doc yy x (+ x (iedit-length st)) nil))))

;;; ------------------------------------------------------------------
;;; The keys the session binds, over every keymap
;;; ------------------------------------------------------------------

(defun iedit-key-command (key)
  "The session's own command for KEY, or NIL: M-n, M-p and M-; while a
session is on."
  (cond ((eql key (make-key (char-code #\n) +mod-meta+)) 'clamacs-iedit-next)
        ((eql key (make-key (char-code #\p) +mod-meta+)) 'clamacs-iedit-previous)
        ((eql key (make-key (char-code #\;) +mod-meta+)) 'clamacs-iedit-toggle-occurrence)
        (t nil)))

(defun iedit-self-insert (doc key)
  "A key the widget would edit with on its own, done through the protocol
instead so the session sees it: true when KEY was one.  A key that moves
stays the widget's."
  (let ((code (key-code key)))
    (cond ((/= (key-mods key) 0) nil)
          ((printable-key-p key) (doc-insert doc (string (code-char code))) t)
          ((= code +key-backspace+) (doc-edit doc :backspace) t)
          ((= code +key-delete+) (doc-edit doc :delete) t)
          ((= code +key-return+) (doc-insert doc (string #\Newline)) t)
          ((= code +key-tab+) (doc-insert doc (string #\Tab)) t)
          (t nil))))

(defun iedit-handle-key (doc key)
  "HANDLE-KEY's first look at a key while a session is on and no prefix
is pending: the session's own keys, and the edits the widget would make
itself.  True when the key was taken."
  (let ((command (iedit-key-command key)))
    (cond (command
           (run-command doc command)
           t)
          (t
           (let ((taken nil))
             (iedit-around doc nil (lambda () (setq taken (iedit-self-insert doc key))))
             (when taken
               (setf (doc-last-command doc) nil))
             taken)))))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(define-command clamacs-iedit (doc arg)
  "Edit every occurrence of the symbol at point at once, or stop: with a
session on, end it.  The occurrences are those in the current defun;
with `C-u' those in the whole buffer.  M-n and M-p move between them,
M-; drops the one at point, C-g ends the session."
  (cond ((doc-iedit doc)
         (iedit-end doc))
        ((doc-repl doc)
         (doc-message doc "iedit is not available in the REPL")
         (doc-beep doc))
        (t
         (iedit-start doc (if (and (eql arg 1) (doc-lisp-mode doc)) :defun :buffer)))))

(defun iedit-move (doc step)
  (let ((st (doc-iedit doc)))
    (cond ((null st)
           (doc-message doc "No iedit session")
           (doc-beep doc))
          (t
           (let* ((starts (iedit-starts st))
                  (n (length starts))
                  (point (doc-point doc))
                  ;; Where the cursor is NOW: a frontend reports a move
                  ;; after the key, so the remembered one may be stale
                  (k (iedit-index-at st point))
                  (next (cond (k (mod (+ k step) n))
                              ((> step 0)
                               (or (position-if (lambda (s) (> s point)) starts) 0))
                              (t
                               (or (position-if (lambda (s) (< s point)) starts :from-end t)
                                   (1- n))))))
             (doc-set-point doc (nth next starts))
             (iedit-note-point doc)
             (message doc "iedit: occurrence ~D of ~D" (1+ next) n))))))

(define-command clamacs-iedit-next (doc arg)
  "Move to the next occurrence of the iedit session, around to the first."
  (declare (ignore arg))
  (iedit-move doc 1))

(define-command clamacs-iedit-previous (doc arg)
  "Move to the previous occurrence of the iedit session, around to the last."
  (declare (ignore arg))
  (iedit-move doc -1))

(define-command clamacs-iedit-toggle-occurrence (doc arg)
  "Drop the occurrence at point out of the iedit session: edits no longer
reach it."
  (declare (ignore arg))
  (let* ((st (doc-iedit doc))
         (k (and st (iedit-current st))))
    (cond ((null st)
           (doc-message doc "No iedit session")
           (doc-beep doc))
          ((null k)
           (doc-message doc "The cursor is not in an occurrence")
           (doc-beep doc))
          (t
           (iedit-drop doc st k)
           (let ((st (doc-iedit doc)))
             (when st
               (message doc "iedit: ~D occurrences left" (length (iedit-starts st)))))))))

;;; ------------------------------------------------------------------
;;; The port: IEDIT answers the session's state for a macro
;;; ------------------------------------------------------------------

;;; IEDIT: `off', or `N TEXT START-END ...' -- the count, the symbol as
;;; it reads now, and each occurrence's indices, the one under the cursor
;;; starred.
(define-port-verb "IEDIT" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (let ((st (doc-iedit doc)))
      (values +rc-ok+
              (if (null st)
                  "off"
                  (with-output-to-string (out)
                    (format out "~D ~A" (length (iedit-starts st)) (iedit-text st))
                    (let ((k 0))
                      (dolist (start (iedit-starts st))
                        (format out " ~:[~;*~]~D-~D" (eql k (iedit-current st))
                                start (iedit-end-index st start))
                        (incf k)))))))))
