;;;; diag.lisp -- parsing clamiga's replies.
;;;;
;;;; A LOAD, COMPILE-FILE or EVAL over the wire answers with the machine-
;;;; readable rows first, one diagnostic per line --
;;;;
;;;;   Work:src/foo.lisp:3: ERROR: Too many arguments to FOO
;;;;   Work:src/foo.lisp:7: WARNING: Undefined variable Y
;;;;   1 error(s), 1 warning(s)
;;;;   --- log ---
;;;;   ...whatever the command printed...
;;;;
;;;; -- and cl-amiga's lib/dev-commands.lisp (%REPLY) is the specification
;;;; of that shape.  This is the port of src/rexx/diag.c: the same rules,
;;;; the C test cases as the data of tests/test-diag.lisp.  The one trap is
;;;; that an Amiga path has colons of its own (`Work:src/foo.lisp', `Ram
;;;; Disk:my file.lisp'), so a line is anchored on the severity keyword, never
;;;; on a colon, and `file:line' is split from the right.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defstruct (diagnostic (:constructor make-diagnostic
                           (severity file line text rendered)))
  severity     ; :ERROR, :WARNING or :NOTE
  file         ; a path, or NIL for a diagnostic clamiga could not locate
  line         ; 1-based, or 0 when there is none
  text         ; the message without the prefix
  rendered)    ; the whole line, for the error list

(defstruct (diaglist (:constructor make-diaglist ()))
  (items (make-array 0 :adjustable t :fill-pointer 0))
  (errors 0)
  (warnings 0)
  (summary nil)            ; the `N error(s), M warning(s)' line, or NIL
  (aborted nil)            ; `; aborted -- ...' was seen
  (truncated nil))         ; `[truncated at ...]' was seen

(defun diaglist-count (list)
  (length (diaglist-items list)))

(defun diaglist-ref (list row)
  (aref (diaglist-items list) row))

(defun diaglist-summary-seen (list)
  (and (diaglist-summary list) t))

(defun diaglist-rendered (list)
  "The rows of the error list, oldest first."
  (map 'list #'diagnostic-rendered (diaglist-items list)))

(defun diaglist-clear (list)
  (setf (fill-pointer (diaglist-items list)) 0
        (diaglist-errors list) 0
        (diaglist-warnings list) 0
        (diaglist-summary list) nil
        (diaglist-aborted list) nil
        (diaglist-truncated list) nil)
  list)

;;; Longest match first, so STYLE-WARNING is not read as an unknown word
;;; that happens to begin with nothing.
(defparameter *severity-words*
  '(("ERROR" . :error) ("STYLE-WARNING" . :warning) ("WARNING" . :warning)
    ("NOTE" . :note)))

