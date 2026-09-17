;;;; test-bindings.lisp -- the default key table.  The cases of
;;;; tests/test_bindings.c.
;;;;
;;;; specs/clamacs-ide.md calls this table "the bindings a user can rely
;;;; on".  This file is what makes that promise checkable: every sequence
;;;; below is fed through the real state machine against the real maps, so a
;;;; binding that stops resolving -- or starts resolving to something else --
;;;; fails here rather than on an Amiga.

(in-package :clamacs)

(defun feed-sequence (st keys)
  "Feed the keys spelled in KEYS; the values of the last feed, as a list."
  (let ((result '(:unbound)))
    (dolist (key (split-key-sequence keys) result)
      (setq result (multiple-value-list (keystate-feed st key))))))

(defun check-table (table local)
  "LOCAL: NIL for the global map alone, or a map to lay over it."
  (let ((global (global-keymap)))
    (dolist (row table)
      (let* ((keys (first row))
             (command (find-command (second row)))
             (result (feed-sequence (make-keystate global local) keys)))
        (unless command
          (test-failure (second row) " is not a command"))
        (unless (equal result (list :command command))
          (test-failure keys (format nil " gave ~S, expected ~S"
                                     result (second row))))))))

(deftest spec-movement-keys
  (check-table '(("C-f" "forward-char") ("C-b" "backward-char")
                 ("C-n" "next-line") ("C-p" "previous-line")
                 ("C-a" "beginning-of-line") ("C-e" "end-of-line")
                 ("M-f" "forward-word") ("M-b" "backward-word")
                 ("M-<" "beginning-of-buffer") ("M->" "end-of-buffer")
                 ("C-v" "scroll-up") ("M-v" "scroll-down")
                 ("C-l" "recenter") ("M-g g" "goto-line"))
               nil))

(deftest spec-kill-and-yank-keys
  (check-table '(("C-d" "delete-char") ("M-d" "kill-word")
                 ("M-DEL" "backward-kill-word") ("M-BS" "backward-kill-word")
                 ("C-k" "kill-line") ("C-w" "kill-region")
                 ("M-w" "kill-ring-save") ("C-y" "yank") ("M-y" "yank-pop"))
               nil))

(deftest spec-mark-undo-and-search-keys
  (check-table '(("C-SPC" "set-mark-command") ("C-x h" "mark-whole-buffer")
                 ("C-x C-x" "exchange-point-and-mark")
                 ("C-/" "undo") ("C-_" "undo") ("C-x u" "undo")
                 ("C-x r" "redo")
                 ("C-s" "isearch-forward") ("C-r" "isearch-backward"))
               nil))

(deftest spec-file-and-window-keys
  (check-table '(("C-x C-f" "find-file") ("C-x C-s" "save-buffer")
                 ("C-x C-w" "write-file") ("C-x b" "switch-to-buffer")
                 ("C-x k" "kill-buffer")
                 ("C-x C-c" "save-buffers-kill-emacs")
                 ("C-x o" "other-window") ("C-x 2" "find-file-other-window")
                 ("M-x" "execute-extended-command")
                 ("C-g" "keyboard-quit"))
               nil))

