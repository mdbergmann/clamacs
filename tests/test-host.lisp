;;;; test-host.lisp -- the host frontend (lisp/frontend-host.lisp) with the
;;;; page stubbed: an editor without a window keeps the batches it would
;;;; have sent to the page, and every requester answers from a script.
;;;; What is checked is the Lisp side of specs/clamacs-host.md -- the key
;;;; decoder, a document driven through the clamacsKey binding, what the
;;;; page changes on its own, the batch read back.

(in-package :clamacs)

(load (concatenate 'string (cl-user::clamacs-root *load-truename*)
                   "lisp/frontend-host.lisp"))

;;; --- helpers -----------------------------------------------------------

(defun host-test-editor ()
  "An editor without a window: its batches go to HOST-EDITOR-EVALS."
  (%make-host-editor))

(defun host-test-document (editor &optional (text "") path)
  "A document opened as START opens the first one, holding TEXT, the
batch flushed."
  (let ((doc nil))
    (with-entry (editor)
      (setq doc (open-document editor path))
      (when (string/= text "")
        (doc-set-text doc text)
        (colour-all doc)))
    doc))

(defun host-type (editor keys &key (target "text"))
  "The keys spelled in KEYS through the clamacsKey binding, one entry
each, with the KeyboardEvent fields a real key would carry."
  (dolist (key (split-key-sequence keys))
    (multiple-value-bind (name code alt shift) (host-key-event key)
      (let ((id (hdoc-id (editor-active-document editor)))
            (ctrl (/= 0 (logand (key-mods key) +mod-ctrl+))))
        (with-entry (editor)
          (host-key editor id name code ctrl alt nil shift target))))))

