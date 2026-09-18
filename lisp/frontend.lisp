;;;; frontend.lisp -- the frontend protocol.
;;;;
;;;; Commands never call MUI.  Everything the Emacs layer needs from the
;;;; toolkit goes through the generic functions below, specialised on the
;;;; document: frontend-mui.lisp is the first implementation (a window with a
;;;; TextEditor.mcc subclass in it), tests/fake-frontend.lisp the second (a
;;;; string and a cursor), and that second one is why commands.lisp is
;;;; host-tested like every other pure module.  This is the Lisp form of the
;;;; C editor's rule that the pure modules take no OS types, and it is what
;;;; keeps a later host frontend a bounded piece of work.
;;;;
;;;; The protocol is as wide as the text widgets it has to fit and no wider.
;;;; A position is a character INDEX into the whole text; a widget that
;;;; thinks in lines and columns (TextEditor.mcc, Tk's text) converts.  The
;;;; widget owns the buffer, the cursor, undo, the selection and the
;;;; clipboard: the protocol asks for the motions and edits such a widget
;;;; has anyway instead of reimplementing them on exported text, so `C-f'
;;;; and the widget's own arrow key cannot disagree.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The editor: what every document shares
;;; ------------------------------------------------------------------

(defstruct (editor (:constructor make-editor ()))
  ;; Set by save-buffers-kill-emacs; the frontend's event loop leaves.
  (quitting nil)
  (kill-ring (make-killring))
  ;; One history per KIND of prompt, since the input line is reused.
  (command-history (make-history))
  (file-history (make-history))
  (documents '())
  ;; The connection to clamiga (wire.lisp), or NIL before it is set up.
  (wire nil))

;;; ------------------------------------------------------------------
;;; The document: one text in one window.  A frontend subclasses it.
;;; ------------------------------------------------------------------

(defclass document ()
  ((editor :initarg :editor :reader doc-editor)
   (path :initarg :path :initform nil :accessor doc-path)
   ;; What the title shows: the file's name, "(unnamed)", or a scratch
   ;; window's own name ("*errors*").
   (name :initarg :name :initform "(unnamed)" :accessor doc-name)
   ;; Retired: off the screen, waiting for the frontend to dispose of it.
   (closing :initform nil :accessor doc-closing)
   (lisp-mode :initarg :lisp-mode :initform t :accessor doc-lisp-mode)
   (keys :accessor doc-keys)
   (mark :initform nil :accessor doc-mark)
   ;; The open prompt or search (minibuffer.lisp), or NIL.
   (minibuffer :initform nil :accessor doc-minibuffer)
   ;; The command that ran before this one: consecutive kills join, and
   ;; `M-y' is only valid after a yank.  NIL after an unbound key.
   (last-command :initform nil :accessor doc-last-command)
   ;; Where the paren highlight is, as (y . x), to take it down again.
   (paren-shown :initform nil :accessor doc-paren-shown)))

(defmethod initialize-instance :after ((doc document) &key)
  (setf (doc-keys doc)
        (make-keystate (global-keymap)
                       (and (doc-lisp-mode doc) (lisp-keymap))))
  (push doc (editor-documents (doc-editor doc))))

(defun doc-kill-ring (doc)
  (editor-kill-ring (doc-editor doc)))

;;; ------------------------------------------------------------------
;;; Text access
;;; ------------------------------------------------------------------

(defgeneric doc-point (doc)
  (:documentation "The cursor, as an index into the text."))

