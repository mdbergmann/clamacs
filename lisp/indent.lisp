;;;; indent.lisp -- Lisp indentation.
;;;;
;;;; The rules follow SLIME's cl-indent: a table maps an operator to the
;;;; number of DISTINGUISHED arguments it takes.  Those arguments indent four
;;;; columns past the open paren; everything after them -- the body --
;;;; indents two.  An operator that is not in the table aligns its arguments
;;;; under the first one, or one column past the paren when it stands alone
;;;; on its line.  That one rule, plus the table, covers `defun', `let',
;;;; `when', `handler-case' and `(foo bar\n     baz)' alike.
;;;;
;;;; The table is data: DEFINE-INDENT adds to it at run time, so phase 2 can
;;;; extend it with &body positions asked from clamiga rather than guessed
;;;; here, and the user's init file can teach it a project's macros.
;;;;
;;;; A port of src/lisp/indent.c, answering exactly what it answers.  Pure:
;;;; no MUI, no OS types.  Same buffer contract as sexp.lisp -- offset 0 must
;;;; be outside any string and any comment.

(in-package :clamacs)

(defconstant +indent-body+ 2
  "Body forms, past the distinguished arguments.")
(defconstant +indent-distinct+ 4
  "The distinguished arguments themselves.")

;;; ------------------------------------------------------------------
;;; The rule table
;;;
;;; The head of a form is a range of the buffer, and the lookup runs on
;;; every RET and TAB (and once per line of an indent-region), so it must
;;; not cons: no downcased SUBSEQ to serve as an EQUAL key.  The table is an
;;; EQL hash table -- the cheapest kind the runtime has, the keymaps use the
;;; same -- from a fixnum made of the name's length and its first and last
;;; characters to the short list of rules that share them; the candidates
;;; are compared with a declared case-insensitive loop.  With the rules
;;; below no bucket holds more than two names.
;;; ------------------------------------------------------------------

