;;;; test-winstore.lisp -- the snapshot of window positions, as data: the
;;;; cases of tests/test_winstore.c.
;;;;
;;;; What the file format promises: an entry round-trips through format and
;;;; parse; a comment, a blank line or a line that does not parse is skipped
;;;; and costs nothing else; a role is looked up by name and replaced in
;;;; place; the roles of file windows and scratch windows are derived the way
;;;; winstore.lisp says.

(in-package :clamacs)

(deftest winstore-empty-store
  (let ((s (make-winstore)))
    (is-equal (winstore-count s) 0)
    (is (null (winstore-find s "repl")))
    (is (null (winstore-find s nil)))
    ;; An empty store still formats to a valid file: the header only.
    (let ((out (winstore-format s)))
      (is (> (length out) 0))
      (is-equal (char out 0) #\;)
      (is-equal (winstore-parse s out) 0))))

(deftest winstore-set-and-find
  (let ((s (make-winstore)))
    (is (winstore-set s "repl" 10 20 640 400))
    (is (winstore-set s "doc1" 0 11 700 500))
    (is-equal (winstore-count s) 2)
    (let ((e (winstore-find s "repl")))
      (is e)
      (is-equal (winentry-left e) 10)
      (is-equal (winentry-top e) 20)
      (is-equal (winentry-width e) 640)
      (is-equal (winentry-height e) 400))
    ;; A second snapshot of the same window replaces, never duplicates.
    (is (winstore-set s "repl" 30 40 600 300))
    (is-equal (winstore-count s) 2)
    (is-equal (winentry-left (winstore-find s "repl")) 30)
    (is-equal (winentry-height (winstore-find s "repl")) 300)
    ;; Roles are exact: `Repl' is not `repl'.
    (is (null (winstore-find s "Repl")))
    (is (null (winstore-find s "doc")))))

(deftest winstore-set-rejects-what-it-cannot-hold
  (let ((s (make-winstore))
        (long (make-string (+ +winstore-name-max+ 8) :initial-element #\x)))
    (is (not (winstore-set s "" 1 2 3 4)))
    (is (not (winstore-set s nil 1 2 3 4)))
    (is (not (winstore-set s long 1 2 3 4)))
    ;; exactly the longest allowed
    (is (winstore-set s (subseq long 0 +winstore-name-max+) 1 2 3 4))
    (is-equal (winstore-count s) 1)
    (loop for i from 1 below +winstore-max+
          do (is (winstore-set s (format nil "doc~D" i) i i i i)))
    (is-equal (winstore-count s) +winstore-max+)
    ;; Full: a new role is refused, an existing one is still updated.
    (is (not (winstore-set s "one-too-many" 1 2 3 4)))
    (is (winstore-set s "doc1" 9 9 9 9))
    (is-equal (winentry-left (winstore-find s "doc1")) 9)
    (is-equal (winstore-count s) +winstore-max+)))

(deftest winstore-format-then-parse-round-trips
  (let ((a (make-winstore)) (b (make-winstore)))
    (winstore-set a "doc1" 0 11 640 200)
    (winstore-set a "doc2" 320 11 320 200)
    (winstore-set a "repl" 0 222 640 100)
    (winstore-set a "errors" -4 300 500 60)   ; a window pushed off the left edge
    (let ((text (winstore-format a)))
      (is (search (format nil "doc2 320 11 320 200~%") text))
      (is (search (format nil "errors -4 300 500 60~%") text))
      (is-equal (winstore-parse b text) 4)
      (is-equal (winstore-count b) 4)
      (is-equal (winentry-top (winstore-find b "repl")) 222)
      (is-equal (winentry-left (winstore-find b "errors")) -4)
      (is-equal (winentry-height (winstore-find b "errors")) 60))))

(deftest winstore-full-store-round-trips
  ;; The widest numbers and the longest roles, a full store.
  (let ((full (make-winstore)))
    (dotimes (i +winstore-max+)
      (let ((name (make-string +winstore-name-max+ :initial-element #\w)))
        (setf (char name 0) (code-char (+ (char-code #\a) (mod i 26)))
              (char name 1) (code-char (+ (char-code #\a) (floor i 26))))
        (is (winstore-set full name -99999 -99999 999999 999999))))
    (is-equal (winstore-count full) +winstore-max+)
    (is-equal (winstore-parse full (winstore-format full)) +winstore-max+)))

(deftest winstore-parse-is-forgiving
  (let* ((s (make-winstore))
         (cr (string #\Return))
         (text (lines "; a comment"
                      "# another"
                      ""
                      "   "
                      (concatenate 'string "doc1 10 20 300 400" cr)   ; CRLF, from a file edited elsewhere
                      (format nil "  repl~C5~C6~C7~C8  " #\Tab #\Tab #\Tab #\Tab) ; tabs and stray blanks
                      "errors 1 2 3"                     ; one number short: skipped
                      "debugger 1 2 3 4 5"               ; one too many: skipped
                      "inspector x 2 3 4"                ; not a number: skipped
                      "doc2 10 20 30 40 ; trailing"      ; junk after the numbers: skipped
                      "doc3 12345678 1 1 1"              ; absurd: skipped
                      "sevendigit 1000000 1 1 1"         ; one digit past the cap: skipped
                      "averyveryveryverylongrolename 1 2 3 4"   ; role too long: skipped
                      "apropos 0 0 0 0")))               ; no final newline
    (is-equal (winstore-parse s text) 3)
    (is-equal (winentry-height (winstore-find s "doc1")) 400)
    (is-equal (winentry-left (winstore-find s "repl")) 5)
    (is-equal (winentry-height (winstore-find s "repl")) 8)
    (is (winstore-find s "apropos"))
    (dolist (role '("errors" "debugger" "inspector" "doc2" "doc3" "sevendigit"))
      (is (null (winstore-find s role))))
    ;; A later line for the same role wins, as a hand edit would expect.
    (is-equal (winstore-parse s (lines "repl 1 1 1 1" "repl 2 2 2 2" "")) 2)
    (is-equal (winstore-count s) 1)
    (is-equal (winentry-left (winstore-find s "repl")) 2)
    ;; Parsing replaces: nothing of the old contents survives.
    (is-equal (winstore-parse s "") 0)
    (is-equal (winstore-count s) 0)
    (is-equal (winstore-parse s nil) 0)
    (is-equal (winstore-count s) 0)))

(deftest winstore-parse-survives-a-very-long-line
  ;; A 500-character line of digits, then a good entry after it.
  (let ((s (make-winstore))
        (text (concatenate 'string (make-string 500 :initial-element #\7)
                           (lines "" "repl 1 2 3 4" ""))))
    (is-equal (winstore-parse s text) 1)
    (is (winstore-find s "repl"))))

(deftest winstore-parse-line-exactly-fits
  ;; The C line buffer was 128 bytes; a 127-character line (the entry
  ;; padded with blanks) still parses, a 128-character one is dropped.
  (let ((s (make-winstore))
        (entry "doc1 1 2 3 4"))
    (flet ((padded (n)
             (concatenate 'string entry
                          (make-string (- n (length entry)) :initial-element #\Space)
                          (string #\Newline))))
      (is-equal (winstore-parse s (padded +winstore-line-max+)) 1)
      (is (winstore-find s "doc1"))
      (is-equal (winstore-parse s (padded (1+ +winstore-line-max+))) 0))))

(deftest winstore-doc-roles
  (is-equal (winstore-doc-role 1) "doc1")
  (is-equal (winstore-doc-role 12) "doc12")
  (is (null (winstore-doc-role 0)))
  (is (null (winstore-doc-role -3)))
  (is-equal (winstore-doc-slot "doc1") 1)
  (is-equal (winstore-doc-slot "doc12") 12)
  (dolist (role '("doc" "doc1x" "docs" "repl" "document" "" nil "doc99999999999"))
    (is (null (winstore-doc-slot role)))))

(deftest winstore-scratch-roles
  (is-equal (winstore-scratch-role "*clamacs-repl*") "repl")
  (is-equal (winstore-scratch-role "*clamacs-description*") "description")
  (is-equal (winstore-scratch-role "*clamacs-macroexpansion*") "macroexpansion")
  (is-equal (winstore-scratch-role "*scratch*") "scratch")
  (is-equal (winstore-scratch-role "no stars here") "no-stars-here")
  (is-equal (winstore-scratch-role "**") "")
  (is-equal (winstore-scratch-role nil) "")
  ;; A name longer than a role is cut to fit, never overrun.
  (let ((role (winstore-scratch-role "*clamacs-abcdefghijklmnopqrstuvwxyz0123456789*")))
    (is-equal (length role) +winstore-name-max+)
    (is (null (position #\* role))))
  ;; The role of a scratch window is never a file window's slot.
  (is (null (winstore-doc-slot "repl"))))
