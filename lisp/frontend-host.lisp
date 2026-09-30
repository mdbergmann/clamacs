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
;;;;   - The menu bar is the table of menu.lisp, sent once: on macOS to the
;;;;     shim, which puts it on the screen's menu bar, elsewhere to the
;;;;     page, which draws it (webview has no native one); MENU-UPDATE
;;;;     keeps its enable states and the dynamic groups (Buffers, View)
;;;;     in step after every entry, and a pick comes back as a table index
;;;;     either way, so the menu is the third entrance to the command
;;;;     table here as under MUI.
;;;;   - A theme (theme.lisp) is the page's CSS variables set on the
;;;;     document element, one CK.theme call: EDITOR-APPLY-THEME sends what
;;;;     THEME-CSS-VARS answers, at start and whenever LOAD-THEME runs, and
;;;;     the page's scheme (dark or light, from the system) reported at
;;;;     clamacsReady decides the default theme.
;;;;   - A tab can be shown in a window of its own (the tab's context menu,
;;;;     M-x clamacs-detach-window): a HOST-WINDOW is one webview instance
;;;;     with the same page in it, and every CK call is routed by its target
;;;;     -- a document to the window that holds it, a panel to the window it
;;;;     was moved to, the editor to the main window.  The move itself is
;;;;     what the mirror makes cheap: the tab is taken out of one page and
;;;;     made in the other from the text Lisp holds (see "Detached windows").
;;;;
;;;; The page may be absent: an editor made without a window (the tests)
;;;; keeps its flushed batches in the window's EVALS instead, and the
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
  "The directory host/build.sh writes to in a checkout: page.html and the
two libraries.  Settled when this file loads, so an image holds the answer
of the checkout it was saved from; HOST-FRONTEND-DIR decides at run time.")

(defun host-library-name (base)
  "BASE with this host's shared-library suffix: .dylib on macOS, .so on
Linux, .dll elsewhere (Windows -- the runtime puts no feature of its own
there, and none for the BSDs, which host/build.sh does not build for)."
  (concatenate 'string base
               (cond ((member :darwin *features*) ".dylib")
                     ((member :linux *features*) ".so")
                     (t ".dll"))))

