;;;; load.lisp -- load the editor's files in order, from wherever this
;;;; file sits.  (load "lisp/load.lisp") is the one entry point for the
;;;; tests, the image script and a developer's REPL.
;;;;
;;;; A file's FASL beside it is taken when there is one and it is not older
;;;; than the source (the binary release ships lib/clamacs/ as sources plus
;;;; the FASLs compiled from them, so a `--no-image' start does not compile
;;;; the editor on a 68020); a checkout has none and loads the sources,
;;;; through LOAD's own cache.  A source edited after its FASL was written
;;;; wins, so a FASL left in lisp/ by a refresh never runs stale code.

;;; DEFVAR, so a caller may bind the list first and load a subset.
(defvar cl-user::*clamacs-pure-files*
  '("package" "keymap" "rawkey" "minihist" "command" "bindings"
    "killring" "locstack" "symcache" "winstore"
    "token" "sexp" "indent" "json" "textmirror"
    "frontend" "commands" "minibuffer" "files"
    "diag" "wire" "port" "mailbox" "introspect"
    "replmsg" "repl" "debugger" "inspector"
    "menu" "snapshot" "transport-self"))

;;; The frontend: the MUI one on an Amiga, with the ARexx transport and the
;;; editor's port behind it; none on the host (the tests bring their own,
;;; tests/fake-frontend.lisp and tests/fake-transport.lisp).  Bind it to
;;; NIL to load the pure modules alone on an Amiga too.
(defvar cl-user::*clamacs-frontend-files*
  #+amigaos '("frontend-mui" "transport-arexx")
  #-amigaos '())

;;; True: every file is COMPILE-FILEd to the FASL beside it and the FASL
;;; loaded -- how cl-amiga's release script builds lib/clamacs/*.fasl on
;;; the host (with CLAMIGA_FASL_PORTABLE=1 in the environment, so a string
;;; the Amiga could not load fails there), and how a developer refreshes
;;; them.  Bind it, do not set it: the tests load the sources.
(defvar cl-user::*clamacs-compile-fasls* nil)

(let ((here (or *load-truename* *load-pathname*)))
  (dolist (name (append cl-user::*clamacs-pure-files*
                        cl-user::*clamacs-frontend-files*))
    (let* ((fasl (merge-pathnames (concatenate 'string name ".fasl") here))
           (source (merge-pathnames (concatenate 'string name ".lisp") here))
           ;; NIL when there is no FASL; with no source to compare, it stands.
           (fasl-date (and (probe-file fasl) (file-write-date fasl)))
           (source-date (file-write-date source)))
      (cond (cl-user::*clamacs-compile-fasls*
             (load (compile-file source :output-file fasl)))
            ((and fasl-date (or (null source-date) (>= fasl-date source-date)))
             (load fasl))
            (t (load source))))))
