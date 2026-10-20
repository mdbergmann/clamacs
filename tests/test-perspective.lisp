;;;; test-perspective.lisp -- projects on the fake frontend
;;;; (specs/clamacs-perspectives.md): the scratch set, who belongs, what is
;;;; shown, the switch, the rules that keep a window on the screen, open
;;;; and recent projects, the commands and their prompts, the naming, the
;;;; folder, the file, the two menu groups and the port's PROJECTS and
;;;; RECENT verbs.

(in-package :clamacs)

(defun persp-doc (editor name &optional path)
  "A fake document called NAME, showing PATH, on EDITOR -- named at its
making, as the editor makes its documents, since that is when a document
joins a perspective or, as a tool buffer, none."
  (make-instance 'fake-document :editor editor :name name :path path
                                :lisp-mode t :mirror (make-mirror)))

(defun persp-fixture ()
  "An editor with two file buffers outside any project, the first active:
\(values editor a b)."
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

(defun make-temp-dir (name)
  "A directory under the temp path, made: (values dir dir/)."
  (let* ((dir (temp-path name))
         (dir/ (concatenate 'string dir "/")))
    (ensure-directories-exist (concatenate 'string dir/ "x"))
    (values dir dir/)))

(defun delete-temp-dir (dir)
  (let ((dir/ (concatenate 'string dir "/")))
    (dolist (file (ignore-errors (directory (concatenate 'string dir/ "*.*"))))
      (ignore-errors (delete-file file)))
    (ignore-errors (delete-file dir))))

;;; --- the scratch set: who belongs, and what is shown ------------------------

(deftest an-editor-starts-in-the-scratch-set-and-its-sources-join-it
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor)))
      (is (perspective-scratch-p scratch))
      (is (not (perspective-project-p scratch)))
      (is-equal (perspective-names editor) '("scratch"))
      (is-equal (perspective-label scratch) "(no project)")
      (is (eq (scratch-perspective editor) scratch))
      (is (eq (doc-perspective a) scratch))
      (is (eq (doc-perspective b) scratch))
      (is-equal (perspective-documents scratch) (list a b))
      (is (null (perspective-root scratch)))
      ;; No project: nothing in the status line, nothing open or recent.
      (is-equal (status-perspective a) "")
      (is (null (open-projects editor)))
      (is (null (recent-projects editor)))
      (is-equal (project-cycle editor) (list scratch))
      ;; A tool buffer belongs to none and is shown in every project.
      (let ((repl (persp-doc editor "*clamacs-repl*")))
        (is (null (doc-perspective repl)))
        (is (doc-shown-p repl))
        (is (not (member repl (perspective-documents scratch))))
        ;; ... until a save gives it a file: then it is a source and joins.
        (visit-path repl "T:repl-saved.lisp")
        (is (eq (doc-perspective repl) scratch))
        (is-equal (perspective-documents scratch) (list a b repl)))
      ;; Every document is shown while there is no project.
      (is-equal (shown-names editor) '("a.lisp" "b.lisp" "repl-saved.lisp"))
      (is (every #'fake-shown (live-documents editor))))))

(deftest a-closed-document-leaves-its-perspective
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor)))
      (close-document b nil)
      (is-equal (perspective-documents scratch) (list a))
      (is-equal (perspective-live-documents scratch) (list a))
      ;; The last one too; with no project nothing else happens (the
      ;; frontend's loop sees the last window go, as before).
      (close-document a nil)
      (is (null (perspective-documents scratch)))
      (is (eq (current-perspective editor) scratch))
      (is (null (live-documents editor)))
      ;; Empty, the scratch set is not in the cycle.
      (is (null (project-cycle editor))))))

;;; --- switching -----------------------------------------------------------------

(deftest a-switch-shows-the-new-project-and-hides-the-old
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor))
          (other (make-perspective editor "other" :root "T:other/")))
      (is-equal (perspective-names editor) '("scratch" "other"))
      (is (perspective-open other))
      (is-equal (open-projects editor) (list other))
      ;; Entered empty: an unnamed buffer opens in it and takes the keyboard.
      (doc-activate b)
      (is (eq (perspective-switch editor other) other))
      (is (eq (current-perspective editor) other))
      (let ((u (editor-active-document editor)))
        (is-equal (doc-name u) *unnamed*)
        (is (eq (doc-perspective u) other))
        (is-equal (perspective-documents other) (list u))
        (is-equal (fake-last-message u) "Project: other (T:other/)")
        (is-equal (status-perspective u) " [other]")
        ;; The scratch set remembered its active document and hid its
        ;; windows; the project's are shown.
        (is (eq (perspective-active scratch) b))
        (is-equal (shown-names editor) (list *unnamed*))
        (is-equal (fake-shown-names editor) (list *unnamed*))
        (is (not (doc-shown-p a)))
        (is (not (fake-shown a)))
        ;; Back: the remembered document is activated, the other hidden,
        ;; and the message says there is no project.
        (perspective-switch editor scratch)
        (is (eq (editor-active-document editor) b))
        (is-equal (fake-activations b) 2)
        (is-equal (shown-names editor) '("a.lisp" "b.lisp"))
        (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
        (is (not (fake-shown u)))
        (is-equal (fake-last-message b) "No project")
        (is-equal (status-perspective b) "")
        ;; Switching to the one in front does nothing.
        (perspective-switch editor scratch)
        (is-equal (fake-activations b) 2)))))

(deftest a-tool-buffer-stays-shown-across-a-switch
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore a b))
    (let ((repl (persp-doc editor "*clamacs-repl*"))
          (other (make-perspective editor "other" :root "T:other/")))
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
        (is (not (buffer-menu-pick editor (first (perspective-documents (scratch-perspective editor))))))))))

(deftest closing-the-last-buffer-in-front-brings-another-set-in-front
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor))
          (other (make-perspective editor "other" :root "T:other/")))
      (perspective-switch editor other)
      (let ((u (editor-active-document editor)))
        ;; C-x k on the only buffer of `other': the scratch set comes
        ;; back, with its documents shown and the remembered one active.
        (run-command u 'kill-buffer)
        (is (doc-closing u))
        (is (eq (current-perspective editor) scratch))
        (is (eq (editor-active-document editor) a))
        (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
        (is-equal (fake-last-message a) "No project")
        ;; `other' stays open, empty; entered again it gets a buffer again.
        (is (member other (editor-perspectives editor)))
        (is (perspective-open other))
        (is (null (perspective-live-documents other)))
        (perspective-switch editor other)
        (is-equal (doc-name (editor-active-document editor)) *unnamed*)
        (is (not (eq (editor-active-document editor) u)))))))

(deftest a-question-about-a-hidden-buffer-is-asked-in-front-of-it
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((scratch (current-perspective editor))
          (other (make-perspective editor "other" :root "T:other/")))
      (type-text a "x")
      (is (doc-modified-p a))
      (perspective-switch editor other)
      (is (not (fake-shown a)))
      ;; The quit closes every window; a's question brings the scratch
      ;; set in front first, and the answer closes it.
      (setf (fake-answers a) '(:discard))
      (let ((u (editor-active-document editor)))
        (run-command u 'save-buffers-kill-emacs)
        (is (quit-requested editor))
        (is-equal (length (fake-asked a)) 1)
        (is (null (live-documents editor)))
        (is (eq (perspective-of-document editor a) scratch))))))

;;; --- the commands ---------------------------------------------------------------