(defun with-trailing-slash (dir)
  (if (and (> (length dir) 0)
           (member (char dir (1- (length dir))) '(#\/ #\\)))
      dir
      (concatenate 'string dir "/")))

(defun choose-host-frontend-dir (env exe-dir default)
  "The directory of the page and the libraries: ENV (CLAMACS_HOST_FRONTEND)
when it is set; else EXE-DIR, the running binary's directory, when the page
is there -- the Clamacs.app bundle and an installed layout put page,
libraries and image beside clamiga; else DEFAULT, the checkout's build
directory.  Each with a trailing slash."
  (cond ((and env (string/= env "")) (with-trailing-slash env))
        ((and exe-dir
              (probe-file (concatenate 'string (with-trailing-slash exe-dir) "page.html")))
         (with-trailing-slash exe-dir))
        (t default)))

(defun host-frontend-dir ()
  (let ((exe (ext:executable-path)))
    (choose-host-frontend-dir (ext:getenv "CLAMACS_HOST_FRONTEND")
                              (and exe (directory-namestring exe))
                              *host-frontend-dir*)))

(defun host-frontend-file (name)
  (concatenate 'string (host-frontend-dir) name))

;;; ------------------------------------------------------------------
;;; The editor and its documents
;;; ------------------------------------------------------------------

(defconstant +dock-default-height+ 200
  "The dock's height in pixels until the layout file or the splitter says
otherwise; the page's stylesheet starts from the same figure.")

(defstruct (host-window (:constructor %make-host-window (editor number)))
  "One native window with the page in it: the main window, NUMBER 1, or
a window a tab was shown in separately (see \"Detached windows\")."
  editor
  number
  ;; The webview instance and its native window: NIL for a window
  ;; without a page (the tests), whose batches go to EVALS.
  w win
  (callbacks '())
  ;; The batch: the CK calls of this entry to this window
  (batch (make-string-output-stream))
  (batch-empty t)
  (evals '())
  ;; The page reported clamacsReady; SETTLED once the menus, the theme
  ;; and the dock height went out (HOUSEKEEPING does it, from the loop);
  ;; PENDING holds what moves in then -- documents and panel names -- so
  ;; nothing is sent to a page that is not up yet.  The main window is
  ;; settled from the start: HOST-OPEN waits for its page.
  (ready nil)
  (settled nil)
  (pending '())
  ;; What the status line and the window title show, to push only changes
  (shown-status nil)
  (shown-title nil)
  ;; The dock of this window as Lisp told the page to show it (see "The
  ;; dock" below): whether it is open and what it displays, its height.
  ;; PAGE-PANELS is the page's own last report (clamacsPanels), JSON text.
  (dock-open nil)
  (dock-shown nil)
  (dock-height +dock-default-height+)
  (page-panels nil)
  ;; Without a page: the frame WINDOW-FRAME answers, so a test sees where
  ;; a window was placed
  (stub-frame (list 0 0 800 600))
  ;; :ATTACH when the close button was pressed, :EMPTY when the last tab
  ;; left: HOUSEKEEPING takes the window down (the main window never)
  (closing nil))

(defstruct (host-editor (:include editor)
                        (:constructor %%make-host-editor ()))
  ;; The two libraries: NIL for an editor without a page (the tests)
  webview shim
  ;; The page's HTML, read once (every window gets the same page)
  (page-html nil)
  ;; The windows, the main one first (see "Detached windows"), and which
  ;; window holds each panel that was moved out of the main one
  (main nil)
  (windows '())
  (next-window 0)
  (panel-windows '())            ; panel name -> window
  ;; The pending colour records of one document (see DOC-COLOUR)
  (colour-doc nil)
  (colour-runs '())              ; run records, newest first
  (colour-lines (make-hash-table)) ; line -> runs, for lines cleared whole
  ;; id -> document, the ids the page knows the documents by
  (docs (make-hash-table :test 'equal))
  (next-id 0)
  active-doc
  ;; A modal requester is up
  (in-modal nil)
  user-agent
  ;; The system's colour scheme the page reported at ready, "dark" or
  ;; "light": what decides the default theme (theme.lisp)
  (scheme nil)
  ;; Without a window: what the requesters answer (a test's script),
  ;; what was asked, how often the beep sounded, the last clipboard text,
  ;; the windows raised
  (answers '())
  (asked '())
  (beeps 0)
  (clipboard nil)
  (urls '())
  (raised '())
  ;; Keys still to push through the page (HOST-INJECT-KEYS)
  (inject '())
  ;; The panels as Lisp told the page to show them (see "The dock"
  ;; below): each panel's open flag, the diagnostics rows and selection
  (diag-open nil)
  (diag-rows '())
  (diag-selected nil)
  (dbg-open nil)
  (insp-open nil)
  ;; The menu bar as Lisp told the page -- or the shim, NATIVE-MENU (see
  ;; "The menu bar" below) -- to show it: whether the table went out
  ;; (nothing is synced before), one enable flag per table entry, and per
  ;; dynamic group (Buffers, View) its entries with the ticked object and
  ;; the objects behind its lines in order.  Without a shim a native
  ;; menu's calls go onto NATIVE-CALLS, as the page's batches go onto
  ;; EVALS.
  (menus-sent nil)
  (native-menu nil)
  (native-calls '())
  (menu-enabled nil)
  (dynamic-shown '())            ; group -> (entries . ticked)
  (dynamic-objects '()))         ; group -> vector of objects, one per line

(defclass host-document (document)
  ((id :initarg :id :reader hdoc-id)
   ;; The window whose page holds this document's tab
   (window :initarg :window :accessor hdoc-window)
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
   ;; The completion list shown at the prompt (DOC-SHOW-COMPLETIONS), the
   ;; names as given, and the row the cursor is on
   (mini-completions :initform nil :accessor hdoc-mini-completions)
   (mini-completion-index :initform -1 :accessor hdoc-mini-completion-index)
   (package :initform "CL-USER" :accessor hdoc-package)
   (arglist :initform "" :accessor hdoc-arglist)
   (title :initform "" :accessor hdoc-title)
   ;; Whether the page made this document a tab of the dock.  Decided once,
   ;; when the tab was made (EDITOR-MAKE-DOCUMENT), because the page fixes it
   ;; there: TOOL-DOCUMENT-P asked later says no once a save gave the buffer
   ;; a file, while the page still holds it in the dock.
   (dock-p :initform nil :accessor hdoc-dock-p)))

;;; *EDITOR*, the running editor, is frontend.lisp's: START sets it.

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
  (let ((doc (and (stringp id) (gethash id (host-editor-docs editor)))))
    (and doc (not (doc-closing doc)) doc)))

;;; --- the windows

(defun add-window (editor)
  "A new HOST-WINDOW on EDITOR, numbered after the ones before it; the
first one made is the main window."
  (let ((window (%make-host-window editor (incf (host-editor-next-window editor)))))
    (setf (host-editor-windows editor) (append (host-editor-windows editor) (list window)))
    (unless (host-editor-main editor)
      (setf (host-editor-main editor) window
            (host-window-settled window) t))
    window))

(defun %make-host-editor ()
  "An editor with its main window, without a page: HOST-OPEN gives the
window one."
  (let ((editor (%%make-host-editor)))
    (add-window editor)
    editor))

(defun host-window (editor number)
  "The window numbered NUMBER, or NIL."
  (find number (host-editor-windows editor) :key #'host-window-number))

(defun main-window-p (window)
  (eq window (host-editor-main (host-window-editor window))))

(defun live-windows (editor)
  "The windows that are not on their way down, the main one first."
  (remove-if #'host-window-closing (host-editor-windows editor)))

(defun target-window (target)
  "The window a CK call for TARGET goes to: a window itself, a
document's own, the editor's main window."
  (etypecase target
    (host-window target)
    (host-document (hdoc-window target))
    (host-editor (host-editor-main target))))

(defun window-documents (window)
  "The open documents whose tabs are in WINDOW's page, oldest first."
  (remove window (live-documents (host-window-editor window))
          :key #'hdoc-window :test-not #'eq))

(defun window-source-documents (window)
  (remove-if #'hdoc-dock-p (window-documents window)))

(defun active-window (editor)
  "The window the active document is in, or the main window."
  (let ((doc (active-document editor)))
    (or (and doc (hdoc-window doc)) (host-editor-main editor))))

;;; The two the tests read off the editor: the main window's.
(defun host-editor-ready (editor)
  (host-window-ready (host-editor-main editor)))

(defun host-editor-dock-height (editor)
  (host-window-dock-height (host-editor-main editor)))

;;; ------------------------------------------------------------------
;;; The foreign side: webview and the shim
;;; ------------------------------------------------------------------

(defun wv (editor name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name (host-editor-webview editor)) ret types args))

(defun shim (editor name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name (host-editor-shim editor)) ret types args))

(defun wv-str (window name &rest strings)
  "Call NAME with WINDOW's webview instance and one or more C strings."
  (let ((ptrs (mapcar #'ffi:foreign-string strings)))
    (unwind-protect
         (ffi:call-foreign (ffi:symbol-pointer name (host-editor-webview (host-window-editor window)))
                           :int32
                           (cons :pointer (mapcar (constantly :pointer) ptrs))
                           (cons (host-window-w window) ptrs))
      (mapc #'ffi:free-foreign ptrs))))

(defun js-eval (window js)
  (wv-str window "webview_eval" js))

(defun js-return (window id json)
  (let ((pid (ffi:foreign-string id)) (pjson (ffi:foreign-string json)))
    (unwind-protect
         (wv (host-window-editor window) "webview_return" :int32 '(:pointer :pointer :int32 :pointer)
             (host-window-w window) pid 0 pjson)
      (ffi:free-foreign pid) (ffi:free-foreign pjson))))

(defun host-step (editor ms)
  "One turn of the event loop, at most MS milliseconds: every window's
events, since the loop is the application's.  The bindings' callbacks
run inside it."
  (let ((w (host-window-w (host-editor-main editor))))
    (when w
      (shim editor "clamacs_host_step" :int32 '(:pointer :int32) w ms))))

(defun set-window-title (window title)
  (unless (equal title (host-window-shown-title window))
    (setf (host-window-shown-title window) title)
    (when (host-window-w window)
      (wv-str window "webview_set_title" title))))

(defun raise-window (window)
  "WINDOW to the front with the keyboard, as MUI's window activation
does; without a shim, noted on RAISED for a test."
  (let ((editor (host-window-editor window)))
    (cond ((and (host-editor-shim editor) (host-window-win window))
           (shim editor "clamacs_host_raise" :void '(:pointer) (host-window-win window)))
          ((null (host-editor-shim editor))
           (push (host-window-number window) (host-editor-raised editor))))))

;;; ------------------------------------------------------------------
;;; The batch: what Lisp tells the page, one eval per entry and window
;;; ------------------------------------------------------------------

(defun batch-js (target js)
  "Append JS, a statement, to TARGET's window's batch (TARGET-WINDOW)."
  (let ((window (target-window target)))
    (flush-colours (host-window-editor window))
    (let ((out (host-window-batch window)))
      (write-string js out)
      (write-char #\; out))
    (setf (host-window-batch-empty window) nil)))

(defun ck (target name &rest args)
  "Append the call CK.NAME(ARGS...) to the batch of TARGET's window: a
document's own, the editor's main one, or the window given.  A string
argument is written as an ASCII JavaScript literal, a symbol as its
lower-cased name, T and NIL as true and false, a list or vector as an
array."
  (let ((window (target-window target)))
    (flush-colours (host-window-editor window))
    (let ((out (host-window-batch window)))
      (write-string "CK." out)
      (write-string name out)
      (write-char #\( out)
      (loop for (arg . more) on args
            do (json-write arg out)
               (when more (write-char #\, out)))
      (write-string ");" out))
    (setf (host-window-batch-empty window) nil)))

(defun ck-all (editor name &rest args)
  "CK.NAME(ARGS...) to every window whose page is up: what every page
shows alike -- the menu bar's state, the theme."
  (dolist (window (live-windows editor))
    (when (host-window-settled window)
      (apply #'ck window name args))))

(defun flush-window-batch (window)
  "WINDOW's batch to its page as one webview_eval -- or, without a page,
onto its EVALS.  A failure inside it is reported by the page (clamacsLog)."
  (unless (host-window-batch-empty window)
    (let ((js (get-output-stream-string (host-window-batch window))))
      (setf (host-window-batch-empty window) t)
      (if (host-window-w window)
          (js-eval window (concatenate 'string "try{" js
                                       "}catch(e){clamacsLog(\"batch: \"+e)}"))
          (push js (host-window-evals window))))))

(defun flush-batch (editor)
  "Every window's batch to its page."
  (flush-colours editor)
  (mapc #'flush-window-batch (host-editor-windows editor)))

(defun host-take-evals (target)
  "The batches TARGET's window (TARGET-WINDOW: the editor's main one)
flushed so far, oldest first as one string, and forgotten."
  (let ((window (target-window target)))
    (prog1 (format nil "~{~A~}" (reverse (host-window-evals window)))
      (setf (host-window-evals window) '()))))

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
        (ck doc "colour" (hdoc-id doc)
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

(defun shown-selection (doc)
  "Head and anchor as the page should show them: the point, with the
mark while the region is shown (DOC-MARK-ACTIVE), else with the mirror's
selection when the point is at one of its ends."
  (let* ((m (hdoc-mirror doc))
         (point (mirror-point m))
         (sel (mirror-selection m)))
    (cond ((and (doc-mark-active doc) (doc-mark doc))
           (values point (max 0 (min (doc-mark doc) (mirror-end m)))))
          ((null sel) (values point point))
          ((= point (car sel)) (values point (cdr sel)))
          ((= point (cdr sel)) (values point (car sel)))
          (t (values point point)))))

(defun sync-document (doc)
  "What the page holds of DOC brought in step with the mirror: the text
as one applyEdit, then the selection, then the modified flag.  Cheap when
nothing changed: the text is compared by identity first."
  (let* ((id (hdoc-id doc))
         (m (hdoc-mirror doc))
         (text (mirror-text m))
         (shown (hdoc-shown-text doc)))
    (declare (simple-string text shown))
    (unless (or (eq text shown) (string= text shown))
      (multiple-value-bind (from to insert) (text-diff shown text)
        (ck doc "applyEdit" id from to insert (mirror-point m)))
      (setf (hdoc-shown-text doc) text
            (hdoc-shown-head doc) (mirror-point m)
            (hdoc-shown-anchor doc) (mirror-point m)))
    (multiple-value-bind (head anchor) (shown-selection doc)
      (unless (and (= head (hdoc-shown-head doc)) (= anchor (hdoc-shown-anchor doc)))
        (ck doc "setPoint" id head anchor)
        (setf (hdoc-shown-head doc) head
              (hdoc-shown-anchor doc) anchor)))
    (let ((modified (and (mirror-modified m) t)))
      (unless (eq modified (hdoc-shown-modified doc))
        (ck doc "setModified" id modified)
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
      ;; Selected whole: the cursor at the start and the mark at the
      ;; end, as Emacs's mark-whole-buffer leaves them, so the page shows
      ;; the selection and the region commands work on it.
      (when (eq operation :select-all)
        (mirror-set-point m 0)
        (setf (doc-mark doc) (mirror-end m)
              (doc-mark-active doc) t)))))

(defmethod doc-clipboard-set ((doc host-document) text)
  (let ((editor (doc-editor doc)))
    (setf (host-editor-clipboard editor) text)
    (when (host-editor-shim editor)
      (ffi:with-foreign-string (p text)
        (shim editor "clamacs_host_clipboard_set" :int32 '(:pointer) p)))))

(defmethod doc-clipboard-copy ((doc host-document) start end cut)
  (when (> end start)
    (doc-clipboard-set doc (doc-text doc start end))
    (when cut
      (doc-delete doc start end))))

(defun clipboard-lines (text)
  "TEXT with its lines separated by #\\Newline alone: another application's
CR LF loses the CR, a lone CR becomes the newline."
  (declare (simple-string text))
  (if (not (find #\Return text))
      text
      (let ((out (make-string (length text)))
            (n 0)
            (len (length text)))
        (declare (fixnum n len))
        (dotimes (i len)
          (let ((c (schar text i)))
            (cond ((char/= c #\Return)
                   (setf (schar out n) c)
                   (incf n))
                  ((and (< (1+ i) len) (char= (schar text (1+ i)) #\Newline)))
                  (t (setf (schar out n) #\Newline)
                     (incf n)))))
        (subseq out 0 n))))

(defmethod doc-clipboard-text ((doc host-document))
  "The system clipboard's text through the shim; without one (the page
stubbed) what the editor holds as the clipboard, which a test sets."
  (let* ((editor (doc-editor doc))
         (text (if (host-editor-shim editor)
                   (let ((p (shim editor "clamacs_host_clipboard_get" :pointer '())))
                     (unless (ffi:null-pointer-p p)
                       (unwind-protect (ffi:foreign-to-string p)
                         (shim editor "clamacs_host_free" :void '(:pointer) p))))
                   (host-editor-clipboard editor))))
    (and text (clipboard-lines (coerce text 'simple-string)))))

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

;;; The status line and the echo row are one per window, and show the
;;; ACTIVE document's state: a document that is not the active one keeps
;;; its message and status to itself until it is activated again, when
;;; SHOW-ECHO-STATE renders them into its window.

(defmethod doc-message ((doc host-document) text)
  (setf (hdoc-message-text doc) text)
  (when (host-active-p doc)
    (ck doc "setEcho" text)))

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
  "The status line and the title of DOC's window, when DOC is the active
document and they changed."
  (when (host-active-p doc)
    (let ((window (hdoc-window doc))
          (text (status-text doc)))
      (unless (equal text (host-window-shown-status window))
        (setf (host-window-shown-status window) text)
        (ck doc "setStatus" text))
      (set-window-title window (doc-name doc)))))

(defmethod doc-show-arglist ((doc host-document) text)
  (setf (hdoc-arglist doc) text)
  (update-status doc))

(defmethod doc-set-title ((doc host-document) title)
  (setf (hdoc-title doc) title)
  (ck doc "setTitle" (hdoc-id doc) title)
  (when (host-active-p doc)
    (set-window-title (hdoc-window doc) title)))

(defun show-echo-state (doc)
  "The echo row of DOC's window as DOC has it -- its prompt when one is
open, else its message -- after DOC became the active document."
  (cond ((hdoc-mini-text doc)
         (ck doc "openMini" (hdoc-mini-label doc) (hdoc-mini-text doc))
         (when (hdoc-mini-completions doc)
           (ck doc "showCompletions" (hdoc-mini-completions doc)
               (hdoc-mini-completion-index doc))))
        (t
         (ck doc "closeMini")
         (ck doc "setEcho" (hdoc-message-text doc))))
  (setf (host-window-shown-status (hdoc-window doc)) nil)
  (update-status doc))

;;; ------------------------------------------------------------------
;;; The minibuffer's part
;;; ------------------------------------------------------------------

(defmethod doc-open-minibuffer ((doc host-document) label initial)
  (setf (hdoc-mini-label doc) label
        (hdoc-mini-text doc) (copy-seq initial)
        (hdoc-mini-completions doc) nil
        (hdoc-mini-completion-index doc) -1
        (hdoc-message-text doc) label)
  (when (host-active-p doc)
    (ck doc "openMini" label initial)))

(defmethod doc-close-minibuffer ((doc host-document))
  ;; The page's closeMini hides the list with the line.
  (setf (hdoc-mini-label doc) nil
        (hdoc-mini-text doc) nil
        (hdoc-mini-completions doc) nil
        (hdoc-mini-completion-index doc) -1
        (hdoc-message-text doc) "")
  (when (host-active-p doc)
    (ck doc "closeMini")
    (ck doc "setEcho" "")))

(defmethod doc-minibuffer-text ((doc host-document))
  (or (hdoc-mini-text doc) ""))

(defmethod doc-set-minibuffer-text ((doc host-document) text)
  (setf (hdoc-mini-text doc) (copy-seq text))
  (when (host-active-p doc)
    (ck doc "setMiniText" text)))

(defmethod doc-set-minibuffer-label ((doc host-document) label)
  (setf (hdoc-mini-label doc) label
        (hdoc-message-text doc) label)
  (when (host-active-p doc)
    (ck doc "setMiniLabel" label)))

(defmethod doc-show-completions ((doc host-document) names index)
  "The page's list above the input line: filled when NAMES is a list it
has not shown, its cursor moved when NAMES is the list it shows, hidden
when NAMES is NIL.  Kept on the document for SHOW-ECHO-STATE."
  (let ((same (and names (eq names (hdoc-mini-completions doc)))))
    (setf (hdoc-mini-completions doc) names
          (hdoc-mini-completion-index doc) index)
    (when (host-active-p doc)
      (cond ((null names) (ck doc "hideCompletions"))
            (same (ck doc "selectCompletion" index))
            (t (ck doc "showCompletions" names index))))
    ;; A list it is (shown with the prompt when the document is not the
    ;; active one): the echo row counts the candidates only.
    t))

(defun host-pick-completion (editor index accept)
  "The clamacsPickCompletion binding: row INDEX of the list clicked (ACCEPT
0) or double-clicked (1) in the active document's window."
  (let ((doc (active-document editor)))
    (when (and doc (integerp index))
      (minibuffer-pick doc index (and (realp accept) (/= accept 0))))))

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
Delete delete, the arrows and Home, End, PageUp, PageDown move, the
left and right arrows by the word with Alt or Control.  True when the key
did something."
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
          ;; By the word with Alt or Control, as the platforms have it
          ((or (eql key (make-key +key-left+ +mod-meta+))
               (eql key (make-key +key-left+ +mod-ctrl+)))
           (move :previous-word))
          ((or (eql key (make-key +key-right+ +mod-meta+))
               (eql key (make-key +key-right+ +mod-ctrl+)))
           (move :next-word))
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

(defparameter *host-command-keys*
  '(("c" . kill-ring-save) ("x" . kill-region) ("v" . yank)
    ("a" . mark-whole-buffer) ("z" . undo) ("Z" . redo))
  "What a letter held with the Command key runs: the platform's own keys
for copy, cut, paste, select all, undo and (with Shift) redo, as the
commands the Emacs keys run.")

(defun host-command-key (name shift)
  "The command of the Command key with the key NAME, or NIL."
  (and (= (length name) 1)
       (let ((c (char name 0)))
         (cdr (assoc (string (if (and shift (char-equal c #\z))
                                 #\Z
                                 (char-downcase c)))
                     *host-command-keys* :test #'string=)))))

(defun host-platform-key (doc command)
  "COMMAND, what a Command key asked for.  At a prompt only the paste is
the editor's: the clipboard's first line goes to the end of the input."
  (cond ((not (minibuffer-open-p doc))
         (keystate-reset (doc-keys doc))
         (run-command doc command))
        ((eq command 'yank)
         (let ((text (doc-clipboard-text doc)))
           (when (and text (string/= text ""))
             (doc-set-minibuffer-text
              doc (concatenate 'string (doc-minibuffer-text doc)
                               (subseq text 0 (position #\Newline text))))
             (minibuffer-changed doc))))))

(defparameter *host-motion-keys*
  (list +key-left+ +key-right+ +key-up+ +key-down+ +key-home+ +key-end+
        +key-pageup+ +key-pagedown+)
  "The keys that select when held with Shift.")

(defun shift-motion-key (key)
  "KEY without its Shift when it is a motion key held with Shift -- with
Control or Alt as well, which move by more -- else NIL."
  (and (/= 0 (logand (key-mods key) +mod-shift+))
       (member (key-code key) *host-motion-keys*)
       (make-key (key-code key) (logand (key-mods key) (lognot +mod-shift+)))))

(defun selection-shown-p (doc)
  "True while a selection -- Shift with a motion key, the mouse -- is shown
and holds text."
  (and (eq (doc-mark-active doc) :selection)
       (doc-mark doc)
       (/= (doc-mark doc) (doc-point doc))))

(defun delete-selection (doc)
  "The selection deleted, as typing over it and Backspace do in every
other application; the kill ring and the clipboard are left alone."
  (let ((mark (min (doc-mark doc) (doc-end doc)))
        (point (doc-point doc)))
    (setf (doc-mark-active doc) nil)
    (doc-delete doc (min mark point) (max mark point))
    t))

(defun host-text-key (doc key)
  "A key in the text: the Emacs layer first, then the widget's default.
Shift with a motion key is that motion with the mark left where the
selection began; a selection is replaced by what is typed and deleted by
Backspace and Delete, and the next key that is no such motion drops it."
  (let ((motion (shift-motion-key key))
        (before (mirror-text (hdoc-mirror doc))))
    (when motion
      (unless (doc-mark-active doc)
        (setf (doc-mark doc) (doc-point doc)
              (doc-mark-active doc) :selection))
      (setq key motion))
    (cond ((and (selection-shown-p doc)
                (not (keystate-in-prefix (doc-keys doc)))
                (or (printable-key-p key)
                    (eql key +key-backspace+)
                    (eql key +key-delete+)))
           (delete-selection doc)
           (when (printable-key-p key)
             (setf (doc-last-command doc) nil)
             (widget-default-key doc key)))
          ((handle-key doc key))
          (t (widget-default-key doc key)))
    (cond ((not (eq before (mirror-text (hdoc-mirror doc))))
           ;; An edit ends what is shown; the mark stays for `C-w'.
           (setf (doc-mark-active doc) nil))
          ((and (not motion) (eq (doc-mark-active doc) :selection))
           (setf (doc-mark-active doc) nil)))))

(defun host-key (editor doc-id name code ctrl alt meta shift target)
  "The clamacsKey binding: a key in DOC-ID's view (TARGET \"text\") or in
the input line (\"mini\")."
  (let ((doc (host-document-by-id editor doc-id))
        (key (host-decode-key name code ctrl alt meta shift))
        (command (and meta (not ctrl) (not alt) (host-command-key name shift))))
    (when (and doc (or key command))
      (let ((before (mirror-text (hdoc-mirror doc))))
        (cond (command
               (host-platform-key doc command)
               (unless (eq before (mirror-text (hdoc-mirror doc)))
                 (setf (doc-mark-active doc) nil)))
              ((minibuffer-open-p doc)
               (host-mini-key doc key))
              ((equal target "mini")
               ;; The input line is closed: the key is nobody's.
               nil)
              (t (host-text-key doc key)))
        ;; Whatever edited -- a command or the widget's default -- the
        ;; text changed: what the MUI widget's ContentsChanged hook says.
        (note-text-if-changed doc before)
        (note-cursor-moved doc)))))

(defun note-text-if-changed (doc before)
  "NOTE-TEXT-CHANGED for the lines the edit spans when the mirror's text
is no longer BEFORE -- every edit makes a fresh string, so identity is
the test -- so a paste or an undo of many lines is coloured whole."
  (let ((now (mirror-text (hdoc-mirror doc))))
    (unless (eq before now)
      (multiple-value-bind (from to insert) (text-diff before now)
        (declare (ignore to))
        (note-text-changed doc
                           (doc-index-line doc from)
                           (doc-index-line doc (+ from (length insert))))))))

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
        (let ((lo nil)
              (hi 0))
          (dolist (change changes)
            (destructuring-bind (from to inserted) change
              (mirror-replace m (+ from delta) (+ to delta) inserted)
              (setq lo (if lo (min lo (+ from delta)) (+ from delta))
                    hi (max hi (+ from delta (length inserted))))
              (incf delta (- (length inserted) (- to from)))))
          (mirror-set-point m head)
          (setf (doc-mark-active doc) nil)
          (setf (hdoc-shown-text doc) (mirror-text m)
                (hdoc-shown-head doc) (mirror-point m)
                (hdoc-shown-anchor doc) (mirror-point m))
          ;; Every line the changes span is coloured
          (if lo
              (note-text-changed doc (doc-index-line doc lo) (doc-index-line doc hi))
              (note-text-changed doc)))
        (note-cursor-moved doc)))))

(defun host-cursor (editor doc-id head anchor)
  "The clamacsCursor binding: the selection moved on its own.  What the
mouse selected is the region -- the mark at its anchor -- and a click
that selects nothing takes the shown region down."
  (let ((doc (host-document-by-id editor doc-id)))
    (when doc
      (let ((m (hdoc-mirror doc)))
        (mirror-set-point m head)
        (cond ((/= head anchor)
               (setf (doc-mark doc) (max 0 (min anchor (mirror-end m)))
                     (doc-mark-active doc) :selection))
              (t (setf (doc-mark-active doc) nil)))
        (setf (mirror-selection m) (and (/= head anchor)
                                        (cons (min head anchor) (max head anchor))))
        (setf (hdoc-shown-head doc) (mirror-point m)
              (hdoc-shown-anchor doc) (max 0 (min anchor (mirror-end m))))
        (note-cursor-moved doc)))))

;;; ------------------------------------------------------------------
;;; Documents and the window
;;; ------------------------------------------------------------------

(defun doc-kind-string (doc)
  (if (hdoc-dock-p doc) "tool" "source"))

(defmethod editor-make-document ((editor host-editor) &key path name lisp-mode)
  "A new document as a tab of the window the active document is in: a
source tab, or a tab of that window's dock for a tool buffer."
  (let* ((id (format nil "doc~D" (incf (host-editor-next-id editor))))
         (doc (make-instance 'host-document :editor editor :path path
                                            :name (or name *unnamed*)
                                            :lisp-mode lisp-mode
                                            :id id
                                            :window (active-window editor))))
    (setf (gethash id (host-editor-docs editor)) doc
          (hdoc-dock-p doc) (tool-document-p doc))
    (ck doc "makeDoc" id (doc-name doc) (doc-kind-string doc))
    (doc-set-title doc (doc-name doc))
    (doc-activate doc)
    doc))

(defmethod doc-activate ((doc host-document))
  "DOC's tab displayed with the keyboard, its window raised when the
keyboard was in another one, its echo row and status line rendered."
  (let* ((editor (doc-editor doc))
         (before (host-editor-active-doc editor))
         (window (hdoc-window doc)))
    (setf (host-editor-active-doc editor) doc)
    (when (hdoc-dock-p doc)
      (dock-note-shown window (hdoc-id doc)))
    (ck doc "activateDoc" (hdoc-id doc))
    (when (and before (not (eq (hdoc-window before) window)))
      (raise-window window))
    (show-echo-state doc)))

(defmethod doc-close-window ((doc host-document))
  "DOC's tab taken down; the next document of the same window takes
the keyboard, else the oldest open one; a detached window left with
nothing in it goes with it (HOUSEKEEPING)."
  (let ((editor (doc-editor doc))
        (window (hdoc-window doc)))
    (remhash (hdoc-id doc) (host-editor-docs editor))
    (ck doc "removeDoc" (hdoc-id doc))
    (when (hdoc-dock-p doc)
      (dock-note-hidden window (hdoc-id doc)))
    (when (eq (host-editor-active-doc editor) doc)
      (setf (host-editor-active-doc editor) nil)
      (let ((next (or (first (window-documents window))
                      (first (live-documents editor)))))
        (when next
          (doc-activate next)
          (unless (eq (hdoc-window next) window)
            (raise-window (hdoc-window next))))))
    (note-window-emptied window)))

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
                                (host-window-win (active-window editor)) text buttons))))))
             (if (and (integerp n) (<= 0 n) (< n (length choices)))
                 (nth n choices)
                 (car (last choices))))))))

(defmethod doc-ask-file ((doc host-document) title save initial)
  (let ((editor (doc-editor doc)))
    (push (list :file title save initial) (host-editor-asked editor))
    (cond ((null (host-editor-shim editor))
           (pop (host-editor-answers editor)))
          (t
           (let ((p (with-modal (editor)
                      (ffi:with-foreign-string (ftitle title)
                        (ffi:with-foreign-string (finitial initial)
                          (shim editor "clamacs_host_ask_file" :pointer
                                '(:pointer :pointer :int32 :pointer)
                                (host-window-win (active-window editor)) ftitle (if save 1 0) finitial))))))
             (unless (ffi:null-pointer-p p)
               (unwind-protect (ffi:foreign-to-string p)
                 (shim editor "clamacs_host_free" :void '(:pointer) p))))))))

;;; --- window positions (snapshot.lisp)

(defun window-frame (window)
  "Left, top, width and height of WINDOW's native window -- without
one, its stub frame."
  (let ((editor (host-window-editor window))
        (win (host-window-win window)))
    (if win
        (let ((out (ffi:alloc-foreign 16)))
          (unwind-protect
               (progn
                 (shim editor "clamacs_host_get_frame" :void '(:pointer :pointer) win out)
                 (values (ffi:peek-i32 out 0) (ffi:peek-i32 out 4)
                         (ffi:peek-i32 out 8) (ffi:peek-i32 out 12)))
            (ffi:free-foreign out)))
        (values-list (host-window-stub-frame window)))))

(defun set-window-frame (window left top width height)
  (let ((editor (host-window-editor window))
        (win (host-window-win window)))
    (if win
        (shim editor "clamacs_host_set_frame" :void '(:pointer :int32 :int32 :int32 :int32)
              win left top width height)
        (setf (host-window-stub-frame window) (list left top width height)))))

(defconstant +cascade-offset+ 40
  "How far a detached window without a stored place sits from the main
window's corner.")

(defun place-window (window role)
  "WINDOW where the layout file puts ROLE -- the main window's `doc1',
a detached window's first document's role or its panel's -- else, for a
detached window, a cascade off the main window's frame (the main window
keeps webview's own place: the layout said nothing).  ROLE `doc1' is the
main window's place, never a detached window's."
  (let ((editor (host-window-editor window)))
    (multiple-value-bind (left top width height)
        (if (and (not (main-window-p window)) (equal role "doc1"))
            nil
            (layout-place editor role))
      (cond (left
             (set-window-frame window left top width height))
            ((not (main-window-p window))
             (multiple-value-bind (mleft mtop mwidth mheight)
                 (window-frame (host-editor-main editor))
               (set-window-frame window (+ mleft +cascade-offset+) (+ mtop +cascade-offset+)
                                 mwidth mheight)))))))

(defmethod doc-geometry ((doc host-document))
  (and (not (doc-closing doc))
       (window-frame (hdoc-window doc))))

(defun dock-frame (window)
  "Where WINDOW's dock is, as a window of its own would be: the bottom
DOCK-HEIGHT pixels of its frame -- the whole frame when the window has
no source tabs, since the page lets the dock fill it then."
  (multiple-value-bind (left top width height) (window-frame window)
    (if (window-source-documents window)
        (let ((dock (min (host-window-dock-height window) height)))
          (values left (+ top (- height dock)) width dock))
        (values left top width height))))

(defmethod editor-aux-windows ((editor host-editor))
  "The main window's dock, when it is open, under the role `dock' -- the
layout file's entry for its height -- and each open panel under the role
the MUI frontend's window has, with the frame of the dock it is in, so a
snapshot taken here keeps every role the Amiga file has and a panel
shown in a window of its own comes up there again."
  (let ((main (host-editor-main editor)))
    (flet ((panel (name role open)
             (when open
               (list (cons role (multiple-value-list (dock-frame (panel-window editor name))))))))
      (append (when (host-window-dock-open main)
                (list (cons "dock" (multiple-value-list (dock-frame main)))))
              (panel "diagnostics" "errors" (host-editor-diag-open editor))
              (panel "debugger" "debugger" (host-editor-dbg-open editor))
              (panel "inspector" "inspector" (host-editor-insp-open editor))))))

(defun place-dock (editor)
  "The dock's height from the layout file's `dock' entry, told to the
main window's page before anything opens it."
  (multiple-value-bind (left top width height) (layout-place editor "dock")
    (declare (ignore left top width))
    (when (and height (> height 0))
      (setf (host-window-dock-height (host-editor-main editor)) height)
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
;;; The menu strip is the table SEND-MENUS hands out once at start, one
;;; entry per table index.  Where the host has a menu bar of its own --
;;; macOS, the screen's -- the shim builds it there
;;; (clamacs_host_menu_set) and the page's bar stays hidden; elsewhere the
;;; page draws it, webview having no API for a native one.  A pick comes
;;; back as that index either way (the shim's callback, the clamacsMenu
;;; binding) and runs MENU-PICK on the active document, so the menu is
;;; the third entrance to the command table here as it is under MUI,
;;; never a second implementation.  MENU-UPDATE, after every entry, brings
;;; the enable states in step with MENU-STATE (only what changed is sent)
;;; and each dynamic group -- the Buffers menu, the View menu's themes --
;;; in step with DYNAMIC-MENU (remade when its entries or the ticked
;;; object changed), as the MUI frontend's does after a command and after
;;; every mailbox drain.  CLAMACS_HOST_MENU=page in the environment keeps
;;; the page's bar on a host that has its own.

;;; The page and the shim are told each entry's MENU-WIRE-KIND in lower
;;; case: `title', `item', `bar', a dynamic group's name (`buffers',
;;; `themes'), or `hidden' for what this frontend does not draw.  Both
;;; skip a kind they do not know, and every entry keeps its line, so the
;;; indices stay the table's.  A group's lines go out as CK.setDynamic
;;; (which, lines) to the page and clamacs_host_menu_dynamic (which,
;;; lines) to the shim -- neither knows what a buffer or a theme is, they
;;; see a named list of lines -- and a pick comes back as the group and
;;; the line's position (clamacsDynamic; the shim's callback names the
;;; group by its entry's table index).

(defmethod editor-dynamic-groups ((editor host-editor))
  '(:buffers :themes :minimap))

(defun dynamic-group-named (editor name)
  "The dynamic group this frontend draws under NAME -- a keyword, or its
name as the page spells it (`buffers') -- or NIL."
  (and (or (stringp name) (symbolp name))
       name
       (find name (editor-dynamic-groups editor) :test #'string-equal)))

(defun dynamic-group-at (index)
  "The dynamic group whose entry is at the table INDEX, or NIL."
  (let ((e (menu-entry index)))
    (and e (menu-entry-dynamic e))))

(defun menu-wire-kind-string (editor index)
  (string-downcase (symbol-name (menu-wire-kind editor index))))

(defun menu-table-text (editor)
  "The table as the shim takes it: one line per entry in order,
`kind<TAB>title<TAB>keys'."
  (format nil "~{~A~^~%~}"
          (loop for e in (menu-entries)
                for index from 0
                collect (format nil "~A~C~A~C~A"
                                (menu-wire-kind-string editor index)
                                #\Tab (or (menu-entry-title e) "")
                                #\Tab (or (menu-entry-keys e) "")))))

(defun dynamic-menu-text (entries ticked)
  "A dynamic group's ENTRIES (DYNAMIC-MENU's list) with TICKED's item
ticked, as the shim takes it: one line per entry, spelled as the port's
BUFFERS and THEMES verbs spell them."
  (format nil "~{~A~^~%~}" (dynamic-menu-lines entries ticked)))

(defun native-menu-wanted-p ()
  "False when CLAMACS_HOST_MENU=page asks for the page's bar on a host
that has a menu bar of its own."
  (let ((env (ext:getenv "CLAMACS_HOST_MENU")))
    (not (and env (string-equal env "page")))))

(defun native-menu-callback (editor which n)
  "The shim's pick callback: WHICH 0 is the table's item N; any other
WHICH is the table index of a dynamic group's entry, and N the position
of the line picked in that group (the bar counts).  It runs inside an
entry, as a binding does (CALL-WITH-ENTRY: the WITH-ENTRY macro is
defined further down), and is dropped while a requester runs its own
loop."
  (unless (host-editor-in-modal editor)
    (call-with-entry editor
                     (lambda ()
                       (if (eql which 0)
                           (host-menu-pick editor n)
                           (let ((group (dynamic-group-at which)))
                             (when group
                               (host-dynamic-pick editor group n))))))))

(defun native-menu-install (editor)
  "The table onto the host's own menu bar through the shim, when it has
one: true then.  Picks come back through NATIVE-MENU-CALLBACK."
  (when (and (host-editor-shim editor) (native-menu-wanted-p))
    (let ((cb (ffi:make-callback
               :void '(:int32 :int32 :pointer)
               (lambda (which n arg)
                 (declare (ignore arg))
                 (native-menu-callback editor which n)))))
      (push cb (host-window-callbacks (host-editor-main editor)))
      (/= 0 (ffi:with-foreign-string (table (menu-table-text editor))
              (shim editor "clamacs_host_menu_set" :int32 '(:pointer :pointer :pointer :pointer)
                    (host-window-win (host-editor-main editor)) table cb (ffi:make-foreign-pointer 0)))))))

(defun menu-table-for-page (editor)
  "The table as the page takes it: [kind, title, keys] per entry -- or
empty, which hides the page's bar, when the menu is the host's own."
  (if (host-editor-native-menu editor)
      #()
      (coerce (loop for e in (menu-entries)
                    for index from 0
                    collect (list (menu-wire-kind-string editor index)
                                  (or (menu-entry-title e) "")
                                  (or (menu-entry-keys e) "")))
              'vector)))

(defun send-menus (editor &key (native (native-menu-install editor)))
  "The table to the host's menu bar when NATIVE (the shim took it), or
else to the page (an empty table hides the page's bar), and the enable
states forgotten so the next MENU-UPDATE sends every one."
  (setf (host-editor-native-menu editor) native)
  (ck editor "setMenus" (menu-table-for-page editor))
  (setf (host-editor-menus-sent editor) t
        (host-editor-menu-enabled editor) nil
        (host-editor-dynamic-shown editor) '()
        (host-editor-dynamic-objects editor) '()))

(defun send-menus-to (window)
  "What the menu bar shows, to the page of a WINDOW that came up after
the table went out: the table, then every item's enable state and every
dynamic group as the bar shows them now -- the host's own bar needs
nothing, and an empty table hides the page's."
  (let ((editor (host-window-editor window)))
    (when (host-editor-menus-sent editor)
      (ck window "setMenus" (menu-table-for-page editor))
      (unless (host-editor-native-menu editor)
        (loop for flag in (host-editor-menu-enabled editor)
              for index from 0
              when (eq (menu-entry-kind (menu-entry index)) :item)
                do (ck window "menuEnable" index flag))
        (dolist (which (editor-dynamic-groups editor))
          (let ((shown (dynamic-menu-shown editor which)))
            (when shown
              (ck window "setDynamic" which (dynamic-menu-page-lines (car shown) (cdr shown))))))))))

(defun dynamic-menu-page-lines (entries ticked)
  "A dynamic group's ENTRIES as the page takes them: `-' for the bar,
[label, ticked] for an item."
  (coerce (mapcar (lambda (e)
                    (if (eq e :bar)
                        "-"
                        (list (car e) (eq (cdr e) ticked))))
                  entries)
          'vector))

(defun native-menu-enable (editor index flag)
  (if (host-editor-shim editor)
      (shim editor "clamacs_host_menu_enable" :void '(:int32 :int32) index (if flag 1 0))
      (push (list :enable index flag) (host-editor-native-calls editor))))

(defun native-menu-dynamic (editor which text)
  "The group WHICH's lines TEXT to the shim, which remakes the menu."
  (if (host-editor-shim editor)
      (ffi:with-foreign-string (name (string-downcase (symbol-name which)))
        (ffi:with-foreign-string (lines text)
          (shim editor "clamacs_host_menu_dynamic" :void '(:pointer :pointer) name lines)))
      (push (list which text) (host-editor-native-calls editor))))

(defun menu-enable-sync (editor)
  "The enable state of every item whose state differs from what the
menu bar shows."
  (let ((want (menu-enabled-items editor))
        (shown (host-editor-menu-enabled editor)))
    (loop for flag in want
          for index from 0
          do (let ((entry (menu-entry index)))
               (when (and (eq (menu-entry-kind entry) :item)
                          (or (null shown) (not (eq flag (nth index shown)))))
                 (if (host-editor-native-menu editor)
                     (native-menu-enable editor index flag)
                     (ck-all editor "menuEnable" index flag)))))
    (setf (host-editor-menu-enabled editor) want)))

(defun dynamic-menu-shown (editor which)
  "What the menu bar shows of the group WHICH: (ENTRIES . TICKED), or
NIL before its first sync."
  (cdr (assoc which (host-editor-dynamic-shown editor))))

(defun dynamic-menu-sync (editor which)
  "The group WHICH remade when its entries or its tick are no longer what
the menu bar shows: to the page `-' for the bar and [label, ticked] for
an item, to the shim the port verb's lines."
  (multiple-value-bind (want ticked) (dynamic-menu editor which)
    (let ((shown (dynamic-menu-shown editor which)))
      (unless (and shown
                   (dynamic-menu-equal want (car shown))
                   (eq ticked (cdr shown)))
        (if (host-editor-native-menu editor)
            (native-menu-dynamic editor which (dynamic-menu-text want ticked))
            (ck-all editor "setDynamic" which (dynamic-menu-page-lines want ticked)))
        (setf (host-editor-dynamic-shown editor)
              (acons which (cons want ticked)
                     (remove which (host-editor-dynamic-shown editor) :key #'car))
              (host-editor-dynamic-objects editor)
              (acons which (coerce (mapcar (lambda (e) (if (eq e :bar) nil (cdr e))) want) 'vector)
                     (remove which (host-editor-dynamic-objects editor) :key #'car)))))))

(defun host-menu-click (which n &optional (editor *editor*))
  "For a script: pick an item of the host's own menu bar as the mouse
would -- WHICH 0 and the table index N, or a dynamic group (:BUFFERS,
:THEMES, or its entry's table index) and the position N of a line in it
-- through the shim, which performs the NSMenuItem's action, so the pick
takes the whole path: Cocoa, the callback, the entry.  Answers
\"picked\", or \"no native menu\" where the page draws the bar (the page's
items are picked through the port's MENU verb then)."
  (let ((which (if (keywordp which) (or (menu-find-dynamic which) -1) which)))
    (cond ((not (and editor (host-editor-shim editor) (host-editor-native-menu editor)))
           "no native menu")
          ((and (integerp which) (>= which 0) (integerp n)
                (/= 0 (shim editor "clamacs_host_menu_click" :int32 '(:int32 :int32) which n)))
           "picked")
          (t "no such item"))))

(defun page-menu-report (panels)
  "The `menu' object of the page's report PANELS (clamacsPanels), or NIL:
it holds arrays only, so it ends at its first brace."
  (let* ((key "\"menu\":{")
         (start (search key panels)))
    (when start
      (let ((end (position #\} panels :start start)))
        (when end
          (subseq panels (+ start (length key) -1) (1+ end)))))))

(defun host-menu-report (&optional (editor *editor*))
  "What the menu bar shows, read off the bar itself -- the shim's items
when the menu is the host's, the page's last report otherwise -- as JSON:
the item count, the dimmed table indices, and each dynamic group's lines
under its name (`buffers', `themes') as the port's verbs spell them.  For
a script's `EVAL (clamacs::host-menu-report)' over the port, so the run
checks what is on the screen beside HOST-PANEL-STATE, the editor's own
account.  \"no report\" when there is none yet."
  (or (and editor
           (if (host-editor-native-menu editor)
               (when (host-editor-shim editor)
                 (let ((p (shim editor "clamacs_host_menu_report" :pointer '())))
                   (unless (ffi:null-pointer-p p)
                     (unwind-protect (ffi:foreign-to-string p)
                       (shim editor "clamacs_host_free" :void '(:pointer) p)))))
               (page-menu-report (host-page-panels editor))))
      "no report"))

(defun menu-update (editor)
  "The menu bar in step with the editor's state, after every entry.
Nothing before the table went out (an editor the tests make without one)."
  (when (host-editor-menus-sent editor)
    (menu-enable-sync editor)
    (dolist (which (editor-dynamic-groups editor))
      (dynamic-menu-sync editor which))))

(defun host-menu-pick (editor index)
  "The clamacsMenu binding: the item at INDEX was picked.  Run only when
the item is enabled now -- the page dims what Lisp told it to, but the
state may have moved since the last report."
  (when (and (integerp index) (menu-item-enabled-p editor index))
    (menu-pick editor index)))

(defun host-dynamic-pick (editor which n)
  "The clamacsDynamic binding and the shim's pick: the item at position N
of the group WHICH, as the menu bar counts its entries (the bar included),
picked -- a buffer's window activated, a theme loaded.  A position off the
menu, the bar's, or a group the bar does not draw: nothing."
  (let ((objects (cdr (assoc which (host-editor-dynamic-objects editor)))))
    (when (and objects (integerp n) (<= 0 n) (< n (length objects)))
      (let ((object (aref objects n)))
        (and object (dynamic-menu-pick editor which object))))))

(defun dynamic-menu-drawn-p (editor which)
  "Whether the menu bar has the group WHICH: the table went out and this
frontend draws it."
  (and (host-editor-menus-sent editor)
       (member which (editor-dynamic-groups editor))
       t))

(defmethod editor-dynamic-menu-lines ((editor host-editor) which)
  "What the menu bar's group WHICH shows, brought up to date first -- the
port's verbs run from the mailbox, not inside a menu pick.  Without a
menu bar (the table not sent), what it should be."
  (cond ((not (dynamic-menu-drawn-p editor which))
         (call-next-method))
        (t
         (dynamic-menu-sync editor which)
         (let ((shown (dynamic-menu-shown editor which)))
           (dynamic-menu-lines (car shown) (cdr shown))))))

(defmethod editor-dynamic-menu-pick ((editor host-editor) which label)
  (cond ((not (dynamic-menu-drawn-p editor which))
         (call-next-method))
        (t
         (dynamic-menu-sync editor which)
         (let ((n (position-if (lambda (e) (and (consp e) (string= (car e) label)))
                               (car (dynamic-menu-shown editor which)))))
           (and n (host-dynamic-pick editor which n))))))

;;; ------------------------------------------------------------------
;;; The theme (theme.lisp)
;;; ------------------------------------------------------------------
;;;
;;; The page keeps every colour in CSS variables on :root, so a theme is
;;; those variables set on the document element, which every rule reads
;;; already: one CK.theme call with THEME-CSS-VARS' pairs and the dark
;;; flag (the page sets data-theme from it, so color-scheme -- the
;;; scrollbars, the form controls -- follows).  Sent by LOAD-THEME through
;;; the generic, and by START after the menus, so the editor comes up in
;;; the theme the init file named.  The page's own palette, picked by the
;;; system's setting, stays as the fallback before the first call -- and
;;; that setting, reported at clamacsReady, is what the default theme
;;; follows, so an editor without a pick looks exactly as before.

(defun theme-page-args (theme)
  "THEME's variables for the page, the text size setting (FONT-SIZE)
over the theme's `--font-size' when there is one."
  (list (mapcar (lambda (pair)
                  (list (car pair)
                        (if (and *font-size* (string= (car pair) "--font-size"))
                            (format nil "~Dpx" *font-size*)
                            (cdr pair))))
                (theme-css-vars theme))
        (and (theme-dark theme) t)))

(defmethod editor-apply-font-size ((editor host-editor) size)
  "The theme sent again, its `--font-size' the setting's."
  (declare (ignore size))
  (editor-apply-theme editor (active-theme)))

(defmethod editor-default-font-size ((editor host-editor))
  "The theme's `:font-size' in pixels, 14 when it is not a pixel size."
  (let* ((value (theme-resolve (active-theme) :font-size))
         (n (and (stringp value) (parse-integer value :junk-allowed t))))
    (if (and n (plusp n)) n 14)))

(defmethod editor-apply-theme ((editor host-editor) theme)
  (apply #'ck-all editor "theme" (theme-page-args theme)))

(defun send-theme (editor)
  "The theme in effect to the page: at start, after the menus."
  (editor-apply-theme editor (active-theme)))

(defun send-theme-to (window)
  "The theme in effect to the page of a WINDOW that came up later."
  (apply #'ck window "theme" (theme-page-args (active-theme))))

;;; The minimap (theme.lisp, SHOW-MINIMAP): the page draws it beside every
;;; source view -- the whole text in miniature, the part on screen marked
;;; -- and CK.setMinimap shows or hides it in every window.  Sent at start
;;; after the theme, so an init file's `(show-minimap nil)' is honoured
;;; before the first document, and to a later window when it settles.

(defmethod editor-apply-minimap ((editor host-editor) flag)
  (ck-all editor "setMinimap" (and flag t)))

(defun send-minimap (editor)
  "The minimap setting to the page: at start, after the theme."
  (editor-apply-minimap editor *minimap*))

(defun send-minimap-to (window)
  "The minimap setting to the page of a WINDOW that came up later."
  (ck window "setMinimap" (and *minimap* t)))

(defun host-ready (target user-agent &optional scheme)
  "The clamacsReady binding: the page of TARGET's window (TARGET-WINDOW)
is up.  From the main window's page, the first, SCHEME -- `dark' or
`light' from its matchMedia -- makes the same built-in the default
theme; a page that does not say (an older page, the smoke's stub) leaves
the default as it is.  A later window's page reports the same scheme and
is told the theme in effect when it is settled (SETTLE-WINDOW)."
  (let ((window (target-window target)))
    (setf (host-window-ready window) t)
    (when (main-window-p window)
      (setf (host-editor-user-agent (host-window-editor window)) user-agent)
      (when (member scheme '("dark" "light") :test #'equal)
        (setf (host-editor-scheme (host-window-editor window)) scheme
              *default-theme* (if (string= scheme "dark") :dark :light))))))

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

;;; Each window has a dock of its own, and a panel lives in one window's
;;; dock: the main window's until it is moved out (MOVE-PANEL), which
;;; PANEL-WINDOWS records.  A window's dock mirror counts what is in THAT
;;; window.

(defparameter *panel-names* '("diagnostics" "debugger" "inspector"))

(defparameter *panel-roles* '(("diagnostics" . "errors") ("debugger" . "debugger")
                              ("inspector" . "inspector"))
  "Each panel's role in the layout file: the MUI frontend's window.")

(defun panel-name-p (name)
  (and (stringp name) (member name *panel-names* :test #'string=) t))

(defun panel-role (name)
  (cdr (assoc name *panel-roles* :test #'string=)))

(defun panel-window (editor name)
  "The window whose dock holds the panel NAME."
  (or (cdr (assoc name (host-editor-panel-windows editor) :test #'string=))
      (host-editor-main editor)))

(defun set-panel-window (editor name window)
  (setf (host-editor-panel-windows editor)
        (remove name (host-editor-panel-windows editor) :key #'car :test #'string=))
  (unless (main-window-p window)
    (push (cons name window) (host-editor-panel-windows editor))))

(defun panel-open-p (editor name)
  (cond ((string= name "diagnostics") (host-editor-diag-open editor))
        ((string= name "debugger") (host-editor-dbg-open editor))
        ((string= name "inspector") (host-editor-insp-open editor))
        (t nil)))

(defun window-panels (window)
  "The open panels in WINDOW's dock, in the page's order."
  (let ((editor (host-window-editor window)))
    (remove-if-not (lambda (name)
                     (and (panel-open-p editor name)
                          (eq (panel-window editor name) window)))
                   *panel-names*)))

(defun dock-note-shown (window name)
  (setf (host-window-dock-open window) t
        (host-window-dock-shown window) name))

(defun dock-open-items (window)
  "The names of WINDOW's dock's open items, panels first, as the page
keeps them: which one takes over when the displayed item goes."
  (append (window-panels window)
          (loop for doc in (window-documents window)
                when (hdoc-dock-p doc) collect (hdoc-id doc))))

(defun dock-note-hidden (window name)
  (when (equal (host-window-dock-shown window) name)
    (let ((next (first (dock-open-items window))))
      (setf (host-window-dock-shown window) next
            (host-window-dock-open window) (and next t)))))

;;; --- the diagnostics panel

(defmethod editor-show-diagnostics ((editor host-editor) rows &key open)
  (setf (host-editor-diag-rows editor) rows
        (host-editor-diag-selected editor) nil)
  (let ((window (panel-window editor "diagnostics")))
    (ck window "showDiagnostics" (coerce rows 'vector) (and (or open rows) t))
    (when (or open rows)
      (setf (host-editor-diag-open editor) t)
      (dock-note-shown window "diagnostics"))))

(defmethod editor-select-diagnostic ((editor host-editor) row)
  (setf (host-editor-diag-selected editor) row)
  (ck (panel-window editor "diagnostics") "selectDiagnostic" row))

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

(defun dbg-open-call (window dbg)
  (ck window "dbgOpen" (debugger-level dbg) (debugger-condition dbg)
      (coerce (debugger-restarts dbg) 'vector) (and (debugger-has-continue dbg) t)))

(defmethod editor-debugger-open ((editor host-editor) dbg)
  (setf (host-editor-dbg-open editor) t)
  (let ((window (panel-window editor "debugger")))
    (dbg-open-call window dbg)
    ;; Shown, not given the keyboard: it arrives while the user may be typing.
    (dock-note-shown window "debugger")))

(defmethod editor-debugger-close ((editor host-editor))
  (when (host-editor-dbg-open editor)
    (setf (host-editor-dbg-open editor) nil)
    (let ((window (panel-window editor "debugger")))
      (ck window "dbgClose")
      (dock-note-hidden window "debugger")
      (note-window-emptied window))))

(defmethod editor-debugger-raise ((editor host-editor))
  (setf (host-editor-dbg-open editor) t)
  (let ((window (panel-window editor "debugger")))
    (ck window "dbgRaise")
    (dock-note-shown window "debugger")
    (raise-window window)))

(defmethod editor-debugger-frames ((editor host-editor) rows)
  (ck (panel-window editor "debugger") "dbgFrames" (coerce rows 'vector)))

(defmethod editor-debugger-select-frame ((editor host-editor) n)
  (ck (panel-window editor "debugger") "dbgSelectFrame" n))

(defmethod editor-debugger-locals ((editor host-editor) rows)
  (ck (panel-window editor "debugger") "dbgLocals" (coerce rows 'vector)))

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
         (dock-note-hidden (panel-window editor name) name)
         (note-window-emptied (panel-window editor name)))
        ((equal name "inspector")
         (setf (host-editor-insp-open editor) nil)
         (dock-note-hidden (panel-window editor name) name)
         (note-window-emptied (panel-window editor name)))
        (t (error "The dock has no panel ~S" name))))

(defun host-dock-shown (editor name)
  "The clamacsDockShown binding: the user clicked the tab of the panel NAME
and the page displays it.  Told to the dock's mirror of the panel's window
as any other showing is, so the next hide of the displayed item follows
the page.  A name that is no open panel (a stale page, JSON null) changes
nothing; a tool buffer's tab is clamacsActivate's."
  (when (panel-name-p name)
    (let ((window (panel-window editor name)))
      (when (member name (dock-open-items window) :test #'equal)
        (dock-note-shown window name)))))

;;; --- the inspector panel

(defun insp-open-call (window insp)
  (ck window "inspOpen" (inspector-type insp) (inspector-depth insp)
      (inspector-object insp) (coerce (inspector-parts insp) 'vector)))

(defmethod editor-inspector-open ((editor host-editor) insp)
  (setf (host-editor-insp-open editor) t)
  (let ((window (panel-window editor "inspector")))
    (insp-open-call window insp)
    (dock-note-shown window "inspector")))

;;; --- the dock's height, and what the page reports

(defun host-dock-resized (target height)
  "The clamacsDockResized binding: the splitter of TARGET's window was
dragged.  A page at a fractional zoom reports a fractional height; it is
rounded to whole pixels."
  (when (and (realp height) (> height 0))
    (setf (host-window-dock-height (target-window target)) (round height))))

(defun host-panels-report (target json)
  "The clamacsPanels binding: what TARGET's window's page shows, kept
verbatim."
  (when (stringp json)
    (setf (host-window-page-panels (target-window target)) json)))

;;; --- for a script: what the panels show

(defun window-contents-words (window)
  "WINDOW's tabs as words: the source documents' ids, the dock's items."
  (append (mapcar #'hdoc-id (window-source-documents window))
          (dock-open-items window)))

(defun panel-window-suffix (editor name)
  "` window N' after a panel's state when it is not in the main window."
  (let ((window (panel-window editor name)))
    (if (main-window-p window) "" (format nil " window ~D" (host-window-number window)))))

(defun host-panel-state (panel &optional (editor *editor*))
  "What the editor told the page to show for PANEL -- :MENU, :THEME,
:MINIMAP, :DOCK (the main window's), :WINDOWS, :DIAGNOSTICS, :DEBUGGER
or :INSPECTOR -- as one line of words, for a script's `EVAL
\(clamacs::host-panel-state :debugger)' over the port.  A panel shown in
a window of its own says `window N' at the end."
  (unless editor
    (return-from host-panel-state "no editor"))
  (flet ((open-word (flag) (if flag "open" "closed"))
         (row-word (n) (if n (princ-to-string n) "none")))
    (ecase panel
      (:windows
       ;; `windows 2: 1 (doc1 doc3) 2 (doc2 debugger) active doc2'
       (let ((active (active-document editor)))
         (format nil "windows ~D:~{ ~D (~{~A~^ ~})~} active ~A"
                 (length (live-windows editor))
                 (loop for w in (live-windows editor)
                       append (list (host-window-number w) (window-contents-words w)))
                 (if active (hdoc-id active) "none"))))
      (:menu
       (format nil "items ~D disabled (~{~D~^ ~}) buffers (~{~A~^|~}) themes (~{~A~^|~}) minimap (~{~A~^|~})"
               (count :item (menu-entries) :key #'menu-entry-kind)
               (loop for flag in (host-editor-menu-enabled editor)
                     for index from 0
                     when (and (not flag) (eq (menu-entry-kind (menu-entry index)) :item))
                       collect index)
               (editor-dynamic-menu-lines editor :buffers)
               (editor-dynamic-menu-lines editor :themes)
               (editor-dynamic-menu-lines editor :minimap)))
      (:minimap
       ;; The setting, as the page was told it; the page's report says
       ;; what it drew (`minimap' in clamacsPanels)
       (if *minimap* "on" "off"))
      (:theme
       ;; The theme in effect, and the colours the page's report carries
       ;; -- two variables and the gutter's painted background -- so a
       ;; script compares the two accounts
       (let ((theme (active-theme)))
         (format nil "~A ~A bg ~A keyword ~A system ~A gutter ~A"
                 (theme-name-string (theme-name theme))
                 (if (theme-dark theme) "dark" "light")
                 (theme-resolve theme :bg)
                 (theme-resolve theme :keyword)
                 (or (host-editor-scheme editor) "unknown")
                 (theme-resolve theme :gutter-bg))))
      (:dock
       (let ((main (host-editor-main editor)))
         (format nil "~A height ~D shown ~A"
                 (open-word (host-window-dock-open main))
                 (host-window-dock-height main)
                 (or (host-window-dock-shown main) "nothing"))))
      (:diagnostics
       (format nil "~A rows ~D selected ~A~A"
               (open-word (host-editor-diag-open editor))
               (length (host-editor-diag-rows editor))
               (row-word (host-editor-diag-selected editor))
               (panel-window-suffix editor "diagnostics")))
      (:debugger
       (let ((dbg (editor-debugger-state editor)))
         (format nil "~A level ~D restarts ~D continue ~A frames ~D frame ~A locals ~D condition ~A~A"
                 (open-word (host-editor-dbg-open editor))
                 (debugger-level dbg)
                 (length (debugger-restarts dbg))
                 (if (debugger-has-continue dbg) "yes" "no")
                 (length (debugger-frames dbg))
                 (row-word (debugger-frame dbg))
                 (length (debugger-locals dbg))
                 (debugger-condition dbg)
                 (panel-window-suffix editor "debugger"))))
      (:inspector
       (let ((insp (editor-inspector-state editor)))
         (format nil "~A type ~A depth ~D parts ~D object ~A~A"
                 (open-word (host-editor-insp-open editor))
                 (inspector-type insp)
                 (inspector-depth insp)
                 (length (inspector-parts insp))
                 (inspector-object insp)
                 (panel-window-suffix editor "inspector")))))))

(defun host-page-panels (&optional (editor *editor*) (number 1))
  "The last report of the page of window NUMBER (the main window's)
about what its menu bar, its dock and its panels show (clamacsPanels), as
the JSON text it sent; \"no report\" before the first, \"no window\" for a
number no window has."
  (let ((window (and editor (host-window editor number))))
    (cond ((null window) (if editor "no window" "no report"))
          ((host-window-page-panels window))
          (t "no report"))))

;;; ------------------------------------------------------------------
;;; Detached windows: a tab shown in a window of its own
;;; ------------------------------------------------------------------
;;;
;;; What the MUI editor does with every document -- a window each -- the
;;; host does on request: the tab's context menu (`Show in separate
;;; window', clamacsDetach) or M-x clamacs-detach-window opens a second
;;; webview instance with the same page in it and moves the tab there;
;;; `Move to main window' (clamacsAttach, clamacs-attach-window) brings
;;; it back.  The detached window's close button brings its documents
;;; back the same way -- a buffer is not lost by closing a window -- and
;;; CLOSES its panels, as their tabs' close buttons would: a panel is a
;;; view of state the editor keeps (Show Errors, M-x clamacs-debugger
;;; bring it back), and a closed window that came back as a tab to close
;;; again was the complaint.  A window whose last tab closes goes down by
;;; itself.  The library serves any number of instances (its Cocoa
;;; backend sets the application up once and stops the loop only when
;;; the last window it counts goes, which a webview_destroy of ours
;;; never counts), and the stepped loop pumps the application's events,
;;; every window's.
;;;
;;; The move is two things the mirror makes cheap: the tab is taken out
;;; of one page (removeDoc) and made in the other (makeDoc) from the
;;; text, the point and the modified flag Lisp holds, then coloured whole
;;; -- the colours live in the page, so they are painted again.  A panel
;;; moves by replaying its state (the rows of diag.lisp, the debugger and
;;; inspector structs) into the other window's dock (REPLAY-PANEL).  A
;;; new window's page is not up when the move is asked for, so the move
;;; waits on the window's PENDING list until clamacsReady came and
;;; HOUSEKEEPING settled the window with the menus, the theme and the
;;; dock height -- nothing is ever sent to a page that is not there.
;;; The layout file places a detached window at its first tab's role (a
;;; document's `docN', a panel's MUI window role), so a debugger shown
;;; separately comes up where the Amiga's debugger window was; without an
;;; entry it cascades off the main window.

(defun note-window-emptied (window)
  "A detached window whose page holds no tab any more is closed by
HOUSEKEEPING -- unless something is on its way in."
  (when (and (not (main-window-p window))
             (null (window-documents window))
             (null (window-panels window))
             (null (host-window-pending window)))
    (setf (host-window-closing window) (or (host-window-closing window) :empty))))

(defun open-window (editor role)
  "A new window with the page in it, placed at the layout's ROLE (else
cascaded), its page loading; what moves in waits for it to settle.
Without a page (the tests) it is ready at once."
  (let ((window (add-window editor)))
    (when (host-editor-webview editor)
      (let ((w (wv editor "webview_create" :pointer '(:int32 :pointer) 0 (ffi:make-foreign-pointer 0))))
        (when (ffi:null-pointer-p w)
          (setf (host-editor-windows editor) (remove window (host-editor-windows editor)))
          (error "Clamacs: webview_create failed for a second window."))
        (setf (host-window-w window) w)
        (wv-str window "webview_set_title" "Clamacs")
        (wv editor "webview_set_size" :int32 '(:pointer :int32 :int32 :int32) w 1000 700 0)
        (setf (host-window-win window) (wv editor "webview_get_window" :pointer '(:pointer) w))
        (install-bindings window)
        ;; The close button: the documents back into the main window, the
        ;; panels closed (ATTACH-ALL).
        (install-close-hook window (lambda () (setf (host-window-closing window) :attach)))
        (wv-str window "webview_set_html" (host-editor-page-html editor))))
    (setf (host-window-dock-height window) (host-window-dock-height (host-editor-main editor)))
    (place-window window role)
    (unless (host-window-w window)
      (setf (host-window-ready window) t))
    window))

(defun settle-window (window)
  "WINDOW's page is up: the menus, the theme, the dock's height and the
detached mark to it, then what was waiting to move in."
  (setf (host-window-settled window) t)
  (send-menus-to window)
  (send-theme-to window)
  (send-minimap-to window)
  (ck window "setDock" (host-window-dock-height window))
  (ck window "setDetached" t)
  (let ((pending (reverse (host-window-pending window))))
    (setf (host-window-pending window) '())
    (dolist (item pending)
      (move-into window item)))
  (note-window-emptied window))

(defun move-into (window item)
  "ITEM -- a document, or a panel's name -- into WINDOW: now when its
page is up, else once it is."
  (cond ((not (host-window-settled window))
         (push item (host-window-pending window)))
        ((typep item 'host-document)
         (move-document item window))
        (t
         (move-panel (host-window-editor window) item window))))

(defun move-document (doc window &key (activate t))
  "DOC's tab out of its window and into WINDOW, made there from the
mirror -- the text, the point, the modified flag, the colours -- and
activated.  Nothing when DOC is there already or closing.  ACTIVATE NIL
leaves the keyboard where it is: ATTACH-ALL moves several tabs at once
and activates the true focus only once, after all of them have moved,
so a moved tab's own activation never raises a window as a side effect
and steals focus from wherever it really belongs."
  (let ((old (hdoc-window doc)))
    (unless (or (eq old window) (doc-closing doc))
      (ck old "removeDoc" (hdoc-id doc))
      (when (and (host-active-p doc) (hdoc-mini-text doc))
        (ck old "closeMini"))
      ;; Moved before the old dock's mirror is told, which counts what
      ;; is in the window
      (setf (hdoc-window doc) window)
      (when (hdoc-dock-p doc)
        (dock-note-hidden old (hdoc-id doc)))
      (ck doc "makeDoc" (hdoc-id doc) (doc-name doc) (doc-kind-string doc))
      (ck doc "setTitle" (hdoc-id doc) (hdoc-title doc))
      ;; The new view is empty: what it shows is pushed from the mirror whole.
      (setf (hdoc-shown-text doc) ""
            (hdoc-shown-head doc) 0
            (hdoc-shown-anchor doc) 0
            (hdoc-shown-modified doc) nil)
      (sync-document doc)
      (setf (doc-paren-shown doc) nil)
      (colour-all doc)
      (show-paren doc)
      (when activate (doc-activate doc))
      (note-window-emptied old))))

(defun replay-panel (editor name window)
  "The panel NAME shown in WINDOW's dock from the state Lisp holds."
  (cond ((string= name "diagnostics")
         (ck window "showDiagnostics" (coerce (host-editor-diag-rows editor) 'vector) t)
         (when (host-editor-diag-selected editor)
           (ck window "selectDiagnostic" (host-editor-diag-selected editor))))
        ((string= name "debugger")
         (let ((dbg (editor-debugger-state editor)))
           (dbg-open-call window dbg)
           (ck window "dbgFrames" (coerce (debugger-frames dbg) 'vector))
           (when (debugger-frame dbg)
             (ck window "dbgSelectFrame" (debugger-frame dbg)))
           (ck window "dbgLocals" (coerce (debugger-locals dbg) 'vector))))
        ((string= name "inspector")
         (insp-open-call window (editor-inspector-state editor))))
  (dock-note-shown window name))

(defun move-panel (editor name window &key (activate t))
  "The open panel NAME out of the dock it is in and into WINDOW's,
replayed there and raised.  Nothing when it is there already.  ACTIVATE
NIL skips the raise: ATTACH-ALL moves several tabs at once and raises
the window only once, after all of them have moved."
  (let ((old (panel-window editor name)))
    (unless (or (eq old window) (not (panel-open-p editor name)))
      (ck old "panelHide" name)
      (set-panel-window editor name window)
      (dock-note-hidden old name)
      (replay-panel editor name window)
      (when activate (raise-window window))
      (note-window-emptied old))))

(defun host-detach (editor name)
  "The clamacsDetach binding: the document with the page id NAME, or the
panel NAME, shown in a window of its own.  Answers a message for a
script -- what happened, or why nothing did."
  (let ((doc (host-document-by-id editor name)))
    (cond (doc
           (move-into (open-window editor (doc-role doc)) doc)
           (format nil "~A detached" name))
          ((not (panel-name-p name))
           (format nil "no tab ~A" name))
          ((not (panel-open-p editor name))
           (format nil "the ~A panel is not open" name))
          (t
           (move-into (open-window editor (panel-role name)) name)
           (format nil "~A detached" name)))))

(defun host-attach (editor name)
  "The clamacsAttach binding: the document or the panel NAME back into
the main window's page."
  (let ((doc (host-document-by-id editor name))
        (main (host-editor-main editor)))
    (cond ((and doc (eq (hdoc-window doc) main))
           (format nil "~A is in the main window" name))
          (doc
           (move-document doc main)
           (format nil "~A attached" name))
          ((not (panel-name-p name))
           (format nil "no tab ~A" name))
          ((eq (panel-window editor name) main)
           (format nil "~A is in the main window" name))
          (t
           (move-panel editor name main)
           (format nil "~A attached" name)))))

(define-command clamacs-detach-window (doc arg)
  "Show this buffer in a window of its own."
  (declare (ignore arg))
  (doc-message doc (host-detach (doc-editor doc) (hdoc-id doc))))

(define-command clamacs-attach-window (doc arg)
  "Move this buffer back into the main window."
  (declare (ignore arg))
  (doc-message doc (host-attach (doc-editor doc) (hdoc-id doc))))

(defun attach-all (window)
  "WINDOW's close button: its documents back into the main window, the
document that had the keyboard keeping it, and its panels closed as
their own close buttons close them (HOST-PANEL-CLOSE: the debugger's
says the REPL is still parked).  Every tab moves quietly (ACTIVATE NIL):
a moved tab's own activation would raise main as a side effect whenever
the true focus is a third window, stealing it before the final
activation below puts it back.  So the true focus is activated, and the
right window raised, exactly once, after all tabs have moved."
  (let* ((editor (host-window-editor window))
         (main (host-editor-main editor))
         (active (active-document editor)))
    (dolist (doc (window-documents window))
      (move-document doc main :activate nil))
    (dolist (name (window-panels window))
      (host-panel-close editor name))
    (when (and active (not (doc-closing active)))
      (doc-activate active))))

(defun destroy-window (window)
  "WINDOW's webview instance and callbacks released; the window
forgotten.  The handles are cleared first, so a nested entry (GTK
drains its queue while destroying) sends it nothing; and the close hook
is taken off the native window first, because GTK's webview_destroy
closes the window with gtk_window_close, which asks delete-event -- a
hook still answering TRUE there keeps the window alive while webview
frees its engine, and the page's next message runs on freed memory
(the Linux gate's crash of 2026-09-27)."
  (let ((editor (host-window-editor window))
        (w (host-window-w window))
        (win (host-window-win window)))
    (setf (host-editor-windows editor) (remove window (host-editor-windows editor)))
    (dolist (entry (host-editor-panel-windows editor))
      (when (eq (cdr entry) window)
        (set-panel-window editor (car entry) (host-editor-main editor))))
    (setf (host-window-w window) nil
          (host-window-win window) nil)
    (when (and win (host-editor-shim editor))
      (shim editor "clamacs_host_on_close" :void '(:pointer :pointer :pointer)
            win (ffi:make-foreign-pointer 0) (ffi:make-foreign-pointer 0)))
    (when w
      (wv editor "webview_destroy" :int32 '(:pointer) w))
    (dolist (cb (host-window-callbacks window))
      (ffi:free-callback cb))
    (setf (host-window-callbacks window) '())))

(defun close-window (window)
  "A detached window on its way down: its documents back into the main
window and its panels closed when its close button asked (:ATTACH), then
the window itself."
  (when (eq (host-window-closing window) :attach)
    (attach-all window))
  (destroy-window window))

(defun windows-housekeeping (editor)
  "Between two turns: the windows whose page came up are settled (which
moves tabs, and may empty the window they came from), then the ones on
their way down are closed -- in this turn, whichever pass emptied them.
An :EMPTY mark is stale once something is routed back into the window
before this pass runs (a panel reopened, a document made there while its
window was still the active one) -- re-checked here rather than trusted,
or the window would be destroyed out from under what it is now showing."
  (dolist (window (copy-list (host-editor-windows editor)))
    (when (and (not (main-window-p window))
               (host-window-ready window)
               (not (host-window-settled window))
               (not (host-window-closing window)))
      (settle-window window)))
  (dolist (window (copy-list (host-editor-windows editor)))
    (when (and (not (main-window-p window)) (host-window-closing window))
      (if (and (eq (host-window-closing window) :empty)
               (or (window-documents window) (window-panels window)
                   (host-window-pending window)))
          (setf (host-window-closing window) nil)
          (close-window window)))))

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

(defun bind (window name function &key always)
  "Bind NAME in WINDOW's page to FUNCTION, called with the parsed JSON
arguments inside an entry; the promise is answered with true.  While a
native dialog runs its own loop the call is dropped: only the timer's
ticks can arrive then -- except a binding bound ALWAYS (clamacsReady,
which only notes that a page is up), called outside any entry."
  (let* ((editor (host-window-editor window))
         (cb (ffi:make-callback
              :void '(:pointer :pointer :pointer)
              (lambda (id req arg)
                (declare (ignore arg))
                (unless (and (host-editor-in-modal editor) (not always))
                  (let ((args (handler-case (json-parse (ffi:foreign-to-string req))
                                (error (e)
                                  (report-error editor e)
                                  :bad))))
                    (unless (eq args :bad)
                      (if always
                          (apply function args)
                          (with-entry (editor)
                            (apply function args))))))
                (js-return window (ffi:foreign-to-string id) "true")))))
    (push cb (host-window-callbacks window))
    (ffi:with-foreign-string (pname name)
      (wv editor "webview_bind" :int32 '(:pointer :pointer :pointer :pointer)
          (host-window-w window) pname cb (ffi:make-foreign-pointer 0)))))

(defun install-close-hook (window function)
  "The close button of WINDOW's native window asks FUNCTION instead of
closing it (the shim's hook); the loop closes the window when the
editor is done."
  (let ((editor (host-window-editor window))
        (cb (ffi:make-callback :void '(:pointer)
                               (lambda (arg)
                                 (declare (ignore arg))
                                 (funcall function)))))
    (push cb (host-window-callbacks window))
    (shim editor "clamacs_host_on_close" :void '(:pointer :pointer :pointer)
          (host-window-win window) cb (ffi:make-foreign-pointer 0))))

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

(defun install-bindings (window)
  "The bindings on WINDOW's page.  A document's id names the document
whichever page sends it; what is the page's own -- ready, the dock's
height, the report -- goes to the window."
  (let ((editor (host-window-editor window)))
    (bind window "clamacsReady"
          (lambda (user-agent &optional scheme) (host-ready window user-agent scheme))
          :always t)
    (bind window "clamacsLog" (lambda (text) (host-log editor text)))
    (bind window "clamacsKey"
          (lambda (doc-id key code ctrl alt meta shift target)
            (host-key editor doc-id key code ctrl alt meta shift target)))
    (bind window "clamacsUpdate"
          (lambda (doc-id changes head) (host-update editor doc-id changes head)))
    (bind window "clamacsCursor"
          (lambda (doc-id head anchor) (host-cursor editor doc-id head anchor)))
    (bind window "clamacsMiniInput" (lambda (text) (host-mini-input editor text)))
    (bind window "clamacsPickCompletion"
          (lambda (index accept) (host-pick-completion editor index accept)))
    (bind window "clamacsActivate"
          (lambda (doc-id)
            (let ((doc (host-document-by-id editor doc-id)))
              (when doc (doc-activate doc)))))
    (bind window "clamacsCloseTab"
          (lambda (doc-id)
            (let ((doc (host-document-by-id editor doc-id)))
              (when doc (close-document doc)))))
    ;; One timer serves the editor: the main window's page's.
    (bind window "clamacsTick"
          (if (main-window-p window) (lambda () (host-tick editor)) (lambda () nil)))
    ;; The menu bar (phase H4)
    (bind window "clamacsMenu" (lambda (index) (host-menu-pick editor index)))
    (bind window "clamacsDynamic"
          (lambda (which n)
            (let ((group (dynamic-group-named editor which)))
              (when group (host-dynamic-pick editor group n)))))
    ;; The dock and the panels (phase H3).  A row number the page sends for
    ;; "nothing selected" is JSON null: ROW-ARG makes it NIL.
    (bind window "clamacsDiagPick" (lambda (row) (host-diag-pick editor (row-arg row))))
    (bind window "clamacsDbgFrame" (lambda (n) (debug-frame-selected editor (row-arg n))))
    (bind window "clamacsDbgFrameOpen" (lambda (n) (debug-frame-clicked editor (row-arg n))))
    (bind window "clamacsDbgRestart" (lambda (n) (debug-restart-clicked editor (row-arg n))))
    (bind window "clamacsDbgEval" (lambda (text) (debug-eval-entered editor text)))
    (bind window "clamacsDbgButton" (lambda (which) (host-dbg-button editor which)))
    (bind window "clamacsInspPart" (lambda (n) (inspect-part-clicked editor (row-arg n))))
    (bind window "clamacsInspBack" (lambda () (inspect-back-clicked editor)))
    (bind window "clamacsPanelClose" (lambda (name) (host-panel-close editor name)))
    (bind window "clamacsDockShown" (lambda (name) (host-dock-shown editor name)))
    (bind window "clamacsDockResized" (lambda (height) (host-dock-resized window height)))
    (bind window "clamacsPanels" (lambda (json) (host-panels-report window json)))
    ;; Detached windows (phase H7)
    (bind window "clamacsDetach" (lambda (name) (host-detach editor name)))
    (bind window "clamacsAttach" (lambda (name) (host-attach editor name)))))

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
the windows settled or closed, the next injected key sent.  True when
the last document is gone."
  (reap editor)
  (when (editor-quitting editor)
    (quit-requested editor)
    (reap editor))
  (windows-housekeeping editor)
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
  "The libraries, the main window, its bindings, the page; returns once
the page has reported ready."
  (let ((webview (host-frontend-file (host-library-name "libwebview")))
        (shim (host-frontend-file (host-library-name "libclamacs-host")))
        (page (host-frontend-file "page.html"))
        (main (host-editor-main editor)))
    (dolist (file (list webview shim page))
      (unless (probe-file file)
        (error "Clamacs: ~A is missing -- run host/build.sh first (or point CLAMACS_HOST_FRONTEND at the directory that has it)." file)))
    (setf (host-editor-webview editor) (or (ffi:load-library webview)
                                           (error "Clamacs: ~A did not load." webview))
          (host-editor-shim editor) (or (ffi:load-library shim)
                                        (error "Clamacs: ~A did not load." shim))
          (host-editor-page-html editor) (read-page page))
    (let ((w (wv editor "webview_create" :pointer '(:int32 :pointer) 0 (ffi:make-foreign-pointer 0))))
      (when (ffi:null-pointer-p w)
        (error "Clamacs: webview_create failed."))
      (setf (host-window-w main) w))
    (wv-str main "webview_set_title" "Clamacs")
    (wv editor "webview_set_size" :int32 '(:pointer :int32 :int32 :int32)
        (host-window-w main) 1000 700 0)
    (setf (host-window-win main)
          (wv editor "webview_get_window" :pointer '(:pointer) (host-window-w main)))
    (place-window main "doc1")
    (install-bindings main)
    ;; The close button asks the editor: `save-buffers-kill-emacs', which
    ;; the loop carries out.
    (install-close-hook main (lambda () (setf (editor-quitting editor) t)))
    (wv-str main "webview_set_html" (host-editor-page-html editor))
    (let ((deadline (+ (get-internal-real-time) (* 20 internal-time-units-per-second))))
      (loop until (host-window-ready main)
            do (when (> (get-internal-real-time) deadline)
                 (error "Clamacs: the page did not report ready within 20 seconds."))
               (host-step editor +step-ms+)))))

(defun host-close (editor)
  "The windows -- the detached ones first, the main one last -- the
callbacks, the libraries: nothing OS-owned outlives START."
  (when (and (host-editor-shim editor) (host-editor-native-menu editor))
    (shim editor "clamacs_host_menu_clear" :void '())
    (setf (host-editor-native-menu editor) nil))
  (dolist (window (reverse (host-editor-windows editor)))
    (destroy-window window))
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
                    (send-theme editor)
                    (send-minimap editor)
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
command line.  The image's start (`clamiga --image clamacs.img --eval
\"(clamacs::run)\"') comes here too, so the user's paths are re-derived
first: the image holds the saving machine's."
  (refresh-user-paths)
  (load-init-file)
  (start :files (parse-command-line ext:*command-line-args*)))
