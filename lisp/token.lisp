;;;; token.lisp -- the Lisp colouring tokenizer.
;;;;
;;;; Line-oriented and incremental, because that is what redisplay needs:
;;;; after an edit only the changed line is re-tokenized and recoloured.  A
;;;; construct that spans lines (a string, a `#| |#' comment) leaves its
;;;; state in a TOK-STATE, and the caller re-tokenizes forward until the
;;;; state at the end of a line matches what it was before the edit -- at
;;;; which point the rest of the buffer is unchanged.
;;;;
;;;; Separate from sexp.lisp on purpose.  The sexp scanner answers
;;;; structural questions over a whole buffer; this answers "what colour is
;;;; character N of this one line", and it must be able to start in the
;;;; middle of a string.
;;;;
;;;; Pure: no MUI, no OS types.  The mapping from a token kind to a
;;;; TextEditor colour index lives in the frontend.
;;;;
;;;; The port of src/lisp/token.[ch]; the names follow the C ones so the two
;;;; read side by side.  The C code is the specification, quirks included.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Tokens and the carried state
;;;
;;; Token kinds:  :symbol :paren :comment :string :char (#\a, #\Space)
;;;               :keyword (:foo) :number
;;;               :defining (the head of a defining form: defun, ...)
;;; State where:  :code :string :block-comment
;;; ------------------------------------------------------------------

;;; A token is a struct, not a (start len kind) list: a line is re-tokenized
;;; on every repaint, and one four-word object per token is less for the
;;; collector than three conses -- and the accessors say what they mean.
(defstruct (token (:constructor make-token (start len kind)))
  (start 0 :type fixnum)                ; character offset within the line
  (len 0 :type fixnum)
  (kind :symbol))

;;; Carried from one line to the next.  MAKE-TOK-STATE is ck_tok_state_init.
(defstruct (tok-state (:copier copy-tok-state))
  (where :code)
  ;; #| |# nesting.  The C field is a byte and saturates at 255; here it is
  ;; an integer and does not, so a comment nested deeper than that is
  ;; tracked correctly instead of closing early.
  (depth 0 :type fixnum)
  ;; The next atom is in head position (an open paren was the last thing
  ;; seen), so `defun' colours as a defining form even when the paren was on
  ;; the line before.
  (head nil))

(defun tok-state-equal (a b)
  (and (eq (tok-state-where a) (tok-state-where b))
       (= (tok-state-depth a) (tok-state-depth b))
       (eq (not (tok-state-head a)) (not (tok-state-head b)))))

;;; ------------------------------------------------------------------
;;; Character classes
;;; ------------------------------------------------------------------

(declaim (inline tk-space-p tk-terminating-p tk-lower tk-digit-value))

