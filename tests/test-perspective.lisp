;;;; test-perspective.lisp -- perspectives on the fake frontend
;;;; (specs/clamacs-perspectives.md): who belongs, what is shown, the
;;;; switch, the rules that keep a window on the screen, the commands and
;;;; their prompts, the project directory, the file, the menu group and
;;;; the port's PERSPECTIVES verb.

(in-package :clamacs)

(defun persp-doc (editor name &optional path)
  "A fake document called NAME, showing PATH, on EDITOR -- named at its
making, as the editor makes its documents, since that is when a document
joins a perspective or, as a tool buffer, none."
  (make-instance 'fake-document :editor editor :name name :path path
                                :lisp-mode t :mirror (make-mirror)))

(defun persp-fixture ()
  "An editor with two file buffers in `main', the first active: (values
editor a b)."
  (let* ((editor (make-fake-editor))
         (a (persp-doc editor "a.lisp" "T:a.lisp"))
         (b (persp-doc editor "b.lisp" "T:b.lisp")))
    (doc-activate a)
    (values editor a b)))

(defun shown-names (editor)
  (mapcar #'doc-name (shown-documents editor)))

(defun fake-shown-names (editor)
  "The documents whose windows the fake frontend shows, oldest first."
  (mapcar #'doc-name (remove-if-not #'fake-shown (live-documents editor))))

(defun answer-prompt (doc text)
  "The open prompt answered with TEXT and RET."
  (is (minibuffer-open-p doc))
  (doc-set-minibuffer-text doc text)
  (type-keys doc "RET"))

;;; --- who belongs, and what is shown --------------------------------------------

(deftest an-editor-has-a-main-perspective-and-its-sources-join-it
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor)))
      (is-equal (perspective-name main) "main")
      (is-equal (perspective-names editor) '("main"))
      (is (eq (doc-perspective a) main))
      (is (eq (doc-perspective b) main))
      (is-equal (perspective-documents main) (list a b))
      (is (null (perspective-root main)))
      ;; A tool buffer belongs to none and is shown in every perspective.
      (let ((repl (persp-doc editor "*clamacs-repl*")))
        (is (null (doc-perspective repl)))
        (is (doc-shown-p repl))
        (is (not (member repl (perspective-documents main))))
        ;; ... until a save gives it a file: then it is a source and joins.
        (visit-path repl "T:repl-saved.lisp")
        (is (eq (doc-perspective repl) main))
        (is-equal (perspective-documents main) (list a b repl)))
      ;; Every document is shown while there is one perspective.
      (is-equal (shown-names editor) '("a.lisp" "b.lisp" "repl-saved.lisp"))
      (is (every #'fake-shown (live-documents editor))))))

(deftest a-closed-document-leaves-its-perspective
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor)))
      (close-document b nil)
      (is-equal (perspective-documents main) (list a))
      (is-equal (perspective-live-documents main) (list a))
      ;; The last one too; with no other perspective nothing else happens
      ;; (the frontend's loop sees the last window go, as before).
      (close-document a nil)
      (is (null (perspective-documents main)))
      (is (eq (current-perspective editor) main))
      (is (null (live-documents editor))))))

;;; --- switching -----------------------------------------------------------------

(deftest a-switch-shows-the-new-perspective-and-hides-the-old
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other")))
      (is-equal (perspective-names editor) '("main" "other"))
      ;; Entered empty: an unnamed buffer opens in it and takes the keyboard.
      (doc-activate b)
      (is (eq (perspective-switch editor other) other))
      (is (eq (current-perspective editor) other))
      (let ((u (editor-active-document editor)))
        (is-equal (doc-name u) *unnamed*)
        (is (eq (doc-perspective u) other))
        (is-equal (perspective-documents other) (list u))
        (is-equal (fake-last-message u) "Perspective: other")
        ;; The old perspective remembered its active document and hid
        ;; its windows; the new one's are shown.
        (is (eq (perspective-active main) b))
        (is-equal (shown-names editor) (list *unnamed*))
        (is-equal (fake-shown-names editor) (list *unnamed*))
        (is (not (doc-shown-p a)))
        (is (not (fake-shown a)))
        ;; Back: the remembered document is activated, the other hidden.
        (perspective-switch editor main)
        (is (eq (editor-active-document editor) b))
        (is-equal (fake-activations b) 2)
        (is-equal (shown-names editor) '("a.lisp" "b.lisp"))
        (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
        (is (not (fake-shown u)))
        (is-equal (fake-last-message b) "Perspective: main")
        ;; Switching to the one in front does nothing.
        (perspective-switch editor main)
        (is-equal (fake-activations b) 2)))))

(deftest a-tool-buffer-stays-shown-across-a-switch
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore a b))
    (let ((repl (persp-doc editor "*clamacs-repl*"))
          (other (make-perspective editor "other")))
      (perspective-switch editor other)
      (is (fake-shown repl))
      (is-equal (shown-names editor) (list "*clamacs-repl*" *unnamed*))
      ;; The Buffers menu and C-x o see the shown ones only.
      (is-equal (mapcar (lambda (e) (if (eq e :bar) :bar (car e))) (buffer-menu editor))
                (list *unnamed* :bar "*clamacs-repl*"))
      (let ((u (editor-active-document editor)))
        (is (eq (next-document u) repl))
        (is (eq (next-document repl) u))
        (run-command u 'other-window)
        (is (eq (editor-active-document editor) repl))
        ;; A hidden buffer cannot be picked from the menu.
        (is (not (buffer-menu-pick editor (first (perspective-documents (find-perspective editor "main"))))))))))

(deftest closing-the-last-buffer-in-front-brings-another-perspective-in-front
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other")))
      (perspective-switch editor other)
      (let ((u (editor-active-document editor)))
        ;; C-x k on the only buffer of `other': main comes back, with its
        ;; documents shown and the remembered one active.
        (run-command u 'kill-buffer)
        (is (doc-closing u))
        (is (eq (current-perspective editor) main))
        (is (eq (editor-active-document editor) a))
        (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
        (is-equal (fake-last-message a) "Perspective: main")
        ;; `other' stays, empty; entered again it gets a buffer again.
        (is (member other (editor-perspectives editor)))
        (is (null (perspective-live-documents other)))
        (perspective-switch editor other)
        (is-equal (doc-name (editor-active-document editor)) *unnamed*)
        (is (not (eq (editor-active-document editor) u)))))))

