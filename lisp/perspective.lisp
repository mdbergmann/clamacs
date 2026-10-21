;;;; perspective.lisp -- projects: a folder the user opens, works in and
;;;; closes, which the editor remembers.
;;;;
;;;; Underneath, a project is a PERSPECTIVE -- Emacs's perspective.el, a
;;;; named set of buffers with their windows, of which one is in front,
;;;; for an editor where a buffer IS a window (MUI) or a tab (the host) --
;;;; and this file keeps that word for the mechanism; the user sees
;;;; `project' everywhere (specs/clamacs-perspectives.md).  Switching
;;;; hides the windows of the perspective left and shows the windows of
;;;; the one entered, the Buffers menu and `C-x o' see the buffers in
;;;; front only, a file opened from a project belongs to it, `find-file'
;;;; and the ASDF commands start from the project's folder, and a switch
;;;; tells amilisp the folder.  Buffers outside any project live in the
;;;; SCRATCH set, a perspective with no root the user never sees named:
;;;; the status line shows nothing there, and the Project menu lists it as
;;;; `(no project)' only while it has buffers.  A project is OPEN (listed
;;;; at the tail of the Project menu, its windows on the screen when it is
;;;; in front) or RECENT (the Recent Projects submenu; its files waiting
;;;; to be opened by the first switch into it).  The projects are written
;;;; to a small text file beside the layout file whenever one is opened or
;;;; closed and at every quit, and LISTED at the next start: every project
;;;; comes back recent, the editor opens the window it always did in the
;;;; scratch set, and the user picks the project to reopen.
;;;;
;;;; Three rules.  A project is DATA the frontends read: this file decides
;;;; which documents are shown (DOC-SHOWN-P), and a frontend only hides or
;;;; shows a window when told (DOC-SET-SHOWN).  One implementation with
;;;; three entrances: the Project menu (menu.lisp's :PROJECTS and :RECENT
;;;; groups), the `M-x clamacs-project-*' commands on `C-x p' and the
;;;; port's PROJECTS / RECENT verbs all end in PERSPECTIVE-SWITCH and its
;;;; siblings.  And the editor is never left without a window: a project
;;;; entered empty gets an unnamed buffer, closing the last buffer of the
;;;; one in front brings another with buffers in front, and closing the
;;;; last open project puts the editor in the scratch set with an unnamed
;;;; buffer -- only when nothing has buffers does the last window's close
;;;; end the editor, as it always did.
;;;;
;;;; Pure: no MUI, no OS types.  The file I/O is Common Lisp's own.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The struct and the editor's list
;;; ------------------------------------------------------------------

