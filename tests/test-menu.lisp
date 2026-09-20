;;;; test-menu.lisp -- the menu strip as data (the cases of
;;;; tests/test_menudef.c), the port's MENU verb on the fake frontend
;;;; (drive.rexx's menu legs), and the two Help items.
;;;;
;;;; Three promises the table makes, each checkable on the host:
;;;;   - every item names a real command, and no command is listed twice;
;;;;   - the key shown in an item's shortcut column really runs that
;;;;     command, fed through the real state machine against the real maps
;;;;     -- a rebinding that forgets the menu fails here, not on an Amiga;
;;;;   - the enable rules answer as menu.lisp documents them.

(in-package :clamacs)

(defun resolve-keys (keys local)
  "The command KEYS runs against the global map and LOCAL, or NIL."
  (let ((st (make-keystate (global-keymap) local))
        (result nil) (command nil))
    (dolist (key (split-key-sequence keys))
      (multiple-value-setq (result command) (keystate-feed st key)))
    (and (eq result :command) command)))

;;; --- the table -------------------------------------------------------------

(deftest menu-table-is-well-formed
  (let ((entries (menu-entries))
        (seen '()) (titles 0) (items 0))
    (is-equal (menu-entry-kind (first entries)) :title)   ; the first entry opens a menu
    (loop for (e next) on entries
          for i from 0
          do (ecase (menu-entry-kind e)
               (:title
                (is (and (stringp (menu-entry-title e)) (string/= (menu-entry-title e) "")))
                (incf titles))
               (:bar
                (is (null (menu-entry-title e)))
                ;; A bar never opens or closes a menu.
                (is (and (> i 0) (not (eq (menu-entry-kind (nth (1- i) entries)) :title))))
                (is (and next (eq (menu-entry-kind next) :item))))
               (:item
                (is (and (stringp (menu-entry-title e)) (string/= (menu-entry-title e) "")))
                (let ((command (menu-entry-command e)))
                  (is (command-name command))            ; a real command
                  (is (find-command (command-name command)))
                  (is (not (member command seen)))       ; listed once
                  (push command seen))
                (is (member (menu-entry-rule e) *menu-rules*))
                (is (member (menu-entry-map e) '(:global :lisp :repl)))
                (incf items))))
    (is-equal (menu-count) (length entries))
    (is-equal titles 6)
    (is (> items 30))))

(deftest menu-find-returns-the-item
  (let ((i (menu-find 'save-buffer)))
    (is i)
    (is-equal (menu-entry-command (menu-entry i)) 'save-buffer)
    (is-equal (menu-entry-rule (menu-entry i)) :doc-changed))
  (is-equal (menu-find "save-buffer") (menu-find 'save-buffer))
  (is (null (menu-find 'forward-char)))    ; not in the menu
  (is (null (menu-find "forward-char")))
  (is (null (menu-find nil)))
  (is (null (menu-find "no-such-command")))
  (is (null (menu-entry -1)))
  (is (null (menu-entry (menu-count)))))

(deftest the-unbound-commands-are-reachable-from-the-menu
  ;; The reason the menu exists for these: they have no key.
  (dolist (command '(clamacs-new-buffer clamacs-connect run-lisp clamacs-compile-file
                     clamacs-arglist clamacs-debugger clamacs-snapshot-windows
                     clamacs-hyperspec clamacs-about))
    (is (menu-find command))))

(deftest every-shortcut-shown-runs-its-command
  (let ((lisp (lisp-keymap)) (repl (repl-keymap)))
    (dolist (e (menu-entries))
      (when (and (eq (menu-entry-kind e) :item) (menu-entry-keys e))
        (let ((got (resolve-keys (menu-entry-keys e)
                                 (ecase (menu-entry-map e)
                                   (:global nil) (:lisp lisp) (:repl repl)))))
          (unless (eq got (menu-entry-command e))
            (test-failure (list :shortcut (menu-entry-title e) (menu-entry-keys e))
                          (format nil " runs ~A" (or got "nothing")))))))))

(deftest menu-rules
  (let ((s (make-menu-state)))
    (is (menu-rule-holds-p :always s))
    (is (not (menu-rule-holds-p :doc-changed s)))
    (is (not (menu-rule-holds-p :doc-has-path s)))
    (is (not (menu-rule-holds-p :connected s)))
    (is (menu-rule-holds-p :not-connected s))
    (is (not (menu-rule-holds-p :repl-window s)))
    (is (not (menu-rule-holds-p :debugging s)))
    (is (not (menu-rule-holds-p :diagnostics s)))
    (is (not (menu-rule-holds-p :can-pop s)))
    (setf (menu-state-doc-changed s) t (menu-state-doc-has-path s) t
          (menu-state-connected s) t (menu-state-repl-window s) t
          (menu-state-debugging s) t (menu-state-diagnostics s) t
          (menu-state-can-pop s) t)
    (is (menu-rule-holds-p :doc-changed s))
    (is (menu-rule-holds-p :doc-has-path s))
    (is (menu-rule-holds-p :connected s))
    (is (not (menu-rule-holds-p :not-connected s)))
    (is (menu-rule-holds-p :repl-window s))
    (is (menu-rule-holds-p :debugging s))
    (is (menu-rule-holds-p :diagnostics s))
    (is (menu-rule-holds-p :can-pop s))))

;;; --- the state, read off the editor ---------------------------------------------

(deftest menu-state-follows-the-editor
  (multiple-value-bind (doc tr wire) (make-wired-fake "(a)|" :port nil)
    (let ((editor (doc-editor doc)))
      (doc-activate doc)
      (let ((s (menu-state editor)))
        (is (not (menu-state-doc-changed s)))
        (is (not (menu-state-doc-has-path s)))
        (is (not (menu-state-connected s)))
        (is (not (menu-state-diagnostics s)))
        (is (not (menu-state-can-pop s)))
        (is (not (menu-state-debugging s)))
        (is (not (menu-state-repl-window s))))
      (type-text doc "x")
      (setf (doc-path doc) "T:x.lisp")
      (is (menu-state-doc-changed (menu-state editor)))
      (is (menu-state-doc-has-path (menu-state editor)))
      ;; The port appears: connected.
      (setf (fake-transport-port tr) "CLAMIGA")
      (wire-find-port wire)
      (is (menu-state-connected (menu-state editor)))
      ;; Two diagnostics: the error list is not empty.
      (wire-diagnostics wire doc (lines "T:x.lisp:1: ERROR: one" "T:x.lisp:2: ERROR: two"
                                        "2 error(s), 0 warning(s)"))
      (is (menu-state-diagnostics (menu-state editor)))
      ;; M-. was used: there is a place to go back to.
      (locstack-push (editor-locations editor) "T:x.lisp" 1 0)
      (is (menu-state-can-pop (menu-state editor)))
      ;; The debugger entered and left.
      (debug-entered editor 1 (lines "SIMPLE-ERROR: bad" "0: ABORT Return to top level"))
      (is (menu-state-debugging (menu-state editor)))
      (debug-left editor)
      (is (not (menu-state-debugging (menu-state editor))))
      ;; Without an active document the document flags are off.
      (close-document doc nil)
      (let ((s (menu-state editor)))
        (is (not (menu-state-doc-changed s)))
        (is (menu-state-connected s))))))

(deftest menu-state-without-a-wire
  ;; The host tests' bare fake has no wire: nothing is connected, no
  ;; diagnostics, no error.
  (let ((doc (make-fake "|")))
    (let ((s (menu-state (doc-editor doc))))
      (is (not (menu-state-connected s)))
      (is (not (menu-state-diagnostics s))))
    (is (menu-item-enabled-p (doc-editor doc) (menu-find 'run-lisp)))
    (is (not (menu-item-enabled-p (doc-editor doc) (menu-find 'clamacs-eval-defun))))))

(deftest menu-enabled-items-is-one-flag-per-entry
  (let* ((doc (make-fake "|"))
         (flags (menu-enabled-items (doc-editor doc))))
    (is-equal (length flags) (menu-count))
    (is (nth (menu-find 'find-file) flags))
    (is (not (nth (menu-find 'save-buffer) flags)))
    ;; Titles and bars count as enabled.
    (is (nth 0 flags))))

;;; --- MENU, drive.rexx's menu leg --------------------------------------------------

(deftest menu-verb-reports-and-picks
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "MENU find-file STATE") '(0 "enabled"))
      ;; Cursor motion is deliberately not in the menu.
      (is-equal (port editor "MENU forward-char STATE") '(0 "no such menu item"))
      (is-equal (port editor "MENU forward-char") '(0 "no such menu item"))
      (is-equal (port editor "MENU no-such-command STATE") '(0 "no such menu item"))
      (is-equal (first (port editor "MENU")) 10)
      ;; STATE is case-insensitive, as ReadArgs keywords are.
      (is-equal (port editor "MENU find-file state") '(0 "enabled"))
      ;; Save follows the buffer: dimmed while it is clean, enabled by the
      ;; first edit, dimmed again once the menu has saved it.
      (let ((path (temp-file "menu-test.lisp")))
        (let ((new (open-document editor path)))
          (is-equal (fake-last-message new) "(New file)")
          (doc-activate new)
          (is-equal (port editor "MENU save-buffer STATE") '(0 "disabled"))
          ;; A pick of a disabled item does not run it.
          (is-equal (port editor "MENU save-buffer") '(0 "disabled"))
          (is (null (probe-file path)))
          (port editor "INSERT (defun menu-test () 42)")
          (is-equal (port editor "MENU save-buffer STATE") '(0 "enabled"))
          (is-equal (port editor "MENU save-buffer") '(0 ""))
          (is-equal (read-file-text path) "(defun menu-test () 42)")
          (is-equal (port editor "MENU save-buffer STATE") '(0 "disabled"))
          ;; Close Buffer from the menu; the saved buffer goes without a question.
          (is-equal (port editor "MENU kill-buffer") '(0 ""))
          (is (doc-closing new))
          (is (null (fake-asked new)))
          (is-equal (port editor "GETFILE") '(0 "Clamacs:verify/realamiga/sample.lisp"))
          (delete-file path)))
      ;; A pick runs the command on the active document: the same defun
      ;; the EVAL check finds from line 6.
      (port editor "GOTOLINE 6")
      (is-equal (port editor "MENU beginning-of-defun") '(0 ""))
      (is-equal (port editor "TE GETCURSOR LINE") '(0 "2"))
      ;; The REPL window's own items are dimmed in a file buffer.
      (is-equal (port editor "MENU clamacs-repl-clear STATE") '(0 "disabled"))
      ;; Help > Common Lisp HyperSpec is always live.
      (is-equal (port editor "MENU clamacs-hyperspec STATE") '(0 "enabled")))))

(deftest the-clamiga-menu-follows-the-port
  (multiple-value-bind (doc tr wire) (make-wired-fake "(+ 1 2)|" :port nil)
    (let ((editor (doc-editor doc)))
      (doc-activate doc)
      (is-equal (port editor "MENU clamacs-eval-defun STATE") '(0 "disabled"))
      (is-equal (port editor "MENU run-lisp STATE") '(0 "enabled"))
      (is-equal (port editor "MENU clamacs-next-error STATE") '(0 "disabled"))
      ;; The port is found: the Clamiga menu wakes up, Start clamiga dims.
      (setf (fake-transport-port tr) "CLAMIGA")
      (wire-find-port wire)
      (is-equal (port editor "MENU clamacs-eval-defun STATE") '(0 "enabled"))
      (is-equal (port editor "MENU run-lisp STATE") '(0 "disabled"))
      ;; A load's reply filled the error list: Next Error wakes up.
      (wire-diagnostics wire doc (lines "T:e.lisp:7: ERROR: a" "T:e.lisp:9: ERROR: b"
                                        "2 error(s), 0 warning(s)"))
      (is-equal (port editor "MENU clamacs-next-error STATE") '(0 "enabled"))
      (is-equal (port editor "MENU clamacs-previous-error STATE") '(0 "enabled")))))

(deftest the-windows-menu-follows-the-repl-and-the-debugger
  (multiple-value-bind (source repl tr wire) (repl-fixture)
    (declare (ignore tr wire))
    (let ((editor (doc-editor source)))
      ;; C-c C-z opened the REPL: its items are live there ...
      (is (eq (editor-active-document editor) repl))
      (is-equal (port editor "MENU clamacs-repl-clear STATE") '(0 "enabled"))
      (is-equal (port editor "MENU clamacs-repl-previous-input STATE") '(0 "enabled"))
      ;; ... and dimmed in the source window.
      (doc-activate source)
      (is-equal (port editor "MENU clamacs-repl-clear STATE") '(0 "disabled"))
      ;; The Debugger item follows the DEBUGGER messages.
      (is-equal (port editor "MENU clamacs-debugger STATE") '(0 "disabled"))
      (fake-inbound editor (lines "DEBUGGER 1 CL-USER" "SIMPLE-ERROR: bad 12"
                                  "0: ABORT Return to top level"))
      (is-equal (port editor "MENU clamacs-debugger STATE") '(0 "enabled"))
      (fake-inbound editor "DEBUGGER 0 CL-USER")
      (is-equal (port editor "MENU clamacs-debugger STATE") '(0 "disabled")))))

(deftest menu-pick-needs-an-active-document
  (let ((editor (make-fake-editor)))
    (is (not (menu-pick editor (menu-find 'find-file))))
    (is (not (menu-pick editor nil)))
    (is (not (menu-pick editor 0)))         ; a title
    ;; A pick over the port without a document is still answered.
    (is-equal (port editor "MENU find-file STATE") '(0 "enabled"))))

;;; --- About and the HyperSpec ---------------------------------------------------

(deftest about-says-what-it-runs-on
  (multiple-value-bind (doc tr wire) (make-wired-fake "|" :port nil)
    (let ((editor (doc-editor doc)))
      (let ((text (about-text editor)))
        (is (search (format nil "clamacs ~A" *clamacs-version*) text))
        (is (search "fake frontend 1.0" text))
        (is (search "clamiga: not connected" text)))
      ;; Connected but the version not asked yet: the port's name.
      (setf (fake-transport-port tr) "CLAMIGA.1")
      (wire-find-port wire)
      (is (search "clamiga: CLAMIGA.1" (about-text editor)))
      (setf (wire-version wire) "clamiga 0.11")
      (is (search "clamiga: clamiga 0.11" (about-text editor)))
      ;; The command puts it in a requester with one button.
      (setf (fake-answers doc) '(:ok))
      (run-command doc 'clamacs-about)
      (let ((asked (first (fake-asked doc))))
        (is-equal (second asked) '(:ok))
        (is (search "clamiga 0.11" (first asked))))))
  ;; Without a wire (the bare fake): not connected, no error.
  (is (search "not connected" (about-text (make-fake-editor)))))

(deftest hyperspec-goes-to-the-browser
  (let* ((doc (make-fake "|"))
         (editor (doc-editor doc)))
    (run-command doc 'clamacs-hyperspec)
    (is-equal (first (fake-urls doc)) *hyperspec-url*)
    (is-equal (fake-last-message doc) (format nil "Opened ~A" *hyperspec-url*))
    (is-equal (fake-beeps doc) 0)
    ;; No browser took it: said so, with a beep.
    (setf (fake-editor-url-answer editor) :refused)
    (run-command doc 'clamacs-hyperspec)
    (is-equal (fake-last-message doc)
              (format nil "No browser took ~A (check the OpenURL prefs)" *hyperspec-url*))
    (is-equal (fake-beeps doc) 1)
    ;; No openurl.library: the URL goes in a requester, where the user can
    ;; read it off.
    (setf (fake-editor-url-answer editor) :missing
          (fake-answers doc) '(:ok))
    (run-command doc 'clamacs-hyperspec)
    (let ((asked (first (fake-asked doc))))
      (is-equal (second asked) '(:ok))
      (is (search *hyperspec-url* (first asked)))
      (is (search "openurl.library is not installed" (first asked))))
    (is-equal (fake-last-message doc) "openurl.library not found")
    (is-equal (length (fake-urls doc)) 3)))

;;; --- the init file ------------------------------------------------------------

;;; The release compiles the FASLs with the HOST binary, whose *FEATURES* has
;;; no :AMIGAOS: a `#+amigaos' in the source is settled there, and the shipped
;;; editor would look for ~/.clamacsrc on the Amiga.  Binding *FEATURES* here
;;; only changes the answer when it is asked at run time.
(deftest the-init-file-is-chosen-when-the-editor-loads
  (let ((*features* (cons :amigaos *features*)))
    (is-equal (default-init-file) "S:.clamacsrc"))
  #-amigaos
  (let ((*features* (remove :amigaos *features*)))
    (is-equal (default-init-file)
              (namestring (merge-pathnames ".clamacsrc" (user-homedir-pathname))))))

(deftest the-init-file-defines-commands-and-binds-keys
  (let ((rc (temp-file "clamacsrc"
                       (lines "(define-command my-init-command (doc arg)"
                              "  (declare (ignore arg))"
                              "  (doc-message doc \"from the init file\"))"
                              "(bind-key \"C-c t\" 'my-init-command)"
                              "(bind-key \"C-c C-t\" 'my-init-command :lisp)")))
        (global *global-bindings*)
        (lisp *lisp-bindings*))
    (unwind-protect
         (progn
           (is-equal (load-init-file rc) t)
           (is (find-command "my-init-command"))
           ;; A document made afterwards has the bindings.
           (let ((doc (make-fake "|")))
             (type-keys doc "C-c t")
             (is-equal (fake-last-message doc) "from the init file")
             (setf (fake-messages doc) '())
             (type-keys doc "C-c C-t")
             (is-equal (fake-last-message doc) "from the init file"))
           ;; A missing file is nothing.  (A broken form is LOAD's own
           ;; business: it reports the file and line and goes on with the
           ;; forms after it, but only with no handler above it, so nothing
           ;; can show it from inside this runner's HANDLER-CASE.  No test
           ;; here covers it -- it would take a clamiga subprocess on a
           ;; broken rc file -- which is why the README does not promise it.)
           (is (null (load-init-file (temp-path "no-such-rc"))))
           ;; What cannot be bound is refused at once, not when the next
           ;; window is made.
           (is (typep (handler-case (bind-key "" 'my-init-command) (error (e) e)) 'error))
           (is (typep (handler-case (bind-key "C-c u" "not-a-symbol") (error (e) e)) 'error))
           (is (typep (handler-case (bind-key "C-c u" 'my-init-command :nowhere) (error (e) e)) 'error)))
      (setq *global-bindings* global *lisp-bindings* lisp)
      (delete-file rc))))

;;; KEYMAP-BIND-SEQ replaces silently -- a command by a prefix, a prefix by a
;;; command -- so the scratch-map rehearsal in BIND-KEY only catches a
;;; spelling that does not parse.  A clash with what is bound is refused too.
(deftest bind-key-refuses-a-key-that-is-both-a-command-and-a-prefix
  (let ((global *global-bindings*)
        (lisp *lisp-bindings*)
        (repl *repl-bindings*))
    (flet ((refused-p (keys map)
             (typep (handler-case (bind-key keys 'clamacs-about map) (error (e) e))
                    'error)))
      (unwind-protect
           (progn
             ;; A prefix cannot become a command (C-x's whole map would go),
             ;; and a key bound to a command cannot be run through.
             (is (refused-p "C-x" :global))
             (is (refused-p "M-g" :global))
             (is (refused-p "C-x C-f x" :global))
             (is (refused-p "C-M-f x" :lisp))
             ;; The REPL's map is the Lisp map with its own bindings on top.
             (is (refused-p "C-c C-c x" :repl))
             (is (refused-p "C-M-f x" :repl))
             ;; A refusal binds nothing.
             (is (eq *global-bindings* global))
             (is (eq *lisp-bindings* lisp))
             (is (eq *repl-bindings* repl))
             ;; What the user bound earlier counts as much as the defaults.
             (bind-key "C-c t" 'clamacs-about)
             (is (refused-p "C-c t x" :global))
             (is-equal (length *global-bindings*) (1+ (length global)))
             ;; The same keys again replace; a sibling and a new prefix are
             ;; fine.
             (bind-key "C-c t" 'clamacs-about)
             (bind-key "C-c u" 'clamacs-about)
             (bind-key "C-c v w" 'clamacs-about)
             (bind-key "C-c C-q" 'clamacs-about :repl)
             (is-equal (length *global-bindings*) (+ 4 (length global)))
             (is-equal (length *repl-bindings*) (1+ (length repl)))
             ;; The message names the binding it ran into.
             (is (search "\"C-x C-f\""
                         (format nil "~A" (handler-case (bind-key "C-x C-f x" 'clamacs-about)
                                            (error (e) e))))))
        (setq *global-bindings* global *lisp-bindings* lisp *repl-bindings* repl)))))