(defun tk-space-p (c)
  (declare (character c))
  (case c
    ((#\Space #\Tab #\Return #\Page) t)
    (t nil)))

(defun tk-terminating-p (c)
  (declare (character c))
  (case c
    ((#\Space #\Tab #\Return #\Page #\Newline
      #\( #\) #\[ #\] #\" #\; #\' #\` #\,)
     t)
    (t nil)))

;;; ASCII only, as in C: CHAR-DOWNCASE would also fold what is not a letter
;;; of any defining form or number.
(defun tk-lower (c)
  (declare (character c))
  (if (char<= #\A c #\Z)
      (code-char (+ (char-code c) 32))
      c))

(defun tk-digit-value (c)
  "The value of C as a digit in the largest radix, or 99 when it is none."
  (declare (character c))
  (let ((code (char-code c)))
    (declare (fixnum code))
    (cond ((<= 48 code 57) (- code 48))          ; 0-9
          ((<= 97 code 122) (- code 87))         ; a-z
          ((<= 65 code 90) (- code 55))          ; A-Z
          (t 99))))

;;; ------------------------------------------------------------------
;;; Numbers
;;; ------------------------------------------------------------------

(defun tk-digits (text i end radix)
  "Skip digits of RADIX from I; the index after them (I when there are
none, so the digit count is the difference)."
  (declare (simple-string text) (fixnum i end radix))
  (loop
    (when (>= i end) (return))
    (when (>= (tk-digit-value (schar text i)) radix) (return))
    (incf i))
  i)

(declaim (inline tk-sign-p))
(defun tk-sign-p (c)
  (declare (character c))
  (or (char= c #\+) (char= c #\-)))

(defun tk-radix-number-p (text start end)
  "#x1f, #b1010, #o17, #16rFF.  TEXT[START] is the #, and END > START + 1."
  (declare (simple-string text) (fixnum start end))
  (let ((i (+ start 2))
        (radix 10)
        (c (tk-lower (schar text (1+ start)))))
    (declare (fixnum i radix))
    (cond ((char= c #\x) (setq radix 16))
          ((char= c #\b) (setq radix 2))
          ((char= c #\o) (setq radix 8))
          ((char<= #\0 c #\9)
           (let ((r 0))
             (declare (fixnum r))
             (setq i (1+ start))
             (loop
               (unless (and (< i end) (char<= #\0 (schar text i) #\9))
                 (return))
               ;; Clamped so an absurd digit string stays a fixnum; any
               ;; value above 36 is refused below all the same.
               (setq r (min 1000 (+ (* r 10)
                                    (- (char-code (schar text i)) 48))))
               (incf i))
             (when (or (>= i end)
                       (char/= (tk-lower (schar text i)) #\r)
                       (< r 2)
                       (> r 36))
               (return-from tk-radix-number-p nil))
             (incf i)
             (setq radix r)))
          (t (return-from tk-radix-number-p nil)))
    (when (and (< i end) (tk-sign-p (schar text i)))
      (incf i))
    (let ((j (tk-digits text i end radix)))
      (declare (fixnum j))
      (when (= j i)
        (return-from tk-radix-number-p nil))
      (setq i j))
    (when (and (< i end) (char= (schar text i) #\/))
      (incf i)
      (let ((j (tk-digits text i end radix)))
        (declare (fixnum j))
        (when (= j i)
          (return-from tk-radix-number-p nil))
        (setq i j)))
    (= i end)))

(defun tk-number-p (text start end)
  "TOK-NUMBER-P on a simple string and a checked range."
  (declare (simple-string text) (fixnum start end))
  (when (>= start end)
    (return-from tk-number-p nil))
  (when (and (char= (schar text start) #\#) (>= (- end start) 2))
    (return-from tk-number-p (tk-radix-number-p text start end)))
  (let ((i start) (intdigits 0) (fracdigits 0))
    (declare (fixnum i intdigits fracdigits))
    (when (tk-sign-p (schar text i))
      (incf i))
    (let ((j (tk-digits text i end 10)))
      (declare (fixnum j))
      (setq intdigits (- j i)
            i j))
    ;; A ratio: 1/2
    (when (and (> intdigits 0) (< i end) (char= (schar text i) #\/))
      (incf i)
      (let ((j (tk-digits text i end 10)))
        (declare (fixnum j))
        (return-from tk-number-p (and (> j i) (= j end)))))
    ;; An integer written with a trailing dot: 10.
    (when (and (> intdigits 0) (= i (1- end)) (char= (schar text i) #\.))
      (return-from tk-number-p t))
    (when (and (< i end) (char= (schar text i) #\.))
      (incf i)
      (let ((j (tk-digits text i end 10)))
        (declare (fixnum j))
        (setq fracdigits (- j i)
              i j)))
    ;; `-', `.', `+' and friends are symbols.
    (when (and (= intdigits 0) (= fracdigits 0))
      (return-from tk-number-p nil))
    ;; An exponent marker: 1e10, 1.0d0, 1s-3
    (when (< i end)
      (case (schar text i)
        ((#\e #\s #\f #\d #\l #\E #\S #\F #\D #\L)
         (incf i)
         (when (and (< i end) (tk-sign-p (schar text i)))
           (incf i))
         (let ((j (tk-digits text i end 10)))
           (declare (fixnum j))
           (when (= j i)
             (return-from tk-number-p nil))
           (setq i j)))))
    (= i end)))

(defun tok-number-p (text &optional (start 0) end)
  "Whether TEXT from START to END reads as a Common Lisp number.  Exposed
because it is the one piece of the tokenizer with interesting edge cases --
`1+' and `-' are symbols, `1/2' and `1.0d0' are not."
  (let ((text (coerce text 'simple-string)))
    (tk-number-p text start (or end (length text)))))

;;; ------------------------------------------------------------------
;;; Defining forms
;;; ------------------------------------------------------------------

(defparameter *tk-defining*
  '("defclass" "defconstant" "defgeneric" "define-compiler-macro"
    "define-condition" "define-method-combination" "define-modify-macro"
    "define-setf-expander" "define-symbol-macro" "defmacro" "defmethod"
    "defpackage" "defparameter" "defsetf" "defstruct" "defsubst"
    "deftype" "defun" "defvar"))

(defun tk-equal-ci (text start end word)
  "Whether TEXT from START to END is WORD (lower case) in any case."
  (declare (simple-string text word) (fixnum start end))
  (let ((n (- end start)))
    (declare (fixnum n))
    (and (= n (length word))
         (let ((i 0))
           (declare (fixnum i))
           (loop
             (when (>= i n) (return t))
             (unless (char= (tk-lower (schar text (+ start i)))
                            (schar word i))
               (return nil))
             (incf i))))))

(defun tk-defining-p (text start end)
  "TOK-DEFINING-P on a simple string and a checked range."
  (declare (simple-string text) (fixnum start end))
  ;; Every word is at least "defun" long and starts with a d: most atoms in
  ;; head position leave here.
  (when (and (>= (- end start) 5)
             (char= (tk-lower (schar text start)) #\d))
    (dolist (word *tk-defining* nil)
      (when (tk-equal-ci text start end word)
        (return t)))))

(defun tok-defining-p (text &optional (start 0) end)
  "Whether TEXT from START to END names a defining form (defun, defmacro,
defclass, ...).  Case insensitive."
  (let ((text (coerce text 'simple-string)))
    (tk-defining-p text start (or end (length text)))))

;;; ------------------------------------------------------------------
;;; The line tokenizer
;;; ------------------------------------------------------------------

(defun tk-scan-string (line i len state)
  "Scan the inside of a string from I.  The index after the closing quote,
with STATE back in code -- or LEN, with STATE left where it was, when the
line ends first."
  (declare (simple-string line) (fixnum i len))
  (loop
    (when (>= i len) (return))
    (let ((c (schar line i)))
      (cond ((char= c #\\) (incf i 2))
            ((char= c #\")
             (incf i)
             (setf (tok-state-where state) :code)
             (return))
            (t (incf i)))))
  ;; A backslash as the last character steps past the end.
  (if (> i len) len i))

(defun tk-scan-block-comment (line i len state)
  "Scan the inside of a #| |# comment from I, keeping the nesting depth in
STATE.  The index after the |# that closes the outermost level, with STATE
back in code -- or LEN when the line ends first."
  (declare (simple-string line) (fixnum i len))
  (loop
    (when (>= i len) (return))
    (let ((c (schar line i))
          (d (if (< (1+ i) len) (schar line (1+ i)) #\Space)))
      (cond ((and (char= c #\#) (char= d #\|))
             (incf (tok-state-depth state))
             (incf i 2))
            ((and (char= c #\|) (char= d #\#))
             (incf i 2)
             (when (> (tok-state-depth state) 0)
               (decf (tok-state-depth state)))
             (when (= (tok-state-depth state) 0)
               (setf (tok-state-where state) :code)
               (return)))
            (t (incf i)))))
  i)

(defun tk-scan-atom (line i len)
  "The index after the atom that starts at I, clamped to LEN.  |...| and a
backslash quote what would otherwise end it."
  (declare (simple-string line) (fixnum i len))
  (loop
    (when (>= i len) (return))
    (let ((d (schar line i)))
      (cond ((char= d #\|)
             (incf i)
             (loop
               (when (or (>= i len) (char= (schar line i) #\|))
                 (return))
               (when (char= (schar line i) #\\)
                 (incf i))
               (incf i))
             (when (< i len)
               (incf i)))
            ((char= d #\\) (incf i 2))
            ((tk-terminating-p d) (return))
            (t (incf i)))))
  (if (> i len) len i))

(defun tokenize-line (line state)
  "Tokenize one line (without its newline).  Returns the list of its tokens
in order and leaves in STATE what the next line starts with."
  (let* ((line (coerce line 'simple-string))
         (len (length line))
         (i 0)
         (tokens '()))
    (declare (simple-string line) (fixnum len i))
    (macrolet ((emit (start kind)
                 `(push (make-token ,start (- i ,start) ,kind) tokens)))
      ;; Finish a construct the previous line left open before anything
      ;; else: the first characters of this line belong to it, not to a new
      ;; token.
      (case (tok-state-where state)
        (:string
         (setq i (tk-scan-string line 0 len state))
         (emit 0 :string)
         (when (eq (tok-state-where state) :code)
           (setf (tok-state-head state) nil)))
        (:block-comment
         (setq i (tk-scan-block-comment line 0 len state))
         (emit 0 :comment)))
      (loop
        (loop
          (unless (and (< i len) (tk-space-p (schar line i)))
            (return))
          (incf i))
        (when (>= i len)
          (return))
        (let* ((start i)
               (c (schar line i))
               (d (if (< (1+ i) len) (schar line (1+ i)) #\Space)))
          (declare (fixnum start))
          (cond
            ((char= c #\;)
             (setq i len)
             (emit start :comment))
            ((and (char= c #\#) (char= d #\|))
             (setf (tok-state-where state) :block-comment
                   (tok-state-depth state) 1)
             (setq i (tk-scan-block-comment line (+ i 2) len state))
             (emit start :comment))
            ;; Ahead of the dispatch-macro branch, so that #\( #\; #\" do
            ;; not open a list, start a comment or open a string.
            ((and (char= c #\#) (char= d #\\))
             (incf i 2)
             (when (< i len)
               (incf i))
             (loop
               (unless (and (< i len)
                            (not (tk-terminating-p (schar line i))))
                 (return))
               (incf i))
             (emit start :char)
             (setf (tok-state-head state) nil))
            ((char= c #\")
             (setf (tok-state-where state) :string)
             (setq i (tk-scan-string line (1+ i) len state))
             (emit start :string)
             (setf (tok-state-head state) nil))
            ((or (char= c #\() (char= c #\[))
             (incf i)
             (emit start :paren)
             (setf (tok-state-head state) t))
            ((or (char= c #\)) (char= c #\]))
             (incf i)
             (emit start :paren)
             (setf (tok-state-head state) nil))
            ;; A prefix character: it does not itself end head position, so
            ;; `(#'foo ...)' still sees foo as the head.
            ((or (char= c #\') (char= c #\`) (char= c #\,) (char= c #\#))
             (incf i)
             (when (and (char= c #\,) (char= d #\@))
               (incf i))
             (emit start :symbol))
            ;; An atom.
            (t
             (setq i (tk-scan-atom line i len))
             (when (= i start)
               (incf i))                ; never fail to advance
             (emit start
                   (cond ((char= c #\:) :keyword)
                         ((tk-number-p line start i) :number)
                         ((and (tok-state-head state)
                               (tk-defining-p line start i))
                          :defining)
                         (t :symbol)))
             (setf (tok-state-head state) nil))))))
    (nreverse tokens)))
