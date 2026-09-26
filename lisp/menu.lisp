;;;; menu.lisp -- the menu strip, as data, and the two Help items.
;;;;
;;;; The menu is the command table seen from the mouse: every item names a
;;;; command, so picking an item and typing `M-x <name>' are one path with
;;;; two entrances.  What is listed here is what a user who has never heard
;;;; of `C-x C-f' needs to find, plus the commands that have no key at all
;;;; (connect, run-lisp, compile-file, the arglist).  Cursor and word
;;;; motion, the kill commands and the like are left out on purpose: nobody
;;;; picks `forward-char' from a menu.
;;;;
;;;; Each item also carries the Emacs key it is bound to, shown in the
;;;; shortcut column, and an enable rule that says when the item is greyed
;;;; out.  The rule is evaluated against a plain struct of flags computed
;;;; from the editor (MENU-STATE), so the table, the rules and the port's
;;;; MENU verb are host-tested: tests/test-menu.lisp checks that every
;;;; command exists, that every key shown really runs that command through
;;;; the real keymaps, and that the rules answer as documented.
;;;;
;;;; The port of src/emacs/menudef.c and the Lisp half of src/menu.c and
;;;; src/url.c.  Pure: no MUI, no OS types.  frontend-mui.lisp turns the
;;;; table into Menu and Menuitem objects and keeps their enable state in
;;;; step with MENU-STATE after every command.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The table
;;; ------------------------------------------------------------------

(defstruct (menu-entry (:constructor make-menu-entry (kind rule command title keys map)))
  kind                      ; :title, :item, :bar, or :dynamic -- the place
                            ; a group of items made at run time goes: the
                            ; open buffers, the themes (DYNAMIC-MENU)
  rule                      ; when an item is enabled, see MENU-RULE-HOLDS-P
  command                   ; the command symbol, or NIL; for a :dynamic
                            ; entry the group's name (:buffers, :themes)
  title                     ; the label; the menu's name for a :title
  keys                      ; the key shown beside it, or NIL
  ;; Which map the key lives in: :global, :lisp or :repl.  Only the test
  ;; reads it; the shortcut column shows the key regardless.
  map)

(defparameter *menu-rules*
  '(:always
    :doc-changed            ; the active document has unsaved changes
    :doc-has-path           ; ... has a file behind it
    :connected              ; a clamiga port is known
    :not-connected
    :repl-window            ; the active document is the REPL window
    :debugging              ; clamiga's REPL thread is parked in the debugger
    :diagnostics            ; the error list is not empty
    :can-pop                ; `M-.' has been used: there is a place to go back to
    :self                   ; the wire talks to the editor's own Lisp
    :not-self))

