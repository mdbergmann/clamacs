(in-package :cl-user)

(defun frobnicate (x)
  "A sample function, so the editor has real Lisp to colour and navigate."
  (let ((y (* x 2)))
    (when (> y 10)
      (format t "~a is big~%" y))
    y))

(defvar *sample* 42)
