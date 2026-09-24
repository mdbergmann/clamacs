;;;; spike.lisp -- can clamiga drive a webview window with CodeMirror in it?
;;;;
;;;; The round trip under test: JS -> Lisp (webview_bind callback into a
;;;; ffi:make-callback closure), Lisp -> JS (webview_eval), and a synchronous
;;;; answer to the JS promise (webview_return).
;;;;
;;;;   clamiga --non-interactive --load spike.lisp            interactive
;;;;   clamiga --non-interactive --load spike.lisp -- auto    unattended:
;;;;      the page reports ready, Lisp inserts text and injects C-x, the
;;;;      key comes back through the binding, Lisp terminates the loop.

(require "ffi")

(defpackage :spike (:use :cl))
(in-package :spike)

(defvar *here* (directory-namestring *load-pathname*))
(defvar *auto* (member "auto" ext:*command-line-args* :test #'string=))
(defvar *lib* (or (ffi:load-library (concatenate 'string *here* "build/libwebview.dylib"))
                  (error "libwebview.dylib not found beside ~a" *here*)))
(defvar *w* nil)
(defvar *log* '())

(defun log* (fmt &rest args)
  (let ((line (apply #'format nil fmt args)))
    (push line *log*)
    (format t "SPIKE: ~a~%" line)
    (finish-output)))

;;; ---- the C API ---------------------------------------------------------

(defun wv (name ret types &rest args)
  (ffi:call-foreign (ffi:symbol-pointer name *lib*) ret types args))

(defun wv-str (name &rest strings)
  "Call NAME with *w* and one or more C strings."
  (let ((ptrs (mapcar #'ffi:foreign-string strings)))
    (unwind-protect
         (ffi:call-foreign (ffi:symbol-pointer name *lib*) :int32
                           (cons :pointer (mapcar (constantly :pointer) ptrs))
                           (cons *w* ptrs))
      (mapc #'ffi:free-foreign ptrs))))

(defun js-string (s)
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s do
      (case c
        (#\" (write-string "\\\"" o))
        (#\\ (write-string "\\\\" o))
        (#\Newline (write-string "\\n" o))
        (#\Return (write-string "\\r" o))
        (t (write-char c o))))
    (write-char #\" o)))

(defun js-eval (fmt &rest args)
  (wv-str "webview_eval" (apply #'format nil fmt args)))

(defun js-return (id json)
  (let ((pid (ffi:foreign-string id)) (pjson (ffi:foreign-string json)))
    (unwind-protect
         (wv "webview_return" :int32 '(:pointer :pointer :int32 :pointer)
             *w* pid 0 pjson)
      (ffi:free-foreign pid) (ffi:free-foreign pjson))))

;;; ---- a JSON array reader just wide enough for the bindings' arguments ---

(defun parse-json-array (s)
  "\"[\"x\",true,12]\" -> (\"x\" T 12).  Strings, booleans, null, integers."
  (let ((i 1) (n (length s)) (out '()))
    (labels ((peek () (if (< i n) (char s i) #\Nul))
             (skip () (loop while (member (peek) '(#\Space #\,)) do (incf i)))
             (item ()
               (let ((c (peek)))
                 (cond ((char= c #\")
                        (incf i)
                        (with-output-to-string (o)
                          (loop for ch = (peek)
                                until (char= ch #\")
                                do (incf i)
                                   (if (char= ch #\\)
                                       (let ((e (peek)))
                                         (incf i)
                                         (write-char (case e (#\n #\Newline) (#\t #\Tab) (t e)) o))
                                       (write-char ch o)))
                          (incf i)))
                       ((string= s "true" :start1 i :end1 (min n (+ i 4))) (incf i 4) t)
                       ((string= s "false" :start1 i :end1 (min n (+ i 5))) (incf i 5) nil)
                       ((string= s "null" :start1 i :end1 (min n (+ i 4))) (incf i 4) nil)
                       (t (let ((start i))
                            (loop while (or (digit-char-p (peek)) (char= (peek) #\-)) do (incf i))
                            (parse-integer s :start start :end i)))))))
      (loop (skip)
            (when (or (>= i n) (char= (peek) #\])) (return))
            (push (item) out))
      (nreverse out))))

;;; ---- the bindings: JS calls these, the callback runs on the GUI thread ---

(defvar *keys-seen* 0)
(defvar *last-update* nil)

(defun on-ready (ua)
  (log* "page ready, user agent ~s" ua)
  (when *auto*
    ;; Lisp -> JS: an edit, then a synthetic Emacs key that must come back.
    (js-eval "cmInsert(~a)" (js-string "(+ 1 2) "))
    (js-eval "simulateKey(\"x\", {ctrlKey: true})"))
  "Hello from clamiga -- keys go to Lisp first")

(defun on-key (key ctrl alt meta shift point len)
  (incf *keys-seen*)
  (log* "key ~s ctrl=~a alt=~a meta=~a shift=~a point=~d len=~d"
        key ctrl alt meta shift point len)
  (js-eval "showEcho(~a)" (js-string (format nil "Lisp saw ~:[~;C-~]~:[~;M-~]~a at ~d" ctrl alt key point)))
  (when (and ctrl (string= key "x"))
    (js-eval "showStatus(~a)" (js-string "(defun hello (name) ...)   ; arglist from Lisp"))
    (when *auto*
      (log* "C-x arrived through the binding -- round trip complete, terminating")
      (wv "webview_terminate" :int32 '(:pointer) *w*)))
  ;; T: Lisp took the key (ctrl/alt keys), NIL: let CodeMirror have it.
  (or ctrl alt))

(defun on-update (point len)
  (setf *last-update* (list point len))
  (log* "widget update: point=~d len=~d" point len))

(defun make-binding (name fn &key (answer t))
  "Bind NAME in the page to FN, called with the JS arguments; FN's value
goes back as the promise's result when ANSWER."
  (let ((cb (ffi:make-callback
             :void '(:pointer :pointer :pointer)
             (lambda (id req arg)
               (declare (ignore arg))
               (let* ((args (parse-json-array (ffi:foreign-to-string req)))
                      (result (handler-case (apply fn args)
                                (error (e)
                                  (log* "error in ~a: ~a" name e)
                                  nil))))
                 (when answer
                   (js-return (ffi:foreign-to-string id)
                              (cond ((stringp result) (js-string result))
                                    (result "true")
                                    (t "false")))))))))
    (let ((pname (ffi:foreign-string name)))
      (unwind-protect
           (wv "webview_bind" :int32 '(:pointer :pointer :pointer :pointer)
               *w* pname cb (ffi:make-foreign-pointer 0))
        (ffi:free-foreign pname)))
    cb))

;;; ---- run ---------------------------------------------------------------

(defun read-file (path)
  (with-open-file (in path)
    (let ((s (make-string (file-length in))))
      (let ((n (read-sequence s in)))
        (subseq s 0 n)))))

(defun run ()
  (setf *w* (wv "webview_create" :pointer '(:int32 :pointer) 0 (ffi:make-foreign-pointer 0)))
  (when (ffi:null-pointer-p *w*) (error "webview_create failed"))
  (log* "webview created")
  (wv-str "webview_set_title" "Clamacs (host spike)")
  (wv "webview_set_size" :int32 '(:pointer :int32 :int32 :int32) *w* 900 600 0)
  (make-binding "clamacsReady" #'on-ready)
  (make-binding "clamacsKey" #'on-key)
  (make-binding "clamacsUpdate" #'on-update :answer nil)
  (let ((html (read-file (concatenate 'string *here* "build/page.html"))))
    (log* "page is ~d chars" (length html))
    (wv-str "webview_set_html" html))
  (log* "entering webview_run")
  (wv "webview_run" :int32 '(:pointer) *w*)
  (log* "webview_run returned")
  (wv "webview_destroy" :int32 '(:pointer) *w*)
  (log* "keys seen ~d, last update ~s" *keys-seen* *last-update*)
  (when *auto*
    (format t "SPIKE-RESULT: ~a~%"
            (if (and (>= *keys-seen* 1) *last-update*) "PASS" "FAIL"))))

(run)
