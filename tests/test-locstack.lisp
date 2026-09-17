;;;; test-locstack.lisp -- where `M-,' goes back to.  The cases of
;;;; tests/test_locstack.c (a path is not cut in Lisp: no fixed buffer).

(in-package :clamacs)

(deftest locstack-empty-stack
  (let ((s (make-locstack)))
    (is-equal (locstack-depth s) 0)
    (is-equal (locstack-pop s) nil)
    (is-equal (locstack-depth s) 0)))

(deftest locstack-last-in-first-out
  (let ((s (make-locstack)))
    (locstack-push s "Work:a.lisp" 1 10)
    (locstack-push s "Work:b.lisp" 2 20)
    (is-equal (locstack-depth s) 2)
    (let ((loc (locstack-pop s)))
      (is-equal (location-path loc) "Work:b.lisp")
      (is-equal (location-id loc) 2)
      (is-equal (location-index loc) 20))
    (let ((loc (locstack-pop s)))
      (is-equal (location-path loc) "Work:a.lisp")
      (is-equal (location-index loc) 10))
    (is-equal (locstack-pop s) nil)))

(deftest locstack-a-scratch-window-has-no-path
  (let ((s (make-locstack)))
    (locstack-push s nil 7 0)
    (let ((loc (locstack-pop s)))
      (is-equal (location-path loc) nil)
      (is-equal (location-id loc) 7))))

(deftest locstack-overflow-drops-the-oldest
  (let ((s (make-locstack)))
    (dotimes (i (+ +locstack-size+ 3))
      (locstack-push s "f" i i))
    (is-equal (locstack-depth s) +locstack-size+)
    ;; The newest are all there, in order ...
    (loop for i from (+ +locstack-size+ 2) downto 3
          do (is-equal (location-index (locstack-pop s)) i))
    ;; ... and the three oldest are gone.
    (is-equal (locstack-pop s) nil)))
