;;;; keymap.lisp -- key encoding, keymaps and the prefix-key state machine.
;;;;
;;;; Pure: no MUI and no OS types, so the whole engine is exercised by
;;;; tests/test-keymap.lisp on the host.  The frontend does one job this file
;;;; cannot: turn a raw key event into a key (rawkey.lisp holds the rules).
;;;; Everything after that -- prefix maps, C-u arguments, ESC-as-Meta, C-g --
;;;; happens here.
;;;;
;;;; Why the editor owns its bindings at all: TextEditor.mcc resolves keys
;;;; through a table taken from the USER's MUI preferences, and although
;;;; MUIA_TextEditor_KeyBindings exists in the header, nothing in the class
;;;; reads it (checked against the 15.56 sources).  An application cannot hand
;;;; the class a table, so the Emacs layer sees keys first in MUIM_HandleEvent
;;;; and passes what it does not bind down to the superclass.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; Key encoding
;;;
;;; A key is a fixnum: a 16-bit key code in the low half and modifier bits
;;; above it.  Codes #x01..#xFF are ISO-8859-1 characters (the editor is
;;; 8-bit, matching clamiga's narrow strings); codes from +KEY-UP+ up name
;;; the keys that have no character.  "No key" is NIL.  A fixnum because it
;;; is the EQL hash key of every keymap lookup, once per keystroke.
;;; ------------------------------------------------------------------

