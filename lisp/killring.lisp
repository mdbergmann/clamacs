;;;; killring.lisp -- the kill ring.
;;;;
;;;; Distinct from the Amiga clipboard on purpose: `C-k' three times in a row
;;;; must build one entry, and `M-y' must walk backwards through entries the
;;;; clipboard has no concept of.  The frontend additionally copies what
;;;; `C-w'/`M-w' kill to the clipboard so other applications see the last
;;;; kill; that is a one-way mirror and does not live here.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +kill-ring-size+ 16)

(defstruct (killring (:constructor make-killring ()))
  (entries '())                  ; strings, the most recent kill first
  (yank 0 :type fixnum))         ; how far `M-y' has rotated back

(defun kill-count (ring)
  (length (killring-entries ring)))

(defun kill-clear (ring)
  (setf (killring-entries ring) '()
        (killring-yank ring) 0)
  ring)

(defun kill-push (ring text)
  "Start a new entry.  The oldest one falls off a full ring."
  (let ((entries (cons (copy-seq text) (killring-entries ring))))
    (when (> (length entries) +kill-ring-size+)
      (setf (cdr (nthcdr (1- +kill-ring-size+) entries)) nil))
    (setf (killring-entries ring) entries
          (killring-yank ring) 0))
  ring)

(defun kill-extend (ring text at-front)
  (if (null (killring-entries ring))
      (kill-push ring text)
      (let ((old (first (killring-entries ring))))
        (setf (first (killring-entries ring))
              (if at-front
                  (concatenate 'string text old)
                  (concatenate 'string old text))
              (killring-yank ring) 0)
        ring)))

(defun kill-append (ring text)
  "Extend the most recent entry at its end, as consecutive `C-k' does.
Falls back to a push when the ring is empty."
  (kill-extend ring text nil))

(defun kill-prepend (ring text)
  "Extend the most recent entry at its front, as backward kills such as
`backward-kill-word' do -- which is what makes `M-DEL M-DEL' yank back in
reading order."
  (kill-extend ring text t))

(defun kill-current (ring)
  "What `C-y' yanks: the entry at the current rotation, or NIL when the ring
is empty."
  (nth (killring-yank ring) (killring-entries ring)))

(defun kill-rotate (ring)
  "`M-y': step one entry further back and return it, or NIL when the ring is
empty.  Wraps around."
  (when (killring-entries ring)
    (setf (killring-yank ring)
          (mod (1+ (killring-yank ring)) (kill-count ring)))
    (kill-current ring)))

(defun kill-reset-yank (ring)
  "Called when something other than a yank happens, so the next `C-y' starts
from the most recent kill again."
  (setf (killring-yank ring) 0)
  ring)
