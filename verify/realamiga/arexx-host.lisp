;;; arexx-host.lisp -- the clamiga side of the clamacs integration test.
;;;
;;; This is what a user's S:.clamigarc does, minus the interactive REPL: open
;;; the development port and stay alive so the editor has something to talk
;;; to.  Loaded with --non-interactive, so the wait below is what keeps the
;;; process (and the port) around for the duration of the run.

(require "amiga/arexx")

;; quit.rexx sets this through the port (`EVAL (setf cl-user::*clamacs-host-quit* t)')
;; once the editor has gone, and the main thread then takes the port down
;; and lets the process end.  Before this the host slept out its deadline,
;; and every run-drive left a clamiga behind for the rest of it.
(defvar *clamacs-host-quit* nil)

;; quit.rexx reads this file for the exact port name to message instead of
;; scanning CLAMIGA/CLAMIGA.1-9: SHOW('P', name) only proves a port is still
;; registered, not that the task behind it is alive, and messaging a port
;; whose task has already died hangs the sender forever (see CLAUDE.md,
;; "Never let a clamiga exit with its port thread alive").  Restricting the
;; send to the one port this run itself opened keeps a stale port left by an
;; unrelated earlier run out of reach.
(defparameter *clamacs-host-port-file* "T:clamacs-clamiga-port")

(let ((port (amiga.arexx:start)))
  (format t "CLAMIGA-PORT ~a~%" port)
  (finish-output)
  (with-open-file (s *clamacs-host-port-file*
                      :direction :output :if-exists :supersede)
    (write-line port s)))

;; The deadline is long enough for the editor's tests -- the phase-1
;; integration leg, the phase-2 leg and the phase-3 REPL leg after it (whose
;; first REPL-ATTACH compiles dev-repl and the gray streams from source on a
;; cold FASL cache), each waiting on replies half a second at a time -- and
;; short enough that a run which loses its watchdog still ends.
(loop repeat 900
      until *clamacs-host-quit*
      do (sleep 1))

(format t "CLAMIGA-HOST ~a~%" (if *clamacs-host-quit* "quit requested" "deadline"))
(finish-output)
(ignore-errors (delete-file *clamacs-host-port-file*))
(amiga.arexx:stop)
