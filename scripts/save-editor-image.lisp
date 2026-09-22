;;;; save-editor-image.lisp -- write the editor's heap image, clamacs.img,
;;;; beside the clamiga binary that will start from it.
;;;;
;;;; Images are per-build (cl-amiga's specs/image-save-load.md), so this
;;;; runs ON THE TARGET, with the binary that ships, from the directory
;;;; that binary lives in, with the editor loaded and nothing else -- no
;;;; window, no library, no port: everything OS-owned is made by START and
;;;; only there, so nothing OS-owned is in the image.
;;;;
;;;;   cd bin/aos3
;;;;   clamiga --no-userinit --no-image --non-interactive --heap 8M
;;;;       --load //lib/clamacs/load.lisp --load //lib/clamacs/save-editor-image.lisp
;;;;
;;;; (`//' is AmigaDOS for the grandparent directory.)  The Clamacs
;;;; launcher then starts the editor as
;;;;
;;;;   clamiga --image clamacs.img --non-interactive --eval "(clamacs::run)" -- file ...
;;;;
;;;; and RUN loads S:.clamacsrc and opens the windows; a `--no-image' start
;;;; loads lib/clamacs/clamacs.lisp instead and gets the same editor from
;;;; the FASLs.  cl-amiga's verify/realamiga/make-editor-image.sh runs this
;;;; unattended in FS-UAE and verify-editor-image.lisp checks the result.

(when ext:*image-restored-p*
  (format t "SAVE-EDITOR-IMAGE-FAILED: this session was itself restored from an image - rerun with --no-image~%")
  (finish-output)
  (quit 1))

(unless (find-package :clamacs)
  (format t "SAVE-EDITOR-IMAGE-FAILED: the editor is not loaded - --load lib/clamacs/load.lisp first~%")
  (finish-output)
  (quit 1))

;; Deferred: the dump runs at the top-level safe point after this load,
;; then the process exits (:quit t) -- with --non-interactive, right away.
;;
;; :shake-bindings sheds the binding tables of the amiga/raw/* modules the
;; frontend loads (cl-amiga's specs/raw-bindings-footprint.md, Phase 3):
;; about 2,000 names each, of which the editor uses a few dozen -- 254 KB
;; of the image and of the heap it runs in.  The names the loaded code
;; refers to are all in the image already; one it never named is gone from
;; it, so an init file or a port EVAL that calls into the OS directly gets
;; a reader error saying the table was shed (the README says how to get a
;; module back).
(ext:save-image "clamacs.img" :quit t :shake-bindings t)
