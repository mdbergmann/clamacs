;;;; test-json.lisp -- the JSON reader and the JavaScript string writer
;;;; (lisp/json.lisp): what the host frontend's bindings carry.

(in-package :clamacs)

(defun bytes-string (&rest codes)
  "A string holding CODES (byte values, or characters) as characters --
the UTF-8 bytes of a C string as FFI:FOREIGN-TO-STRING hands them over."
  (coerce (mapcar (lambda (c) (if (characterp c) c (code-char c))) codes)
          'simple-string))

(defun json-fails-p (text)
  (handler-case (progn (json-parse text) nil)
    (json-error () t)))

;;; --- reading ----------------------------------------------------------

(deftest json-reads-the-literals-and-numbers
  (is-equal (json-parse "true") t)
  (is-equal (json-parse "false") nil)
  (is-equal (json-parse "null") :null)
  (is-equal (json-parse "0") 0)
  (is-equal (json-parse "-17") -17)
  (is-equal (json-parse "  42  ") 42)
  (is-equal (json-parse "123456789012") 123456789012)
  (is (= (json-parse "1.5") 1.5))
  (is (= (json-parse "-2.25e1") -22.5))
  (is (= (json-parse "1E2") 100))
  (is (floatp (json-parse "1e2"))))

(deftest json-reads-strings-and-escapes
  (is-equal (json-parse "\"\"") "")
  (is-equal (json-parse "\"plain\"") "plain")
  (is (simple-string-p (json-parse "\"plain\"")))
  (is-equal (json-parse "\"a\\\"b\\\\c\\/d\"") "a\"b\\c/d")
  (is-equal (json-parse "\"x\\ny\\tz\\r\"")
            (format nil "x~%y~Cz~C" #\Tab #\Return))
  (is-equal (json-parse "\"\\b\\f\"") (coerce (list (code-char 8) (code-char 12)) 'string))
  (is-equal (json-parse "\"\\u0041\\u00e9\"") (bytes-string 65 #xE9))
  ;; Above 255: the editor's text is 8-bit, so `?'
  (is-equal (json-parse "\"\\u20ac\"") "?")
  ;; A surrogate pair is ONE character above 255
  (is-equal (json-parse "\"a\\ud83d\\ude00b\"") "a?b")
  ;; A lone surrogate is a `?' of its own
  (is-equal (json-parse "\"\\ud83dx\"") "?x"))

(deftest json-decodes-utf8-bytes
  ;; e-acute is C3 A9 in UTF-8 and #xE9 in the editor's text
  (is-equal (json-parse (bytes-string #\" #xC3 #xA9 #\")) (bytes-string #xE9))
  (is-equal (json-parse (bytes-string #\" #\a #xC3 #xA9 #\b #\")) (bytes-string #\a #xE9 #\b))
  ;; The euro sign (E2 82 AC) and an emoji (F0 9F 98 80) are one `?' each
  (is-equal (json-parse (bytes-string #\" #xE2 #x82 #xAC #\")) "?")
  (is-equal (json-parse (bytes-string #\" #xF0 #x9F #x98 #x80 #\x #\")) "?x")
  ;; A byte that is not part of a well-formed sequence is a `?' of its
  ;; own, and decoding goes on with the next byte
  (is-equal (json-parse (bytes-string #\" #xC3 #\a #\")) "?a")
  (is-equal (json-parse (bytes-string #\" #xFF #\")) "?")
  (is-equal (json-parse (bytes-string #\" #x82 #\b #\")) "?b")
  ;; Truncated before the closing quote: the lead byte and the stray
  ;; continuation byte are one `?' each
  (is-equal (json-parse (bytes-string #\" #\a #xE2 #x82 #\")) "a??")
  (is (json-fails-p (bytes-string #\" #\a #xE2))))

(deftest json-reads-arrays-and-objects
  (is-equal (json-parse "[]") '())
  (is-equal (json-parse "[ ]") '())
  (is-equal (json-parse "[1,\"two\",true,null,[3,[4]]]") '(1 "two" t :null (3 (4))))
  (is-equal (json-parse " [ 1 , 2 ] ") '(1 2))
  ;; The bindings' arguments, as the page sends them
  (is-equal (json-parse "[\"doc1\",\"x\",\"KeyX\",true,false,false,false,\"text\"]")
            '("doc1" "x" "KeyX" t nil nil nil "text"))
  (is-equal (json-parse "[\"d\",[[0,0,\"ab\"],[5,7,\"\"]],7]")
            '("d" ((0 0 "ab") (5 7 "")) 7))
  (let ((table (json-parse "{\"a\":1,\"b\":[true],\"c\":{\"d\":null}}")))
    (is (hash-table-p table))
    (is-equal (hash-table-count table) 3)
    (is-equal (gethash "a" table) 1)
    (is-equal (gethash "b" table) '(t))
    (is-equal (gethash "d" (gethash "c" table)) :null))
  (is-equal (hash-table-count (json-parse "{}")) 0)
  (is-equal (hash-table-count (json-parse "{ }")) 0))

(deftest json-refuses-what-is-not-json
  (dolist (bad '("" "   " "[1,]" "[1" "[1 2]" "{\"a\":1" "{\"a\" 1}" "{a:1}"
                 "\"open" "\"bad\\q\"" "\"\\u12\"" "\"\\u12G4\"" "tru" "nul"
                 "01x" "-" "1." "1e" "[1]]" "[1] 2" "x"))
    (unless (json-fails-p bad)
      (test-failure `(json-fails-p ,bad))))
  ;; The condition says where
  (handler-case (json-parse "[1,]")
    (json-error (e)
      (is-equal (json-error-position e) 3)
      (is (search "JSON:" (princ-to-string e))))))

;;; --- writing ----------------------------------------------------------

(deftest json-string-is-an-ascii-js-literal
  (is-equal (json-string "") "\"\"")
  (is-equal (json-string "plain") "\"plain\"")
  (is-equal (json-string "a\"b\\c") "\"a\\\"b\\\\c\"")
  (is-equal (json-string (format nil "x~%y~Cz~C" #\Tab #\Return)) "\"x\\ny\\tz\\r\"")
  (is-equal (json-string (coerce (list (code-char 1) (code-char 127)) 'string))
            "\"\\u0001\\u007F\"")
  ;; The editor's 8-bit characters go over as \u00XX, so the C string
  ;; handed to webview_eval is ASCII
  (is-equal (json-string (bytes-string #xE9 #xFF)) "\"\\u00E9\\u00FF\"")
  (loop for c across (json-string (bytes-string 200 10 34 92 7))
        do (unless (< (char-code c) 128)
             (test-failure '(ascii-p (json-string ...)))))
  ;; What is written reads back
  (let ((text (bytes-string #\a #xE9 10 34 92 9 13 0 127 #\z)))
    (is-equal (json-parse (json-string text)) text)))

(deftest json-encode-writes-what-json-parse-reads
  (is-equal (json-encode t) "true")
  (is-equal (json-encode nil) "false")
  (is-equal (json-encode :null) "null")
  (is-equal (json-encode 42) "42")
  (is-equal (json-encode -1) "-1")
  (is-equal (json-encode "s\"") "\"s\\\"\"")
  (is-equal (json-encode '(1 "a" t nil (2))) "[1,\"a\",true,false,[2]]")
  ;; NIL is false, so the empty array is a vector
  (is-equal (json-encode #()) "[]")
  (is-equal (json-encode #(1 2)) "[1,2]")
  (is-equal (json-encode :source) "\"source\"")
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "k" table) '(1))
    (is-equal (json-encode table) "{\"k\":[1]}"))
  (is-equal (json-parse (json-encode '(1 "two" (t nil) :null))) '(1 "two" (t nil) :null))
  (is (search "1.5" (json-encode 1.5))))
