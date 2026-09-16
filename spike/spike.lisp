;;; spike.lisp -- phase 0 of specs/clamacs-lisp.md: is a TextEditor.mcc
;;; subclass whose Emacs layer is Lisp fast enough?
;;;
;;; A clamiga program.  It creates a private subclass of the installed
;;; TextEditor.mcc with AMIGA.MUI:CREATE-CUSTOM-CLASS, registers its OWN
;;; RAWKEY handler node at priority 1 in MUIM_Setup (the phase-1 fact: a
;;; bare MUIM_HandleEvent override on a TextEditor subclass is never
;;; called), and in MUIM_HandleEvent decodes the key through MapRawKey the
;;; way src/emacs/rawkey.c does, looks it up in a keymap, and either runs
;;; the command (RET = newline-and-indent over the exported text, C-x C-c
;;; = quit) or returns 0 so the class's own node edits.
;;;
;;; Every MUIM_HandleEvent is timed with ReadEClock from dispatcher entry
;;; to return; the report (median, max, RET separately, GC counters, ROOM)
;;; goes to Clamacs:build/amiga/spike.log and the buffer's final text to
;;; Clamacs:build/amiga/spike-buffer.txt, so the run can check that what
;;; was typed is what arrived.  spike/run-spike.sh drives it in FS-UAE.
;;;
;;;   clamiga --heap 8M --non-interactive --load Clamacs:spike/spike.lisp

(require "amiga/mui")
(require "amiga/exec")
(require "amiga/raw/exec")
(require "amiga/raw/intuition")
(require "amiga/raw/keymap")
(require "amiga/raw/timer")
(require "amiga/raw/muimaster")

(defpackage "CLAMACS-SPIKE"
  (:use "CL")
  (:local-nicknames ("MUI" "AMIGA.MUI")
                    ("M" "AMIGA.RAW.MUIMASTER")
                    ("EXEC" "AMIGA.RAW.EXEC")
                    ("KEYMAP" "AMIGA.RAW.KEYMAP")
                    ("TIMER" "AMIGA.RAW.TIMER")))
(in-package "CLAMACS-SPIKE")

;;; ---------------------------------------------------------------- log