(defgeneric doc-set-point (doc index)
  (:documentation "Move the cursor to INDEX (clamped to the text) and keep
it in view."))

(defgeneric doc-end (doc)
  (:documentation "The index past the last character: the text's length."))

(defgeneric doc-line-count (doc)
  (:documentation "The number of lines; an empty text has one."))

(defgeneric doc-index-line (doc index)
  (:documentation "The line INDEX is in and its column there, two values,
both counted from 0."))

(defgeneric doc-line-index (doc y)
  (:documentation "The index at which line Y starts.  Y is clamped to the
lines there are."))

(defgeneric doc-text (doc start end)
  (:documentation "The text from START to END, a fresh SIMPLE-STRING with
lines separated by #\\Newline and no styling."))

(defgeneric doc-lines-text (doc y0 y1)
  (:documentation "Lines Y0 to Y1 inclusive, whole, as DOC-TEXT gives them;
the newline of Y1 is included when it has one."))

;;; ------------------------------------------------------------------
;;; Editing.  Each call is one undo step of the widget.
;;; ------------------------------------------------------------------

(defgeneric doc-insert (doc text)
  (:documentation "Insert TEXT at the cursor; the cursor ends up after it."))

(defgeneric doc-delete (doc start end)
  (:documentation "Delete the text from START to END without touching the
clipboard; the cursor ends up at START."))

(defgeneric doc-move (doc motion)
  (:documentation "One of the widget's own cursor motions: :LEFT :RIGHT :UP
:DOWN :LINE-START :LINE-END :TEXT-START :TEXT-END :NEXT-WORD :PREVIOUS-WORD
:NEXT-PAGE :PREVIOUS-PAGE.  True when the widget accepted it."))

(defgeneric doc-edit (doc operation)
  (:documentation "One of the widget's own edits: :DELETE (the character at
the cursor) :BACKSPACE :UNDO :REDO :SELECT-ALL :SELECT-NONE.  True when the
widget accepted it."))

(defgeneric doc-clipboard-copy (doc start end cut)
  (:documentation "Put the text from START to END on the system clipboard,
deleting it when CUT.  `C-w' and `M-w' mirror their kill there so other
applications see it; the kill ring itself never reads the clipboard."))

;;; ------------------------------------------------------------------
;;; Presentation
;;; ------------------------------------------------------------------

(defgeneric doc-message (doc text)
  (:documentation "Show TEXT in the echo area."))

(defgeneric doc-message-text (doc)
  (:documentation "What the echo area shows: the last DOC-MESSAGE, or the
prompt's label while one is open.  The port's STATUS command reads it."))

(defgeneric doc-widget-command (doc command)
  (:documentation "One of the text widget's OWN commands, TextEditor.mcc's
ARexx set (`GETCURSOR LINE', `POSITION SOL'): the text it answers, T for
a command that answered nothing, NIL when the widget did not take it."))

(defgeneric editor-active-document (editor)
  (:documentation "The document the port's commands and the messages mean:
the one whose window is active."))

(defgeneric editor-show-diagnostics (editor rows &key open)
  (:documentation "Fill the diagnostics window with ROWS, one string per
line, nothing selected; open it when OPEN, or when there are rows.  A row
the user selects there is DIAGNOSTIC-JUMPed to (wire.lisp)."))

(defgeneric editor-select-diagnostic (editor row)
  (:documentation "Show ROW (0-based, NIL for none) as the selected row of
the diagnostics window, without jumping to it."))

(defgeneric doc-beep (doc)
  (:documentation "The error signal: a display beep."))

(defgeneric doc-colour (doc y x0 x1 colour)
  (:documentation "Colour columns X0 to X1 of line Y.  COLOUR is a token
kind (:COMMENT :STRING :CHAR :KEYWORD :NUMBER :DEFINING), :PAREN-MATCH, or
NIL for the normal pen.  Colour is presentation, not content: it must not
mark the text modified."))

(defgeneric doc-call-quietly (doc function)
  (:documentation "Call FUNCTION with display updates held back, for an
operation that touches many lines.")
  (:method ((doc document) function)
    (funcall function)))

(defmacro with-quiet-display ((doc) &body body)
  `(doc-call-quietly ,doc (lambda () ,@body)))

(defun message (doc control &rest args)
  "FORMAT into the echo area."
  (doc-message doc (apply #'format nil control args)))
