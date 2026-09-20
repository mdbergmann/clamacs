;;;; fake-frontend.lisp -- the frontend protocol over a string.
;;;;
;;;; The second implementation of lisp/frontend.lisp, and the reason the
;;;; commands are host-tested: a document whose "widget" is a string, a
;;;; cursor and an undo list, which records what it was told to show (the
;;;; echo area, beeps, colours, the clipboard) so a test can ask.  It is
;;;; deliberately as dumb as TextEditor.mcc is opaque: it implements the
;;;; protocol and nothing the commands could lean on by accident.

(in-package :clamacs)

(defclass fake-document (document)
  ((text :initarg :text :initform "" :accessor fake-text)
   (point :initarg :point :initform 0 :accessor fake-point)
   (undo-list :initform '() :accessor fake-undo-list)
   (redo-list :initform '() :accessor fake-redo-list)
   (messages :initform '() :accessor fake-messages) ; newest first
   (beeps :initform 0 :accessor fake-beeps)
   (colours :initform '() :accessor fake-colours)   ; (y x0 x1 colour) ...
   (clipboard :initform nil :accessor fake-clipboard)
   (selection :initform nil :accessor fake-selection)
   (quiet-calls :initform 0 :accessor fake-quiet-calls)
   ;; The input line: NIL while hidden, else its contents; and its label.
   (mini-text :initform nil :accessor fake-mini-text)
   (mini-label :initform nil :accessor fake-mini-label)
   (modified :initform nil :accessor fake-modified)
   (title :initform nil :accessor fake-title)
   ;; The status line's arglist field
   (arglist :initform "" :accessor fake-arglist)
   (active :initform 0 :accessor fake-activations)
   (window-open :initform t :accessor fake-window-open)
   ;; What the requesters will answer, a test's script: keywords for
   ;; DOC-ASK, paths (or NIL, cancel) for DOC-ASK-FILE; and what was asked.
   (answers :initform '() :accessor fake-answers)
   (asked :initform '() :accessor fake-asked)
   (page-lines :initform 10 :accessor fake-page-lines)))

;;; The editor whose documents are fake ones.  It records what the
;;; diagnostics window was told, and which document was activated last.
(defstruct (fake-editor (:include editor)
                        (:constructor make-fake-editor ()))
  (active nil)
  (diag-rows '())
  (diag-open nil)
  (diag-selected nil)
  ;; The debugger window: open or not, raised (given the keyboard) how
  ;; often, and what it was told to show
  (dbg-open nil)
  (dbg-raised 0)
  (dbg-shown nil)                ; (level condition restarts has-continue)
  (dbg-frames '())
  (dbg-selected nil)
  (dbg-locals '())
  ;; The inspector window
  (insp-open nil)
  (insp-shown nil))              ; (type depth object parts)

;;; --- the debugger and inspector windows (debugger.lisp, inspector.lisp)

(defmethod editor-debugger-open ((editor fake-editor) dbg)
  (setf (fake-editor-dbg-open editor) t
        (fake-editor-dbg-shown editor) (list (debugger-level dbg)
                                             (debugger-condition dbg)
                                             (debugger-restarts dbg)
                                             (debugger-has-continue dbg))
        (fake-editor-dbg-frames editor) '()
        (fake-editor-dbg-selected editor) nil
        (fake-editor-dbg-locals editor) '()))

(defmethod editor-debugger-close ((editor fake-editor))
  (setf (fake-editor-dbg-open editor) nil))

(defmethod editor-debugger-raise ((editor fake-editor))
  (setf (fake-editor-dbg-open editor) t)
  (incf (fake-editor-dbg-raised editor)))

(defmethod editor-debugger-frames ((editor fake-editor) rows)
  (setf (fake-editor-dbg-frames editor) rows
        (fake-editor-dbg-selected editor) nil))

(defmethod editor-debugger-select-frame ((editor fake-editor) n)
  (setf (fake-editor-dbg-selected editor) n))

(defmethod editor-debugger-locals ((editor fake-editor) rows)
  (setf (fake-editor-dbg-locals editor) rows))

(defmethod editor-inspector-open ((editor fake-editor) insp)
  (setf (fake-editor-insp-open editor) t
        (fake-editor-insp-shown editor) (list (inspector-type insp)
                                              (inspector-depth insp)
                                              (inspector-object insp)
                                              (inspector-parts insp))))

(defmethod editor-active-document ((editor fake-editor))
  (let ((active (fake-editor-active editor)))
    (or (and active (not (doc-closing active)) active)
        (first (live-documents editor)))))

(defmethod editor-show-diagnostics ((editor fake-editor) rows &key open)
  (setf (fake-editor-diag-rows editor) rows
        (fake-editor-diag-selected editor) nil)
  (when (or open rows)
    (setf (fake-editor-diag-open editor) t)))

(defmethod editor-select-diagnostic ((editor fake-editor) row)
  (setf (fake-editor-diag-selected editor) row))

(defmethod editor-make-document ((editor fake-editor)
                                 &key path name lisp-mode)
  (make-instance 'fake-document :editor editor :path path :name name
                                :lisp-mode lisp-mode
                                :text (coerce "" 'simple-string)))

(defun make-fake (text &key (point 0) (lisp-mode t)
                       (editor (make-fake-editor)))
  "A document holding TEXT.  A `|' in TEXT is removed and marks the cursor."
  (let ((bar (position #\| text)))
    (when bar
      (setq text (concatenate 'string (subseq text 0 bar)
                              (subseq text (1+ bar)))
            point bar))
    (make-instance 'fake-document :editor editor :lisp-mode lisp-mode
                                  :text (coerce text 'simple-string)
                                  :point point)))

(defun fake-state (doc)
  "The text with a `|' where the cursor is."
  (let ((text (fake-text doc)) (point (fake-point doc)))
    (concatenate 'string (subseq text 0 point) "|" (subseq text point))))

(defun fake-last-message (doc)
  (first (fake-messages doc)))

(defun lines (&rest lines)
  "LINES joined by newlines: (lines \"(a\" \" b)\")."
  (format nil "~{~A~^~%~}" lines))

;;; --- text access ----------------------------------------------------

(defmethod doc-point ((doc fake-document))
  (fake-point doc))

(defmethod doc-set-point ((doc fake-document) index)
  (setf (fake-point doc) (max 0 (min index (length (fake-text doc))))))

(defmethod doc-end ((doc fake-document))
  (length (fake-text doc)))

(defmethod doc-line-count ((doc fake-document))
  (1+ (count #\Newline (fake-text doc))))

(defmethod doc-index-line ((doc fake-document) index)
  (let* ((text (fake-text doc))
         (index (max 0 (min index (length text))))
         (y (count #\Newline text :end index))
         (start (let ((nl (position #\Newline text :end index :from-end t)))
                  (if nl (1+ nl) 0))))
    (values y (- index start))))

(defmethod doc-line-index ((doc fake-document) y)
  (let ((text (fake-text doc))
        (index 0))
    (dotimes (i (max 0 (min y (1- (doc-line-count doc)))) index)
      (setq index (1+ (position #\Newline text :start index))))))

(defmethod doc-text ((doc fake-document) start end)
  (coerce (subseq (fake-text doc) start end) 'simple-string))

(defmethod doc-lines-text ((doc fake-document) y0 y1)
  (let ((last (1- (doc-line-count doc))))
    (doc-text doc
              (doc-line-index doc y0)
              (if (>= y1 last)
                  (doc-end doc)
                  (doc-line-index doc (1+ y1))))))

;;; --- editing --------------------------------------------------------

(defun fake-record-undo (doc)
  (setf (fake-modified doc) t)
  (push (cons (fake-text doc) (fake-point doc)) (fake-undo-list doc))
  (setf (fake-redo-list doc) '()))

(defmethod doc-insert ((doc fake-document) text)
  (fake-record-undo doc)
  (let ((old (fake-text doc)) (point (fake-point doc)))
    (setf (fake-text doc) (concatenate 'simple-string (subseq old 0 point)
                                       text (subseq old point))
          (fake-point doc) (+ point (length text)))))

(defmethod doc-delete ((doc fake-document) start end)
  (fake-record-undo doc)
  (let ((old (fake-text doc)))
    (setf (fake-text doc) (concatenate 'simple-string (subseq old 0 start)
                                       (subseq old end))
          (fake-point doc) start)))

(defun fake-word-char-p (c)
  (alphanumericp c))

(defmethod doc-move ((doc fake-document) motion)
  (let* ((text (fake-text doc))
         (len (length text))
         (point (fake-point doc))
         (target
           (multiple-value-bind (y x) (doc-index-line doc point)
             (flet ((line-end (y)
                      (or (position #\Newline text
                                    :start (doc-line-index doc y))
                          len))
                    (to-line (y)
                      (and (<= 0 y (1- (doc-line-count doc)))
                           (let ((start (doc-line-index doc y)))
                             (min (+ start x)
                                  (or (position #\Newline text :start start)
                                      len))))))
               (ecase motion
                 (:left (and (> point 0) (1- point)))
                 (:right (and (< point len) (1+ point)))
                 (:up (to-line (1- y)))
                 (:down (to-line (1+ y)))
                 (:line-start (doc-line-index doc y))
                 (:line-end (line-end y))
                 (:text-start 0)
                 (:text-end len)
                 (:next-word
                  (and (< point len)
                       (let ((p point))
                         (loop while (and (< p len)
                                          (not (fake-word-char-p
                                                (char text p))))
                               do (incf p))
                         (loop while (and (< p len)
                                          (fake-word-char-p (char text p)))
                               do (incf p))
                         p)))
                 (:previous-word
                  (and (> point 0)
                       (let ((p point))
                         (loop while (and (> p 0)
                                          (not (fake-word-char-p
                                                (char text (1- p)))))
                               do (decf p))
                         (loop while (and (> p 0)
                                          (fake-word-char-p
                                           (char text (1- p))))
                               do (decf p))
                         p)))
                 (:next-page
                  (to-line (min (1- (doc-line-count doc))
                                (+ y (fake-page-lines doc)))))
                 (:previous-page
                  (to-line (max 0 (- y (fake-page-lines doc))))))))))
    (when target
      (setf (fake-point doc) target)
      t)))

(defmethod doc-edit ((doc fake-document) operation)
  (let ((point (fake-point doc)))
    (ecase operation
      (:delete
       (when (< point (doc-end doc))
         (doc-delete doc point (1+ point))
         t))
      (:backspace
       (when (> point 0)
         (doc-delete doc (1- point) point)
         t))
      (:undo
       (let ((entry (pop (fake-undo-list doc))))
         (when entry
           (push (cons (fake-text doc) point) (fake-redo-list doc))
           (setf (fake-text doc) (car entry)
                 (fake-point doc) (cdr entry))
           t)))
      (:redo
       (let ((entry (pop (fake-redo-list doc))))
         (when entry
           (push (cons (fake-text doc) point) (fake-undo-list doc))
           (setf (fake-text doc) (car entry)
                 (fake-point doc) (cdr entry))
           t)))
      (:select-all
       (setf (fake-selection doc) (cons 0 (doc-end doc)))
       t)
      (:select-none
       (setf (fake-selection doc) nil)
       t))))

(defmethod doc-clipboard-copy ((doc fake-document) start end cut)
  (setf (fake-clipboard doc) (doc-text doc start end))
  (when cut
    (doc-delete doc start end)))

;;; --- presentation ---------------------------------------------------

(defmethod doc-message ((doc fake-document) text)
  (push text (fake-messages doc)))

(defmethod doc-message-text ((doc fake-document))
  ;; A prompt's label takes the message line's place while it is open,
  ;; exactly as the MUI echo area shows it.
  (or (fake-mini-label doc) (first (fake-messages doc)) ""))

(defmethod doc-widget-command ((doc fake-document) command)
  "The few TextEditor.mcc commands the tests send through `TE': the
cursor as the class reports it (0-based), the cursor line, the four
POSITIONs.  NIL for anything else, as the class answers FALSE."
  (let ((words (split-words (string-upcase command))))
    (multiple-value-bind (y x) (doc-index-line doc (fake-point doc))
      (cond ((equal words '("GETCURSOR" "LINE")) (princ-to-string y))
            ((equal words '("GETCURSOR" "COLUMN")) (princ-to-string x))
            ((equal words '("GETLINE")) (doc-lines-text doc y y))
            ((equal words '("POSITION" "SOL")) (doc-move doc :line-start) t)
            ((equal words '("POSITION" "EOL")) (doc-move doc :line-end) t)
            ((equal words '("POSITION" "SOF")) (doc-move doc :text-start) t)
            ((equal words '("POSITION" "EOF")) (doc-move doc :text-end) t)
            (t nil)))))

(defmethod doc-beep ((doc fake-document))
  (incf (fake-beeps doc)))

(defmethod doc-show-arglist ((doc fake-document) text)
  (setf (fake-arglist doc) text))

(defmethod doc-colour ((doc fake-document) y x0 x1 colour)
  (push (list y x0 x1 colour) (fake-colours doc)))

(defmethod doc-call-quietly ((doc fake-document) function)
  (incf (fake-quiet-calls doc))
  (funcall function))

(defun fake-line-colours (doc y)
  "What line Y looks like after every DOC-COLOUR so far: (x0 x1 colour) for
each coloured run, left to right, as a painter's algorithm gives it."
  (let* ((width (length (doc-lines-text doc y y)))
         (pens (make-list width :initial-element nil)))
    (dolist (entry (reverse (fake-colours doc)))
      (destructuring-bind (ey x0 x1 colour) entry
        (when (= ey y)
          (loop for x from x0 below (min x1 width)
                do (setf (nth x pens) colour)))))
    (let ((runs '()) (x 0))
      (loop
        (when (>= x width)
          (return (nreverse runs)))
        (let ((pen (nth x pens)) (start x))
          (loop while (and (< x width) (eq (nth x pens) pen))
                do (incf x))
          (when pen
            (push (list start x pen) runs)))))))

;;; --- files and windows ---------------------------------------------

(defmethod doc-set-text ((doc fake-document) text)
  (setf (fake-text doc) (coerce text 'simple-string)
        (fake-point doc) 0
        (fake-undo-list doc) '()
        (fake-redo-list doc) '()
        (fake-modified doc) nil))

(defmethod doc-modified-p ((doc fake-document))
  (fake-modified doc))

(defmethod doc-set-modified ((doc fake-document) flag)
  (setf (fake-modified doc) flag))

(defmethod doc-set-title ((doc fake-document) title)
  (setf (fake-title doc) title))

(defmethod doc-ask-file ((doc fake-document) title save)
  (push (list :file title save) (fake-asked doc))
  (pop (fake-answers doc)))

(defmethod doc-ask ((doc fake-document) question choices)
  (push (list question choices) (fake-asked doc))
  (let ((answer (pop (fake-answers doc))))
    (unless (member answer choices)
      (error "The test scripted ~S for a requester offering ~S."
             answer choices))
    answer))

(defmethod doc-activate ((doc fake-document))
  (incf (fake-activations doc))
  (let ((editor (doc-editor doc)))
    (when (fake-editor-p editor)
      (setf (fake-editor-active editor) doc))))

(defmethod doc-close-window ((doc fake-document))
  (setf (fake-window-open doc) nil))

;;; --- the minibuffer ------------------------------------------------

(defmethod doc-open-minibuffer ((doc fake-document) label initial)
  (setf (fake-mini-label doc) label
        (fake-mini-text doc) (copy-seq initial)))

(defmethod doc-close-minibuffer ((doc fake-document))
  (setf (fake-mini-label doc) nil
        (fake-mini-text doc) nil))

(defmethod doc-minibuffer-text ((doc fake-document))
  (fake-mini-text doc))

(defmethod doc-set-minibuffer-text ((doc fake-document) text)
  (setf (fake-mini-text doc) (copy-seq text)))

(defmethod doc-set-minibuffer-label ((doc fake-document) label)
  (setf (fake-mini-label doc) label))

(defmethod doc-search ((doc fake-document) pattern backwards again)
  ;; Forwards the cursor ends up after the match, backwards at its start,
  ;; so AGAIN needs no adjustment either way: the next search from the
  ;; cursor cannot find the same match.
  (declare (ignore again))
  (let* ((text (fake-text doc))
         (point (fake-point doc))
         (found (if backwards
                    (search pattern text :from-end t
                                         :end2 (min (length text)
                                                    (+ point
                                                       (length pattern)
                                                       -1)))
                    (search pattern text :start2 point))))
    (when found
      (setf (fake-point doc)
            (if backwards found (+ found (length pattern))))
      t)))

(defun fake-prompt (doc)
  "The input line as the user sees it, label and contents; NIL when hidden."
  (and (fake-mini-text doc)
       (concatenate 'string (fake-mini-label doc) (fake-mini-text doc))))

;;; --- driving it -----------------------------------------------------

(defun type-minibuffer-key (doc key)
  "A key while the input line has the keyboard: the minibuffer's own keys
first, then the input line's editing, which is the widget's half -- the
protocol's default DOC-MINIBUFFER-EDIT, which is also what the port's KEY
uses."
  (or (minibuffer-key doc key)
      (doc-minibuffer-edit doc key)))

(defun type-keys (doc keys)
  "Feed the keys spelled in KEYS (\"C-x C-f\") to whatever has the keyboard:
the input line while a prompt is open, else HANDLE-KEY.  In the text an
unbound printable key self-inserts and an unbound BS deletes backwards,
which is the widget's half of the bargain; the list of the keys the Emacs
layer did NOT take is returned."
  (let ((passed '()))
    (dolist (key (split-key-sequence keys) (nreverse passed))
      (cond ((minibuffer-open-p doc)
             (type-minibuffer-key doc key))
            ((not (handle-key doc key))
             (push (key-to-string key) passed)
             (cond ((printable-key-p key)
                    (doc-insert doc (string (code-char (key-code key)))))
                   ((eql key +key-backspace+)
                    (doc-edit doc :backspace)))
             (note-text-changed doc)))
      (note-cursor-moved doc))))

(defun type-text (doc text)
  "Type the characters of TEXT, spaces included."
  (loop for c across text
        do (type-keys doc (if (char= c #\Space) "SPC" (string c)))))
