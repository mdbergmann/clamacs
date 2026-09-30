;;;; cpumeter.lisp -- how much CPU everything else takes, from the inside.
;;;;
;;;; AmigaOS has no per-task CPU accounting, so this is the meter every
;;;; Amiga CPU monitor is built on: a task at priority -5 counts how often
;;;; it gets to run.  In an idle system it gets nearly all of the CPU; a
;;;; task at priority 0 that is busy starves it.  Each window's count,
;;;; against the count of the quietest window, is the share left over.
;;;;
;;;;   clamiga --no-userinit --heap 4M --non-interactive --load cpumeter.lisp
;;;;
;;;; writes one line per WINDOW seconds to *LOG* -- "<seconds-since-start>
;;;; <count> <note>", the note being the contents of T:cpumeter-note when
;;;; that file exists (the driving script names the phase there) -- until
;;;; T:cpumeter-stop exists.  run-cpu-idle.sh reads it back.

(require "amiga/raw/exec")

(defvar *log* "Clamacs:build/amiga/cpumeter.log")
(defvar *window* 5)

(defun note ()
  (with-open-file (s "T:cpumeter-note" :if-does-not-exist nil)
    (if s (or (read-line s nil "") "") "")))

(defun stop-p ()
  (with-open-file (s "T:cpumeter-stop" :if-does-not-exist nil)
    (and s t)))

(amiga.raw.exec:set-task-pri (amiga.raw.exec:find-task nil) -5)

(let ((start (get-universal-time)))
  (with-open-file (out *log* :direction :output :if-exists :supersede)
    (format out "start window ~D s~%" *window*)
    (finish-output out)
    (loop
      (let* ((from (get-universal-time))
             (until (+ from *window*))
             (n 0))
        (declare (type fixnum n))
        (loop while (< (get-universal-time) until)
              do (incf n))
        (format out "~D ~D ~A~%" (- from start) n (note))
        (finish-output out))
      (when (stop-p)
        (format out "stop~%")
        (return)))))
