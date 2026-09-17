;;;; test-sexp.lisp -- the s-expression scanner.  The cases of
;;;; tests/test_sexp.c under their C names, then (the SEXP- tests) what the C
;;;; file leaves uncovered; every expectation of those was taken from the C
;;;; code, which is the specification, not from the Lisp.
;;;;
;;;; Positions are located with SX-AT rather than counted by hand, so the test
;;;; source stays readable and a fixture can be edited without renumbering.

(in-package :clamacs)

(defun sx-text (&rest lines)
  "LINES joined by newlines; a last \"\" gives the text a final newline."
  (with-output-to-string (out)
    (loop for (line . more) on lines
          do (write-string line out)
             (when more
               (write-char #\Newline out)))))

(defun sx-at (buf needle)
  (or (search needle buf)
      (error "fixture does not contain ~S" needle)))

(defun sx-tokens (buf)
  "Every token of BUF as (kind start end)."
  (let ((pos 0)
        (tokens '()))
    (loop
      (multiple-value-bind (kind start end) (sx-next buf (length buf) pos)
        (when (eq kind :eof)
          (return (nreverse tokens)))
        (push (list kind start end) tokens)
        (setq pos end)))))

(defun sx-last (buf pos)
  (multiple-value-bind (start end) (sexp-last-sexp buf pos)
    (and start (list start end))))

(defun sx-nest (n &optional (close t) (tail ""))
  "N open parens, their N close parens unless CLOSE is NIL, then TAIL."
  (concatenate 'string
               (make-string n :initial-element #\()
               (if close (make-string n :initial-element #\)) "")
               tail))

(defun sx-non-simple (text)
  "TEXT as an adjustable string with a fill pointer and room to spare."
  (let ((buf (make-array (+ (length text) 8) :element-type 'character
                                             :adjustable t
                                             :fill-pointer 0)))
    (loop for c across text do (vector-push c buf))
    buf))

(deftest forward-over-atoms-and-lists
  (let* ((b "(foo bar)")
         (n (length b)))
    (is-equal (sexp-forward b 0) 9)          ; the whole list
    (is-equal (sexp-forward b 1) 4)          ; foo
    (is-equal (sexp-forward b 4) 8)          ; bar
    (is-equal (sexp-forward b 8) nil)        ; at the close paren
    (is-equal (sexp-forward b n) nil)))      ; at the end

(deftest forward-from-inside-an-atom
  ;; Emacs moves to the end of the atom point is standing in.
  (is-equal (sexp-forward "(foo bar)" 2) 4))

(deftest forward-over-a-quoted-form
  (is-equal (sexp-forward "'(a b) next" 0) 6)
  ;; ,@ and #' are prefixes too.
  (is-equal (sexp-forward ",@(a) x" 0) 5)
  (is-equal (sexp-forward "#'foo bar" 0) 5)
  (is-equal (sexp-forward "#(1 2 3) x" 0) 8))

(deftest forward-over-a-string
  (let* ((b "(f \"a ) b\" c)")
         (s (sx-at b "\"")))
    (is-equal (sexp-forward b s) (+ s 7))    ; past "a ) b"
    ;; The `)' inside the string must not close the list.
    (is-equal (sexp-forward b 0) (length b))))

(deftest unbalanced-input-does-not-hang
  (is-equal (sexp-forward "(a b" 0) nil)
  (is-equal (sexp-forward "" 0) nil)
  (is-equal (sexp-forward ")))" 0) nil)
  (is-equal (sexp-backward "(((" 3) nil)
  (is-equal (sexp-forward "\"unterminated" 0) 13))

(deftest backward-over-atoms-and-lists
  (let* ((b "(foo bar)")
         (n (length b)))
    (is-equal (sexp-backward b n) 0)         ; the whole list
    (is-equal (sexp-backward b 8) 5)         ; bar
    (is-equal (sexp-backward b 4) 1)         ; foo
    (is-equal (sexp-backward b 1) nil)       ; nothing before it
    (is-equal (sexp-backward b 0) nil)))

(deftest backward-includes-the-quote
  ;; backward-sexp from the end must land on the quote, not on the paren:
  ;; the quote is part of the form, and `C-x C-e' sends what it delimits.
  (let ((b "'(a b)"))
    (is-equal (sexp-backward b (length b)) 0)))

(deftest backward-from-inside-an-atom
  (is-equal (sexp-backward "(foo bar)" 6) 5))

(deftest up-and-down-list
  (let* ((b "(a (b (c)) d)")
         (c (sx-at b "c")))
    (is-equal (sexp-up b c) (sx-at b "(c)"))
    (is-equal (sexp-up b (sx-at b "(c)")) (sx-at b "(b "))
    (is-equal (sexp-up b (sx-at b "(b ")) 0)
    (is-equal (sexp-up b 0) nil)             ; already at top level
    (is-equal (sexp-down b 0) 1)
    (is-equal (sexp-down b 1) (+ (sx-at b "(b ") 1))))

(deftest down-list-refuses-to-leave-the-list
  ;; From inside the first list there is no sublist to descend into; the
  ;; close paren stops the search rather than jumping to (c).
  (is-equal (sexp-down "(a b) (c)" 3) nil))

(defparameter *sx-fixture*
  (sx-text "(in-package :my-app)"
           ""
           "(defun frobnicate (x)"
           "  ;; a ) paren in a comment"
           "  (let ((y \"a ( string\"))"
           "    (list x y)))"
           ""
           "(defvar *thing* 42)"
           ""))

(deftest defun-start-and-end
  (let* ((fixture *sx-fixture*)
         (defun-pos (sx-at fixture "(defun"))
         (inner (sx-at fixture "(list"))
         (defvar-pos (sx-at fixture "(defvar")))
    (is-equal (sexp-defun-start fixture inner) defun-pos)
    ;; A `(' in column 0 is what makes a defun; the nested ones do not
    ;; count, however deep point is.
    (is-equal (sexp-defun-start fixture defvar-pos) defvar-pos)
    (is-equal (sexp-defun-start fixture 0) 0)
    (is-equal (sexp-defun-end fixture inner)
              (+ (sx-at fixture "(list x y)))") (length "(list x y)))")))))

(deftest comments-and-strings-hide-their-parens
  ;; The whole defun still closes correctly despite a `)' in a comment and
  ;; a `(' in a string.
  (let ((fixture *sx-fixture*))
    (is-equal (sexp-forward fixture (sx-at fixture "(defun"))
              (+ (sx-at fixture "(list x y)))") (length "(list x y)))")))))

(deftest context
  (let ((fixture *sx-fixture*))
    (is-equal (sexp-context fixture (sx-at fixture "paren in a")) :comment)
    (is-equal (sexp-context fixture (+ (sx-at fixture "a ( string") 2))
              :string)
    (is-equal (sexp-context fixture (sx-at fixture "(list")) :code)))

(deftest match-paren
  (let ((b "(a (b) c)"))
    (is-equal (sexp-match-paren b 0) 8)
    (is-equal (sexp-match-paren b 8) 0)
    (is-equal (sexp-match-paren b 3) 5)
    (is-equal (sexp-match-paren b 5) 3)
    (is-equal (sexp-match-paren b 1) nil)))  ; not on a paren

(deftest match-paren-ignores-comments-and-strings
  (let* ((fixture *sx-fixture*)
         (comment-paren (sx-at fixture ") paren in a comment"))
         (string-paren (sx-at fixture "( string")))
    (is-equal (sexp-match-paren fixture comment-paren) nil)
    (is-equal (sexp-match-paren fixture string-paren) nil)
    ;; And a real paren still matches across both of them.
    (is-equal (sexp-match-paren fixture (sx-at fixture "(let"))
              (+ (sx-at fixture "(list x y)))") (length "(list x y))") -1))))

(deftest match-paren-unbalanced
  (is-equal (sexp-match-paren "(a b" 0) nil)
  (is-equal (sexp-match-paren "a)" 1) nil))

(deftest last-sexp
  (let* ((b "(foo) (+ 1 2)")
         (n (length b)))
    (is-equal (multiple-value-list (sexp-last-sexp b n)) '(6 13))
    ;; Point right after the first form.
    (is-equal (multiple-value-list (sexp-last-sexp b 5)) '(0 5))
    (is-equal (multiple-value-list (sexp-last-sexp b 0)) '(nil))))

(deftest current-package
  (let* ((fixture *sx-fixture*)
         (n (length fixture)))
    (is-equal (sexp-current-package fixture n) "my-app")
    ;; A form later in the file must not apply above itself.
    (is-equal (sexp-current-package fixture 0) nil)))

(deftest current-package-spellings
  (is-equal (sexp-current-package "(in-package \"BAR\")" 18) "BAR")
  (is-equal (sexp-current-package "(in-package #:baz)" 18) "baz")
  (is-equal (sexp-current-package "(IN-PACKAGE :qux)" 17) "qux")
  (is-equal (sexp-current-package "(defun in-package ())" 21) nil))

(deftest current-package-takes-the-nearest-one-above
  (let ((b (sx-text "(in-package :a)" "(foo)" "(in-package :b)" "(bar)" "")))
    (is-equal (sexp-current-package b (sx-at b "(foo)")) "a")
    (is-equal (sexp-current-package b (sx-at b "(bar)")) "b")))

(deftest character-literal-parens-are-not-parens
  (let* ((b "(list #\\( #\\))")
         (n (length b)))
    (is-equal (sexp-forward b 0) n)
    (is-equal (sexp-match-paren b 0) (- n 1))))

;;; ------------------------------------------------------------------
;;; Phase 2: the operator and the symbol at point
;;; ------------------------------------------------------------------

(defun op-at (buf pos)
  "The operator at POS as a string, or NIL."
  (multiple-value-bind (start end) (sexp-operator-at-point buf pos)
    (and start (subseq buf start end))))

(deftest operator-is-the-head-of-the-innermost-list
  (let ((b (sx-text "(defun foo (a b)"
                    "  (let ((x 1))"
                    "    (mapcar #'bar lst)))")))
    (is-equal (op-at b (sx-at b "lst)")) "mapcar")
    (is-equal (op-at b (+ (sx-at b "lst)") 3)) "mapcar") ; just before the `)'
    (is-equal (op-at b (sx-at b "1))")) "x")       ; a binding: its head
    (is-equal (op-at b (sx-at b "(mapcar")) "let") ; between the forms
    (is-equal (op-at b (sx-at b "(let")) "defun")
    (is-equal (op-at b (sx-at b "b)")) "a")))      ; the lambda list

(deftest operator-skips-quoted-data
  (let ((b "(member x '(a b))"))
    (is-equal (op-at b (sx-at b "b))")) "member"))
  ;; `#'' is a function, not data.
  (let ((b "(mapcar #'(lambda (x) x) l)"))
    (is-equal (op-at b (sx-at b "x) l")) "lambda"))
  ;; Inside a backquote a comma is code again.
  (let ((b "`(a ,(foo x) b)"))
    (is-equal (op-at b (sx-at b "x) b")) "foo")
    (is-equal (op-at b (sx-at b "b)")) nil))       ; data: nothing
  ;; A quoted list's inner lists are data too.
  (let ((b "(list '(a (b c)))"))
    (is-equal (op-at b (sx-at b "c)))")) "list")))

(deftest operator-needs-a-symbol-head
  (is-equal (op-at "(list (1 2))" 10) "list")      ; a number is no operator
  (is-equal (op-at "(getf p :a 1)" 11) "getf")
  (is-equal (op-at "(:a 1 :b 2)" 5) nil)           ; a plist
  (is-equal (op-at "((lambda (x) x) 1)" 17) nil)   ; a list in head position
  (is-equal (op-at "(f \"a b\")" 5) "f")           ; inside a string
  (is-equal (op-at "foo bar" 4) nil)               ; no list at all
  (is-equal (op-at "" 0) nil))

(deftest operator-being-typed-is-not-asked-about
  (let ((b "(defu x)"))
    ;; Inside the head: the user is still typing it.
    (is-equal (op-at b 3) nil)
    ;; At its end it is complete as far as we can tell.
    (is-equal (op-at b 5) "defu"))
  ;; And a nested one while typing does not fall back to the outer.
  (is-equal (op-at "(let ((x (fo" 11) nil))

(defun sym-at (buf pos)
  "The symbol at POS as a string, or NIL."
  (multiple-value-bind (start end) (sexp-symbol-at-point buf pos)
    (and start (subseq buf start end))))

(deftest symbol-at-point
  (is-equal (sym-at "foo bar" 0) "foo")
  (is-equal (sym-at "foo bar" 1) "foo")
  (is-equal (sym-at "foo bar" 3) "foo")            ; just after it
  (is-equal (sym-at "foo bar" 4) "bar")
  (is-equal (sym-at "foo bar" 7) "bar")            ; at the end of the buffer
  (is-equal (sym-at "foo  bar" 4) nil)             ; between two spaces
  (is-equal (sym-at "(cl:mapcar f l)" 3) "cl:mapcar")
  (is-equal (sym-at "'foo" 2) "foo")               ; the quote is not part of it
  (is-equal (sym-at "(f \"str\")" 5) "str")        ; inside a string, as Emacs
  (is-equal (sym-at (sx-text ";; see frob" "") 8) "frob")
  (is-equal (sym-at "(foo)" 0) nil)
  (is-equal (sym-at "(foo)" 4) "foo")              ; on the `)': the one before
  (is-equal (sym-at "" 0) nil)
  (is-equal (sym-at "*var*" 2) "*var*")
  (is-equal (sym-at "a-b.c/d" 3) "a-b.c/d"))

(deftest input-complete-for-the-repl
  ;; Complete: RET sends these.
  (is-equal (sexp-input-complete-p "(+ 1 2)") t)
  (is-equal (sexp-input-complete-p "42") t)
  (is-equal (sexp-input-complete-p "\"a string\"") t)
  (is-equal (sexp-input-complete-p "(a) (b)") t)
  (is-equal (sexp-input-complete-p "'(a b)") t)
  (is-equal (sexp-input-complete-p "#'car") t)
  (is-equal (sexp-input-complete-p "(list #\\( #\\))") t)
  (is-equal (sexp-input-complete-p "(a) ; comment (") t)
  (is-equal (sexp-input-complete-p "#| note |# 1") t)
  (is-equal (sexp-input-complete-p "(\"a\\\"b\")") t)
  (is-equal (sexp-input-complete-p "") t)
  (is-equal (sexp-input-complete-p nil) t)
  ;; Incomplete: RET inserts a newline and waits for more.
  (is-equal (sexp-input-complete-p "(defun foo (x)") nil)
  (is-equal (sexp-input-complete-p (sx-text "(defun foo (x)" "  (* x")) nil)
  (is-equal (sexp-input-complete-p "\"open string") nil)
  ;; (The C case passes a length one short of the text, so the closing
  ;; quote is not part of the input.)
  (is-equal (sexp-input-complete-p "(princ \"a)") nil)
  (is-equal (sexp-input-complete-p "#| still a comment") nil)
  (is-equal (sexp-input-complete-p "'") nil)
  (is-equal (sexp-input-complete-p "(a) '") nil)
  (is-equal (sexp-input-complete-p "\"a\\\"") nil) ; the quote is escaped
  ;; Too many closers: complete, so READ can complain.
  (is-equal (sexp-input-complete-p "(a))") t))

;;; ------------------------------------------------------------------
;;; What the C tests leave uncovered.  Expectations are the C code's.
;;; ------------------------------------------------------------------

(deftest sexp-walker-whitespace-and-positions
  ;; Space, tab, newline, return and page separate tokens; nothing else.
  (let ((b (format nil " ~C~C~C~C a~Cb~Cc~Cd"
                   #\Tab #\Return #\Newline #\Page #\Tab #\Page #\Return)))
    (is-equal (sx-tokens b)
              '((:atom 6 7) (:atom 8 9) (:atom 10 11) (:atom 12 13))))
  (is-equal (sx-tokens (format nil " ~C~C~C~C " #\Tab #\Return #\Newline
                               #\Page))
            '())
  ;; A position before the buffer reads from its start; one past its end
  ;; is the end of the buffer, and END is still the length.
  (is-equal (multiple-value-list (sx-next "ab" 2 -3)) '(:atom 0 2))
  (is-equal (multiple-value-list (sx-next "ab" 2 2)) '(:eof 2 2))
  (is-equal (multiple-value-list (sx-next "ab" 2 5)) '(:eof 5 2))
  (is-equal (multiple-value-list (sx-next "" 0 0)) '(:eof 0 0)))

(deftest sexp-depth-limit
  ;; 128 open lists is the limit of every function that keeps a stack, as
  ;; in the C code; one more and the answer is "not possible".
  (let ((deep (sx-nest 128))
        (deeper (sx-nest 129)))
    (is-equal (sexp-forward deep 0) 256)
    (is-equal (sexp-forward deeper 0) nil)
    ;; ... counted from where the move starts, not from the top.
    (is-equal (sexp-forward deeper 1) 257)
    (is-equal (sexp-match-paren deep 0) 255)
    (is-equal (sexp-match-paren deep 127) 128)
    (is-equal (sexp-match-paren deep 128) 127)
    (is-equal (sexp-match-paren deep 255) 0)
    (is-equal (sexp-match-paren deeper 0) nil)
    (is-equal (sexp-match-paren deeper 128) nil)
    (is-equal (sexp-match-paren deeper 129) nil)
    (is-equal (sexp-match-paren deeper 257) nil)
    (is-equal (sexp-backward deep 256) 0)
    (is-equal (sexp-backward deeper 258) nil))
  (let ((open (sx-nest 128 nil))
        (opener (sx-nest 129 nil)))
    (is-equal (sexp-up open 128) 127)
    (is-equal (sexp-up opener 129) nil)
    (is-equal (sexp-down open 127) 128)
    (is-equal (sexp-down opener 128) 129)   ; keeps no stack
    (is-equal (sexp-backward open 128) nil)
    (is-equal (sexp-input-complete-p open) nil)
    (is-equal (sexp-input-complete-p opener) nil))
  (is-equal (sexp-backward (sx-nest 128 nil "a") 129) 128)
  (is-equal (sexp-backward (sx-nest 129 nil "a") 130) nil)
  (is-equal (sx-last (sx-nest 128 nil "a") 129) '(128 129))
  (is-equal (sx-last (sx-nest 129 nil "a") 130) nil)
  (flet ((heads (n)
           (let ((b (with-output-to-string (out)
                      (dotimes (i n) (write-string "(f " out)))))
             (multiple-value-list
              (sexp-operator-at-point b (length b))))))
    (is-equal (heads 128) '(382 383))
    (is-equal (heads 129) '(nil)))
  ;; The package scan counts depth but keeps no stack.
  (is-equal (sexp-current-package (sx-nest 129 t "(in-package :x)") 300)
            "x"))

(deftest sexp-operator-bounds
  ;; The head of an ENCLOSING list: its end is read again from its start.
  (is-equal (multiple-value-list (sexp-operator-at-point "(defun foo (" 12))
            '(1 6))
  (is-equal (multiple-value-list (sexp-operator-at-point "(|my op| (1" 11))
            '(1 8))
  (is-equal (multiple-value-list (sexp-operator-at-point "(foo x)" 6))
            '(1 4))
  (is-equal (multiple-value-list (sexp-operator-at-point "'(a b)" 5))
            '(nil)))

(deftest sexp-symbol-at-point-and-the-nul-character
  ;; A NUL is no symbol character: the C code never scans across one.
  (let ((b (format nil "a~Cb" (code-char 0))))
    (is-equal (multiple-value-list (sexp-symbol-at-point b 1)) '(0 1))
    (is-equal (multiple-value-list (sexp-symbol-at-point b 2)) '(2 3)))
  (is-equal (multiple-value-list (sexp-symbol-at-point "(foo)" 0)) '(nil)))

(deftest sexp-buffers-that-are-not-simple-strings
  ;; The scans are declared for SIMPLE-STRING; the public functions accept
  ;; any string, and only the characters below the fill pointer.
  (let ((b (sx-non-simple "(foo 'bar) \"s\" ; c")))
    (is (not (simple-string-p b)))
    (is-equal (sexp-forward b 0) 10)
    (is-equal (sexp-backward b 10) 0)
    (is-equal (sexp-up b 6) 0)
    (is-equal (sexp-down b 0) 1)
    (is-equal (sexp-defun-start b 5) 0)
    (is-equal (sexp-defun-end b 5) 10)
    (is-equal (sexp-match-paren b 9) 0)
    (is-equal (sx-last b 10) '(0 10))
    (is-equal (sexp-context b 12) :string)
    (is-equal (sexp-context b 17) :comment)
    (is-equal (op-at b 9) "foo")
    (is-equal (sym-at b 7) "bar")
    (is-equal (sexp-input-complete-p b) t)
    (vector-push-extend #\( b)
    (is-equal (sexp-input-complete-p b) t)  ; the `(' is in the comment
    (is-equal (sexp-current-package (sx-non-simple "(in-package :foo)") 17)
              "foo"))
  ;; No buffer at all is the empty buffer.
  (is-equal (sexp-forward nil 0) nil)
  (is-equal (sexp-context nil 0) :code)
  (is-equal (sexp-current-package nil 0) nil))

(deftest sexp-current-package-is-a-fresh-string
  (let* ((b (copy-seq "(in-package :foo)"))
         (name (sexp-current-package b 17)))
    (is (simple-string-p name))
    (setf (char b 13) #\x)
    (is-equal name "foo")))

(deftest sexp-walker-token-stream
  (is-equal (sx-tokens
             (sx-text "(a 'b ,@c #'d \"s\" ; c"
                      " #|x|# #\\( |q r| [e])"))
            '((:open 0 1) (:atom 1 2) (:quote 3 4) (:atom 4 5) (:quote 6 8)
              (:atom 8 9) (:quote 10 11) (:quote 11 12) (:atom 12 13)
              (:string 14 17) (:comment 18 21) (:comment 23 28)
              (:atom 29 32) (:atom 33 38) (:open 39 40) (:atom 40 41)
              (:close 41 42) (:close 42 43)))
  (is-equal (sx-tokens "`(,a #(1) #x10 #p\"f\")")
            '((:quote 0 1) (:open 1 2) (:quote 2 3) (:atom 3 4) (:quote 5 6)
              (:open 6 7) (:atom 7 8) (:close 8 9) (:quote 10 11)
              (:atom 11 14) (:quote 15 16) (:atom 16 17) (:string 17 20)
              (:close 20 21)))
  (is-equal (sx-tokens "#| a #| b |# c |# x")
            '((:comment 0 17) (:atom 18 19)))
  (is-equal (sx-tokens "#\\; #\\Space #\\a-b #\\")
            '((:atom 0 3) (:atom 4 11) (:atom 12 17) (:atom 18 20)))
  (is-equal (sx-tokens "a\\ b |c\\|d| e|f g|h")
            '((:atom 0 4) (:atom 5 11) (:atom 12 19)))
  (is-equal (sx-tokens "\"a\\\"b\" \"c")
            '((:string 0 6) (:string 7 9)))
  (is-equal (sx-tokens "abc\\")
            '((:atom 0 4)))
  (is-equal (sx-tokens "\"abc\\")
            '((:string 0 5)))
  (is-equal (sx-tokens "|abc")
            '((:atom 0 4)))
  (is-equal (sx-tokens "|ab\\")
            '((:atom 0 4)))
  (is-equal (sx-tokens "#|")
            '((:comment 0 2)))
  (is-equal (sx-tokens "#")
            '((:quote 0 1)))
  (is-equal (sx-tokens ",@")
            '((:quote 0 2)))
  (is-equal (sx-tokens "")
            '()))

(deftest sexp-forward-positions-at-the-edges
  (is-equal (sexp-forward "(foo bar)" -5) 9)
  (is-equal (sexp-forward "(foo bar)" 20) nil)
  (is-equal (sexp-forward "  foo" 0) 5)
  (is-equal (sexp-forward "foo   " 3) nil)
  (is-equal (sexp-forward "x" 0) 1)
  (is-equal (sexp-forward "x" 1) nil))

(deftest sexp-forward-skips-comments
  (is-equal (sexp-forward (sx-text "foo ; c" " bar") 3) 12)
  (is-equal (sexp-forward "#| c ( |# (x)" 0) 13)
  (is-equal (sexp-forward "#| a #| b |# c |# x" 0) 19)
  (is-equal (sexp-forward (sx-text "; abc" "foo") 2) 9)
  (is-equal (sexp-forward (sx-text "(a ; )" " b)") 0) 10)
  (is-equal (sexp-forward (sx-text "' ; c" " x") 0) 8)
  (is-equal (sexp-forward "; only" 0) nil)
  (is-equal (sexp-forward "#| open" 0) nil))

(deftest sexp-forward-prefixes
  (is-equal (sexp-forward "`(a ,@b) c" 0) 8)
  (is-equal (sexp-forward ",@" 0) nil)
  (is-equal (sexp-forward "'" 0) nil)
  (is-equal (sexp-forward "' ; c" 0) nil)
  ;; Inside a prefix token there is nothing to move over.
  (is-equal (sexp-forward ",@x" 1) nil)
  (is-equal (sexp-forward "''a b" 0) 3)
  (is-equal (sexp-forward "#'(lambda (x) x) y" 0) 16)
  (is-equal (sexp-forward "#x10 y" 0) 4)
  ;; `#' is one character of prefix whatever follows: the `p' is an atom of
  ;; its own, and the move ends after it.
  (is-equal (sexp-forward "#p\"f\" y" 0) 2)
  (is-equal (sexp-forward "(a ')" 3) nil))

(deftest sexp-forward-lexical-quirks
  (is-equal (sexp-forward "#\\; x" 0) 3)
  (is-equal (sexp-forward "#\\Space x" 0) 7)
  (is-equal (sexp-forward "#\\( x" 0) 3)
  (is-equal (sexp-forward "#\\" 0) 2)
  (is-equal (sexp-forward "|a b| c" 0) 5)
  (is-equal (sexp-forward "a\\ b c" 0) 4)
  ;; A backslash as the last character skips past the end and is clamped.
  (is-equal (sexp-forward "abc\\" 0) 4)
  (is-equal (sexp-forward "\"abc\\" 0) 5)
  (is-equal (sexp-forward "(f \"abc\")" 5) 8)
  (is-equal (sexp-forward "(f \"a;b\" c)" 0) 11)
  (is-equal (sexp-forward "(f \"a\\\"b)\" c)" 0) 13)
  (is-equal (sexp-forward "|abc" 0) 4)
  (is-equal (sexp-forward "foo|a b|bar x" 0) 11))

(deftest sexp-forward-brackets
  (is-equal (sexp-forward "(a [b c] d)" 3) 8)
  (is-equal (sexp-forward "[a b]" 0) 5)
  (is-equal (sexp-forward "(a b]" 0) 5)
  (is-equal (sexp-forward "[a (b] c)" 0) 9))

(deftest sexp-backward-positions-at-the-edges
  (is-equal (sexp-backward "(a) b" 100) 4)
  (is-equal (sexp-backward "(a) b" -1) nil)
  (is-equal (sexp-backward "  a" 2) nil)
  (is-equal (sexp-backward "a  " 3) 0)
  (is-equal (sexp-backward "x" 1) 0))

(deftest sexp-backward-includes-every-prefix
  (is-equal (sexp-backward "'foo" 4) 0)
  (is-equal (sexp-backward "#'foo bar" 5) 0)
  (is-equal (sexp-backward ",@(a) x" 5) 0)
  (is-equal (sexp-backward "(a 'b)" 5) 3)
  (is-equal (sexp-backward "#(1 2)" 6) 0)
  (is-equal (sexp-backward "`(a ,b)" 6) 4)
  (is-equal (sexp-backward "' foo" 5) 0)
  (is-equal (sexp-backward "''a" 3) 0)
  (is-equal (sexp-backward "'\"abc\"" 3) 0)
  (is-equal (sexp-backward "'foo" 2) 0)
  ;; A prefix with no form after it is not a form: the one before it is.
  (is-equal (sexp-backward "a '" 3) 0)
  (is-equal (sexp-backward "(a) '" 5) 0))

(deftest sexp-backward-unbalanced
  (is-equal (sexp-backward "(a b" 4) 3)
  (is-equal (sexp-backward "a b)" 4) 2)
  (is-equal (sexp-backward "(foo (bar" 9) 6)
  (is-equal (sexp-backward "(foo (" 6) nil)
  (is-equal (sexp-backward "a) b) c" 7) 6)
  (is-equal (sexp-backward ")))" 3) nil))

(deftest sexp-backward-strings-and-comments
  (is-equal (sexp-backward "(f \"abc\")" 6) 3)
  (is-equal (sexp-backward "(f \"a ( b\")" 10) 3)
  ;; Inside a comment: the form before the comment.
  (is-equal (sexp-backward (sx-text "a ; b c" "") 5) 0)
  (is-equal (sexp-backward (sx-text "a ; c" "b") 7) 6)
  (is-equal (sexp-backward "a #| ( |# b" 11) 10)
  (is-equal (sexp-backward "(a #\\) b)" 8) 7)
  (is-equal (sexp-backward "(a #\\) b)" 9) 0))

(deftest sexp-backward-brackets
  (is-equal (sexp-backward "[a b]" 5) 0)
  (is-equal (sexp-backward "(a [b c])" 8) 3))

(deftest sexp-up-list-edge-cases
  (is-equal (sexp-up "(a (b))" 100) nil)
  (is-equal (sexp-up "(a (b))" -1) nil)
  (is-equal (sexp-up "(a \"b (\" c)" 9) 0)
  (is-equal (sexp-up "(a) b" 5) nil)
  ;; A surplus close paren at top level is ignored.
  (is-equal (sexp-up ") (a" 4) 2)
  (is-equal (sexp-up "(abc)" 3) 0)
  (is-equal (sexp-up "(a \"bcd\")" 5) 0)
  (is-equal (sexp-up (sx-text "(a ; (" " b)") 8) 0)
  (is-equal (sexp-up "[a (b] c" 8) 0)
  (is-equal (sexp-up "(a (b) c)" 7) 0)
  (is-equal (sexp-up "(a" 1) 0)
  (is-equal (sexp-up "" 0) nil))

(deftest sexp-down-list-edge-cases
  (is-equal (sexp-down "(a b) (c)" 5) 7)
  (is-equal (sexp-down "(a)" -3) 1)
  (is-equal (sexp-down "a (b)" 0) 3)
  (is-equal (sexp-down "'(a)" 0) 2)
  (is-equal (sexp-down "(a)" 100) nil)
  (is-equal (sexp-down (sx-text "; (" "(a)") 0) 5)
  (is-equal (sexp-down "\"(\" (a)" 0) 5)
  (is-equal (sexp-down "(ab (c))" 2) 5)
  (is-equal (sexp-down "a b" 0) nil)
  (is-equal (sexp-down "" 0) nil)
  (is-equal (sexp-down "[a]" 0) 1)
  (is-equal (sexp-down "#\\( (a)" 0) 5)
  (is-equal (sexp-down "(a)" 3) nil))

(deftest sexp-defun-start-edge-cases
  (is-equal (sexp-defun-start "" 0) nil)
  (is-equal (sexp-defun-start (sx-text "foo" "(a)" "") 0) nil)
  (is-equal (sexp-defun-start (sx-text "foo" "(a)" "") 4) 4)
  (is-equal (sexp-defun-start (sx-text "foo" "(a)" "") 3) nil)
  (is-equal (sexp-defun-start " (a)" 4) nil)
  (is-equal (sexp-defun-start "(a)" -1) 0)
  (is-equal (sexp-defun-start (sx-text "(a)" "(b)") 100) 4)
  (is-equal (sexp-defun-start "[a]" 2) 0)
  (is-equal (sexp-defun-start (sx-text "(a \"x" "(b\" c)") 12) 0)
  (is-equal (sexp-defun-start (sx-text "(a" ";(" " b)") 9) 0)
  (is-equal (sexp-defun-start (sx-text "(a" "#|" "(" "|# b)") 13) 0)
  (is-equal (sexp-defun-start (sx-text "(a)" "" "(b)") 4) 0)
  (is-equal (sexp-defun-start (sx-text "(a)" "" "(b)") 5) 5)
  (is-equal (sexp-defun-start (sx-text "(a)" "" "(b)") 6) 5))

(deftest sexp-defun-end-edge-cases
  (is-equal (sexp-defun-end (sx-text "(a)" "(b") 5) nil)
  (is-equal (sexp-defun-end "foo bar" 3) nil)
  (is-equal (sexp-defun-end (sx-text "(a)" "(b)" "") 1) 3)
  (is-equal (sexp-defun-end (sx-text "(a)" "(b)" "") 3) 3)
  (is-equal (sexp-defun-end (sx-text "(a)" "(b)" "") 4) 7)
  (is-equal (sexp-defun-end (sx-text "(a (b)" "   c)" "d") 14) 12)
  (is-equal (sexp-defun-end "" 0) nil))

(deftest sexp-match-paren-edge-cases
  (is-equal (sexp-match-paren "(a)" -1) nil)
  (is-equal (sexp-match-paren "(a)" 3) nil)
  (is-equal (sexp-match-paren "(a)" 100) nil)
  (is-equal (sexp-match-paren "" 0) nil)
  (is-equal (sexp-match-paren "[a]" 0) 2)
  (is-equal (sexp-match-paren "[a]" 2) 0)
  ;; Parens and brackets are one kind, as for the C scanner.
  (is-equal (sexp-match-paren "(a]" 0) 2)
  (is-equal (sexp-match-paren "(a]" 2) 0)
  ;; The paren of a character literal is code by context, but no token.
  (is-equal (sexp-match-paren "(a #\\( b)" 5) nil)
  (is-equal (sexp-match-paren "(a #\\( b)" 0) 8)
  (is-equal (sexp-match-paren "(a #\\) b)" 5) nil)
  (is-equal (sexp-match-paren "(a #\\) b)" 8) 0)
  (is-equal (sexp-match-paren "#|(|# (a)" 2) nil)
  (is-equal (sexp-match-paren "#|(|# (a)" 6) 8)
  (is-equal (sexp-match-paren "(a \"(\" b)" 4) nil)
  (is-equal (sexp-match-paren (sx-text "(a ; )" ")") 5) nil)
  (is-equal (sexp-match-paren (sx-text "(a ; )" ")") 7) 0)
  (is-equal (sexp-match-paren "(a))" 3) nil)
  (is-equal (sexp-match-paren "(a))" 2) 0)
  (is-equal (sexp-match-paren ")(" 0) nil)
  (is-equal (sexp-match-paren ")(" 1) nil)
  (is-equal (sexp-match-paren "((a)" 0) nil)
  (is-equal (sexp-match-paren "((a)" 1) 3)
  (is-equal (sexp-match-paren "((a)" 3) 1)
  (is-equal (sexp-match-paren "'(a)" 1) 3)
  (is-equal (sexp-match-paren "'(a)" 0) nil))

(deftest sexp-last-sexp-edge-cases
  (is-equal (sx-last "'(a b)" 6) '(0 6))
  (is-equal (sx-last "(a b" 4) '(3 4))
  (is-equal (sx-last "(foo bar" 8) '(5 8))
  (is-equal (sx-last "#'car" 5) '(0 5))
  (is-equal (sx-last "(a) ; c" 7) '(0 3))
  (is-equal (sx-last ",@(x)" 5) '(0 5))
  (is-equal (sx-last "foobar" 3) '(0 6))
  (is-equal (sx-last "(a (b" 5) '(4 5))
  (is-equal (sx-last "(a \"b c\")" 8) '(3 8))
  (is-equal (sx-last "(a \"b c\")" 5) '(3 8))
  (is-equal (sx-last "(a)" 100) '(0 3))
  (is-equal (sx-last "(a)" -1) nil)
  (is-equal (sx-last "" 0) nil)
  (is-equal (sx-last "(((" 3) nil)
  (is-equal (sx-last "' " 2) nil)
  (is-equal (sx-last "`(a ,@(b c))" 11) '(4 11))
  (is-equal (sx-last "`(a ,@(b c))" 12) '(0 12))
  (is-equal (sx-last "[a b] c" 5) '(0 5)))

(deftest sexp-current-package-edge-cases
  (is-equal (sexp-current-package "(in-package foo)" 16) "foo")
  (is-equal (sexp-current-package "(cl:in-package :foo)" 20) nil)
  (is-equal (sexp-current-package "(in-package :foo" 16) "foo")
  (is-equal (sexp-current-package "(in-package :foo)" 100) "foo")
  (is-equal (sexp-current-package "(in-package :foo)" -1) nil)
  ;; Point must be past the open paren, no more: the form counts as read.
  (is-equal (sexp-current-package "(in-package :foo)" 1) "foo")
  (is-equal (sexp-current-package (sx-text "(foo)" "(in-package :b)") 6) nil)
  (is-equal (sexp-current-package (sx-text "(foo)" "(in-package :b)") 7) "b")
  (is-equal (sexp-current-package "(in-package)" 12) nil)
  (is-equal (sexp-current-package "(in-package \"\")" 15) nil)
  (is-equal (sexp-current-package
             (sx-text "(in-package :a)"
                      "(in-package \"\")"
                      "")
             32)
            "a")
  (is-equal (sexp-current-package "(in-package '(a))" 17) nil)
  (is-equal (sexp-current-package (sx-text "(in-package ; c" " :foo)") 22)
            "foo")
  (is-equal (sexp-current-package "(progn (in-package :x))" 23) nil)
  (is-equal (sexp-current-package
             (sx-text ";; (in-package :no)"
                      "(in-package :yes)")
             37)
            "yes")
  (is-equal (sexp-current-package "\"(in-package :no)\"" 18) nil)
  (is-equal (sexp-current-package "#| (in-package :no) |#" 22) nil)
  (is-equal (sexp-current-package "(in-package |Foo|)" 18) "|Foo|")
  (is-equal (sexp-current-package "(in-package :a :b)" 18) "a")
  (is-equal (sexp-current-package "(In-Package #:Mixed.Case)" 25) "Mixed.Case")
  (is-equal (sexp-current-package "[in-package :br]" 16) "br")
  (is-equal (sexp-current-package "(in-package 'foo)" 17) "foo")
  (is-equal (sexp-current-package "(in-package :foo) (in-packag :b)" 32) "foo")
  ;; An unterminated string loses its last character to the closing quote
  ;; it does not have.
  (is-equal (sexp-current-package "(in-package \"FOO" 16) "FO")
  ;; A string in head position does not take the head slot.
  (is-equal (sexp-current-package "(\"s\" in-package :foo)" 21) "foo")
  (is-equal (sexp-current-package "(in-package (f) :foo)" 21) nil)
  (is-equal (sexp-current-package "" 0) nil)
  (is-equal (sexp-current-package "in-package :foo" 15) nil)
  (is-equal (sexp-current-package "(in-package :)" 14) nil)
  (is-equal (sexp-current-package "(in-package #:)" 15) nil))

(deftest sexp-operator-in-quoted-and-unquoted-lists
  (is-equal (op-at "'(a b)" 5) nil)
  (is-equal (op-at "`(a b)" 5) nil)
  (is-equal (op-at "#(a b)" 5) nil)
  (is-equal (op-at "#'(lambda (x) x)" 15) "lambda")
  (is-equal (op-at ",@(foo x)" 8) "foo")
  (is-equal (op-at "`(a ,@(foo x))" 12) "foo")
  (is-equal (op-at "`(a ,(foo '(b c)))" 15) "foo")
  (is-equal (op-at "'(a ,(b c))" 9) "b")
  ;; Only a prefix makes data; QUOTE spelled out does not ...
  (is-equal (op-at "(quote (a b))" 11) "a")
  ;; ... and the prefix must touch its paren.
  (is-equal (op-at "' (a b)" 6) "a")
  (is-equal (op-at "'#(a b)" 6) nil)
  ;; The FIRST prefix character decides.
  (is-equal (op-at ",'(a b)" 6) "a")
  (is-equal (op-at "(a '(b c) (d e))" 14) "d")
  (is-equal (op-at "'(a (b) (c d))" 12) nil)
  (is-equal (op-at "(foo '(a) x)" 11) "foo")
  (is-equal (op-at "`(a ,(b) c)" 10) nil)
  (is-equal (op-at "(f #'(lambda (x) (g x)))" 21) "g")
  (is-equal (op-at "(f '(a) (g '(b) x))" 17) "g"))

(deftest sexp-operator-heads
  (is-equal (op-at "(+ 1 2)" 5) "+")
  (is-equal (op-at "(-5 a)" 5) nil)
  (is-equal (op-at "(- 5 a)" 6) "-")
  (is-equal (op-at "(.5 a)" 5) nil)
  (is-equal (op-at "(... a)" 6) "...")
  ;; Whatever starts with a digit counts as a number.
  (is-equal (op-at "(1+ x)" 5) nil)
  (is-equal (op-at "(#\\a b)" 6) nil)
  ;; A string takes the head slot.
  (is-equal (op-at "(\"s\" foo bar)" 12) nil)
  (is-equal (op-at "('foo bar)" 9) "foo")
  (is-equal (op-at "[foo bar]" 8) "foo")
  (is-equal (op-at "(|my op| (x" 11) "x")
  (is-equal (op-at "(defun foo (" 12) "defun")
  (is-equal (op-at "(a (b c) d)" 10) "a")
  (is-equal (op-at "(foo))) (bar x" 14) "bar")
  (is-equal (op-at (sx-text "(foo ; (bar" " x)") 14) "foo")
  (is-equal (op-at "(foo #| (bar |# x)" 17) "foo")
  (is-equal (op-at "(cl:car x)" 9) "cl:car")
  (is-equal (op-at "(+a b)" 5) "+a")
  (is-equal (op-at "(- a)" 4) "-")
  (is-equal (op-at "(:key (f x))" 10) "f"))

(deftest sexp-operator-positions
  (is-equal (op-at "(foo x)" 0) nil)
  (is-equal (op-at "(foo x)" 1) nil)
  (is-equal (op-at "(foo x)" -1) nil)
  (is-equal (op-at "(foo x)" 100) nil)
  (is-equal (op-at "(foo x)" 7) nil)
  (is-equal (op-at "(foo x)" 4) "foo")
  ;; At the end of the head it is complete; inside it, still being typed.
  (is-equal (op-at "(foo (ba" 8) "ba")
  (is-equal (op-at "(foo (ba" 7) nil)
  (is-equal (op-at "(foo (" 6) "foo")
  (is-equal (op-at "(foo \"ab" 7) "foo")
  (is-equal (op-at "(foo x) " 8) nil)
  (is-equal (op-at "(f (g) " 7) "f")
  (is-equal (op-at "(foo bar)" 7) "foo"))

(deftest sexp-symbol-at-point-edge-cases
  (is-equal (sym-at "foo" -1) nil)
  (is-equal (sym-at "foo" 4) nil)
  (is-equal (sym-at "foo" 3) "foo")
  (is-equal (sym-at "(a)" 1) "a")
  (is-equal (sym-at "(a)" 2) "a")
  (is-equal (sym-at "a,b" 1) "a")
  (is-equal (sym-at "a,b" 2) "b")
  ;; `#' and `|' are symbol characters by the rule of terminating characters.
  (is-equal (sym-at "#'foo" 0) "#")
  (is-equal (sym-at "#'foo" 1) "#")
  (is-equal (sym-at "|a b|" 1) "|a")
  (is-equal (sym-at "|a b|" 3) "b|")
  (is-equal (sym-at "a`b" 1) "a")
  (is-equal (sym-at "a;b" 2) "b")
  (is-equal (sym-at "[ab]" 1) "ab")
  (is-equal (sym-at "[ab]" 4) nil)
  (is-equal (sym-at " " 0) nil)
  (is-equal (sym-at " " 1) nil)
  (is-equal (sym-at (sx-text "a" "b") 1) "a")
  (is-equal (sym-at (sx-text "a" "b") 2) "b")
  (is-equal (sym-at "pkg::sym" 4) "pkg::sym")
  (is-equal (sym-at "#\\a" 1) "#\\a"))

(deftest sexp-input-complete-edge-cases
  (is-equal (sexp-input-complete-p "[a") nil)
  (is-equal (sexp-input-complete-p "(a]") t)
  (is-equal (sexp-input-complete-p "[a]") t)
  (is-equal (sexp-input-complete-p "#|a #| b |#") nil)
  (is-equal (sexp-input-complete-p "#| a #| b |# c |#") t)
  (is-equal (sexp-input-complete-p "#|") nil)
  (is-equal (sexp-input-complete-p "#|a|") nil)
  (is-equal (sexp-input-complete-p "#|a|#") t)
  (is-equal (sexp-input-complete-p "#") nil)
  (is-equal (sexp-input-complete-p ",@") nil)
  (is-equal (sexp-input-complete-p ",") nil)
  (is-equal (sexp-input-complete-p "`") nil)
  (is-equal (sexp-input-complete-p "; comment") t)
  ;; A comment after a dangling quote does not complete it.
  (is-equal (sexp-input-complete-p "'; c") nil)
  (is-equal (sexp-input-complete-p (sx-text "' ; c" "")) nil)
  (is-equal (sexp-input-complete-p "' a") t)
  (is-equal (sexp-input-complete-p "\"a\\") nil)
  (is-equal (sexp-input-complete-p "\"a\\\\\"") t)
  (is-equal (sexp-input-complete-p "   ") t)
  (is-equal (sexp-input-complete-p (sx-text "" "")) t)
  (is-equal (sexp-input-complete-p ")") t)
  ;; A surplus `)' does not pay for a later `('.
  (is-equal (sexp-input-complete-p ")(") nil)
  (is-equal (sexp-input-complete-p "#\\(") t)
  (is-equal (sexp-input-complete-p "#\\") t)
  (is-equal (sexp-input-complete-p "(|a") nil)
  ;; An open |symbol is an atom for the walker, so nothing is pending.
  (is-equal (sexp-input-complete-p "|a") t)
  (is-equal (sexp-input-complete-p "\"a\" \"b") nil)
  (is-equal (sexp-input-complete-p "(a \"b\")") t)
  (is-equal (sexp-input-complete-p "(a \"b)") nil)
  (is-equal (sexp-input-complete-p (sx-text "(a ; )" "")) nil)
  (is-equal (sexp-input-complete-p (sx-text "(a ; )" ")")) t)
  (is-equal (sexp-input-complete-p "(a #| ) |#") nil)
  (is-equal (sexp-input-complete-p "(a #| ) |# )") t)
  (is-equal (sexp-input-complete-p "(a) #| x") nil)
  (is-equal (sexp-input-complete-p "#'") nil)
  (is-equal (sexp-input-complete-p "(a '") nil)
  (is-equal (sexp-input-complete-p "(a ')") t)
  (is-equal (sexp-input-complete-p "1 #|x|#") t)
  (is-equal (sexp-input-complete-p "\"\"") t)
  (is-equal (sexp-input-complete-p "\"") nil)
  (is-equal (sexp-input-complete-p "(a\\) b)") t)
  (is-equal (sexp-input-complete-p "(a\\)") nil))

(deftest sexp-context-edge-cases
  (is-equal (sexp-context "" 0) :code)
  (is-equal (sexp-context "\"ab\" c" 0) :code)
  (is-equal (sexp-context "\"ab\" c" 1) :string)
  ;; On the closing quote is still inside; after it is not.
  (is-equal (sexp-context "\"ab\" c" 3) :string)
  (is-equal (sexp-context "\"ab\" c" 4) :code)
  (is-equal (sexp-context "\"ab\" c" 6) :code)
  (is-equal (sexp-context "\"ab\" c" 7) :code)
  (is-equal (sexp-context "\"ab\" c" -1) :code)
  (is-equal (sexp-context "x ; c" 2) :code)
  (is-equal (sexp-context "x ; c" 3) :comment)
  ;; At the end of the buffer nothing contains point.
  (is-equal (sexp-context "x ; c" 5) :code)
  (is-equal (sexp-context (sx-text "x ; c" "y") 5) :code)
  (is-equal (sexp-context (sx-text "x ; c" "y") 6) :code)
  (is-equal (sexp-context "#| a |# b" 1) :comment)
  (is-equal (sexp-context "#| a |# b" 6) :comment)
  (is-equal (sexp-context "#| a |# b" 7) :code)
  (is-equal (sexp-context "#| a #| b |# c |# d" 14) :comment)
  (is-equal (sexp-context "#\\; x" 2) :code)
  (is-equal (sexp-context "#\\; x" 4) :code)
  (is-equal (sexp-context "#\\\" x" 3) :code)
  (is-equal (sexp-context "\"a\\\"b\" c" 5) :string)
  (is-equal (sexp-context "\"a\\\"b\" c" 7) :code)
  (is-equal (sexp-context "\"open" 5) :code)
  (is-equal (sexp-context "#| open" 7) :code)
  (is-equal (sexp-context "|a;b| c" 3) :code))
