;;;; snapshot.lisp -- window positions: the roles, the file, the command.
;;;;
;;;; The store itself (winstore.lisp) is data; this is what the editor does
;;;; with it, the port of src/snapshot.c written against the frontend
;;;; protocol:
;;;;
;;;;   - every document gets a ROLE when it is made (NEXT-DOCUMENT-ROLE):
;;;;     a file window the lowest free `docN', a scratch window its name's
;;;;     role;
;;;;   - at startup, SNAPSHOT-LOAD reads the file into the editor's layout,
;;;;     and a frontend asks LAYOUT-PLACE for a window's stored geometry
;;;;     when it creates the window -- the one place a position comes from;
;;;;   - `clamacs-snapshot-windows' reads every open window's geometry
;;;;     through DOC-GEOMETRY and EDITOR-AUX-WINDOWS, puts it in the store
;;;;     and writes the file to ENV: and ENVARC:;
;;;;   - the port's GETWINDOW says where the active window is and under
;;;;     which role, so drive.rexx can check the file against the window.
;;;;
;;;; Why not MUI's snapshot (MUIA_Window_ID)?  MUI 3.8 snapshots one window
;;;; at a time from that window's own MUI menu, and a window that has an ID
;;;; takes MUI's snapshot over any LeftEdge/TopEdge it was created with --
;;;; so the two mechanisms would fight.  The editor's windows therefore
;;;; carry no MUI ID, on MUI 3.8 and MUI 4 alike, and the file is plain text
;;;; the user can read and edit.
;;;;
;;;; Pure: no MUI, no OS types.  The file I/O is Common Lisp's own.

(in-package :clamacs)

;;; ENV: is what this boot reads, ENVARC: is what the next one copies to
;;; ENV:.  On the host (the tests) there is one file, bound per test.  Asked
;;; when the file loads, not with #+amigaos: the release compiles the FASL
;;; with the HOST binary, which reads `#+amigaos' as false (see *INIT-FILE*).
(defun default-snapshot-files ()
  (if (member :amigaos *features*)
      (list "ENV:Clamacs/windows.cfg" "ENVARC:Clamacs/windows.cfg")
      (list (namestring (merge-pathnames ".clamacs-windows.cfg"
                                         (user-homedir-pathname))))))

(defparameter *snapshot-files* (default-snapshot-files)
  "The files a snapshot is written to, the first of them read at startup
\(the second when the first is missing).")

;;; ------------------------------------------------------------------
;;; The frontend's part
;;; ------------------------------------------------------------------

(defgeneric doc-geometry (doc)
  (:documentation "Where DOC's window is: four values, left, top, width and
height, in pixels; NIL when the window is not open."))

(defgeneric editor-aux-windows (editor)
  (:documentation "The open windows that are not documents -- the error
list, the inspector, the debugger -- as a list of (role left top width
height)."))

;;; ------------------------------------------------------------------
;;; Roles
;;; ------------------------------------------------------------------

(defun free-document-slot (editor)
  "The lowest slot no open file window holds, so the first file of a
session takes `doc1' wherever it was snapshotted, and a window closed and
reopened takes its slot back."
  (let ((used (loop for doc in (editor-documents editor)
                    for slot = (and (not (doc-closing doc))
                                    (winstore-doc-slot (doc-role doc)))
                    when slot collect slot)))
    (loop for slot from 1
          unless (member slot used) return slot)))

(defun next-document-role (editor path name)
  "The role of a document about to be made: a file window (PATH, or the
unnamed buffer) the next free `docN', a scratch window (NAME) its name's
role, or NIL for a name that leaves none."
  (if (or path (equal name *unnamed*))
      (winstore-doc-role (free-document-slot editor))
      (let ((role (winstore-scratch-role name)))
        (and (string/= role "") role))))

;;; ------------------------------------------------------------------
;;; The file
;;; ------------------------------------------------------------------

(defun snapshot-load (editor)
  "Read the layout file into EDITOR's layout: the number of entries read,
0 when there is no file."
  (let ((store (editor-layout editor)))
    (setf (winstore-entries store) '())
    (dolist (path *snapshot-files* 0)
      (let ((text (read-file-text path)))
        (when text
          (return (winstore-parse store text)))))))

(defun snapshot-write-file (path text)
  "TEXT to PATH, the drawer made first.  True when written."
  (ignore-errors (ensure-directories-exist path))
  (write-file-text path text))

(defun snapshot-save (editor)
  "Write the layout to every file: the paths that could not be written."
  (let ((text (winstore-format (editor-layout editor))))
    (remove-if (lambda (path) (snapshot-write-file path text))
               *snapshot-files*)))

(defun layout-place (editor role)
  "The stored geometry of the window ROLE: four values, left, top, width
and height, or NIL when none is stored.  A size that is not positive would
be one of MUI's special values (MUIV_Window_Width_MinMax and friends are
zero and below): such a hand-edited entry counts as none."
  (let ((e (and role (winstore-find (editor-layout editor) role))))
    (and e
         (> (winentry-width e) 0) (> (winentry-height e) 0)
         (values (winentry-left e) (winentry-top e)
                 (winentry-width e) (winentry-height e)))))

;;; ------------------------------------------------------------------
;;; The command
;;; ------------------------------------------------------------------

(defun snapshot-record (editor role left top width height)
  (if (and role (winstore-set (editor-layout editor) role left top width height))
      1
      0))

(defun snapshot-take (doc)
  "Every open window into the store, and the store into the files."
  (let ((editor (doc-editor doc))
        (count 0))
    (dolist (d (live-documents editor))
      (multiple-value-bind (left top width height) (doc-geometry d)
        (when left
          (incf count (snapshot-record editor (doc-role d) left top width height)))))
    (dolist (entry (editor-aux-windows editor))
      (incf count (apply #'snapshot-record editor entry)))
    (let ((failed (snapshot-save editor)))
      (cond (failed
             (message doc "Cannot write ~{~A~^ or ~}" failed)
             (doc-beep doc))
            (t
             (message doc "Saved the positions of ~D window(s) to ~A"
                      count (car (last *snapshot-files*))))))
    count))

(define-command clamacs-snapshot-windows (doc arg)
  (declare (ignore arg))
  (snapshot-take doc))

;;; ------------------------------------------------------------------
;;; For the port
;;; ------------------------------------------------------------------

(defun snapshot-describe (doc)
  "`role left top width height' of DOC's window, `-' for a window that has
no role."
  (multiple-value-bind (left top width height) (doc-geometry doc)
    (format nil "~A ~D ~D ~D ~D" (or (doc-role doc) "-")
            (or left 0) (or top 0) (or width 0) (or height 0))))

;;; The active window's place: `role left top width height', the role being
;;; what `clamacs-snapshot-windows' stores it under (`doc1', `repl', ...).
;;; A macro cannot move a window, so this is the read side only -- and how
;;; the unattended test checks that a snapshot wrote what the window showed
;;; and that a second editor came up where the file said.
(define-port-verb "GETWINDOW" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (values +rc-ok+ (snapshot-describe doc))))
