;;;; frontend-host.lisp -- the frontend protocol over webview and CodeMirror.
;;;;
;;;; The host editor of specs/clamacs-host.md: one native window with the
;;;; page (host/page-app.js) in it, one CodeMirror view per document in a
;;;; tab, and the Lisp side of every generic function of frontend.lisp,
;;;; minibuffer.lisp, files.lisp, snapshot.lisp and menu.lisp.  The rules
;;;; the spec fixes, each a section below:
;;;;
;;;;   - Lisp owns the text.  A HOST-DOCUMENT runs on a text mirror
;;;;     (textmirror.lisp), the fake frontend's model made real: every
;;;;     synchronous read of the protocol is answered from it, every write
;;;;     goes to it first.  What the page holds is brought in step at the
;;;;     end of every entry into Lisp (SYNC-DOCUMENT: one applyEdit per
;;;;     document from a prefix/suffix diff, then the point, then the
;;;;     modified flag), and a change the page made on its own (a paste, a
;;;;     mouse click) comes back through the clamacsUpdate / clamacsCursor
;;;;     bindings and is applied to the mirror as an edit.
;;;;   - Keys go to Lisp first.  The page sends every key (clamacsKey);
;;;;     HOST-DECODE-KEY turns the browser's KeyboardEvent fields into a
;;;;     key of keymap.lisp, HANDLE-KEY runs the Emacs layer, and a key it
;;;;     leaves alone gets the widget's default on the mirror
;;;;     (WIDGET-DEFAULT-KEY) -- what tests/fake-frontend.lisp's TYPE-KEYS
;;;;     calls the widget's half of the bargain.
;;;;   - Everything Lisp tells the page is batched: a CK call is appended
;;;;     to the editor's batch and the batch goes out as ONE webview_eval at
;;;;     the end of the entry (FLUSH-BATCH).  Colour runs are coalesced per
;;;;     line on the way (the colour records), so colouring a file is one
;;;;     call with one record per line.
;;;;   - The event loop is stepped, never parked: RUN-LOOP asks the shim for
;;;;     one turn of the Cocoa loop at a time and drains the mailbox in
;;;;     between, so a worker thread's stop-the-world collection waits at
;;;;     most one step.
;;;;   - The page draws the menu bar (webview has no native one) from the
;;;;     table of menu.lisp, sent once; MENU-UPDATE keeps its enable states
;;;;     and the Buffers menu in step after every entry, and a pick comes
;;;;     back as a table index, so the menu is the third entrance to the
;;;;     command table here as under MUI.
;;;;
;;;; The page may be absent: an editor made without a window (the tests)
;;;; keeps its flushed batches in HOST-EDITOR-EVALS instead, and the
;;;; requesters answer from a script, so the whole frontend short of the
;;;; window is host-tested by tests/test-host.lisp.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "ffi"))

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Where the page and the two libraries are
;;; ------------------------------------------------------------------

