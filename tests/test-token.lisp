;;;; test-token.lisp -- the Lisp colouring tokenizer.  The cases of
;;;; tests/test_token.c, then the edges that file leaves alone; every added
;;;; expectation is what src/lisp/token.c answers for the same input.

(in-package :clamacs)

(defvar *tok-state* (make-tok-state)
  "The state carried from one TOKENIZE call of a test to the next.")

(defun tok-reset ()
  (setq *tok-state* (make-tok-state)))

(defun tokenize (line)
  "The tokens of LINE as a list of (kind text)."
  (mapcar (lambda (tok)
            (list (token-kind tok)
                  (subseq line (token-start tok)
                          (+ (token-start tok) (token-len tok)))))
          (tokenize-line line *tok-state*)))

(defun tokenize-spans (line)
  "The tokens of LINE as a list of (kind start len)."
  (mapcar (lambda (tok)
            (list (token-kind tok) (token-start tok) (token-len tok)))
          (tokenize-line line *tok-state*)))

(defun tok-where () (tok-state-where *tok-state*))
(defun tok-depth () (tok-state-depth *tok-state*))
(defun tok-head () (tok-state-head *tok-state*))

;;; ------------------------------------------------------------------
;;; The cases of test_token.c
;;; ------------------------------------------------------------------

(deftest numbers
  (dolist (text '("42" "-3" "+7" "1/2" "-1/2" "1.5" ".5" "1." "1.0d0"
                  "1e10" "1.5e-3" "#xFF" "#xff" "#b1010" "#o17" "#16rFF"
                  "#x-10"))
    (is-equal (list text (tok-number-p text)) (list text t)))
  (dolist (text '("1+" "-" "+" "a1" "1.2.3" "foo" "1/" "#x" "#xg" "#zz"
                  ":42" ""))
    (is-equal (list text (tok-number-p text)) (list text nil))))

(deftest defining-forms
  (is (tok-defining-p "defun"))
  (is (tok-defining-p "DEFUN"))
  (is (tok-defining-p "DefMacro"))
  (is (tok-defining-p "define-condition"))
  (is (not (tok-defining-p "defunny")))
  (is (not (tok-defining-p "def")))
  (is (not (tok-defining-p ""))))

(deftest simple-form
  (tok-reset)
  (is-equal (tokenize "(defun foo (a b)")
            '((:paren "(") (:defining "defun") (:symbol "foo")
              (:paren "(") (:symbol "a") (:symbol "b") (:paren ")"))))

(deftest defun-only-colours-in-head-position
  (tok-reset)
  ;; Not the head of its list, so it is an ordinary symbol here.
  (is-equal (tokenize "(list defun 1)")
            '((:paren "(") (:symbol "list") (:symbol "defun")
              (:number "1") (:paren ")"))))

(deftest keywords-and-numbers
  (tok-reset)
  (is-equal (tokenize "(foo :key 42 1/2 x)")
            '((:paren "(") (:symbol "foo") (:keyword ":key")
              (:number "42") (:number "1/2") (:symbol "x") (:paren ")"))))

