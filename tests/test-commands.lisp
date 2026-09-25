;;;; test-commands.lisp -- the command loop and the editing commands, run
;;;; against tests/fake-frontend.lisp.  A `|' in a text is the cursor.

(in-package :clamacs)

(defun after-keys (text keys)
  "The state of a document holding TEXT after typing KEYS."
  (let ((doc (make-fake text)))
    (type-keys doc keys)
    (fake-state doc)))

;;; --- the command loop -----------------------------------------------

(deftest loop-unbound-keys-go-to-the-widget
  (let ((doc (make-fake "|")))
    (is-equal (type-keys doc "a b <up> C-z") '("a" "b" "<up>" "C-z"))
    (is-equal (fake-state doc) "ab|")
    (is-equal (doc-last-command doc) nil)))

(deftest loop-prefix-echoes-and-undefined-beeps
  (let ((doc (make-fake "|")))
    (is-equal (type-keys doc "C-x") '())
    (is-equal (fake-last-message doc) "C-x -")
    (type-keys doc "C-q")
    (is-equal (fake-last-message doc) "C-x C-q is undefined")
    (is-equal (fake-beeps doc) 1)
    ;; The `q' did not reach the text.
    (is-equal (fake-state doc) "|")
    (type-keys doc "C-u")
    (is-equal (fake-last-message doc) "C-u 4 -")
    (type-keys doc "C-g")
    (is-equal (fake-last-message doc) "Quit")))

