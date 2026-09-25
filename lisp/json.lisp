;;;; json.lisp -- JSON in, JavaScript strings out.
;;;;
;;;; The host frontend's bindings (specs/clamacs-host.md) carry their
;;;; arguments as a JSON array in UTF-8, and what Lisp tells the page is a
;;;; JavaScript call whose string arguments must survive webview_eval.
;;;; Both ends of that boundary are here, and nowhere else.
;;;;
;;;; JSON-PARSE reads the whole grammar -- arrays, objects, strings with
;;;; every escape, numbers, the three literals -- into Lisp data:
;;;;
;;;;   array   -> a list            object -> an EQUAL hash table
;;;;   string  -> a SIMPLE-STRING   number -> an integer, or a float
;;;;   true    -> T                 false  -> NIL           null -> :NULL
;;;;
;;;; The input string holds the UTF-8 BYTES as characters 0-255, which is
;;;; how FFI:FOREIGN-TO-STRING hands a C string over; a multi-byte sequence
;;;; and a \uXXXX escape decode to their code point, kept when it fits the
;;;; editor's 8-bit text and turned into `?' otherwise -- as STORE-TEXT does
;;;; for MUI.  JSON-STRING writes a JavaScript string literal: every code
;;;; above 127 as \u00XX, so the C string given to webview_eval is ASCII.
;;;; JSON-ENCODE writes a value the way JSON-PARSE reads it, except that
;;;; NIL is `false' (a list is an array, so an empty array is #()).
;;;;
;;;; Pure: no MUI, no OS, no frontend.

(in-package :clamacs)

(define-condition json-error (error)
  ((message :initarg :message :reader json-error-message)
   (position :initarg :position :reader json-error-position))
  (:report (lambda (c stream)
             (format stream "JSON: ~A at ~D"
                     (json-error-message c) (json-error-position c)))))

(defun json-fail (message position)
  (error 'json-error :message message :position position))

;;; --- reading --------------------------------------------------------

(defun json-whitespace-p (c)
  (or (char= c #\Space) (char= c #\Tab) (char= c #\Newline) (char= c #\Return)))

(defun json-skip-whitespace (s i)
  (declare (simple-string s) (fixnum i))
  (let ((n (length s)))
    (loop while (and (< i n) (json-whitespace-p (schar s i)))
          do (incf i))
    i))

(defun json-code-char (code)
  "The character for a decoded code point: itself below 256, `?' above."
  (if (< code 256) (code-char code) #\?))

(defun json-utf8-char (s i)
  "Decode the UTF-8 sequence starting at S[I] (a byte above 127): the
character and the index after it.  A byte that starts no well-formed
sequence is a `?' of its own, and decoding goes on with the next byte."
  (declare (simple-string s) (fixnum i))
  (let* ((n (length s))
         (b0 (char-code (schar s i)))
         (count (cond ((= (logand b0 #xE0) #xC0) 1)
                      ((= (logand b0 #xF0) #xE0) 2)
                      ((= (logand b0 #xF8) #xF0) 3)
                      (t nil)))
         (code (and count
                    (logand b0 (case count (1 #x1F) (2 #x0F) (t #x07))))))
    (if (or (null count) (> (+ i count) (1- n)))
        (values #\? (1+ i))
        (dotimes (k count (values (json-code-char code) (+ i count 1)))
          (let ((b (char-code (schar s (+ i k 1)))))
            (unless (= (logand b #xC0) #x80)
              (return (values #\? (1+ i))))
            (setq code (logior (ash code 6) (logand b #x3F))))))))

(defun json-hex4 (s i)
  "The four hex digits at S[I..I+3], or a JSON-ERROR."
  (declare (simple-string s) (fixnum i))
  (when (> (+ i 4) (length s))
    (json-fail "truncated \\u escape" i))
  (let ((code (parse-integer s :start i :end (+ i 4) :radix 16 :junk-allowed t)))
    ;; JUNK-ALLOWED accepts a shorter run of digits; the escape needs four.
    (unless (and code
                 (dotimes (k 4 t)
                   (unless (digit-char-p (schar s (+ i k)) 16)
                     (return nil))))
      (json-fail "bad \\u escape" i))
    code))

(defun json-read-string (s i)
  "S[I] is the opening quote: the string and the index after the closing
one."
  (declare (simple-string s) (fixnum i))
  (let ((n (length s))
        (out (make-string-output-stream)))
    (incf i)
    (loop
      (when (>= i n)
        (json-fail "unterminated string" i))
      (let ((c (schar s i)))
        (cond ((char= c #\")
               (return (values (coerce (get-output-stream-string out) 'simple-string)
                               (1+ i))))
              ((char= c #\\)
               (when (>= (1+ i) n)
                 (json-fail "unterminated escape" i))
               (let ((e (schar s (1+ i))))
                 (incf i 2)
                 (case e
                   (#\" (write-char #\" out))
                   (#\\ (write-char #\\ out))
                   (#\/ (write-char #\/ out))
                   (#\b (write-char (code-char 8) out))
                   (#\f (write-char (code-char 12) out))
                   (#\n (write-char #\Newline out))
                   (#\r (write-char #\Return out))
                   (#\t (write-char #\Tab out))
                   (#\u
                    (let ((code (json-hex4 s i)))
                      (incf i 4)
                      ;; A surrogate pair is one character, above 255 always.
                      (when (and (<= #xD800 code #xDBFF)
                                 (<= (+ i 6) n)
                                 (char= (schar s i) #\\)
                                 (char= (schar s (1+ i)) #\u))
                        (let ((low (json-hex4 s (+ i 2))))
                          (when (<= #xDC00 low #xDFFF)
                            (incf i 6)
                            (setq code #x10000))))
                      (write-char (json-code-char code) out)))
                   (t (json-fail "unknown escape" (- i 2))))))
              ((< (char-code c) 128)
               (write-char c out)
               (incf i))
              (t
               (multiple-value-bind (ch next) (json-utf8-char s i)
                 (write-char ch out)
                 (setq i next))))))))

(defun json-read-number (s i)
  (declare (simple-string s) (fixnum i))
  (let ((n (length s))
        (start i)
        (float nil))
    (flet ((digits ()
             (let ((from i))
               (loop while (and (< i n) (digit-char-p (schar s i)))
                     do (incf i))
               (when (= i from)
                 (json-fail "digit expected" i)))))
      (when (and (< i n) (char= (schar s i) #\-))
        (incf i))
      (digits)
      (when (and (< i n) (char= (schar s i) #\.))
        (setq float t)
        (incf i)
        (digits))
      (when (and (< i n) (char-equal (schar s i) #\e))
        (setq float t)
        (incf i)
        (when (and (< i n) (member (schar s i) '(#\+ #\-)))
          (incf i))
        (digits)))
    (values (if float
                ;; The text was checked against the number grammar above,
                ;; so the reader sees a float and nothing else.
                (let ((*read-default-float-format* 'single-float)
                      (*read-eval* nil))
                  (read-from-string (subseq s start i)))
                (parse-integer s :start start :end i))
            i)))

(defun json-read-value (s i)
  "The value at S[I] (whitespace allowed before it) and the index after."
  (declare (simple-string s) (fixnum i))
  (setq i (json-skip-whitespace s i))
  (let ((n (length s)))
    (when (>= i n)
      (json-fail "value expected" i))
    (let ((c (schar s i)))
      (flet ((literal (word value)
               (let ((end (+ i (length word))))
                 (unless (and (<= end n) (string= s word :start1 i :end1 end))
                   (json-fail "unknown literal" i))
                 (values value end))))
        (cond ((char= c #\") (json-read-string s i))
              ((char= c #\[)
               (let ((items '()))
                 (incf i)
                 (setq i (json-skip-whitespace s i))
                 (if (and (< i n) (char= (schar s i) #\]))
                     (values '() (1+ i))
                     (loop
                       (multiple-value-bind (value next) (json-read-value s i)
                         (push value items)
                         (setq i (json-skip-whitespace s next)))
                       (when (>= i n)
                         (json-fail "unterminated array" i))
                       (case (schar s i)
                         (#\, (incf i))
                         (#\] (return (values (nreverse items) (1+ i))))
                         (t (json-fail "`,' or `]' expected" i)))))))
              ((char= c #\{)
               (let ((table (make-hash-table :test 'equal)))
                 (incf i)
                 (setq i (json-skip-whitespace s i))
                 (if (and (< i n) (char= (schar s i) #\}))
                     (values table (1+ i))
                     (loop
                       (setq i (json-skip-whitespace s i))
                       (unless (and (< i n) (char= (schar s i) #\"))
                         (json-fail "key expected" i))
                       (multiple-value-bind (key next) (json-read-string s i)
                         (setq i (json-skip-whitespace s next))
                         (unless (and (< i n) (char= (schar s i) #\:))
                           (json-fail "`:' expected" i))
                         (multiple-value-bind (value next) (json-read-value s (1+ i))
                           (setf (gethash key table) value)
                           (setq i (json-skip-whitespace s next))))
                       (when (>= i n)
                         (json-fail "unterminated object" i))
                       (case (schar s i)
                         (#\, (incf i))
                         (#\} (return (values table (1+ i))))
                         (t (json-fail "`,' or `}' expected" i)))))))
              ((char= c #\t) (literal "true" t))
              ((char= c #\f) (literal "false" nil))
              ((char= c #\n) (literal "null" :null))
              ((or (char= c #\-) (digit-char-p c)) (json-read-number s i))
              (t (json-fail "unexpected character" i)))))))

(defun json-parse (string)
  "The one JSON value STRING holds; a JSON-ERROR names what is wrong and
where."
  (let ((s (coerce string 'simple-string)))
    (multiple-value-bind (value end) (json-read-value s 0)
      (let ((end (json-skip-whitespace s end)))
        (unless (= end (length s))
          (json-fail "trailing characters" end)))
      value)))

;;; --- writing --------------------------------------------------------

(defun json-write-string (string stream)
  (write-char #\" stream)
  (loop for c across string
        for code = (char-code c)
        do (cond ((char= c #\") (write-string "\\\"" stream))
                 ((char= c #\\) (write-string "\\\\" stream))
                 ((char= c #\Newline) (write-string "\\n" stream))
                 ((char= c #\Return) (write-string "\\r" stream))
                 ((char= c #\Tab) (write-string "\\t" stream))
                 ((or (< code 32) (> code 126))
                  (if (< code #x10000)
                      (format stream "\\u~4,'0X" code)
                      (write-char #\? stream)))
                 (t (write-char c stream))))
  (write-char #\" stream))

(defun json-string (string)
  "STRING as a JavaScript string literal, quotes included, all ASCII."
  (with-output-to-string (out)
    (json-write-string string out)))

(defun json-write (value stream)
  (cond ((eq value t) (write-string "true" stream))
        ((null value) (write-string "false" stream))
        ((eq value :null) (write-string "null" stream))
        ((stringp value) (json-write-string value stream))
        ((integerp value) (format stream "~D" value))
        ((floatp value)
         (let ((*read-default-float-format* (type-of value)))
           (format stream "~F" value)))
        ((consp value)
         (write-char #\[ stream)
         (loop for (item . more) on value
               do (json-write item stream)
                  (when more (write-char #\, stream)))
         (write-char #\] stream))
        ((vectorp value)
         (write-char #\[ stream)
         (dotimes (i (length value))
           (when (> i 0) (write-char #\, stream))
           (json-write (aref value i) stream))
         (write-char #\] stream))
        ((hash-table-p value)
         (write-char #\{ stream)
         (let ((first t))
           (maphash (lambda (key item)
                      (unless first (write-char #\, stream))
                      (setq first nil)
                      (json-write-string (string key) stream)
                      (write-char #\: stream)
                      (json-write item stream))
                    value))
         (write-char #\} stream))
        ((symbolp value) (json-write-string (string-downcase (symbol-name value)) stream))
        (t (error "JSON: cannot encode ~S" value))))

(defun json-encode (value)
  "VALUE as JSON text: T true, NIL false, :NULL null, a list or vector an
array, a hash table an object, another symbol its lower-cased name."
  (with-output-to-string (out)
    (json-write value out)))
