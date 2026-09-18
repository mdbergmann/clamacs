;;;; clamacs.lisp -- run the editor from source.
;;;;
;;;;   clamiga --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- file ...
;;;;
;;;; Loads the editor (lisp/load.lisp) and starts it on the program's own
;;;; arguments: what follows `--' on clamiga's command line (a bare argument
;;;; before it is a --load, so the files need the separator), or, started
;;;; from a Workbench icon, the full path of every project icon -- both are
;;;; EXT:*COMMAND-LINE-ARGS*, set before this file runs.  No files: one
;;;; unnamed Lisp buffer.  The image build of a later step replaces the
;;;; --load with `clamiga --image clamacs.img', whose restore hook calls
;;;; START the same way.

(load (merge-pathnames "load.lisp" (or *load-truename* *load-pathname*)))

(clamacs::start :files ext:*command-line-args*)
