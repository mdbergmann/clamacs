;;;; test-iedit.lisp -- editing every occurrence of a symbol at once
;;;; (lisp/iedit.lisp), run against tests/fake-frontend.lisp.  A `|' in a
;;;; text is the cursor.

(in-package :clamacs)

(defparameter *iedit-text*
  (lines "(defun f (foo bar)"
         "  ;; foo in a comment"
         "  (list \"foo\" foo (g bar))"
         "  (+ foo 1))"
         ""
         "(defun g (foo)"
         "  foo)"))

(defun iedit-fake (&optional (text *iedit-text*) (symbol "foo") (nth 0))
  "A document holding TEXT with the cursor at the start of the NTH
occurrence of SYMBOL in it (counted from 0, every occurrence, code or not)."
  (let ((pos 0))
    (dotimes (i (1+ nth))
      (setq pos (search symbol text :start2 (if (= i 0) 0 (1+ pos)))))
    (make-fake text :point pos)))

(defun iedit-starts-of (doc)
  (and (doc-iedit doc) (iedit-starts (doc-iedit doc))))

(defun iedit-marks (doc y)
  "The iedit marks on line Y as FAKE-LINE-COLOURS shows them."
  (remove-if-not (lambda (run) (member (third run) '(:occurrence :occurrence-current)))
                 (fake-line-colours doc y)))

;;; --- starting and ending ------------------------------------------

(deftest iedit-starts-on-the-symbol-in-the-defun
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (is (iedit-active-p doc))
    ;; The parameter, the one in the LIST form and the one in the `+'
    ;; form; not the comment's, not the string's, not g's.
    (is-equal (iedit-starts-of doc) (list 10 55 73))
    (is-equal (fake-last-message doc) "iedit: 3 occurrences of foo in the defun")
    ;; Marked, the one under the cursor distinctly
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence-current)))
    (is-equal (iedit-marks doc 2) '((14 17 :occurrence)))
    (is-equal (iedit-marks doc 3) '((5 8 :occurrence)))
    (is-equal (iedit-marks doc 1) '())))

(deftest iedit-with-an-argument-takes-the-buffer
  (let ((doc (iedit-fake)))
    (type-keys doc "C-u C-;")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))
    (is-equal (fake-last-message doc) "iedit: 5 occurrences of foo in the buffer")))

(deftest iedit-refuses-a-symbol-in-a-string-or-alone
  (let ((doc (iedit-fake *iedit-text* "foo" 1)))   ; the comment's
    (type-keys doc "C-;")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "foo here is not code")
    (is-equal (fake-beeps doc) 1))
  (let ((doc (iedit-fake *iedit-text* "list")))
    (type-keys doc "C-;")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "list occurs once in the defun"))
  (let ((doc (make-fake "   |   ")))
    (type-keys doc "C-;")
    (is-equal (fake-last-message doc) "No symbol at point")))

(deftest iedit-matches-the-symbol-whatever-its-case
  (let ((doc (make-fake "(defun f (|foo) (list FOO Foo foobar))")))
    (type-keys doc "C-;")
    (is-equal (iedit-starts-of doc) (list 10 21 25))
    (type-keys doc "x")
    (is-equal (fake-state doc) "(defun f (x|foo) (list xFOO xFoo foobar))")))

