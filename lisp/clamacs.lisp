;;;; clamacs.lisp -- run the editor from source.
;;;;
;;;;   clamiga --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- file ...
;;;;
;;;; Loads the editor (lisp/load.lisp) and starts it on the program's own
;;;; arguments: what follows `--' on clamiga's command line (a bare argument
;;;; before it is a --load, so the files need the separator), or, started
;;;; from a Workbench icon, the full path of every project icon -- both are
;;;; EXT:*COMMAND-LINE-ARGS*, set before this file runs.  No files: one
;;;; unnamed Lisp buffer.  The user's init file (S:.clamacsrc) is loaded
;;;; first, so its commands and bindings are there for the first window.
;;;; The image (scripts/save-editor-image.lisp) replaces the --load with
;;;; `clamiga --image clamacs.img', whose restore hook calls RUN the same
;;;; way.

(load (merge-pathnames "load.lisp" (or *load-truename* *load-pathname*)))

(clamacs::run)
