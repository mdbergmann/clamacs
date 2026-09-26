;;;; test-theme.lisp -- colour themes (lisp/theme.lisp): the built-ins,
;;;; DEFINE-THEME's inherit chains and refusals, the two views the
;;;; frontends read, LOAD-THEME on the fake frontend, the init file's
;;;; rewrite on every fixture of specs/clamacs-themes.md, and the command.

(in-package :clamacs)

(defvar *theme-page-head*
  (concatenate 'string (cl-user::clamacs-root *load-truename*) "host/page-head.html"))

(defparameter *builtin-theme-names*
  '("light" "dark" "solarized-light" "solarized-dark" "one-dark" "gruvbox-dark"))

;;; The theme state is global: a test that picks or defines runs with the
;;; state its own -- no pick, a known default, no running editor, the init
;;; file a scratch path -- and the registry as it was afterwards.
(defmacro with-theme-state ((&key (default :light)) &body body)
  `(let ((*theme* nil)
         (*default-theme* ,default)
         (*editor* nil)
         (*init-file* (temp-file "theme-rc"))
         (saved-themes (copy-list *themes*)))
     (unwind-protect (progn ,@body)
       (setq *themes* saved-themes)
       (delete-quietly *init-file*))))

;;; --- the built-ins ---------------------------------------------------------------

(deftest the-built-ins-come-first-in-order
  (is-equal (subseq (theme-names) 0 6) *builtin-theme-names*)
  (dolist (name *builtin-theme-names*)
    (let ((th (find-theme name)))
      (is (theme-p th))
      (is (theme-builtin th))
      (is (keywordp (theme-name th)))
      (is (stringp (theme-label th)))))
  (is-equal (mapcar (lambda (n) (theme-label (find-theme n))) *builtin-theme-names*)
            '("Light" "Dark" "Solarized Light" "Solarized Dark" "One Dark" "Gruvbox Dark"))
  (is-equal (mapcar (lambda (n) (theme-dark (find-theme n))) *builtin-theme-names*)
            '(nil t nil t t t))
  (is-equal (mapcar (lambda (n) (theme-inherits (find-theme n))) *builtin-theme-names*)
            '(nil nil :light :dark :dark :dark)))

(deftest every-built-in-sets-every-key-through-its-chain
  ;; No built-in needs the default's fallback: THEME-VALUE alone answers.
  (dolist (name *builtin-theme-names*)
    (let ((th (find-theme name)))
      (dolist (key (theme-keys))
        (unless (theme-value th key)
          (test-failure (list :unset name key))))
      (is-equal (length (theme-css-vars th)) (length (theme-keys)))
      (is-equal (length (theme-pens th)) 8)))
  (is-equal (length (theme-keys)) 26))

(defun css-block-vars (css from)
  "The `--name: value;' pairs of the first `:root {' block after FROM in
CSS, as an alist -- a `#abc' expanded to `#aabbcc', the theme's spelling."
  (let* ((open (search ":root {" css :start2 from))
         (close (and open (position #\} css :start open)))
         (vars '())
         (at open))
    (loop
      (let ((dash (and at (search "--" css :start2 at :end2 close))))
        (unless dash (return))
        (let* ((colon (position #\: css :start dash))
               (semi (position #\; css :start colon))
               (name (subseq css dash colon))
               (value (string-trim " " (subseq css (1+ colon) semi))))
          (when (and (= (length value) 4) (char= (char value 0) #\#))
            (setq value (format nil "#~C~C~C~C~C~C" (char value 1) (char value 1)
                                (char value 2) (char value 2) (char value 3) (char value 3))))
          (push (cons name value) vars)
          (setq at semi))))
    (nreverse vars)))

(deftest light-and-dark-are-the-pages-two-palettes
  ;; Byte for byte with host/page-head.html, so an editor that never
  ;; picked a theme looks as before.  The page's :root block has every
  ;; key, the font included; its dark block the colours only (the font is
  ;; the same), so :dark's font keys are :light's.
  (let ((css (read-file-text *theme-page-head*)))
    (is (stringp css))
    (when (stringp css)
      (let ((light (css-block-vars css 0))
            (dark (css-block-vars css (search "prefers-color-scheme: dark" css))))
        (is-equal (length light) (length (theme-keys)))
        (is-equal (length dark) (length (theme-colour-keys)))
        (dolist (pair (theme-css-vars (find-theme :light)))
          (is-equal (cdr (assoc (car pair) light :test #'string=)) (cdr pair)))
        (dolist (pair (theme-css-vars (find-theme :dark)))
          (if (member (car pair) '("--font-family" "--font-size") :test #'string=)
              (is-equal (cdr (assoc (car pair) light :test #'string=)) (cdr pair))
              (is-equal (cdr (assoc (car pair) dark :test #'string=)) (cdr pair))))))))

;;; --- finding, defining, forgetting ---------------------------------------------------

(deftest find-theme-takes-a-keyword-a-string-a-symbol-or-a-theme
  (let ((dark (find-theme :dark)))
    (is (theme-p dark))
    (is (eq (find-theme "dark") dark))
    (is (eq (find-theme "DARK") dark))
    (is (eq (find-theme 'dark) dark))
    (is (eq (find-theme dark) dark))
    (is (null (find-theme :no-such-theme)))
    (is (null (find-theme "")))
    (is (null (find-theme nil)))
    (is (null (find-theme 42)))))

(deftest define-theme-inherits-what-it-leaves-out
  (with-theme-state ()
    (let ((mine (define-theme :mine (:inherits :dark :label "Mine") :keyword "#ff9900")))
      (is (eq (find-theme :mine) mine))
      (is-equal (theme-label mine) "Mine")
      (is (theme-dark mine))                        ; the parent's flag
      (is (not (theme-builtin mine)))
      (is-equal (theme-inherits mine) :dark)
      (is-equal (theme-value mine :keyword) "#ff9900")
      (is-equal (theme-value mine :bg) "#1e1e1e")   ; from :dark
      (is-equal (theme-values mine) '((:keyword . "#ff9900")))
      (is-equal (car (last (theme-names))) "mine")
      ;; A grandchild: the chain is walked.
      (define-theme :grandchild (:inherits :mine :dark nil) :bg "#000001")
      (is-equal (theme-value (find-theme :grandchild) :keyword) "#ff9900")
      (is-equal (theme-value (find-theme :grandchild) :fg) "#d4d4d4")
      (is (not (theme-dark (find-theme :grandchild))))
      ;; Redefined: in its place, the new values.
      (define-theme :mine (:inherits :light) :keyword "#00ff00")
      (is-equal (position "mine" (theme-names) :test #'string=) 6)
      (is-equal (theme-value (find-theme :mine) :keyword) "#00ff00")
      (is-equal (theme-value (find-theme :mine) :bg) "#ffffff")
      (is (not (theme-dark (find-theme :mine))))
      (is-equal (theme-value (find-theme :grandchild) :keyword) "#00ff00")
      ;; The label by default: the name, capitalised.
      (define-theme :my-own-dark (:inherits :dark))
      (is-equal (theme-label (find-theme :my-own-dark)) "My Own Dark")
      (is (forget-theme :my-own-dark))
      (is (null (find-theme :my-own-dark)))
      (is (not (forget-theme :my-own-dark)))
      ;; A parent forgotten: the chain ends there, the default fills in.
      (forget-theme :mine)
      (is (null (theme-value (find-theme :grandchild) :keyword)))
      (is-equal (theme-resolve (find-theme :grandchild) :keyword) "#0000ff"))))

(defun theme-error (name options colours)
  "The error MAKE-THEME signals for these, as text, or NIL."
  (handler-case (progn (make-theme name options colours) nil)
    (error (e) (format nil "~A" e))))

(deftest define-theme-refuses-what-it-cannot-mean
  (with-theme-state ()
    (is (search "not a theme key" (theme-error :t1 '() '(:background "#000000"))))
    (is (search "T1" (theme-error :t1 '() '(:background "#000000"))))
    (is (search "#rrggbb" (theme-error :t1 '() '(:bg "#ggg"))))
    (is (search "#rrggbb" (theme-error :t1 '() '(:bg "ffffff"))))
    (is (search "#rrggbb" (theme-error :t1 '() '(:bg 0))))
    (is (search "needs a string" (theme-error :t1 '() '(:font-size 14))))
    (is (search "not defined" (theme-error :t1 '(:inherits :nowhere) '())))
    (is (search "the label must be a string" (theme-error :t1 '(:label 3) '())))
    (is (search "without a value" (theme-error :t1 '() '(:bg "#000000" :fg))))
    ;; The name: a keyword of letters, digits and hyphens, so the init
    ;; file's lowercase spelling reads back.
    (is (search "keyword" (theme-error 'plain '() '())))
    (is (search "keyword" (theme-error :|a b| '() '())))
    (is (search "keyword" (theme-error "dark" '() '())))
    (is (search "keyword" (theme-error nil '() '())))
    ;; Nothing was registered.
    (is (null (find-theme :t1)))
    (is-equal (length (theme-names)) 6)))

;;; --- resolution and the two views ---------------------------------------------------

(deftest a-theme-without-a-parent-falls-back-to-the-default
  (with-theme-state ()
    (define-theme :bare () :bg "#123456")
    (let ((bare (find-theme :bare)))
      (is (null (theme-inherits bare)))
      (is (not (theme-dark bare)))
      (is-equal (theme-value bare :bg) "#123456")
      (is (null (theme-value bare :fg)))
      (is-equal (theme-resolve bare :fg) "#1f1f1f")     ; :light's
      (is-equal (length (theme-css-vars bare)) (length (theme-keys)))
      (is-equal (cdr (assoc "--bg" (theme-css-vars bare) :test #'string=)) "#123456")
      (is-equal (first (theme-pens bare)) '(31 31 31))
      ;; The default is what the frontend says the system shows.
      (let ((*default-theme* :dark))
        (is-equal (theme-resolve bare :fg) "#d4d4d4")
        (is-equal (first (theme-pens bare)) '(212 212 212)))
      ;; The default itself resolves to nothing more.
      (let ((*default-theme* :bare))
        (is (null (theme-resolve bare :fg)))
        (is-equal (length (theme-css-vars bare)) 1)))))

(deftest the-css-view-is-the-pages-variables
  (let ((vars (theme-css-vars (find-theme :light))))
    (is-equal (first vars) '("--bg" . "#ffffff"))
    (is-equal (cdr (assoc "--c-keyword" vars :test #'string=)) "#0000ff")
    (is-equal (cdr (assoc "--c-paren-match" vars :test #'string=)) "#c8e6c9")
    (is-equal (cdr (assoc "--gutter-fg" vars :test #'string=)) "#9a9a9a")
    (is-equal (cdr (assoc "--font-family" vars :test #'string=)) "\"SF Mono\", Menlo, monospace")
    (is-equal (cdr (assoc "--font-size" vars :test #'string=)) "14px")
    (is (null (assoc "--keyword" vars :test #'string=))))
  (is-equal (theme-css-var :bg) "--bg")
  (is-equal (theme-css-var :status-bg) "--status-bg")
  (is-equal (theme-css-var :string) "--c-string")
  (is-equal (theme-css-var :font-size) "--font-size"))

(deftest the-pen-view-is-the-colour-map
  ;; Eight (r g b) in SetBlock's slot order: the text, the free slot,
  ;; paren-match, comment, keyword, string, defining, number.
  (is-equal (theme-pens (find-theme :light))
            '((31 31 31) (255 255 255) (200 230 201) (122 122 122)
              (0 0 255) (163 21 21) (121 94 38) (9 134 88)))
  (is-equal (first (theme-pens (find-theme :dark))) '(212 212 212))
  (is-equal (multiple-value-list (theme-rgb "#FFcc00")) '(255 204 0))
  (is-equal (multiple-value-list (theme-rgb "#000000")) '(0 0 0))
  (is (null (theme-rgb "#fff")))
  (is (null (theme-rgb "ffcc00")))
  (is (null (theme-rgb "#gg0000")))
  (is (null (theme-rgb 42)))
  (is (null (theme-rgb nil))))

;;; --- LOAD-THEME ------------------------------------------------------------------

(deftest load-theme-picks-applies-and-remembers
  (with-theme-state ()
    (let* ((doc (make-fake "|"))
           (editor (doc-editor doc)))
      (doc-activate doc)
      (is (eq (active-theme) (find-theme :light)))
      (let ((*editor* editor))
        ;; A pick: *THEME*, the frontend, the init file.
        (is (eq (load-theme :dark) (find-theme :dark)))
        (is (eq *theme* (find-theme :dark)))
        (is (eq (active-theme) (find-theme :dark)))
        (is (eq (fake-editor-theme editor) (find-theme :dark)))
        (is-equal (fake-editor-theme-applied editor) 1)
        (is-equal (read-file-text *init-file*)
                  (format nil "~A~%(load-theme :dark)~%" *theme-persist-comment*))
        ;; For the session only: applied, not written.
        (is (eq (load-theme "one-dark" :save nil) (find-theme :one-dark)))
        (is (eq (fake-editor-theme editor) (find-theme :one-dark)))
        (is-equal (fake-editor-theme-applied editor) 2)
        (is (search "(load-theme :dark)" (read-file-text *init-file*)))
        ;; The same pick again: the file is left as it is.
        (load-theme :dark)
        (is-equal (read-file-text *init-file*)
                  (format nil "~A~%(load-theme :dark)~%" *theme-persist-comment*))
        ;; A name no theme has: the default, with a message, no error.
        (is (eq (load-theme :nope) (find-theme :light)))
        (is (null *theme*))
        (is (eq (fake-editor-theme editor) (find-theme :light)))
        (is-equal (fake-editor-theme-applied editor) 4)
        (is (search "No theme named NOPE" (fake-last-message doc)))
        (is (search "gruvbox-dark" (fake-last-message doc)))
        ;; ... and nothing was written for it.
        (is (search "(load-theme :dark)" (read-file-text *init-file*)))
        ;; A system reported dark: the default follows it.
        (let ((*default-theme* :dark))
          (is (eq (load-theme :nope) (find-theme :dark)))))
      ;; Without a running editor nothing is applied and the message goes
      ;; to the console.
      (let ((*error-output* (make-string-output-stream)))
        (is (eq (load-theme :nope) (find-theme :light)))
        (is (search "clamacs: No theme named NOPE" (get-output-stream-string *error-output*))))
      (is-equal (fake-editor-theme-applied editor) 5))))

(deftest load-theme-says-when-the-init-file-cannot-be-written
  (with-theme-state ()
    (let* ((doc (make-fake "|"))
           (editor (doc-editor doc))
           (blocker (temp-file "theme-blocker" "not a directory")))
      (doc-activate doc)
      (unwind-protect
           (let ((*editor* editor)
                 (*init-file* (concatenate 'string blocker "/rc")))
             (is (eq (load-theme :dark) (find-theme :dark)))
             (is (eq *theme* (find-theme :dark)))
             (is (eq (fake-editor-theme editor) (find-theme :dark)))
             (is (search "Cannot write" (fake-last-message doc)))
             (is (search "holds for this session" (fake-last-message doc))))
        (delete-file blocker)))))

;;; --- LOAD-THEME from another thread ----------------------------------------------
;;;
;;; A form at the self REPL runs on the REPL thread: LOAD-THEME must reach
;;; the frontend only through the editor's task.  This thread plays that
;;; task -- it drains a mailbox the other thread's closures are posted to,
;;; as the self transport's CALL does (transport-self.lisp) -- so "not
;;; before the drain" is something the test can look at.

(defun theme-wait-for (predicate &optional (seconds 60))
  (let ((deadline (+ (get-universal-time) seconds)))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-universal-time) deadline) (return nil))
      (sleep 0.01))))

(defmacro with-theme-task-box ((box editor) &body body)
  "BOX is where the closures another thread posts to the editor's task
land; this thread is that task.  *SELF-TRANSPORT* is SET, not bound: the
thread the test starts does not see this thread's bindings."
  `(let ((,box (make-mailbox))
         (%saved-transport *self-transport*))
     (setf *self-transport*
           (%make-self-transport ,editor
                                 (lambda (thunk wait) (mailbox-post ,box thunk :wait wait))))
     (unwind-protect (progn ,@body)
       (setf *self-transport* %saved-transport))))

(defun theme-from-thread (box editor init before-drain thunk)
  "THUNK called on a thread of its own, as the REPL thread would call it
(with the theme state this test made, since bindings do not cross
threads), while this thread plays the editor's task: BEFORE-DRAIN runs once
the thread has posted its first closure and waits for it -- nothing of the
editor may be touched yet -- then the box is drained until the thread ends.
THUNK's value."
  (let* ((default *default-theme*)
         (answer nil)
         (thread (mp:make-thread
                  (lambda ()
                    (let ((*editor* editor) (*init-file* init)
                          (*default-theme* default) (*theme* nil))
                      (setq answer (funcall thunk))))
                  :name "test-theme-repl")))
    (is (theme-wait-for (lambda () (mailbox-items box))))
    (funcall before-drain)
    (is (theme-wait-for (lambda ()
                          (mailbox-drain box)
                          (not (mp:thread-alive-p thread)))))
    answer))

(deftest load-theme-from-another-thread-reaches-the-frontend-on-the-editors-task
  (with-theme-state ()
    (let* ((doc (make-fake "|"))
           (editor (doc-editor doc))
           (blocker (temp-file "theme-blocker3" "not a directory")))
      (doc-activate doc)
      (unwind-protect
           (with-theme-task-box (box editor)
             ;; A pick: the frontend is told when the editor's task runs the
             ;; closure, and not before.
             (let ((got (theme-from-thread
                         box editor *init-file*
                         (lambda ()
                           (is-equal (fake-editor-theme-applied editor) 0)
                           (is (null (fake-editor-theme editor))))
                         (lambda () (load-theme :dark)))))
               (is (eq got (find-theme :dark)))
               (is (eq (fake-editor-theme editor) (find-theme :dark)))
               (is-equal (fake-editor-theme-applied editor) 1)
               (is (search "(load-theme :dark)" (read-file-text *init-file*))))
             ;; A name no theme has: the message is the first thing posted,
             ;; then the default is shown.
             (let ((got (theme-from-thread
                         box editor *init-file*
                         (lambda ()
                           (is (null (fake-messages doc)))
                           (is-equal (fake-editor-theme-applied editor) 1))
                         (lambda () (load-theme :nope)))))
               (is (eq got (find-theme :light)))
               (is (search "No theme named NOPE" (fake-last-message doc)))
               (is (eq (fake-editor-theme editor) (find-theme :light)))
               (is-equal (fake-editor-theme-applied editor) 2))
             ;; An init file that cannot be written: the theme is shown, then
             ;; the message.
             (let ((got (theme-from-thread
                         box editor (concatenate 'string blocker "/rc")
                         (lambda ()
                           (is-equal (fake-editor-theme-applied editor) 2))
                         (lambda () (load-theme :one-dark)))))
               (is (eq got (find-theme :one-dark)))
               (is (eq (fake-editor-theme editor) (find-theme :one-dark)))
               (is-equal (fake-editor-theme-applied editor) 3)
               (is (search "Cannot write" (fake-last-message doc)))
               (is (search "holds for this session" (fake-last-message doc))))
             ;; On the editor's own task nothing is posted: it runs at once,
             ;; with the transport in place.
             (let ((*editor* editor))
               (is (eq (load-theme :light :save nil) (find-theme :light)))
               (is (null (mailbox-items box)))
               (is (eq (fake-editor-theme editor) (find-theme :light)))
               (is-equal (fake-editor-theme-applied editor) 4)
               (setf (fake-messages doc) '())
               (load-theme :nope :save nil)
               (is (null (mailbox-items box)))
               (is (search "No theme named NOPE" (fake-last-message doc)))))
        (delete-file blocker)))))

(deftest redefining-the-theme-in-effect-shows-at-once
  (with-theme-state ()
    (let ((editor (make-fake-editor)))
      (let ((*editor* editor))
        (define-theme :mine (:inherits :dark) :keyword "#ff0000")
        (load-theme :mine :save nil)
        (is-equal (fake-editor-theme-applied editor) 1)
        (let ((new (define-theme :mine (:inherits :dark) :keyword "#00ff00")))
          (is (eq *theme* new))
          (is (eq (fake-editor-theme editor) new))
          (is-equal (fake-editor-theme-applied editor) 2))
        ;; Another theme redefined: nothing shown.
        (define-theme :other (:inherits :light))
        (define-theme :other (:inherits :dark))
        (is-equal (fake-editor-theme-applied editor) 2)))))

(deftest the-init-file-loads-its-theme-without-writing-itself
  (with-theme-state ()
    (let* ((text (lines "(define-theme :from-rc (:inherits :light :label \"From RC\")"
                        "  :keyword \"#123456\")"
                        "(load-theme :from-rc)"
                        "(bind-key \"C-c t\" 'clamacs-about)"))
           (rc (temp-file "theme-init-rc" text))
           (global *global-bindings*))
      (unwind-protect
           (let ((*init-file* rc))
             (is-equal (load-init-file rc) t)
             (is (eq *theme* (find-theme :from-rc)))
             (is-equal (theme-value *theme* :keyword) "#123456")
             ;; Every byte as it was.
             (is-equal (read-file-text rc) text)
             ;; Outside the load, LOAD-THEME writes again.
             (is *theme-persist*)
             (load-theme :dark)
             (is (search "(load-theme :dark)" (read-file-text rc)))
             (is (search "(define-theme :from-rc" (read-file-text rc)))
             (is (not (search "(load-theme :from-rc)" (read-file-text rc)))))
        (setq *global-bindings* global)
        (delete-file rc)))
    ;; A theme the file names but no longer defines: the editor comes up
    ;; on the default, the file untouched.
    (let ((rc (temp-file "theme-init-rc2" (lines "(load-theme :gone)")))
          (*error-output* (make-string-output-stream)))
      (unwind-protect
           (let ((*init-file* rc))
             (is-equal (load-init-file rc) t)
             (is (null *theme*))
             (is (eq (active-theme) (find-theme :light)))
             (is-equal (read-file-text rc) (lines "(load-theme :gone)"))
             (is (search "No theme named GONE" (get-output-stream-string *error-output*))))
        (delete-file rc)))))

;;; --- the init file's rewrite --------------------------------------------------------

(deftest theme-persist-text-replaces-the-one-form-in-place
  (flet ((rewrite (text) (theme-persist-text text :dark)))
    ;; In the middle of the file.
    (is-equal (rewrite (lines "(bind-key \"C-c d\" 'insert-date)"
                              "(load-theme :light)"
                              "(define-command x (doc arg) nil)"
                              ""))
              (lines "(bind-key \"C-c d\" 'insert-date)"
                     "(load-theme :dark)"
                     "(define-command x (doc arg) nil)"
                     ""))
    ;; At the end, without a trailing newline.
    (is-equal (rewrite (lines "(bind-key \"C-c d\" 'insert-date)" "(load-theme :light)"))
              (lines "(bind-key \"C-c d\" 'insert-date)" "(load-theme :dark)"))
    ;; Alone, and at the very start.
    (is-equal (rewrite "(load-theme :light)") "(load-theme :dark)")
    (is-equal (rewrite (lines "(load-theme :light)" "x")) (lines "(load-theme :dark)" "x"))
    ;; Comments around it and inside it: the form's own text goes, the
    ;; comments stay.
    (is-equal (rewrite (lines ";; before"
                              "(load-theme ; which one"
                              "  :light) ; after"
                              ""))
              (lines ";; before"
                     "(load-theme :dark) ; after"
                     ""))
    ;; A string argument, a quoted symbol, extra arguments: the whole
    ;; form is the one replaced.
    (is-equal (rewrite (lines "(load-theme \"light\" :save nil)" "")) (lines "(load-theme :dark)" ""))
    (is-equal (rewrite (lines "(load-theme 'light)" "")) (lines "(load-theme :dark)" ""))
    ;; Twice: the first wins, as it does when the file loads.
    (is-equal (rewrite (lines "(load-theme :light)" "(load-theme :one-dark)" ""))
              (lines "(load-theme :dark)" "(load-theme :one-dark)" ""))
    ;; With a package prefix, and in upper case.
    (is-equal (rewrite (lines "(clamacs::load-theme :light)" "")) (lines "(load-theme :dark)" ""))
    (is-equal (rewrite (lines "(clamacs:load-theme :light)" "")) (lines "(load-theme :dark)" ""))
    (is-equal (rewrite (lines "(LOAD-THEME :LIGHT)" "")) (lines "(load-theme :dark)" ""))))

(deftest theme-persist-text-appends-when-there-is-no-form
  (flet ((rewrite (text) (theme-persist-text text :dark))
         (appended (&rest before)
           (format nil "~{~A~%~}~A~%(load-theme :dark)~%" before *theme-persist-comment*)))
    ;; An empty file, a file with a trailing newline, one without.
    (is-equal (rewrite "") (format nil "~A~%(load-theme :dark)~%" *theme-persist-comment*))
    (is-equal (rewrite (lines "(bind-key \"C-c d\" 'insert-date)" ""))
              (appended "(bind-key \"C-c d\" 'insert-date)" ""))
    (is-equal (rewrite "(bind-key \"C-c d\" 'insert-date)")
              (appended "(bind-key \"C-c d\" 'insert-date)" ""))
    ;; A guarded form is not the form: its paren is off column 0.
    (is-equal (rewrite (lines "#+amigaos (load-theme :light)" ""))
              (appended "#+amigaos (load-theme :light)" ""))
    ;; ... but the plain one beside it is.
    (is-equal (rewrite (lines "#+amigaos (load-theme :light)" "(load-theme :light)" ""))
              (lines "#+amigaos (load-theme :light)" "(load-theme :dark)" ""))
    ;; Indented, in a comment, in a string: none of these.
    (is-equal (rewrite (lines "  (load-theme :light)" ""))
              (appended "  (load-theme :light)" ""))
    (is-equal (rewrite (lines ";; (load-theme :light)" ""))
              (appended ";; (load-theme :light)" ""))
    (is-equal (rewrite (lines "#| a block" "(load-theme :light)" "|#" ""))
              (appended "#| a block" "(load-theme :light)" "|#" ""))
    (is-equal (rewrite (lines "(defparameter *s* \"" "(load-theme :light)\")" ""))
              (appended "(defparameter *s* \"" "(load-theme :light)\")" ""))
    ;; Another head.
    (is-equal (rewrite (lines "(load-themes :light)" ""))
              (appended "(load-themes :light)" ""))
    (is-equal (rewrite (lines "(my-load-theme :light)" ""))
              (appended "(my-load-theme :light)" ""))
    ;; A form the scanner cannot bound is left alone, never cut in half.
    (is-equal (rewrite "(load-theme :light")
              (appended "(load-theme :light" ""))
    (is-equal (rewrite (lines "(load-theme :light \"unterminated)" ""))
              (appended "(load-theme :light \"unterminated)" ""))))

(deftest theme-form-bounds-finds-the-form
  (is-equal (multiple-value-list (theme-form-bounds "(load-theme :x)")) '(0 15))
  (is-equal (multiple-value-list (theme-form-bounds (lines "a" "(load-theme :x)" "b"))) '(2 17))
  (is (null (theme-form-bounds "")))
  (is (null (theme-form-bounds "(foo)")))
  (is (null (theme-form-bounds " (load-theme :x)")))
  (is (null (theme-form-bounds "(load-theme")))
  (is (null (theme-form-bounds "load-theme :x")))
  (is (theme-head-p "load-theme"))
  (is (theme-head-p "LOAD-THEME"))
  (is (theme-head-p "clamacs::load-theme"))
  (is (not (theme-head-p "load-themes")))
  (is (not (theme-head-p ""))))

(deftest theme-persist-writes-the-init-file
  (with-theme-state ()
    ;; No file: made, with the form under the comment -- and no sibling
    ;; left behind.
    (is (null (probe-file *init-file*)))
    (is (theme-persist :one-dark))
    (is-equal (read-file-text *init-file*)
              (format nil "~A~%(load-theme :one-dark)~%" *theme-persist-comment*))
    (is (null (probe-file (concatenate 'string *init-file* ".tmp"))))
    (is (null (probe-file (concatenate 'string *init-file* ".bak"))))
    ;; A file with things in it: the form replaced, the rest kept.
    (write-file-text *init-file* (lines ";; mine" "(load-theme :one-dark)" "(bind-key \"C-c t\" 'clamacs-about)" ""))
    (is (theme-persist :light))
    (is-equal (read-file-text *init-file*)
              (lines ";; mine" "(load-theme :light)" "(bind-key \"C-c t\" 'clamacs-about)" ""))
    ;; Nothing to change: true, and the file as it was.
    (let ((date (file-write-date *init-file*)))
      (is (theme-persist :light))
      (is-equal (file-write-date *init-file*) date))
    ;; A path that cannot be written: NIL, nothing made.
    (let ((blocker (temp-file "theme-blocker2" "x")))
      (unwind-protect
           (progn
             (is (null (theme-persist :dark (concatenate 'string blocker "/rc"))))
             (is (null (probe-file (concatenate 'string blocker "/rc")))))
        (delete-file blocker)))))

;;; The init file is the user's: a write that fails on the way -- the
;;; sibling cannot be written, the swap does not happen -- leaves it as it was.

(deftest theme-swap-in-on-the-amiga-keeps-the-old-file-until-the-new-one-is-in
  ;; The Amiga's rename deletes its target first: the branch that steps the
  ;; old file aside runs here with the feature set, over the host's rename.
  (let ((*features* (cons :amigaos *features*))
        (target (temp-file "theme-swap-target" "old"))
        (tmp (temp-file "theme-swap-tmp" "new")))
    (unwind-protect
         (progn
           ;; The new file cannot take the place (it is not there): the old
           ;; one comes back, whole, and no backup is left.
           (is (null (theme-swap-in (temp-path "theme-swap-missing") target)))
           (is-equal (read-file-text target) "old")
           (is (null (probe-file (concatenate 'string target ".bak"))))
           ;; The swap: the new text in, the backup gone with it.
           (is (theme-swap-in tmp target))
           (is-equal (read-file-text target) "new")
           (is (null (probe-file tmp)))
           (is (null (probe-file (concatenate 'string target ".bak")))))
      (delete-quietly target)
      (delete-quietly tmp)
      (delete-quietly (concatenate 'string target ".bak")))))

(deftest theme-persist-keeps-the-file-when-the-sibling-cannot-be-written
  (unless (member :amigaos *features*)
    (with-theme-state ()
      (let* ((text (lines ";; mine" "(load-theme :one-dark)" "(bind-key \"C-c t\" 'clamacs-about)" ""))
             (rc (temp-file "theme-keep-rc" text))
             (tmp (concatenate 'string rc ".tmp"))
             (keep (concatenate 'string tmp "/keep")))
        ;; The sibling's name is taken by a directory that is not empty:
        ;; it can neither be replaced nor written.
        (ensure-directories-exist keep)
        (unwind-protect
             (progn
               (is (write-file-text keep "k"))
               (is (null (theme-persist :dark rc)))
               (is-equal (read-file-text rc) text)
               (is-equal (read-file-text keep) "k"))
          (ext:system-command (format nil "rm -rf '~A'" tmp))
          (delete-quietly rc))))))

(deftest theme-write-file-keeps-the-target-when-the-swap-fails
  (unless (member :amigaos *features*)
    ;; The target is a directory: the sibling is written and read back, but
    ;; a file cannot be renamed over it.  The target is as it was and the
    ;; sibling is gone.
    (let* ((dir (temp-path "theme-target-dir"))
           (keep (concatenate 'string dir "/keep")))
      (ensure-directories-exist keep)
      (unwind-protect
           (progn
             (is (write-file-text keep "k"))
             (is (null (theme-write-file dir "new text")))
             (is-equal (read-file-text keep) "k")
             (is (null (probe-file (concatenate 'string dir ".tmp")))))
        (ext:system-command (format nil "rm -rf '~A'" dir))))))

(deftest theme-persist-writes-through-a-symlink
  ;; A dotfile manager's link stays a link; the file behind it changes.
  (unless (member :amigaos *features*)
    (with-theme-state ()
      (let* ((real (temp-file "theme-real-rc" (lines ";; mine" "(load-theme :one-dark)" "")))
             (link (temp-path "theme-link-rc")))
        (delete-quietly link)
        (unwind-protect
             (when (and (zerop (ext:system-command (format nil "ln -s '~A' '~A'" real link)))
                        (zerop (ext:system-command (format nil "test -L '~A'" link))))
               (is (theme-persist :dark link))
               (is (zerop (ext:system-command (format nil "test -L '~A'" link))))
               (is-equal (read-file-text real) (lines ";; mine" "(load-theme :dark)" ""))
               (is-equal (read-file-text link) (read-file-text real))
               ;; Nothing left beside either of them.
               (is (null (probe-file (concatenate 'string real ".tmp"))))
               (is (null (probe-file (concatenate 'string link ".tmp")))))
          (delete-quietly link)
          (delete-quietly real))))))

;;; --- M-x clamacs-theme --------------------------------------------------------------

(deftest clamacs-theme-prompts-with-completion
  (with-theme-state ()
    (let* ((doc (make-fake "|"))
           (editor (doc-editor doc)))
      (doc-activate doc)
      (let ((*editor* editor))
        (run-command doc 'clamacs-theme)
        (is-equal (fake-prompt doc) "Theme: ")
        ;; A message while the prompt is open takes the label's place.
        (type-text doc "sol")
        (type-keys doc "TAB")
        (is-equal (fake-mini-text doc) "solarized-")
        (is-equal (doc-message-text doc) "[2 completions]")
        (type-text doc "d")
        (type-keys doc "TAB")
        (is-equal (fake-mini-text doc) "solarized-dark")
        (is-equal (doc-message-text doc) "[Sole completion]")
        (type-keys doc "RET")
        (is (null (fake-prompt doc)))
        (is (eq *theme* (find-theme :solarized-dark)))
        (is (eq (fake-editor-theme editor) (find-theme :solarized-dark)))
        (is-equal (fake-last-message doc) "Theme: Solarized Dark")
        (is (search "(load-theme :solarized-dark)" (read-file-text *init-file*)))
        ;; C-u: for this session only.
        (run-command doc 'clamacs-theme 4)
        (type-text doc "light")
        (type-keys doc "RET")
        (is (eq *theme* (find-theme :light)))
        (is-equal (fake-last-message doc) "Theme: Light (this session)")
        (is (search "(load-theme :solarized-dark)" (read-file-text *init-file*)))
        ;; A name no theme has: said, with a beep, nothing changed.
        (run-command doc 'clamacs-theme)
        (type-text doc "nope")
        (type-keys doc "RET")
        (is-equal (fake-last-message doc) "No theme named nope")
        (is-equal (fake-beeps doc) 1)
        (is (eq *theme* (find-theme :light)))
        ;; TAB on nothing lists them all; a miss says so.
        (run-command doc 'clamacs-theme)
        (type-keys doc "TAB")
        (is-equal (doc-message-text doc) "[6 completions]")
        (type-text doc "zzz")
        (type-keys doc "TAB")
        (is-equal (doc-message-text doc) "[No match]")
        (type-keys doc "C-g")
        (is (eq *theme* (find-theme :light)))))))

(deftest clamacs-theme-is-a-command-the-menu-can-reach
  (is (find-command "clamacs-theme"))
  (is (command-function 'clamacs-theme)))

;;; --- the View menu's entries ------------------------------------------------------

(deftest the-theme-menu-lists-built-ins-then-the-users
  (with-theme-state ()
    (is-equal (mapcar #'car (theme-menu))
              '("Light" "Dark" "Solarized Light" "Solarized Dark" "One Dark" "Gruvbox Dark"))
    (is (every (lambda (e) (theme-p (cdr e))) (theme-menu)))
    (define-theme :mine (:inherits :dark :label "Mine"))
    (define-theme :other (:inherits :light))
    (is-equal (mapcar (lambda (e) (if (consp e) (car e) e)) (theme-menu))
              '("Light" "Dark" "Solarized Light" "Solarized Dark" "One Dark" "Gruvbox Dark"
                :bar "Mine" "Other"))
    (is (eq (cdr (car (last (theme-menu)))) (find-theme :other)))))
