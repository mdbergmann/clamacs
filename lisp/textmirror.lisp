;;;; textmirror.lisp -- the text model: a string, a point, an undo list.
;;;;
;;;; What the fake frontend (tests/fake-frontend.lisp) kept as its
;;;; "widget", promoted to a module of its own so the host frontend
;;;; (specs/clamacs-host.md) can run on it for real: the page's CodeMirror
;;;; is asynchronous, so every synchronous read of the frontend protocol --
;;;; DOC-TEXT, DOC-INDEX-LINE, DOC-SEARCH, ... -- is answered from this
;;;; mirror, and every write goes here first and is pushed to the page.
;;;; The fake frontend is the same model with a recorder around it, which
;;;; is what makes tests/test-commands.lisp the host editor's specification.
;;;;
;;;; Pure: no MUI, no OS, no frontend.  A text is a SIMPLE-STRING, a
;;;; position a character index, "not possible" is NIL; the line scans are
;;;; SCHAR loops (the runtime's string-scan opcodes), since the host
;;;; document runs them on every key.

(in-package :clamacs)

(defparameter *mirror-undo-depth* 1000
  "The most undo entries a mirror keeps.")

(defparameter *mirror-undo-chars* 4000000
  "The most characters of text its undo entries hold together; the newest
entry stays however long the text is.")

(defstruct (mirror (:constructor %make-mirror))
  (text "" :type simple-string)
  (point 0 :type fixnum)
  ;; (text . point) before each edit, newest first; REDO the same the
  ;; other way.  A whole-text snapshot per edit keeps the model trivially
  ;; right, so the list is bounded (MIRROR-TRIM-HISTORY): the oldest
  ;; entries go once it holds *MIRROR-UNDO-DEPTH* of them or
  ;; *MIRROR-UNDO-CHARS* characters.  An undo moves one entry to REDO and
  ;; a redo moves it back, so the two lists together never hold more
  ;; entries than the bound allows, and REDO needs no trimming of its own.
  (undo '())
  (redo '())
  (modified nil)
  ;; The widget's selection as (start . end), or NIL
  (selection nil)
  ;; How far :NEXT-PAGE / :PREVIOUS-PAGE move
  (page-lines 10 :type fixnum))

(defun make-mirror (&key (text "") (point 0) (page-lines 10))
  (let ((m (%make-mirror :text (coerce text 'simple-string)
                         :page-lines page-lines)))
    (mirror-set-point m point)
    m))

;;; --- text access ----------------------------------------------------

(defun mirror-end (m)
  (length (mirror-text m)))

(defun mirror-set-point (m index)
  "Move the point to INDEX, clamped to the text; the new point."
  (setf (mirror-point m) (max 0 (min index (mirror-end m)))))

(defun mirror-line-count (m)
  "The number of lines; an empty text has one."
  (let ((text (mirror-text m))
        (n 1))
    (declare (simple-string text) (fixnum n))
    (dotimes (i (length text) n)
      (when (char= (schar text i) #\Newline)
        (incf n)))))

(defun mirror-index-line (m index)
  "The line INDEX (clamped) is on and its column there, two values."
  (let* ((text (mirror-text m))
         (index (max 0 (min index (length text))))
         (y 0)
         (start 0))
    (declare (simple-string text) (fixnum index y start))
    (dotimes (i index)
      (when (char= (schar text i) #\Newline)
        (incf y)
        (setq start (1+ i))))
    (values y (- index start))))

(defun mirror-line-index (m y)
  "The index where line Y starts; the last line's for a Y past the end,
the first's for a negative one."
  (let* ((text (mirror-text m))
         (len (length text))
         (index 0)
         (line 0))
    (declare (simple-string text) (fixnum len index line))
    (dotimes (i len index)
      (when (>= line y)
        (return index))
      (when (char= (schar text i) #\Newline)
        (incf line)
        (setq index (1+ i))))))

(defun mirror-line-end (m start)
  "The index of the newline that ends the line starting at START, or the
text's end."
  (let* ((text (mirror-text m))
         (len (length text)))
    (declare (simple-string text) (fixnum len))
    (loop for i of-type fixnum from start below len
          when (char= (schar text i) #\Newline)
            do (return i)
          finally (return len))))

(defun mirror-substring (m start end)
  (coerce (subseq (mirror-text m) start end) 'simple-string))

(defun mirror-lines-text (m y0 y1)
  "Lines Y0 to Y1 inclusive, newlines included but the last line's."
  (let ((last (1- (mirror-line-count m))))
    (mirror-substring m
                      (mirror-line-index m y0)
                      (if (>= y1 last)
                          (mirror-end m)
                          (mirror-line-index m (1+ y1))))))

;;; --- editing --------------------------------------------------------

(defun mirror-trim-history (history)
  "HISTORY, a list of (text . point) entries newest first, cut before the
first entry that takes it past *MIRROR-UNDO-DEPTH* entries or
*MIRROR-UNDO-CHARS* characters.  The newest entry always stays.  Destructive
on the conses; HISTORY itself is returned."
  (let ((depth 0)
        (chars 0)
        (prev nil))
    (declare (fixnum depth chars))
    (do ((cell history (cdr cell)))
        ((null cell) history)
      (incf depth)
      (incf chars (length (caar cell)))
      (when (and (> depth 1)
                 (or (> depth *mirror-undo-depth*)
                     (> chars *mirror-undo-chars*)))
        (setf (cdr prev) nil)
        (return history))
      (setq prev cell))))

(defun mirror-record-undo (m)
  (setf (mirror-modified m) t)
  (setf (mirror-undo m)
        (mirror-trim-history (cons (cons (mirror-text m) (mirror-point m))
                                   (mirror-undo m))))
  (setf (mirror-redo m) '()))

(defun mirror-insert (m text)
  "Insert TEXT at the point; the point ends after it."
  (mirror-record-undo m)
  (let ((old (mirror-text m))
        (point (mirror-point m)))
    (setf (mirror-text m) (concatenate 'simple-string
                                       (subseq old 0 point)
                                       text
                                       (subseq old point))
          (mirror-point m) (+ point (length text)))))

(defun mirror-delete (m start end)
  "Delete START to END; the point ends at START."
  (mirror-record-undo m)
  (let ((old (mirror-text m)))
    (setf (mirror-text m) (concatenate 'simple-string
                                       (subseq old 0 start)
                                       (subseq old end))
          (mirror-point m) start)))

(defun mirror-set-text (m text)
  "Replace the whole text, as a file load does: point at 0, no undo, not
modified."
  (setf (mirror-text m) (coerce text 'simple-string)
        (mirror-point m) 0
        (mirror-undo m) '()
        (mirror-redo m) '()
        (mirror-selection m) nil
        (mirror-modified m) nil))

(defun mirror-word-char-p (c)
  (alphanumericp c))

(defun mirror-move (m motion)
  "The widget's cursor motions (DOC-MOVE): true when the point moved, NIL
when the motion is not possible there."
  (let* ((text (mirror-text m))
         (len (length text))
         (point (mirror-point m))
         (target
           (multiple-value-bind (y x) (mirror-index-line m point)
             (flet ((to-line (y)
                      (and (<= 0 y (1- (mirror-line-count m)))
                           (let ((start (mirror-line-index m y)))
                             (min (+ start x) (mirror-line-end m start))))))
               (ecase motion
                 (:left (and (> point 0) (1- point)))
                 (:right (and (< point len) (1+ point)))
                 (:up (to-line (1- y)))
                 (:down (to-line (1+ y)))
                 (:line-start (mirror-line-index m y))
                 (:line-end (mirror-line-end m (mirror-line-index m y)))
                 (:text-start 0)
                 (:text-end len)
                 (:next-word
                  (and (< point len)
                       (let ((p point))
                         (declare (fixnum p))
                         (loop while (and (< p len)
                                          (not (mirror-word-char-p (schar text p))))
                               do (incf p))
                         (loop while (and (< p len)
                                          (mirror-word-char-p (schar text p)))
                               do (incf p))
                         p)))
                 (:previous-word
                  (and (> point 0)
                       (let ((p point))
                         (declare (fixnum p))
                         (loop while (and (> p 0)
                                          (not (mirror-word-char-p (schar text (1- p)))))
                               do (decf p))
                         (loop while (and (> p 0)
                                          (mirror-word-char-p (schar text (1- p))))
                               do (decf p))
                         p)))
                 (:next-page
                  (to-line (min (1- (mirror-line-count m))
                                (+ y (mirror-page-lines m)))))
                 (:previous-page
                  (to-line (max 0 (- y (mirror-page-lines m))))))))))
    (when target
      (setf (mirror-point m) target)
      t)))

(defun mirror-edit (m operation)
  "The widget's own edits (DOC-EDIT): true when something happened."
  (let ((point (mirror-point m)))
    (ecase operation
      (:delete
       (when (< point (mirror-end m))
         (mirror-delete m point (1+ point))
         t))
      (:backspace
       (when (> point 0)
         (mirror-delete m (1- point) point)
         t))
      (:undo
       (let ((entry (pop (mirror-undo m))))
         (when entry
           (push (cons (mirror-text m) point) (mirror-redo m))
           (setf (mirror-text m) (car entry)
                 (mirror-point m) (cdr entry))
           t)))
      (:redo
       (let ((entry (pop (mirror-redo m))))
         (when entry
           (push (cons (mirror-text m) point) (mirror-undo m))
           (setf (mirror-text m) (car entry)
                 (mirror-point m) (cdr entry))
           t)))
      (:select-all
       (setf (mirror-selection m) (cons 0 (mirror-end m)))
       t)
      (:select-none
       (setf (mirror-selection m) nil)
       t))))

;;; --- search ---------------------------------------------------------

(defun mirror-match-at (text pattern i)
  (declare (simple-string text pattern) (fixnum i))
  (let ((n (length pattern)))
    (declare (fixnum n))
    (and (<= (+ i n) (length text))
         (dotimes (k n t)
           (unless (char= (schar text (+ i k)) (schar pattern k))
             (return nil))))))

(defun mirror-search (m pattern backwards again)
  "DOC-SEARCH: find PATTERN from the point.  Forwards the point ends after
the match, backwards at its start, so AGAIN needs no adjustment either
way: the next search from the point cannot find the same match.  True
when found."
  (declare (ignore again))
  (let* ((text (mirror-text m))
         (pattern (coerce pattern 'simple-string))
         (len (length text))
         (n (length pattern))
         (point (mirror-point m))
         (found
           (if backwards
               ;; The match may end just before the point's character.
               (loop for i of-type fixnum from (min (- len n) (+ point -1)) downto 0
                     when (mirror-match-at text pattern i)
                       do (return i))
               (loop for i of-type fixnum from point to (- len n)
                     when (mirror-match-at text pattern i)
                       do (return i)))))
    (when found
      (setf (mirror-point m) (if backwards found (+ found n)))
      t)))
