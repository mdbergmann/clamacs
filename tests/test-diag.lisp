;;;; test-diag.lisp -- parsing clamiga's replies: the cases of
;;;; tests/test_diag.c, plus what C did not ask.

(in-package :clamacs)

(deftest located-diagnostic
  (let* ((line "Work:src/foo.lisp:3: ERROR: Too many arguments to FOO")
         (d (parse-diagnostic-line line)))
    (is d)
    ;; An Amiga path has a colon of its own, so the split cannot be on the
    ;; first one -- nor even on the second, for a path with an assign AND
    ;; a drive.
    (is-equal (diagnostic-file d) "Work:src/foo.lisp")
    (is-equal (diagnostic-line d) 3)
    (is-equal (diagnostic-severity d) :error)
    (is-equal (diagnostic-text d) "Too many arguments to FOO")
    (is-equal (diagnostic-rendered d) line)))

(deftest path-with-spaces-and-assigns
  (let ((d (parse-diagnostic-line "Ram Disk:my file.lisp:12: WARNING: unused variable X")))
    (is-equal (diagnostic-file d) "Ram Disk:my file.lisp")
    (is-equal (diagnostic-line d) 12)
    (is-equal (diagnostic-severity d) :warning)))

(deftest unlocated-diagnostic
  (let ((d (parse-diagnostic-line "ERROR: no such package: FOO")))
    (is d)
    (is-equal (diagnostic-file d) nil)
    (is-equal (diagnostic-line d) 0)
    (is-equal (diagnostic-severity d) :error)
    ;; The message keeps its own colons.
    (is-equal (diagnostic-text d) "no such package: FOO")))

(deftest style-warning-and-note
  (is-equal (diagnostic-severity (parse-diagnostic-line "a.lisp:1: STYLE-WARNING: x")) :warning)
  (is-equal (diagnostic-text (parse-diagnostic-line "a.lisp:1: STYLE-WARNING: x")) "x")
  (is-equal (diagnostic-severity (parse-diagnostic-line "NOTE: y")) :note))

(deftest message-containing-a-severity-word
  (let ((d (parse-diagnostic-line "foo.lisp:1: ERROR: the word ERROR: appears again")))
    (is-equal (diagnostic-file d) "foo.lisp")
    (is-equal (diagnostic-line d) 1)
    (is-equal (diagnostic-text d) "the word ERROR: appears again")))

(deftest a-prefix-without-a-line-number-is-the-file
  (let ((d (parse-diagnostic-line "foo.lisp: ERROR: no line")))
    (is-equal (diagnostic-file d) "foo.lisp")
    (is-equal (diagnostic-line d) 0)))

(deftest non-diagnostic-lines
  (dolist (line '("; loading Work:src/foo.lisp" "--- log ---" "just some output"
                  "a:b:c" "" "ERROR" "ERRORS: none" "x: ERRORX: y"))
    (is (null (parse-diagnostic-line line)))))

(deftest full-reply
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics
               list
               (lines "; loading Work:src/foo.lisp"
                      "Work:src/foo.lisp:3: ERROR: Too many arguments to FOO"
                      "Work:src/foo.lisp:7: WARNING: Undefined variable Y"
                      "1 error(s), 1 warning(s)"
                      "--- log ---"
                      "some compiler chatter"
                      ""))
              2)
    (is-equal (diaglist-count list) 2)
    (is-equal (diaglist-errors list) 1)
    (is-equal (diaglist-warnings list) 1)
    (is (diaglist-summary-seen list))
    (is-equal (diaglist-summary list) "1 error(s), 1 warning(s)")
    (is-equal (diagnostic-line (diaglist-ref list 0)) 3)
    (is-equal (diagnostic-severity (diaglist-ref list 0)) :error)
    (is-equal (diagnostic-line (diaglist-ref list 1)) 7)
    (is-equal (diagnostic-severity (diaglist-ref list 1)) :warning)
    (is-equal (diaglist-rendered list)
              '("Work:src/foo.lisp:3: ERROR: Too many arguments to FOO"
                "Work:src/foo.lisp:7: WARNING: Undefined variable Y"))
    ;; What the command printed, for the REPL transcript.
    (is-equal (diaglist-log list) (lines "some compiler chatter" ""))
    (diaglist-clear list)
    (is-equal (diaglist-count list) 0)
    (is (not (diaglist-summary-seen list)))
    (is (null (diaglist-log list)))))

