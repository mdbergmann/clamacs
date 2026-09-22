;;;; test-port.lisp -- the editor's own command set, on the fake frontend:
;;;; what verify/realamiga/drive.rexx sends, answered the same way.

(in-package :clamacs)

;;; *SAMPLE-TEXT*, SAMPLE-DOC and PORT are in fake-transport.lisp: the menu
;;; and snapshot tests drive the port too.

;;; --- arguments ---------------------------------------------------------------

(deftest split-words-honours-quotes
  (is-equal (split-words "a b  c") '("a" "b" "c"))
  (is-equal (split-words "\"Ram Disk:x y\" 3") '("Ram Disk:x y" "3"))
  (is-equal (split-words "") '())
  (is-equal (split-words "\"\"") '(""))
  (is-equal (split-words "a\"b c\"d") '("ab cd")))

(deftest parse-template-takes-names-and-positions
  (is-equal (parse-template "FILE x.lisp LINE 2" '("FILE" "LINE")) '(("FILE" . "x.lisp") ("LINE" . "2")))
  (is-equal (parse-template "x.lisp 2" '("FILE" "LINE")) '(("FILE" . "x.lisp") ("LINE" . "2")))
  (is-equal (parse-template "line 2 file x.lisp" '("FILE" "LINE")) '(("FILE" . "x.lisp") ("LINE" . "2")))
  (is-equal (parse-template "\"Ram Disk:a b.lisp\"" '("FILE" "LINE")) '(("FILE" . "Ram Disk:a b.lisp") ("LINE")))
  (is-equal (parse-template "" '("FILE" "LINE")) '(("FILE") ("LINE")))
  (is-equal (template-value (parse-template "x 3" '("FILE" "LINE")) "LINE") "3")
  (is-equal (template-value (parse-template "x" '("FILE" "LINE")) "LINE") nil)
  (is-equal (parse-template "FILE" '("FILE" "LINE")) '(("FILE") ("LINE")))
  (is-equal (parse-template "LINE" '("FILE" "LINE")) '(("FILE") ("LINE"))))

;;; --- dispatch ------------------------------------------------------------------

(deftest verbs-are-case-insensitive-and-unknown-ones-are-fatal
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "getfile") '(0 "Clamacs:verify/realamiga/sample.lisp"))
      (is-equal (port editor "  GETFILE  ") '(0 "Clamacs:verify/realamiga/sample.lisp"))
      (is-equal (port editor "") '(0 ""))
      (let ((answer (port editor "NOSUCHVERB")))
        (is-equal (first answer) 20)
        (is (search "unknown command: NOSUCHVERB" (second answer)))
        (is (search "GETFILE" (second answer)))))))

(deftest an-error-inside-a-verb-is-its-answer
  (let ((editor (make-fake-editor)))
    (define-port-verb "BOOM" (editor arg)
      (declare (ignore editor arg))
      (error "kaboom"))
    (let ((answer (port editor "BOOM")))
      (is-equal (first answer) 10)
      (is-equal (second answer) "ERROR: kaboom"))
    (setf *port-verbs* (remove "BOOM" *port-verbs* :key #'car :test #'string=))))

(deftest without-a-document-the-verbs-say-so
  (let ((editor (make-fake-editor)))
    (is-equal (port editor "GETFILE") '(10 "ERROR: no document is open"))
    (is-equal (port editor "STATUS") '(10 "ERROR: no document is open"))))

;;; --- the phase-1 leg of drive.rexx, verb by verb ------------------------------------

(deftest getfile-getname-gotoline-and-te
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "GETNAME") '(0 "sample.lisp"))
      ;; GOTOLINE is 1-based; the class's GETCURSOR reports 0-based.
      (is-equal (port editor "GOTOLINE 3") '(0 ""))
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "2"))
      (is-equal (port editor "GOTOLINE LINE 5") '(0 ""))
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "4"))
      (is-equal (first (port editor "GOTOLINE")) 10)
      (is-equal (first (port editor "GOTOLINE 0")) 10)
      ;; A widget command that answers nothing answers "".
      (is-equal (port editor "TE POSITION EOL") '(0 ""))
      (is-equal (port editor "TE GETCURSOR COLUMN") '(0 "20"))
      (is-equal (port editor "TE NOSUCH") '(0 "")))))

(deftest eval-runs-editor-commands-by-name
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "EVAL end-of-buffer") '(0 ""))
      (is-equal (port editor "EVAL beginning-of-buffer") '(0 ""))
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "0"))
      ;; The sexp scanner on the real thing: from inside frobnicate's body,
      ;; beginning-of-defun finds the `(' in column 0 that opens it.
      (port editor "GOTOLINE 6")
      (port editor "EVAL beginning-of-defun")
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "2"))
      (port editor "EVAL end-of-defun")
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "7"))
      ;; A command that does not exist is reported, not run.
      (is-equal (port editor "EVAL no-such-command") '(0 "unknown command"))
      ;; A /F argument keeps trailing spaces; the command table does not.
      (is-equal (port editor "EVAL end-of-buffer  ") '(0 ""))
      (is-equal (first (port editor "EVAL")) 10))))

(deftest eval-of-a-form-runs-in-the-editor
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "EVAL (+ 40 2)") '(0 "42"))
      (is-equal (port editor "EVAL (values 1 2)") '(0 "1 ; 2"))
      (is-equal (port editor "EVAL (values)") '(0 "; no values"))
      (is-equal (port editor "EVAL (defparameter *port-test-var* 7) *port-test-var*") '(0 "7"))
      (let ((answer (port editor "EVAL (error \"nope\")")))
        (is-equal (first answer) 10)
        (is-equal (second answer) "ERROR: nope"))
      ;; And it is what makes the editor live-hackable: a command defined
      ;; from a macro is a command.
      (port editor "EVAL (clamacs:define-command port-test-command (doc arg) (declare (ignore arg)) (clamacs::doc-message doc \"hi from the port\"))")
      (is-equal (port editor "EVAL port-test-command") '(0 ""))
      (is-equal (port editor "STATUS") '(0 "hi from the port")))))

;;; What a form PRINTS is the answer for everything that reports instead of
;;; returning -- ROOM, DESCRIBE, a redefinition warning.  The editor has no
;;; console (Workbench start), so uncaptured output is lost, not misplaced.
(deftest eval-of-a-form-answers-with-what-it-printed
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      ;; Output with no newline of its own gets one before the values.
      (is-equal (port editor "EVAL (princ \"hello\")") '(0 "hello
\"hello\""))
      ;; Output that ends in a newline is not given a second one.
      (is-equal (port editor "EVAL (format t \"a~%\")") '(0 "a
NIL"))
      ;; *ERROR-OUTPUT* and *TRACE-OUTPUT* come back too.
      (is-equal (port editor "EVAL (format *error-output* \"warned\")") '(0 "warned
NIL"))
      (is-equal (port editor "EVAL (format *trace-output* \"traced\")") '(0 "traced
NIL"))
      ;; Several forms: every one of them prints into the same answer.
      (is-equal (port editor "EVAL (princ \"one\") (princ \"two\") 3") '(0 "onetwo
3"))
      ;; A form that prints nothing answers exactly as it did before capture.
      (is-equal (port editor "EVAL (+ 40 2)") '(0 "42"))
      (is-equal (port editor "EVAL (values)") '(0 "; no values"))
      ;; Printed, then failed: the answer carries both, at rc 10.
      (let ((answer (port editor "EVAL (progn (princ \"before\") (error \"nope\"))")))
        (is-equal (first answer) 10)
        (is-equal (second answer) "before
ERROR: nope"))
      ;; And the reader's own error still reads as one.
      (is-equal (first (port editor "EVAL (car 1 2 3)")) 10))))

;;; A result whose print method itself errors must not drop the output
;;; already captured ahead of it -- printing the value is part of the
;;; same protected extent as evaluating it, not a separate step outside.
(deftest eval-of-a-form-keeps-its-output-when-the-result-cant-be-printed
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (port editor "EVAL (defclass port-test-unprintable () ())")
      (port editor "EVAL (defmethod print-object ((x port-test-unprintable) s) (declare (ignore s)) (error \"cannot print\"))")
      (let ((answer (port editor "EVAL (progn (princ \"before\") (make-instance (quote port-test-unprintable)))")))
        (is-equal (first answer) 10)
        (is-equal (second answer) "before
ERROR: cannot print")))))

;;; The point of the exercise: ROOM reports the EDITOR's heap.  It prints
;;; from C (cl_write_cstring_to_stdout), which reaches a rebound
;;; *STANDARD-OUTPUT* only because a string stream is a native stream --
;;; so this pins the runtime path as much as the verb.
(deftest eval-of-room-answers-with-the-heap-report
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let* ((editor (doc-editor doc))
           (answer (port editor "EVAL (room)"))
           (text (second answer)))
      (is-equal (first answer) 0)
      (is (search "Heap:" text))
      (is (search "bytes used" text))
      (is (search "bytes free" text))
      (is (search "collections" text)))))

(deftest insert-and-getline-round-trip
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (port editor "EVAL end-of-buffer")
      (is-equal (port editor "INSERT (list 1 2 3)") '(0 ""))
      (is (search "(list 1 2 3)" (second (port editor "TE GETLINE"))))
      ;; backward-sexp over the form just inserted lands on its open paren,
      ;; column 0 of that line.
      (port editor "EVAL backward-sexp")
      (is-equal (port editor "TE GETCURSOR COLUMN") '(0 "0")))))

(deftest open-gives-a-second-window-and-finds-an-open-file
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let* ((editor (doc-editor doc))
           (path (temp-file "sample2.lisp" (lines "(a)" "(b)" "(c)" ""))))
      (is-equal (port editor (format nil "OPEN FILE ~A LINE 2" path)) '(0 ""))
      (is-equal (port editor "GETFILE") (list 0 path))
      (let ((second (editor-active-document editor)))
        (is (not (eq second doc)))
        (is-equal (port editor "TE GETCURSOR LINE") '(0 "1")))
      ;; Opening the first file again activates its window, no third one.
      (is-equal (port editor "OPEN FILE Clamacs:verify/realamiga/sample.lisp") '(0 ""))
      (is-equal (editor-active-document editor) doc)
      (is-equal (length (live-documents editor)) 2)
      ;; A path with spaces is quoted, as ReadArgs would have it.
      (is-equal (port editor "OPEN \"T:no such.lisp\"") '(0 ""))
      (is-equal (port editor "GETFILE") '(0 "T:no such.lisp"))
      (is-equal (first (port editor "OPEN")) 10)
      ;; A bare keyword with nothing after it (`OPEN FILE') leaves FILE
      ;; unset rather than storing the literal word "FILE" as the path.
      (is-equal (port editor "OPEN FILE") '(10 "ERROR: OPEN needs a FILE"))
      (delete-file path))))

(deftest save-writes-the-active-document
  (let ((path (temp-file "port-save.lisp")))
    (multiple-value-bind (doc tr wire) (make-wired-fake "(saved)")
      (declare (ignore tr wire))
      (let ((editor (doc-editor doc)))
        (doc-activate doc)
        ;; An unnamed buffer is not saved and not complained about: the
        ;; shipped macro asks GETFILE first.
        (is-equal (port editor "SAVE") '(0 ""))
        (setf (doc-path doc) path)
        (is-equal (port editor "SAVE") '(0 ""))
        (is-equal (read-file-text path) "(saved)")
        (delete-file path)))))

(deftest keys-go-through-the-keymaps
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (port editor "EVAL beginning-of-buffer")
      ;; A prefix key leaves the sequence pending and says so.
      (is-equal (port editor "KEY C-x") '(0 ""))
      (is-equal (port editor "STATUS") '(0 "C-x -"))
      ;; ... and C-g abandons it.
      (port editor "KEY C-g")
      (is-equal (port editor "STATUS") '(0 "Quit"))
      ;; An undefined sequence is ours: reported, not passed on.
      (port editor "KEY C-x C-q")
      (is (search "undefined" (second (port editor "STATUS"))))
      ;; C-u 4 C-n moves four lines, not one.
      (port editor "EVAL beginning-of-buffer")
      (port editor "KEY C-u 4 C-n")
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "4"))
      (port editor "KEY M-<")
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "0"))
      ;; The kill ring: C-SPC, move, C-w, then C-y puts it back.
      (let ((first-line (second (port editor "TE GETLINE"))))
        (port editor "KEY C-SPC")
        (port editor "KEY C-n")
        (port editor "KEY C-w")
        (port editor "EVAL beginning-of-buffer")
        (is (string/= (second (port editor "TE GETLINE")) first-line))
        (port editor "KEY C-y")
        (port editor "EVAL beginning-of-buffer")
        (is-equal (second (port editor "TE GETLINE")) first-line))
      ;; TAB reindents through the Lisp indenter.
      (port editor "GOTOLINE 6")
      (port editor "TE POSITION SOL")
      (port editor "KEY TAB")
      (is-equal (port editor "TE GETCURSOR COLUMN") '(0 "4"))
      (is-equal (port editor "KEY C-x nonsense") '(0 "unknown key")))))

(deftest keys-type-into-an-open-minibuffer
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      ;; M-x opens the minibuffer, and C-g closes it again.
      (port editor "KEY M-x")
      (is-equal (port editor "STATUS") '(0 "M-x "))
      (port editor "KEY C-g")
      (is-equal (port editor "STATUS") '(0 "Quit"))
      ;; A name typed key by key, TAB-completed, RET runs it.
      (port editor "EVAL beginning-of-buffer")
      (port editor "KEY M-x")
      (port editor "KEY e n d - o f - b")
      (is-equal (fake-prompt doc) "M-x end-of-b")
      (port editor "KEY TAB")
      ;; The message takes the label's place while the prompt is open, as
      ;; in the MUI echo area; the input holds the completion.
      (is (search "Sole completion" (second (port editor "STATUS"))))
      (is-equal (fake-mini-text doc) "end-of-buffer")
      (port editor "KEY RET")
      (is (not (minibuffer-open-p doc)))
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "10"))
      ;; BS edits the input; a modifier key the minibuffer does not bind
      ;; is neither typed nor lost.
      (port editor "KEY M-x")
      (port editor "KEY a b BS")
      (is-equal (fake-prompt doc) "M-x a")
      (port editor "KEY C-f")
      (is-equal (fake-prompt doc) "M-x a")
      (port editor "KEY C-g"))))

(deftest a-quit-through-the-port-sets-the-flag
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "EVAL save-buffers-kill-emacs") '(0 ""))
      (is-equal (editor-quitting editor) t)
      ;; The unattended quit (quit.rexx): no requester for a macro to
      ;; leave the editor waiting on.
      (is-equal (port editor "EVAL kill-emacs") '(0 ""))
      (is-equal (editor-quitting editor) :discard)
      (doc-insert doc "unsaved")
      (is (quit-requested editor))
      (is (null (fake-asked doc)))
      (is (not (fake-window-open doc))))))