(deftest spec-sexp-keys-are-lisp-mode
  (let ((table '(("C-M-f" "forward-sexp") ("C-M-b" "backward-sexp")
                 ("C-M-u" "backward-up-list") ("C-M-d" "down-list")
                 ("C-M-a" "beginning-of-defun") ("C-M-e" "end-of-defun")
                 ("C-M-k" "kill-sexp") ("M-(" "insert-parentheses")
                 ("TAB" "indent-for-tab-command")
                 ("RET" "newline-and-indent") ("C-M-\\" "indent-region"))))
    (check-table table (lisp-keymap))
    ;; ... and ONLY Lisp mode: without the map they belong to the class.
    (let ((global (global-keymap)))
      (dolist (row table)
        (is-equal (feed-sequence (make-keystate global) (first row))
                  '(:unbound))))))

(deftest spec-lisp-interaction-keys
  (check-table '(("C-c C-k" "clamacs-load-buffer")
                 ("C-c C-c" "clamacs-eval-defun")
                 ("C-x C-e" "clamacs-eval-last-sexp")
                 ("C-c C-r" "clamacs-eval-region")
                 ("C-c C-e" "clamacs-eval-expression")
                 ("C-c C-l" "clamacs-load-file")
                 ("C-x `" "clamacs-next-error")
                 ("C-x ~" "clamacs-previous-error"))
               (lisp-keymap)))

(deftest spec-introspection-keys
  ;; SLIME's keys where SLIME has them, and both spellings of each
  ;; documentation key, since `C-c C-d d' and `C-c C-d C-d' are the same
  ;; command under the same fingers.
  (check-table '(("M-TAB" "complete-symbol") ("C-M-i" "complete-symbol")
                 ("M-." "clamacs-edit-definition")
                 ("M-," "clamacs-pop-definition")
                 ("C-c C-d d" "clamacs-describe-symbol")
                 ("C-c C-d C-d" "clamacs-describe-symbol")
                 ("C-c C-d a" "clamacs-apropos")
                 ("C-c C-d C-a" "clamacs-apropos")
                 ("C-c RET" "clamacs-macroexpand-1")
                 ("C-c C-m" "clamacs-macroexpand-1")
                 ("C-c M-m" "clamacs-macroexpand")
                 ("C-c ! l" "clamacs-show-errors"))
               (lisp-keymap)))

(deftest spec-repl-keys
  ;; In the REPL window RET sends, M-p/M-n walk the history, `C-c C-c'
  ;; interrupts (SLIME's listener key); the Lisp map's other bindings stay
  ;; -- TAB still indents, `M-.' still jumps -- and the global `C-c C-z'
  ;; raises the REPL from any document.
  (check-table '(("RET" "clamacs-repl-return")
                 ("M-p" "clamacs-repl-previous-input")
                 ("M-n" "clamacs-repl-next-input")
                 ("C-c C-c" "clamacs-interrupt")
                 ("C-c C-b" "clamacs-interrupt")
                 ("C-c M-o" "clamacs-repl-clear")
                 ("C-c C-z" "clamacs-repl")
                 ("TAB" "indent-for-tab-command")
                 ("M-." "clamacs-edit-definition")
                 ("C-c C-d d" "clamacs-describe-symbol")
                 ("C-x C-f" "find-file")
                 ("C-c I" "clamacs-inspect"))
               (repl-keymap))
  (check-table '(("C-c C-z" "clamacs-repl")
                 ("C-c C-b" "clamacs-interrupt")
                 ;; unchanged in a source buffer
                 ("C-c C-c" "clamacs-eval-defun")
                 ("RET" "newline-and-indent")
                 ;; SLIME's inspect key, in the Lisp map and so in the REPL's.
                 ("C-c I" "clamacs-inspect"))
               (lisp-keymap))
  (check-table '(("C-c C-z" "clamacs-repl")) nil))

(deftest c-c-c-d-is-a-prefix
  ;; It was `clamacs-show-errors' once; a binding that silently turned back
  ;; into a command would swallow the documentation keys.
  (let ((st (make-keystate (global-keymap) (lisp-keymap))))
    (is-equal (feed-sequence st "C-c") '(:prefix))
    (is-equal (feed-sequence st "C-d") '(:prefix))
    (is-equal (keystate-describe st) "C-c C-d -")))

(deftest lisp-prefix-does-not-hide-the-global-one
  ;; Both maps bind something on C-x.  The local map must win for `C-x C-e',
  ;; and entering Lisp mode must not cost the user `C-x C-f', `C-x C-s' or
  ;; `C-x u'.
  (check-table '(("C-x C-f" "find-file") ("C-x C-s" "save-buffer")
                 ("C-x C-c" "save-buffers-kill-emacs") ("C-x u" "undo")
                 ("C-x b" "switch-to-buffer") ("C-x h" "mark-whole-buffer")
                 ("C-x C-e" "clamacs-eval-last-sexp"))
               (lisp-keymap))
  (is-equal (feed-sequence (make-keystate (global-keymap) (lisp-keymap))
                           "C-x C-q")
            '(:undefined)))

(deftest unbound-keys-reach-the-superclass
  ;; The keys TextEditor.mcc handles itself must NOT be claimed here, or the
  ;; class's own navigation, selection and self-insert stop working.
  (let ((global (global-keymap))
        (lisp (lisp-keymap)))
    (dolist (key '("a" "Z" "1" "<up>" "<down>" "<left>" "<right>"
                   "<home>" "<end>" "BS" "DEL" "C-z" "M-z"))
      (is-equal (list key (feed-sequence (make-keystate global lisp) key))
                (list key '(:unbound))))))

(defun check-bindings-name-commands (map)
  (maphash (lambda (key binding)
             (declare (ignore key))
             (if (keymap-p binding)
                 (check-bindings-name-commands binding)
                 (unless (command-name binding)
                   (test-failure binding " is bound but is not a command"))))
           (keymap-table map)))

(deftest every-binding-names-a-real-command
  ;; A binding to a symbol outside the table would be a silent no-op at
  ;; runtime; catch it here instead.  All prefix levels.
  (check-bindings-name-commands (global-keymap))
  (check-bindings-name-commands (lisp-keymap))
  (check-bindings-name-commands (repl-keymap)))

(deftest keymaps-are-fresh-copies
  ;; A document that rebinds a key in its map must not change another's.
  (let ((one (lisp-keymap))
        (two (lisp-keymap)))
    (keymap-bind-seq one "C-c C-c" 'keyboard-quit)
    (is-equal (feed-sequence (make-keystate (global-keymap) two) "C-c C-c")
              '(:command clamacs-eval-defun))))

(deftest a-bad-table-row-is-an-error
  (is (handler-case (progn (add-bindings (make-keymap "bad")
                                         '(("C-x nonsense" find-file)))
                           nil)
        (error () t))))