(deftest loop-declared-command-reports-not-implemented
  (let ((doc (make-fake "|")))
    (register-command 'test-declared-only)
    (is (not (run-command doc 'test-declared-only)))
    (is-equal (fake-last-message doc) "test-declared-only is not implemented")
    (is-equal (fake-beeps doc) 1)
    (is-equal (doc-last-command doc) nil)
    (is (run-command doc 'forward-char))
    (is-equal (doc-last-command doc) 'forward-char)))

(deftest loop-every-bound-editing-command-is-implemented
  ;; What this file's module promises; the prompts, files and the wire come
  ;; with their own modules.
  (dolist (command '(forward-char backward-char next-line previous-line
                     beginning-of-line end-of-line forward-word
                     backward-word beginning-of-buffer end-of-buffer
                     scroll-up scroll-down recenter delete-char
                     backward-delete-char kill-word backward-kill-word
                     kill-line kill-region kill-ring-save yank yank-pop
                     set-mark-command mark-whole-buffer
                     exchange-point-and-mark undo redo keyboard-quit
                     forward-sexp backward-sexp backward-up-list down-list
                     beginning-of-defun end-of-defun kill-sexp
                     insert-parentheses indent-for-tab-command
                     newline-and-indent indent-region))
    (is (command-function command))))

;;; --- motion -----------------------------------------------------------

(deftest motion-characters-and-the-argument
  (is-equal (after-keys "|hello" "C-f C-f") "he|llo")
  (is-equal (after-keys "hel|lo" "C-b") "he|llo")
  (is-equal (after-keys "|hello" "C-u C-f") "hell|o")
  (is-equal (after-keys "|hello" "C-u 2 C-f") "he|llo")
  ;; A negative argument reverses; the end of the text stops a run.
  (is-equal (after-keys "hel|lo" "M-- C-f") "he|llo")
  (is-equal (after-keys "hel|lo" "C-u - 2 C-b") "hello|")
  (is-equal (after-keys "hel|lo" "C-u 9 C-f") "hello|"))

(deftest motion-lines-and-buffer
  (let ((text (lines "first" "se|cond" "third")))
    (is-equal (after-keys text "C-n") (lines "first" "second" "th|ird"))
    (is-equal (after-keys text "C-p") (lines "fi|rst" "second" "third"))
    (is-equal (after-keys text "C-a") (lines "first" "|second" "third"))
    (is-equal (after-keys text "C-e") (lines "first" "second|" "third"))
    (is-equal (after-keys text "M-<") (lines "|first" "second" "third"))
    (is-equal (after-keys text "M->") (lines "first" "second" "third|"))
    (is-equal (after-keys text "M-- C-n") (lines "fi|rst" "second" "third"))))

(deftest motion-words
  (is-equal (after-keys "|foo bar-baz" "M-f") "foo| bar-baz")
  (is-equal (after-keys "|foo bar-baz" "C-u 2 M-f") "foo bar|-baz")
  (is-equal (after-keys "foo bar|" "M-b") "foo |bar"))

(deftest scroll-up-and-down-move-by-a-page
  (let ((doc (make-fake
              (apply #'lines
                     (loop for i below 25 collect (format nil "line~D" i))))))
    (is-equal (fake-page-lines doc) 10)
    (type-keys doc "C-v")
    (is-equal (doc-index-line doc (doc-point doc)) 10)
    (type-keys doc "C-v")
    (is-equal (doc-index-line doc (doc-point doc)) 20)
    (type-keys doc "M-v")
    (is-equal (doc-index-line doc (doc-point doc)) 10)
    (type-keys doc "M-v")
    (is-equal (doc-index-line doc (doc-point doc)) 0)
    ;; Fewer lines left than a page: C-v goes as far as it can, and M-v at
    ;; the top does not move (and does not error).
    (type-keys doc "M-v")
    (is-equal (doc-index-line doc (doc-point doc)) 0)
    (doc-set-point doc (doc-line-index doc 20))
    (type-keys doc "C-v")
    (is-equal (doc-index-line doc (doc-point doc)) 24)))

(deftest recenter-recolours-the-buffer
  (let ((doc (make-fake (lines "(defun f () 42)"))))
    (type-keys doc "C-l")
    (is-equal (fake-line-colours doc 0) '((1 6 :defining) (12 14 :number)))
    (is-equal (fake-quiet-calls doc) 1)))

;;; --- deleting, undo ---------------------------------------------------

(deftest delete-and-undo
  (is-equal (after-keys "a|bcd" "C-d") "a|cd")
  (is-equal (after-keys "a|bcd" "C-u 2 C-d") "a|d")
  (is-equal (after-keys "a|bcd" "C-d C-/") "a|bcd")
  (is-equal (after-keys "a|bcd" "C-d C-x u") "a|bcd")
  (is-equal (after-keys "a|bcd" "C-d C-_ C-x r") "a|cd"))

(deftest backward-delete-char-removes-before-point
  ;; Not bound to a key by default (BS self-inserts/backspaces at the
  ;; widget level, see TYPE-KEYS), so it is run directly here.
  (let ((doc (make-fake "ab|cd")))
    (is (run-command doc 'backward-delete-char))
    (is-equal (fake-state doc) "a|cd")
    (is (run-command doc 'backward-delete-char 2))
    (is-equal (fake-state doc) "|cd")
    ;; At the start of the buffer there is nothing to delete.
    (is (run-command doc 'backward-delete-char))
    (is-equal (fake-state doc) "|cd")))

;;; --- killing and yanking ----------------------------------------------

(deftest kill-line-to-the-end-then-the-newline
  (let ((doc (make-fake (lines "one |two" "three"))))
    (type-keys doc "C-k")
    (is-equal (fake-state doc) (lines "one |" "three"))
    (is-equal (kill-current (doc-kill-ring doc)) "two")
    ;; At the end of a line, C-k joins it with the next one -- and
    ;; consecutive kills are ONE entry.
    (type-keys doc "C-k")
    (is-equal (fake-state doc) "one |three")
    (is-equal (kill-current (doc-kill-ring doc)) (lines "two" ""))
    (is-equal (kill-count (doc-kill-ring doc)) 1)
    (type-keys doc "C-k")
    (is-equal (fake-state doc) "one |")
    (is-equal (kill-current (doc-kill-ring doc)) (lines "two" "three"))
    ;; Nothing left: no kill, no entry.
    (type-keys doc "C-k")
    (is-equal (kill-count (doc-kill-ring doc)) 1)
    ;; And C-y brings all of it back.
    (type-keys doc "C-y")
    (is-equal (fake-state doc) (lines "one two" "three|"))))

(deftest kill-line-with-an-argument-takes-whole-lines
  (let ((doc (make-fake (lines "|a" "b" "c" "d"))))
    (type-keys doc "C-u 3 C-k")
    (is-equal (fake-state doc) (lines "|" "d"))
    (is-equal (kill-current (doc-kill-ring doc)) (lines "a" "b" "c"))))

(deftest a-command-between-kills-starts-a-new-entry
  (let ((doc (make-fake (lines "|ab" "cd"))))
    (type-keys doc "C-k C-f C-k")
    (is-equal (kill-count (doc-kill-ring doc)) 2)
    (is-equal (kill-current (doc-kill-ring doc)) "cd"))
  ;; ... and so does typing.
  (let ((doc (make-fake "|ab cd")))
    (type-keys doc "M-d x M-d")
    (is-equal (kill-count (doc-kill-ring doc)) 2)))

(deftest kill-words-join-in-reading-order
  (let ((doc (make-fake "|one two three")))
    (type-keys doc "M-d M-d")
    (is-equal (fake-state doc) "| three")
    (is-equal (kill-current (doc-kill-ring doc)) "one two"))
  (let ((doc (make-fake "one two three|")))
    (type-keys doc "M-DEL M-BS")
    (is-equal (fake-state doc) "one |")
    (is-equal (kill-current (doc-kill-ring doc)) "two three")
    (is-equal (kill-count (doc-kill-ring doc)) 1))
  (is-equal (after-keys "|one two three" "C-u 2 M-d") "| three"))

(deftest region-kill-and-copy
  (let ((doc (make-fake "ab|cdef")))
    (type-keys doc "C-SPC")
    (is-equal (fake-last-message doc) "Mark set")
    (type-keys doc "C-f C-f C-w")
    (is-equal (fake-state doc) "ab|ef")
    (is-equal (kill-current (doc-kill-ring doc)) "cd")
    ;; Other applications see the kill.
    (is-equal (fake-clipboard doc) "cd")
    (is-equal (doc-mark doc) nil))
  ;; The mark may be after point; M-w leaves the text alone.
  (let ((doc (make-fake "abcd|ef")))
    (type-keys doc "C-SPC C-b C-b M-w")
    (is-equal (fake-state doc) "ab|cdef")
    (is-equal (kill-current (doc-kill-ring doc)) "cd")
    (is-equal (fake-clipboard doc) "cd")))

(deftest region-commands-need-a-mark
  (dolist (keys '("C-w" "M-w" "C-x C-x" "C-M-\\"))
    (let ((doc (make-fake "ab|cd")))
      (type-keys doc keys)
      (is-equal (list keys (fake-last-message doc))
                (list keys "No mark set in this buffer"))
      (is-equal (fake-beeps doc) 1)
      (is-equal (fake-state doc) "ab|cd")))
  ;; An empty region kills nothing and pushes nothing.
  (let ((doc (make-fake "ab|cd")))
    (type-keys doc "C-SPC C-w")
    (is-equal (kill-count (doc-kill-ring doc)) 0)
    (is-equal (doc-mark doc) nil)))

(deftest exchange-point-and-mark-swaps
  (let ((doc (make-fake "a|bcd")))
    (type-keys doc "C-SPC C-e C-x C-x")
    (is-equal (fake-state doc) "a|bcd")
    (is-equal (doc-mark doc) 4)))

(deftest yank-and-yank-pop
  (let ((doc (make-fake "|")))
    (type-keys doc "C-y")
    (is-equal (fake-last-message doc) "Kill ring is empty")
    (is-equal (fake-beeps doc) 1)
    (kill-push (doc-kill-ring doc) "first")
    (kill-push (doc-kill-ring doc) "second")
    (type-keys doc "C-y")
    (is-equal (fake-state doc) "second|")
    ;; M-y replaces what the yank inserted, and wraps.
    (type-keys doc "M-y")
    (is-equal (fake-state doc) "first|")
    (type-keys doc "M-y")
    (is-equal (fake-state doc) "second|")
    ;; A fresh C-y starts from the newest kill again.
    (type-keys doc "M-y C-f C-y")
    (is-equal (fake-state doc) "firstsecond|")))

(deftest yank-pop-only-after-a-yank
  (let ((doc (make-fake "x|")))
    (kill-push (doc-kill-ring doc) "k")
    (type-keys doc "M-y")
    (is-equal (fake-last-message doc) "Previous command was not a yank")
    (is-equal (fake-state doc) "x|")
    ;; Typing between the yank and M-y ends the yank too.
    (type-keys doc "C-y a M-y")
    (is-equal (fake-state doc) "xka|")))

(deftest the-kill-ring-is-the-editors
  ;; Kill in one window, yank in another.
  (let* ((editor (make-editor))
         (one (make-fake "|text" :editor editor))
         (two (make-fake "|" :editor editor)))
    (type-keys one "C-k")
    (type-keys two "C-y")
    (is-equal (fake-state two) "text|")
    (is-equal (length (editor-documents editor)) 2)))

(deftest keyboard-quit-drops-mark-and-selection
  (let ((doc (make-fake "ab|")))
    (type-keys doc "C-SPC C-x h")
    (is-equal (fake-selection doc) '(0 . 2))
    (type-keys doc "C-g")
    (is-equal (doc-mark doc) nil)
    (is-equal (fake-selection doc) nil)
    (is-equal (fake-last-message doc) "Quit")))

;;; --- Lisp structure -----------------------------------------------------

(deftest sexp-motion-commands
  (is-equal (after-keys "|(a (b c)) d" "C-M-f") "(a (b c))| d")
  (is-equal (after-keys "|(a (b c)) d" "C-u 2 C-M-f") "(a (b c)) d|")
  (is-equal (after-keys "(a (b c)) d|" "C-M-b") "(a (b c)) |d")
  (is-equal (after-keys "(a (b |c)) d" "C-M-u") "(a |(b c)) d")
  (is-equal (after-keys "(a (b |c)) d" "C-u 2 C-M-u") "|(a (b c)) d")
  (is-equal (after-keys "|(a (b c)) d" "C-M-d") "(|a (b c)) d")
  (let ((text (lines "(defun a ()" "  1)" "" "(defun b ()" "  |2)")))
    (is-equal (after-keys text "C-M-a")
              (lines "(defun a ()" "  1)" "" "|(defun b ()" "  2)"))
    (is-equal (after-keys text "C-M-e")
              (lines "(defun a ()" "  1)" "" "(defun b ()" "  2)|"))))

(deftest sexp-motion-goes-as-far-as-it-can
  ;; Three asked, two there.
  (is-equal (after-keys "(|a b)" "C-u 3 C-M-f") "(a b|)")
  ;; None there: a complaint, and the cursor stays.
  (let ((doc (make-fake "(a b|)")))
    (type-keys doc "C-M-f")
    (is-equal (fake-state doc) "(a b|)")
    (is-equal (fake-last-message doc) "No further expression")
    (is-equal (fake-beeps doc) 1))
  ;; Already at the defun start is a move of no distance, not a failure.
  (let ((doc (make-fake "|(a)")))
    (type-keys doc "C-M-a")
    (is-equal (fake-beeps doc) 0)))

(deftest kill-sexp-and-insert-parentheses
  (let ((doc (make-fake "(a |(b c) \"s\" d)")))
    (type-keys doc "C-M-k C-M-k")
    (is-equal (fake-state doc) "(a | d)")
    (is-equal (kill-current (doc-kill-ring doc)) "(b c) \"s\""))
  (let ((doc (make-fake "(a|)")))
    (type-keys doc "C-M-k")
    (is-equal (fake-last-message doc) "No expression after point")
    (is-equal (fake-state doc) "(a|)"))
  (is-equal (after-keys "(a |)" "M-( b") "(a (b|))"))

;;; --- indentation --------------------------------------------------------

(deftest newline-and-indent-follows-the-table
  (is-equal (after-keys "(defun foo (x)|" "RET")
            (lines "(defun foo (x)" "  |"))
  (is-equal (after-keys "(defun foo|" "RET") (lines "(defun foo" "    |"))
  (is-equal (after-keys "(list a|" "RET") (lines "(list a" "      |"))
  (is-equal (after-keys "(let ((a 1)|" "RET") (lines "(let ((a 1)" "      |"))
  ;; Top level.
  (is-equal (after-keys "(a)|" "RET") (lines "(a)" "|"))
  ;; Splitting a line takes the text along, its leading blank replaced.
  (is-equal (after-keys "(when x| (y))" "RET") (lines "(when x" "  |(y))")))

(deftest typing-a-defun-comes-out-indented
  (let ((doc (make-fake "|")))
    (type-keys doc "M-( d e f u n SPC f SPC M-( x C-f RET")
    (type-keys doc "M-( i f SPC x RET 1 RET 2")
    (is-equal (fake-state doc)
              ;; The table's `if': two distinguished arguments, then body.
              (lines "(defun f (x)" "  (if x" "      1" "    2|))"))))

(deftest tab-reindents-and-the-cursor-follows-the-text
  ;; In the indentation: to the first non-blank character.
  (is-equal (after-keys (lines "(when x" "|(y))") "TAB")
            (lines "(when x" "  |(y))"))
  (is-equal (after-keys (lines "(when x" "   |     (y))") "TAB")
            (lines "(when x" "  |(y))"))
  ;; In the text: the same place in the text.
  (is-equal (after-keys (lines "(when x" "(y|))") "TAB")
            (lines "(when x" "  (y|))"))
  (is-equal (after-keys (lines "(when x" "        (y)|)") "TAB")
            (lines "(when x" "  (y)|)"))
  ;; Already right: only the cursor moves, and the text is not edited.
  (let ((doc (make-fake (lines "(when x" "|  (y))"))))
    (type-keys doc "TAB")
    (is-equal (fake-state doc) (lines "(when x" "  |(y))"))
    (is-equal (mirror-undo (fake-mirror doc)) '()))
  ;; A tab in the indentation counts as whitespace to replace.
  (is-equal (after-keys (format nil "(when x~%~C(y|))" #\Tab) "TAB")
            (lines "(when x" "  (y|))")))

(deftest tab-inside-a-string-leaves-the-line-alone
  (let ((text (lines "(foo \"first" "  |  second\")")))
    (is-equal (after-keys text "TAB") text)))

(deftest indent-region-works-top-down
  (let ((doc (make-fake (lines "|(defun f (x)" "(if x" "1" "  2))" "(g)"))))
    (type-keys doc "C-SPC C-n C-n C-n C-M-\\")
    ;; Each line is indented against the lines above it AS REINDENTED: the
    ;; `1' hangs off an `(if' that has already moved to column 2.
    (is-equal (fake-text doc)
              (lines "(defun f (x)" "  (if x" "      1" "    2))" "(g)"))
    (is-equal (fake-last-message doc) "Indented 4 line(s)")
    (is-equal (fake-quiet-calls doc) 1)))

;;; --- the context ----------------------------------------------------------

(deftest context-skip-finds-a-clean-start
  (is-equal (context-skip "anything" t) 0)
  (is-equal (context-skip "(defun" nil) 0)
  (is-equal (context-skip (lines "  tail of a string\"" "(defun a ())") nil) 20)
  (is-equal (context-skip (lines "  no defun" "  here (") nil) nil)
  (is-equal (context-skip "" nil) nil)
  (is-equal (context-skip "" t) 0))

(defun numbered-defuns (n)
  (format nil "~{(defun f~D ()~%  ~:*~D)~^~%~}" (loop for i below n collect i)))

(deftest context-window-starts-at-a-defun
  ;; 300 defuns of two lines: the window around the cursor is smaller than
  ;; the buffer, starts at a `(' in column 0 and holds the cursor's line.
  (let* ((doc (make-fake (numbered-defuns 300)))
         (index (search "(defun f250 " (fake-text doc))))
    (doc-set-point doc (+ index 3))
    (multiple-value-bind (text base point) (doc-context doc)
      (is (< (length text) (doc-end doc)))
      (is (> base 0))
      (is-equal (char text 0) #\()
      (is-equal (char (fake-text doc) (1- base)) #\Newline)
      (is-equal (subseq text point (+ point 9)) "fun f250 ")
      (is-equal (+ base point) (doc-point doc)))
    ;; The full context is the buffer.
    (multiple-value-bind (text base point) (doc-context-full doc)
      (is-equal (length text) (doc-end doc))
      (is-equal base 0)
      (is-equal point (doc-point doc)))
    ;; Commands work through the window: RET deep in the file indents.
    (doc-set-point doc (+ index (length "(defun f250 ()")))
    (type-keys doc "RET")
    (is-equal (doc-index-line doc (doc-point doc)) 501)
    (is-equal (nth-value 1 (doc-index-line doc (doc-point doc))) 2)))

(deftest context-falls-back-to-the-whole-buffer
  ;; No `(' in column 0 within the window: offset 0 of the buffer it is.
  (let* ((body (format nil "~{~A~%~}" (loop for i below 500
                                            collect (format nil "  (x ~D)" i))))
         (doc (make-fake (concatenate 'string "(progn" (string #\Newline)
                                      body ")"))))
    (doc-set-point doc (- (doc-end doc) 1))
    (multiple-value-bind (text base) (doc-context doc)
      (is-equal base 0)
      (is-equal (length text) (doc-end doc)))))

;;; --- colouring and the paren highlight -----------------------------------

(deftest colour-all-colours-every-line
  (let ((doc (make-fake (lines "(defun f () ; note" "  \"two" "lines\" :k 42)"))))
    (colour-all doc)
    (is-equal (fake-line-colours doc 0) '((1 6 :defining) (12 18 :comment)))
    ;; The string carries over the line end.
    (is-equal (fake-line-colours doc 1) '((2 6 :string)))
    (is-equal (fake-line-colours doc 2)
              '((0 6 :string) (7 9 :keyword) (10 12 :number)))
    (is-equal (fake-quiet-calls doc) 1)))

(deftest colouring-is-for-lisp-buffers
  (let ((doc (make-fake "(defun f ())|" :lisp-mode nil)))
    (colour-all doc)
    (note-text-changed doc)
    (note-cursor-moved doc)
    (is-equal (fake-colours doc) '())
    ;; ... and without Lisp mode RET and TAB belong to the widget.
    (is-equal (type-keys doc "RET TAB") '("RET" "TAB"))))

(deftest a-shrunk-token-loses-its-colour
  (let ((doc (make-fake ";; all comment|")))
    (colour-all doc)
    (is-equal (fake-line-colours doc 0) '((0 14 :comment)))
    ;; The comment signs go: the line is code again.
    (doc-delete doc 0 3)
    (note-text-changed doc)
    (is-equal (fake-line-colours doc 0) '())))

(deftest typing-recolours-the-line-with-carried-state
  (let ((doc (make-fake (lines "(defun f ()" "  \"doc" "  more|" "  x)"))))
    (type-keys doc "\"")
    ;; Line 2 is the end of the string opened on line 1, and only line 2
    ;; was repainted.
    (is-equal (fake-line-colours doc 2) '((0 7 :string)))
    (is-equal (fake-line-colours doc 1) '())
    (is-equal (fake-line-colours doc 3) '())))

(deftest paren-highlight-follows-the-cursor
  (let ((doc (make-fake (lines "(a" " (b c)|)"))))
    (note-cursor-moved doc)
    (is-equal (doc-paren-shown doc) '(1 . 1))
    (is-equal (fake-line-colours doc 1) '((1 2 :paren-match)))
    ;; One further: the partner is on the line above, the old one is down.
    (type-keys doc "C-f")
    (is-equal (doc-paren-shown doc) '(0 . 0))
    (is-equal (fake-line-colours doc 1) '())
    (is-equal (fake-line-colours doc 0) '((0 1 :paren-match)))
    ;; Away from a paren nothing is lit.
    (type-keys doc "C-b C-b")
    (is-equal (doc-paren-shown doc) nil)
    (is-equal (fake-line-colours doc 0) '())))

(deftest paren-in-a-string-or-unbalanced-is-not-matched
  (let ((doc (make-fake "(a \")|\" b)")))
    (note-cursor-moved doc)
    (is-equal (doc-paren-shown doc) nil))
  (let ((doc (make-fake "a)|")))
    (note-cursor-moved doc)
    (is-equal (doc-paren-shown doc) nil))
  (let ((doc (make-fake "|(a)")))
    (note-cursor-moved doc)
    (is-equal (doc-paren-shown doc) nil)))
