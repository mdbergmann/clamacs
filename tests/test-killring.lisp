;;;; test-killring.lisp -- the kill ring.  The cases of tests/test_killring.c.

(in-package :clamacs)

(deftest kill-empty-ring-yanks-nothing
  (let ((r (make-killring)))
    (is-equal (kill-current r) nil)
    (is-equal (kill-rotate r) nil)
    (is-equal (kill-count r) 0)))

(deftest kill-push-and-yank
  (let ((r (make-killring)))
    (kill-push r "one")
    (is-equal (kill-current r) "one")
    (kill-push r "two")
    (is-equal (kill-current r) "two")
    (is-equal (kill-count r) 2)
    (kill-clear r)
    (is-equal (kill-count r) 0)
    (is-equal (kill-current r) nil)))

(deftest kill-consecutive-kills-join
  (let ((r (make-killring)))
    ;; Three C-k on the same line make one entry, so C-y brings the whole
    ;; line back rather than its last third.
    (kill-push r "one ")
    (kill-append r "two ")
    (kill-append r "three")
    (is-equal (kill-current r) "one two three")
    (is-equal (kill-count r) 1)))

(deftest kill-backward-kills-join-at-the-front
  (let ((r (make-killring)))
    ;; M-DEL twice kills "two " then "one ", and the yank must read
    ;; forwards.
    (kill-push r "two ")
    (kill-prepend r "one ")
    (is-equal (kill-current r) "one two ")))

(deftest kill-append-to-empty-ring-pushes
  (let ((r (make-killring)))
    (kill-append r "x")
    (is-equal (kill-current r) "x")
    (is-equal (kill-count r) 1))
  (let ((r (make-killring)))
    (kill-prepend r "y")
    (is-equal (kill-current r) "y")))

(deftest kill-extending-joins-the-newest-entry-only
  (let ((r (make-killring)))
    (kill-push r "old")
    (kill-push r "new")
    ;; Even while M-y has rotated back, a kill extends the newest entry and
    ;; the rotation starts over.
    (kill-rotate r)
    (kill-append r "er")
    (is-equal (kill-current r) "newer")
    (is-equal (kill-rotate r) "old")))

(deftest kill-yank-pop-walks-back
  (let ((r (make-killring)))
    (kill-push r "first")
    (kill-push r "second")
    (kill-push r "third")
    (is-equal (kill-current r) "third")
    (is-equal (kill-rotate r) "second")
    (is-equal (kill-rotate r) "first")
    ;; And wraps.
    (is-equal (kill-rotate r) "third")
    ;; Anything that is not a yank starts over at the newest kill.
    (kill-rotate r)
    (kill-reset-yank r)
    (is-equal (kill-current r) "third")))

(deftest kill-a-new-kill-resets-the-rotation
  (let ((r (make-killring)))
    (kill-push r "a")
    (kill-push r "b")
    (kill-rotate r)
    (is-equal (kill-current r) "a")
    (kill-push r "c")
    (is-equal (kill-current r) "c")))

(deftest kill-ring-wraps-and-drops-the-oldest
  (let ((r (make-killring))
        (n (+ +kill-ring-size+ 5)))
    (dotimes (i n)
      (kill-push r (string (code-char (+ 97 (mod i 26))))))
    (is-equal (kill-count r) +kill-ring-size+)
    ;; Rotating all the way round comes home without ever leaving the ring,
    ;; and passes the oldest survivor on the way.
    (dotimes (i (1- +kill-ring-size+))
      (is (kill-rotate r)))
    (is-equal (kill-current r) (string (code-char (+ 97 5))))
    (is (kill-rotate r))
    (is-equal (kill-current r) (string (code-char (+ 97 (mod (1- n) 26)))))))

(deftest kill-embedded-newlines-survive
  (let ((r (make-killring))
        (block (format nil "(defun foo ()~%  42)~%")))
    (kill-push r block)
    (is-equal (kill-current r) block)))

(deftest kill-entries-are-copies
  ;; The frontend hands over a buffer it reuses; the ring must not alias it.
  (let ((r (make-killring))
        (text (copy-seq "abc")))
    (kill-push r text)
    (setf (char text 0) #\X)
    (is-equal (kill-current r) "abc")))
