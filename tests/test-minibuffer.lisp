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
    (dolist (key '("C-g" "TAB" "M-p" "M-n"))
      (is (minibuffer-binds-p doc (k key))))
    (dolist (key '("C-s" "C-r" "a" "RET" "C-f"))
      (is (not (minibuffer-binds-p doc (k key)))))
    (type-keys doc "C-g C-s")
    (dolist (key '("C-g" "C-s" "C-r"))
      (is (minibuffer-binds-p doc (k key))))
    (dolist (key '("TAB" "M-p" "M-n" "a"))
      (is (not (minibuffer-binds-p doc (k key)))))))

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
    (is-equal (fake-prompt doc) "[2 completions]kill-r")
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
