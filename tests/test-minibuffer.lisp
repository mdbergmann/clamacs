;;;; test-minibuffer.lisp -- prompts, completion, history and incremental
;;;; search, on the fake frontend.

(in-package :clamacs)

(deftest prompt-runs-its-continuation-with-the-answer
  (let ((doc (make-fake "|"))
        (got nil))
    (prompt doc "Name: " (lambda (d answer) (setq got (list d answer))))
    (is (minibuffer-open-p doc))
    (is-equal (fake-prompt doc) "Name: ")
    (type-text doc "a b")
    (is-equal (fake-prompt doc) "Name: a b")
    ;; The text was not typed into.
    (is-equal (fake-state doc) "|")
    (type-keys doc "RET")
    (is-equal got (list doc "a b"))
    (is (not (minibuffer-open-p doc)))
    (is-equal (fake-prompt doc) nil)))

(deftest prompt-initial-input-and-abort
  (let ((doc (make-fake "|"))
        (called nil))
    (prompt doc "Write file: " (lambda (d a) (declare (ignore d a))
                                 (setq called t))
            :initial "Work:a.lisp")
    (is-equal (fake-prompt doc) "Write file: Work:a.lisp")
    (type-keys doc "C-g")
    (is (not (minibuffer-open-p doc)))
    (is (not called))
    (is-equal (fake-last-message doc) "Quit")))

;; ESC abandons a prompt like C-g.  Left to the input line it was MUI's
;; GADGET_OFF + WINDOW_CLOSE, and one ESC at "Inspect value: " closed the
;; document window -- the exit, with one document open.  So the
;; minibuffer takes it, in every state, and the continuation never runs.
(deftest esc-abandons-a-prompt-like-c-g
  (let ((doc (make-fake "ab|c"))
        (called nil))
    (prompt doc "Inspect value (evaluated): "
            (lambda (d a) (declare (ignore d a)) (setq called t)))
    (is (minibuffer-binds-p doc (k "ESC")))
    (type-text doc "(+ 1")
    (type-keys doc "ESC")
    (is (not (minibuffer-open-p doc)))
    (is (not called))
    (is-equal (fake-last-message doc) "Quit")
    (is-equal (fake-prompt doc) nil)
    ;; Neither the ESC nor the typed text reached the buffer.
    (is-equal (fake-state doc) "ab|c")
    ;; Closed, the minibuffer no longer claims it: in the text ESC is Meta.
    (is (not (minibuffer-binds-p doc (k "ESC"))))
    (is (not (minibuffer-key doc (k "ESC"))))))

(deftest esc-abandons-a-search-back-to-the-anchor
  (let ((doc (make-fake "|one two one")))
    (type-keys doc "C-s")
    (is (minibuffer-binds-p doc (k "ESC")))
    (type-text doc "two")
    (is-equal (fake-state doc) "one two| one")
    (type-keys doc "ESC")
    (is (not (minibuffer-open-p doc)))
    (is-equal (fake-state doc) "|one two one")
    (is-equal (fake-last-message doc) "Quit")))

