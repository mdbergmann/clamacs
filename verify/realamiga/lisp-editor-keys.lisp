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

(defun type-into (doc)
  "Type *SMOKE-LINES* into DOC the way the harness types them into the
Amiga editor: the text of each line, then RET."
  (dolist (line *smoke-lines*)
    (type-text doc line)
    (type-keys doc "RET")))

(defun write-sendkey-script (path sendkey)
  "The AmigaDOS lines that type *SMOKE-LINES* with SENDKEY."
  (with-open-file (out path :direction :output :if-exists :supersede)
    (dolist (line *smoke-lines*)
      (unless (string= line "")
        (format out "~A TEXT \"~A\" DELAY 1~%" sendkey line))
      (format out "~A RET~%" sendkey))))
