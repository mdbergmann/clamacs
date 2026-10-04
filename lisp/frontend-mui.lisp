;;;; frontend-mui.lisp -- the frontend protocol over MUI and TextEditor.mcc.
;;;;
;;;; The one file that names AMIGA.MUI.  It is the Lisp form of the C
;;;; editor's src/textclass.c and the MUI half of src/document.c, and every
;;;; "Phase 1 fact" in CLAUDE.md is a line here:
;;;;
;;;;   - ClamacsText is a private subclass of the INSTALLED TextEditor.mcc
;;;;     (CREATE-CUSTOM-CLASS at runtime), and it exists to see keys before
;;;;     the class does.  A bare MUIM_HandleEvent override on such a
;;;;     subclass is never called -- MUI coerces input to the class named in
;;;;     the handler node, and the class registers its own -- so the
;;;;     subclass adds its OWN RAWKEY node at priority 1 in MUIM_Setup,
;;;;     naming itself.  The Emacs layer runs first and returns 0 for a key
;;;;     it does not take, and the class's node edits.
;;;;   - ClamacsMini subclasses String for the minibuffer: TAB, C-g and the
;;;;     history keys are taken through a MUIA_String_EditHook, because an
;;;;     active MUI 3.8 String edits its keys before the window's handler
;;;;     list is consulted -- and it edits them on input.device's task,
;;;;     where no Lisp can run (a Lisp hook there is answered 0 by the
;;;;     runtime, unseen: the Vampire's finding B, 2026-09-18).  So the
;;;;     hook is the runtime's native one, MUI:MAKE-STRING-KEY-HOOK, given
;;;;     a table of raw keys built here from the keymap; it pushes a taken
;;;;     key to the mini object as CKM_MiniKey, which arrives on the
;;;;     application's task.  MUI 4 never calls that hook and sends the
;;;;     keys through MUIM_HandleEvent twice instead.  Both paths are here.
;;;;   - MUI hands a RAWKEY to every registered node: each class acts only
;;;;     when it is the window's active object.
;;;;   - RET, TAB and ESC are also MUI's window keys; each class switches
;;;;     them off in GoActive and again in Show, since the class's Hide
;;;;     zeroes the set on every relayout.
;;;;   - Export with the NoStyle hook; SetBlock marks the text changed, so
;;;;     HasChanged is saved around everything that only paints.
;;;;   - A window is never disposed from inside its own notification: the
;;;;     document is retired and the event loop reaps it.
;;;;
;;;; Per-object state lives in Lisp: the document is found from the object
;;;; through a hash table keyed by the object's address, and the few bytes
;;;; MUI must own (the handler node, the pen map, the edit hook pointer) sit
;;;; in the class's instance data.  Strings MUI keeps a pointer to (titles,
;;;; the status line, the echo line) live in per-document foreign buffers,
;;;; never in the tag list's pool copies, which would leak one per update.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require "amiga/mui")
  (require "amiga/exec")
  (require "amiga/raw/exec")
  (require "amiga/raw/dos")
  (require "amiga/raw/intuition")
  (require "amiga/raw/graphics")
  (require "amiga/raw/keymap")
  (require "amiga/raw/asl")
  (require "amiga/raw/diskfont")
  (require "amiga/raw/muimaster")
  (require "amiga/iff")
  (dolist (nick '(("MUI" "AMIGA.MUI") ("M" "AMIGA.RAW.MUIMASTER")
                  ("EXEC" "AMIGA.RAW.EXEC") ("DOS" "AMIGA.RAW.DOS")
                  ("INTUI" "AMIGA.RAW.INTUITION") ("GFX" "AMIGA.RAW.GRAPHICS")
                  ("KEYMAP" "AMIGA.RAW.KEYMAP") ("ASL" "AMIGA.RAW.ASL")
                  ("DISKFONT" "AMIGA.RAW.DISKFONT")))
    (clamiga::add-package-local-nickname (first nick) (second nick) :clamacs)))

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Constants: TextEditor.mcc (mui/TextEditor_mcc.h) and the structs read
;;; by hand
;;; ------------------------------------------------------------------

