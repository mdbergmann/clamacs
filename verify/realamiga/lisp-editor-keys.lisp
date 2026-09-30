;;;; lisp-editor-keys.lisp -- the keystrokes of the Lisp editor's FS-UAE
;;;; smoke run, and what they must produce.
;;;;
;;;; Loaded twice by run-lisp-editor.sh: on the HOST under the fake frontend
;;;; (tests/fake-frontend.lisp), where TYPE-INTO produces the expected file,
;;;; and read by the harness to emit the same keys as `sendkey' lines for
;;;; the Amiga.  One list of lines, two frontends: what the MUI editor
;;;; saves must equal what the host-tested one holds.  The lines are typed
;;;; WITHOUT indentation; RET is newline-and-indent in both.
;;;;
;;;; AmigaDOS quoting rules for the sendkey lines: no `*' and no `"'.

(in-package :clamacs)

(defparameter *smoke-lines*
  '("(defun smoke-alpha (n acc)"
    "(if (< n 2)"
    "(values n acc)"
    "(let ((a (smoke-alpha (- n 1) acc))"
    "(b (smoke-alpha (- n 2) (cons n acc))))"
    "(when (and (integerp a) (integerp b))"
    "(print (+ a b)))"
    "(dolist (item acc (+ a b))"
    "(unless (zerop item)"
    "(incf a (floor item 2)))))))"
    ""))

(defparameter *smoke-edits*
  '(;; The region and the kill ring: the first line copied to the end
    (:keys "M-< C-SPC C-e M-w M-> C-y RET")
    ;; Amiga-C copies the region `C-SPC' and a motion show, Amiga-V pastes
    ;; it: the platform's keys, the commands of `M-w' and `C-y'
    (:keys "M-< C-n C-SPC C-e") (:amiga "c" "M-w")
    (:keys "M->") (:amiga "v" "C-y") (:keys "RET")
    ;; Amiga-X cuts, and the region shown is not typed over: the mark set,
    ;; a motion, a character
    (:keys "M-< C-SPC C-f C-f C-f C-f C-f C-f") (:amiga "x" "C-w")
    (:keys "M-> C-SPC C-p C-e ; M->") (:amiga "v" "C-y") (:keys "RET"))
  "What is typed after *SMOKE-LINES*: (:KEYS spelling) for keys both
frontends take, (:AMIGA letter spelling) for a letter typed with the right
Amiga key held, which the fake frontend types as SPELLING.")

(defun type-into (doc)
  "Type *SMOKE-LINES* and *SMOKE-EDITS* into DOC the way the harness types
them into the Amiga editor: the text of each line, then RET; then the
edits, an Amiga key as the Emacs key of the same command."
  (dolist (line *smoke-lines*)
    (type-text doc line)
    (type-keys doc "RET"))
  (dolist (edit *smoke-edits*)
    (type-keys doc (ecase (first edit)
                     (:keys (second edit))
                     (:amiga (third edit))))))

(defun write-sendkey-script (path sendkey)
  "The AmigaDOS lines that type *SMOKE-LINES* with SENDKEY."
  (with-open-file (out path :direction :output :if-exists :supersede)
    (dolist (line *smoke-lines*)
      (unless (string= line "")
        (format out "~A TEXT \"~A\" DELAY 1~%" sendkey line))
      (format out "~A RET~%" sendkey))
    ;; `;' starts a comment on a DOS command line and `<' `>' redirect:
    ;; every key is quoted.
    (dolist (edit *smoke-edits*)
      (ecase (first edit)
        (:keys (format out "~A~{ \"~A\"~} DELAY 3~%" sendkey
                       (split-spelling (second edit))))
        (:amiga (format out "~A \"~A\" AMIGA DELAY 3~%" sendkey (second edit)))))))

(defun split-spelling (keys)
  "The words of KEYS, a key spelling each."
  (let ((words '())
        (start nil))
    (dotimes (i (length keys))
      (cond ((char= (char keys i) #\Space)
             (when start
               (push (subseq keys start i) words)
               (setq start nil)))
            ((null start) (setq start i))))
    (when start
      (push (subseq keys start) words))
    (nreverse words)))
