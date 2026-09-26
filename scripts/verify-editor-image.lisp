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
;;;; EDITOR-IMAGE-FAILED line per failed check and exit status 1.
;;;; Counterpart of save-editor-image.lisp.
;;;;
;;;; The image tells which frontend it holds: the MUI one needs MUI (run in
;;;; FS-UAE by cl-amiga's verify/realamiga/make-editor-image.sh, or on a
;;;; machine) and is checked for the Amiga's paths and the shed binding
;;;; tables; the host one (specs/clamacs-host.md, H6; host/make-image.sh
;;;; runs this) needs a window server and is checked for re-deriving the
;;;; user's paths from THIS run's HOME, since the image was saved under
;;;; another.

(defvar *editor-image-failures* 0)

(defvar *editor-image-frontend*
  (cond ((and (find-package :clamacs)
              (fboundp (find-symbol "MUI-EDITOR-MENUSTRIP" :clamacs)))
         :mui)
        ((and (find-package :clamacs)
              (fboundp (find-symbol "%MAKE-HOST-EDITOR" :clamacs)))
         :host)
        (t nil))
  "Which frontend the image holds: :MUI, :HOST, or NIL for none.")

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
(editor-image-check "the image holds no frontend (neither the MUI nor the host editor)"
                    *editor-image-frontend*)
(format t "IMAGE-FRONTEND ~a~%" *editor-image-frontend*)

;;; Where the editor looks for the user's files.
(case *editor-image-frontend*
  (:mui
   ;; The release compiles the FASLs with the HOST binary, so a choice the
   ;; source makes at read time (`#+amigaos') is the host's, not the
   ;; Amiga's: the image would then hold ~/.clamacsrc and
   ;; ~/.clamacs-windows.cfg, the init file would never load and a snapshot
   ;; would never persist.  This branch only runs on the target.
   (editor-image-check "*INIT-FILE* is not S:.clamacsrc (settled when the FASLs were compiled?)"
                       (equal (symbol-value (find-symbol "*INIT-FILE*" :clamacs))
                              "S:.clamacsrc"))
   (editor-image-check "*SNAPSHOT-FILES* is not ENV:/ENVARC:Clamacs/windows.cfg (settled when the FASLs were compiled?)"
                       (equal (symbol-value (find-symbol "*SNAPSHOT-FILES*" :clamacs))
                              '("ENV:Clamacs/windows.cfg" "ENVARC:Clamacs/windows.cfg")))
   ;; The binding tables of the amiga/raw/* modules the frontend loads are
   ;; shed (save-editor-image.lisp's :shake-bindings): one still attached
   ;; is its whole OS module's names back in the image, tens of KB each.
   (let ((lazy (remove-if-not #'clamiga::%binding-table-info (list-all-packages))))
     (editor-image-check "the image holds no amiga/raw binding module (the MUI frontend loads seven)"
                         lazy)
     (editor-image-check "a binding table was not shed (was the image saved without :shake-bindings?)"
                         (every (lambda (p) (getf (clamiga::%binding-table-info p) :shed))
                                lazy))))
  (:host
   ;; The paths are the saving machine's until RUN re-derives them
   ;; (REFRESH-USER-PATHS); host/make-image.sh verifies under a HOME of its
   ;; own, so the re-derived paths must be under THIS home, and the image's
   ;; must not have been (else the check proves nothing).
   (let* ((home (namestring (user-homedir-pathname)))
          (init (find-symbol "*INIT-FILE*" :clamacs))
          (files (find-symbol "*SNAPSHOT-FILES*" :clamacs))
          (before (symbol-value init)))
     (editor-image-check "REFRESH-USER-PATHS is missing from the image"
                         (fboundp (find-symbol "REFRESH-USER-PATHS" :clamacs)))
     (funcall (find-symbol "REFRESH-USER-PATHS" :clamacs))
     (format t "IMAGE-INIT-FILE ~a -> ~a~%" before (symbol-value init))
     (editor-image-check "*INIT-FILE* is not under this run's HOME after REFRESH-USER-PATHS"
                         (eql 0 (search home (symbol-value init))))
     (editor-image-check "*SNAPSHOT-FILES* is not under this run's HOME after REFRESH-USER-PATHS"
                         (and (= 1 (length (symbol-value files)))
                              (eql 0 (search home (first (symbol-value files))))))
     (editor-image-check "the image's *INIT-FILE* was already this run's (verify under a HOME the image was not saved under)"
                         (not (equal before (symbol-value init)))))))

(defvar *editor-image-windows* 0)

(when (find-package :clamacs)
  ;; The editor runs one turn: once its first window is open, the hook
  ;; counts the documents and asks for a quit that discards nothing (the
  ;; buffer is empty), and START returns when the last window is gone.
  ;; The quit is a SETF of a structure accessor, compiled here from the
  ;; symbol: whether a DEFSTRUCT accessor also has a (SETF name) FUNCTION
  ;; is implementation-dependent (CLHS DEFSTRUCT), and clamiga has none,
  ;; so FDEFINITION of it is an undefined function.
  (let ((quit (compile nil `(lambda (editor)
                              (setf (,(find-symbol "EDITOR-QUITTING" :clamacs) editor)
                                    :discard)))))
    (push (lambda (editor)
            (setf *editor-image-windows*
                  (length (funcall (find-symbol "LIVE-DOCUMENTS" :clamacs) editor)))
            ;; The menu: MUI's strip object, or the table sent to the page.
            (setf (symbol-value (find-symbol "*MENU-STRIP-BUILT*" :cl-user))
                  (and (funcall (find-symbol (if (eq *editor-image-frontend* :mui)
                                                 "MUI-EDITOR-MENUSTRIP"
                                                 "HOST-EDITOR-MENUS-SENT")
                                             :clamacs)
                                editor)
                       t))
            (funcall quit editor))
          (symbol-value (find-symbol "*AFTER-START-HOOKS*" :clamacs))))
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
