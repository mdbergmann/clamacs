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

;;; What the phase-4 leg breaks on purpose.  Defined here, not typed at the
;;; prompt, so no string has to travel through INSERT's ReadArgs template:
;;; (dbg-fn 3 4) opens the debugger with ARG0 = 3 and LOCAL3 = 12 in frame
;;; 0, (dbg-go-on) offers a CONTINUE restart and answers :WENT-ON.
(defun dbg-fn (a b)
  (let ((c (* a b)))
    (error "bad ~a" c)))

(defun dbg-go-on ()
  (cerror "Go on" "stop here")
  :went-on)
