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
;;;;     list is consulted; MUI 4 never calls that hook and sends the keys
;;;;     through MUIM_HandleEvent twice instead.  Both paths are here.
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
  (require "amiga/raw/muimaster")
  (dolist (nick '(("MUI" "AMIGA.MUI") ("M" "AMIGA.RAW.MUIMASTER")
                  ("EXEC" "AMIGA.RAW.EXEC") ("DOS" "AMIGA.RAW.DOS")
                  ("INTUI" "AMIGA.RAW.INTUITION") ("GFX" "AMIGA.RAW.GRAPHICS")
                  ("KEYMAP" "AMIGA.RAW.KEYMAP") ("ASL" "AMIGA.RAW.ASL")))
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
;;; MUIIHNF_TIMER | MUIIHNF_TIMER_SCALE100, 3 units: 300 ms.
(defconstant +idle-tick-units+ 3)

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
;; struct SGWork (intuition/sghooks.h): IEvent 20, Code 24, Actions 30, EditOp 42
(defconstant +sgw-ievent-offset+ 20)
(defconstant +sgw-code-offset+ 24)
(defconstant +sgw-actions-offset+ 30)
(defconstant +sgw-editop-offset+ 42)
(defconstant +sgh-key-done+ #xFFFFFFFF)   ; "understood", sghooks.h: SGH_KEY is assumed
;; struct MUI_RenderInfo: mri_WindowObject first; mri_Screen at 4
(defconstant +mri-window-object-offset+ 0)
(defconstant +mri-screen-offset+ 4)
;; struct Screen.ViewPort (44) .ColorMap (4)
(defconstant +screen-colormap-offset+ 48)
;; struct TextFont.tf_XSize
(defconstant +tf-xsize-offset+ 24)
;; struct FileRequester (libraries/asl.h)
(defconstant +fr-file-offset+ 4)
(defconstant +fr-drawer-offset+ 8)

;;; Instance data of ClamacsText: the handler node, the eight pens
;;; (MUIA_TextEditor_ColorMap points here), two flags, the idle timer's
;;; input handler node and its flag.
(defconstant +text-data-size+ 96)
(defconstant +text-ehn-offset+ 0)
(defconstant +text-cmap-offset+ 24)
(defconstant +text-pens-held-offset+ 56)
(defconstant +text-eh-added-offset+ 60)
(defconstant +text-ihn-offset+ 64)
(defconstant +text-timer-added-offset+ 88)
;;; Instance data of ClamacsMini: the handler node, the edit hook, the key
;;; the hook last took, and the event MUIM_HandleEvent last saw.
(defconstant +mini-data-size+ 56)
(defconstant +mini-ehn-offset+ 0)
(defconstant +mini-hook-offset+ 24)
(defconstant +mini-eh-added-offset+ 28)
(defconstant +mini-hook-taken-offset+ 32)
(defconstant +mini-hook-key-offset+ 36)
(defconstant +mini-seen-imsg-offset+ 40)
(defconstant +mini-seen-code-offset+ 44)
(defconstant +mini-seen-seconds-offset+ 48)
(defconstant +mini-seen-micros-offset+ 52)

;;; The window keys switched off while the text has the focus: RET must
;;; not fire a default gadget, TAB not cycle, ESC neither deactivate nor
;;; close.  The minibuffer keeps TAB for completion.
(defparameter *text-window-keys*
  (logior m:+muikeyf-press+ m:+muikeyf-gadget-next+ m:+muikeyf-gadget-prev+
          m:+muikeyf-gadget-off+ m:+muikeyf-window-close+))
(defparameter *mini-window-keys* m:+muikeyf-gadget-next+)

;;; Eight pens for MUIA_TextEditor_ColorMap.  A SetBlock colour value of N
;;; means pen N-1 of this table, 0 the normal pen; the token kinds map onto
;;; them below.  1 black, 2 white, 3 red, 4 green, 5 cyan, 6 yellow,
;;; 7 blue, 8 magenta.
(defparameter *pen-rgb*
  '((#x00 #x00 #x00) (#xff #xff #xff) (#xcc #x00 #x00) (#x00 #x88 #x00)
    (#x00 #x99 #x99) (#x99 #x77 #x00) (#x00 #x00 #xcc) (#xaa #x00 #xaa)))
(defconstant +pen-count+ 8)

(defun colour-value (colour)
  (case colour
    (:comment 4) ((:string :char) 6) (:keyword 5) (:number 8) (:defining 7)
    (:paren-match 3)
    (t 0)))

;;; ------------------------------------------------------------------
;;; Small foreign helpers
;;; ------------------------------------------------------------------

(defconstant +string-buffer-size+ 256)

(defun store-string (buffer string)
  "Copy STRING into BUFFER, a +STRING-BUFFER-SIZE+ foreign block, cut to
fit and NUL-terminated.  Characters above 255 become `?'."
  (let ((n (min (length string) (1- +string-buffer-size+))))
    (dotimes (i n)
      (let ((code (char-code (char string i))))
        (ffi:poke-u8 buffer (if (< code 256) code 63) i)))
    (ffi:poke-u8 buffer 0 n)
    buffer))

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
  ;; the document the port and the messages mean, and the activation
  ;; request that outranks late activation reports (see ACTIVATE-HOOK)
  active-doc activate-pending (activate-stamp 0)
  ;; the return ID that wakes the loop to reap closed windows
  (reap-id 1)
  ;; The mailbox: what the other threads (the port's, the client's) hand
  ;; the MUI task -- see CALL-IN-EDITOR.  The task and the signal bit the
  ;; loop waits on beside MUI's own.
  task (signal-bit -1) (signal-mask 0)
  mailbox-lock mailbox-cv (mailbox '()) (mailbox-closed nil)
  ;; The diagnostics window, made on first use, and its list
  errors-window errors-list
  ;; Set while EDITOR-SELECT-DIAGNOSTIC moves the list's cursor, so the
  ;; selection hook does not jump a second time
  (selecting nil))

(defvar *editor* nil
  "The running MUI editor, from START to its return.")

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
   (arglist :initform "" :accessor mdoc-arglist)))

(defun object-document (editor object)
  (gethash (object-address object) (mui-editor-objects editor)))

(defun address-document (editor address)
  (gethash address (mui-editor-objects editor)))

;;; ------------------------------------------------------------------
;;; The mailbox: only the MUI task touches MUI
;;; ------------------------------------------------------------------
;;;
;;; The port's handler thread and the client thread never call a method;
;;; they post a closure here, raise the editor's signal, and the event loop
;;; runs it between two MUI inputs.  A waiting caller (a port command that
;;; needs the answer) blocks on the condition variable until the loop has
;;; run its closure; a fire-and-forget one (a reply arriving from clamiga)
;;; just posts.  Exec signals are sticky, so a post while the loop is busy
;;; is picked up on its next wait.

(defstruct (mail (:constructor make-mail (thunk wait)))
  thunk wait (done nil) (values nil))

(defun setup-mailbox (editor)
  (let ((bit (exec:alloc-signal -1)))
    (when (< bit 0)
      (error "Clamacs: no free signal bit for the editor's mailbox."))
    (setf (mui-editor-task editor) (exec:find-task nil)
          (mui-editor-signal-bit editor) bit
          (mui-editor-signal-mask editor) (ash 1 bit)
          (mui-editor-mailbox-lock editor) (mp:make-lock "clamacs-mailbox")
          (mui-editor-mailbox-cv editor) (mp:make-condition-variable "clamacs-mailbox")
          (mui-editor-mailbox editor) '()
          (mui-editor-mailbox-closed editor) nil)))

(defun free-mailbox (editor)
  (when (>= (mui-editor-signal-bit editor) 0)
    (exec:free-signal (mui-editor-signal-bit editor))
    (setf (mui-editor-signal-bit editor) -1
          (mui-editor-signal-mask editor) 0)))

(defun call-in-editor (editor thunk &key (wait t))
  "From any thread: have the MUI task call THUNK.  With WAIT, block until
it has run and return its values; a closed mailbox (the editor is shutting
down) answers rc 20 instead.  Without, post and return at once."
  (let ((lock (mui-editor-mailbox-lock editor))
        (cv (mui-editor-mailbox-cv editor))
        (mail (make-mail thunk wait)))
    (mp:with-lock-held (lock)
      (when (mui-editor-mailbox-closed editor)
        (return-from call-in-editor
          (values +rc-fatal+ "ERROR: the editor is shutting down")))
      (push mail (mui-editor-mailbox editor)))
    (exec:signal (mui-editor-task editor) (mui-editor-signal-mask editor))
    (when wait
      (mp:with-lock-held (lock)
        (loop until (or (mail-done mail) (mui-editor-mailbox-closed editor))
              do (mp:condition-wait cv lock 1)))
      (if (mail-done mail)
          (values-list (mail-values mail))
          (values +rc-fatal+ "ERROR: the editor is shutting down")))))

(defun drain-mailbox (editor)
  "The MUI task: run everything posted since the last drain."
  (let ((lock (mui-editor-mailbox-lock editor))
        (cv (mui-editor-mailbox-cv editor)))
    (loop
      (let ((batch (mp:with-lock-held (lock)
                     (prog1 (nreverse (mui-editor-mailbox editor))
                       (setf (mui-editor-mailbox editor) '())))))
        (when (null batch)
          (return))
        (dolist (mail batch)
          (let ((values (handler-case (multiple-value-list (funcall (mail-thunk mail)))
                          (error (e)
                            (if (mail-wait mail)
                                (list +rc-fatal+
                                      (format nil "ERROR: ~A"
                                              (handler-case (princ-to-string e)
                                                (error () "(unprintable condition)"))))
                                (progn (report-error editor e) nil))))))
            (mp:with-lock-held (lock)
              (setf (mail-values mail) values
                    (mail-done mail) t)
              (mp:condition-broadcast cv))))))))

(defun close-mailbox (editor)
  "No more calls: every waiter is woken with the shutdown answer, and a
later post is refused."
  (let ((lock (mui-editor-mailbox-lock editor)))
    (when lock
      (mp:with-lock-held (lock)
        (setf (mui-editor-mailbox-closed editor) t)
        (mp:condition-broadcast (mui-editor-mailbox-cv editor))))))

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

(defun decode-input-event (editor ie)
  "The key of a struct InputEvent (the SGWork's), without the dead-key
history: none of the keys the minibuffer binds is a composed character."
  (rawkey-decode (ffi:peek-u16 ie +ie-code-offset+)
                 (ffi:peek-u16 ie +ie-qualifier-offset+)
                 (lambda (code qualifier)
                   (map-raw-key editor code qualifier 0))))

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
  "The arglist idle timer: MUI fires +CKM-IDLE-TICK+ on OBJECT every
3/10 s; ARGLIST-IDLE returns at once unless the cursor has come to rest in
this (active) window, so a background document costs a comparison per
tick.  Its own handler node, like the RAWKEY one, so its lifetime is
exactly the object's."
  (dotimes (i +ihn-size+)
    (ffi:poke-u8 ihn 0 i))
  (ffi:poke-u32 ihn (object-address object) +ihn-object-offset+)
  (ffi:poke-u16 ihn +idle-tick-units+ +ihn-millis-offset+)
  (ffi:poke-u32 ihn (logior m:+muiihnf-timer+ m:+muiihnf-timer-scale100+) +ihn-flags-offset+)
  (ffi:poke-u32 ihn +ckm-idle-tick+ +ihn-method-offset+)
  (mui:do-method (mui-editor-app editor) m:+muim-application-add-input-handler+ ihn))

(defun rem-idle-timer (editor ihn)
  (mui:do-method (mui-editor-app editor) m:+muim-application-rem-input-handler+ ihn))

(defun text-setup (editor class object message)
  (let ((ok (mui:do-super-method class object message)))
    (when (/= ok 0)
      (let ((data (mui:inst-data class object)))
        ;; Pens for the colouring: obtained here rather than at creation,
        ;; since a pen belongs to the screen the object ends up on.
        (let ((cm (screen-colormap object)))
          (loop for (r g b) in *pen-rgb*
                for i from 0
                do (ffi:poke-i32 data
                                 (gfx:obtain-best-pen-a cm (ash r 24) (ash g 24) (ash b 24) nil)
                                 (+ +text-cmap-offset+ (* 4 i)))))
        (ffi:poke-u32 data 1 +text-pens-held-offset+)
        (mui:set-attrs object +tea-color-map+ (ffi:pointer+ data +text-cmap-offset+))
        ;; The Emacs layer's key handler, ahead of the class's own.
        (add-handler (ffi:pointer+ data +text-ehn-offset+) class object)
        (ffi:poke-u32 data 1 +text-eh-added-offset+)
        (add-idle-timer editor (ffi:pointer+ data +text-ihn-offset+) object)
        (ffi:poke-u32 data 1 +text-timer-added-offset+)))
    ok))

(defun text-cleanup (editor class object message)
  (let ((data (mui:inst-data class object)))
    (when (/= 0 (ffi:peek-u32 data +text-timer-added-offset+))
      (rem-idle-timer editor (ffi:pointer+ data +text-ihn-offset+))
      (ffi:poke-u32 data 0 +text-timer-added-offset+))
    (when (/= 0 (ffi:peek-u32 data +text-eh-added-offset+))
      (rem-handler (ffi:pointer+ data +text-ehn-offset+) object)
      (ffi:poke-u32 data 0 +text-eh-added-offset+))
    (when (/= 0 (ffi:peek-u32 data +text-pens-held-offset+))
      (let ((cm (screen-colormap object)))
        (mui:set-attrs object +tea-color-map+ nil)
        (dotimes (i +pen-count+)
          (let ((pen (ffi:peek-i32 data (+ +text-cmap-offset+ (* 4 i)))))
            (when (/= pen -1)
              (gfx:release-pen cm pen))
            (ffi:poke-i32 data -1 (+ +text-cmap-offset+ (* 4 i))))))
      (ffi:poke-u32 data 0 +text-pens-held-offset+)))
  (mui:do-super-method class object message))

(defun wake-loop (editor)
  "Hand the event loop a return ID, so that it runs its housekeeping --
reaping retired windows, acting on a quit -- once MUI is out of the
method or hook that asked."
  (mui:return-id (mui-editor-app editor) (mui-editor-reap-id editor)))

(defun after-command (editor)
  "A command ran inside a method or a hook: a quit it asked for is the
loop's to carry out."
  (when (editor-quitting editor)
    (wake-loop editor)))

(defun text-handle-event (editor object message)
  "Invoked only through the class's own node, so it does not chain to the
superclass: when the Emacs layer does not take the key it returns 0 and
MUI's next handler -- the class's node -- edits."
  (let ((imsg (handle-event-imsg message))
        (doc (object-document editor object)))
    (if (and imsg doc (active-object-p object))
        (let* ((key (decode-imsg editor imsg))
               (taken (and key (handle-key doc key))))
          (after-command editor)
          (if taken m:+mui-event-handler-rc-eat+ 0))
        0)))

(defun make-text-dispatcher (editor)
  (lambda (class object message)
    (let ((id (mui:method-id message)))
      (cond ((= id m:+muim-handle-event+)
             (text-handle-event editor object message))
            ((= id +ckm-idle-tick+)
             (let ((doc (object-document editor object)))
               (when (and doc (not (doc-closing doc)))
                 (arglist-idle doc)
                 (after-command editor)))
             0)
            ((= id m:+muim-setup+)
             (text-setup editor class object message))
            ((= id m:+muim-cleanup+)
             (text-cleanup editor class object message))
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

(defun mini-edit-hook-function (editor)
  "The MUIA_String_EditHook function.  MUI 3.8 calls it BEFORE the class's
own edit hook and ignores the result, so a key we take is made invisible
to the class's hook: the event becomes a key release, the character is
cleared.  The action itself is deferred with MUIM_Application_PushMethod,
since the class's hook may still write its work buffer back after us."
  (lambda (hook sgw msg)
    (cond ((or (ffi:null-pointer-p sgw) (ffi:null-pointer-p msg)) 0)
          ((/= (ffi:peek-u32 msg 0) intui:+sgh-key+) 0)
          (t
           (let* ((address (amiga.ffi:hook-data hook))
                  (doc (address-document editor address))
                  (ie-addr (ffi:peek-u32 sgw +sgw-ievent-offset+)))
             (when (and doc (/= ie-addr 0))
               (let* ((ie (ffi:make-foreign-pointer ie-addr))
                      (key (decode-input-event editor ie)))
                 (when (and key
                            (or (minibuffer-binds-p doc key) (meta-char-key-p key)))
                   (let ((data (mui:inst-data (mui:custom-class-class (mui-editor-miniclass editor))
                                              (mdoc-mini doc))))
                     (ffi:poke-u32 data key +mini-hook-key-offset+)
                     (ffi:poke-u32 data 1 +mini-hook-taken-offset+))
                   ;; A release of no key, no qualifier, no character.
                   (ffi:poke-u16 ie (logior +raw-up-prefix+ #x7F) +ie-code-offset+)
                   (ffi:poke-u16 ie 0 +ie-qualifier-offset+)
                   (ffi:poke-u16 sgw 0 +sgw-code-offset+)
                   ;; And undo the default editing when it ran before us (MUI 4).
                   (ffi:poke-u32 sgw
                                 (logandc2 (ffi:peek-u32 sgw +sgw-actions-offset+)
                                           (logior intui:+sga-use+ intui:+sga-end+ intui:+sga-beep+
                                                   intui:+sga-reuse+ intui:+sga-nextactive+
                                                   intui:+sga-prevactive+))
                                 +sgw-actions-offset+)
                   (ffi:poke-u16 sgw intui:+eo-noop+ +sgw-editop-offset+)
                   (mui:do-method (mui-editor-app editor) m:+muim-application-push-method+
                                  (mdoc-mini doc) 2 +ckm-mini-key+ key))))
             +sgh-key-done+)))))

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
      (when (and imsg doc (active-object-p object))
        (let ((key (decode-imsg editor imsg)))
          ;; An active String edits through the edit hook before the handler
          ;; list is consulted: when the hook has just taken this key, the
          ;; node is seeing the same event again.
          (when (/= 0 (ffi:peek-u32 data +mini-hook-taken-offset+))
            (ffi:poke-u32 data 0 +mini-hook-taken-offset+)
            (when (eql key (ffi:peek-u32 data +mini-hook-key-offset+))
              (return-from mini-handle-event m:+mui-event-handler-rc-eat+)))
          (when key
            (when (minibuffer-key doc key)
              (after-command editor)
              (return-from mini-handle-event m:+mui-event-handler-rc-eat+))
            (when (and (meta-char-key-p key) (minibuffer-open-p doc))
              (mini-key-undefined doc key)
              (return-from mini-handle-event m:+mui-event-handler-rc-eat+))))))
    ;; Not consumed: the string gadget's own handler edits.
    0))

(defun make-mini-dispatcher (editor)
  (let ((edit-function (mini-edit-hook-function editor)))
    (lambda (class object message)
      (let ((id (mui:method-id message)))
        (cond ((= id m:+muim-handle-event+)
               (mini-handle-event editor class object message))
              ((= id +ckm-mini-key+)
               ;; The key the edit hook took, now that the String's own
               ;; handling is over and the contents may change safely.
               (let ((doc (object-document editor object))
                     (key (ffi:peek-u32 message 4)))
                 (when doc
                   (unless (minibuffer-key doc key)
                     (mini-key-undefined doc key))
                   (after-command editor))
                 0))
              ((= id intui:+om-new+)
               (let ((self (mui:do-super-method class object message)))
                 (when (/= self 0)
                   ;; One hook per object, its h_Data the object's address,
                   ;; which is how the hook finds the document.
                   (let* ((obj (ffi:make-foreign-pointer self))
                          (data (mui:inst-data class obj))
                          (hook (amiga.ffi:make-hook edit-function :data self)))
                     (ffi:poke-u32 data (object-address hook) +mini-hook-offset+)
                     (mui:set-attrs obj m:+muia-string-edit-hook+ hook)))
                 self))
              ((= id intui:+om-dispose+)
               (let* ((data (mui:inst-data class object))
                      (hook (ffi:peek-u32 data +mini-hook-offset+)))
                 (when (/= hook 0)
                   (amiga.ffi:free-hook (ffi:make-foreign-pointer hook))
                   (ffi:poke-u32 data 0 +mini-hook-offset+)))
               (mui:do-super-method class object message))
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
               (ffi:poke-u32 (mui:inst-data class object) 0 +mini-hook-taken-offset+)
               (set-window-keys object 0)
               (mui:do-super-method class object message))
              (t (mui:do-super-method class object message)))))))

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
                                   :data-size +text-data-size+)
          (mui-editor-miniclass editor)
          (mui:create-custom-class :string (make-mini-dispatcher editor)
                                   :data-size +mini-data-size+))))

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
  (let ((d (gensym "DOC")) (was (gensym "WAS")))
    `(let* ((,d ,doc)
            (,was (te-get ,d +tea-has-changed+)))
       (unwind-protect (progn ,@body)
         (mui:set-attrs (mdoc-text ,d) +tea-has-changed+ (/= ,was 0))))))

(defmethod doc-colour ((doc mui-document) y x0 x1 colour)
  (with-changed-flag (doc)
    (mui:do-method (mdoc-text doc) +tem-set-block+ x0 y x1 y
                   +tef-set-block-color+ (colour-value colour))))

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

(defmethod doc-ask-file ((doc mui-document) title save)
  "The ASL file requester, through MUI so it opens on the editor's screen."
  (let ((req (mui:with-tags (tags) (m:mui-alloc-asl-request asl:+asl-file-request+ tags))))
    (when req
      (unwind-protect
           (ffi:with-foreign-string (ftitle title)
             (ffi:with-foreign-string (finitial (doc-name doc))
               (mui:with-tags (tags asl:+aslfr-title-text+ ftitle
                                    asl:+aslfr-do-save-mode+ (and save t)
                                    asl:+aslfr-initial-file+ finitial
                                    asl:+aslfr-window+ (mui:get-attr-pointer m:+muia-window-window+
                                                                             (mdoc-window doc)))
                 (when (m:mui-asl-request req tags)
                   (let ((drawer (ffi:foreign-to-string
                                  (ffi:make-foreign-pointer (ffi:peek-u32 req +fr-drawer-offset+))))
                         (file (ffi:foreign-to-string
                                (ffi:make-foreign-pointer (ffi:peek-u32 req +fr-file-offset+)))))
                     (join-path drawer file))))))
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
             (window (mui:new-object :window
                                     m:+muia-window-title+ "clamacs diagnostics"
                                     m:+muia-window-width+ (mui:window-size-visible 60)
                                     m:+muia-window-height+ (mui:window-size-visible 25)
                                     m:+muia-window-root-object+
                                     (mui:new-object :listview m:+muia-listview-list+ list))))
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
          (list :cursor (hook (lambda (doc)
                                (update-status doc)
                                (note-cursor-moved doc)
                                (hscroll-into-view doc)))
                :changed (hook (lambda (doc)
                                 (note-text-changed doc)
                                 (update-status doc)
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
        (mui:new-object (mui:custom-class-class (mui-editor-textclass editor))
                        m:+muia-cycle-chain+ t
                        +tea-fixed-font+ t
                        +tea-undo-levels+ 200
                        +tea-wrap-mode+ +tev-wrap-mode-nowrap+
                        ;; NoStyle, not Plain: Plain writes colour escapes
                        ;; into the exported text.
                        +tea-export-hook+ +tev-export-hook-nostyle+
                        +tea-import-hook+ +tev-import-hook-plain+)
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
        (mui:new-object :window
                        m:+muia-window-title+ (mdoc-title-buf doc)
                        m:+muia-window-width+ (mui:window-size-screen 60)
                        m:+muia-window-height+ (mui:window-size-screen 60)
                        m:+muia-window-root-object+
                        (mui:new-object :group
                                        m:+muia-group-child+ (text-group doc)
                                        m:+muia-group-child+ (mdoc-status doc)
                                        m:+muia-group-child+ (mdoc-echo doc))))
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
  doc)

(defmethod editor-make-document ((editor mui-editor) &key path name lisp-mode)
  (let ((doc (make-instance 'mui-document :editor editor :path path
                                          :name (or name *unnamed*)
                                          :lisp-mode lisp-mode)))
    (build-window editor doc)
    (doc-set-title doc (doc-name doc))
    doc))

(defun reap (editor)
  "Dispose of the retired windows, from the event loop where nothing is
running inside them."
  (dolist (doc (editor-documents editor))
    (when (and (doc-closing doc) (mdoc-window doc))
      (let ((objects (mui-editor-objects editor)))
        (remhash (object-address (mdoc-text doc)) objects)
        (remhash (object-address (mdoc-mini doc)) objects)
        (remhash (object-address (mdoc-window doc)) objects))
      (mui:do-method (mui-editor-app editor) intui:+om-remmember+ (mdoc-window doc))
      (mui:dispose-object (mdoc-window doc))
      (setf (mdoc-window doc) nil (mdoc-text doc) nil (mdoc-mini doc) nil)
      (dolist (buf (list (mdoc-title-buf doc) (mdoc-status-buf doc)
                         (mdoc-message-buf doc) (mdoc-label-buf doc)))
        (when buf (ffi:free-foreign buf)))
      (setf (mdoc-title-buf doc) nil (mdoc-status-buf doc) nil
            (mdoc-message-buf doc) nil (mdoc-label-buf doc) nil)))
  (setf (editor-documents editor)
        (remove-if #'doc-closing (editor-documents editor))))

;;; ------------------------------------------------------------------
;;; The event loop
;;; ------------------------------------------------------------------

(defun report-error (editor condition)
  "An error in a command or a method, re-signaled at the loop: shown in the
active document's echo area, and on the console when there is none."
  (let ((doc (active-document editor))
        (text (handler-case (format nil "Error: ~A" condition)
                (error () "Error (unprintable condition)"))))
    (if doc
        (doc-message doc (substitute #\Space #\Newline text))
        (format *error-output* "clamacs: ~A~%" text))))

(defun housekeeping (editor id)
  "After MUI input or a mailbox drain: reap retired windows, carry out a
quit.  True when the last window is gone and the loop must leave."
  (when (eql id (mui-editor-reap-id editor))
    (reap editor))
  (when (editor-quitting editor)
    (quit-requested editor))
  (null (live-documents editor)))

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
              (when (eq id :quit)
                (return-from run-loop))
              (when (housekeeping editor id)
                (return-from run-loop))
              (cond ((zerop sigs)
                     ;; MUI: more input pending -- but never spin on nothing.
                     (unless id (dos:delay 1)))
                    (t
                     (let ((got (amiga:wait-signals
                                 (logior sigs mailbox dos:+sigbreakf-ctrl-c+))))
                       (when (logtest got dos:+sigbreakf-ctrl-c+)
                         (return-from run-loop))
                       (when (logtest got mailbox)
                         (drain-mailbox editor)
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
    (unwind-protect
         (mui:with-foreign-pool ()
           (setf (mui-editor-ie editor) (mui:pool-alloc +ie-size+)
                 (mui-editor-mapbuf editor) (mui:pool-alloc 8))
           (create-classes editor)
           (install-hooks editor)
           ;; No MUIA_Application_Base: MUI would open an ARexx port of its
           ;; own; the editor's port is AMIGA.AREXX's (phase 2).
           (setf (mui-editor-app editor)
                 (mui:new-object :application
                                 m:+muia-application-title+ "Clamacs"
                                 m:+muia-application-version+ "$VER: Clamacs (Lisp)"
                                 m:+muia-application-description+ "Emacs-flavoured Common Lisp IDE"))
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
                    (run-loop editor)))
             ;; Order: no more calls from the other threads (waiters are
             ;; woken with the shutdown answer), then the port and the
             ;; client thread, then the windows.
             (close-mailbox editor)
             (when (and *wire-stopper* (editor-wire editor))
               (handler-case (funcall *wire-stopper* editor)
                 (error (e) (report-error editor e))))
             (dolist (doc (editor-documents editor))
               (setf (doc-closing doc) t))
             (reap editor)
             (mui:dispose-object (mui-editor-app editor))
             (setf (mui-editor-app editor) nil)
             (free-mailbox editor)))
      (setf *editor* nil))
    t))