(defvar *indent-rules* (make-hash-table :test 'eql)
  "Bucket key (see IND-KEY) -> list of (lowercase-name . args).")

(declaim (inline ind-lower))

(defun ind-lower (c)
  "ASCII lowercase, as the C code has it; other characters as they are."
  (declare (character c))
  (if (char<= #\A c #\Z)
      (code-char (+ (char-code c) 32))
      c))

(defun ind-key (name start end)
  "The bucket of NAME[START, END), which must not be empty.  Only a hash:
what it leaves out (the middle of the name, the high bits) IND-EQUAL-CI
checks."
  (declare (simple-string name) (fixnum start end))
  (let ((first (char-code (ind-lower (schar name start))))
        (last (char-code (ind-lower (schar name (- end 1))))))
    (declare (fixnum first last))
    (+ (* (logand (- end start) 255) 65536)
       (* (logand first 255) 256)
       (logand last 255))))

(defun ind-equal-ci (text start end word)
  "Whether TEXT[START, END), in either case, is the lowercase WORD."
  (declare (simple-string text word) (fixnum start end))
  (let ((n (- end start)))
    (declare (fixnum n))
    (and (= n (length word))
         (dotimes (i n t)
           (unless (char= (ind-lower (schar text (+ start i)))
                          (schar word i))
             (return nil))))))

(defun ind-name-start (name start end)
  "START moved past a package prefix: `cl:when' indents like `when'.  The
last colon wins, so `cl-user::foo' works too."
  (declare (simple-string name) (fixnum start end))
  (let ((from start))
    (declare (fixnum from))
    (do ((i start (+ i 1)))
        ((>= i end) from)
      (declare (fixnum i))
      (when (char= (schar name i) #\:)
        (setq from (+ i 1))))))

(defun define-indent (name args)
  "Give the operator NAME (a string designator; case and a package prefix
do not matter) ARGS distinguished arguments: those indent four columns, the
body after them two.  ARGS NIL removes the rule.  Returns the name as
stored, or NIL when there is no name to store.

  (define-indent \"with-foo\" 1)"
  (check-type args (or null (integer 0)))
  (let* ((text (sx-simple (string name)))
         (start (ind-name-start text 0 (length text)))
         (word (make-string (- (length text) start))))
    (declare (simple-string text word) (fixnum start))
    (when (= (length word) 0)
      (return-from define-indent nil))
    (dotimes (i (length word))
      (setf (schar word i) (ind-lower (schar text (+ start i)))))
    (let* ((key (ind-key word 0 (length word)))
           (bucket (gethash key *indent-rules*))
           (entry (assoc word bucket :test #'string=)))
      (cond ((null args)
             (when entry
               (setq bucket (delete entry bucket))
               (if bucket
                   (setf (gethash key *indent-rules*) bucket)
                   (remhash key *indent-rules*))))
            (entry (setf (cdr entry) args))
            (t (push (cons word args) (gethash key *indent-rules*)))))
    word))

;;; Distinguished-argument counts.  `defun' is 2 (name and lambda list),
;;; `let' is 1 (the bindings), `when' is 1 (the test); everything after
;;; those is body.  `loop' is deliberately absent: the default rule aligns
;;; its clauses under the first one, which is what
;;; `(loop for x in xs\n      collect x)' wants and what a fixed number
;;; could not express.
(dolist (rule '(("block" . 1)
                ("case" . 1)
                ("catch" . 1)
                ("ccase" . 1)
                ("cond" . 0)
                ("ctypecase" . 1)
                ("defclass" . 2)
                ("defconstant" . 1)
                ("define-compiler-macro" . 2)
                ("define-condition" . 2)
                ("define-modify-macro" . 1)
                ("define-setf-expander" . 2)
                ("define-symbol-macro" . 1)
                ("defgeneric" . 2)
                ("defmacro" . 2)
                ("defmethod" . 2)
                ("defpackage" . 1)
                ("defparameter" . 1)
                ("defsetf" . 2)
                ("defstruct" . 1)
                ("defsubst" . 2)
                ("deftype" . 2)
                ("defun" . 2)
                ("defvar" . 1)
                ("destructuring-bind" . 2)
                ("do" . 2)
                ("do*" . 2)
                ("dolist" . 1)
                ("dotimes" . 1)
                ("ecase" . 1)
                ("etypecase" . 1)
                ("eval-when" . 1)
                ("flet" . 1)
                ("handler-bind" . 1)
                ("handler-case" . 1)
                ("if" . 2)
                ("labels" . 1)
                ("lambda" . 1)
                ("let" . 1)
                ("let*" . 1)
                ("locally" . 0)
                ("loop-finish" . 0)
                ("macrolet" . 1)
                ("multiple-value-bind" . 2)
                ("prog1" . 1)
                ("prog2" . 2)
                ("progn" . 0)
                ("restart-bind" . 1)
                ("restart-case" . 1)
                ("symbol-macrolet" . 1)
                ("tagbody" . 0)
                ("typecase" . 1)
                ("unless" . 1)
                ("unwind-protect" . 1)
                ("when" . 1)
                ("with-accessors" . 2)
                ("with-input-from-string" . 1)
                ("with-open-file" . 1)
                ("with-open-stream" . 1)
                ("with-output-to-string" . 1)
                ("with-slots" . 2)
                ("with-standard-io-syntax" . 0)))
  (define-indent (car rule) (cdr rule)))

(defun ind-body-args (name start end)
  "INDENT-BODY-ARGS on a simple string and a checked range."
  (declare (simple-string name) (fixnum start end))
  (let ((start (ind-name-start name start end)))
    (declare (fixnum start))
    (when (<= end start)
      (return-from ind-body-args nil))
    (dolist (rule (gethash (ind-key name start end) *indent-rules*))
      (when (ind-equal-ci name start end (car rule))
        (return-from ind-body-args (cdr rule))))
    ;; An unknown `def...' is almost always a defining macro whose first two
    ;; arguments name the thing being defined.  Guessing 2 here is what
    ;; makes a project's own `define-foo' indent sensibly before phase 2 can
    ;; ask clamiga for its real &body position.
    (if (and (> (- end start) 3)
             (char= (ind-lower (schar name start)) #\d)
             (char= (ind-lower (schar name (+ start 1))) #\e)
             (char= (ind-lower (schar name (+ start 2))) #\f))
        2
        nil)))

(defun indent-body-args (name &optional (start 0) end)
  "Distinguished-argument count for the operator spelled by NAME[START,
END), or NIL when it is not in the table.  Case insensitive; a package
prefix (`cl:when') is ignored.  The range is what lets the indenter ask
about a head where it stands in the buffer, without a substring."
  (let* ((name (sx-simple name))
         (len (length name))
         (end (or end len)))
    (declare (simple-string name) (fixnum len))
    (if (<= 0 start end len)
        (ind-body-args name start end)
        nil)))

;;; ------------------------------------------------------------------
;;; Lines and columns
;;; ------------------------------------------------------------------

(defun ind-line-start (buf len offset)
  (declare (simple-string buf) (fixnum len offset))
  (when (<= offset 0)
    (return-from ind-line-start 0))
  (when (> offset len)
    (setq offset len))
  (do ((i (- offset 1) (- i 1)))
      ((< i 0) 0)
    (declare (fixnum i))
    (when (char= (schar buf i) #\Newline)
      (return (+ i 1)))))

(declaim (inline ind-column-of))

(defun ind-column-of (buf len offset)
  (declare (simple-string buf) (fixnum len offset))
  (- offset (ind-line-start buf len offset)))

(defun indent-line-start (buf offset)
  "Start of the line containing OFFSET."
  (let ((buf (sx-simple buf)))
    (ind-line-start buf (length buf) offset)))

(defun indent-column-of (buf offset)
  "The column of OFFSET within its line, counting a tab as one column.  The
indenter emits spaces, so a file it has touched has no tabs in its
indentation and the two notions agree."
  (let ((buf (sx-simple buf)))
    (ind-column-of buf (length buf) offset)))

(defun ind-same-line-p (buf from to)
  (declare (simple-string buf) (fixnum from to))
  (do ((i from (+ i 1)))
      ((>= i to) t)
    (declare (fixnum i))
    (when (char= (schar buf i) #\Newline)
      (return nil))))

;;; ------------------------------------------------------------------
;;; The indenter
;;; ------------------------------------------------------------------

(defun indent-for-line (buf line-start)
  "The column the line beginning at LINE-START should start in.  NIL when
the line must be left alone, which is the case inside a multi-line string:
reindenting there would change the string's contents."
  (declare (fixnum line-start))
  (let* ((buf (sx-simple buf))
         (len (length buf))
         (depth 0)
         ;; The list being walked -- the C code's frame:
         (open 0)           ; offset of its `(', or of the prefix before it
         (nforms 0)         ; complete forms seen inside, head included
         (head-start 0)
         (head-end 0)       ; :LIST when the head is itself a list
         (arg1-start nil)   ; start of the second form
         (pending nil)      ; start of a form introduced by prefix characters
         ;; The enclosing frames, five conses each, pushed in the order of
         ;; the variables above and popped in reverse.  (PENDING is NIL on
         ;; both sides of a paren and needs no slot.)
         (outer '()))
    (declare (simple-string buf) (fixnum len depth open nforms head-start))
    (when (or (< line-start 0) (> line-start len))
      (return-from indent-for-line nil))
    ;; A macro, not a local function: a closure over the frame variables
    ;; would box every one of them for the whole scan.
    (macrolet ((complete-form (start end)
                 ;; END is :LIST for a list.
                 `(progn
                    (cond ((= nforms 0)
                           (setq head-start ,start
                                 head-end ,end))
                          ((= nforms 1)
                           (setq arg1-start ,start)))
                    (incf nforms))))
      (do-sx-tokens (kind start end buf len)
        (when (>= start line-start)
          (return))
        (when (> end line-start)
          ;; The token straddles the start of the line.  Inside a string the
          ;; line's leading characters ARE the string, so reindenting would
          ;; silently edit data; inside a block comment there is nothing to
          ;; align to.  Either way, hands off.
          (when (or (eq kind :string) (eq kind :comment))
            (return-from indent-for-line nil))
          (return))
        (case kind
          (:quote
           (unless pending
             (setq pending start)))
          ((:atom :string)
           (complete-form (or pending start) end)
           (setq pending nil))
          (:open
           (when (>= depth +sx-max-depth+)
             (return-from indent-for-line nil))
           (incf depth)
           (push open outer)
           (push nforms outer)
           (push head-start outer)
           (push head-end outer)
           (push arg1-start outer)
           (setq open (or pending start)
                 nforms 0
                 head-start 0
                 head-end 0
                 arg1-start nil
                 pending nil))
          (:close
           (when (> depth 0)
             (let ((opened open))
               (decf depth)
               (setq arg1-start (pop outer)
                     head-end (pop outer)
                     head-start (pop outer)
                     nforms (pop outer)
                     open (pop outer))
               (complete-form opened :list)
               (setq pending nil)))))))
    (cond
      ((= depth 0) 0)                   ; top level
      ;; Nothing after the open paren yet: `(\n   foo)'.
      ((= nforms 0) (+ (ind-column-of buf len open) 1))
      ;; The head is itself a list, so this is data or `((lambda ...) x)':
      ;; line the elements up one past the paren.
      ((eq head-end :list) (+ (ind-column-of buf len open) 1))
      (t
       (let ((arg-index (- nforms 1))   ; the head is form 0
             (rule (ind-body-args buf head-start head-end)))
         (declare (fixnum arg-index))
         (cond
           (rule
            (+ (ind-column-of buf len open)
               (if (< arg-index rule) +indent-distinct+ +indent-body+)))
           ;; Unknown operator: align under the first argument when there is
           ;; one on the operator's own line, otherwise one past the paren.
           ((and arg1-start (ind-same-line-p buf head-start arg1-start))
            (ind-column-of buf len arg1-start))
           (t (+ (ind-column-of buf len open) 1))))))))
