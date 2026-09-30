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
      ;; ... then the colours: the edit spans both lines, so the line the
      ;; newline split is painted whole (a line record, which takes the
      ;; paren highlight down with it) and the new line, none; then the
      ;; status
      (is (search "CK.colour(\"doc1\",[[0,[[1,6,\"defining\"]]],[1,[]]]);" js))
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
      (host-key editor "doc1" "q" "KeyQ" nil nil t nil "text"))
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

(deftest host-completion-list-follows-tab-and-the-arrows
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "hello")))
    (host-take-evals editor)
    (host-type editor "M-x")
    (host-type-text editor "kill-r")
    (host-take-evals editor)
    ;; TAB: the candidates as a list, no cursor, the common prefix in the line
    (host-type editor "TAB" :target "mini")
    (is-equal (doc-minibuffer-text doc) "kill-r")
    (let ((js (host-take-evals editor)))
      (is (search "CK.showCompletions([\"kill-region\",\"kill-ring-save\"],-1);" js))
      ;; a frontend with a list counts the candidates in the echo row only
      (is (search "CK.setMiniLabel(\"[2 completions]\");" js))
      (is (not (search "kill-ring-save]" js))))
    ;; The arrows move the cursor: the list is not sent again
    (host-type editor "<down>" :target "mini")
    (is-equal (doc-minibuffer-text doc) "kill-region")
    (let ((js (host-take-evals editor)))
      (is (search "CK.selectCompletion(0);" js))
      (is (search "CK.setMiniText(\"kill-region\");" js))
      (is (not (search "showCompletions" js))))
    (host-type editor "<up>" :target "mini")
    (is-equal (doc-minibuffer-text doc) "kill-ring-save")
    (is (search "CK.selectCompletion(1);" (host-take-evals editor)))
    ;; A click in the page's list
    (with-entry (editor) (host-pick-completion editor 0 0))
    (is-equal (doc-minibuffer-text doc) "kill-region")
    (is (search "CK.selectCompletion(0);" (host-take-evals editor)))
    ;; An edit from the page hides it
    (with-entry (editor) (host-mini-input editor "kill-regio"))
    (is (search "CK.hideCompletions();" (host-take-evals editor)))
    (is (minibuffer-open-p doc))
    ;; A sole completion shows no list
    (host-type editor "TAB" :target "mini")
    (let ((js (host-take-evals editor)))
      (is (search "CK.setMiniLabel(\"[Sole completion]\");" js))
      (is (not (search "Completions" js))))
    ;; A double click takes the row: the prompt closes, the command runs
    (with-entry (editor) (host-mini-input editor "kill-r"))
    (host-type editor "TAB" :target "mini")
    (host-take-evals editor)
    (with-entry (editor) (host-pick-completion editor 1 1))
    (is (not (minibuffer-open-p doc)))
    (let ((js (host-take-evals editor)))
      (is (search "CK.selectCompletion(1);" js))
      (is (search "CK.hideCompletions();" js))
      (is (search "CK.closeMini();" js))
      (is (< (search "hideCompletions" js) (search "closeMini" js))))
    ;; The list is the document's: shown again with its prompt when the
    ;; document becomes the active one again
    (host-type editor "M-x")
    (host-type-text editor "kill-r")
    (host-type editor "TAB" :target "mini")
    (let ((other (host-test-document editor "x")))
      (is (search "CK.closeMini();" (host-take-evals editor)))
      (with-entry (editor) (doc-activate doc))
      (let ((js (host-take-evals editor)))
        ;; (the label is the completions message: a message at a prompt takes it)
        (is (search "CK.openMini(\"[2 completions]\",\"kill-r\");" js))
        (is (search "CK.showCompletions([\"kill-region\",\"kill-ring-save\"],-1);" js))
        (is (< (search "openMini" js) (search "showCompletions" js))))
      (with-entry (editor) (doc-activate other))
      (host-take-evals editor)
      ;; A pick reaches the active document only
      (with-entry (editor) (host-pick-completion editor 0 0))
      (is-equal (doc-minibuffer-text doc) "kill-r")
      (is-equal (host-take-evals editor) ""))))

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

(deftest host-region-is-shown-from-the-mark-to-the-cursor
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "hello world")))
    (host-type editor "C-SPC")
    (host-take-evals editor)
    (host-type editor "M-f")
    (is-equal (doc-mark-active doc) t)
    (is (search "CK.setPoint(\"doc1\",5,0);" (host-take-evals editor)))
    ;; A plain motion extends a region a command began
    (host-type editor "<right>")
    (is (search "CK.setPoint(\"doc1\",6,0);" (host-take-evals editor)))
    ;; C-x C-x swaps the ends, C-g takes the region down
    (host-type editor "C-x C-x")
    (is (search "CK.setPoint(\"doc1\",0,6);" (host-take-evals editor)))
    (host-type editor "C-g")
    (is-equal (doc-mark-active doc) nil)
    (is (search "CK.setPoint(\"doc1\",0,0);" (host-take-evals editor)))
    ;; An edit ends what is shown and keeps the mark: C-SPC, type, C-w
    (host-type editor "C-SPC")
    (host-type-text editor "ab")
    (is-equal (doc-mark-active doc) nil)
    (is-equal (doc-mark doc) 0)
    (is (not (search "setPoint" (host-take-evals editor))))
    (host-type editor "C-w")
    (is-equal (host-text doc) "hello world")
    (is-equal (host-editor-clipboard editor) "ab")))

(deftest host-shift-with-a-motion-key-selects
  (let* ((editor (host-test-editor))
         (path (temp-file "host-select.txt"))
         (doc (host-test-document editor (format nil "one two~%three") path)))
    (host-take-evals editor)
    (host-type editor "S-<right>")
    (host-type editor "S-<right>")
    (is-equal (doc-mark doc) 0)
    (is-equal (doc-mark-active doc) :selection)
    (is (search "CK.setPoint(\"doc1\",2,0);" (host-take-evals editor)))
    (host-type editor "S-<down>")
    (is-equal (doc-point doc) 10)
    (host-type editor "S-<home>")
    (is-equal (doc-point doc) 8)
    (host-type editor "S-<left>")
    (is (search "CK.setPoint(\"doc1\",7,0);" (host-take-evals editor)))
    ;; M-w copies what is selected
    (host-type editor "M-w")
    (is-equal (host-editor-clipboard editor) "one two")
    (is-equal (doc-mark-active doc) nil)
    ;; The next plain motion drops a selection
    (host-type editor "S-<left>")
    (host-type editor "<left>")
    (is-equal (doc-mark-active doc) nil)
    (is-equal (doc-point doc) 5)
    (is (search "CK.setPoint(\"doc1\",5,5);" (host-take-evals editor)))
    ;; Shift with Meta selects by the word
    (host-type editor "M-S-<left>")
    (is-equal (list (doc-point doc) (doc-mark doc)) '(4 5))
    ;; Typing replaces a selection, Backspace deletes it
    (host-type-text editor "X")
    (is-equal (host-text doc) (format nil "one Xwo~%three"))
    (host-type editor "S-<left>")
    (host-type editor "S-<left>")
    (host-type editor "BS")
    (is-equal (host-text doc) (format nil "onewo~%three"))
    (is-equal (doc-point doc) 3)
    (host-type editor "S-<end>")
    (host-type editor "DEL")
    (is-equal (host-text doc) (format nil "one~%three"))
    (is-equal (doc-mark-active doc) nil)))

(deftest host-shift-up-reaches-the-first-line
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor (format nil "(defun fac (n)~%  (if (< n 2)~%      1~%    (* n (fac (1- n)))))~%"))))
    (host-type editor "M->")
    (host-take-evals editor)
    (dotimes (i 4) (host-type editor "S-<up>"))
    (is-equal (doc-point doc) 0)
    (is (search "CK.setPoint(\"doc1\",0,62);" (host-take-evals editor)))
    ;; The copy takes the whole text, the first line included
    (host-command-type editor "c")
    (is-equal (host-editor-clipboard editor) (host-text doc))
    (host-type editor "M->")
    (host-command-type editor "v")
    (is-equal (doc-line-count doc) 9)))

(deftest host-the-mouse-s-selection-is-the-region
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "hello world")))
    (with-entry (editor)
      (host-cursor editor "doc1" 5 0))
    (is-equal (doc-mark doc) 0)
    (is-equal (doc-mark-active doc) :selection)
    (host-take-evals editor)
    (host-type editor "M-w")
    (is-equal (host-editor-clipboard editor) "hello")
    ;; A click takes the region down
    (with-entry (editor)
      (host-cursor editor "doc1" 8 2))
    (with-entry (editor)
      (host-cursor editor "doc1" 3 3))
    (is-equal (doc-mark-active doc) nil)
    (is (not (search "setPoint" (host-take-evals editor))))))

(deftest host-yank-takes-what-another-application-copied
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "ab")))
    ;; The editor's own kill, every kill, is on the clipboard
    (host-type editor "C-k")
    (is-equal (host-editor-clipboard editor) "ab")
    (host-type editor "C-y")
    (is-equal (host-text doc) "ab")
    (is-equal (kill-count (doc-kill-ring doc)) 1)
    ;; Another application's text is the newest kill, its CR LF a newline
    (setf (host-editor-clipboard editor)
          (format nil "x~C~Cy~Cz" #\Return #\Newline #\Return))
    (host-type editor "C-y")
    (is-equal (host-text doc) (format nil "abx~%y~%z"))
    (is-equal (kill-count (doc-kill-ring doc)) 2)
    ;; ... and M-y reaches the kill before it
    (host-type editor "M-y")
    (is-equal (host-text doc) "abab")
    ;; An empty clipboard yanks the ring
    (setf (host-editor-clipboard editor) "")
    (host-type editor "C-y")
    (is-equal (host-text doc) (format nil "ababx~%y~%z"))))

(defun host-command-type (editor name &key shift (target "text"))
  "The key NAME held with the Command key, through the clamacsKey binding."
  (with-entry (editor)
    (host-key editor (hdoc-id (editor-active-document editor))
              name "" nil nil t shift target)))

