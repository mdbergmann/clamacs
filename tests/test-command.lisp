;;;; test-command.lisp -- the command table and completion.  The cases of
;;;; tests/test_command.c, plus DEFINE-COMMAND, which C did not have.

(in-package :clamacs)

(deftest command-name-and-lookup-agree
  ;; Every name finds a command, and that command gives the name again.
  ;; This is the property the ARexx port relies on when it turns a string
  ;; from another program into something to run.
  (is (>= (length (command-names)) 90))
  (dolist (name (command-names))
    (is (string/= name ""))
    (is-equal name (string-downcase name))
    (let ((command (find-command name)))
      (is (and command (symbolp command)))
      (is-equal (command-name command) name))))

(deftest command-names-are-unique
  (let ((names (command-names)))
    (is-equal (length names)
              (length (remove-duplicates names :test #'string=)))))

(deftest command-lookup-rejects-junk
  (is-equal (find-command "no-such-command") nil)
  (is-equal (find-command "") nil)
  (is-equal (find-command nil) nil)
  (is-equal (find-command 'find-file) nil)
  ;; Case matters: an ARexx macro sending FIND-FILE has a bug.
  (is-equal (find-command "FIND-FILE") nil)
  (is-equal (find-command "find-file") 'find-file))

(deftest command-name-rejects-what-is-no-command
  (is-equal (command-name 'car) nil)
  (is-equal (command-name nil) nil)
  (is-equal (command-name "find-file") nil)
  (is-equal (command-name 42) nil))

(deftest command-table-keeps-its-order
  (is-equal (first (command-names)) "forward-char")
  (is-equal (second (command-names)) "backward-char")
  ;; The last one the editor declares (this file defines more, later).
  (is-equal (second (member "clamacs-snapshot-windows" (command-names)
                            :test #'string=))
            "clamacs-hyperspec"))

(defun command-completions (prefix)
  (multiple-value-list (complete-command prefix)))

(deftest command-completion-finds-prefix
  (is-equal (command-completions "beginning-of-")
            '(("beginning-of-line" "beginning-of-buffer" "beginning-of-defun")
              "beginning-of-"))
  (is-equal (command-completions "kill-r")
            '(("kill-region" "kill-ring-save") "kill-r"))
  ;; A unique match completes fully.
  (is-equal (command-completions "yank-p") '(("yank-pop") "yank-pop")))

(deftest command-completion-empty-prefix-is-everything
  (is-equal (first (command-completions "")) (command-names)))

(deftest command-completion-no-match
  (is-equal (command-completions "zzz") '(() "")))

(deftest clamacs-commands-are-namespaced
  ;; The commands that talk to clamiga carry the editor's own prefix, so
  ;; `M-x' completion separates them from ordinary editing commands.
  (is (>= (length (complete-command "clamacs-")) 8))
  (is (find-command "clamacs-load-buffer"))
  (is (find-command "clamacs-eval-defun")))

(deftest declared-command-has-no-function-yet
  (register-command 'test-only-declared)
  (is-equal (command-function 'test-only-declared) nil)
  (is-equal (command-function 'car) nil))

(define-command test-say-hello (&optional (who "world"))
  "Greets, for the DEFINE-COMMAND test."
  (concatenate 'string "hello, " who))

(deftest define-command-registers-and-runs
  (is-equal (command-name 'test-say-hello) "test-say-hello")
  (is-equal (find-command "test-say-hello") 'test-say-hello)
  (is-equal (funcall (command-function 'test-say-hello)) "hello, world")
  (is-equal (documentation 'test-say-hello 'function)
            "Greets, for the DEFINE-COMMAND test.")
  ;; `M-x' sees it, after the commands the editor came with.
  (is (member "test-say-hello" (complete-command "test-say") :test #'string=))
  (is (< (position "clamacs-hyperspec" (command-names) :test #'string=)
         (position "test-say-hello" (command-names) :test #'string=)))
  ;; Redefining is how a running editor is hacked: same name, same slot in
  ;; the table, new behaviour.
  (let ((count (length (command-names))))
    (eval '(define-command test-say-hello () "Again." "hello again"))
    (is-equal (length (command-names)) count)
    (is-equal (funcall (command-function 'test-say-hello)) "hello again")))

(deftest command-name-is-taken-over-across-packages
  ;; The user's init file lives in another package; its command of the same
  ;; name replaces the editor's under `M-x'.
  (let ((mine (make-symbol "TEST-TAKEN-OVER"))
        (theirs (make-symbol "TEST-TAKEN-OVER")))
    (register-command mine)
    (register-command theirs)
    (is-equal (find-command "test-taken-over") theirs)
    (is-equal (command-name theirs) "test-taken-over")
    (is-equal (command-name mine) nil)))