;;; The order is the order on screen.  Project first, as on any Amiga; the
;;; key in the shortcut column is the one a user would learn next.
(defparameter *menu-table*
  (flet ((title (name) (make-menu-entry :title :always nil name nil nil))
         (bar () (make-menu-entry :bar :always nil nil nil nil))
         (item (command rule label keys map)
           (make-menu-entry :item rule command label keys map)))
    (list
     (title "Project")
     (item 'clamacs-new-buffer          :always        "New"                    nil       :global)
     (item 'find-file                   :always        "Open..."                "C-x C-f" :global)
     (item 'find-file-other-window      :always        "Open in New Window..."  "C-x 2"   :global)
     (item 'save-buffer                 :doc-changed   "Save"                   "C-x C-s" :global)
     (item 'write-file                  :always        "Save As..."             "C-x C-w" :global)
     (bar)
     (item 'switch-to-buffer            :always        "Next Buffer"            "C-x b"   :global)
     (item 'kill-buffer                 :always        "Close Buffer"           "C-x k"   :global)
     (bar)
     (item 'clamacs-about               :always        "About..."               nil       :global)
     (bar)
     (item 'save-buffers-kill-emacs     :always        "Quit"                   "C-x C-c" :global)

     (title "Edit")
     (item 'undo                        :always        "Undo"                   "C-/"     :global)
     (item 'redo                        :always        "Redo"                   "C-x r"   :global)
     (bar)
     (item 'kill-region                 :always        "Cut"                    "C-w"     :global)
     (item 'kill-ring-save              :always        "Copy"                   "M-w"     :global)
     (item 'yank                        :always        "Paste"                  "C-y"     :global)
     (item 'yank-pop                    :always        "Paste Previous"         "M-y"     :global)
     (item 'mark-whole-buffer           :always        "Select All"             "C-x h"   :global)
     (bar)
     (item 'isearch-forward             :always        "Search Forward..."      "C-s"     :global)
     (item 'isearch-backward            :always        "Search Backward..."     "C-r"     :global)
     (item 'goto-line                   :always        "Go to Line..."          "M-g g"   :global)
     (bar)
     (item 'execute-extended-command    :always        "Run Command..."         "M-x"     :global)

     (title "Lisp")
     (item 'indent-for-tab-command      :always        "Indent Line"            "TAB"     :lisp)
     (item 'indent-region               :always        "Indent Region"          "C-M-\\"  :lisp)
     (bar)
     (item 'beginning-of-defun          :always        "Beginning of Defun"     "C-M-a"   :lisp)
     (item 'end-of-defun                :always        "End of Defun"           "C-M-e"   :lisp)
     (bar)
     (item 'complete-symbol             :connected     "Complete Symbol"        "M-TAB"   :lisp)
     (item 'clamacs-arglist             :connected     "Show Arglist"           nil       :lisp)
     (item 'clamacs-describe-symbol     :connected     "Describe Symbol..."     "C-c C-d d" :lisp)
     (item 'clamacs-apropos             :connected     "Apropos..."             "C-c C-d a" :lisp)
     (bar)
     (item 'clamacs-edit-definition     :connected     "Edit Definition"        "M-."     :lisp)
     (item 'clamacs-pop-definition      :can-pop       "Back from Definition"   "M-,"     :lisp)
     (bar)
     (item 'clamacs-macroexpand-1       :connected     "Macroexpand Once"       "C-c RET" :lisp)
     (item 'clamacs-macroexpand         :connected     "Macroexpand All"        "C-c M-m" :lisp)

     (title "Clamiga")
     (item 'clamacs-connect             :always        "Connect"                nil       :global)
     (item 'run-lisp                    :not-connected "Start clamiga"          nil       :global)
     (bar)
     (item 'clamacs-connect-self        :not-self      "Talk to the Editor Itself" nil    :global)
     (item 'clamacs-connect-clamiga     :self          "Talk to clamiga"        nil       :global)
     (bar)
     (item 'clamacs-load-buffer         :connected     "Load Buffer"            "C-c C-k" :lisp)
     (item 'clamacs-load-file           :connected     "Load File..."           "C-c C-l" :lisp)
     (item 'clamacs-compile-file        :doc-has-path  "Compile File"           nil       :lisp)
     (bar)
     (item 'clamacs-eval-defun          :connected     "Eval Defun"             "C-c C-c" :lisp)
     (item 'clamacs-eval-last-sexp      :connected     "Eval Last Sexp"         "C-x C-e" :lisp)
     (item 'clamacs-eval-region         :connected     "Eval Region"            "C-c C-r" :lisp)
     (item 'clamacs-eval-expression     :connected     "Eval Expression..."     "C-c C-e" :lisp)
     (bar)
     (item 'clamacs-interrupt           :connected     "Interrupt"              "C-c C-b" :lisp)
     (bar)
     (item 'clamacs-show-errors         :always        "Show Errors"            "C-c ! l" :lisp)
     (item 'clamacs-next-error          :diagnostics   "Next Error"             "C-x `"   :lisp)
     (item 'clamacs-previous-error      :diagnostics   "Previous Error"         "C-x ~"   :lisp)

     (title "Windows")
     (item 'clamacs-repl                :connected     "REPL"                   "C-c C-z" :global)
     (item 'clamacs-inspect             :connected     "Inspect..."             "C-c I"   :lisp)
     (item 'clamacs-debugger            :debugging     "Debugger"               nil       :global)
     (item 'clamacs-room                :always        "Editor Memory"          nil       :global)
     (bar)
     (item 'clamacs-repl-clear          :repl-window   "Clear Transcript"       "C-c M-o" :repl)
     (item 'clamacs-repl-previous-input :repl-window   "Previous Input"         "M-p"     :repl)
     (item 'clamacs-repl-next-input     :repl-window   "Next Input"             "M-n"     :repl)
     (bar)
     (item 'other-window                :always        "Other Window"           "C-x o"   :global)
     (bar)
     (item 'clamacs-snapshot-windows    :always        "Snapshot Windows"       nil       :global)

     ;; One item per theme (theme.lisp), the one in effect ticked.
     (title "View")
     (make-menu-entry :dynamic :always :themes nil nil nil)

     ;; One item per open buffer, made and remade as windows come and go.
     (title "Buffers")
     (make-menu-entry :dynamic :always :buffers nil nil nil)

     (title "Help")
     (item 'clamacs-hyperspec           :always        "Common Lisp HyperSpec..." nil     :global))))

(defun menu-entries ()
  *menu-table*)

(defun menu-count ()
  (length *menu-table*))

(defun menu-entry (index)
  "The entry at INDEX, or NIL."
  (and (integerp index) (<= 0 index) (nth index *menu-table*)))

(defun menu-find (command)
  "The index of the item for COMMAND (a symbol or a command name), or
NIL."
  (let ((symbol (if (stringp command) (find-command command) command)))
    (and symbol
         (position-if (lambda (e)
                        (and (eq (menu-entry-kind e) :item)
                             (eq (menu-entry-command e) symbol)))
                      *menu-table*))))

(defun menu-entry-dynamic (entry)
  "The name of the dynamic group ENTRY stands for, or NIL for any other
kind of entry."
  (and (eq (menu-entry-kind entry) :dynamic) (menu-entry-command entry)))

(defun menu-find-dynamic (which)
  "The index of the dynamic group WHICH's entry, or NIL."
  (position which *menu-table* :key #'menu-entry-dynamic))

;;; ------------------------------------------------------------------
;;; The rules
;;; ------------------------------------------------------------------

(defstruct (menu-state (:constructor make-menu-state ()))
  (doc-changed nil) (doc-has-path nil) (connected nil) (repl-window nil)
  (debugging nil) (diagnostics nil) (can-pop nil) (self nil))

(defun menu-rule-holds-p (rule state)
  (ecase rule
    (:always t)
    (:doc-changed (menu-state-doc-changed state))
    (:doc-has-path (menu-state-doc-has-path state))
    (:connected (menu-state-connected state))
    (:not-connected (not (menu-state-connected state)))
    (:repl-window (menu-state-repl-window state))
    (:debugging (menu-state-debugging state))
    (:diagnostics (menu-state-diagnostics state))
    (:can-pop (menu-state-can-pop state))
    (:self (menu-state-self state))
    (:not-self (not (menu-state-self state)))))

(defun menu-state (editor)
  "The flags the rules are evaluated against, read off EDITOR now."
  (let ((state (make-menu-state))
        (doc (editor-active-document editor))
        (wire (editor-wire editor)))
    (when doc
      (setf (menu-state-doc-changed state) (and (doc-modified-p doc) t)
            (menu-state-doc-has-path state) (and (doc-path doc) t)
            (menu-state-repl-window state) (repl-mode-p doc)))
    (setf (menu-state-connected state) (and wire (wire-connected wire) t)
          (menu-state-diagnostics state) (and wire (> (diaglist-count (wire-diags wire)) 0))
          (menu-state-debugging state) (debugger-active-p editor)
          (menu-state-can-pop state) (> (locstack-depth (editor-locations editor)) 0)
          (menu-state-self state) (wire-self-p wire))
    state))

(defun menu-enabled-items (editor)
  "One boolean per table entry: whether it is enabled now (a title or a
bar counts as enabled).  What a frontend applies to its items after a
command, setting only the ones that changed."
  (let ((state (menu-state editor)))
    (mapcar (lambda (e) (menu-rule-holds-p (menu-entry-rule e) state))
            *menu-table*)))

(defun menu-item-enabled-p (editor index)
  (let ((e (menu-entry index)))
    (and e (eq (menu-entry-kind e) :item)
         (menu-rule-holds-p (menu-entry-rule e) (menu-state editor)))))

;;; ------------------------------------------------------------------
;;; Picking
;;; ------------------------------------------------------------------

(defun menu-pick (editor index)
  "Run the item at INDEX on the active document, as the mouse would.
True when it ran."
  (let ((e (menu-entry index))
        (doc (editor-active-document editor)))
    (and e (eq (menu-entry-kind e) :item) doc
         (progn (run-command doc (menu-entry-command e) 1) t))))

;;; MENU <command-name> [STATE]: the menu strip, from a macro.  Without
;;; STATE it picks the item that runs the command, the way the mouse would
;;; -- on the active document, and only when the item is enabled -- and
;;; answers "" (ran), "disabled" or "no such menu item".  With STATE it
;;; only reports "enabled" or "disabled".  What this tests is what a click
;;; cannot be made to: that the item exists, that its enable state follows
;;; the editor's, and that picking it runs the same command `EVAL' would.
;;; (MUI's own menu handling, from IDCMP_MENUPICK to
;;; MUIA_Application_MenuAction, is MUI's.)
(define-port-verb "MENU" (editor arg)
  (let* ((words (split-words arg))
         (state (and (rest words) (string-equal (car (last words)) "STATE")))
         (name (first words))
         (index (and name (menu-find name))))
    (cond ((null name)
           (values +rc-error+ "ERROR: MENU needs a command name"))
          ((null index)
           (values +rc-ok+ "no such menu item"))
          (state
           (values +rc-ok+ (if (menu-item-enabled-p editor index) "enabled" "disabled")))
          ((not (menu-item-enabled-p editor index))
           (values +rc-ok+ "disabled"))
          (t
           (menu-pick editor index)
           (values +rc-ok+ "")))))

;;; ------------------------------------------------------------------
;;; The Buffers menu
;;; ------------------------------------------------------------------

;;; Every open buffer, to switch to with the mouse: the source buffers
;;; first -- files and unnamed buffers, in the order they were opened --
;;; then a bar, then the tool buffers the editor makes for itself (the REPL,
;;; *clamacs-description*, *clamacs-apropos*, ...).  One document is one
;;; window, so picking a buffer activates its window, as `C-x o' would.
;;; A frontend remakes the menu's items whenever BUFFER-MENU answers
;;; something else than what it shows, and ticks the active document's.

(defun tool-document-p (doc)
  "A buffer the editor made for itself: no file behind it and a name in
stars, as Emacs spells its own (*clamacs-repl*)."
  (let ((name (doc-name doc)))
    (and (null (doc-path doc))
         (> (length name) 1)
         (char= (char name 0) #\*))))

(defun buffer-labels (docs)
  "The label of each of DOCS, in order.  A name that two buffers share
gets the file's directory when it has one (\"x.lisp  (Work:a/)\"), else
Emacs's `<2>', `<3>' ... from the second on."
  ;; A handful of buffers, asked after every input event: counted in the
  ;; list, no tables made.
  (let ((names (mapcar #'doc-name docs)))
    (loop for doc in docs
          for i from 0
          collect
              (let* ((name (doc-name doc))
                     (path (doc-path doc))
                     (n (1+ (count name names :end i :test #'string=))))
                (cond ((= (count name names :test #'string=) 1) name)
                      (path
                       (let ((dir (subseq path 0 (- (length path)
                                                    (length (path-basename path))))))
                         (if (string= dir "")
                             name
                             (format nil "~A  (~A)" name dir))))
                      ((= n 1) name)
                      (t (format nil "~A<~D>" name n)))))))

(defun buffer-menu (editor)
  "The Buffers menu as it should be now: a list of (LABEL . DOC) for each
open buffer and :BAR between the sources and the tools -- only when there
are both."
  (let* ((docs (live-documents editor))
         (sources (remove-if #'tool-document-p docs))
         (tools (remove-if-not #'tool-document-p docs))
         (all (append sources tools))
         (entries (mapcar #'cons (buffer-labels all) all)))
    (if (and sources tools)
        (append (subseq entries 0 (length sources))
                (list :bar)
                (nthcdr (length sources) entries))
        entries)))

(defun buffer-menu-pick (editor doc)
  "Switch to DOC's window, as its item in the Buffers menu does.  True
when DOC is still open."
  (when (and doc (member doc (live-documents editor)))
    (doc-activate doc)
    t))

;;; ------------------------------------------------------------------
;;; The dynamic groups: Buffers and View, one mechanism
;;; ------------------------------------------------------------------

;;; A dynamic group is a menu whose items are made at run time and
;;; remade when they no longer match: the open buffers, the themes.  Each
;;; is two functions of the editor -- the entries with the one to tick,
;;; and the pick -- and everything else (the sync a frontend runs after
;;; every command, the lines the port answers, the pick by label) is
;;; written once over the group's name.

(defun dynamic-menu (editor which)
  "The group WHICH as it should be now: a list of (LABEL . OBJECT) and
:BAR, and as second value the object whose item is ticked."
  (ecase which
    (:buffers (values (buffer-menu editor) (editor-active-document editor)))
    (:themes (values (theme-menu) (active-theme)))))

(defun dynamic-menu-pick (editor which object)
  "Pick OBJECT's item in the group WHICH as the mouse would: a buffer's
window is activated, a theme loaded (and remembered, as LOAD-THEME
does).  True when it was done."
  (ecase which
    (:buffers (buffer-menu-pick editor object))
    (:themes (and (find-theme object) (load-theme object) t))))

(defun dynamic-menu-equal (a b)
  "Whether the groups A and B show the same items for the same objects
-- what a frontend asks before remaking its items."
  (and (= (length a) (length b))
       (every (lambda (x y)
                (if (eq x :bar)
                    (eq y :bar)
                    (and (consp y) (eq (cdr x) (cdr y)) (string= (car x) (car y)))))
              a b)))

(defun dynamic-menu-lines (entries ticked)
  "ENTRIES, a group's list, as the port spells it: one string per item,
the label with `> ' before the ticked one and `  ' before the others,
and `-' for a bar."
  (mapcar (lambda (e)
            (cond ((eq e :bar) "-")
                  ((eq (cdr e) ticked) (format nil "> ~A" (car e)))
                  (t (format nil "  ~A" (car e)))))
          entries))

(defgeneric editor-dynamic-groups (editor)
  (:documentation "The dynamic groups the frontend makes items for.  A
title whose menu holds nothing but a group the frontend does not draw
is left out of its bar (MENU-ENTRY-DRAWN-P), so a frontend that has not
caught up with a group shows no empty menu.")
  (:method ((editor editor)) '(:buffers :themes)))

(defun menu-entry-drawn-p (editor index)
  "Whether the frontend draws the entry at INDEX: a dynamic group when
the frontend makes its items, a title when something under it is drawn,
everything else always."
  (let ((e (menu-entry index)))
    (case (menu-entry-kind e)
      (:dynamic (and (member (menu-entry-dynamic e) (editor-dynamic-groups editor)) t))
      (:title (loop for i from (1+ index) below (menu-count)
                    for next = (menu-entry i)
                    until (eq (menu-entry-kind next) :title)
                    thereis (menu-entry-drawn-p editor i)))
      (t t))))

(defun menu-wire-kind (editor index)
  "The kind of the entry at INDEX as a frontend's menu bar is told it:
:HIDDEN for an entry it does not draw, a dynamic group's own name, else
the kind.  Every entry keeps its line, so the indices stay the table's."
  (let ((e (menu-entry index)))
    (cond ((not (menu-entry-drawn-p editor index)) :hidden)
          ((eq (menu-entry-kind e) :dynamic) (menu-entry-dynamic e))
          (t (menu-entry-kind e)))))

(defgeneric editor-dynamic-menu-lines (editor which)
  (:documentation "The group WHICH as the frontend shows it, one string
per item as DYNAMIC-MENU-LINES spells them.  A frontend with real menu
items reads them back; this method says what they should be.")
  (:method ((editor editor) which)
    (multiple-value-bind (entries ticked) (dynamic-menu editor which)
      (dynamic-menu-lines entries ticked))))

(defgeneric editor-dynamic-menu-pick (editor which label)
  (:documentation "Pick the item LABEL of the group WHICH as the mouse
would.  True when there was one.  A frontend with real menu items goes
through the item it made.")
  (:method ((editor editor) which label)
    (let ((e (find-if (lambda (e) (and (consp e) (string= (car e) label)))
                      (dynamic-menu editor which))))
      (and e (dynamic-menu-pick editor which (cdr e))))))

(defun dynamic-menu-verb (editor which arg missing)
  "BUFFERS and THEMES: without an argument the group's lines; with one
a pick of the item with that label, answering \"\" or MISSING."
  (cond ((string= arg "")
         (values +rc-ok+ (format nil "~{~A~^~%~}" (editor-dynamic-menu-lines editor which))))
        ((editor-dynamic-menu-pick editor which arg)
         (values +rc-ok+ ""))
        (t (values +rc-ok+ missing))))

;;; BUFFERS [label]: the Buffers menu from a macro.
(define-port-verb "BUFFERS" (editor arg)
  (dynamic-menu-verb editor :buffers arg "no such buffer"))

;;; THEMES [label]: the View menu from a macro -- the twin of BUFFERS.
(define-port-verb "THEMES" (editor arg)
  (dynamic-menu-verb editor :themes arg "no such theme"))

;;; ------------------------------------------------------------------
;;; About
;;; ------------------------------------------------------------------

(defparameter *clamacs-version* "0.2 (Lisp)")

(defgeneric editor-toolkit-lines (editor)
  (:documentation "What the frontend runs on, one string per line, for the
About requester: the MUI and TextEditor.mcc versions.")
  (:method ((editor editor)) '()))

(defun about-text (editor)
  (let ((wire (editor-wire editor)))
    (format nil "clamacs ~A~%An Emacs-flavoured Common Lisp IDE for clamiga~%~%~{~A~%~}clamiga: ~A"
            *clamacs-version*
            (editor-toolkit-lines editor)
            (cond ((null wire) "not connected")
                  ((not (wire-connected wire)) "not connected")
                  ((wire-version wire))
                  (t (wire-port-name wire))))))

(define-command clamacs-about (doc arg)
  (declare (ignore arg))
  (doc-ask doc (about-text (doc-editor doc)) '(:ok)))

;;; ------------------------------------------------------------------
;;; The HyperSpec
;;; ------------------------------------------------------------------

(defparameter *hyperspec-url* "https://www.lispworks.com/documentation/HyperSpec/Front/"
  "Where `clamacs-hyperspec' (Help > Common Lisp HyperSpec) goes.")

(defgeneric doc-open-url (doc url)
  (:documentation "Hand URL to the user's browser: :OPENED when one took
it, :REFUSED when the mechanism is there but no browser took it, :MISSING
when there is no way to reach a browser at all (no openurl.library)."))

(defun open-url (doc url)
  "URL into the browser, the outcome in the echo area.  Without a way to
reach a browser the URL is put in a requester, where the user can at
least read it off -- a beep and an echo-area message would hide the one
thing they came for."
  (ecase (doc-open-url doc url)
    (:opened
     (message doc "Opened ~A" url)
     t)
    (:refused
     (message doc "No browser took ~A (check the OpenURL prefs)" url)
     (doc-beep doc)
     nil)
    (:missing
     (doc-ask doc
              (format nil "openurl.library is not installed, so no browser~%can be asked to open~%~%~A~%~%Install the OpenURL package, or type the address~%into your browser."
                      url)
              '(:ok))
     (doc-message doc "openurl.library not found")
     nil)))

(define-command clamacs-hyperspec (doc arg)
  (declare (ignore arg))
  (open-url doc *hyperspec-url*))