(defun host-type-text (editor text)
  (loop for c across text
        do (host-type editor (if (char= c #\Space) "SPC" (string c)))))

(defun dk (key code &key ctrl alt meta shift)
  (host-decode-key key code ctrl alt meta shift))

(defun host-text (doc)
  (doc-text doc 0 (doc-end doc)))

;;; --- the decoder -----------------------------------------------------------

(deftest host-decoder-named-keys
  (is-equal (dk "Enter" "Enter") +key-return+)
  (is-equal (dk "Tab" "Tab") +key-tab+)
  (is-equal (dk "Escape" "Escape") +key-esc+)
  (is-equal (dk "Backspace" "Backspace") +key-backspace+)
  (is-equal (dk "Delete" "Delete") +key-delete+)
  (is-equal (dk "ArrowUp" "ArrowUp") +key-up+)
  (is-equal (dk "ArrowDown" "ArrowDown") +key-down+)
  (is-equal (dk "ArrowLeft" "ArrowLeft") +key-left+)
  (is-equal (dk "ArrowRight" "ArrowRight") +key-right+)
  (is-equal (dk "Home" "Home") +key-home+)
  (is-equal (dk "End" "End") +key-end+)
  (is-equal (dk "PageUp" "PageUp") +key-pageup+)
  (is-equal (dk "PageDown" "PageDown") +key-pagedown+)
  (is-equal (dk "Insert" "Insert") +key-insert+)
  (is-equal (dk "Help" "Help") +key-help+)
  (is-equal (dk "F1" "F1") +key-f1+)
  (is-equal (dk "F10" "F10") +key-f10+)
  (is-equal (dk " " "Space") (k "SPC"))
  ;; Modifiers on a named key stay
  (is-equal (dk "Tab" "Tab" :shift t) (make-key +key-tab+ +mod-shift+))
  (is-equal (dk "ArrowUp" "ArrowUp" :ctrl t) (k "C-<up>"))
  (is-equal (dk "Enter" "Enter" :alt t) (k "M-RET")))

(deftest host-decoder-control-and-alt
  (is-equal (dk "x" "KeyX" :ctrl t) (k "C-x"))
  ;; Control plus a letter is one key whichever case the browser reports
  (is-equal (dk "X" "KeyX" :ctrl t :shift t) (k "C-x"))
  (is-equal (dk "g" "KeyG" :ctrl t) (k "C-g"))
  (is-equal (dk " " "Space" :ctrl t) (k "C-SPC"))
  ;; Alt composes a character on macOS: the letter comes from the code
  (is-equal (dk (string (code-char 402)) "KeyF" :alt t) (k "M-f"))
  (is-equal (dk "F" "KeyF" :alt t :shift t) (k "M-F"))
  (is-equal (dk "x" "KeyX" :alt t) (k "M-x"))
  (is-equal (dk "f" "KeyF" :ctrl t :alt t) (k "C-M-f"))
  ;; Alt+Shift+comma is M-<, whatever character Option composed
  (is-equal (dk (string (code-char 8804)) "Comma" :alt t :shift t) (k "M-<"))
  (is-equal (dk "," "Comma" :alt t) (k "M-,"))
  (is-equal (dk "." "Period" :alt t) (k "M-."))
  (is-equal (dk "/" "Slash" :alt t) (k "M-/"))
  (is-equal (dk "\\" "Backslash" :ctrl t :alt t) (k "C-M-\\"))
  (is-equal (dk "1" "Digit1" :alt t) (k "M-1"))
  (is-equal (dk "-" "Minus" :alt t) (k "M--"))
  ;; A code the table does not know under Alt: the character itself
  (is-equal (dk "q" "IntlBackslash" :alt t) (k "M-q"))
  ;; macOS reports Option-N/E/I/U/` as a dead key: the letter comes from
  ;; the code all the same, so M-n (history, next input) can be typed
  (is-equal (dk "Dead" "KeyN" :alt t) (k "M-n"))
  (is-equal (dk "Dead" "KeyE" :alt t) (k "M-e"))
  (is-equal (dk "Dead" "Backquote" :alt t) (k "M-`"))
  (is-equal (dk "Dead" "KeyN" :ctrl t :alt t) (k "C-M-n")))

(deftest host-decoder-refuses-what-is-not-the-editors
  ;; The Command key is the OS's and the widget's
  (is-equal (dk "a" "KeyA" :meta t) nil)
  (is-equal (dk "c" "KeyC" :meta t) nil)
  (is-equal (dk "Enter" "Enter" :meta t) nil)
  ;; A bare modifier, a dead key (without Alt), a key with no name here
  (is-equal (dk "Shift" "ShiftLeft" :shift t) nil)
  (is-equal (dk "Control" "ControlLeft" :ctrl t) nil)
  (is-equal (dk "Dead" "KeyE") nil)
  (is-equal (dk "CapsLock" "CapsLock") nil)
  (is-equal (dk "F11" "F11") nil)
  ;; Latin-1 types, anything above it does not
  (is-equal (dk (string (code-char 233)) "KeyE") (make-key 233))
  (is-equal (dk (string (code-char 8364)) "Digit2" :shift t) nil)
  (is-equal (dk (string (code-char 8364)) "IntlBackslash" :alt t) nil))

(deftest host-key-event-is-the-decoders-inverse
  (dolist (spelling '("a" "A" "(" ")" "\"" "<" "SPC" "C-x" "C-g" "C-SPC" "C-/"
                      "M-f" "M-F" "M-x" "M-<" "M-," "M-." "C-M-\\" "M-1" "M--"
                      "RET" "TAB" "ESC" "DEL" "BS" "<up>" "<f5>" "C-<home>"
                      "M-RET" "S-TAB"))
    (let ((key (k spelling)))
      (multiple-value-bind (name code alt shift) (host-key-event key)
        (let ((back (host-decode-key name code
                                     (/= 0 (logand (key-mods key) +mod-ctrl+))
                                     alt nil shift)))
          (unless (eql back key)
            (test-failure spelling (format nil ": ~S ~S ~S ~S came back as ~S"
                                           name code alt shift (key-to-string back))))))))
  ;; Under Alt the character is spelled the US way, code and shift
  (is-equal (multiple-value-list (host-key-event (k "M-<"))) '("<" "Comma" t t))
  (is-equal (multiple-value-list (host-key-event (k "M-f"))) '("f" "KeyF" t nil))
  (is-equal (multiple-value-list (host-key-event (k "C-x"))) '("x" "KeyX" nil nil))
  (is-equal (host-key-js (k "C-x"))
            "simulateKey(\"x\",{code:\"KeyX\",ctrlKey:true,altKey:false,shiftKey:false})")
  (is-equal (host-key-js (k "RET"))
            "simulateKey(\"Enter\",{code:\"\",ctrlKey:false,altKey:false,shiftKey:false})"))

;;; --- the batch's pieces ------------------------------------------------------

(deftest host-text-diff-is-one-replacement
  (flet ((diff (old new) (multiple-value-list (text-diff old new))))
    (is-equal (diff "" "abc") '(0 0 "abc"))
    (is-equal (diff "abc" "abXc") '(2 2 "X"))
    (is-equal (diff "abc" "ac") '(1 2 ""))
    (is-equal (diff "abc" "abc") '(3 3 ""))
    (is-equal (diff "aaa" "aa") '(2 3 ""))
    (is-equal (diff "aa" "aaa") '(2 2 "a"))
    (is-equal (diff "abc" "xyz") '(0 3 "xyz"))
    (is-equal (diff "abc" "") '(0 3 ""))
    (is-equal (diff "one two" "one big two") '(4 4 "big "))))

(deftest host-runs-paint-clips-what-it-covers
  (is-equal (runs-paint '() 0 3 :a) '((0 3 :a)))
  (is-equal (runs-paint '((0 5 :a)) 2 3 :b) '((0 2 :a) (2 3 :b) (3 5 :a)))
  (is-equal (runs-paint '((0 2 :a) (4 6 :b)) 1 5 nil) '((0 1 :a) (5 6 :b)))
  (is-equal (runs-paint '((0 2 :a) (4 6 :b)) 2 4 :c) '((0 2 :a) (2 4 :c) (4 6 :b)))
  (is-equal (runs-paint '((0 2 :a)) 0 2 :b) '((0 2 :b)))
  ;; An empty range paints nothing
  (is-equal (runs-paint '((0 2 :a)) 2 2 :b) '((0 2 :a))))

(deftest host-colour-runs-reach-the-page-oldest-first
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "(a) (b)")))
    (host-take-evals editor)
    ;; A range cleared and painted again in one entry (the paren highlight
    ;; taking itself down and going up): the page applies the records in
    ;; order, so the clear must come first or the paint is lost
    (with-entry (editor)
      (doc-colour doc 0 0 1 nil)
      (doc-colour doc 0 0 1 :paren-match))
    (is-equal (host-take-evals editor)
              "CK.colour(\"doc1\",[[0,0,1,false],[0,0,1,\"paren-match\"]]);")
    ;; Three runs, in the order they were made
    (with-entry (editor)
      (doc-colour doc 0 0 3 :string)
      (doc-colour doc 0 1 2 nil)
      (doc-colour doc 0 4 7 :keyword))
    (is-equal (host-take-evals editor)
              "CK.colour(\"doc1\",[[0,0,3,\"string\"],[0,1,2,false],[0,4,7,\"keyword\"]]);")
    ;; A line cleared whole wipes the runs made on it before: the line
    ;; record follows them, and takes the later run into itself
    (with-entry (editor)
      (doc-colour doc 0 0 1 :string)
      (doc-colour doc 0 0 7 nil)
      (doc-colour doc 0 4 5 :keyword))
    (is-equal (host-take-evals editor)
              "CK.colour(\"doc1\",[[0,0,1,\"string\"],[0,[[4,5,\"keyword\"]]]]);")))

(deftest host-char-literals-are-coloured-as-chars
  (let ((editor (host-test-editor)))
    (host-test-document editor "(list #\\a #\\Space)")
    (is (search "CK.colour(\"doc1\",[[0,[[6,9,\"char\"],[10,17,\"char\"]]]]);"
                (host-take-evals editor)))))

(defvar *host-page-head*
  (concatenate 'string (cl-user::clamacs-root *load-truename*) "host/page-head.html"))

(deftest host-page-styles-every-kind-lisp-paints
  ;; A kind the page has no rule for is painted, and shows as plain text
  (let ((css (read-file-text *host-page-head*)))
    (is (stringp css))
    (dolist (kind '("comment" "string" "char" "keyword" "number" "defining"
                    "symbol" "paren-match" "paren-bad"))
      (when (stringp css)
        (is (search (format nil ".ck-~A {" kind) css))))))

;;; --- a document through the bindings ------------------------------------------

(deftest host-opening-a-document-makes-a-tab
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "(defun f ())"))
         (js (host-take-evals editor)))
    (is-equal (hdoc-id doc) "doc1")
    (is (eq (editor-active-document editor) doc))
    (is (search "CK.makeDoc(\"doc1\",\"(unnamed)\",\"source\");" js))
    (is (search "CK.setTitle(\"doc1\",\"(unnamed)\");" js))
    (is (search "CK.activateDoc(\"doc1\");" js))
    ;; The text went in as one edit, then its colours as one line record
    (is (search "CK.applyEdit(\"doc1\",0,0,\"(defun f ())\",0);" js))
    (is (search "CK.colour(\"doc1\",[[0,[[1,6,\"defining\"]]]]);" js))
    (is (search "CK.setStatus(\" (unnamed)  CL-USER  1:1\");" js))
    (is (not (search "setModified(\"doc1\",true)" js)))
    ;; The order: the text before its colours
    (is (< (search "applyEdit" js) (search "CK.colour" js)))
    ;; Nothing more to say until something happens
    (with-entry (editor) nil)
    (is-equal (host-take-evals editor) "")))

(deftest host-self-insert-goes-to-the-mirror-and-the-page
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor)))
    (host-take-evals editor)
    (host-type-text editor "ab")
    (is-equal (host-text doc) "ab")
    (is-equal (doc-point doc) 2)
    (is (doc-modified-p doc))
    (let ((js (host-take-evals editor)))
      (is (search "CK.applyEdit(\"doc1\",0,0,\"a\",1);" js))
      (is (search "CK.applyEdit(\"doc1\",1,1,\"b\",2);" js))
      (is (search "CK.setModified(\"doc1\",true);" js))
      (is (search "CK.setStatus(\"*(unnamed)  CL-USER  1:3\");" js)))
    ;; A key of the Emacs layer: no widget default on top of it
    (host-type editor "C-a")
    (is-equal (doc-point doc) 0)
    (is (search "CK.setPoint(\"doc1\",0,0);" (host-take-evals editor)))))

(deftest host-newline-and-indent-is-one-edit-with-its-colours
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor)))
    (host-type-text editor "(defun f ()")
    (host-take-evals editor)
    (host-type editor "RET")
    (is-equal (host-text doc) (format nil "(defun f ()~%  "))
    (let ((js (host-take-evals editor)))
      ;; The newline and the indentation as one applyEdit ...
      (is (search "CK.applyEdit(\"doc1\",11,11,\"\\n  \",14);" js))
      ;; ... then the colours: the old paren highlight taken down (a run
      ;; record) and the new line's, none (a line record); then the status
      (is (search "CK.colour(\"doc1\",[[0,9,10,false],[1,[]]]);" js))
      (is (search "CK.setStatus(\"*(unnamed)  CL-USER  2:3\");" js))
      (is (< (search "applyEdit" js) (search "CK.colour" js))))))

(deftest host-paren-highlight-rides-on-the-line-record
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor)))
    (host-type-text editor "(a")
    (host-take-evals editor)
    (host-type editor ")")
    (is-equal (host-text doc) "(a)")
    ;; The line was recoloured (cleared) and the partner painted over it
    (is (search "CK.colour(\"doc1\",[[0,[[0,1,\"paren-match\"]]]]);" (host-take-evals editor)))
    (is-equal (doc-paren-shown doc) '(0 . 0))
    ;; A run on a line not cleared in the entry is a run record
    (with-entry (editor)
      (doc-colour doc 0 1 3 :string))
    (is (search "CK.colour(\"doc1\",[[0,1,3,\"string\"]]);" (host-take-evals editor)))
    ;; Typing on takes the highlight down with the line's recolouring
    (host-type editor "x")
    (is-equal (doc-paren-shown doc) nil)
    (is (search "CK.colour(\"doc1\",[[0,[]]]);" (host-take-evals editor)))))

(deftest host-paren-highlight-survives-a-key-that-edits-nothing
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor)))
    (host-type-text editor "(a)")
    (is-equal (doc-paren-shown doc) '(0 . 0))
    (host-take-evals editor)
    ;; At (a)| a key that only moves nothing: NOTE-CURSOR-MOVED takes the
    ;; highlight down and puts it up on the same spot in one entry, and the
    ;; page must end with it painted
    (host-type editor "C-g")
    (is-equal (doc-point doc) 3)
    (is-equal (doc-paren-shown doc) '(0 . 0))
    (is (search "CK.colour(\"doc1\",[[0,0,1,false],[0,0,1,\"paren-match\"]]);"
                (host-take-evals editor)))))

(deftest host-widget-defaults-on-the-mirror
  (let* ((editor (host-test-editor))
         (path (temp-file "host-plain.txt"))
         (doc (host-test-document editor "" path)))
    (is (not (doc-lisp-mode doc)))
    (host-type-text editor "ab")
    (host-type editor "RET")
    (host-type editor "TAB")
    (is-equal (host-text doc) (format nil "ab~%~C" #\Tab))
    (host-type editor "BS")
    (host-type editor "<up>")
    (is-equal (doc-point doc) 0)
    (host-type editor "<end>")
    (is-equal (doc-point doc) 2)
    (host-type editor "<left>")
    (host-type editor "DEL")
    (is-equal (host-text doc) (format nil "a~%"))
    (host-type editor "<down>")
    (is-equal (doc-point doc) 2)
    (host-type editor "<home>")
    (is-equal (doc-point doc) 2)
    (host-type editor "<prior>")
    (is-equal (doc-point doc) 0)
    (host-type editor "<next>")
    (is-equal (doc-point doc) 2)
    ;; Nothing was made of the moves but the point
    (is (search "CK.setPoint(\"doc1\",2,2);" (host-take-evals editor)))))

(deftest host-widget-command-answers-the-ports-te-verb
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor (format nil "one~%two words~%three"))))
    (host-take-evals editor)
    (with-entry (editor) (doc-set-point doc 8))
    ;; The cursor as the class reports it: line and column, 0-based
    (is-equal (doc-widget-command doc "GETCURSOR LINE") "1")
    (is-equal (doc-widget-command doc "GETCURSOR COLUMN") "4")
    (is-equal (doc-widget-command doc "getcursor line") "1")
    ;; The cursor line whole, its newline with it -- the last line has none
    (is-equal (doc-widget-command doc "GETLINE") (format nil "two words~%"))
    ;; The four POSITIONs answer T and move the cursor
    (is-equal (doc-widget-command doc "POSITION SOL") t)
    (is-equal (doc-point doc) 4)
    (is-equal (doc-widget-command doc "POSITION EOL") t)
    (is-equal (doc-point doc) 13)
    (is-equal (doc-widget-command doc "POSITION SOF") t)
    (is-equal (doc-point doc) 0)
    (is-equal (doc-widget-command doc "GETCURSOR LINE") "0")
    (is-equal (doc-widget-command doc "POSITION EOF") t)
    (is-equal (doc-point doc) (doc-end doc))
    (is-equal (doc-widget-command doc "GETCURSOR LINE") "2")
    (is-equal (doc-widget-command doc "GETCURSOR COLUMN") "5")
    (is-equal (doc-widget-command doc "GETLINE") "three")
    ;; Anything else the class answers FALSE
    (is-equal (doc-widget-command doc "NOSUCH") nil)
    (is-equal (doc-widget-command doc "GETCURSOR") nil)
    (is-equal (doc-widget-command doc "POSITION MIDDLE") nil)
    (is-equal (doc-widget-command doc "") nil)))

(deftest host-unknown-document-and-refused-keys-do-nothing
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x")))
    (host-take-evals editor)
    (with-entry (editor)
      (host-key editor "doc9" "a" "KeyA" nil nil nil nil "text"))
    (with-entry (editor)
      (host-key editor "doc1" "a" "KeyA" nil nil t nil "text"))
    (with-entry (editor)
      (host-key editor "doc1" "Shift" "ShiftLeft" nil nil nil t "text"))
    (is-equal (host-text doc) "x")
    (is-equal (host-take-evals editor) "")))

;;; --- the minibuffer ---------------------------------------------------------

(deftest host-prompt-through-the-input-line
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor (format nil "one~%two~%three"))))
    (host-take-evals editor)
    (host-type editor "M-x")
    (is (minibuffer-open-p doc))
    (is-equal (doc-message-text doc) "M-x ")
    (is (search "CK.openMini(\"M-x \",\"\");" (host-take-evals editor)))
    ;; Synthetic keys into the input line: Lisp edits it and tells the page
    (host-type-text editor "goto-li")
    (is-equal (doc-minibuffer-text doc) "goto-li")
    (is (search "CK.setMiniText(\"goto-li\");" (host-take-evals editor)))
    (host-type editor "TAB" :target "mini")
    (is-equal (doc-minibuffer-text doc) "goto-line")
    (let ((js (host-take-evals editor)))
      (is (search "CK.setMiniText(\"goto-line\");" js))
      (is (search "CK.setMiniLabel(\"[Sole completion]\");" js)))
    (host-type editor "RET" :target "mini")
    ;; The command ran and prompts in turn
    (is-equal (doc-message-text doc) "Goto line: ")
    (let ((js (host-take-evals editor)))
      (is (search "CK.closeMini();" js))
      (is (search "CK.openMini(\"Goto line: \",\"\");" js)))
    ;; The user typed into the native input: the page reports, nothing goes back
    (with-entry (editor) (host-mini-input editor "3"))
    (is-equal (doc-minibuffer-text doc) "3")
    (is-equal (host-take-evals editor) "")
    (host-type editor "RET" :target "mini")
    (is (not (minibuffer-open-p doc)))
    (is-equal (doc-point doc) 8)
    (let ((js (host-take-evals editor)))
      (is (search "CK.closeMini();" js))
      (is (search "CK.setPoint(\"doc1\",8,8);" js))
      (is (search "CK.setStatus(\" (unnamed)  CL-USER  3:1\");" js)))))

