;;; arexx-host.lisp -- the clamiga side of the clamacs integration test.
;;;
;;; This is what a user's S:.clamigarc does, minus the interactive REPL: open
;;; the development port and stay alive so the editor has something to talk
;;; to.  Loaded with --non-interactive, so the SLEEP is what keeps the
;;; process (and the port) around for the duration of the run.

(require "amiga/arexx")

(let ((port (amiga.arexx:start)))
  (format t "CLAMIGA-PORT ~a~%" port)
  (finish-output))

;; Long enough for the editor's tests -- the phase-1 integration leg and the
;; phase-2 leg after it, each waiting on replies half a second at a time --
;; and short enough that a run which loses its watchdog still ends.
(sleep 480)
