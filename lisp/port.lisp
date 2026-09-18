;;;; port.lisp -- the editor's own ARexx command set.
;;;;
;;;; What a macro (and verify/realamiga/drive.rexx) sends to the CLAMACS
;;;; port: the phase-1 table of specs/clamacs-ide.md, plus GETNAME.  This is
;;;; the port of src/rexxport.c, and like the rest of the editor it is
;;;; written against the frontend protocol, so tests/test-port.lisp drives
;;;; every verb on the fake frontend.  A verb is a function of the editor and
;;;; its argument string that answers (values RC TEXT), RC on the ARexx
;;;; ladder of wire.lisp; the transport (transport-arexx.lisp) registers each
;;;; one with EXT.DEV:DEFINE-COMMAND and runs it on the MUI task.
;;;;
;;;; `EVAL' runs an EDITOR command by name -- the namespace `M-x' uses, which
;;;; is the point of having a command table -- or, when the argument starts
;;;; with `(', evaluates a form in the editor's own Lisp: a macro can DEFUN a
;;;; command into the running editor.  `KEY' goes through the keymaps, so
;;;; prefix keys, the C-u reader, C-g and the minibuffer all take part; `TE'
;;;; passes straight through to the text widget's own commands.
;;;;
;;;; Pure: no MUI, no OS types.

(in-package :clamacs)

(defvar *port-verbs* '()
  "Alist of verb (an upcased string) to a function of (editor argument).")

(defmacro define-port-verb (verb (editor arg) &body body)
  `(let ((entry (assoc ,verb *port-verbs* :test #'string=)))
     (if entry
         (setf (cdr entry) (lambda (,editor ,arg) ,@body))
         (push (cons ,verb (lambda (,editor ,arg) ,@body)) *port-verbs*))
     ,verb))

(defun port-verb-names ()
  (sort (mapcar #'car *port-verbs*) #'string<))

(defun port-command (editor line)
  "Run the command LINE (`OPEN FILE x LINE 3') on EDITOR: (values RC TEXT).
The verb is case-insensitive; the argument keeps its internal spacing."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) line))
         (end (or (position-if (lambda (c) (member c '(#\Space #\Tab))) trimmed)
                  (length trimmed)))
         (verb (string-upcase (subseq trimmed 0 end)))
         (arg (string-trim '(#\Space #\Tab #\Newline #\Return) (subseq trimmed end)))
         (entry (assoc verb *port-verbs* :test #'string=)))
    (cond ((string= verb "") (values +rc-ok+ ""))
          ((null entry)
           (values +rc-fatal+
                   (format nil "ERROR: unknown command: ~A~%Known commands: ~{~A~^ ~}"
                           verb (port-verb-names))))
          (t (port-verb editor verb arg)))))

(defun port-verb (editor verb arg)
  "Run VERB with ARG.  An error inside a verb is its answer, not the
editor's end: rc 10 and the condition's text."
  (let ((entry (assoc verb *port-verbs* :test #'string=)))
    (if (null entry)
        (values +rc-fatal+ (format nil "ERROR: unknown command: ~A" verb))
        (handler-case
            (multiple-value-bind (rc text) (funcall (cdr entry) editor arg)
              (values (or rc +rc-ok+) (or text "")))
          (error (e)
            (values +rc-error+
                    (format nil "ERROR: ~A"
                            (handler-case (princ-to-string e)
                              (error () "(unprintable condition)")))))))))

;;; ------------------------------------------------------------------
;;; Arguments, in the shape of a ReadArgs template
;;; ------------------------------------------------------------------

(defun split-words (string)
  "The words of STRING; a double-quoted run is one word without its quotes."
  (let ((words '()) (word '()) (in-word nil) (quoted nil))
    (flet ((finish ()
             (when in-word
               (push (coerce (nreverse word) 'string) words)
               (setq word '() in-word nil))))
      (loop for c across string
            do (cond ((and quoted (char= c #\"))
                      (setq quoted nil))
                     (quoted (push c word))
                     ((char= c #\")
                      (setq quoted t in-word t))
                     ((member c '(#\Space #\Tab))
                      (finish))
                     (t (push c word)
                        (setq in-word t))))
      (finish))
    (nreverse words)))

(defun parse-template (arg keys)
  "ARG's words matched against KEYS, the names of a ReadArgs template in
order (\"FILE\" \"LINE\"): a word naming a key takes the next word as its
value, any other word fills the first key still empty.  An alist of key
and value string (NIL when absent), read with TEMPLATE-VALUE."
  (let ((values (mapcar (lambda (k) (cons k nil)) keys))
        (words (split-words arg)))
    (loop while words
          do (let* ((word (pop words))
                    (named (assoc word values :test #'string-equal)))
               (cond (named
                      (when words (setf (cdr named) (pop words))))
                     (t
                      (let ((slot (find nil values :key #'cdr)))
                        (when slot (setf (cdr slot) word)))))))
    values))

(defun template-value (values key)
  (cdr (assoc key values :test #'string=)))

(defun template-integer (value)
  (and value (parse-integer value :junk-allowed t)))

;;; ------------------------------------------------------------------
;;; The verbs
;;; ------------------------------------------------------------------

(defmacro with-port-document ((doc editor) &body body)
  "BODY with DOC the active document; without one the verb answers rc 10."
  `(let ((,doc (editor-active-document ,editor)))
     (if (null ,doc)
         (values +rc-error+ "ERROR: no document is open")
         (progn ,@body))))

(defun goto-line-1 (doc line)
  "The cursor to the start of LINE, 1-based: what `file:12:' in a
diagnostic means and what the error list clicks through to.  The class's
own GOTOLINE (through TE) is 0-based; every line number crossing THIS port
is 1-based."
  (when (and line (> line 0))
    (doc-set-point doc (doc-line-index doc (1- line)))))

(define-port-verb "OPEN" (editor arg)
  (let ((values (parse-template arg '("FILE" "LINE"))))
    (let ((file (template-value values "FILE"))
          (line (template-integer (template-value values "LINE"))))
      (cond ((or (null file) (string= file ""))
             (values +rc-error+ "ERROR: OPEN needs a FILE"))
            (t
             (let ((doc (or (find-document-by-path editor file)
                            (open-document editor file))))
               (cond ((null doc)
                      (values +rc-error+ (format nil "ERROR: cannot open ~A" file)))
                     (t
                      (doc-activate doc)
                      (goto-line-1 doc line)
                      (values +rc-ok+ "")))))))))

(define-port-verb "SAVE" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (if (doc-path doc)
        (values (if (save-file doc (doc-path doc)) +rc-ok+ +rc-error+) "")
        (values +rc-ok+ ""))))

(define-port-verb "GETFILE" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (values +rc-ok+ (or (doc-path doc) ""))))

;;; The active document's name: the file part of its path, or the name of
;;; a window that has no file -- the scratch windows.  GETFILE is empty for
;;; those, so this is how a macro learns which window it is talking to.
(define-port-verb "GETNAME" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (values +rc-ok+ (doc-name doc))))

(define-port-verb "GOTOLINE" (editor arg)
  (with-port-document (doc editor)
    (let ((line (template-integer (template-value (parse-template arg '("LINE")) "LINE"))))
      (cond ((or (null line) (<= line 0))
             (values +rc-error+ "ERROR: GOTOLINE needs a line number"))
            (t (goto-line-1 doc line)
               (values +rc-ok+ ""))))))

(defun port-eval-form (editor text)
  "TEXT, one or more forms, evaluated in the editor's own Lisp, in
CL-USER: the printed values of the last, or the error."
  (declare (ignore editor))
  (let ((*package* (find-package :cl-user))
        (eof (list :eof))
        (results '()))
    (with-input-from-string (in text)
      (loop for form = (read in nil eof)
            until (eq form eof)
            do (setq results (multiple-value-list (eval form)))))
    (values +rc-ok+
            (if results
                (format nil "~{~S~^ ; ~}" results)
                "; no values"))))

(define-port-verb "EVAL" (editor arg)
  (with-port-document (doc editor)
    (let ((name (string-trim '(#\Space #\Tab #\Newline) arg)))
      (cond ((string= name "")
             (values +rc-error+ "ERROR: EVAL needs a command name or a form"))
            ((char= (char name 0) #\()
             (port-eval-form editor name))
            (t
             (let ((command (find-command name)))
               (cond ((null command)
                      (values +rc-ok+ "unknown command"))
                     (t
                      (run-command doc command 1)
                      (values +rc-ok+ "")))))))))

(define-port-verb "INSERT" (editor arg)
  (with-port-document (doc editor)
    (doc-insert doc arg)
    (values +rc-ok+ "")))

(define-port-verb "TE" (editor arg)
  (with-port-document (doc editor)
    (let ((answer (doc-widget-command doc arg)))
      (values +rc-ok+ (if (stringp answer) answer "")))))

;;; The echo area, as text: how a macro that asked for a LOAD reads the
;;; outcome, and how the unattended test observes an ASYNCHRONOUS result --
;;; issue the command, then poll STATUS until the reply has arrived.
(define-port-verb "STATUS" (editor arg)
  (declare (ignore arg))
  (with-port-document (doc editor)
    (values +rc-ok+ (or (doc-message-text doc) ""))))

(defun port-key (doc key)
  "One key, to whichever object has the focus, exactly as a keypress would:
with the minibuffer open the keys belong to it, and the ones the Emacs
layer does not take are the input line's own."
  (if (minibuffer-open-p doc)
      (or (minibuffer-key doc key)
          (doc-minibuffer-edit doc key))
      (handle-key doc key)))

(define-port-verb "KEY" (editor arg)
  (with-port-document (doc editor)
    (let ((keys (split-key-sequence arg)))
      (cond ((null keys)
             (values +rc-ok+ "unknown key"))
            (t
             (dolist (key keys)
               (port-key doc key))
             (values +rc-ok+ ""))))))
