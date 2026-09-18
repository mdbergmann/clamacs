;;;; load.lisp -- load the editor's files in order, from wherever this
;;;; file sits.  (load "lisp/load.lisp") is the one entry point for the
;;;; tests, the image script and a developer's REPL.

;;; DEFVAR, so a caller may bind the list first and load a subset.
(defvar cl-user::*clamacs-pure-files*
  '("package" "keymap" "rawkey" "minihist" "command" "bindings"
    "killring" "locstack"
    "token" "sexp" "indent"
    "frontend" "commands" "minibuffer" "files"))

;;; The frontend: the MUI one on an Amiga, none on the host (the tests
;;; bring their own, tests/fake-frontend.lisp).  Bind it to NIL to load
;;; the pure modules alone on an Amiga too.
(defvar cl-user::*clamacs-frontend-files*
  #+amigaos '("frontend-mui")
  #-amigaos '())

(let ((here (or *load-truename* *load-pathname*)))
  (dolist (name (append cl-user::*clamacs-pure-files*
                        cl-user::*clamacs-frontend-files*))
    (load (merge-pathnames (concatenate 'string name ".lisp") here))))
