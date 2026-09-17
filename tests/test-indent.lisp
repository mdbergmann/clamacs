;;;; test-indent.lisp -- Lisp indentation.  The cases of tests/test_indent.c
;;;; under their C names, then (the INDENT- tests) what the C file leaves
;;;; uncovered; every expectation of those was taken from the C code, which
;;;; is the specification, not from the Lisp.
;;;;
;;;; Each fixture is written the way the file would actually look, and the
;;;; test asks for the indent of the line containing a marker.  What the
;;;; marker line is currently indented to is irrelevant -- the indenter only
;;;; reads what comes BEFORE the line -- which is exactly the property that
;;;; makes `Tab' idempotent.

(in-package :clamacs)

(defun ind-text (&rest lines)
  "LINES joined by newlines; a last \"\" gives the text a final newline."
  (with-output-to-string (out)
    (loop for (line . more) on lines
          do (write-string line out)
             (when more
               (write-char #\Newline out)))))

(defun indent-of-line-with (src needle)
  (let ((p (or (search needle src)
               (error "fixture does not contain ~S" needle))))
    (indent-for-line src (indent-line-start src p))))

(deftest top-level-is-column-zero
  (is-equal (indent-of-line-with (ind-text "(a b)" "" "(c d)" "") "(c d)") 0)
  (is-equal (indent-for-line "" 0) 0))

(deftest defun-body-indents-two
  (is-equal (indent-of-line-with (ind-text "(defun foo (a b)" "  body)" "")
                                 "body")
            2))

(deftest defun-distinguished-arguments-indent-four
  ;; The lambda list is a distinguished argument of `defun', so a lambda
  ;; list on its own line lines up further in than the body does.
  (is-equal (indent-of-line-with
             (ind-text "(defun foo" "    (a b)" "  body)" "")
             "(a b)")
            4))

(deftest let-and-when
  (is-equal (indent-of-line-with (ind-text "(let ((a 1))" "  body)" "")
                                 "body")
            2)
  (is-equal (indent-of-line-with (ind-text "(when x" "  y)" "") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(unless x" "  y)" "") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(let" "    ((a 1))" "  body)" "")
                                 "((a 1))")
            4))

(deftest if-distinguishes-two-arguments
  (let ((src (ind-text "(if test" "    then" "  else)" "")))
    (is-equal (indent-of-line-with src "then") 4)
    (is-equal (indent-of-line-with src "else") 2)))

(deftest unknown-operator-aligns-under-the-first-argument
  (is-equal (indent-of-line-with (ind-text "(foo bar" "     baz)" "") "baz")
            5)
  (is-equal (indent-of-line-with
             (ind-text "(frobnicate a" "            b)" "")
             "b)")
            12))

(deftest operator-alone-on-its-line-indents-one-past-the-paren
  (is-equal (indent-of-line-with (ind-text "(foo" "  bar)" "") "bar") 1)
  (is-equal (indent-of-line-with (ind-text "(" "  foo)" "") "foo") 1))

(deftest loop-aligns-its-clauses
  ;; `loop' is deliberately absent from the table: the default rule lines
  ;; clauses up under the first one, which no fixed argument count could
  ;; express.
  (is-equal (indent-of-line-with
             (ind-text "(loop for x in xs" "      collect x)" "")
             "collect")
            6))

(deftest data-list-indents-one-past-the-paren
  (is-equal (indent-of-line-with (ind-text "((a 1)" " (b 2))" "") "(b 2)")
            1))

(deftest nested-forms
  (let ((src (ind-text "(defun f ()"
                       "  (let ((x 1))"
                       "    (+ x"
                       "       1)))"
                       "")))
    (is-equal (indent-of-line-with src "(let") 2)
    (is-equal (indent-of-line-with src "(+ x") 4)
    (is-equal (indent-of-line-with src "1)))") 7)))

(deftest comment-lines-indent-like-body
  (is-equal (indent-of-line-with
             (ind-text "(defun f ()" "  ;; note" "  body)" "")
             ";; note")
            2))

(deftest multi-line-string-is-left-alone
  ;; Reindenting inside a string would silently edit its contents.
  (let ((src (ind-text "(defun f ()"
                       "  \"a string"
                       "continues here\")"
                       "")))
    (is-equal (indent-of-line-with src "continues here") nil)))

(deftest unknown-def-form-is-treated-as-a-definer
  ;; A project's own `define-...' macro indents sensibly before phase 2 can
  ;; ask clamiga where its &body starts.
  (is-equal (indent-of-line-with
             (ind-text "(define-widget bar baz" "  body)" "")
             "body")
            2)
  (is-equal (indent-of-line-with
             (ind-text "(define-widget bar" "    baz)" "")
             "baz")
            4))

