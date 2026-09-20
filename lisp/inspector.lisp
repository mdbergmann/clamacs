;;;; inspector.lisp -- the inspector window.
;;;;
;;;; `C-c I' asks for a form, clamiga evaluates it and answers INSPECT with
;;;; the object and its numbered parts (cl-amiga's lib/dev-commands.lisp: a
;;;; header `<TYPE> <depth> <count>', the object, then `<n>: <label> =
;;;; <value>' per part).  The window shows the object and the parts; a
;;;; double-click on a part sends PART <n> and the window shows that, Back
;;;; sends POP.  The navigation stack lives in clamiga, one per connection,
;;;; so the editor only mirrors the depth it is told.  Synchronous replies,
;;;; unlike the debugger's: the object is evaluated on the port's handler
;;;; thread (with the REPL's `*' in scope, so `C-c I *' looks at the last
;;;; REPL value).  This is the port of src/inspectwin.c.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defstruct (inspector (:constructor make-inspector ()))
  (depth 0)                 ; 0: nothing is being inspected
  (type "")
  (object "")               ; the object's line
  (parts '()))              ; the rows, `<n>: <label> = <value>' (+ a `... more' row)

(defun editor-inspector-state (editor)
  (or (editor-inspector editor)
      (setf (editor-inspector editor) (make-inspector))))

(defgeneric editor-inspector-open (editor inspector)
  (:documentation "Show INSPECTOR's object and parts in the inspector
window, titled with the type, Back disabled at depth 1, nothing selected,
and open it with the keyboard."))

;;; ------------------------------------------------------------------
;;; The commands
;;; ------------------------------------------------------------------

(defun inspect-form (doc form)
  (cond ((or (null form) (string= form ""))
         (doc-beep doc))
        (t
         (let ((wire (require-wire doc)))
           (when wire
             (wire-ensure-package wire doc)
             (wire-request wire doc :inspect (concatenate 'string "INSPECT " form)))))))

(defun inspect-active (doc)
  (or (> (inspector-depth (editor-inspector-state (doc-editor doc))) 0)
      (progn (doc-message doc "Nothing is being inspected (C-c I inspects a value)")
             (doc-beep doc)
             nil)))

(defun inspect-part (doc n)
  "Descend into part N; NIL prompts for the number."
  (when (inspect-active doc)
    (cond ((null n)
           (prompt-for-number doc "Part: " #'inspect-part))
          (t
           (let ((wire (require-wire doc)))
             (when wire
               (wire-request wire doc :inspect (format nil "PART ~D" n))))))))

(defun inspect-pop (doc)
  (when (inspect-active doc)
    (cond ((= (inspector-depth (editor-inspector-state (doc-editor doc))) 1)
           (doc-message doc "Already at the object the inspector started from")
           (doc-beep doc))
          (t
           (let ((wire (require-wire doc)))
             (when wire
               (wire-request wire doc :inspect "POP")))))))

(define-command clamacs-inspect (doc arg)
  (declare (ignore arg))
  (prompt-for-form doc "Inspect value (evaluated): " #'inspect-form))

(define-command clamacs-inspector-part (doc arg)
  (declare (ignore arg))
  (inspect-part doc nil))

(define-command clamacs-inspector-pop (doc arg)
  (declare (ignore arg))
  (inspect-pop doc))

;;; ------------------------------------------------------------------
;;; What the window does
;;; ------------------------------------------------------------------

(defun inspect-part-clicked (editor n)
  "A double-click on row N of the parts, or the Inspect-part button with
it selected (NIL: none is).  The row's own number is what counts: the
`... more' row has none."
  (let* ((doc (editor-active-document editor))
         (row (and n (nth n (inspector-parts (editor-inspector-state editor)))))
         (index (dbg-row-index row)))
    (when doc
      (cond ((null index)
             (doc-message doc "Not a part")
             (doc-beep doc))
            (t (inspect-part doc index))))))

(defun inspect-back-clicked (editor)
  (let ((doc (editor-active-document editor)))
    (when doc (inspect-pop doc))))

;;; ------------------------------------------------------------------
;;; The reply
;;; ------------------------------------------------------------------

(defun inspect-reply (wire doc rc text)
  (let* ((editor (wire-editor wire))
         (insp (editor-inspector-state editor))
         (text (or text "")))
    (multiple-value-bind (type depth count) (and (= rc +rc-ok+) (inspect-header text))
      (cond
        ((null type)
         (when doc
           (let ((line (first-line text)))
             (doc-message doc (if (string/= line "") line "clamiga could not inspect that"))
             (doc-beep doc))))
        (t
         ;; The header, the object, then the parts.
         (let* ((lines (message-lines text))
                (object (or (second lines) ""))
                (parts (remove "" (cddr lines) :test #'string=)))
           (when (> count (length parts))
             (setq parts (append parts
                                 (list (format nil "... ~D more part(s); M-x clamacs-inspector-part takes any number"
                                               (- count (length parts)))))))
           (setf (inspector-depth insp) depth
                 (inspector-type insp) type
                 (inspector-object insp) object
                 (inspector-parts insp) parts)
           (editor-inspector-open editor insp)
           (when doc
             (message doc "Inspecting ~A: ~A" type object))))))))
