;;;; test-files.lisp -- files, buffers and windows, on the fake frontend and
;;;; real files under TMPDIR.

(in-package :clamacs)

;;; TEMP-FILE is in framework.lisp: test-wire and test-introspect use it too.

(defun answer-prompt (doc text)
  (type-text doc text)
  (type-keys doc "RET"))

;;; --- names ----------------------------------------------------------------

(deftest path-basename-cuts-at-slash-and-colon
  (is-equal (path-basename "Work:src/main.lisp") "main.lisp")
  (is-equal (path-basename "Work:main.lisp") "main.lisp")
  (is-equal (path-basename "/tmp/a/b.lisp") "b.lisp")
  (is-equal (path-basename "plain.lisp") "plain.lisp")
  (is-equal (path-basename "dir/") ""))

(deftest path-directory-cuts-at-slash-and-colon
  ;; What both frontends seed the requester with, and the MUI one splits
  ;; into drawer and file: the path up to and including the last separator.
  (is-equal (path-directory "Work:a/b.lisp") "Work:a/")
  (is-equal (path-directory "Work:src/main.lisp") "Work:src/")
  (is-equal (path-directory "/tmp/a/b.lisp") "/tmp/a/")
  (is-equal (path-directory "T:x") "T:")
  (is-equal (path-directory "Work:") "Work:")
  (is-equal (path-directory "a/") "a/")
  (is-equal (path-directory "x.lisp") "")
  (is-equal (path-directory "") ""))