(deftest iedit-ends-on-its-key-on-quit-and-takes-the-marks-down
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (type-keys doc "C-;")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit off")
    (is-equal (iedit-marks doc 0) '())
    (is-equal (iedit-marks doc 2) '())
    ;; Typing is the widget's again
    (is-equal (type-keys doc "x") '("x"))
    (is-equal (fake-state doc) "(defun f (x|foo bar)
  ;; foo in a comment
  (list \"foo\" foo (g bar))
  (+ foo 1))

(defun g (foo)
  foo)"))
  (let ((doc (iedit-fake)))
    (type-keys doc "C-; C-g")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit off")))

(deftest iedit-is-not-for-the-repl-window
  (let ((doc (make-fake "|foo foo")))
    (setf (doc-repl doc) (make-repl-window))
    (type-keys doc "C-;")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit is not available in the REPL")))

;;; --- mirrored edits ------------------------------------------------

(deftest iedit-typing-reaches-every-occurrence
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (is-equal (type-keys doc "x y") '())
    (is-equal (fake-state doc) "(defun f (xy|foo bar)
  ;; foo in a comment
  (list \"foo\" xyfoo (g bar))
  (+ xyfoo 1))

(defun g (foo)
  foo)")
    (is-equal (iedit-starts-of doc) (list 10 57 77))
    (is-equal (iedit-text (doc-iedit doc)) "xyfoo")
    ;; The marks moved with the text
    (is-equal (iedit-marks doc 0) '((10 15 :occurrence-current)))
    (is-equal (iedit-marks doc 2) '((14 19 :occurrence)))))

(deftest iedit-edits-at-the-end-and-inside-mirror
  (let ((doc (make-fake "(let ((foo 1)) (* foo| foo))")))
    (type-keys doc "C-; s")
    (is-equal (fake-state doc) "(let ((foos 1)) (* foos| foos))")
    ;; Back into the symbol, Backspace: the character before the cursor
    ;; goes everywhere
    (type-keys doc "C-b C-b BS")
    (is-equal (fake-state doc) "(let ((fos 1)) (* f|os fos))")
    (is-equal (iedit-text (doc-iedit doc)) "fos")))

(deftest iedit-an-edit-outside-the-occurrence-only-moves-the-set
  (let ((doc (make-fake "(let ((|foo 1)) (* foo foo))")))
    (type-keys doc "C-;")
    ;; Backspace at the start deletes the paren before the symbol: not
    ;; mirrored, and the set moves up by one
    (type-keys doc "BS")
    (is-equal (fake-state doc) "(let (|foo 1)) (* foo foo))")
    (is-equal (iedit-starts-of doc) (list 6 17 21))
    (is (iedit-active-p doc))
    ;; Delete after the end: the same
    (type-keys doc "C-f C-f C-f C-d")
    (is-equal (fake-state doc) "(let (foo|1)) (* foo foo))")
    (is-equal (iedit-starts-of doc) (list 6 16 20))
    ;; And typing in an occurrence still reaches the others
    (type-keys doc "C-b z")
    (is-equal (fake-state doc) "(let (foz|o1)) (* fozo fozo))")))

(deftest iedit-an-edit-over-an-occurrence-drops-it
  (let ((doc (make-fake "(let ((|foo 1)) (* foo foo))")))
    (type-keys doc "C-;")
    ;; Kill from before the second occurrence into it: that one is no
    ;; longer a `foo' and leaves the set; the third moves up
    (setf (doc-mark doc) 16)
    (doc-set-point doc 19)
    (type-keys doc "C-w")
    (is-equal (fake-state doc) "(let ((foo 1)) (|oo foo))")
    (is-equal (iedit-starts-of doc) (list 7 19))
    (type-keys doc "C-f C-f C-f x")
    (is-equal (fake-state doc) "(let ((xfoo 1)) (oo x|foo))")
    (is-equal (iedit-starts-of doc) (list 7 20))))

(deftest iedit-kill-word-and-yank-mirror
  (let ((doc (make-fake "(defun f (foo bar) (+ |foo bar foo))")))
    (type-keys doc "C-; M-d")
    (is-equal (fake-state doc) "(defun f ( bar) (+ | bar ))")
    (is-equal (iedit-starts-of doc) (list 10 19 24))
    (is-equal (iedit-text (doc-iedit doc)) "")
    (type-keys doc "C-y")
    (is-equal (fake-state doc) "(defun f (foo bar) (+ foo| bar foo))")
    (is-equal (iedit-starts-of doc) (list 10 22 30))))

(deftest iedit-a-new-line-ends-the-session
  (let ((doc (make-fake "(defun f (foo) (+ fo|o 1))")))
    (type-keys doc "C-; RET")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit ended: the edit added or removed a line")
    ;; The newline went in once, where the cursor was
    (is-equal (doc-line-count doc) 2)
    (is-equal (doc-lines-text doc 0 0) (lines "(defun f (foo) (+ fo" ""))
    (is-equal (iedit-marks doc 0) '())))

(deftest iedit-the-cursor-outside-every-occurrence-edits-alone
  (let ((doc (make-fake "(defun f (|foo) (+ foo 1))")))
    ;; Past the symbol's end -- AT its end an insertion extends it
    (type-keys doc "C-; M-f C-f SPC x")
    (is-equal (fake-state doc) "(defun f (foo) x| (+ foo 1))")
    (is-equal (iedit-starts-of doc) (list 10 20))
    (is (iedit-active-p doc))
    ;; No occurrence is the current one now
    (is-equal (iedit-current (doc-iedit doc)) nil)
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence) (20 23 :occurrence)))))

;;; --- undo ----------------------------------------------------------

(deftest iedit-undo-takes-the-edit-back-everywhere
  (let ((doc (make-fake "(defun f (|foo) (+ foo foo))")))
    (type-keys doc "C-; x y")
    (is-equal (fake-state doc) "(defun f (xy|foo) (+ xyfoo xyfoo))")
    (type-keys doc "C-/")
    (is-equal (fake-state doc) "(defun f (x|foo) (+ xfoo xfoo))")
    (is-equal (iedit-starts-of doc) (list 10 19 24))
    (is-equal (iedit-text (doc-iedit doc)) "xfoo")
    (type-keys doc "C-x r")                   ; redo
    (is-equal (fake-state doc) "(defun f (xy|foo) (+ xyfoo xyfoo))")
    (is-equal (iedit-starts-of doc) (list 10 20 26))
    (type-keys doc "C-/ C-/")
    (is-equal (fake-state doc) "(defun f (|foo) (+ foo foo))")
    (is (iedit-active-p doc))
    ;; Past the session's start: it ends, and the undo is the widget's
    (type-keys doc "C-/")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit ended: undone past its start")))

;;; --- the session's keys --------------------------------------------

(deftest iedit-next-and-previous-walk-the-set-around
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (type-keys doc "M-n")
    (is-equal (fake-point doc) 55)
    (is-equal (fake-last-message doc) "iedit: occurrence 2 of 3")
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence)))
    (is-equal (iedit-marks doc 2) '((14 17 :occurrence-current)))
    (type-keys doc "M-n M-n")
    (is-equal (fake-point doc) 10)
    (type-keys doc "M-p")
    (is-equal (fake-point doc) 73)
    ;; From outside the set: the next one after the cursor
    (doc-set-point doc 30)
    (type-keys doc "M-n")
    (is-equal (fake-point doc) 55)
    (doc-set-point doc 30)
    (type-keys doc "M-p")
    (is-equal (fake-point doc) 10)))

(deftest iedit-toggle-drops-the-occurrence-at-point
  (let ((doc (make-fake "(defun f (|foo) (+ foo foo))")))
    (type-keys doc "C-; M-n M-;")
    (is-equal (iedit-starts-of doc) (list 10 22))
    (is-equal (fake-last-message doc) "iedit: 2 occurrences left")
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence) (22 25 :occurrence)))
    (type-keys doc "x")
    (is-equal (fake-state doc) "(defun f (foo) (+ x|foo foo))")
    ;; Dropping down to one ends the session
    (type-keys doc "M-n M-;")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit ended: one occurrence left")))

(deftest iedit-keys-mean-nothing-without-a-session
  (let ((doc (make-fake "|foo foo")))
    (is-equal (type-keys doc "M-n") '("M-n"))
    (is-equal (fake-state doc) "|foo foo")
    (run-command doc 'clamacs-iedit-next)
    (is-equal (fake-last-message doc) "No iedit session")))

(deftest iedit-keys-are-the-listed-table
  ;; The session's keys are the ones the command listing shows: every
  ;; entry of *IEDIT-BINDINGS* is what IEDIT-KEY-COMMAND answers, and
  ;; nothing else is.
  (is-equal (length *iedit-bindings*) 6)
  (dolist (spec *iedit-bindings*)
    (is-equal (iedit-key-command (key-from-string (first spec))) (second spec))
    (is-equal (command-keys-text (second spec)) (format nil "~A [iedit]" (first spec))))
  (is (null (iedit-key-command (key-from-string "M-x"))))
  (is (null (iedit-key-command (key-from-string "C-;"))))
  ;; M-H is the shifted letter; M-h is nobody's
  (is-equal (iedit-key-command (key-from-string "M-H")) 'clamacs-iedit-restrict-defun)
  (is (null (iedit-key-command (key-from-string "M-h"))))
  ;; The first line of each docstring stands on its own in the listing.
  (dolist (command '(clamacs-iedit clamacs-iedit-next clamacs-iedit-previous
                     clamacs-iedit-toggle-occurrence clamacs-iedit-expand-up
                     clamacs-iedit-expand-down clamacs-iedit-restrict-defun))
    (let ((line (command-doc-line command)))
      (unless (char= (char line (1- (length line))) #\.)
        (test-failure line " is not a whole sentence")))))

;;; --- the scope: M-{ M-} widen it a line at a time, M-H narrows it ---

(deftest iedit-expands-down-a-line-at-a-time
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (is-equal (iedit-region (doc-iedit doc)) '(0 . 3))
    ;; The empty line: nothing joins, the scope is lines now
    (type-keys doc "M-}")
    (is-equal (iedit-starts-of doc) (list 10 55 73))
    (is-equal (iedit-region (doc-iedit doc)) '(0 . 4))
    (is-equal (fake-last-message doc) "iedit: 3 occurrences of foo in lines 1-5")
    ;; g's parameter line
    (type-keys doc "M-}")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92))
    (is-equal (fake-last-message doc) "iedit: 4 occurrences of foo in lines 1-6")
    (is-equal (iedit-marks doc 5) '((10 13 :occurrence)))
    (is-equal (iedit-marks doc 6) '())
    ;; g's body, the last line
    (type-keys doc "M-}")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))
    (is-equal (iedit-marks doc 6) '((2 5 :occurrence)))
    ;; No further
    (type-keys doc "M-}")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))
    (is-equal (fake-last-message doc) "iedit: at the end of the buffer")
    (is-equal (fake-beeps doc) 1)
    ;; The cursor's occurrence is still the current one, and an edit
    ;; reaches the ones that joined
    (type-keys doc "x")
    (is-equal (fake-state doc) (lines "(defun f (x|foo bar)"
                                      "  ;; foo in a comment"
                                      "  (list \"foo\" xfoo (g bar))"
                                      "  (+ xfoo 1))"
                                      ""
                                      "(defun g (xfoo)"
                                      "  xfoo)"))))

(deftest iedit-expands-up-a-line-at-a-time
  (let ((doc (iedit-fake *iedit-text* "foo" 5)))   ; g's parameter
    (type-keys doc "C-;")
    (is-equal (iedit-starts-of doc) (list 92 99))
    (is-equal (iedit-region (doc-iedit doc)) '(5 . 6))
    (type-keys doc "M-{")
    (is-equal (iedit-starts-of doc) (list 92 99))
    (is-equal (fake-last-message doc) "iedit: 2 occurrences of foo in lines 5-7")
    ;; f's last line: the one in the `+' form joins, in order, marked
    (type-keys doc "M-{")
    (is-equal (iedit-starts-of doc) (list 73 92 99))
    (is-equal (iedit-marks doc 3) '((5 8 :occurrence)))
    (is-equal (iedit-marks doc 5) '((10 13 :occurrence-current)))
    ;; The LIST line: the string's foo is not code, the other one joins
    (type-keys doc "M-{")
    (is-equal (iedit-starts-of doc) (list 55 73 92 99))
    ;; The comment's never joins
    (type-keys doc "M-{")
    (is-equal (iedit-starts-of doc) (list 55 73 92 99))
    (type-keys doc "M-{")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))
    (is-equal (iedit-region (doc-iedit doc)) '(0 . 6))
    (type-keys doc "M-{")
    (is-equal (fake-last-message doc) "iedit: at the top of the buffer")
    (is-equal (fake-beeps doc) 1)))

(deftest iedit-expand-has-nothing-to-widen-for-the-buffer
  (let ((doc (iedit-fake)))
    (type-keys doc "C-u C-;")
    (is (null (iedit-region (doc-iedit doc))))
    (type-keys doc "M-}")
    (is-equal (fake-last-message doc) "iedit: the whole buffer already")
    (is-equal (fake-beeps doc) 1)
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))))

(deftest iedit-expand-keeps-a-dropped-occurrence-dropped
  (let ((doc (iedit-fake)))
    (type-keys doc "C-; M-n M-;")
    (is-equal (iedit-starts-of doc) (list 10 73))
    (type-keys doc "M-} M-}")
    (is-equal (iedit-starts-of doc) (list 10 73 92))
    (is-equal (iedit-marks doc 2) '())))

(deftest iedit-restricts-to-the-defun-again
  (let ((doc (iedit-fake)))
    (type-keys doc "C-u C-;")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92 99))
    (type-keys doc "M-H")
    (is-equal (iedit-starts-of doc) (list 10 55 73))
    (is-equal (iedit-region (doc-iedit doc)) '(0 . 3))
    (is-equal (fake-last-message doc) "iedit: 3 occurrences of foo in the defun")
    ;; The marks outside are gone, the ones inside stay
    (is-equal (iedit-marks doc 5) '())
    (is-equal (iedit-marks doc 6) '())
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence-current)))
    (is-equal (iedit-marks doc 3) '((5 8 :occurrence)))
    ;; Widening again from the defun works as from the start
    (type-keys doc "M-} M-}")
    (is-equal (iedit-starts-of doc) (list 10 55 73 92))
    ;; An edit no longer reaches what left
    (type-keys doc "M-H x")
    (is-equal (fake-state doc) (lines "(defun f (x|foo bar)"
                                      "  ;; foo in a comment"
                                      "  (list \"foo\" xfoo (g bar))"
                                      "  (+ xfoo 1))"
                                      ""
                                      "(defun g (foo)"
                                      "  foo)"))))

(deftest iedit-restrict-ends-the-session-when-too-few-remain
  ;; One occurrence in the cursor's defun
  (let ((doc (make-fake (lines "(defun f (foo) foo)" "(defun g () |foo)"))))
    (type-keys doc "C-u C-;")
    (is-equal (length (iedit-starts-of doc)) 3)
    (type-keys doc "M-H")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit ended: one occurrence left")
    (is-equal (iedit-marks doc 0) '())
    (is-equal (iedit-marks doc 1) '()))
  ;; None: the cursor moved out of the defun with the occurrences
  (let ((doc (make-fake (lines "(defun f (|foo) foo)" "(defun g () bar)"))))
    (type-keys doc "C-;")
    (type-keys doc "C-n M-H")
    (is (not (iedit-active-p doc)))
    (is-equal (fake-last-message doc) "iedit ended: no occurrence in the defun")))

(deftest iedit-restrict-needs-a-defun
  (let ((doc (make-fake "|foo foo" :lisp-mode t)))
    (type-keys doc "C-u C-;")
    (type-keys doc "M-H")
    (is (iedit-active-p doc))
    (is-equal (fake-last-message doc) "The cursor is in no defun")
    (is-equal (fake-beeps doc) 1))
  (let ((doc (make-fake "|foo foo" :lisp-mode nil)))
    (type-keys doc "C-;")
    (type-keys doc "M-H")
    (is (iedit-active-p doc))
    (is-equal (fake-last-message doc) "No defuns outside Lisp mode"))
  ;; Outside Lisp mode the scope widens by whole words
  (let ((doc (make-fake (lines "a |cat" "the cat sat" "cat") :lisp-mode nil)))
    (type-keys doc "C-;")
    (is-equal (iedit-starts-of doc) (list 2 10 18))
    (type-keys doc "M-}")
    (is-equal (fake-last-message doc) "iedit: the whole buffer already"))
  ;; Without a session the keys are nobody's
  (let ((doc (make-fake "|foo foo")))
    (is-equal (type-keys doc "M-}") '("M-}"))
    (run-command doc 'clamacs-iedit-restrict-defun)
    (is-equal (fake-last-message doc) "No iedit session")))

(deftest iedit-keys-yield-to-a-prefix-and-an-argument
  (let ((doc (make-fake "(defun f (|foo) (+ foo 1))")))
    (type-keys doc "C-;")
    ;; C-u 2 x: the digit is the argument's, not typed; the x is typed
    ;; (once: the widget's self-insert knows no argument) and mirrored
    (type-keys doc "C-u 2 x")
    (is-equal (fake-state doc) "(defun f (x|foo) (+ xfoo 1))")
    ;; Inside a prefix the session's keys are the prefix's
    (type-keys doc "C-x C-x")
    (is-equal (fake-last-message doc) "No mark set in this buffer")
    (is (iedit-active-p doc))))

;;; --- a buffer that is not Lisp --------------------------------------

(deftest iedit-outside-lisp-mode-edits-whole-words-in-the-buffer
  (let ((doc (make-fake (lines "the |cat sat" "on the cat's catalogue") :lisp-mode nil)))
    (type-keys doc "C-;")
    (is-equal (iedit-starts-of doc) (list 4 19))
    (is-equal (fake-last-message doc) "iedit: 2 occurrences of cat in the buffer")
    (type-keys doc "C-f C-f C-f s")
    (is-equal (fake-state doc) (lines "the cats| sat" "on the cats's catalogue"))))

;;; --- the marks follow a recolour -----------------------------------

(deftest iedit-marks-survive-a-recolour-of-their-lines
  (let ((doc (iedit-fake)))
    (type-keys doc "C-;")
    (colour-lines doc 0 3)
    (is-equal (iedit-marks doc 0) '((10 13 :occurrence-current)))
    (is-equal (iedit-marks doc 2) '((14 17 :occurrence)))
    (colour-all doc)
    (is-equal (iedit-marks doc 3) '((5 8 :occurrence)))
    ;; A text replaced under the session (a file loaded into the window):
    ;; the recolour finds no occurrences and the session ends
    (doc-set-text doc "(nothing here)")
    (colour-all doc)
    (is (not (iedit-active-p doc)))))

;;; --- the port ------------------------------------------------------

(deftest iedit-port-verb-answers-the-set
  (let* ((editor (make-fake-editor))
         (doc (make-fake "(defun f (|foo) (+ foo 1))" :editor editor)))
    (doc-activate doc)
    (is-equal (multiple-value-list (port-command editor "IEDIT")) (list +rc-ok+ "off"))
    (type-keys doc "C-;")
    (is-equal (multiple-value-list (port-command editor "IEDIT"))
              (list +rc-ok+ "2 foo *10-13 18-21"))))
