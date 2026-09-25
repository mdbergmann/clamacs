;;;; test-textmirror.lisp -- the text model (lisp/textmirror.lisp).
;;;;
;;;; What tests/test-commands.lisp implies about the fake document's
;;;; widget, stated directly, plus the boundaries the commands never hit:
;;;; the empty text, the last line, page motion at either end, a search
;;;; that overlaps the point.

(in-package :clamacs)

(defun mirror-state (m)
  "The text with a `|' where the point is."
  (let ((text (mirror-text m)) (point (mirror-point m)))
    (concatenate 'string (subseq text 0 point) "|" (subseq text point))))

(defun mirror-from (state)
  "A mirror from STATE, a text with a `|' at the point."
  (let ((bar (position #\| state)))
    (make-mirror :text (concatenate 'string (subseq state 0 bar)
                                    (subseq state (1+ bar)))
                 :point bar)))

;;; --- lines ------------------------------------------------------

(deftest mirror-empty-text-has-one-line
  (let ((m (make-mirror)))
    (is-equal (mirror-end m) 0)
    (is-equal (mirror-line-count m) 1)
    (is-equal (multiple-value-list (mirror-index-line m 0)) '(0 0))
    (is-equal (mirror-line-index m 0) 0)
    (is-equal (mirror-line-index m 5) 0)
    (is-equal (mirror-lines-text m 0 0) "")
    (is-equal (mirror-substring m 0 0) "")))

(deftest mirror-lines-and-columns
  (let ((m (make-mirror :text (format nil "ab~%cde~%~%f"))))
    (is-equal (mirror-line-count m) 4)
    (is-equal (multiple-value-list (mirror-index-line m 0)) '(0 0))
    (is-equal (multiple-value-list (mirror-index-line m 2)) '(0 2))
    (is-equal (multiple-value-list (mirror-index-line m 3)) '(1 0))
    (is-equal (multiple-value-list (mirror-index-line m 6)) '(1 3))
    (is-equal (multiple-value-list (mirror-index-line m 7)) '(2 0))
    (is-equal (multiple-value-list (mirror-index-line m 9)) '(3 1))
    ;; Clamped at both ends
    (is-equal (multiple-value-list (mirror-index-line m 99)) '(3 1))
    (is-equal (multiple-value-list (mirror-index-line m -4)) '(0 0))
    (is-equal (mirror-line-index m 0) 0)
    (is-equal (mirror-line-index m 1) 3)
    (is-equal (mirror-line-index m 2) 7)
    (is-equal (mirror-line-index m 3) 8)
    ;; Past the last line: the last line; before the first: the first
    (is-equal (mirror-line-index m 4) 8)
    (is-equal (mirror-line-index m -1) 0)
    (is-equal (mirror-lines-text m 0 0) (format nil "ab~%"))
    (is-equal (mirror-lines-text m 1 2) (format nil "cde~%~%"))
    (is-equal (mirror-lines-text m 3 3) "f")
    (is-equal (mirror-lines-text m 2 9) (format nil "~%f"))))

(deftest mirror-trailing-newline-is-an-empty-last-line
  (let ((m (make-mirror :text (format nil "ab~%"))))
    (is-equal (mirror-line-count m) 2)
    (is-equal (mirror-line-index m 1) 3)
    (is-equal (mirror-lines-text m 1 1) "")
    (is-equal (multiple-value-list (mirror-index-line m 3)) '(1 0))))

(deftest mirror-set-point-clamps
  (let ((m (make-mirror :text "abc")))
    (is-equal (mirror-set-point m 2) 2)
    (is-equal (mirror-set-point m 10) 3)
    (is-equal (mirror-set-point m -1) 0)
    (is-equal (mirror-point (make-mirror :text "ab" :point 7)) 2)))

;;; --- editing ------------------------------------------------------

(deftest mirror-insert-and-delete
  (let ((m (mirror-from "ab|cd")))
    (is (not (mirror-modified m)))
    (mirror-insert m "XY")
    (is-equal (mirror-state m) "abXY|cd")
    (is (mirror-modified m))
    (mirror-delete m 1 5)
    (is-equal (mirror-state m) "a|d")
    (mirror-insert m "")
    (is-equal (mirror-state m) "a|d")))

(deftest mirror-undo-and-redo
  (let ((m (mirror-from "|")))
    (is (not (mirror-edit m :undo)))
    (is (not (mirror-edit m :redo)))
    (mirror-insert m "one")
    (mirror-insert m " two")
    (is (mirror-edit m :undo))
    (is-equal (mirror-state m) "one|")
    (is (mirror-edit m :undo))
    (is-equal (mirror-state m) "|")
    (is (not (mirror-edit m :undo)))
    (is (mirror-edit m :redo))
    (is-equal (mirror-state m) "one|")
    ;; A new edit forgets the redo branch
    (mirror-insert m "!")
    (is (not (mirror-edit m :redo)))
    (is-equal (mirror-state m) "one!|")))

(defun undo-lengths (m)
  "The lengths of the texts in M's undo list, newest first."
  (mapcar (lambda (entry) (length (car entry))) (mirror-undo m)))

(deftest mirror-undo-depth-is-bounded
  (let ((*mirror-undo-depth* 5)
        (m (make-mirror)))
    (loop repeat 8 do (mirror-insert m "x"))
    ;; Snapshots of 0 to 7 characters were taken; the newest 5 stay
    (is-equal (undo-lengths m) '(7 6 5 4 3))
    (loop repeat 5 do (is (mirror-edit m :undo)))
    (is (not (mirror-edit m :undo)))
    (is-equal (mirror-text m) "xxx")
    ;; Everything undone can be redone, and no more than that
    (loop repeat 5 do (is (mirror-edit m :redo)))
    (is (not (mirror-edit m :redo)))
    (is-equal (mirror-text m) "xxxxxxxx")
    (is-equal (undo-lengths m) '(7 6 5 4 3))))

(deftest mirror-undo-chars-are-bounded
  (let ((*mirror-undo-chars* 100)
        (m (make-mirror :text (make-string 40 :initial-element #\a))))
    (loop repeat 10 do (mirror-insert m "x"))
    ;; Snapshots of 49 and 48 characters fit (97); a third makes 144
    (is-equal (undo-lengths m) '(49 48))
    (is (mirror-edit m :undo))
    (is (mirror-edit m :undo))
    (is (not (mirror-edit m :undo)))
    (is-equal (length (mirror-text m)) 48))
  ;; The newest entry stays even when it alone is over the bound
  (let ((*mirror-undo-chars* 100)
        (m (make-mirror :text (make-string 200 :initial-element #\a))))
    (mirror-insert m "x")
    (is-equal (undo-lengths m) '(200))
    (mirror-insert m "y")
    (is-equal (undo-lengths m) '(201))
    (is (mirror-edit m :undo))
    (is-equal (length (mirror-text m)) 201)
    (is (not (mirror-edit m :undo)))))

(deftest mirror-delete-and-backspace-at-the-ends
  (let ((m (mirror-from "|ab")))
    (is (not (mirror-edit m :backspace)))
    (is (mirror-edit m :delete))
    (is-equal (mirror-state m) "|b")
    (mirror-set-point m 1)
    (is (not (mirror-edit m :delete)))
    (is (mirror-edit m :backspace))
    (is-equal (mirror-state m) "|")))

(deftest mirror-selection
  (let ((m (mirror-from "ab|")))
    (is-equal (mirror-selection m) nil)
    (is (mirror-edit m :select-all))
    (is-equal (mirror-selection m) '(0 . 2))
    (is (mirror-edit m :select-none))
    (is-equal (mirror-selection m) nil)))

(deftest mirror-set-text-starts-over
  (let ((m (mirror-from "ab|")))
    (mirror-insert m "c")
    (mirror-edit m :select-all)
    (mirror-set-text m (format nil "new~%text"))
    (is-equal (mirror-state m) (format nil "|new~%text"))
    (is (not (mirror-modified m)))
    (is-equal (mirror-selection m) nil)
    (is (not (mirror-edit m :undo)))
    (setf (mirror-modified m) t)
    (is (mirror-modified m))))

;;; --- motions ------------------------------------------------------

(deftest mirror-character-and-line-motions
  (let ((m (mirror-from (format nil "ab~%c|de~%f"))))
    (is (mirror-move m :left))
    (is-equal (mirror-state m) (format nil "ab~%|cde~%f"))
    (is (mirror-move m :right))
    (is (mirror-move m :line-end))
    (is-equal (mirror-state m) (format nil "ab~%cde|~%f"))
    ;; Up keeps the column where the line allows, else its end
    (is (mirror-move m :up))
    (is-equal (mirror-state m) (format nil "ab|~%cde~%f"))
    (is (mirror-move m :down))
    (is-equal (mirror-state m) (format nil "ab~%cd|e~%f"))
    (is (mirror-move m :down))
    (is-equal (mirror-state m) (format nil "ab~%cde~%f|"))
    (is (not (mirror-move m :down)))
    (is (mirror-move m :line-start))
    (is-equal (mirror-state m) (format nil "ab~%cde~%|f"))
    (is (mirror-move m :text-start))
    (is-equal (mirror-state m) (format nil "|ab~%cde~%f"))
    (is (not (mirror-move m :up)))
    (is (not (mirror-move m :left)))
    (is (mirror-move m :text-end))
    (is (not (mirror-move m :right)))
    (is-equal (mirror-state m) (format nil "ab~%cde~%f|"))))

(deftest mirror-motions-on-the-empty-text
  (let ((m (make-mirror)))
    (dolist (motion '(:left :right :up :down :next-word :previous-word))
      (is (not (mirror-move m motion))))
    ;; These "succeed" without moving, as the widget's do: a page motion
    ;; stays on the one line, so `C-v' never beeps
    (dolist (motion '(:line-start :line-end :text-start :text-end
                      :next-page :previous-page))
      (is (mirror-move m motion)))
    (is-equal (mirror-point m) 0)))

(deftest mirror-word-motions
  (let ((m (mirror-from "|foo bar-baz  ")))
    (is (mirror-move m :next-word))
    (is-equal (mirror-state m) "foo| bar-baz  ")
    (is (mirror-move m :next-word))
    (is-equal (mirror-state m) "foo bar|-baz  ")
    (is (mirror-move m :next-word))
    (is-equal (mirror-state m) "foo bar-baz|  ")
    ;; Nothing but separators ahead: the point goes to the end
    (is (mirror-move m :next-word))
    (is-equal (mirror-state m) "foo bar-baz  |")
    (is (not (mirror-move m :next-word)))
    (is (mirror-move m :previous-word))
    (is-equal (mirror-state m) "foo bar-|baz  ")
    (is (mirror-move m :previous-word))
    (is-equal (mirror-state m) "foo |bar-baz  ")
    (is (mirror-move m :previous-word))
    (is-equal (mirror-state m) "|foo bar-baz  ")
    (is (not (mirror-move m :previous-word)))))

(deftest mirror-page-motions-stop-at-the-ends
  (let ((m (make-mirror :text (format nil "~{line~D~^~%~}"
                                      (loop for i below 25 collect i)))))
    (is-equal (mirror-page-lines m) 10)
    (is (mirror-move m :next-page))
    (is-equal (mirror-index-line m (mirror-point m)) 10)
    (is (mirror-move m :next-page))
    (is-equal (mirror-index-line m (mirror-point m)) 20)
    ;; The last page is short: the last line, not past it
    (is (mirror-move m :next-page))
    (is-equal (mirror-index-line m (mirror-point m)) 24)
    ;; Already on the last line: stays there, and is still "possible" --
    ;; `C-v' at the end does not beep (test-commands.lisp)
    (is (mirror-move m :next-page))
    (is-equal (mirror-index-line m (mirror-point m)) 24)
    (is (mirror-move m :previous-page))
    (is-equal (mirror-index-line m (mirror-point m)) 14)
    (is (mirror-move m :previous-page))
    (is (mirror-move m :previous-page))
    (is-equal (mirror-index-line m (mirror-point m)) 0)
    (is (mirror-move m :previous-page))
    (is-equal (mirror-point m) 0)
    ;; The column survives a page motion where the line is long enough
    (mirror-set-point m 3)
    (mirror-move m :next-page)
    (is-equal (multiple-value-list (mirror-index-line m (mirror-point m))) '(10 3))
    (setf (mirror-page-lines m) 5)
    (mirror-move m :next-page)
    (is-equal (mirror-index-line m (mirror-point m)) 15)))

;;; --- search -------------------------------------------------------

(deftest mirror-search-forwards-and-back
  (let ((m (mirror-from "|abcabc")))
    (is (mirror-search m "bc" nil nil))
    (is-equal (mirror-state m) "abc|abc")
    (is (mirror-search m "bc" nil t))
    (is-equal (mirror-state m) "abcabc|")
    (is (not (mirror-search m "bc" nil t)))
    (is (mirror-search m "bc" t nil))
    (is-equal (mirror-state m) "abca|bc")
    (is (mirror-search m "bc" t t))
    (is-equal (mirror-state m) "a|bcabc")
    (is (not (mirror-search m "bc" t t)))
    (is-equal (mirror-state m) "a|bcabc")))

(deftest mirror-search-edge-cases
  (let ((m (mirror-from "ab|")))
    (is (not (mirror-search m "abc" nil nil)))
    (is (not (mirror-search m "x" t nil)))
    ;; A backwards search may end just before the point's character
    (is (mirror-search m "ab" t nil))
    (is-equal (mirror-state m) "|ab")
    ;; The empty pattern matches at the point
    (is (mirror-search m "" nil nil))
    (is-equal (mirror-state m) "|ab"))
  (let ((m (make-mirror)))
    (is (not (mirror-search m "a" nil nil)))
    (is (not (mirror-search m "a" t nil)))))

;;; --- the fake document is the mirror with a recorder ------------------

(deftest fake-document-runs-on-a-mirror
  (let ((doc (make-fake (format nil "ab|c~%d"))))
    (is (mirror-p (fake-mirror doc)))
    (is-equal (fake-text doc) (format nil "abc~%d"))
    (is-equal (fake-point doc) 2)
    (doc-insert doc "X")
    (is-equal (fake-state doc) (format nil "abX|c~%d"))
    (is (doc-modified-p doc))
    (is (doc-edit doc :undo))
    (is-equal (fake-state doc) (format nil "ab|c~%d"))
    (is (doc-move doc :down))
    (is-equal (fake-state doc) (format nil "abc~%d|"))
    (setf (fake-point doc) 0)
    (is (doc-search doc "d" nil nil))
    (is-equal (doc-point doc) 5)
    (doc-set-text doc "fresh")
    (is-equal (fake-state doc) "|fresh")
    (is (not (doc-modified-p doc)))))