(deftest host-command-keys-copy-cut-and-paste
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "hello world")))
    (is-equal (host-command-key "v" nil) 'yank)
    (is-equal (host-command-key "C" nil) 'kill-ring-save)
    (is-equal (host-command-key "z" t) 'redo)
    (is-equal (host-command-key "q" nil) nil)
    (is-equal (host-command-key "Enter" nil) nil)
    (host-type editor "S-<right>")
    (host-type editor "S-<right>")
    (host-command-type editor "c")
    (is-equal (host-editor-clipboard editor) "he")
    (is-equal (host-text doc) "hello world")
    (host-type editor "M-S-<right>")
    (host-command-type editor "x")
    (is-equal (host-editor-clipboard editor) "llo")
    (is-equal (host-text doc) "he world")
    (setf (host-editor-clipboard editor) "LLO")
    (host-command-type editor "v")
    (is-equal (host-text doc) "heLLO world")
    (host-command-type editor "z")
    (is-equal (host-text doc) "he world")
    (host-command-type editor "Z" :shift t)
    (is-equal (host-text doc) "heLLO world")
    ;; Select all, then typing replaces nothing: that region is a command's
    (host-command-type editor "a")
    (is-equal (list (doc-point doc) (doc-mark doc)) '(0 11))
    (host-command-type editor "c")
    (is-equal (host-editor-clipboard editor) "heLLO world")
    ;; A Command key that is not the editor's does nothing
    (host-command-type editor "q")
    (is-equal (host-text doc) "heLLO world")
    ;; At a prompt the paste goes to the input line, its first line only
    (host-type editor "M-x")
    (setf (host-editor-clipboard editor) (format nil "goto~%line"))
    (host-command-type editor "v" :target "mini")
    (is-equal (doc-minibuffer-text doc) "goto")
    (host-command-type editor "c" :target "mini")
    (is-equal (host-editor-clipboard editor) (format nil "goto~%line"))
    (host-type editor "C-g")))

(deftest host-a-paste-and-its-undo-colour-every-line-they-span
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "")))
    (host-take-evals editor)
    ;; Two lines pasted with the Command key: both coloured
    (setf (host-editor-clipboard editor) (format nil "(defun f ()~%  \"s\")"))
    (host-command-type editor "v")
    (let ((js (host-take-evals editor)))
      ;; (the paren highlight of the `)' before the cursor rides on line 0)
      (is (search "[1,6,\"defining\"]" js))
      (is (search "[1,[[2,5,\"string\"]]]" js)))
    ;; The undo takes the text and the colour away, the redo brings both
    (host-command-type editor "z")
    (is-equal (host-text doc) "")
    (host-take-evals editor)
    (host-command-type editor "Z" :shift t)
    (let ((js (host-take-evals editor)))
      (is (search "[1,6,\"defining\"]" js))
      (is (search "[1,[[2,5,\"string\"]]]" js)))
    ;; A change the page made itself (a drop) over two lines, the same
    (with-entry (editor)
      (host-update editor "doc1" (list (list 0 0 (format nil "#\\a~%")) (list 18 18 " 1")) 2))
    (let ((js (host-take-evals editor)))
      ;; The whole char token: the `(' lit before the change sat at 0:0
      ;; and its take-down used to clear the token's first column.
      (is (search "[0,[[0,3,\"char\"]]]" js))
      (is (search "[1,[[1,6,\"defining\"]]]" js))
      (is (search "[2,[[2,5,\"string\"],[7,8,\"number\"]]]" js)))))

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
    (is-equal (doc-ask-file doc "Open" nil "/tmp/") nil)
    (is-equal (first (host-editor-asked editor)) '(:file "Open" nil "/tmp/"))
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

(deftest host-every-panel-generic-has-a-method
  ;; Every panel generic has a method on the host editor.  Without one,
  ;; the REPL window's close at quit signalled "no applicable method" out
  ;; of EDITOR-DEBUGGER-CLOSE before the document was marked closing, and
  ;; the editor could not quit (the H2 drive).
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

;;; --- the dock: the tool buffers and the panels (phase H3) --------------------------

(defparameter *host-dbg-announce*
  (lines "DEBUGGER 1 CL-USER" "SIMPLE-ERROR: bad 12" "0: ABORT Return to the REPL")
  "What clamiga sends when (dbg-fn 3 4) errs at the prompt (test-debugger.lisp has the same).")

(defparameter *host-cons-reply*
  (lines "CONS 1 2" "(1 (2 3))" "0: Car = 1" "1: Cdr = (2 3)")
  "The INSPECT reply for (list 1 (list 2 3)) (test-inspector.lisp has the same).")

(defun host-wired-editor (&optional (text "") path)
  "A host editor without a window, a document on it, and a wire over a
fake transport that finds CLAMIGA: (values editor doc tr wire)."
  (let* ((editor (host-test-editor))
         (tr (make-fake-transport))
         (wire (make-wire editor tr)))
    (setf (fake-transport-wire tr) wire
          (fake-transport-port tr) "CLAMIGA")
    (let ((doc (host-test-document editor text path)))
      (with-entry (editor) (wire-find-port wire))
      (host-take-evals editor)
      (values editor doc tr wire))))

(defmacro host-deliver (editor tr rc text)
  "A reply delivered inside an entry, so the batch it makes goes out."
  `(with-entry (,editor) (fake-deliver ,tr ,rc ,text)))

(deftest host-tool-buffers-are-dock-tabs
  (multiple-value-bind (editor doc tr) (host-wired-editor "(twice 21)")
    (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
    (is-equal (editor-aux-windows editor) '())
    ;; C-c C-z: the REPL buffer is a tool buffer, so its tab is the dock's
    (with-entry (editor) (run-command doc 'clamacs-repl))
    (let ((repl (repl-doc editor))
          (js (host-take-evals editor)))
      (is (search "CK.makeDoc(\"doc2\",\"*clamacs-repl*\",\"tool\");" js))
      (is (search "CK.activateDoc(\"doc2\");" js))
      (is (eq (editor-active-document editor) repl))
      (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
      ;; The dock is a window of its own to the snapshot: the bottom of
      ;; the native window's frame
      (is-equal (editor-aux-windows editor) '(("dock" 0 400 800 200)))
      (with-entry (editor) (fake-answer-attach tr))
      ;; Going back to the source leaves the dock open on the REPL
      (with-entry (editor) (doc-activate doc))
      (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
      ;; Closing the last dock item collapses the dock
      (with-entry (editor) (run-command repl 'kill-buffer))
      (is (doc-closing repl))
      (is (search "CK.removeDoc(\"doc2\");" (host-take-evals editor)))
      (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
      (is-equal (editor-aux-windows editor) '()))))

(deftest host-diagnostics-panel-shows-the-rows-and-a-pick-jumps
  (let ((path (temp-file "host-errors.lisp"
                         (lines ";;; errors" "" "(defun ok ())" "" "" "" "(error \"first\")" ""
                                "(no-such-function)" ""))))
    (multiple-value-bind (editor doc tr wire) (host-wired-editor "" path)
      (with-entry (editor) (run-command doc 'clamacs-load-buffer))
      (is-equal (fake-last-sent tr) (format nil "LOAD ~A" path))
      (host-take-evals editor)
      (host-deliver editor tr 10 "")
      (is-equal (fake-last-sent tr) "LASTRESULT")
      (host-deliver editor tr 0 (lines (format nil "~A:7: ERROR: first deliberate error" path)
                                       (format nil "~A:9: ERROR: Undefined function: NO-SUCH-FUNCTION" path)
                                       "2 error(s), 0 warning(s)" ""))
      (is-equal (doc-message-text doc) "2 error(s), 0 warning(s)")
      ;; The rows went to the panel, which opened without a selection
      (let ((js (host-take-evals editor)))
        (is (search (format nil "CK.showDiagnostics([~S,~S],true);"
                            (format nil "~A:7: ERROR: first deliberate error" path)
                            (format nil "~A:9: ERROR: Undefined function: NO-SUCH-FUNCTION" path))
                    js)))
      (is-equal (host-panel-state :diagnostics editor) "open rows 2 selected none")
      (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics")
      (is-equal (editor-aux-windows editor) '(("dock" 0 400 800 200) ("errors" 0 400 800 200)))
      ;; C-x ` selects the row it jumps to
      (with-entry (editor) (run-command doc 'clamacs-next-error))
      (is-equal (doc-index-line doc (doc-point doc)) 6)
      (is (search "CK.selectDiagnostic(0);" (host-take-evals editor)))
      (is-equal (host-panel-state :diagnostics editor) "open rows 2 selected 0")
      ;; A row picked in the panel is visited, and nothing is pushed back
      (with-entry (editor) (host-diag-pick editor 1))
      (is-equal (doc-index-line doc (doc-point doc)) 8)
      (is-equal (doc-message-text doc) "Undefined function: NO-SUCH-FUNCTION")
      (is-equal (wire-error-row wire) 1)
      (is (not (search "selectDiagnostic" (host-take-evals editor))))
      ;; Nothing selected, and a row that is not there: nothing happens
      (with-entry (editor) (host-diag-pick editor nil))
      (with-entry (editor) (host-diag-pick editor 7))
      (is-equal (doc-index-line doc (doc-point doc)) 8)
      ;; The panel's close only takes it off the screen; the rows stay
      (with-entry (editor) (host-panel-close editor "diagnostics"))
      (is-equal (host-panel-state :diagnostics editor) "closed rows 2 selected none")
      (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
      (is-equal (editor-aux-windows editor) '())
      ;; C-c ! l shows it again, rows or no rows
      (with-entry (editor) (run-command doc 'clamacs-show-errors))
      (is (search "CK.showDiagnostics([" (host-take-evals editor)))
      (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics")
      ;; A fresh load empties the list; with nothing to show it stays open
      (with-entry (editor) (run-command doc 'clamacs-load-buffer))
      (host-deliver editor tr 0 (lines (format nil "; loading ~A" path) "0 error(s), 0 warning(s)"))
      (is (search "CK.showDiagnostics([],false);" (host-take-evals editor)))
      (is-equal (host-panel-state :diagnostics editor) "open rows 0 selected none"))
    (delete-file path)))

(defun host-repl-fixture (&optional (text "(twice 21)"))
  "A host editor with its REPL buffer open and attached, the REPL active:
(values editor doc repl tr wire)."
  (multiple-value-bind (editor doc tr wire) (host-wired-editor text)
    (with-entry (editor) (run-command doc 'clamacs-repl))
    (with-entry (editor) (fake-answer-attach tr))
    (host-take-evals editor)
    (values editor doc (repl-doc editor) tr wire)))

(deftest host-debugger-panel-follows-the-session
  (multiple-value-bind (editor doc repl tr) (host-repl-fixture)
    (declare (ignore doc))
    (is-equal (host-panel-state :debugger editor)
              "closed level 0 restarts 0 continue no frames 0 frame none locals 0 condition ")
    ;; (dbg-fn 3 4) RET at the prompt, then clamiga's DEBUGGER 1
    (host-type-text editor "(dbg-fn 3 4)")
    (host-type editor "RET")
    (is-equal (fake-last-sent tr) "REPL-EVAL (dbg-fn 3 4)")
    (host-deliver editor tr 0 "")
    (host-take-evals editor)
    (with-entry (editor) (port-raw-command editor *host-dbg-announce*))
    (let ((js (host-take-evals editor)))
      (is (search "CK.dbgOpen(1,\"SIMPLE-ERROR: bad 12\",[\"0: ABORT Return to the REPL\"],false);" js))
      (is (not (search "dbgRaise" js))))
    (is-equal (fake-last-sent tr) "BACKTRACE")
    (is-equal (host-panel-state :debugger editor)
              "open level 1 restarts 1 continue no frames 0 frame none locals 0 condition SIMPLE-ERROR: bad 12")
    (is-equal (host-panel-state :dock editor) "open height 200 shown debugger")
    (is-equal (editor-aux-windows editor) '(("dock" 0 400 800 200) ("debugger" 0 400 800 200)))
    (is-equal (doc-message-text repl) "Debugger level 1: SIMPLE-ERROR: bad 12")
    ;; The frames come, frame 0 is selected and its locals asked for
    (host-deliver editor tr 0 (lines "0: dbg-fn  T:dbg.lisp:27" "1: <anonymous>"))
    (let ((js (host-take-evals editor)))
      (is (search "CK.dbgFrames([\"0: dbg-fn  T:dbg.lisp:27\",\"1: <anonymous>\"]);" js))
      (is (search "CK.dbgSelectFrame(0);" js))
      (is (search "CK.dbgLocals([]);" js)))
    (is-equal (fake-last-sent tr) "FRAME 0")
    (host-deliver editor tr 0 (lines "ARG0 = 3" "ARG1 = 4"))
    (is (search "CK.dbgLocals([\"ARG0 = 3\",\"ARG1 = 4\"]);" (host-take-evals editor)))
    (is-equal (doc-message-text repl) "Debugger level 1, frame 0: ARG0 = 3")
    (is-equal (host-panel-state :debugger editor)
              "open level 1 restarts 1 continue no frames 2 frame 0 locals 2 condition SIMPLE-ERROR: bad 12")
    ;; The panel's lists and buttons: a frame selected asks for its
    ;; locals; Invoke with no restart selected complains; the eval line
    ;; goes to the selected frame; Abort and Continue send their verbs
    (with-entry (editor) (debug-frame-selected editor 1))
    (is-equal (fake-last-sent tr) "FRAME 1")
    (is (search "CK.dbgLocals([]);" (host-take-evals editor)))
    (is-equal (host-panel-state :debugger editor)
              "open level 1 restarts 1 continue no frames 2 frame 1 locals 0 condition SIMPLE-ERROR: bad 12")
    ;; One request in flight: each is answered before the next goes out
    (host-deliver editor tr 0 "X = 1")
    (is (search "CK.dbgLocals([\"X = 1\"]);" (host-take-evals editor)))
    (is-equal (host-panel-state :debugger editor)
              "open level 1 restarts 1 continue no frames 2 frame 1 locals 1 condition SIMPLE-ERROR: bad 12")
    (with-entry (editor) (debug-restart-clicked editor nil))
    (is-equal (doc-message-text repl) "Select a restart first")
    (is-equal (host-editor-beeps editor) 1)
    (with-entry (editor) (debug-eval-entered editor "(list arg0 arg1)"))
    (is-equal (fake-last-sent tr) "FRAME-EVAL 1 (list arg0 arg1)")
    (host-deliver editor tr 0 "")
    (with-entry (editor) (host-dbg-button editor "continue"))
    (is-equal (fake-last-sent tr) "CONTINUE")
    (host-deliver editor tr 0 "")
    (with-entry (editor) (host-dbg-button editor "abort"))
    (is-equal (fake-last-sent tr) "ABORT")
    (host-deliver editor tr 0 "")
    (with-entry (editor) (host-dbg-button editor "nope"))
    (is (search "no button" (doc-message-text repl)))
    ;; The tab's close hides the panel; the REPL is still parked, and
    ;; M-x clamacs-debugger raises it again
    (with-entry (editor) (host-panel-close editor "debugger"))
    (is (search "CK.dbgClose();" (host-take-evals editor)))
    (is (search "still in the debugger" (doc-message-text repl)))
    (is (debugger-active-p editor))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    (is (not (member '("debugger" 0 400 800 200) (editor-aux-windows editor) :test #'equal)))
    (with-entry (editor) (run-command repl 'clamacs-debugger))
    (is (search "CK.dbgRaise();" (host-take-evals editor)))
    (is-equal (host-panel-state :dock editor) "open height 200 shown debugger")
    ;; Invoke with restart 0 selected, and the level leaves
    (with-entry (editor) (debug-restart-clicked editor 0))
    (is-equal (fake-last-sent tr) "RESTART 0")
    (host-deliver editor tr 0 "")
    (with-entry (editor) (port-raw-command editor "DEBUGGER 0 CL-USER"))
    (is (search "CK.dbgClose();" (host-take-evals editor)))
    (is-equal (host-panel-state :debugger editor)
              "closed level 0 restarts 1 continue no frames 2 frame none locals 1 condition SIMPLE-ERROR: bad 12")
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    ;; Closed twice is closed once: nothing more goes to the page
    (with-entry (editor) (editor-debugger-close editor))
    (is-equal (host-take-evals editor) "")))

(deftest host-inspector-panel-shows-the-object-and-descends
  (multiple-value-bind (editor doc tr) (host-wired-editor "")
    (with-entry (editor) (inspect-form doc "(list 1 (list 2 3))"))
    (is-equal (fake-last-sent tr) "IN-PACKAGE CL-USER")
    (host-deliver editor tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "INSPECT (list 1 (list 2 3))")
    (host-take-evals editor)
    (host-deliver editor tr 0 *host-cons-reply*)
    (is (search "CK.inspOpen(\"CONS\",1,\"(1 (2 3))\",[\"0: Car = 1\",\"1: Cdr = (2 3)\"]);"
                (host-take-evals editor)))
    (is-equal (host-panel-state :inspector editor) "open type CONS depth 1 parts 2 object (1 (2 3))")
    (is-equal (host-panel-state :dock editor) "open height 200 shown inspector")
    (is-equal (editor-aux-windows editor) '(("dock" 0 400 800 200) ("inspector" 0 400 800 200)))
    (is-equal (doc-message-text doc) "Inspecting CONS: (1 (2 3))")
    ;; Back at the first object is refused; a part descends; Back pops
    (with-entry (editor) (inspect-back-clicked editor))
    (is-equal (doc-message-text doc) "Already at the object the inspector started from")
    (with-entry (editor) (inspect-part-clicked editor nil))
    (is-equal (doc-message-text doc) "Not a part")
    (with-entry (editor) (inspect-part-clicked editor 1))
    (is-equal (fake-last-sent tr) "PART 1")
    (host-deliver editor tr 0 (lines "CONS 2 2" "((2 3))" "0: Car = (2 3)" "1: Cdr = NIL"))
    (is (search "CK.inspOpen(\"CONS\",2,\"((2 3))\",[\"0: Car = (2 3)\",\"1: Cdr = NIL\"]);"
                (host-take-evals editor)))
    (is-equal (host-panel-state :inspector editor) "open type CONS depth 2 parts 2 object ((2 3))")
    (with-entry (editor) (inspect-back-clicked editor))
    (is-equal (fake-last-sent tr) "POP")
    ;; The tab's close hides the panel; the next C-c I shows it again
    (with-entry (editor) (host-panel-close editor "inspector"))
    (is-equal (host-panel-state :inspector editor) "closed type CONS depth 2 parts 2 object ((2 3))")
    (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
    (host-deliver editor tr 0 *host-cons-reply*)
    (is-equal (host-panel-state :dock editor) "open height 200 shown inspector")))

(deftest host-a-panel-tab-the-user-picks-is-the-docks-shown-item
  ;; The REPL is displayed, Diagnostics and Debugger are open, and the user
  ;; clicks a panel's tab: the page displays it and says so
  ;; (clamacsDockShown), so closing the REPL afterwards leaves the dock on
  ;; that panel on both sides instead of moving Lisp's mirror to the first
  ;; open panel.
  (multiple-value-bind (editor doc repl) (host-repl-fixture)
    (declare (ignore doc))
    (with-entry (editor) (editor-show-diagnostics editor '("a:1: ERROR: x") :open t))
    (with-entry (editor) (editor-debugger-open editor (make-debugger)))
    (with-entry (editor) (doc-activate repl))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    (host-take-evals editor)
    ;; Not an open panel, a tool buffer's id, JSON null, a number: nothing
    (with-entry (editor) (host-dock-shown editor "inspector"))
    (with-entry (editor) (host-dock-shown editor "doc2"))
    (with-entry (editor) (host-dock-shown editor :null))
    (with-entry (editor) (host-dock-shown editor 7))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    ;; The Debugger tab, then the Diagnostics tab, then the Debugger's again
    (with-entry (editor) (host-dock-shown editor "debugger"))
    (is-equal (host-panel-state :dock editor) "open height 200 shown debugger")
    (with-entry (editor) (host-dock-shown editor "diagnostics"))
    (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics")
    (with-entry (editor) (host-dock-shown editor "debugger"))
    ;; A tab pick tells the page nothing: it displays the tab already
    (is-equal (host-take-evals editor) "")
    ;; A second tool buffer displayed, the Debugger tab picked over it, and
    ;; that buffer closed: the dock stays on the picked panel instead of
    ;; moving to the first open one
    (let ((desc nil))
      (with-entry (editor) (setq desc (ensure-scratch-document editor "*clamacs-description*" nil)))
      (is-equal (host-panel-state :dock editor) "open height 200 shown doc3")
      (with-entry (editor) (host-dock-shown editor "debugger"))
      (with-entry (editor) (run-command desc 'kill-buffer))
      (is (doc-closing desc))
      (is-equal (host-panel-state :dock editor) "open height 200 shown debugger"))
    ;; The panel not displayed closes without moving the dock; the displayed
    ;; one hands the dock to the next open item, the REPL
    (with-entry (editor) (host-panel-close editor "diagnostics"))
    (is-equal (host-panel-state :dock editor) "open height 200 shown debugger")
    (with-entry (editor) (editor-debugger-close editor))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    ;; The REPL's close takes the session's debugger with it (its window
    ;; is the session's): nothing open, the dock collapses
    (with-entry (editor) (run-command repl 'kill-buffer))
    (is (doc-closing repl))
    (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")))

(deftest host-a-tool-buffer-saved-to-a-file-stays-a-dock-tab
  ;; C-x C-w gives *clamacs-description* a path and the file's name, so
  ;; TOOL-DOCUMENT-P says no from then on -- but the page made its tab in
  ;; the dock and keeps it there.  The dock's mirror follows the tab, not
  ;; the name: activating the saved buffer shows the dock, another item
  ;; closing shows it, closing it collapses the dock.
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x"))
         (path (temp-file "host-description.txt"))
         (desc nil)
         (saved nil))
    (host-take-evals editor)
    (with-entry (editor)
      (setq desc (ensure-scratch-document editor "*clamacs-description*" nil)))
    (is (search "CK.makeDoc(\"doc2\",\"*clamacs-description*\",\"tool\");" (host-take-evals editor)))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    (with-entry (editor) (doc-set-text desc "some description"))
    (with-entry (editor) (setq saved (save-file desc path)))
    (is saved)
    (is (not (tool-document-p desc)))
    (is-equal (doc-name desc) (path-basename path))
    (is (not (doc-modified-p desc)))
    ;; Source and dock are different regions: the dock stays on it
    (with-entry (editor) (doc-activate doc))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    ;; A panel over it, and closing the panel shows the saved buffer's tab
    ;; again, as the page does
    (with-entry (editor) (editor-show-diagnostics editor '() :open t))
    (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics")
    (with-entry (editor) (host-panel-close editor "diagnostics"))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    ;; Activating it (its tab picked) keeps the dock on it; closing it
    ;; collapses the dock
    (with-entry (editor) (doc-activate desc))
    (is-equal (host-panel-state :dock editor) "open height 200 shown doc2")
    (with-entry (editor) (run-command desc 'kill-buffer))
    (is (doc-closing desc))
    (is (search "CK.removeDoc(\"doc2\");" (host-take-evals editor)))
    (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
    (is-equal (editor-aux-windows editor) '())
    (delete-file path)))

(deftest host-dock-height-comes-from-the-layout-and-the-splitter
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x"))
         (cfg (temp-file "host-dock.cfg")))
    (host-take-evals editor)
    ;; Nothing stored: nothing said
    (with-entry (editor) (place-dock editor))
    (is-equal (host-take-evals editor) "")
    (winstore-set (editor-layout editor) "dock" 0 400 800 260)
    (with-entry (editor) (place-dock editor))
    (is-equal (host-take-evals editor) "CK.setDock(260);")
    (is-equal (host-editor-dock-height editor) 260)
    ;; The splitter dragged: the new height is what the snapshot stores
    (with-entry (editor) (host-dock-resized editor 310))
    (is-equal (host-editor-dock-height editor) 310)
    ;; A page at a fractional zoom reports a float: rounded, not dropped
    (with-entry (editor) (host-dock-resized editor 310.4))
    (is-equal (host-editor-dock-height editor) 310)
    (with-entry (editor) (host-dock-resized editor 312.6))
    (is-equal (host-editor-dock-height editor) 313)
    (with-entry (editor) (host-dock-resized editor 310))
    (with-entry (editor) (host-dock-resized editor 0))
    (with-entry (editor) (host-dock-resized editor -5.5))
    (with-entry (editor) (host-dock-resized editor "x"))
    (is-equal (host-editor-dock-height editor) 310)
    (with-entry (editor) (editor-show-diagnostics editor '() :open t))
    (is-equal (editor-aux-windows editor) '(("dock" 0 290 800 310) ("errors" 0 290 800 310)))
    (let ((*snapshot-files* (list cfg)))
      (with-entry (editor) (run-command doc 'clamacs-snapshot-windows))
      (is-equal (doc-message-text doc)
                (format nil "Saved the positions of 3 window(s) to ~A" cfg))
      (let ((text (read-file-text cfg)))
        (is (search (format nil "~%doc1 0 0 800 600~%") text))
        (is (search (format nil "~%dock 0 290 800 310~%") text))
        (is (search (format nil "~%errors 0 290 800 310~%") text))))
    ;; What the page reports is kept as it came
    (is-equal (host-page-panels editor) "no report")
    (with-entry (editor) (host-panels-report editor "{\"dock\":{\"open\":true}}"))
    (is-equal (host-page-panels editor) "{\"dock\":{\"open\":true}}")
    (is-equal (host-panel-state :dock nil) "no editor")
    (delete-file cfg)))

;;; --- the menu bar (phase H4) ---------------------------------------------------

(defun host-menu-editor (&optional (text "") path)
  "A host editor without a window that was handed the menu table, as
START hands it before the first document, and a document on it; the
batch of both taken."
  (let ((editor (host-test-editor)))
    (with-entry (editor) (send-menus editor))
    (let ((doc (host-test-document editor text path)))
      (values editor doc (host-take-evals editor)))))

(defun menu-enable-call (command flag)
  (format nil "CK.menuEnable(~D,~A);" (menu-find command) (if flag "true" "false")))

(defun menu-disabled-indices (editor)
  "The indices HOST-PANEL-STATE :MENU lists as disabled."
  (let* ((state (host-panel-state :menu editor))
         (start (search "disabled (" state)))
    (read-from-string state t nil :start (+ start (length "disabled ")))))

(defun count-calls (call js)
  "How often CALL occurs in the batch JS."
  (loop with start = 0 and n = 0
        for at = (search call js :start2 start)
        while at do (incf n) (setq start (1+ at))
        finally (return n)))

(deftest host-menu-bar-is-the-table-and-its-enable-states-follow-the-editor
  (multiple-value-bind (editor doc js) (host-menu-editor "" nil)
    ;; The table, one entry per index, at the head of the batch
    (is (search "CK.setMenus([[\"title\",\"Project\",\"\"],[\"item\",\"New\",\"\"],[\"item\",\"Open...\",\"C-x C-f\"]," js))
    (is (search "[\"bar\",\"\",\"\"]" js))
    ;; The two dynamic groups go out under their names, the themes with
    ;; the title of their submenu
    ;; -- the View menu's text-size items first, then its groups
    (is (search "[\"title\",\"View\",\"\"],[\"item\",\"Bigger Text\",\"C-x C-+\"],[\"item\",\"Smaller Text\",\"C-x C--\"],[\"item\",\"Normal Text Size\",\"C-x C-0\"],[\"bar\",\"\",\"\"],[\"themes\",\"Themes\",\"\"],[\"minimap\",\"\",\"\"],[\"title\",\"Buffers\",\"\"],[\"buffers\",\"\",\"\"],[\"title\",\"Help\",\"\"]" js))
    (is (< (search "CK.setMenus" js) (search "CK.makeDoc" js)))
    ;; Every item's state went out once: a clean unnamed buffer without a
    ;; wire dims Save, Complete Symbol and the REPL, keeps Open and Undo
    (is (search (menu-enable-call 'find-file t) js))
    (is (search (menu-enable-call 'undo t) js))
    (is (search (menu-enable-call 'save-buffer nil) js))
    (is (search (menu-enable-call 'complete-symbol nil) js))
    (is (search (menu-enable-call 'clamacs-repl nil) js))
    (is (search (menu-enable-call 'clamacs-repl-clear nil) js))
    (is-equal (count-calls "CK.menuEnable(" js)
              (count :item (menu-entries) :key #'menu-entry-kind))
    (is (search (format nil "items ~D disabled (" (count :item (menu-entries) :key #'menu-entry-kind))
                (host-panel-state :menu editor)))
    (is (member (menu-find 'save-buffer) (menu-disabled-indices editor)))
    ;; Nothing changed: nothing said
    (with-entry (editor) nil)
    (is-equal (host-take-evals editor) "")
    ;; The first edit enables Save -- and only Save is mentioned
    (host-type-text editor "x")
    (let ((js (host-take-evals editor)))
      (is (search (menu-enable-call 'save-buffer t) js))
      (is-equal (count-calls "CK.menuEnable(" js) 1))
    (is (not (member (menu-find 'save-buffer) (menu-disabled-indices editor))))
    ;; A prompt opened by the menu: `M-x' is Run Command...
    (with-entry (editor) (host-menu-pick editor (menu-find 'execute-extended-command)))
    (is (minibuffer-open-p doc))
    (is (search "CK.openMini(\"M-x \",\"\");" (host-take-evals editor)))
    (host-type editor "C-g")))

(deftest host-menu-pick-runs-the-command-on-the-active-document
  (multiple-value-bind (editor doc) (host-menu-editor (lines "(defun a ()" "  1)" "" "(defun b ()" "  2)"))
    (doc-set-point doc (doc-end doc))
    (with-entry (editor) (host-menu-pick editor (menu-find 'beginning-of-defun)))
    (is-equal (doc-index-line doc (doc-point doc)) 3)
    ;; A dimmed item is refused, however the page came to send it: Save on a
    ;; clean buffer neither asks for a file nor writes one
    (with-entry (editor) (host-menu-pick editor (menu-find 'save-buffer)))
    (is-equal (host-editor-asked editor) '())
    ;; A title, a bar, an index off the table, JSON null: nothing
    (with-entry (editor) (host-menu-pick editor 0))
    (with-entry (editor) (host-menu-pick editor (menu-count)))
    (with-entry (editor) (host-menu-pick editor :null))
    (is-equal (doc-index-line doc (doc-point doc)) 3)
    ;; About: the requester, with the toolkit lines of a stubbed page
    (with-entry (editor) (host-menu-pick editor (menu-find 'clamacs-about)))
    (let ((asked (first (host-editor-asked editor))))
      (is (search "clamacs 0." (first asked)))
      (is (search "no native shim (page stubbed)" (first asked)))
      (is (search "webview unknown, WebKit unknown" (first asked)))
      (is-equal (second asked) '(:ok)))
    ;; Help > HyperSpec goes to the browser
    (with-entry (editor) (host-menu-pick editor (menu-find 'clamacs-hyperspec)))
    (is-equal (host-editor-urls editor) (list *hyperspec-url*))
    (is-equal (doc-message-text doc) (format nil "Opened ~A" *hyperspec-url*))))

(deftest host-webkit-version-is-read-off-the-user-agent
  (is-equal (webkit-version "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)")
            "605.1.15")
  (is-equal (webkit-version "AppleWebKit/700") "700")
  (is-equal (webkit-version "Mozilla/5.0 Gecko/2010") "unknown")
  (is-equal (webkit-version nil) "unknown"))

;;; The theme state is global (theme.lisp): a test that picks runs with
;;; no pick, a known default, the init file a scratch path, and the
;;; registry as it was afterwards -- test-theme.lisp's WITH-THEME-STATE,
;;; kept here too so this file runs on its own (CLAMACS_TEST=host).
;;; LOAD-THEME reaches the frontend through *EDITOR*, the running editor:
;;; the test's editor stands in as soon as it is made (WITH-HOST-EDITOR).
(defmacro with-host-theme-state (&body body)
  `(let ((*theme* nil)
         (*default-theme* :light)
         (*editor* nil)
         (*init-file* (temp-file "host-theme-rc"))
         (saved-themes (copy-list *themes*)))
     (unwind-protect (progn ,@body)
       (setq *themes* saved-themes)
       (delete-quietly *init-file*))))

(defmacro with-host-editor ((editor) &body body)
  "BODY with EDITOR as the running editor, as START makes it."
  `(let ((*editor* ,editor)) ,@body))

(defparameter *host-builtin-theme-lines*
  '("> Light" "  Dark" "  Solarized Light" "  Solarized Dark" "  One Dark" "  Gruvbox Dark")
  "The View menu's lines with no pick made.")

(deftest host-buffers-menu-follows-the-documents-and-the-tick
  (multiple-value-bind (editor d1 js) (host-menu-editor "one")
    (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",true]]);" js))
    (let ((d2 (host-test-document editor "two")))
      ;; A second unnamed buffer: Emacs's <2>, the tick on the new one
      (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",false],[\"(unnamed)<2>\",true]]);" (host-take-evals editor)))
      (is-equal (editor-dynamic-menu-lines editor :buffers) '("  (unnamed)" "> (unnamed)<2>"))
      (is (search "buffers (  (unnamed)|> (unnamed)<2>)" (host-panel-state :menu editor)))
      ;; A pick by the page's position activates; only the tick is remade
      (with-entry (editor) (host-dynamic-pick editor :buffers 0))
      (is (eq (editor-active-document editor) d1))
      (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",true],[\"(unnamed)<2>\",false]]);" (host-take-evals editor)))
      ;; The port's BUFFERS verb reads the page's lines and picks by label
      (is-equal (nth-value 1 (port-command editor "BUFFERS"))
                (format nil "> (unnamed)~%  (unnamed)<2>"))
      (is-equal (nth-value 1 (port-command editor "BUFFERS (unnamed)<2>")) "")
      (is (eq (editor-active-document editor) d2))
      (is-equal (nth-value 1 (port-command editor "BUFFERS nobody")) "no such buffer")
      ;; A position off the menu, null, or a group the bar does not have:
      ;; nothing
      (with-entry (editor) (host-dynamic-pick editor :buffers 7))
      (with-entry (editor) (host-dynamic-pick editor :buffers :null))
      (with-entry (editor) (host-dynamic-pick editor :windows 0))
      (is (eq (editor-active-document editor) d2))
      ;; A tool buffer goes below the bar; the bar's position is not a pick
      (with-entry (editor) (show-text-window editor "*clamacs-scratch*" nil "hello"))
      (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",false],[\"(unnamed)<2>\",false],\"-\",[\"*clamacs-scratch*\",true]]);"
                  (host-take-evals editor)))
      (with-entry (editor) (host-dynamic-pick editor :buffers 2))
      (is-equal (doc-name (editor-active-document editor)) "*clamacs-scratch*")
      (with-entry (editor) (host-dynamic-pick editor :buffers 1))
      (is (eq (editor-active-document editor) d2))
      ;; A closed buffer leaves the menu
      (with-entry (editor) (run-command d2 'kill-buffer))
      (reap editor)
      (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",true],\"-\",[\"*clamacs-scratch*\",false]]);"
                  (host-take-evals editor))))))

(deftest host-text-size-is-the-themes-font-size-variable
  ;; The View menu's text-size items: a step re-sends the theme with
  ;; `--font-size' the setting's, the init file gets the form, and Normal
  ;; puts the theme's own size back.  The size in effect starts from the
  ;; theme's :font-size (14px).
  (with-host-theme-state
    (let ((*font-size* nil))
      (multiple-value-bind (editor doc js) (host-menu-editor "one")
        (declare (ignore js))
        (with-host-editor (editor)
          (is-equal (editor-default-font-size editor) 14)
          (is-equal (effective-font-size editor) 14)
          (with-entry (editor) (run-command doc 'clamacs-increase-font-size))
          (is-equal *font-size* 16)
          (let ((js (host-take-evals editor)))
            (is (search "CK.theme(" js))
            (is (search "[\"--font-size\",\"16px\"]],false);" js))
            (is (not (search "14px" js))))
          (is (search "(font-size 16)" (read-file-text *init-file*)))
          (with-entry (editor) (run-command doc 'clamacs-increase-font-size))
          (is (search "[\"--font-size\",\"18px\"]],false);" (host-take-evals editor)))
          ;; The menu items are the same commands; a pick through the
          ;; table index steps down
          (with-entry (editor) (menu-pick editor (menu-find 'clamacs-decrease-font-size)))
          (is-equal *font-size* 16)
          (is (search "16px" (host-take-evals editor)))
          ;; Normal: the theme's own size again, the form says NIL
          (with-entry (editor) (run-command doc 'clamacs-reset-font-size))
          (is (null *font-size*))
          (is (search "[\"--font-size\",\"14px\"]],false);" (host-take-evals editor)))
          (is (search "(font-size nil)" (read-file-text *init-file*)))
          ;; A theme pick keeps the size setting over the new theme's
          (setq *font-size* 20)
          (with-entry (editor) (host-dynamic-pick editor :themes 3))
          (is (search "[\"--font-size\",\"20px\"]],true);" (host-take-evals editor)))
          (setq *font-size* nil))))))

(deftest host-view-menu-lists-the-themes-and-a-pick-loads-one
  (with-host-theme-state
    (multiple-value-bind (editor doc js) (host-menu-editor "one")
     (with-host-editor (editor)
      ;; The View menu went out with the table, the default ticked
      (is (search "CK.setDynamic(\"themes\",[[\"Light\",true],[\"Dark\",false],[\"Solarized Light\",false],[\"Solarized Dark\",false],[\"One Dark\",false],[\"Gruvbox Dark\",false]]);" js))
      (is-equal (editor-dynamic-menu-lines editor :themes) *host-builtin-theme-lines*)
      (is (search (format nil "themes (~{~A~^|~})" *host-builtin-theme-lines*)
                  (host-panel-state :menu editor)))
      ;; Nothing changed: nothing said
      (with-entry (editor) nil)
      (is-equal (host-take-evals editor) "")
      ;; A pick by the page's position is LOAD-THEME: the theme, the
      ;; page's CK.theme, the tick, the init file
      (with-entry (editor) (host-dynamic-pick editor :themes 3))
      (is (eq *theme* (find-theme :solarized-dark)))
      (let ((js (host-take-evals editor)))
        (is (search "CK.theme([[\"--bg\",\"#002b36\"],[\"--fg\",\"#839496\"]" js))
        (is (search "[\"--c-keyword\",\"#859900\"]" js))
        (is (search "[\"--font-size\",\"14px\"]],true);" js))
        (is (search "CK.setDynamic(\"themes\",[[\"Light\",false],[\"Dark\",false],[\"Solarized Light\",false],[\"Solarized Dark\",true],[\"One Dark\",false],[\"Gruvbox Dark\",false]]);" js))
        ;; The theme is sent before the menu's tick: what the page shows
        ;; first is the colours
        (is (< (search "CK.theme(" js) (search "CK.setDynamic(\"themes\"" js))))
      (is (search "(load-theme :solarized-dark)" (read-file-text *init-file*)))
      (is-equal (host-panel-state :theme editor)
                "solarized-dark dark bg #002b36 keyword #859900 system unknown gutter #073642")
      ;; The port's THEMES verb reads the page's lines and picks by label
      (is-equal (nth-value 1 (port-command editor "THEMES"))
                (format nil "  Light~%  Dark~%  Solarized Light~%> Solarized Dark~%  One Dark~%  Gruvbox Dark"))
      (is-equal (nth-value 1 (port-command editor "THEMES One Dark")) "")
      (is (eq *theme* (find-theme :one-dark)))
      ;; (the port runs its verbs inside an entry, which flushes)
      (flush-batch editor)
      (is (search "[\"--bg\",\"#282c34\"]" (host-take-evals editor)))
      (is-equal (nth-value 1 (port-command editor "THEMES Nobody")) "no such theme")
      (is (eq *theme* (find-theme :one-dark)))
      ;; The page's pick comes with the group's name: what it spells
      (is (eq (dynamic-group-named editor "themes") :themes))
      (is (eq (dynamic-group-named editor "BUFFERS") :buffers))
      (is (null (dynamic-group-named editor "windows")))
      (is (null (dynamic-group-named editor :null)))
      (is (null (dynamic-group-named editor 3)))
      (is (null (dynamic-group-named editor nil)))
      ;; A theme defined from the REPL is in the menu after the next
      ;; entry, below a bar, and the command's message names the label
      (with-entry (editor)
        (register-theme (make-theme :mine '(:inherits :dark :label "Mine") '(:keyword "#ff9900"))))
      (is (search "CK.setDynamic(\"themes\",[[\"Light\",false],[\"Dark\",false],[\"Solarized Light\",false],[\"Solarized Dark\",false],[\"One Dark\",true],[\"Gruvbox Dark\",false],\"-\",[\"Mine\",false]]);"
                  (host-take-evals editor)))
      (with-entry (editor) (host-dynamic-pick editor :themes 7))
      (is (eq *theme* (find-theme :mine)))
      (is (search "[\"--c-keyword\",\"#ff9900\"]" (host-take-evals editor)))
      (is (search "(load-theme :mine)" (read-file-text *init-file*)))
      ;; The bar's position is not a pick
      (with-entry (editor) (host-dynamic-pick editor :themes 6))
      (is (eq *theme* (find-theme :mine)))
      (is (not (search "CK.theme(" (host-take-evals editor))))
      ;; A pick without the page (the shim's path, the same function):
      ;; C-u M-x clamacs-theme leaves the file alone
      (with-entry (editor) (run-command doc 'clamacs-theme 4))
      (host-type-text editor "gruvbox-dark")
      (host-type editor "RET")
      (is (eq *theme* (find-theme :gruvbox-dark)))
      (is-equal (doc-message-text doc) "Theme: Gruvbox Dark (this session)")
      (is (search "(load-theme :mine)" (read-file-text *init-file*)))))))

(deftest host-view-menu-toggles-the-minimap-and-remembers-it
  ;; The View menu's other group (phase H9): the page draws the map, Lisp
  ;; keeps the setting -- the tick, CK.setMinimap to every page, the init
  ;; file's form, the port's verb, the command.
  (with-host-theme-state
    (let ((*minimap* t))
      (multiple-value-bind (editor doc js) (host-menu-editor "one")
        (with-host-editor (editor)
          ;; The group went out with the table, ticked
          (is (search "CK.setDynamic(\"minimap\",[[\"Minimap\",true]]);" js))
          (is-equal (editor-dynamic-menu-lines editor :minimap) '("> Minimap"))
          (is (search "minimap (> Minimap)" (host-panel-state :menu editor)))
          (is-equal (host-panel-state :minimap editor) "on")
          ;; START sends the setting after the theme; a later window gets
          ;; it when it settles
          (with-entry (editor) (send-minimap editor))
          (is (search "CK.setMinimap(true);" (host-take-evals editor)))
          (with-entry (editor) (send-minimap-to (host-editor-main editor)))
          (is (search "CK.setMinimap(true);" (host-take-evals editor)))
          ;; Nothing changed: nothing said
          (with-entry (editor) nil)
          (is-equal (host-take-evals editor) "")
          ;; A pick by the page's position hides it: the page, then the
          ;; tick, and the init file
          (with-entry (editor) (host-dynamic-pick editor :minimap 0))
          (is (null *minimap*))
          (let ((js (host-take-evals editor)))
            (is (search "CK.setMinimap(false);" js))
            (is (search "CK.setDynamic(\"minimap\",[[\"Minimap\",false]]);" js))
            (is (< (search "CK.setMinimap(" js) (search "CK.setDynamic(\"minimap\"" js))))
          (is (search "(show-minimap nil)" (read-file-text *init-file*)))
          (is-equal (host-panel-state :minimap editor) "off")
          (is (search "minimap (  Minimap)" (host-panel-state :menu editor)))
          ;; The port's verb reads the line and picks it
          (is-equal (nth-value 1 (port-command editor "MINIMAP")) "  Minimap")
          (is-equal (nth-value 1 (port-command editor "MINIMAP Minimap")) "")
          (is *minimap*)
          (flush-batch editor)
          (is (search "CK.setMinimap(true);" (host-take-evals editor)))
          (is (search "(show-minimap t)" (read-file-text *init-file*)))
          (is-equal (nth-value 1 (port-command editor "MINIMAP Nobody")) "no such item")
          ;; A position off the group: nothing
          (with-entry (editor) (host-dynamic-pick editor :minimap 1))
          (is *minimap*)
          (is (eq (dynamic-group-named editor "minimap") :minimap))
          ;; The command: C-u M-x clamacs-toggle-minimap leaves the file alone
          (with-entry (editor) (run-command doc 'clamacs-toggle-minimap 4))
          (is (null *minimap*))
          (is-equal (doc-message-text doc) "Minimap off (this session)")
          (is (search "CK.setMinimap(false);" (host-take-evals editor)))
          (is (search "(show-minimap t)" (read-file-text *init-file*)))
          ;; The init file's own form is loaded without being written back
          (write-file-text *init-file* (format nil "(show-minimap t)~%"))
          (is-equal (load-init-file *init-file*) t)
          (is *minimap*)
          (is-equal (read-file-text *init-file*) (format nil "(show-minimap t)~%"))
          (flush-batch editor)
          (is (search "CK.setMinimap(true);" (host-take-evals editor))))))))

(deftest host-theme-goes-to-the-page-at-start-and-follows-the-system-scheme
  (with-host-theme-state
    (let ((editor (host-test-editor)))
      ;; START's order: the menus, then the theme -- the page's own
      ;; palette until then.  With no pick and no word from the page, the
      ;; light built-in, every variable of the page's :root block
      (with-entry (editor) (send-menus editor) (send-theme editor))
      (let ((js (host-take-evals editor)))
        (is (< (search "CK.setMenus(" js) (search "CK.theme(" js)))
        (is (search "CK.theme([[\"--bg\",\"#ffffff\"],[\"--fg\",\"#1f1f1f\"],[\"--dim\",\"#6a6a6a\"]" js))
        (is (search "[\"--font-family\",\"\\\"SF Mono\\\", Menlo, monospace\"],[\"--font-size\",\"14px\"]],false);" js))
        (is-equal (count-calls "CK.theme(" js) 1))
      (is-equal (host-panel-state :theme editor)
                "light light bg #ffffff keyword #0000ff system unknown gutter #f7f7f7")
      ;; The page reports the system dark at ready: the default follows,
      ;; and so does an editor without a pick
      (host-ready editor "Mozilla/5.0 AppleWebKit/605.1.15" "dark")
      (is (host-editor-ready editor))
      (is-equal (host-editor-user-agent editor) "Mozilla/5.0 AppleWebKit/605.1.15")
      (is-equal (host-editor-scheme editor) "dark")
      (is (eq *default-theme* :dark))
      (is (eq (active-theme) (find-theme :dark)))
      (with-entry (editor) (send-theme editor))
      (is (search "CK.theme([[\"--bg\",\"#1e1e1e\"]" (host-take-evals editor)))
      (is-equal (host-panel-state :theme editor)
                "dark dark bg #1e1e1e keyword #569cd6 system dark gutter #1e1e1e")
      ;; A pick made before the page came up (the init file's) wins over
      ;; the scheme
      (setf *theme* (find-theme :solarized-light))
      (host-ready editor "UA" "light")
      (is (eq *default-theme* :light))
      (is (eq (active-theme) (find-theme :solarized-light)))
      ;; An older page says nothing about the scheme, and a word that is
      ;; not one is ignored: the default stays
      (host-ready editor "UA")
      (host-ready editor "UA" "purple")
      (host-ready editor "UA" :null)
      (is (eq *default-theme* :light))
      (is-equal (host-editor-scheme editor) "light"))))

(deftest host-native-menu-takes-the-table-as-lines-and-its-syncs-go-to-the-shim
  (flet ((tabbed (&rest fields) (format nil "~{~A~^	~}" fields)))
    ;; The table as the shim takes it: one line per entry, in order, the
    ;; dynamic groups under their names
    (let ((text (menu-table-text (host-test-editor))))
      (is (search (lines (tabbed "title" "Project" "") (tabbed "item" "New" "")
                         (tabbed "item" "Open..." "C-x C-f"))
                  text))
      (is (search (lines "" (tabbed "bar" "" "") "") text))
      (is (search (lines (tabbed "title" "View" "")
                         (tabbed "item" "Bigger Text" "C-x C-+") (tabbed "item" "Smaller Text" "C-x C--")
                         (tabbed "item" "Normal Text Size" "C-x C-0") (tabbed "bar" "" "")
                         (tabbed "themes" "Themes" "")
                         (tabbed "minimap" "" "")
                         (tabbed "title" "Buffers" "") (tabbed "buffers" "" "")
                         (tabbed "title" "Help" ""))
                  text))
      (is-equal (count #\Newline text) (1- (menu-count)))))
  ;; A dynamic group as the shim takes it: the port verb's lines
  (is-equal (dynamic-menu-text '(("a.lisp" . :a) ("b.lisp" . :b) :bar ("*clamacs-repl*" . :r)) :b)
            (lines "  a.lisp" "> b.lisp" "-" "  *clamacs-repl*"))
  (is-equal (dynamic-menu-text '() nil) "")
  ;; An editor whose menu is the host's: the page's bar is told an empty
  ;; table, and the enable states and the groups' lines go to the shim --
  ;; onto NATIVE-CALLS without one -- never to the page
  (with-host-theme-state
   (let ((editor (host-test-editor)))
    (setq *editor* editor)
    (with-entry (editor) (send-menus editor :native t))
    (host-test-document editor "one")
    (let ((js (host-take-evals editor))
          (calls (reverse (host-editor-native-calls editor))))
      (is (search "CK.setMenus([]);" js))
      (is (not (search "menuEnable" js)))
      (is (not (search "setDynamic" js)))
      (is-equal (count :enable calls :key #'first)
                (count :item (menu-entries) :key #'menu-entry-kind))
      (is (member (list :enable (menu-find 'find-file) t) calls :test #'equal))
      (is (member (list :enable (menu-find 'save-buffer) nil) calls :test #'equal))
      (is (member (list :enable (menu-find 'clamacs-repl) nil) calls :test #'equal))
      (is (member (list :buffers "> (unnamed)") calls :test #'equal))
      (is (member (list :themes (format nil "~{~A~^~%~}" *host-builtin-theme-lines*)) calls :test #'equal)))
    ;; Nothing changed: nothing said.  The first edit enables Save, alone
    (setf (host-editor-native-calls editor) '())
    (with-entry (editor) nil)
    (is-equal (host-editor-native-calls editor) '())
    (host-type-text editor "x")
    (is-equal (host-editor-native-calls editor) (list (list :enable (menu-find 'save-buffer) t)))
    (is (not (search "menuEnable" (host-take-evals editor))))
    ;; A second buffer remakes the Buffers menu, the tick on the new one;
    ;; the editor's own account reads the same as with the page's bar
    (setf (host-editor-native-calls editor) '())
    (host-test-document editor "two")
    (is (member (list :buffers (lines "  (unnamed)" "> (unnamed)<2>"))
                (host-editor-native-calls editor) :test #'equal))
    (is (search "buffers (  (unnamed)|> (unnamed)<2>)" (host-panel-state :menu editor)))
    (is-equal (editor-dynamic-menu-lines editor :buffers) '("  (unnamed)" "> (unnamed)<2>"))
    ;; A pick by the shim's position activates the edited first buffer,
    ;; and the port's verbs read the state as before: Save follows it
    (with-entry (editor) (host-dynamic-pick editor :buffers 0))
    (is-equal (editor-dynamic-menu-lines editor :buffers) '("> (unnamed)" "  (unnamed)<2>"))
    (is-equal (nth-value 1 (port-command editor "MENU save-buffer STATE")) "enabled")
    (is (member (list :enable (menu-find 'save-buffer) t) (host-editor-native-calls editor) :test #'equal))
    ;; A theme picked on the host's bar: the theme, the View lines remade
    ;; for the shim, the page told the colours (its variables, whichever
    ;; draws the bar)
    (setf (host-editor-native-calls editor) '())
    (with-entry (editor) (host-dynamic-pick editor :themes 1))
    (is (eq *theme* (find-theme :dark)))
    (is (member (list :themes (lines "  Light" "> Dark" "  Solarized Light" "  Solarized Dark" "  One Dark" "  Gruvbox Dark"))
                (host-editor-native-calls editor) :test #'equal))
    (is (search "CK.theme([[\"--bg\",\"#1e1e1e\"]" (host-take-evals editor)))
    ;; No shim: no report of the bar, and no click on it
    (is-equal (host-menu-report editor) "no report")
    (is-equal (host-menu-click 0 (menu-find 'find-file) editor) "no native menu")
    (is-equal (host-menu-click :themes 0 editor) "no native menu"))))

(defun host-test-setenv (name value)
  "libc's setenv in this process -- unsetenv for a NIL VALUE -- which is
what EXT:GETENV reads.  lisp/transport-tcp.lisp makes the same calls, but
loading it here would also replace the wire starter the other tests use."
  (ffi:with-foreign-string (n name)
    (if value
        (ffi:with-foreign-string (v value)
          (ffi:call-foreign (ffi:symbol-pointer "setenv" nil) :int32 '(:pointer :pointer :int32)
                            (list n v 1)))
        (ffi:call-foreign (ffi:symbol-pointer "unsetenv" nil) :int32 '(:pointer) (list n)))))

(deftest host-native-menu-is-wanted-unless-the-environment-asks-for-the-page
  (let ((saved (ext:getenv "CLAMACS_HOST_MENU")))
    (unwind-protect
         (progn
           (host-test-setenv "CLAMACS_HOST_MENU" nil)
           (is (native-menu-wanted-p))
           (host-test-setenv "CLAMACS_HOST_MENU" "page")
           (is (not (native-menu-wanted-p)))
           (host-test-setenv "CLAMACS_HOST_MENU" "PAGE")
           (is (not (native-menu-wanted-p)))
           ;; Anything else, and an empty value, leave the host's own bar
           (host-test-setenv "CLAMACS_HOST_MENU" "")
           (is (native-menu-wanted-p))
           (host-test-setenv "CLAMACS_HOST_MENU" "native")
           (is (native-menu-wanted-p))
           ;; Wanted or not, an editor without a shim has no bar of its own
           (host-test-setenv "CLAMACS_HOST_MENU" nil)
           (is (null (native-menu-install (host-test-editor)))))
      (host-test-setenv "CLAMACS_HOST_MENU" saved))))

(deftest host-native-menu-callback-picks-by-which-and-is-dropped-in-a-modal
  (multiple-value-bind (editor doc) (host-menu-editor (lines "(defun a ()" "  1)" "" "(defun b ()" "  2)"))
    (doc-set-point doc (doc-end doc))
    ;; A requester runs its own loop: a pick is dropped, whichever menu
    (setf (host-editor-in-modal editor) t)
    (native-menu-callback editor 0 (menu-find 'beginning-of-defun))
    (is-equal (doc-point doc) (doc-end doc))
    (setf (host-editor-in-modal editor) nil)
    ;; `which' 0: the table's item, run on the active document
    (native-menu-callback editor 0 (menu-find 'beginning-of-defun))
    (is-equal (doc-index-line doc (doc-point doc)) 3)
    ;; `which' a dynamic group's table index: the n-th line of that group
    (let ((d2 (host-test-document editor "two"))
          (buffers (menu-find-dynamic :buffers))
          (themes (menu-find-dynamic :themes)))
      (is (eq (editor-active-document editor) d2))
      (setf (host-editor-in-modal editor) t)
      (native-menu-callback editor buffers 0)
      (is (eq (editor-active-document editor) d2))
      (setf (host-editor-in-modal editor) nil)
      (native-menu-callback editor buffers 0)
      (is (eq (editor-active-document editor) doc))
      (native-menu-callback editor buffers 1)
      (is (eq (editor-active-document editor) d2))
      ;; A line off the menu, an index off the table, an index that is no
      ;; group's (a title's, an item's), JSON null: nothing, no error
      (native-menu-callback editor buffers 7)
      (native-menu-callback editor 0 (menu-count))
      (native-menu-callback editor (1- buffers) 0)
      (native-menu-callback editor (menu-find 'find-file) 0)
      (native-menu-callback editor :null 0)
      (native-menu-callback editor (menu-count) 0)
      (is (eq (editor-active-document editor) d2))
      ;; The View group's line picks a theme
      (with-host-theme-state
        (setq *editor* editor)
        (with-entry (editor) nil)
        (host-take-evals editor)
        (native-menu-callback editor themes 4)
        (is (eq *theme* (find-theme :one-dark)))
        (is (search "CK.theme([[\"--bg\",\"#282c34\"]" (host-take-evals editor)))
        (is (search "(load-theme :one-dark)" (read-file-text *init-file*)))))))

(deftest host-menu-report-is-the-page-s-menu-object-when-the-page-draws-the-bar
  (let ((editor (host-test-editor)))
    (with-entry (editor) (send-menus editor :native nil))
    (is-equal (host-menu-report editor) "no report")
    (with-entry (editor)
      (host-panels-report editor "{\"menu\":{\"items\":52,\"disabled\":[4,23],\"themes\":[\"> Light\",\"  Dark\"],\"buffers\":[\"> a\",\"-\",\"  *b*\"]},\"theme\":{\"bg\":\"#ffffff\"},\"dock\":{\"open\":false}}"))
    (is-equal (host-menu-report editor)
              "{\"items\":52,\"disabled\":[4,23],\"themes\":[\"> Light\",\"  Dark\"],\"buffers\":[\"> a\",\"-\",\"  *b*\"]}")
    (is (null (page-menu-report "{\"dock\":{\"open\":false}}")))
    (is-equal (host-menu-report nil) "no report")))

(deftest host-without-a-menu-bar-the-buffers-verb-still-answers
  ;; An editor the table was never sent to (the tests' plain one) answers
  ;; BUFFERS and THEMES from the model and sends the page nothing about
  ;; menus.
  (with-host-theme-state
    (let* ((editor (host-test-editor))
           (doc (host-test-document editor "x")))
      (declare (ignore doc))
      (setq *editor* editor)
      (is-equal (nth-value 1 (port-command editor "BUFFERS")) "> (unnamed)")
      (is-equal (nth-value 1 (port-command editor "THEMES"))
                (format nil "~{~A~^~%~}" *host-builtin-theme-lines*))
      (let ((js (host-take-evals editor)))
        (is (not (search "menuEnable" js)))
        (is (not (search "setDynamic" js))))
      ;; A pick still applies the theme through the page
      (is-equal (nth-value 1 (port-command editor "THEMES Dark")) "")
      (is (eq *theme* (find-theme :dark)))
      (flush-batch editor)
      (is (search "CK.theme([[\"--bg\",\"#1e1e1e\"]" (host-take-evals editor))))))

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

;;; --- where the page and the libraries are (phase H6) -------------------------

(deftest host-library-name-follows-the-host
  ;; One suffix per host, decided by the runtime's features -- .dylib for
  ;; :darwin, .so for :linux, .dll where neither is present (Windows: the
  ;; runtime has no feature for it, and pushes :posix and :unix there like
  ;; anywhere off the Amiga).  The features are bound, so every branch runs
  ;; on every host, the Windows fallback included.
  (let ((*features* (list :darwin :posix :unix)))
    (is-equal (host-library-name "libwebview") "libwebview.dylib"))
  (let ((*features* (list :linux :posix :unix)))
    (is-equal (host-library-name "libwebview") "libwebview.so")
    (is-equal (host-library-name "libclamacs-host") "libclamacs-host.so"))
  (let ((*features* (list :posix :unix)))
    (is-equal (host-library-name "libwebview") "libwebview.dll")
    (is-equal (host-library-name "libclamacs-host") "libclamacs-host.dll"))
  (let ((*features* '()))
    (is-equal (host-library-name "libwebview") "libwebview.dll"))
  ;; The real features answer with one of the three.
  (is (member (host-library-name "libwebview")
              '("libwebview.dylib" "libwebview.so" "libwebview.dll")
              :test #'string=)))

(deftest host-frontend-dir-is-chosen-at-run-time
  ;; The environment first; else the running binary's directory when the
  ;; page is there (the app bundle, an installed layout); else the
  ;; checkout's build directory an image may hold from another machine.
  ;; Every answer carries a trailing slash, so a name can be appended.
  ;; A directory of the test's own holding a page.html: TEMP-FILE's names
  ;; carry a prefix, and TMPDIR itself has a page only by accident.
  (let* ((with-page (concatenate 'string (temp-path "frontend-dir") "/"))
         (page (concatenate 'string with-page "page.html"))
         (without (concatenate 'string with-page "nowhere-such/")))
    (ensure-directories-exist page)
    (is (write-file-text page "<html></html>"))
    (is-equal (choose-host-frontend-dir "/env/dir" with-page "/build/") "/env/dir/")
    (is-equal (choose-host-frontend-dir "/env/dir/" nil "/build/") "/env/dir/")
    (is-equal (choose-host-frontend-dir "" with-page "/build/") with-page)
    (is-equal (choose-host-frontend-dir nil with-page "/build/") with-page)
    ;; A directory given without its slash.  The natural (inline) spelling
    ;; stays, not a let-bound one: one wrong answer to exactly this was seen
    ;; once and never again (specs/clamacs-host.md, R5), and a test that
    ;; only ever passes a let-bound copy would hide it.
    (is-equal (choose-host-frontend-dir nil (string-right-trim "/" with-page) "/build/") with-page)
    (is-equal (choose-host-frontend-dir nil without "/build/") "/build/")
    (is-equal (choose-host-frontend-dir nil nil "/build/") "/build/")
    ;; What the editor asks for ends in the file's name under that directory.
    (let ((file (host-frontend-file "page.html")))
      (is (search "/page.html" file))
      (is-equal (host-frontend-dir) (subseq file 0 (- (length file) (length "page.html")))))
    (delete-file page)))

;;; --- detached windows (phase H7) ---------------------------------------------
;;;
;;; A window without a page is ready at once, and HOUSEKEEPING settles it
;;; and moves the tab in, as the loop does once a real page reported
;;; ready; each window keeps the batches it would have sent to its page.

(defun host-detach-now (editor name)
  "NAME shown in a window of its own, the loop's turn taken: the window
settled and the tab moved.  The message HOST-DETACH answered."
  (let ((answer nil))
    (with-entry (editor)
      (setq answer (host-detach editor name))
      (housekeeping editor))
    answer))

(deftest host-a-tab-shown-separately-moves-into-a-window-of-its-own
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "(defun a ())"))
         (d2 (host-test-document editor "(defun b ())")))
    (host-take-evals editor)
    (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1 doc2) active doc2")
    ;; The ask makes the window; nothing moves and nothing is sent until
    ;; its page is up
    (with-entry (editor)
      (is-equal (host-detach editor "doc1") "doc1 detached"))
    (let ((w2 (host-window editor 2)))
      (is w2)
      (is (not (host-window-settled w2)))
      (is-equal (host-window-pending w2) (list d1))
      (is (eq (hdoc-window d1) (host-editor-main editor)))
      (is-equal (host-take-evals editor) "")
      (is-equal (host-take-evals w2) "")
      ;; Settled: the theme, the dock's height and the detached mark, then
      ;; the tab made from the mirror -- the text, then the colours, then
      ;; the activation -- while the main page loses the tab.  No menu
      ;; table went out here, so none goes to the new page either.
      (with-entry (editor) (housekeeping editor))
      (is (host-window-settled w2))
      (is (eq (hdoc-window d1) w2))
      (is-equal (host-window-pending w2) '())
      (let ((main-js (host-take-evals editor))
            (js (host-take-evals w2)))
        (is (search "CK.removeDoc(\"doc1\");" main-js))
        (is (not (search "makeDoc" main-js)))
        (is (not (search "setMenus" js)))
        (is (search "CK.theme([" js))
        (is (search "CK.setDock(200);CK.setDetached(true);" js))
        (is (search "CK.makeDoc(\"doc1\",\"(unnamed)\",\"source\");CK.setTitle(\"doc1\",\"(unnamed)\");CK.applyEdit(\"doc1\",0,0,\"(defun a ())\"," js))
        (is (search "CK.colour(\"doc1\",[[0,[[" js))
        (is (search "CK.activateDoc(\"doc1\");" js))
        (is (< (search "CK.applyEdit(" js) (search "CK.colour(" js)))
        (is (< (search "CK.colour(" js) (search "CK.activateDoc(" js))))
      (is (eq (editor-active-document editor) d1))
      (is-equal (host-editor-raised editor) '(2))
      (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc2) 2 (doc1) active doc1")
      ;; The window cascades off the main one (`doc1' is the main window's
      ;; place), and each document answers its own window's frame
      (is-equal (multiple-value-list (window-frame w2)) '(40 40 800 600))
      (is-equal (multiple-value-list (doc-geometry d1)) '(40 40 800 600))
      (is-equal (multiple-value-list (doc-geometry d2)) '(0 0 800 600))
      ;; A key edits the moved document, and what it changes goes to its
      ;; window alone -- the status line and the title with it
      (host-type-text editor "x")
      (is-equal (host-text d1) "x(defun a ())")
      (let ((js (host-take-evals w2)))
        (is (search "CK.applyEdit(\"doc1\",0,0,\"x\",1);" js))
        (is (search "CK.setStatus(\"*(unnamed)  CL-USER  1:2\");" js)))
      (is-equal (host-take-evals editor) "")
      (is-equal (host-window-shown-title w2) "(unnamed)")
      ;; Back: the tab is made in the main window again, and the window
      ;; left empty goes at the next turn
      (with-entry (editor)
        (is-equal (host-attach editor "doc1") "doc1 attached"))
      (is (eq (hdoc-window d1) (host-editor-main editor)))
      (is (search "CK.makeDoc(\"doc1\",\"(unnamed)\",\"source\");" (host-take-evals editor)))
      (is (search "CK.removeDoc(\"doc1\");" (host-take-evals w2)))
      (is (eq (host-window-closing w2) :empty))
      (with-entry (editor) (housekeeping editor))
      (is (null (host-window editor 2)))
      (is-equal (live-windows editor) (list (host-editor-main editor)))
      (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1 doc2) active doc1")
      ;; Already there, and a name no tab has
      (with-entry (editor)
        (is-equal (host-attach editor "doc1") "doc1 is in the main window"))
      (is-equal (host-attach editor "nope") "no tab nope")
      (is-equal (host-detach editor "nope") "no tab nope")
      (is-equal (host-detach editor :null) "no tab NULL")
      (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1 doc2) active doc1"))))

(deftest host-a-detached-window-closes-with-its-last-tab-and-its-close-button-attaches
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two"))
         (d3 (host-test-document editor "three")))
    (host-detach-now editor "doc2")
    (host-detach-now editor "doc3")
    (is-equal (host-panel-state :windows editor) "windows 3: 1 (doc1) 2 (doc2) 3 (doc3) active doc3")
    ;; C-x k on the only tab of window 3: the window goes, the keyboard
    ;; to the oldest open document
    (with-entry (editor) (run-command d3 'kill-buffer))
    (is (doc-closing d3))
    (is (eq (host-window-closing (host-window editor 3)) :empty))
    (with-entry (editor) (housekeeping editor))
    (is (null (host-window editor 3)))
    (is (eq (editor-active-document editor) d1))
    ;; Window 2's close button while the keyboard is in the main window:
    ;; doc2 comes back, the keyboard stays where it was
    (setf (host-window-closing (host-window editor 2)) :attach)
    (with-entry (editor) (housekeeping editor))
    (is (null (host-window editor 2)))
    (is (eq (hdoc-window d2) (host-editor-main editor)))
    (is (eq (editor-active-document editor) d1))
    (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1 doc2) active doc1")
    ;; ... and while the keyboard is in the closed window: its document keeps it
    (host-detach-now editor "doc2")
    (is (eq (editor-active-document editor) d2))
    (setf (host-window-closing (host-window editor 4)) :attach)
    (with-entry (editor) (housekeeping editor))
    (is (null (host-window editor 4)))
    (is (eq (editor-active-document editor) d2))
    (is (search "CK.activateDoc(\"doc2\");" (host-take-evals editor)))
    ;; A new document opens beside the active one, in its window
    (host-detach-now editor "doc1")
    (let ((d4 (host-test-document editor "four")))
      (is (eq (hdoc-window d4) (host-window editor 5)))
      (is (search "CK.makeDoc(\"doc4\",\"(unnamed)\",\"source\");" (host-take-evals (host-window editor 5))))
      (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc2) 5 (doc1 doc4) active doc4"))))

(deftest host-closing-a-multi-tab-window-does-not-steal-focus-from-a-third
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two"))
         (d3 (host-test-document editor "three")))
    (declare (ignore d1))
    (host-detach-now editor "doc2")
    (let ((w2 (host-window editor 2))
          (d4 (host-test-document editor "four")))
      ;; D4 opens beside the active D2, so window 2 now has two tabs
      (is (eq (hdoc-window d4) w2))
      (host-detach-now editor "doc3")
      (let ((w3 (host-window editor 3)))
        (is (eq (editor-active-document editor) d3))
        (is (eq (hdoc-window d3) w3))
        ;; Window 2's close button, with two tabs to move and the keyboard
        ;; really in window 3: ATTACH-ALL must not raise the main window as
        ;; a side effect of moving the first tab back, only to raise
        ;; window 3 again a moment later -- the keyboard never left it, so
        ;; nothing should be raised at all.
        (setf (host-editor-raised editor) '())
        (setf (host-window-closing w2) :attach)
        (with-entry (editor) (housekeeping editor))
        (is (null (host-window editor 2)))
        (is (eq (hdoc-window d2) (host-editor-main editor)))
        (is (eq (hdoc-window d4) (host-editor-main editor)))
        (is-equal (host-editor-raised editor) '())
        (is (eq (editor-active-document editor) d3))
        (is (eq (hdoc-window d3) w3))))))

(deftest host-a-tool-buffer-shown-separately-is-its-windows-dock
  (multiple-value-bind (editor doc repl tr) (host-repl-fixture)
    (declare (ignore doc tr))
    (host-detach-now editor (hdoc-id repl))
    (let ((w2 (host-window editor 2)))
      (is (search "CK.makeDoc(\"doc2\",\"*clamacs-repl*\",\"tool\");" (host-take-evals w2)))
      (is (search "CK.removeDoc(\"doc2\");" (host-take-evals editor)))
      ;; Each window's dock counts what is in it
      (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
      (is-equal (host-window-dock-shown w2) "doc2")
      (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc1) 2 (doc2) active doc2")
      ;; No source tab there: the dock is the whole window (the snapshot's
      ;; `dock' line is the main window's, closed now)
      (is-equal (multiple-value-list (dock-frame w2)) '(40 40 800 600))
      (is-equal (editor-aux-windows editor) '())
      ;; The splitter of that window: its own height
      (with-entry (editor) (host-dock-resized w2 300))
      (is-equal (host-window-dock-height w2) 300)
      (is-equal (host-editor-dock-height editor) 200)
      ;; Killing the REPL leaves the window empty: it goes
      (with-entry (editor) (run-command repl 'kill-buffer))
      (is (eq (host-window-closing w2) :empty))
      (with-entry (editor) (housekeeping editor))
      (is (null (host-window editor 2))))))

(deftest host-a-panel-shown-separately-is-replayed-into-its-window
  (multiple-value-bind (editor doc tr) (host-wired-editor "(x)")
    (declare (ignore doc tr))
    (with-entry (editor)
      (editor-show-diagnostics editor '("a:1: ERROR: x" "a:2: ERROR: y") :open t)
      (editor-select-diagnostic editor 1))
    (host-take-evals editor)
    ;; A closed panel cannot be shown separately; an open one is replayed
    ;; into its window's dock once the window is up
    (is-equal (host-detach editor "debugger") "the debugger panel is not open")
    (is-equal (host-detach-now editor "diagnostics") "diagnostics detached")
    (let ((w2 (host-window editor 2)))
      (is (eq (panel-window editor "diagnostics") w2))
      (is (search "CK.panelHide(\"diagnostics\");" (host-take-evals editor)))
      (is (search "CK.showDiagnostics([\"a:1: ERROR: x\",\"a:2: ERROR: y\"],true);CK.selectDiagnostic(1);"
                  (host-take-evals w2)))
      (is-equal (host-panel-state :diagnostics editor) "open rows 2 selected 1 window 2")
      (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
      (is-equal (host-window-dock-shown w2) "diagnostics")
      (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc1) 2 (diagnostics) active doc1")
      (is-equal (host-editor-raised editor) '(2))
      ;; To the snapshot the panel is where its window is, under its MUI
      ;; role; no source tab there, so the whole window
      (is-equal (editor-aux-windows editor) '(("errors" 40 40 800 600)))
      ;; What the panel is told next goes there
      (with-entry (editor) (editor-select-diagnostic editor 0))
      (is (search "CK.selectDiagnostic(0);" (host-take-evals w2)))
      (is-equal (host-take-evals editor) "")
      ;; The tab's close in that window: the panel off the screen, the
      ;; window gone, the panel the main window's again
      (with-entry (editor) (host-panel-close editor "diagnostics"))
      (is (eq (host-window-closing w2) :empty))
      (with-entry (editor) (housekeeping editor))
      (is (null (host-window editor 2)))
      (is (eq (panel-window editor "diagnostics") (host-editor-main editor)))
      (is (search "closed rows 2" (host-panel-state :diagnostics editor)))
      (with-entry (editor) (editor-show-diagnostics editor '("a:1: ERROR: x") :open t))
      (is (search "CK.showDiagnostics(" (host-take-evals editor)))
      (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics"))
    ;; The debugger, with its frames and locals
    (let ((dbg (editor-debugger-state editor)))
      (setf (debugger-level dbg) 1
            (debugger-condition dbg) "SIMPLE-ERROR: bad"
            (debugger-restarts dbg) '("0: ABORT")
            (debugger-frames dbg) '("0: f" "1: g")
            (debugger-frame dbg) 1
            (debugger-locals dbg) '("X = 1"))
      (with-entry (editor) (editor-debugger-open editor dbg))
      (is-equal (host-panel-state :dock editor) "open height 200 shown debugger")
      (host-take-evals editor)
      (host-detach-now editor "debugger")
      (let ((w3 (host-window editor 3)))
        (is (search "CK.panelHide(\"debugger\");" (host-take-evals editor)))
        (is (search "CK.dbgOpen(1,\"SIMPLE-ERROR: bad\",[\"0: ABORT\"],false);CK.dbgFrames([\"0: f\",\"1: g\"]);CK.dbgSelectFrame(1);CK.dbgLocals([\"X = 1\"]);"
                    (host-take-evals w3)))
        (is (search " window 3" (host-panel-state :debugger editor)))
        ;; The main window's dock fell back to the diagnostics
        (is-equal (host-panel-state :dock editor) "open height 200 shown diagnostics")
        (is-equal (editor-aux-windows editor)
                  '(("dock" 0 400 800 200) ("errors" 0 400 800 200) ("debugger" 40 40 800 600)))
        ;; What the session sends next goes to that window; a raise raises it
        (with-entry (editor) (editor-debugger-locals editor '("Y = 2")))
        (is (search "CK.dbgLocals([\"Y = 2\"]);" (host-take-evals w3)))
        (is-equal (host-take-evals editor) "")
        (with-entry (editor) (editor-debugger-raise editor))
        (is (search "CK.dbgRaise();" (host-take-evals w3)))
        (is-equal (first (host-editor-raised editor)) 3)
        ;; Its close takes the panel down there, and the window with it
        (with-entry (editor) (editor-debugger-close editor))
        (is (search "CK.dbgClose();" (host-take-evals w3)))
        (is (eq (host-window-closing w3) :empty))
        (with-entry (editor) (housekeeping editor))
        (is (null (host-window editor 3)))
        (is (eq (panel-window editor "debugger") (host-editor-main editor)))))
    ;; The inspector, and the way back by the tab menu
    (let ((insp (editor-inspector-state editor)))
      (setf (inspector-type insp) "CONS"
            (inspector-depth insp) 1
            (inspector-object insp) "(1)"
            (inspector-parts insp) '("0: Car = 1"))
      (with-entry (editor) (editor-inspector-open editor insp))
      (host-take-evals editor)
      (host-detach-now editor "inspector")
      (let ((w4 (host-window editor 4)))
        (is (search "CK.inspOpen(\"CONS\",1,\"(1)\",[\"0: Car = 1\"]);" (host-take-evals w4)))
        (is-equal (editor-aux-windows editor)
                  '(("dock" 0 400 800 200) ("errors" 0 400 800 200) ("inspector" 40 40 800 600)))
        (with-entry (editor)
          (is-equal (host-attach editor "inspector") "inspector attached"))
        (is (search "CK.inspOpen(\"CONS\",1,\"(1)\",[\"0: Car = 1\"]);" (host-take-evals editor)))
        (is (search "CK.panelHide(\"inspector\");" (host-take-evals w4)))
        (is-equal (host-panel-state :dock editor) "open height 200 shown inspector")
        (is-equal (host-panel-state :inspector editor) "open type CONS depth 1 parts 1 object (1)")
        (with-entry (editor)
          (is-equal (host-attach editor "inspector") "inspector is in the main window"))
        (with-entry (editor) (housekeeping editor))
        (is (null (host-window editor 4)))))))

(deftest host-closing-a-panels-window-closes-the-panel
  ;; The window's close button on a panel CLOSES it, as the tab's close
  ;; does -- it does not come back as a tab in the main window to be
  ;; closed a second time -- while a document in the same window goes
  ;; back there.
  (multiple-value-bind (editor doc tr) (host-wired-editor "(x)")
    (declare (ignore doc tr))
    (with-entry (editor)
      (editor-show-diagnostics editor '("a:1: ERROR: x") :open t))
    (host-take-evals editor)
    (is-equal (host-detach-now editor "diagnostics") "diagnostics detached")
    (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc1) 2 (diagnostics) active doc1")
    (let ((w2 (host-window editor 2))
          (d2 (host-test-document editor "two")))
      (host-take-evals editor)
      (with-entry (editor) (move-document d2 w2))
      (is-equal (host-panel-state :windows editor) "windows 2: 1 (doc1) 2 (doc2 diagnostics) active doc2")
      (setf (host-window-closing w2) :attach)
      (with-entry (editor) (housekeeping editor))
      (is (null (host-window editor 2)))
      (is (eq (hdoc-window d2) (host-editor-main editor)))
      (is (not (host-editor-diag-open editor)))
      (is (eq (panel-window editor "diagnostics") (host-editor-main editor)))
      (is-equal (host-panel-state :diagnostics editor) "closed rows 1 selected none")
      (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1 doc2) active doc2")
      (let ((js (host-take-evals editor)))
        (is (search "CK.makeDoc(\"doc2\"" js))
        (is (not (search "CK.showDiagnostics(" js))))
      (is-equal (host-panel-state :dock editor) "closed height 200 shown nothing")
      ;; Show Errors brings it back, in the main window
      (with-entry (editor) (editor-show-diagnostics editor '("a:1: ERROR: x") :open t))
      (is (search "CK.showDiagnostics(" (host-take-evals editor)))
      (is-equal (host-panel-state :diagnostics editor) "open rows 1 selected none"))
    ;; The debugger's window closed while the REPL is parked: the panel
    ;; goes, the parked thread is announced as the tab's close announces it
    (let ((dbg (editor-debugger-state editor)))
      (setf (debugger-level dbg) 1
            (debugger-condition dbg) "SIMPLE-ERROR: bad"
            (debugger-restarts dbg) '("0: ABORT")
            (debugger-frames dbg) '("0: f")
            (debugger-frame dbg) 0
            (debugger-locals dbg) '())
      (with-entry (editor) (editor-debugger-open editor dbg))
      (host-take-evals editor)
      (host-detach-now editor "debugger")
      (let ((w3 (host-window editor 3)))
        (is (search " window 3" (host-panel-state :debugger editor)))
        (setf (host-window-closing w3) :attach)
        (with-entry (editor) (housekeeping editor))
        (is (null (host-window editor 3)))
        (is (not (host-editor-dbg-open editor)))
        (is (search "closed" (host-panel-state :debugger editor)))
        (is (not (search "CK.dbgOpen(" (host-take-evals editor))))))))

(deftest host-a-panel-reopened-before-housekeeping-cancels-its-windows-stale-empty-mark
  (multiple-value-bind (editor doc tr) (host-wired-editor "(x)")
    (declare (ignore doc tr))
    (with-entry (editor)
      (editor-show-diagnostics editor '("a:1: ERROR: x") :open t))
    (host-take-evals editor)
    (host-detach-now editor "diagnostics")
    (let ((w2 (host-window editor 2)))
      ;; Closed from its own tab: the window is marked :EMPTY for the next
      ;; HOUSEKEEPING turn.  Before that turn runs, the panel reopens --
      ;; PANEL-WINDOWS still maps it to this very window -- so the mark is
      ;; stale: the window is showing something again and must not be
      ;; destroyed out from under it.
      (with-entry (editor) (host-panel-close editor "diagnostics"))
      (is (eq (host-window-closing w2) :empty))
      (with-entry (editor)
        (editor-show-diagnostics editor '("a:1: ERROR: x" "a:2: ERROR: y") :open t))
      (is (eq (panel-window editor "diagnostics") w2))
      (with-entry (editor) (housekeeping editor))
      (is (host-window editor 2))
      (is (not (host-window-closing w2)))
      (is (eq (panel-window editor "diagnostics") w2))
      (is-equal (host-panel-state :diagnostics editor) "open rows 2 selected none window 2"))))

(deftest host-a-detached-window-gets-the-menu-bar-the-theme-and-every-later-change
  (with-host-theme-state
    (multiple-value-bind (editor doc js) (host-menu-editor "one" nil)
      (declare (ignore doc js))
      (setq *editor* editor)
      (host-test-document editor "two")
      (host-take-evals editor)
      (host-detach-now editor "doc2")
      (let* ((w2 (host-window editor 2))
             (js (host-take-evals w2)))
        ;; The table, every item's state and both groups as the bar shows
        ;; them now, then the theme, before the tab
        (is (search "CK.setMenus([[\"title\",\"Project\",\"\"]" js))
        (is-equal (count-calls "CK.menuEnable(" js)
                  (count :item (menu-entries) :key #'menu-entry-kind))
        (is (search (menu-enable-call 'save-buffer nil) js))
        (is (search "CK.setDynamic(\"buffers\",[[\"(unnamed)\",false],[\"(unnamed)<2>\",true]]);" js))
        (is (search "CK.setDynamic(\"themes\",[[\"Light\",true],[\"Dark\",false]" js))
        (is (search "CK.theme([[\"--bg\",\"#ffffff\"]" js))
        (is (< (search "CK.setMenus(" js) (search "CK.theme(" js)))
        (is (< (search "CK.theme(" js) (search "CK.makeDoc(" js)))
        ;; An edit enables Save on both bars; a theme picked reaches both
        ;; pages, and the View group is remade on both
        (host-type-text editor "x")
        (is (search (menu-enable-call 'save-buffer t) (host-take-evals editor)))
        (is (search (menu-enable-call 'save-buffer t) (host-take-evals w2)))
        (with-entry (editor) (host-dynamic-pick editor :themes 1))
        (is (search "CK.theme([[\"--bg\",\"#1e1e1e\"]" (host-take-evals editor)))
        (let ((js (host-take-evals w2)))
          (is (search "CK.theme([[\"--bg\",\"#1e1e1e\"]" js))
          (is (search "CK.setDynamic(\"themes\",[[\"Light\",false],[\"Dark\",true]" js)))))
    ;; With the host's own menu bar the new page gets the empty table, so
    ;; its bar stays hidden, and no enable state
    (let ((editor (host-test-editor)))
      (setq *editor* editor)
      (with-entry (editor) (send-menus editor :native t))
      (host-test-document editor "one")
      (host-take-evals editor)
      (host-detach-now editor "doc1")
      (let ((js (host-take-evals (host-window editor 2))))
        (is (search "CK.setMenus([]);" js))
        (is (not (search "menuEnable" js)))
        (is (not (search "setDynamic" js)))))))

(deftest host-a-window-whose-page-is-not-up-holds-its-tab-back
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two")))
    (declare (ignore d2))
    (host-take-evals editor)
    (with-entry (editor) (host-detach editor "doc1"))
    (let ((w2 (host-window editor 2)))
      ;; The page (stood in for here) has not reported ready: the turn
      ;; settles nothing, and a second ask for the same window waits too
      (setf (host-window-ready w2) nil)
      (with-entry (editor) (housekeeping editor))
      (is (not (host-window-settled w2)))
      (is (eq (hdoc-window d1) (host-editor-main editor)))
      (is-equal (host-take-evals w2) "")
      (is (host-window editor 2))
      ;; Ready from a later window's page: noted, and its scheme does not
      ;; move the default theme (the main page's did)
      (let ((default *default-theme*))
        (host-ready w2 "UA" (if (eq default :dark) "light" "dark"))
        (is (host-window-ready w2))
        (is (eq *default-theme* default)))
      (with-entry (editor) (housekeeping editor))
      (is (host-window-settled w2))
      (is (eq (hdoc-window d1) w2))
      (is (search "CK.makeDoc(\"doc1\"" (host-take-evals w2)))
      ;; Each page's report is its own
      (is-equal (host-page-panels editor 2) "no report")
      (is-equal (host-page-panels editor 9) "no window")
      (is-equal (host-page-panels nil) "no report")
      (with-entry (editor) (host-panels-report w2 "{\"detached\":true}"))
      (is-equal (host-page-panels editor 2) "{\"detached\":true}")
      (is-equal (host-page-panels editor) "no report")
      ;; A document closed while its move waits: the window comes up empty
      ;; and goes again
      (with-entry (editor) (host-detach editor "doc2"))
      (let ((w3 (host-window editor 3)))
        (setf (host-window-ready w3) nil)
        (with-entry (editor) (run-command (host-document-by-id editor "doc2") 'kill-buffer))
        (is (not (host-window-closing w3)))
        (host-ready w3 "UA")
        (with-entry (editor) (housekeeping editor))
        (is (null (host-window editor 3)))
        (is-equal (host-panel-state :windows editor) "windows 2: 1 () 2 (doc1) active doc1")))))

(deftest host-detach-and-attach-are-commands-with-messages
  (let* ((editor (host-test-editor))
         (doc (host-test-document editor "x")))
    (with-entry (editor) (run-command doc 'clamacs-attach-window))
    (is-equal (doc-message-text doc) "doc1 is in the main window")
    (with-entry (editor) (run-command doc 'clamacs-detach-window))
    (is-equal (doc-message-text doc) "doc1 detached")
    (with-entry (editor) (housekeeping editor))
    (is-equal (host-window-number (hdoc-window doc)) 2)
    ;; From a detached window, showing separately again makes yet another
    ;; window, and the emptied one goes
    (with-entry (editor) (run-command doc 'clamacs-detach-window))
    (with-entry (editor) (housekeeping editor))
    (is-equal (host-window-number (hdoc-window doc)) 3)
    (is (null (host-window editor 2)))
    (with-entry (editor) (run-command doc 'clamacs-attach-window))
    (is-equal (doc-message-text doc) "doc1 attached")
    (is (main-window-p (hdoc-window doc)))
    (with-entry (editor) (housekeeping editor))
    (is-equal (host-panel-state :windows editor) "windows 1: 1 (doc1) active doc1")
    ;; The window's echo row shows the message where the document is
    (is (search "CK.setEcho(\"doc1 attached\");" (host-take-evals editor)))))

(deftest host-snapshot-records-a-detached-window-under-its-tabs-role
  (let* ((editor (host-test-editor))
         (d1 (host-test-document editor "one"))
         (d2 (host-test-document editor "two"))
         (cfg (temp-file "host-detach.cfg")))
    (winstore-set (editor-layout editor) "doc2" 10 20 300 200)
    (winstore-set (editor-layout editor) "debugger" 5 6 400 300)
    (host-detach-now editor "doc2")
    ;; Placed where the layout put its role
    (is-equal (multiple-value-list (doc-geometry d2)) '(10 20 300 200))
    (is-equal (multiple-value-list (doc-geometry d1)) '(0 0 800 600))
    (is-equal (nth-value 1 (port-command editor "GETWINDOW")) "doc2 10 20 300 200")
    ;; The debugger's window where the Amiga's debugger window was
    (with-entry (editor) (editor-debugger-open editor (editor-debugger-state editor)))
    (host-detach-now editor "debugger")
    (is-equal (editor-aux-windows editor) '(("debugger" 5 6 400 300)))
    (let ((*snapshot-files* (list cfg)))
      (with-entry (editor) (run-command d2 'clamacs-snapshot-windows))
      (is-equal (doc-message-text d2)
                (format nil "Saved the positions of 3 window(s) to ~A" cfg))
      (let ((text (read-file-text cfg)))
        (is (search (format nil "~%doc1 0 0 800 600~%") text))
        (is (search (format nil "~%doc2 10 20 300 200~%") text))
        (is (search (format nil "~%debugger 5 6 400 300~%") text))))
    (delete-file cfg)))