(deftest host-isearch-follows-the-input-line
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "abc def abc")))
    (host-take-evals editor)
    (host-type editor "C-s")
    (is (search "CK.openMini(\"I-search: \",\"\");" (host-take-evals editor)))
    (with-entry (editor) (host-mini-input editor "def"))
    (is-equal (doc-point doc) 7)
    (is (search "CK.setPoint(\"doc1\",7,7);" (host-take-evals editor)))
    ;; A failing search leaves the point at the anchor
    (with-entry (editor) (host-mini-input editor "defx"))
    (is-equal (doc-point doc) 0)
    (is-equal (doc-message-text doc) "Failing I-search: ")
    (is (search "CK.setMiniLabel(\"Failing I-search: \");" (host-take-evals editor)))
    (with-entry (editor) (host-mini-input editor "def"))
    (host-type editor "RET" :target "mini")
    (is (not (minibuffer-open-p doc)))
    (is-equal (doc-mark doc) 0)
    (is-equal (doc-message-text doc) "Mark set")
    (let ((js (host-take-evals editor)))
      (is (search "CK.closeMini();" js))
      (is (search "CK.setEcho(\"Mark set\");" js))
      (is (< (search "closeMini" js) (search "setEcho(\"Mark set\")" js))))
    ;; C-g at a prompt abandons it
    (host-type editor "M-x")
    (host-type editor "C-g" :target "mini")
    (is (not (minibuffer-open-p doc)))
    (is-equal (doc-message-text doc) "Quit")
    ;; Meta plus a character the minibuffer does not bind is reported
    (host-type editor "M-x")
    (host-type editor "M-q" :target "mini")
    (is-equal (doc-message-text doc) "M-q is undefined")
    (is (search "CK.setMiniLabel(\"M-q is undefined\");" (host-take-evals editor)))))

