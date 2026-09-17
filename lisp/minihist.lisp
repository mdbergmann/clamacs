;;;; minihist.lisp -- minibuffer history and completion.
;;;;
;;;; The minibuffer is one object reused for every prompt, so the history has
;;;; to be per PROMPT KIND (file names, commands, search patterns) rather
;;;; than per object -- hence a plain struct the caller keeps one of per
;;;; kind.  Completion is generic over a candidate list so `M-x', file names
;;;; and symbol names from clamiga all share one implementation.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +hist-size+ 32)

(defstruct (history (:constructor make-history ()))
  (items '())                    ; strings, the newest first
  (cursor 0 :type fixnum))       ; 0 = not walking, N = N entries back

(defun hist-count (hist)
  (length (history-items hist)))

(defun hist-clear (hist)
  (setf (history-items hist) '()
        (history-cursor hist) 0)
  hist)

(defun hist-nth (hist n)
  "Entry N back from the newest (0 = newest), or NIL."
  (and (>= n 0) (nth n (history-items hist))))

(defun hist-add (hist text)
  "Record an entry.  NIL, the empty string and a repeat of the newest entry
are dropped, so holding a key down does not fill the ring with one string.
Resets the cursor."
  (setf (history-cursor hist) 0)
  (when (and text
             (string/= text "")
             (not (equal text (first (history-items hist)))))
    (let ((items (cons (copy-seq text) (history-items hist))))
      (when (> (length items) +hist-size+)
        (setf (cdr (nthcdr (1- +hist-size+) items)) nil))
      (setf (history-items hist) items)))
  hist)

(defun hist-prev (hist)
  "`M-p': the entry to show, or NIL at the end of the ring."
  (let ((cursor (history-cursor hist)))
    (when (< cursor (hist-count hist))
      (setf (history-cursor hist) (1+ cursor))
      (hist-nth hist cursor))))

(defun hist-next (hist)
  "`M-n': the entry to show; NIL means \"back to what the user was typing\",
which the caller holds."
  (cond ((<= (history-cursor hist) 1)
         (setf (history-cursor hist) 0)
         nil)
        (t
         (decf (history-cursor hist))
         (hist-nth hist (1- (history-cursor hist))))))

(defun hist-reset (hist)
  "Stop walking; the next M-p starts from the newest entry again."
  (setf (history-cursor hist) 0)
  hist)

;;; ------------------------------------------------------------------
;;; Completion
;;; ------------------------------------------------------------------

(defun prefix-p (prefix string)
  (declare (simple-string prefix string))
  (let ((n (length prefix)))
    (and (<= n (length string))
         (dotimes (i n t)
           (unless (char= (schar prefix i) (schar string i))
             (return nil))))))

(defun complete (candidates prefix)
  "The strings of CANDIDATES that start with PREFIX, in table order, and as
second value the longest common prefix of all of them -- which is what TAB
inserts; \"\" when nothing matches.  Case sensitive.  The caller shows as
many matches as it likes and says how many there are."
  (let ((prefix (coerce (or prefix "") 'simple-string))
        (matches '())
        (first nil)
        (common-len 0))
    (declare (fixnum common-len))
    (dolist (name candidates)
      (when (and name (prefix-p prefix (coerce name 'simple-string)))
        (push name matches)
        (if (null first)
            (setq first name
                  common-len (length name))
            (let ((diff (mismatch first name :end1 common-len)))
              (when diff
                (setq common-len diff))))))
    (values (nreverse matches)
            (if first (subseq first 0 common-len) ""))))

(defun split-lines (text)
  "The non-empty lines of TEXT, trailing CR and spaces stripped.  A candidate
list that came from clamiga: COMPLETE answers one symbol per line, and this
turns that reply into the list COMPLETE takes.  TEXT may be NIL."
  (let ((lines '())
        (start 0)
        (len (length text)))
    (loop
      (when (>= start len)
        (return (nreverse lines)))
      (let* ((nl (or (position #\Newline text :start start) len))
             (end nl))
        (loop while (and (> end start)
                         (member (char text (1- end)) '(#\Return #\Space)))
              do (decf end))
        (when (> end start)
          (push (subseq text start end) lines))
        (setq start (1+ nl))))))
