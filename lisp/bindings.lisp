;;;; bindings.lisp -- the default key tables.
;;;;
;;;; Split in two because Lisp mode is the only mode the editor has, and the
;;;; commands that only make sense with a Lisp reader behind them (sexp
;;;; motion, indentation, everything that talks to clamiga) belong to it
;;;; rather than to every buffer.  The state machine consults the local map
;;;; first, so a non-Lisp buffer still gets the whole global table.
;;;;
;;;; This is the key table of specs/clamacs-ide.md, in the order the spec
;;;; lists it.  tests/test-bindings.lisp walks the same table and fails if a
;;;; promised key stops resolving, so the document and the editor cannot
;;;; drift.
;;;;
;;;; Anything NOT bound here reaches TextEditor.mcc unchanged, which is how
;;;; the arrows, Home/End, mouse selection, Backspace and self-insert keep
;;;; working without the editor reimplementing them.

(in-package :clamacs)

(defparameter *global-bindings*
  '(;; movement
    ("C-f" forward-char) ("C-b" backward-char)
    ("C-n" next-line) ("C-p" previous-line)
    ("C-a" beginning-of-line) ("C-e" end-of-line)
    ("M-f" forward-word) ("M-b" backward-word)
    ("M-<" beginning-of-buffer) ("M->" end-of-buffer)
    ("C-v" scroll-up) ("M-v" scroll-down)
    ("C-l" recenter) ("M-g g" goto-line)
    ;; deleting, killing, yanking
    ("C-d" delete-char) ("M-d" kill-word)
    ("M-DEL" backward-kill-word) ("M-BS" backward-kill-word)
    ("C-k" kill-line) ("C-w" kill-region) ("M-w" kill-ring-save)
    ("C-y" yank) ("M-y" yank-pop)
    ;; mark and region
    ("C-SPC" set-mark-command) ("C-x h" mark-whole-buffer)
    ("C-x C-x" exchange-point-and-mark)
    ;; undo
    ("C-/" undo) ("C-_" undo) ("C-x u" undo) ("C-x r" redo)
    ;; search
    ("C-s" isearch-forward) ("C-r" isearch-backward)
    ;; files, buffers, windows, quit
    ("C-x C-f" find-file) ("C-x C-s" save-buffer) ("C-x C-w" write-file)
    ("C-x b" switch-to-buffer) ("C-x k" kill-buffer)
    ("C-x C-c" save-buffers-kill-emacs) ("C-x o" other-window)
    ("C-x 2" find-file-other-window)
    ;; the command loop itself
    ("M-x" execute-extended-command) ("C-g" keyboard-quit)
    ;; the REPL window, reachable from any document as in SLIME
    ("C-c C-z" clamacs-repl)))

(defparameter *lisp-bindings*
  '(;; sexp motion and editing
    ("C-M-f" forward-sexp) ("C-M-b" backward-sexp)
    ("C-M-u" backward-up-list) ("C-M-d" down-list)
    ("C-M-a" beginning-of-defun) ("C-M-e" end-of-defun)
    ("C-M-k" kill-sexp) ("M-(" insert-parentheses)
    ;; indentation.  Both live in the Lisp map: without a Lisp indenter
    ;; behind them, Tab and Return are better served by the class's own
    ;; handling, which is exactly what an unbound key gets.
    ("TAB" indent-for-tab-command) ("RET" newline-and-indent)
    ("C-M-\\" indent-region)
    ;; talking to clamiga
    ("C-c C-k" clamacs-load-buffer) ("C-c C-l" clamacs-load-file)
    ("C-c C-c" clamacs-eval-defun) ("C-x C-e" clamacs-eval-last-sexp)
    ("C-c C-r" clamacs-eval-region) ("C-c C-e" clamacs-eval-expression)
    ("C-x `" clamacs-next-error) ("C-x ~" clamacs-previous-error)
    ;; `C-c C-d' is the documentation prefix (SLIME's), so the error list
    ;; is on flycheck's `C-c ! l'.
    ("C-c ! l" clamacs-show-errors)
    ;; introspection: SLIME's keys where SLIME has them
    ("M-TAB" complete-symbol) ("C-M-i" complete-symbol)
    ("M-." clamacs-edit-definition) ("M-," clamacs-pop-definition)
    ("C-c C-d d" clamacs-describe-symbol)
    ("C-c C-d C-d" clamacs-describe-symbol)
    ("C-c C-d a" clamacs-apropos) ("C-c C-d C-a" clamacs-apropos)
    ("C-c RET" clamacs-macroexpand-1) ("C-c C-m" clamacs-macroexpand-1)
    ("C-c M-m" clamacs-macroexpand)
    ;; the REPL thread: SLIME's interrupt key in a source buffer
    ("C-c C-b" clamacs-interrupt)
    ;; the inspector: SLIME's key, a form evaluated in clamiga
    ("C-c I" clamacs-inspect)))