;;; --- what the page changed on its own -------------------------------------------

(deftest host-update-applies-the-pages-changes-to-the-mirror
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "abc")))
    (host-take-evals editor)
    ;; Two changes in the coordinates of the text before them
    (with-entry (editor)
      (host-update editor "doc1" '((0 0 "xy") (3 3 "!")) 5))
    (is-equal (host-text doc) "xyabc!")
    (is-equal (doc-point doc) 5)
    (is (doc-modified-p doc))
    (let ((js (host-take-evals editor)))
      ;; Nothing is pushed back but the flag and the colours
      (is (not (search "applyEdit" js)))
      (is (not (search "setPoint" js)))
      (is (search "CK.setModified(\"doc1\",true);" js))
      (is (search "CK.colour(\"doc1\"," js)))
    ;; One undo step per change
    (host-type editor "C-/")
    (is-equal (host-text doc) "xyabc")
    (host-type editor "C-/")
    (is-equal (host-text doc) "abc")
    (is (search "CK.applyEdit(\"doc1\",0,2,\"\",0);" (host-take-evals editor)))
    ;; An empty change list changes nothing
    (with-entry (editor)
      (host-update editor "doc1" '() 1))
    (is-equal (host-text doc) "abc")
    (is-equal (doc-point doc) 1)))

(deftest host-cursor-report-moves-the-point-and-the-selection
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "(a) (b)")))
    (host-take-evals editor)
    (with-entry (editor)
      (host-cursor editor "doc1" 3 3))
    (is-equal (doc-point doc) 3)
    ;; The paren highlight followed, nothing else went out
    (is-equal (doc-paren-shown doc) '(0 . 0))
    (let ((js (host-take-evals editor)))
      (is (not (search "setPoint" js)))
      (is (search "CK.colour(\"doc1\",[[0,0,1,\"paren-match\"]]);" js)))
    (with-entry (editor)
      (host-cursor editor "doc1" 5 1))
    (is-equal (doc-point doc) 5)
    (is-equal (mirror-selection (hdoc-mirror doc)) '(1 . 5))
    (is (not (search "setPoint" (host-take-evals editor))))
    ;; A selection Lisp makes is shown with the cursor at its start
    (host-type editor "C-x h")
    (is-equal (doc-point doc) 0)
    (is (search "CK.setPoint(\"doc1\",0,7);" (host-take-evals editor)))))

