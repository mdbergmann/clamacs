;;;; replmsg.lisp -- what clamiga's REPL thread sends, and the lines of the
;;;; debugger's and the inspector's replies.
;;;;
;;;; The port of src/rexx/replmsg.c and src/rexx/dbgmsg.c.  Four commands
;;;; arrive at the editor's OWN port from clamiga's REPL thread
;;;; (lib/dev-repl.lisp): OUTPUT with a chunk of program output, READLINE,
;;;; RESULT and DEBUGGER with a header `<number> <package>' and a body after
;;;; the first newline.  The verb is split off by EXT.DEV before a port verb
;;;; sees its argument (OUTPUT, RESULT and DEBUGGER are raw verbs there, so
;;;; the argument is verbatim); PARSE-REPL-MESSAGE does the whole job for a
;;;; caller that has the raw line, and PARSE-RESULT-HEADER the header for
;;;; one that has the argument.  The strings the tests use are what
;;;; cl-amiga's tests/test_dev_commands.sh shows the REPL thread sending, so
;;;; the two ends are pinned to one wire format from both sides.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The REPL thread's commands
;;; ------------------------------------------------------------------

(defun repl-verb-length (raw verb)
  "The length of VERB when RAW starts with it (case-insensitively) as a
whole word -- followed by a blank, a newline or the end -- else NIL."
  (let ((n (length verb)))
    (and (>= (length raw) n)
         (string-equal raw verb :end1 n)
         (or (= (length raw) n)
             (member (char raw n) '(#\Space #\Newline)))
         n)))

(defun parse-result-header (text)
  "The argument of RESULT or DEBUGGER: `<number> <package>' on the first
line, the body after it.  Three values -- the number, the package and the
body (\"\" when the header stands alone) -- or NIL for a header that is
not one."
  (let* ((text (or text ""))
         (len (length text))
         (p 0)
         (n 0)
         (digits 0))
    (loop while (and (< p len) (char= (char text p) #\Space)) do (incf p))
    (loop while (and (< p len) (digit-char-p (char text p)))
          do (setq n (+ (* n 10) (digit-char-p (char text p))))
             (incf p)
             (incf digits))
    (when (zerop digits)
      (return-from parse-result-header nil))
    (loop while (and (< p len) (char= (char text p) #\Space)) do (incf p))
    (let ((start p))
      (loop while (and (< p len)
                       (not (member (char text p) '(#\Space #\Newline #\Return))))
            do (incf p))
      (when (= p start)
        (return-from parse-result-header nil))
      (let ((package (subseq text start p))
            (nl (position #\Newline text :start p)))
        (values n package (if nl (subseq text (1+ nl)) ""))))))

(defun parse-repl-message (raw)
  "RAW, a command as the REPL thread sends it.  Four values: the kind
(:OUTPUT :READLINE :RESULT :DEBUGGER), the number (RESULT's rc, DEBUGGER's
level; 0 otherwise), the package (\"\" when none) and the text -- OUTPUT's
chunk, verbatim past the verb's one blank; the body of the other two.  NIL
for anything else, malformed headers included."
  (when raw
    (let ((n nil))
      (cond ((setq n (repl-verb-length raw "OUTPUT"))
             (values :output 0 ""
                     (if (and (< n (length raw)) (char= (char raw n) #\Space))
                         (subseq raw (1+ n))
                         (subseq raw n))))
            ((repl-verb-length raw "READLINE")
             (values :readline 0 "" ""))
            ((or (setq n (repl-verb-length raw "RESULT"))
                 (setq n (repl-verb-length raw "DEBUGGER")))
             (multiple-value-bind (number package body) (parse-result-header (subseq raw n))
               (and number
                    (values (if (char-equal (char raw 0) #\R) :result :debugger)
                            number package body))))
            (t nil)))))

;;; ------------------------------------------------------------------
;;; The lines of a reply
;;; ------------------------------------------------------------------

(defun message-lines (text)
  "The lines of TEXT without their line ends (LF or CR LF), empty ones
included; NIL for no text.  A list of rows for a window starts here."
  (let ((lines '())
        (start 0)
        (text (or text "")))
    (loop
      (when (>= start (length text))
        (return (nreverse lines)))
      (let* ((nl (or (position #\Newline text :start start) (length text)))
             (end nl))
        (when (and (> end start) (char= (char text (1- end)) #\Return))
          (decf end))
        (push (subseq text start end) lines)
        (setq start (1+ nl))))))

(defun message-rows (text)
  "MESSAGE-LINES without the empty lines: what a list window shows."
  (remove "" (message-lines text) :test #'string=))

(defun dbg-row-index (line)
  "The number a row starts with (`12: Cdr = (2 3)'), or NIL: the restarts,
the frames and the inspector's parts are all numbered that way, and the
number is the row's own, not its position in a list."
  (when line
    (let ((colon (position #\: line)))
      (and colon
           (> colon 0)
           (every #'digit-char-p (subseq line 0 colon))
           (parse-integer line :end colon)))))

(defun dbg-frame-location (line)
  "The `<file>:<line>' a backtrace row ends with, as two values, or NIL.
The location follows the LAST run of two blanks (a function name holds no
blank, a file name may), and the line number is what follows the last
colon, so an Amiga path keeps its device colon."
  (when line
    (let ((sep (search "  " line :from-end t)))
      (when sep
        (let* ((p (position #\Space line :start sep :test-not #'char=))
               (colon (and p (position #\: line :from-end t))))
          (when (and p colon (> colon p))
            (let* ((digits (subseq line (1+ colon)))
                   (digits (string-right-trim '(#\Return #\Newline) digits)))
              (when (and (plusp (length digits)) (every #'digit-char-p digits))
                (values (subseq line p colon) (parse-integer digits))))))))))

(defun inspect-header (text)
  "The first line of an INSPECT reply, `<TYPE> <depth> <count>': three
values, or NIL when TEXT does not start with one."
  (when text
    (let* ((end (or (position-if (lambda (c) (member c '(#\Newline #\Return))) text)
                    (length text)))
           (words (split-words (subseq text 0 end))))
      (when (= (length words) 3)
        (let ((depth (parse-integer (second words) :junk-allowed t))
              (count (parse-integer (third words) :junk-allowed t)))
          (when (and depth count
                     (every #'digit-char-p (second words))
                     (every #'digit-char-p (third words)))
            (values (first words) depth count)))))))
