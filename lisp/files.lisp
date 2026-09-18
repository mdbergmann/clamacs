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

(defgeneric doc-ask-file (doc title save)
  (:documentation "The file requester behind an empty answer to `C-x C-f':
a path, or NIL when the user cancelled.  SAVE asks for a file to write."))

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
                                          (and lisp-mode (lisp-keymap)))))))

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

(defun show-file-text (doc path text)
  (doc-set-text doc text)
  (visit-path doc path)
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
  (find path (live-documents editor) :key #'doc-path :test #'equal))

(defun open-document (editor path)
  "A new window showing PATH (NIL: an unnamed Lisp buffer; a name no file
has yet: a new buffer with that name, exactly as in Emacs).  NIL when the
file is there but cannot be read."
  (if (null path)
      (editor-make-document editor :name *unnamed* :lisp-mode t)
      (let ((text (read-file-text path)))
        (when (or text (not (probe-file path)))
          (let ((doc (editor-make-document editor
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

(defun prompt-for-file (doc label continuation &key (initial "") save)
  "Prompt for a path; an empty answer means \"show me\" -- the file
requester.  CONTINUATION gets DOC and the path, unless the user cancelled."
  (prompt doc label
          (lambda (doc answer)
            (let ((path (if (string= answer "")
                            (doc-ask-file doc (string-right-trim ": " label)
                                          save)
                            answer)))
              (when path
                (funcall continuation doc path))))
          :initial initial
          :history (editor-file-history (doc-editor doc))))

(define-command find-file (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Find file: "
                   (lambda (doc path) (find-file-named doc path nil))))

(define-command find-file-other-window (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Find file: "
                   (lambda (doc path) (find-file-named doc path t))))

(define-command clamacs-new-buffer (doc arg)
  (declare (ignore arg))
  (unless (open-document (doc-editor doc) nil)
    (doc-message doc "Cannot open a new window")
    (doc-beep doc)))

(define-command write-file (doc arg)
  (declare (ignore arg))
  (prompt-for-file doc "Write file: " #'save-file
                   :initial (or (doc-path doc) "") :save t))

(define-command save-buffer (doc arg)
  (if (doc-path doc)
      (save-file doc (doc-path doc))
      (write-file doc arg)))

(defun close-document (doc &optional (ask t))
  "Close DOC's window, asking about unsaved changes first when ASK.  Saving
an unnamed buffer needs a name: the prompt opens and the window stays."
  (unless (doc-closing doc)
    (when (and ask (doc-modified-p doc))
      (case (doc-ask doc (format nil "~A has unsaved changes." (doc-name doc))
                     '(:save :discard :cancel))
        (:save
         (cond ((null (doc-path doc))
                (write-file doc 1)
                (return-from close-document nil))
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

(defun quit-requested (editor)
  "A quit command set the flag: close every window, asking about each
unsaved text unless the quit was KILL-EMACS.  A Cancel keeps the editor
running.  True when every window closed."
  (let ((ask (not (eq (editor-quitting editor) :discard))))
    (setf (editor-quitting editor) nil)
    (dolist (doc (live-documents editor) t)
      (unless (close-document doc ask)
        (return nil)))))
