;;;; test-rawkey.lisp -- raw key decoding, minus the one OS call.  The cases
;;;; of tests/test_rawkey.c.
;;;;
;;;; The mapper below stands in for keymap.library's MapRawKey with a slice
;;;; of the US keymap, and it RECORDS the qualifier it was called with --
;;;; because the rule under test is not only what comes out but what the
;;;; keymap was allowed to see: never Control (C-f would become #x06), never
;;;; Alt (a dead-key accent instead of Meta).

(in-package :clamacs)

;;; A slice of the US keymap: raw code, unshifted, shifted.
(defparameter *us-keymap*
  '((#x10 #\q #\Q) (#x20 #\a #\A) (#x21 #\s #\S) (#x33 #\x #\X)
    (#x36 #\n #\N) (#x38 #\, #\<) (#x39 #\. #\>) (#x0A #\9 #\()
    (#x0B #\0 #\)) (#x0C #\- #\_) (#x40 #\Space #\Space)
    (#x41 8 8)                          ; Backspace
    (#x42 9 9)                          ; Tab
    (#x43 13 13)                        ; Enter
    (#x44 13 13)                        ; Return
    (#x45 27 27)                        ; Esc
    (#x46 127 127)))                    ; Del

(defvar *seen-qualifier* nil)
(defvar *mapper-calls* 0)

(defun fake-map (code qualifier)
  (incf *mapper-calls*)
  (setq *seen-qualifier* qualifier)
  ;; Code 0 is a dead key here: no character on its own.
  (let ((row (and (/= code 0) (assoc code *us-keymap*))))
    (when row
      (let ((c (if (/= 0 (logand qualifier
                                 (logior +qual-lshift+ +qual-rshift+)))
                   (third row)
                   (second row))))
        (if (characterp c) (char-code c) c)))))

(defun decode (code qualifier)
  (setq *mapper-calls* 0
        *seen-qualifier* nil)
  (rawkey-decode code qualifier #'fake-map))

(deftest rawkey-plain-character
  (is-equal (decode #x20 0) (make-key (char-code #\a) 0))
  (is-equal *mapper-calls* 1))

(deftest rawkey-shift-goes-to-the-keymap
  ;; Shift selects the character; the keymap sees it, and the result is the
  ;; shifted character with no Shift modifier of its own.
  (is-equal (decode #x20 +qual-lshift+) (make-key (char-code #\A) 0))
  (is-equal *seen-qualifier* +qual-lshift+)
  (is-equal (decode #x38 +qual-rshift+) (k "<"))
  ;; Caps lock is the keymap's business too.
  (decode #x20 +qual-capslock+)
  (is-equal *seen-qualifier* +qual-capslock+))

(deftest rawkey-control-is-ours
  (is-equal (decode #x36 +qual-control+) (k "C-n"))
  ;; ... and the keymap was not told about it.
  (is-equal (logand *seen-qualifier* +qual-control+) 0))

(deftest rawkey-alt-is-meta
  (is-equal (decode #x33 +qual-lalt+) (k "M-x"))
  (is-equal (logand *seen-qualifier* (logior +qual-lalt+ +qual-ralt+)) 0)
  (is-equal (decode #x33 +qual-ralt+) (k "M-x"))
  ;; M-< is Alt plus Shift plus the comma key: Shift reaches the keymap and
  ;; yields `<'; Alt does not, and becomes Meta.
  (is-equal (decode #x38 (logior +qual-lalt+ +qual-lshift+)) (k "M-<"))
  (is-equal *seen-qualifier* +qual-lshift+))

(deftest rawkey-control-meta-together
  (is-equal (decode #x36 (logior +qual-control+ +qual-lalt+)) (k "C-M-n")))

(deftest rawkey-control-letter-is-case-insensitive
  ;; C-S-n and C-n are one key, as MAKE-KEY promises.
  (is-equal (decode #x36 (logior +qual-control+ +qual-lshift+)) (k "C-n")))

(deftest rawkey-key-release-is-ignored
  (is-equal (decode (logior #x20 +raw-up-prefix+) 0) nil)
  (is-equal *mapper-calls* 0)
  ;; ... the release of a key recognised by code included.
  (is-equal (decode (logior +raw-up+ +raw-up-prefix+) 0) nil))

(deftest rawkey-amiga-keys-are-not-ours
  ;; Amiga+x is MUI's (menu shortcuts) or the OS's; it must not even reach
  ;; the keymaps as an unbound `x'.
  (is-equal (decode #x33 +qual-lcommand+) nil)
  (is-equal (decode #x33 (logior +qual-rcommand+ +qual-lshift+)) nil)
  (is-equal (decode +raw-up+ +qual-lcommand+) nil)
  (is-equal *mapper-calls* 0))

(deftest rawkey-keys-without-a-character
  (is-equal (decode +raw-up+ 0) (make-key +key-up+ 0))
  (is-equal (decode +raw-down+ 0) (make-key +key-down+ 0))
  (is-equal (decode +raw-left+ 0) (make-key +key-left+ 0))
  (is-equal (decode +raw-right+ 0) (make-key +key-right+ 0))
  (is-equal (decode +raw-help+ 0) (make-key +key-help+ 0))
  (is-equal (decode +raw-f1+ 0) (k "<f1>"))
  (is-equal (decode (+ +raw-f1+ 9) 0) (k "<f10>"))
  ;; Recognised by code: the keymap is not consulted.
  (is-equal *mapper-calls* 0)
  ;; The code after F10 is not a function key.
  (is-equal (decode (+ +raw-f1+ 10) 0) nil)
  (is-equal *mapper-calls* 1)
  ;; Modifiers still apply to them.
  (is-equal (decode +raw-up+ +qual-control+) (make-key +key-up+ +mod-ctrl+))
  (is-equal (decode +raw-down+ +qual-lshift+)
            (make-key +key-down+ +mod-shift+)))

(deftest rawkey-control-characters-come-from-the-keymap
  (is-equal (decode #x44 0) (k "RET"))
  (is-equal (decode #x42 0) (k "TAB"))
  (is-equal (decode #x45 0) (k "ESC"))
  (is-equal (decode #x46 0) (k "DEL"))
  (is-equal (decode #x41 0) (k "BS"))
  (is-equal (decode #x40 +qual-control+) (k "C-SPC"))
  (is-equal (decode #x41 +qual-lalt+) (k "M-BS"))
  ;; Shift+Tab keeps its Shift: there is no character to carry it.
  (is-equal (decode #x42 +qual-lshift+) (make-key +key-tab+ +mod-shift+)))

(deftest rawkey-dead-key-and-unmapped-keys-fall-through
  ;; A dead key gives no character on its own: not ours, the class composes
  ;; it with the next key.
  (is-equal (decode #x00 0) nil)
  ;; A code the keymap does not know.
  (is-equal (decode #x7E 0) nil)
  ;; A mapper answering something that is not one 8-bit character.
  (is-equal (rawkey-decode #x20 0 (lambda (code qualifier)
                                    (declare (ignore code qualifier))
                                    0))
            nil)
  (is-equal (rawkey-decode #x20 0 (lambda (code qualifier)
                                    (declare (ignore code qualifier))
                                    #x100))
            nil)
  ;; No mapper at all: only the keys recognised by code decode.
  (is-equal (rawkey-decode #x20 0 nil) nil)
  (is-equal (rawkey-decode +raw-up+ 0 nil) (make-key +key-up+ 0)))

(deftest rawkey-repeat-and-numeric-pad-are-transparent
  ;; Auto-repeat is a keypress like any other.
  (is-equal (decode #x36 (logior +qual-control+ +qual-repeat+)) (k "C-n"))
  (is-equal *seen-qualifier* 0)
  ;; The numeric pad flag is the keymap's business and is passed on.
  (is-equal (decode #x20 +qual-numericpad+) (make-key (char-code #\a) 0))
  (is-equal *seen-qualifier* +qual-numericpad+))

(deftest rawkey-inverse-for-event-synthesis
  (is-equal (rawkey-special +key-up+) +raw-up+)
  (is-equal (rawkey-special (+ +key-f1+ 3)) (+ +raw-f1+ 3))
  (is-equal (rawkey-special +key-f10+) (+ +raw-f1+ 9))
  (is-equal (rawkey-special (char-code #\a)) nil)
  (is-equal (rawkey-special +key-tab+) nil) ; has a character
  (is-equal (rawkey-special +key-home+) nil) ; no raw code on a classic board
  (is-equal (rawkey-qualifier +mod-ctrl+) +qual-control+)
  (is-equal (rawkey-qualifier +mod-meta+) +qual-lalt+)
  (is-equal (rawkey-qualifier (logior +mod-ctrl+ +mod-meta+ +mod-shift+))
            (logior +qual-control+ +qual-lalt+ +qual-lshift+))
  (is-equal (rawkey-qualifier 0) 0)
  ;; Round trip: what the inverse synthesises, the decoder reads back.
  (let ((key (k "C-M-<up>")))
    (is-equal (decode (rawkey-special (key-code key))
                      (rawkey-qualifier (key-mods key)))
              key)))
