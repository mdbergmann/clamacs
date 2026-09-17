;;;; test-keymap.lisp -- key encoding, keymaps, and the prefix/argument
;;;; machine.  The cases of tests/test_keymap.c.

(in-package :clamacs)

(deftest key-make-normalises
  ;; Control plus a letter has one spelling, whatever the shift state.
  (is-equal (make-key (char-code #\F) +mod-ctrl+)
            (make-key (char-code #\f) +mod-ctrl+))
  ;; Shift on a printable character is already in the character.
  (is-equal (make-key (char-code #\<) (logior +mod-meta+ +mod-shift+))
            (make-key (char-code #\<) +mod-meta+))
  ;; ... but a key with no character keeps it.
  (is (/= (make-key +key-tab+ +mod-shift+) (make-key +key-tab+ 0)))
  (is-equal (key-code (make-key (char-code #\a) +mod-ctrl+)) (char-code #\a))
  (is-equal (key-mods (make-key (char-code #\a) +mod-ctrl+)) +mod-ctrl+)
  ;; Bits outside the modifier mask never reach the key.
  (is-equal (make-key (char-code #\a) #x80000) (char-code #\a)))

(deftest key-to-string-spellings
  (is-equal (key-to-string (make-key (char-code #\x) +mod-ctrl+)) "C-x")
  (is-equal (key-to-string (make-key (char-code #\f) +mod-meta+)) "M-f")
  (is-equal (key-to-string (make-key (char-code #\f)
                                     (logior +mod-ctrl+ +mod-meta+)))
            "C-M-f")
  (is-equal (key-to-string (make-key +key-space+ +mod-ctrl+)) "C-SPC")
  (is-equal (key-to-string (make-key +key-tab+ 0)) "TAB")
  (is-equal (key-to-string (make-key +key-tab+ +mod-shift+)) "S-TAB")
  (is-equal (key-to-string (make-key +key-return+ 0)) "RET")
  (is-equal (key-to-string (make-key +key-up+ 0)) "<up>")
  (is-equal (key-to-string (make-key (char-code #\<) +mod-meta+)) "M-<")
  ;; The first table entry for a code is the one printed.
  (is-equal (key-to-string (make-key +key-pageup+ 0)) "<prior>")
  (is-equal (key-to-string (make-key 1 0)) "<?>")
  (is-equal (key-to-string nil) ""))

(deftest key-from-string-spellings
  (is-equal (k "C-x") (make-key (char-code #\x) +mod-ctrl+))
  (is-equal (k "M-f") (make-key (char-code #\f) +mod-meta+))
  (is-equal (k "C-M-f") (make-key (char-code #\f)
                                  (logior +mod-ctrl+ +mod-meta+)))
  (is-equal (k "C-SPC") (make-key +key-space+ +mod-ctrl+))
  (is-equal (k "<f1>") (make-key +key-f1+ 0))
  (is-equal (k "<pageup>") (k "<prior>"))
  ;; A bare minus and a control-minus must both survive the modifier
  ;; parser, which is the one place the spelling grammar is ambiguous.
  (is-equal (k "-") (make-key (char-code #\-) 0))
  (is-equal (k "C--") (make-key (char-code #\-) +mod-ctrl+))
  (is-equal (k "C-_") (make-key (char-code #\_) +mod-ctrl+))
  (is-equal (k "nonsense") nil)
  (is-equal (k "X-a") nil)
  (is-equal (k "") nil))

(deftest key-string-round-trip
  (dolist (spelling '("C-x" "M-f" "C-M-f" "C-SPC" "TAB" "RET" "ESC" "DEL"
                      "<up>" "<down>" "<f10>" "a" "Z" "M-<" "M->" "C--"))
    (let ((key (k spelling)))
      (is key)
      (is-equal (key-to-string key) spelling))))

(deftest keymap-bind-and-lookup
  (let ((map (make-keymap "test")))
    (is (keymap-bind map (k "C-f") 'cmd-11))
    (is (keymap-bind map (k "C-b") 'cmd-22))
    (is (keymap-bind map (k "M-f") 'cmd-33))
    (is-equal (keymap-lookup map (k "C-f")) 'cmd-11)
    (is-equal (keymap-lookup map (k "M-f")) 'cmd-33)
    (is-equal (keymap-lookup map (k "C-z")) nil)
    (is-equal (keymap-lookup nil (k "C-f")) nil)
    (is-equal (keymap-lookup map nil) nil)
    ;; Rebinding replaces.
    (is (keymap-bind map (k "C-f") 'cmd-99))
    (is-equal (keymap-lookup map (k "C-f")) 'cmd-99)
    (is-equal (keymap-count map) 3)
    ;; No key, no binding, or a binding that is neither a command nor a map.
    (is (not (keymap-bind map nil 'cmd-1)))
    (is (not (keymap-bind map (k "C-q") nil)))
    (is (not (keymap-bind map (k "C-q") 42)))
    (is-equal (keymap-count map) 3)))

(deftest keymap-many-bindings
  (let ((map (make-keymap "test")))
    (dotimes (i 60)
      (is (keymap-bind map
                       (make-key (+ (char-code #\a) (mod (* i 7) 26))
                                 (if (oddp i) +mod-ctrl+ +mod-meta+))
                       (if (oddp i) 'odd 'even))))
    ;; I and the letter's index share their parity, so 13 letters land
    ;; under each modifier and every later bind is a rebind.
    (is-equal (keymap-count map) 26)
    (is-equal (keymap-lookup map (k "C-h")) 'odd)
    (is-equal (keymap-lookup map (k "M-a")) 'even)))

(deftest keymap-bind-seq-builds-prefix-maps
  (let ((map (make-keymap "test")))
    (is (keymap-bind-seq map "C-x C-f" 'cmd-7))
    (is (keymap-bind-seq map "C-x C-s" 'cmd-8))
    (is (keymap-bind-seq map "C-x  b" 'cmd-9))
    (let ((sub (keymap-lookup map (k "C-x"))))
      (is (keymap-p sub))
      (is-equal (keymap-count sub) 3)
      (is-equal (keymap-lookup sub (k "C-f")) 'cmd-7)
      (is-equal (keymap-lookup sub (k "b")) 'cmd-9))
    (is (not (keymap-bind-seq map "" 'cmd-1)))
    (is (not (keymap-bind-seq map "   " 'cmd-1)))
    (is (not (keymap-bind-seq map "C-x nonsense" 'cmd-1)))
    (is (not (keymap-bind-seq map "C-x C-q" nil)))
    ;; A failed bind leaves nothing behind.
    (is-equal (keymap-count (keymap-lookup map (k "C-x"))) 3)
    ;; A command in the way of a longer sequence becomes a prefix.
    (is (keymap-bind-seq map "C-c" 'cmd-1))
    (is (keymap-bind-seq map "C-c C-d d" 'cmd-2))
    (is-equal (keymap-lookup
               (keymap-lookup (keymap-lookup map (k "C-c")) (k "C-d"))
               (k "d"))
              'cmd-2)))

;;; --- the state machine --------------------------------------------

(defun state-fixture ()
  (let ((global (make-keymap "global")))
    (keymap-bind-seq global "C-f" 'cmd-1)
    (keymap-bind-seq global "M-f" 'cmd-2)
    (keymap-bind-seq global "C-x C-f" 'cmd-3)
    (keymap-bind-seq global "C-x b" 'cmd-4)
    (keymap-bind-seq global "C-g" 'cmd-5)
    (make-keystate global)))

(defun feed (st spelling)
  "The result and the command of one key, as a list."
  (multiple-value-list (keystate-feed st (k spelling))))

(deftest state-simple-command
  (let ((st (state-fixture)))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is (not (keystate-arg-given-p st)))
    (is-equal (keystate-take-arg st) 1)
    (is-equal (multiple-value-list (keystate-feed st nil)) '(:unbound))))

(deftest state-unbound-falls-through
  (let ((st (state-fixture)))
    ;; A plain character is not ours: it must reach TextEditor.mcc, or
    ;; self-insert stops working.
    (is-equal (feed st "a") '(:unbound))
    (is-equal (feed st "C-z") '(:unbound))))

(deftest state-prefix-sequence
  (let ((st (state-fixture)))
    (is-equal (feed st "C-x") '(:prefix))
    (is-equal (keystate-describe st) "C-x -")
    (is-equal (feed st "C-f") '(:command cmd-3))
    ;; And the state is clean again afterwards.
    (is-equal (feed st "C-f") '(:command cmd-1))))

(deftest state-undefined-sequence-is-eaten
  (let ((st (state-fixture)))
    (is-equal (feed st "C-x") '(:prefix))
    ;; C-x C-q is ours and undefined: reporting it is right, letting the
    ;; superclass insert a `q' is not.
    (is-equal (feed st "C-q") '(:undefined))
    (is (null (keystate-pending st)))
    (is (null (keystate-pending-global st)))
    ;; The sequence stays readable so the echo area can name it; the next
    ;; key clears it.
    (is-equal (keystate-describe st) "C-x C-q ")
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-describe st) "C-f ")))

(deftest state-esc-is-meta
  (let ((st (state-fixture)))
    (is-equal (feed st "ESC") '(:prefix))
    (is-equal (keystate-describe st) "ESC -")
    (is-equal (feed st "f") '(:command cmd-2)))) ; the M-f binding

(deftest state-c-g-cancels-then-runs
  (let ((st (state-fixture)))
    (is-equal (feed st "C-x") '(:prefix))
    (is-equal (feed st "C-g") '(:cancel))
    (is (null (keystate-pending-global st)))
    (is-equal (keystate-describe st) "")
    ;; An argument alone is cancelled too.
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "C-g") '(:cancel))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) 1)
    ;; With nothing pending, C-g is an ordinary command.
    (is-equal (feed st "C-g") '(:command cmd-5))))

(deftest state-universal-argument
  (let ((st (state-fixture)))
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (keystate-describe st) "C-u 4 -")
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is (keystate-arg-given-p st))
    (is-equal (keystate-take-arg st) 4)
    (is (not (keystate-arg-given-p st)))
    ;; C-u C-u multiplies.
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) 16)
    ;; Digits after C-u replace the 4.
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "1") '(:arg))
    (is-equal (feed st "2") '(:arg))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) 12)
    ;; C-u - negates.
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "-") '(:arg))
    (is-equal (feed st "5") '(:arg))
    (is-equal (keystate-describe st) "C-u -5 -")
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) -5)
    ;; M-5 is an argument too, and so is M--.
    (is-equal (feed st "M-5") '(:arg))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) 5)
    (is-equal (feed st "M--") '(:arg))
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) -1)
    ;; Without an argument pending a digit is a key like any other.
    (is-equal (feed st "5") '(:unbound))))

(deftest state-argument-does-not-leak
  (let ((st (state-fixture)))
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "C-f") '(:command cmd-1))
    ;; The caller here deliberately does NOT read the argument; the next
    ;; command must still see the default.
    (is-equal (feed st "C-f") '(:command cmd-1))
    (is-equal (keystate-take-arg st) 1)))

(deftest state-digit-inside-prefix-is-a-key
  (let ((st (state-fixture)))
    (keymap-bind-seq (keystate-global st) "C-x 2" 'cmd-42)
    (is-equal (feed st "C-u") '(:arg))
    (is-equal (feed st "C-x") '(:prefix))
    (is-equal (keystate-describe st) "C-u 4 C-x -")
    ;; Inside C-x, `2' is a key and not a digit of the argument.
    (is-equal (feed st "2") '(:command cmd-42))
    (is-equal (keystate-take-arg st) 4)))

(deftest state-local-map-wins
  (let ((global (make-keymap "global"))
        (local (make-keymap "local")))
    (keymap-bind-seq global "C-f" 'cmd-1)
    (keymap-bind-seq global "C-b" 'cmd-2)
    (keymap-bind-seq local "C-f" 'cmd-99)
    (let ((st (make-keystate global local)))
      (is-equal (feed st "C-f") '(:command cmd-99))
      (is-equal (feed st "C-b") '(:command cmd-2)))))

(deftest state-shared-prefix-keeps-both-sides
  ;; The Lisp map binds `C-x C-e' and the global map `C-x C-f' on one
  ;; prefix key: entering the local C-x map must not hide the global one.
  (let ((global (make-keymap "global"))
        (local (make-keymap "local")))
    (keymap-bind-seq global "C-x C-f" 'find-it)
    (keymap-bind-seq global "C-x C-e" 'global-e)
    (keymap-bind-seq local "C-x C-e" 'local-e)
    (let ((st (make-keystate global local)))
      (is-equal (feed st "C-x") '(:prefix))
      (is-equal (feed st "C-f") '(:command find-it))
      (is-equal (feed st "C-x") '(:prefix))
      (is-equal (feed st "C-e") '(:command local-e))
      (is-equal (feed st "C-x") '(:prefix))
      (is-equal (feed st "C-q") '(:undefined)))))

(deftest state-sequence-is-capped
  ;; A sequence longer than +MAX-SEQ+ still resolves; only the echo stops
  ;; growing.
  (let ((global (make-keymap "global")))
    (keymap-bind-seq global "C-c a b c d e" 'deep)
    (let ((st (make-keystate global)))
      (dolist (key '("C-c" "a" "b" "c" "d"))
        (is-equal (feed st key) '(:prefix)))
      (is-equal (keystate-describe st) "C-c a b c -")
      (is-equal (feed st "e") '(:command deep)))))