(deftest the-switch-command-completes-over-open-and-recent-projects
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((work (make-perspective editor "work" :root "T:work/"))
          (old (make-perspective editor "old" :root "T:old/" :open nil)))
      (is (perspective-recent-p old))
      (is-equal (recent-projects editor) (list old))
      (is-equal (project-choices editor :recent t) '("(no project)" "work" "old"))
      (is-equal (project-choices editor) '("(no project)" "work"))
      (run-command a 'clamacs-project-switch)
      (is-equal (fake-mini-label a) "Project: ")
      ;; TAB completes over the names.
      (doc-set-minibuffer-text a "w")
      (type-keys a "TAB")
      (is-equal (fake-mini-text a) "work")
      (type-keys a "RET")
      (is (eq (current-perspective editor) work))
      (is (not (fake-shown a)))
      (let ((u (editor-active-document editor)))
        (is-equal (fake-last-message u) "Project: work (T:work/)")
        ;; The one in front: nothing happens.
        (run-command u 'clamacs-project-switch)
        (answer-prompt u "work")
        (is-equal (fake-last-message u) "Already in work")
        ;; An unknown name is refused: no project is made at the prompt.
        (run-command u 'clamacs-project-switch)
        (answer-prompt u "nobody")
        (is-equal (fake-last-message u) "No project called nobody")
        (is-equal (fake-beeps u) 1)
        (run-command u 'clamacs-project-switch)
        (answer-prompt u "  ")
        (is-equal (fake-last-message u) "A project needs a name")
        (is-equal (fake-beeps u) 2)
        ;; The scratch set's own name is no project.
        (run-command u 'clamacs-project-switch)
        (answer-prompt u "scratch")
        (is-equal (fake-last-message u) "No project called scratch")
        (is-equal (perspective-names editor) '("scratch" "work" "old"))
        ;; A recent project: opened.
        (run-command u 'clamacs-project-switch)
        (answer-prompt u "old")
        (is (eq (current-perspective editor) old))
        (is (perspective-open old))
        (is (null (recent-projects editor)))
        (is-equal (fake-last-message (editor-active-document editor)) "Project: old (T:old/)")
        ;; Back out of any project, by its label.
        (run-command (editor-active-document editor) 'clamacs-project-switch)
        (answer-prompt (editor-active-document editor) "(no project)")
        (is (eq (editor-active-document editor) a))
        (is-equal (fake-last-message a) "No project")
        (run-command a 'clamacs-project-switch)
        (answer-prompt a "(no project)")
        (is-equal (fake-last-message a) "Already in (no project)")))))

(deftest next-and-previous-cycle-the-open-projects
  (multiple-value-bind (editor a b) (persp-fixture)
    (run-command a 'clamacs-project-next)
    (is-equal (fake-last-message a) "No other project")
    (is (not (menu-state-projects (menu-state editor))))
    (is (not (menu-item-enabled-p editor (menu-find 'clamacs-project-next))))
    (make-perspective editor "two" :root "T:two/")
    (make-perspective editor "three" :root "T:three/")
    ;; A recent project is not in the cycle.
    (make-perspective editor "later" :root "T:later/" :open nil)
    (is-equal (mapcar #'perspective-name (project-cycle editor)) '("scratch" "two" "three"))
    (is (menu-state-projects (menu-state editor)))
    (is (menu-item-enabled-p editor (menu-find 'clamacs-project-next)))
    (run-command a 'clamacs-project-next)
    (is-equal (perspective-name (current-perspective editor)) "two")
    (run-command (editor-active-document editor) 'clamacs-project-next)
    (is-equal (perspective-name (current-perspective editor)) "three")
    (run-command (editor-active-document editor) 'clamacs-project-next)
    (is (perspective-scratch-p (current-perspective editor)))
    (is-equal (fake-last-message a) "No project")
    (run-command (editor-active-document editor) 'clamacs-project-previous)
    (is-equal (perspective-name (current-perspective editor)) "three")
    ;; The scratch set leaves the cycle once it has no buffers: its two
    ;; are closed while hidden, and next from three goes to two.
    (close-document a nil)
    (close-document b nil)
    (is-equal (mapcar #'perspective-name (project-cycle editor)) '("two" "three"))
    (run-command (editor-active-document editor) 'clamacs-project-next)
    (is-equal (perspective-name (current-perspective editor)) "two")))

(deftest rename-is-for-a-project-and-refuses-empty-and-taken-names
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (run-command a 'clamacs-project-rename)
    (is (not (minibuffer-open-p a)))
    (is-equal (fake-last-message a) "Not in a project")
    (is-equal (fake-beeps a) 1)
    (make-perspective editor "work" :root "T:work/")
    (let ((other (make-perspective editor "other" :root "T:other/")))
      (perspective-switch editor other)
      (let ((u (editor-active-document editor)))
        (run-command u 'clamacs-project-rename)
        (is-equal (fake-prompt u) "Rename project to: other")
        (answer-prompt u "work")
        (is-equal (fake-last-message u) "There is a project called work already")
        (run-command u 'clamacs-project-rename)
        (answer-prompt u "")
        (is-equal (fake-last-message u) "A project needs a name")
        (run-command u 'clamacs-project-rename)
        (answer-prompt u "scratch")
        (is-equal (fake-last-message u) "There is a project called scratch already")
        (is-equal (fake-beeps u) 3)
        (run-command u 'clamacs-project-rename)
        (answer-prompt u " proj ")
        (is-equal (fake-last-message u) "Renamed other to proj")
        (is-equal (perspective-names editor) '("scratch" "work" "proj"))
        (is-equal (status-perspective u) " [proj]")
        ;; Its own name again is fine.
        (run-command u 'clamacs-project-rename)
        (answer-prompt u "proj")
        (is-equal (fake-last-message u) "Renamed proj to proj")))))

(deftest close-switches-away-closes-the-buffers-and-keeps-the-project-recent
  (let ((c (temp-file "persp-close-c.lisp" "(c)")))
    (unwind-protect
         (multiple-value-bind (editor a b) (persp-fixture)
           (let ((scratch (current-perspective editor)))
             ;; Outside a project there is nothing to close.
             (run-command a 'clamacs-project-close)
             (is-equal (fake-last-message a) "Not in a project")
             (is-equal (fake-beeps a) 1)
             (is (not (menu-item-enabled-p editor (menu-find 'clamacs-project-close))))
             ;; A project with a buffer of its own: closed, it is recent.
             (let ((other (make-perspective editor "other" :root "T:other/")))
               (perspective-switch editor other)
               (is (menu-item-enabled-p editor (menu-find 'clamacs-project-close)))
               (let ((u (editor-active-document editor)))
                 (run-command u 'clamacs-project-close)
                 (is (doc-closing u))
                 (is (perspective-recent-p other))
                 (is (member other (editor-perspectives editor)))
                 (is-equal (recent-projects editor) (list other))
                 (is (null (open-projects editor)))
                 (is (null (perspective-pending-files other)))
                 (is (eq (current-perspective editor) scratch))
                 (is (eq (editor-active-document editor) a))
                 (is-equal (fake-last-message a) "Closed project other")
                 (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp")))
               ;; Opened again from Recent: empty, so an unnamed buffer.  An
               ;; unsaved buffer asks; a cancel keeps the project open.
               (is (dynamic-menu-pick editor :recent other))
               (is (perspective-open other))
               (let ((u (editor-active-document editor)))
                 (is-equal (doc-name u) *unnamed*)
                 (type-text u "x")
                 (setf (fake-answers u) '(:cancel))
                 (run-command u 'clamacs-project-close)
                 (is (not (doc-closing u)))
                 (is (perspective-open other))
                 ;; The question was asked in front of it, so `other' is in front.
                 (is (eq (current-perspective editor) other))
                 (is-equal (fake-last-message u) "Cancelled; other stays open")
                 ;; Discarded: it goes, and the scratch set -- its remembered
                 ;; document a -- is in front again.
                 (setf (fake-answers u) '(:discard))
                 (run-command u 'clamacs-project-close)
                 (is (doc-closing u))
                 (is (perspective-recent-p other))
                 (is (eq (editor-active-document editor) a))
                 (is (fake-shown b))
                 (is-equal (fake-last-message a) "Closed project other")
                 (is (eq (current-perspective editor) scratch)))
               ;; A file in the project: remembered on it across the close,
               ;; and opened again by the next switch into it.
               (perspective-switch editor other)
               (let ((d (open-document editor c)))
                 (doc-activate d)
                 (run-command d 'clamacs-project-close)
                 (is (doc-closing d))
                 (is-equal (perspective-pending-files other) (list c))
                 (is-equal (perspective-pending-active other) c)
                 (is (search (format nil "project other~%root T:other/~%file ~A~%active ~A~%" c c)
                             (perspectives-text editor)))
                 (perspective-switch editor other)
                 (is (not (perspective-pending-p other)))
                 (is-equal (doc-path (editor-active-document editor)) c)
                 (is-equal (fake-last-message (editor-active-document editor))
                           "Project: other (T:other/), 1 file(s) opened")))
             ;; The last open project closed with nothing outside it: the
             ;; scratch set, made now, gets an unnamed buffer.
             (let* ((editor2 (make-fake-editor))
                    (work (make-perspective editor2 "work" :root "T:work/")))
               (perspective-switch editor2 work)
               (let ((u1 (editor-active-document editor2)))
                 (is (null (scratch-perspective editor2)))
                 (is (eq (perspective-close editor2 work) t))
                 (is (doc-closing u1))
                 (is (perspective-scratch-p (current-perspective editor2)))
                 (is-equal (doc-name (editor-active-document editor2)) *unnamed*)
                 (is (not (eq (editor-active-document editor2) u1)))
                 (is (perspective-recent-p work))))))
      (delete-quietly c))))

(deftest move-buffer-puts-the-window-in-another-project
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor))
          (work (make-perspective editor "work" :root "T:work/")))
      (make-perspective editor "old" :root "T:old/" :open nil)
      ;; Into the project: the buffer hidden here, the next one active.
      (run-command a 'clamacs-project-move-buffer)
      (is-equal (fake-mini-label a) "Move buffer to project: ")
      (answer-prompt a "work")
      (is (eq (doc-perspective a) work))
      (is-equal (perspective-documents scratch) (list b))
      (is-equal (perspective-documents work) (list a))
      (is (eq (current-perspective editor) scratch))
      (is (not (fake-shown a)))
      (is (eq (editor-active-document editor) b))
      (is-equal (fake-last-message b) "a.lisp moved to work")
      ;; Already there: said so.  An unknown or a recent project: refused.
      (run-command b 'clamacs-project-move-buffer)
      (answer-prompt b "(no project)")
      (is-equal (fake-last-message b) "b.lisp is in (no project) already")
      (run-command b 'clamacs-project-move-buffer)
      (answer-prompt b "old")
      (is-equal (fake-last-message b) "No project called old")
      (is-equal (fake-beeps b) 1)
      (is (eq (doc-perspective b) scratch))
      ;; The last buffer outside any project moves: the editor follows it.
      (run-command b 'clamacs-project-move-buffer)
      (answer-prompt b "work")
      (is (eq (current-perspective editor) work))
      (is (eq (editor-active-document editor) b))
      (is-equal (perspective-documents work) (list a b))
      (is-equal (fake-shown-names editor) '("a.lisp" "b.lisp"))
      (is (null (perspective-documents scratch)))
      ;; Out of the project again, by the label.
      (run-command a 'clamacs-project-move-buffer)
      (answer-prompt a "(no project)")
      (is (eq (doc-perspective a) scratch))
      (is (not (fake-shown a)))
      (is-equal (fake-last-message b) "a.lisp moved to (no project)")
      ;; A tool buffer is refused.
      (let ((repl (persp-doc editor "*clamacs-repl*")))
        (run-command repl 'clamacs-project-move-buffer)
        (is (not (minibuffer-open-p repl)))
        (is-equal (fake-last-message repl) "*clamacs-repl* is a tool buffer, shown in every project")
        (is-equal (fake-beeps repl) 1)))))

(deftest find-file-brings-a-file-over-from-another-project
  (multiple-value-bind (editor a b) (persp-fixture)
    (let ((scratch (current-perspective editor))
          (other (make-perspective editor "other" :root "T:other/")))
      (perspective-switch editor other)
      (let ((u (editor-active-document editor)))
        ;; a.lisp is open outside: it is moved here, not opened again.
        (find-file-named u "T:a.lisp" nil)
        (is (eq (doc-perspective a) other))
        (is (eq (editor-active-document editor) a))
        (is (fake-shown a))
        (is-equal (fake-last-message a) "a.lisp brought over from (no project)")
        (is-equal (perspective-documents scratch) (list b))
        (is-equal (perspective-documents other) (list u a))
        (is-equal (count "a.lisp" (live-documents editor) :key #'doc-name :test #'equal) 1)
        ;; Back outside, b is there and a is not: a is brought back the
        ;; same way, after its window.
        (perspective-switch editor scratch)
        (is (eq (editor-active-document editor) b))
        (find-file-named b "T:a.lisp" nil)
        (is (eq (doc-perspective a) scratch))
        (is-equal (perspective-documents scratch) (list b a))
        (is-equal (perspective-documents other) (list u))
        (is-equal (fake-last-message a) "a.lisp brought over from other")))))

;;; --- the folder ----------------------------------------------------------------

(deftest the-project-folder-is-where-prompts-start
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((work (make-perspective editor "work" :root "T:work/"))
          (u (open-document editor nil)))
      (doc-activate u)
      ;; Outside a project an unnamed buffer starts nowhere; a file buffer
      ;; in its file's directory.
      (is-equal (doc-directory u) "")
      (is-equal (doc-directory a) "T:")
      (is-equal (doc-prompt-directory u) "")
      ;; In the project: the folder, in an unnamed buffer of its own.
      (perspective-switch editor work)
      (let ((v (editor-active-document editor)))
        (is-equal (doc-directory v) "T:work/")
        (is-equal (doc-prompt-directory v) "T:work/")
        (perspective-move a work)
        (is-equal (doc-directory a) "T:")
        (is-equal (doc-prompt-directory a) "")
        ;; find-file's line is seeded with it in the unnamed buffer only.
        (run-command v 'find-file)
        (is-equal (fake-mini-text v) "T:work/")
        (type-keys v "C-g")))))

(deftest a-project-is-named-after-its-asd-or-its-folder
  (is-equal (directory-last-component "Work:src/") "src")
  (is-equal (directory-last-component "Work:") "Work")
  (is-equal (directory-last-component "/home/me/proj/") "proj")
  (is-equal (directory-last-component "/") "/")
  (is-equal (project-directory "Work:sento/sento.asd") "Work:sento/")
  (is-equal (project-directory "Work:sento/sento.asd/") "Work:sento/")
  (is-equal (project-directory "Work:sento") "Work:sento/")
  (is-equal (project-directory " Work:sento/ ") "Work:sento/")
  (is (null (project-directory "")))
  (multiple-value-bind (dir dir/) (make-temp-dir "persp-named")
    (unwind-protect
         (progn
           ;; No .asd: the folder's name.  One: the system's.  Two: the
           ;; folder's again.
           (is-equal (project-name-from-directory dir/) "clamacs-test-persp-named")
           (write-file-text (concatenate 'string dir/ "sento.asd") "(defsystem \"sento\")")
           (is-equal (project-name-from-directory dir/) "sento")
           (write-file-text (concatenate 'string dir/ "sento-tests.asd") "(defsystem \"sento-tests\")")
           (is-equal (project-name-from-directory dir/) "clamacs-test-persp-named"))
      (delete-temp-dir dir)))
  ;; A taken name gets the folder above; that taken too, a number; the
  ;; scratch set's name is always taken.
  (let ((editor (make-fake-editor)))
    (is-equal (unique-project-name editor "src" "/a/sento/src/") "src")
    (make-perspective editor "src" :root "/a/other/src/")
    (is-equal (unique-project-name editor "src" "/a/sento/src/") "src (sento)")
    (make-perspective editor "src (sento)" :root "/b/sento/src/")
    (is-equal (unique-project-name editor "src" "/a/sento/src/") "src (2)")
    (is-equal (unique-project-name editor "scratch" "/a/scratch/") "scratch (a)")
    (is-equal (unique-project-name editor "Work" "Work:") "Work")))

(deftest open-project-makes-finds-or-reopens-the-project-of-a-folder
  (let ((file (temp-path "persp-open.cfg")))
    (multiple-value-bind (dir dir/) (make-temp-dir "persp-open-project")
      (multiple-value-bind (dir2 dir2/) (make-temp-dir "persp-open-asd")
        (let ((asd (concatenate 'string dir2/ "myproj.asd"))
              (*perspective-files* (list file)))
          (write-file-text asd "(defsystem \"myproj\")")
          (unwind-protect
               (multiple-value-bind (editor a b) (persp-fixture)
                 (declare (ignore b))
                 (is (null (probe-file file)))
                 (run-command a 'clamacs-project-open)
                 (is-equal (fake-mini-label a) "Open project (folder or .asd; TAB: browse): ")
                 ;; A folder that is not there is refused.
                 (answer-prompt a (temp-path "no-such-persp-dir"))
                 (is (search "No such directory: " (fake-last-message a)))
                 (is-equal (fake-beeps a) 1)
                 (is (null (open-projects editor)))
                 ;; One that is: a new project named after it, entered, and
                 ;; the file written -- the first Open Project opts in.
                 (run-command a 'clamacs-project-open)
                 (answer-prompt a dir)
                 (let ((p (find-perspective editor "clamacs-test-persp-open-project")))
                   (is p)
                   (is (eq (current-perspective editor) p))
                   (is (perspective-open p))
                   (is-equal (perspective-root p) dir/)
                   (is (not (fake-shown a)))
                   (is (probe-file file))
                   (is (search "project clamacs-test-persp-open-project" (read-file-text file)))
                   (let ((u (editor-active-document editor)))
                     (is-equal (doc-name u) *unnamed*)
                     (is-equal (fake-last-message u)
                               (format nil "New project: clamacs-test-persp-open-project (~A)" dir/))
                     (is-equal (doc-directory u) dir/)
                     ;; Again, from outside: the same project, switched to --
                     ;; found by its folder, in any spelling of its case.
                     (is (eq (find-project-by-root editor (string-upcase dir/)) p))
                     (is (null (find-project-by-root editor "/no/such/")))
                     (perspective-switch editor (scratch-perspective editor))
                     (run-command a 'clamacs-project-open)
                     (answer-prompt a dir/)
                     (is (eq (current-perspective editor) p))
                     (is (eq (editor-active-document editor) u))
                     (is-equal (fake-last-message u)
                               (format nil "Project: clamacs-test-persp-open-project (~A)" dir/))
                     (is-equal (length (open-projects editor)) 1)
                     ;; Closed, it is recent; opened by its folder again it
                     ;; is open again.
                     (run-command u 'clamacs-project-close)
                     (is (perspective-recent-p p))
                     (run-command a 'clamacs-project-open)
                     (answer-prompt a dir)
                     (is (perspective-open p))
                     (is (eq (current-perspective editor) p))
                     (is-equal (fake-last-message (editor-active-document editor))
                               (format nil "Project: clamacs-test-persp-open-project (~A)" dir/))))
                 ;; A .asd names the project after its system; its folder
                 ;; is the same project.
                 (run-command (editor-active-document editor) 'clamacs-project-open)
                 (answer-prompt (editor-active-document editor) asd)
                 (let ((p (find-perspective editor "myproj")))
                   (is p)
                   (is-equal (perspective-root p) dir2/)
                   (is (eq (current-perspective editor) p))
                   (is-equal (fake-last-message (editor-active-document editor))
                             (format nil "New project: myproj (~A)" dir2/))
                   (run-command (editor-active-document editor) 'clamacs-project-open)
                   (answer-prompt (editor-active-document editor) dir2)
                   (is (eq (current-perspective editor) p))
                   (is-equal (length (open-projects editor)) 2))
                 ;; An empty answer opens the folder requester where the
                 ;; prompt started; cancelled, nothing happens.
                 (let ((u (editor-active-document editor)))
                   (setf (fake-answers u) (list nil))
                   (run-command u 'clamacs-project-open)
                   (answer-prompt u "")
                   (is-equal (first (fake-asked u)) (list :file "Open Project" :directory dir2/))
                   (is (not (minibuffer-open-p u)))
                   (is-equal (length (open-projects editor)) 2))
                 ;; The file holds both, their roots, the current one.
                 (let ((text (read-file-text file)))
                   (is (search "project clamacs-test-persp-open-project" text))
                   (is (search (format nil "root ~A" dir/) text))
                   (is (search (format nil "project myproj~%root ~A~%" dir2/) text))
                   (is (not (search "scratch" text)))))
            (delete-quietly file)
            (delete-temp-dir dir)
            (delete-temp-dir dir2)))))))

(deftest open-project-from-the-requester-and-from-tab-on-an-empty-line
  ;; The menu's Open Project... asks in the folder requester, as Open
  ;; File... does in the file one; at the key's prompt TAB on an empty
  ;; line opens the same requester.
  (let ((file (temp-path "persp-open-req.cfg")))
    (multiple-value-bind (dir dir/) (make-temp-dir "persp-open-requester")
      (let ((*perspective-files* (list file)))
        (unwind-protect
             (multiple-value-bind (editor a b) (persp-fixture)
               (declare (ignore b))
               ;; Cancelled: no project, no prompt, no message.
               (setf (fake-answers a) (list nil))
               (run-command a 'clamacs-project-open-requester)
               (is-equal (first (fake-asked a)) '(:file "Open Project" :directory "T:"))
               (is (null (open-projects editor)))
               (is (not (minibuffer-open-p a)))
               (is (null (fake-last-message a)))
               ;; The folder chosen (the toolkit hands it without a `/')
               ;; is the project, opened and said as at the prompt.
               (setf (fake-answers a) (list dir))
               (run-command a 'clamacs-project-open-requester)
               (let ((p (find-perspective editor "clamacs-test-persp-open-requester")))
                 (is p)
                 (is (eq (current-perspective editor) p))
                 (is-equal (perspective-root p) dir/)
                 (is-equal (fake-last-message (editor-active-document editor))
                           (format nil "New project: clamacs-test-persp-open-requester (~A)" dir/))
                 (is (probe-file file))
                 ;; TAB on the prompt's seed, a bare directory: the requester
                 ;; there, and the prompt is closed by the choice.
                 (perspective-switch editor (scratch-perspective editor))
                 (setf (fake-answers a) (list dir/))
                 (run-command a 'clamacs-project-open)
                 (is-equal (fake-mini-text a) "T:")
                 (type-keys a "TAB")
                 (is-equal (first (fake-asked a)) '(:file "Open Project" :directory "T:"))
                 (is (not (minibuffer-open-p a)))
                 (is (eq (current-perspective editor) p))
                 (is-equal (fake-last-message (editor-active-document editor))
                           (format nil "Project: clamacs-test-persp-open-requester (~A)" dir/))
                 ;; With text on the line TAB completes, as before.
                 (perspective-switch editor (scratch-perspective editor))
                 (run-command a 'clamacs-project-open)
                 (doc-set-minibuffer-text a (temp-path "persp-open-requ"))
                 (type-keys a "TAB")
                 (is (minibuffer-open-p a))
                 (is-equal (fake-mini-text a) dir/)
                 (type-keys a "RET")
                 (is (eq (current-perspective editor) p))))
          (delete-quietly file)
          (delete-temp-dir dir))))))

(deftest a-switch-tells-amilisp-the-project-folder
  (multiple-value-bind (a tr wire) (make-wired-fake "(foo)|")
    (let* ((editor (doc-editor a))
           (scratch (current-perspective editor))
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
      (perspective-switch editor scratch)
      ;; Connected: a project is told, the scratch set leaves the
      ;; directory as it is.
      (is (wire-find-port wire))
      (perspective-switch editor work)
      (is-equal (fake-sent-commands tr)
                '("EVAL (cl:setf cl:*default-pathname-defaults* (cl:pathname \"T:work/\"))"))
      (fake-deliver tr 0 "#P\"T:work/\"")
      (perspective-switch editor scratch)
      (is-equal (length (fake-sent-commands tr)) 1)
      ;; A failed reply is fetched and dropped: nothing is said about it.
      (perspective-switch editor work)
      (let ((u (editor-active-document editor)))
        ;; The switch's message names the folder the user is in now.
        (is-equal (fake-last-message u) "Project: work (T:work/)")
        (fake-deliver tr 10 "")
        (is-equal (fake-last-sent tr) "LASTRESULT")
        (fake-deliver tr 0 "No such directory")
        (is-equal (fake-last-message u) "Project: work (T:work/)")
        (is (null (wire-inflight wire)))))))

(deftest the-folder-told-is-noted-in-an-open-repl
  (multiple-value-bind (a repl tr wire) (repl-fixture)
    (declare (ignore wire))
    (let* ((editor (doc-editor a))
           (work (make-perspective editor "work" :root "T:work/")))
      ;; The REPL is a tool buffer: shown in every project.
      (perspective-switch editor work)
      (is (doc-shown-p repl))
      (is-equal (fake-last-sent tr) (concatenate 'string "EVAL " (root-form "T:work/")))
      (is (search (format nil "; default directory T:work/ (project work)~%") (transcript repl)))
      (fake-deliver tr 0 "")
      ;; The prompt is still there to type at.
      (is (repl-window-input-start (doc-repl repl))))))

;;; --- the file ---------------------------------------------------------------------

(deftest the-projects-files-are-chosen-when-the-editor-loads
  (let ((*features* (cons :amigaos *features*)))
    (is-equal (default-perspective-files)
              '("ENV:Clamacs/projects.cfg" "ENVARC:Clamacs/projects.cfg")))
  #-amigaos
  (let ((*features* (remove :amigaos *features*)))
    (is-equal (default-perspective-files)
              (list (namestring (merge-pathnames ".clamacs-projects.cfg"
                                                 (user-homedir-pathname)))))))

(deftest the-file-round-trips
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore a b))
    (let ((other (make-perspective editor "other" :root "Work:other/"))
          (old (make-perspective editor "old" :root "Work:old/" :open nil)))
      (setf (perspective-pending-files old) '("Work:old/x.lisp" "Work:old/y.lisp")
            (perspective-pending-active old) "Work:old/y.lisp")
      (perspective-switch editor other)
      (let ((c (persp-doc editor "c.lisp" "Work:other/c.lisp")))
        (persp-doc editor "*clamacs-repl*")               ; a tool: not recorded
        (open-document editor nil)                         ; unnamed: not recorded
        (doc-activate c))
      ;; The scratch set's two files are not recorded; a recent project
      ;; keeps the files it waits with.
      (let ((text (perspectives-text editor)))
        (is-equal text
                  (lines *perspectives-header*
                         "project other" "root Work:other/"
                         "file Work:other/c.lisp" "active Work:other/c.lisp"
                         "project old" "root Work:old/"
                         "file Work:old/x.lisp" "file Work:old/y.lisp" "active Work:old/y.lisp"
                         "current other" ""))
        (multiple-value-bind (entries current) (perspectives-parse text)
          (is-equal current "other")
          (is-equal entries
                    '((:name "other" :root "Work:other/" :files ("Work:other/c.lisp") :active "Work:other/c.lisp")
                      (:name "old" :root "Work:old/" :files ("Work:old/x.lisp" "Work:old/y.lisp") :active "Work:old/y.lisp"))))))))

(deftest the-parser-skips-what-it-cannot-read
  (multiple-value-bind (entries current)
      (perspectives-parse (lines "; a comment" "# another" ""
                                 "file before/any.lisp"                 ; before a project: dropped
                                 "project  spaced name "
                                 "ROOT /tmp"                            ; the keyword in any case; a / added
                                 "file /tmp/x.lisp"
                                 "file"                                 ; no value: dropped
                                 "junk line"
                                 (format nil "file /tmp/y.lisp~C" #\Return)
                                 "project"                              ; no name: dropped, with its lines
                                 "file /tmp/z.lisp"
                                 "perspective older"                    ; the keyword before the rename
                                 "root Work:older/"
                                 "current spaced name"))
    (is-equal current "spaced name")
    (is-equal entries '((:name "spaced name" :root "/tmp/" :files ("/tmp/x.lisp" "/tmp/y.lisp") :active nil)
                        (:name "older" :root "Work:older/" :files () :active nil))))
  (is (null (perspectives-parse "")))
  ;; A current line naming nothing is handed over as it is; the restore
  ;; falls back to the first project.
  (is-equal (nth-value 1 (perspectives-parse "current nobody")) "nobody"))

(deftest save-writes-every-file-and-restore-reads-them-back
  (let* ((dir (temp-path "persp-dir"))
         (env (concatenate 'string dir "/env/projects.cfg"))
         (envarc (concatenate 'string dir "/envarc/projects.cfg"))
         (one (temp-file "persp-one.lisp" "(one)"))
         (two (temp-file "persp-two.lisp" "(two)"))
         (gone (temp-path "persp-gone.lisp"))
         (layout (concatenate 'string dir "/env/windows.cfg")))
    (let ((*perspective-files* (list env envarc))
          (*snapshot-files* (list layout)))
      (unwind-protect
           (progn
             ;; Nothing to restore yet.
             (let ((editor (make-fake-editor)))
               (is (null (perspective-restore editor)))
               (is (null (perspectives-read)))
               (let ((doc (make-fake "|" :editor editor)))
                 (run-command doc 'clamacs-project-restore)
                 (is-equal (fake-last-message doc) (format nil "No projects file (~A)" env))
                 (is-equal (fake-beeps doc) 1)
                 ;; Save: two projects, three files, one of which will be
                 ;; gone.
                 (let ((editor2 (make-fake-editor)))
                   (let ((base (make-perspective editor2 "base" :root (concatenate 'string dir "/")))
                         (work (make-perspective editor2 "work" :root (concatenate 'string dir "/env/"))))
                     (perspective-switch editor2 base)
                     (let ((d1 (open-document editor2 one)))
                       (doc-activate d1)
                       (perspective-switch editor2 work)
                       (let ((d2 (open-document editor2 two)))
                         (persp-doc editor2 "gone.lisp" gone)
                         (doc-activate d2)
                         (run-command d2 'clamacs-project-save)
                         (is-equal (fake-last-message d2) (format nil "Saved 2 project(s) to ~A" envarc))
                         (is-equal (read-file-text env) (read-file-text envarc))
                         (is (search "current work" (read-file-text env)))
                         (is (search (format nil "active ~A" two) (read-file-text env)))))))))
             ;; Restore into a fresh editor: the projects made and open,
             ;; the files opened, the missing one skipped, `work' in front
             ;; with its recorded document active, base's windows hidden.
             (let ((editor (make-fake-editor)))
               (is (perspective-restore editor))
               (is-equal (perspective-names editor) '("base" "work"))
               (is (null (recent-projects editor)))
               (is-equal (perspective-name (current-perspective editor)) "work")
               (is-equal (perspective-root (find-perspective editor "work")) (concatenate 'string dir "/env/"))
               (is-equal (mapcar #'doc-path (live-documents editor)) (list one two))
               (is-equal (doc-path (editor-active-document editor)) two)
               (is-equal (fake-shown-names editor) '("clamacs-test-persp-two.lisp"))
               (is-equal (shown-names editor) '("clamacs-test-persp-two.lisp"))
               (let ((d1 (find-document-by-path editor one)))
                 (is (not (fake-shown d1)))
                 (is (eq (doc-perspective d1) (find-perspective editor "base")))
                 ;; Back in base: its file is shown and active.
                 (perspective-switch editor (find-perspective editor "base"))
                 (is (eq (editor-active-document editor) d1))
                 (is (fake-shown d1))))
             ;; A restore into a running editor merges: a file already open
             ;; is moved, nothing is opened twice, and the message counts.
             (let* ((editor (make-fake-editor))
                    (d2 (open-document editor two)))
               (doc-activate d2)
               (run-command d2 'clamacs-project-restore)
               (is-equal (perspective-names editor) '("scratch" "base" "work"))
               (is (eq (doc-perspective d2) (find-perspective editor "work")))
               (is-equal (length (live-documents editor)) 2)
               (is (eq (editor-active-document editor) d2))
               (is-equal (fake-last-message d2) "Reopened: 2 project(s) made, 1 file(s) opened, 1 missing"))
             ;; The quit keeps the file in step: a third project made after
             ;; the save is in it afterwards -- and the windows' places go
             ;; to the layout file beside it, the hidden window's (base's,
             ;; closed on MUI) with the kept geometry, so the next start
             ;; comes up where this one was left (snapshot-autosave).
             (is (null (probe-file layout)))
             (let ((editor (make-fake-editor)))
               (perspective-restore editor)
               (make-perspective editor "later" :root "T:later/")
               (let ((doc (editor-active-document editor)))
                 (setf (fake-geometry doc) (list 30 40 500 300))
                 (run-command doc 'kill-emacs)
                 (is (quit-requested editor)))
               (is (search "project later" (read-file-text env)))
               (is (search "project later" (read-file-text envarc)))
               (let ((text (read-file-text layout)))
                 (is (search *winstore-header* text))
                 (is (search (format nil "doc1 0 11 640 200~%") text))
                 (is (search (format nil "doc2 30 40 500 300~%") text))))
             ;; Without a file and without a project nothing is written at
             ;; a quit: not the projects, not the layout.
             (delete-file env)
             (delete-file envarc)
             (delete-file layout)
             (let ((editor (make-fake-editor)))
               (make-fake "|" :editor editor)
               (run-command (editor-active-document editor) 'kill-emacs)
               (is (quit-requested editor))
               (is (null (probe-file env)))
               (is (null (probe-file layout))))
             ;; With a project and no file: both written, the project's
             ;; folder recorded.
             (let ((editor (make-fake-editor)))
               (make-fake "|" :editor editor)
               (perspective-switch editor (make-perspective editor "fresh" :root "T:fresh/"))
               (run-command (editor-active-document editor) 'kill-emacs)
               (is (quit-requested editor))
               (is (search (format nil "project fresh~%root T:fresh/~%") (read-file-text env)))
               (is (probe-file layout))))
        (delete-quietly env)
        (delete-quietly envarc)
        (delete-quietly layout)
        (delete-quietly one)
        (delete-quietly two)))))

;;; --- the start: listed as recent, not restored --------------------------------

(deftest a-start-lists-the-saved-projects-as-recent-and-the-first-switch-opens-them
  (let* ((one (temp-file "persp-start-one.lisp" "(one)"))
         (two (temp-file "persp-start-two.lisp" "(two)"))
         (file (temp-file "persp-start.cfg"
                          (lines "project main" "root /tmp/main/" (format nil "file ~A" one) (format nil "active ~A" one)
                                 "project work" "root /tmp/" (format nil "file ~A" two)
                                 "current work"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             ;; Listed: both projects recent, by name with their roots,
             ;; after a scratch set that is in front, their files waiting
             ;; -- nothing opened, and the recorded `current' not honoured:
             ;; nothing is restored at a start, nothing is ticked.
             (is-equal (perspective-list-at-start editor) 2)
             (is-equal (perspective-names editor) '("scratch" "main" "work"))
             (is (null (live-documents editor)))
             (let ((scratch (find-perspective editor "scratch"))
                   (main (find-perspective editor "main"))
                   (work (find-perspective editor "work")))
               (is (eq (editor-perspective editor) scratch))
               (is (perspective-scratch-p scratch))
               (is (not (perspective-pending-p scratch)))
               (is (perspective-recent-p main))
               (is (perspective-recent-p work))
               (is (null (open-projects editor)))
               (is-equal (recent-projects editor) (list main work))
               (is-equal (editor-dynamic-menu-lines editor :recent) '("  main" "  work"))
               (is-equal (editor-dynamic-menu-lines editor :projects) '())
               (is (perspective-pending-p main))
               (is (perspective-pending-p work))
               (is-equal (perspective-pending-files main) (list one))
               (is-equal (perspective-pending-active main) one)
               (is-equal (perspective-root work) "/tmp/")
               ;; The window a start always opened: the unnamed buffer, in
               ;; the scratch set, which the status line does not name.
               (let ((u (open-document editor nil)))
                 (doc-activate u)
                 (is (eq (current-perspective editor) scratch))
                 (is (eq (doc-perspective u) scratch))
                 (is-equal (shown-names editor) (list *unnamed*))
                 (is-equal (status-perspective u) "")
                 (is-equal (editor-dynamic-menu-lines editor :projects) '("> (no project)"))
                 (is (not (menu-item-enabled-p editor (menu-find 'clamacs-project-next))))
                 ;; The user picks work at C-x p p: its file opens into it,
                 ;; the unnamed buffer (the scratch set's) is hidden, work
                 ;; is open and waits no more.
                 (run-command u 'clamacs-project-switch)
                 (answer-prompt u "work")
                 (is (eq (current-perspective editor) work))
                 (is (perspective-open work))
                 (is (not (perspective-pending-p work)))
                 (is-equal (recent-projects editor) (list main))
                 (is-equal (mapcar #'doc-path (live-documents editor)) (list nil two))
                 (is-equal (doc-path (editor-active-document editor)) two)
                 (is-equal (fake-last-message (editor-active-document editor))
                           "Project: work (/tmp/), 1 file(s) opened")
                 (is-equal (shown-names editor) '("clamacs-test-persp-start-two.lisp"))
                 (is-equal (fake-shown-names editor) '("clamacs-test-persp-start-two.lisp"))
                 (is (not (fake-shown u)))
                 (is-equal (editor-dynamic-menu-lines editor :projects) '("  (no project)" "> work"))
                 (is-equal (editor-dynamic-menu-lines editor :recent) '("  main"))
                 ;; ... and main from the Recent submenu: its file opens, the
                 ;; recorded document has the keyboard, the scratch set's
                 ;; buffer stays hidden.
                 (is (dynamic-menu-pick editor :recent main))
                 (is (not (perspective-pending-p main)))
                 (is (null (recent-projects editor)))
                 (is-equal (doc-path (editor-active-document editor)) one)
                 (is-equal (fake-last-message (editor-active-document editor))
                           "Project: main (/tmp/main/), 1 file(s) opened")
                 (is-equal (fake-shown-names editor) '("clamacs-test-persp-start-one.lisp"))
                 (is (not (fake-shown u)))
                 (is (not (fake-shown (find-document-by-path editor two))))
                 ;; Once opened, the one in front is refused as before.
                 (run-command u 'clamacs-project-switch)
                 (answer-prompt u "main")
                 (is-equal (fake-last-message u) "Already in main")
                 (is-equal (length (live-documents editor)) 3)
                 ;; Back to the scratch set from the menu: a plain switch,
                 ;; the unnamed buffer back; and it is refused in front too.
                 (is (dynamic-menu-pick editor :projects scratch))
                 (is-equal (fake-last-message u) "No project")
                 (is-equal (fake-shown-names editor) (list *unnamed*))
                 (run-command u 'clamacs-project-switch)
                 (answer-prompt u "(no project)")
                 (is-equal (fake-last-message u) "Already in (no project)")
                 ;; The quit's write leaves the scratch set out, and names
                 ;; no current while it is in front.
                 (let ((text (perspectives-text editor)))
                   (is (not (search "scratch" text)))
                   (is (not (search (format nil "~%current ") text)))
                   (is (search (format nil "project main~%root /tmp/main/~%file ~A~%active ~A~%project work~%root /tmp/~%file ~A~%active ~A~%"
                                       one one two two)
                               text))))))
        (delete-quietly file)
        (delete-quietly one)
        (delete-quietly two)))))

(deftest a-switch-into-the-listed-project-in-front-opens-its-files
  (let* ((one (temp-file "persp-infront-one.lisp" "(one)"))
         (two (temp-file "persp-infront-two.lisp" "(two)"))
         (file (temp-file "persp-infront.cfg"
                          (lines "project main" (format nil "file ~A" one) (format nil "file ~A" two)
                                 (format nil "active ~A" one) "file T:no-such-file-at-all.lisp"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             (is-equal (perspective-list-at-start editor) 1)
             (let ((u (open-document editor nil))
                   (main (find-perspective editor "main")))
               (doc-activate u)
               ;; C-x p p main opens its files: the recorded one gets the
               ;; keyboard although the last opened took it, the missing one
               ;; is counted, and the unnamed buffer, the scratch set's, is
               ;; hidden.  A project without a root says none.
               (run-command u 'clamacs-project-switch)
               (answer-prompt u "main")
               (is (not (perspective-pending-p main)))
               (is-equal (mapcar #'doc-path (live-documents editor)) (list nil one two))
               (is-equal (doc-path (editor-active-document editor)) one)
               (is-equal (fake-last-message (editor-active-document editor))
                         "Project: main, 2 file(s) opened, 1 missing")
               (is (not (fake-shown u)))
               (is (every #'fake-shown (perspective-live-documents main)))
               ;; Files waiting on the project IN FRONT -- which a switch
               ;; otherwise leaves alone -- open too, and a file open
               ;; already is brought over, not opened twice.
               (let ((p (make-perspective editor "again" :root "T:again/")))
                 (perspective-switch editor p)
                 (is-equal (fake-last-message (editor-active-document editor)) "Project: again (T:again/)")
                 (setf (perspective-pending-files p) (list two))
                 (run-command (editor-active-document editor) 'clamacs-project-switch)
                 (answer-prompt (editor-active-document editor) "again")
                 (is (not (perspective-pending-p p)))
                 (is (eq (doc-perspective (find-document-by-path editor two)) p))
                 (is-equal (length (live-documents editor)) 4)
                 (is-equal (fake-last-message (editor-active-document editor))
                           "Project: again (T:again/), 1 file(s) opened"))))
        (delete-quietly file)
        (delete-quietly one)
        (delete-quietly two)))))

(deftest the-file-keeps-what-a-recent-project-never-opened
  (let* ((one (temp-file "persp-keep-one.lisp" "(one)"))
         (two (temp-file "persp-keep-two.lisp" "(two)"))
         (file (temp-file "persp-keep.cfg"
                          (lines "project main" (format nil "file ~A" one) (format nil "active ~A" one)
                                 "project work" (format nil "file ~A" two) "current main"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             (perspective-list-at-start editor)
             (doc-activate (open-document editor nil))
             ;; Only work entered: the quit's write must still hold main's
             ;; file and its recorded document, never opened this session --
             ;; and nothing of the scratch set, the start's.
             (perspective-switch editor (find-perspective editor "work"))
             (let ((text (perspectives-text editor)))
               (is (search (format nil "project main~%file ~A~%active ~A~%project work~%file ~A~%active ~A~%current work~%"
                                   one one two two)
                           text))
               (is (not (search "scratch" text)))
               ;; Listed again from that text, main waits as before.
               (let ((editor2 (make-fake-editor)))
                 (perspective-list-at-start editor2 text)
                 (is-equal (perspective-pending-files (find-perspective editor2 "main")) (list one))
                 (is-equal (perspective-pending-active (find-perspective editor2 "main")) one)
                 (is-equal (perspective-pending-files (find-perspective editor2 "work")) (list two))))
             ;; Restore into the running editor opens the waiting files
             ;; eagerly, and nothing waits afterwards.
             (run-command (editor-active-document editor) 'clamacs-project-restore)
             (is (not (perspective-pending-p (find-perspective editor "main"))))
             (is (perspective-open (find-perspective editor "main")))
             (is (find-document-by-path editor one))
             (is-equal (fake-last-message (editor-active-document editor))
                       "Reopened: 0 project(s) made, 1 file(s) opened"))
        (delete-quietly file)
        (delete-quietly one)
        (delete-quietly two)))))

(deftest a-start-without-a-file-or-with-an-empty-one-lists-nothing
  (let ((file (temp-path "persp-none.cfg")))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             (is (null (perspective-list-at-start editor)))
             (is (null (editor-perspectives editor)))
             ;; An empty file lists nothing and makes no scratch set either:
             ;; the editor makes it when the first buffer needs it.
             (write-file-text file "")
             (is-equal (perspective-list-at-start editor) 0)
             (is (null (editor-perspectives editor)))
             (is (null (editor-perspective editor)))
             ;; A name listed twice, or in the editor already, is one; the
             ;; scratch set comes first and is in front, and a `scratch'
             ;; entry of the file is skipped like a name in use.
             (is-equal (perspective-list-at-start editor (lines "project main" "project main")) 1)
             (is-equal (perspective-names editor) '("scratch" "main"))
             (is (perspective-scratch-p (current-perspective editor)))
             (is-equal (perspective-list-at-start editor (lines "project main" "project work"
                                                                 "project scratch" "file /tmp/x.lisp"))
                       1)
             (is-equal (perspective-names editor) '("scratch" "main" "work"))
             (is (not (perspective-pending-p (find-perspective editor "scratch")))))
        (delete-quietly file)))))

(deftest the-scratch-set-is-never-written
  (let* ((one (temp-file "persp-scratch-one.lisp" "(one)"))
         (file (temp-file "persp-scratch.cfg" (lines "project main" "root /tmp/"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             (is-equal (perspective-list-at-start editor) 1)
             ;; A file opened outside any project is not recorded: the file
             ;; keeps main as it was, with no current.
             (let ((d (open-document editor one)))
               (doc-activate d)
               (is (perspective-scratch-p (doc-perspective d)))
               (is-equal (perspectives-text editor)
                         (lines *perspectives-header* "project main" "root /tmp/" ""))
               (run-command d 'clamacs-project-save)
               (is-equal (fake-last-message d) (format nil "Saved 1 project(s) to ~A" file))
               ;; Moved into main -- opened from Recent, empty, so with an
               ;; unnamed buffer -- it is recorded there.
               (is (dynamic-menu-pick editor :recent (find-perspective editor "main")))
               (run-command d 'clamacs-project-move-buffer)
               (answer-prompt d "main")
               (is-equal (perspectives-text editor)
                         (lines *perspectives-header*
                                "project main" "root /tmp/" (format nil "file ~A" one) (format nil "active ~A" one)
                                "current main" ""))
               ;; The next start lists main again, recent, and makes a new
               ;; scratch set.
               (let ((editor2 (make-fake-editor)))
                 (is-equal (perspective-list-at-start editor2 (perspectives-text editor)) 1)
                 (is-equal (perspective-names editor2) '("scratch" "main"))
                 (is (perspective-recent-p (find-perspective editor2 "main"))))))
        (delete-quietly file)
        (delete-quietly one)))))

(deftest the-repl-title-names-the-project-in-front
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((repl (repl-open editor a)))
      ;; No project: the name alone, as the status line has it -- also
      ;; once a project exists, while the scratch set is in front.
      (is-equal (doc-name repl) "*clamacs-repl*")
      (is-equal (fake-title repl) "*clamacs-repl*")
      (let ((work (make-perspective editor "work" :root "T:work/")))
        (is-equal (fake-title repl) "*clamacs-repl*")
        (perspective-switch editor work)
        (is-equal (fake-title repl) "*clamacs-repl* [work]")
        (run-command repl 'clamacs-project-rename)
        (answer-prompt repl "proj")
        (is-equal (fake-title repl) "*clamacs-repl* [proj]")
        ;; The name stays: the Buffers menu, the window's role.
        (is-equal (doc-name repl) "*clamacs-repl*")
        (is (eq (perspective-close editor work) t))
        (is-equal (fake-title repl) "*clamacs-repl*")))))

(deftest a-restore-into-the-project-in-front-activates-the-recorded-document
  (let* ((one (temp-file "persp-front-one.lisp" "(one)"))
         (two (temp-file "persp-front-two.lisp" "(two)"))
         (file (temp-file "persp-front.cfg"
                          (lines "project main" (format nil "file ~A" one) (format nil "file ~A" two)
                                 (format nil "active ~A" one) "current main"))))
    (let ((*perspective-files* (list file)))
      (unwind-protect
           (let ((editor (make-fake-editor)))
             ;; main is listed and entered before the restore, so the
             ;; restore's switch would do nothing -- and the files opened
             ;; each took the keyboard as they came, the last of them last.
             ;; The recorded one must have it afterwards all the same (the
             ;; drive's second editor found this, 2026-10-15).
             (perspective-list-at-start editor)
             (make-fake "|" :editor editor)
             (setf (perspective-pending-files (find-perspective editor "main")) '())
             (perspective-switch editor (find-perspective editor "main"))
             (let ((u (editor-active-document editor)))
               (is (perspective-restore editor))
               (is-equal (doc-path (editor-active-document editor)) one)
               (is-equal (perspective-name (current-perspective editor)) "main")
               (is (every #'fake-shown (perspective-live-documents (find-perspective editor "main"))))
               (is (member u (perspective-live-documents (find-perspective editor "main"))))))
        (delete-quietly file)
        (delete-quietly one)
        (delete-quietly two)))))

;;; --- the menu and the port -----------------------------------------------------

(deftest the-projects-group-lists-and-picks
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (let ((scratch (current-perspective editor))
          (other (make-perspective editor "other" :root "T:other/")))
      (is-equal (dynamic-menu editor :projects) (list (cons "(no project)" scratch) (cons "other" other)))
      (is (eq (nth-value 1 (dynamic-menu editor :projects)) scratch))
      (is-equal (editor-dynamic-menu-lines editor :projects) '("> (no project)" "  other"))
      (is (dynamic-menu-pick editor :projects other))
      (is (eq (current-perspective editor) other))
      (is-equal (editor-dynamic-menu-lines editor :projects) '("  (no project)" "> other"))
      (is (not (dynamic-menu-pick editor :projects :nothing)))
      (is (not (dynamic-menu-pick editor :projects (%make-perspective "stranger"))))
      ;; By label, as the frontends pick.
      (is (editor-dynamic-menu-pick editor :projects "(no project)"))
      (is (eq (editor-active-document editor) a))
      (is (not (editor-dynamic-menu-pick editor :projects "nobody")))
      (is (not (editor-dynamic-menu-pick editor :projects "scratch")))
      ;; The Recent submenu: nothing until a project is closed; a pick
      ;; opens it and it leaves the submenu for the tail.
      (is (null (dynamic-menu editor :recent)))
      (is-equal (editor-dynamic-menu-lines editor :recent) '())
      (is (eq (perspective-close editor other) t))
      (is-equal (dynamic-menu editor :recent) (list (cons "other" other)))
      (is (null (nth-value 1 (dynamic-menu editor :recent))))
      (is-equal (editor-dynamic-menu-lines editor :recent) '("  other"))
      (is-equal (editor-dynamic-menu-lines editor :projects) '("> (no project)"))
      (is (editor-dynamic-menu-pick editor :recent "other"))
      (is (eq (current-perspective editor) other))
      (is-equal (editor-dynamic-menu-lines editor :recent) '())
      (is-equal (editor-dynamic-menu-lines editor :projects) '("  (no project)" "> other"))
      (is (not (editor-dynamic-menu-pick editor :recent "other"))))))

(deftest projects-and-recent-verbs-list-and-pick
  (multiple-value-bind (doc tr wire) (sample-doc)
    (declare (ignore tr wire))
    (let ((editor (doc-editor doc)))
      (is-equal (port editor "PROJECTS") '(0 "> (no project)"))
      (is-equal (port editor "PROJECTS nobody") '(0 "no such project"))
      (is-equal (port editor "RECENT") '(0 ""))
      (is-equal (port editor "RECENT nobody") '(0 "no such project"))
      (make-perspective editor "work" :root "T:work/")
      (is-equal (port editor "PROJECTS") (list 0 (lines "> (no project)" "  work")))
      (is-equal (port editor "PROJECTS work") '(0 ""))
      (is-equal (perspective-name (current-perspective editor)) "work")
      (is-equal (port editor "PROJECTS") (list 0 (lines "  (no project)" "> work")))
      ;; The sample buffer is hidden now; the port's active document is
      ;; the unnamed buffer of `work'.
      (is-equal (port editor "GETNAME") (list 0 *unnamed*))
      (is (not (fake-shown doc)))
      (is-equal (port editor "BUFFERS") (list 0 (format nil "> ~A" *unnamed*)))
      (is-equal (port editor "PROJECTS (no project)") '(0 ""))
      (is-equal (port editor "GETNAME") '(0 "sample.lisp"))
      ;; The label is matched exactly.
      (is-equal (port editor "PROJECTS WORK") '(0 "no such project"))
      ;; A file open outside the project: OPEN brings it over, as
      ;; find-file does -- a window cannot be in two places.
      (is-equal (port editor "PROJECTS work") '(0 ""))
      (is (not (fake-shown doc)))
      (is-equal (port editor "OPEN FILE Clamacs:verify/realamiga/sample.lisp") '(0 ""))
      (is (fake-shown doc))
      (is (eq (doc-perspective doc) (find-perspective editor "work")))
      (is-equal (port editor "GETNAME") '(0 "sample.lisp"))
      (is (member "> sample.lisp" (split-lines (second (port editor "BUFFERS"))) :test #'string=))
      ;; Nothing is left outside: the scratch set is not listed, and
      ;; closing the project puts it in Recent, where a pick reopens it.
      (is-equal (port editor "PROJECTS") '(0 "> work"))
      (is (eq (perspective-close editor (find-perspective editor "work")) t))
      (is-equal (port editor "RECENT") '(0 "  work"))
      (is-equal (port editor "PROJECTS") '(0 "> (no project)"))
      ;; The close remembered sample.lisp's path on work; this host has no
      ;; such file, so the reopened project comes up with an unnamed buffer
      ;; and the status says so.
      (is-equal (perspective-pending-files (find-perspective editor "work"))
                '("Clamacs:verify/realamiga/sample.lisp"))
      (is-equal (port editor "RECENT work") '(0 ""))
      (is-equal (port editor "RECENT") '(0 ""))
      (is-equal (port editor "GETNAME") (list 0 *unnamed*))
      (is-equal (port editor "STATUS") '(0 "Project: work (T:work/), 0 file(s) opened, 1 missing"))
      ;; The close had put the editor in the scratch set with an unnamed
      ;; buffer, which stays listed, hidden, after the reopen.
      (is-equal (port editor "PROJECTS") (list 0 (lines "  (no project)" "> work"))))))

;;; --- the status line's part ---------------------------------------------------

(deftest the-status-line-names-the-project-in-front
  ;; What both frontends put after the buffer's name: nothing outside a
  ;; project, ` [NAME]' of the project in front -- the one DOC is shown
  ;; in, so a hidden document's never shows.
  (multiple-value-bind (editor a b) (persp-fixture)
    (declare (ignore b))
    (is-equal (status-perspective a) "")
    (let ((work (make-perspective editor "work" :root "T:work/")))
      (is-equal (status-perspective a) "")
      (perspective-switch editor work :say nil)
      (is-equal (status-perspective a) " [work]")
      (is-equal (status-perspective (editor-active-document editor)) " [work]")
      (perspective-close editor work)
      (is-equal (status-perspective a) ""))))
