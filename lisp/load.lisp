;;;; load.lisp -- load the editor's files in order, from wherever this
;;;; file sits.  (load "lisp/load.lisp") is the one entry point for the
;;;; tests, the image script and a developer's REPL.

;;; DEFVAR, so a caller may bind the list first and load a subset.
(defvar cl-user::*clamacs-pure-files*
  '("package" "keymap" "rawkey" "minihist" "command" "bindings"
    "killring" "locstack"
    "token" "sexp" "indent"))

(let ((here (or *load-truename* *load-pathname*)))
  (dolist (name cl-user::*clamacs-pure-files*)
    (load (merge-pathnames (concatenate 'string name ".lisp") here))))