(defconstant +mod-ctrl+  #x10000)
(defconstant +mod-meta+  #x20000)
(defconstant +mod-shift+ #x40000)
(defconstant +mod-mask+  #x70000)

(defconstant +key-backspace+ #x08)
(defconstant +key-tab+       #x09)
(defconstant +key-return+    #x0D)
(defconstant +key-esc+       #x1B)
(defconstant +key-space+     #x20)
(defconstant +key-delete+    #x7F)

;;; Keys with no character.  Kept above #xFF so a code and a character never
;;; collide.
(defconstant +key-up+       #x100)
(defconstant +key-down+     #x101)
(defconstant +key-left+     #x102)
(defconstant +key-right+    #x103)
(defconstant +key-home+     #x104)
(defconstant +key-end+      #x105)
(defconstant +key-pageup+   #x106)
(defconstant +key-pagedown+ #x107)
(defconstant +key-insert+   #x108)
(defconstant +key-help+     #x109)
(defconstant +key-f1+       #x10A)      ; F1..F10 are +key-f1+ + 0 .. + 9
(defconstant +key-f10+      #x113)

(declaim (inline key-code key-mods))

(defun key-code (key)
  (declare (fixnum key))
  (logand key #xFFFF))

(defun key-mods (key)
  (declare (fixnum key))
  (logand key +mod-mask+))

(defun make-key (code &optional (mods 0))
  "Build a key, normalising the combinations that would otherwise give one
keystroke two spellings: Control plus a letter is stored lowercase (C-f and
C-S-f are one key), and Shift is dropped for printable characters, where
the shift is already expressed in the character ('<' is not S-',')."
  (declare (fixnum code mods))
  (let ((mods (logand mods +mod-mask+)))
    (declare (fixnum mods))
    (when (and (/= 0 (logand mods +mod-ctrl+)) (<= 65 code 90))
      (setq code (+ code 32)))
    ;; Keeping the bit would make `M-<' unbindable.
    (when (<= #x20 code #xFF)
      (setq mods (logand mods (lognot +mod-shift+))))
    (logior code mods)))

;;; Spelling table.  The first entry for a code is the one printed; later
;;; entries are accepted aliases.
(defparameter *named-keys*
  `(("SPC" . ,+key-space+) ("TAB" . ,+key-tab+) ("RET" . ,+key-return+)
    ("ESC" . ,+key-esc+) ("DEL" . ,+key-delete+) ("BS" . ,+key-backspace+)
    ("<up>" . ,+key-up+) ("<down>" . ,+key-down+)
    ("<left>" . ,+key-left+) ("<right>" . ,+key-right+)
    ("<home>" . ,+key-home+) ("<end>" . ,+key-end+)
    ("<prior>" . ,+key-pageup+) ("<next>" . ,+key-pagedown+)
    ("<pageup>" . ,+key-pageup+) ("<pagedown>" . ,+key-pagedown+)
    ("<insert>" . ,+key-insert+) ("<help>" . ,+key-help+)
    ("<f1>" . ,(+ +key-f1+ 0)) ("<f2>" . ,(+ +key-f1+ 1))
    ("<f3>" . ,(+ +key-f1+ 2)) ("<f4>" . ,(+ +key-f1+ 3))
    ("<f5>" . ,(+ +key-f1+ 4)) ("<f6>" . ,(+ +key-f1+ 5))
    ("<f7>" . ,(+ +key-f1+ 6)) ("<f8>" . ,(+ +key-f1+ 7))
    ("<f9>" . ,(+ +key-f1+ 8)) ("<f10>" . ,(+ +key-f1+ 9))))

(defun key-to-string (key)
  "Emacs spelling of KEY: \"C-x\", \"M-f\", \"C-M-f\", \"C-SPC\", \"TAB\",
\"RET\", \"ESC\", \"DEL\", \"<up>\", \"<f1>\".  The empty string for NIL."
  (if (null key)
      ""
      (let* ((code (key-code key))
             (mods (key-mods key))
             (name (car (rassoc code *named-keys*))))
        (concatenate 'string
                     (if (/= 0 (logand mods +mod-ctrl+)) "C-" "")
                     (if (/= 0 (logand mods +mod-meta+)) "M-" "")
                     (if (/= 0 (logand mods +mod-shift+)) "S-" "")
                     (cond (name name)
                           ((<= #x20 code #xFF) (string (code-char code)))
                           ;; A control character with no name.
                           (t "<?>"))))))

(defun key-from-string (text)
  "Inverse of KEY-TO-STRING; NIL when the spelling is not understood."
  (let ((mods 0)
        (pos 0)
        (len (length text)))
    (declare (fixnum mods pos len))
    ;; Modifier prefixes.  The length test keeps "C--" (control and minus)
    ;; and a bare "-" working.
    (loop
      (unless (and (< (+ pos 2) len) (char= (char text (1+ pos)) #\-))
        (return))
      (case (char text pos)
        (#\C (setq mods (logior mods +mod-ctrl+)))
        (#\M (setq mods (logior mods +mod-meta+)))
        (#\S (setq mods (logior mods +mod-shift+)))
        (t (return)))
      (incf pos 2))
    (let* ((rest (subseq text pos))
           (named (assoc rest *named-keys* :test #'string=)))
      (cond (named (make-key (cdr named) mods))
            ((= (length rest) 1) (make-key (char-code (char rest 0)) mods))
            (t nil)))))

;;; ------------------------------------------------------------------
;;; Keymaps
;;;
;;; An EQL hash table from key to binding.  A binding is a command (a
;;; symbol, see command.lisp) or another KEYMAP, which makes the key a
;;; prefix.
;;; ------------------------------------------------------------------

(defstruct (keymap (:constructor %make-keymap (name)))
  name
  (table (make-hash-table :test 'eql)))

(defun make-keymap (name)
  (%make-keymap name))

(defun keymap-count (map)
  (hash-table-count (keymap-table map)))

(defun keymap-bind (map key binding)
  "Bind KEY in MAP to BINDING, a command symbol or a KEYMAP.  Rebinding
replaces.  Returns T, or NIL when KEY is NIL or BINDING is neither."
  (when (and key binding (or (symbolp binding) (keymap-p binding)))
    (setf (gethash key (keymap-table map)) binding)
    t))

(defun keymap-lookup (map key)
  "The binding of KEY in MAP, or NIL.  MAP may be NIL."
  (and map key (values (gethash key (keymap-table map)))))

(defun split-key-sequence (keys)
  "The keys spelled in KEYS (\"C-x C-f\") as a list, or NIL when KEYS is
empty or one of the spellings is not understood."
  (let ((result '())
        (pos 0)
        (len (length keys)))
    (loop
      (loop while (and (< pos len) (char= (char keys pos) #\Space))
            do (incf pos))
      (when (>= pos len)
        (return (nreverse result)))
      (let* ((end (or (position #\Space keys :start pos) len))
             (key (key-from-string (subseq keys pos end))))
        (unless key
          (return nil))
        (push key result)
        (setq pos end)))))

(defun keymap-bind-seq (map keys command)
  "Bind a key given by its Emacs spelling.  \"C-x C-f\" binds through prefix
maps, creating them as needed under MAP; an intermediate key that is bound
to a command becomes a prefix.  Returns T, or NIL when KEYS does not parse."
  (let ((seq (split-key-sequence keys)))
    (when (and seq command (symbolp command))
      (loop
        (let ((key (pop seq)))
          (when (null seq)
            (return (keymap-bind map key command)))
          (let ((sub (keymap-lookup map key)))
            (unless (keymap-p sub)
              (setq sub (make-keymap (keymap-name map)))
              (keymap-bind map key sub))
            (setq map sub)))))))

;;; ------------------------------------------------------------------
;;; The key state machine
;;; ------------------------------------------------------------------

(defconstant +max-seq+ 4)

(defstruct (keystate (:constructor make-keystate (global &optional local)))
  global
  local                     ; mode map, consulted first; may be NIL
  ;; Inside a prefix, BOTH sides stay live.  The Lisp map binds `C-x C-e'
  ;; and the global map binds `C-x C-f' on the same prefix key, so entering
  ;; the local C-x map must not hide the global one -- otherwise turning on
  ;; Lisp mode would break find-file.
  (pending nil)             ; the local prefix map, or NIL
  (pending-global nil)      ; the global prefix map, or NIL
  (in-prefix nil)           ; a sequence is in progress
  (seq '())                 ; the keys of the sequence, newest first
  (meta-pending nil)        ; ESC was seen: the next key gains Meta
  ;; C-u state.  ARG-VALID says an argument was actually given, which is
  ;; what distinguishes `C-u 0 C-k' from a plain C-k.
  (arg 0 :type fixnum)
  (arg-valid nil)
  (arg-reading nil)         ; digits are being accumulated
  (arg-negative nil)
  ;; The argument that belongs to the command just returned.  FEED moves it
  ;; here and clears the accumulator, so a caller that forgets to read it
  ;; cannot leak an argument into the next command.
  (last-arg 1 :type fixnum)
  (last-arg-given nil))

(defun keystate-reset-arg (st)
  (setf (keystate-arg st) 0
        (keystate-arg-valid st) nil
        (keystate-arg-reading st) nil
        (keystate-arg-negative st) nil))

(defun keystate-reset (st)
  (setf (keystate-pending st) nil
        (keystate-pending-global st) nil
        (keystate-in-prefix st) nil
        (keystate-seq st) '()
        (keystate-meta-pending st) nil)
  (keystate-reset-arg st))

(defun keystate-end (st)
  ;; End a sequence, but KEEP the keys in it.  The echo area has to be able
  ;; to say "C-x C-q is undefined", and by the time the caller hears about it
  ;; the sequence is over -- so it is cleared at the start of the next key.
  (setf (keystate-pending st) nil
        (keystate-pending-global st) nil
        (keystate-in-prefix st) nil
        (keystate-meta-pending st) nil)
  (keystate-reset-arg st))

(defun keystate-push (st key)
  (when (< (length (keystate-seq st)) +max-seq+)
    (push key (keystate-seq st))))

(defun keystate-feed (st key)
  "Feed one key.  Returns one of
  :UNBOUND    nothing matched at top level -- let the superclass have it,
              which is how the class's own arrows, Home/End, mouse selection
              and self-insert keep working
  :PREFIX     a prefix map is pending; echo the sequence
  :COMMAND    the second value is the command to run
  :UNDEFINED  the sequence ended with no binding
  :ARG        consumed by the C-u numeric-argument reader
  :CANCEL     C-g cancelled a pending sequence or argument"
  (when (null key)
    (return-from keystate-feed :unbound))
  ;; The previous sequence stays readable until the next key arrives.
  (unless (keystate-in-prefix st)
    (setf (keystate-seq st) '()))
  ;; ESC is a Meta prefix as well as Alt, for keyboards and users where Alt
  ;; is awkward or is eaten by the window manager.
  (cond ((keystate-meta-pending st)
         (setf (keystate-meta-pending st) nil)
         (setq key (make-key (key-code key)
                             (logior (key-mods key) +mod-meta+))))
        ((eql key +key-esc+)
         (setf (keystate-meta-pending st) t)
         (return-from keystate-feed :prefix)))
  (let ((code (key-code key))
        (mods (key-mods key)))
    (declare (fixnum code mods))
    ;; C-g abandons whatever is half-typed.  With nothing pending it falls
    ;; through so keyboard-quit itself can run.
    (when (and (eql key (logior 103 +mod-ctrl+)) ; C-g
               (or (keystate-in-prefix st)
                   (keystate-seq st)
                   (keystate-arg-valid st)))
      (keystate-reset st)
      (return-from keystate-feed :cancel))
    ;; --- the C-u numeric argument ---
    ;; Only at top level: inside a prefix map a digit is a key like any
    ;; other (`C-x 2' must not be read as an argument).
    (unless (keystate-in-prefix st)
      (when (eql key (logior 117 +mod-ctrl+)) ; C-u
        ;; C-u, C-u C-u, ... multiply by four; digits after a C-u replace
        ;; the accumulated value, as in Emacs.
        (setf (keystate-arg st) (if (keystate-arg-valid st)
                                    (* (keystate-arg st) 4)
                                    4)
              (keystate-arg-valid st) t
              (keystate-arg-reading st) nil)
        (return-from keystate-feed :arg))
      (when (and (keystate-arg-valid st)
                 (or (= mods 0) (= mods +mod-meta+)))
        (when (<= 48 code 57)
          (if (keystate-arg-reading st)
              (setf (keystate-arg st) (+ (* (keystate-arg st) 10) (- code 48)))
              (setf (keystate-arg st) (- code 48)
                    (keystate-arg-reading st) t))
          (return-from keystate-feed :arg))
        (when (and (= code 45)
                   (not (keystate-arg-reading st))
                   (not (keystate-arg-negative st)))
          (setf (keystate-arg-negative st) t
                (keystate-arg st) 1)
          (return-from keystate-feed :arg)))
      ;; M-1 .. M-9 and M-- start an argument without a preceding C-u.
      (when (and (not (keystate-arg-valid st)) (= mods +mod-meta+))
        (when (<= 48 code 57)
          (setf (keystate-arg st) (- code 48)
                (keystate-arg-valid st) t
                (keystate-arg-reading st) t)
          (return-from keystate-feed :arg))
        (when (= code 45)
          (setf (keystate-arg st) 1
                (keystate-arg-valid st) t
                (keystate-arg-negative st) t)
          (return-from keystate-feed :arg)))))
  ;; --- binding lookup ---
  ;; Both sides are consulted at every step, not just the first: local wins
  ;; where it has something, and the global map still answers for the keys
  ;; the local map leaves alone -- including inside a prefix the two share.
  (let* ((in-prefix (keystate-in-prefix st))
         (local (keymap-lookup (if in-prefix
                                   (keystate-pending st)
                                   (keystate-local st))
                               key))
         (global (keymap-lookup (if in-prefix
                                    (keystate-pending-global st)
                                    (keystate-global st))
                                key))
         (binding (or local global)))
    (keystate-push st key)
    (cond ((null binding)
           (setf (keystate-last-arg st) 1
                 (keystate-last-arg-given st) nil)
           (keystate-end st)
           ;; `C-x C-q' with nothing bound: the sequence is ours and it is
           ;; undefined.  The caller reports it; the key must not reach the
           ;; superclass, or C-x C-q would insert a `q'.
           (if in-prefix :undefined :unbound))
          ((keymap-p binding)
           (setf (keystate-pending st) (and (keymap-p local) local)
                 (keystate-pending-global st) (and (keymap-p global) global)
                 (keystate-in-prefix st) t)
           :prefix)
          (t
           ;; Hand the argument to the command that was just resolved, and
           ;; clear it here rather than trusting every caller to consume it.
           (setf (keystate-last-arg st)
                 (cond ((not (keystate-arg-valid st)) 1)
                       ((keystate-arg-negative st) (- (keystate-arg st)))
                       (t (keystate-arg st)))
                 (keystate-last-arg-given st) (keystate-arg-valid st))
           (keystate-end st)
           (values :command binding)))))

(defun keystate-describe (st)
  "The pending sequence as text for the echo area: \"C-x -\", \"C-u 4 C-x -\"."
  (with-output-to-string (out)
    (when (keystate-arg-valid st)
      (format out "C-u ~D " (if (keystate-arg-negative st)
                                (- (keystate-arg st))
                                (keystate-arg st))))
    (dolist (key (reverse (keystate-seq st)))
      (write-string (key-to-string key) out)
      (write-char #\Space out))
    (when (keystate-meta-pending st)
      (write-string "ESC " out))
    (when (or (keystate-in-prefix st)
              (keystate-meta-pending st)
              (keystate-arg-valid st))
      (write-string "-" out))))

(defun keystate-take-arg (st)
  "The numeric argument for the command just returned: the given argument,
or 1 when none was given.  Reading it clears it, so every command sees
either its own argument or the default."
  (prog1 (keystate-last-arg st)
    (setf (keystate-last-arg st) 1
          (keystate-last-arg-given st) nil)))

(defun keystate-arg-given-p (st)
  "Whether an argument was actually typed (for commands whose behaviour
differs between `C-k' and `C-u 1 C-k')."
  (keystate-last-arg-given st))