(deftest package-prefixes-are-ignored
  (is-equal (indent-of-line-with (ind-text "(cl:when x" "  y)" "") "y)") 2)
  (is-equal (indent-of-line-with
             (ind-text "(cl-user::defun f ()" "  body)" "")
             "body")
            2))

(deftest indented-open-paren-shifts-everything
  (let ((src (ind-text "(defun f ()"
                       "  (when x"
                       "    y))"
                       "")))
    (is-equal (indent-of-line-with src "y))") 4)))

(deftest body-args-table
  (is-equal (indent-body-args "defun") 2)
  (is-equal (indent-body-args "DEFUN") 2)
  (is-equal (indent-body-args "let") 1)
  (is-equal (indent-body-args "let*") 1)
  (is-equal (indent-body-args "progn") 0)
  (is-equal (indent-body-args "cl:when") 1)
  (is-equal (indent-body-args "loop") nil)
  (is-equal (indent-body-args "frobnicate") nil)
  (is-equal (indent-body-args "") nil)
  (is-equal (indent-body-args nil) nil))

(deftest column-helpers
  (let ((src (ind-text "abc" "defgh" "")))
    (is-equal (indent-line-start src 0) 0)
    (is-equal (indent-line-start src 2) 0)
    (is-equal (indent-line-start src 4) 4)
    (is-equal (indent-line-start src 7) 4)
    (is-equal (indent-column-of src 6) 2)))

(deftest reindenting-is-idempotent
  ;; Whatever the line is currently indented to, the answer is the same --
  ;; the indenter reads only what comes before the line.
  (let ((a (ind-text "(defun f ()" "body)" ""))
        (b (ind-text "(defun f ()" "              body)" "")))
    (is-equal (indent-of-line-with a "body") 2)
    (is-equal (indent-of-line-with b "body") 2)))

;;; ------------------------------------------------------------------
;;; What the C tests leave uncovered.  Expectations are the C code's.
;;; ------------------------------------------------------------------