(defstruct (perspective (:constructor %make-perspective (name)))
  name                        ; a string, unique among the editor's
  (root nil)                  ; the folder, ending in / or :; NIL for the scratch set
  (open t)                    ; a project: open (may have windows) or recent
  (documents '())             ; its source documents, oldest first
  (active nil)                ; the document that had the keyboard when
                              ; the perspective was left, or NIL
  (pending-files '())         ; a recent project's files, not opened yet:
                              ; the first switch into it opens them
  (pending-active nil))       ; ... and the path of its recorded document

(defun perspective-pending-p (p)
  "Whether P still has files waiting to be opened: listed from the file
or closed since, and not entered since."
  (and (perspective-pending-files p) t))

(defparameter *scratch-perspective-name* "scratch"
  "The name of the perspective the buffers outside any project live in:
Emacs's *scratch*, never written to the file, with no root, shown as
`(no project)' in the Project menu while it has buffers and named
nowhere else.  A project cannot take the name.")

(defparameter *no-project-label* "(no project)"
  "How the Project menu and the prompts call the scratch set.")

(defun perspective-scratch-p (p)
  "Whether P is the scratch set."
  (string= (perspective-name p) *scratch-perspective-name*))

(defun perspective-project-p (p)
  "Whether P is a project: anything but the scratch set."
  (not (perspective-scratch-p p)))

(defun perspective-recent-p (p)
  "Whether P is a recent project: known, not open."
  (and (perspective-project-p p) (not (perspective-open p))))

(defun perspective-label (p)
  "P's name as the user sees it: the project's, or `(no project)'."
  (if (perspective-scratch-p p) *no-project-label* (perspective-name p)))

(defun find-perspective (editor name)
  "The perspective called NAME, or NIL.  Names are exact."
  (and (stringp name)
       (find name (editor-perspectives editor) :key #'perspective-name :test #'string=)))

(defun perspective-names (editor)
  "Every perspective's name, in the order made: what the reports list."
  (mapcar #'perspective-name (editor-perspectives editor)))

(defun scratch-perspective (editor)
  (find-perspective editor *scratch-perspective-name*))

(defun open-projects (editor)
  "The open projects, in the order made."
  (remove-if-not (lambda (p) (and (perspective-project-p p) (perspective-open p)))
                 (editor-perspectives editor)))

(defun recent-projects (editor)
  "The recent projects, in the order made: the Recent Projects submenu."
  (remove-if-not #'perspective-recent-p (editor-perspectives editor)))

(defun project-cycle (editor)
  "What Next Project / Previous Project cycle and the Project menu lists
at its tail: the scratch set while it has open buffers, then the open
projects."
  (let ((scratch (scratch-perspective editor)))
    (append (and scratch (perspective-live-documents scratch) (list scratch))
            (open-projects editor))))

(defun perspective-name-ok-p (name)
  "A name is one or more characters that are not all blanks."
  (and (stringp name) (string/= (string-trim " " name) "")))

(defun make-perspective (editor name &key root (open t))
  "A new perspective NAME at the end of EDITOR's list -- a project with
ROOT, open unless OPEN is NIL.  An error for a name in use, or no name
at all."
  (unless (perspective-name-ok-p name)
    (error "A project needs a name, not ~S." name))
  (let ((name (string-trim " " name)))
    (when (find-perspective editor name)
      (error "There is a project called ~A already." name))
    (let ((p (%make-perspective name)))
      (setf (perspective-root p) root
            (perspective-open p) open
            (editor-perspectives editor) (append (editor-perspectives editor) (list p)))
      (repl-sync-title editor)
      p)))

(defun ensure-scratch-perspective (editor)
  "The scratch set, made when there is none yet."
  (or (scratch-perspective editor)
      (make-perspective editor *scratch-perspective-name* :root nil)))

(defun current-perspective (editor)
  "The perspective in front, the scratch set (made now) when there is
none yet -- so an editor that never opens a project has one and behaves
as before."
  (or (editor-perspective editor)
      (setf (editor-perspective editor) (ensure-scratch-perspective editor))))

;;; ------------------------------------------------------------------
;;; Who belongs, and what is shown
;;; ------------------------------------------------------------------

(defun perspective-adopt (doc)
  "DOC into the perspective in front, when it is a source document -- a
file window or an unnamed buffer -- that belongs to none yet.  A tool
buffer (the REPL, *clamacs-description*, ...) belongs to no perspective
and is shown in every one: there is one amilisp, one REPL thread.  Called
when a document is made, and again when a tool buffer becomes a file
\(VISIT-PATH).  The perspective, or NIL when DOC stays a tool buffer."
  (when (and (null (doc-perspective doc)) (not (tool-document-p doc)))
    (let ((p (current-perspective (doc-editor doc))))
      (setf (doc-perspective doc) p
            (perspective-documents p) (append (perspective-documents p) (list doc)))
      p)))

(defun doc-shown-p (doc)
  "Whether DOC's window is on the screen: it belongs to no perspective, or
to the one in front."
  (let ((p (doc-perspective doc)))
    (or (null p) (eq p (editor-perspective (doc-editor doc))))))

(defun shown-documents (editor)
  "The open documents that are shown, oldest first: what the Buffers menu
lists, what `C-x o' cycles, and what a frontend falls back on for the
active document."
  (remove-if-not #'doc-shown-p (live-documents editor)))

(defun perspective-live-documents (p)
  "P's documents that are still open, oldest first."
  (remove-if #'doc-closing (perspective-documents p)))

(defun perspective-of-document (editor doc)
  "The perspective DOC is in, as the editor sees it now: P, or NIL for a
tool buffer.  (The slot, checked against the list.)"
  (let ((p (doc-perspective doc)))
    (and p (member p (editor-perspectives editor)) p)))

(defun perspective-note (editor control &rest args)
  "A message where the user looks now: the active document's echo area."
  (let ((doc (editor-active-document editor)))
    (when doc
      (doc-message doc (apply #'format nil control args)))))

(defun status-perspective (doc)
  "` [NAME]' after the buffer's name in a status line while a project is
in front -- the one DOC is shown in, since a hidden document's status
line is never on the screen -- and \"\" in the scratch set.  Both
frontends' status lines and the REPL's title call it."
  (let ((p (current-perspective (doc-editor doc))))
    (if (perspective-project-p p)
        (format nil " [~A]" (perspective-name p))
        "")))

;;; ------------------------------------------------------------------
;;; Switching
;;; ------------------------------------------------------------------

(defun root-form (root)
  "The form that makes ROOT amilisp's default directory, one line, the
symbols qualified since the port reads it in whatever package it was
last told."
  (format nil "(cl:setf cl:*default-pathname-defaults* (cl:pathname ~S))" root))

(defun perspective-tell-root (editor p)
  "Tell amilisp P's folder -- when P has one and the wire is connected:
one EVAL on the handler thread, nothing waited for, the reply dropped
\(wire-dispatch has no continuation for :TELL-ROOT), so a relative path
typed at the REPL means the project's.  Emacs's `default-directory' is
buffer-local and SLIME's `,cd' does this by hand; here the project does
it.  An open REPL transcript gets a note.  Never starts an amilisp.
True when the EVAL went out."
  (let ((wire (editor-wire editor))
        (root (perspective-root p)))
    (when (and wire root (wire-connected wire)
               (wire-request wire nil :tell-root (concatenate 'string "EVAL " (root-form root))))
      (let ((repl (repl-doc editor)))
        (when repl
          (repl-note repl "default directory ~A (project ~A)" root (perspective-name p))))
      t)))

(defun perspective-open-files (editor p files active-path)
  "FILES opened into P, which must be in front so they join it: a file
open elsewhere is moved over, one that is not there or cannot be read
is skipped.  The document showing ACTIVE-PATH, when it is P's, becomes
P's active one.  Three values: the files opened, the files skipped, the
files that were open already."
  (let ((opened 0) (skipped 0) (moved 0))
    (dolist (path files)
      (let ((open (find-document-by-path editor path)))
        (cond (open (perspective-move open p) (incf moved))
              ((not (ignore-errors (probe-file path))) (incf skipped))
              ((open-document editor path) (incf opened))
              (t (incf skipped)))))
    (let ((active (and active-path (find-document-by-path editor active-path))))
      (when (and active (eq (doc-perspective active) p))
        (setf (perspective-active p) active)))
    (values opened skipped moved)))

(defun perspective-open-pending (editor p)
  "P's waiting files opened into P, which must be in front, and P waits
no more.  Two values, the files P has open now for it (the ones brought
over from elsewhere counted) and the files skipped; NIL and 0 when none
waited."
  (let ((files (perspective-pending-files p))
        (active-path (perspective-pending-active p)))
    (cond (files
           (setf (perspective-pending-files p) '()
                 (perspective-pending-active p) nil)
           (multiple-value-bind (opened skipped moved)
               (perspective-open-files editor p files active-path)
             (values (+ opened moved) skipped)))
          (t (values nil 0)))))

(defun perspective-root-note (p)
  "` (ROOT)' after P's name in the switch's message when P has a folder,
and \"\" when it has none."
  (if (perspective-root p)
      (format nil " (~A)" (perspective-root p))
      ""))

(defun perspective-opened-note (opened skipped)
  "`, N file(s) opened[, M missing]' after the switch's message when the
switch opened a project's waiting files; \"\" otherwise."
  (if opened
      (format nil ", ~D file(s) opened~A" opened
              (if (> skipped 0) (format nil ", ~D missing" skipped) ""))
      ""))

(defun perspective-switch-message (p opened skipped)
  "What a switch into P says: `Project: NAME (ROOT)[, N file(s) opened]',
or `No project' for the scratch set."
  (if (perspective-scratch-p p)
      "No project"
      (format nil "Project: ~A~A~A" (perspective-name p)
              (perspective-root-note p)
              (perspective-opened-note opened skipped))))

(defun perspective-switch (editor p &key (say t))
  "Bring P in front.  The active document of the perspective left is
remembered on it; P is open from now on; its waiting files, if any, are
opened into it (PERSPECTIVE-OPEN-PENDING); its documents are shown, the
remembered one -- or the first -- activated, and only then the old
perspective's hidden, so the frontend never has a moment without a shown
active document.  A perspective entered empty gets an unnamed buffer.
amilisp is told P's folder (PERSPECTIVE-TELL-ROOT).  A switch into the
perspective in front opens its waiting files and otherwise does nothing.
Says PERSPECTIVE-SWITCH-MESSAGE unless SAY is NIL.  Three values: P, the
files opened (NIL when none waited), the files skipped."
  (let ((old (editor-perspective editor))
        (opened nil) (skipped 0))
    (setf (perspective-open p) t)
    (cond ((eq old p)
           ;; In front already: only the waiting files, if any, and the
           ;; recorded document to the keyboard, since each file took it
           ;; as it opened.
           (multiple-value-setq (opened skipped) (perspective-open-pending editor p))
           (when opened
             (let ((active (perspective-active p)))
               (when (and active (member active (perspective-live-documents p)))
                 (doc-activate active)))
             (perspective-tell-root editor p)))
          (t
           (when old
             (let ((active (editor-active-document editor)))
               (when (and active (eq (doc-perspective active) old))
                 (setf (perspective-active old) active))))
           (setf (editor-perspective editor) p)
           (multiple-value-setq (opened skipped) (perspective-open-pending editor p))
           (let ((docs (perspective-live-documents p)))
             (cond (docs
                    (dolist (doc docs)
                      (doc-set-shown doc t))
                    (let ((active (perspective-active p)))
                      (doc-activate (if (and active (member active docs)) active (first docs)))))
                   (t
                    ;; Made now, so it joins P, which is in front.
                    (let ((doc (open-document editor nil)))
                      (when doc (doc-activate doc))))))
           (when old
             (dolist (doc (perspective-live-documents old))
               (doc-set-shown doc nil)))
           (perspective-tell-root editor p)))
    (repl-sync-title editor)
    (when say
      (perspective-note editor "~A" (perspective-switch-message p opened skipped)))
    (values p opened skipped)))

(defun perspective-sync-shown (editor)
  "Every open document shown or hidden as DOC-SHOWN-P says now: what a
restore runs before it brings the recorded project in front, since the
documents it opened came up shown."
  (dolist (doc (live-documents editor))
    (doc-set-shown doc (doc-shown-p doc))))

(defun perspective-neighbour (editor delta)
  "The perspective DELTA places after the one in front in the cycle
\(PROJECT-CYCLE); the cycle's first when the one in front is not in it
\(the scratch set without buffers); NIL for an empty cycle."
  (let* ((all (project-cycle editor))
         (n (length all))
         (pos (position (current-perspective editor) all)))
    (cond ((= n 0) nil)
          ((null pos) (first all))
          (t (nth (mod (+ pos delta) n) all)))))

(defun perspective-with-documents (editor from)
  "The nearest perspective before FROM in the list, cyclically, that has
open documents; NIL when no other has any."
  (let* ((all (editor-perspectives editor))
         (n (length all))
         (pos (position from all)))
    (loop for k from 1 below n
          for p = (nth (mod (- pos k) n) all)
          when (perspective-live-documents p) return p)))

;;; ------------------------------------------------------------------
;;; Leaving and moving
;;; ------------------------------------------------------------------

(defun perspective-forget (doc)
  "DOC's window went (CLOSE-DOCUMENT): out of its perspective.  When that
emptied the perspective in front and another has documents, that one
comes in front -- the rule that keeps a window on the screen.  When no
other has any, nothing happens here and the frontend's loop sees the
last window go, as before."
  (let ((p (doc-perspective doc))
        (editor (doc-editor doc)))
    (when p
      (setf (perspective-documents p) (remove doc (perspective-documents p)))
      (when (eq (perspective-active p) doc)
        (setf (perspective-active p) nil))
      (when (and (eq p (editor-perspective editor))
                 (null (perspective-live-documents p)))
        (let ((next (perspective-with-documents editor p)))
          (when next
            (perspective-switch editor next)))))))

(defun perspective-move (doc p)
  "DOC into P, out of the perspective it is in: hidden when it leaves the
one in front, shown when it enters it.  True when it moved; NIL for a
tool buffer, which belongs to none, or a document in P already."
  (let ((old (doc-perspective doc))
        (editor (doc-editor doc)))
    (unless (or (eq old p) (tool-document-p doc))
      (when old
        (setf (perspective-documents old) (remove doc (perspective-documents old)))
        (when (eq (perspective-active old) doc)
          (setf (perspective-active old) nil)))
      (setf (doc-perspective doc) p
            (perspective-documents p) (append (perspective-documents p) (list doc)))
      (let ((current (editor-perspective editor)))
        (cond ((eq p current) (doc-set-shown doc t))
              ((eq old current) (doc-set-shown doc nil))))
      t)))

(defun perspective-bring-over (editor doc)
  "DOC, open in another perspective, into the one in front -- what
`find-file' does with a file that has a window elsewhere, since a window
cannot be in two places.  The perspective it came from, or NIL when it
was here already."
  (let ((from (doc-perspective doc)))
    (and (perspective-move doc (current-perspective editor))
         from)))

(defun perspective-close (editor p)
  "The project P closed: the editor switches away first when P is in front
\(to the previous in the cycle, else to the scratch set, which gets an
unnamed buffer), P's buffers are closed (each asking about unsaved
changes), P's file list is remembered on it and P is recent from then
on.  T when it went; :SCRATCH for the scratch set, which cannot be
closed; :CANCELLED when a question was cancelled, P staying open with
what is left.  The file is kept in step."
  (cond ((perspective-scratch-p p) :scratch)
        (t
         (let ((files (loop for doc in (perspective-live-documents p)
                            when (doc-path doc) collect (doc-path doc)))
               (active (let ((a (perspective-active-now editor p)))
                         (and a (not (doc-closing a)) (doc-path a)))))
           (when (eq p (editor-perspective editor))
             (let ((next (perspective-neighbour editor -1)))
               (perspective-switch editor (if (or (null next) (eq next p))
                                              (ensure-scratch-perspective editor)
                                              next)
                                   :say nil)))
           (dolist (doc (perspective-live-documents p))
             (unless (close-document doc)
               (return-from perspective-close :cancelled)))
           (setf (perspective-open p) nil
                 (perspective-pending-files p) files
                 (perspective-pending-active p) active)
           ;; The question about an unsaved buffer brought P in front
           ;; again: out of it, now that it is empty.
           (when (eq p (editor-perspective editor))
             (perspective-switch editor (ensure-scratch-perspective editor) :say nil))
           (repl-sync-title editor)
           (perspective-autosave editor)
           t))))

;;; ------------------------------------------------------------------
;;; Opening a project: the folder, the name
;;; ------------------------------------------------------------------

(defun normalize-directory (text)
  "TEXT as a directory: trimmed, with a `/' after it unless it ends in
`/' or `:' already; NIL for nothing."
  (let ((dir (string-trim " " text)))
    (cond ((string= dir "") nil)
          ((member (char dir (1- (length dir))) '(#\/ #\:)) dir)
          (t (concatenate 'string dir "/")))))

(defun directory-exists-p (dir)
  "Whether DIR is there.  Asked both with and without its `/', since the
two spellings are not the same to every file system."
  (and dir
       (or (ignore-errors (probe-file dir))
           (let ((bare (string-right-trim "/" dir)))
             (and (string/= bare "") (ignore-errors (probe-file bare)))))
       t))

(defun directory-last-component (dir)
  "The last component of DIR: `src' for `Work:src/', `Work' for `Work:',
DIR itself when nothing is left."
  (let* ((trimmed (string-right-trim "/" dir))
         (n (length trimmed))
         (name (cond ((= n 0) "")
                     ((char= (char trimmed (1- n)) #\:) (subseq trimmed 0 (1- n)))
                     (t (path-basename trimmed)))))
    (if (string= name "") dir name)))

(defun project-directory (path)
  "PATH as a project's folder: a .asd's directory (`Work:sento/' for
`Work:sento/sento.asd', with or without a `/' typed after it), else PATH
itself as a directory; NIL for nothing."
  (let ((bare (string-right-trim "/" (string-trim " " path))))
    (if (system-path-p bare)
        (path-directory bare)
        (normalize-directory path))))

(defun project-name-from-directory (dir)
  "The project's name for the folder DIR: the system of the one .asd in
it (`sento' for `Work:sento/sento.asd' -- what a Lisp programmer calls
the project), else the folder's own name (DIRECTORY-LAST-COMPONENT)."
  (let ((systems (directory-system-files dir)))
    (if (= (length systems) 1)
        (system-name (first systems))
        (directory-last-component dir))))

(defun unique-project-name (editor name dir)
  "NAME when no perspective of EDITOR's has it (the scratch set's name
counts as taken); else NAME with the folder above DIR in parentheses,
`src (sento)'; else numbered, `src (2)'."
  (flet ((taken-p (n)
           (or (string= n *scratch-perspective-name*) (find-perspective editor n))))
    (if (not (taken-p name))
        name
        (let* ((parent (path-parent-directory dir))
               (qualified (and parent
                               (format nil "~A (~A)" name (directory-last-component parent)))))
          (if (and qualified (not (taken-p qualified)))
              qualified
              (loop for i from 2
                    for n = (format nil "~A (~D)" name i)
                    unless (taken-p n) return n))))))

(defun find-project-by-root (editor dir)
  "The project whose folder is DIR, or NIL.  Folders are compared without
regard to case: AmigaDOS has none, and a folder typed twice in two
spellings is one project."
  (find-if (lambda (p) (and (perspective-root p) (string-equal (perspective-root p) dir)))
           (editor-perspectives editor)))

(defun perspective-open-project (editor path)
  "The project of the folder PATH (or of the .asd PATH) opened: made and
named after the folder when there is none (UNIQUE-PROJECT-NAME), brought
in front -- a recent one's files opened -- and the file kept in step.
Four values: the project, what it was (:NEW, :RECENT or :OPEN), the
files opened and the files skipped."
  (let* ((dir (project-directory path))
         (p (find-project-by-root editor dir))
         (was (cond ((null p) :new)
                    ((perspective-open p) :open)
                    (t :recent))))
    (unless p
      (setq p (make-perspective editor (unique-project-name editor (project-name-from-directory dir) dir)
                                :root dir)))
    (multiple-value-bind (p opened skipped) (perspective-switch editor p :say nil)
      (when (eq was :new)
        (perspective-autosave editor))
      (values p was opened skipped))))

;;; ------------------------------------------------------------------
;;; The file
;;; ------------------------------------------------------------------

;;; The layout file's sibling: ENV: for this boot, ENVARC: for the next,
;;; one file in the home directory on the host.  Asked when the file
;;; loads, not with #+amigaos (see *SNAPSHOT-FILES*); REFRESH-USER-PATHS
;;; settles it again at run time.
(defun default-perspective-files ()
  (if (member :amigaos *features*)
      (list "ENV:Clamacs/projects.cfg" "ENVARC:Clamacs/projects.cfg")
      (list (namestring (merge-pathnames ".clamacs-projects.cfg"
                                         (user-homedir-pathname))))))

(defparameter *perspective-files* (default-perspective-files)
  "The files the projects are written to, the first of them read at a
start (the second when the first is missing).")

(defparameter *perspectives-header*
  "; clamacs projects -- project NAME, then its root and files; current NAME")

(defun perspective-active-now (editor p)
  "The document P would come back to: the active one while P is in front,
else the one remembered when P was left."
  (if (eq p (editor-perspective editor))
      (let ((active (editor-active-document editor)))
        (if (and active (eq (doc-perspective active) p)) active (perspective-active p)))
      (perspective-active p)))

(defun recorded-perspectives (editor)
  "The projects the file records: every perspective but the scratch set."
  (remove-if #'perspective-scratch-p (editor-perspectives editor)))

(defun perspectives-text (editor)
  "The projects as the file holds them: one keyword and the rest of the
line.  Unnamed buffers are not recorded, nor is the scratch set
\(RECORDED-PERSPECTIVES; the `current' line names none when it is in
front).  A recent project keeps the files it was listed or closed with:
the write must not lose what this session never opened."
  (with-output-to-string (out)
    (write-string *perspectives-header* out)
    (terpri out)
    (dolist (p (recorded-perspectives editor))
      (format out "project ~A~%" (perspective-name p))
      (when (perspective-root p)
        (format out "root ~A~%" (perspective-root p)))
      (dolist (doc (perspective-live-documents p))
        (when (doc-path doc)
          (format out "file ~A~%" (doc-path doc))))
      (dolist (path (perspective-pending-files p))
        (format out "file ~A~%" path))
      (let ((active (perspective-active-now editor p)))
        (cond ((and active (not (doc-closing active)) (doc-path active))
               (format out "active ~A~%" (doc-path active)))
              ((perspective-pending-active p)
               (format out "active ~A~%" (perspective-pending-active p))))))
    (let ((current (current-perspective editor)))
      (unless (perspective-scratch-p current)
        (format out "current ~A~%" (perspective-name current))))))

(defun perspectives-parse-line (line)
  "A line's keyword and value, two values, or NIL for a comment or a
blank line.  The value is the rest of the line, trimmed."
  (let* ((line (string-right-trim '(#\Return #\Space #\Tab) line))
         (start (position-if-not (lambda (c) (member c '(#\Space #\Tab))) line)))
    (when (and start (not (member (char line start) '(#\; #\#))))
      (let* ((end (or (position-if (lambda (c) (member c '(#\Space #\Tab))) line :start start)
                      (length line)))
             (keyword (string-downcase (subseq line start end)))
             (value (string-trim '(#\Space #\Tab) (subseq line end))))
        (values keyword value)))))

(defun perspectives-parse (text)
  "TEXT, the file, as a list of plists (:NAME :ROOT :FILES :ACTIVE) in file
order, and as second value the name the `current' line gives, or NIL.  A
line that does not parse, or names a project nothing, is skipped.
`perspective NAME' is read as `project NAME' (the file's keyword before
2026-10-20)."
  (let ((entries '()) (entry nil) (current nil)
        (start 0) (n (length text)))
    (flet ((finish ()
             (when entry
               (setf (getf entry :files) (nreverse (getf entry :files)))
               (push entry entries)
               (setq entry nil))))
      (loop
        (let* ((end (or (position #\Newline text :start start) n))
               (line (subseq text start end)))
          (multiple-value-bind (keyword value) (perspectives-parse-line line)
            (when keyword
              (cond ((or (string= keyword "project") (string= keyword "perspective"))
                     (finish)
                     (when (perspective-name-ok-p value)
                       (setq entry (list :name value :root nil :files '() :active nil))))
                    ((null entry))
                    ((string= keyword "root")
                     (setf (getf entry :root) (normalize-directory value)))
                    ((string= keyword "file")
                     (when (string/= value "")
                       (push value (getf entry :files))))
                    ((string= keyword "active")
                     (when (string/= value "")
                       (setf (getf entry :active) value))))
              (when (string= keyword "current")
                (setq current (and (string/= value "") value)))))
          (when (>= end n) (return))
          (setq start (1+ end))))
      (finish))
    (values (nreverse entries) current)))

(defun perspectives-read ()
  "The text of the first projects file that is there, or NIL."
  (dolist (path *perspective-files* nil)
    (let ((text (read-file-text path)))
      (when text (return text)))))

(defun perspective-save (editor)
  "The projects into every file: the paths that could not be written."
  (let ((text (perspectives-text editor)))
    (remove-if (lambda (path) (snapshot-write-file path text))
               *perspective-files*)))

(defun perspective-autosave (editor)
  "The file kept in step on the editor's own: after Open Project, Close
Project and a rename, and at a quit (QUIT-REQUESTED, which writes the
layout file next through SNAPSHOT-AUTOSAVE) -- whenever there is a
project to record or the file exists already.  The first Open Project
creates it; an editor that never opens a project writes nothing.  True
when it was written."
  (when (or (recorded-perspectives editor)
            (some (lambda (path) (ignore-errors (probe-file path))) *perspective-files*))
    (null (perspective-save editor))))

(defun perspective-restore (editor &optional (text (perspectives-read)))
  "The projects of TEXT (the file's, by default) into the running editor,
eagerly: each made when missing and open, its root set, its files opened
into it -- a file open elsewhere moved, one that is not there or cannot
be read skipped -- the recorded document made its active one, and the
recorded project (or the first) brought in front.  Three values: the
projects made, the files opened, the files skipped; NIL when there is no
file."
  (when text
    (multiple-value-bind (entries current-name) (perspectives-parse text)
      (let ((original (editor-perspective editor))
            (made 0) (opened 0) (skipped 0))
        (dolist (e entries)
          (let ((p (find-perspective editor (getf e :name))))
            (unless p
              (setq p (make-perspective editor (getf e :name)))
              (incf made))
            (when (getf e :root)
              (setf (perspective-root p) (getf e :root)))
            ;; The file's files are opened now, so none wait.
            (setf (perspective-open p) t
                  (perspective-pending-files p) '()
                  (perspective-pending-active p) nil)
            ;; In front while its files open, so they join it.
            (setf (editor-perspective editor) p)
            (multiple-value-bind (o s)
                (perspective-open-files editor p (getf e :files) (getf e :active))
              (incf opened o)
              (incf skipped s))))
        (setf (editor-perspective editor) original)
        (let ((target (or (find-perspective editor current-name)
                          (first (editor-perspectives editor)))))
          (when target
            (perspective-sync-shown editor)
            (if (eq target (editor-perspective editor))
                ;; In front already (a switch to it would do nothing): the
                ;; recorded document activated all the same, since the
                ;; files opened each took the keyboard as they came.
                (let ((active (perspective-active target)))
                  (when (and active (member active (perspective-live-documents target)))
                    (doc-activate active)))
                (perspective-switch editor target :say nil))))
        (values made opened skipped)))))

(defun perspective-list-at-start (editor &optional (text (perspectives-read)))
  "A start: the projects of TEXT (the file's, by default) made RECENT, by
name with their roots, their files and recorded document waiting on them
-- nothing opened, none brought in front -- so the editor comes up with
the window it always did (the files named on the command line, else an
unnamed buffer) in the scratch set, made first and put in front when the
file lists anything, and the user picks the project to reopen from
Recent Projects, at `C-x p p' or over the port; that first switch opens
its files.  The file's `current' line is not honoured.  A `scratch'
entry, which the editor never writes, is skipped like any name in use.
The number of projects listed, or NIL when there is no file."
  (when text
    (let ((entries (perspectives-parse text))
          (made 0))
      (when entries
        (setf (editor-perspective editor) (ensure-scratch-perspective editor)))
      (dolist (e entries)
        (unless (find-perspective editor (getf e :name))
          (let ((p (make-perspective editor (getf e :name) :root (getf e :root) :open nil)))
            (setf (perspective-pending-files p) (getf e :files)
                  (perspective-pending-active p) (getf e :active))
            (incf made))))
      made)))

;;; ------------------------------------------------------------------
;;; The menu's groups
;;; ------------------------------------------------------------------

(defun perspective-menu (editor)
  "The Project menu's tail as it should be now: (LABEL . PERSPECTIVE) for
the scratch set while it has buffers and for each open project, in the
order made; the one in front is the ticked object."
  (mapcar (lambda (p) (cons (perspective-label p) p)) (project-cycle editor)))

(defun recent-menu (editor)
  "The Recent Projects submenu as it should be now: (NAME . PERSPECTIVE)
for each recent project, in the order made; nothing ticked."
  (mapcar (lambda (p) (cons (perspective-name p) p)) (recent-projects editor)))

(defun perspective-menu-pick (editor p)
  "Bring P in front, as its item in either group does -- a recent project
opened.  True when P is a perspective of the editor's."
  (when (and (perspective-p p) (member p (editor-perspectives editor)))
    (perspective-switch editor p)
    t))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun project-choices (editor &key recent)
  "The names a prompt offers: `(no project)' while the scratch set has
buffers, the open projects, and the recent ones when RECENT."
  (append (mapcar #'perspective-label (project-cycle editor))
          (and recent (mapcar #'perspective-name (recent-projects editor)))))

(defun project-completer (editor &key recent)
  (lambda (prefix) (complete (project-choices editor :recent recent) prefix)))

(defun project-named (editor name &key recent)
  "The perspective a prompt's answer NAME means: the scratch set for
`(no project)', an open project by name, a recent one too when RECENT;
NIL for no name or an unknown one."
  (let ((name (string-trim " " name)))
    (cond ((string= name "") nil)
          ((string= name *no-project-label*) (ensure-scratch-perspective editor))
          (t (let ((p (find-perspective editor name)))
               (and p (perspective-project-p p) (or recent (perspective-open p)) p))))))

(defun refuse-project-name (doc answer)
  "The message for a prompt's answer that names no project."
  (if (string= (string-trim " " answer) "")
      (message doc "A project needs a name")
      (message doc "No project called ~A" (string-trim " " answer)))
  (doc-beep doc))

(define-command clamacs-project-switch (doc arg)
  "Switch to a project by name, with completion over the open projects,
the recent ones and `(no project)'.  A recent project is opened, its
files with it; the one in front opens its waiting files, if any, and is
refused otherwise; an unknown name is refused."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (prompt doc "Project: "
            (lambda (doc answer)
              (let ((p (project-named editor answer :recent t)))
                (cond ((null p)
                       (refuse-project-name doc answer))
                      ((and (eq p (current-perspective editor))
                            (not (perspective-pending-p p)))
                       (message doc "Already in ~A" (perspective-label p)))
                      (t (perspective-switch editor p)))))
            :completer (project-completer editor :recent t))))

(defun perspective-step (doc delta)
  (let ((editor (doc-editor doc)))
    (if (rest (project-cycle editor))
        (perspective-switch editor (perspective-neighbour editor delta))
        (message doc "No other project"))))

(define-command clamacs-project-next (doc arg)
  "Switch to the next open project, in the order they were opened -- the
buffers outside any project among them, while there are some."
  (declare (ignore arg))
  (perspective-step doc 1))

(define-command clamacs-project-previous (doc arg)
  "Switch to the previous open project, in the order they were opened."
  (declare (ignore arg))
  (perspective-step doc -1))

(define-command clamacs-project-rename (doc arg)
  "Rename the project in front; the prompt offers its name.  Refused
outside a project."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (p (current-perspective editor)))
    (if (perspective-scratch-p p)
        (progn (message doc "Not in a project") (doc-beep doc))
        (prompt doc "Rename project to: "
                (lambda (doc answer)
                  (let* ((name (string-trim " " answer))
                         (taken (find-perspective editor name)))
                    (cond ((string= name "")
                           (message doc "A project needs a name")
                           (doc-beep doc))
                          ((or (string= name *scratch-perspective-name*)
                               (and taken (not (eq taken p))))
                           (message doc "There is a project called ~A already" name)
                           (doc-beep doc))
                          (t
                           (let ((old (perspective-name p)))
                             (setf (perspective-name p) name)
                             (repl-sync-title editor)
                             (perspective-autosave editor)
                             (message doc "Renamed ~A to ~A" old name))))))
                :initial (perspective-name p)))))

(define-command clamacs-project-close (doc arg)
  "Close the project in front: the editor switches to the previous one
\(or to the buffers outside any project), the project's buffers are
closed -- each unsaved one asks -- and the project is recent from then
on, its files remembered.  Refused outside a project."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (p (current-perspective editor))
         (name (perspective-name p)))
    (case (perspective-close editor p)
      (:scratch
       (message doc "Not in a project")
       (doc-beep doc))
      (:cancelled
       (perspective-note editor "Cancelled; ~A stays open" name))
      (t
       (perspective-note editor "Closed project ~A" name)))))

(define-command clamacs-project-move-buffer (doc arg)
  "Move this buffer into an open project named at the prompt (or out of
any, as `(no project)'), where its window is shown; here it is hidden.
When that leaves the project in front empty, the editor follows the
buffer."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (if (tool-document-p doc)
        (progn
          (message doc "~A is a tool buffer, shown in every project" (doc-name doc))
          (doc-beep doc))
        (prompt doc "Move buffer to project: "
                (lambda (doc answer)
                  (let* ((p (project-named editor answer))
                         (current (current-perspective editor))
                         (from (or (perspective-of-document editor doc) current)))
                    (cond ((null p)
                           (refuse-project-name doc answer))
                          ((eq p from)
                           (message doc "~A is in ~A already" (doc-name doc) (perspective-label p)))
                          (t
                           (perspective-move doc p)
                           ;; Where P comes back to: this buffer.
                           (setf (perspective-active p) doc)
                           (cond ((eq p current)
                                  ;; Brought into the one in front (a script
                                  ;; moving a hidden buffer): to the keyboard.
                                  (doc-activate doc))
                                 ((eq from current)
                                  (let ((left (perspective-live-documents from)))
                                    (if left
                                        (doc-activate (first left))
                                        (perspective-switch editor p :say nil)))))
                           (perspective-note editor "~A moved to ~A" (doc-name doc)
                                             (perspective-label p))))))
                :completer (project-completer editor)))))

(defun prompt-for-directory (doc label title initial continuation)
  "Prompt for a directory with LABEL, seeded with INITIAL.  TAB completes
a name typed after the directory; on a bare directory (the seed as it
came, or one typed with its `/' or `:') TAB opens the folder requester
TITLE there, as a file prompt's does, and so does RET on an empty line
-- where INITIAL points.  CONTINUATION gets DOC and the directory,
normalized (a `/' after it); a directory typed that is not there is
refused, and nothing happens when the requester was cancelled."
  (flet ((requester (text)
           ;; From the completer the prompt is still open: it goes before
           ;; the continuation, which may open the next one.
           (ask-file-then doc title :directory (if (string= text "") initial text)
                          (lambda (doc path)
                            (when (minibuffer-open-p doc)
                              (minibuffer-finish doc))
                            (funcall continuation doc (normalize-directory path))))))
    (prompt doc label
            (lambda (doc answer)
              (let ((dir (normalize-directory answer)))
                (cond ((null dir)
                       (requester ""))
                      ((not (directory-exists-p dir))
                       (message doc "No such directory: ~A" dir)
                       (doc-beep doc))
                      (t (funcall continuation doc dir)))))
            :initial initial
            :completer (lambda (text)
                         (if (directory-only-p text)
                             (progn (requester text) :handled)
                             (complete-path text)))
            :history (editor-file-history (doc-editor doc)))))

(defun open-project-path (doc path)
  "PATH -- a folder, or its .asd -- opened as a project
\(PERSPECTIVE-OPEN-PROJECT), DOC's echo area told what happened."
  (let ((editor (doc-editor doc)))
    (multiple-value-bind (p was opened skipped) (perspective-open-project editor path)
      (perspective-note editor "~A"
                        (if (eq was :new)
                            (format nil "New project: ~A~A"
                                    (perspective-name p) (perspective-root-note p))
                            (perspective-switch-message p opened skipped))))))

(defun project-home-directory ()
  "Where Open Project starts: the user's home directory, with its `/'
after it.  An Amiga has none -- amilisp's USER-HOMEDIR-PATHNAME answers
PROGDIR:, the editor's own drawer -- so there it is the HOME variable
when the user set one, else SYS:.  Asked when the prompt opens, never at
load: a heap image would hold the saving machine's home."
  (if (member :amigaos *features*)
      (let ((home (ext:getenv "HOME")))
        (or (and home (normalize-directory home)) "SYS:"))
      (namestring (user-homedir-pathname))))

(define-command clamacs-project-open (doc arg)
  "Open a project: a folder asked for at the prompt -- or its .asd; the
line is seeded with the home directory, TAB on a bare directory browses
from there, RET on an empty line from the home directory -- is the
project, named after the one .asd in it or after the folder, its files
opened when it is a recent one, and the editor switches to it.  The
menu's Open Project... is this prompt too, as the key's is: the
requester is one TAB away, never the first thing shown."
  (declare (ignore arg))
  (prompt-for-directory doc "Open project (folder or .asd; TAB: browse): " "Open Project"
                        (project-home-directory) #'open-project-path))

(define-command clamacs-project-open-requester (doc arg)
  "Open the project of a folder chosen in the requester, opened at the
home directory, as `clamacs-project-open' opens one typed.  M-x and a
script reach it; the menu prompts."
  (declare (ignore arg))
  (ask-file-then doc "Open Project" :directory (project-home-directory) #'open-project-path))

(define-command clamacs-project-save (doc arg)
  "Write the projects file now -- every project with its folder and its
files, the buffers outside any project left out.  The editor keeps the
file in step on its own; this is for a script."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (failed (perspective-save editor)))
    (cond (failed
           (message doc "Cannot write ~{~A~^ or ~}" failed)
           (doc-beep doc))
          (t
           (message doc "Saved ~D project(s) to ~A"
                    (length (recorded-perspectives editor))
                    (car (last *perspective-files*)))))))

(define-command clamacs-project-restore (doc arg)
  "Reopen every project of the projects file at once into the running
editor: the ones missing are made, their files opened, the recorded one
switched to."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (multiple-value-bind (made opened skipped) (perspective-restore editor)
      (cond ((null made)
             (message doc "No projects file (~A)" (first *perspective-files*))
             (doc-beep doc))
            (t
             (perspective-note editor "Reopened: ~D project(s) made, ~D file(s) opened~A"
                               made opened
                               (if (> skipped 0) (format nil ", ~D missing" skipped) "")))))))
