;;;; test-symcache.lisp -- the arglist cache: tests/test_symcache.c.

(in-package :clamacs)

(deftest unknown-miss-and-hit-are-three-different-answers
  (let ((c (make-symcache)))
    ;; Never asked: NIL, the one case that costs a round trip.
    (is (null (symcache-get c "CL-USER|foo")))
    (is (symcache-put c "CL-USER|foo" "(a &optional b)"))
    (is-equal (symcache-get c "CL-USER|foo") "(a &optional b)")
    ;; Asked, and clamiga had nothing: "" -- remembered so the cursor
    ;; entering a binding list does not ask about `x' every time.
    (is (symcache-put c "CL-USER|x" ""))
    (is-equal (symcache-get c "CL-USER|x") "")
    (is (symcache-put c "CL-USER|y" nil))
    (is-equal (symcache-get c "CL-USER|y") "")
    (symcache-clear c)
    (is (null (symcache-get c "CL-USER|foo")))
    (is-equal (symcache-count c) 0)))

(deftest keys-are-symbols-so-case-does-not-matter
  (let ((c (make-symcache)))
    (symcache-put c "cl-user|Mapcar" "(fn list &rest more)")
    (is-equal (symcache-get c "CL-USER|MAPCAR") "(fn list &rest more)")
    (is-equal (symcache-get c "Cl-User|mapcar") "(fn list &rest more)")
    ;; A package is part of the key: the same name elsewhere is another
    ;; symbol.
    (is (null (symcache-get c "FOO|mapcar")))))

(deftest putting-again-updates-in-place
  (let ((c (make-symcache)))
    (symcache-put c "P|f" "(a)")
    (symcache-put c "P|f" "(a b)")     ; redefined with more arguments
    (is-equal (symcache-get c "P|f") "(a b)")
    (is-equal (symcache-count c) 1)))  ; one slot used, not two

(deftest the-oldest-entry-goes-first
  (let ((c (make-symcache)))
    (dotimes (i (+ +symcache-size+ 5))
      (is (symcache-put c (format nil "P|sym~D" i) "(x)")))
    (is-equal (symcache-count c) +symcache-size+)
    ;; The first five were replaced; the rest are still there.
    (dotimes (i 5)
      (is (null (symcache-get c (format nil "P|sym~D" i)))))
    (loop for i from 5 below (+ +symcache-size+ 5)
          do (is (symcache-get c (format nil "P|sym~D" i))))
    ;; Updating an old entry does not make it young: sym5 is next to go.
    (symcache-put c "P|sym5" "(y)")
    (symcache-put c "P|new" "(z)")
    (is (null (symcache-get c "P|sym5")))
    (is-equal (symcache-get c "P|new") "(z)")))

(deftest junk-keys-are-refused
  (let ((c (make-symcache)))
    (is (null (symcache-put c "" "(x)")))
    (is (null (symcache-put c nil "(x)")))
    (is (null (symcache-get c "")))
    (is (null (symcache-get c nil)))
    (is-equal (symcache-count c) 0)))
