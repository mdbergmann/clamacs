;;;; command.lisp -- the command table.
;;;;
;;;; Commands are named, and the name is the whole point: `M-x' and the
;;;; editor's own ARexx port (`EVAL <command-name>') share one namespace, so
;;;; a macro can drive anything a key can.
;;;;
;;;; A command is a SYMBOL.  Its name is the symbol's name in lower case; a
;;;; keymap binds keys to the symbol; running it calls the symbol's function.
;;;; That is what makes the editor live-hackable: DEFINE-COMMAND in a running
;;;; editor -- from the user's init file, from any package -- adds to `M-x'
;;;; and can be bound at once, and redefining a command changes what its
;;;; keys do without touching a keymap.
;;;;
;;;; The list below declares every command of the C editor, so the bindings,
;;;; the menu table and the port's namespace are complete (and host-tested)
;;;; before the frontend that implements them is loaded.  A declared command
;;;; without a function is "not implemented", which COMMAND-FUNCTION lets
;;;; the caller say in the echo area.
;;;;
;;;; Pure: no MUI, no OS types.  What each command DOES lives in the
;;;; frontend-facing files; what each command IS lives here.

(in-package :clamacs)

(defvar *commands* (make-hash-table :test 'equal)
  "Command name (a lowercase string) to command symbol.")

(defvar *command-names* '()
  "The names in registration order, newest first; see COMMAND-NAMES.")

(defun register-command (symbol)
  "Make SYMBOL a command.  Registering again is harmless; a second symbol
with the same name (from another package) takes the name over."
  (let ((name (string-downcase (symbol-name symbol))))
    (unless (gethash name *commands*)
      (push name *command-names*))
    (let ((old (gethash name *commands*)))
      (when (and old (not (eq old symbol)))
        (remprop old 'command-name)))
    (setf (gethash name *commands*) symbol
          (get symbol 'command-name) name)
    symbol))

(defmacro declare-commands (&rest symbols)
  `(dolist (symbol ',symbols)
     (register-command symbol)))

(defmacro define-command (name lambda-list &body body)
  "Define the function NAME and make it a command: `M-x', the menu table and
the ARexx port find it by its lowercase name, and a keymap can bind it.  The
docstring is what `M-x' help shows."
  `(progn
     (defun ,name ,lambda-list ,@body)
     (register-command ',name)))

(defun command-name (symbol)
  "The name of the command SYMBOL, or NIL when it is not a command."
  (and (symbolp symbol) (get symbol 'command-name)))

(defun find-command (name)
  "The command named NAME, or NIL.  Exact match, case sensitive: command
names are lowercase by convention and an ARexx macro that sends `FIND-FILE'
has a bug, not a spelling variant."
  (and (stringp name) (values (gethash name *commands*))))

(defun command-function (symbol)
  "The function to call for the command SYMBOL, or NIL while it is only
declared."
  (and (command-name symbol) (fboundp symbol) (symbol-function symbol)))

(defun command-names ()
  "Every command name, in the order the commands were registered."
  (reverse *command-names*))

(defun complete-command (prefix)
  "Completion over command names for the minibuffer: the matches and their
longest common prefix, as COMPLETE returns them."
  (complete (command-names) prefix))

;;; Order is not significant; it is grouped the way the phase-1 key table in
;;; specs/clamacs-ide.md is grouped, so the two can be read side by side.
(declare-commands
 ;; movement
 forward-char backward-char next-line previous-line
 beginning-of-line end-of-line forward-word backward-word
 beginning-of-buffer end-of-buffer scroll-up scroll-down
 goto-line recenter
 ;; deleting, killing, yanking
 delete-char backward-delete-char kill-word backward-kill-word
 kill-line kill-region kill-ring-save yank yank-pop
 ;; mark and region
 set-mark-command mark-whole-buffer exchange-point-and-mark
 ;; undo
 undo redo
 ;; search
 isearch-forward isearch-backward
 ;; files, buffers, windows
 find-file find-file-other-window clamacs-new-buffer save-buffer
 write-file switch-to-buffer kill-buffer other-window
 save-buffers-kill-emacs
 ;; the command loop itself.  `C-u' is deliberately absent: the numeric
 ;; argument is read by the key state machine before dispatch, so it never
 ;; becomes a command and `M-x universal-argument' would be meaningless.
 execute-extended-command keyboard-quit
 ;; Lisp mode: structure
 forward-sexp backward-sexp backward-up-list down-list
 beginning-of-defun end-of-defun kill-sexp insert-parentheses
 indent-for-tab-command newline-and-indent indent-region
 ;; Lisp mode: talking to clamiga
 clamacs-load-buffer clamacs-load-file clamacs-compile-file
 clamacs-eval-defun clamacs-eval-last-sexp clamacs-eval-region
 clamacs-eval-expression clamacs-connect clamacs-show-errors
 clamacs-next-error clamacs-previous-error run-lisp
 ;; Lisp mode: introspection.  `complete-symbol' keeps its Emacs name
 ;; because it is the same key doing the same thing; the rest carry the
 ;; editor's prefix, as the other clamiga commands do.
 complete-symbol clamacs-arglist clamacs-edit-definition
 clamacs-pop-definition clamacs-describe-symbol clamacs-apropos
 clamacs-macroexpand-1 clamacs-macroexpand
 ;; The REPL window.  `clamacs-repl' opens or raises it from any document;
 ;; the `clamacs-repl-*' commands act in it; the interrupt reaches clamiga's
 ;; REPL thread from anywhere.
 clamacs-repl clamacs-repl-return clamacs-repl-previous-input
 clamacs-repl-next-input clamacs-repl-clear clamacs-interrupt
 ;; The debugger and inspector windows.  `clamacs-inspect' is SLIME's
 ;; `C-c I'; the rest are the windows' buttons and lists as commands, so
 ;; `M-x' and the ARexx port can drive the debugger too.
 clamacs-inspect clamacs-inspector-part clamacs-inspector-pop
 clamacs-debugger clamacs-debugger-abort clamacs-debugger-continue
 clamacs-debugger-restart clamacs-debugger-frame clamacs-debugger-eval
 ;; Window positions, and the HyperSpec in the user's browser.
 clamacs-snapshot-windows clamacs-hyperspec)
