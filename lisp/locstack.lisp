;;;; locstack.lisp -- where `M-.' came from, so `M-,' can go back.
;;;;
;;;; A jump to a definition pushes the place it left; popping returns there.
;;;; The place is a file path and a character index, plus the document id it
;;;; was in: the id finds the same window when it is still open, the path
;;;; reopens the file when it is not, and a scratch window (no path, NIL) is
;;;; only ever found by id.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +locstack-size+ 16)

(defstruct (location (:constructor make-location (path id index)))
  path id index)

(defstruct (locstack (:constructor make-locstack ()))
  (items '()))                          ; the most recent place first

(defun locstack-depth (stack)
  (length (locstack-items stack)))

(defun locstack-push (stack path id index)
  "Push a place.  When the stack is full the oldest entry is dropped: the
user can always get back to the last few places, which is what matters."
  (let ((items (cons (make-location path id index) (locstack-items stack))))
    (when (> (length items) +locstack-size+)
      (setf (cdr (nthcdr (1- +locstack-size+) items)) nil))
    (setf (locstack-items stack) items))
  stack)

(defun locstack-pop (stack)
  "Pop the most recent place: a LOCATION, or NIL when the stack is empty."
  (pop (locstack-items stack)))
