;;;; files.lisp -- files, buffers and windows.
;;;;
;;;; A document is one text in one window, so "buffer" and "window" commands
;;;; are both about documents: find-file loads into THIS window (as Emacs
;;;; does) unless the file already has one, find-file-other-window always
;;;; opens another, kill-buffer closes the window.  File I/O is Common Lisp's
;;;; own; the toolkit's part -- replacing the text, the modified flag, the
;;;; title, the file requester, the "unsaved changes" requester, raising and
;;;; closing a window, making a new one -- is the protocol below.
;;;;
;;;; The editor is 8-bit: files are read and written as ISO-8859-1, byte for
;;;; character, whatever the host's default encoding is.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The frontend's part
;;; ------------------------------------------------------------------

(defgeneric doc-set-text (doc text)
  (:documentation "Replace the whole text; the cursor goes to the start.
This is not an edit: the text is unmodified afterwards."))

(defgeneric doc-modified-p (doc))

(defgeneric doc-set-modified (doc flag))

(defgeneric doc-set-title (doc title)
  (:documentation "The window's title."))

(defgeneric doc-ask-file (doc title save initial)
  (:documentation "The file requester: a path, or NIL when the user
cancelled.  SAVE asks for a file to write.  INITIAL is where it opens --
a directory, or a file whose directory it shows and whose name it offers
(what Save As seeds it with); \"\" leaves that to the toolkit."))

(defgeneric doc-ask (doc question choices)
  (:documentation "A requester with QUESTION and one button per keyword in
CHOICES, the last of which is the cancel position.  Returns the keyword
chosen."))

(defgeneric doc-activate (doc)
  (:documentation "Bring the window to the front and give its text the
keyboard."))

(defgeneric doc-close-window (doc)
  (:documentation "Take the window off the screen.  Called from inside the
window's own event handling, so a frontend retires the window here and
disposes of it later, from its event loop."))

(defgeneric editor-make-document (editor &key path name lisp-mode)
  (:documentation "A new document in a window of its own, empty and named
NAME; the caller loads PATH into it."))

;;; ------------------------------------------------------------------
;;; Names and modes
;;; ------------------------------------------------------------------

(defparameter *unnamed* "(unnamed)")

(defun path-basename (path)
  "What follows the last `/' or `:' -- AmigaDOS and POSIX paths alike."
  (let ((cut (position-if (lambda (c) (or (char= c #\/) (char= c #\:)))
                          path :from-end t)))
    (if cut (subseq path (1+ cut)) path)))

(defun path-directory (path)
  "PATH up to and including its last `/' or `:'; \"\" when it has none."
  (subseq path 0 (- (length path) (length (path-basename path)))))

(defun doc-directory (doc)
  "Where a file prompt of DOC starts: its file's directory, or nowhere in
particular (\"\") for a buffer without one."
  (path-directory (or (doc-path doc) "")))

(defun lisp-path-p (path)
  (let ((dot (position #\. path :from-end t)))
    (and dot
         (member (subseq path dot) '(".lisp" ".lsp" ".cl" ".asd")
                 :test #'string=)
         t)))

(defun doc-holds-file-p (doc)
  "Is this a file window -- one that find-file may load another file into?
A window with a path is; so is the unnamed window the editor opens at
startup.  The scratch windows (*description*, *errors*, ...: no path, a name
of their own) keep their text and get a new window instead."
  (and (or (doc-path doc) (equal (doc-name doc) *unnamed*)) t))

(defun set-lisp-mode (doc lisp-mode)
  (let ((lisp-mode (and lisp-mode t)))
    (unless (eq lisp-mode (and (doc-lisp-mode doc) t))
      (setf (doc-lisp-mode doc) lisp-mode
            (doc-keys doc) (make-keystate (global-keymap)
                                          (and lisp-mode (lisp-keymap))))
      (doc-lisp-mode-changed doc))))

(defun visit-path (doc path)
  "DOC now shows PATH: the name, the title, the mode and the state that
belonged to the old text."
  (setf (doc-path doc) path
        (doc-name doc) (path-basename path)
        (doc-mark doc) nil
        (doc-paren-shown doc) nil)
  (doc-set-title doc (doc-name doc))
  (set-lisp-mode doc (lisp-path-p path)))

;;; ------------------------------------------------------------------
;;; Reading and writing
;;; ------------------------------------------------------------------

(defun read-file-text (path)
  "The contents of PATH as a string, or NIL when it cannot be read."
  (handler-case
      (with-open-file (in path :external-format :latin-1)
        (let* ((text (make-string (file-length in)))
               (n (read-sequence text in)))
          (if (= n (length text)) text (subseq text 0 n))))
    (error () nil)))

(defun write-file-text (path text)
  "Write TEXT to PATH.  True when it was written."
  (handler-case
      (with-open-file (out path :direction :output :if-exists :supersede
                                :external-format :latin-1)
        (write-string text out)
        t)
    (error () nil)))

(defun delete-quietly (path)
  "Remove PATH if it exists; a failure is nobody's concern (a launch's
scratch files)."
  (ignore-errors (when (probe-file path) (delete-file path))))

(defun show-file-text (doc path text)
  (doc-set-text doc text)
  (visit-path doc path)
  ;; The arglist shown belonged to the old text (introspect.lisp).
  (forget-arglist doc)
  (colour-all doc)
  t)

(defun load-file (doc path)
  "Show the file PATH in DOC.  NIL, with DOC untouched, when it cannot be
read."
  (let ((text (read-file-text path)))
    (and text (show-file-text doc path text))))

(defun save-file (doc path)
  "Write DOC's text to PATH, which becomes its file.  Says what happened."
  (cond ((write-file-text path (doc-text doc 0 (doc-end doc)))
         (unless (equal path (doc-path doc))
           (let ((point (doc-point doc)) (mark (doc-mark doc))
                 (shown (doc-paren-shown doc)))
             ;; VISIT-PATH drops PAREN-SHOWN without telling the widget: take
             ;; the highlight down first, or it is left painted with nothing
             ;; that will ever clear it.
             (when shown
               (doc-colour doc (car shown) (cdr shown) (1+ (cdr shown)) nil))
             (visit-path doc path)
             (setf (doc-mark doc) mark)
             (doc-set-point doc point)
             ;; Recolour: harmless when the mode did not change, needed when
             ;; it did (LOAD-FILE's SHOW-FILE-TEXT does the same).
             (colour-all doc)))
         (doc-set-modified doc nil)
         (message doc "Wrote ~A" path)
         t)
        (t
         (message doc "Cannot write ~A" path)
         nil)))

(defun release-text (doc)
  "Before DOC's text is replaced or its window closed: ask about unsaved
changes.  True when the text may go -- it was clean, saved, or discarded.
An unnamed buffer cannot be saved in place, so it is only offered Discard
and Cancel."
  (let ((question (format nil "~A has unsaved changes." (doc-name doc))))
    (cond ((not (doc-modified-p doc)) t)
          ((null (doc-path doc))
           (eq (doc-ask doc question '(:discard :cancel)) :discard))
          (t
           (case (doc-ask doc question '(:save :discard :cancel))
             (:save (save-file doc (doc-path doc)))
             (:discard t)
             (t nil))))))

;;; ------------------------------------------------------------------
;;; Opening and closing
;;; ------------------------------------------------------------------

(defun live-documents (editor)
  "The open documents, oldest first."
  (reverse (remove-if #'doc-closing (editor-documents editor))))

(defun find-document-by-path (editor path)
  "The window showing PATH.  AmigaDOS paths are case-insensitive, and
clamiga spells a path back (a diagnostic's, a source location's) as it
was given, not necessarily as the window was opened."
  (find-if (lambda (doc)
             (let ((p (doc-path doc)))
               (and p (string-equal p path))))
           (live-documents editor)))

(defun find-scratch-document (editor name)
  "The scratch window called NAME -- no file, a name of its own."
  (find-if (lambda (doc)
             (and (null (doc-path doc)) (equal (doc-name doc) name)))
           (live-documents editor)))

(defun ensure-scratch-document (editor name lisp-mode)
  "The scratch window NAME (*clamacs-description*, ...), made when there
is none, in LISP-MODE or not.  NIL when no window could be made."
  (let ((doc (find-scratch-document editor name)))
    (cond (doc
           (set-lisp-mode doc lisp-mode)
           doc)
          (t
           (editor-make-document editor :name name :lisp-mode lisp-mode)))))

(defun open-document (editor path)
  "A new window showing PATH (NIL: an unnamed Lisp buffer; a name no file
has yet: a new buffer with that name, exactly as in Emacs).  NIL when the
file is there but cannot be read."
  (if (null path)
      (editor-make-document editor :name *unnamed* :lisp-mode t)
      (let ((text (read-file-text path)))
        (when (or text (not (probe-file path)))
          ;; PATH goes in at creation: the window's role (snapshot.lisp)
          ;; is a file window's from the start.
          (let ((doc (editor-make-document editor
                                           :path path
                                           :name (path-basename path)
                                           :lisp-mode (lisp-path-p path))))
            (cond (text (show-file-text doc path text))
                  (t (visit-path doc path)
                     (doc-message doc "(New file)")))
            doc)))))

(defun find-file-named (doc path other-window)
  (let* ((editor (doc-editor doc))
         (open (and (not other-window) (find-document-by-path editor path))))
    (cond
      ;; A file that is open already has a window: go there, as Emacs
      ;; switches to the buffer it already has.
      (open (doc-activate open))
      ((and (not other-window) (doc-holds-file-p doc))
       (when (release-text doc)
         (cond ((load-file doc path))
               ((probe-file path)
                (message doc "Cannot open ~A" path))
               (t
                (doc-set-text doc "")
                (visit-path doc path)
                (doc-message doc "(New file)")))))
      ((null (open-document editor path))
       (message doc "Cannot open ~A" path)))))

;;; ------------------------------------------------------------------
;;; Asking for a file: the prompt and the requester
;;; ------------------------------------------------------------------

;;; Two ways in, as in Emacs on a GUI: the keys open a prompt in the
;;; minibuffer, the menu opens the requester.  At the prompt TAB completes
;;; the name against the directory typed so far, and on a line that names
;;; no file yet -- empty, or a bare directory -- TAB (or RET) opens the
;;; requester there instead, which the label says.  The C editor hid the
;;; requester behind RET on an empty line and nothing else, and nobody
;;; found it.

(defun directory-only-p (text)
  "Whether TEXT names no file: empty, or ending in a `/' or `:'."
  (or (string= text "")
      (let ((last (char text (1- (length text)))))
        (or (char= last #\/) (char= last #\:)))))

(defun complete-path (text)
  "Completion of the file name in TEXT against its directory, as COMPLETE
answers: the matching paths, directories with a `/' after them so the
next TAB descends, and their common prefix.  The name part is matched
without regard to case (AmigaDOS has none; nor does the Mac), and the
completion is the file's own spelling.  COMPLETE finds the common prefix
case-sensitively, so two matches that differ only in case inside the typed
part share less than TEXT: the line then stays as typed, and TAB only
counts.  A directory that cannot be listed matches nothing."
  (let* ((dir (path-directory text))
         (name (path-basename text))
         (n (length name))
         (paths (ignore-errors
                 (mapcar #'namestring
                         (directory (concatenate 'string dir "*")))))
         (matches '()))
    (dolist (path paths)
      (let ((base (path-basename (string-right-trim "/" path))))
        (when (and (>= (length base) n)
                   (string-equal name base :end2 n))
          (push (concatenate 'string dir base
                             (if (directory-only-p path) "/" ""))
                matches))))
    (multiple-value-bind (matches common) (complete (nreverse matches) "")
      (values matches
              (if (< (length common) (length text)) text common)))))

(defun ask-file-then (doc title save initial continuation)
  "The requester, titled TITLE, opening at INITIAL; the path chosen goes
to CONTINUATION with DOC, and into the file history.  Nothing happens
when the user cancelled."
  (let ((path (doc-ask-file doc title save initial)))
    (when path
      (hist-add (editor-file-history (doc-editor doc)) path)
      (funcall continuation doc path)
      t)))

(defun prompt-for-file (doc label continuation &key (initial "") save
                                                    (title (string-right-trim ": " label)))
  "Prompt for a path with LABEL, completing on TAB.  A line that names no
file (empty, or a directory) opens the requester TITLE there on TAB or
RET; an empty line opens it where INITIAL points, or in the buffer's own
directory.  CONTINUATION gets DOC and the path, unless the user
cancelled."
  (flet ((requester (text)
           ;; From the completer the prompt is still open: it goes before
           ;; the continuation, which may open the next one.
           (let ((seed (cond ((string/= text "") text)
                             ((string/= initial "") initial)
                             (t (doc-directory doc)))))
             (ask-file-then doc title save seed
                            (lambda (doc path)
                              (when (minibuffer-open-p doc)
                                (minibuffer-finish doc))
                              (funcall continuation doc path))))))
    (prompt doc (format nil "~A (TAB: browse): " (string-right-trim ": " label))
            (lambda (doc answer)
              (if (string= answer "")
                  (requester "")
                  (funcall continuation doc answer)))
            :initial initial
            :completer (lambda (text)
                         (if (directory-only-p text)
                             (progn (requester text) :handled)
                             (complete-path text)))
            :history (editor-file-history (doc-editor doc)))))

(define-command find-file (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Find file: "
                   (lambda (doc path) (find-file-named doc path nil))
                   :title "Open"))

(define-command find-file-other-window (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Find file: "
                   (lambda (doc path) (find-file-named doc path t))
                   :title "Open in New Window"))

;;; The menu's entrances: Open... and friends carry an ellipsis, so they
;;; open the requester itself, the way Emacs's File menu does with a
;;; mouse.  Each is a command in its own right, for `M-x' or a key of
;;; the user's.

(define-command find-file-requester (doc arg)
  "Open a file chosen in the requester, as `find-file' opens one typed."
  (declare (ignore arg))
  (ask-file-then doc "Open" nil (doc-directory doc)
                 (lambda (doc path) (find-file-named doc path nil))))

(define-command find-file-other-window-requester (doc arg)
  "Open a file chosen in the requester in a window of its own."
  (declare (ignore arg))
  (ask-file-then doc "Open in New Window" nil (doc-directory doc)
                 (lambda (doc path) (find-file-named doc path t))))

(define-command clamacs-new-buffer (doc arg)
  (declare (ignore arg))
  (unless (open-document (doc-editor doc) nil)
    (doc-message doc "Cannot open a new window")
    (doc-beep doc)))

(define-command write-file (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Write file: " #'save-file
                   :initial (or (doc-path doc) "") :save t :title "Save As"))

(define-command write-file-requester (doc arg)
  "Save the buffer under a name chosen in the requester, which offers its
current one."
  (declare (ignore arg))
  (ask-file-then doc "Save As" t (or (doc-path doc) "") #'save-file))

(define-command save-buffer (doc arg)
  (if (doc-path doc)
      (save-file doc (doc-path doc))
      (write-file doc arg)))

(define-command save-buffer-requester (doc arg)
  "Save: in place when the buffer has a file, else under a name from the
requester -- the menu's Save, which never drops into the minibuffer."
  (if (doc-path doc)
      (save-file doc (doc-path doc))
      (write-file-requester doc arg)))

(defun close-document (doc &optional (ask t))
  "Close DOC's window, asking about unsaved changes first when ASK.  Saving
an unnamed buffer needs a name: the requester opens (the user is in a
requester already) and the window stays."
  (unless (doc-closing doc)
    ;; A transcript is not a file: the REPL window never asks to save, and
    ;; closing it stops clamiga's REPL thread (repl.lisp).
    (when (doc-repl doc)
      (repl-closed doc)
      (setq ask nil))
    (when (and ask (doc-modified-p doc))
      (case (doc-ask doc (format nil "~A has unsaved changes." (doc-name doc))
                     '(:save :discard :cancel))
        (:save
         (cond ((null (doc-path doc))
                ;; Named and written in the requester: the close goes on.
                (write-file-requester doc 1)
                (when (or (null (doc-path doc)) (doc-modified-p doc))
                  (return-from close-document nil)))
               ((not (save-file doc (doc-path doc)))
                (return-from close-document nil))))
        (:discard)
        (t (return-from close-document nil))))
    (setf (doc-closing doc) t)
    (doc-close-window doc)
    t))

(define-command kill-buffer (doc arg)
  (declare (ignore arg))
  (close-document doc))

(defun next-document (doc)
  (let* ((docs (live-documents (doc-editor doc)))
         (rest (rest (member doc docs))))
    (or (first rest) (first docs))))

(define-command other-window (doc arg)
  (declare (ignore arg))
  (let ((next (next-document doc)))
    (when (and next (not (eq next doc)))
      (doc-activate next))))

;;; One document per window, so switching buffers is switching windows.
(define-command switch-to-buffer (doc arg)
  (other-window doc arg))

(define-command save-buffers-kill-emacs (doc arg)
  (declare (ignore arg))
  ;; The frontend's event loop sees the flag and leaves; it closes the
  ;; windows through CLOSE-DOCUMENT, which asks about each unsaved text.
  (setf (editor-quitting (doc-editor doc)) t))

(define-command kill-emacs (doc arg)
  "Quit without asking: unsaved changes are discarded.  What a macro or an
unattended run wants -- a requester nobody is there to answer would hold
the editor -- and what the C editor's quit always did."
  (declare (ignore arg))
  (setf (editor-quitting (doc-editor doc)) :discard))

;;; ------------------------------------------------------------------
;;; The user's init file
;;; ------------------------------------------------------------------

;;; Asked when the file loads, not with #+amigaos: the release compiles this
;;; file's FASL with the HOST binary, which reads `#+amigaos' as false, so the
;;; shipped editor would look for the host's ~/.clamacsrc on the Amiga.
(defun default-init-file ()
  "S:.clamacsrc on an Amiga, .clamacsrc in the home directory elsewhere."
  (if (member :amigaos *features*)
      "S:.clamacsrc"
      (namestring (merge-pathnames ".clamacsrc" (user-homedir-pathname)))))

(defparameter *init-file* (default-init-file)
  "Loaded by LOAD-INIT-FILE before the first window is made: DEFINE-COMMAND
and BIND-KEY forms in the CLAMACS package, mostly.  It runs after an image
restores, so EXT:*IMAGE-RESTORED-P* lets it skip loads the image holds.")

(defvar *theme-persist* t
  "Whether LOAD-THEME (theme.lisp) writes the choice into the init file.
Bound to NIL while the init file loads: its own `(load-theme ...)' form
is the record, not something to write back into the file being read.")

(defun load-init-file (&optional (path *init-file*))
  "LOAD PATH, the user's init file, when there is one, in the CLAMACS
package: T when it loaded, NIL when there is none.  A form that signals
is reported by LOAD itself, with the file and the line, and the forms
after it still load -- deliberately outside any handler, since a
HANDLER-CASE around LOAD would end the load at the first mistake instead."
  (and (probe-file path)
       (let ((*package* (find-package :clamacs))
             (*theme-persist* nil))
         (load path)
         t)))

(defun quit-requested (editor)
  "A quit command set the flag: close every window, asking about each
unsaved text unless the quit was KILL-EMACS.  A Cancel keeps the editor
running.  True when every window closed."
  (let ((ask (not (eq (editor-quitting editor) :discard))))
    (setf (editor-quitting editor) nil)
    (dolist (doc (live-documents editor) t)
      (unless (close-document doc ask)
        (return nil)))))