(deftest host-activation-restores-the-echo-and-status
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two")))
    (is (eq (editor-active-document editor) d2))
    (with-entry (editor) (doc-message d1 "hello"))
    ;; Not the active document: nothing shown
    (is (not (search "hello" (host-take-evals editor))))
    (with-entry (editor) (doc-activate d1))
    (is (eq (editor-active-document editor) d1))
    (let ((js (host-take-evals editor)))
      (is (search "CK.activateDoc(\"doc1\");" js))
      (is (search "CK.setEcho(\"hello\");" js))
      (is (search "CK.setStatus(\" (unnamed)  CL-USER  1:1\");" js)))
    ;; A prompt open in the document that becomes active is shown again
    (with-entry (editor) (doc-activate d2))
    (host-type editor "M-x")
    (with-entry (editor) (doc-activate d1))
    (with-entry (editor) (doc-activate d2))
    (is (search "CK.openMini(\"M-x \",\"\");" (host-take-evals editor)))
    ;; A page report of a click on a tab goes the same way
    (with-entry (editor)
      (let ((doc (host-document-by-id editor "doc1")))
        (doc-activate doc)))
    (is (eq (editor-active-document editor) d1))))

(deftest host-closing-the-active-tab-activates-the-next
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two")))
    (host-take-evals editor)
    (host-type editor "C-x k")
    (is (doc-closing d2))
    (is (eq (editor-active-document editor) d1))
    (is (null (host-document-by-id editor "doc2")))
    (let ((js (host-take-evals editor)))
      (is (search "CK.removeDoc(\"doc2\");" js))
      (is (search "CK.activateDoc(\"doc1\");" js)))
    (reap editor)
    (is-equal (editor-documents editor) (list d1))
    ;; The last one: nothing left to show
    (host-type editor "C-x k")
    (reap editor)
    (is-equal (live-documents editor) '())
    (is (null (editor-active-document editor)))))

