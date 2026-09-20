;;;; test-replmsg.lisp -- the commands clamiga's REPL thread sends to the
;;;; editor, and the lines of the debugger's and inspector's replies: the
;;;; cases of tests/test_replmsg.c and tests/test_dbgmsg.c.  The strings are
;;;; what cl-amiga's tests/test_dev_commands.sh shows the other end sending
;;;; (`OUTPUT hello', `RESULT 0 CL-USER' with the value on the next line,
;;;; `0: dbg-fn  <file>:27', `ARG0 = 3', `CONS 1 2'), so the two ends are
;;;; pinned to one wire format from both sides.

(in-package :clamacs)

(defun msg (raw)
  (multiple-value-list (parse-repl-message raw)))

;;; --- the REPL thread's commands ----------------------------------------------

(deftest output-keeps-its-text-verbatim
  (is-equal (msg (format nil "OUTPUT hello~%")) (list :output 0 "" (format nil "hello~%")))
  ;; Leading blanks belong to the chunk: an indented line of output must
  ;; not lose its indentation.  Only the verb's own separator goes.
  (is-equal (fourth (msg (format nil "OUTPUT   indented~%"))) (format nil "  indented~%"))
  ;; A chunk with quotes -- balanced or not -- is text, not syntax.
  (is-equal (fourth (msg "OUTPUT say \"hi")) "say \"hi")
  ;; Several lines in one chunk.
  (is-equal (fourth (msg (format nil "OUTPUT a~%b~%c~%"))) (format nil "a~%b~%c~%"))
  ;; An empty chunk, both spellings.
  (is-equal (msg "OUTPUT ") (list :output 0 "" ""))
  (is-equal (msg "OUTPUT") (list :output 0 "" "")))

(deftest readline-has-no-argument
  (is-equal (first (msg "READLINE")) :readline)
  (is-equal (first (msg (format nil "READLINE~%"))) :readline))

(deftest result-carries-rc-package-and-values
  (is-equal (msg (format nil "RESULT 0 CL-USER~%5")) (list :result 0 "CL-USER" "5"))
  ;; Several values, one per line, and the no-values marker.
  (is-equal (fourth (msg (format nil "RESULT 0 CL-USER~%1~%2~%3"))) (format nil "1~%2~%3"))
  (is-equal (fourth (msg (format nil "RESULT 0 CL-USER~%; No values"))) "; No values")
  ;; An error: rc 10 and the text after the newline.
  (is-equal (msg (format nil "RESULT 10 EXT.DEV~%ERROR: boom")) (list :result 10 "EXT.DEV" "ERROR: boom"))
  ;; No newline at all: nothing follows the header.
  (is-equal (msg "RESULT 0 CL-USER") (list :result 0 "CL-USER" "")))

