;;;; theme.lisp -- colour themes: the struct, the built-ins, the registry,
;;;; LOAD-THEME, the two views the frontends read, and the init file's form.
;;;;
;;;; A theme is DATA the frontends read, never code a frontend runs: the
;;;; same DEFINE-THEME form means the same on the host and on the Amiga,
;;;; and a frontend honours what it can of it and says nothing about the
;;;; rest (specs/clamacs-themes.md).  The keys are the host page's CSS
;;;; variables spelled as keywords; THEME-CSS-VARS answers them as the
;;;; page wants them, THEME-PENS as the eight RGB triples of the MUI text
;;;; class's colour map.  A theme has one implementation with three
;;;; entrances -- the View menu (menu.lisp), `M-x clamacs-theme' and the
;;;; init file's form -- and all three end in LOAD-THEME.
;;;;
;;;; Pure: no MUI, no OS types.  The init file's rewrite is string work
;;;; over the sexp scanner (THEME-PERSIST-TEXT); the file I/O goes through
;;;; a temp file and a swap (THEME-WRITE-FILE), since the file is the
;;;; user's.  The minimap setting at the end of the file -- one flag,
;;;; the View menu's other item -- is kept the same way, with the same
;;;; three entrances (the menu, `M-x clamacs-toggle-minimap', the init
;;;; file's `(show-minimap ...)' form) ending in SHOW-MINIMAP.

(in-package :clamacs)

;;; ------------------------------------------------------------------
;;; The keys
;;; ------------------------------------------------------------------

(defparameter *theme-text-keys* '(:bg :fg :dim :cursor :selection :active-line))
(defparameter *theme-gutter-keys* '(:gutter-bg :gutter-fg))
(defparameter *theme-chrome-keys* '(:bar :bar-fg :tab-active :line
                                    :status-bg :status-fg :echo-bg :echo-fg))
(defparameter *theme-token-keys* '(:comment :string :number :keyword :defining
                                   :symbol :paren-match :paren-bad))