(deftest a-continuation-may-prompt-again
  (let ((doc (make-fake "|"))
        (answers '()))
    (prompt doc "One: "
            (lambda (d a)
              (push a answers)
              (prompt d "Two: " (lambda (d a)
                                  (declare (ignore d))
                                  (push a answers)))))
    (type-keys doc "x RET")
    (is-equal (fake-prompt doc) "Two: ")
    (type-keys doc "y RET")
    (is-equal answers '("y" "x"))
    (is (not (minibuffer-open-p doc)))))

(deftest minibuffer-keys-are-only-its-own
  (let ((doc (make-fake "|")))
    (is (not (minibuffer-binds-p doc (k "C-g"))))
    (is (not (minibuffer-key doc (k "C-g"))))
    (prompt doc "P: " (lambda (d a) (declare (ignore d a))))
    (dolist (key '("C-g" "ESC" "TAB" "M-p" "M-n" "<up>" "<down>"))
      (is (minibuffer-binds-p doc (k key))))
    (dolist (key '("C-s" "C-r" "a" "RET" "C-f" "<left>"))
      (is (not (minibuffer-binds-p doc (k key)))))
    (type-keys doc "C-g C-s")
    (dolist (key '("C-g" "ESC" "C-s" "C-r"))
      (is (minibuffer-binds-p doc (k key))))
    (dolist (key '("TAB" "M-p" "M-n" "a" "<up>" "<down>"))
      (is (not (minibuffer-binds-p doc (k key)))))))

;; The union a frontend takes from an active input line before it knows
;; the state (the MUI String's native key table): every key BINDS-P can
;; say yes to, and nothing else.
(deftest minibuffer-ever-binds-is-the-union-of-the-states
  (dolist (key '("C-g" "ESC" "TAB" "M-p" "M-n" "C-s" "C-r" "<up>" "<down>"))
    (is (minibuffer-ever-binds-p (k key))))
  (dolist (key '("a" "RET" "C-f" "M-x" "S-TAB" "C-TAB" "M-ESC" "C-ESC" "<left>" "C-<up>"))
    (is (not (minibuffer-ever-binds-p (k key)))))
  ;; and it agrees with BINDS-P in both states
  (let ((doc (make-fake "|")))
    (prompt doc "P: " (lambda (d a) (declare (ignore d a))))
    (dolist (key '("C-g" "ESC" "TAB" "M-p" "M-n" "C-s" "C-r" "a" "RET"))
      (when (minibuffer-binds-p doc (k key))
        (is (minibuffer-ever-binds-p (k key)))))
    (type-keys doc "C-g C-s")
    (dolist (key '("C-g" "ESC" "TAB" "M-p" "M-n" "C-s" "C-r" "a" "RET"))
      (when (minibuffer-binds-p doc (k key))
        (is (minibuffer-ever-binds-p (k key)))))))

(deftest a-message-during-a-prompt-takes-the-label
  (let ((doc (make-fake "|")))
    (doc-message doc "before")
    (prompt doc "P: " (lambda (d a) (declare (ignore d a))))
    (doc-message doc "[No match]")
    (is-equal (fake-mini-label doc) "[No match]")
    (is-equal (fake-last-message doc) "before")))

;;; --- M-x ------------------------------------------------------------------

(deftest m-x-runs-a-command-by-name
  (let ((doc (make-fake "|hello")))
    (type-keys doc "M-x")
    (is-equal (fake-prompt doc) "M-x ")
    (type-text doc "end-of-line")
    (type-keys doc "RET")
    (is-equal (fake-state doc) "hello|")
    (is-equal (doc-last-command doc) 'end-of-line)))

(deftest m-x-completes-with-tab
  (let ((doc (make-fake "|hello")))
    (type-keys doc "M-x")
    (type-text doc "end-of-l")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[Sole completion]end-of-line")
    (type-keys doc "RET")
    (is-equal (fake-state doc) "hello|"))
  (let ((doc (make-fake "|")))
    (type-keys doc "M-x")
    (type-text doc "kill-r")
    (type-keys doc "TAB")
    ;; Ambiguous: the candidates are named, there being no completions
    ;; buffer to show them in.
    (is-equal (fake-prompt doc) "[2 completions: kill-region kill-ring-save]kill-r")
    (type-text doc "i")
    (type-keys doc "TAB")
    (is-equal (fake-mini-text doc) "kill-ring-save")
    (type-keys doc "C-g"))
  (let ((doc (make-fake "|")))
    (type-keys doc "M-x")
    (type-text doc "zzz")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[No match]zzz")
    (type-keys doc "RET")
    (is-equal (fake-last-message doc) "[No match]")
    (is-equal (fake-beeps doc) 1)))

(deftest m-x-tab-on-an-empty-line-shows-what-there-is
  ;; The way to find out what `M-x' offers: the count of every command,
  ;; the first eight by name, and an ellipsis for the rest.  Nothing goes
  ;; into the line (the names have nothing in common).
  (let ((doc (make-fake "|")))
    (type-keys doc "M-x")
    (type-keys doc "TAB")
    (is-equal (fake-mini-text doc) "")
    (is-equal (fake-mini-label doc)
              (format nil "[~D completions:~{ ~A~} ...]"
                      (length (command-names))
                      (subseq (command-names) 0 8)))
    (is (> (length (command-names)) 8))
    (is-equal (subseq (command-names) 0 2) '("forward-char" "backward-char"))
    ;; Typing on narrows it, and the ellipsis goes once eight or fewer remain.
    (type-text doc "clamacs-debugger")
    (type-keys doc "TAB")
    (is-equal (fake-mini-text doc) "clamacs-debugger")
    (is-equal (fake-mini-label doc)
              "[6 completions: clamacs-debugger clamacs-debugger-abort clamacs-debugger-continue clamacs-debugger-restart clamacs-debugger-frame clamacs-debugger-eval]")
    (type-keys doc "C-g")))

(deftest tab-again-cycles-through-the-candidates
  (let ((doc (make-fake "|hello")))
    (type-keys doc "M-x")
    (type-text doc "kill-r")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[2 completions: kill-region kill-ring-save]kill-r")
    ;; TAB on what TAB left: the candidates in turn, whole, counted.
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[1/2]kill-region")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[2/2]kill-ring-save")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[1/2]kill-region")
    ;; An edit ends the round: TAB completes what is typed now.
    (type-keys doc "BS BS BS BS")
    (is-equal (fake-mini-text doc) "kill-re")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[Sole completion]kill-region")
    ;; A sole completion offers nothing to cycle through.
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[Sole completion]kill-region")
    ;; RET takes the candidate in the line.
    (type-keys doc "C-g M-x")
    (type-text doc "kill-r")
    (type-keys doc "TAB TAB TAB")
    (is-equal (fake-mini-text doc) "kill-ring-save")
    (type-keys doc "RET")
    (is-equal (doc-last-command doc) 'kill-ring-save)
    (is-equal (fake-state doc) "|hello")))

;; The candidates TAB offers are a list where the frontend has one, with
;; a cursor the arrows (and TAB) move; the candidate under the cursor is in
;; the line.  No cursor (-1) = the common prefix is there.
(deftest the-arrows-walk-the-candidates-tab-offered
  (let ((doc (make-fake "|hello")))
    (type-keys doc "M-x")
    (type-text doc "kill-r")
    (is (null (fake-completions doc)))
    (type-keys doc "TAB")
    (is-equal (fake-completions doc) '("kill-region" "kill-ring-save"))
    (is-equal (fake-completion-index doc) -1)
    (is-equal (fake-mini-text doc) "kill-r")
    (type-keys doc "<down>")
    (is-equal (fake-prompt doc) "[1/2]kill-region")
    (is-equal (fake-completion-index doc) 0)
    (type-keys doc "<down>")
    (is-equal (fake-prompt doc) "[2/2]kill-ring-save")
    (is-equal (fake-completion-index doc) 1)
    ;; round, in both directions
    (type-keys doc "<down>")
    (is-equal (fake-completion-index doc) 0)
    (type-keys doc "<up>")
    (is-equal (fake-completion-index doc) 1)
    (is-equal (fake-mini-text doc) "kill-ring-save")
    ;; TAB moves the same cursor
    (type-keys doc "TAB")
    (is-equal (fake-completion-index doc) 0)
    (is-equal (fake-completions doc) '("kill-region" "kill-ring-save"))
    ;; An edit ends the offer: the list goes
    (type-keys doc "BS")
    (is (null (fake-completions doc)))
    (is-equal (fake-completion-index doc) -1)
    (is-equal (fake-mini-text doc) "kill-regio")
    ;; <up> from the common prefix goes to the last candidate
    (type-keys doc "C-g M-x")
    (type-text doc "kill-r")
    (type-keys doc "TAB <up>")
    (is-equal (fake-prompt doc) "[2/2]kill-ring-save")
    ;; RET takes the candidate, and the list goes with the prompt
    (type-keys doc "RET")
    (is (null (fake-completions doc)))
    (is (not (minibuffer-open-p doc)))
    (is-equal (doc-last-command doc) 'kill-ring-save)
    ;; A sole completion and no match offer no list
    (type-keys doc "M-x")
    (type-text doc "kill-re")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[Sole completion]kill-region")
    (is (null (fake-completions doc)))
    (type-text doc "zz")
    (type-keys doc "TAB")
    (is-equal (fake-prompt doc) "[No match]kill-regionzz")
    (is (null (fake-completions doc)))
    ;; C-g with the list up takes it down
    (type-keys doc "C-g M-x")
    (type-text doc "kill-r")
    (type-keys doc "TAB")
    (is (fake-completions doc))
    (type-keys doc "C-g")
    (is (null (fake-completions doc)))))

;; With nothing on offer the arrows are the history's, as in Emacs.
(deftest the-arrows-walk-the-history-when-nothing-is-on-offer
  (let ((doc (make-fake "|ab")))
    (type-keys doc "M-x")
    (type-text doc "forward-char")
    (type-keys doc "RET M-x")
    (type-text doc "end-of-line")
    (type-keys doc "RET M-x <up>")
    (is-equal (fake-mini-text doc) "end-of-line")
    (type-keys doc "<up>")
    (is-equal (fake-mini-text doc) "forward-char")
    (type-keys doc "<down>")
    (is-equal (fake-mini-text doc) "end-of-line")
    (type-keys doc "<down>")
    (is-equal (fake-mini-text doc) "")
    ;; Once TAB offers candidates, the arrows are theirs again
    (type-text doc "kill-r")
    (type-keys doc "TAB <down>")
    (is-equal (fake-mini-text doc) "kill-region")
    (is-equal (fake-completion-index doc) 0)))

;; The frontend's list may be clicked: the row goes into the line, a
;; double click takes it.
(deftest a-click-in-the-list-picks-a-candidate
  (let ((doc (make-fake "|hello")))
    (is (not (minibuffer-pick doc 0)))
    (type-keys doc "M-x")
    (type-text doc "kill-r")
    (is (not (minibuffer-pick doc 0)))
    (type-keys doc "TAB")
    (is (not (minibuffer-pick doc 2)))
    (is (not (minibuffer-pick doc -1)))
    (is (not (minibuffer-pick doc nil)))
    (is (minibuffer-pick doc 1))
    (is-equal (fake-prompt doc) "[2/2]kill-ring-save")
    (is-equal (fake-completion-index doc) 1)
    (is (minibuffer-open-p doc))
    ;; <down> goes on from the picked row
    (type-keys doc "<down>")
    (is-equal (fake-completion-index doc) 0)
    (is-equal (fake-mini-text doc) "kill-region")
    ;; A double click takes it
    (is (minibuffer-pick doc 1 t))
    (is (not (minibuffer-open-p doc)))
    (is (null (fake-completions doc)))
    (is-equal (doc-last-command doc) 'kill-ring-save)
    ;; Not in a search
    (type-keys doc "C-s")
    (is (not (minibuffer-pick doc 0)))
    (type-keys doc "C-g")))

;; A completer may say what to show for each match (a file's base name
;; for its path): the list shows that, the line gets the match.
(deftest the-list-shows-the-names-the-completer-gives
  (let ((doc (make-fake "|")))
    (prompt doc "F: " (lambda (d a) (declare (ignore d a)))
            :completer (lambda (text)
                         (declare (ignore text))
                         (values '("/a/one" "/a/two") "/a/" '("one" "two"))))
    (type-keys doc "TAB")
    (is-equal (fake-completions doc) '("one" "two"))
    (is-equal (fake-prompt doc) "[2 completions: one two]/a/")
    (type-keys doc "<down>")
    (is-equal (fake-mini-text doc) "/a/one")
    (is-equal (fake-completions doc) '("one" "two"))
    (is-equal (fake-completion-index doc) 0)
    (is (minibuffer-pick doc 1))
    (is-equal (fake-mini-text doc) "/a/two")
    (type-keys doc "C-g")))

(deftest m-x-history-walks-with-m-p-and-m-n
  (let ((doc (make-fake "|ab")))
    (type-keys doc "M-x")
    (type-text doc "forward-char")
    (type-keys doc "RET M-x")
    (type-text doc "end-of-line")
    (type-keys doc "RET M-x M-p")
    (is-equal (fake-mini-text doc) "end-of-line")
    (type-keys doc "M-p")
    (is-equal (fake-mini-text doc) "forward-char")
    ;; Past the oldest the line is blank; M-n comes forward again.
    (type-keys doc "M-p")
    (is-equal (fake-mini-text doc) "")
    (type-keys doc "M-n")
    (is-equal (fake-mini-text doc) "end-of-line")
    (type-keys doc "M-n")
    (is-equal (fake-mini-text doc) "")
    (type-keys doc "C-g")
    ;; The history is the editor's: another window sees it.
    (let ((other (make-fake "|" :editor (doc-editor doc))))
      (type-keys other "M-x M-p")
      (is-equal (fake-mini-text other) "end-of-line"))))

(deftest a-prompt-without-completer-or-history
  (let ((doc (make-fake "|")))
    (prompt doc "P: " (lambda (d a) (declare (ignore d a))))
    (type-keys doc "x TAB")
    (is-equal (fake-beeps doc) 1)
    (type-keys doc "M-p")
    (is-equal (fake-mini-text doc) "")))

;;; --- goto-line ------------------------------------------------------------

(deftest goto-line-moves-to-a-line
  (let ((doc (make-fake (lines "one" "two" "th|ree"))))
    (type-keys doc "M-g g")
    (is-equal (fake-prompt doc) "Goto line: ")
    (type-keys doc "2 RET")
    (is-equal (fake-state doc) (lines "one" "|two" "three"))
    ;; Past the end is the last line; junk and zero move nothing.
    (type-keys doc "M-g g 9 9 RET")
    (is-equal (fake-state doc) (lines "one" "two" "|three"))
    (type-keys doc "M-g g x RET M-g g 0 RET M-g g RET")
    (is-equal (fake-state doc) (lines "one" "two" "|three"))
    ;; Line numbers are not worth a history.
    (is-equal (hist-count (editor-command-history (doc-editor doc))) 0)))

;;; --- incremental search -----------------------------------------------------

(deftest isearch-finds-as-you-type
  (let ((doc (make-fake "|foo bar foobar")))
    (type-keys doc "C-s")
    (is-equal (fake-prompt doc) "I-search: ")
    (type-keys doc "b")
    (is-equal (fake-state doc) "foo b|ar foobar")
    (type-keys doc "a r")
    (is-equal (fake-state doc) "foo bar| foobar")
    ;; Again: the next one.
    (type-keys doc "C-s")
    (is-equal (fake-state doc) "foo bar foobar|")
    ;; No further match: the label says so and the cursor stays.
    (type-keys doc "C-s")
    (is-equal (fake-prompt doc) "Failing I-search: bar")
    (is-equal (fake-state doc) "foo bar foobar|")
    ;; Turning round finds the last one again, then the one before.
    (type-keys doc "C-r")
    (is-equal (fake-prompt doc) "Reverse I-search: bar")
    (is-equal (fake-state doc) "foo bar foo|bar")
    (type-keys doc "C-r")
    (is-equal (fake-state doc) "foo |bar foobar")
    ;; RET stays there; the way back is the mark.
    (type-keys doc "RET")
    (is (not (minibuffer-open-p doc)))
    (is-equal (doc-mark doc) 0)
    (is-equal (fake-last-message doc) "Mark set")
    (is-equal (fake-state doc) "foo |bar foobar")))

(deftest isearch-shrinking-the-pattern-starts-over
  (let ((doc (make-fake "|ab abc")))
    (type-keys doc "C-s a b c")
    (is-equal (fake-state doc) "ab abc|")
    (type-keys doc "BS")
    (is-equal (fake-state doc) "ab| abc")
    ;; An empty pattern searches for nothing and moves nothing further.
    (type-keys doc "BS BS")
    (is-equal (fake-prompt doc) "I-search: ")))

(deftest isearch-abort-returns-to-the-anchor
  (let ((doc (make-fake "a|b needle")))
    (type-keys doc "C-s n e e")
    (is-equal (fake-state doc) "ab nee|dle")
    (type-keys doc "C-g")
    (is-equal (fake-state doc) "a|b needle")
    (is-equal (doc-mark doc) nil)
    (is-equal (fake-last-message doc) "Quit")))

(deftest isearch-backward-and-failing
  (let ((doc (make-fake "needle hay needle|")))
    (type-keys doc "C-r")
    (is-equal (fake-prompt doc) "Reverse I-search: ")
    (type-keys doc "n e e")
    (is-equal (fake-state doc) "needle hay |needle")
    (type-keys doc "x")
    (is-equal (fake-prompt doc) "Failing I-search: neex")
    ;; A failing search leaves the cursor at the anchor.
    (is-equal (fake-state doc) "needle hay needle|")))
