;;;; verify-editor-image.lisp -- prove a clamacs.img starts the editor.
;;;;
;;;;   clamiga --no-userinit --non-interactive --heap 8M --image bin/aos3/clamacs.img
;;;;       --load lib/clamacs/verify-editor-image.lisp
;;;;
;;;; Checks that the session came from an image and holds the editor, then
;;;; runs the editor unattended: a hook on the first windows asks it to
;;;; quit, so START opens a document window, builds the menu strip, runs
;;;; one turn of its loop and tears everything down.  Prints
;;;; EDITOR-IMAGE-VERIFIED and exits 0 on success, else one
;;;; EDITOR-IMAGE-FAILED line per failed check and exit status 1.  Needs
;;;; MUI: run in FS-UAE (cl-amiga's verify/realamiga/make-editor-image.sh)
;;;; or on a machine.  Counterpart of save-editor-image.lisp.

(defvar *editor-image-failures* 0)

(defmacro editor-image-check (what form)
  `(let ((result (handler-case ,form
                   (error (e)
                     (format t "EDITOR-IMAGE-FAILED: ~a signalled: ~a~%" ,what e)
                     :signalled))))
     (cond ((eq result :signalled) (incf *editor-image-failures*))
           ((not result)
            (incf *editor-image-failures*)
            (format t "EDITOR-IMAGE-FAILED: ~a~%" ,what)))))

(format t "IMAGE-RESTORED-P ~a~%" ext:*image-restored-p*)
(format t "IMAGE-VERSION ~a~%" (lisp-implementation-version))

(editor-image-check "no image was restored - the session booted from the FASLs instead"
                    ext:*image-restored-p*)
(editor-image-check "the image does not hold the editor (no CLAMACS package)"
                    (find-package :clamacs))
(editor-image-check "the editor's entry points are missing from the image"
                    (and (fboundp (find-symbol "RUN" :clamacs))
                         (fboundp (find-symbol "START" :clamacs))))

;;; Where the editor looks for the user's files.  The release compiles the
;;; FASLs with the HOST binary, so a choice the source makes at read time
;;; (`#+amigaos') is the host's, not the Amiga's: the image would then hold
;;; ~/.clamacsrc and ~/.clamacs-windows.cfg, the init file would never load
;;; and a snapshot would never persist.  This script only runs on the target.
(editor-image-check "*INIT-FILE* is not S:.clamacsrc (settled when the FASLs were compiled?)"
                    (equal (symbol-value (find-symbol "*INIT-FILE*" :clamacs))
                           "S:.clamacsrc"))
(editor-image-check "*SNAPSHOT-FILES* is not ENV:/ENVARC:Clamacs/windows.cfg (settled when the FASLs were compiled?)"
                    (equal (symbol-value (find-symbol "*SNAPSHOT-FILES*" :clamacs))
                           '("ENV:Clamacs/windows.cfg" "ENVARC:Clamacs/windows.cfg")))

(defvar *editor-image-windows* 0)

(when (find-package :clamacs)
  ;; The editor runs one turn: once its first window is open, the hook
  ;; counts the documents and asks for a quit that discards nothing (the
  ;; buffer is empty), and START returns when the last window is gone.
  (push (lambda (editor)
          (setf *editor-image-windows*
                (length (funcall (find-symbol "LIVE-DOCUMENTS" :clamacs) editor)))
          (setf (symbol-value (find-symbol "*MENU-STRIP-BUILT*" :cl-user))
                (and (funcall (find-symbol "MUI-EDITOR-MENUSTRIP" :clamacs) editor) t))
          (funcall (fdefinition (list 'setf (find-symbol "EDITOR-QUITTING" :clamacs)))
                   :discard editor))
        (symbol-value (find-symbol "*AFTER-START-HOOKS*" :clamacs)))
  (defvar cl-user::*menu-strip-built* nil)
  (editor-image-check "START did not run to a clean return"
                      (eq t (funcall (find-symbol "START" :clamacs))))
  (editor-image-check "no document window was opened"
                      (= *editor-image-windows* 1))
  (editor-image-check "the menu strip was not built"
                      cl-user::*menu-strip-built*))

(finish-output)
(cond ((zerop *editor-image-failures*)
       (format t "EDITOR-IMAGE-VERIFIED~%")
       (finish-output))
      (t
       (format t "EDITOR-IMAGE-FAILED: ~a check(s) failed~%" *editor-image-failures*)
       (finish-output)
       (quit 1)))
