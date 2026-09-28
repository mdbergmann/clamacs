;;;; shots.lisp -- the host editor's screenshots for the README, taken from
;;;; the running editor over its own port: a sibling of drive.lisp (whose
;;;; protocol helpers it loads) that walks the editor through the states
;;;; the README shows and photographs each one with `screencapture'.
;;;;
;;;;   verify/host/shots.sh [OUT-DIR]     starts the editor and runs this
;;;;
;;;; The environment is drive.lisp's (CLAMACS_DRIVE_DIR and friends), plus
;;;;
;;;;   CLAMACS_SHOTS_OUT   the directory the PNGs go to
;;;;   CLAMACS_SHOTS_PID   the editor's process id: the window is brought
;;;;                       to the front before every picture
;;;;   CLAMACS_SHOTS_LEDGER  where shots.sh copied the two fixtures
;;;;
;;;; macOS only (the pictures are the Mac editor's): screencapture needs
;;;; the Screen Recording permission for the terminal the script runs in.
;;;; The lines printed are drive.lisp's OK/FAIL/INFO lines; shots.sh greps
;;;; them.

(load (concatenate 'string (ext:getenv "CLAMACS_DRIVE_ROOT") "verify/host/drive.lisp"))

(in-package :clamacs-drive)

(defvar *out* (or (ext:getenv "CLAMACS_SHOTS_OUT") (error "CLAMACS_SHOTS_OUT is not set")))
(defvar *pid* (or (ext:getenv "CLAMACS_SHOTS_PID") (error "CLAMACS_SHOTS_PID is not set")))
(defvar *ledger* (or (ext:getenv "CLAMACS_SHOTS_LEDGER") (error "CLAMACS_SHOTS_LEDGER is not set")))

(defun shots-file (name)
  (concatenate 'string *ledger* "/" name))

(defun words (string)
  (let ((words '()) (start nil))
    (dotimes (i (length string))
      (if (char= (char string i) #\Space)
          (when start (push (subseq string start i) words) (setq start nil))
          (unless start (setq start i))))
    (when start (push (subseq string start) words))
    (nreverse words)))

(defun front ()
  "The editor's window to the front: what screencapture photographs is
whatever is on the screen there."
  (ext:system-command
   (format nil "osascript -e 'tell application \"System Events\" to set frontmost of (first process whose unix id is ~A) to true' >/dev/null 2>&1"
           *pid*)))

(defun shot (name)
  "The active document's window, as it is, to NAME.png under *OUT*."
  (front)
  (pause 60)                            ; the page settles, the raise lands
  (cmd "GETWINDOW")
  (let ((frame (mapcar (lambda (w) (parse-integer w :junk-allowed t)) (rest (words *result*))))
        (path (format nil "~A/~A.png" *out* name)))
    (cond ((or (/= *rc* 0) (/= (length frame) 4) (some #'null frame))
           (fail "~A: GETWINDOW gave ~A" name *result*))
          ((zerop (ext:system-command
                   (format nil "screencapture -x -R ~{~D~^,~} ~S" frame path)))
           (ok "shot ~A (~{~D~^ ~})" path frame))
          (t (fail "screencapture failed for ~A (no Screen Recording permission?)" path)))))

(defun repl-form (text needle ticks)
  "TEXT at the REPL prompt, RET, and wait for NEEDLE among the lines the
answer took, above the new prompt."
  (cmd "EVAL end-of-buffer")
  (let ((p (cursor-line)))
    (cmd (concatenate 'string "INSERT " text))
    (cmd "KEY RET")
    (let ((y (wait-cursor-past (1+ p) ticks)))
      (if (and y (loop for i from (+ p 2) to y
                       do (cmd (format nil "GOTOLINE ~D" i))
                       thereis (search needle (get-line))))
          (ok "~A -> ~A" text (string-trim " " (get-line)))
          (fail "~A did not answer with ~A; the lines after it are ~A" text needle
                (progn (cmd "TE GETLINE") *result*)))))
  (cmd "EVAL end-of-buffer"))

(defun place ()
  (cmd "EVAL (clamacs::set-window-frame (clamacs::host-editor-main clamacs::*editor*) 80 60 1100 760)")
  (cmd "THEMES Light")
  (cmd "MINIMAP")
  (unless (member "> Minimap" (result-lines) :test #'string=)
    (cmd "MINIMAP Minimap")))

(defun shots ()
  (setq *port* (connect 60))
  (when (null *port*)
    (fail "no clamacs port appeared under ~A" *dir*)
    (return-from shots nil))
  (place)
  ;; The clamiga behind the editor, and the ledger loaded into it.
  (cmd "MENU run-lisp")
  (cmd "STATUS")
  (if (string= *result* "Started clamiga")
      (ok "Start clamiga: ~A" *result*)
      (fail "Start clamiga said ~A" *result*))
  (cmd (format nil "OPEN FILE ~A" (shots-file "accounts.lisp")))
  (cmd "EVAL clamacs-load-buffer")
  (if (string/= (wait-echo "0 error(s)" 240) "")
      (ok "accounts.lisp loaded: ~A" *result*)
      (fail "loading accounts.lisp said ~A" *result*))
  ;; The REPL in the dock, talking to it.
  (cmd "KEY C-c C-z")
  (if (string/= (wait-line "CL-USER> " 240) "")
      (ok "the REPL is up")
      (fail "no REPL prompt; the cursor line is ~A" (get-line)))
  (repl-form "(defparameter *acct* (open-account \"Ada\" 100))" "*ACCT*" 40)
  (repl-form "(deposit *acct* 50)" "150" 40)
  (repl-form "(statement *acct*)" "150" 40)
  ;; Back in the source, a defun re-evaluated (its note lands in the
  ;; transcript) and the cursor inside a call of DEPOSIT, for the arglist.
  (cmd (format nil "OPEN FILE ~A LINE 31" (shots-file "accounts.lisp")))
  (cmd "EVAL clamacs-eval-defun")
  (if (string/= (wait-echo "DEPOSIT" 40) "")
      (ok "C-c C-c on DEPOSIT: ~A" *result*)
      (fail "C-c C-c on DEPOSIT said ~A" *result*))
  (cmd "GOTOLINE 28")
  (cmd "TE POSITION SOL")
  (cmd (format nil "KEY ~{~A~^ ~}" (make-list 15 :initial-element "C-f")))
  (cmd "EVAL clamacs-arglist")
  (if (string/= (wait-echo "(deposit" 20) "")
      (ok "the arglist is up: ~A" *result*)
      (info "no arglist in the echo area: ~A" *result*))
  (shot "host-editor")
  ;; An overdraft opens the debugger.
  (cmd "EVAL clamacs-repl")
  (cmd "EVAL end-of-buffer")
  (cmd "INSERT (withdraw *acct* 500)")
  (cmd "KEY RET")
  (if (string/= (wait-echo "Debugger level 1" 60) "")
      (ok "the debugger opened: ~A" *result*)
      (fail "no debugger; the echo area says ~A" *result*))
  (panel-state :debugger "frame 0 locals ")
  (shot "host-debugger")
  (cmd "EVAL clamacs-debugger-abort")
  (if (string/= (wait-line "CL-USER> " 40) "")
      (ok "Abort returned to the prompt")
      (fail "no prompt after Abort"))
  ;; The inspector on the account.
  (cmd "KEY C-c I")
  (cmd "KEY * a c c t * RET")
  (if (string/= (wait-echo "Inspecting" 40) "")
      (ok "the inspector opened: ~A" *result*)
      (fail "no inspector; the echo area says ~A" *result*))
  (shot "host-inspector")
  (cmd "EVAL clamacs-repl")
  ;; A file with mistakes: the diagnostics, the first one visited.
  (cmd (format nil "OPEN FILE ~A" (shots-file "report.lisp")))
  (cmd "EVAL clamacs-load-buffer")
  (if (string/= (wait-echo "error(s)" 120) "")
      (ok "report.lisp loaded with diagnostics: ~A" *result*)
      (fail "loading report.lisp said ~A" *result*))
  (cmd "EVAL clamacs-next-error")
  (pause 25)
  (shot "host-diagnostics")
  ;; A dark theme, the REPL back in the dock, and M-x with its
  ;; completion list.
  (cmd "THEMES One Dark")
  (cmd "EVAL clamacs-repl")
  (cmd "EVAL clamacs-repl-clear")
  (repl-form "(withdraw *acct* 30)" "120" 40)
  (cmd (format nil "OPEN FILE ~A LINE 36" (shots-file "accounts.lisp")))
  (cmd "KEY M-x")
  (cmd "KEY c l a m a c s - e v a l TAB")
  (if (string/= (wait-echo "completions" 20) "")
      (ok "M-x lists the candidates: ~A" *result*)
      (fail "M-x TAB said ~A" *result*))
  (shot "host-completion")
  (cmd "KEY C-g")
  (say "SHOTS-DONE"))

(unwind-protect
     (handler-case (shots)
       (error (e)
         (fail "the shots run itself failed: ~A" e)))
  (when *port* (quit-editor)))
(finish-output)
(cl-user::quit 0)
