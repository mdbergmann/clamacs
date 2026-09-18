;;;; clamacs.lisp -- run the editor from source.
;;;;
;;;;   clamiga --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp
;;;;
;;;; Loads the editor (lisp/load.lisp) and starts it on the files named in
;;;; CL-USER::*CLAMACS-FILES* (bound by an --eval before this file, else an
;;;; unnamed Lisp buffer).  The image build and the command-line / Workbench
;;;; arguments of a later step replace this for the release.

(defvar cl-user::*clamacs-files* '())

(load (merge-pathnames "load.lisp" (or *load-truename* *load-pathname*)))

(clamacs::start :files cl-user::*clamacs-files*)
