;;; warm.lisp -- compile what the Lisp editor and the target clamiga load,
;;; so the acceptance run on a real machine (run-lisp-drive) starts from a
;;; warm FASL cache: drive.rexx waits 15 s for the target's port and the
;;; editor's window, which a cold cache outlasts on any 68k.
(require "amiga/arexx")
(load "Clamacs:lisp/load.lisp")
(format t "WARM-DONE~%")
