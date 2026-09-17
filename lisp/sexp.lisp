;;;; sexp.lisp -- the s-expression scanner.
;;;;
;;;; Operates on a flat string, because that is what the text area can give
;;;; us: TextEditor.mcc has no line-access API, so structural editing works
;;;; on text exported with MUIM_TextEditor_ExportBlock over a range of full
;;;; lines (specs/clamacs-ide.md, "Text access").
;;;;
;;;; CONTRACT: offset 0 of BUF must be outside any string and any comment.
;;;; The frontend guarantees that by exporting from a defun start -- a `(' in
;;;; column 0 -- or from the start of the buffer.  Every function here scans
;;;; from 0, so a buffer that violates the contract gives wrong answers
;;;; rather than signalling.
;;;;
;;;; All positions are character indexes into BUF.  Every navigation function
;;;; returns NIL when the move is not possible, which is what a command turns
;;;; into a beep and a message rather than a wrong cursor position.
;;;;
;;;; Everything here is built on one low-level walker, SX-NEXT, and every
;;;; public function is a single left-to-right pass over it starting at
;;;; offset 0.  That is deliberate: a backwards scanner cannot tell a `;'
;;;; that starts a comment from a `;' inside a string without reading forward
;;;; anyway, and a defun-sized buffer is small enough that one pass costs
;;;; nothing even on a 68020.  It also means there is exactly one place where
;;;; Lisp lexical rules live, so `#\(' and "a ) in a string" cannot be right
;;;; in one function and wrong in the next.
;;;;
;;;; This is a port of src/lisp/sexp.c and answers exactly what it answers,
;;;; quirks included; the function names are the C names without the ck_
;;;; prefix so the two read side by side.  Where the C code keeps an array
;;;; of CK_SX_MAX_DEPTH + 1 ints on the stack, the Lisp keeps a list used as
;;;; a stack -- one cons per open paren, no vector per call -- and the same
;;;; depth limit with the same answer ("not possible") beyond it.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +sx-max-depth+ 128)

;;; ------------------------------------------------------------------
;;; Character classes
;;; ------------------------------------------------------------------

(declaim (inline sx-space-p sx-terminating-p sx-constituent-p
                 sx-symbol-char-p sx-paren-p))

