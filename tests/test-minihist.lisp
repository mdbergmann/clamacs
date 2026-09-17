;;;; test-minihist.lisp -- minibuffer history and generic completion.  The
;;;; cases of tests/test_minihist.c.

(in-package :clamacs)

(deftest hist-empty-history
  (let ((h (make-history)))
    (is-equal (hist-prev h) nil)
    (is-equal (hist-next h) nil)
    (is-equal (hist-nth h 0) nil)
    (is-equal (hist-nth h -1) nil)))

(deftest hist-add-and-walk
  (let ((h (make-history)))
    (hist-add h "first")
    (hist-add h "second")
    (hist-add h "third")
    (is-equal (hist-prev h) "third")
    (is-equal (hist-prev h) "second")
    (is-equal (hist-prev h) "first")
    (is-equal (hist-prev h) nil)        ; the end of the ring
    (is-equal (hist-next h) "second")
    (is-equal (hist-next h) "third")
    (is-equal (hist-next h) nil)        ; back to what was being typed
    ;; And M-p starts from the newest again.
    (is-equal (hist-prev h) "third")
    (hist-prev h)
    (hist-reset h)
    (is-equal (hist-prev h) "third")))

(deftest hist-repeats-and-blanks-are-dropped
  (let ((h (make-history)))
    (hist-add h "same")
    (hist-add h "same")
    (hist-add h "")
    (hist-add h nil)
    (is-equal (hist-count h) 1)
    ;; Only a repeat of the NEWEST entry is dropped.
    (hist-add h "other")
    (hist-add h "same")
    (is-equal (hist-count h) 3)))

(deftest hist-adding-resets-the-cursor
  (let ((h (make-history)))
    (hist-add h "a")
    (hist-add h "b")
    (hist-prev h)
    (hist-add h "c")
    (is-equal (hist-prev h) "c")
    ;; A dropped entry resets it too.
    (hist-prev h)
    (hist-add h "c")
    (is-equal (hist-prev h) "c")))

(deftest hist-wraps
  (let ((h (make-history))
        (last nil))
    (dotimes (i (+ +hist-size+ 4))
      (setq last (format nil "a~D" i))
      (hist-add h last))
    (is-equal (hist-count h) +hist-size+)
    (is-equal (hist-nth h 0) last)
    (is-equal (hist-nth h (1- +hist-size+)) "a4")
    (is-equal (hist-nth h +hist-size+) nil)
    (hist-clear h)
    (is-equal (hist-count h) 0)))

(defparameter *completion-files*
  '("boot.lisp" "boot.fasl" "clos.lisp" "ffi.lisp" "dev-commands.lisp"))

(defun completions (candidates prefix)
  (multiple-value-list (complete candidates prefix)))

(deftest completion-common-prefix
  (is-equal (completions *completion-files* "boot")
            '(("boot.lisp" "boot.fasl") "boot."))
  ;; A unique match completes fully.
  (is-equal (completions *completion-files* "c") '(("clos.lisp") "clos.lisp"))
  ;; Everything matches the empty prefix, in table order, with nothing in
  ;; common.
  (is-equal (completions *completion-files* "") (list *completion-files* ""))
  (is-equal (completions *completion-files* nil) (list *completion-files* ""))
  (is-equal (completions *completion-files* "zz") '(() "")))

(deftest completion-edges
  ;; A candidate that IS the prefix, and one shorter than it.
  (is-equal (completions '("map" "mapc" "ma") "map") '(("map" "mapc") "map"))
  ;; Case matters.
  (is-equal (completions '("Boot" "boot") "b") '(("boot") "boot"))
  ;; A NIL among the candidates is skipped.
  (is-equal (completions '(nil "abc" nil "abd") "a") '(("abc" "abd") "ab")))

(deftest completion-handles-no-candidates
  (is-equal (completions '() "x") '(() "")))

(deftest split-lines-from-a-reply
  ;; COMPLETE answers one candidate per line; the last line may or may not
  ;; end in a newline, and an Amiga reply can carry CR.
  (let ((items (split-lines (format nil "mapc~C~%mapcan~%mapcar" #\Return))))
    (is-equal items '("mapc" "mapcan" "mapcar"))
    ;; ... and the list is what COMPLETE takes.
    (is-equal (completions items "mapca") '(("mapcan" "mapcar") "mapca")))
  ;; Blank lines are skipped; trailing spaces go; empty is empty.
  (is-equal (split-lines (format nil "~%~%only~%~%")) '("only"))
  (is-equal (split-lines (format nil "a  ~% ~%b~C ~C~%" #\Return #\Return))
            '("a" "b"))
  (is-equal (split-lines "") '())
  (is-equal (split-lines nil) '()))
