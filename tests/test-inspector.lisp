;;;; test-inspector.lisp -- the inspector window on the fake frontend and
;;;; the fake transport: the inspector steps of verify/realamiga/drive.rexx's
;;;; phase-4 leg (C-c I, a part, Back), plus the capped list, the `... more'
;;;; row, and a refusal.

(in-package :clamacs)

(defparameter *cons-reply*
  (lines "CONS 1 2" "(1 (2 3))" "0: Car = 1" "1: Cdr = (2 3)"))

(defun inspect-fixture ()
  "A wired fake source buffer whose C-c I has been answered with a cons:
(values doc tr)."
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (doc-activate doc)
    (type-keys doc "C-c I")
    (type-text doc "(list 1 (list 2 3))")
    (type-keys doc "RET")
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 0 *cons-reply*)
    (values doc tr)))

(deftest c-c-i-prompts-and-the-window-shows-the-object-and-its-parts
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (doc-activate doc)
    (type-keys doc "C-c I")
    (is-equal (fake-prompt doc) "Inspect value (evaluated): ")
    (type-text doc "(list 1 (list 2 3))")
    (type-keys doc "RET")
    ;; The buffer's package first, then the form.
    (is-equal (fake-last-sent tr) "IN-PACKAGE CL-USER")
    (fake-deliver tr 0 "Package is now CL-USER")
    (is-equal (fake-last-sent tr) "INSPECT (list 1 (list 2 3))")
    (fake-deliver tr 0 *cons-reply*)
    (let ((editor (doc-editor doc)))
      (is (fake-editor-insp-open editor))
      (is-equal (fake-editor-insp-shown editor)
                '("CONS" 1 "(1 (2 3))" ("0: Car = 1" "1: Cdr = (2 3)")))
      (is-equal (fake-last-message doc) "Inspecting CONS: (1 (2 3))"))
    ;; An empty form is nothing to send.
    (type-keys doc "C-c I")
    (type-keys doc "RET")
    (is-equal (fake-beeps doc) 1)
    (is-equal (fake-last-sent tr) "INSPECT (list 1 (list 2 3))")))

(deftest a-part-descends-and-back-comes-up
  (multiple-value-bind (doc tr) (inspect-fixture)
    (run-command doc 'clamacs-inspector-part)
    (is-equal (fake-prompt doc) "Part: ")
    (type-text doc "1")
    (type-keys doc "RET")
    (is-equal (fake-last-sent tr) "PART 1")
    (fake-deliver tr 0 (lines "CONS 2 2" "((2 3))" "0: Car = (2 3)" "1: Cdr = NIL"))
    (is-equal (fake-last-message doc) "Inspecting CONS: ((2 3))")
    (is-equal (second (fake-editor-insp-shown (doc-editor doc))) 2)
    (run-command doc 'clamacs-inspector-pop)
    (is-equal (fake-last-sent tr) "POP")
    (fake-deliver tr 0 *cons-reply*)
    (is-equal (fake-last-message doc) "Inspecting CONS: (1 (2 3))")
    ;; At the object the inspector started from, Back has nowhere to go.
    (run-command doc 'clamacs-inspector-pop)
    (is-equal (fake-last-message doc) "Already at the object the inspector started from")
    (is-equal (fake-beeps doc) 1)
    (is-equal (fake-last-sent tr) "POP")))

(deftest the-window-clicks-go-by-the-rows-own-number
  (multiple-value-bind (doc tr) (inspect-fixture)
    (let ((editor (doc-editor doc)))
      (inspect-part-clicked editor 1)
      (is-equal (fake-last-sent tr) "PART 1")
      (fake-deliver tr 0 (lines "CONS 2 2" "((2 3))" "0: Car = (2 3)" "1: Cdr = NIL"))
      (inspect-back-clicked editor)
      (is-equal (fake-last-sent tr) "POP")
      (fake-deliver tr 0 *cons-reply*)
      ;; Nothing selected: nothing happens.
      (inspect-part-clicked editor nil)
      (is-equal (fake-last-message doc) "Not a part"))))

(deftest a-capped-list-ends-with-a-more-row-that-is-not-a-part
  (multiple-value-bind (doc tr) (inspect-fixture)
    (run-command doc 'clamacs-inspector-part)
    (type-text doc "0")
    (type-keys doc "RET")
    (fake-deliver tr 0 (lines "SIMPLE-VECTOR 2 5" "#(1 2 3 4 5)" "0: 0 = 1" "1: 1 = 2"))
    (let* ((editor (doc-editor doc))
           (parts (fourth (fake-editor-insp-shown editor))))
      (is-equal (length parts) 3)
      (is-equal (third parts) "... 3 more part(s); M-x clamacs-inspector-part takes any number")
      (inspect-part-clicked editor 2)
      (is-equal (fake-last-message doc) "Not a part")
      (is-equal (fake-beeps doc) 1)
      ;; Any number is still reachable by name.
      (run-command doc 'clamacs-inspector-part)
      (type-text doc "4")
      (type-keys doc "RET")
      (is-equal (fake-last-sent tr) "PART 4"))))

(deftest nothing-inspected-and-a-refusal
  (multiple-value-bind (doc tr wire) (make-wired-fake "|")
    (declare (ignore wire))
    (run-command doc 'clamacs-inspector-part)
    (is-equal (fake-last-message doc) "Nothing is being inspected (C-c I inspects a value)")
    (run-command doc 'clamacs-inspector-pop)
    (is-equal (fake-beeps doc) 2)
    (is (null (fake-transport-sent tr)))
    (type-keys doc "C-c I")
    (type-text doc "(no-such-fn)")
    (type-keys doc "RET")
    (fake-deliver tr 0 "Package is now CL-USER")
    (fake-deliver tr 10 "")
    (fake-deliver tr 0 "ERROR: Undefined function: NO-SUCH-FN")
    (is-equal (fake-last-message doc) "ERROR: Undefined function: NO-SUCH-FN")
    (is-equal (fake-beeps doc) 3)
    (is (not (fake-editor-insp-open (doc-editor doc))))
    ;; A reply that is not an INSPECT answer at all.
    (type-keys doc "C-c I")
    (type-text doc "1")
    (type-keys doc "RET")
    (fake-deliver tr 0 "")
    (is-equal (fake-last-message doc) "clamiga could not inspect that")))