(deftest directory-only-p-is-empty-or-ends-in-slash-or-colon
  (dolist (text '("" "dir/" "/" "T:" "Work:src/" "/tmp/a/"))
    (is (directory-only-p text)))
  (dolist (text '("x" "dir/file" "T:x" "Work:src/main.lisp" "a.b"))
    (is (not (directory-only-p text)))))

(deftest lisp-path-p-goes-by-the-extension
  (dolist (path '("a.lisp" "Work:b.lsp" "c.cl" "sys.asd" "x.y.lisp"))
    (is (lisp-path-p path)))
  (dolist (path '("a.txt" "lisp" "a.lispx" "a.LISP" "README" "a.lisp/b"))
    (is (not (lisp-path-p path)))))

;;; --- reading and writing ------------------------------------------------------

(deftest file-text-round-trips-byte-for-character
  ;; ISO-8859-1 whatever the host's default encoding is, CR kept.
  (let* ((text (coerce (list #\a (code-char 228) (code-char 255) #\Return
                             #\Newline #\z)
                       'string))
         (path (temp-file "latin1.txt" text)))
    (is-equal (read-file-text path) text)
    (with-open-file (in path :element-type '(unsigned-byte 8))
      (is-equal (file-length in) 6))
    (delete-file path)))

(deftest unreadable-and-unwritable-files-are-nil-not-errors
  (is-equal (read-file-text (temp-file "missing.txt")) nil)
  (is-equal (write-file-text (temp-path "no-such-dir/x.txt") "x") nil))

;;; --- find-file ------------------------------------------------------------------

(deftest find-file-loads-into-this-window
  (let ((path (temp-file "one.lisp" (lines "(defun one ()" "  1)")))
        (doc (make-fake "|")))
    (type-keys doc "C-x C-f")
    (is-equal (fake-prompt doc) "Find file (TAB: browse): ")
    (answer-prompt doc path)
    (is-equal (fake-state doc) (lines "|(defun one ()" "  1)"))
    (is-equal (doc-path doc) path)
    (is-equal (doc-name doc) "clamacs-test-one.lisp")
    (is-equal (fake-title doc) "clamacs-test-one.lisp")
    (is (not (doc-modified-p doc)))
    ;; Coloured on the way in.
    (is-equal (fake-line-colours doc 0) '((1 6 :defining)))
    (is-equal (length (live-documents (doc-editor doc))) 1)
    ;; The path is in the file history.
    (type-keys doc "C-x C-f M-p")
    (is-equal (fake-mini-text doc) path)
    (type-keys doc "C-g")
    (delete-file path)))

(deftest find-file-of-a-new-name-is-a-new-buffer
  (let ((path (temp-file "new.txt"))
        (doc (make-fake "|")))
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (is-equal (fake-last-message doc) "(New file)")
    (is-equal (doc-path doc) path)
    (is-equal (fake-state doc) "|")
    ;; The mode follows the name: no Lisp keys in a .txt.
    (is (not (doc-lisp-mode doc)))
    (is-equal (type-keys doc "TAB") '("TAB"))
    (is (not (probe-file path)))))

(deftest find-file-asks-before-dropping-unsaved-text
  (let ((path (temp-file "two.lisp" "two"))
        (doc (make-fake "|")))
    (type-keys doc "x")
    (is (doc-modified-p doc))
    ;; Unnamed: Discard or Cancel only.  Cancel keeps the text.
    (setf (fake-answers doc) '(:cancel))
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (is-equal (first (fake-asked doc))
              '("(unnamed) has unsaved changes." (:discard :cancel)))
    (is-equal (fake-state doc) "x|")
    (setf (fake-answers doc) '(:discard))
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (is-equal (fake-state doc) "|two")
    ;; Named and modified: Save writes it first.
    (let ((other (temp-file "three.lisp" "three")))
      (type-keys doc "y")
      (setf (fake-answers doc) '(:save))
      (type-keys doc "C-x C-f")
      (answer-prompt doc other)
      (is-equal (read-file-text path) "ytwo")
      (is-equal (fake-state doc) "|three")
      (delete-file other))
    (delete-file path)))

(deftest find-file-goes-to-the-window-that-has-the-file
  (let* ((path (temp-file "shared.lisp" "shared"))
         (doc (make-fake "|"))
         (editor (doc-editor doc)))
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (let ((second (make-fake "|" :editor editor)))
      (type-keys second "C-x C-f")
      (answer-prompt second path)
      (is-equal (fake-activations doc) 1)
      (is-equal (fake-state second) "|")
      ;; C-x 2 always opens another window, even for an open file.
      (type-keys second "C-x 2")
      (answer-prompt second path)
      (is-equal (length (live-documents editor)) 3)
      (let ((third (first (last (live-documents editor)))))
        (is-equal (fake-text third) "shared")
        (is-equal (doc-path third) path)
        (is (doc-lisp-mode third))))
    (delete-file path)))

(deftest find-file-with-an-empty-answer-opens-the-requester
  (let ((path (temp-file "asked.lisp" "asked"))
        (doc (make-fake "|")))
    (setf (fake-answers doc) (list path))
    (type-keys doc "C-x C-f RET")
    ;; An unnamed buffer has no directory to start in.
    (is-equal (first (fake-asked doc)) '(:file "Open" nil ""))
    (is-equal (fake-text doc) "asked")
    ;; ... a named one does.
    (setf (fake-answers doc) (list path))
    (type-keys doc "C-x C-f RET")
    (is-equal (first (fake-asked doc)) (list :file "Open" nil (path-directory path)))
    ;; Cancelled: nothing happens.
    (setf (fake-answers doc) (list nil))
    (type-keys doc "C-x C-f RET")
    (is-equal (fake-text doc) "asked")
    (is (not (minibuffer-open-p doc)))
    (delete-file path)))

;;; --- TAB at the file prompt ------------------------------------------------------

(defun completion-fixture ()
  "A directory with two files and a subdirectory in it; its path, with the
separator."
  (let ((dir (temp-path "cdir/")))
    (ensure-directories-exist (concatenate 'string dir "sub/"))
    (write-file-text (concatenate 'string dir "alpha.lisp") "a")
    (write-file-text (concatenate 'string dir "alps.txt") "b")
    dir))

(deftest tab-completes-a-file-name-against-its-directory
  (let ((dir (completion-fixture)))
    (multiple-value-bind (matches common) (complete-path (concatenate 'string dir "al"))
      (is-equal matches (list (concatenate 'string dir "alpha.lisp")
                              (concatenate 'string dir "alps.txt")))
      (is-equal common (concatenate 'string dir "alp")))
    ;; Case does not matter for the typed part; the completion is the
    ;; file's own spelling.
    (multiple-value-bind (matches common) (complete-path (concatenate 'string dir "ALPH"))
      (is-equal matches (list (concatenate 'string dir "alpha.lisp")))
      (is-equal common (concatenate 'string dir "alpha.lisp")))
    ;; A directory completes with its separator, so the next TAB descends.
    (multiple-value-bind (matches common) (complete-path (concatenate 'string dir "s"))
      (is-equal matches (list (concatenate 'string dir "sub/")))
      (is-equal common (concatenate 'string dir "sub/")))
    ;; Nothing there, or no such directory: nothing, not an error.
    (is-equal (complete-path (concatenate 'string dir "zzz")) '())
    (is-equal (complete-path (temp-path "no-such-dir/x")) '())
    ;; Through the keys: the common prefix goes into the line, and the
    ;; count is said.
    (let ((doc (make-fake "|")))
      (type-keys doc "C-x C-f")
      (type-text doc (concatenate 'string dir "al"))
      (type-keys doc "TAB")
      (is-equal (fake-mini-text doc) (concatenate 'string dir "alp"))
      (is-equal (fake-mini-label doc) "[2 completions]")
      (type-text doc "h")
      (type-keys doc "TAB")
      (is-equal (fake-mini-text doc) (concatenate 'string dir "alpha.lisp"))
      (is-equal (fake-mini-label doc) "[Sole completion]")
      (type-keys doc "RET")
      (is-equal (fake-text doc) "a")
      (is-equal (doc-path doc) (concatenate 'string dir "alpha.lisp")))))

(deftest tab-keeps-what-was-typed-when-matches-differ-in-case
  ;; The name is matched without regard to case but COMPLETE's common
  ;; prefix is not: `alpha.lisp' and `Alps.txt' share nothing past the
  ;; directory, and TAB must not cut the `al' the user typed back to it.
  (let ((dir (temp-path "case-dir/")))
    (ensure-directories-exist dir)
    (write-file-text (concatenate 'string dir "alpha.lisp") "a")
    (write-file-text (concatenate 'string dir "Alps.txt") "b")
    (let ((typed (concatenate 'string dir "al")))
      (multiple-value-bind (matches common) (complete-path typed)
        (is-equal (length matches) 2)
        (is (member (concatenate 'string dir "alpha.lisp") matches :test #'string=))
        (is (member (concatenate 'string dir "Alps.txt") matches :test #'string=))
        (is-equal common typed))
      ;; Through the keys: the line stays, the count is said.
      (let ((doc (make-fake "|")))
        (type-keys doc "C-x C-f")
        (type-text doc typed)
        (type-keys doc "TAB")
        (is-equal (fake-mini-text doc) typed)
        (is-equal (fake-mini-label doc) "[2 completions]")
        (type-keys doc "C-g")))))

(deftest tab-after-a-device-name-opens-the-requester-there
  ;; A `:' ends a directory as a `/' does.
  (let ((doc (make-fake "|")))
    (setf (fake-answers doc) (list nil))
    (type-keys doc "C-x C-f")
    (type-text doc "Work:")
    (type-keys doc "TAB")
    (is-equal (first (fake-asked doc)) '(:file "Open" nil "Work:"))
    ;; Cancelled: the prompt is still there, with the line as typed.
    (is (minibuffer-open-p doc))
    (is-equal (fake-mini-text doc) "Work:")
    (type-keys doc "C-g")))

(deftest tab-on-a-line-that-names-no-file-opens-the-requester
  (let ((dir (completion-fixture))
        (doc (make-fake "|")))
    ;; Empty line: the requester, and the prompt is over once a file was
    ;; chosen.
    (setf (fake-answers doc) (list (concatenate 'string dir "alps.txt")))
    (type-keys doc "C-x C-f TAB")
    (is-equal (first (fake-asked doc)) '(:file "Open" nil ""))
    (is (not (minibuffer-open-p doc)))
    (is-equal (fake-text doc) "b")
    ;; A bare directory: the requester opens there.
    (setf (fake-answers doc) (list nil))
    (type-keys doc "C-x C-f")
    (type-text doc dir)
    (type-keys doc "TAB")
    (is-equal (first (fake-asked doc)) (list :file "Open" nil dir))
    ;; Cancelled: the prompt is still there, with the line as typed.
    (is (minibuffer-open-p doc))
    (is-equal (fake-mini-text doc) dir)
    (type-keys doc "C-g")
    ;; The requester's choice is in the file history like a typed one.
    (type-keys doc "C-x C-f M-p")
    (is-equal (fake-mini-text doc) (concatenate 'string dir "alps.txt"))
    (type-keys doc "C-g")))

(deftest the-requester-commands-are-the-menus-entrances
  (let ((path (temp-file "picked.lisp" "picked"))
        (doc (make-fake "|")))
    ;; Open... from the menu: the requester, no prompt.
    (setf (fake-answers doc) (list path))
    (is (menu-pick (doc-editor doc) (menu-find 'find-file)))
    (is-equal (first (fake-asked doc)) '(:file "Open" nil ""))
    (is (not (minibuffer-open-p doc)))
    (is-equal (fake-text doc) "picked")
    ;; Open in New Window... from the menu.
    (setf (fake-answers doc) (list path))
    (is (menu-pick (doc-editor doc) (menu-find 'find-file-other-window)))
    (is-equal (first (fake-asked doc))
              (list :file "Open in New Window" nil (path-directory path)))
    (is-equal (length (live-documents (doc-editor doc))) 2)
    ;; Save As... offers the buffer's own name in save mode.
    (let ((other (temp-file "picked-as.lisp")))
      (setf (fake-answers doc) (list other))
      (is (menu-pick (doc-editor doc) (menu-find 'write-file)))
      (is-equal (first (fake-asked doc)) (list :file "Save As" t path))
      (is-equal (read-file-text other) "picked")
      (is-equal (doc-path doc) other)
      (delete-file other))
    ;; Cancelled: nothing, and no prompt either.
    (setf (fake-answers doc) (list nil))
    (is (menu-pick (doc-editor doc) (menu-find 'write-file)))
    (is (not (minibuffer-open-p doc)))
    (delete-file path)))

(deftest the-menus-save-never-prompts
  ;; Save on a named buffer writes it; on an unnamed one it asks in the
  ;; requester, where the mouse already is.
  (let ((path (temp-file "menu-save.lisp"))
        (doc (make-fake "one|")))
    (setf (fake-answers doc) (list path))
    (run-command doc 'save-buffer-requester)
    (is-equal (first (fake-asked doc)) '(:file "Save As" t ""))
    (is-equal (read-file-text path) "one")
    (type-keys doc "SPC t w o")
    (run-command doc 'save-buffer-requester)
    (is-equal (length (fake-asked doc)) 1)
    (is-equal (read-file-text path) "one two")
    (is (not (doc-modified-p doc)))
    (delete-file path)))

(deftest a-scratch-window-keeps-its-text
  ;; *errors* and friends are not file windows: find-file opens another.
  (let* ((doc (make-fake "diagnostics|"))
         (path (temp-file "four.lisp" "four")))
    (setf (doc-name doc) "*errors*")
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (is-equal (fake-text doc) "diagnostics")
    (is-equal (length (live-documents (doc-editor doc))) 2)
    (delete-file path)))

;;; --- saving -----------------------------------------------------------------------

(deftest save-buffer-writes-and-clears-the-flag
  (let ((path (temp-file "save.lisp" "old"))
        (doc (make-fake "|")))
    (type-keys doc "C-x C-f")
    (answer-prompt doc path)
    (type-keys doc "n e w SPC C-x C-s")
    (is-equal (read-file-text path) "new old")
    (is (not (doc-modified-p doc)))
    (is-equal (fake-last-message doc)
              (concatenate 'string "Wrote " path))
    ;; The cursor is where it was.
    (is-equal (fake-state doc) "new |old")
    (delete-file path)))

(deftest saving-an-unnamed-buffer-asks-for-a-name
  (let ((path (temp-file "named.lisp"))
        (doc (make-fake "(text)|")))
    (type-keys doc "C-SPC C-x C-s")
    (is-equal (fake-prompt doc) "Write file (TAB: browse): ")
    (answer-prompt doc path)
    (is-equal (read-file-text path) "(text)")
    (is-equal (doc-path doc) path)
    (is-equal (fake-title doc) "clamacs-test-named.lisp")
    ;; Naming the buffer is not loading it: cursor and mark stay.
    (is-equal (fake-state doc) "(text)|")
    (is-equal (doc-mark doc) 6)
    ;; C-x C-w offers the current name.
    (type-keys doc "C-x C-w")
    (is-equal (fake-mini-text doc) path)
    (type-keys doc "C-g")
    (delete-file path)))

(deftest save-as-into-lisp-mode-colours-the-buffer
  ;; Renaming a plain-text buffer to a `.lisp' name through C-x C-w flips it
  ;; into Lisp mode -- it must get the same syntax colouring FIND-FILE gives
  ;; a `.lisp' file loaded from disk.
  (let ((doc (make-fake (lines "(defun g ()" "  2)") :lisp-mode nil))
        (path (temp-file "became.lisp")))
    (is (not (doc-lisp-mode doc)))
    (is (save-file doc path))
    (is (doc-lisp-mode doc))
    (is-equal (fake-line-colours doc 0) '((1 6 :defining)))
    (delete-file path)))

(deftest save-as-clears-a-stale-paren-highlight
  ;; A shown paren-match highlight is DOC-PAREN-SHOWN state the widget was
  ;; told to paint; Save-As must take it down, not just forget about it.
  (let ((doc (make-fake (lines "(defun f ()" "  1)"))))
    (colour-all doc)
    (doc-set-point doc 11)
    (show-paren doc)
    (is (doc-paren-shown doc))
    (let ((path (temp-file "moved.lisp")))
      (is (save-file doc path))
      (is (not (doc-paren-shown doc)))
      (is (not (find :paren-match (fake-line-colours doc 0) :key #'third)))
      (delete-file path))))

(deftest a-failed-write-says-so-and-stays-modified
  (let ((doc (make-fake "|"))
        (path (temp-path "no-such-dir/x.lisp")))
    (type-keys doc "x C-x C-w")
    (answer-prompt doc path)
    (is-equal (fake-last-message doc)
              (concatenate 'string "Cannot write " path))
    (is (doc-modified-p doc))
    (is-equal (doc-path doc) nil)))

;;; --- windows ------------------------------------------------------------------------

(deftest new-buffer-and-other-window
  (let* ((doc (make-fake "|"))
         (editor (doc-editor doc)))
    (is (run-command doc 'clamacs-new-buffer))
    (let ((second (second (live-documents editor))))
      (is-equal (doc-name second) "(unnamed)")
      (is (doc-lisp-mode second))
      (type-keys doc "C-x o")
      (is-equal (fake-activations second) 1)
      ;; ... and round again.
      (type-keys second "C-x b")
      (is-equal (fake-activations doc) 1)))
  ;; Alone, there is nowhere to go.
  (let ((doc (make-fake "|")))
    (type-keys doc "C-x o")
    (is-equal (fake-activations doc) 0)))

(deftest kill-buffer-asks-about-unsaved-text
  (let ((doc (make-fake "|")))
    (type-keys doc "C-x k")
    (is (doc-closing doc))
    (is (not (fake-window-open doc)))
    (is-equal (fake-asked doc) '())
    (is-equal (live-documents (doc-editor doc)) '()))
  (let ((doc (make-fake "|")))
    (type-keys doc "x")
    (setf (fake-answers doc) '(:cancel))
    (type-keys doc "C-x k")
    (is (fake-window-open doc))
    (setf (fake-answers doc) '(:discard))
    (type-keys doc "C-x k")
    (is (not (fake-window-open doc)))))

(deftest kill-buffer-save-needs-a-name-first
  ;; The user is in a requester: the name is asked in one too, never in
  ;; the minibuffer, and a name given closes the window in one go.
  (let ((doc (make-fake "|"))
        (path (temp-file "closing.lisp")))
    (type-keys doc "x")
    ;; Save, then cancel the name: the window stays, the text is kept.
    (setf (fake-answers doc) '(:save nil))
    (type-keys doc "C-x k")
    (is (fake-window-open doc))
    (is (not (minibuffer-open-p doc)))
    (is-equal (first (fake-asked doc)) '(:file "Save As" t ""))
    (is-equal (fake-text doc) "x")
    (is (doc-modified-p doc))
    ;; Save with a name: written and closed.
    (setf (fake-answers doc) (list :save path))
    (type-keys doc "C-x k")
    (is-equal (read-file-text path) "x")
    (is (not (fake-window-open doc)))
    (delete-file path)))

(deftest kill-buffer-save-stays-open-when-the-write-fails
  (let ((doc (make-fake "|")))
    (type-keys doc "x")
    (setf (fake-answers doc) (list :save (temp-path "no-such-dir/x.lisp")))
    (type-keys doc "C-x k")
    (is (fake-window-open doc))
    (is (doc-modified-p doc))
    (is (search "Cannot write" (fake-last-message doc)))))

(deftest closed-windows-are-out-of-the-rotation
  (let* ((one (make-fake "|"))
         (editor (doc-editor one))
         (two (make-fake "|" :editor editor))
         (three (make-fake "|" :editor editor)))
    (type-keys two "C-x k")
    (type-keys one "C-x o")
    (is-equal (fake-activations three) 1)
    (is-equal (fake-activations two) 0)))

(deftest quit-raises-the-flag
  (let ((doc (make-fake "|")))
    (is (not (editor-quitting (doc-editor doc))))
    (type-keys doc "C-x C-c")
    (is (editor-quitting (doc-editor doc)))))

(deftest quitting-asks-about-unsaved-text-unless-killed
  (let* ((doc (make-fake "|"))
         (editor (doc-editor doc)))
    (doc-insert doc "unsaved")
    ;; C-x C-c: asked, and Cancel keeps the editor running.
    (type-keys doc "C-x C-c")
    (push :cancel (fake-answers doc))
    (is (not (quit-requested editor)))
    (is-equal (length (fake-asked doc)) 1)
    (is (fake-window-open doc))
    (is (not (editor-quitting editor)))
    ;; kill-emacs: no question, the window goes.
    (run-command doc 'kill-emacs)
    (is (quit-requested editor))
    (is-equal (length (fake-asked doc)) 1)
    (is (not (fake-window-open doc)))))
