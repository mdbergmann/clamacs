;;;; perspective.lisp -- perspectives: a named set of buffers with their
;;;; windows, a project, of which one is in front.
;;;;
;;;; Emacs's perspective.el (`persp-switch', `C-x x') for an editor where
;;;; a buffer IS a window (MUI) or a tab (the host): switching hides the
;;;; windows of the perspective left and shows the windows of the one
;;;; entered, the Buffers menu and `C-x o' see the buffers in front only,
;;;; a file opened from a perspective belongs to it, and a perspective may
;;;; have a project directory that `find-file' and the ASDF commands start
;;;; from (specs/clamacs-perspectives.md).  The set of perspectives is
;;;; written to a small text file beside the layout file and is LISTED at
;;;; the next start: the perspectives come back by name with their roots,
;;;; their files waiting, and the first switch into one opens them
;;;; (PERSPECTIVE-OPEN-PENDING) -- a start opens the window it always
;;;; did, no more, and the user picks the perspective to reopen.
;;;;
;;;; Three rules.  A perspective is DATA the frontends read: this file
;;;; decides which documents are shown (DOC-SHOWN-P), and a frontend only
;;;; hides or shows a window when told (DOC-SET-SHOWN).  One implementation
;;;; with three entrances: the Perspectives menu (menu.lisp's :PERSPECTIVES
;;;; group), the `M-x clamacs-perspective-*' commands on `C-x x' and the
;;;; port's PERSPECTIVES verb all end in PERSPECTIVE-SWITCH and its
;;;; siblings.  And the editor is never left without a window: a
;;;; perspective entered empty gets an unnamed buffer, and closing the
;;;; last buffer of the one in front brings another in front when one has
;;;; buffers -- only when none has does the last window's close end the
;;;; editor, as it always did.
;;;;
;;;; Pure: no MUI, no OS types.  The file I/O is Common Lisp's own.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The struct and the editor's list
;;; ------------------------------------------------------------------