(deftest line-comment
  (tok-reset)
  (let ((toks (tokenize "(foo) ; and the rest (is) \"not\" code")))
    (is-equal (length toks) 4)
    (is-equal (nth 3 toks)
              '(:comment "; and the rest (is) \"not\" code"))
    (is-equal (tok-where) :code)))

(deftest string-on-one-line
  (tok-reset)
  (let ((toks (tokenize "(format t \"hi ; there (\" x)")))
    (is-equal (nth 3 toks) '(:string "\"hi ; there (\""))
    (is-equal (nth 4 toks) '(:symbol "x"))
    (is-equal (tok-where) :code)))

(deftest string-with-escaped-quote
  (tok-reset)
  (is-equal (tokenize "\"a \\\" b\" tail")
            '((:string "\"a \\\" b\"") (:symbol "tail"))))

(deftest string-spanning-lines
  (tok-reset)
  (tokenize "(foo \"start")
  (is-equal (tok-where) :string)

  (is-equal (tokenize "middle") '((:string "middle")))
  (is-equal (tok-where) :string)

  (is-equal (tokenize "end\" done)")
            '((:string "end\"") (:symbol "done") (:paren ")")))
  (is-equal (tok-where) :code))

(deftest block-comment-nesting
  (tok-reset)
  (tokenize "#| outer #| inner")
  (is-equal (tok-where) :block-comment)
  (is-equal (tok-depth) 2)

  (tokenize "|# still in the outer")
  (is-equal (tok-where) :block-comment)
  (is-equal (tok-depth) 1)

  (is-equal (tokenize "|# (code)")
            '((:comment "|#") (:paren "(") (:symbol "code") (:paren ")")))
  (is-equal (tok-where) :code))

(deftest block-comment-on-one-line
  (tok-reset)
  (is-equal (tokenize "(a #| b |# c)")
            '((:paren "(") (:symbol "a") (:comment "#| b |#")
              (:symbol "c") (:paren ")")))
  (is-equal (tok-where) :code))

(deftest character-literals
  (tok-reset)
  ;; None of these open a list, start a comment or otherwise derail the
  ;; scan -- which is the whole reason character literals get their own
  ;; branch ahead of the dispatch-macro one.
  (is-equal (tokenize "(list #\\( #\\; #\\Space #\\a)")
            '((:paren "(") (:symbol "list") (:char "#\\(") (:char "#\\;")
              (:char "#\\Space") (:char "#\\a") (:paren ")"))))

(deftest head-position-carries-across-a-line-break
  (tok-reset)
  (tokenize "(")
  (is-equal (tok-head) t)
  (is-equal (tokenize "  defun foo ()")
            '((:defining "defun") (:symbol "foo")
              (:paren "(") (:paren ")"))))

(deftest state-equality
  (let ((a (make-tok-state))
        (b (make-tok-state)))
    (is (tok-state-equal a b))
    (setf (tok-state-where b) :string)
    (is (not (tok-state-equal a b)))))

(deftest empty-and-blank-lines
  (tok-reset)
  (is-equal (tokenize "") '())
  (is-equal (tokenize "      ") '())
  (is-equal (tok-where) :code))

(deftest token-overflow-still-tracks-state
  ;; The C caller hands in a buffer and may get fewer tokens than the line
  ;; has.  There is no buffer here: every token comes back, and the carried
  ;; state is right.
  (tok-reset)
  (is-equal (length (tokenize "(a b c \"open")) 5)
  (is-equal (tok-where) :string))

;;; ------------------------------------------------------------------
;;; What test_token.c leaves uncovered
;;; ------------------------------------------------------------------

(deftest token-spans
  ;; Offsets and lengths, not only the text they select.
  (tok-reset)
  (is-equal (tokenize-spans "  (foo \"a\" ; c")
            '((:paren 2 1) (:symbol 3 3) (:string 7 3) (:comment 11 3)))
  (let ((tok (first (tokenize-line "abc" (make-tok-state)))))
    (is (token-p tok))
    (is-equal (token-start tok) 0)
    (is-equal (token-len tok) 3)
    (is-equal (token-kind tok) :symbol)))

(deftest more-numbers
  (dolist (text '("#x+a/F" "#36rZz" "#16r-ff" "#16R1f" "#B101" "#2r101"
                  "+.5" "-.5e+3" "1." "+1." "1L5" "1S-3" "1f0" "1E5"
                  ;; Not a number to the Lisp reader, but one to token.c:
                  ;; the dot is only special as the LAST character.
                  "1.e5"))
    (is-equal (list text (tok-number-p text)) (list text t)))
  (dolist (text '(;; digits the radix does not have
                  "#b12" "#o78" "#2r102" "#xFFg"
                  ;; a radix out of range, or none
                  "#37r1" "#1r0" "#r1" "#" "##"
                  ;; a ratio needs digits on both sides, and no sign, dot
                  ;; or second slash after the first
                  "#x1/" "#x1/g" "1/-2" "1/2/3" "1/2." "#x1."
                  ;; an exponent needs digits
                  "1e" "1e+" "1d" ".e5" "1e1e1"
                  "." "+-1" "+." "-."))
    (is-equal (list text (tok-number-p text)) (list text nil))))

(deftest number-sub-range
  ;; The tokenizer asks about a stretch of the line, without a SUBSEQ.
  (is (tok-number-p "(+ 42 x)" 3 5))
  (is (not (tok-number-p "(+ 42 x)" 3 6)))
  (is (not (tok-number-p "(+ 42 x)" 2 5)))
  (is (tok-number-p "a1.5e3" 1))
  (is (not (tok-number-p "a1.5e3" 0)))
  ;; 10. is an integer only when the dot is the last character OF THE RANGE
  (is (tok-number-p "10.x" 0 3))
  (is (not (tok-number-p "10.x" 0 4)))
  (is (tok-number-p "x#xFFy" 1 5))
  (is (not (tok-number-p "x#xFFy" 1 6)))
  ;; a # with nothing after it in the range
  (is (not (tok-number-p "#x1" 0 1)))
  ;; an empty range
  (is (not (tok-number-p "42" 1 1)))
  (is (not (tok-number-p "42" 2))))

(deftest more-defining-forms
  (dolist (text '("defclass" "defconstant" "defgeneric"
                  "define-compiler-macro" "define-condition"
                  "define-method-combination" "define-modify-macro"
                  "define-setf-expander" "define-symbol-macro" "defmacro"
                  "defmethod" "defpackage" "defparameter" "defsetf"
                  "defstruct" "defsubst" "deftype" "defun" "defvar"
                  "DEFINE-METHOD-COMBINATION" "dEfVaR"))
    (is-equal (list text (tok-defining-p text)) (list text t)))
  ;; A prefix, a longer word, a first letter off, a trailing space.
  (dolist (text '("defu" "define" "define-conditions" "xefun" "defun "
                  "d" "lambda"))
    (is-equal (list text (tok-defining-p text)) (list text nil))))

(deftest defining-sub-range
  (is (tok-defining-p "(defun foo" 1 6))
  (is (not (tok-defining-p "(defun foo" 0 6)))
  (is (not (tok-defining-p "(defun foo" 1 7)))
  (is (not (tok-defining-p "(defun foo" 1 5)))
  (is (tok-defining-p "xxdefvar" 2))
  (is (not (tok-defining-p "defun" 3 3))))

(deftest non-simple-strings
  ;; A line may come from an adjustable buffer; it is coerced once at the
  ;; API boundary.
  (let ((line (make-array 16 :element-type 'character
                             :adjustable t :fill-pointer 0)))
    (loop for c across "(defun f 1)" do (vector-push-extend c line))
    (tok-reset)
    (is-equal (tokenize line)
              '((:paren "(") (:defining "defun") (:symbol "f")
                (:number "1") (:paren ")")))
    (is (tok-number-p line 9 10))
    (is (tok-defining-p line 1 6))
    (is (not (tok-defining-p line)))))

(deftest string-ending-in-a-backslash
  ;; The backslash quotes a character the line does not have: the scan
  ;; steps past the end and is clamped, and the string stays open.
  (tok-reset)
  (is-equal (tokenize-spans "\"abc\\") '((:string 0 5)))
  (is-equal (tok-where) :string)
  ;; ... and the same on a continuation line.
  (is-equal (tokenize-spans "abc\\") '((:string 0 4)))
  (is-equal (tok-where) :string)
  ;; The quote on the NEXT line is not quoted by it.
  (is-equal (tokenize "\" x") '((:string "\"") (:symbol "x")))
  (is-equal (tok-where) :code))

(deftest string-continuation-that-is-empty
  (tok-reset)
  (tokenize "\"open")
  ;; An empty line inside a string still yields its (empty) string token.
  (is-equal (tokenize-spans "") '((:string 0 0)))
  (is-equal (tok-where) :string)
  (is-equal (tokenize-spans "\"") '((:string 0 1)))
  (is-equal (tok-where) :code))

(deftest string-ends-head-position
  (tok-reset)
  (is-equal (tokenize "(\"s\" defun) (:k defun) (#\\a defun) (1 defun)")
            '((:paren "(") (:string "\"s\"") (:symbol "defun") (:paren ")")
              (:paren "(") (:keyword ":k") (:symbol "defun") (:paren ")")
              (:paren "(") (:char "#\\a") (:symbol "defun") (:paren ")")
              (:paren "(") (:number "1") (:symbol "defun") (:paren ")")))
  ;; It ends where the string OPENS, closed on this line or not ...
  (tok-reset)
  (tokenize "(\"open")
  (is-equal (tok-head) nil)
  (is-equal (tokenize "closed\" defun")
            '((:string "closed\"") (:symbol "defun")))
  ;; ... and the continuation branch clears it only when the string
  ;; closes, which shows on a state no tokenizer run produces.
  (setq *tok-state* (make-tok-state :where :string :head t))
  (tokenize "still open")
  (is-equal (tok-head) t)
  (tokenize "closed\"")
  (is-equal (tok-head) nil))

(deftest character-literal-at-end-of-line
  (tok-reset)
  (is-equal (tokenize "(#\\") '((:paren "(") (:char "#\\")))
  (is-equal (tok-head) nil)
  (is-equal (tok-where) :code)
  ;; The character after #\ belongs to the literal whatever it is; what
  ;; follows it ends the literal as it would end a symbol.
  (is-equal (tokenize "#\\\" #\\)) #\\a'b #\\  x")
            '((:char "#\\\"") (:char "#\\)") (:paren ")") (:char "#\\a")
              (:symbol "'") (:symbol "b") (:char "#\\ ") (:symbol "x")))
  (is-equal (tok-where) :code))

(deftest bar-quoted-symbols
  (tok-reset)
  (is-equal (tokenize "(|sym with ( paren| x)")
            '((:paren "(") (:symbol "|sym with ( paren|") (:symbol "x")
              (:paren ")")))
  ;; Bars inside an atom, and a backslash-quoted space.
  (is-equal (tokenize "(defun|x| foo\\ bar")
            '((:paren "(") (:symbol "defun|x|") (:symbol "foo\\ bar")))
  ;; A backslash inside the bars quotes the closing bar.
  (is-equal (tokenize "|a\\|b| c") '((:symbol "|a\\|b|") (:symbol "c")))
  ;; An unclosed bar takes the rest of the line and no more: unlike a
  ;; string it is NOT carried to the next line.
  (tok-reset)
  (is-equal (tokenize "(|open ( bar")
            '((:paren "(") (:symbol "|open ( bar")))
  (is-equal (tok-where) :code)
  (is-equal (tokenize "defun)") '((:symbol "defun") (:paren ")"))))

(deftest atom-ending-in-a-backslash
  ;; As in a string: stepped past the end, clamped.
  (tok-reset)
  (is-equal (tokenize-spans "foo\\") '((:symbol 0 4)))
  (is-equal (tokenize-spans "|a\\") '((:symbol 0 3)))
  (is-equal (tokenize-spans "\\") '((:symbol 0 1))))

(deftest prefix-characters
  (tok-reset)
  ;; ,@ is one token; every other prefix character is one of its own.
  (is-equal (tokenize "`(a ,@b ,c)")
            '((:symbol "`") (:paren "(") (:symbol "a") (:symbol ",@")
              (:symbol "b") (:symbol ",") (:symbol "c") (:paren ")")))
  (is-equal (tokenize ",") '((:symbol ",")))
  (is-equal (tokenize "'a") '((:symbol "'") (:symbol "a")))
  ;; A # that opens neither a comment nor a character is a prefix too, so
  ;; a radix number in a LINE is a # and a symbol: TOK-NUMBER-P knows #xFF,
  ;; the tokenizer never asks it.
  (is-equal (tokenize "(a #xFF #")
            '((:paren "(") (:symbol "a") (:symbol "#") (:symbol "xFF")
              (:symbol "#"))))

(deftest head-position-survives-a-prefix
  (tok-reset)
  (is-equal (tokenize "(#'defun x)")
            '((:paren "(") (:symbol "#") (:symbol "'") (:defining "defun")
              (:symbol "x") (:paren ")")))
  (is-equal (tokenize "('defun)")
            '((:paren "(") (:symbol "'") (:defining "defun") (:paren ")")))
  (is-equal (tokenize "(,@") '((:paren "(") (:symbol ",@")))
  (is-equal (tok-head) t))

(deftest head-position-and-comments
  ;; Neither kind of comment ends head position ...
  (tok-reset)
  (tokenize "(")
  (is-equal (tokenize "; comment") '((:comment "; comment")))
  (is-equal (tok-head) t)
  (is-equal (tokenize "  defun") '((:defining "defun")))
  (is-equal (tok-head) nil)
  (tok-reset)
  (tokenize "(")
  (is-equal (tokenize "#| c |# defun")
            '((:comment "#| c |#") (:defining "defun")))
  ;; ... and a close paren does.
  (tok-reset)
  (is-equal (tokenize "() defun")
            '((:paren "(") (:paren ")") (:symbol "defun"))))

(deftest brackets-are-parens
  (tok-reset)
  (is-equal (tokenize (format nil "[defun]~Cx" #\Tab))
            '((:paren "[") (:defining "defun") (:paren "]") (:symbol "x")))
  (is-equal (tok-head) nil))

(deftest atoms-in-a-line
  (tok-reset)
  (is-equal (tokenize "(a 1+ +.5 . 1. 1e 1.5e-3 - :k DEFUN)")
            '((:paren "(") (:symbol "a") (:symbol "1+") (:number "+.5")
              (:symbol ".") (:number "1.") (:symbol "1e")
              (:number "1.5e-3") (:symbol "-") (:keyword ":k")
              (:symbol "DEFUN") (:paren ")")))
  ;; A colon first makes a keyword even of what would be a number, and a
  ;; keyword in head position is no defining form.
  (is-equal (tokenize "(:defun :42 :")
            '((:paren "(") (:keyword ":defun") (:keyword ":42")
              (:keyword ":"))))

(deftest whitespace-characters
  (tok-reset)
  ;; Tab, return and page separate tokens and belong to none.
  (is-equal (tokenize-spans
             (format nil "a~Cb~Cc~Cd" #\Tab #\Return #\Page))
            '((:symbol 0 1) (:symbol 2 1) (:symbol 4 1) (:symbol 6 1)))
  ;; A newline is not expected inside a line.  It terminates an atom but
  ;; is not skipped as white space, so it comes out as a token of its own
  ;; -- the "never fail to advance" step of the atom branch.
  (is-equal (tokenize-spans (format nil "a~Cb" #\Newline))
            '((:symbol 0 1) (:symbol 1 1) (:symbol 2 1))))

(deftest block-comment-closing-mid-line
  (tok-reset)
  (is-equal (tokenize "#| a #| b |# c |# (defun x) #| open")
            '((:comment "#| a #| b |# c |#") (:paren "(")
              (:defining "defun") (:symbol "x") (:paren ")")
              (:comment "#| open")))
  (is-equal (tok-where) :block-comment)
  (is-equal (tok-depth) 1)
  (is-equal (tokenize "still |# (defun")
            '((:comment "still |#") (:paren "(") (:defining "defun")))
  (is-equal (tok-where) :code)
  (is-equal (tok-depth) 0))

(deftest block-comment-delimiters-that-overlap
  ;; #|#|# is two opens and a stray #; |#|#x is two closes.  A | is never
  ;; shared between a close and an open.
  (tok-reset)
  (is-equal (tokenize-spans "#|#|#") '((:comment 0 5)))
  (is-equal (tok-depth) 2)
  (is-equal (tokenize "|#|#x") '((:comment "|#|#") (:symbol "x")))
  (is-equal (tok-where) :code)
  ;; A lone # or | at the end of the line is neither.
  (tok-reset)
  (is-equal (tokenize-spans "#| x |") '((:comment 0 6)))
  (is-equal (tok-depth) 1)
  (is-equal (tokenize-spans "#") '((:comment 0 1)))
  (is-equal (tok-depth) 1)
  ;; Strings and semicolons mean nothing inside one.
  (is-equal (tokenize "\" ; |# \"s\"") '((:comment "\" ; |#")
                                         (:string "\"s\"")))
  (is-equal (tok-where) :code))

(deftest block-comment-empty-continuation
  (tok-reset)
  (tokenize "#|")
  (is-equal (tokenize-spans "") '((:comment 0 0)))
  (is-equal (tok-where) :block-comment)
  (is-equal (tok-depth) 1))

(deftest block-comment-deep-nesting
  ;; The one deliberate difference from token.c, whose depth is a byte that
  ;; saturates at 255 (and so closes such a comment early): the depth here
  ;; is an integer.
  (tok-reset)
  (let ((opens (make-string 600))
        (closes (make-string 598)))
    (dotimes (i 300)
      (setf (schar opens (* 2 i)) #\#
            (schar opens (1+ (* 2 i))) #\|))
    (dotimes (i 299)
      (setf (schar closes (* 2 i)) #\|
            (schar closes (1+ (* 2 i))) #\#))
    (tokenize opens)
    (is-equal (tok-depth) 300)
    (is-equal (tokenize-spans closes) '((:comment 0 598)))
    (is-equal (tok-where) :block-comment)
    (is-equal (tok-depth) 1)
    (is-equal (tokenize "|# x") '((:comment "|#") (:symbol "x")))
    (is-equal (tok-where) :code)))

(deftest state-equality-and-copy
  (let* ((a (make-tok-state))
         (b (copy-tok-state a)))
    (is-equal (tok-state-where a) :code)
    (is-equal (tok-state-depth a) 0)
    (is-equal (tok-state-head a) nil)
    (is (not (eq a b)))
    (is (tok-state-equal a b))
    (setf (tok-state-depth b) 1)
    (is (not (tok-state-equal a b)))
    (setf (tok-state-depth b) 0
          (tok-state-head b) t)
    (is (not (tok-state-equal a b)))
    ;; The copy is what redisplay keeps per line: tokenizing on does not
    ;; touch it.
    (let ((before (copy-tok-state b)))
      (tokenize-line "x \"open" b)
      (is (not (tok-state-equal before b)))
      (is-equal (tok-state-head before) t)
      (is-equal (tok-state-where before) :code))))

(deftest retokenize-until-the-state-matches
  ;; The redisplay protocol of the file header: after an edit, lines are
  ;; re-tokenized until the state at the end of one equals what it was.
  (let ((lines '("(foo \"a" "b\" bar)" "(baz)"))
        (st (make-tok-state))
        (ends '()))
    (dolist (line lines)
      (tokenize-line line st)
      (push (copy-tok-state st) ends))
    (setq ends (nreverse ends))
    ;; Edit line 0 so the string closes on it: line 1 now ends differently
    ;; (it opens a string of its own), line 2 must be redone as well.
    (let ((st (make-tok-state)))
      (tokenize-line "(foo \"a\"" st)
      (is (not (tok-state-equal st (first ends))))
      (tokenize-line (second lines) st)
      (is (not (tok-state-equal st (second ends))))
      (is-equal (tok-state-where st) :string))
    ;; An edit that keeps the string open leaves line 0's end state as it
    ;; was: nothing below needs another look.
    (let ((st (make-tok-state)))
      (tokenize-line "(foo \"abc" st)
      (is (tok-state-equal st (first ends))))))