(defvar *out-dir*
  (if (boundp 'cl-user::*spike-out*) (symbol-value 'cl-user::*spike-out*) "Clamacs:build/amiga/")
  "Where the log, the buffer copy and the ready sentinel go; a run on
real hardware sets CL-USER::*SPIKE-OUT* before loading this file.")
(defvar *log-path* (concatenate 'string *out-dir* "spike.log"))
(defvar *buffer-path* (concatenate 'string *out-dir* "spike-buffer.txt"))
(defvar *ready-path* (concatenate 'string *out-dir* "spike-ready"))

(defun log-line (fmt &rest args)
  (let ((line (apply #'format nil fmt args)))
    (format t "~A~%" line) (finish-output)
    (with-open-file (s *log-path* :direction :output :if-exists :append
                                  :if-does-not-exist :create)
      (write-line line s))))

;;; ---------------------------------------------------------------- constants

;; TextEditor.mcc (mui/TextEditor_mcc.h): TextEditor_Dummy = 0xad000000
(defconstant +te-base+ #xad000000)
(defconstant +tea-fixed-font+   (+ +te-base+ #x0a))
(defconstant +tea-export-hook+  (+ +te-base+ #x08))
(defconstant +tea-import-hook+  (+ +te-base+ #x0e))
(defconstant +tea-cursor-index+ (+ +te-base+ #x42))
(defconstant +tem-export-text+  (+ +te-base+ #x25))
(defconstant +tem-insert-text+  (+ +te-base+ #x26))
(defconstant +tev-export-hook-nostyle+ 2)
(defconstant +tev-import-hook-plain+ 0)
(defconstant +tev-insert-text-cursor+ 0)

;; struct MUIP_HandleEvent { ULONG MethodID; struct IntuiMessage *imsg; LONG muikey; }
(defconstant +hev-imsg-offset+ 4)
;; struct IntuiMessage (intuition/intuition.h): Class 20, Code 24, Qualifier 26, IAddress 28
(defconstant +imsg-class-offset+ 20)
(defconstant +imsg-code-offset+ 24)
(defconstant +imsg-qualifier-offset+ 26)
(defconstant +imsg-iaddress-offset+ 28)
;; struct MUI_EventHandlerNode (libraries/mui.h): MinNode 0, Reserved 8,
;; Priority 9, Flags 10, Object 12, Class 16, Events 20; 24 bytes
(defconstant +ehn-size+ 24)
(defconstant +ehn-priority-offset+ 9)
(defconstant +ehn-flags-offset+ 10)
(defconstant +ehn-object-offset+ 12)
(defconstant +ehn-class-offset+ 16)
(defconstant +ehn-events-offset+ 20)
;; struct InputEvent (devices/inputevent.h): NextEvent 0, Class 4 (UBYTE),
;; SubClass 5, Code 6, Qualifier 8, EventAddress 10, TimeStamp 14; 22 bytes
(defconstant +ie-size+ 22)
(defconstant +ie-class-offset+ 4)
(defconstant +ie-code-offset+ 6)
(defconstant +ie-qualifier-offset+ 8)
(defconstant +ie-eventaddress-offset+ 10)
(defconstant +ieclass-rawkey+ 1)
(defconstant +idcmp-rawkey+ #x400)
;; mri_WindowObject is the first field of struct MUI_RenderInfo
(defconstant +mri-window-object-offset+ 0)

;; IEQUALIFIER_* (src/emacs/rawkey.h restates the same values)
(defconstant +q-lshift+ #x0001) (defconstant +q-rshift+ #x0002)
(defconstant +q-capslock+ #x0004) (defconstant +q-control+ #x0008)
(defconstant +q-lalt+ #x0010) (defconstant +q-ralt+ #x0020)
(defconstant +q-lcommand+ #x0040) (defconstant +q-rcommand+ #x0080)
(defconstant +q-numericpad+ #x0100)
(defconstant +q-map-mask+ (logior +q-lshift+ +q-rshift+ +q-capslock+ +q-numericpad+))
(defconstant +raw-up-prefix+ #x80)

;; ck_key-style encoding: character code (or a special >= 1000) | mods << 16
(defconstant +mod-ctrl+ 1) (defconstant +mod-meta+ 2) (defconstant +mod-shift+ 4)
(defconstant +key-return+ 13) (defconstant +key-tab+ 9)
(defconstant +key-up+ 1000) (defconstant +key-down+ 1001)
(defconstant +key-right+ 1002) (defconstant +key-left+ 1003) (defconstant +key-help+ 1004)
(defconstant +key-f1+ 1010)

(declaim (inline make-key))
(defun make-key (code mods) (logior code (ash mods 16)))
(defun key-code (key) (logand key #xFFFF))
(defun key-mods (key) (ash key -16))

(defun key (spec)
  "\"C-x\" / \"M-<\" / \"RET\" -> key integer, the spike's spelling."
  (let ((mods 0) (i 0))
    (loop while (and (< (+ i 1) (length spec)) (char= (char spec (1+ i)) #\-)
                     (member (char spec i) '(#\C #\M #\S)))
          do (setf mods (logior mods (ecase (char spec i) (#\C +mod-ctrl+) (#\M +mod-meta+) (#\S +mod-shift+))))
             (incf i 2))
    (let ((rest (subseq spec i)))
      (make-key (cond ((string= rest "RET") +key-return+)
                      ((string= rest "TAB") +key-tab+)
                      ((= (length rest) 1) (char-code (char rest 0)))
                      (t (error "spike: unknown key ~S" spec)))
                mods))))

;;; ---------------------------------------------------------------- clock

(defvar *timer-io* nil)
(defvar *timer-port* nil)
(defvar *eclock-buf* nil)
(defvar *eclock-freq* nil)

(defun open-clock ()
  "timer.device unit MICROHZ, so ReadEClock is callable; falls back to
GET-INTERNAL-REAL-TIME (milliseconds) if the device will not open."
  (handler-case
      (let* ((port (or (amiga.exec:create-msg-port) (error "no msg port")))
             (io (or (amiga.exec:create-io-request port 40) (error "no io request"))))
        (setf *timer-port* port *timer-io* io)
        (unless (zerop (amiga.exec:open-device "timer.device" 0 io))
          (error "OpenDevice(timer.device) failed"))
        (setf timer:*timer-base* (amiga.exec:io-request-device io))
        (setf *eclock-buf* (ffi:alloc-foreign 8))
        (setf *eclock-freq* (timer:read-e-clock *eclock-buf*))
        (log-line "clock: ReadEClock at ~D Hz" *eclock-freq*))
    (error (e)
      (log-line "clock: FALLBACK to millisecond clock (~A)" e)
      (setf *eclock-freq* nil))))

(defun close-clock ()
  (when *timer-io*
    (when timer:*timer-base* (amiga.exec:close-device *timer-io*))
    (amiga.exec:delete-io-request *timer-io*)
    (setf *timer-io* nil timer:*timer-base* nil))
  (when *timer-port* (amiga.exec:delete-msg-port *timer-port*) (setf *timer-port* nil)))

(declaim (inline now-ticks))
(defun now-ticks ()
  (if *eclock-freq*
      (progn (timer:read-e-clock *eclock-buf*) (ffi:peek-u32 *eclock-buf* 4))
      (get-internal-real-time)))

(defun ticks->us (dt)
  (if *eclock-freq*
      (floor (* dt 1000) (floor *eclock-freq* 1000))
      (* dt 1000)))

;;; ---------------------------------------------------------------- stats

(defconstant +max-samples+ 8192)
(defvar *all-us* (make-array +max-samples+ :initial-element 0))
(defvar *all-n* 0)
(defvar *ret-us* (make-array 512 :initial-element 0))
(defvar *ret-n* 0)
(defvar *eaten* 0)
(defvar *passed* 0)
(defvar *dropped* 0)                    ; releases, Amiga-key combos, dead keys
(defvar *errors* 0)

(defun record (us eaten ret)
  (when (< *all-n* +max-samples+) (setf (svref *all-us* *all-n*) us) (incf *all-n*))
  (when (and ret (< *ret-n* 512)) (setf (svref *ret-us* *ret-n*) us) (incf *ret-n*))
  (if eaten (incf *eaten*) (incf *passed*)))

(defun percentile (vec n p)
  (if (zerop n) 0
      (let ((v (sort (subseq vec 0 n) #'<)))
        (svref v (min (1- n) (floor (* p n) 100))))))

(defun vmax (vec n) (if (zerop n) 0 (loop for i below n maximize (svref vec i))))

;;; ---------------------------------------------------------------- indentation

(defparameter *body-forms*
  '("defun" "defmacro" "defmethod" "let" "let*" "when" "unless" "lambda" "loop"
    "dolist" "dotimes" "progn" "if" "cond" "case" "ecase" "flet" "labels"
    "defvar" "defparameter" "with-open-file" "handler-case" "unwind-protect"
    "multiple-value-bind" "destructuring-bind" "do" "block" "return-from"))

(defun line-column (text pos)
  "Column of POS in TEXT."
  (- pos (1+ (or (position #\Newline text :end pos :from-end t) -1))))

(defun indent-at-paren (text end popen)
  "Indentation for a new line at END given POPEN, the innermost open paren
before it: body forms indent 2 past it, a form whose first argument is
on the paren's line aligns with that argument, anything else 1 past it."
  (let* ((pcol (line-column text popen))
         (hstart (1+ popen))
         (hend (or (position-if (lambda (ch) (member ch '(#\Space #\Tab #\Newline #\( #\))))
                                text :start hstart :end end)
                   end))
         (head (subseq text hstart hend)))
    (cond ((or (zerop (length head)) (char= (char head 0) #\()) (1+ pcol))
          ((member head *body-forms* :test #'string-equal) (+ pcol 2))
          (t (let ((argpos (position-if-not (lambda (ch) (member ch '(#\Space #\Tab)))
                                            text :start hend :end end)))
               (if (and argpos (not (char= (char text argpos) #\Newline))
                        (not (find #\Newline text :start popen :end argpos)))
                   (line-column text argpos)
                   (1+ pcol)))))))

(defun compute-indent (text end)
  "The naive scan: generic CHAR, MEMBER per character, no declarations."
  (let ((stack '()) (in-string nil) (in-comment nil) (i 0))
    (loop while (< i end)
          do (let ((c (char text i)))
               (cond ((char= c #\Newline) (setf in-comment nil))
                     (in-comment)
                     (in-string (cond ((char= c #\\) (incf i))
                                      ((char= c #\") (setf in-string nil))))
                     ((char= c #\;) (setf in-comment t))
                     ((char= c #\") (setf in-string t))
                     ((char= c #\() (push i stack))
                     ((char= c #\)) (pop stack))))
             (incf i))
    (if (null stack) 0 (indent-at-paren text end (first stack)))))

(defun compute-indent-fast (text end)
  "The same scan as a declared state machine over a SIMPLE-STRING: what
an editor would actually ship, and what the compiler can do with it."
  (declare (optimize (speed 3) (safety 1))
           (type simple-string text) (type fixnum end))
  (let ((stack '()) (state 0) (i 0))
    (declare (type fixnum state i))
    (loop while (< i end)
          do (let ((c (schar text i)))
               (case state
                 (0 (case c
                      (#\( (push i stack))
                      (#\) (pop stack))
                      (#\" (setf state 1))
                      (#\; (setf state 2))))
                 (1 (case c
                      (#\\ (setf state 3))
                      (#\" (setf state 0))))
                 (2 (when (char= c #\Newline) (setf state 0)))
                 (t (setf state 1))))
             (incf i))
    (if (null stack) 0 (indent-at-paren text end (first stack)))))

;;; ---------------------------------------------------------------- the object

(defvar *app* nil)
(defvar *win* nil)
(defvar *text* nil)                     ; the ClamacsText object (foreign pointer)
(defvar *text-addr* 0)
(defvar *ehn* nil)                      ; the handler node, pool-allocated
(defvar *ie* nil)                       ; a struct InputEvent for MapRawKey
(defvar *mapbuf* nil)                   ; MapRawKey's output buffer
(defvar *prefix* nil)                   ; pending prefix keys, e.g. (C-x)
(defvar *quit-requested* nil)

(defun export-text (object)
  "MUIM_TextEditor_ExportText: the buffer as a Lisp string (the class's
copy is FreeVec'd)."
  (let ((addr (mui:do-method object +tem-export-text+)))
    (if (zerop addr)
        ""
        (let ((fp (ffi:make-foreign-pointer addr)))
          (unwind-protect (ffi:foreign-to-string fp)
            (exec:free-vec fp))))))

(defun insert-text (object string)
  (ffi:with-foreign-string (p string)
    (mui:do-method object +tem-insert-text+ p +tev-insert-text-cursor+)))

(defun window-object (object)
  (let ((ri (mui:area-render-info object)))
    (and ri (not (ffi:null-pointer-p ri))
         (ffi:make-foreign-pointer (ffi:peek-u32 ri +mri-window-object-offset+)))))

(defun active-p (object)
  "Whether OBJECT is its window's active object (MUI hands a RAWKEY to
every registered handler; TextEditor.mcc checks this too)."
  (let ((win (window-object object)))
    (or (null win)
        (eql (mui:get-attr m:+muia-window-active-object+ win)
             (ffi:foreign-pointer-address object)))))

;;; --- commands

(defvar *ret-export-us* 0) (defvar *ret-indent-us* 0) (defvar *ret-indent-fast-us* 0)
(defvar *ret-insert-us* 0) (defvar *ret-chars* 0) (defvar *indent-disagreements* 0)

(defun elapsed-us (t0 t1) (ticks->us (logand (- t1 t0) #xFFFFFFFF)))

(defun cmd-newline-and-indent (object)
  (let* ((t0 (now-ticks))
         (text (export-text object))
         (index (or (mui:get-attr +tea-cursor-index+ object) (length text)))
         (end (min index (length text)))
         (t1 (now-ticks))
         (indent (compute-indent text end))
         (t2 (now-ticks))
         (indent-fast (compute-indent-fast (coerce text 'simple-string) end))
         (t3 (now-ticks)))
    (unless (= indent indent-fast) (incf *indent-disagreements*))
    (insert-text object (concatenate 'string (string #\Newline)
                                     (make-string indent :initial-element #\Space)))
    (let ((t4 (now-ticks)))
      (incf *ret-export-us* (elapsed-us t0 t1))
      (incf *ret-indent-us* (elapsed-us t1 t2))
      (incf *ret-indent-fast-us* (elapsed-us t2 t3))
      (incf *ret-insert-us* (elapsed-us t3 t4))
      (incf *ret-chars* (length text))
      (log-line "RET ~D: ~D chars, export ~D us, indent ~D us (fast ~D us), insert ~D us"
                (1+ *ret-n*) (length text) (elapsed-us t0 t1) (elapsed-us t1 t2)
                (elapsed-us t2 t3) (elapsed-us t3 t4)))
    t))

(defun cmd-quit (object)
  (declare (ignore object))
  (setf *quit-requested* t)
  (mui:do-method *app* m:+muim-application-return-id+ m:+muiv-application-return-id-quit+)
  t)

(defvar *keymap* (make-hash-table))     ; key -> command, or a nested table for a prefix

(defun split-spaces (s)
  (loop with start = 0
        for pos = (position #\Space s :start start)
        collect (subseq s start pos)
        while pos do (setf start (1+ pos))))

(defun bind (spec command)
  "(bind \"C-x C-c\" #'cmd): a prefix key holds a nested table."
  (let ((keys (mapcar #'key (split-spaces spec)))
        (table *keymap*))
    (loop while (rest keys)
          do (let ((sub (gethash (first keys) table)))
               (unless (hash-table-p sub)
                 (setf sub (make-hash-table)
                       (gethash (first keys) table) sub))
               (setf table sub keys (rest keys))))
    (setf (gethash (first keys) table) command)))

(defun lookup (key)
  "Command for KEY given the pending prefix table: a function, :PREFIX
when KEY opens one, :UNBOUND after a prefix, NIL for a key the class edits."
  (let* ((table (or *prefix* *keymap*))
         (hit (gethash key table)))
    (cond ((hash-table-p hit) (setf *prefix* hit) :prefix)
          (hit (setf *prefix* nil) hit)
          (*prefix* (setf *prefix* nil) :unbound)
          (t nil))))

;;; --- key decoding, src/emacs/rawkey.c's rules

(defun decode-key (imsg)
  "IntuiMessage -> key integer, or NIL for anything the Emacs layer must
leave to the class: releases, Amiga-key combos, keys without one character."
  (let ((code (ffi:peek-u16 imsg +imsg-code-offset+))
        (qual (ffi:peek-u16 imsg +imsg-qualifier-offset+)))
    (when (or (logtest code +raw-up-prefix+)
              (logtest qual (logior +q-lcommand+ +q-rcommand+)))
      (return-from decode-key nil))
    (let ((mods (logior (if (logtest qual +q-control+) +mod-ctrl+ 0)
                        (if (logtest qual (logior +q-lalt+ +q-ralt+)) +mod-meta+ 0)
                        (if (logtest qual (logior +q-lshift+ +q-rshift+)) +mod-shift+ 0))))
      (case code
        (#x4C (return-from decode-key (make-key +key-up+ mods)))
        (#x4D (return-from decode-key (make-key +key-down+ mods)))
        (#x4E (return-from decode-key (make-key +key-right+ mods)))
        (#x4F (return-from decode-key (make-key +key-left+ mods)))
        (#x5F (return-from decode-key (make-key +key-help+ mods))))
      (when (<= #x50 code #x59)
        (return-from decode-key (make-key (+ +key-f1+ (- code #x50)) mods)))
      ;; the keymap sees Shift and Caps only: base character, our modifiers on top
      (ffi:poke-u8 *ie* +ieclass-rawkey+ +ie-class-offset+)
      (ffi:poke-u16 *ie* code +ie-code-offset+)
      (ffi:poke-u16 *ie* (logand qual +q-map-mask+) +ie-qualifier-offset+)
      (let ((iaddr (ffi:peek-u32 imsg +imsg-iaddress-offset+)))
        (ffi:poke-u32 *ie* (if (zerop iaddr) 0 (ffi:peek-u32 (ffi:make-foreign-pointer iaddr) 0))
                      +ie-eventaddress-offset+))
      (let ((n (keymap:map-raw-key *ie* *mapbuf* 8 0)))
        (if (/= n 1)
            nil
            (let ((ch (ffi:peek-u8 *mapbuf* 0)))
              (if (zerop ch)
                  nil
                  ;; C-x and C-X are the same key
                  (make-key (if (and (/= mods 0) (<= 65 ch 90)) (+ ch 32) ch) mods))))))))

;;; --- the dispatcher

(defun handle-event (class object message)
  (declare (ignore class))
  (let* ((t0 (now-ticks))
         (imsg-addr (ffi:peek-u32 message +hev-imsg-offset+))
         (result 0) (ret nil) (seen nil))
    (when (and (/= imsg-addr 0)
               (= (ffi:peek-u32 (ffi:make-foreign-pointer imsg-addr) +imsg-class-offset+) +idcmp-rawkey+)
               (active-p object))
      (let ((k (decode-key (ffi:make-foreign-pointer imsg-addr))))
        (if (null k)
            (incf *dropped*)
            (let ((cmd (lookup k)))
              (setf seen t ret (= k +key-return+))
              (cond ((eq cmd :prefix) (setf result m:+mui-event-handler-rc-eat+))
                    ((eq cmd :unbound) (setf result m:+mui-event-handler-rc-eat+))
                    ((null cmd))                        ; the class edits
                    ((funcall cmd object) (setf result m:+mui-event-handler-rc-eat+)))))))
    (when seen
      (record (ticks->us (logand (- (now-ticks) t0) #xFFFFFFFF)) (/= result 0) ret)
      (when (zerop (mod (+ *eaten* *passed*) 100))
        (log-line "progress: ~D keys seen, last ~D us" (+ *eaten* *passed*)
                  (svref *all-us* (1- *all-n*)))))
    result))

(defun setup (class object message)
  (let ((ok (mui:do-super-method class object message)))
    (when (/= ok 0)
      (ffi:poke-u8 *ehn* 1 +ehn-priority-offset+)             ; above the class's 0
      (ffi:poke-u16 *ehn* m:+mui-ehf-guimode+ +ehn-flags-offset+)
      (ffi:poke-u32 *ehn* (ffi:foreign-pointer-address object) +ehn-object-offset+)
      (ffi:poke-u32 *ehn* (ffi:foreign-pointer-address class) +ehn-class-offset+)
      (ffi:poke-u32 *ehn* +idcmp-rawkey+ +ehn-events-offset+)
      (mui:do-method (window-object object) m:+muim-window-add-event-handler+ *ehn*))
    ok))

(defun cleanup (class object message)
  (mui:do-method (window-object object) m:+muim-window-rem-event-handler+ *ehn*)
  (mui:do-super-method class object message))

(defun go-active (class object message)
  (let ((r (mui:do-super-method class object message)))
    ;; RET must not fire a default gadget, TAB not cycle, ESC not close
    (mui:set-attrs (window-object object) m:+muia-window-disable-keys+
                   (logior m:+muikeyf-press+ m:+muikeyf-gadget-next+ m:+muikeyf-gadget-prev+
                           m:+muikeyf-gadget-off+ m:+muikeyf-window-close+))
    r))

(defun make-dispatcher ()
  (let ((handle-event-id m:+muim-handle-event+)
        (setup-id m:+muim-setup+)
        (cleanup-id m:+muim-cleanup+)
        (go-active-id m:+muim-go-active+))
    (lambda (class object message)
      (let ((id (mui:method-id message)))
        (cond ((= id handle-event-id) (handle-event class object message))
              ((= id setup-id) (setup class object message))
              ((= id cleanup-id) (cleanup class object message))
              ((= id go-active-id) (go-active class object message))
              (t (mui:do-super-method class object message)))))))

;;; ---------------------------------------------------------------- report

(defun gc-stats ()
  (let ((f (find-symbol "%GC-TIME-STATS" "EXT")))
    (and f (fboundp f) (ignore-errors (funcall f)))))

(defun report (gc0 t-start)
  (let ((gc1 (gc-stats)))
    (log-line "=== spike report ===")
    (log-line "keys seen ~D (eaten ~D, passed to class ~D), dropped events ~D, callback errors ~D"
              (+ *eaten* *passed*) *eaten* *passed* *dropped* *errors*)
    (log-line "all keys: median ~D us, p90 ~D us, max ~D us"
              (percentile *all-us* *all-n* 50) (percentile *all-us* *all-n* 90) (vmax *all-us* *all-n*))
    (log-line "RET (export + both indent scans + insert): n ~D, median ~D us, max ~D us"
              *ret-n* (percentile *ret-us* *ret-n* 50) (vmax *ret-us* *ret-n*))
    (when (plusp *ret-n*)
      (log-line "RET split (mean per RET over ~D, buffer mean ~D chars): export ~D us, indent ~D us (declared state machine ~D us, ~D disagreements), insert ~D us"
                *ret-n* (floor *ret-chars* *ret-n*)
                (floor *ret-export-us* *ret-n*) (floor *ret-indent-us* *ret-n*)
                (floor *ret-indent-fast-us* *ret-n*) *indent-disagreements*
                (floor *ret-insert-us* *ret-n*)))
    (let ((gc (or (find-symbol "GC" "EXT") (find-symbol "GC" "CL-USER"))))
      (when (and gc (fboundp gc))
        (dotimes (i 3)
          (let ((t0 (now-ticks)) (g0 (gc-stats)))
            (funcall gc)
            (let ((g1 (gc-stats)))
              (log-line "explicit full GC #~D on this heap: ~D us~@[ (mark ~,1F ms, sweep ~,1F ms, compact ~,1F ms)~]"
                        (1+ i) (ticks->us (logand (- (now-ticks) t0) #xFFFFFFFF))
                        (and g0 g1 (list (* 1000 (- (nth 3 g1) (nth 3 g0)))
                                         (* 1000 (- (nth 4 g1) (nth 4 g0)))
                                         (* 1000 (- (nth 5 g1) (nth 5 g0)))))))))))
    (when (and gc0 gc1)
      (log-line "GC: collections ~D -> ~D, compactions ~D -> ~D, mark+sweep+compact seconds ~,3F -> ~,3F"
                (nth 0 gc0) (nth 0 gc1) (nth 1 gc0) (nth 1 gc1)
                (+ (nth 3 gc0) (nth 4 gc0) (nth 5 gc0)) (+ (nth 3 gc1) (nth 4 gc1) (nth 5 gc1))))
    (log-line "wall seconds in the event loop: ~,1F"
              (/ (- (get-internal-real-time) t-start) internal-time-units-per-second))
    (log-line "room:")
    (let ((room (with-output-to-string (*standard-output*) (room))))
      (dolist (l (split-lines room)) (log-line "  ~A" l)))
    (log-line "=== end report ===")))

(defun split-lines (s)
  (loop with start = 0
        for pos = (position #\Newline s :start start)
        collect (subseq s start pos)
        while pos do (setf start (1+ pos))))

;;; ---------------------------------------------------------------- main

(defun run ()
  (log-line "spike: ~A; JIT active: ~A" (lisp-implementation-version)
            (let ((f (find-symbol "%JIT-ACTIVE-P" "CLAMIGA"))) (if (and f (fboundp f)) (funcall f) :unknown)))
  (log-line "spike: heap ~A" (with-output-to-string (*standard-output*) (room)))
  (open-clock)
  (bind "RET" #'cmd-newline-and-indent)
  (bind "C-x C-c" #'cmd-quit)
  (mui:with-foreign-pool ()
    (setf *ehn* (mui:pool-alloc +ehn-size+)
          *ie* (mui:pool-alloc +ie-size+)
          *mapbuf* (mui:pool-alloc 8))
    (let* ((mcc (mui:create-custom-class "TextEditor.mcc" (make-dispatcher)))
           (text (mui:new-object (mui:custom-class-class mcc)
                   +tea-fixed-font+ t
                   +tea-export-hook+ +tev-export-hook-nostyle+
                   +tea-import-hook+ +tev-import-hook-plain+))
           (win (mui:new-object :window
                  m:+muia-window-title+ "Clamacs spike (Lisp)"
                  m:+muia-window-width+ 640
                  m:+muia-window-height+ 300
                  m:+muia-window-root-object+ text))
           (app (mui:new-object :application
                  m:+muia-application-title+ "ClamacsSpike"
                  m:+muia-application-window+ win)))
      (setf *app* app *win* win *text* text *text-addr* (ffi:foreign-pointer-address text))
      (unwind-protect
           (let ((gc0 (gc-stats)) (t-start (get-internal-real-time)))
             (mui:notify win m:+muia-window-close-request+ t
                         :application m:+muim-application-return-id+
                         m:+muiv-application-return-id-quit+)
             (mui:set-attrs win m:+muia-window-open+ t)
             (when (zerop (or (mui:get-attr m:+muia-window-open+ win) 0))
               (error "spike: the window would not open"))
             ;; MUI opens the window with no active object; the editor
             ;; gives the text the focus, as a document window does.
             (mui:set-attrs win m:+muia-window-active-object+ text)
             (log-line "spike: window open; the text object is active: ~A" (active-p text))
             (with-open-file (s *ready-path* :direction :output :if-exists :supersede)
               (write-line "ready" s))
             ;; The loop: an error inside a method is caught at the callback
             ;; boundary and re-signaled when APPLICATION-INPUT returns, i.e.
             ;; here -- log it and go on, as the editor's echo area would.
             (loop
               (handler-case
                   (progn (mui:do-application-events ((id) app :timeout nil) nil)
                          (return))
                 (error (e)
                   (incf *errors*)
                   (log-line "spike: ERROR in a method: ~A" e)
                   (when *quit-requested* (return)))))
             (log-line "spike: loop left (quit requested: ~A)" *quit-requested*)
             (with-open-file (s *buffer-path* :direction :output :if-exists :supersede)
               (write-string (export-text text) s))
             (mui:set-attrs win m:+muia-window-open+ nil)
             (report gc0 t-start))
        (mui:dispose-object app)
        (close-clock)))))

(run)
