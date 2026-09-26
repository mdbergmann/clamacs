;;;; test-snapshot.lisp -- window positions on the fake frontend: the roles
;;;; documents get, the layout file, `clamacs-snapshot-windows' and the
;;;; port's GETWINDOW -- drive.rexx's snapshot leg, minus the second
;;;; editor, which a restore test stands in for.

(in-package :clamacs)

(defun snapshot-fixture ()
  "A wired fake showing a file, activated: (values doc editor)."
  (multiple-value-bind (doc tr wire) (make-wired-fake "(defun a ())|")
    (declare (ignore tr wire))
    (setf (doc-path doc) "T:a.lisp" (doc-name doc) "a.lisp")
    (doc-activate doc)
    (values doc (doc-editor doc))))

;;; --- roles ----------------------------------------------------------------

(deftest file-windows-take-the-lowest-free-slot
  (let* ((editor (make-fake-editor))
         (d1 (make-fake "" :editor editor))
         (d2 (open-document editor (temp-file "two.lisp" "(two)")))
         (d3 (open-document editor nil)))
    (is-equal (doc-role d1) "doc1")
    (is-equal (doc-role d2) "doc2")
    (is-equal (doc-role d3) "doc3")
    ;; A window closed and reopened takes its slot back.
    (close-document d2)
    (let ((d4 (open-document editor nil)))
      (is-equal (doc-role d4) "doc2"))
    (is-equal (doc-role (open-document editor nil)) "doc4")
    ;; find-file into the unnamed window keeps the window's role.
    (let ((path (temp-file "three.lisp" "(three)")))
      (find-file-named d3 path nil)
      (is-equal (doc-path d3) path)
      (is-equal (doc-role d3) "doc3"))))

(deftest scratch-windows-go-by-their-name
  (let* ((editor (make-fake-editor))
         (repl (ensure-scratch-document editor "*clamacs-repl*" t))
         (desc (ensure-scratch-document editor "*clamacs-description*" nil))
         (stars (ensure-scratch-document editor "**" nil)))
    (is-equal (doc-role repl) "repl")
    (is-equal (doc-role desc) "description")
    ;; A name that leaves nothing stores no place.
    (is (null (doc-role stars)))
    ;; Scratch windows never take a file slot.
    (is-equal (doc-role (open-document editor nil)) "doc1")))

;;; --- the file ---------------------------------------------------------------

;;; As for the init file (test-menu.lisp): the release compiles the FASLs with
;;; the host binary, so the choice between ENV:/ENVARC: and a file in the home
;;; directory has to be made when the editor loads, not when it is compiled.
(deftest the-snapshot-files-are-chosen-when-the-editor-loads
  (let ((*features* (cons :amigaos *features*)))
    (is-equal (default-snapshot-files)
              '("ENV:Clamacs/windows.cfg" "ENVARC:Clamacs/windows.cfg")))
  #-amigaos
  (let ((*features* (remove :amigaos *features*)))
    (let ((files (default-snapshot-files)))
      (is-equal (length files) 1)
      (is (search ".clamacs-windows.cfg" (first files))))))

(deftest snapshot-load-reads-the-first-file-that-is-there
  (let ((env (temp-file "windows-env.cfg"))
        (envarc (temp-file "windows-envarc.cfg" (lines "doc1 24 48 400 160" "repl 1 2 3 4" ""))))
    (let ((*snapshot-files* (list env envarc))
          (editor (make-fake-editor)))
      ;; ENV: missing: the ENVARC: copy is read.
      (is-equal (snapshot-load editor) 2)
      (is-equal (multiple-value-list (layout-place editor "doc1")) '(24 48 400 160))
      (is-equal (multiple-value-list (layout-place editor "repl")) '(1 2 3 4))
      (is (null (layout-place editor "doc2")))
      (is (null (layout-place editor nil)))
      ;; ENV: present: it wins, whatever ENVARC: says.
      (write-file-text env (lines "; written by drive.rexx" "" "doc1 1 1 100 50" ""))
      (is-equal (snapshot-load editor) 1)
      (is-equal (multiple-value-list (layout-place editor "doc1")) '(1 1 100 50))
      (is (null (layout-place editor "repl")))
      ;; No file at all: an empty layout, no error.
      (delete-file env)
      (delete-file envarc)
      (is-equal (snapshot-load editor) 0)
      (is (null (layout-place editor "doc1"))))))

(deftest a-stored-size-that-is-not-positive-counts-as-none
  (let ((editor (make-fake-editor)))
    (winstore-set (editor-layout editor) "doc1" 10 10 0 100)
    (winstore-set (editor-layout editor) "doc2" 10 10 100 -1)
    (winstore-set (editor-layout editor) "doc3" -5 -5 100 100)
    (is (null (layout-place editor "doc1")))
    (is (null (layout-place editor "doc2")))
    (is-equal (multiple-value-list (layout-place editor "doc3")) '(-5 -5 100 100))))

;;; --- GETWINDOW and the command: drive.rexx's leg ------------------------------

(deftest getwindow-answers-role-and-geometry
  (multiple-value-bind (doc editor) (snapshot-fixture)
    (is-equal (port editor "GETWINDOW") '(0 "doc1 0 11 640 200"))
    (setf (fake-geometry doc) (list 24 48 400 160))
    (is-equal (port editor "GETWINDOW") '(0 "doc1 24 48 400 160"))
    ;; A window that is not open has no geometry to report.
    (setf (fake-window-open doc) nil)
    (is-equal (port editor "GETWINDOW") '(0 "doc1 0 0 0 0"))
    (setf (fake-window-open doc) t)
    ;; A scratch window with no role says `-'.
    (let ((stars (ensure-scratch-document editor "**" nil)))
      (doc-activate stars)
      (is-equal (port editor "GETWINDOW") '(0 "- 0 11 640 200")))
    (is-equal (port (make-fake-editor) "GETWINDOW") '(10 "ERROR: no document is open"))))

(deftest snapshot-windows-writes-every-open-window-to-both-files
  (let* ((dir (temp-path "snapshot-dir"))
         (env (concatenate 'string dir "/env/windows.cfg"))
         (envarc (temp-file "windows-arc.cfg")))
    (let ((*snapshot-files* (list env envarc)))
      (multiple-value-bind (doc editor) (snapshot-fixture)
        (setf (fake-geometry doc) (list 24 48 400 160))
        (let ((second (open-document editor nil)))
          (setf (fake-geometry second) (list 300 100 200 150)))
        ;; The error list is open too, so a fixed window is in the snapshot.
        (run-command doc 'clamacs-show-errors)
        (is (fake-editor-diag-open editor))
        (run-command doc 'clamacs-snapshot-windows)
        (is-equal (fake-last-message doc)
                  (format nil "Saved the positions of 3 window(s) to ~A" envarc))
        (is-equal (fake-beeps doc) 0)
        ;; The drawer was made for the file, and both hold the same text.
        (let ((text (read-file-text env)))
          (is text)
          (is-equal (read-file-text envarc) text)
          (is (search (format nil "~%doc1 24 48 400 160~%") text))
          (is (search (format nil "~%doc2 300 100 200 150~%") text))
          (is (search (format nil "~%errors 10 20 300 100~%") text))
          (is-equal (char text 0) #\;))
        ;; The active window's line is what GETWINDOW says.
        (is (search (second (port editor "GETWINDOW")) (read-file-text env)))
        ;; Snapshotting again only updates the windows that are open: the
        ;; second window closed, its line stays.
        (close-document (second (live-documents editor)))
        (setf (fake-geometry doc) (list 1 2 300 300))
        (run-command doc 'clamacs-snapshot-windows)
        (let ((text (read-file-text env)))
          (is (search "doc1 1 2 300 300" text))
          (is (search "doc2 300 100 200 150" text)))
        (delete-file env)
        (delete-file envarc)))))

(deftest snapshot-windows-reports-the-file-it-could-not-write
  ;; (Not `no-such-dir': test-files relies on THAT drawer never existing.)
  (let ((bad (temp-path "snapshot-newdir/deeper/windows.cfg"))
        (good (temp-file "windows-good.cfg")))
    ;; ENSURE-DIRECTORIES-EXIST makes the drawer, so one level is fine:
    ;; make the path unwritable another way -- a file where the drawer
    ;; should be.
    (let ((blocker (temp-file "blocker" "x")))
      (let ((*snapshot-files* (list (concatenate 'string blocker "/windows.cfg") good)))
        (multiple-value-bind (doc editor) (snapshot-fixture)
          (declare (ignore editor))
          (run-command doc 'clamacs-snapshot-windows)
          (is-equal (fake-last-message doc)
                    (format nil "Cannot write ~A/windows.cfg" blocker))
          (is-equal (fake-beeps doc) 1)
          ;; The good one was written all the same.
          (is (search "doc1 0 11 640 200" (read-file-text good)))))
      (delete-file blocker)
      (delete-file good))
    (let ((*snapshot-files* (list bad)))
      ;; A drawer that can be made is made.
      (multiple-value-bind (doc editor) (snapshot-fixture)
        (declare (ignore editor))
        (run-command doc 'clamacs-snapshot-windows)
        (is (search "Saved the positions of 1 window(s)" (fake-last-message doc)))
        (is (read-file-text bad))
        (delete-file bad)))))

(deftest a-second-editor-comes-up-where-the-file-says
  ;; What drive.rexx checks by starting a second editor: a fresh editor
  ;; reads the file and its first window's place is what the file said.
  (let ((env (temp-file "windows-second.cfg"
                        (lines "; written by drive.rexx" "" "doc1 24 48 400 160" ""))))
    (let ((*snapshot-files* (list env))
          (editor (make-fake-editor)))
      (is-equal (snapshot-load editor) 1)
      (let ((doc (open-document editor nil)))
        (is-equal (doc-role doc) "doc1")
        (is-equal (multiple-value-list (layout-place editor (doc-role doc)))
                  '(24 48 400 160))
        ;; The second window has no stored place.
        (is (null (layout-place editor (doc-role (open-document editor nil)))))))
    (delete-file env)))

(deftest the-user-paths-are-re-derived-when-the-editor-runs
  ;; A heap image holds *INIT-FILE* and *SNAPSHOT-FILES* as the saving
  ;; machine had them; RUN calls REFRESH-USER-PATHS first, which answers
  ;; what a fresh load of the two files would.
  (let ((*init-file* "/some/other/machine/.clamacsrc")
        (*snapshot-files* (list "/some/other/machine/.clamacs-windows.cfg")))
    (refresh-user-paths)
    (is-equal *init-file* (default-init-file))
    (is-equal *snapshot-files* (default-snapshot-files))
    (is (search ".clamacsrc" *init-file*))
    (is (search ".clamacs-windows.cfg" (first *snapshot-files*)))
    (is (null (search "/some/other/machine/" *init-file*)))))
