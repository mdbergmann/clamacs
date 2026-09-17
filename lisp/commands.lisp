;;;; commands.lisp -- the command loop and the editing commands.
;;;;
;;;; A command is a function of the document and the numeric argument,
;;;; written against the frontend protocol (frontend.lisp) and nothing else,
;;;; so tests/test-commands.lisp runs every one of them on the host against
;;;; a string.  This file holds the commands that need neither a prompt nor
;;;; clamiga: motion, killing and yanking, the mark, the sexp commands,
;;;; indentation, and the two things that follow the cursor and the text --
;;;; the paren highlight and the colouring.
;;;;
;;;; The behaviour is src/document.c's.  Three deliberate differences: a
;;;; backward kill joins a run of kills (C forgot `backward-kill-word' in
;;;; its list, so `M-DEL M-DEL' made two entries), colouring one line stops
;;;; tokenizing at that line instead of at the end of the context, and
;;;; indent-region works top-down (see there).
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The command loop
;;; ------------------------------------------------------------------

(defun run-command (doc command &optional (arg 1))
  "Run COMMAND, a command symbol, on DOC.  True when it ran."
  (let ((function (command-function command)))
    (cond (function
           (funcall function doc arg)
           (setf (doc-last-command doc) command)
           t)
          (t
           (message doc "~A is not implemented"
                    (or (command-name command) command))
           (doc-beep doc)
           (setf (doc-last-command doc) nil)
           nil))))

(defun handle-key (doc key)
  "Feed KEY to DOC's key state machine and act on the answer.  True when
the key was the Emacs layer's; NIL hands it to the widget, which is how the
class's own arrows, selection and self-insert keep working."
  (let ((keys (doc-keys doc)))
    (multiple-value-bind (result command) (keystate-feed keys key)
      (case result
        (:command
         (run-command doc command (keystate-take-arg keys))
         t)
        ((:prefix :arg)
         (doc-message doc (keystate-describe keys))
         t)
        (:undefined
         (message doc "~Ais undefined" (keystate-describe keys))
         (doc-beep doc)
         t)
        (:cancel
         (doc-message doc "Quit")
         t)
        (t
         ;; Not ours, and ordinary typing ends a run of kills or yanks.
         (setf (doc-last-command doc) nil)
         nil)))))

;;; ------------------------------------------------------------------
;;; The context: text the sexp scanner can trust
;;; ------------------------------------------------------------------

;;; Lines either side of the cursor for the things that run on every
;;; keystroke.
(defconstant +context-lines+ 200)

(defun context-skip (text first-line-p)
  "How much of TEXT to drop so that offset 0 is outside any string and any
comment -- the sexp scanner's contract.  A `(' in column 0 is the cheap way
to guarantee that: it is a defun start by definition.  NIL when TEXT holds
none and is not the start of the buffer, where offset 0 needs no proof."
  (declare (simple-string text))
  (let ((n (length text)))
    (declare (fixnum n))
    (cond (first-line-p 0)
          ((and (> n 0) (char= (schar text 0) #\()) 0)
          (t (let ((i 0))
               (declare (fixnum i))
               (loop
                 (when (>= (1+ i) n)
                   (return nil))
                 (when (and (char= (schar text i) #\Newline)
                            (char= (schar text (1+ i)) #\())
                   (return (1+ i)))
                 (incf i)))))))

(defun doc-context-range (doc y0 y1)
  "Lines Y0..Y1 from a trustworthy start.  Three values: the text, the index
of its first character in the document, and the cursor as an offset into it
(clamped); or NIL."
  (let* ((y0 (max y0 0))
         (y1 (max y1 y0))
         (text (doc-lines-text doc y0 y1))
         (skip (context-skip text (= y0 0))))
    (when skip
      (let* ((base (+ (doc-line-index doc y0) skip))
             (text (if (= skip 0) text (subseq text skip)))
             (point (- (doc-point doc) base)))
        (values text base (max 0 (min point (length text))))))))

(defun doc-context-full (doc)
  "The whole buffer, for the structural commands -- end-of-defun, the sexp
motions, and everything that hands a form to clamiga.  A window is wrong for
these: a defun whose closing paren falls outside it reads as unbalanced.
They are single user actions, not per-keystroke work."
  (doc-context-range doc 0 (1- (doc-line-count doc))))

(defun doc-context (doc)
  "The window around the cursor, for what runs on every keystroke:
colouring, paren matching, indentation.  It reaches forward as well as back,
since a paren typed at point can have its partner below."
  (let* ((y (doc-index-line doc (doc-point doc)))
         (last (1- (doc-line-count doc)))
         (y1 (min last (+ y +context-lines+))))
    (multiple-value-bind (text base point)
        (doc-context-range doc (- y +context-lines+) y1)
      (if text
          (values text base point)
          ;; No `(' in column 0 in the window.
          (doc-context-full doc)))))

;;; ------------------------------------------------------------------
;;; Helpers
;;; ------------------------------------------------------------------

(defun repeat-move (doc motion times)
  (dotimes (i (abs times))
    (unless (doc-move doc motion)
      (return))))

(defun repeat-edit (doc operation times)
  (dotimes (i (abs times))
    (unless (doc-edit doc operation)
      (return))))

(defun take-region (doc start stop erase)
  "The text from START to STOP, deleted when ERASE; NIL for an empty range."
  (when (> stop start)
    (let ((text (doc-text doc start stop)))
      (when erase
        (doc-delete doc start stop))
      text)))

(defun last-was-kill-p (doc)
  (member (doc-last-command doc)
          '(kill-line kill-word backward-kill-word kill-sexp)))

(defun kill-text (doc text backwards)
  "Put TEXT on the kill ring: joined to the last kill when the previous
command was a kill too, at the front for a backward kill."
  (when text
    (let ((ring (doc-kill-ring doc)))
      (cond ((not (last-was-kill-p doc)) (kill-push ring text))
            (backwards (kill-prepend ring text))
            (t (kill-append ring text))))))

(defun region-bounds (doc)
  "START and STOP of the region, or NIL (and a message) without a mark."
  (let ((mark (doc-mark doc))
        (point (doc-point doc)))
    (cond (mark (values (min mark point) (max mark point)))
          (t (doc-message doc "No mark set in this buffer")
             (doc-beep doc)
             nil))))

;;; ------------------------------------------------------------------
;;; Motion and simple edits, delegated to the widget
;;; ------------------------------------------------------------------

(define-command forward-char (doc arg)
  (repeat-move doc (if (< arg 0) :left :right) arg))

(define-command backward-char (doc arg)
  (repeat-move doc (if (< arg 0) :right :left) arg))

(define-command next-line (doc arg)
  (repeat-move doc (if (< arg 0) :up :down) arg))

(define-command previous-line (doc arg)
  (repeat-move doc (if (< arg 0) :down :up) arg))

(define-command beginning-of-line (doc arg)
  (declare (ignore arg))
  (doc-move doc :line-start))

(define-command end-of-line (doc arg)
  (declare (ignore arg))
  (doc-move doc :line-end))

(define-command forward-word (doc arg)
  (repeat-move doc :next-word arg))

(define-command backward-word (doc arg)
  (repeat-move doc :previous-word arg))

(define-command beginning-of-buffer (doc arg)
  (declare (ignore arg))
  (doc-move doc :text-start))

(define-command end-of-buffer (doc arg)
  (declare (ignore arg))
  (doc-move doc :text-end))

(define-command scroll-up (doc arg)
  (repeat-move doc :next-page arg))

(define-command scroll-down (doc arg)
  (repeat-move doc :previous-page arg))

(define-command recenter (doc arg)
  (declare (ignore arg))
  (colour-all doc))

(define-command delete-char (doc arg)
  (repeat-edit doc :delete arg))

(define-command backward-delete-char (doc arg)
  (repeat-edit doc :backspace arg))

(define-command undo (doc arg)
  (declare (ignore arg))
  (doc-edit doc :undo))

(define-command redo (doc arg)
  (declare (ignore arg))
  (doc-edit doc :redo))

(define-command mark-whole-buffer (doc arg)
  (declare (ignore arg))
  (doc-edit doc :select-all))

(define-command keyboard-quit (doc arg)
  (declare (ignore arg))
  (setf (doc-mark doc) nil)
  (doc-edit doc :select-none)
  (doc-message doc "Quit"))

;;; ------------------------------------------------------------------
;;; Killing and yanking
;;; ------------------------------------------------------------------

(define-command kill-word (doc arg)
  (let ((start (doc-point doc)))
    (repeat-move doc :next-word arg)
    (let ((stop (doc-point doc)))
      (doc-set-point doc start)
      (kill-text doc (take-region doc start stop t) nil))))

(define-command backward-kill-word (doc arg)
  (let ((stop (doc-point doc)))
    (repeat-move doc :previous-word arg)
    (kill-text doc (take-region doc (doc-point doc) stop t) t)))

(define-command kill-line (doc arg)
  (multiple-value-bind (text base point) (doc-context doc)
    (declare (simple-string text) (fixnum point))
    (let ((len (length text))
          (stop point))
      (declare (fixnum len stop))
      (flet ((to-line-end ()
               (loop
                 (unless (and (< stop len)
                              (char/= (schar text stop) #\Newline))
                   (return))
                 (incf stop))))
        (to-line-end)
        ;; At the end of a line, C-k joins it with the next one.
        (when (and (= stop point) (< stop len))
          (incf stop))
        (let ((lines arg))
          (loop
            (unless (and (> lines 1) (< stop len))
              (return))
            (incf stop)                 ; over the newline
            (to-line-end)
            (decf lines))))
      (kill-text doc (take-region doc (+ base point) (+ base stop) t) nil))))

(defun region-command (doc erase)
  (multiple-value-bind (start stop) (region-bounds doc)
    (when start
      (let ((text (take-region doc start stop nil)))
        (when text
          ;; C-w and M-w also put the text on the clipboard, so other
          ;; applications see the last kill.
          (doc-clipboard-copy doc start stop erase)
          (kill-push (doc-kill-ring doc) text)))
      (setf (doc-mark doc) nil))))

(define-command kill-region (doc arg)
  (declare (ignore arg))
  (region-command doc t))

(define-command kill-ring-save (doc arg)
  (declare (ignore arg))
  (region-command doc nil))

(defun yank-text (doc text)
  (cond (text (doc-insert doc text))
        (t (doc-message doc "Kill ring is empty")
           (doc-beep doc))))

(define-command yank (doc arg)
  (declare (ignore arg))
  (let ((ring (doc-kill-ring doc)))
    (kill-reset-yank ring)
    (yank-text doc (kill-current ring))))

(define-command yank-pop (doc arg)
  (declare (ignore arg))
  (cond ((not (member (doc-last-command doc) '(yank yank-pop)))
         (doc-message doc "Previous command was not a yank")
         (doc-beep doc))
        (t
         (let ((text (kill-rotate (doc-kill-ring doc))))
           ;; M-y replaces what the previous yank inserted, and that yank
           ;; was one undo step of the widget.
           (when text
             (doc-edit doc :undo))
           (yank-text doc text)))))

;;; ------------------------------------------------------------------
;;; The mark
;;; ------------------------------------------------------------------

(define-command set-mark-command (doc arg)
  (declare (ignore arg))
  (setf (doc-mark doc) (doc-point doc))
  (doc-message doc "Mark set"))

(define-command exchange-point-and-mark (doc arg)
  (declare (ignore arg))
  (let ((mark (doc-mark doc))
        (point (doc-point doc)))
    (cond (mark
           (doc-set-point doc mark)
           (setf (doc-mark doc) point))
          (t
           (doc-message doc "No mark set in this buffer")
           (doc-beep doc)))))

;;; ------------------------------------------------------------------
;;; Lisp structure
;;; ------------------------------------------------------------------

(defun sexp-move (doc arg mover)
  "Move by MOVER, one of the SEXP- navigation functions, ARG times: as far
as it goes, and a complaint when it does not go at all."
  (multiple-value-bind (text base point) (doc-context-full doc)
    (let ((pos point)
          (moved nil))
      (dotimes (i (abs arg))
        (let ((target (funcall mover text pos)))
          (unless target
            (return))
          (setq pos target
                moved t)))
      (cond ((or moved (= arg 0))
             (doc-set-point doc (+ base pos)))
            (t
             (doc-message doc "No further expression")
             (doc-beep doc))))))

(define-command forward-sexp (doc arg)
  (sexp-move doc arg #'sexp-forward))

(define-command backward-sexp (doc arg)
  (sexp-move doc arg #'sexp-backward))

(define-command backward-up-list (doc arg)
  (sexp-move doc arg #'sexp-up))

(define-command down-list (doc arg)
  (sexp-move doc arg #'sexp-down))

(define-command beginning-of-defun (doc arg)
  (sexp-move doc arg #'sexp-defun-start))

(define-command end-of-defun (doc arg)
  (sexp-move doc arg #'sexp-defun-end))

(define-command kill-sexp (doc arg)
  (declare (ignore arg))
  (multiple-value-bind (text base point) (doc-context-full doc)
    (let ((stop (sexp-forward text point)))
      (cond (stop
             (kill-text doc
                        (take-region doc (+ base point) (+ base stop) t)
                        nil))
            (t
             (doc-message doc "No expression after point")
             (doc-beep doc))))))

(define-command insert-parentheses (doc arg)
  (declare (ignore arg))
  (doc-insert doc "()")
  (doc-move doc :left))

;;; ------------------------------------------------------------------
;;; Indentation
;;; ------------------------------------------------------------------

(defun reindent-line (doc y column)
  "Replace the leading whitespace of line Y with COLUMN spaces.

The cursor follows the text: a cursor that was inside the indentation ends up
at the first non-blank character (which is what Emacs does, and is why TAB
at the start of an already-correct line still moves point), and one that was
in the text keeps its position relative to it."
  (let* ((line (doc-lines-text doc y y))
         (start (doc-line-index doc y))
         (cx (- (doc-point doc) start))
         (old 0))
    (declare (simple-string line) (fixnum old))
    (loop
      (unless (and (< old (length line))
                   (let ((c (schar line old)))
                     (or (char= c #\Space) (char= c #\Tab))))
        (return))
      (incf old))
    (when (/= old column)
      ;; One delete, not N backspaces: one undo step, and the clipboard is
      ;; left alone.
      (when (> old 0)
        (doc-delete doc start (+ start old)))
      (doc-set-point doc start)
      (when (> column 0)
        (doc-insert doc (make-string column :initial-element #\Space))))
    (doc-set-point doc (+ start (if (<= cx old)
                                    column
                                    (+ (- cx old) column))))))

(defun indent-current-line (doc)
  (multiple-value-bind (text base point) (doc-context doc)
    (declare (ignore base))
    (let ((column (indent-for-line text (indent-line-start text point))))
      ;; NIL inside a multi-line string: reindenting would edit the string.
      (when column
        (reindent-line doc (doc-index-line doc (doc-point doc)) column)))))

(define-command indent-for-tab-command (doc arg)
  (declare (ignore arg))
  (indent-current-line doc))

(define-command newline-and-indent (doc arg)
  (declare (ignore arg))
  (doc-insert doc (string #\Newline))
  (indent-current-line doc))

(define-command indent-region (doc arg)
  (declare (ignore arg))
  (multiple-value-bind (start stop) (region-bounds doc)
    (when start
      (let ((y0 (doc-index-line doc start))
            (y1 (doc-index-line doc stop)))
        ;; Top to bottom: a line's indentation depends on the lines above
        ;; it as they will be, and reindenting moves offsets but no line
        ;; numbers.  (The C editor went bottom-up and so indented a line
        ;; against a parent that had not moved yet.)
        (with-quiet-display (doc)
          (loop for y from y0 to y1
                do (doc-set-point doc (doc-line-index doc y))
                   (indent-current-line doc)))
        (message doc "Indented ~D line(s)" (1+ (- y1 y0)))))))

;;; ------------------------------------------------------------------
;;; Following the cursor and the text.  The frontend calls NOTE-CURSOR-MOVED
;;; and NOTE-TEXT-CHANGED from the widget's notifications.
;;; ------------------------------------------------------------------

(defun colour-kind-p (kind)
  (member kind '(:comment :string :char :keyword :number :defining)))

(defun colour-one-line (doc y line state)
  (let ((tokens (tokenize-line line state)))
    ;; Clear first: a token that shrank must not leave its old colour behind
    ;; on the characters it no longer covers.
    (when (> (length line) 0)
      (doc-colour doc y 0 (length line) nil))
    (dolist (token tokens)
      (when (colour-kind-p (token-kind token))
        (doc-colour doc y (token-start token)
                    (+ (token-start token) (token-len token))
                    (token-kind token))))))

(defmacro do-text-lines ((line text) &body body)
  "Run BODY with LINE bound to each line of TEXT (a fresh string, without
its newline); a trailing newline does not open another line."
  (let ((start (gensym "START")) (nl (gensym "NL")) (len (gensym "LEN")))
    `(let ((,start 0) (,len (length ,text)))
       (loop
         (when (>= ,start ,len)
           (return))
         (let* ((,nl (or (position #\Newline ,text :start ,start) ,len))
                (,line (subseq ,text ,start ,nl)))
           ,@body
           (setq ,start (1+ ,nl)))))))

(defun colour-all (doc)
  "Colour the whole text, as after loading a file."
  (when (doc-lisp-mode doc)
    (let ((text (doc-text doc 0 (doc-end doc)))
          (state (make-tok-state))
          (y 0))
      (with-quiet-display (doc)
        (do-text-lines (line text)
          (colour-one-line doc y line state)
          (incf y))))))

(defun colour-line (doc line-number)
  "Recolour one line.  The context starts at a defun, where the tokenizer
state is known to be plain code -- so the state carried down to the line is
correct without rescanning the whole file."
  (when (doc-lisp-mode doc)
    (multiple-value-bind (text base) (doc-context doc)
      (let ((state (make-tok-state))
            (y (doc-index-line doc base)))
        (do-text-lines (line text)
          (when (= y line-number)
            (colour-one-line doc y line state)
            (return))
          (tokenize-line line state)
          (incf y))))))

(defun show-paren (doc)
  "Highlight the partner of the paren BEFORE point, which is where the
cursor sits after typing a `)' -- Emacs's rule."
  (when (doc-lisp-mode doc)
    ;; Take the previous highlight down first.
    (let ((shown (doc-paren-shown doc)))
      (when shown
        (doc-colour doc (car shown) (cdr shown) (1+ (cdr shown)) nil)
        (setf (doc-paren-shown doc) nil)))
    (multiple-value-bind (text base point) (doc-context doc)
      (let ((partner (and (> point 0)
                          (sexp-match-paren text (1- point)))))
        (when partner
          (multiple-value-bind (y x) (doc-index-line doc (+ base partner))
            (doc-colour doc y x (1+ x) :paren-match)
            (setf (doc-paren-shown doc) (cons y x))))))))

(defun note-cursor-moved (doc)
  (show-paren doc))

(defun note-text-changed (doc)
  (colour-line doc (doc-index-line doc (doc-point doc))))