(defparameter *theme-font-keys* '(:font-family :font-size))

(defun theme-colour-keys ()
  (append *theme-text-keys* *theme-gutter-keys* *theme-chrome-keys* *theme-token-keys*))

(defun theme-keys ()
  "Every key a theme may set, in the order the CSS lists them."
  (append (theme-colour-keys) *theme-font-keys*))

(defun theme-rgb (value)
  "The three components of VALUE, a `#rrggbb' string, or NIL for anything
else."
  (and (stringp value)
       (= (length value) 7)
       (char= (char value 0) #\#)
       (loop for i from 1 below 7 always (digit-char-p (char value i) 16))
       (values (parse-integer value :start 1 :end 3 :radix 16)
               (parse-integer value :start 3 :end 5 :radix 16)
               (parse-integer value :start 5 :end 7 :radix 16))))

;;; ------------------------------------------------------------------
;;; The struct and the registry
;;; ------------------------------------------------------------------

(defstruct (theme (:constructor %make-theme (name label dark inherits builtin values)))
  name                       ; a keyword
  label                      ; what the menu shows
  dark                       ; T for a dark background: the Amiga's
                             ; shallow-screen rule reads it
  inherits                   ; the name of the theme unset keys come from, or NIL
  builtin                    ; T for the ones this file defines
  values)                    ; alist of key and value: what THIS theme sets

(defvar *themes* '()
  "The registry, in definition order: the built-ins, then the user's.")

(defvar *theme* nil
  "The theme LOAD-THEME picked, or NIL: the default applies.")

(defvar *default-theme* :light
  "The theme an editor without a pick shows -- what the page would show
anyway: :LIGHT, or :DARK once the frontend has said the system is dark.")

(defvar *theme-builtin* nil
  "True while this file defines its themes.")

(defun theme-name-string (name)
  (string-downcase (symbol-name name)))

(defun find-theme (name)
  "The theme NAME -- a keyword, a symbol, its name as a string in any
case, or a theme -- or NIL."
  (cond ((theme-p name) name)
        ((and name (symbolp name))
         (find (symbol-name name) *themes*
               :key (lambda (th) (symbol-name (theme-name th))) :test #'string-equal))
        ((stringp name)
         (find name *themes*
               :key (lambda (th) (symbol-name (theme-name th))) :test #'string-equal))
        (t nil)))

(defun theme-names ()
  "Every theme's name as a lowercase string, in registry order: what the
prompt completes over."
  (mapcar (lambda (th) (theme-name-string (theme-name th))) *themes*))

(defun active-theme ()
  "The theme in effect: the picked one, else the default."
  (or *theme* (find-theme *default-theme*)))

(defun theme-plain-name-p (name)
  "A keyword whose name reads back from the lowercase spelling the init
file gets: letters, digits and hyphens."
  (and (keywordp name)
       (> (length (symbol-name name)) 0)
       (every (lambda (c) (or (alphanumericp c) (char= c #\-))) (symbol-name name))))

(defun theme-label-from-name (name)
  (string-capitalize (substitute #\Space #\- (theme-name-string name))))

(defun theme-check-values (name colours)
  "COLOURS, a plist of key and value, as the alist a theme keeps.  A key
that is not a theme's, or a colour that is not `#rrggbb', is an error
naming the theme -- LOAD reports it with the init file's line."
  (let ((values '()))
    (when (oddp (length colours))
      (error "Theme ~S: a key without a value at the end (~S)." name (car (last colours))))
    (loop for (key value) on colours by #'cddr
          do (cond ((not (member key (theme-keys)))
                    (error "Theme ~S: ~S is not a theme key; the keys are ~{~S~^ ~}."
                           name key (theme-keys)))
                   ((and (member key *theme-font-keys*) (not (stringp value)))
                    (error "Theme ~S: ~S needs a string, not ~S." name key value))
                   ((and (member key (theme-colour-keys)) (not (theme-rgb value)))
                    (error "Theme ~S: ~S needs a colour spelled #rrggbb, not ~S."
                           name key value))
                   (t (push (cons key value) values))))
    (nreverse values)))

(defun make-theme (name options colours)
  "A theme NAME from OPTIONS (:inherits :label :dark) and COLOURS, checked."
  (unless (theme-plain-name-p name)
    (error "A theme's name is a keyword of letters, digits and hyphens, not ~S." name))
  (destructuring-bind (&key inherits label (dark nil dark-p)) options
    (let ((parent (and inherits (find-theme inherits))))
      (when (and inherits (null parent))
        (error "Theme ~S inherits ~S, which is not defined (the themes are ~{~A~^ ~})."
               name inherits (theme-names)))
      (when (and label (not (stringp label)))
        (error "Theme ~S: the label must be a string, not ~S." name label))
      (%make-theme name
                   (or label (theme-label-from-name name))
                   (cond (dark-p (and dark t))
                         (parent (theme-dark parent))
                         (t nil))
                   (and parent (theme-name parent))
                   *theme-builtin*
                   (theme-check-values name colours)))))

(defun register-theme (theme)
  "THEME into the registry: in the place of the theme of that name when
there is one, at the end otherwise.  A redefinition of the theme in
effect takes effect at once -- a theme edited in the REPL shows."
  (let ((old (find-theme (theme-name theme))))
    (if old
        (setf *themes* (substitute theme old *themes*))
        (setf *themes* (append *themes* (list theme))))
    (when (and old (eq *theme* old))
      (setf *theme* theme)
      (theme-apply theme))
    theme))

(defun forget-theme (name)
  "Take the theme NAME out of the registry.  The theme in effect stays in
effect until the next LOAD-THEME.  True when there was one."
  (let ((theme (find-theme name)))
    (when theme
      (setf *themes* (remove theme *themes*))
      t)))

(defmacro define-theme (name (&rest options) &rest colours)
  "Define the theme NAME: `(define-theme :my-dark (:inherits :dark :label
\"Mine\") :keyword \"#ff9900\")'.  OPTIONS are :INHERITS (a defined theme,
whose values stand for every key left out), :LABEL (the menu's text, the
name capitalised by default) and :DARK (T for a dark background; the
parent's flag by default).  COLOURS are key and `#rrggbb' pairs over the
keys of THEME-KEYS; :FONT-FAMILY and :FONT-SIZE take any string."
  `(register-theme (make-theme ',name ',options ',colours)))

;;; ------------------------------------------------------------------
;;; Resolution and the two views
;;; ------------------------------------------------------------------

(defun theme-value (theme key)
  "What THEME sets for KEY, through its inherit chain; NIL when nothing
in the chain sets it."
  (let ((seen '()))
    (loop for th = theme then (and (theme-inherits th) (find-theme (theme-inherits th)))
          while (and th (not (member th seen)))
          do (let ((cell (assoc key (theme-values th))))
               (when cell (return (cdr cell))))
             (push th seen))))

(defun theme-resolve (theme key)
  "THEME-VALUE, and for a key the chain leaves unset the default theme's
value -- what the page would show anyway -- so a frontend always gets a
whole picture."
  (or (theme-value theme key)
      (let ((default (find-theme *default-theme*)))
        (and default (not (eq default theme)) (theme-value default key)))))

(defun theme-css-var (key)
  "The page's variable for KEY: `--bg', `--c-keyword', `--font-size'."
  (if (member key *theme-token-keys*)
      (format nil "--c-~(~A~)" key)
      (format nil "--~(~A~)" key)))

(defun theme-css-vars (theme)
  "THEME as the host page takes it: an alist of CSS variable name and
value, every key resolved; a key nothing sets is left out."
  (loop for key in (theme-keys)
        for value = (theme-resolve theme key)
        when value collect (cons (theme-css-var key) value)))

;;; The MUI text class's colour map, by slot: SetBlock's colour values are
;;; 1-based, so slot 1 is the first pen (the C editor's black, now the
;;; text colour), slot 2 the second (white, free), then the paren match,
;;; comment, keyword, string, defining, number -- COLOUR-VALUE's numbers
;;; in frontend-mui.lisp.  The paren match is a FOREGROUND pen there (the
;;; class colours characters, it does not tint behind them), so it takes
;;; :NUMBER's colour -- green on the two default themes, as the page's
;;; :PAREN-MATCH tint is -- and not the tint itself, which would be a pale
;;; paren on a pale page (decided at T3, 2026-09-26).
(defparameter *theme-pen-keys* '(:fg nil :number :comment :keyword :string :defining :number))

(defun theme-pens (theme)
  "THEME as the MUI frontend takes it: eight (R G B) lists in the colour
map's order.  The free slot is white."
  (mapcar (lambda (key)
            (multiple-value-bind (r g b) (and key (theme-rgb (theme-resolve theme key)))
              (if r (list r g b) (list 255 255 255))))
          *theme-pen-keys*))

(defun theme-background-spec (theme)
  "THEME's :BG as a MUI image spec, `2:rrrrrrrr,gggggggg,bbbbbbbb' -- an
RGB colour, each component a 32-bit value with the byte repeated, the
form MUIA_Background takes.  NIL when the theme has no :BG."
  (multiple-value-bind (r g b) (theme-rgb (theme-resolve theme :bg))
    (and r
         (flet ((wide (c) (* c #x01010101)))
           (string-downcase
            (format nil "2:~8,'0x,~8,'0x,~8,'0x" (wide r) (wide g) (wide b)))))))

;;; The Amiga's shallow-screen rule: on a Workbench with 16 colours or
;;; fewer ObtainBestPen answers nearest matches, and a dark theme's text on
;;; its background comes out as one grey on another.  So such a theme
;;; applies its token colours only there and leaves the text and the
;;; background to the class's own -- a function of the depth and the theme,
;;; so it is tested without a screen.
(defconstant +theme-shallow-depth+ 4)

(defun theme-text-pens-p (theme depth)
  "Whether a frontend that paints with pens should paint THEME's text and
background colours on a screen of DEPTH bitplanes: always for a light
theme, and for a dark one on a screen deeper than +THEME-SHALLOW-DEPTH+
\(more than 16 colours).  A DEPTH of NIL (not known) says yes."
  (or (not (theme-dark theme))
      (null depth)
      (> depth +theme-shallow-depth+)))

;;; ------------------------------------------------------------------
;;; The built-ins
;;; ------------------------------------------------------------------

;;; :light and :dark are host/page-head.html's two palettes, byte for
;;; byte (tests/test-theme.lisp reads the CSS to check), so an editor that
;;; never picked a theme looks exactly as before.  The font is the page's.

(setq *theme-builtin* t)

(define-theme :light (:label "Light")
  :bg "#ffffff" :fg "#1f1f1f" :dim "#6a6a6a"
  :cursor "#1f1f1f" :selection "#b8d4ff" :active-line "#f6f8fc"
  :gutter-bg "#f7f7f7" :gutter-fg "#9a9a9a"
  :bar "#ececec" :bar-fg "#333333" :tab-active "#ffffff" :line "#d0d0d0"
  :status-bg "#e4e8f0" :status-fg "#1a3a6a"
  :echo-bg "#f4f4f4" :echo-fg "#1f1f1f"
  :comment "#7a7a7a" :string "#a31515" :number "#098658"
  :keyword "#0000ff" :defining "#795e26" :symbol "#1f1f1f"
  :paren-match "#c8e6c9" :paren-bad "#ffcdd2"
  :font-family "\"SF Mono\", Menlo, monospace" :font-size "14px")

(define-theme :dark (:label "Dark" :dark t)
  :bg "#1e1e1e" :fg "#d4d4d4" :dim "#8a8a8a"
  :cursor "#d4d4d4" :selection "#264f78" :active-line "#232323"
  :gutter-bg "#1e1e1e" :gutter-fg "#6e6e6e"
  :bar "#2d2d30" :bar-fg "#cccccc" :tab-active "#1e1e1e" :line "#3c3c3c"
  :status-bg "#223047" :status-fg "#9cdcfe"
  :echo-bg "#252526" :echo-fg "#d4d4d4"
  :comment "#6a9955" :string "#ce9178" :number "#b5cea8"
  :keyword "#569cd6" :defining "#dcdcaa" :symbol "#d4d4d4"
  :paren-match "#2f5f2f" :paren-bad "#6f2f2f"
  :font-family "\"SF Mono\", Menlo, monospace" :font-size "14px")

;;; Ethan Schoonover's Solarized: base3/base2/base1/base00 on the light
;;; side, base03/base02/base01/base0 on the dark, the same eight accents.
(define-theme :solarized-light (:inherits :light :label "Solarized Light")
  :bg "#fdf6e3" :fg "#657b83" :dim "#93a1a1"
  :cursor "#657b83" :selection "#eee8d5" :active-line "#f5efdc"
  :gutter-bg "#eee8d5" :gutter-fg "#93a1a1"
  :bar "#eee8d5" :bar-fg "#586e75" :tab-active "#fdf6e3" :line "#ddd6c1"
  :status-bg "#eee8d5" :status-fg "#268bd2"
  :echo-bg "#fdf6e3" :echo-fg "#657b83"
  :comment "#93a1a1" :string "#2aa198" :number "#d33682"
  :keyword "#859900" :defining "#268bd2" :symbol "#657b83"
  :paren-match "#d6e2b4" :paren-bad "#f5c6c1")

(define-theme :solarized-dark (:inherits :dark :label "Solarized Dark")
  :bg "#002b36" :fg "#839496" :dim "#586e75"
  :cursor "#839496" :selection "#073642" :active-line "#073642"
  :gutter-bg "#073642" :gutter-fg "#586e75"
  :bar "#073642" :bar-fg "#93a1a1" :tab-active "#002b36" :line "#0f3a45"
  :status-bg "#073642" :status-fg "#268bd2"
  :echo-bg "#002b36" :echo-fg "#839496"
  :comment "#586e75" :string "#2aa198" :number "#d33682"
  :keyword "#859900" :defining "#268bd2" :symbol "#839496"
  :paren-match "#2d5a3d" :paren-bad "#6b2a2a")

;;; Atom's One Dark.
(define-theme :one-dark (:inherits :dark :label "One Dark")
  :bg "#282c34" :fg "#abb2bf" :dim "#5c6370"
  :cursor "#528bff" :selection "#3e4451" :active-line "#2c313c"
  :gutter-bg "#282c34" :gutter-fg "#4b5263"
  :bar "#21252b" :bar-fg "#9da5b4" :tab-active "#282c34" :line "#181a1f"
  :status-bg "#21252b" :status-fg "#61afef"
  :echo-bg "#21252b" :echo-fg "#abb2bf"
  :comment "#5c6370" :string "#98c379" :number "#d19a66"
  :keyword "#c678dd" :defining "#61afef" :symbol "#abb2bf"
  :paren-match "#3a5f3a" :paren-bad "#6e2f2f")

;;; Pavel Pertsev's Gruvbox, the dark medium contrast.
(define-theme :gruvbox-dark (:inherits :dark :label "Gruvbox Dark")
  :bg "#282828" :fg "#ebdbb2" :dim "#928374"
  :cursor "#ebdbb2" :selection "#504945" :active-line "#3c3836"
  :gutter-bg "#282828" :gutter-fg "#7c6f64"
  :bar "#3c3836" :bar-fg "#d5c4a1" :tab-active "#282828" :line "#1d2021"
  :status-bg "#3c3836" :status-fg "#83a598"
  :echo-bg "#3c3836" :echo-fg "#ebdbb2"
  :comment "#928374" :string "#b8bb26" :number "#d3869b"
  :keyword "#fb4934" :defining "#fabd2f" :symbol "#ebdbb2"
  :paren-match "#4a5f2a" :paren-bad "#7a2a2a")

(setq *theme-builtin* nil)

;;; ------------------------------------------------------------------
;;; Remembering the choice: the init file
;;; ------------------------------------------------------------------

;;; The editor never rewrites the user's file, only the one form: the
;;; first top-level `(load-theme ...)' -- an open paren in column 0
;;; outside a string or comment, its head LOAD-THEME in any package --
;;; is replaced by exactly its own text; without one the form is appended
;;; under a comment; every other byte stays.  (The same for the minimap's
;;; `(show-minimap ...)': the machinery takes the form's head as a
;;; parameter, INIT-FORM-PERSIST.)  A `#+amigaos' before a form
;;; puts its paren off column 0, so a guarded form is left alone, as a
;;; second form is (the first wins, as it does when the file loads), and
;;; a form the scanner cannot bound (unbalanced) is left alone too and the
;;; form appended instead -- never a partial replacement.

(defparameter *theme-persist-comment*
  ";; Written by M-x clamacs-theme and the View menu")

(defun theme-form-text (name)
  (format nil "(load-theme :~A)" (theme-name-string name)))

(defun theme-head-p (token &optional (head "load-theme"))
  "Whether TOKEN, an atom's text, names HEAD (LOAD-THEME), with or
without a package prefix."
  (let ((colon (position #\: token :from-end t)))
    (string-equal (if colon (subseq token (1+ colon)) token) head)))

(defun theme-form-bounds (text &optional (head "load-theme"))
  "The start and end of the top-level `(HEAD ...)' form in TEXT -- the
`(load-theme ...)' form -- two values, or NIL."
  (let* ((buf (sx-simple text))
         (len (length buf)))
    (declare (simple-string buf) (fixnum len))
    (do-sx-tokens (kind start end buf len)
      (when (and (eq kind :open)
                 (or (= start 0) (char= (schar buf (1- start)) #\Newline)))
        (multiple-value-bind (k2 s2 e2) (sx-next buf len end)
          (when (and (eq k2 :atom) (theme-head-p (subseq buf s2 e2) head))
            (let ((close (sexp-forward buf start)))
              (return (and close (values start close))))))))))

(defun init-form-persist-text (text head form comment)
  "TEXT, the init file, with FORM as its `(HEAD ...)' form: the one it
has replaced in place, or FORM appended under COMMENT."
  (multiple-value-bind (start end) (theme-form-bounds text head)
    (if start
        (concatenate 'string (subseq text 0 start) form (subseq text end))
        (concatenate 'string
                     text
                     (cond ((string= text "") "")
                           ((char= (char text (1- (length text))) #\Newline)
                            (string #\Newline))
                           (t (format nil "~%~%")))
                     comment (string #\Newline)
                     form (string #\Newline)))))

(defun theme-persist-text (text name)
  "TEXT, the init file, with `(load-theme :NAME)' as its theme form: the
one it has replaced in place, or the form appended."
  (init-form-persist-text text "load-theme" (theme-form-text name) *theme-persist-comment*))

;;; The init file is the USER's, hand-written and often a dotfile manager's
;;; symlink, not a file the editor owns like the layout file: a write that
;;; deletes it first (WRITE-FILE-TEXT's :SUPERSEDE) would leave it empty
;;; after a full disk or a reset, and would turn the link into a plain
;;; file.  So the text goes to a sibling file, is read back, and only then
;;; takes the file's place -- and the place is the link's target.

(defun theme-persist-target (path)
  "The file PATH stands for: its truename when it exists, so a symlink is
followed and stays a link, else PATH itself."
  (let* ((true (ignore-errors (probe-file path)))
         (name (and true (ignore-errors (namestring true)))))
    (if (and name (ignore-errors (probe-file name))) name path)))

(defun theme-swap-in (tmp target)
  "TMP, whole and checked, into TARGET's place: true when TARGET holds it
now.  On a failure TARGET is as it was.  A rename replaces its target in
one step on POSIX and Windows; on the Amiga it deletes the target first, so
there the old file steps aside as `TARGET.bak' and comes back when the new
one cannot take its place."
  (flet ((move (from to) (ignore-errors (rename-file from to) t)))
    (if (and (member :amigaos *features*) (probe-file target))
        (let ((bak (concatenate 'string target ".bak")))
          (and (move target bak)
               (or (move tmp target)
                   (progn (move bak target) nil))
               (progn (delete-quietly bak) t)))
        (move tmp target))))

(defun theme-write-file (target text)
  "TEXT to TARGET so that TARGET always holds the old text or the whole
new one: written to `TARGET.tmp' (the drawer made first), read back,
swapped in.  True when written; on NIL TARGET is untouched."
  (let ((tmp (concatenate 'string target ".tmp")))
    (unwind-protect
         (and (snapshot-write-file tmp text)
              (equal (read-file-text tmp) text)
              (theme-swap-in tmp target))
      (delete-quietly tmp))))

(defun init-form-persist (head form comment &optional (path *init-file*))
  "FORM, the `(HEAD ...)' form of the init file PATH, into it (the file
is made when missing), replacing the one there or appended under
COMMENT.  True when the file holds it now (an unchanged file is not
rewritten); NIL when it could not be read or written, in which case the
file is as it was."
  (let* ((target (theme-persist-target path))
         (old (read-file-text target)))
    (cond ((and (null old) (probe-file target))
           ;; There, but unreadable: not something to write over.
           nil)
          (t
           (let* ((old (or old ""))
                  (new (init-form-persist-text old head form comment)))
             (or (string= old new)
                 (theme-write-file target new)))))))

(defun theme-persist (name &optional (path *init-file*))
  "The choice NAME into the init file PATH: `(load-theme :NAME)' as its
theme form.  True when the file holds it now, NIL when it could not be
read or written (INIT-FORM-PERSIST)."
  (init-form-persist "load-theme" (theme-form-text name) *theme-persist-comment* path))

;;; ------------------------------------------------------------------
;;; LOAD-THEME: the one implementation
;;; ------------------------------------------------------------------

;;; LOAD-THEME is called from a form at the self REPL, where it runs on the
;;; REPL thread, and only the editor's task may touch a frontend
;;; (mailbox.lisp).  So what reaches a document or the editor -- the
;;; message, the theme -- goes through CALL-IN-EDITOR-TASK, which runs the
;;; closure directly when the caller IS the editor's task (the menu, the
;;; command, the init file).  That function is in transport-self.lisp, which
;;; loads after this file: it is looked up when called, and without it (a
;;; subset of the files loaded) the closure simply runs.

(defun theme-on-editor-task (thunk)
  "THUNK's values, THUNK run on the editor's task."
  (if (fboundp 'call-in-editor-task)
      (funcall 'call-in-editor-task thunk)
      (funcall thunk)))

(defun theme-note (control &rest args)
  "A message where the user looks: the active document's echo area, or
the console before there is a window (the init file loads first)."
  (let ((text (apply #'format nil control args))
        (editor *editor*))
    (unless (and editor
                 (theme-on-editor-task
                  (lambda ()
                    (let ((doc (editor-active-document editor)))
                      (when doc
                        (doc-message doc text)
                        t)))))
      (format *error-output* "clamacs: ~A~%" text))))

(defun theme-apply (theme)
  "THEME to the running frontend, when there is one."
  (let ((editor *editor*))
    (when editor
      (theme-on-editor-task (lambda () (editor-apply-theme editor theme))))))

(defun load-theme (name &key (save t))
  "Make NAME the theme: *THEME*, the frontend told, and -- unless SAVE is
NIL, or the init file is loading its own form -- the choice written into
the init file.  A name no theme has (a misspelling in the init file, a
theme the user's file no longer defines) falls back to the default with
a message, never an error: the editor must come up.  Answers the theme
in effect.  Callable from any thread: the frontend is reached on the
editor's task."
  (let ((theme (find-theme name)))
    (cond (theme
           (setf *theme* theme)
           (theme-apply theme)
           (when (and save *theme-persist*)
             (unless (theme-persist (theme-name theme))
               (theme-note "Cannot write ~A; the theme holds for this session" *init-file*)))
           theme)
          (t
           (theme-note "No theme named ~A; the themes are ~{~A~^ ~}" name (theme-names))
           (setf *theme* nil)
           (let ((default (active-theme)))
             (when default (theme-apply default))
             default)))))

;;; ------------------------------------------------------------------
;;; The View menu's lines and M-x clamacs-theme
;;; ------------------------------------------------------------------

(defun theme-menu ()
  "The View menu as it should be now: (LABEL . THEME) for each theme,
the built-ins first, a :BAR before the user's when there are any."
  (let ((builtins (remove-if-not #'theme-builtin *themes*))
        (users (remove-if #'theme-builtin *themes*)))
    (flet ((entries (themes) (mapcar (lambda (th) (cons (theme-label th) th)) themes)))
      (if (and builtins users)
          (append (entries builtins) (list :bar) (entries users))
          (entries (append builtins users))))))

(defun theme-completer (prefix)
  (complete (theme-names) prefix))

(define-command clamacs-theme (doc arg)
  "Pick a theme by name, with completion.  With `C-u' the theme applies
for this session only and the init file is left alone."
  (let ((save (eql arg 1)))
    (prompt doc "Theme: "
            (lambda (doc answer)
              (let ((theme (find-theme answer)))
                (cond ((null theme)
                       (message doc "No theme named ~A" answer)
                       (doc-beep doc))
                      (t
                       (load-theme theme :save save)
                       (message doc "Theme: ~A~A" (theme-label theme)
                                (if save "" " (this session)"))))))
            :completer #'theme-completer)))

;;; ------------------------------------------------------------------
;;; The minimap: the View menu's other item, kept the theme's way
;;; ------------------------------------------------------------------

;;; The minimap is the whole text in miniature beside the text area, the
;;; part on screen marked -- what the host's page draws (page-app.js);
;;; the MUI editor has none and never lists the menu item.  The SETTING
;;; lives here, with the theme, because it is kept the same way: one
;;; flag, *MINIMAP*, with three entrances -- View > Minimap (menu.lisp's
;;; :MINIMAP group), `M-x clamacs-toggle-minimap' and the init file's
;;; `(show-minimap nil)' -- all ending in SHOW-MINIMAP, which tells the
;;; frontend (EDITOR-APPLY-MINIMAP) and writes the form into the init
;;; file as LOAD-THEME writes its own.  Shown by default: the form is
;;; written on the first change.

(defvar *minimap* t
  "Whether the minimap is shown, where the frontend has one.")

(defparameter *minimap-persist-comment*
  ";; Written by M-x clamacs-toggle-minimap and the View menu")

(defun minimap-form-text (flag)
  (format nil "(show-minimap ~A)" (if flag "t" "nil")))

(defun minimap-persist (flag &optional (path *init-file*))
  "The choice FLAG into the init file PATH: `(show-minimap T-or-NIL)' as
its form, the theme's way (INIT-FORM-PERSIST)."
  (init-form-persist "show-minimap" (minimap-form-text flag) *minimap-persist-comment* path))

(defun show-minimap (flag &key (save t))
  "Show the minimap when FLAG, hide it otherwise: *MINIMAP*, the frontend
told, and -- unless SAVE is NIL, or the init file is loading its own form
-- the choice written into the init file.  Answers the flag in effect.
Callable from any thread, as LOAD-THEME is."
  (let ((flag (and flag t)))
    (setq *minimap* flag)
    (let ((editor *editor*))
      (when editor
        (theme-on-editor-task (lambda () (editor-apply-minimap editor flag)))))
    (when (and save *theme-persist*)
      (unless (minimap-persist flag)
        (theme-note "Cannot write ~A; the minimap setting holds for this session" *init-file*)))
    flag))

(define-command clamacs-toggle-minimap (doc arg)
  "Show the minimap -- the whole buffer in miniature beside the text,
the part on screen marked -- or hide it.  With `C-u' the change holds
for this session only and the init file is left alone.  The MUI editor
has no minimap; there the command only records the choice."
  (let* ((save (eql arg 1))
         (flag (show-minimap (not *minimap*) :save save)))
    (message doc "Minimap ~A~A" (if flag "on" "off") (if save "" " (this session)"))))
