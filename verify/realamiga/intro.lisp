;;; intro.lisp -- what the phase-2 leg of drive.rexx asks clamiga about.
;;;
;;; The script loads this into clamiga (C-c C-k) and then points every
;;; introspection command at these definitions, so each answer is known in
;;; advance.  Line numbers matter: SOURCE-LOCATION must report the line of
;;; the DEFUN, and the script goes to the forms below by line number.
(in-package :cl-user)

(defun twice (n)
  "Twice N."
  (* n 2))

(defun twice-again (n)
  (twice (twice n)))

(defmacro with-twice (var n &body body)
  `(let ((,var (twice ,n))) ,@body))

(defmacro twice-of (n)
  `(with-twice z ,n z))

(twice-of 4)

(twice 21)