;;; Laid over the Lisp map for the REPL window.  RET sends the input (or,
;;; for an unfinished form, does what it does in a source buffer); `C-c C-c'
;;; is the interrupt here, as in SLIME's listener, since there is no defun to
;;; evaluate; M-p/M-n walk the input history the way the minibuffer's do.
(defparameter *repl-bindings*
  '(("RET" clamacs-repl-return)
    ("M-p" clamacs-repl-previous-input) ("M-n" clamacs-repl-next-input)
    ("C-c C-c" clamacs-interrupt) ("C-c C-b" clamacs-interrupt)
    ("C-c M-o" clamacs-repl-clear)))

(defun add-bindings (map specs)
  (dolist (spec specs map)
    (unless (keymap-bind-seq map (first spec) (second spec))
      (error "Cannot bind ~S to ~S in the ~A keymap."
             (first spec) (second spec) (keymap-name map)))))

(defun binding-specs (map)
  "The specs the keymap MAP names is built from: the REPL's is the Lisp
map with its own laid over it."
  (ecase map
    (:global *global-bindings*)
    (:lisp *lisp-bindings*)
    (:repl (append *lisp-bindings* *repl-bindings*))))

(defun binding-clash (keys specs)
  "The first of SPECS that the key sequence KEYS cannot be bound beside, or
NIL: KEYS runs through a key that spec binds to a command (which would have
to become a prefix), or is a prefix of that spec's keys (binding it would
throw the prefix's map away).  The same keys are no clash: that replaces."
  (let ((new (split-key-sequence keys)))
    (find-if (lambda (spec)
               (let* ((old (split-key-sequence (first spec)))
                      (at (mismatch new old)))
                 (and old at (or (= at (length new)) (= at (length old))))))
             specs)))

(defun bind-key (keys command &optional (map :global))
  "Bind the key sequence KEYS (\"C-c t\") to COMMAND, a command symbol, in
the :GLOBAL, :LISP or :REPL bindings -- for the user's init file
\(S:.clamacsrc), which runs before the first window is made: every
document made afterwards gets the binding, and a later binding of the
same keys replaces it.  Signals when KEYS cannot be bound: it does not
parse, or it clashes with a binding already there -- it would run through
a key bound to a command (\"C-c t x\" after \"C-c t\") or be the prefix of
a bound sequence (\"C-x\" while \"C-x C-f\" is bound), which would throw
that prefix's whole map away."
  (unless (and (symbolp command) command)
    (error "BIND-KEY: ~S is not a command symbol." command))
  ;; A rehearsal on a scratch map, so a bad sequence fails here and not
  ;; when the next document is made ...
  (unless (keymap-bind-seq (make-keymap "probe") keys command)
    (error "Cannot bind ~S to ~S." keys command))
  ;; ... and against what is bound already, which the scratch map cannot
  ;; know: KEYMAP-BIND-SEQ replaces silently, a prefix or a command alike.
  (let ((clash (binding-clash keys (binding-specs map))))
    (when clash
      (error "BIND-KEY: ~S clashes with ~S (~S) in the ~(~A~) bindings: a key is either a command or a prefix, not both."
             keys (first clash) (second clash) map)))
  (let ((spec (list keys command)))
    (ecase map
      (:global (setq *global-bindings* (append *global-bindings* (list spec))))
      (:lisp (setq *lisp-bindings* (append *lisp-bindings* (list spec))))
      (:repl (setq *repl-bindings* (append *repl-bindings* (list spec))))))
  command)

(defun global-keymap ()
  "A fresh copy of the default global map."
  (add-bindings (make-keymap "global") *global-bindings*))

(defun lisp-keymap ()
  "A fresh copy of the Lisp-mode map."
  (add-bindings (make-keymap "lisp") *lisp-bindings*))

(defun repl-keymap ()
  "A fresh copy of the REPL window's map: the Lisp map with RET, the input
history and the interrupt rebound for a listener.  Rebinding replaces."
  (add-bindings (add-bindings (make-keymap "repl") *lisp-bindings*)
                *repl-bindings*))
