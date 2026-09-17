;;;; rawkey.lisp -- IDCMP_RAWKEY to key: the portable part.
;;;;
;;;; Intuition reports a keypress as a raw key code plus a qualifier word,
;;;; and the character it stands for has to be looked up in the keymap.
;;;; Splitting the job in two keeps the decision-making host-testable:
;;;; everything that is a RULE -- which qualifier is Meta, what the keymap
;;;; may be told, which keys are recognised by code rather than by
;;;; character, what to refuse -- lives here and runs under
;;;; tests/test-rawkey.lisp; the one OS call, MapRawKey, is passed in by the
;;;; caller as a function (the MUI frontend supplies the real one, the tests
;;;; a table).
;;;;
;;;; Pure: no MUI and no OS types.  The values below are those from
;;;; <devices/inputevent.h>, fixed by the OS ABI since 1.x, so restating
;;;; them here is what lets the module load on the host.

(in-package :clamacs)

;;; IECODE_UP_PREFIX: set in the code of a key-release event.
(defconstant +raw-up-prefix+ #x80)

;;; IEQUALIFIER_* bits.
(defconstant +qual-lshift+     #x0001)
(defconstant +qual-rshift+     #x0002)
(defconstant +qual-capslock+   #x0004)
(defconstant +qual-control+    #x0008)
(defconstant +qual-lalt+       #x0010)
(defconstant +qual-ralt+       #x0020)
(defconstant +qual-lcommand+   #x0040)
(defconstant +qual-rcommand+   #x0080)
(defconstant +qual-numericpad+ #x0100)
(defconstant +qual-repeat+     #x0200)

;;; The qualifier bits the keymap is allowed to see.  Shift and caps select
;;; the character; Control and Alt are OURS: letting the keymap see Control
;;; would turn C-f into #x06 and lose which letter it was, and Alt would
;;; produce a dead-key accent instead of Meta.
(defconstant +qual-map-mask+ #x0107)    ; shifts, capslock, numericpad

;;; Raw codes of the keys that have no character.
(defconstant +raw-up+    #x4C)
(defconstant +raw-down+  #x4D)
(defconstant +raw-right+ #x4E)
(defconstant +raw-left+  #x4F)
(defconstant +raw-f1+    #x50)          ; F1..F10 are #x50..#x59
(defconstant +raw-help+  #x5F)

(defun rawkey-mods (qualifier)
  (declare (fixnum qualifier))
  (logior (if (/= 0 (logand qualifier +qual-control+)) +mod-ctrl+ 0)
          ;; Meta is Alt, either one (specs/clamacs-ide.md, "Key handling").
          (if (/= 0 (logand qualifier (logior +qual-lalt+ +qual-ralt+)))
              +mod-meta+
              0)
          (if (/= 0 (logand qualifier (logior +qual-lshift+ +qual-rshift+)))
              +mod-shift+
              0)))

(defun rawkey-decode (code qualifier mapper)
  "Decode one raw key event.  Returns NIL for anything the Emacs layer must
not act on -- a key release, a key held with an Amiga (Command) key, a key
without a single-character meaning -- so the caller can pass it to the
superclass untouched.

MAPPER is the keymap lookup, a function of the raw code and the (already
masked) qualifier.  It returns the code of the ONE character the keymap
gives for the key, or NIL for a dead key, a key that maps to a string and a
key with no character: none of those is something the Emacs layer binds,
they belong to the class.  On the Amiga it wraps MapRawKey.  MAPPER may be
NIL; then only the keys recognised by code decode."
  (declare (fixnum code qualifier))
  (cond ((/= 0 (logand code +raw-up-prefix+)) nil)
        ;; The Amiga keys stay free for the OS and for MUI's menu
        ;; shortcuts.  A key held with one of them is not a keystroke of
        ;; ours at all -- not even an unbound one, which would still go
        ;; through the keymaps.
        ((/= 0 (logand qualifier (logior +qual-lcommand+ +qual-rcommand+)))
         nil)
        (t
         (let ((mods (rawkey-mods qualifier))
               ;; The keys that have no character are recognised by raw
               ;; code; the keymap would give nothing useful for them.
               (special (cond ((= code +raw-up+) +key-up+)
                              ((= code +raw-down+) +key-down+)
                              ((= code +raw-right+) +key-right+)
                              ((= code +raw-left+) +key-left+)
                              ((= code +raw-help+) +key-help+)
                              ((<= +raw-f1+ code (+ +raw-f1+ 9))
                               (+ +key-f1+ (- code +raw-f1+)))
                              (t nil))))
           (cond (special (make-key special mods))
                 ((null mapper) nil)
                 (t
                  ;; Shift and caps only: we want the BASE character and add
                  ;; our own modifier bits on top.
                  (let ((char-code (funcall mapper code
                                            (logand qualifier
                                                    +qual-map-mask+))))
                    (and char-code
                         (< 0 char-code #x100)
                         (make-key char-code mods)))))))))

;;; The inverse, for a tool that synthesises events: the raw code of a key
;;; that has no character, or NIL when KEYCODE is a character (whose code
;;; the keymap has to supply); and the qualifier bits for a set of modifiers.

(defun rawkey-special (keycode)
  (declare (fixnum keycode))
  (cond ((= keycode +key-up+) +raw-up+)
        ((= keycode +key-down+) +raw-down+)
        ((= keycode +key-right+) +raw-right+)
        ((= keycode +key-left+) +raw-left+)
        ((= keycode +key-help+) +raw-help+)
        ((<= +key-f1+ keycode +key-f10+) (+ +raw-f1+ (- keycode +key-f1+)))
        (t nil)))

(defun rawkey-qualifier (mods)
  (declare (fixnum mods))
  (logior (if (/= 0 (logand mods +mod-ctrl+)) +qual-control+ 0)
          (if (/= 0 (logand mods +mod-meta+)) +qual-lalt+ 0)
          (if (/= 0 (logand mods +mod-shift+)) +qual-lshift+ 0)))