(deftest a-question-about-a-hidden-buffer-is-asked-in-front-of-it
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other")))
      (type-text a "x")
      (is (doc-modified-p a))
      (perspective-switch editor other)
      (is (not (fake-shown a)))
      ;; The quit closes every window; a's question brings main in front
      ;; first, and the answer closes it.
      (setf (fake-answers a) '(:discard))
      (let ((u (editor-active-document editor)))
        (run-command u 'save-buffers-kill-emacs)
        (is (quit-requested editor))
        (is-equal (length (fake-asked a)) 1)
        (is (null (live-documents editor)))
        (is (eq (perspective-of-document editor a) main))))))

;;; --- the commands ---------------------------------------------------------------

(deftest the-switch-command-completes-and-makes-a-new-one
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (run-command a 'clamacs-perspective-switch)
    (is-equal (fake-mini-label a) "Perspective: ")
    ;; TAB completes over the names.
    (doc-set-minibuffer-text a "m")
    (type-keys a "TAB")
    (is-equal (fake-mini-text a) "main")
    ;; The one in front: nothing happens.
    (type-keys a "RET")
    (is-equal (fake-last-message a) "Already in main")
    ;; A new name makes one and switches to it.
    (run-command a 'clamacs-perspective-switch)
    (answer-prompt a "work")
    (is-equal (perspective-names editor) '("main" "work"))
    (is-equal (perspective-name (current-perspective editor)) "work")
    (is (not (fake-shown a)))
    (let ((u (editor-active-document editor)))
      (is-equal (fake-last-message u) "New perspective: work")
      ;; By name, back.
      (run-command u 'clamacs-perspective-switch)
      (answer-prompt u "main")
      (is (eq (editor-active-document editor) a))
      (is-equal (fake-last-message a) "Perspective: main")
      ;; No name: refused.
      (run-command a 'clamacs-perspective-switch)
      (answer-prompt a "  ")
      (is-equal (fake-last-message a) "A perspective needs a name")
      (is-equal (fake-beeps a) 1)
      (is-equal (perspective-names editor) '("main" "work")))))

(deftest next-and-previous-cycle-in-the-order-made
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (run-command a 'clamacs-perspective-next)
    (is-equal (fake-last-message a) "Only one perspective (main)")
    (make-perspective editor "two")
    (make-perspective editor "three")
    (run-command a 'clamacs-perspective-next)
    (is-equal (perspective-name (current-perspective editor)) "two")
    (run-command (editor-active-document editor) 'clamacs-perspective-next)
    (is-equal (perspective-name (current-perspective editor)) "three")
    (run-command (editor-active-document editor) 'clamacs-perspective-next)
    (is-equal (perspective-name (current-perspective editor)) "main")
    (run-command (editor-active-document editor) 'clamacs-perspective-previous)
    (is-equal (perspective-name (current-perspective editor)) "three")
    ;; The menu's rule: enabled with two or more.
    (is (menu-state-perspectives (menu-state editor)))
    (is (menu-item-enabled-p editor (menu-find 'clamacs-perspective-next)))))

(deftest rename-refuses-empty-and-taken-names
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (make-perspective editor "other")
    (run-command a 'clamacs-perspective-rename)
    (is-equal (fake-prompt a) "Rename perspective to: main")
    (answer-prompt a "other")
    (is-equal (fake-last-message a) "There is a perspective called other already")
    (is-equal (perspective-names editor) '("main" "other"))
    (run-command a 'clamacs-perspective-rename)
    (answer-prompt a "")
    (is-equal (fake-last-message a) "A perspective needs a name")
    (is-equal (fake-beeps a) 2)
    (run-command a 'clamacs-perspective-rename)
    (answer-prompt a " project ")
    (is-equal (fake-last-message a) "Renamed main to project")
    (is-equal (perspective-names editor) '("project" "other"))
    ;; Its own name again is fine.
    (run-command a 'clamacs-perspective-rename)
    (answer-prompt a "project")
    (is-equal (fake-last-message a) "Renamed project to project")))

(deftest close-switches-away-then-closes-the-buffers
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor)))
      ;; The only one cannot be closed.
      (run-command a 'clamacs-perspective-close)
      (is-equal (fake-last-message a) "main is the only perspective")
      (is-equal (fake-beeps a) 1)
      (is (member main (editor-perspectives editor)))
      ;; A second one, with a buffer of its own.
      (let ((other (make-perspective editor "other")))
        (perspective-switch editor other)
        (let ((u (editor-active-document editor)))
          (run-command u 'clamacs-perspective-close)
          (is (doc-closing u))
          (is-equal (perspective-names editor) '("main"))
          (is (eq (current-perspective editor) main))
          (is (eq (editor-active-document editor) a))
          (is-equal (fake-last-message a) "Closed perspective other")
          (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))))
      ;; An unsaved buffer asks; a cancel keeps the perspective.
      (let ((other (make-perspective editor "other")))
        (perspective-switch editor other)
        (let ((u (editor-active-document editor)))
          (type-text u "x")
          (setf (fake-answers u) '(:cancel))
          (run-command u 'clamacs-perspective-close)
          (is (not (doc-closing u)))
          (is-equal (perspective-names editor) '("main" "other"))
          ;; The question was asked in front of it, so `other' is in front.
          (is (eq (current-perspective editor) other))
          (is-equal (fake-last-message u) "Cancelled; other stays")
          ;; Discarded: it goes, and main -- its remembered document a --
          ;; is in front again.
          (setf (fake-answers u) '(:discard))
          (run-command u 'clamacs-perspective-close)
          (is (doc-closing u))
          (is-equal (perspective-names editor) '("main"))
          (is (eq (editor-active-document editor) a))
          (is (fake-shown b))
          (is-equal (fake-last-message a) "Closed perspective other")
          (is (eq (current-perspective editor) main)))))))

(deftest move-buffer-puts-the-window-in-another-perspective
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor)))
      ;; Into a new one: made, the buffer hidden here, the next one active.
      (run-command a 'clamacs-perspective-move-buffer)
      (answer-prompt a "work")
      (let ((work (find-perspective editor "work")))
        (is work)
        (is (eq (doc-perspective a) work))
        (is-equal (perspective-documents main) (list b))
        (is-equal (perspective-documents work) (list a))
        (is (eq (current-perspective editor) main))
        (is (not (fake-shown a)))
        (is (eq (editor-active-document editor) b))
        (is-equal (fake-last-message b) "a.lisp moved to work")
        ;; Already there: said so.
        (run-command b 'clamacs-perspective-move-buffer)
        (answer-prompt b "main")
        (is-equal (fake-last-message b) "b.lisp is in main already")
        (is (eq (doc-perspective b) main))
        ;; The last buffer of the one in front moves: the editor follows it.
        (run-command b 'clamacs-perspective-move-buffer)
        (answer-prompt b "work")
        (is (eq (current-perspective editor) work))
        (is (eq (editor-active-document editor) b))
        (is-equal (perspective-documents work) (list a b))
        (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
        (is (null (perspective-documents main)))
        ;; A tool buffer is refused.
        (let ((repl (persp-doc editor "*clamacs-repl*")))
          (run-command repl 'clamacs-perspective-move-buffer)
          (is (not (minibuffer-open-p repl)))
          (is-equal (fake-last-message repl) "*clamacs-repl* is a tool buffer, shown in every perspective")
          (is-equal (fake-beeps repl) 1))))))

(deftest find-file-brings-a-file-over-from-another-perspective
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other")))
      (perspective-switch editor other)
      (let ((u (editor-active-document editor)))
        ;; a.lisp is open in main: it is moved here, not opened again.
        (find-file-named u "T:a.lisp" nil)
        (is (eq (doc-perspective a) other))
        (is (eq (editor-active-document editor) a))
        (is (fake-shown a))
        (is-equal (fake-last-message a) "a.lisp brought over from main")
        (is-equal (perspective-documents main) (list b))
        (is-equal (perspective-documents other) (list u a))
        (is-equal (count "a.lisp" (live-documents editor) :key #'doc-name :test #'equal) 1)
        ;; Back in main, b is there and a is not: a is brought back the
        ;; same way, after its window.
        (perspective-switch editor main)
        (is (eq (editor-active-document editor) b))
        (find-file-named b "T:a.lisp" nil)
        (is (eq (doc-perspective a) main))
        (is-equal (perspective-documents main) (list b a))
        (is-equal (perspective-documents other) (list u))
        (is-equal (fake-last-message a) "a.lisp brought over from other")))))

;;; --- the project directory ---------------------------------------------------

(deftest the-project-directory-is-where-prompts-start
  (let* ((dir (temp-path "persp-project"))
         (dir/ (concatenate 'string dir "/")))
    (ensure-directories-exist (concatenate 'string dir/ "x"))
    (unwind-protect
         (multiple-value-bind (editor a b) (persp-fixture)
           (declare (ignore b))
           (let ((main (current-perspective editor))
                 (u (open-document editor nil)))
             (doc-activate u)
             ;; Without a root an unnamed buffer starts nowhere; a file
             ;; buffer in its file's directory.
             (is-equal (doc-directory u) "")
             (is-equal (doc-directory a) "T:")
             (is-equal (doc-prompt-directory u) "")
             ;; The command: a directory that is not there is refused.
             (run-command u 'clamacs-perspective-set-directory)
             (is-equal (fake-prompt u) "Project directory: ")
             (answer-prompt u (temp-path "no-such-persp-dir"))
             (is (search "No such directory: " (fake-last-message u)))
             (is-equal (fake-beeps u) 1)
             (is (null (perspective-root main)))
             ;; One that is: set, with a `/' after it.
             (run-command u 'clamacs-perspective-set-directory)
             (answer-prompt u dir)
             (is-equal (perspective-root main) dir/)
             (is-equal (fake-last-message u) (format nil "main: project directory ~A" dir/))
             (is-equal (doc-directory u) dir/)
             (is-equal (doc-directory a) "T:")
             ;; find-file's line is seeded with it in the unnamed buffer only.
             (is-equal (doc-prompt-directory u) dir/)
             (is-equal (doc-prompt-directory a) "")
             (run-command u 'find-file)
             (is-equal (fake-mini-text u) dir/)
             (type-keys u "C-g")
             ;; The prompt offers the root; an empty answer takes it away.
             (run-command u 'clamacs-perspective-set-directory)
             (is-equal (fake-prompt u) (concatenate 'string "Project directory: " dir/))
             (answer-prompt u "")
             (is (null (perspective-root main)))
             (is-equal (fake-last-message u) "main has no project directory now")))
      (ignore-errors (delete-file (concatenate 'string dir/ "x")))
      (ignore-errors (delete-file dir)))))

(deftest open-project-names-the-perspective-after-the-directory
  (let* ((dir (temp-path "persp-open-project"))
         (dir/ (concatenate 'string dir "/")))
    (ensure-directories-exist (concatenate 'string dir/ "x"))
    (unwind-protect
         (multiple-value-bind (editor a b) (persp-fixture)
           (declare (ignore b))
           (is-equal (project-name-from-directory "Work:src/") "src")
           (is-equal (project-name-from-directory "Work:") "Work")
           (is-equal (project-name-from-directory "/home/me/proj/") "proj")
           (is-equal (project-name-from-directory "/") "/")
           (run-command a 'clamacs-perspective-open-project)
           (answer-prompt a dir)
           (let ((p (find-perspective editor "clamacs-test-persp-open-project")))
             (is p)
             (is (eq (current-perspective editor) p))
             (is-equal (perspective-root p) dir/)
             (is (not (fake-shown a)))
             (let ((u (editor-active-document editor)))
               (is-equal (doc-name u) *unnamed*)
               (is-equal (fake-last-message u)
                         (format nil "New project clamacs-test-persp-open-project (~A)" dir/))
               (is-equal (doc-directory u) dir/)
               ;; Again: the same perspective, switched to.
               (perspective-switch editor (find-perspective editor "main"))
               (run-command a 'clamacs-perspective-open-project)
               (answer-prompt a dir/)
               (is (eq (current-perspective editor) p))
               (is (eq (editor-active-document editor) u))
               (is-equal (fake-last-message u)
                         (format nil "Project clamacs-test-persp-open-project (~A)" dir/))
               (is-equal (length (editor-perspectives editor)) 2))
             ;; An empty answer is refused.
             (run-command (editor-active-document editor) 'clamacs-perspective-open-project)
             (answer-prompt (editor-active-document editor) "")
             (is-equal (fake-last-message (editor-active-document editor)) "A project needs a directory")))
      (ignore-errors (delete-file (concatenate 'string dir/ "x")))
      (ignore-errors (delete-file dir)))))

(deftest a-switch-tells-amilisp-the-project-directory
  (multiple-value-bind (a tr wire) (make-wired-fake "(foo)|")
    (let* ((editor (doc-editor a))
           (main (current-perspective editor))
           (work (make-perspective editor "work" :root "T:work/")))
      (doc-activate a)
      (is-equal (root-form "T:work/")
                "(cl:setf cl:*default-pathname-defaults* (cl:pathname \"T:work/\"))")
      (is-equal (root-form "/home/me/a\"b/")
                "(cl:setf cl:*default-pathname-defaults* (cl:pathname \"/home/me/a\\\"b/\"))")
      ;; Not connected: nothing goes out and no amilisp is started.
      (perspective-switch editor work)
      (is (null (fake-sent-commands tr)))
      (is-equal (fake-transport-launched tr) 0)
      (perspective-switch editor main)
      ;; Connected: a perspective with a root is told, one without leaves
      ;; the directory as it is.
      (is (wire-find-port wire))
      (perspective-switch editor work)
      (is-equal (fake-sent-commands tr)
                '("EVAL (cl:setf cl:*default-pathname-defaults* (cl:pathname \"T:work/\"))"))
      (fake-deliver tr 0 "#P\"T:work/\"")
      (perspective-switch editor main)
      (is-equal (length (fake-sent-commands tr)) 1)
      ;; A failed reply is fetched and dropped: nothing is said about it.
      (perspective-switch editor work)
      (let ((u (editor-active-document editor)))
        (is-equal (fake-last-message u) "Perspective: work")
        (fake-deliver tr 10 "")
        (is-equal (fake-last-sent tr) "LASTRESULT")
        (fake-deliver tr 0 "No such directory")
        (is-equal (fake-last-message u) "Perspective: work")
        (is (null (wire-inflight wire)))
        ;; Setting the directory of the perspective in front tells it too.
        (let* ((dir (temp-path "persp-tell"))
               (dir/ (concatenate 'string dir "/")))
          (ensure-directories-exist (concatenate 'string dir/ "x"))
          (unwind-protect
               (progn
                 (run-command u 'clamacs-perspective-set-directory)
                 (answer-prompt u dir)
                 (is-equal (perspective-root work) dir/)
                 (is-equal (fake-last-sent tr) (concatenate 'string "EVAL " (root-form dir/)))
                 (fake-deliver tr 0 ""))
            (ignore-errors (delete-file (concatenate 'string dir/ "x")))
            (ignore-errors (delete-file dir))))))))

(deftest the-directory-told-is-noted-in-an-open-repl
  (multiple-value-bind (a repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (let* ((editor (doc-editor a))
           (work (make-perspective editor "work" :root "T:work/")))
      ;; The REPL is a tool buffer: shown in both perspectives.
      (perspective-switch editor work)
      (is (doc-shown-p repl))
      (is-equal (fake-last-sent tr) (concatenate 'string "EVAL " (root-form "T:work/")))
      (is (search (format nil "; default directory T:work/ (perspective work)~%") (transcript repl)))
      (fake-deliver tr 0 "")
      ;; The prompt is still there to type at.
      (is (repl-window-input-start (doc-repl repl))))))

;;; --- the file ---------------------------------------------------------------------

(deftest the-perspective-files-are-chosen-when-the-editor-loads
  (let ((*features* (cons :amigaos *features*)))
    (is-equal (default-perspective-files)
              '("ENV:Clamacs/perspectives.cfg" "ENVARC:Clamacs/perspectives.cfg")))
  #-amigaos
  (let ((*features* (remove :amigaos *features*)))
    (is-equal (default-perspective-files)
              (list (namestring (merge-pathnames ".clamacs-perspectives.cfg"
                                                 (user-homedir-pathname)))))))

(deftest the-file-round-trips
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore a))
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other" :root "Work:other/")))
      (setf (perspective-root main) "T:")
      (doc-activate b)
      (perspective-switch editor other)
      (persp-doc editor "c.lisp" "Work:other/c.lisp")
      (persp-doc editor "*clamacs-repl*")                 ; a tool: not recorded
      (open-document editor nil)                           ; unnamed: not recorded
      (let ((text (perspectives-text editor)))
        (is-equal text
                  (lines *perspectives-header*
                         "perspective main" "root T:"
                         "file T:a.lisp" "file T:b.lisp" "active T:b.lisp"
                         "perspective other" "root Work:other/"
                         "file Work:other/c.lisp"
                         "current other" ""))
        (multiple-value-bind (entries current) (perspectives-parse text)
          (is-equal current "other")
          (is-equal entries
                    '((:name "main" :root "T:" :files ("T:a.lisp" "T:b.lisp") :active "T:b.lisp")
                      (:name "other" :root "Work:other/" :files ("Work:other/c.lisp") :active nil))))))))

(deftest the-parser-skips-what-it-cannot-read
  (multiple-value-bind (entries current)
      (perspectives-parse (lines "; a comment" "# another" ""
                                 "file before/any.lisp"                 ; before a perspective: dropped
                                 "perspective  spaced name "
                                 "ROOT /tmp"                            ; the keyword in any case; a / added
                                 "file /tmp/x.lisp"
                                 "file"                                 ; no value: dropped
                                 "junk line"
                                 (format nil "file /tmp/y.lisp~C" #\Return)
                                 "perspective"                          ; no name: dropped, with its lines
                                 "file /tmp/z.lisp"
                                 "current spaced name"))
    (is-equal current "spaced name")
    (is-equal entries '((:name "spaced name" :root "/tmp/" :files ("/tmp/x.lisp" "/tmp/y.lisp") :active nil))))
  (is (null (perspectives-parse "")))
  ;; A current line naming nothing is handed over as it is; the restore
  ;; falls back to the first perspective.
  (is-equal (nth-value 1 (perspectives-parse "current nobody")) "nobody"))

(deftest save-writes-every-file-and-restore-reads-them-back
  (let* ((dir (temp-path "persp-dir"))
         (env (concatenate 'string dir "/env/perspectives.cfg"))
         (envarc (concatenate 'string dir "/envarc/perspectives.cfg"))
         (one (temp-file "persp-one.lisp" "(one)"))
         (two (temp-file "persp-two.lisp" "(two)"))
         (gone (temp-path "persp-gone.lisp")))
    (let ((*perspective-files* (list env envarc)))
      (unwind-protect
           (progn
             ;; Nothing to restore yet.
             (let ((editor (make-fake-editor)))
               (is (null (perspective-restore editor)))
               (is (null (perspectives-read)))
               (let ((doc (make-fake "|" :editor editor)))
                 (run-command doc 'clamacs-perspective-restore)
                 (is-equal (fake-last-message doc) (format nil "No perspectives file (~A)" env))
                 (is-equal (fake-beeps doc) 1)
                 ;; Save: two perspectives, three files, one of which will
                 ;; be gone.
                 (let ((editor2 (make-fake-editor)))
                   (let ((d1 (open-document editor2 one))
                         (work (make-perspective editor2 "work" :root (concatenate 'string dir "/"))))
                     (doc-activate d1)
                     (perspective-switch editor2 work)
                     (let ((d2 (open-document editor2 two)))
                       (persp-doc editor2 "gone.lisp" gone)
                       (doc-activate d2)
                       (run-command d2 'clamacs-perspective-save)
                       (is-equal (fake-last-message d2) (format nil "Saved 2 perspective(s) to ~A" envarc))
                       (is-equal (read-file-text env) (read-file-text envarc))
                       (is (search "current work" (read-file-text env)))
                       (is (search (format nil "active ~A" two) (read-file-text env))))))))
             ;; Restore into a fresh editor: the perspectives made, the
             ;; files opened, the missing one skipped, `work' in front with
             ;; its recorded document active, main's windows hidden.
             (let ((editor (make-fake-editor)))
               (is (perspective-restore-at-start editor))
               (is-equal (perspective-names editor) '("main" "work"))
               (is-equal (perspective-name (current-perspective editor)) "work")
               (is-equal (perspective-root (find-perspective editor "work")) (concatenate 'string dir "/"))
               (is-equal (mapcar #'doc-path (live-documents editor)) (list one two))
               (is-equal (doc-path (editor-active-document editor)) two)
               (is-equal (fake-shown-names editor) '("clamacs-test-persp-two.lisp"))
               (is-equal (shown-names editor) '("clamacs-test-persp-two.lisp"))
               (let ((d1 (find-document-by-path editor one)))
                 (is (not (fake-shown d1)))
                 (is (eq (doc-perspective d1) (find-perspective editor "main")))
                 ;; Back in main: its file is shown and active.
                 (perspective-switch editor (find-perspective editor "main"))
                 (is (eq (editor-active-document editor) d1))
                 (is (fake-shown d1))))
             ;; A restore into a running editor merges: a file already open
             ;; is moved, nothing is opened twice, and the message counts.
             (let* ((editor (make-fake-editor))
                    (d2 (open-document editor two)))
               (doc-activate d2)
               (run-command d2 'clamacs-perspective-restore)
               (is-equal (perspective-names editor) '("main" "work"))
               (is (eq (doc-perspective d2) (find-perspective editor "work")))
               (is-equal (length (live-documents editor)) 2)
               (is (eq (editor-active-document editor) d2))
               (is-equal (fake-last-message d2) "Restored: 1 perspective(s) made, 1 file(s) opened, 1 missing"))
             ;; The quit keeps the file in step once it exists: a third
             ;; perspective made after the save is in it afterwards.
             (let ((editor (make-fake-editor)))
               (perspective-restore editor)
               (make-perspective editor "later")
               (let ((doc (editor-active-document editor)))
                 (run-command doc 'kill-emacs)
                 (is (quit-requested editor)))
               (is (search "perspective later" (read-file-text env)))
               (is (search "perspective later" (read-file-text envarc))))
             ;; Without a file nothing is written at a quit.
             (delete-file env)
             (delete-file envarc)
             (let ((editor (make-fake-editor)))
               (make-fake "|" :editor editor)
               (run-command (editor-active-document editor) 'kill-emacs)
               (is (quit-requested editor))
               (is (null (probe-file env)))))
        (delete-quietly env)
        (delete-quietly envarc)
        (delete-quietly one)
        (delete-quietly two)))))

(deftest a-restore-that-opens-nothing-leaves-the-start-to-the-caller
  (let ((file (temp-file "persp-empty.cfg" (lines "perspective main" "file T:no-such-file-at-all.lisp"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             ;; The perspective is made, entered empty, and gets its unnamed
             ;; buffer -- so the editor has a document after all.
             (is (perspective-restore-at-start editor))
             (is-equal (perspective-names editor) '("main"))
             (is-equal (doc-name (editor-active-document editor)) *unnamed*)
             ;; An empty file makes nothing: the caller opens the buffer.
             (write-file-text file "")
             (let ((editor (make-fake-editor)))
               (is (not (perspective-restore-at-start editor)))
               (is (null (live-documents editor)))))
        (delete-quietly file)))))

(deftest a-restore-into-the-perspective-in-front-activates-the-recorded-document
  (let* ((one (temp-file "persp-front-one.lisp" "(one)"))
         (two (temp-file "persp-front-two.lisp" "(two)"))
         (file (temp-file "persp-front.cfg"
                          (lines "perspective main" (format nil "file ~A" one) (format nil "file ~A" two)
                                 (format nil "active ~A" one) "current main"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             ;; main is in front from the start, so the restore's switch
             ;; would do nothing -- and the files opened each took the
             ;; keyboard as they came, the last of them last.  The recorded
             ;; one must have it afterwards all the same (the drive's
             ;; second editor found this, 2026-10-15).
             (make-fake "|" :editor editor)
             (is (perspective-restore editor))
             (is-equal (doc-path (editor-active-document editor)) one)
             (is-equal (perspective-name (current-perspective editor)) "main")
             (is (every #'fake-shown (live-documents editor))))
        (delete-quietly file)
        (delete-quietly one)
        (delete-quietly two)))))

;;; --- the menu and the port -----------------------------------------------------

(deftest the-perspectives-group-lists-and-picks
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((main (current-perspective editor))
          (other (make-perspective editor "other")))
      (is-equal (dynamic-menu editor :perspectives) (list (cons "main" main) (cons "other" other)))
      (is (eq (nth-value 1 (dynamic-menu editor :perspectives)) main))
      (is-equal (editor-dynamic-menu-lines editor :perspectives) '("> main" "  other"))
      (is (dynamic-menu-pick editor :perspectives other))
      (is (eq (current-perspective editor) other))
      (is-equal (editor-dynamic-menu-lines editor :perspectives) '("  main" "> other"))
      (is (not (dynamic-menu-pick editor :perspectives :nothing)))
      (is (not (dynamic-menu-pick editor :perspectives (%make-perspective "stranger"))))
      ;; By label, as the frontends pick.
      (is (editor-dynamic-menu-pick editor :perspectives "main"))
      (is (eq (editor-active-document editor) a))
      (is (not (editor-dynamic-menu-pick editor :perspectives "nobody")))
      ;; The Close item follows the count.
      (is (menu-item-enabled-p editor (menu-find 'clamacs-perspective-close)))
      (perspective-close editor other)
      (is (not (menu-item-enabled-p editor (menu-find 'clamacs-perspective-close)))))))

(deftest perspectives-verb-lists-and-picks
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "PERSPECTIVES") '(0 "> main"))
      (is-equal (port editor "PERSPECTIVES nobody") '(0 "no such perspective"))
      (make-perspective editor "work")
      (is-equal (port editor "PERSPECTIVES") (list 0 (lines "> main" "  work")))
      (is-equal (port editor "PERSPECTIVES work") '(0 ""))
      (is-equal (perspective-name (current-perspective editor)) "work")
      (is-equal (port editor "PERSPECTIVES") (list 0 (lines "  main" "> work")))
      ;; The sample buffer is hidden now; the port's active document is
      ;; the unnamed buffer of `work'.
      (is-equal (port editor "GETNAME") (list 0 *unnamed*))
      (is (not (fake-shown doc)))
      (is-equal (port editor "BUFFERS") (list 0 (format nil "> ~A" *unnamed*)))
      (is-equal (port editor "PERSPECTIVES main") '(0 ""))
      (is-equal (port editor "GETNAME") '(0 "sample.lisp"))
      ;; The label is matched exactly.
      (is-equal (port editor "PERSPECTIVES MAIN") '(0 "no such perspective"))
      ;; A file open in a perspective not in front: OPEN brings it over,
      ;; as find-file does -- a window cannot be in two places.
      (is-equal (port editor "PERSPECTIVES work") '(0 ""))
      (is (not (fake-shown doc)))
      (is-equal (port editor "OPEN FILE Clamacs:verify/realamiga/sample.lisp") '(0 ""))
      (is (fake-shown doc))
      (is (eq (doc-perspective doc) (find-perspective editor "work")))
      (is-equal (port editor "GETNAME") '(0 "sample.lisp"))
      (is (member "> sample.lisp" (split-lines (second (port editor "BUFFERS"))) :test #'string=))
      ;; Main is empty now: the switch back opens an unnamed buffer there.
      (is-equal (port editor "PERSPECTIVES main") '(0 ""))
      (is (not (equal (port editor "GETNAME") '(0 "sample.lisp"))))
      (is (not (fake-shown doc))))))

;;; --- the status line's part ---------------------------------------------------

(deftest the-status-line-names-the-perspective-once-there-are-two
  ;; What both frontends put after the buffer's name: nothing while there
  ;; is one perspective, ` [NAME]' of the one in front from the second on
  ;; -- the one DOC is shown in, so a hidden document's never shows.
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (is-equal (status-perspective a) "")
    (let ((work (make-perspective editor "work")))
      (is-equal (status-perspective a) " [main]")
      (perspective-switch editor work :say nil)
      (is-equal (status-perspective a) " [work]")
      (is-equal (status-perspective (editor-active-document editor)) " [work]")
      (perspective-close editor work)
      (is-equal (status-perspective a) ""))))