(defstruct (perspective (:constructor %make-perspective (name)))
  name                        ; a string, unique among the editor's
  (root nil)                  ; the project directory, ending in / or :, or NIL
  (documents '())             ; its source documents, oldest first
  (active nil)                ; the document that had the keyboard when
                              ; the perspective was left, or NIL
  (pending-files '())         ; the files the perspectives file records for
                              ; it, not opened yet: a start lists, the
                              ; first switch into it opens
  (pending-active nil))       ; ... and the path of its recorded document

(defun perspective-pending-p (p)
  "Whether P still has the files of the perspectives file waiting to be
opened: listed at a start and never entered since."
  (and (perspective-pending-files p) t))

(defparameter *main-perspective-name* "main"
  "The name of the perspective an editor starts with.")

(defun find-perspective (editor name)
  "The perspective called NAME, or NIL.  Names are exact."
  (and (stringp name)
       (find name (editor-perspectives editor) :key #'perspective-name :test #'string=)))

(defun perspective-names (editor)
  "Every perspective's name, in the order made: what the prompts complete over."
  (mapcar #'perspective-name (editor-perspectives editor)))

(defun perspective-name-ok-p (name)
  "A name is one or more characters that are not all blanks."
  (and (stringp name) (string/= (string-trim " " name) "")))

(defun make-perspective (editor name &key root)
  "A new perspective NAME at the end of EDITOR's list.  An error for a
name in use, or no name at all."
  (unless (perspective-name-ok-p name)
    (error "A perspective needs a name, not ~S." name))
  (let ((name (string-trim " " name)))
    (when (find-perspective editor name)
      (error "There is a perspective called ~A already." name))
    (let ((p (%make-perspective name)))
      (setf (perspective-root p) root
            (editor-perspectives editor) (append (editor-perspectives editor) (list p)))
      ;; The second perspective puts ` [name]' into the REPL's title.
      (repl-sync-title editor)
      p)))

(defun current-perspective (editor)
  "The perspective in front, made (`main') when there is none yet -- so
an editor that never hears of perspectives has one and behaves as before."
  (or (editor-perspective editor)
      (setf (editor-perspective editor)
            (or (first (editor-perspectives editor))
                (make-perspective editor *main-perspective-name*)))))

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
tool buffer.  (The slot, checked against the list: a perspective closed
since leaves its documents nowhere.)"
  (let ((p (doc-perspective doc)))
    (and p (member p (editor-perspectives editor)) p)))

(defun perspective-note (editor control &rest args)
  "A message where the user looks now: the active document's echo area."
  (let ((doc (editor-active-document editor)))
    (when doc
      (doc-message doc (apply #'format nil control args)))))

(defun status-perspective (doc)
  "` [NAME]' after the buffer's name in a status line while the editor
has more than one perspective: the one in front, which is the one DOC is
shown in -- a hidden document's status line is never on the screen.
Both frontends' status lines call it."
  (let ((editor (doc-editor doc)))
    (if (rest (editor-perspectives editor))
        (format nil " [~A]" (perspective-name (current-perspective editor)))
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
  "Tell amilisp P's project directory -- when P has one and the wire is
connected: one EVAL on the handler thread, nothing waited for, the reply
dropped (wire-dispatch has no continuation for :TELL-ROOT), so a
relative path typed at the REPL means the project's.  Emacs's
`default-directory' is buffer-local and SLIME's `,cd' does this by hand;
here the perspective does it.  An open REPL transcript gets a note.
Never starts an amilisp.  True when the EVAL went out."
  (let ((wire (editor-wire editor))
        (root (perspective-root p)))
    (when (and wire root (wire-connected wire)
               (wire-request wire nil :tell-root (concatenate 'string "EVAL " (root-form root))))
      (let ((repl (repl-doc editor)))
        (when repl
          (repl-note repl "default directory ~A (perspective ~A)" root (perspective-name p))))
      t)))

(defun perspective-open-files (editor p files active-path)
  "FILES opened into P, which must be in front so they join it: a file
open elsewhere is moved over, one that is not there or cannot be read
is skipped.  The document showing ACTIVE-PATH, when it is P's, becomes
P's active one.  Three values: the files opened, the files skipped, the
files that were open already.  What a restore does per entry, and what
a listed perspective does at its first switch."
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
  "P's waiting files (PERSPECTIVE-LIST-AT-START) opened into P, which must
be in front, and P waits no more.  Two values, the files P has open now
for it (the ones brought over from elsewhere counted) and the files
skipped; NIL and 0 when none waited."
  (let ((files (perspective-pending-files p))
        (active-path (perspective-pending-active p)))
    (cond (files
           (setf (perspective-pending-files p) '()
                 (perspective-pending-active p) nil)
           (multiple-value-bind (opened skipped moved)
               (perspective-open-files editor p files active-path)
             (values (+ opened moved) skipped)))
          (t (values nil 0)))))

(defun perspective-opened-note (opened skipped)
  "`, N file(s) opened[, M missing]' after the switch's message when the
switch opened a listed perspective's files; \"\" otherwise."
  (if opened
      (format nil ", ~D file(s) opened~A" opened
              (if (> skipped 0) (format nil ", ~D missing" skipped) ""))
      ""))

(defun perspective-switch (editor p &key (say t))
  "Bring P in front.  The active document of the perspective left is
remembered on it; P's documents are shown, the remembered one -- or the
first -- activated, and only then the old perspective's hidden, so the
frontend never has a moment without a shown active document.  A
perspective entered empty gets an unnamed buffer.  amilisp is told P's
project directory (PERSPECTIVE-TELL-ROOT).  A perspective listed at a
start opens its recorded files first (PERSPECTIVE-OPEN-PENDING) -- also
when it is the one in front already, which a switch otherwise leaves
alone.  Says `Perspective: NAME', with the files opened, unless SAY is
NIL.  P."
  (let ((old (editor-perspective editor))
        (opened nil) (skipped 0))
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
      (perspective-note editor "Perspective: ~A~A" (perspective-name p)
                        (perspective-opened-note opened skipped)))
    p))

(defun perspective-sync-shown (editor)
  "Every open document shown or hidden as DOC-SHOWN-P says now: what a
restore runs before it brings the recorded perspective in front, since
the documents it opened came up shown."
  (dolist (doc (live-documents editor))
    (doc-set-shown doc (doc-shown-p doc))))

(defun perspective-neighbour (editor delta)
  "The perspective DELTA places after the one in front, cyclically."
  (let* ((all (editor-perspectives editor))
         (n (length all))
         (pos (position (current-perspective editor) all)))
    (nth (mod (+ pos delta) n) all)))

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
comes in front -- the one rule that keeps a window on the screen.  When
no other has any, nothing happens here and the frontend's loop sees the
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
  "P closed: the editor switches away first when P is in front, then P's
buffers are closed (each asking about unsaved changes), then P is
forgotten.  T when it went; :ONLY for the only perspective, which stays;
:CANCELLED when a question was cancelled, P staying with what is left."
  (cond ((null (rest (editor-perspectives editor)))
         :only)
        (t
         (when (eq p (editor-perspective editor))
           (perspective-switch editor (perspective-neighbour editor -1) :say nil))
         (dolist (doc (perspective-live-documents p))
           (unless (close-document doc)
             (return-from perspective-close :cancelled)))
         (setf (editor-perspectives editor) (remove p (editor-perspectives editor)))
         (when (eq (editor-perspective editor) p)
           (setf (editor-perspective editor) nil))
         (repl-sync-title editor)
         t)))

;;; ------------------------------------------------------------------
;;; The project directory
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

(defun project-name-from-directory (dir)
  "The last component of DIR: `src' for `Work:src/', `Work' for `Work:',
DIR itself when nothing is left."
  (let* ((trimmed (string-right-trim "/" dir))
         (n (length trimmed))
         (name (cond ((= n 0) "")
                     ((char= (char trimmed (1- n)) #\:) (subseq trimmed 0 (1- n)))
                     (t (path-basename trimmed)))))
    (if (string= name "") dir name)))

(defun perspective-open-project (editor dir)
  "The perspective of the project at DIR: made and named after the
directory when there is none, its root DIR when it had none, brought in
front.  Two values: the perspective, and whether it was made now."
  (let* ((name (project-name-from-directory dir))
         (p (find-perspective editor name))
         (new (null p)))
    (when new
      (setq p (make-perspective editor name)))
    (unless (perspective-root p)
      (setf (perspective-root p) dir))
    (perspective-switch editor p :say nil)
    (values p new)))

;;; ------------------------------------------------------------------
;;; The file
;;; ------------------------------------------------------------------

;;; The layout file's sibling: ENV: for this boot, ENVARC: for the next,
;;; one file in the home directory on the host.  Asked when the file
;;; loads, not with #+amigaos (see *SNAPSHOT-FILES*); REFRESH-USER-PATHS
;;; settles it again at run time.
(defun default-perspective-files ()
  (if (member :amigaos *features*)
      (list "ENV:Clamacs/perspectives.cfg" "ENVARC:Clamacs/perspectives.cfg")
      (list (namestring (merge-pathnames ".clamacs-perspectives.cfg"
                                         (user-homedir-pathname))))))

(defparameter *perspective-files* (default-perspective-files)
  "The files the perspectives are written to, the first of them read at
a start without files (the second when the first is missing).")

(defparameter *perspectives-header*
  "; clamacs perspectives -- perspective NAME, then its root and files; current NAME")

(defun perspective-active-now (editor p)
  "The document P would come back to: the active one while P is in front,
else the one remembered when P was left."
  (if (eq p (editor-perspective editor))
      (let ((active (editor-active-document editor)))
        (if (and active (eq (doc-perspective active) p)) active (perspective-active p)))
      (perspective-active p)))

(defun perspectives-text (editor)
  "The perspectives as the file holds them: one keyword and the rest of
the line.  Unnamed buffers are not recorded.  A perspective listed at the
start and never entered keeps the files it was listed with: the quit's
write must not lose what this session never opened."
  (with-output-to-string (out)
    (write-string *perspectives-header* out)
    (terpri out)
    (dolist (p (editor-perspectives editor))
      (format out "perspective ~A~%" (perspective-name p))
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
    (format out "current ~A~%" (perspective-name (current-perspective editor)))))

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
line that does not parse, or names a perspective nothing, is skipped."
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
              (cond ((string= keyword "perspective")
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
  "The text of the first perspectives file that is there, or NIL."
  (dolist (path *perspective-files* nil)
    (let ((text (read-file-text path)))
      (when text (return text)))))

(defun perspective-save (editor)
  "The perspectives into every file: the paths that could not be written."
  (let ((text (perspectives-text editor)))
    (remove-if (lambda (path) (snapshot-write-file path text))
               *perspective-files*)))

(defun perspective-autosave (editor)
  "At a quit: the file kept in step once it exists -- saving once opts
in, for this file and for the layout file (QUIT-REQUESTED writes that
one next, through SNAPSHOT-AUTOSAVE).  True when it was written."
  (when (some (lambda (path) (ignore-errors (probe-file path))) *perspective-files*)
    (null (perspective-save editor))))

(defun perspective-restore (editor &optional (text (perspectives-read)))
  "The perspectives of TEXT (the file's, by default) into the running
editor: each made when missing, its root set, its files opened into it
-- a file open elsewhere moved, one that is not there or cannot be read
skipped -- the recorded document made its active one, and the recorded
perspective (or the first) brought in front.  Three values: the
perspectives made, the files opened, the files skipped; NIL when there
is no file."
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
            ;; The file's files are opened now, so none wait (a
            ;; perspective listed at the start).
            (setf (perspective-pending-files p) '()
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
  "A start: the perspectives of TEXT (the file's, by default) made by
name with their roots, their files and recorded document kept WAITING on
them -- nothing opened, nothing brought in front -- so the editor comes
up with the window it always did (the files named on the command line,
else an unnamed buffer, in the first perspective listed) and the user
picks the perspective to reopen from the menu, at `C-x x s' or over the
port; that first switch opens its files (PERSPECTIVE-OPEN-PENDING).  The
file's `current' line is not honoured: no perspective is restored.  The
number of perspectives listed, or NIL when there is no file."
  (when text
    (let ((made 0))
      (dolist (e (perspectives-parse text))
        (unless (find-perspective editor (getf e :name))
          (let ((p (make-perspective editor (getf e :name) :root (getf e :root))))
            (setf (perspective-pending-files p) (getf e :files)
                  (perspective-pending-active p) (getf e :active))
            (incf made))))
      made)))

;;; ------------------------------------------------------------------
;;; The menu's group
;;; ------------------------------------------------------------------

(defun perspective-menu (editor)
  "The Perspectives menu as it should be now: (NAME . PERSPECTIVE) for
each, in the order made; the one in front is the ticked object."
  (mapcar (lambda (p) (cons (perspective-name p) p)) (editor-perspectives editor)))

(defun perspective-menu-pick (editor p)
  "Bring P in front, as its item does.  True when P is a perspective of
the editor's."
  (when (and (perspective-p p) (member p (editor-perspectives editor)))
    (perspective-switch editor p)
    t))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun perspective-completer (editor)
  (lambda (prefix) (complete (perspective-names editor) prefix)))

(defun perspective-named-or-new (editor name)
  "The perspective NAME, made when there is none: two values, the
perspective and whether it was made now; NIL for no name."
  (let ((name (string-trim " " name)))
    (cond ((string= name "") nil)
          ((find-perspective editor name))
          (t (values (make-perspective editor name) t)))))

(define-command clamacs-perspective-switch (doc arg)
  "Switch to a perspective by name, with completion.  A name no
perspective has makes a new, empty one and switches to it, where an
unnamed buffer opens.  The name of the one in front opens its files when
they are still waiting from the start, and is refused otherwise."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (prompt doc "Perspective: "
            (lambda (doc answer)
              (multiple-value-bind (p new) (perspective-named-or-new editor answer)
                (cond ((null p)
                       (message doc "A perspective needs a name")
                       (doc-beep doc))
                      ((and (eq p (current-perspective editor))
                            (not (perspective-pending-p p)))
                       (message doc "Already in ~A" (perspective-name p)))
                      (new
                       (perspective-switch editor p :say nil)
                       (perspective-note editor "New perspective: ~A" (perspective-name p)))
                      (t (perspective-switch editor p)))))
            :completer (perspective-completer editor))))

(defun perspective-step (doc delta)
  (let ((editor (doc-editor doc)))
    (if (rest (editor-perspectives editor))
        (perspective-switch editor (perspective-neighbour editor delta))
        (message doc "Only one perspective (~A)" (perspective-name (current-perspective editor))))))

(define-command clamacs-perspective-next (doc arg)
  "Switch to the next perspective, in the order they were made."
  (declare (ignore arg))
  (perspective-step doc 1))

(define-command clamacs-perspective-previous (doc arg)
  "Switch to the previous perspective, in the order they were made."
  (declare (ignore arg))
  (perspective-step doc -1))

(define-command clamacs-perspective-rename (doc arg)
  "Rename the perspective in front; the prompt offers its name."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (p (current-perspective editor)))
    (prompt doc "Rename perspective to: "
            (lambda (doc answer)
              (let* ((name (string-trim " " answer))
                     (taken (find-perspective editor name)))
                (cond ((string= name "")
                       (message doc "A perspective needs a name")
                       (doc-beep doc))
                      ((and taken (not (eq taken p)))
                       (message doc "There is a perspective called ~A already" name)
                       (doc-beep doc))
                      (t
                       (let ((old (perspective-name p)))
                         (setf (perspective-name p) name)
                         (repl-sync-title editor)
                         (message doc "Renamed ~A to ~A" old name))))))
            :initial (perspective-name p))))

(define-command clamacs-perspective-close (doc arg)
  "Close the perspective in front: the editor switches to the previous
one, the buffers of this one are closed -- each unsaved one asks -- and
the perspective is forgotten.  The only perspective cannot be closed."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (p (current-perspective editor))
         (name (perspective-name p)))
    (case (perspective-close editor p)
      (:only
       (message doc "~A is the only perspective" name)
       (doc-beep doc))
      (:cancelled
       (perspective-note editor "Cancelled; ~A stays" name))
      (t
       (perspective-note editor "Closed perspective ~A" name)))))

(define-command clamacs-perspective-move-buffer (doc arg)
  "Move this buffer into a perspective named at the prompt (made when
new), where its window is shown; here it is hidden.  When that leaves
the perspective in front empty, the editor follows the buffer."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (if (tool-document-p doc)
        (progn
          (message doc "~A is a tool buffer, shown in every perspective" (doc-name doc))
          (doc-beep doc))
        (prompt doc "Move buffer to perspective: "
                (lambda (doc answer)
                  (let ((p (perspective-named-or-new editor answer))
                        (from (current-perspective editor)))
                    (cond ((null p)
                           (message doc "A perspective needs a name")
                           (doc-beep doc))
                          ((eq p from)
                           (message doc "~A is in ~A already" (doc-name doc) (perspective-name p)))
                          (t
                           (perspective-move doc p)
                           ;; Where P comes back to: this buffer.
                           (setf (perspective-active p) doc)
                           (let ((left (perspective-live-documents from)))
                             (if left
                                 (doc-activate (first left))
                                 (perspective-switch editor p :say nil)))
                           (perspective-note editor "~A moved to ~A" (doc-name doc)
                                             (perspective-name p))))))
                :completer (perspective-completer editor)))))

(defun prompt-for-directory (doc label initial continuation)
  "Prompt for a directory with LABEL, path completion on TAB (which
descends into a directory), seeded with INITIAL.  CONTINUATION gets DOC
and the directory, normalized (a `/' after it), when it is there; an
empty answer hands NIL; a directory that is not there is refused."
  (prompt doc label
          (lambda (doc answer)
            (let ((dir (normalize-directory answer)))
              (cond ((null dir)
                     (funcall continuation doc nil))
                    ((not (directory-exists-p dir))
                     (message doc "No such directory: ~A" dir)
                     (doc-beep doc))
                    (t (funcall continuation doc dir)))))
          :initial initial
          :completer #'complete-path
          :history (editor-file-history (doc-editor doc))))

(define-command clamacs-perspective-set-directory (doc arg)
  "Set the project directory of the perspective in front: where a file
prompt starts in a buffer without a file, and where the ASDF commands
look for the system.  An empty answer takes it away."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (p (current-perspective editor)))
    (prompt-for-directory doc "Project directory: " (or (perspective-root p) "")
                          (lambda (doc dir)
                            (setf (perspective-root p) dir)
                            (cond (dir
                                   (message doc "~A: project directory ~A" (perspective-name p) dir)
                                   ;; The directory of the perspective in front
                                   ;; changed: amilisp follows, as at a switch.
                                   (when (eq p (editor-perspective editor))
                                     (perspective-tell-root editor p)))
                                  (t
                                   (message doc "~A has no project directory now" (perspective-name p))))))))

(define-command clamacs-perspective-open-project (doc arg)
  "Open a project: a directory asked for at the prompt becomes a
perspective named after it, with the directory as its project directory,
and the editor switches to it.  A perspective of that name is switched to."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (prompt-for-directory doc "Project directory: " (doc-directory doc)
                          (lambda (doc dir)
                            (cond ((null dir)
                                   (message doc "A project needs a directory")
                                   (doc-beep doc))
                                  (t
                                   (multiple-value-bind (p new) (perspective-open-project editor dir)
                                     (perspective-note editor "~A ~A (~A)"
                                                       (if new "New project" "Project")
                                                       (perspective-name p)
                                                       (perspective-root p)))))))))

(define-command clamacs-perspective-save (doc arg)
  "Save the perspectives -- each with its project directory and its
files -- to the perspectives file, which a start without files restores
and every later quit keeps in step, the windows' places with it."
  (declare (ignore arg))
  (let* ((editor (doc-editor doc))
         (failed (perspective-save editor)))
    (cond (failed
           (message doc "Cannot write ~{~A~^ or ~}" failed)
           (doc-beep doc))
          (t
           (message doc "Saved ~D perspective(s) to ~A"
                    (length (editor-perspectives editor))
                    (car (last *perspective-files*)))))))

(define-command clamacs-perspective-restore (doc arg)
  "Restore the perspectives from the file into the running editor: the
ones missing are made, their files opened, the recorded one switched to."
  (declare (ignore arg))
  (let ((editor (doc-editor doc)))
    (multiple-value-bind (made opened skipped) (perspective-restore editor)
      (cond ((null made)
             (message doc "No perspectives file (~A)" (first *perspective-files*))
             (doc-beep doc))
            (t
             (perspective-note editor "Restored: ~D perspective(s) made, ~D file(s) opened~A"
                               made opened
                               (if (> skipped 0) (format nil ", ~D missing" skipped) "")))))))
