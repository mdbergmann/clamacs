;;;; package.lisp -- the CLAMACS package.
;;;;
;;;; Clamacs in Lisp (specs/clamacs-lisp.md).  The files under lisp/ fall in
;;;; two halves, and the split is a design rule, not an accident:
;;;;
;;;;   - the PURE modules (keymap, rawkey, command, bindings, killring,
;;;;     minihist, locstack, token, sexp, indent) take no MUI and no OS
;;;;     types.  They load on the host and tests/test-*.lisp runs them there
;;;;     under ../build/host/clamiga, again with CLAMIGA_GC_STRESS=1;
;;;;   - the frontend (frontend-mui.lisp and what sits on it) is the only
;;;;     place that names AMIGA.MUI.
;;;;
;;;; Conventions of the pure modules: a buffer is a SIMPLE-STRING and a
;;;; position is a character index into it; "not possible" is NIL, never -1;
;;;; scans are declared loops over SCHAR (the runtime's string-scan opcodes),
;;;; never generic sequence functions on a per-key path.

(defpackage :clamacs
  (:use :cl)
  (:export #:define-command
           #:command-name
           #:find-command
           #:make-keymap
           #:keymap-bind-seq
           #:global-keymap
           #:lisp-keymap
           #:repl-keymap
           #:in-editor))