(deftest debugger-carries-level-package-and-body
  ;; What lib/dev-repl.lisp sends on entry: the level and package on the
  ;; header line, then the condition and one restart per line.
  (is-equal (msg (format nil "DEBUGGER 1 CL-USER~%SIMPLE-ERROR: bad 12~%0: ABORT Return to the REPL"))
            (list :debugger 1 "CL-USER" (format nil "SIMPLE-ERROR: bad 12~%0: ABORT Return to the REPL")))
  ;; A nested level.
  (is-equal (subseq (msg (format nil "DEBUGGER 2 EXT.DEV~%SIMPLE-ERROR: nested~%0: ABORT Return to debugger level 1")) 0 3)
            (list :debugger 2 "EXT.DEV"))
  ;; Level 0 -- the debugger was left -- has no body.
  (is-equal (msg "DEBUGGER 0 CL-USER") (list :debugger 0 "CL-USER" ""))
  ;; The same header rules as RESULT.
  (is-equal (msg "DEBUGGER") '(nil))
  (is-equal (msg "DEBUGGER x CL-USER") '(nil))
  (is-equal (msg "DEBUGGER 1") '(nil))
  (is-equal (msg "DEBUGGERS 1 CL-USER") '(nil)))

(deftest verbs-match-like-mui-does
  ;; MUI matches its command names case-insensitively; so do we.
  (is-equal (first (msg "output x")) :output)
  (is-equal (first (msg (format nil "Result 0 CL-USER~%1"))) :result)
  ;; But a verb is a whole word: OUTPUTS is not OUTPUT.
  (is-equal (msg "OUTPUTS x") '(nil)))

(deftest malformed-and-foreign-commands-are-rejected
  (is-equal (msg "STATUS") '(nil))
  (is-equal (msg "") '(nil))
  (is-equal (msg nil) '(nil))
  (is-equal (msg "RESULT") '(nil))            ; no rc
  (is-equal (msg "RESULT x CL-USER") '(nil))  ; no rc
  (is-equal (msg "RESULT 0") '(nil))          ; no package
  (is-equal (msg (format nil "RESULT 0~%5")) '(nil)))

(deftest the-result-header-alone-is-what-a-raw-verb-gets
  ;; EXT.DEV splits the verb off; the port verb parses the rest.
  (is-equal (multiple-value-list (parse-result-header (format nil "0 CL-USER~%3"))) '(0 "CL-USER" "3"))
  (is-equal (multiple-value-list (parse-result-header "  10  EXT.DEV")) '(10 "EXT.DEV" ""))
  (is-equal (multiple-value-list (parse-result-header "CL-USER")) '(nil))
  (is-equal (multiple-value-list (parse-result-header "")) '(nil))
  (is-equal (multiple-value-list (parse-result-header nil)) '(nil)))

;;; --- the lines of a reply -----------------------------------------------------

(deftest lines-are-split-without-their-newlines
  (is-equal (message-lines (format nil "first~%second~C~%~%last" #\Return))
            '("first" "second" "" "last"))
  (is-equal (message-lines "") '())
  (is-equal (message-lines nil) '())
  (is-equal (message-lines (format nil "one~%")) '("one"))
  (is-equal (message-rows (format nil "a~%~%b~%")) '("a" "b")))

(deftest row-index-is-the-leading-number
  (is-equal (dbg-row-index "0: ABORT Return to the REPL") 0)
  (is-equal (dbg-row-index "12: Cdr = (2 3)") 12)
  (is (null (dbg-row-index "ARG0 = 3")))
  (is (null (dbg-row-index "SIMPLE-ERROR: boom")))
  (is (null (dbg-row-index ": no")))
  (is (null (dbg-row-index "")))
  (is (null (dbg-row-index nil))))

(deftest frame-location-is-file-and-line-after-two-blanks
  (is-equal (multiple-value-list (dbg-frame-location "0: dbg-fn  T:dbg.lisp:27")) '("T:dbg.lisp" 27))
  ;; An Amiga path keeps its device colon; a path with a blank in it is
  ;; still one file.
  (is-equal (multiple-value-list (dbg-frame-location "3: foo  Work:my src/a.lisp:5")) '("Work:my src/a.lisp" 5))
  ;; No location: an anonymous frame, a frame with a name only.
  (is (null (dbg-frame-location "1: <anonymous>")))
  (is (null (dbg-frame-location "1: foo")))
  ;; Two blanks but no line number after the last colon.
  (is (null (dbg-frame-location "1: foo  Work:")))
  (is (null (dbg-frame-location "1: foo  nocolon")))
  (is (null (dbg-frame-location nil))))

(deftest inspect-header-carries-type-depth-and-count
  (is-equal (multiple-value-list (inspect-header (format nil "CONS 1 2~%(1 (2 3))~%0: Car = 1~%")))
            '("CONS" 1 2))
  ;; A leaf: no parts, and nothing after the object line.
  (is-equal (multiple-value-list (inspect-header (format nil "FIXNUM 3 0~%42"))) '("FIXNUM" 3 0))
  ;; The header alone, and one with a Windows-style line end.
  (is-equal (multiple-value-list (inspect-header "SIMPLE-VECTOR 1 10")) '("SIMPLE-VECTOR" 1 10))
  (is-equal (multiple-value-list (inspect-header (format nil "CONS 1 2~C~%x" #\Return))) '("CONS" 1 2))
  ;; Not a header: an error line, a count that is not a number, nothing.
  (is (null (inspect-header "ERROR: no such variable")))
  (is (null (inspect-header "CONS 1 x")))
  (is (null (inspect-header "CONS 1")))
  (is (null (inspect-header "")))
  (is (null (inspect-header nil))))
