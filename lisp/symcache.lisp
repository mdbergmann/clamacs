;;;; symcache.lisp -- what clamiga has already said about a symbol.
;;;;
;;;; The status line asks for the arglist of the operator at point whenever
;;;; the cursor comes to rest somewhere new, and most of the time that
;;;; operator is one it has asked about before -- `let', `defun', the
;;;; project's own functions.  A round trip over ARexx is cheap, but it is
;;;; not free on a 68020 and it queues behind whatever else is on the wire,
;;;; so the answer is kept.  A miss is kept too (an empty value): asking
;;;; again about `x' every time the cursor enters a binding list would be
;;;; the same waste.
;;;;
;;;; Keys are compared case-insensitively, as Lisp reads symbols, and are
;;;; expected to carry the package they were resolved in (`CL-USER|foo'):
;;;; the same unqualified name can mean different things in different
;;;; packages.  The port of src/rexx/symcache.c: a ring of 64 slots, the
;;;; oldest entry replaced first.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +symcache-size+ 64)

(defstruct (symcache (:constructor make-symcache ()))
  ;; lowercased key -> value; and the keys in insertion order, oldest
  ;; first, for the ring's eviction
  (table (make-hash-table :test 'equal))
  (order '())
  (count 0))

(defun symcache-key (key)
  (and (stringp key) (> (length key) 0) (string-downcase key)))

(defun symcache-clear (cache)
  (clrhash (symcache-table cache))
  (setf (symcache-order cache) '()
        (symcache-count cache) 0)
  cache)

(defun symcache-put (cache key value)
  "Remember VALUE for KEY.  An existing key is updated in place; a new one
takes the oldest slot once the ring is full.  VALUE may be \"\" (or NIL) to
record that clamiga had no answer.  True, or NIL for a junk key."
  (let ((k (symcache-key key))
        (value (or value "")))
    (when k
      (let ((table (symcache-table cache)))
        (multiple-value-bind (old found) (gethash k table)
          (declare (ignore old))
          (cond (found
                 (setf (gethash k table) value))
                (t
                 (when (>= (symcache-count cache) +symcache-size+)
                   (let ((oldest (pop (symcache-order cache))))
                     (remhash oldest table)
                     (decf (symcache-count cache))))
                 (setf (gethash k table) value
                       (symcache-order cache) (nconc (symcache-order cache) (list k)))
                 (incf (symcache-count cache))))))
      t)))

(defun symcache-get (cache key)
  "The remembered value, \"\" for a remembered miss, or NIL when KEY has
never been asked about -- the one case that needs a round trip."
  (let ((k (symcache-key key)))
    (and k (values (gethash k (symcache-table cache))))))
