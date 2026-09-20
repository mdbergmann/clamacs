;;;; winstore.lisp -- where the windows go: the snapshot of window positions.
;;;;
;;;; `M-x clamacs-snapshot-windows' (Windows > Snapshot Windows) records the
;;;; position and size of every open window in a small text file,
;;;; ENVARC:Clamacs/windows.cfg (and ENV:), and the editor opens its windows
;;;; there from then on.  This is the editor's own store, not MUI's: MUI 3.8
;;;; can snapshot only one window at a time, from that window's MUI menu, and
;;;; a window with a MUI window ID would take MUI's snapshot over anything
;;;; the editor asked for, so the windows carry no MUI ID and this file is
;;;; the one place a position lives.
;;;;
;;;; A window is named by its ROLE.  The fixed windows are `errors',
;;;; `inspector' and `debugger'; the scratch windows go by their name without
;;;; the stars and the `clamacs-' prefix (`repl', `description', `apropos',
;;;; `macroexpansion'); a file window is `doc1', `doc2', ... -- the lowest
;;;; slot no open file window holds, so the first file opened in a session
;;;; comes up where the first file window was when the snapshot was taken,
;;;; the second where the second was, and so on.
;;;;
;;;; The file is one entry per line, `role left top width height', with `;'
;;;; and `#' lines as comments.  A line that does not parse is skipped, not
;;;; fatal: a hand-edited file loses one entry, never the editor's start.
;;;;
;;;; The port of src/emacs/winstore.c; tests/test-winstore.lisp holds its
;;;; cases.  Pure: no MUI, no OS types.

(in-package :clamacs)

(defconstant +winstore-max+ 24
  "Entries a store holds.")
(defconstant +winstore-name-max+ 23
  "The longest role, in characters.")
(defconstant +winstore-line-max+ 127
  "A longer line of the file is dropped whole.")
(defconstant +winstore-digits-max+ 6
  "Anything wider than a screen is a corrupt line, not a position.")

(defparameter *winstore-header*
  "; clamacs window positions -- role left top width height")

(defstruct (winentry (:constructor make-winentry (role left top width height)))
  role left top width height)

(defstruct (winstore (:constructor make-winstore ()))
  (entries '()))               ; oldest first

(defun winstore-count (store)
  (length (winstore-entries store)))

(defun winstore-find (store role)
  "The entry for ROLE, or NIL.  Roles are exact: `Repl' is not `repl'."
  (and role
       (find role (winstore-entries store) :key #'winentry-role :test #'string=)))

(defun winstore-set (store role left top width height)
  "Record ROLE's geometry, replacing an entry of that role or appending.
True, or NIL when the store is full or ROLE is empty or too long."
  (cond ((or (null role) (string= role "")
             (> (length role) +winstore-name-max+))
         nil)
        (t
         (let ((entry (winstore-find store role)))
           (cond (entry
                  (setf (winentry-left entry) left
                        (winentry-top entry) top
                        (winentry-width entry) width
                        (winentry-height entry) height)
                  t)
                 ((>= (winstore-count store) +winstore-max+)
                  nil)
                 (t
                  (setf (winstore-entries store)
                        (append (winstore-entries store)
                                (list (make-winentry role left top width height))))
                  t))))))

;;; ------------------------------------------------------------------
;;; Text
;;; ------------------------------------------------------------------

(defun winstore-blank-p (c)
  (or (char= c #\Space) (char= c #\Tab)))

(defun winstore-number (line start)
  "A signed decimal in LINE at START, blanks skipped: two values, the
number and the index after it, or NIL when there is none there."
  (let ((i start) (n (length line)) (neg nil) (value 0) (digits 0))
    (loop while (and (< i n) (winstore-blank-p (char line i))) do (incf i))
    (when (and (< i n) (char= (char line i) #\-))
      (setq neg t)
      (incf i))
    (loop while (and (< i n) (digit-char-p (char line i)))
          do (when (>= digits +winstore-digits-max+)
               (return-from winstore-number nil))
             (setq value (+ (* value 10) (digit-char-p (char line i))))
             (incf digits)
             (incf i))
    (when (zerop digits)
      (return-from winstore-number nil))
    (when (and (< i n)
               (not (winstore-blank-p (char line i)))
               (not (char= (char line i) #\Return)))
      (return-from winstore-number nil))
    (values (if neg (- value) value) i)))

(defun winstore-parse-line (store line)
  "One line, without its newline.  True when it held an entry."
  (let ((i 0) (n (length line)))
    (loop while (and (< i n) (winstore-blank-p (char line i))) do (incf i))
    (when (or (>= i n) (member (char line i) '(#\; #\# #\Return)))
      (return-from winstore-parse-line nil))
    (let ((start i))
      (loop while (and (< i n)
                       (not (winstore-blank-p (char line i)))
                       (not (char= (char line i) #\Return)))
            do (incf i))
      (when (> (- i start) +winstore-name-max+)
        (return-from winstore-parse-line nil))
      (let ((role (subseq line start i))
            (numbers '()))
        (dotimes (k 4)
          (multiple-value-bind (value next) (winstore-number line i)
            (unless value
              (return-from winstore-parse-line nil))
            (push value numbers)
            (setq i next)))
        (loop while (and (< i n)
                         (or (winstore-blank-p (char line i))
                             (char= (char line i) #\Return)))
              do (incf i))
        (when (< i n)
          (return-from winstore-parse-line nil))   ; trailing junk: not an entry
        (destructuring-bind (height width top left) numbers
          (winstore-set store role left top width height))))))

(defun winstore-parse (store text)
  "Replace the store's contents with what TEXT holds.  The number of
entries read; a NIL or empty TEXT gives 0."
  (setf (winstore-entries store) '())
  (let ((read 0))
    (when text
      (let ((start 0) (n (length text)))
        (loop
          (let* ((end (or (position #\Newline text :start start) n))
                 (len (- end start)))
            (when (and (<= len +winstore-line-max+)
                       (winstore-parse-line store (subseq text start end)))
              (incf read))
            (when (>= end n)
              (return))
            (setq start (1+ end))))))
    read))

(defun winstore-format (store)
  "The store as text, header line included."
  (with-output-to-string (out)
    (write-string *winstore-header* out)
    (terpri out)
    (dolist (e (winstore-entries store))
      (format out "~A ~D ~D ~D ~D~%" (winentry-role e) (winentry-left e)
              (winentry-top e) (winentry-width e) (winentry-height e)))))

;;; ------------------------------------------------------------------
;;; Roles
;;; ------------------------------------------------------------------

(defun winstore-doc-role (slot)
  "The role of file window number SLOT (1-based): `doc1', `doc2', ...; NIL
when SLOT is not positive."
  (and (integerp slot) (> slot 0) (format nil "doc~D" slot)))

(defun winstore-doc-slot (role)
  "The slot a `docN' role names, or NIL for any other role."
  (and (stringp role)
       (> (length role) 3)
       (string= role "doc" :end1 3)
       (every #'digit-char-p (subseq role 3))
       (<= (length role) 9)
       (parse-integer role :start 3)))

(defun winstore-scratch-role (name)
  "The role of the scratch window called NAME: the name without its stars
and a leading `clamacs-', so `*clamacs-repl*' is `repl'.  Blanks become
`-' (a role is one word in the file), and the result is cut to the longest
role.  \"\" when nothing is left; the caller then gives the window no
stored place."
  (if (null name)
      ""
      (let* ((start (or (position #\* name :test #'char/=) (length name)))
             (start (if (and (>= (- (length name) start) 8)
                             (string= name "clamacs-" :start1 start :end1 (+ start 8)))
                        (+ start 8)
                        start))
             (end (or (position #\* name :start start) (length name)))
             (role (substitute-if #\- #'winstore-blank-p (subseq name start end))))
        (if (> (length role) +winstore-name-max+)
            (subseq role 0 +winstore-name-max+)
            role))))