(deftest the-log-is-kept-verbatim
  ;; Blank lines and indentation are the program's; a reply without a
  ;; trailing newline still gets one; CRs are stripped as on the rows.
  (let ((list (make-diaglist)))
    (parse-diagnostics list
                       (format nil "; loading a.lisp~%0 error(s), 0 warning(s)~%--- log ---~%hello~%~%  indented~C~%last" #\Return))
    (is-equal (diaglist-log list) (lines "hello" "" "  indented" "last" "")))
  ;; No log section, or an empty one: NIL, so nothing is shown for it.
  (let ((list (make-diaglist)))
    (parse-diagnostics list (lines "; loading a.lisp" "0 error(s), 0 warning(s)" ""))
    (is (null (diaglist-log list)))
    (parse-diagnostics list (lines "; loading a.lisp" "0 error(s), 0 warning(s)" "--- log ---" ""))
    (is (null (diaglist-log list)))))

(deftest the-log-section-is-not-parsed
  ;; The log holds clamiga's own error reports, which begin with `ERROR: '
  ;; -- reading those doubles the list, so `C-x `' walks into rows that are
  ;; not real.  Found on the Amiga.
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics
               list
               (lines "; loading Work:errors.lisp"
                      "Work:errors.lisp:7: ERROR: first deliberate error"
                      "Work:errors.lisp:9: ERROR: Undefined function: NO-SUCH-FUNCTION"
                      "2 error(s), 0 warning(s)"
                      "--- log ---"
                      "; Loading Work:errors.lisp"
                      "ERROR: SIMPLE-ERROR: first deliberate error"
                      "Backtrace:"
                      "  0: <anonymous> (Work:errors.lisp:7)"
                      "ERROR: Undefined function: NO-SUCH-FUNCTION"
                      ""))
              2)
    (is-equal (diaglist-count list) 2)
    (is-equal (diaglist-errors list) 2)
    (is-equal (diagnostic-line (diaglist-ref list 0)) 7)
    (is-equal (diagnostic-line (diaglist-ref list 1)) 9)))

(deftest truncation-is-seen-after-the-log
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics
               list
               (lines "foo.lisp:1: ERROR: boom"
                      "1 error(s), 0 warning(s)"
                      "--- log ---"
                      "ERROR: chatter that is not a diagnostic"
                      "[truncated at 8192 characters]"
                      ""))
              1)
    (is-equal (diaglist-count list) 1)
    (is (diaglist-truncated list))
    ;; The marker stays in the log: the transcript's reader sees the cut.
    (is-equal (diaglist-log list)
              (lines "ERROR: chatter that is not a diagnostic"
                     "[truncated at 8192 characters]" ""))))

(deftest clean-reply
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics list "; loading Work:src/foo.lisp
0 error(s), 0 warning(s)")
              0)
    (is (diaglist-summary-seen list))
    (is-equal (diaglist-errors list) 0)
    (is-equal (diaglist-warnings list) 0)))

(deftest markers
  (let ((list (make-diaglist)))
    (parse-diagnostics list (lines "foo.lisp:1: ERROR: boom"
                                   "1 error(s), 0 warning(s)"
                                   "; aborted -- the remaining forms were not processed"
                                   "[truncated at 8192 characters]"
                                   ""))
    (is (diaglist-aborted list))
    (is (diaglist-truncated list))
    (is-equal (diaglist-count list) 1)))

(deftest crlf-and-missing-final-newline
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics list (format nil "foo.lisp:1: ERROR: boom~C~%foo.lisp:2: ERROR: bang"
                                              #\Return))
              2)
    (is-equal (diagnostic-text (diaglist-ref list 0)) "boom")
    (is-equal (diagnostic-text (diaglist-ref list 1)) "bang")))

(deftest parse-accumulates
  (let ((list (make-diaglist)))
    (parse-diagnostics list (lines "a.lisp:1: ERROR: one" ""))
    (parse-diagnostics list (lines "b.lisp:2: ERROR: two" ""))
    (is-equal (diaglist-count list) 2)
    (is-equal (diagnostic-file (diaglist-ref list 0)) "a.lisp")
    (is-equal (diagnostic-file (diaglist-ref list 1)) "b.lisp")))

(deftest many-diagnostics-grow-the-list
  (let ((list (make-diaglist)))
    (dotimes (i 100)
      (parse-diagnostics list (lines "x.lisp:1: ERROR: boom" "")))
    (is-equal (diaglist-count list) 100)))

(deftest empty-input
  (let ((list (make-diaglist)))
    (is-equal (parse-diagnostics list "") 0)
    (is-equal (diaglist-count list) 0)))

(deftest summary-line-shapes
  (is-equal (multiple-value-list (parse-summary-line "2 error(s), 3 warning(s)")) '(2 3))
  (is-equal (multiple-value-list (parse-summary-line "  0 error(s), 0 warning(s)")) '(0 0))
  (is-equal (parse-summary-line "2 errors, 3 warnings") nil)
  (is-equal (parse-summary-line "error(s), 3 warning(s)") nil)
  (is-equal (parse-summary-line "2 error(s), warning(s)") nil)
  (is-equal (parse-summary-line "") nil))

(deftest source-location
  ;; SOURCE-LOCATION's reply: a path with its own colons, then the line.
  (is-equal (multiple-value-list (parse-location "Work:src/foo.lisp:12"))
            '("Work:src/foo.lisp" 12))
  ;; Only the first line counts, and a trailing newline is not a digit.
  (is-equal (multiple-value-list (parse-location (format nil "T:x.lisp:3~%[truncated]~%")))
            '("T:x.lisp" 3))
  (is-equal (multiple-value-list (parse-location (format nil "T:x.lisp:3 ~C" #\Return)))
            '("T:x.lisp" 3))
  ;; What an error reply looks like is not a location.
  (dolist (text '("ERROR: no source location recorded for foo" "foo.lisp"
                  "foo.lisp:0" ":12" "" nil))
    (is (null (parse-location text)))))