(defun severity-at (line at)
  "A severity keyword at LINE[AT] followed by a colon: its length and the
severity, or NIL."
  (let ((len (length line)))
    (dolist (entry *severity-words* nil)
      (let* ((word (car entry)) (wlen (length word)))
        (when (and (<= (+ at wlen 1) len)
                   (string= word line :start2 at :end2 (+ at wlen))
                   (char= (char line (+ at wlen)) #\:))
          (return (values wlen (cdr entry))))))))

(defun all-digits-p (string start end)
  (and (< start end)
       (loop for i from start below end
             always (digit-char-p (char string i)))))

(defun parse-diagnostic-line (line)
  "LINE as a DIAGNOSTIC, or NIL when it is not one."
  (let ((len (length line)))
    (when (zerop len)
      (return-from parse-diagnostic-line nil))
    (multiple-value-bind (wlen severity) (severity-at line 0)
      (let ((prefix-end nil) (at 0))
        (unless wlen
          ;; `file:line: SEVERITY: message' -- anchored on the keyword.
          (loop for i from 0 while (< (+ i 2) len)
                do (when (and (char= (char line i) #\:)
                              (char= (char line (1+ i)) #\Space))
                     (multiple-value-bind (w s) (severity-at line (+ i 2))
                       (when w
                         (setq wlen w severity s prefix-end i at (+ i 2))
                         (return)))))
          (unless wlen
            (return-from parse-diagnostic-line nil)))
        (let ((text-at (+ at wlen 1))
              (file nil)
              (number 0))
          (loop while (and (< text-at len) (char= (char line text-at) #\Space))
                do (incf text-at))
          (when (and prefix-end (> prefix-end 0))
            ;; Split `file:line' from the right: the LAST colon whose tail is
            ;; all digits is the line number, so a path keeps its colons.
            (let ((colon (position #\: line :end prefix-end :from-end t)))
              (cond ((and colon (all-digits-p line (1+ colon) prefix-end))
                     (setq number (parse-integer line :start (1+ colon) :end prefix-end)
                           file (subseq line 0 colon)))
                    (t (setq file (subseq line 0 prefix-end))))))
          (make-diagnostic severity file number (subseq line text-at) line))))))

(defun parse-summary-line (line)
  "`N error(s), M warning(s)': the two counts, or NIL."
  (let* ((len (length line))
         (i (or (position #\Space line :test-not #'char=) len))
         (e-tag " error(s), ")
         (w-tag " warning(s)"))
    (let ((e-end (or (position-if-not #'digit-char-p line :start i) len)))
      (when (and (> e-end i)
                 (<= (+ e-end (length e-tag)) len)
                 (string= e-tag line :start2 e-end :end2 (+ e-end (length e-tag))))
        (let* ((w-start (+ e-end (length e-tag)))
               (w-end (or (position-if-not #'digit-char-p line :start w-start) len)))
          (when (and (> w-end w-start)
                     (<= (+ w-end (length w-tag)) len)
                     (string= w-tag line :start2 w-end :end2 (+ w-end (length w-tag))))
            (values (parse-integer line :start i :end e-end)
                    (parse-integer line :start w-start :end w-end))))))))

(defun starts-with-p (prefix line)
  (and (>= (length line) (length prefix))
       (string= prefix line :end2 (length prefix))))

(defun parse-diagnostics (list text)
  "Add the diagnostics in TEXT, a whole reply, to LIST.  Returns how many
were added.  Everything after the `--- log ---' marker is what the command
PRINTED, for a human to read -- clamiga's own error reports in there begin
with `ERROR: ' and must not become rows -- except the truncation marker,
which %TRUNCATE appends to the whole reply, after the log."
  (let ((added 0) (in-log nil) (start 0) (len (length text)))
    (loop
      (when (>= start len) (return))
      (let* ((nl (position #\Newline text :start start))
             (end (or nl len))
             (line (subseq text start end)))
        (when (and (> (length line) 0)
                   (char= (char line (1- (length line))) #\Return))
          (setq line (subseq line 0 (1- (length line)))))
        (when (starts-with-p "--- log ---" line)
          (setq in-log t))
        (when (starts-with-p "[truncated a" line)
          (setf (diaglist-truncated list) t))
        (when (and (> (length line) 0) (not in-log))
          (multiple-value-bind (errors warnings) (parse-summary-line line)
            (cond (errors
                   (setf (diaglist-errors list) errors
                         (diaglist-warnings list) warnings
                         (diaglist-summary list) line))
                  ((starts-with-p "[truncated a" line))
                  ((starts-with-p "; aborted -" line)
                   (setf (diaglist-aborted list) t))
                  (t
                   (let ((d (parse-diagnostic-line line)))
                     (when d
                       (vector-push-extend d (diaglist-items list))
                       (incf added)))))))
        (if nl
            (setq start (1+ nl))
            (return))))
    added))

(defun parse-location (text)
  "A SOURCE-LOCATION reply, `path:line', as two values -- the path (with
its own colons) and the line -- or NIL for anything else.  Only the first
line counts."
  (when text
    (let* ((end (or (position #\Newline text) (length text))))
      (loop while (and (> end 0) (member (char text (1- end)) '(#\Return #\Space)))
            do (decf end))
      (let ((colon (position #\: text :end end :from-end t)))
        (when (and colon (> colon 0) (all-digits-p text (1+ colon) end))
          (let ((line (parse-integer text :start (1+ colon) :end end)))
            (when (> line 0)
              (values (subseq text 0 colon) line))))))))