(defvar *host-frontend-dir*
  (let* ((here (or *load-truename* *load-pathname*))
         (dir (if here (directory-namestring here) ""))
         (cut (search "lisp/" dir :from-end t)))
    (concatenate 'string (if cut (subseq dir 0 cut) dir) "build/host-frontend/"))
  "The directory host/build.sh writes to: page.html, libwebview.dylib and
libclamacs-host.dylib.  CLAMACS_HOST_FRONTEND in the environment overrides
it.")

(defun host-frontend-file (name)
  (concatenate 'string (or (ext:getenv "CLAMACS_HOST_FRONTEND") *host-frontend-dir*) name))

;;; ------------------------------------------------------------------
;;; The editor and its documents
;;; ------------------------------------------------------------------

(defconstant +dock-default-height+ 200
  "The dock's height in pixels until the layout file or the splitter says
otherwise; the page's stylesheet starts from the same figure.")

(defstruct (host-editor (:include editor)
                        (:constructor %make-host-editor ()))
  ;; The two libraries and the webview: NIL for an editor without a
  ;; window, whose batches go to EVALS.
  webview shim w win
  (callbacks '())
  ;; The batch: the CK calls of this entry, and the pending colour
  ;; records of one document (see DOC-COLOUR).
  (batch (make-string-output-stream))
  (batch-empty t)
  (evals '())
  (colour-doc nil)
  (colour-runs '())              ; run records, newest first
  (colour-lines (make-hash-table)) ; line -> runs, for lines cleared whole
  ;; id -> document, the ids the page knows the documents by
  (docs (make-hash-table :test 'equal))
  (next-id 0)
  active-doc
  ;; The page reported clamacsReady; a modal requester is up
  (ready nil)
  (in-modal nil)
  user-agent
  ;; What the status line and the window title show, to push only changes
  (shown-status nil)
  (shown-title nil)
  ;; Without a window: what the requesters answer (a test's script),
  ;; what was asked, how often the beep sounded, the last clipboard text
  (answers '())
  (asked '())
  (beeps 0)
  (clipboard nil)
  (urls '())
  ;; Keys still to push through the page (HOST-INJECT-KEYS)
  (inject '())
  ;; The dock and the panels as Lisp told the page to show them (see "The
  ;; dock" below): whether the dock is open and what it displays, the
  ;; dock's height, each panel's open flag and selection.  PAGE-PANELS is
  ;; the page's own last report of the same (clamacsPanels), JSON text.
  (dock-open nil)
  (dock-shown nil)
  (dock-height +dock-default-height+)
  (diag-open nil)
  (diag-rows '())
  (diag-selected nil)
  (dbg-open nil)
  (insp-open nil)
  (page-panels nil)
  ;; The menu bar as Lisp told the page to show it (see "The menu bar"
  ;; below): whether the table went out (nothing is synced before), one
  ;; enable flag per table entry, the Buffers menu's entries and the ticked
  ;; document, the documents behind its items in order.
  (menus-sent nil)
  (menu-enabled nil)
  (buffers-shown '())
  (buffers-active nil)
  (buffers-docs #()))

(defclass host-document (document)
  ((id :initarg :id :reader hdoc-id)
   (mirror :initform (make-mirror) :accessor hdoc-mirror)
   ;; What the page holds: the text, the selection, the modified flag
   (shown-text :initform "" :accessor hdoc-shown-text)
   (shown-head :initform 0 :accessor hdoc-shown-head)
   (shown-anchor :initform 0 :accessor hdoc-shown-anchor)
   (shown-modified :initform nil :accessor hdoc-shown-modified)
   ;; The echo area, the input line and the status line of this document
   (message-text :initform "" :accessor hdoc-message-text)
   (mini-label :initform nil :accessor hdoc-mini-label)
   (mini-text :initform nil :accessor hdoc-mini-text)
   (package :initform "CL-USER" :accessor hdoc-package)
   (arglist :initform "" :accessor hdoc-arglist)
   (title :initform "" :accessor hdoc-title)
   ;; Whether the page made this document a tab of the dock.  Decided once,
   ;; when the tab was made (EDITOR-MAKE-DOCUMENT), because the page fixes it
   ;; there: TOOL-DOCUMENT-P asked later says no once a save gave the buffer
   ;; a file, while the page still holds it in the dock.
   (dock-p :initform nil :accessor hdoc-dock-p)))

(defvar *editor* nil
  "The running host editor, from START to its return.")

(defvar *wire-starter* nil
  "Function of the editor that sets up the wire and the editor's own port,
called by START once the first documents are open.  transport-host.lisp
sets it; without it the editor runs alone.")

(defvar *wire-stopper* nil
  "Its counterpart at exit.")

(defvar *host-bind* nil
  "The address `--bind ADDR' (after `--') asked the editor's own port to
listen on (\"\" when the option had no address), or NIL for 127.0.0.1.
transport-host.lisp reads it and refuses any value.")

(defvar *after-start-hooks* '()
  "Functions of the editor, called once its first documents are open and
before the event loop runs.")

(defvar *exit-trace* nil
  "Kept for the harness scripts the MUI frontend shares; the host editor
writes no exit log.")

(defun host-active-p (doc)
  (eq (host-editor-active-doc (doc-editor doc)) doc))

(defun active-document (editor)
  (let ((doc (host-editor-active-doc editor)))
    (or (and doc (not (doc-closing doc)) doc)
        (first (live-documents editor)))))

(defmethod editor-active-document ((editor host-editor))
  (active-document editor))

(defun host-document-by-id (editor id)
  (let ((doc (gethash id (host-editor-docs editor))))
    (and doc (not (doc-closing doc)) doc)))

;;; ------------------------------------------------------------------
;;; The foreign side: webview and the shim
;;; ------------------------------------------------------------------

(defun wv (editor name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name (host-editor-webview editor)) ret types args))

(defun shim (editor name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name (host-editor-shim editor)) ret types args))

(defun wv-str (editor name &rest strings)
  "Call NAME with the webview and one or more C strings."
  (let ((ptrs (mapcar #'ffi:foreign-string strings)))
    (unwind-protect
         (ffi:call-foreign (ffi:symbol-pointer name (host-editor-webview editor)) :int32
                           (cons :pointer (mapcar (constantly :pointer) ptrs))
                           (cons (host-editor-w editor) ptrs))
      (mapc #'ffi:free-foreign ptrs))))

(defun js-eval (editor js)
  (wv-str editor "webview_eval" js))

(defun js-return (editor id json)
  (let ((pid (ffi:foreign-string id)) (pjson (ffi:foreign-string json)))
    (unwind-protect
         (wv editor "webview_return" :int32 '(:pointer :pointer :int32 :pointer)
             (host-editor-w editor) pid 0 pjson)
      (ffi:free-foreign pid) (ffi:free-foreign pjson))))

(defun host-step (editor ms)
  "One turn of the event loop, at most MS milliseconds.  The bindings'
callbacks run inside it."
  (when (host-editor-w editor)
    (shim editor "clamacs_host_step" :int32 '(:pointer :int32) (host-editor-w editor) ms)))

(defun set-window-title (editor title)
  (unless (equal title (host-editor-shown-title editor))
    (setf (host-editor-shown-title editor) title)
    (when (host-editor-w editor)
      (wv-str editor "webview_set_title" title))))

;;; ------------------------------------------------------------------
;;; The batch: what Lisp tells the page, one eval per entry
;;; ------------------------------------------------------------------

(defun batch-js (editor js)
  "Append JS, a statement, to the batch."
  (flush-colours editor)
  (let ((out (host-editor-batch editor)))
    (write-string js out)
    (write-char #\; out))
  (setf (host-editor-batch-empty editor) nil))

(defun ck (editor name &rest args)
  "Append the call CK.NAME(ARGS...) to the batch.  A string argument is
written as an ASCII JavaScript literal, a symbol as its lower-cased name,
T and NIL as true and false, a list or vector as an array."
  (flush-colours editor)
  (let ((out (host-editor-batch editor)))
    (write-string "CK." out)
    (write-string name out)
    (write-char #\( out)
    (loop for (arg . more) on args
          do (json-write arg out)
             (when more (write-char #\, out)))
    (write-string ");" out))
  (setf (host-editor-batch-empty editor) nil))

(defun flush-batch (editor)
  "The batch to the page as one webview_eval -- or, without a page, onto
EVALS.  A failure inside it is reported by the page (clamacsLog)."
  (flush-colours editor)
  (unless (host-editor-batch-empty editor)
    (let ((js (get-output-stream-string (host-editor-batch editor))))
      (setf (host-editor-batch-empty editor) t)
      (if (host-editor-w editor)
          (js-eval editor (concatenate 'string "try{" js
                                       "}catch(e){clamacsLog(\"batch: \"+e)}"))
          (push js (host-editor-evals editor))))))

(defun host-take-evals (editor)
  "The batches flushed so far, oldest first as one string, and forgotten."
  (prog1 (format nil "~{~A~}" (reverse (host-editor-evals editor)))
    (setf (host-editor-evals editor) '())))

;;; ------------------------------------------------------------------
;;; Colours: DOC-COLOUR's runs, coalesced per line
;;; ------------------------------------------------------------------
;;;
;;; The page keeps the colours as CodeMirror decorations, which move with
;;; the text; Lisp keeps nothing across entries.  Within one entry the
;;; runs of a line are coalesced: COLOUR-ONE-LINE clears a line whole and
;;; then paints its tokens, so a clear opens a LINE record the later runs
;;; are painted into (a painter's algorithm, RUNS-PAINT), and the page
;;; replaces that line's decorations in one go; a run on a line that was
;;; not cleared in this entry is a RUN record the page paints over what it
;;; has.  Every record refers to the text as pushed: DOC-COLOUR brings the
;;; page's text in step first, and any other CK call flushes the records
;;; ahead of itself.

(defun runs-paint (runs x0 x1 kind)
  "RUNS -- (x0 x1 kind) triples, sorted and disjoint -- with columns X0 to
X1 painted KIND (NIL: cleared): the runs it overlaps are clipped."
  (if (<= x1 x0)
      runs
      (let ((out '()))
        (dolist (run runs)
          (destructuring-bind (a b k) run
            (cond ((or (<= b x0) (>= a x1)) (push run out))
                  (t (when (< a x0) (push (list a x0 k) out))
                     (when (> b x1) (push (list x1 b k) out))))))
        (when kind
          (push (list x0 x1 kind) out))
        (sort out #'< :key #'first))))

(defun flush-colours (editor)
  "The pending colour records into the batch as one CK.colour call.  The
page applies them in order: the run records oldest first, so that a range
cleared and then painted (the paren highlight taking itself down and going
up again) ends up painted; the line records after them, a line cleared whole
wiping any earlier run on it."
  (let ((doc (host-editor-colour-doc editor)))
    (when doc
      (let ((line-records '())
            (runs (reverse (host-editor-colour-runs editor)))
            (lines (host-editor-colour-lines editor)))
        (maphash (lambda (y line-runs)
                   (push (list y (coerce line-runs 'vector)) line-records))
                 lines)
        (setf (host-editor-colour-doc editor) nil
              (host-editor-colour-runs editor) '())
        (clrhash lines)
        (ck editor "colour" (hdoc-id doc)
            (coerce (append runs (nreverse line-records)) 'vector))))))

(defmethod doc-colour ((doc host-document) y x0 x1 colour)
  (let ((editor (doc-editor doc)))
    (sync-document doc)
    (unless (eq (host-editor-colour-doc editor) doc)
      (flush-colours editor)
      (setf (host-editor-colour-doc editor) doc))
    (let* ((lines (host-editor-colour-lines editor))
           (runs (gethash y lines :none)))
      (cond ((and (null colour) (= x0 0)
                  (>= x1 (mirror-line-length (hdoc-mirror doc) y)))
             ;; The line cleared whole: a line record, from scratch.
             (setf (gethash y lines) '()))
            ((not (eq runs :none))
             (setf (gethash y lines) (runs-paint runs x0 x1 colour)))
            (t
             (push (list y x0 x1 colour) (host-editor-colour-runs editor)))))))

(defun mirror-line-length (m y)
  (let ((start (mirror-line-index m y)))
    (- (mirror-line-end m start) start)))

;;; ------------------------------------------------------------------
;;; The text: the mirror, and the page brought in step with it
;;; ------------------------------------------------------------------

(defun text-diff (old new)
  "The one replacement that turns OLD into NEW: three values, the start,
the end in OLD, and the text that goes in between."
  (declare (simple-string old new))
  (let* ((len-old (length old))
         (len-new (length new))
         (prefix 0)
         (suffix 0))
    (declare (fixnum len-old len-new prefix suffix))
    (loop while (and (< prefix len-old) (< prefix len-new)
                     (char= (schar old prefix) (schar new prefix)))
          do (incf prefix))
    (loop while (and (< (+ prefix suffix) len-old)
                     (< (+ prefix suffix) len-new)
                     (char= (schar old (- len-old suffix 1))
                            (schar new (- len-new suffix 1))))
          do (incf suffix))
    (values prefix (- len-old suffix) (subseq new prefix (- len-new suffix)))))

(defun shown-selection (m)
  "Head and anchor as the page should show them: the point, with the
mirror's selection when the point is at one of its ends."
  (let ((point (mirror-point m))
        (sel (mirror-selection m)))
    (cond ((null sel) (values point point))
          ((= point (car sel)) (values point (cdr sel)))
          ((= point (cdr sel)) (values point (car sel)))
          (t (values point point)))))

(defun sync-document (doc)
  "What the page holds of DOC brought in step with the mirror: the text
as one applyEdit, then the selection, then the modified flag.  Cheap when
nothing changed: the text is compared by identity first."
  (let* ((editor (doc-editor doc))
         (id (hdoc-id doc))
         (m (hdoc-mirror doc))
         (text (mirror-text m))
         (shown (hdoc-shown-text doc)))
    (declare (simple-string text shown))
    (unless (or (eq text shown) (string= text shown))
      (multiple-value-bind (from to insert) (text-diff shown text)
        (ck editor "applyEdit" id from to insert (mirror-point m)))
      (setf (hdoc-shown-text doc) text
            (hdoc-shown-head doc) (mirror-point m)
            (hdoc-shown-anchor doc) (mirror-point m)))
    (multiple-value-bind (head anchor) (shown-selection m)
      (unless (and (= head (hdoc-shown-head doc)) (= anchor (hdoc-shown-anchor doc)))
        (ck editor "setPoint" id head anchor)
        (setf (hdoc-shown-head doc) head
              (hdoc-shown-anchor doc) anchor)))
    (let ((modified (and (mirror-modified m) t)))
      (unless (eq modified (hdoc-shown-modified doc))
        (ck editor "setModified" id modified)
        (setf (hdoc-shown-modified doc) modified)))))

(defmethod doc-point ((doc host-document))
  (mirror-point (hdoc-mirror doc)))

(defmethod doc-set-point ((doc host-document) index)
  (mirror-set-point (hdoc-mirror doc) index))

(defmethod doc-end ((doc host-document))
  (mirror-end (hdoc-mirror doc)))

(defmethod doc-line-count ((doc host-document))
  (mirror-line-count (hdoc-mirror doc)))

(defmethod doc-index-line ((doc host-document) index)
  (mirror-index-line (hdoc-mirror doc) index))

(defmethod doc-line-index ((doc host-document) y)
  (mirror-line-index (hdoc-mirror doc) y))

(defmethod doc-text ((doc host-document) start end)
  (mirror-substring (hdoc-mirror doc) start end))

(defmethod doc-lines-text ((doc host-document) y0 y1)
  (mirror-lines-text (hdoc-mirror doc) y0 y1))

(defmethod doc-insert ((doc host-document) text)
  (mirror-insert (hdoc-mirror doc) text))

(defmethod doc-delete ((doc host-document) start end)
  (when (> end start)
    (mirror-delete (hdoc-mirror doc) start end)))

(defmethod doc-move ((doc host-document) motion)
  (mirror-move (hdoc-mirror doc) motion))

(defmethod doc-edit ((doc host-document) operation)
  (let ((m (hdoc-mirror doc)))
    (prog1 (mirror-edit m operation)
      ;; Selected whole: the cursor at the start, as Emacs's
      ;; mark-whole-buffer leaves it, so the page shows the selection.
      (when (eq operation :select-all)
        (mirror-set-point m 0)))))

(defmethod doc-clipboard-copy ((doc host-document) start end cut)
  (when (> end start)
    (let ((editor (doc-editor doc))
          (text (doc-text doc start end)))
      (setf (host-editor-clipboard editor) text)
      (when (host-editor-shim editor)
        (ffi:with-foreign-string (p text)
          (shim editor "clamacs_host_clipboard_set" :int32 '(:pointer) p)))
      (when cut
        (doc-delete doc start end)))))

(defmethod doc-search ((doc host-document) pattern backwards again)
  (mirror-search (hdoc-mirror doc) pattern backwards again))

(defmethod doc-set-text ((doc host-document) text)
  (mirror-set-text (hdoc-mirror doc) text))

(defmethod doc-modified-p ((doc host-document))
  (mirror-modified (hdoc-mirror doc)))

(defmethod doc-set-modified ((doc host-document) flag)
  (setf (mirror-modified (hdoc-mirror doc)) (and flag t)))

(defmethod doc-widget-command ((doc host-document) command)
  "The few TextEditor.mcc commands the port's TE forwards: the cursor as
the class reports it, the cursor line, the four POSITIONs.  NIL for
anything else, as the class answers FALSE."
  (let ((words (split-words (string-upcase command))))
    (multiple-value-bind (y x) (doc-index-line doc (doc-point doc))
      (cond ((equal words '("GETCURSOR" "LINE")) (princ-to-string y))
            ((equal words '("GETCURSOR" "COLUMN")) (princ-to-string x))
            ((equal words '("GETLINE")) (doc-lines-text doc y y))
            ((equal words '("POSITION" "SOL")) (doc-move doc :line-start) t)
            ((equal words '("POSITION" "EOL")) (doc-move doc :line-end) t)
            ((equal words '("POSITION" "SOF")) (doc-move doc :text-start) t)
            ((equal words '("POSITION" "EOF")) (doc-move doc :text-end) t)
            (t nil)))))

;;; ------------------------------------------------------------------
;;; Presentation: the echo area, the status line, the title
;;; ------------------------------------------------------------------

(defmethod doc-message ((doc host-document) text)
  (setf (hdoc-message-text doc) text)
  (when (host-active-p doc)
    (ck (doc-editor doc) "setEcho" text)))

(defmethod doc-message-text ((doc host-document))
  (hdoc-message-text doc))

(defmethod doc-beep ((doc host-document))
  (let ((editor (doc-editor doc)))
    (incf (host-editor-beeps editor))
    (when (host-editor-shim editor)
      (shim editor "clamacs_host_beep" :void '()))))

(defun status-text (doc)
  "`*name  PACKAGE  line:column  arglist', the MUI status line's."
  (multiple-value-bind (y x) (doc-index-line doc (doc-point doc))
    (let ((arglist (hdoc-arglist doc)))
      (format nil "~A~A  ~A  ~D:~D~A~A"
              (if (doc-modified-p doc) "*" " ")
              (doc-name doc)
              (hdoc-package doc)
              (1+ y) (1+ x)
              (if (string= arglist "") "" "  ")
              arglist))))

(defun update-status (doc)
  "The status line and the window title, when DOC is the active document
and they changed."
  (when (host-active-p doc)
    (let ((editor (doc-editor doc))
          (text (status-text doc)))
      (unless (equal text (host-editor-shown-status editor))
        (setf (host-editor-shown-status editor) text)
        (ck editor "setStatus" text))
      (set-window-title editor (doc-name doc)))))

(defmethod doc-show-arglist ((doc host-document) text)
  (setf (hdoc-arglist doc) text)
  (update-status doc))

(defmethod doc-set-title ((doc host-document) title)
  (setf (hdoc-title doc) title)
  (ck (doc-editor doc) "setTitle" (hdoc-id doc) title)
  (when (host-active-p doc)
    (set-window-title (doc-editor doc) title)))

(defun show-echo-state (doc)
  "The echo row as DOC has it -- its prompt when one is open, else its
message -- after DOC became the active document."
  (let ((editor (doc-editor doc)))
    (cond ((hdoc-mini-text doc)
           (ck editor "openMini" (hdoc-mini-label doc) (hdoc-mini-text doc)))
          (t
           (ck editor "closeMini")
           (ck editor "setEcho" (hdoc-message-text doc))))
    (setf (host-editor-shown-status editor) nil)
    (update-status doc)))

;;; ------------------------------------------------------------------
;;; The minibuffer's part
;;; ------------------------------------------------------------------

(defmethod doc-open-minibuffer ((doc host-document) label initial)
  (setf (hdoc-mini-label doc) label
        (hdoc-mini-text doc) (copy-seq initial)
        (hdoc-message-text doc) label)
  (when (host-active-p doc)
    (ck (doc-editor doc) "openMini" label initial)))

(defmethod doc-close-minibuffer ((doc host-document))
  (setf (hdoc-mini-label doc) nil
        (hdoc-mini-text doc) nil
        (hdoc-message-text doc) "")
  (when (host-active-p doc)
    (ck (doc-editor doc) "closeMini")
    (ck (doc-editor doc) "setEcho" "")))

(defmethod doc-minibuffer-text ((doc host-document))
  (or (hdoc-mini-text doc) ""))

(defmethod doc-set-minibuffer-text ((doc host-document) text)
  (setf (hdoc-mini-text doc) (copy-seq text))
  (when (host-active-p doc)
    (ck (doc-editor doc) "setMiniText" text)))

(defmethod doc-set-minibuffer-label ((doc host-document) label)
  (setf (hdoc-mini-label doc) label
        (hdoc-message-text doc) label)
  (when (host-active-p doc)
    (ck (doc-editor doc) "setMiniLabel" label)))

(defun host-mini-input (editor text)
  "The input line changed by itself (the page's input event): the new
contents, not pushed back, and the minibuffer told once."
  (let ((doc (active-document editor)))
    (when (and doc (minibuffer-open-p doc))
      (setf (hdoc-mini-text doc) (copy-seq text))
      (minibuffer-changed doc))))

;;; ------------------------------------------------------------------
;;; Keys: the browser's KeyboardEvent to a key of keymap.lisp
;;; ------------------------------------------------------------------
;;;
;;; The page sends `key' (what the key types, or its name), `code' (the
;;; physical key) and the four modifier flags.  Without Alt the character
;;; is `key' itself.  With Alt held macOS composes a character (Option-f
;;; is a florin), so the character comes from `code' through a US layout
;;; table -- letters and digits by code on every layout, punctuation
;;; right on the US one (specs/clamacs-host.md, Risks).  A key held with
;;; the Command key is the OS's and the widget's, never the editor's.

(defparameter *host-named-keys*
  `(("Enter" . ,+key-return+) ("Tab" . ,+key-tab+) ("Escape" . ,+key-esc+)
    ("Backspace" . ,+key-backspace+) ("Delete" . ,+key-delete+)
    ("ArrowUp" . ,+key-up+) ("ArrowDown" . ,+key-down+)
    ("ArrowLeft" . ,+key-left+) ("ArrowRight" . ,+key-right+)
    ("Home" . ,+key-home+) ("End" . ,+key-end+)
    ("PageUp" . ,+key-pageup+) ("PageDown" . ,+key-pagedown+)
    ("Insert" . ,+key-insert+) ("Help" . ,+key-help+)
    ("F1" . ,(+ +key-f1+ 0)) ("F2" . ,(+ +key-f1+ 1)) ("F3" . ,(+ +key-f1+ 2))
    ("F4" . ,(+ +key-f1+ 3)) ("F5" . ,(+ +key-f1+ 4)) ("F6" . ,(+ +key-f1+ 5))
    ("F7" . ,(+ +key-f1+ 6)) ("F8" . ,(+ +key-f1+ 7)) ("F9" . ,(+ +key-f1+ 8))
    ("F10" . ,(+ +key-f1+ 9)))
  "The browser's names of the keys that type no character.")

(defparameter *host-code-chars*
  '(("Comma" #\, #\<) ("Period" #\. #\>) ("Slash" #\/ #\?)
    ("Semicolon" #\; #\:) ("Quote" #\' #\") ("BracketLeft" #\[ #\{)
    ("BracketRight" #\] #\}) ("Backslash" #\\ #\|) ("Backquote" #\` #\~)
    ("Minus" #\- #\_) ("Equal" #\= #\+) ("Space" #\Space #\Space)
    ("Digit0" #\0 #\)) ("Digit1" #\1 #\!) ("Digit2" #\2 #\@) ("Digit3" #\3 #\#)
    ("Digit4" #\4 #\$) ("Digit5" #\5 #\%) ("Digit6" #\6 #\^) ("Digit7" #\7 #\&)
    ("Digit8" #\8 #\*) ("Digit9" #\9 #\())
  "The US layout: a KeyboardEvent code, its character, and its character
with Shift.")

(defun host-code-char (code shift)
  "The character the physical key CODE types on a US layout, or NIL."
  (cond ((and (= (length code) 4) (string= code "Key" :end1 3)
              (char<= #\A (char code 3) #\Z))
         (if shift (char code 3) (char-downcase (char code 3))))
        (t (let ((entry (assoc code *host-code-chars* :test #'string=)))
             (and entry (if shift (third entry) (second entry)))))))

(defun host-decode-key (key code ctrl alt meta shift)
  "The key of keymap.lisp for a KeyboardEvent, or NIL for one the editor
leaves alone: a Command key, a bare modifier, a dead key (under Alt the
letter comes from CODE, so Option-N is M-n), a character outside Latin-1,
a key with no name here."
  (unless meta
    (let ((mods (logior (if ctrl +mod-ctrl+ 0)
                        (if alt +mod-meta+ 0)
                        (if shift +mod-shift+ 0)))
          (named (assoc key *host-named-keys* :test #'string=)))
      (cond (named (make-key (cdr named) mods))
            (alt
             (let ((c (or (host-code-char code shift)
                          (and (= (length key) 1) (char key 0)))))
               (and c (< (char-code c) 256) (make-key (char-code c) mods))))
            ((= (length key) 1)
             (let ((c (char key 0)))
               (and (< (char-code c) 256) (make-key (char-code c) mods))))
            (t nil)))))

(defun host-key-event (key)
  "The KeyboardEvent fields that decode to KEY, for a synthetic key: four
values, `key', `code', the Alt flag and the Shift flag; the Ctrl flag is
the key's own.  With Alt the character comes from the code, so it is
spelled the US way."
  (let* ((code (key-code key))
         (mods (key-mods key))
         (alt (/= 0 (logand mods +mod-meta+)))
         (shift (/= 0 (logand mods +mod-shift+)))
         (named (rassoc code *host-named-keys*)))
    (cond (named (values (car named) "" alt shift))
          ((<= #x20 code #xFF)
           (let* ((c (code-char code))
                  (entry (find-if (lambda (e) (or (char= c (second e)) (char= c (third e))))
                                  *host-code-chars*)))
             (cond ((and (< code 128) (alpha-char-p c))
                    (values (string c)
                            (format nil "Key~C" (char-upcase c))
                            alt (upper-case-p c)))
                   (entry
                    (values (string c) (first entry) alt
                            (and (char/= c (second entry)) (char= c (third entry)))))
                   (t (values (string c) "" alt shift)))))
          (t (values (key-to-string key) "" alt shift)))))

(defun host-key-js (key)
  "The simulateKey call that sends KEY through the page."
  (multiple-value-bind (name code alt shift) (host-key-event key)
    (format nil "simulateKey(~A,{code:~A,ctrlKey:~A,altKey:~A,shiftKey:~A})"
            (json-string name) (json-string code)
            (if (/= 0 (logand (key-mods key) +mod-ctrl+)) "true" "false")
            (if alt "true" "false")
            (if shift "true" "false"))))

;;; ------------------------------------------------------------------
;;; A key arriving: the Emacs layer first, then the widget's default
;;; ------------------------------------------------------------------

(defun widget-default-key (doc key)
  "What the widget does with a key the Emacs layer left alone: a
printable key inserts, RET and TAB insert their character, Backspace and
Delete delete, the arrows and Home, End, PageUp, PageDown move.  True
when the key did something."
  (flet ((edit (op) (doc-edit doc op))
         (move (motion) (doc-move doc motion) t))
    (cond ((printable-key-p key)
           (doc-insert doc (string (code-char (key-code key))))
           t)
          ((eql key +key-return+) (doc-insert doc (string #\Newline)) t)
          ((eql key +key-tab+) (doc-insert doc (string #\Tab)) t)
          ((eql key +key-backspace+) (edit :backspace))
          ((eql key +key-delete+) (edit :delete))
          ((eql key +key-left+) (move :left))
          ((eql key +key-right+) (move :right))
          ((eql key +key-up+) (move :up))
          ((eql key +key-down+) (move :down))
          ((eql key +key-home+) (move :line-start))
          ((eql key +key-end+) (move :line-end))
          ((eql key +key-pageup+) (move :previous-page))
          ((eql key +key-pagedown+) (move :next-page))
          (t nil))))

(defun host-mini-key (doc key)
  "A key while the input line has the keyboard: the minibuffer's own keys
first, then the input line's editing, which is the widget's half; Meta
plus a character the minibuffer does not bind is reported undefined, as
the MUI frontend's hook reports it."
  (or (minibuffer-key doc key)
      (doc-minibuffer-edit doc key)
      (when (and (/= 0 (logand (key-mods key) +mod-meta+))
                 (<= #x20 (key-code key) #xFF))
        (message doc "~A is undefined" (key-to-string key))
        t)))

(defun host-key (editor doc-id name code ctrl alt meta shift target)
  "The clamacsKey binding: a key in DOC-ID's view (TARGET \"text\") or in
the input line (\"mini\")."
  (let ((doc (host-document-by-id editor doc-id))
        (key (host-decode-key name code ctrl alt meta shift)))
    (when (and doc key)
      (let ((before (mirror-text (hdoc-mirror doc))))
        (cond ((minibuffer-open-p doc)
               (host-mini-key doc key))
              ((equal target "mini")
               ;; The input line is closed: the key is nobody's.
               nil)
              ((handle-key doc key))
              (t (widget-default-key doc key)))
        ;; Whatever edited -- a command or the widget's default -- the
        ;; text changed: what the MUI widget's ContentsChanged hook says.
        (note-text-if-changed doc before)
        (note-cursor-moved doc)))))

(defun note-text-if-changed (doc before)
  "NOTE-TEXT-CHANGED when the mirror's text is no longer BEFORE.  Every
edit makes a fresh string, so identity is the test."
  (unless (eq before (mirror-text (hdoc-mirror doc)))
    (note-text-changed doc)))

;;; ------------------------------------------------------------------
;;; What the page changed on its own
;;; ------------------------------------------------------------------

(defun host-update (editor doc-id changes head)
  "The clamacsUpdate binding: CHANGES, (from to inserted) triples in the
coordinates of the text before them, applied to the mirror as edits; the
page holds the result already."
  (let ((doc (host-document-by-id editor doc-id)))
    (when doc
      (let ((m (hdoc-mirror doc))
            (delta 0))
        (dolist (change changes)
          (destructuring-bind (from to inserted) change
            (mirror-replace m (+ from delta) (+ to delta) inserted)
            (incf delta (- (length inserted) (- to from)))))
        (mirror-set-point m head)
        (setf (hdoc-shown-text doc) (mirror-text m)
              (hdoc-shown-head doc) (mirror-point m)
              (hdoc-shown-anchor doc) (mirror-point m))
        (note-text-changed doc)
        (note-cursor-moved doc)))))

(defun host-cursor (editor doc-id head anchor)
  "The clamacsCursor binding: the selection moved on its own."
  (let ((doc (host-document-by-id editor doc-id)))
    (when doc
      (let ((m (hdoc-mirror doc)))
        (mirror-set-point m head)
        (setf (mirror-selection m) (and (/= head anchor)
                                        (cons (min head anchor) (max head anchor))))
        (setf (hdoc-shown-head doc) (mirror-point m)
              (hdoc-shown-anchor doc) (max 0 (min anchor (mirror-end m))))
        (note-cursor-moved doc)))))

;;; ------------------------------------------------------------------
;;; Documents and the window
;;; ------------------------------------------------------------------

(defmethod editor-make-document ((editor host-editor) &key path name lisp-mode)
  (let* ((id (format nil "doc~D" (incf (host-editor-next-id editor))))
         (doc (make-instance 'host-document :editor editor :path path
                                            :name (or name *unnamed*)
                                            :lisp-mode lisp-mode
                                            :id id)))
    (setf (gethash id (host-editor-docs editor)) doc
          (hdoc-dock-p doc) (tool-document-p doc))
    (ck editor "makeDoc" id (doc-name doc) (if (hdoc-dock-p doc) "tool" "source"))
    (doc-set-title doc (doc-name doc))
    (doc-activate doc)
    doc))

(defmethod doc-activate ((doc host-document))
  (let ((editor (doc-editor doc)))
    (setf (host-editor-active-doc editor) doc)
    (when (hdoc-dock-p doc)
      (dock-note-shown editor (hdoc-id doc)))
    (ck editor "activateDoc" (hdoc-id doc))
    (show-echo-state doc)))

(defmethod doc-close-window ((doc host-document))
  (let ((editor (doc-editor doc)))
    (remhash (hdoc-id doc) (host-editor-docs editor))
    (ck editor "removeDoc" (hdoc-id doc))
    (when (hdoc-dock-p doc)
      (dock-note-hidden editor (hdoc-id doc)))
    (when (eq (host-editor-active-doc editor) doc)
      (setf (host-editor-active-doc editor) nil)
      (let ((next (first (live-documents editor))))
        (when next
          (doc-activate next))))))

(defun reap (editor)
  "Forget the closed documents; the page took their tabs down already."
  (setf (editor-documents editor)
        (remove-if #'doc-closing (editor-documents editor))))

;;; --- the requesters

(defun choice-label (choice)
  (case choice
    (:save "Save") (:discard "Discard") (:cancel "Cancel")
    (:yes "Yes") (:no "No") (:ok "OK") (:start "Start")
    (t (string-capitalize (symbol-name choice)))))

(defmacro with-modal ((editor) &body body)
  "BODY with the page brought up to date first and the mailbox left alone
while a native dialog runs its own loop."
  (let ((e (gensym "EDITOR")))
    `(let ((,e ,editor))
       (flush-batch ,e)
       (setf (host-editor-in-modal ,e) t)
       (unwind-protect (progn ,@body)
         (setf (host-editor-in-modal ,e) nil)))))

(defmethod doc-ask ((doc host-document) question choices)
  (let ((editor (doc-editor doc)))
    (push (list question choices) (host-editor-asked editor))
    (cond ((null (host-editor-shim editor))
           ;; Scripted: the next answer, or the cancel position.
           (let ((answer (pop (host-editor-answers editor))))
             (if (member answer choices) answer (car (last choices)))))
          (t
           (let ((n (with-modal (editor)
                      (ffi:with-foreign-string (text question)
                        (ffi:with-foreign-string (buttons (format nil "~{~A~^|~}"
                                                                  (mapcar #'choice-label choices)))
                          (shim editor "clamacs_host_ask" :int32 '(:pointer :pointer :pointer)
                                (host-editor-win editor) text buttons))))))
             (if (and (integerp n) (<= 0 n) (< n (length choices)))
                 (nth n choices)
                 (car (last choices))))))))

(defmethod doc-ask-file ((doc host-document) title save)
  (let ((editor (doc-editor doc)))
    (push (list :file title save) (host-editor-asked editor))
    (cond ((null (host-editor-shim editor))
           (pop (host-editor-answers editor)))
          (t
           (let ((p (with-modal (editor)
                      (ffi:with-foreign-string (ftitle title)
                        (ffi:with-foreign-string (initial (or (doc-path doc) ""))
                          (shim editor "clamacs_host_ask_file" :pointer
                                '(:pointer :pointer :int32 :pointer)
                                (host-editor-win editor) ftitle (if save 1 0) initial))))))
             (unless (ffi:null-pointer-p p)
               (unwind-protect (ffi:foreign-to-string p)
                 (shim editor "clamacs_host_free" :void '(:pointer) p))))))))

;;; --- window positions (snapshot.lisp)

(defun window-frame (editor)
  "Left, top, width and height of the native window, or NIL without one."
  (when (host-editor-win editor)
    (let ((out (ffi:alloc-foreign 16)))
      (unwind-protect
           (progn
             (shim editor "clamacs_host_get_frame" :void '(:pointer :pointer)
                   (host-editor-win editor) out)
             (values (ffi:peek-i32 out 0) (ffi:peek-i32 out 4)
                     (ffi:peek-i32 out 8) (ffi:peek-i32 out 12)))
        (ffi:free-foreign out)))))

(defun place-window (editor)
  "The native window where the layout file puts `doc1'."
  (multiple-value-bind (left top width height) (layout-place editor "doc1")
    (when (and left (host-editor-win editor))
      (shim editor "clamacs_host_set_frame" :void '(:pointer :int32 :int32 :int32 :int32)
            (host-editor-win editor) left top width height))))

(defmethod doc-geometry ((doc host-document))
  (let ((editor (doc-editor doc)))
    (and (not (doc-closing doc))
         (if (host-editor-win editor)
             (window-frame editor)
             (values 0 0 800 600)))))

(defun dock-frame (editor)
  "Where the dock is, as a window of its own would be: the bottom
DOCK-HEIGHT pixels of the native window's frame."
  (multiple-value-bind (left top width height)
      (if (host-editor-win editor) (window-frame editor) (values 0 0 800 600))
    (let ((dock (min (host-editor-dock-height editor) height)))
      (values left (+ top (- height dock)) width dock))))

(defmethod editor-aux-windows ((editor host-editor))
  "The dock, when it is open, under the role `dock' -- the layout file's
entry for its height -- and each open panel under the role the MUI
frontend's window has, with the dock's frame, so a snapshot taken here
keeps every role the Amiga file has."
  (when (host-editor-dock-open editor)
    (let ((frame (multiple-value-list (dock-frame editor))))
      (append (list (cons "dock" frame))
              (when (host-editor-diag-open editor) (list (cons "errors" frame)))
              (when (host-editor-dbg-open editor) (list (cons "debugger" frame)))
              (when (host-editor-insp-open editor) (list (cons "inspector" frame)))))))

(defun place-dock (editor)
  "The dock's height from the layout file's `dock' entry, told to the
page before anything opens it."
  (multiple-value-bind (left top width height) (layout-place editor "dock")
    (declare (ignore left top width))
    (when (and height (> height 0))
      (setf (host-editor-dock-height editor) height)
      (ck editor "setDock" height))))

;;; --- About, the browser (menu.lisp)

(defun webview-version (editor)
  "The webview library's version, \"MAJOR.MINOR.PATCH\": the three
unsigned ints that start webview_version()'s struct."
  (let ((info (wv editor "webview_version" :pointer '())))
    (if (ffi:null-pointer-p info)
        "unknown"
        (format nil "~D.~D.~D" (ffi:peek-u32 info 0) (ffi:peek-u32 info 4) (ffi:peek-u32 info 8)))))

(defun webkit-version (user-agent)
  "The engine's version out of the page's user agent -- the token after
`AppleWebKit/' -- or \"unknown\"."
  (let ((at (and user-agent (search "AppleWebKit/" user-agent))))
    (if at
        (let* ((start (+ at (length "AppleWebKit/")))
               (end (or (position #\Space user-agent :start start) (length user-agent))))
          (subseq user-agent start end))
        "unknown")))

(defmethod editor-toolkit-lines ((editor host-editor))
  "The toolkit lines of About: the platform the shim reports, and the
two things the window is made of -- the webview library and the WebKit
behind the page."
  (list (if (host-editor-shim editor)
            (ffi:foreign-to-string (shim editor "clamacs_host_toolkit" :pointer '()))
            "no native shim (page stubbed)")
        (format nil "webview ~A, WebKit ~A"
                (if (host-editor-webview editor) (webview-version editor) "unknown")
                (webkit-version (host-editor-user-agent editor)))))

(defmethod doc-open-url ((doc host-document) url)
  (let ((editor (doc-editor doc)))
    (push url (host-editor-urls editor))
    (cond ((null (host-editor-shim editor)) :opened)
          ((/= 0 (ffi:with-foreign-string (p url)
                   (shim editor "clamacs_host_open_url" :int32 '(:pointer) p)))
           :opened)
          (t :refused))))

;;; ------------------------------------------------------------------
;;; The menu bar (menu.lisp)
;;; ------------------------------------------------------------------
;;;
;;; The page draws the menu strip -- webview has no API for a native one
;;; -- from the table SEND-MENUS hands it once at start, one entry per
;;; table index.  A pick comes back as that index (clamacsMenu) and runs
;;; MENU-PICK on the active document, so the menu is the third entrance
;;; to the command table here as it is under MUI, never a second
;;; implementation.  MENU-UPDATE, after every entry, brings the enable
;;; states in step with MENU-STATE (only what changed is sent) and the
;;; Buffers menu in step with BUFFER-MENU (remade when its entries or the
;;; ticked document changed), as the MUI frontend's does after a command
;;; and after every mailbox drain.

(defun send-menus (editor)
  "The table to the page, and the enable states forgotten so the next
MENU-UPDATE sends every one."
  (ck editor "setMenus"
      (coerce (mapcar (lambda (e)
                        (list (menu-entry-kind e)
                              (or (menu-entry-title e) "")
                              (or (menu-entry-keys e) "")))
                      (menu-entries))
              'vector))
  (setf (host-editor-menus-sent editor) t
        (host-editor-menu-enabled editor) nil
        (host-editor-buffers-shown editor) '()
        (host-editor-buffers-active editor) nil
        (host-editor-buffers-docs editor) #()))

(defun menu-enable-sync (editor)
  "menuEnable for every item whose state differs from what the page shows."
  (let ((want (menu-enabled-items editor))
        (shown (host-editor-menu-enabled editor)))
    (loop for flag in want
          for index from 0
          do (let ((entry (menu-entry index)))
               (when (and (eq (menu-entry-kind entry) :item)
                          (or (null shown) (not (eq flag (nth index shown)))))
                 (ck editor "menuEnable" index flag))))
    (setf (host-editor-menu-enabled editor) want)))

(defun buffers-menu-sync (editor)
  "setBuffers when the Buffers menu's entries or its tick are no longer
what the page shows: `-' for the bar, [label, ticked] for a buffer."
  (let ((want (buffer-menu editor))
        (active (editor-active-document editor)))
    (unless (and (buffer-menu-equal want (host-editor-buffers-shown editor))
                 (eq active (host-editor-buffers-active editor)))
      (ck editor "setBuffers"
          (coerce (mapcar (lambda (e)
                            (if (eq e :bar)
                                "-"
                                (list (car e) (eq (cdr e) active))))
                          want)
                  'vector))
      (setf (host-editor-buffers-shown editor) want
            (host-editor-buffers-active editor) active
            (host-editor-buffers-docs editor)
            (coerce (mapcar (lambda (e) (if (eq e :bar) nil (cdr e))) want) 'vector)))))

(defun menu-update (editor)
  "The menu bar in step with the editor's state, after every entry.
Nothing before the table went out (an editor the tests make without one)."
  (when (host-editor-menus-sent editor)
    (menu-enable-sync editor)
    (buffers-menu-sync editor)))

(defun host-menu-pick (editor index)
  "The clamacsMenu binding: the item at INDEX was picked.  Run only when
the item is enabled now -- the page dims what Lisp told it to, but the
state may have moved since the last report."
  (when (and (integerp index) (menu-item-enabled-p editor index))
    (menu-pick editor index)))

(defun host-buffers-pick (editor n)
  "The clamacsBuffers binding: the Buffers menu's item N, as the page
counts its entries (the bar included), activates its document."
  (let ((docs (host-editor-buffers-docs editor)))
    (when (and (integerp n) (<= 0 n) (< n (length docs)))
      (buffer-menu-pick editor (aref docs n)))))

(defmethod editor-buffer-menu-lines ((editor host-editor))
  "What the page's Buffers menu shows, brought up to date first -- the
port's verbs run from the mailbox, not inside a menu pick.  Without a
menu bar (the table not sent), what it should be."
  (cond ((not (host-editor-menus-sent editor)) (call-next-method))
        (t
         (buffers-menu-sync editor)
         (let ((active (host-editor-buffers-active editor)))
           (mapcar (lambda (e)
                     (cond ((eq e :bar) "-")
                           ((eq (cdr e) active) (format nil "> ~A" (car e)))
                           (t (format nil "  ~A" (car e)))))
                   (host-editor-buffers-shown editor))))))

(defmethod editor-buffer-menu-pick ((editor host-editor) label)
  (cond ((not (host-editor-menus-sent editor)) (call-next-method))
        (t
         (buffers-menu-sync editor)
         (let ((n (position-if (lambda (e) (and (consp e) (string= (car e) label)))
                               (host-editor-buffers-shown editor))))
           (and n (host-buffers-pick editor n))))))

;;; ------------------------------------------------------------------
;;; The dock: the tool buffers and the three panels as tabs
;;; ------------------------------------------------------------------
;;;
;;; What the MUI frontend opens as windows of their own -- the error list,
;;; the debugger, the inspector, and the tool buffers (the REPL, a
;;; description, ...) -- the page holds as tabs of the dock below the
;;; splitter.  The state behind the panels lives in diag.lisp,
;;; debugger.lisp and inspector.lisp; the methods here only tell the page
;;; what to show, and the bindings hand a row number or a line of text
;;; back, as the MUI hooks do.  A missing method here is not harmless: a
;;; "no applicable method" out of EDITOR-DEBUGGER-CLOSE aborted the REPL
;;; window's close before the document was marked closing, and the editor
;;; could not quit (the H2 drive, 2026-09-25).
;;;
;;; The editor keeps a mirror of what it told the page -- the open flags
;;; and the diagnostics selection; the debugger's and the inspector's rows
;;; and selection are their structs' -- which is what HOST-PANEL-STATE
;;; answers and what the snapshot reads.  The page reports what it shows
;;; after every change (clamacsPanels), kept verbatim for
;;; HOST-PAGE-PANELS, so a script can check the page against the mirror.
;;; The dock's rule, on both sides: showing an item opens the dock; hiding
;;; the item it displays shows the next open one, or collapses it.  What
;;; Lisp does not show itself, the page tells: a tool buffer's tab is a
;;; clamacsActivate, a panel's tab clamacsDockShown.  Which documents are
;;; tabs of the dock is HDOC-DOCK-P, fixed when the tab was made.

(defun dock-note-shown (editor name)
  (setf (host-editor-dock-open editor) t
        (host-editor-dock-shown editor) name))

(defun dock-open-items (editor)
  "The names of the dock's open items, panels first, as the page keeps
them: which one takes over when the displayed item goes."
  (append (when (host-editor-diag-open editor) (list "diagnostics"))
          (when (host-editor-dbg-open editor) (list "debugger"))
          (when (host-editor-insp-open editor) (list "inspector"))
          (loop for doc in (live-documents editor)
                when (hdoc-dock-p doc) collect (hdoc-id doc))))

(defun dock-note-hidden (editor name)
  (when (equal (host-editor-dock-shown editor) name)
    (let ((next (first (dock-open-items editor))))
      (setf (host-editor-dock-shown editor) next
            (host-editor-dock-open editor) (and next t)))))

;;; --- the diagnostics panel

(defmethod editor-show-diagnostics ((editor host-editor) rows &key open)
  (setf (host-editor-diag-rows editor) rows
        (host-editor-diag-selected editor) nil)
  (ck editor "showDiagnostics" (coerce rows 'vector) (and (or open rows) t))
  (when (or open rows)
    (setf (host-editor-diag-open editor) t)
    (dock-note-shown editor "diagnostics")))

(defmethod editor-select-diagnostic ((editor host-editor) row)
  (setf (host-editor-diag-selected editor) row)
  (ck editor "selectDiagnostic" row))

(defun row-arg (n)
  "A row number from the page: a non-negative integer, or NIL for
anything else (JSON null, the reader's :NULL, is `nothing selected')."
  (and (integerp n) (>= n 0) n))

(defun host-diag-pick (editor row)
  "The clamacsDiagPick binding: a row selected in the list is visited.  A
row the list does not have (a stale page) selects nothing."
  (let ((wire (editor-wire editor))
        (row (and row (< row (length (host-editor-diag-rows editor))) row)))
    (setf (host-editor-diag-selected editor) row)
    (when (and wire row)
      (diagnostic-jump wire row))))

;;; --- the debugger panel

(defmethod editor-debugger-open ((editor host-editor) dbg)
  (setf (host-editor-dbg-open editor) t)
  (ck editor "dbgOpen" (debugger-level dbg) (debugger-condition dbg)
      (coerce (debugger-restarts dbg) 'vector) (and (debugger-has-continue dbg) t))
  ;; Shown, not given the keyboard: it arrives while the user may be typing.
  (dock-note-shown editor "debugger"))

(defmethod editor-debugger-close ((editor host-editor))
  (when (host-editor-dbg-open editor)
    (setf (host-editor-dbg-open editor) nil)
    (ck editor "dbgClose")
    (dock-note-hidden editor "debugger")))

(defmethod editor-debugger-raise ((editor host-editor))
  (setf (host-editor-dbg-open editor) t)
  (ck editor "dbgRaise")
  (dock-note-shown editor "debugger"))

(defmethod editor-debugger-frames ((editor host-editor) rows)
  (ck editor "dbgFrames" (coerce rows 'vector)))

(defmethod editor-debugger-select-frame ((editor host-editor) n)
  (ck editor "dbgSelectFrame" n))

(defmethod editor-debugger-locals ((editor host-editor) rows)
  (ck editor "dbgLocals" (coerce rows 'vector)))

(defun host-dbg-button (editor which)
  "The clamacsDbgButton binding: `continue' or `abort'."
  (cond ((equal which "continue") (debug-continue-clicked editor))
        ((equal which "abort") (debug-abort-clicked editor))
        (t (error "The debugger panel has no button ~S" which))))

(defun host-panel-close (editor name)
  "The clamacsPanelClose binding: the panel's tab was closed.  The
debugger's close is DEBUG-WINDOW-CLOSED, which says the REPL is still
parked; the other two only go off the screen."
  (cond ((equal name "debugger")
         (debug-window-closed editor))
        ((equal name "diagnostics")
         (setf (host-editor-diag-open editor) nil)
         (dock-note-hidden editor name))
        ((equal name "inspector")
         (setf (host-editor-insp-open editor) nil)
         (dock-note-hidden editor name))
        (t (error "The dock has no panel ~S" name))))

(defun host-dock-shown (editor name)
  "The clamacsDockShown binding: the user clicked the tab of the panel NAME
and the page displays it.  Told to the dock's mirror as any other showing
is, so the next hide of the displayed item follows the page.  A name that
is no open panel (a stale page, JSON null) changes nothing; a tool
buffer's tab is clamacsActivate's."
  (when (and (member name '("diagnostics" "debugger" "inspector") :test #'equal)
             (member name (dock-open-items editor) :test #'equal))
    (dock-note-shown editor name)))

;;; --- the inspector panel

(defmethod editor-inspector-open ((editor host-editor) insp)
  (setf (host-editor-insp-open editor) t)
  (ck editor "inspOpen" (inspector-type insp) (inspector-depth insp)
      (inspector-object insp) (coerce (inspector-parts insp) 'vector))
  (dock-note-shown editor "inspector"))

;;; --- the dock's height, and what the page reports

(defun host-dock-resized (editor height)
  "The clamacsDockResized binding: the splitter was dragged.  A page at a
fractional zoom reports a fractional height; it is rounded to whole pixels."
  (when (and (realp height) (> height 0))
    (setf (host-editor-dock-height editor) (round height))))

(defun host-panels-report (editor json)
  "The clamacsPanels binding: what the page shows, kept verbatim."
  (when (stringp json)
    (setf (host-editor-page-panels editor) json)))

;;; --- for a script: what the panels show

(defun host-panel-state (panel &optional (editor *editor*))
  "What the editor told the page to show for PANEL -- :DOCK, :DIAGNOSTICS,
:DEBUGGER or :INSPECTOR -- as one line of words, for a script's `EVAL
\(clamacs::host-panel-state :debugger)' over the port."
  (unless editor
    (return-from host-panel-state "no editor"))
  (flet ((open-word (flag) (if flag "open" "closed"))
         (row-word (n) (if n (princ-to-string n) "none")))
    (ecase panel
      (:menu
       (format nil "items ~D disabled (~{~D~^ ~}) buffers (~{~A~^|~})"
               (count :item (menu-entries) :key #'menu-entry-kind)
               (loop for flag in (host-editor-menu-enabled editor)
                     for index from 0
                     when (and (not flag) (eq (menu-entry-kind (menu-entry index)) :item))
                       collect index)
               (editor-buffer-menu-lines editor)))
      (:dock
       (format nil "~A height ~D shown ~A"
               (open-word (host-editor-dock-open editor))
               (host-editor-dock-height editor)
               (or (host-editor-dock-shown editor) "nothing")))
      (:diagnostics
       (format nil "~A rows ~D selected ~A"
               (open-word (host-editor-diag-open editor))
               (length (host-editor-diag-rows editor))
               (row-word (host-editor-diag-selected editor))))
      (:debugger
       (let ((dbg (editor-debugger-state editor)))
         (format nil "~A level ~D restarts ~D continue ~A frames ~D frame ~A locals ~D condition ~A"
                 (open-word (host-editor-dbg-open editor))
                 (debugger-level dbg)
                 (length (debugger-restarts dbg))
                 (if (debugger-has-continue dbg) "yes" "no")
                 (length (debugger-frames dbg))
                 (row-word (debugger-frame dbg))
                 (length (debugger-locals dbg))
                 (debugger-condition dbg))))
      (:inspector
       (let ((insp (editor-inspector-state editor)))
         (format nil "~A type ~A depth ~D parts ~D object ~A"
                 (open-word (host-editor-insp-open editor))
                 (inspector-type insp)
                 (inspector-depth insp)
                 (length (inspector-parts insp))
                 (inspector-object insp)))))))

(defun host-page-panels (&optional (editor *editor*))
  "The page's own last report of what its dock and panels show
\(clamacsPanels), as the JSON text it sent; \"no report\" before the
first."
  (or (and editor (host-editor-page-panels editor))
      "no report"))

;;; ------------------------------------------------------------------
;;; An entry into Lisp: a binding, a drain, a turn of the loop
;;; ------------------------------------------------------------------

(defun report-error (editor condition)
  "An error in a command or a binding: shown in the active document's echo
area, and on the console when there is none."
  (let ((doc (active-document editor))
        (text (handler-case (format nil "Error: ~A" condition)
                (error () "Error (unprintable condition)"))))
    (if doc
        (doc-message doc (substitute #\Space #\Newline text))
        (format *error-output* "clamacs: ~A~%" text))))

(defun after-entry (editor)
  "The page brought in step and the batch sent: after every entry.  A
text an entry other than a key changed (a port verb, a reply) is noted
here, as the MUI widget's ContentsChanged hook would have."
  (dolist (doc (editor-documents editor))
    (unless (doc-closing doc)
      (note-text-if-changed doc (hdoc-shown-text doc))
      (sync-document doc)))
  (let ((doc (active-document editor)))
    (when doc
      (update-status doc)))
  (menu-update editor)
  (flush-batch editor))

(defun call-with-entry (editor thunk)
  (handler-case (funcall thunk)
    (error (e) (report-error editor e)))
  (after-entry editor))

(defmacro with-entry ((editor) &body body)
  `(call-with-entry ,editor (lambda () ,@body)))

;;; ------------------------------------------------------------------
;;; The bindings: what the page calls
;;; ------------------------------------------------------------------

(defun bind (editor name function)
  "Bind NAME in the page to FUNCTION, called with the parsed JSON
arguments inside an entry; the promise is answered with true.  While a
native dialog runs its own loop the call is dropped: only the timer's
ticks can arrive then."
  (let ((cb (ffi:make-callback
             :void '(:pointer :pointer :pointer)
             (lambda (id req arg)
               (declare (ignore arg))
               (unless (host-editor-in-modal editor)
                 (let ((args (handler-case (json-parse (ffi:foreign-to-string req))
                               (error (e)
                                 (report-error editor e)
                                 :bad))))
                   (unless (eq args :bad)
                     (with-entry (editor)
                       (apply function args)))))
               (js-return editor (ffi:foreign-to-string id) "true")))))
    (push cb (host-editor-callbacks editor))
    (ffi:with-foreign-string (pname name)
      (wv editor "webview_bind" :int32 '(:pointer :pointer :pointer :pointer)
          (host-editor-w editor) pname cb (ffi:make-foreign-pointer 0)))))

(defun host-log (editor text)
  "The clamacsLog binding: the page reports a JavaScript error."
  (format *error-output* "clamacs: the page reported: ~A~%" text)
  (let ((doc (active-document editor)))
    (when doc
      (message doc "Page: ~A" text))))

(defun host-tick (editor)
  "The clamacsTick binding, every 300 ms: the arglist in the status line."
  (let ((doc (active-document editor)))
    (when doc
      (arglist-idle doc))))

(defun install-bindings (editor)
  (bind editor "clamacsReady"
        (lambda (user-agent)
          (setf (host-editor-ready editor) t
                (host-editor-user-agent editor) user-agent)))
  (bind editor "clamacsLog" (lambda (text) (host-log editor text)))
  (bind editor "clamacsKey"
        (lambda (doc-id key code ctrl alt meta shift target)
          (host-key editor doc-id key code ctrl alt meta shift target)))
  (bind editor "clamacsUpdate"
        (lambda (doc-id changes head) (host-update editor doc-id changes head)))
  (bind editor "clamacsCursor"
        (lambda (doc-id head anchor) (host-cursor editor doc-id head anchor)))
  (bind editor "clamacsMiniInput" (lambda (text) (host-mini-input editor text)))
  (bind editor "clamacsActivate"
        (lambda (doc-id)
          (let ((doc (host-document-by-id editor doc-id)))
            (when doc (doc-activate doc)))))
  (bind editor "clamacsCloseTab"
        (lambda (doc-id)
          (let ((doc (host-document-by-id editor doc-id)))
            (when doc (close-document doc)))))
  (bind editor "clamacsTick" (lambda () (host-tick editor)))
  ;; The menu bar (phase H4)
  (bind editor "clamacsMenu" (lambda (index) (host-menu-pick editor index)))
  (bind editor "clamacsBuffers" (lambda (n) (host-buffers-pick editor n)))
  ;; The dock and the panels (phase H3).  A row number the page sends for
  ;; "nothing selected" is JSON null: ROW-ARG makes it NIL.
  (bind editor "clamacsDiagPick" (lambda (row) (host-diag-pick editor (row-arg row))))
  (bind editor "clamacsDbgFrame" (lambda (n) (debug-frame-selected editor (row-arg n))))
  (bind editor "clamacsDbgFrameOpen" (lambda (n) (debug-frame-clicked editor (row-arg n))))
  (bind editor "clamacsDbgRestart" (lambda (n) (debug-restart-clicked editor (row-arg n))))
  (bind editor "clamacsDbgEval" (lambda (text) (debug-eval-entered editor text)))
  (bind editor "clamacsDbgButton" (lambda (which) (host-dbg-button editor which)))
  (bind editor "clamacsInspPart" (lambda (n) (inspect-part-clicked editor (row-arg n))))
  (bind editor "clamacsInspBack" (lambda () (inspect-back-clicked editor)))
  (bind editor "clamacsPanelClose" (lambda (name) (host-panel-close editor name)))
  (bind editor "clamacsDockShown" (lambda (name) (host-dock-shown editor name)))
  (bind editor "clamacsDockResized" (lambda (height) (host-dock-resized editor height)))
  (bind editor "clamacsPanels" (lambda (json) (host-panels-report editor json))))

;;; ------------------------------------------------------------------
;;; Keys through the page, for the harness (verify/host/host-keys.sh)
;;; ------------------------------------------------------------------

(defun host-inject-keys (editor keys)
  "Have the loop push KEYS -- key fixnums, or strings TYPE-TEXT would type
-- through the page's simulateKey, one per turn, so each takes the path a
real key takes: the page's keydown handler, the clamacsKey binding, the
decoder."
  (let ((flat '()))
    (dolist (item keys)
      (if (stringp item)
          (loop for c across item do (push (make-key (char-code c)) flat))
          (push item flat)))
    (setf (host-editor-inject editor)
          (append (host-editor-inject editor) (nreverse flat)))))

(defun inject-next-key (editor)
  (let ((key (pop (host-editor-inject editor))))
    (when key
      (batch-js editor (host-key-js key)))))

;;; ------------------------------------------------------------------
;;; The event loop
;;; ------------------------------------------------------------------

(defconstant +step-ms+ 50
  "How long one turn of the loop waits for an event: the longest a worker
thread waits for the main thread's safepoint.")

(defun housekeeping (editor)
  "Between two turns: the closed documents forgotten, a quit carried out,
the next injected key sent.  True when the last document is gone."
  (reap editor)
  (when (editor-quitting editor)
    (quit-requested editor)
    (reap editor))
  (inject-next-key editor)
  (null (live-documents editor)))

(defun run-loop (editor)
  "Step the native loop, drain the mailbox, keep house, until the last
document closes."
  (let ((box (editor-mailbox editor))
        (done nil))
    (loop
      (host-step editor +step-ms+)
      (with-entry (editor)
        (mailbox-drain box)
        (setq done (housekeeping editor)))
      (when done
        (return)))))

;;; ------------------------------------------------------------------
;;; Opening and closing the window
;;; ------------------------------------------------------------------

(defun read-page (path)
  "The page byte for byte: Latin-1 keeps every byte a character and
ffi:foreign-string writes one byte per character, so WebKit gets the
file -- valid UTF-8 as long as host/build.sh kept it ASCII."
  (with-open-file (in path :external-format :latin-1)
    (let* ((s (make-string (file-length in)))
           (n (read-sequence s in)))
      (subseq s 0 n))))

(defun host-open (editor)
  "The libraries, the window, the bindings, the page; returns once the
page has reported ready."
  (let ((webview (host-frontend-file "libwebview.dylib"))
        (shim (host-frontend-file "libclamacs-host.dylib"))
        (page (host-frontend-file "page.html")))
    (dolist (file (list webview shim page))
      (unless (probe-file file)
        (error "Clamacs: ~A is missing -- run host/build.sh first." file)))
    (setf (host-editor-webview editor) (or (ffi:load-library webview)
                                           (error "Clamacs: ~A did not load." webview))
          (host-editor-shim editor) (or (ffi:load-library shim)
                                        (error "Clamacs: ~A did not load." shim)))
    (let ((w (wv editor "webview_create" :pointer '(:int32 :pointer) 0 (ffi:make-foreign-pointer 0))))
      (when (ffi:null-pointer-p w)
        (error "Clamacs: webview_create failed."))
      (setf (host-editor-w editor) w))
    (wv-str editor "webview_set_title" "Clamacs")
    (wv editor "webview_set_size" :int32 '(:pointer :int32 :int32 :int32)
        (host-editor-w editor) 1000 700 0)
    (setf (host-editor-win editor)
          (wv editor "webview_get_window" :pointer '(:pointer) (host-editor-w editor)))
    (place-window editor)
    (install-bindings editor)
    ;; The close button asks the editor: `save-buffers-kill-emacs', which
    ;; the loop carries out.
    (let ((cb (ffi:make-callback :void '(:pointer)
                                 (lambda (arg)
                                   (declare (ignore arg))
                                   (setf (editor-quitting editor) t)))))
      (push cb (host-editor-callbacks editor))
      (shim editor "clamacs_host_on_close" :void '(:pointer :pointer :pointer)
            (host-editor-win editor) cb (ffi:make-foreign-pointer 0)))
    (wv-str editor "webview_set_html" (read-page page))
    (let ((deadline (+ (get-internal-real-time) (* 20 internal-time-units-per-second))))
      (loop until (host-editor-ready editor)
            do (when (> (get-internal-real-time) deadline)
                 (error "Clamacs: the page did not report ready within 20 seconds."))
               (host-step editor +step-ms+)))))

(defun host-close (editor)
  "The window, the callbacks, the libraries -- nothing OS-owned outlives
START."
  (when (host-editor-w editor)
    (wv editor "webview_destroy" :int32 '(:pointer) (host-editor-w editor))
    (setf (host-editor-w editor) nil
          (host-editor-win editor) nil))
  (dolist (cb (host-editor-callbacks editor))
    (ffi:free-callback cb))
  (setf (host-editor-callbacks editor) '())
  (when (host-editor-shim editor)
    (ffi:close-library (host-editor-shim editor))
    (setf (host-editor-shim editor) nil))
  (when (host-editor-webview editor)
    (ffi:close-library (host-editor-webview editor))
    (setf (host-editor-webview editor) nil)))

(defun setup-mailbox (editor)
  (setf (editor-mailbox editor)
        (make-mailbox :wake (lambda ()
                              (when (host-editor-shim editor)
                                (shim editor "clamacs_host_wake" :void '())))
                      :on-error (lambda (e) (report-error editor e))
                      :after-drain (lambda () (menu-update editor)))))

;;; ------------------------------------------------------------------
;;; Entry
;;; ------------------------------------------------------------------

(defun start (&key files)
  "Run the editor: the window with the page in it, one tab per path in
FILES (an unnamed Lisp buffer when there are none), the loop until the
last tab closes."
  (let ((editor (%make-host-editor)))
    (setf *editor* editor)
    (snapshot-load editor)
    (unwind-protect
         (progn
           (host-open editor)
           (setup-mailbox editor)
           (unwind-protect
                (progn
                  (with-entry (editor)
                    (send-menus editor)
                    (place-dock editor)
                    (if files
                        (dolist (path files)
                          (unless (open-document editor path)
                            (format *error-output* "clamacs: cannot open ~A~%" path)))
                        (open-document editor nil)))
                  (when (live-documents editor)
                    (when *wire-starter*
                      (handler-case (funcall *wire-starter* editor)
                        (error (e) (report-error editor e))))
                    (with-entry (editor)
                      (dolist (hook *after-start-hooks*)
                        (funcall hook editor)))
                    (run-loop editor)))
             ;; No more calls from the other threads, then the wire, then
             ;; the window.
             (mailbox-close (editor-mailbox editor))
             (when (and *wire-stopper* (editor-wire editor))
               (handler-case (funcall *wire-stopper* editor)
                 (error (e) (report-error editor e))))
             (dolist (doc (editor-documents editor))
               (setf (doc-closing doc) t))
             (reap editor)))
      (host-close editor)
      (setf *editor* nil))
    t))

(defun parse-command-line (args)
  "The files among ARGS, in order, with the editor's own options taken
out: `--bind ADDR' sets *HOST-BIND* to ADDR as given, or to \"\" when
nothing follows it.  No judgement is passed here -- a wildcard, a missing
address and a non-loopback one are all refused by HOST-PORT-START with a
message, so the editor comes up without its port and says why, never on
loopback as if the option had not been given."
  (let ((files '()))
    (loop while args
          do (let ((arg (pop args)))
               (if (string= arg "--bind")
                   (setf *host-bind* (or (pop args) ""))
                   (push arg files))))
    (nreverse files)))

(defun run ()
  "The editor as a program: the user's init file (~/.clamacsrc), then
START on the program's own arguments -- what follows `--' on clamiga's
command line."
  (load-init-file)
  (start :files (parse-command-line ext:*command-line-args*)))