(defconstant +te-base+ #xad000000)
(defconstant +tea-contents+          (+ +te-base+ #x02))
(defconstant +tea-cursor-x+          (+ +te-base+ #x04))
(defconstant +tea-cursor-y+          (+ +te-base+ #x05))
(defconstant +tea-export-hook+       (+ +te-base+ #x08))
(defconstant +tea-fixed-font+        (+ +te-base+ #x0a))
(defconstant +tea-has-changed+       (+ +te-base+ #x0c))
(defconstant +tea-import-hook+       (+ +te-base+ #x0e))
(defconstant +tea-prop-entries+      (+ +te-base+ #x15))
(defconstant +tea-quiet+             (+ +te-base+ #x17))
(defconstant +tea-slider+            (+ +te-base+ #x1a))
(defconstant +tea-color-map+         (+ +te-base+ #x2f))
(defconstant +tea-undo-levels+       (+ +te-base+ #x38))
(defconstant +tea-wrap-mode+         (+ +te-base+ #x39))
(defconstant +tea-cursor-index+      (+ +te-base+ #x42))
(defconstant +tea-horizontal-slider+ (+ +te-base+ #x46))
(defconstant +tea-contents-changed+  (+ +te-base+ #x4b))
(defconstant +tem-arexx-cmd+         (+ +te-base+ #x23))
(defconstant +tem-export-text+       (+ +te-base+ #x25))
(defconstant +tem-insert-text+       (+ +te-base+ #x26))
(defconstant +tem-search+            (+ +te-base+ #x2b))
(defconstant +tem-mark-text+         (+ +te-base+ #x2c))
(defconstant +tem-set-block+         (+ +te-base+ #x2e))
(defconstant +tem-block-info+        (+ +te-base+ #x30))
(defconstant +tem-export-block+      (+ +te-base+ #x37))
(defconstant +tem-cursor-xy-to-index+ (+ +te-base+ #x43))
(defconstant +tem-index-to-cursor-xy+ (+ +te-base+ #x44))
(defconstant +tev-export-hook-nostyle+ 2)
(defconstant +tev-import-hook-plain+ 0)
(defconstant +tev-insert-text-cursor+ 0)
(defconstant +tev-wrap-mode-nowrap+ 0)
(defconstant +tef-search-next+ 2)
(defconstant +tef-search-backwards+ 16)
(defconstant +tef-export-block-full-lines+ 1)
(defconstant +tef-export-block-take-block+ 2)
(defconstant +tef-set-block-color+ 1)
;;; The class's prefs items (mcp/TextEditor_mcp.h) it asks its object for
;;; with MUIM_GetConfigItem at Setup: the cursor's pen spec and the
;;; marked block's, which the theme answers (TEXT-GET-CONFIG-ITEM).
(defconstant +tecfg-cursor-color+ #xad000054)
(defconstant +tecfg-marked-color+ #xad00005a)
;; struct MUIP_GetConfigItem { ULONG MethodID; ULONG id; IPTR *storage; }
(defconstant +gci-id-offset+ 4)
(defconstant +gci-storage-offset+ 8)

;;; The oldest TextEditor.mcc the editor works with: SetBlock arrived in
;;; 15.29 (vendor/texteditor/ChangeLog); the horizontal slider in 15.48.
(defconstant +te-min-version+ 15)
(defconstant +te-min-revision+ 29)

;;; The editor's private methods, the C editor's (TAG_USER | 0x0C1A000n):
;;; CKM_IdleTick, fired on the text object by its own MUI timer input
;;; handler every 3/10 s for the arglist in the status line; CKM_MiniKey,
;;; a minibuffer key the edit hook took, delivered later through
;;; MUIM_Application_PushMethod.
(defconstant +ckm-idle-tick+ #x8c1a0002)
(defconstant +ckm-mini-key+ #x8c1a0003)
;;; struct MUI_InputHandlerNode (libraries/mui.h), 24 bytes: ihn_Object at
;;; 8, ihn_Millis (UWORD) at 12, ihn_Flags at 16, ihn_Method at 20.
(defconstant +ihn-size+ 24)
(defconstant +ihn-object-offset+ 8)
(defconstant +ihn-millis-offset+ 12)
(defconstant +ihn-flags-offset+ 16)
(defconstant +ihn-method-offset+ 20)
;;; MUIIHNF_TIMER alone, ihn_Millis in milliseconds: 300 ms.  Never the
;;; SCALE10 / SCALE100 flags of the newer header: MUI 3.8 (muimaster 19)
;;; predates them and reads the field as milliseconds regardless, so "3
;;; units of 100 ms" was a 3 ms timer there -- 38 ticks a second on the
;;; 68040 (2026-09-30, measured by run-cpu-idle.sh), each running the
;;; arglist check and a menu update, and the editor took the CPU while
;;; nobody typed.  Plain milliseconds mean the same on every MUI.
;;;
;;; 150 ms since 2026-10-01: the tick is also what repaints after the
;;; keys (REDISPLAY), once one tick passed without any, so it decides how
;;; long the colours trail the typing -- and the timer is up only while
;;; there is something to do (ARM-IDLE-TIMER), never in a resting editor.
(defconstant +idle-tick-millis+ 150)

;;; Rest ticks after which a timer with nothing left but an arglist that
;;; cannot be asked (no port, a reply that does not come) is taken down:
;;; three seconds.  The next key or reply puts it up again.
(defconstant +idle-give-up-ticks+ 20)

;;; Ticks in a row that saw the keys still coming after which the display
;;; is brought in step anyway: someone who types without a pause sees the
;;; colours and the status line follow about once a second.
(defconstant +busy-redisplay-ticks+ 6)

;; struct MUIP_HandleEvent { ULONG MethodID; struct IntuiMessage *imsg; LONG muikey; }
(defconstant +hev-imsg-offset+ 4)
;; struct IntuiMessage (intuition/intuition.h)
(defconstant +imsg-class-offset+ 20)
(defconstant +imsg-code-offset+ 24)
(defconstant +imsg-qualifier-offset+ 26)
(defconstant +imsg-iaddress-offset+ 28)
(defconstant +imsg-seconds-offset+ 36)
(defconstant +imsg-micros-offset+ 40)
(defconstant +idcmp-rawkey+ #x400)
;; struct MUI_EventHandlerNode (libraries/mui.h), 24 bytes
(defconstant +ehn-size+ 24)
(defconstant +ehn-priority-offset+ 9)
(defconstant +ehn-flags-offset+ 10)
(defconstant +ehn-object-offset+ 12)
(defconstant +ehn-class-offset+ 16)
(defconstant +ehn-events-offset+ 20)
;; struct InputEvent (devices/inputevent.h), 22 bytes
(defconstant +ie-size+ 22)
(defconstant +ie-class-offset+ 4)
(defconstant +ie-code-offset+ 6)
(defconstant +ie-qualifier-offset+ 8)
(defconstant +ie-eventaddress-offset+ 10)
(defconstant +ieclass-rawkey+ 1)
;; struct MUI_RenderInfo: mri_WindowObject first; mri_Screen at 4
(defconstant +mri-window-object-offset+ 0)
(defconstant +mri-screen-offset+ 4)
;; struct Screen.ViewPort (44) .ColorMap (4)
(defconstant +screen-colormap-offset+ 48)
;; struct TextFont.tf_XSize, .tf_YSize, and the font's name
;; (tf_Message.mn_Node.ln_Name)
(defconstant +tf-xsize-offset+ 24)
(defconstant +tf-ysize-offset+ 20)
(defconstant +tf-name-offset+ 10)
;; struct TextAttr (graphics/text.h): ta_Name, ta_YSize, ta_Style, ta_Flags
(defconstant +text-attr-size+ 8)
(defconstant +font-name-size+ 64)
;; struct FileRequester (libraries/asl.h)
(defconstant +fr-file-offset+ 4)
(defconstant +fr-drawer-offset+ 8)

;; struct Screen.RastPort (84) .BitMap (4): the screen's bitmap, whose
;; depth decides the shallow-screen rule (THEME-TEXT-PENS-P)
(defconstant +screen-rastport-bitmap-offset+ 88)

;;; Instance data of ClamacsText: the handler node, the eight pens
;;; (MUIA_TextEditor_ColorMap points here), two flags, the idle timer's
;;; input handler node and its flag, and whether the theme's background
;;; was set on this object (a switch to a theme without one puts the
;;; standard text background back in its place).
(defconstant +text-data-size+ 96)
(defconstant +text-ehn-offset+ 0)
(defconstant +text-cmap-offset+ 24)
(defconstant +text-pens-held-offset+ 56)
(defconstant +text-eh-added-offset+ 60)
(defconstant +text-ihn-offset+ 64)
(defconstant +text-timer-added-offset+ 88)
(defconstant +text-own-bg-offset+ 92)
;;; Instance data of ClamacsMini: the handler node and the event
;;; MUIM_HandleEvent last saw.  The edit hook itself is a Lisp object
;;; (MUI-EDITOR-MINI-HOOKS), not an address here: FREE-STRING-KEY-HOOK
;;; takes the object MAKE-STRING-KEY-HOOK returned, and a pointer rebuilt
;;; from an address is not a live hook (finding A of the 2026-09-18
;;; Vampire run).
(defconstant +mini-data-size+ 44)
(defconstant +mini-ehn-offset+ 0)
(defconstant +mini-eh-added-offset+ 24)
(defconstant +mini-seen-imsg-offset+ 28)
(defconstant +mini-seen-code-offset+ 32)
(defconstant +mini-seen-seconds-offset+ 36)
(defconstant +mini-seen-micros-offset+ 40)

;;; The raw keys the minibuffer's String hands over (MAKE-STRING-KEY-HOOK):
;;; every raw code with each of these qualifier sets is decoded through
;;; the keymap once, and the ones that give a key the minibuffer binds in
;;; some state, or Meta plus a character, go into the table.  The mask is
;;; Shift, Control, Alt and the two Amiga keys (the right-hand Shift and
;;; Alt are folded into the left before it applies): a press with an
;;; Amiga key never matches, as RAWKEY-DECODE never decodes one.
(defconstant +mini-hook-qual-mask+ #xD9)
(defparameter *mini-hook-qualifiers* '(#x00 #x01 #x08 #x09 #x10 #x11)
  "None, Shift, Control, Control-Shift, Alt, Alt-Shift.")

;;; The window keys switched off while the text has the focus: RET must
;;; not fire a default gadget, TAB not cycle, ESC neither deactivate nor
;;; close.  The minibuffer keeps TAB for completion, and ESC as well:
;;; ESC is both GADGET_OFF and WINDOW_CLOSE to MUI, and with only
;;; GADGET_NEXT off (as the C editor had it) one ESC at a prompt first
;;; deactivated the String and then, the mini's GoInactive having
;;; re-enabled every key, reached the window as WINDOW_CLOSE -- which
;;; with one document open was the editor's exit.  The mini keeps RET:
;;; that is how the String accepts the input.
(defparameter *text-window-keys*
  (logior m:+muikeyf-press+ m:+muikeyf-gadget-next+ m:+muikeyf-gadget-prev+
          m:+muikeyf-gadget-off+ m:+muikeyf-window-close+))
(defparameter *mini-window-keys*
  (logior m:+muikeyf-gadget-next+ m:+muikeyf-gadget-off+
          m:+muikeyf-window-close+))

;;; Eight pens for MUIA_TextEditor_ColorMap, the theme's (THEME-PENS in
;;; theme.lisp gives them in this order: the text colour, a free white,
;;; the paren match, comment, keyword, string, defining, number).  A
;;; SetBlock colour value of N means pen N-1 of the table, 0 the class's
;;; own text pen; the token kinds map onto them below.
(defconstant +pen-count+ 8)

(defun colour-value (colour text-pen-p)
  "The SetBlock colour value of COLOUR, a token kind or NIL for plain
text.  Every recolour clears the line with the plain value before it
paints the tokens, so with TEXT-PEN-P -- the theme's text colour in slot
1 (THEME-TEXT-PENS-P) -- plain text is painted in the theme's foreground
at the same cost; without it the class's own text pen stays."
  (case colour
    (:comment 4) ((:string :char) 6) (:keyword 5) (:number 8) (:defining 7)
    (:paren-match 3)
    (t (if text-pen-p 1 0))))

;;; ------------------------------------------------------------------
;;; Small foreign helpers
;;; ------------------------------------------------------------------

(defconstant +string-buffer-size+ 256)
(defconstant +wide-buffer-size+ 512)   ; a condition line, an inspected object

(defun store-text (buffer size string)
  "Copy STRING into BUFFER, a foreign block of SIZE bytes, cut to fit and
NUL-terminated.  Characters above 255 become `?'."
  (let ((n (min (length string) (1- size))))
    (dotimes (i n)
      (let ((code (char-code (char string i))))
        (ffi:poke-u8 buffer (if (< code 256) code 63) i)))
    (ffi:poke-u8 buffer 0 n)
    buffer))

(defun store-string (buffer string)
  "STORE-TEXT into a +STRING-BUFFER-SIZE+ block."
  (store-text buffer +string-buffer-size+ string))

(defun take-foreign-string (address)
  "A string the class AllocVec'd for us (ExportText, ExportBlock): its
contents as a Lisp string, the block freed.  \"\" for NULL."
  (if (zerop address)
      ""
      (let ((fp (ffi:make-foreign-pointer address)))
        (unwind-protect (ffi:foreign-to-string fp)
          (exec:free-vec fp)))))

(defun object-address (object)
  (ffi:foreign-pointer-address object))

(defun window-object (object)
  "_win(obj): the window object OBJECT sits in, or NIL before Setup."
  (let ((ri (mui:area-render-info object)))
    (and ri (not (ffi:null-pointer-p ri))
         (let ((addr (ffi:peek-u32 ri +mri-window-object-offset+)))
           (and (/= addr 0) (ffi:make-foreign-pointer addr))))))

(defun screen-colormap (object)
  (let ((ri (mui:area-render-info object)))
    (ffi:make-foreign-pointer
     (ffi:peek-u32 (ffi:make-foreign-pointer (ffi:peek-u32 ri +mri-screen-offset+))
                   +screen-colormap-offset+))))

(defun active-object-p (object)
  "Whether OBJECT is its window's active object.  MUI delivers a RAWKEY to
every registered handler regardless of focus, so each class checks before
acting, exactly as TextEditor.mcc does before its own self-insert."
  (let ((win (window-object object)))
    (and win
         (eql (mui:get-attr m:+muia-window-active-object+ win)
              (object-address object)))))

(defun set-window-keys (object keys)
  (let ((win (window-object object)))
    (when win
      (mui:set-attrs win m:+muia-window-disable-keys+ keys))))

;;; ------------------------------------------------------------------
;;; The editor and its documents
;;; ------------------------------------------------------------------

(defstruct (mui-editor (:include editor)
                       (:constructor %make-mui-editor ()))
  app
  ;; object address -> document, for the dispatchers and the hooks
  (objects (make-hash-table))
  textclass miniclass
  (te-version 0) (te-revision 0)
  ;; scratch for MapRawKey: a struct InputEvent and its output buffer
  ie mapbuf
  ;; the MUIM_CallHook hooks, one per notification kind
  hooks
  ;; mini object address -> the MUIA_String_EditHook MAKE-STRING-KEY-HOOK
  ;; returned for it, kept as the object so OM_DISPOSE can free it; and
  ;; the key table every such hook is made from, built once
  (mini-hooks (make-hash-table))
  (mini-hook-entries nil)
  ;; the document the port and the messages mean, and the activation
  ;; request that outranks late activation reports (see ACTIVATE-HOOK)
  active-doc activate-pending (activate-stamp 0)
  ;; the return ID that wakes the loop to reap closed windows
  (reap-id 1)
  ;; The mailbox (mailbox.lisp, EDITOR-MAILBOX) is woken by an Exec
  ;; signal: the task and the signal bit the loop waits on beside MUI's own.
  task (signal-bit -1) (signal-mask 0)
  ;; The diagnostics window, made on first use, and its list
  errors-window errors-list
  ;; Set while EDITOR-SELECT-DIAGNOSTIC moves the list's cursor, so the
  ;; selection hook does not jump a second time
  (selecting nil)
  ;; The debugger window (debugger.lisp), made on first use: its objects
  ;; and the strings MUI keeps pointers to; DBG-SELECTING as SELECTING
  dbg-window dbg-condition-obj dbg-restarts dbg-frames dbg-locals
  dbg-evalstr dbg-continue-btn dbg-title-buf dbg-condition-buf
  (dbg-selecting nil)
  ;; The inspector window (inspector.lisp), made on first use
  insp-window insp-object-obj insp-parts insp-back-btn
  insp-title-buf insp-object-buf
  ;; The menu strip (menu.lisp): the Menuitem object of each table entry
  ;; (NIL for a title or a bar) and the enable state last set on it, so
  ;; MENU-UPDATE touches only what changed.  NIL when no strip was built.
  menustrip menu-items menu-enabled
  ;; The dynamic groups (menu.lisp's DYNAMIC-MENU: the Buffers menu, the
  ;; View menu's themes), one DYN-GROUP each, in the table's order
  (dyn-groups '())
  ;; The theme (theme.lisp) as this frontend paints it: the theme
  ;; EDITOR-APPLY-THEME was last handed (NIL: ACTIVE-THEME), the depth of
  ;; the screen the first text object was set up on (NIL before that),
  ;; and what the two decide (THEME-PLAN): the eight pens, whether plain
  ;; text is painted with the theme's text pen, the background spec in a
  ;; foreign buffer MUI reads (NIL when the class keeps its own), the
  ;; cursor's and the selection's pen specs the same way (NIL: the user's
  ;; prefs), and the message the shallow-screen rule owes the user, shown
  ;; once.
  theme screen-depth (theme-rgb '()) (text-pen-p nil) bg-buf (bg-spec nil)
  cursor-buf (cursor-spec nil) marked-buf (marked-spec nil)
  (theme-note nil) (shallow-noted nil)
  ;; Set when the windows must be repainted for the theme (THEME-REPAINT,
  ;; from the event loop)
  (theme-dirty nil)
  ;; Counted up by everything that ran editor code -- a command, a hook,
  ;; a port verb.  What follows such a wake but is not the edit itself --
  ;; the colours, the paren highlight, the status line, the menus -- is
  ;; held back until the keys rest (REDISPLAY): SHOWN-ACTIVITY is the
  ;; count the display was last brought in step with, TICK-ACTIVITY the
  ;; count the idle timer's last tick saw and REST-TICKS the ticks since
  ;; that passed without any.  The timer is up only while there is such
  ;; work: on TIMER-DOC's text object, and TIMER-IDLE once a tick found
  ;; nothing left, for the loop to take it down (never the tick itself:
  ;; MUI is walking its handlers then).
  (activity 0 :type fixnum) (shown-activity -1 :type fixnum)
  (tick-activity -1 :type fixnum) (rest-ticks 0 :type fixnum)
  (busy-ticks 0 :type fixnum)
  (timer-doc nil) (timer-idle nil)
  ;; The text size (theme.lisp's FONT-SIZE): MUI's fixed font as the first
  ;; text object's Setup found it -- its name and its height, what the
  ;; setting sizes and what NIL goes back to -- the TextFont this frontend
  ;; opened at the setting's size (NIL: MUI's own), the size it is, the
  ;; TextAttr and name buffers it was opened with, and whether the
  ;; windows must be reopened for a changed size (THEME-REPAINT)
  (font-name nil) (font-default-size nil) font (font-size nil)
  font-attr font-name-buf (font-dirty nil))

;;; One dynamic group of the menu strip: the Menu object under its title,
;;; the Menuitem of each entry shown with the foreign title it points to
;;; (NIL for a bar's), the entries shown, a vector of their objects (a
;;; document, a theme) by item id, and the object whose item is ticked
;;; (:UNKNOWN once Intuition may have ticked one itself).  Its items carry
;;; ids of their own above the table's: +DYNAMIC-ITEM-ID-BASE+ times the
;;; group's number (from 1) plus the position.
(defstruct (dyn-group (:constructor make-dyn-group (which number)))
  which number menu (items '()) (shown '()) (objects #()) (checked :unknown))

(defconstant +dynamic-item-id-base+ #x10000)

(defun dyn-group (editor which)
  (find which (mui-editor-dyn-groups editor) :key #'dyn-group-which))

(defun dyn-group-item-id (group n)
  (+ (* +dynamic-item-id-base+ (dyn-group-number group)) n))

(defun dyn-group-of-id (editor id)
  "The group an item id above the table's belongs to, and the position in
it, two values; NIL for a table item's id."
  (and (>= id +dynamic-item-id-base+)
       (let ((group (find (floor id +dynamic-item-id-base+) (mui-editor-dyn-groups editor)
                          :key #'dyn-group-number)))
         (and group (values group (mod id +dynamic-item-id-base+))))))

;;; *EDITOR*, the running editor, is frontend.lisp's: START sets it.

(defvar *wire-starter* nil
  "Function of the editor that sets up the wire to clamiga and the editor's
own port, called by START once the first windows are open -- so the port
never answers before there is a document.  transport-arexx.lisp sets it;
without it the editor runs alone.")

(defvar *wire-stopper* nil
  "Its counterpart at exit, called before the windows go.")

(defvar *after-start-hooks* '()
  "Functions of the editor, called once its first windows are open and
before the event loop runs: the harness writes its ready marker here, the
init file may open what it likes.")

(defclass mui-document (document)
  ((window :initform nil :accessor mdoc-window)
   (text :initform nil :accessor mdoc-text)
   (slider :initform nil :accessor mdoc-slider)
   (hslider :initform nil :accessor mdoc-hslider)
   (status :initform nil :accessor mdoc-status)
   (echo :initform nil :accessor mdoc-echo)         ; the page group
   (msgline :initform nil :accessor mdoc-msgline)
   (miniline :initform nil :accessor mdoc-miniline)
   (prompt :initform nil :accessor mdoc-prompt)     ; the label beside the input
   (mini :initform nil :accessor mdoc-mini)
   ;; The strings MUI holds pointers to
   (title-buf :initform nil :accessor mdoc-title-buf)
   (status-buf :initform nil :accessor mdoc-status-buf)
   (message-buf :initform nil :accessor mdoc-message-buf)
   (label-buf :initform nil :accessor mdoc-label-buf)
   ;; What the echo area shows and what the prompt label says, for the
   ;; port's STATUS and to skip a relayout when the label is unchanged
   (message-text :initform "" :accessor mdoc-message-text)
   (label-text :initform "" :accessor mdoc-label-text)
   ;; The package the status line shows; the wire (phase 2) tracks it
   (package :initform "CL-USER" :accessor mdoc-package)
   ;; The arglist of the operator at point, at the end of the status line
   (arglist :initform "" :accessor mdoc-arglist)
   ;; The class's marked block is the region, put there by SHOW-REGION
   (region-shown :initform nil :accessor mdoc-region-shown)
   ;; What the notifications left for REDISPLAY: the lines changed (NIL:
   ;; none) and whether the cursor moved or the status line is stale
   (dirty-y0 :initform nil :accessor mdoc-dirty-y0)
   (dirty-y1 :initform nil :accessor mdoc-dirty-y1)
   (cursor-dirty :initform nil :accessor mdoc-cursor-dirty)
   ;; Set while WITH-CHANGED-FLAG holds the class's changed flag
   (flag-held :initform nil :accessor mdoc-flag-held)))

(defun object-document (editor object)
  (gethash (object-address object) (mui-editor-objects editor)))

(defun address-document (editor address)
  (gethash address (mui-editor-objects editor)))

;;; ------------------------------------------------------------------
;;; The mailbox: only the MUI task touches MUI
;;; ------------------------------------------------------------------
;;;
;;; The port's handler thread and the client thread never call a method;
;;; they post a closure to the editor's mailbox (mailbox.lisp,
;;; CALL-IN-EDITOR), which raises the editor's signal, and the event loop
;;; runs it between two MUI inputs.  Exec signals are sticky, so a post
;;; while the loop is busy is picked up on its next wait.

(defun setup-mailbox (editor)
  (let ((bit (exec:alloc-signal -1)))
    (when (< bit 0)
      (error "Clamacs: no free signal bit for the editor's mailbox."))
    (let ((task (exec:find-task nil))
          (mask (ash 1 bit)))
      (setf (mui-editor-task editor) task
            (mui-editor-signal-bit editor) bit
            (mui-editor-signal-mask editor) mask
            (editor-mailbox editor)
            (make-mailbox :wake (lambda () (exec:signal task mask))
                          :on-error (lambda (e) (report-error editor e))
                          ;; A reply from clamiga or a port verb moved the
                          ;; state the menu shows (a port found, an error
                          ;; list filled, a DEBUGGER message).
                          :after-drain (lambda ()
                                         (incf (mui-editor-activity editor))))))))

(defun free-mailbox (editor)
  (when (>= (mui-editor-signal-bit editor) 0)
    (exec:free-signal (mui-editor-signal-bit editor))
    (setf (mui-editor-signal-bit editor) -1
          (mui-editor-signal-mask editor) 0)))

;;; ------------------------------------------------------------------
;;; Raw keys: the one OS call rawkey.lisp is parameterised over
;;; ------------------------------------------------------------------

(defun map-raw-key (editor code qualifier event-address)
  "MapRawKey for one key: the code of the single character the keymap
gives, or NIL.  EVENT-ADDRESS is the dead-key history (an IntuiMessage's
IAddress points at it) or 0."
  (let ((ie (mui-editor-ie editor))
        (buf (mui-editor-mapbuf editor)))
    (ffi:poke-u8 ie +ieclass-rawkey+ +ie-class-offset+)
    (ffi:poke-u16 ie code +ie-code-offset+)
    (ffi:poke-u16 ie qualifier +ie-qualifier-offset+)
    (ffi:poke-u32 ie event-address +ie-eventaddress-offset+)
    (let ((n (keymap:map-raw-key ie buf 8 nil)))
      (and (= n 1)
           (let ((ch (ffi:peek-u8 buf 0)))
             (and (/= ch 0) ch))))))

(defun decode-imsg (editor imsg)
  "An IntuiMessage's key, or NIL for what the Emacs layer must leave to the
class (see RAWKEY-DECODE)."
  (let ((iaddr (ffi:peek-u32 imsg +imsg-iaddress-offset+)))
    (rawkey-decode (ffi:peek-u16 imsg +imsg-code-offset+)
                   (ffi:peek-u16 imsg +imsg-qualifier-offset+)
                   (lambda (code qualifier)
                     (map-raw-key editor code qualifier
                                  (if (zerop iaddr)
                                      0
                                      (ffi:peek-u32 (ffi:make-foreign-pointer iaddr) 0)))))))

(defun handle-event-imsg (message)
  "The IntuiMessage of a MUIM_HandleEvent MESSAGE when it is a RAWKEY, else
NIL."
  (let ((addr (ffi:peek-u32 message +hev-imsg-offset+)))
    (and (/= addr 0)
         (let ((imsg (ffi:make-foreign-pointer addr)))
           (and (= (ffi:peek-u32 imsg +imsg-class-offset+) +idcmp-rawkey+)
                imsg)))))

;;; ------------------------------------------------------------------
;;; The handler node both classes register
;;; ------------------------------------------------------------------

(defun add-handler (ehn class object)
  "Register EHN, the class's OWN RAWKEY node at priority 1 -- above the
superclass's 0, so the Emacs layer runs first -- naming CLASS, so that
MUI's CoerceMethod comes back to this dispatcher."
  (ffi:poke-u8 ehn 1 +ehn-priority-offset+)
  (ffi:poke-u16 ehn m:+mui-ehf-guimode+ +ehn-flags-offset+)
  (ffi:poke-u32 ehn (object-address object) +ehn-object-offset+)
  (ffi:poke-u32 ehn (object-address class) +ehn-class-offset+)
  (ffi:poke-u32 ehn +idcmp-rawkey+ +ehn-events-offset+)
  (mui:do-method (window-object object) m:+muim-window-add-event-handler+ ehn))

(defun rem-handler (ehn object)
  (mui:do-method (window-object object) m:+muim-window-rem-event-handler+ ehn))

;;; ------------------------------------------------------------------
;;; ClamacsText
;;; ------------------------------------------------------------------

(defun add-idle-timer (editor ihn object)
  "The idle timer: MUI fires +CKM-IDLE-TICK+ on OBJECT every
+IDLE-TICK-MILLIS+ (IDLE-TICK).  The node is in the object's instance
data, like the RAWKEY one, so it cannot outlive the object: Cleanup takes
down a timer that is still up."
  (dotimes (i +ihn-size+)
    (ffi:poke-u8 ihn 0 i))
  (ffi:poke-u32 ihn (object-address object) +ihn-object-offset+)
  (ffi:poke-u16 ihn +idle-tick-millis+ +ihn-millis-offset+)
  (ffi:poke-u32 ihn m:+muiihnf-timer+ +ihn-flags-offset+)
  (ffi:poke-u32 ihn +ckm-idle-tick+ +ihn-method-offset+)
  (mui:do-method (mui-editor-app editor) m:+muim-application-add-input-handler+ ihn))

(defun rem-idle-timer (editor ihn)
  (mui:do-method (mui-editor-app editor) m:+muim-application-rem-input-handler+ ihn))

;;; With any timer handler up MUI 3.8 wakes the application loop some 60
;;; times a second, due or not, and each tick is Lisp: an editor that
;;; keeps one up for good takes a fifth of a 68040 while nobody types
;;; (the user's 68040, 2026-10-01).  So the timer is put up by
;;; the loop after a wake that ran editor code, and taken down by the loop
;;; once a tick found the display in step and no arglist to look up.

(defun arm-idle-timer (editor)
  "The idle timer up, on the active document's text object when it is not
up already.  True when it is up now; NIL when there is no set-up text
object to carry it -- the caller repaints at once then."
  (setf (mui-editor-timer-idle editor) nil)
  (or (and (mui-editor-timer-doc editor) t)
      (let* ((doc (active-document editor))
             (object (and doc (not (doc-closing doc)) (mdoc-text doc)))
             (data (and object (text-instance-data editor object))))
        (when (and data (/= 0 (ffi:peek-u32 data +text-eh-added-offset+)))
          (add-idle-timer editor (ffi:pointer+ data +text-ihn-offset+) object)
          (ffi:poke-u32 data 1 +text-timer-added-offset+)
          (count-timer-arm)
          (setf (mui-editor-timer-doc editor) doc
                (mui-editor-rest-ticks editor) 0)
          t))))

(defun disarm-idle-timer (editor)
  "The idle timer down, wherever it is."
  (let* ((doc (mui-editor-timer-doc editor))
         (object (and doc (mdoc-text doc)))
         (data (and object (text-instance-data editor object))))
    (setf (mui-editor-timer-doc editor) nil
          (mui-editor-timer-idle editor) nil)
    (when (and data (/= 0 (ffi:peek-u32 data +text-timer-added-offset+)))
      (rem-idle-timer editor (ffi:pointer+ data +text-ihn-offset+))
      (ffi:poke-u32 data 0 +text-timer-added-offset+))))

;;; --- The theme on the text objects (theme.lisp; specs/clamacs-themes.md,
;;; "The MUI frontend").  TextEditor.mcc lets a program set the colour map
;;; its SetBlock colours index -- eight pens obtained on the screen's
;;; colour map at Setup, released at Cleanup -- and a MUIA_Background,
;;; which it keeps (FLG_OwnBackground) instead of its configured one; the
;;; text colour has no attribute, so plain text is painted with the
;;; theme's text pen by the clear every recolour makes (COLOUR-VALUE).  The
;;; cursor and the selection are prefs items the class asks its object for
;;; (TEXT-GET-CONFIG-ITEM answers the theme's where the background is the
;;; theme's); the chrome stays the user's MUI prefs.  What
;;; the theme and the screen's depth decide is settled once, at the first
;;; Setup (THEME-PLAN), and again at every EDITOR-APPLY-THEME.

(defun screen-bitmap-depth (screen)
  "The depth of SCREEN (a struct Screen): GetBitMapAttr on its RastPort's
BitMap -- what an RTG screen answers too."
  (let ((bitmap (ffi:peek-u32 screen +screen-rastport-bitmap-offset+)))
    (if (zerop bitmap)
        8
        (gfx:get-bitmap-attr (ffi:make-foreign-pointer bitmap) gfx:+bma-depth+))))

(defun screen-depth (object)
  "The depth of the screen OBJECT is set up on."
  (screen-bitmap-depth (mui:area-screen object)))

(defun default-screen-depth ()
  "The depth of the default public screen, where the windows open unless
the user's MUI prefs say otherwise: what the plan is made from before the
first window exists.  8 when the screen cannot be locked."
  (let ((screen (intui:lock-pub-screen nil)))
    (if (or (null screen) (ffi:null-pointer-p screen))
        8
        (unwind-protect (screen-bitmap-depth screen)
          (intui:unlock-pub-screen nil screen)))))

(defconstant +bg-buffer-size+ 32)   ; "2:rrrrrrrr,gggggggg,bbbbbbbb" is 29
(defconstant +pen-spec-size+ 32)    ; struct MUI_PenSpec; "rrrrrrrrr,..." is 28

(defun mui-theme (editor)
  (or (mui-editor-theme editor) (active-theme)))

(defun theme-plan (editor)
  "What this frontend paints for the theme in effect on the screen it has
seen: the pens, the text pen, the background.  A dark theme on a shallow
screen (THEME-TEXT-PENS-P) keeps its token colours only, and says so
once."
  (let* ((theme (mui-theme editor))
         (depth (mui-editor-screen-depth editor))
         (text-pens (theme-text-pens-p theme depth)))
    (setf (mui-editor-theme-rgb editor) (theme-pens theme)
          (mui-editor-text-pen-p editor) text-pens
          (mui-editor-bg-spec editor) (and text-pens (theme-background-spec theme))
          ;; The cursor and the selection go with the background: a
          ;; theme's cursor over the class's own background would be a
          ;; colour the user never chose on one they did.
          (mui-editor-cursor-spec editor) (and text-pens (theme-pen-spec theme :cursor))
          (mui-editor-marked-spec editor) (and text-pens (theme-pen-spec theme :selection)))
    (when (and (not text-pens) (not (mui-editor-shallow-noted editor)))
      (setf (mui-editor-shallow-noted editor) t
            (mui-editor-theme-note editor)
            (format nil "~A: a dark theme keeps the screen's text and background on a ~D-colour screen"
                    (theme-label theme) (ash 1 depth))))
    (when (mui-editor-bg-spec editor)
      (store-text (mui-editor-bg-buf editor) +bg-buffer-size+ (mui-editor-bg-spec editor)))
    (when (mui-editor-cursor-spec editor)
      (store-text (mui-editor-cursor-buf editor) +pen-spec-size+ (mui-editor-cursor-spec editor)))
    (when (mui-editor-marked-spec editor)
      (store-text (mui-editor-marked-buf editor) +pen-spec-size+ (mui-editor-marked-spec editor)))))

(defun show-theme-note (editor doc)
  "The message THEME-PLAN left, in DOC's echo area, once."
  (let ((note (mui-editor-theme-note editor)))
    (when (and note doc)
      (setf (mui-editor-theme-note editor) nil)
      (doc-message doc note))))

(defun obtain-text-pens (editor data object)
  "The theme's eight pens on OBJECT's screen into its colour map."
  (let ((cm (screen-colormap object)))
    (loop for (r g b) in (mui-editor-theme-rgb editor)
          for i from 0 below +pen-count+
          do (ffi:poke-i32 data
                           (gfx:obtain-best-pen-a cm (ash r 24) (ash g 24) (ash b 24) nil)
                           (+ +text-cmap-offset+ (* 4 i))))
    (ffi:poke-u32 data 1 +text-pens-held-offset+)))

(defun release-text-pens (data object)
  (when (/= 0 (ffi:peek-u32 data +text-pens-held-offset+))
    (let ((cm (screen-colormap object)))
      (dotimes (i +pen-count+)
        (let ((pen (ffi:peek-i32 data (+ +text-cmap-offset+ (* 4 i)))))
          (when (/= pen -1)
            (gfx:release-pen cm pen))
          (ffi:poke-i32 data -1 (+ +text-cmap-offset+ (* 4 i))))))
    (ffi:poke-u32 data 0 +text-pens-held-offset+)))

(defun text-background-wanted (editor doc)
  "Does the plan give DOC's text object the theme's background?  Only a
Lisp-mode document, and only where the theme paints one."
  (and doc (doc-lisp-mode doc) (mui-editor-bg-spec editor) t))

(defun text-background-owned-p (data)
  "Does the text object with instance data DATA hold the theme's background?"
  (/= 0 (ffi:peek-u32 data +text-own-bg-offset+)))

(defun text-instance-data (editor object)
  (mui:inst-data (mui:custom-class-class (mui-editor-textclass editor)) object))

(defun apply-text-background (editor data object doc)
  "The theme's background on OBJECT when DOC is in Lisp mode -- where the
colouring paints every line in the theme's text colour; a document that is
not keeps the class's own colours, like the chrome -- and the standard
text background back where this object had the theme's before.  Only on
an object that is not set up: MUI 3.8 does not repaint one that is."
  (let ((want (text-background-wanted editor doc))
        (own (text-background-owned-p data)))
    (cond (want
           (mui:set-attrs object m:+muia-background+ (mui-editor-bg-buf editor))
           (ffi:poke-u32 data 1 +text-own-bg-offset+))
          (own
           (mui:set-attrs object m:+muia-background+ m:+muii-text-back+)
           (ffi:poke-u32 data 0 +text-own-bg-offset+)))))

(defun ensure-theme-plan (editor)
  "The plan before the first window: from the default public screen's
depth.  A window's Setup checks it against the screen it really opened on."
  (unless (mui-editor-screen-depth editor)
    (setf (mui-editor-screen-depth editor) (default-screen-depth))
    (theme-plan editor)))

(defun text-creation-background-p (editor lisp-mode)
  "Is a text object made now for a document in LISP-MODE given the theme's
background?  BUILD-WINDOW records it in the object (the owned flag) when it
was, so that a plan the first Setup corrects can take it away again."
  (ensure-theme-plan editor)
  (and lisp-mode (mui-editor-bg-spec editor) t))

(defun text-creation-tags (editor lisp-mode)
  "The theme's background as a creation tag of a text object -- the way
the class takes it for sure (an Area sets its background up at Setup from
what it was given before) -- for a Lisp-mode document with a theme that
paints one; and the font, always: MUIA_Font among the creation tags is
what makes the class take the font as ours (FLG_OwnFont, set at OM_NEW
alone), so a later set of the attribute on the closed object is honoured
at its next Setup.  MUI's fixed font until the text size setting opened
one of its own (TEXT-FONT-WANTED)."
  (append (and (text-creation-background-p editor lisp-mode)
               (list m:+muia-background+ (mui-editor-bg-buf editor)))
          (list m:+muia-font+ (text-font-wanted editor))))

;;; The text size (theme.lisp's FONT-SIZE).  The class draws with the
;;; font MUIA_Font names -- MUI's fixed font by default -- and reads the
;;; attribute again at every Setup, so a size is applied the way a theme
;;; is: the windows closed, the attribute set, the windows opened
;;; (THEME-REPAINT).  The font is MUI's fixed font's, by name, at the
;;; wanted height, opened with diskfont.library and closed once no object
;;; draws with it any more.

(defun text-font-wanted (editor)
  "What MUIA_Font is set to: the font this frontend opened for the text
size setting, else MUI's own fixed font."
  (or (mui-editor-font editor) m:+muiv-font-fixed+))

(defun learn-text-font (editor object)
  "MUI's fixed font, as OBJECT's Setup resolved it, when it is not known
yet: its name and height.  A text size in force before the first window
is applied now that the font to size is known."
  (unless (mui-editor-font-name editor)
    (let ((font (mui:area-font object)))
      (when (and font (not (ffi:null-pointer-p font)))
        (let ((name (ffi:peek-pointer font +tf-name-offset+)))
          (unless (ffi:null-pointer-p name)
            (setf (mui-editor-font-name editor) (ffi:foreign-to-string name)
                  (mui-editor-font-default-size editor) (ffi:peek-u16 font +tf-ysize-offset+))
            (when (and *font-size* (/= *font-size* (mui-editor-font-default-size editor)))
              (setf (mui-editor-font-dirty editor) t
                    (mui-editor-theme-dirty editor) t))))))))

(defun open-text-font (editor size)
  "MUI's fixed font at SIZE pixels, opened, or NIL when diskfont cannot.
The TextAttr and the name stay allocated for the font's lifetime."
  (let ((name (mui-editor-font-name editor)))
    (when name
      (unless (mui-editor-font-attr editor)
        (setf (mui-editor-font-attr editor) (ffi:alloc-foreign +text-attr-size+)
              (mui-editor-font-name-buf editor) (ffi:alloc-foreign +font-name-size+)))
      (let ((attr (mui-editor-font-attr editor)))
        (store-text (mui-editor-font-name-buf editor) +font-name-size+ name)
        (ffi:poke-u32 attr (ffi:foreign-pointer-address (mui-editor-font-name-buf editor)) 0)
        (ffi:poke-u16 attr size 4)
        (ffi:poke-u8 attr 0 6)
        (ffi:poke-u8 attr 0 7)
        (let ((font (diskfont:open-disk-font attr)))
          (and font (not (ffi:null-pointer-p font)) font))))))

(defun close-text-font (editor)
  "The font this frontend opened given back, once nothing draws with it."
  (let ((font (mui-editor-font editor)))
    (when font
      (gfx:close-font font)
      (setf (mui-editor-font editor) nil
            (mui-editor-font-size editor) nil))))

(defun free-text-font-buffers (editor)
  (when (mui-editor-font-attr editor)
    (ffi:free-foreign (mui-editor-font-attr editor))
    (ffi:free-foreign (mui-editor-font-name-buf editor))
    (setf (mui-editor-font-attr editor) nil
          (mui-editor-font-name-buf editor) nil)))

(defun text-font-size-shown (doc)
  "The height of the font DOC's text area draws with, from Setup on, or
NIL before: what a run reads back."
  (let* ((object (mdoc-text doc))
         (ri (and object (mui:area-render-info object))))
    (and ri (not (ffi:null-pointer-p ri))
         (ffi:peek-u16 (mui:area-font object) +tf-ysize-offset+))))

(defmethod editor-apply-font-size ((editor mui-editor) size)
  "Applied at the next repaint from the event loop (THEME-REPAINT): the
font opened there, the windows reopened with it."
  (declare (ignore size))
  (when (mui-editor-app editor)
    (setf (mui-editor-font-dirty editor) t
          (mui-editor-theme-dirty editor) t)))

(defmethod editor-default-font-size ((editor mui-editor))
  (or (mui-editor-font-default-size editor) 16))

(defun text-font-change (editor)
  "The font the windows are reopened with when the size setting changed:
(values CHANGED-P NEW-FONT OLD-FONT) -- NEW-FONT the freshly opened font,
or NIL for MUI's own; OLD-FONT the one to close once the windows are up
again.  Nothing changes when the wanted font cannot be opened, which the
echo area says."
  (setf (mui-editor-font-dirty editor) nil)
  (let ((want (and *font-size*
                   (mui-editor-font-name editor)
                   (/= *font-size* (or (mui-editor-font-default-size editor) 0))
                   *font-size*)))
    (cond ((eql want (mui-editor-font-size editor))
           (values nil nil nil))
          ((null want)
           (values t nil (mui-editor-font editor)))
          (t
           (let ((font (open-text-font editor want)))
             (cond (font
                    (values t font (mui-editor-font editor)))
                   (t
                    (setf (mui-editor-theme-note editor)
                          (format nil "Cannot open ~A at ~D pixels; the text size stays"
                                  (mui-editor-font-name editor) want))
                    (values nil nil nil))))))))

(defun text-setup (editor class object message)
  (let ((ok (mui:do-super-method class object message)))
    (when (/= ok 0)
      (let ((data (mui:inst-data class object)))
        ;; Pens for the colouring: obtained here rather than at creation,
        ;; since a pen belongs to the screen the object ends up on -- whose
        ;; depth is checked against the plan's here.
        (let ((depth (screen-depth object)))
          (unless (eql depth (mui-editor-screen-depth editor))
            (setf (mui-editor-screen-depth editor) depth)
            (theme-plan editor)))
        (obtain-text-pens editor data object)
        (learn-text-font editor object)
        (mui:set-attrs object +tea-color-map+ (ffi:pointer+ data +text-cmap-offset+))
        ;; The background is the repaint's to change, the object not being
        ;; set up there (MUI 3.8 repaints nothing set during Setup): an
        ;; object created with the theme's -- or without it -- that the
        ;; plan, corrected just now for the screen it opened on, wants
        ;; otherwise is put right by a repaint from the event loop.
        (unless (eq (text-background-wanted editor (object-document editor object))
                    (text-background-owned-p data))
          (setf (mui-editor-theme-dirty editor) t))
        ;; The Emacs layer's key handler, ahead of the class's own.
        (add-handler (ffi:pointer+ data +text-ehn-offset+) class object)
        (ffi:poke-u32 data 1 +text-eh-added-offset+)
        ;; The idle timer is the loop's to put up (ARM-IDLE-TIMER); the
        ;; window just opened has its status line and menus to show.
        (incf (mui-editor-activity editor))))
    ok))

(defun text-cleanup (editor class object message)
  (let ((data (mui:inst-data class object)))
    (when (/= 0 (ffi:peek-u32 data +text-timer-added-offset+))
      (rem-idle-timer editor (ffi:pointer+ data +text-ihn-offset+))
      (ffi:poke-u32 data 0 +text-timer-added-offset+)
      ;; The loop puts it up again, on an object that is set up, at the
      ;; next wake: what the display still owes is not lost with it.
      (setf (mui-editor-timer-doc editor) nil
            (mui-editor-timer-idle editor) nil)
      (incf (mui-editor-activity editor)))
    (when (/= 0 (ffi:peek-u32 data +text-eh-added-offset+))
      (rem-handler (ffi:pointer+ data +text-ehn-offset+) object)
      (ffi:poke-u32 data 0 +text-eh-added-offset+))
    (when (/= 0 (ffi:peek-u32 data +text-pens-held-offset+))
      (mui:set-attrs object +tea-color-map+ nil)
      (release-text-pens data object)))
  (mui:do-super-method class object message))

(defun text-get-config-item (editor class object message)
  "MUIM_GetConfigItem, which the class asks its object for each of its
prefs at Setup (InitConfig, inside the superclass's MUIM_Setup): the
cursor's and the marked block's pen specs are the theme's on an object
that holds the theme's background -- the class's default cursor is MUI's
shine pen, white on a light theme's white -- and whatever the user's
prefs say on any other, as for every other item."
  (let* ((id (ffi:peek-u32 message +gci-id-offset+))
         (buf (cond ((= id +tecfg-cursor-color+)
                     (and (mui-editor-cursor-spec editor) (mui-editor-cursor-buf editor)))
                    ((= id +tecfg-marked-color+)
                     (and (mui-editor-marked-spec editor) (mui-editor-marked-buf editor))))))
    (if (and buf (text-background-owned-p (mui:inst-data class object)))
        (let ((storage (ffi:peek-u32 message +gci-storage-offset+)))
          (when (/= storage 0)
            (ffi:poke-u32 (ffi:make-foreign-pointer storage) (object-address buf) 0))
          1)
        (mui:do-super-method class object message))))

(defmethod editor-apply-theme ((editor mui-editor) theme)
  "THEME remembered, and the windows marked for THEME-REPAINT.  Before the
first window that window's Setup paints it."
  (setf (mui-editor-theme editor) theme)
  (when (mui-editor-app editor)
    (setf (mui-editor-theme-dirty editor) t)))

(defmethod doc-lisp-mode-changed ((doc mui-document))
  "The background follows the mode: the theme's on a Lisp-mode document,
the class's own otherwise -- at the next repaint."
  (let ((editor (doc-editor doc)))
    (when (mui-editor-app editor)
      (setf (mui-editor-theme-dirty editor) t))))

(defun window-open-p (window)
  (and window (/= 0 (or (mui:get-attr m:+muia-window-open+ window) 0))))

(defun theme-repaint (editor)
  "The theme onto the open document windows, the way MUI itself brings a
changed look to an application: each window is closed and opened again.
A MUIA_Background set on a set-up object does not repaint it (MUI 3.8),
and a changed colour map repaints nothing either; the close runs Cleanup
(the pens released), the background is set on the object while it is not
set up -- as at creation, where the class takes it for sure -- and the
open runs Setup (the theme's pens obtained) and redraws.  Then every
Lisp-mode document is recoloured -- and one that left Lisp mode with the
theme's background, which the colouring no longer runs on, is cleared of
the colours it was painted in -- and the active window made active again.
Only from the event loop (HOUSEKEEPING, START), never from a hook: MUI may
still be inside the window that asked."
  (when (and (mui-editor-theme-dirty editor) (mui-editor-app editor)
             (not (editor-quitting editor)))
    (setf (mui-editor-theme-dirty editor) nil)
    (when (mui-editor-screen-depth editor)
      (theme-plan editor))
    (multiple-value-bind (font-changed new-font old-font)
        (if (mui-editor-font-dirty editor)
            (text-font-change editor)
            (values nil nil nil))
      (when font-changed
        (setf (mui-editor-font editor) new-font
              (mui-editor-font-size editor) (and new-font *font-size*)))
    (let ((active (active-document editor)))
      (dolist (doc (live-documents editor))
        (let* ((window (mdoc-window doc))
               (object (mdoc-text doc))
               (data (and object (text-instance-data editor object)))
               (painted (and data (text-background-owned-p data))))
          (when (and object (window-open-p window))
            ;; Where the window is and how big the user made it, read
            ;; while it is open, and given back to the closed window
            ;; before it opens: a reopen alone brings the window up at
            ;; its creation size (MUI 4 on MorphOS), the resize lost.
            (multiple-value-bind (left top width height) (window-geometry window)
              (mui:set-attrs window m:+muia-window-open+ nil)
              (apply-text-background editor data object doc)
              ;; The font, taken by the class at the Setup the open runs
              (when font-changed
                (mui:set-attrs object m:+muia-font+ (text-font-wanted editor)))
              (mui:set-attrs window
                             m:+muia-window-left-edge+ left m:+muia-window-top-edge+ top
                             m:+muia-window-width+ width m:+muia-window-height+ height)
              (mui:set-attrs window m:+muia-window-open+ t))
            (cond ((doc-lisp-mode doc) (colour-all doc))
                  (painted (clear-text-colours doc))))))
      (when (and active (not (doc-closing active)))
        (doc-activate active)))
      ;; The font the windows drew with before: no object is set up on it
      ;; now, so it can go.
      (when (and font-changed old-font)
        (gfx:close-font old-font)))
    (show-theme-note editor (active-document editor))))

(defun wake-loop (editor)
  "Hand the event loop a return ID, so that it runs its housekeeping --
reaping retired windows, acting on a quit -- once MUI is out of the
method or hook that asked."
  (mui:return-id (mui-editor-app editor) (mui-editor-reap-id editor)))

(defun after-command (editor)
  "A command ran inside a method or a hook: counted, so that the display
follows the state it left once the keys rest (REDISPLAY) -- on a 68040
the menu's enable states alone, worked out after every key, hook and
key release, were a visible part of what a typed character cost -- and a
quit it asked for is the loop's to carry out."
  (incf (mui-editor-activity editor))
  (when (editor-quitting editor)
    (wake-loop editor)))

(defun command-imsg (editor imsg)
  "The command an IntuiMessage's key asks for with the right Amiga key
(RAWKEY-COMMAND), or NIL."
  (rawkey-command (ffi:peek-u16 imsg +imsg-code-offset+)
                  (ffi:peek-u16 imsg +imsg-qualifier-offset+)
                  (lambda (code qualifier)
                    (map-raw-key editor code qualifier 0))))

(defun show-region (doc)
  "The class's marked block in step with the region: from the mark to the
cursor while the region is shown (DOC-MARK-ACTIVE), taken down when it no
longer is.  A block the class marked itself -- the mouse, Shift with the
arrows -- is never touched."
  (unless (doc-closing doc)
    (let ((mark (and (doc-mark-active doc) (doc-mark doc)))
          (point (doc-point doc)))
      (cond ((and mark (/= mark point))
             (mark-range doc mark point)
             (setf (mdoc-region-shown doc) t))
            ((mdoc-region-shown doc)
             (te-command doc "SELECTNONE")
             (setf (mdoc-region-shown doc) nil))))))

(defun hide-region (doc)
  "The region's block taken down before a key the class edits or moves
with: typing must not replace what `C-SPC' and a motion marked.  The mark
stays."
  (when (mdoc-region-shown doc)
    (te-command doc "SELECTNONE")
    (setf (mdoc-region-shown doc) nil))
  (setf (doc-mark-active doc) nil))

(defun text-handle-event (editor object message)
  "Invoked only through the class's own node, so it does not chain to the
superclass: when the Emacs layer does not take the key it returns 0 and
MUI's next handler -- the class's node -- edits."
  (let ((imsg (handle-event-imsg message))
        (doc (object-document editor object)))
    (if (and imsg doc (active-object-p object))
        (let* ((command (command-imsg editor imsg))
               (key (and (not command) (decode-imsg editor imsg)))
               (taken (cond (command
                             (keystate-reset (doc-keys doc))
                             (run-command doc command)
                             t)
                            (key (handle-key doc key)))))
          (cond (taken (show-region doc))
                (key (hide-region doc)))
          (after-command editor)
          (if taken m:+mui-event-handler-rc-eat+ 0))
        0)))

(defun idle-tick (editor)
  "One tick of the idle timer.  A tick that finds editor code ran since
the last one -- the user is typing -- only notes it (and repaints about
once a second of that).  A tick after a rest
brings the display in step (REDISPLAY) and lets the arglist look (two rest
ticks: ARGLIST-IDLE wants the cursor where it saw it last).  A lookup
moves the editor's state, so the ticks go on; when nothing is left the
timer is marked for the loop to take down."
  (let ((activity (mui-editor-activity editor)))
    (cond ((/= activity (mui-editor-tick-activity editor))
           (setf (mui-editor-tick-activity editor) activity
                 (mui-editor-rest-ticks editor) 0
                 (mui-editor-timer-idle editor) nil)
           ;; Typing without a pause: not left stale for longer than
           ;; +BUSY-REDISPLAY-TICKS+.
           (when (>= (incf (mui-editor-busy-ticks editor)) +busy-redisplay-ticks+)
             (setf (mui-editor-busy-ticks editor) 0)
             (redisplay editor)
             (setf (mui-editor-tick-activity editor) (mui-editor-activity editor))))
          (t
           (incf (mui-editor-rest-ticks editor))
           (setf (mui-editor-busy-ticks editor) 0)
           (redisplay editor)
           ;; What the repaint itself stirred up is not typing.
           (setf (mui-editor-tick-activity editor) (mui-editor-activity editor))
           (let ((doc (active-document editor)))
             (cond ((>= (mui-editor-rest-ticks editor) +idle-give-up-ticks+)
                    (setf (mui-editor-timer-idle editor) t))
                   ((and doc (not (doc-closing doc)) (arglist-idle doc))
                    ;; The state the menu shows may have moved (a port
                    ;; found): shown by the next tick -- which is still a
                    ;; rest tick, the lookup being no key.
                    (after-command editor)
                    (setf (mui-editor-tick-activity editor) (mui-editor-activity editor)))
                   ((or (null doc)
                        (not (arglist-idle-pending-p doc)))
                    (setf (mui-editor-timer-idle editor) t))))))))

;;; MUI sends a text object some thirty methods for every typed character
;;; -- OM_SET, OM_GET, MUIM_Draw, MUIM_DrawBackground, the class's own --
;;; and each one that reaches a Lisp dispatcher is a callback into the VM
;;; whose only work is to hand it on (the user's 68040, 2026-10-04: typing
;;; still trailed the keys).  So each class names the methods its
;;; dispatcher handles and the runtime passes every other one to the
;;; superclass natively (MUI:CREATE-CUSTOM-CLASS :METHODS).  **A method
;;; added to a dispatcher's COND must be added to its list**: one that is
;;; not listed never arrives.

(defun text-dispatcher-methods ()
  "The methods MAKE-TEXT-DISPATCHER handles, one per COND clause."
  (list m:+muim-handle-event+ +ckm-idle-tick+ m:+muim-setup+ m:+muim-cleanup+
        m:+muim-get-config-item+ m:+muim-go-active+ m:+muim-show+))

(defun make-text-dispatcher (editor)
  (lambda (class object message)
    (let ((id (mui:method-id message)))
      (count-method id)
      (cond ((= id m:+muim-handle-event+)
             (text-handle-event editor object message))
            ((= id +ckm-idle-tick+)
             (idle-tick editor)
             0)
            ((= id m:+muim-setup+)
             (text-setup editor class object message))
            ((= id m:+muim-cleanup+)
             (text-cleanup editor class object message))
            ((= id m:+muim-get-config-item+)
             (text-get-config-item editor class object message))
            ((= id m:+muim-go-active+)
             (let ((result (mui:do-super-method class object message)))
               (set-window-keys object *text-window-keys*)
               result))
            ;; The class's own Hide zeroes MUIA_Window_DisableKeys and its
            ;; Show puts nothing back -- and MUI hides and shows every
            ;; object on a relayout.  Re-arm while this is the active one.
            ((= id m:+muim-show+)
             (let ((result (mui:do-super-method class object message)))
               (when (active-object-p object)
                 (set-window-keys object *text-window-keys*))
               result))
            (t (mui:do-super-method class object message))))))

;;; ------------------------------------------------------------------
;;; ClamacsMini
;;; ------------------------------------------------------------------

(defun meta-char-key-p (key)
  "Meta plus a character the minibuffer does not bind: taken too, else the
gadget types a stray dead-key character (Alt-x gave `x' with a ring)."
  (and (/= 0 (logand (key-mods key) +mod-meta+))
       (<= #x20 (key-code key) #xFF)))

(defvar *mini-trace* nil
  "When true, what MUI hands the minibuffer's handler method, and every
key its edit hook pushes, is recorded in *MINI-TRACE-LOG*, newest first
-- the C editor's CK_MINI_TRACE, but switchable from the running editor
\(`EVAL (setf clamacs::*mini-trace* t)' over the port, then read the log
back the same way).  How the MUI 3.8 / MUI 4 key paths were established.
The hook itself is native and records nothing; MUI:STRING-KEY-HOOK-STATS
on a document's hook (MUI-EDITOR-MINI-HOOKS) says how often MUI called
it and how many keys it took.")

(defvar *mini-trace-log* '())

(defun mini-trace (&rest record)
  (when *mini-trace*
    (push record *mini-trace-log*)))

(defun mini-hook-entries (editor)
  "The key table for MAKE-STRING-KEY-HOOK: (code qual-mask qual-value key)
for every raw code and qualifier set that the keymap decodes to a key the
minibuffer binds in some state (MINIBUFFER-EVER-BINDS-P) or to Meta plus
a character (META-CHAR-KEY-P).  The keymap is asked once per editor:
some 750 MapRawKey calls, cached on the editor.  The hook pushes the KEY
itself, which CKM_MiniKey hands to MINIBUFFER-KEY; a key the current
state does not bind is reported undefined there, exactly as the C
editor's hook reports Alt-x."
  (or (mui-editor-mini-hook-entries editor)
      (setf (mui-editor-mini-hook-entries editor)
            (let ((entries '()))
              (dotimes (code #x80)
                (dolist (qualifier *mini-hook-qualifiers*)
                  (let ((key (rawkey-decode code qualifier
                                            (lambda (c q) (map-raw-key editor c q 0)))))
                    (when (and key
                               (or (minibuffer-ever-binds-p key) (meta-char-key-p key)))
                      (push (list code +mini-hook-qual-mask+ qualifier key) entries)))))
              (nreverse entries)))))

(defun mini-key-undefined (doc key)
  (when (minibuffer-open-p doc)
    (message doc "~A is undefined" (key-to-string key))))

(defun mini-handle-event (editor class object message)
  (let ((imsg (handle-event-imsg message))
        (data (mui:inst-data class object)))
    (when imsg
      ;; MUI 3.8 coerces a node's call to the node's class, so this method
      ;; sees an event once.  MUI 4 dispatches the String's own node
      ;; through the class chain -- through here a second time for the
      ;; same event -- and never calls the edit hook: that second visit is
      ;; the String's turn to edit, recognised as the event just seen.
      (let ((code (ffi:peek-u16 imsg +imsg-code-offset+))
            (seconds (ffi:peek-u32 imsg +imsg-seconds-offset+))
            (micros (ffi:peek-u32 imsg +imsg-micros-offset+)))
        (when (and (= (ffi:peek-u32 data +mini-seen-imsg-offset+) (object-address imsg))
                   (= (ffi:peek-u16 data +mini-seen-code-offset+) code)
                   (= (ffi:peek-u32 data +mini-seen-seconds-offset+) seconds)
                   (= (ffi:peek-u32 data +mini-seen-micros-offset+) micros))
          (return-from mini-handle-event (mui:do-super-method class object message)))
        (ffi:poke-u32 data (object-address imsg) +mini-seen-imsg-offset+)
        (ffi:poke-u16 data code +mini-seen-code-offset+)
        (ffi:poke-u32 data seconds +mini-seen-seconds-offset+)
        (ffi:poke-u32 data micros +mini-seen-micros-offset+)))
    (let ((doc (object-document editor object)))
      (when (and imsg *mini-trace*)
        (mini-trace :handle-event (and doc t) (active-object-p object)
                    (ffi:peek-u16 imsg +imsg-code-offset+)
                    (ffi:peek-u16 imsg +imsg-qualifier-offset+)
                    (decode-imsg editor imsg)))
      (when (and imsg doc (active-object-p object))
        ;; An active MUI 3.8 String edits through the edit hook before the
        ;; handler list is consulted, and a key the hook took reaches it as
        ;; a release of no key: only the keys the hook left alone, and on
        ;; MUI 4 every key, arrive here as presses.
        (let ((key (decode-imsg editor imsg)))
          (when key
            (when (minibuffer-key doc key)
              (after-command editor)
              (return-from mini-handle-event m:+mui-event-handler-rc-eat+))
            (when (and (meta-char-key-p key) (minibuffer-open-p doc))
              (mini-key-undefined doc key)
              (return-from mini-handle-event m:+mui-event-handler-rc-eat+))))))
    ;; Not consumed: the string gadget's own handler edits.
    0))

(defun mini-dispatcher-methods ()
  "The methods MAKE-MINI-DISPATCHER handles, one per COND clause."
  (list m:+muim-handle-event+ +ckm-mini-key+ intui:+om-new+ intui:+om-dispose+
        m:+muim-setup+ m:+muim-cleanup+ m:+muim-go-active+ m:+muim-show+
        m:+muim-go-inactive+))

(defun make-mini-dispatcher (editor)
  (lambda (class object message)
    (let ((id (mui:method-id message)))
      (count-method id)
      (cond ((= id m:+muim-handle-event+)
             (mini-handle-event editor class object message))
            ((= id +ckm-mini-key+)
             ;; The key the edit hook took, pushed by MUI's input loop now
             ;; that the String's own handling is over and the contents
             ;; may change safely.
             (let ((doc (object-document editor object))
                   (key (ffi:peek-u32 message 4)))
               (mini-trace :mini-key (and doc t) key)
               (when doc
                 (unless (minibuffer-key doc key)
                   (mini-key-undefined doc key))
                 (after-command editor))
               0))
            ((= id intui:+om-new+)
             (let ((self (mui:do-super-method class object message)))
               (when (/= self 0)
                 ;; One native hook per object, pushing the keys of the
                 ;; table to this object as CKM_MiniKey.  The hook OBJECT
                 ;; is kept, keyed by the object's address: only it can be
                 ;; freed.
                 (let ((hook (mui:make-string-key-hook
                              (or (mui-editor-app editor)
                                  (error "ClamacsMini made before the application object"))
                              (ffi:make-foreign-pointer self)
                              +ckm-mini-key+
                              (mini-hook-entries editor))))
                   (setf (gethash self (mui-editor-mini-hooks editor)) hook)
                   (mui:set-attrs (ffi:make-foreign-pointer self)
                                  m:+muia-string-edit-hook+ hook)))
               self))
            ((= id intui:+om-dispose+)
             ;; The String is disposed of FIRST: it holds the hook, and the
             ;; free releases the hook's entry code as well as the struct
             ;; -- "only after every String that holds it is disposed".
             ;; Forgotten before the free: a second dispose of the same
             ;; object must not free it twice.
             (let* ((table (mui-editor-mini-hooks editor))
                    (address (object-address object))
                    (hook (gethash address table)))
               (remhash address table)
               (prog1 (mui:do-super-method class object message)
                 (mui:free-string-key-hook hook))))
            ((= id m:+muim-setup+)
             (let ((ok (mui:do-super-method class object message)))
               (when (/= ok 0)
                 (let ((data (mui:inst-data class object)))
                   (add-handler (ffi:pointer+ data +mini-ehn-offset+) class object)
                   (ffi:poke-u32 data 1 +mini-eh-added-offset+)))
               ok))
            ((= id m:+muim-cleanup+)
             (let ((data (mui:inst-data class object)))
               (when (/= 0 (ffi:peek-u32 data +mini-eh-added-offset+))
                 (rem-handler (ffi:pointer+ data +mini-ehn-offset+) object)
                 (ffi:poke-u32 data 0 +mini-eh-added-offset+)))
             (mui:do-super-method class object message))
            ;; TAB is MUI's cycle-chain key, acted on at the window level:
            ;; while the minibuffer has the focus it is ours (completion).
            ((= id m:+muim-go-active+)
             (set-window-keys object *mini-window-keys*)
             (mui:do-super-method class object message))
            ((= id m:+muim-show+)
             (let ((result (mui:do-super-method class object message)))
               (when (active-object-p object)
                 (set-window-keys object *mini-window-keys*))
               result))
            ((= id m:+muim-go-inactive+)
             (set-window-keys object 0)
             (mui:do-super-method class object message))
            (t (mui:do-super-method class object message))))))

;;; ------------------------------------------------------------------
;;; The class objects and the TextEditor.mcc version check
;;; ------------------------------------------------------------------

(defun texteditor-version ()
  "YAM's way of asking an MCC its version: a bare object's MUIA_Version /
MUIA_Revision.  Loads the class, so a missing one fails here.  Two values,
or NIL."
  (let ((probe (handler-case (mui:new-object "TextEditor.mcc")
                 (error () nil))))
    (when probe
      (unwind-protect
           (values (or (mui:get-attr m:+muia-version+ probe) 0)
                   (or (mui:get-attr m:+muia-revision+ probe) 0))
        (mui:dispose-object probe)))))

(defun texteditor-at-least (editor version revision)
  (let ((v (mui-editor-te-version editor)) (r (mui-editor-te-revision editor)))
    (or (> v version) (and (= v version) (>= r revision)))))

(defun create-classes (editor)
  (multiple-value-bind (version revision) (texteditor-version)
    (unless version
      (error "Clamacs needs TextEditor.mcc (MUI:Libs/mui/TextEditor.mcc), which did not open."))
    (setf (mui-editor-te-version editor) version
          (mui-editor-te-revision editor) revision)
    (unless (texteditor-at-least editor +te-min-version+ +te-min-revision+)
      (error "Clamacs needs TextEditor.mcc ~D.~D or newer; this one is ~D.~D."
             +te-min-version+ +te-min-revision+ version revision))
    (setf (mui-editor-textclass editor)
          (mui:create-custom-class "TextEditor.mcc" (make-text-dispatcher editor)
                                   :data-size +text-data-size+
                                   :methods (text-dispatcher-methods))
          (mui-editor-miniclass editor)
          (mui:create-custom-class :string (make-mini-dispatcher editor)
                                   :data-size +mini-data-size+
                                   :methods (mini-dispatcher-methods)))))

;;; ------------------------------------------------------------------
;;; The text widget: the protocol's text access and editing
;;; ------------------------------------------------------------------

(defun te-get (doc attribute)
  (or (mui:get-attr attribute (mdoc-text doc)) 0))

(defun te-command (doc command)
  "One of the class's own ARexx commands.  True when it succeeded."
  (let ((r (ffi:with-foreign-string (p command)
             (mui:do-method (mdoc-text doc) +tem-arexx-cmd+ p))))
    (cond ((zerop r) nil)
          ((= r 1) t)
          ;; a query command answers with a string we did not ask for
          (t (exec:free-vec (ffi:make-foreign-pointer r)) t))))

(defun index-to-xy (doc index)
  "Two values, X and Y, of INDEX."
  (let ((xy (ffi:alloc-foreign 8)))
    (unwind-protect
         (progn
           (ffi:poke-u32 xy 0 0)
           (ffi:poke-u32 xy 0 4)
           (mui:do-method (mdoc-text doc) +tem-index-to-cursor-xy+ index
                          xy (ffi:pointer+ xy 4))
           (values (ffi:peek-i32 xy 0) (ffi:peek-i32 xy 4)))
      (ffi:free-foreign xy))))

(defun xy-to-index (doc x y)
  (let ((out (ffi:alloc-foreign 4)))
    (unwind-protect
         (progn
           (ffi:poke-u32 out 0 0)
           (mui:do-method (mdoc-text doc) +tem-cursor-xy-to-index+ x y out)
           (ffi:peek-i32 out 0))
      (ffi:free-foreign out))))

(defun last-line (doc)
  "MUIA_TextEditor_Prop_Entries is the class's line count, 1-based;
ExportBlock leaves its stop line alone when asked for one past the end, so
this clamp matters."
  (let ((total (te-get doc +tea-prop-entries+)))
    (if (> total 0) (1- total) 0)))

(defun char-width (doc)
  "The width of the fixed font's characters, known from Setup on."
  (let ((ri (mui:area-render-info (mdoc-text doc))))
    (if (and ri (not (ffi:null-pointer-p ri)))
        (ffi:peek-u16 (mui:area-font (mdoc-text doc)) +tf-xsize-offset+)
        0)))

(defun hscroll-into-view (doc)
  "TextEditor.mcc scrolls sideways only after its own cursor moves; a move
made by the Emacs layer left the cursor wherever the view was.  The bar
counts pixels and the font is fixed-width."
  (let ((hslider (mdoc-hslider doc)))
    (when hslider
      (let ((cw (char-width doc)))
        (when (> cw 0)
          (let ((px (* (te-get doc +tea-cursor-x+) cw))
                (first (or (mui:get-attr m:+muia-prop-first+ hslider) 0))
                (visible (or (mui:get-attr m:+muia-prop-visible+ hslider) 0)))
            (when (> visible 0)
              (cond ((< px first)
                     (mui:set-attrs hslider m:+muia-prop-first+ px))
                    ((> (+ px cw) (+ first visible))
                     (mui:set-attrs hslider m:+muia-prop-first+ (- (+ px cw) visible)))))))))))

(defmethod doc-point ((doc mui-document))
  (te-get doc +tea-cursor-index+))

(defmethod doc-set-point ((doc mui-document) index)
  (mui:set-attrs (mdoc-text doc) +tea-cursor-index+ (max 0 index))
  (hscroll-into-view doc))

(defmethod doc-end ((doc mui-document))
  ;; No attribute for the length; POSITION EOF and a read of the index
  ;; answer it, the cursor put back afterwards.
  (let ((was (doc-point doc)))
    (te-command doc "POSITION EOF")
    (let ((end (doc-point doc)))
      (when (/= end was)
        (mui:set-attrs (mdoc-text doc) +tea-cursor-index+ was))
      end)))

(defmethod doc-line-count ((doc mui-document))
  (max 1 (te-get doc +tea-prop-entries+)))

(defmethod doc-index-line ((doc mui-document) index)
  (multiple-value-bind (x y) (index-to-xy doc (max 0 index))
    (values y x)))

(defmethod doc-line-index ((doc mui-document) y)
  (xy-to-index doc 0 (max 0 (min y (last-line doc)))))

(defmethod doc-text ((doc mui-document) start end)
  (if (<= end start)
      (coerce "" 'simple-string)
      (multiple-value-bind (x0 y0) (index-to-xy doc start)
        (multiple-value-bind (x1 y1) (index-to-xy doc end)
          (coerce (take-foreign-string
                   (mui:do-method (mdoc-text doc) +tem-export-block+
                                  +tef-export-block-take-block+ x0 y0 x1 y1))
                  'simple-string)))))

(defmethod doc-lines-text ((doc mui-document) y0 y1)
  (let* ((last (last-line doc))
         (y0 (max 0 (min y0 last)))
         (y1 (max y0 (min y1 last))))
    (coerce (take-foreign-string
             (mui:do-method (mdoc-text doc) +tem-export-block+
                            (logior +tef-export-block-take-block+
                                    +tef-export-block-full-lines+)
                            0 y0 0 y1))
            'simple-string)))

(defmethod doc-insert ((doc mui-document) text)
  (ffi:with-foreign-string (p text)
    (mui:do-method (mdoc-text doc) +tem-insert-text+ p +tev-insert-text-cursor+))
  (hscroll-into-view doc))

(defun mark-range (doc start end)
  (multiple-value-bind (x0 y0) (index-to-xy doc start)
    (multiple-value-bind (x1 y1) (index-to-xy doc end)
      (mui:do-method (mdoc-text doc) +tem-mark-text+ x0 y0 x1 y1))))

(defmethod doc-delete ((doc mui-document) start end)
  (when (> end start)
    (mark-range doc start end)
    ;; ERASE deletes the block without touching the clipboard.
    (te-command doc "ERASE")
    (doc-set-point doc start)))

(defmethod doc-move ((doc mui-document) motion)
  (te-command doc (ecase motion
                    (:left "CURSOR LEFT") (:right "CURSOR RIGHT")
                    (:up "CURSOR UP") (:down "CURSOR DOWN")
                    (:line-start "POSITION SOL") (:line-end "POSITION EOL")
                    (:text-start "POSITION SOF") (:text-end "POSITION EOF")
                    (:next-word "NEXT WORD") (:previous-word "PREVIOUS WORD")
                    (:next-page "NEXT PAGE") (:previous-page "PREVIOUS PAGE"))))

(defmethod doc-edit ((doc mui-document) operation)
  (te-command doc (ecase operation
                    (:delete "DELETE") (:backspace "BACKSPACE")
                    (:undo "UNDO") (:redo "REDO")
                    (:select-all "SELECTALL") (:select-none "SELECTNONE"))))

(defmethod doc-clipboard-copy ((doc mui-document) start end cut)
  (when (> end start)
    (mark-range doc start end)
    (te-command doc (if cut "CUT" "COPY"))))

(defun block-bounds (doc)
  "START and END, as indices, of the block the class shows marked; NIL
without one."
  (let ((out (ffi:alloc-foreign 16)))
    (unwind-protect
         (progn
           (dotimes (i 4)
             (ffi:poke-u32 out 0 (* 4 i)))
           (when (/= 0 (mui:do-method (mdoc-text doc) +tem-block-info+
                                      out (ffi:pointer+ out 4)
                                      (ffi:pointer+ out 8) (ffi:pointer+ out 12)))
             (let ((a (xy-to-index doc (ffi:peek-i32 out 0) (ffi:peek-i32 out 4)))
                   (b (xy-to-index doc (ffi:peek-i32 out 8) (ffi:peek-i32 out 12))))
               (values (min a b) (max a b)))))
      (ffi:free-foreign out))))

(defmethod doc-selection-anchor ((doc mui-document))
  (multiple-value-bind (start end) (block-bounds doc)
    (and start
         (/= start end)
         (if (= (doc-point doc) end) start end))))

;;; The clipboard's text is an IFF FORM FTXT with the characters in its
;;; CHRS chunks (clipboard unit 0), read and written through iffparse.
;;; A clipboard that holds no text, or none at all, reads as NIL; a
;;; failed write is the clipboard's loss and nothing else.

(defmethod doc-clipboard-text ((doc mui-document))
  (handler-case
      (let ((chrs (amiga.iff:string-id "CHRS"))
            (parts '()))
        (amiga.iff:with-iff (in :clipboard :direction :read)
          (loop
            (let ((step (amiga.iff:parse-step in)))
              (when (eq step :eof)
                (return))
              (when (eq step :chunk)
                (multiple-value-bind (id type size) (amiga.iff:current-chunk in)
                  (declare (ignore type))
                  (when (and (= id chrs) (> size 0))
                    (let ((data (make-array size :element-type '(unsigned-byte 8))))
                      (amiga.iff:read-chunk-bytes in data)
                      (push (map 'string #'code-char data) parts))))))))
        (and parts
             (coerce (apply #'concatenate 'string (nreverse parts))
                     'simple-string)))
    (error () nil)))

(defmethod doc-clipboard-set ((doc mui-document) text)
  (when (string/= text "")
    (handler-case
        (amiga.iff:with-iff (out :clipboard :direction :write)
          (amiga.iff:push-chunk out "FTXT" "FORM")
          (amiga.iff:push-chunk out nil "CHRS")
          (amiga.iff:write-chunk-bytes out text)
          (amiga.iff:pop-chunk out)
          (amiga.iff:pop-chunk out)
          t)
      (error () nil))))

;;; ------------------------------------------------------------------
;;; Presentation
;;; ------------------------------------------------------------------

(defun set-message-line (doc text)
  (setf (mdoc-message-text doc) text)
  (mui:set-attrs (mdoc-msgline doc) m:+muia-text-contents+
                 (store-string (mdoc-message-buf doc) text)))

(defmethod doc-message ((doc mui-document) text)
  (set-message-line doc text))

(defmethod doc-message-text ((doc mui-document))
  (mdoc-message-text doc))

(defmethod doc-widget-command ((doc mui-document) command)
  "MUIM_TextEditor_ARexxCmd: FALSE, TRUE, or a string the class AllocVec'd."
  (let ((r (ffi:with-foreign-string (p command)
             (mui:do-method (mdoc-text doc) +tem-arexx-cmd+ p))))
    (cond ((zerop r) nil)
          ((= r 1) t)
          (t (take-foreign-string r)))))

(defmethod doc-beep ((doc mui-document))
  (intui:display-beep nil))

(defmacro with-changed-flag ((doc) &body body)
  "SetBlock counts as an edit as far as the class is concerned: colour is
presentation, not content, so the flag is put back afterwards."
  (let ((d (gensym "DOC")) (was (gensym "WAS")) (run (gensym "RUN")))
    ;; Held once around a whole repaint (REDISPLAY-DOCUMENT), where each
    ;; SetBlock would otherwise read and write the flag for itself.
    `(let ((,d ,doc))
       (flet ((,run () ,@body))
         (if (mdoc-flag-held ,d)
             (,run)
             (let ((,was (te-get ,d +tea-has-changed+)))
               (setf (mdoc-flag-held ,d) t)
               (unwind-protect (,run)
                 (setf (mdoc-flag-held ,d) nil)
                 (mui:set-attrs (mdoc-text ,d) +tea-has-changed+ (/= ,was 0)))))))))

(defun set-block-colour (doc y x0 x1 value)
  "SetBlock colour VALUE (COLOUR-VALUE's scale) on columns X0 to X1 of line Y."
  (mui:do-method (mdoc-text doc) +tem-set-block+ x0 y x1 y
                 +tef-set-block-color+ value))

(defmethod doc-colour ((doc mui-document) y x0 x1 colour)
  (with-changed-flag (doc)
    (set-block-colour doc y x0 x1
                      (colour-value colour (mui-editor-text-pen-p (doc-editor doc))))))

(defun clear-text-colours (doc)
  "Every line of DOC back to the class's own text pen and no token colours:
SetBlock's value 0, which DOC-COLOUR cannot say -- its NIL is the theme's
text pen.  For a document that left Lisp mode while it was painted in the
theme's colours: the colouring no longer runs on it, and the theme's light
text would stay on the standard background."
  (let ((text (doc-text doc 0 (doc-end doc)))
        (y 0))
    (with-quiet-display (doc)
      (with-changed-flag (doc)
        (do-text-lines (line text)
          (when (plusp (length line))
            (set-block-colour doc y 0 (length line) 0))
          (incf y))))))

(defmethod doc-call-quietly ((doc mui-document) function)
  (mui:set-attrs (mdoc-text doc) +tea-quiet+ t)
  (unwind-protect (funcall function)
    (mui:set-attrs (mdoc-text doc) +tea-quiet+ nil)))

(defun update-status (doc)
  "`*name  PACKAGE  line:column  (arglist)' in the status line.  The
arglist of the operator at point rides at the end, where a long one is
cut off rather than pushing the rest out of view."
  (let ((arglist (mdoc-arglist doc)))
    (mui:set-attrs (mdoc-status doc) m:+muia-text-contents+
                   (store-string (mdoc-status-buf doc)
                                 (format nil "~A~A  ~A  ~D:~D~A~A"
                                         (if (doc-modified-p doc) "*" " ")
                                         (doc-name doc)
                                         (mdoc-package doc)
                                         (1+ (te-get doc +tea-cursor-y+))
                                         (1+ (te-get doc +tea-cursor-x+))
                                         (if (string= arglist "") "" "  ")
                                         arglist)))))

(defmethod doc-show-arglist ((doc mui-document) text)
  (setf (mdoc-arglist doc) text)
  (update-status doc))

;;; ------------------------------------------------------------------
;;; The minibuffer's part
;;; ------------------------------------------------------------------

(defun set-label (doc text)
  "The prompt label is sized to its text, and MUI measures a Text object
only when its group is laid out: a new label needs the row relaid, under
InitChange/ExitChange.  Unchanged text is left alone, so isearch does not
relayout on every keystroke."
  (unless (string= (mdoc-label-text doc) text)
    (setf (mdoc-label-text doc) text)
    (let ((contents (store-string (mdoc-label-buf doc) text)))
      (cond ((/= 0 (mui:do-method (mdoc-miniline doc) m:+muim-group-init-change+))
             (mui:set-attrs (mdoc-prompt doc) m:+muia-text-contents+ contents)
             (mui:do-method (mdoc-miniline doc) m:+muim-group-exit-change+)
             ;; The relayout re-shows the row and the String comes back
             ;; inactive while the window still names it: take the focus
             ;; away and give it back, or every further key is lost.
             (when (minibuffer-open-p doc)
               (mui:set-attrs (mdoc-window doc) m:+muia-window-active-object+
                              m:+muiv-window-active-object-none+)
               (mui:set-attrs (mdoc-window doc) m:+muia-window-active-object+
                              (mdoc-mini doc))))
            (t
             (mui:set-attrs (mdoc-prompt doc) m:+muia-text-contents+ contents))))))

(defmethod doc-open-minibuffer ((doc mui-document) label initial)
  ;; The prompt IS what the echo area shows, so the port's STATUS reports
  ;; it too.  The page is switched before the label is set so that the row
  ;; being relaid is the one on show.
  (setf (mdoc-message-text doc) label)
  (mui:set-attrs (mdoc-echo doc) m:+muia-group-active-page+ 1)
  (set-label doc label)
  (doc-set-minibuffer-text doc initial)
  (mui:set-attrs (mdoc-window doc) m:+muia-window-active-object+ (mdoc-mini doc)))

(defmethod doc-close-minibuffer ((doc mui-document))
  (mui:set-attrs (mdoc-window doc) m:+muia-window-active-object+ (mdoc-text doc))
  (mui:set-attrs (mdoc-echo doc) m:+muia-group-active-page+ 0)
  (set-message-line doc "")
  (doc-set-minibuffer-text doc "")
  ;; Cleared on the hidden page without a relayout; the next prompt relays
  ;; it once it is on show again.
  (setf (mdoc-label-text doc) "")
  (mui:set-attrs (mdoc-prompt doc) m:+muia-text-contents+
                 (store-string (mdoc-label-buf doc) "")))

(defmethod doc-minibuffer-text ((doc mui-document))
  (or (mui:get-attr-string m:+muia-string-contents+ (mdoc-mini doc)) ""))

(defmethod doc-set-minibuffer-text ((doc mui-document) text)
  ;; The String class copies its contents.
  (ffi:with-foreign-string (p text)
    (mui:set-attrs (mdoc-mini doc) m:+muia-string-contents+ p)))

(defmethod doc-set-minibuffer-label ((doc mui-document) label)
  (setf (mdoc-message-text doc) label)
  (set-label doc label))

(defmethod doc-minibuffer-edit ((doc mui-document) key)
  ;; The String's contents notification runs when the contents are set,
  ;; as it does for typing -- an isearch prompt searches as the pattern
  ;; grows -- so MINIBUFFER-CHANGED must not be called here a second time.
  (let ((text (doc-minibuffer-text doc)))
    (cond ((eql key +key-return+)
           (minibuffer-done doc)
           t)
          ((printable-key-p key)
           (doc-set-minibuffer-text
            doc (concatenate 'string text (string (code-char (key-code key)))))
           t)
          ((and (eql key +key-backspace+) (string/= text ""))
           (doc-set-minibuffer-text doc (subseq text 0 (1- (length text))))
           t)
          (t nil))))

(defmethod doc-search ((doc mui-document) pattern backwards again)
  (ffi:with-foreign-string (p pattern)
    (/= 0 (mui:do-method (mdoc-text doc) +tem-search+ p
                         (logior (if backwards +tef-search-backwards+ 0)
                                 (if again +tef-search-next+ 0))))))

;;; ------------------------------------------------------------------
;;; Files and windows
;;; ------------------------------------------------------------------

(defmethod doc-set-text ((doc mui-document) text)
  (ffi:with-foreign-string (p text)
    (mui:set-attrs (mdoc-text doc) +tea-contents+ p))
  (mui:set-attrs (mdoc-text doc) +tea-has-changed+ nil)
  (doc-set-point doc 0))

(defmethod doc-modified-p ((doc mui-document))
  (/= 0 (te-get doc +tea-has-changed+)))

(defmethod doc-set-modified ((doc mui-document) flag)
  (mui:set-attrs (mdoc-text doc) +tea-has-changed+ (and flag t))
  (update-status doc))

(defmethod doc-set-title ((doc mui-document) title)
  (mui:set-attrs (mdoc-window doc) m:+muia-window-title+
                 (store-string (mdoc-title-buf doc) title)))

(defmethod doc-ask-file ((doc mui-document) title save initial)
  "The ASL file requester, through MUI so it opens on the editor's screen,
in INITIAL's drawer with its file part (\"\" for a directory) in the file
gadget."
  (let ((req (mui:with-tags (tags) (m:mui-alloc-asl-request asl:+asl-file-request+ tags))))
    (when req
      (unwind-protect
           (ffi:with-foreign-string (ftitle title)
             (ffi:with-foreign-string (fdrawer (path-directory initial))
               (ffi:with-foreign-string (ffile (path-basename initial))
                 (mui:with-tags (tags asl:+aslfr-title-text+ ftitle
                                      asl:+aslfr-do-save-mode+ (and save t)
                                      asl:+aslfr-initial-drawer+ fdrawer
                                      asl:+aslfr-initial-file+ ffile
                                      asl:+aslfr-window+ (mui:get-attr-pointer m:+muia-window-window+
                                                                               (mdoc-window doc)))
                   (when (m:mui-asl-request req tags)
                     (let ((drawer (ffi:foreign-to-string
                                    (ffi:make-foreign-pointer (ffi:peek-u32 req +fr-drawer-offset+))))
                           (file (ffi:foreign-to-string
                                  (ffi:make-foreign-pointer (ffi:peek-u32 req +fr-file-offset+)))))
                       (join-path drawer file)))))))
        (m:mui-free-asl-request req)))))

(defun join-path (drawer file)
  "AddPart: DRAWER/FILE, with no separator after a `:' or an empty drawer."
  (cond ((string= drawer "") file)
        ((let ((last (char drawer (1- (length drawer)))))
           (or (char= last #\:) (char= last #\/)))
         (concatenate 'string drawer file))
        (t (concatenate 'string drawer "/" file))))

(defun choice-label (choice)
  (case choice
    (:save "_Save") (:discard "_Discard") (:cancel "_Cancel")
    (:yes "_Yes") (:no "_No") (:ok "_OK") (:start "_Start")
    (t (string-capitalize (symbol-name choice)))))

(defmethod doc-ask ((doc mui-document) question choices)
  "MUI_Request answers 1 for the first gadget, 2 for the second and 0 for
the rightmost, the cancel position."
  (let* ((editor (doc-editor doc))
         (answer (mui:request (mui-editor-app editor) (mdoc-window doc) "clamacs"
                              (format nil "~{~A~^|~}" (mapcar #'choice-label choices))
                              "%s" question)))
    (if (or (null answer) (zerop answer))
        (car (last choices))
        (nth (1- answer) choices))))

;;; Ticks (1/50 s) since some epoch, wrapping: only differences are used.
(defun ticks-now ()
  (let ((ds (ffi:alloc-foreign 12)))
    (unwind-protect
         (progn
           (dos:date-stamp ds)
           (logand (+ (* (+ (* (ffi:peek-u32 ds 0) 1440) (ffi:peek-u32 ds 4)) 3000)
                      (ffi:peek-u32 ds 8))
                   #xFFFFFFFF))
      (ffi:free-foreign ds))))

;;; How long an activation request outranks activation reports.  MUI 4
;;; delivers Intuition's reports seconds late and more than one request
;;; behind, so a report cannot be matched to a request: the request simply
;;; stands for this long (150 ticks = 3 s).
(defconstant +activate-pending-ticks+ 150)

(defmethod doc-activate ((doc mui-document))
  (let ((editor (doc-editor doc)))
    (setf (mui-editor-active-doc editor) doc
          (mui-editor-activate-pending editor) doc
          (mui-editor-activate-stamp editor) (ticks-now))
    (mui:set-attrs (mdoc-window doc) m:+muia-window-activate+ t)
    (mui:set-attrs (mdoc-window doc) m:+muia-window-active-object+ (mdoc-text doc))))

(defmethod doc-close-window ((doc mui-document))
  "Retire the window now, dispose of it later: this is reached from a
notification hook and, for `C-x k', from inside the MUIM_HandleEvent of the
text object that is about to be freed."
  (let ((editor (doc-editor doc)))
    (mui:set-attrs (mdoc-window doc) m:+muia-window-open+ nil)
    (when (eq (mui-editor-active-doc editor) doc)
      (setf (mui-editor-active-doc editor) nil))
    (when (eq (mui-editor-activate-pending editor) doc)
      (setf (mui-editor-activate-pending editor) nil))
    (wake-loop editor)))

(defun active-document (editor)
  "The document the messages mean: the last activated, else the window
Intuition says is active, else any."
  (let ((docs (live-documents editor)))
    (or (let ((doc (mui-editor-active-doc editor)))
          (and doc (not (doc-closing doc)) doc))
        (find-if (lambda (doc)
                   (/= 0 (or (mui:get-attr m:+muia-window-activate+ (mdoc-window doc)) 0)))
                 docs)
        (first docs))))

(defmethod editor-active-document ((editor mui-editor))
  (active-document editor))

;;; ------------------------------------------------------------------
;;; Window positions (snapshot.lisp): where a window is made, and where
;;; it is.  The windows carry no MUIA_Window_ID on purpose -- MUI's own
;;; snapshot would override the editor's, and MUI 3.8 has no way to take
;;; one from code -- so the layout file is the one place a position
;;; comes from.
;;; ------------------------------------------------------------------

(defun signed32 (unsigned)
  (if (>= unsigned #x80000000) (- unsigned #x100000000) unsigned))

(defun window-place-tags (editor role default-width default-height)
  "The tags a window is created with for its place: the layout's
LeftEdge/TopEdge/Width/Height when it stores ROLE, else the default size."
  (multiple-value-bind (left top width height) (layout-place editor role)
    (if left
        (list m:+muia-window-left-edge+ left m:+muia-window-top-edge+ top
              m:+muia-window-width+ width m:+muia-window-height+ height)
        (list m:+muia-window-width+ default-width
              m:+muia-window-height+ default-height))))

(defun window-geometry (window)
  "Left, top, width and height of WINDOW as MUI answers them for an open
window; NIL when it is NIL or not open."
  (when (and window (/= 0 (or (mui:get-attr m:+muia-window-open+ window) 0)))
    (flet ((attr (attribute)
             (signed32 (or (mui:get-attr attribute window) 0))))
      (values (attr m:+muia-window-left-edge+) (attr m:+muia-window-top-edge+)
              (attr m:+muia-window-width+) (attr m:+muia-window-height+)))))

(defmethod doc-geometry ((doc mui-document))
  (window-geometry (mdoc-window doc)))

(defmethod editor-aux-windows ((editor mui-editor))
  (loop for (role window) in (list (list "errors" (mui-editor-errors-window editor))
                                   (list "inspector" (mui-editor-insp-window editor))
                                   (list "debugger" (mui-editor-dbg-window editor)))
        for geometry = (multiple-value-list (window-geometry window))
        when (first geometry)
          collect (cons role geometry)))

;;; ------------------------------------------------------------------
;;; The menu strip (menu.lisp): one strip for the whole application, so
;;; every window -- documents, the REPL, the debugger, the inspector, the
;;; error list -- shows the same menus, and an item acts on the active
;;; document exactly as the port's EVAL does: through MENU-PICK and
;;; RUN-COMMAND with the table index the item carries in MUIA_UserData.
;;; The Emacs key of an item is shown in the shortcut column as a command
;;; string (MUIA_Menuitem_CommandString): MUI displays it and, as the
;;; autodoc says, does not check for it -- the keys are the Emacs layer's.
;;; ------------------------------------------------------------------

;;; MUIA_UserData of the item at table index I: non-zero, so an action of
;;; 0 -- which MUI reports for items without user data -- is never taken
;;; for the first entry.
(defun menu-item-id (index) (1+ index))
(defun menu-item-index (id) (1- id))

;;; NM_BARLABEL, (STRPTR)-1: a separator, as libraries/gadtools.h spells it.
(defconstant +nm-barlabel+ #xFFFFFFFF)

;;; The dynamic groups this frontend makes items for: the open buffers and
;;; the themes (phase T3 of specs/clamacs-themes.md), one mechanism below.
(defmethod editor-dynamic-groups ((editor mui-editor))
  '(:buffers :themes))

(defun build-menustrip (editor)
  "The strip from the table, or NIL -- with the reason on the console --
when MUI would not build it: the editor still runs, keys and port intact."
  (let ((strip nil))
    (handler-case
        (let* ((entries (menu-entries))
               (items (make-array (length entries) :initial-element nil))
               (menu nil))
          (setq strip (mui:new-object :menustrip))
          (loop for e in entries
                for i from 0
                do (ecase (menu-entry-kind e)
                     (:title
                      ;; A title nothing is drawn under is no menu: MENU
                      ;; stays NIL until the next title.
                      (cond ((menu-entry-drawn-p editor i)
                             (setq menu (mui:new-object :menu m:+muia-menu-title+ (menu-entry-title e)))
                             (mui:do-method strip m:+muim-family-add-tail+ menu))
                            (t (setq menu nil))))
                     (:bar
                      (when menu
                        (mui:do-method menu m:+muim-family-add-tail+
                                       (mui:new-object :menuitem
                                                       m:+muia-menuitem-title+ +nm-barlabel+))))
                     (:dynamic
                      ;; The group's items go into the menu, or into a
                      ;; submenu of the entry's title (View > Themes): a
                      ;; Menuitem with children is a submenu, and a
                      ;; Family method adds to either.  A group this
                      ;; frontend does not draw (the minimap's, the
                      ;; host's alone) gets no items and no DYN-GROUP.
                      (when (and menu (menu-entry-drawn-p editor i))
                        (let ((group (make-dyn-group (menu-entry-dynamic e)
                                                     (1+ (length (mui-editor-dyn-groups editor))))))
                          (setf (dyn-group-menu group)
                                (if (menu-entry-title e)
                                    (let ((sub (mui:new-object :menuitem
                                                               m:+muia-menuitem-title+ (menu-entry-title e))))
                                      (mui:do-method menu m:+muim-family-add-tail+ sub)
                                      sub)
                                    menu))
                          (setf (mui-editor-dyn-groups editor)
                                (append (mui-editor-dyn-groups editor) (list group))))))
                     (:item
                      (when menu
                       (let ((item (if (menu-entry-keys e)
                                      (mui:new-object :menuitem
                                                      m:+muia-menuitem-title+ (menu-entry-title e)
                                                      m:+muia-menuitem-shortcut+ (menu-entry-keys e)
                                                      m:+muia-menuitem-command-string+ t
                                                      m:+muia-user-data+ (menu-item-id i))
                                      (mui:new-object :menuitem
                                                      m:+muia-menuitem-title+ (menu-entry-title e)
                                                      m:+muia-user-data+ (menu-item-id i)))))
                        (mui:do-method menu m:+muim-family-add-tail+ item)
                        (setf (aref items i) item))))))
          (setf (mui-editor-menustrip editor) strip
                (mui-editor-menu-items editor) items
                (mui-editor-menu-enabled editor)
                (make-array (length entries) :initial-element :unknown))
          strip)
      (error (e)
        ;; The children added so far go with the strip.
        (when strip (ignore-errors (mui:dispose-object strip)))
        (setf (mui-editor-menustrip editor) nil
              (mui-editor-menu-items editor) nil
              (mui-editor-dyn-groups editor) '())
        (format *error-output* "clamacs: the menu strip could not be built (~A) -- running without menus~%" e)
        nil))))

(defun attach-menustrip (editor)
  "MUIA_Application_MenuAction carries the picked item's MUIA_UserData."
  (when (mui-editor-menustrip editor)
    (mui:notify (mui-editor-app editor) m:+muia-application-menu-action+ :every-time
                :self m:+muim-call-hook+
                (mui:pool-hook (lambda (hook object message)
                                 (declare (ignore hook object))
                                 (let ((id (ffi:peek-u32 message 0)))
                                   (if (>= id +dynamic-item-id-base+)
                                       (dynamic-item-picked editor id)
                                       (menu-pick editor (menu-item-index id))))
                                 (let ((doc (editor-active-document editor)))
                                   (when (typep doc 'mui-document)
                                     (show-region doc)))
                                 (after-command editor)
                                 0))
                :trigger-value)
    (menu-update editor)))

(defun menu-update (editor)
  "MUIA_Menuitem_Enabled of every item in step with MENU-STATE, set only
where it changed.  Cheap enough to run after every command, activation,
reply and debugger message -- which is how it is called, since there is no
notification for \"the active document changed\" and polling at those
points is the honest way."
  (let ((items (mui-editor-menu-items editor)))
    (when (and items (mui-editor-app editor) (not (editor-quitting editor)))
      (let ((enabled (mui-editor-menu-enabled editor)))
        (loop for flag in (menu-enabled-items editor)
              for i from 0
              for want = (and flag t)
              for item = (aref items i)
              when (and item (not (eq want (aref enabled i))))
                do (mui:set-attrs item m:+muia-menuitem-enabled+ want)
                   (setf (aref enabled i) want))))))

;;; The dynamic groups (menu.lisp's DYNAMIC-MENU): the Buffers menu and
;;; the View menu's themes.  Their items are made and disposed as buffers
;;; and themes come and go, so they carry ids of their own above the
;;; table's (DYN-GROUP-ITEM-ID), and everything below is written once over
;;; the group.

(defun dynamic-item-picked (editor id)
  (multiple-value-bind (group n) (dyn-group-of-id editor id)
    (when group
      ;; Intuition ticks a picked CHECKIT item itself: say what is ticked now.
      (setf (dyn-group-checked group) :unknown)
      (let ((objects (dyn-group-objects group)))
        (when (< -1 n (length objects))
          (dynamic-menu-pick editor (dyn-group-which group) (aref objects n)))))))

(defun free-dynamic-items (group)
  "Take GROUP's items out of its menu and dispose of them, with their
titles."
  (let ((menu (dyn-group-menu group)))
    (dolist (entry (dyn-group-items group))
      (mui:do-method menu m:+muim-family-remove+ (car entry))
      (mui:dispose-object (car entry))
      (when (cdr entry) (ffi:free-foreign (cdr entry))))
    (setf (dyn-group-items group) '()
          (dyn-group-shown group) '()
          (dyn-group-objects group) #()
          (dyn-group-checked group) :unknown)))

(defun rebuild-dynamic-items (editor group want ticked)
  (let* ((strip (mui-editor-menustrip editor))
         (menu (dyn-group-menu group))
         (objects (make-array (count-if #'consp want)))
         ;; MUI 4 wants a live strip's changes bracketed; MUI 3 makes them
         ;; as they come and does not know the method (it answers 0).
         (bracketed (/= 0 (mui:do-method strip m:+muim-menustrip-init-change+))))
    (unwind-protect
         (let ((n 0))
           (free-dynamic-items group)
           (dolist (e want)
             (let ((entry
                     (if (eq e :bar)
                         (cons (mui:new-object :menuitem m:+muia-menuitem-title+ +nm-barlabel+)
                               nil)
                         (let ((title (ffi:foreign-string (car e))))
                           (cons (handler-case
                                     (mui:new-object :menuitem
                                                     m:+muia-menuitem-title+ title
                                                     m:+muia-menuitem-checkit+ t
                                                     m:+muia-menuitem-checked+ (eq (cdr e) ticked)
                                                     m:+muia-user-data+ (dyn-group-item-id group n))
                                   (error (c) (ffi:free-foreign title) (error c)))
                                 title)))))
               (mui:do-method menu m:+muim-family-add-tail+ (car entry))
               (push entry (dyn-group-items group))
               (when (consp e)
                 (setf (aref objects n) (cdr e))
                 (incf n))))
           (setf (dyn-group-shown group) want
                 (dyn-group-objects group) objects
                 (dyn-group-checked group) ticked))
      (when bracketed
        (mui:do-method strip m:+muim-menustrip-exit-change+)))))

(defun dynamic-menu-sync (editor group)
  "GROUP's menu in step with DYNAMIC-MENU, the right item ticked.  Only
from the event loop, never from a hook: remaking the items remakes
Intuition's menu strip, and MUI may still be walking the picked items of
the old one when the MenuAction hook runs."
  (multiple-value-bind (want ticked) (dynamic-menu editor (dyn-group-which group))
    (cond ((not (dynamic-menu-equal want (dyn-group-shown group)))
           (handler-case (rebuild-dynamic-items editor group want ticked)
             (error (e)
               ;; Not again until the entries change: the loop runs this
               ;; after every input event.
               (setf (dyn-group-shown group) want)
               (format *error-output* "clamacs: the ~A menu could not be made (~A)~%"
                       (dyn-group-which group) e))))
          ((not (eq ticked (dyn-group-checked group)))
           (loop for entry in (reverse (dyn-group-items group))
                 for e in want
                 when (consp e)
                   do (mui:set-attrs (car entry) m:+muia-menuitem-checked+ (eq (cdr e) ticked)))
           (setf (dyn-group-checked group) ticked)))))

(defun dynamic-menus-sync (editor)
  "Every dynamic group in step: after every input event and mailbox drain."
  (when (and (mui-editor-app editor) (not (editor-quitting editor)))
    (dolist (group (mui-editor-dyn-groups editor))
      (dynamic-menu-sync editor group))))

;;; The port's BUFFERS and THEMES read the items back from MUI, and pick
;;; through the id an item carries, so drive.rexx checks what the menu
;;; shows and the id the MenuAction hook would get.  The port's verbs run
;;; from the mailbox, not inside a menu pick, so the menu is brought up to
;;; date first.
(defun live-dyn-group (editor which)
  (and (mui-editor-app editor) (not (editor-quitting editor))
       (dyn-group editor which)))

(defmethod editor-dynamic-menu-lines ((editor mui-editor) which)
  (let ((group (live-dyn-group editor which)))
    (if (null group)
        (call-next-method)
        (progn
          (dynamic-menu-sync editor group)
          (loop for (item . title) in (reverse (dyn-group-items group))
                collect (if (null title)
                            "-"
                            (format nil "~A ~A"
                                    (if (/= 0 (or (mui:get-attr m:+muia-menuitem-checked+ item) 0))
                                        ">" " ")
                                    (mui:get-attr-string m:+muia-menuitem-title+ item))))))))

(defmethod editor-dynamic-menu-pick ((editor mui-editor) which label)
  (let ((group (live-dyn-group editor which)))
    (if (null group)
        (call-next-method)
        (progn
          (dynamic-menu-sync editor group)
          (let ((entry (find-if (lambda (entry)
                                  (and (cdr entry)
                                       (equal (mui:get-attr-string m:+muia-menuitem-title+ (car entry))
                                              label)))
                                (dyn-group-items group))))
            (and entry
                 (dynamic-item-picked
                  editor (mui:get-attr m:+muia-user-data+ (car entry)))))))))

;;; ------------------------------------------------------------------
;;; About and the HyperSpec (menu.lisp)
;;; ------------------------------------------------------------------

(defmethod editor-toolkit-lines ((editor mui-editor))
  (let ((base (amiga:open-library "muimaster.library" 0)))
    (list (if (and base (not (ffi:null-pointer-p base)))
              (unwind-protect
                   (format nil "muimaster.library ~D.~D"
                           (ffi:peek-u16 base 20) (ffi:peek-u16 base 22))
                (amiga:close-library base))
              "muimaster.library (not open)")
          (format nil "TextEditor.mcc ~D.~D"
                  (mui-editor-te-version editor) (mui-editor-te-revision editor)))))

(defmethod editor-memory-lines ((editor mui-editor))
  (flet ((avail (flags) (amiga.exec:avail-mem flags)))
    (list (format nil "Free:  ~:D bytes (chip ~:D, fast ~:D)"
                  (avail amiga.exec:+memf-any+)
                  (avail amiga.exec:+memf-chip+)
                  (avail amiga.exec:+memf-fast+))
          (format nil "Largest free block: ~:D bytes"
                  (avail amiga.exec:+memf-largest+)))))

;;; URL_OpenA(url, tags) is openurl.library's first function -- `##bias
;;; 30', url in a0, the tag list in a1 -- on every platform OpenURL exists
;;; for; neither toolchain ships its headers, so the one entry is called
;;; by offset.  The library knows which browser is configured, talks to a
;;; running one over ARexx and starts one otherwise.  It is opened per
;;; call: opening a URL is a rare act, and a base held for the session
;;; would keep OpenURL and its prefs resident on a machine where memory
;;; is the constraint.
(defconstant +lvo-url-open-a+ -30)

(defmethod doc-open-url ((doc mui-document) url)
  (let ((base (amiga:open-library "openurl.library" 0)))
    (cond ((or (null base) (ffi:null-pointer-p base)) :missing)
          (t
           (unwind-protect
                (if (/= 0 (ffi:with-foreign-string (s url)
                            (amiga:call-library base +lvo-url-open-a+ (list :a0 s :a1 nil))))
                    :opened
                    :refused)
             (amiga:close-library base))))))

;;; ------------------------------------------------------------------
;;; The diagnostics window: a plain MUI List, deliberately -- a fancier
;;; widget would add a second MCC dependency to the release for no gain.
;;; Selecting a row jumps to the file and line, which is the whole feature.
;;; ------------------------------------------------------------------

(defun list-active-row (list)
  "MUIA_List_Active as a row, or NIL for MUIV_List_Active_Off (-1, which
GetAttr hands back unsigned)."
  (let ((active (or (mui:get-attr m:+muia-list-active+ list) #xFFFFFFFF)))
    (and (< active #x80000000) active)))

(defun ensure-errors-window (editor)
  (or (mui-editor-errors-window editor)
      (let* ((list (mui:new-object :list
                                   m:+muia-frame+ m:+muiv-frame-input-list+
                                   m:+muia-list-construct-hook+ m:+muiv-list-construct-hook-string+
                                   m:+muia-list-destruct-hook+ m:+muiv-list-destruct-hook-string+))
             (window (apply #'mui:new-object :window
                            m:+muia-window-title+ "clamacs diagnostics"
                            m:+muia-window-root-object+
                            (mui:new-object :listview m:+muia-listview-list+ list)
                            (window-place-tags editor "errors"
                                               (mui:window-size-visible 60)
                                               (mui:window-size-visible 25)))))
        (setf (mui-editor-errors-window editor) window
              (mui-editor-errors-list editor) list)
        (mui:do-method (mui-editor-app editor) intui:+om-addmember+ window)
        ;; The close gadget only closes: the rows stay for `C-c ! l'.
        (mui:notify window m:+muia-window-close-request+ t
                    window m:+muim-set+ m:+muia-window-open+ nil)
        (mui:notify list m:+muia-list-active+ :every-time
                    :application m:+muim-call-hook+
                    (mui:pool-hook (lambda (hook object message)
                                     (declare (ignore hook object message))
                                     (unless (mui-editor-selecting editor)
                                       (let ((row (list-active-row list))
                                             (wire (editor-wire editor)))
                                         (when (and row wire)
                                           (diagnostic-jump wire row)
                                           (after-command editor))))
                                     0)))
        window)))

(defmethod editor-show-diagnostics ((editor mui-editor) rows &key open)
  (let* ((window (ensure-errors-window editor))
         (list (mui-editor-errors-list editor)))
    (mui:set-attrs list m:+muia-list-quiet+ t)
    (mui:do-method list m:+muim-list-clear+)
    (dolist (row rows)
      (ffi:with-foreign-string (s row)
        (mui:do-method list m:+muim-list-insert-single+ s m:+muiv-list-insert-bottom+)))
    ;; Setting Active would fire the notification and jump somewhere the
    ;; user did not ask to go: the list comes up with nothing selected.
    (editor-select-diagnostic editor nil)
    (mui:set-attrs list m:+muia-list-quiet+ nil)
    (when (or open rows)
      (mui:set-attrs window m:+muia-window-open+ t))))

(defmethod editor-select-diagnostic ((editor mui-editor) row)
  (let ((list (mui-editor-errors-list editor)))
    (when list
      (setf (mui-editor-selecting editor) t)
      (unwind-protect
           (mui:set-attrs list m:+muia-list-active+ (or row m:+muiv-list-active-off+))
        (setf (mui-editor-selecting editor) nil)))))

;;; ------------------------------------------------------------------
;;; The debugger and inspector windows: the faces of debugger.lisp and
;;; inspector.lisp, plain MUI Lists and buttons as the diagnostics window
;;; is.  The state lives over there; these methods only show it, and the
;;; hooks hand a row number or a line of text back.
;;; ------------------------------------------------------------------

(defun fill-list (list rows)
  "ROWS, one string each, as the entries of LIST; nothing selected."
  (mui:set-attrs list m:+muia-list-quiet+ t)
  (mui:do-method list m:+muim-list-clear+)
  (dolist (row rows)
    (ffi:with-foreign-string (s row)
      (mui:do-method list m:+muim-list-insert-single+ s m:+muiv-list-insert-bottom+)))
  (mui:set-attrs list m:+muia-list-active+ m:+muiv-list-active-off+)
  (mui:set-attrs list m:+muia-list-quiet+ nil))

(defun make-string-list (&optional read-only)
  (mui:new-object :list
                  m:+muia-frame+ (if read-only m:+muiv-frame-read-list+ m:+muiv-frame-input-list+)
                  m:+muia-list-construct-hook+ m:+muiv-list-construct-hook-string+
                  m:+muia-list-destruct-hook+ m:+muiv-list-destruct-hook-string+))

(defun make-listview (list &optional double-click)
  (if double-click
      (mui:new-object :listview m:+muia-listview-double-click+ t m:+muia-listview-list+ list)
      (mui:new-object :listview m:+muia-listview-list+ list)))

(defun make-framed-group (title weight child)
  (mui:new-object :group
                  m:+muia-frame+ m:+muiv-frame-group+
                  m:+muia-frame-title+ title
                  m:+muia-weight+ weight
                  m:+muia-group-child+ child))

(defun make-button (label control-char)
  "MUI's KeyButton: a centred Text with a button frame and a keyboard
shortcut."
  (mui:new-object :text
                  m:+muia-frame+ m:+muiv-frame-button+
                  m:+muia-background+ m:+muii-button-back+
                  m:+muia-input-mode+ m:+muiv-input-mode-rel-verify+
                  m:+muia-text-contents+ label
                  m:+muia-text-pre-parse+ (format nil "~Cc" (code-char 27))
                  m:+muia-control-char+ (char-code control-char)
                  m:+muia-cycle-chain+ t))

(defun app-hook (editor function)
  "A MUIM_CallHook hook that runs FUNCTION (of no arguments) on the
application's task and lets the loop carry out a quit it asked for."
  (mui:pool-hook (lambda (hook object message)
                   (declare (ignore hook object message))
                   (funcall function)
                   (after-command editor)
                   0)))

(defun on-notify (editor object attribute trigger function)
  (mui:notify object attribute trigger :application m:+muim-call-hook+
              (app-hook editor function)))

(defun dispose-aux-window (editor window what)
  "An auxiliary window at exit: closed, taken out of the application and
disposed of, as DISPOSE-ERRORS-WINDOW does (an orphan window otherwise,
on MUI 3.8)."
  (when window
    (mui:set-attrs window m:+muia-window-open+ nil)
    (mui:do-method (mui-editor-app editor) intui:+om-remmember+ window)
    (dispose-window-object editor window what)))

;;; --- the debugger

(defun ensure-debugger-window (editor)
  (or (mui-editor-dbg-window editor)
      (let* ((title-buf (ffi:alloc-foreign +string-buffer-size+))
             (condition-buf (ffi:alloc-foreign +wide-buffer-size+))
             (condition (mui:new-object :text
                                        m:+muia-text-contents+ (store-text condition-buf +wide-buffer-size+ "")
                                        m:+muia-text-set-min+ nil
                                        m:+muia-frame+ m:+muiv-frame-text+
                                        m:+muia-background+ m:+muii-text-back+))
             (restarts (make-string-list))
             (frames (make-string-list))
             (locals (make-string-list t))
             ;; A double-click is the Listview's attribute, not the List's.
             (restarts-view (make-listview restarts t))
             (frames-view (make-listview frames t))
             (evalstr (mui:new-object :string
                                      m:+muia-frame+ m:+muiv-frame-string+
                                      m:+muia-string-max-len+ 256
                                      m:+muia-cycle-chain+ t))
             (invoke-btn (make-button "Invoke restart" #\i))
             (continue-btn (make-button "Continue" #\c))
             (abort-btn (make-button "Abort" #\a))
             (window (apply
                      #'mui:new-object
                      :window
                      m:+muia-window-title+ (store-string title-buf "clamacs debugger")
                      (append
                       (window-place-tags editor "debugger"
                                          (mui:window-size-visible 60)
                                          (mui:window-size-visible 60))
                       (list
                      m:+muia-window-root-object+
                      (mui:new-object
                       :group
                       m:+muia-group-child+ condition
                       m:+muia-group-child+ (make-framed-group "Restarts" 40 restarts-view)
                       m:+muia-group-child+ (make-framed-group "Backtrace" 100 frames-view)
                       m:+muia-group-child+ (make-framed-group "Locals" 60 (make-listview locals))
                       m:+muia-group-child+
                       (mui:new-object :group m:+muia-group-horiz+ t
                                       m:+muia-group-child+ (mui:new-object :text
                                                                            m:+muia-text-contents+ "Eval in frame:"
                                                                            m:+muia-text-set-min+ t
                                                                            m:+muia-weight+ 0)
                                       m:+muia-group-child+ evalstr)
                       m:+muia-group-child+
                       (mui:new-object :group m:+muia-group-horiz+ t
                                       m:+muia-group-child+ invoke-btn
                                       m:+muia-group-child+ continue-btn
                                       m:+muia-group-child+ abort-btn)))))))
        (setf (mui-editor-dbg-window editor) window
              (mui-editor-dbg-condition-obj editor) condition
              (mui-editor-dbg-restarts editor) restarts
              (mui-editor-dbg-frames editor) frames
              (mui-editor-dbg-locals editor) locals
              (mui-editor-dbg-evalstr editor) evalstr
              (mui-editor-dbg-continue-btn editor) continue-btn
              (mui-editor-dbg-title-buf editor) title-buf
              (mui-editor-dbg-condition-buf editor) condition-buf)
        (mui:do-method (mui-editor-app editor) intui:+om-addmember+ window)
        (on-notify editor window m:+muia-window-close-request+ t
                   (lambda () (debug-window-closed editor)))
        ;; Selecting a frame asks for its locals; a double-click opens its
        ;; source.  Selecting a restart does nothing; a double-click or the
        ;; Invoke button invokes it.
        (on-notify editor frames m:+muia-list-active+ :every-time
                   (lambda ()
                     (unless (mui-editor-dbg-selecting editor)
                       (debug-frame-selected editor (list-active-row frames)))))
        (on-notify editor frames-view m:+muia-listview-double-click+ t
                   (lambda () (debug-frame-clicked editor (list-active-row frames))))
        (on-notify editor restarts-view m:+muia-listview-double-click+ t
                   (lambda () (debug-restart-clicked editor (list-active-row restarts))))
        (on-notify editor invoke-btn m:+muia-pressed+ nil
                   (lambda () (debug-restart-clicked editor (list-active-row restarts))))
        (on-notify editor continue-btn m:+muia-pressed+ nil
                   (lambda () (debug-continue-clicked editor)))
        (on-notify editor abort-btn m:+muia-pressed+ nil
                   (lambda () (debug-abort-clicked editor)))
        ;; RET in the eval line: the form goes to the selected frame and
        ;; the line is cleared (the String copies what it is set to).
        (on-notify editor evalstr m:+muia-string-acknowledge+ :every-time
                   (lambda ()
                     (let ((text (or (mui:get-attr-string m:+muia-string-contents+ evalstr) "")))
                       (ffi:with-foreign-string (empty "")
                         (mui:set-attrs evalstr m:+muia-string-contents+ empty))
                       (debug-eval-entered editor text))))
        window)))

(defmethod editor-debugger-open ((editor mui-editor) dbg)
  (let ((window (ensure-debugger-window editor)))
    (mui:set-attrs (mui-editor-dbg-condition-obj editor) m:+muia-text-contents+
                   (store-text (mui-editor-dbg-condition-buf editor) +wide-buffer-size+
                               (debugger-condition dbg)))
    (fill-list (mui-editor-dbg-restarts editor) (debugger-restarts dbg))
    (mui:set-attrs (mui-editor-dbg-continue-btn editor) m:+muia-disabled+
                   (not (debugger-has-continue dbg)))
    (fill-list (mui-editor-dbg-frames editor) '())
    (fill-list (mui-editor-dbg-locals editor) '())
    (mui:set-attrs window m:+muia-window-title+
                   (store-string (mui-editor-dbg-title-buf editor)
                                 (format nil "clamacs debugger (level ~D)" (debugger-level dbg))))
    ;; Opened, not activated: `M-x clamacs-debugger' gives it the focus.
    (mui:set-attrs window m:+muia-window-open+ t)))

(defmethod editor-debugger-close ((editor mui-editor))
  (let ((window (mui-editor-dbg-window editor)))
    (when window
      (mui:set-attrs window m:+muia-window-open+ nil))))

(defmethod editor-debugger-raise ((editor mui-editor))
  (let ((window (ensure-debugger-window editor)))
    (mui:set-attrs window m:+muia-window-open+ t)
    (mui:set-attrs window m:+muia-window-activate+ t)))

(defmethod editor-debugger-frames ((editor mui-editor) rows)
  (fill-list (mui-editor-dbg-frames editor) rows))

(defmethod editor-debugger-select-frame ((editor mui-editor) n)
  (let ((list (mui-editor-dbg-frames editor)))
    (when list
      (setf (mui-editor-dbg-selecting editor) t)
      (unwind-protect
           (mui:set-attrs list m:+muia-list-active+ (or n m:+muiv-list-active-off+))
        (setf (mui-editor-dbg-selecting editor) nil)))))

(defmethod editor-debugger-locals ((editor mui-editor) rows)
  (fill-list (mui-editor-dbg-locals editor) rows))

(defun dispose-debugger-window (editor)
  (let ((window (mui-editor-dbg-window editor)))
    (when window
      (setf (mui-editor-dbg-window editor) nil
            (mui-editor-dbg-frames editor) nil)
      (dispose-aux-window editor window "debugger window")
      (ffi:free-foreign (mui-editor-dbg-title-buf editor))
      (ffi:free-foreign (mui-editor-dbg-condition-buf editor))
      (setf (mui-editor-dbg-title-buf editor) nil
            (mui-editor-dbg-condition-buf editor) nil))))

;;; --- the inspector

(defun ensure-inspector-window (editor)
  (or (mui-editor-insp-window editor)
      (let* ((title-buf (ffi:alloc-foreign +string-buffer-size+))
             (object-buf (ffi:alloc-foreign +wide-buffer-size+))
             (object (mui:new-object :text
                                     m:+muia-text-contents+ (store-text object-buf +wide-buffer-size+ "")
                                     m:+muia-text-set-min+ nil
                                     m:+muia-frame+ m:+muiv-frame-text+
                                     m:+muia-background+ m:+muii-text-back+))
             (parts (make-string-list))
             (parts-view (make-listview parts t))
             (part-btn (make-button "Inspect part" #\p))
             (back-btn (make-button "Back" #\b))
             (window (apply
                      #'mui:new-object
                      :window
                      m:+muia-window-title+ (store-string title-buf "clamacs inspector")
                      (append
                       (window-place-tags editor "inspector"
                                          (mui:window-size-visible 50)
                                          (mui:window-size-visible 40))
                       (list
                        m:+muia-window-root-object+
                        (mui:new-object
                         :group
                         m:+muia-group-child+ object
                         m:+muia-group-child+ parts-view
                         m:+muia-group-child+
                         (mui:new-object :group m:+muia-group-horiz+ t
                                         m:+muia-group-child+ part-btn
                                         m:+muia-group-child+ back-btn)))))))
        (setf (mui-editor-insp-window editor) window
              (mui-editor-insp-object-obj editor) object
              (mui-editor-insp-parts editor) parts
              (mui-editor-insp-back-btn editor) back-btn
              (mui-editor-insp-title-buf editor) title-buf
              (mui-editor-insp-object-buf editor) object-buf)
        (mui:do-method (mui-editor-app editor) intui:+om-addmember+ window)
        ;; The close gadget only closes: the navigation stack in clamiga
        ;; stays, and the next C-c I starts it over.
        (mui:notify window m:+muia-window-close-request+ t
                    window m:+muim-set+ m:+muia-window-open+ nil)
        (on-notify editor parts-view m:+muia-listview-double-click+ t
                   (lambda () (inspect-part-clicked editor (list-active-row parts))))
        (on-notify editor part-btn m:+muia-pressed+ nil
                   (lambda () (inspect-part-clicked editor (list-active-row parts))))
        (on-notify editor back-btn m:+muia-pressed+ nil
                   (lambda () (inspect-back-clicked editor)))
        window)))

(defmethod editor-inspector-open ((editor mui-editor) insp)
  (let ((window (ensure-inspector-window editor)))
    (mui:set-attrs (mui-editor-insp-object-obj editor) m:+muia-text-contents+
                   (store-text (mui-editor-insp-object-buf editor) +wide-buffer-size+
                               (inspector-object insp)))
    (fill-list (mui-editor-insp-parts editor) (inspector-parts insp))
    (mui:set-attrs window m:+muia-window-title+
                   (store-string (mui-editor-insp-title-buf editor)
                                 (format nil "clamacs inspector: ~A" (inspector-type insp))))
    (mui:set-attrs (mui-editor-insp-back-btn editor) m:+muia-disabled+
                   (<= (inspector-depth insp) 1))
    (mui:set-attrs window m:+muia-window-open+ t)
    (mui:set-attrs window m:+muia-window-activate+ t)))

(defun dispose-inspector-window (editor)
  (let ((window (mui-editor-insp-window editor)))
    (when window
      (setf (mui-editor-insp-window editor) nil
            (mui-editor-insp-parts editor) nil)
      (dispose-aux-window editor window "inspector window")
      (ffi:free-foreign (mui-editor-insp-title-buf editor))
      (ffi:free-foreign (mui-editor-insp-object-buf editor))
      (setf (mui-editor-insp-title-buf editor) nil
            (mui-editor-insp-object-buf editor) nil))))

;;; --- The notification hooks: one per kind, the document found from the
;;; text object's address the notification carries.

(defun hook-document (editor message)
  (address-document editor (ffi:peek-u32 message 0)))

(defun install-hooks (editor)
  (flet ((hook (function)
           (mui:pool-hook (lambda (hook object message)
                            (declare (ignore hook object))
                            (let ((doc (hook-document editor message)))
                              (when (and doc (not (doc-closing doc)))
                                (funcall function doc)
                                (after-command editor)))
                            0))))
    (setf (mui-editor-hooks editor)
          ;; Both only note what REDISPLAY owes: the status line, the
          ;; paren highlight and the changed line's colours follow once
          ;; the keys rest, not before the next key is looked at.
          (list :cursor (hook (lambda (doc)
                                (setf (mdoc-cursor-dirty doc) t)))
                :changed (hook (lambda (doc)
                                 ;; An edit ends what is shown of the
                                 ;; region; the mark stays for `C-w'.
                                 (setf (doc-mark-active doc) nil)
                                 ;; The edit itself is counted now: the
                                 ;; arglist and the package cache go by it.
                                 (incf (doc-edit-serial doc))
                                 (let ((y (te-get doc +tea-cursor-y+))
                                       (y0 (mdoc-dirty-y0 doc)))
                                   (setf (mdoc-dirty-y0 doc) (if y0 (min y0 y) y)
                                         (mdoc-dirty-y1 doc) (if y0 (max (mdoc-dirty-y1 doc) y) y)
                                         (mdoc-cursor-dirty doc) t))
                                 ;; The class notifies ContentsChanged only
                                 ;; when the flag flips, and only ever sets
                                 ;; it: cleared here, quietly, so the next
                                 ;; edit is a change again.
                                 (mui:set-attrs (mdoc-text doc) +tea-contents-changed+ nil)))
                :close (hook (lambda (doc) (close-document doc)))
                :activate (hook (lambda (doc)
                                  ;; A late report while a request stands is
                                  ;; ignored; the request does not end on the
                                  ;; requested window's own report either
                                  ;; (see +ACTIVATE-PENDING-TICKS+).
                                  (let ((pending (mui-editor-activate-pending editor)))
                                    (unless (and pending (not (doc-closing pending))
                                                 (< (logand (- (ticks-now)
                                                               (mui-editor-activate-stamp editor))
                                                            #xFFFFFFFF)
                                                    +activate-pending-ticks+))
                                      (setf (mui-editor-activate-pending editor) nil
                                            (mui-editor-active-doc editor) doc)))))
                :mini-ack (hook (lambda (doc) (minibuffer-done doc)))
                :mini-changed (hook (lambda (doc) (minibuffer-changed doc)))))))

(defun editor-hook (editor kind)
  (getf (mui-editor-hooks editor) kind))

(defun notify-hook (editor object attribute trigger kind doc)
  (mui:notify object attribute trigger :application m:+muim-call-hook+
              (editor-hook editor kind) (object-address (mdoc-text doc))))

;;; --- The window

(defun text-group (doc)
  "The editor and the vertical bar side by side and, when the class can
drive one, the horizontal bar under the editor -- a 2x2 column group keeps
it from running under the vertical one."
  (if (mdoc-hslider doc)
      (mui:new-object :group m:+muia-group-columns+ 2 m:+muia-group-spacing+ 0
                      m:+muia-group-child+ (mdoc-text doc)
                      m:+muia-group-child+ (mdoc-slider doc)
                      m:+muia-group-child+ (mdoc-hslider doc)
                      m:+muia-group-child+ (mui:new-object :rectangle))
      (mui:new-object :group m:+muia-group-horiz+ t m:+muia-group-spacing+ 0
                      m:+muia-group-child+ (mdoc-text doc)
                      m:+muia-group-child+ (mdoc-slider doc))))

(defun build-window (editor doc)
  (setf (mdoc-title-buf doc) (ffi:alloc-foreign +string-buffer-size+)
        (mdoc-status-buf doc) (ffi:alloc-foreign +string-buffer-size+)
        (mdoc-message-buf doc) (ffi:alloc-foreign +string-buffer-size+)
        (mdoc-label-buf doc) (ffi:alloc-foreign +string-buffer-size+))
  (store-string (mdoc-title-buf doc) "clamacs")
  (store-string (mdoc-status-buf doc) "")
  (store-string (mdoc-message-buf doc) "")
  (store-string (mdoc-label-buf doc) "")
  (setf (mdoc-text doc)
        (apply #'mui:new-object (mui:custom-class-class (mui-editor-textclass editor))
               m:+muia-cycle-chain+ t
               +tea-fixed-font+ t
               +tea-undo-levels+ 200
               +tea-wrap-mode+ +tev-wrap-mode-nowrap+
               ;; NoStyle, not Plain: Plain writes colour escapes
               ;; into the exported text.
               +tea-export-hook+ +tev-export-hook-nostyle+
               +tea-import-hook+ +tev-import-hook-plain+
               ;; The theme's background (theme.lisp), when it paints one
               (text-creation-tags editor (doc-lisp-mode doc)))
        (mdoc-slider doc) (mui:new-object :scrollbar)
        ;; Lines never wrap, so a long line runs off the right edge: a
        ;; horizontal bar makes it reachable with the mouse, on a class
        ;; that drives one (15.48 on).
        (mdoc-hslider doc) (and (texteditor-at-least editor 15 48)
                                (mui:new-object :scrollbar m:+muia-group-horiz+ t))
        (mdoc-status doc) (mui:new-object :text
                                          m:+muia-text-contents+ (mdoc-status-buf doc)
                                          m:+muia-text-set-min+ nil
                                          m:+muia-frame+ m:+muiv-frame-text+)
        ;; The echo area: a message line, or the prompt beside the input,
        ;; one at a time.  A page switch repaints only what the new page's
        ;; objects cover, so both Text objects grow to the row's full height
        ;; and the row has no spacing.
        (mdoc-msgline doc) (mui:new-object :text
                                           m:+muia-text-contents+ (mdoc-message-buf doc)
                                           m:+muia-text-set-min+ nil
                                           m:+muia-text-set-v-max+ nil)
        (mdoc-prompt doc) (mui:new-object :text
                                          m:+muia-text-contents+ (mdoc-label-buf doc)
                                          m:+muia-text-set-min+ t
                                          m:+muia-text-set-v-max+ nil
                                          m:+muia-weight+ 0)
        (mdoc-mini doc) (mui:new-object (mui:custom-class-class (mui-editor-miniclass editor))
                                        m:+muia-frame+ m:+muiv-frame-string+
                                        m:+muia-string-max-len+ 256
                                        m:+muia-cycle-chain+ t))
  ;; The object holds the theme's background if it was created with it
  ;; (TEXT-CREATION-TAGS): recorded, so that a plan the first Setup corrects
  ;; -- a screen shallower than the default public one -- takes it away again.
  (when (text-creation-background-p editor (doc-lisp-mode doc))
    (ffi:poke-u32 (text-instance-data editor (mdoc-text doc)) 1 +text-own-bg-offset+))
  ;; Register the objects before any method can run on them.
  (setf (gethash (object-address (mdoc-text doc)) (mui-editor-objects editor)) doc
        (gethash (object-address (mdoc-mini doc)) (mui-editor-objects editor)) doc)
  (setf (mdoc-miniline doc)
        (mui:new-object :group m:+muia-group-horiz+ t m:+muia-group-spacing+ 0
                        m:+muia-group-child+ (mdoc-prompt doc)
                        m:+muia-group-child+ (mdoc-mini doc))
        (mdoc-echo doc)
        (mui:new-object :group m:+muia-group-page-mode+ t
                        m:+muia-group-child+ (mdoc-msgline doc)
                        m:+muia-group-child+ (mdoc-miniline doc))
        (mdoc-window doc)
        (apply #'mui:new-object :window
               m:+muia-window-title+ (mdoc-title-buf doc)
               m:+muia-window-root-object+
               (mui:new-object :group
                               m:+muia-group-child+ (text-group doc)
                               m:+muia-group-child+ (mdoc-status doc)
                               m:+muia-group-child+ (mdoc-echo doc))
               ;; Where the layout file puts a window of this role.
               (window-place-tags editor (doc-role doc)
                                  (mui:window-size-screen 60)
                                  (mui:window-size-screen 60))))
  (setf (gethash (object-address (mdoc-window doc)) (mui-editor-objects editor)) doc)
  (mui:set-attrs (mdoc-text doc) +tea-slider+ (mdoc-slider doc))
  (when (mdoc-hslider doc)
    (mui:set-attrs (mdoc-text doc) +tea-horizontal-slider+ (mdoc-hslider doc)))
  (mui:do-method (mui-editor-app editor) intui:+om-addmember+ (mdoc-window doc))
  (notify-hook editor (mdoc-window doc) m:+muia-window-close-request+ t :close doc)
  (notify-hook editor (mdoc-window doc) m:+muia-window-activate+ t :activate doc)
  (notify-hook editor (mdoc-mini doc) m:+muia-string-acknowledge+ :every-time :mini-ack doc)
  (notify-hook editor (mdoc-mini doc) m:+muia-string-contents+ :every-time :mini-changed doc)
  (notify-hook editor (mdoc-text doc) +tea-cursor-y+ :every-time :cursor doc)
  (notify-hook editor (mdoc-text doc) +tea-cursor-x+ :every-time :cursor doc)
  (notify-hook editor (mdoc-text doc) +tea-contents-changed+ t :changed doc)
  (mui:set-attrs (mdoc-window doc) m:+muia-window-open+ t)
  (when (zerop (or (mui:get-attr m:+muia-window-open+ (mdoc-window doc)) 0))
    (error "Clamacs: the document window would not open."))
  ;; MUI opens a window with no active object.
  (doc-activate doc)
  (update-status doc)
  ;; The first window's Setup settled the theme against the screen: what
  ;; the shallow-screen rule has to say goes into this echo area.
  (show-theme-note editor doc)
  doc)

(defmethod editor-make-document ((editor mui-editor) &key path name lisp-mode)
  (let ((doc (make-instance 'mui-document :editor editor :path path
                                          :name (or name *unnamed*)
                                          :lisp-mode lisp-mode)))
    (build-window editor doc)
    (doc-set-title doc (doc-name doc))
    doc))

(defvar *exit-trace* nil
  "When true, each step of START's teardown is appended to
T:clamacs-exit.log as it completes -- set from the running editor over the
port when a window outlives the process.  A file, not standard output:
what a `Run >log' clamiga prints never reaches the log on AmigaOS.")

(defun exit-note (step &optional always)
  (when (or *exit-trace* always)
    (ignore-errors
      (with-open-file (out "T:clamacs-exit.log" :direction :output
                                               :if-exists :append
                                               :if-does-not-exist :create)
        (format out "clamacs: exit ~A~%" step)))))

(defun dispose-window-object (editor window what)
  "MUI_DisposeObject on WINDOW, one of the editor's.  The dispose runs the
editor's own dispatchers (OM_DISPOSE of ClamacsText and ClamacsMini), and
an error in one of them comes back out of the dispose call: it is caught
here, written to T:clamacs-exit.log whether or not the trace is on -- the
one place a `Run'-started editor can report to -- and shown, so the
teardown goes on and the window is never disposed of a second time."
  (handler-case (mui:dispose-object window)
    (error (e)
      (exit-note (format nil "~A: the dispose signalled: ~A" what
                         (handler-case (princ-to-string e)
                           (error () "(unprintable condition)")))
                 t)
      (report-error editor e))))

(defun dispose-errors-window (editor)
  "The diagnostics window, at exit: closed, taken out of the application
and disposed of, exactly as REAP does with a document's window.  Leaving
it to the application's own dispose left an orphan window on the
Workbench after every run on a Vampire (MUI 3.8): a window Intuition still
shows, with no task behind it."
  (let ((window (mui-editor-errors-window editor)))
    (when window
      ;; Forgotten first: a dispose that signals must not be repeated.
      (setf (mui-editor-errors-window editor) nil
            (mui-editor-errors-list editor) nil)
      (mui:set-attrs window m:+muia-window-open+ nil)
      (mui:do-method (mui-editor-app editor) intui:+om-remmember+ window)
      (dispose-window-object editor window "diagnostics window"))))

(defun reap (editor)
  "Dispose of the retired windows, from the event loop where nothing is
running inside them."
  (dolist (doc (editor-documents editor))
    (when (and (doc-closing doc) (mdoc-window doc))
      (exit-note (format nil "reap ~A: forgetting the objects" (doc-name doc)))
      (let ((window (mdoc-window doc))
            (objects (mui-editor-objects editor)))
        (remhash (object-address (mdoc-text doc)) objects)
        (remhash (object-address (mdoc-mini doc)) objects)
        (remhash (object-address window) objects)
        ;; Forgotten BEFORE the dispose: should the dispose signal (an
        ;; error in a dispatcher's OM_DISPOSE), the loop's error handler
        ;; reaps again, and a second dispose of the same window is what
        ;; froze a Vampire.
        (setf (mdoc-window doc) nil (mdoc-text doc) nil (mdoc-mini doc) nil)
        (exit-note "reap: removing the window from the application")
        (mui:do-method (mui-editor-app editor) intui:+om-remmember+ window)
        (exit-note "reap: disposing the window")
        (dispose-window-object editor window (format nil "reap ~A" (doc-name doc)))
        (exit-note "reap: window disposed"))
      (dolist (buf (list (mdoc-title-buf doc) (mdoc-status-buf doc)
                         (mdoc-message-buf doc) (mdoc-label-buf doc)))
        (when buf (ffi:free-foreign buf)))
      (setf (mdoc-title-buf doc) nil (mdoc-status-buf doc) nil
            (mdoc-message-buf doc) nil (mdoc-label-buf doc) nil)
      (exit-note "reap: buffers freed")))
  (setf (editor-documents editor)
        (remove-if #'doc-closing (editor-documents editor))))

;;; ------------------------------------------------------------------
;;; The event loop
;;; ------------------------------------------------------------------

;;; What wakes the loop, counted: the account to read when the editor
;;; takes CPU while nobody types (2026-09-30: 95 % on a 68040).  AmigaOS
;;; has no per-task CPU accounting, so the wakeups and the methods MUI
;;; calls on the two classes are the account there is.  Read it from a
;;; running editor over the port -- `EVAL (clamacs::loop-stats-reset)'
;;; first (the loop's counters run always, the per-method ones from the
;;; reset on), then `EVAL (clamacs::loop-stats-report)' -- which
;;; verify/realamiga/loopstats.rexx does, and run-cpu-idle.sh per phase
;;; of its run, beside the CPU share its meter task measures.

(defstruct (loop-stats (:constructor %make-loop-stats))
  (started (get-internal-real-time))
  (iterations 0 :type fixnum)     ; NewInput calls
  (ids 0 :type fixnum)            ; ... that returned an id
  (spins 0 :type fixnum)          ; ... zero mask, no id: the Delay(1) path
  (waits 0 :type fixnum)          ; Wait calls
  (mailbox-wakes 0 :type fixnum)  ; ... that the mailbox signal ended
  (menu-syncs 0 :type fixnum)     ; display brought in step (REDISPLAY)
  (timer-arms 0 :type fixnum)     ; idle timer put up (ARM-IDLE-TIMER)
  (methods (make-hash-table))     ; method id -> calls, both classes
  ;; What the two classes' dispatchers had been sent, and had passed to
  ;; the superclass natively, when the account was reset (CLASS-ACCOUNT).
  (class-base '()))

(defvar *loop-stats* (%make-loop-stats))

(defvar *count-methods* nil
  "True once LOOP-STATS-RESET ran: the per-method account costs a hash
increment per MUI call, so the shipped editor does not keep it until a
diagnostic run asks.")

(defun count-method (id)
  "One more call of the method ID (the dispatchers, ahead of their COND),
when the account was asked for."
  (when *count-methods*
    (incf (gethash id (loop-stats-methods *loop-stats*) 0))))

(defun count-timer-arm ()
  (incf (loop-stats-timer-arms *loop-stats*)))

(defun class-account ()
  "What MUI sent the two classes' dispatchers so far and how much of it
went to the superclass without entering Lisp: (text-sent text-native
mini-sent mini-native), or NIL when no editor is up."
  (let ((editor *editor*))
    (when (and (typep editor 'mui-editor) (mui-editor-textclass editor))
      (multiple-value-bind (text-sent text-native)
          (mui:custom-class-stats (mui-editor-textclass editor))
        (multiple-value-bind (mini-sent mini-native)
            (mui:custom-class-stats (mui-editor-miniclass editor))
          (list (or text-sent 0) (or text-native 0)
                (or mini-sent 0) (or mini-native 0)))))))

(defun loop-stats-reset ()
  (setf *loop-stats* (%make-loop-stats :class-base (class-account))
        *count-methods* t))

(defun loop-stats-report (&optional (stream *standard-output*))
  "The loop's account since the last reset, one line per counter and one
per method id MUI called on the classes, with their rates per second."
  (let* ((s *loop-stats*)
         (seconds (max 1/1000 (/ (- (get-internal-real-time) (loop-stats-started s))
                                 internal-time-units-per-second))))
    (format stream "loop-stats over ~,1F s~%" seconds)
    (flet ((row (name n)
             (format stream "  ~24A ~8D  ~8,1F/s~%" name n (/ n seconds))))
      (row "iterations" (loop-stats-iterations s))
      (row "  with an id" (loop-stats-ids s))
      (row "  spins (Delay 1)" (loop-stats-spins s))
      (row "waits" (loop-stats-waits s))
      (row "  mailbox wakes" (loop-stats-mailbox-wakes s))
      (row "redisplays" (loop-stats-menu-syncs s))
      (row "idle timer arms" (loop-stats-timer-arms s))
      ;; The methods below are the ones that entered Lisp; these rows are
      ;; everything MUI sent, and the part that never did.
      (let ((now (class-account))
            (base (or (loop-stats-class-base s) '(0 0 0 0))))
        (when now
          (loop for name in '("text class sent" "  passed natively"
                              "mini class sent" "  passed natively")
                for n in now
                for b in base
                do (row name (- n b)))))
      (let ((rows '()))
        (maphash (lambda (id n) (push (cons id n) rows)) (loop-stats-methods s))
        (dolist (row (sort rows #'> :key #'cdr))
          (row (format nil "method #x~8,'0X" (car row)) (cdr row)))))
    (values)))

(defun report-error (editor condition)
  "An error in a command or a method, re-signaled at the loop: shown in the
active document's echo area, and on the console when there is none."
  (let ((doc (active-document editor))
        (text (handler-case (format nil "Error: ~A" condition)
                (error () "Error (unprintable condition)"))))
    (if doc
        (doc-message doc (substitute #\Space #\Newline text))
        (format *error-output* "clamacs: ~A~%" text))))

(defun redisplay-document (doc)
  "What DOC's notifications left to do: the changed lines recoloured, the
paren highlight and the sideways scroll after a cursor move, the status
line -- once for however many keys came in between."
  (let ((y0 (mdoc-dirty-y0 doc))
        (y1 (mdoc-dirty-y1 doc))
        (moved (mdoc-cursor-dirty doc)))
    (when (or y0 moved)
      ;; Cleared first: what the repaint itself stirs up is owed again.
      (setf (mdoc-dirty-y0 doc) nil
            (mdoc-dirty-y1 doc) nil
            (mdoc-cursor-dirty doc) nil)
      (when (and (mdoc-text doc) (not (doc-closing doc)))
        (with-changed-flag (doc)
          (when y0
            (colour-lines doc y0 y1)
            ;; The recolour paints the lines whole, over a paren highlight
            ;; among them: lit again below.
            (let ((shown (doc-paren-shown doc)))
              (when (and shown (<= y0 (car shown) y1))
                (setf (doc-paren-shown doc) nil
                      moved t))))
          (when moved
            (note-cursor-moved doc)))
        (when moved
          (hscroll-into-view doc))
        (update-status doc)))))

(defun redisplay (editor &optional force)
  "The display in step with the editor: every document's changed lines,
paren highlight and status line, the menu's enable states and the dynamic
menus.  Run when the keys rest (IDLE-TICK) and after a wake that carries a
return id; nothing when no editor code ran since the last one, unless
FORCE."
  (when (or force (/= (mui-editor-activity editor) (mui-editor-shown-activity editor)))
    (incf (loop-stats-menu-syncs *loop-stats*))
    (dolist (doc (editor-documents editor))
      (redisplay-document doc))
    (menu-update editor)
    (dynamic-menus-sync editor)
    ;; Read after the work: its own notifications are not a new reason.
    (setf (mui-editor-shown-activity editor) (mui-editor-activity editor))))

(defun housekeeping (editor id)
  "After MUI input or a mailbox drain: reap retired windows, carry out a
quit.  True when the last window is gone and the loop must leave."
  (when (eql id (mui-editor-reap-id editor))
    (reap editor))
  (when (editor-quitting editor)
    (quit-requested editor))
  (theme-repaint editor)
  ;; The display follows a wake that ran editor code -- a return id, a
  ;; mailbox drain, a key or a hook (AFTER-COMMAND counts them) -- at once
  ;; for a return id (a menu pick, a reap), else from the idle timer once
  ;; the keys rest, which is put up here; and never the wake of MUI's own
  ;; timer alone (some 60 a second while a timer handler is up).
  (cond (id
         (redisplay editor t))
        ((/= (mui-editor-activity editor) (mui-editor-shown-activity editor))
         (unless (arm-idle-timer editor)
           (redisplay editor)))
        ((mui-editor-timer-idle editor)
         (disarm-idle-timer editor)))
  ;; No list made per wake: LIVE-DOCUMENTS conses one.
  (loop for doc in (editor-documents editor)
        always (doc-closing doc)))

(defun run-loop (editor)
  "The MUI event loop, MUI's idiom (NewInput, Wait on the mask it hands
back) with two additions: the mailbox signal joins the mask and is drained
when it arrives, and the Wait is AMIGA:WAIT-SIGNALS -- a GC safe region --
so a collection started by the client or the port thread does not wait for
the next keystroke."
  (let ((app (mui-editor-app editor))
        (mailbox (mui-editor-signal-mask editor)))
    (loop
      (handler-case
          (loop
            (multiple-value-bind (id sigs) (mui:application-input app)
              ;; *LOOP-STATS* read each time: a reset replaces it.
              (incf (loop-stats-iterations *loop-stats*))
              (when id (incf (loop-stats-ids *loop-stats*)))
              (when (eq id :quit)
                (return-from run-loop))
              (when (housekeeping editor id)
                (return-from run-loop))
              (cond ((zerop sigs)
                     ;; MUI: more input pending -- but never spin on nothing.
                     (unless id
                       (incf (loop-stats-spins *loop-stats*))
                       (dos:delay 1)))
                    (t
                     (incf (loop-stats-waits *loop-stats*))
                     (let ((got (amiga:wait-signals
                                 (logior sigs mailbox dos:+sigbreakf-ctrl-c+))))
                       (when (logtest got dos:+sigbreakf-ctrl-c+)
                         (return-from run-loop))
                       (when (logtest got mailbox)
                         (incf (loop-stats-mailbox-wakes *loop-stats*))
                         (mailbox-drain (editor-mailbox editor))
                         (when (housekeeping editor nil)
                           (return-from run-loop))))))))
        (error (e)
          (report-error editor e)
          ;; A window closed by the failing command still needs reaping.
          (reap editor)
          (when (null (live-documents editor))
            (return)))))))

;;; ------------------------------------------------------------------
;;; Entry
;;; ------------------------------------------------------------------

(defun start (&key files)
  "Run the editor: open the libraries, build the classes, one window per
path in FILES (an unnamed Lisp buffer when there are none) and enter the
event loop until the last window closes.  Nothing OS-owned outlives this
function: an image is saved before it runs and restores into it."
  (unless (mui:available-p)
    (error "Clamacs needs MUI (muimaster.library), which did not open."))
  (let ((editor (%make-mui-editor)))
    (setf *editor* editor)
    ;; Where the windows go, before the first one is made.
    (snapshot-load editor)
    (unwind-protect
         (mui:with-foreign-pool ()
           (setf (mui-editor-ie editor) (mui:pool-alloc +ie-size+)
                 (mui-editor-mapbuf editor) (mui:pool-alloc 8)
                 ;; The theme's background spec and its two pen specs,
                 ;; which MUI reads
                 (mui-editor-bg-buf editor) (mui:pool-alloc +bg-buffer-size+)
                 (mui-editor-cursor-buf editor) (mui:pool-alloc +pen-spec-size+)
                 (mui-editor-marked-buf editor) (mui:pool-alloc +pen-spec-size+))
           (create-classes editor)
           (install-hooks editor)
           ;; The menu strip goes in at creation (MUIA_Application_Menustrip
           ;; is an init-time attribute); without one the editor still
           ;; runs.  No MUIA_Application_Base: MUI would open an ARexx port
           ;; of its own; the editor's port is AMIGA.AREXX's (phase 2).
           (let ((strip (build-menustrip editor)))
             (setf (mui-editor-app editor)
                   (apply #'mui:new-object :application
                          m:+muia-application-title+ "Clamacs"
                          m:+muia-application-version+ (format nil "$VER: Clamacs ~A" *clamacs-version*)
                          m:+muia-application-description+ "Emacs-flavoured Common Lisp IDE"
                          (and strip (list m:+muia-application-menustrip+ strip)))))
           (attach-menustrip editor)
           (setup-mailbox editor)
           (unwind-protect
                (progn
                  (if files
                      (dolist (path files)
                        (unless (open-document editor path)
                          (format *error-output* "clamacs: cannot open ~A~%" path)))
                      (open-document editor nil))
                  (when (live-documents editor)
                    ;; The wire and the editor's own port, once there is a
                    ;; document for the first command to act on.
                    (when *wire-starter*
                      (handler-case (funcall *wire-starter* editor)
                        (error (e) (report-error editor e))))
                    (dolist (hook *after-start-hooks*)
                      (funcall hook editor))
                    (menu-update editor)
                    (dynamic-menus-sync editor)
                    ;; A theme a start hook or the wire's first reply
                    ;; picked, before the first key.
                    (theme-repaint editor)
                    (run-loop editor)))
             ;; Order: no more calls from the other threads (waiters are
             ;; woken with the shutdown answer), then the port and the
             ;; client thread, then the windows.
             (exit-note "loop left")
             (mailbox-close (editor-mailbox editor))
             (when (and *wire-stopper* (editor-wire editor))
               (handler-case (funcall *wire-stopper* editor)
                 (error (e) (report-error editor e))))
             (exit-note "wire stopped")
             (dolist (doc (editor-documents editor))
               (setf (doc-closing doc) t))
             (reap editor)
             (exit-note "documents reaped")
             (dispose-errors-window editor)
             (exit-note "diagnostics window disposed")
             (dispose-debugger-window editor)
             (dispose-inspector-window editor)
             (exit-note "debugger and inspector windows disposed")
             ;; The strip belongs to the application and goes with it.
             (setf (mui-editor-menu-items editor) nil)
             (mui:dispose-object (mui-editor-app editor))
             (exit-note "application disposed")
             (setf (mui-editor-app editor) nil
                   (mui-editor-menustrip editor) nil)
             ;; The text size's font, now that no object draws with it
             (close-text-font editor)
             (free-text-font-buffers editor)
             ;; The dynamic groups' items went with it; their titles are ours.
             (dolist (group (mui-editor-dyn-groups editor))
               (dolist (entry (dyn-group-items group))
                 (when (cdr entry) (ffi:free-foreign (cdr entry))))
               (setf (dyn-group-items group) '()))
             (setf (mui-editor-dyn-groups editor) '())
             (free-mailbox editor)))
      (setf *editor* nil))
    t))

(defun run ()
  "The editor as a program: the user's init file (S:.clamacsrc), then
START on the program's own arguments -- what follows `--' on clamiga's
command line, or the project icons of a Workbench start, both
EXT:*COMMAND-LINE-ARGS*.  lisp/clamacs.lisp calls it after loading the
editor from source; the image's start calls it the same way, so the
user's paths are re-derived first (constants here; see REFRESH-USER-PATHS)."
  (refresh-user-paths)
  (load-init-file)
  (start :files ext:*command-line-args*))