(defun sx-space-p (c)
  (declare (character c))
  (case c
    ((#\Space #\Tab #\Newline #\Return #\Page) t)
    (t nil)))

(defun sx-terminating-p (c)
  (declare (character c))
  (case c
    ((#\Space #\Tab #\Newline #\Return #\Page
      #\( #\) #\[ #\] #\" #\; #\' #\` #\,)
     t)
    (t nil)))

;;; What may follow the first character of a character literal: `#\Space'
;;; is one atom, `#\(' ends after the paren.
(defun sx-constituent-p (c)
  (declare (character c))
  (or (char<= #\a c #\z) (char<= #\A c #\Z) (char<= #\0 c #\9)
      (char= c #\-)))

(defun sx-symbol-char-p (c)
  (declare (character c))
  (and (char/= c (code-char 0)) (not (sx-terminating-p c))))

(defun sx-paren-p (c)
  (declare (character c))
  (case c
    ((#\( #\) #\[ #\]) t)
    (t nil)))

(defun sx-simple (buf)
  "BUF as a SIMPLE-STRING, which is what the scanning loops are declared
for.  The public functions call this once at their boundary; a buffer that
is already simple -- the normal case -- is returned as it is.  NIL is the
empty buffer."
  (cond ((simple-string-p buf) buf)
        ((null buf) "")
        (t (coerce buf 'simple-string))))

;;; ------------------------------------------------------------------
;;; The walker
;;; ------------------------------------------------------------------

(defun sx-next (buf len pos)
  "Read the token at or after POS.  Returns three values, KIND START END --
no token object is allocated -- and the caller continues from END.  KIND is
one of
  :EOF      the end of the buffer
  :OPEN     ( or [
  :CLOSE    ) or ]
  :ATOM     symbol, number, character literal
  :STRING   \"...\"
  :QUOTE    ' ` , ,@ and the `#' of #' #( and other dispatch prefixes
  :COMMENT  ; to end of line, or #| ... |#
Whitespace is skipped; comments are RETURNED rather than skipped, so a
caller can tell \"inside a comment\" from \"between forms\".  Exposed because
the indenter walks the same stream."
  (declare (simple-string buf) (fixnum len pos))
  (let ((p (if (< pos 0) 0 pos)))
    (declare (fixnum p))
    (loop
      (unless (and (< p len) (sx-space-p (schar buf p)))
        (return))
      (incf p))
    (when (>= p len)
      (return-from sx-next (values :eof p len)))
    (let ((start p)
          (kind :atom)
          (c (schar buf p)))
      (declare (fixnum start))
      (case c
        (#\;
         (loop
           (unless (and (< p len) (char/= (schar buf p) #\Newline))
             (return))
           (incf p))
         (setq kind :comment))
        (#\#
         (cond
           ((and (< (+ p 1) len) (char= (schar buf (+ p 1)) #\|))
            ;; #| ... |#, which nests.
            (let ((depth 0))
              (declare (fixnum depth))
              (loop
                (when (>= p len)
                  (return))
                (cond ((and (< (+ p 1) len)
                            (char= (schar buf p) #\#)
                            (char= (schar buf (+ p 1)) #\|))
                       (incf depth)
                       (incf p 2))
                      ((and (< (+ p 1) len)
                            (char= (schar buf p) #\|)
                            (char= (schar buf (+ p 1)) #\#))
                       (decf depth)
                       (incf p 2)
                       (when (= depth 0)
                         (return)))
                      (t (incf p)))))
            (setq kind :comment))
           ((and (< (+ p 1) len) (char= (schar buf (+ p 1)) #\\))
            ;; A character literal.  Handled before the general `#' case
            ;; because `#\(' and `#\;' must not be read as a paren or a
            ;; comment.
            (incf p 2)
            (when (< p len)
              (incf p))
            (loop
              (unless (and (< p len) (sx-constituent-p (schar buf p)))
                (return))
              (incf p)))
           (t
            ;; Any other dispatch macro: #', #(, #x10, #p"...".  One
            ;; character of prefix, then the form that follows -- which is
            ;; what makes forward-sexp treat `#(1 2 3)' as a single form.
            (incf p)
            (setq kind :quote))))
        (#\"
         (incf p)
         (loop
           (when (>= p len)
             (return))
           (let ((d (schar buf p)))
             (cond ((char= d #\\) (incf p 2))
                   ((char= d #\") (incf p) (return))
                   (t (incf p)))))
         ;; A backslash as the last character skipped past the end.
         (when (> p len)
           (setq p len))
         (setq kind :string))
        ((#\( #\[)
         (incf p)
         (setq kind :open))
        ((#\) #\])
         (incf p)
         (setq kind :close))
        ((#\' #\`)
         (incf p)
         (setq kind :quote))
        (#\,
         (incf p)
         (when (and (< p len) (char= (schar buf p) #\@))
           (incf p))
         (setq kind :quote))
        (t
         (loop
           (when (>= p len)
             (return))
           (let ((d (schar buf p)))
             (cond ((char= d #\|)       ; |symbol with spaces|
                    (incf p)
                    (loop
                      (unless (and (< p len) (char/= (schar buf p) #\|))
                        (return))
                      (when (char= (schar buf p) #\\)
                        (incf p))
                      (incf p))
                    (when (< p len)
                      (incf p)))
                   ((char= d #\\) (incf p 2))
                   ((sx-terminating-p d) (return))
                   (t (incf p)))))
         (when (> p len)
           (setq p len))
         ;; A lone terminating character we do not otherwise handle: never
         ;; loop on it.
         (when (= p start)
           (incf p))))
      (values kind start p))))

(defmacro do-sx-tokens ((kind start end buf len &optional (from 0))
                        &body body)
  "Run BODY for each token of BUF from FROM on, with KIND, START and END
bound to the token, until the walker answers :EOF or BODY does (RETURN).
The `while (ck_sx_next(...) != CK_SX_EOF)' of the C code."
  (let ((p (gensym "P")))
    `(let ((,p ,from))
       (declare (fixnum ,p))
       (loop
         (multiple-value-bind (,kind ,start ,end) (sx-next ,buf ,len ,p)
           (declare (fixnum ,start ,end) (ignorable ,start))
           (when (eq ,kind :eof)
             (return nil))
           (setq ,p ,end)
           ,@body)))))

;;; ------------------------------------------------------------------
;;; Context
;;; ------------------------------------------------------------------

(defun sexp-context (buf pos)
  "What kind of text POS sits in: :CODE, :STRING or :COMMENT."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf)))
    (declare (simple-string buf) (fixnum len))
    (when (or (<= pos 0) (> pos len))
      (return-from sexp-context :code))
    (do-sx-tokens (kind start end buf len)
      (when (>= start pos)
        (return))
      (when (> end pos)
        (return-from sexp-context
          (case kind
            (:string :string)
            (:comment :comment)
            (t :code)))))
    :code))

;;; ------------------------------------------------------------------
;;; Navigation.  POS is the cursor; the value is where the cursor should
;;; end up, or NIL.
;;; ------------------------------------------------------------------

(defun sx-token-at (buf len pos)
  "The first token that is relevant to a forward move from POS: the token
containing POS, or the first one starting at or after it.  Comments are
skipped.  Returns KIND START END, or NIL when there is none."
  (declare (simple-string buf) (fixnum len pos))
  (do-sx-tokens (kind start end buf len)
    (unless (or (eq kind :comment) (<= end pos))
      (return (values kind start end)))))

(defun sexp-forward (buf pos)
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf)))
    (declare (simple-string buf) (fixnum len))
    (when (<= len 0)
      (return-from sexp-forward nil))
    (when (< pos 0)
      (setq pos 0))
    (multiple-value-bind (kind start end) (sx-token-at buf len pos)
      (unless kind
        (return-from sexp-forward nil))
      ;; Inside an atom or a string: move to its end, as Emacs does.
      (when (< start pos)
        (return-from sexp-forward
          (if (or (eq kind :atom) (eq kind :string)) end nil)))
      ;; Skip any prefix characters; the form they introduce is the one we
      ;; move over.
      (loop
        (unless (or (eq kind :quote) (eq kind :comment))
          (return))
        (multiple-value-setq (kind start end) (sx-next buf len end))
        (when (eq kind :eof)
          (return-from sexp-forward nil)))
      (case kind
        ((:atom :string) end)
        (:open
         (let ((depth 1))
           (declare (fixnum depth))
           (do-sx-tokens (k s e buf len end)
             (case k
               (:open
                (incf depth)
                (when (> depth +sx-max-depth+)
                  (return nil)))
               (:close
                (decf depth)
                (when (= depth 0)
                  (return e)))))))  ; NIL at :EOF -- unbalanced
        (t nil)))))

(defun sexp-backward (buf pos)
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         ;; The C code keeps PENDING and LAST per depth.  Only the current
         ;; level's are ever read: an open paren clears the outer PENDING,
         ;; and the close paren that returns to a level overwrites its LAST
         ;; with the start of the list just closed.  So the starts of the
         ;; open lists are all that needs a stack.
         (pending nil)     ; start of a form introduced by prefix characters
         (last nil)        ; start of the last complete form at this level
         (form-open '()))
    (declare (simple-string buf) (fixnum len depth))
    (when (or (<= len 0) (<= pos 0))
      (return-from sexp-backward nil))
    (when (> pos len)
      (setq pos len))
    (do-sx-tokens (kind start end buf len)
      (cond
        ((eq kind :comment))
        ((>= start pos) (return))
        ((> end pos)
         ;; POS sits inside this token.  For an atom or a string that is the
         ;; form we are standing in, so its start is the answer.
         (when (or (eq kind :atom) (eq kind :string))
           (return-from sexp-backward (or pending start)))
         (return))
        (t
         (case kind
           (:quote
            (unless pending
              (setq pending start)))
           ((:atom :string)
            (setq last (or pending start)
                  pending nil))
           (:open
            (when (>= depth +sx-max-depth+)
              (return-from sexp-backward nil))
            (push (or pending start) form-open)
            (incf depth)
            (setq pending nil
                  last nil))
           (:close
            (when (> depth 0)
              (decf depth)
              (setq last (pop form-open)
                    pending nil)))))))
    last))

(defun sexp-up (buf pos)
  "backward-up-list: the enclosing open paren."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         (open-at '()))
    (declare (simple-string buf) (fixnum len depth))
    (when (or (<= len 0) (<= pos 0))
      (return-from sexp-up nil))
    (when (> pos len)
      (setq pos len))
    (do-sx-tokens (kind start end buf len)
      (cond
        ((eq kind :comment))
        ((>= start pos) (return))
        ;; Inside an atom or string: the enclosing list stands.
        ((> end pos) (return))
        ((eq kind :open)
         (when (>= depth +sx-max-depth+)
           (return-from sexp-up nil))
         (incf depth)
         (push start open-at))
        ((eq kind :close)
         (when (> depth 0)
           (decf depth)
           (pop open-at)))))
    (car open-at)))

(defun sexp-down (buf pos)
  "down-list: just inside the next open paren."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf)))
    (declare (simple-string buf) (fixnum len))
    (when (<= len 0)
      (return-from sexp-down nil))
    (when (< pos 0)
      (setq pos 0))
    (do-sx-tokens (kind start end buf len)
      (cond ((eq kind :comment))
            ((< start pos))
            ((eq kind :open) (return end)) ; just inside the paren
            ;; Left the list before finding one.
            ((eq kind :close) (return nil))))))

(defun sexp-defun-start (buf pos)
  "The `(' in column 0 at or before POS.  With SEXP-DEFUN-END, what `C-M-a'
and `C-M-e' move to, and what bounds the text `C-c C-c' sends to clamiga."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (found nil))
    (declare (simple-string buf) (fixnum len))
    (when (<= len 0)
      (return-from sexp-defun-start nil))
    (when (< pos 0)
      (setq pos 0))
    (when (> pos len)
      (setq pos len))
    (do-sx-tokens (kind start end buf len)
      (when (> start pos)
        (return))
      ;; Column 0 is what makes a defun a defun for navigation purposes --
      ;; the same convention Emacs uses, and the reason the frontend can
      ;; export a window of lines and trust offset 0 to be clean.
      (when (and (eq kind :open)
                 (or (= start 0)
                     (char= (schar buf (- start 1)) #\Newline)))
        (setq found start)))
    found))

(defun sexp-defun-end (buf pos)
  "The position just past the form SEXP-DEFUN-START's paren opens."
  (let ((start (sexp-defun-start buf pos)))
    (and start (sexp-forward buf start))))

(defun sexp-match-paren (buf pos)
  "The partner of the paren at POS (either direction), or NIL when POS is
not on a paren or the parens do not balance.  Drives the paren highlight."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         (open-at '()))
    (declare (simple-string buf) (fixnum len depth))
    (when (or (< pos 0) (>= pos len))
      (return-from sexp-match-paren nil))
    (unless (sx-paren-p (schar buf pos))
      (return-from sexp-match-paren nil))
    (unless (eq (sexp-context buf pos) :code)
      (return-from sexp-match-paren nil))
    (do-sx-tokens (kind start end buf len)
      (case kind
        (:open
         (when (>= depth +sx-max-depth+)
           (return nil))
         (incf depth)
         (push start open-at)
         (when (= start pos)
           ;; Forward from here to the matching close.
           (let ((want depth))
             (declare (fixnum want))
             (return
               (do-sx-tokens (k s e buf len end)
                 (case k
                   (:open
                    (incf depth)
                    (when (> depth +sx-max-depth+)
                      (return nil)))
                   (:close
                    (decf depth)
                    (when (< depth want)
                      (return s)))))))))
        (:close
         (when (= start pos)
           (return (car open-at)))
         (when (> depth 0)
           (decf depth)
           (pop open-at)))))))

(defun sexp-last-sexp (buf pos)
  "Bounds of the sexp that ENDS at or immediately before POS -- what
`C-x C-e' sends.  Returns START and END (one past the last character) as
two values, or NIL."
  (let* ((buf (sx-simple buf))
         (start (sexp-backward buf pos))
         (end (and start (sexp-forward buf start))))
    (if end
        (values start end)
        nil)))

(defun sx-in-package-p (buf start end)
  "Whether the atom at [START, END) spells IN-PACKAGE, in either case."
  (declare (simple-string buf) (fixnum start end))
  (let ((word "in-package"))
    (declare (simple-string word))
    (and (= (- end start) 10)
         (dotimes (i 10 t)
           (let ((a (schar buf (+ start i))))
             (when (char<= #\A a #\Z)
               (setq a (code-char (+ (char-code a) 32))))
             (unless (char= a (schar word i))
               (return nil)))))))

(defun sexp-current-package (buf pos)
  "The package named by the nearest (in-package ...) at or before POS, as a
string in the spelling of the buffer, or NIL.  The status line shows it and
every eval carries it."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         (state :idle)    ; :IDLE, :OPEN (saw a top-level open), :IN-PACKAGE
         (form-ok nil)
         (found-start 0)
         (found-end 0))
    (declare (simple-string buf) (fixnum len depth found-start found-end))
    (when (<= len 0)
      (return-from sexp-current-package nil))
    (when (> pos len)
      (setq pos len))
    (do-sx-tokens (kind start end buf len)
      (cond
        ((eq kind :comment))
        ((eq kind :open)
         (incf depth)
         (when (= depth 1)
           (setq state :open
                 ;; Strictly before: with point at the very start of the
                 ;; buffer no package is in effect yet, and the form
                 ;; sitting at offset 0 has not been read.
                 form-ok (< start pos))))
        ((eq kind :close)
         (when (> depth 0)
           (decf depth))
         (when (= depth 0)
           (setq state :idle)))
        ((and (eq state :open) (= depth 1) (eq kind :atom))
         (setq state (if (sx-in-package-p buf start end) :in-package :idle)))
        ((and (eq state :in-package) (= depth 1)
              (or (eq kind :atom) (eq kind :string)))
         (when form-ok
           (let ((s start) (e end))
             (declare (fixnum s e))
             ;; Strip the spellings a package designator comes in:
             ;; "FOO", :foo, #:foo, foo.
             (when (and (char= (schar buf s) #\") (>= (- e s) 2))
               (incf s)
               (decf e))
             (cond ((and (>= (- e s) 2)
                         (char= (schar buf s) #\#)
                         (char= (schar buf (+ s 1)) #\:))
                    (incf s 2))
                   ((and (>= (- e s) 1) (char= (schar buf s) #\:))
                    (incf s)))
             (when (> e s)
               (setq found-start s
                     found-end e))))
         (setq state :idle))
        ;; `#:foo' reaches here as :QUOTE `#' then :ATOM `:foo', so a prefix
        ;; must not abandon the form -- only something genuinely unexpected.
        ((and (eq state :in-package) (not (eq kind :quote)))
         (setq state :idle))))
    (if (> found-end found-start)
        (subseq buf found-start found-end)
        nil)))

;;; ------------------------------------------------------------------
;;; Phase 2: what to ask clamiga about
;;; ------------------------------------------------------------------

(defun sx-operator-like-p (buf s e)
  "Whether the atom at [S, E) could name an operator.  Numbers, keywords and
character literals cannot, and asking clamiga about `1' or `:key' would only
fill the arglist cache with misses."
  (declare (simple-string buf) (fixnum s e))
  (and (> e s)
       (let ((c (schar buf s)))
         (not (or (char<= #\0 c #\9)
                  (char= c #\#)
                  (char= c #\:)
                  (and (or (char= c #\+) (char= c #\-) (char= c #\.))
                       (> (- e s) 1)
                       (char<= #\0 (schar buf (+ s 1)) #\9)))))))

(defun sexp-operator-at-point (buf pos)
  "The operator whose arglist the status line should show: the head symbol
of the innermost list enclosing POS that is CODE.  Returns its START and END
as two values, or NIL.

Lists that are data are transparent -- `(member x '(a b|))' answers MEMBER,
not A -- which is decided by the prefix in front of the open paren: `'', ``'
and `#' make data, `,' and `,@' make code again inside a backquote, and `#''
is a function, so `#'(lambda ...)' answers LAMBDA.  A head that cannot name
an operator (a number, a keyword, a character, a nested list) leaves the list
without one.  While POS sits INSIDE the head atom the user is still typing
it, and nothing is answered rather than a request per keystroke."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         ;; The current list: its head (NIL when it has none), whether it is
         ;; quoted data, whether the next atom is its head.
         (head-start nil)
         (head-end nil)
         (data nil)
         (want-head nil)
         ;; The enclosing lists, innermost first, one cons each: the start
         ;; of the head, or :DATA for a quoted list, or NIL for a code list
         ;; without an operator.  (A data list never has a head, and a list
         ;; we have descended from never wants one any more, so that is the
         ;; whole of the C code's four arrays.  The end of an outer head is
         ;; read again from its start, once, when it is the answer.)
         (outer '())
         (prefix-0 #\Space)
         (prefix-1 #\Space)
         (prefix-len 0)
         (prefix-end -1))   ; where the prefix run ends; the open paren it
                            ; applies to starts there
    (declare (simple-string buf) (fixnum len depth prefix-len prefix-end)
             (character prefix-0 prefix-1))
    (when (or (<= len 0) (< pos 0))
      (return-from sexp-operator-at-point nil))
    (when (> pos len)
      (setq pos len))
    (do-sx-tokens (kind start end buf len)
      (cond
        ((eq kind :comment))
        ((>= start pos) (return))
        ((> end pos)
         ;; POS is inside this token.  Inside the head atom the operator is
         ;; still being typed.
         (when (and (eq kind :atom) (> depth 0) want-head)
           (return-from sexp-operator-at-point nil))
         (return))
        ((eq kind :quote)
         (when (/= prefix-end start)
           (setq prefix-len 0))
         (when (< prefix-len 2)
           (if (= prefix-len 0)
               (setq prefix-0 (schar buf start))
               (setq prefix-1 (schar buf start)))
           (incf prefix-len))
         (setq prefix-end end))
        (t
         (case kind
           (:open
            (when (>= depth +sx-max-depth+)
              (return-from sexp-operator-at-point nil))
            (let ((is-data
                    (if (and (= prefix-end start) (> prefix-len 0))
                        (not (or (char= prefix-0 #\,)
                                 (and (= prefix-len 2)
                                      (char= prefix-0 #\#)
                                      (char= prefix-1 #\'))))
                        data)))
              ;; A list in head position -- ((lambda ...) x) -- takes the
              ;; slot: the atoms after it are arguments, not the operator.
              ;; WANT-HEAD is not saved for that reason.
              (push (cond (head-start head-start) (data :data) (t nil))
                    outer)
              (incf depth)
              (setq data is-data
                    want-head t
                    head-start nil
                    head-end nil)))
           (:close
            (when (> depth 0)
              (decf depth)
              (let ((entry (pop outer)))
                (setq head-start (if (eq entry :data) nil entry)
                      head-end nil
                      data (eq entry :data)
                      want-head nil))))
           (:atom
            (when (and (> depth 0) want-head)
              (when (and (not data) (sx-operator-like-p buf start end))
                (setq head-start start
                      head-end end))
              (setq want-head nil)))
           (:string
            (when (> depth 0)
              (setq want-head nil))))
         (setq prefix-len 0
               prefix-end -1))))
    ;; The innermost enclosing list that has an operator.
    (unless head-start
      (dolist (entry outer)
        (when (and entry (not (eq entry :data)))
          (setq head-start entry)
          (return))))
    (cond ((null head-start) nil)
          (head-end (values head-start head-end))
          (t (multiple-value-bind (kind start end)
                 (sx-next buf len head-start)
               (declare (ignore kind start))
               (values head-start end))))))

(defun sexp-symbol-at-point (buf pos)
  "The symbol under or just before POS, by the rule Emacs's
`symbol-at-point' uses: the run of symbol characters containing POS, or the
one ending at it.  Character-based rather than token-based on purpose, so it
also answers inside a comment or a string, where `M-.' is still useful.
Returns START and END as two values, or NIL."
  (declare (fixnum pos))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (s 0)
         (e 0))
    (declare (simple-string buf) (fixnum len s e))
    (when (or (<= len 0) (< pos 0) (> pos len))
      (return-from sexp-symbol-at-point nil))
    (cond ((and (< pos len) (sx-symbol-char-p (schar buf pos)))
           (setq s pos))
          ((and (> pos 0) (sx-symbol-char-p (schar buf (- pos 1))))
           (setq s (- pos 1)))
          (t (return-from sexp-symbol-at-point nil)))
    (loop
      (unless (and (> s 0) (sx-symbol-char-p (schar buf (- s 1))))
        (return))
      (decf s))
    (setq e s)
    (loop
      (unless (and (< e len) (sx-symbol-char-p (schar buf e)))
        (return))
      (incf e))
    (values s e)))

;;; ------------------------------------------------------------------
;;; Phase 3: is the REPL's input a complete form yet?
;;; ------------------------------------------------------------------

(defun sx-string-closed-p (buf start end)
  "Whether the string token [START, END), which reaches the end of the
buffer, was closed.  SX-NEXT ends an unterminated string at the end of the
buffer too, so the walk has to be repeated with the closing quote as the
question."
  (declare (simple-string buf) (fixnum start end))
  (let ((p (+ start 1)))
    (declare (fixnum p))
    (loop
      (when (>= p end)
        (return nil))
      (let ((c (schar buf p)))
        (cond ((char= c #\\) (incf p 2))
              ((char= c #\") (return t))
              (t (incf p)))))))

(defun sx-block-comment-closed-p (buf start end)
  "The same for a `#| ... |#' comment: closed when its nesting returns to
zero before the token ends."
  (declare (simple-string buf) (fixnum start end))
  (let ((p start)
        (depth 0))
    (declare (fixnum p depth))
    (loop
      (when (>= (+ p 1) end)
        (return nil))
      (cond ((and (char= (schar buf p) #\#)
                  (char= (schar buf (+ p 1)) #\|))
             (incf depth)
             (incf p 2))
            ((and (char= (schar buf p) #\|)
                  (char= (schar buf (+ p 1)) #\#))
             (decf depth)
             (incf p 2)
             (when (= depth 0)
               (return t)))
            (t (incf p))))))

(defun sexp-input-complete-p (buf)
  "Whether BUF holds only complete forms: no list, string, `#|' comment or
quote prefix still open at the end.  RET in the REPL sends the input when
this says so and inserts a newline otherwise, which is what lets a defun be
typed across several lines at the prompt.  A surplus `)' counts as complete
-- READ would signal on it, not wait, and sending it is how the user finds
out.  Empty input is complete."
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         (last :eof))
    (declare (simple-string buf) (fixnum len depth))
    (do-sx-tokens (kind start end buf len)
      (case kind
        (:open (incf depth))
        (:close
         ;; One `)' too many: READ would signal, not wait.
         (when (> depth 0)
           (decf depth)))
        (:string
         (when (and (>= end len) (not (sx-string-closed-p buf start end)))
           (return-from sexp-input-complete-p nil)))
        (:comment
         (when (and (>= end len)
                    (char= (schar buf start) #\#)
                    (not (sx-block-comment-closed-p buf start end)))
           (return-from sexp-input-complete-p nil))))
      (unless (eq kind :comment)
        (setq last kind)))
    ;; A quote with nothing after it is waiting for its form.
    (and (not (eq last :quote))
         (= depth 0))))