(deftest indent-table-is-the-c-table
  ;; Every row of ck_indent_rules, and nothing the C table does not have
  ;; (the `def' guess aside, which is not a row).
  (let ((rows '(("block" . 1) ("case" . 1) ("catch" . 1) ("ccase" . 1)
                ("cond" . 0) ("ctypecase" . 1) ("defclass" . 2)
                ("defconstant" . 1) ("define-compiler-macro" . 2)
                ("define-condition" . 2) ("define-modify-macro" . 1)
                ("define-setf-expander" . 2) ("define-symbol-macro" . 1)
                ("defgeneric" . 2) ("defmacro" . 2) ("defmethod" . 2)
                ("defpackage" . 1) ("defparameter" . 1) ("defsetf" . 2)
                ("defstruct" . 1) ("defsubst" . 2) ("deftype" . 2)
                ("defun" . 2) ("defvar" . 1) ("destructuring-bind" . 2)
                ("do" . 2) ("do*" . 2) ("dolist" . 1) ("dotimes" . 1)
                ("ecase" . 1) ("etypecase" . 1) ("eval-when" . 1)
                ("flet" . 1) ("handler-bind" . 1) ("handler-case" . 1)
                ("if" . 2) ("labels" . 1) ("lambda" . 1) ("let" . 1)
                ("let*" . 1) ("locally" . 0) ("loop-finish" . 0)
                ("macrolet" . 1) ("multiple-value-bind" . 2) ("prog1" . 1)
                ("prog2" . 2) ("progn" . 0) ("restart-bind" . 1)
                ("restart-case" . 1) ("symbol-macrolet" . 1) ("tagbody" . 0)
                ("typecase" . 1) ("unless" . 1) ("unwind-protect" . 1)
                ("when" . 1) ("with-accessors" . 2)
                ("with-input-from-string" . 1) ("with-open-file" . 1)
                ("with-open-stream" . 1) ("with-output-to-string" . 1)
                ("with-slots" . 2) ("with-standard-io-syntax" . 0)))
        (count 0))
    (dolist (row rows)
      (is-equal (list (car row) (indent-body-args (car row)))
                (list (car row) (cdr row)))
      (is-equal (indent-body-args (string-upcase (car row))) (cdr row)))
    (maphash (lambda (key bucket)
               (declare (ignore key))
               (dolist (rule bucket)
                 (incf count)
                 (is (assoc (car rule) rows :test #'string=))))
             *indent-rules*)
    (is-equal count (length rows))
    (is-equal count 62)))

(deftest indent-a-tab-is-one-column
  ;; The indenter emits spaces, so a file it has touched has no tabs in its
  ;; indentation; one it has not touched counts a tab as one column.
  (let ((tab (string #\Tab)))
    (is-equal (indent-of-line-with
               (concatenate 'string "(foo" tab "bar" (ind-text "" " baz)"))
               "baz")
              5)
    (is-equal (indent-of-line-with
               (concatenate 'string tab (ind-text "(when x" " y)"))
               "y)")
              3)
    (is-equal (indent-column-of (concatenate 'string tab "a") 1) 1)))

(deftest indent-carriage-returns-are-whitespace
  (let ((crlf (format nil "~C~C" #\Return #\Newline)))
    (is-equal (indent-of-line-with
               (concatenate 'string "(foo bar" crlf " baz)")
               "baz")
              5)
    (is-equal (indent-of-line-with
               (concatenate 'string "(when x" crlf " y)")
               "y)")
              2)))

(deftest indent-body-args-on-a-range
  ;; The indenter asks about a head where it stands in the buffer.
  (is-equal (indent-body-args "(cl:when x" 1 8) 1)
  (is-equal (indent-body-args "(let* ((a 1))" 1 5) 1)
  (is-equal (indent-body-args "(let* ((a 1))" 1 4) 1)    ; `let'
  (is-equal (indent-body-args "(let* ((a 1))" 1 3) nil)  ; `le'
  (is-equal (indent-body-args "(DEFINE-thing x" 1 13) 2)
  (is-equal (indent-body-args "when" 0 0) nil)
  (is-equal (indent-body-args "when" 4) nil)
  (is-equal (indent-body-args "xwhen" 1) 1)
  ;; A range outside the name is no operator rather than an error.
  (is-equal (indent-body-args "when" 3 2) nil)
  (is-equal (indent-body-args "when" 0 5) nil)
  (is-equal (indent-body-args "when" -1 4) nil)
  ;; The prefix is only looked for inside the range.
  (is-equal (indent-body-args "cl:when" 3) 1)
  (is-equal (indent-body-args "cl:when" 0 3) nil))

(deftest indent-define-indent-extends-the-table
  (let ((src (ind-text "(with-foo (x)" " body)"))
        (deep (ind-text "(with-foo" " (x)" " body)")))
    (unwind-protect
         (progn
           (is-equal (indent-body-args "with-foo") nil)
           (is-equal (indent-of-line-with src "body") 10)
           (is-equal (define-indent "with-foo" 1) "with-foo")
           (is-equal (indent-body-args "with-foo") 1)
           (is-equal (indent-body-args "my:WITH-FOO") 1)
           (is-equal (indent-of-line-with src "body") 2)
           (is-equal (indent-of-line-with deep "(x)") 4)
           (is-equal (indent-of-line-with deep "body") 2)
           ;; Defining it again replaces the rule.
           (is-equal (define-indent "With-Foo" 0) "with-foo")
           (is-equal (indent-body-args "with-foo") 0)
           (is-equal (indent-of-line-with deep "(x)") 2)
           ;; A symbol names the operator too, and a package prefix on the
           ;; name is dropped as the lookup drops it.
           (is-equal (define-indent 'with-foo 3) "with-foo")
           (is-equal (indent-body-args "with-foo") 3)
           (is-equal (define-indent "my-pkg::with-foo" 2) "with-foo")
           (is-equal (indent-body-args "with-foo") 2)
           ;; NIL removes the rule.
           (is-equal (define-indent "with-foo" nil) "with-foo")
           (is-equal (indent-body-args "with-foo") nil)
           (is-equal (indent-of-line-with src "body") 10)
           (is-equal (define-indent "with-foo" nil) "with-foo"))
      (define-indent "with-foo" nil)))
  ;; A rule wins over the `def' guess, and its removal gives the guess back.
  (unwind-protect
       (progn
         (is-equal (indent-body-args "deftest") 2)
         (define-indent "deftest" 1)
         (is-equal (indent-body-args "deftest") 1)
         (is-equal (indent-of-line-with (ind-text "(deftest foo" " (is x))")
                                        "(is x)")
                   2))
    (define-indent "deftest" nil))
  (is-equal (indent-body-args "deftest") 2)
  ;; Rules that share a bucket (length, first and last character) do not
  ;; disturb each other.
  (unwind-protect
       (progn
         (define-indent "waxn" 3)
         (define-indent "wbxn" 4)
         (is-equal (indent-body-args "when") 1)
         (is-equal (indent-body-args "waxn") 3)
         (is-equal (indent-body-args "WBXN") 4)
         (define-indent "waxn" nil)
         (is-equal (indent-body-args "when") 1)
         (is-equal (indent-body-args "waxn") nil)
         (is-equal (indent-body-args "wbxn") 4))
    (define-indent "waxn" nil)
    (define-indent "wbxn" nil))
  ;; No name, no rule; and a count must be a count.
  (is-equal (define-indent "" 1) nil)
  (is-equal (define-indent "cl:" 1) nil)
  (is (handler-case (progn (define-indent "with-foo" -1) nil)
        (error () t)))
  (is (handler-case (progn (define-indent "with-foo" "1") nil)
        (error () t)))
  (is-equal (indent-body-args "with-foo") nil))

(deftest indent-depth-limit
  ;; 128 open lists, as in the C code; one more and the line is left alone.
  (flet ((opens (n)
           (concatenate 'string
                        (make-string n :initial-element #\()
                        (string #\Newline))))
    (is-equal (indent-for-line (opens 128) 129) 128)
    (is-equal (indent-for-line (opens 129) 130) nil)
    ;; The limit is on what is open at once, not on how many were.
    (let ((src (with-output-to-string (out)
                 (write-string "(when x" out)
                 (dotimes (i 300) (write-string " (a (b))" out))
                 (terpri out))))
      (is-equal (indent-for-line src (length src)) 2))))

(deftest indent-buffers-that-are-not-simple-strings
  (let ((buf (make-array 40 :element-type 'character :adjustable t
                            :fill-pointer 0)))
    (loop for c across (ind-text "(when x" "y)" "z")
          do (vector-push c buf))
    (is (not (simple-string-p buf)))
    (is-equal (indent-for-line buf 8) 2)
    (is-equal (indent-line-start buf 9) 8)
    (is-equal (indent-column-of buf 9) 1)
    (is-equal (indent-for-line buf 11) 0)
    ;; Beyond the fill pointer is beyond the buffer.
    (is-equal (indent-for-line buf 13) nil)
    (is-equal (indent-body-args buf 1 5) 1))
  (is-equal (indent-for-line nil 0) 0)
  (is-equal (indent-line-start nil 3) 0))

(deftest indent-line-start-out-of-range
  (is-equal (indent-for-line (ind-text "(a" " b)") -1) nil)
  (is-equal (indent-for-line (ind-text "(a" " b)") 7) nil)
  ;; At the end of a balanced buffer: top level.
  (is-equal (indent-for-line (ind-text "(a" " b)") 6) 0)
  (is-equal (indent-for-line (ind-text "(a" "") 3) 1)
  (is-equal (indent-for-line (ind-text "(a b" "") 5) 3)
  (is-equal (indent-for-line "" 0) 0)
  (is-equal (indent-for-line (ind-text "(a" " b)") 3) 1))

(deftest indent-block-comments
  (is-equal (indent-of-line-with
             (ind-text "(defun f ()"
                       "  #| x"
                       "  y |#"
                       "  body)"
                       "")
             "y |#")
            nil)
  (is-equal (indent-of-line-with
             (ind-text "(defun f ()"
                       "  #| x"
                       "  y |#"
                       "  body)"
                       "")
             "body")
            2)
  (is-equal (indent-of-line-with
             (ind-text "(defun f ()"
                       "  #| ( |#"
                       "  body)"
                       "")
             "body")
            2)
  ;; A comment is no argument to align under.
  (is-equal (indent-of-line-with (ind-text "(foo ; (bar" " baz)" "") "baz") 1)
  (is-equal (indent-of-line-with (ind-text "(foo a ; (bar" " baz)" "") "baz")
            5))

(deftest indent-strings
  (is-equal (indent-of-line-with (ind-text "(f \"a" "b\"" " c)") "b\"") nil)
  (is-equal (indent-of-line-with (ind-text "(f \"a" "b\"" " c)") "c)") 3)
  (is-equal (indent-of-line-with (ind-text "(\"doc\" a" " b)") "b)") 7)
  (is-equal (indent-of-line-with (ind-text "(f \"(\"" " c)") "c)") 3)
  (is-equal (indent-of-line-with (ind-text "(f x \"a ; b\"" " c)") "c)") 3))

(deftest indent-prefixed-forms
  (is-equal (indent-of-line-with (ind-text "'(a b" " c)") "c)") 4)
  (is-equal (indent-of-line-with (ind-text "(list 'a" " 'b)") "'b") 6)
  ;; The column of a prefixed list is the column of its prefix.
  (is-equal (indent-of-line-with
             (ind-text "`(defun ,name ()"
                       " ,@body)")
             ",@body")
            2)
  (is-equal (indent-of-line-with
             (ind-text "  `(defun ,name ()"
                       " ,@body)")
             ",@body")
            4)
  (is-equal (indent-of-line-with (ind-text "#'(lambda (x)" " x)") " x)") 2)
  (is-equal (indent-of-line-with (ind-text "(mapcar #'(lambda (x)" " x)") " x)")
            10)
  (is-equal (indent-of-line-with (ind-text "(foo #(1 2" " 3))") "3))") 9)
  ;; A dangling prefix is no argument yet.
  (is-equal (indent-of-line-with (ind-text "(foo '" " bar)") "bar") 1)
  ;; A quoted head is looked up with its quote, so it is no operator.
  (is-equal (indent-of-line-with (ind-text "('when x" " y)") "y)") 7)
  (is-equal (indent-of-line-with (ind-text "(#'foo x" " y)") "y)") 7))

(deftest indent-lists-in-head-position
  (is-equal (indent-of-line-with (ind-text "(let ((a 1)" " (b 2))") "(b 2)") 6)
  (is-equal (indent-of-line-with (ind-text "(cond ((a)" " b))") "b))") 7)
  (is-equal (indent-of-line-with (ind-text "((lambda (x) x)" " 1)") "1)") 1)
  (is-equal (indent-of-line-with (ind-text "  ((a)" " b)") "b)") 3))

(deftest indent-rules-with-no-distinguished-argument
  (is-equal (indent-of-line-with (ind-text "(cond" " (a b))") "(a b)") 2)
  (is-equal (indent-of-line-with (ind-text "(progn" " a)") "a)") 2)
  (is-equal (indent-of-line-with (ind-text "(progn a" " b)") "b)") 2)
  (is-equal (indent-of-line-with (ind-text "(cond (a b)" " (c d))") "(c d)") 2))

(deftest indent-counts-the-arguments
  (is-equal (indent-of-line-with
             (ind-text "(multiple-value-bind (a b)"
                       " (f)"
                       " body)")
             "(f)")
            4)
  (is-equal (indent-of-line-with
             (ind-text "(multiple-value-bind (a b)"
                       " (f)"
                       " body)")
             "body")
            2)
  (is-equal (indent-of-line-with (ind-text "(if a b" " c)") "c)") 2)
  (is-equal (indent-of-line-with (ind-text "(if" " a)") "a)") 4)
  (is-equal (indent-of-line-with
             (ind-text "(defun f (a)"
                       " \"doc\""
                       " (g))")
             "\"doc\"")
            2)
  (is-equal (indent-of-line-with
             (ind-text "(defun f (a)"
                       " \"doc\""
                       " (g))")
             "(g)")
            2)
  (is-equal (indent-of-line-with (ind-text "(let* ((a 1))" " a)") "a)") 2)
  (is-equal (indent-of-line-with
             (ind-text "(do* ((i 0))"
                       " ((= i 1))"
                       " (f))")
             "((= i 1))")
            4)
  (is-equal (indent-of-line-with
             (ind-text "(do* ((i 0))"
                       " ((= i 1))"
                       " (f))")
             "(f)")
            2))

(deftest indent-unknown-operators
  (is-equal (indent-of-line-with (ind-text "(foo" " bar" " baz)") "baz") 1)
  (is-equal (indent-of-line-with (ind-text "(foo bar" " baz" " qux)") "qux") 5)
  (is-equal (indent-of-line-with (ind-text "   (foo bar" " baz)") "baz") 8)
  (is-equal (indent-of-line-with (ind-text "(foo (bar)" " baz)") "baz") 5)
  (is-equal (indent-of-line-with (ind-text "(foo   bar" " baz)") "baz") 7)
  (is-equal (indent-of-line-with (ind-text "(1 2" " 3)") "3)") 3)
  (is-equal (indent-of-line-with (ind-text "(:a 1" " :b 2)") ":b") 4)
  (is-equal (indent-of-line-with (ind-text "(loop" " for x)") "for") 1))

(deftest indent-case-and-package-prefixes
  (is-equal (indent-of-line-with (ind-text "(DEFUN F ()" " body)") "body") 2)
  (is-equal (indent-of-line-with (ind-text "(Cl:When x" " y)") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(a:b:let ((x 1))" " y)") "y)") 2)
  ;; `:when' has an empty package prefix; `when:' an empty name.
  (is-equal (indent-of-line-with (ind-text "(:when x" " y)") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(when: x" " y)") "y)") 7)
  (is-equal (indent-of-line-with (ind-text "(deffoo x" " y)") "y)") 4)
  ;; The `def' guess needs more than the three letters.
  (is-equal (indent-of-line-with (ind-text "(def x" " y)") "y)") 5)
  (is-equal (indent-of-line-with (ind-text "(my:defthing x" " y)") "y)") 4))

(deftest indent-unbalanced-input
  ;; A surplus close paren at top level is ignored.
  (is-equal (indent-of-line-with (ind-text "a)" "(b" " c)") "c)") 1)
  (is-equal (indent-of-line-with (ind-text ")))" "(when x" " y)") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(a (b" " c") "c") 4)
  (is-equal (indent-of-line-with (ind-text "(a))" " b") "b") 0)
  (is-equal (indent-of-line-with (ind-text "(let ((a 1)))" " b") "b") 0))

(deftest indent-brackets-and-line-endings
  (is-equal (indent-of-line-with (ind-text "[foo bar" " baz]") "baz") 5)
  (is-equal (indent-of-line-with (ind-text "(foo [a" " b])") "b]") 6)
  (is-equal (indent-of-line-with (ind-text "" "" "  (when x" " y)") "y)") 4))

(deftest indent-character-literals
  (is-equal (indent-of-line-with (ind-text "(foo #\\( x" " y)") "y)") 5)
  (is-equal (indent-of-line-with (ind-text "(when #\\)" " y)") "y)") 2)
  (is-equal (indent-of-line-with (ind-text "(foo #\\;" " y)") "y)") 5))

(deftest indent-body-args-edge-cases
  (is-equal (indent-body-args "def") nil)
  (is-equal (indent-body-args "defx") 2)
  (is-equal (indent-body-args "DEFINE-FOO") 2)
  (is-equal (indent-body-args "Define-Condition") 2)
  (is-equal (indent-body-args ":when") 1)
  (is-equal (indent-body-args "when:") nil)
  (is-equal (indent-body-args "cl:") nil)
  (is-equal (indent-body-args ":") nil)
  (is-equal (indent-body-args "a:b:let") 1)
  (is-equal (indent-body-args "do") 2)
  (is-equal (indent-body-args "do*") 2)
  (is-equal (indent-body-args "d") nil)
  (is-equal (indent-body-args "whe") nil)
  (is-equal (indent-body-args "whenx") nil)
  (is-equal (indent-body-args "xwhen") nil)
  (is-equal (indent-body-args "if") 2)
  (is-equal (indent-body-args "iF") 2)
  (is-equal (indent-body-args "loop-finish") 0)
  (is-equal (indent-body-args "with-standard-io-syntax") 0)
  (is-equal (indent-body-args "with-standard-io-syntaxx") nil)
  (is-equal (indent-body-args "defu") 2)
  (is-equal (indent-body-args "cl:defu") 2)
  (is-equal (indent-body-args "x:de") nil)
  (is-equal (indent-body-args "'when") nil)
  (is-equal (indent-body-args "when ") nil)
  (is-equal (indent-body-args "my-defun") nil))

(deftest indent-column-helpers-edge-cases
  (is-equal (indent-line-start (ind-text "abc" "defgh" "") -1) 0)
  (is-equal (indent-line-start (ind-text "abc" "defgh" "") 3) 0)
  (is-equal (indent-line-start (ind-text "abc" "defgh" "") 9) 4)
  (is-equal (indent-line-start (ind-text "abc" "defgh" "") 10) 10)
  (is-equal (indent-line-start (ind-text "abc" "defgh" "") 100) 10)
  (is-equal (indent-line-start "" 0) 0)
  (is-equal (indent-line-start "" 5) 0)
  (is-equal (indent-line-start (ind-text "" "" "") 1) 1)
  (is-equal (indent-line-start (ind-text "" "" "") 2) 2)
  (is-equal (indent-line-start "abc" 3) 0)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 0) 0)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 3) 3)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 4) 0)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 9) 5)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 10) 0)
  ;; The offset is not clamped, only the search for the line start is.
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") 100) 90)
  (is-equal (indent-column-of (ind-text "abc" "defgh" "") -2) -2)
  (is-equal (indent-column-of "" 0) 0))