(deftest host-unsaved-changes-ask-through-the-requester
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor)))
    (host-type-text editor "x")
    (host-take-evals editor)
    (setf (host-editor-answers editor) '(:cancel))
    (host-type editor "C-x k")
    (is (not (doc-closing doc)))
    (is-equal (first (host-editor-asked editor))
              '("(unnamed) has unsaved changes." (:save :discard :cancel)))
    (is (not (search "removeDoc" (host-take-evals editor))))
    ;; No answer scripted: the cancel position
    (setf (host-editor-answers editor) '())
    (host-type editor "C-x k")
    (is (not (doc-closing doc)))
    (setf (host-editor-answers editor) '(:discard))
    (host-type editor "C-x k")
    (is (doc-closing doc))
    (is (search "CK.removeDoc(\"doc1\");" (host-take-evals editor)))))

(deftest host-save-and-quit
  (let* ((editor (host-test-editor))
         (path (temp-file "host-save.lisp"))
         (doc (host-test-document editor "" path)))
    (is-equal (doc-message-text doc) "(New file)")
    (host-type-text editor "(list 1)")
    (host-type editor "C-x C-s")
    (is (not (doc-modified-p doc)))
    (is-equal (read-file-text path) "(list 1)")
    (let ((js (host-take-evals editor)))
      (is (search "CK.setModified(\"doc1\",false);" js))
      (is (search (format nil "CK.setEcho(\"Wrote ~A\");" path) js))
      (is (search "CK.setStatus(\" clamacs-test-host-save.lisp  CL-USER  1:9\");" js)))
    ;; A quit closes every document from the loop's housekeeping
    (host-type editor "C-x C-c")
    (is (editor-quitting editor))
    (is (not (doc-closing doc)))
    (is (housekeeping editor))
    (is (doc-closing doc))
    (is-equal (live-documents editor) '())
    (delete-file path)))

(deftest host-batch-is-ascii-and-the-beep-and-clipboard-are-recorded
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "hello world")))
    (host-take-evals editor)
    (with-entry (editor)
      (doc-message doc (coerce (list (code-char 233) #\!) 'string)))
    (is-equal (host-take-evals editor) "CK.setEcho(\"\\u00E9!\");")
    ;; C-w puts the region on the clipboard and cuts it
    (host-type editor "M-f")
    (host-type editor "C-SPC")
    (host-type editor "M-f")
    (host-type editor "C-w")
    (is-equal (host-text doc) "hello")
    (is-equal (host-editor-clipboard editor) " world")
    (is (search "CK.applyEdit(\"doc1\",5,11,\"\",5);" (host-take-evals editor)))
    ;; An undefined key beeps
    (host-type editor "C-x C-q")
    (is-equal (host-editor-beeps editor) 1)
    (is-equal (doc-message-text doc) "C-x C-q is undefined")
    ;; The file requester and the browser answer from the script
    (setf (host-editor-answers editor) '(nil))
    (is-equal (doc-ask-file doc "Find file" nil) nil)
    (is-equal (first (host-editor-asked editor)) '(:file "Find file" nil))
    (is-equal (doc-open-url doc "https://example.org/") :opened)
    (is-equal (host-editor-urls editor) '("https://example.org/"))
    (is-equal (multiple-value-list (doc-geometry doc)) '(0 0 800 600))
    (is-equal (editor-aux-windows editor) '())
    (is-equal (length (editor-toolkit-lines editor)) 2)))

(deftest host-injected-keys-go-through-the-page
  (let ((editor (host-test-editor)))
    (host-inject-keys editor (list "ab" (k "RET") (k "C-x")))
    (is-equal (length (host-editor-inject editor)) 4)
    (with-entry (editor) (inject-next-key editor))
    (is-equal (host-take-evals editor)
              "simulateKey(\"a\",{code:\"KeyA\",ctrlKey:false,altKey:false,shiftKey:false});")
    (dotimes (i 3) (with-entry (editor) (inject-next-key editor)))
    (is (search "simulateKey(\"x\",{code:\"KeyX\",ctrlKey:true" (host-take-evals editor)))
    (is-equal (host-editor-inject editor) '())
    ;; Nothing left: nothing sent
    (with-entry (editor) (inject-next-key editor))
    (is-equal (host-take-evals editor) "")))

(deftest host-errors-in-an-entry-reach-the-echo-area
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x")))
    (host-take-evals editor)
    (with-entry (editor)
      (error "boom ~A" 7))
    (is-equal (doc-message-text doc) "Error: boom 7")
    (is (search "CK.setEcho(\"Error: boom 7\");" (host-take-evals editor)))
    ;; The page's own report lands there too
    (with-entry (editor)
      (let ((*error-output* (make-broadcast-stream)))
        (host-log editor "JS error: x is not defined (line 3)")))
    (is-equal (doc-message-text doc) "Page: JS error: x is not defined (line 3)")))

(deftest host-panel-state-reaches-the-editor-without-a-dock
  ;; The dock is phase H3; until then every panel generic has a method
  ;; that keeps the state flowing.  Without one, the REPL window's close
  ;; at quit signalled "no applicable method" out of EDITOR-DEBUGGER-CLOSE
  ;; before the document was marked closing, and the editor could not quit.
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x")))
    (with-entry (editor)
      (editor-show-diagnostics editor '() :open t)
      (editor-select-diagnostic editor 0)
      (editor-debugger-open editor (make-debugger))
      (editor-debugger-frames editor '("0: (foo)"))
      (editor-debugger-select-frame editor 0)
      (editor-debugger-locals editor '("A = 1"))
      (editor-debugger-raise editor)
      (editor-debugger-close editor)
      (editor-inspector-open editor (make-inspector)))
    (is-equal (doc-message-text doc) "")
    ;; kill-emacs ends the loop's housekeeping with every document closed.
    (with-entry (editor)
      (run-command doc 'kill-emacs)
      (is (housekeeping editor)))
    (is-equal (live-documents editor) '())))

;;; --- the program's command line ------------------------------------------------

(deftest host-command-line-keeps-the-files-in-order-and-takes-bind-out
  (let ((*host-bind* nil))
    (is-equal (parse-command-line '()) '())
    (is-equal (parse-command-line '("a.lisp" "b.lisp")) '("a.lisp" "b.lisp"))
    (is (null *host-bind*))
    ;; `--bind ADDR' is consumed with its address, wherever it stands.
    (is-equal (parse-command-line '("a.lisp" "--bind" "192.168.1.5" "b.lisp"))
              '("a.lisp" "b.lisp"))
    (is-equal *host-bind* "192.168.1.5")
    (is-equal (parse-command-line '("--bind" "10.0.0.7" "c.lisp")) '("c.lisp"))
    (is-equal *host-bind* "10.0.0.7")))

(deftest host-command-line-hands-a-wildcard-or-a-missing-address-on-to-be-refused
  ;; Not dropped: a `--bind' that named a wildcard, or nothing, must not
  ;; become "no option" (a port on loopback and no word about it).
  ;; HOST-PORT-START refuses these with a message; see test-transport-host.
  (dolist (addr '("0.0.0.0" "::" "*" ""))
    (let ((*host-bind* nil))
      (is-equal (parse-command-line (list "x.lisp" "--bind" addr)) '("x.lisp"))
      (is-equal *host-bind* addr)))
  (let ((*host-bind* nil))
    (is-equal (parse-command-line '("x.lisp" "--bind")) '("x.lisp"))
    (is-equal *host-bind* "")))
