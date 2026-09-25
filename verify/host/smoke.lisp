;;;; smoke.lisp -- the host frontend's ground, exercised end to end
;;;; (specs/clamacs-host.md, phase H0).
;;;;
;;;;   clamiga --non-interactive --load verify/host/smoke.lisp
;;;;
;;;; Unattended: the window opens on build/host-frontend/page.html, the
;;;; page reports clamacsReady through a binding, Lisp makes a document
;;;; and puts text in it and reads the page's state back through a second
;;;; binding, asks the shim for a beep and the window's frame, moves the
;;;; window, checks that a wake from another thread ends a step early,
;;;; installs the close hook, and tears everything down.  The last line
;;;; is the verdict, SMOKE: PASS or SMOKE: FAIL; verify/host/run-smoke.sh
;;;; builds first and reads it.  Every step is logged with SMOKE: so a
;;;; failure says where.

(require "ffi")

(defpackage :clamacs-smoke (:use :cl))
(in-package :clamacs-smoke)

(defvar *here* (directory-namestring *load-pathname*))
(defvar *root* (let* ((s (namestring *here*))
                      (cut (search "verify/host/" s :from-end t)))
                 (if cut (subseq s 0 cut) "")))
(defvar *out* (concatenate 'string *root* "build/host-frontend/"))

;;; The editor's JSON reader, for the bindings' arguments.
(load (concatenate 'string *root* "lisp/package.lisp"))
(load (concatenate 'string *root* "lisp/json.lisp"))

(defvar *failures* '())

(defun note (fmt &rest args)
  (format t "SMOKE: ~?~%" fmt args)
  (finish-output))

(defun check (ok fmt &rest args)
  (unless ok
    (push (apply #'format nil fmt args) *failures*)
    (note "FAILED: ~?" fmt args))
  ok)

;;; ---- the two libraries -------------------------------------------------

(defvar *webview* (or (ffi:load-library (concatenate 'string *out* "libwebview.dylib"))
                      (error "libwebview.dylib not found under ~A -- run host/build.sh" *out*)))
(defvar *shim* (or (ffi:load-library (concatenate 'string *out* "libclamacs-host.dylib"))
                   (error "libclamacs-host.dylib not found under ~A -- run host/build.sh" *out*)))
(defvar *w* nil)
(defvar *callbacks* '())

(defun wv (name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name *webview*) ret types args))

(defun shim (name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name *shim*) ret types args))

(defun wv-str (name &rest strings)
  "Call NAME with *W* and one or more C strings."
  (let ((ptrs (mapcar #'ffi:foreign-string strings)))
    (unwind-protect
         (ffi:call-foreign (ffi:symbol-pointer name *webview*) :int32
                           (cons :pointer (mapcar (constantly :pointer) ptrs))
                           (cons *w* ptrs))
      (mapc #'ffi:free-foreign ptrs))))

(defun js-eval (fmt &rest args)
  (wv-str "webview_eval" (apply #'format nil fmt args)))

(defun js-return (id json)
  (let ((pid (ffi:foreign-string id)) (pjson (ffi:foreign-string json)))
    (unwind-protect
         (wv "webview_return" :int32 '(:pointer :pointer :int32 :pointer)
             *w* pid 0 pjson)
      (ffi:free-foreign pid) (ffi:free-foreign pjson))))

(defun bind (name fn)
  "Bind NAME in the page to FN, called with the parsed JSON arguments; the
promise is answered with true."
  (let ((cb (ffi:make-callback
             :void '(:pointer :pointer :pointer)
             (lambda (id req arg)
               (declare (ignore arg))
               (let ((args (handler-case (clamacs::json-parse (ffi:foreign-to-string req))
                             (error (e)
                               (check nil "~A: bad arguments: ~A" name e)
                               '()))))
                 (handler-case (apply fn args)
                   (error (e) (check nil "~A signalled: ~A" name e))))
               (js-return (ffi:foreign-to-string id) "true")))))
    (push cb *callbacks*)
    (let ((pname (ffi:foreign-string name)))
      (unwind-protect
           (wv "webview_bind" :int32 '(:pointer :pointer :pointer :pointer)
               *w* pname cb (ffi:make-foreign-pointer 0))
        (ffi:free-foreign pname)))))

(defun host-step (ms)
  (shim "clamacs_host_step" :int32 '(:pointer :int32) *w* ms))

(defun now-ms ()
  (floor (* 1000 (get-internal-real-time)) internal-time-units-per-second))

(defun step-until (predicate seconds what)
  "Step the loop until PREDICATE holds; NIL (and a failure) on timeout."
  (let ((deadline (+ (now-ms) (* 1000 seconds))))
    (loop
      (when (funcall predicate)
        (return t))
      (when (> (now-ms) deadline)
        (return (check nil "timed out after ~Ds waiting for ~A" seconds what)))
      (host-step 50))))

(defun read-file (path)
  "The page, byte for byte: Latin-1 keeps every byte a character, and
ffi:foreign-string writes one byte per character, so what WebKit gets
is the file -- valid UTF-8 as long as the file is (host/build.sh keeps it
ASCII).  The default external format would decode UTF-8 into code points
above 255, which a narrow string cannot hold."
  (with-open-file (in path :external-format :latin-1)
    (let* ((s (make-string (file-length in)))
           (n (read-sequence s in)))
      (subseq s 0 n))))

;;; ---- the run -----------------------------------------------------------

(defvar *ready* nil)
(defvar *state* nil)
(defvar *closes* 0)

(defun run ()
  (setf *w* (wv "webview_create" :pointer '(:int32 :pointer) 0 (ffi:make-foreign-pointer 0)))
  (when (ffi:null-pointer-p *w*)
    (error "webview_create failed"))
  (note "webview created")
  (wv-str "webview_set_title" "Clamacs (host smoke)")
  (wv "webview_set_size" :int32 '(:pointer :int32 :int32 :int32) *w* 900 600 0)
  (bind "clamacsReady" (lambda (ua) (note "page ready, user agent ~S" ua) (setq *ready* t)))
  (bind "clamacsSmoke" (lambda (json) (setq *state* (clamacs::json-parse json))))
  (bind "clamacsActivate" (lambda (id) (note "activate ~A" id)))
  (bind "clamacsLog" (lambda (text) (check nil "the page reported: ~A" text)))
  (bind "clamacsTick" (lambda () nil))
  (let ((html (read-file (concatenate 'string *out* "page.html"))))
    (note "page is ~D chars" (length html))
    (wv-str "webview_set_html" html))

  ;; 1. The page comes up and calls clamacsReady from inside a step.
  (step-until (lambda () *ready*) 20 "clamacsReady")

  (when *ready*
    ;; 2. Lisp -> page -> Lisp: a document, its text, the state read back.
    (js-eval "CK.makeDoc(\"doc1\", \"smoke.lisp\", \"source\"); CK.setText(\"doc1\", ~A); CK.setStatus(~A); CK.setEcho(~A); clamacsSmoke(JSON.stringify(CK.state()))"
             (clamacs::json-string (format nil "(defun smoke (x)~%  (* x 2))~%"))
             (clamacs::json-string "smoke.lisp  (CL-USER)  L1")
             (clamacs::json-string "Ready"))
    (when (step-until (lambda () *state*) 10 "the page's state")
      (let ((state *state*))
        (check (equal (gethash "docs" state) '("doc1")) "docs: ~S" (gethash "docs" state))
        (check (equal (gethash "active" state) "doc1") "active: ~S" (gethash "active" state))
        (check (equal (gethash "text" state) (format nil "(defun smoke (x)~%  (* x 2))~%"))
               "text: ~S" (gethash "text" state))
        (check (equal (gethash "status" state) "smoke.lisp  (CL-USER)  L1")
               "status: ~S" (gethash "status" state))
        (check (equal (gethash "message" state) "Ready") "message: ~S" (gethash "message" state))
        (note "page state read back: ~D doc(s), text ~D chars"
              (length (gethash "docs" state)) (length (gethash "text" state))))))

  ;; 3. The shim: beep, frame, move, toolkit line.
  (shim "clamacs_host_beep" :void '())
  (note "beeped")
  (let ((win (wv "webview_get_window" :pointer '(:pointer) *w*))
        (frame (ffi:alloc-foreign 16)))
    (check (not (ffi:null-pointer-p win)) "webview_get_window answered NULL")
    (unwind-protect
         (flet ((get-frame ()
                  (shim "clamacs_host_get_frame" :void '(:pointer :pointer) win frame)
                  (loop for i below 4 collect (ffi:peek-i32 frame (* 4 i)))))
           (let ((f (get-frame)))
             (note "frame ~S" f)
             (check (and (> (third f) 0) (> (fourth f) 0)) "frame has no size: ~S" f))
           (shim "clamacs_host_set_frame" :void '(:pointer :int32 :int32 :int32 :int32)
                 win 120 80 800 500)
           (host-step 100)
           (let ((f (get-frame)))
             (note "frame after set_frame 120 80 800 500: ~S" f)
             (check (equal f '(120 80 800 500)) "set_frame did not take: ~S" f)))
      (ffi:free-foreign frame))
    ;; The close button asks the editor: installed here, clicked by nobody.
    (let ((cb (ffi:make-callback :void '(:pointer) (lambda (arg) (declare (ignore arg)) (incf *closes*)))))
      (push cb *callbacks*)
      (shim "clamacs_host_on_close" :void '(:pointer :pointer :pointer) win cb (ffi:make-foreign-pointer 0))
      (note "close hook installed")))
  (let ((line (ffi:foreign-to-string (shim "clamacs_host_toolkit" :pointer '()))))
    (note "toolkit: ~A" line)
    (check (> (length line) 0) "empty toolkit line"))

  ;; 4. A wake from another thread ends a step before its timeout.
  (let ((thread (mp:make-thread (lambda ()
                                  (sleep 0.2)
                                  (shim "clamacs_host_wake" :void '()))
                                :name "smoke-wake"))
        (start (now-ms)))
    (host-step 3000)
    (let ((elapsed (- (now-ms) start)))
      (note "a 3000 ms step woken from another thread returned after ~D ms" elapsed)
      (check (< elapsed 1500) "the wake did not end the step (~D ms)" elapsed))
    (loop repeat 50 while (mp:thread-alive-p thread) do (sleep 0.02)))

  ;; 5. Down: the window, the callbacks, the libraries.
  (wv "webview_destroy" :int32 '(:pointer) *w*)
  (setq *w* nil)
  (note "webview destroyed")
  (dolist (cb *callbacks*) (ffi:free-callback cb))
  (setq *callbacks* '())
  (ffi:close-library *shim*)
  (ffi:close-library *webview*)
  (note "libraries closed"))

(handler-case (run)
  (error (e)
    (check nil "unhandled: ~A" e)))
(format t "SMOKE: ~A~%" (if *failures* "FAIL" "PASS"))
(finish-output)
(cl-user::quit (if *failures* 1 0))
