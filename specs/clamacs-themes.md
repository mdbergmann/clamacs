# Clamacs colour themes

The Lisp editor colours its text by token kind (`lisp/token.lisp`,
`colour-one-line` in `lisp/commands.lisp`) and leaves every colour to the
frontend: the host page has two fixed palettes, light and dark, picked by
the system (`host/page-head.html`), and the MUI frontend a fixed table of
eight pens (`*pen-rgb*` in `lisp/frontend-mui.lisp`).  This spec makes
the palette a *theme*: a named set of colours the editor knows, defined
in Lisp, shipped with a few built-ins, picked from a View menu or by
`M-x clamacs-theme`, and remembered in the init file.  Decided
2026-09-26.  The host frontend comes first (phase T1, T2), the MUI
frontend after (T3), the two independent once the pure part (T1) is in.

Two rules shape everything below.  A theme is **data the frontends
read**, never code a frontend runs: the same `define-theme` form must
mean the same on the host and on the Amiga, and a frontend honours what
it can of it and says nothing about the rest.  And a theme has **one
implementation with three entrances**: the menu, `M-x clamacs-theme`
and the init file's form all end in `load-theme`, the way the menu
strip runs the command table and never a second copy of it.

## What a theme is

A theme is a struct made by `define-theme` in a new pure module,
`lisp/theme.lisp`: a keyword name, a label for the menu, whether it is
dark (`:dark t` -- see the Amiga's shallow-screen rule below), and the
colours as `#rrggbb` strings under fixed keys.  The keys are the page's
CSS variables of today, spelled as keywords:

| Group | Keys |
|---|---|
| text | `:bg :fg :dim :cursor :selection :active-line` |
| gutter | `:gutter-bg :gutter-fg` |
| chrome | `:bar :bar-fg :tab-active :line :status-bg :status-fg :echo-bg :echo-fg` |
| tokens | `:comment :string :number :keyword :defining :symbol :paren-match :paren-bad` |
| font | `:font-family :font-size` (the editor's monospace font; the chrome keeps the system font) |

A key a theme leaves out is taken from the theme it `:inherits` (a
built-in, by name), so a user theme is a few lines: `(define-theme
:my-dark (:inherits :dark :label "Mine") :keyword "#ff9900")`.  A
built-in is a `define-theme` form too, in `theme.lisp`, nothing is
special about it.  The built-ins at T1: `:light` and `:dark` (the page's
two palettes today, byte for byte, so the default look does not change),
`:solarized-light`, `:solarized-dark`, `:one-dark`, `:gruvbox-dark`.
The registry is an ordered list, so the menu shows the built-ins in the
order defined and user themes after them.

`*theme*` is the active theme; `load-theme` (a function; `NAME`, or a
theme) sets it, tells the frontend through a new generic
`editor-apply-theme`, and, unless asked not to, writes the choice to
the init file.  A name not defined (a misspelling in the init file, a
theme the image knows but the user's file no longer defines) falls back
to the default with a `message`, never an error: the editor must come
up.  The default is the theme the page would show anyway -- `:light` or
`:dark` after the system's setting, which the page reports at
`clamacsReady` -- so an editor without an init file looks exactly as
before.

`theme-css-vars` answers the theme as an alist of CSS variable name and
value, every key resolved through the inherit chain; `theme-pens`
answers the eight RGB triples in the MUI colour map's order.  Both are
pure and both are what the frontends read.

## Three entrances

- **`M-x clamacs-theme`** prompts with completion over the registry
  (`prompt` with a completer, as `clamacs-describe-symbol` does) and
  calls `load-theme`.  A `C-u` prefix applies the theme for the session
  only, without writing the init file.
- **The View menu**, a new title between Windows and Buffers in
  `*menu-table*`, holds one item per theme with the active one ticked
  -- the same dynamic group the Buffers menu is.  See "The menu" below.
- **The init file** carries `(load-theme :name)` as a top-level form,
  and `define-theme` forms above it for the user's own.  The file loads
  before the first window, so the theme is in effect before anything
  is drawn and user themes are in the menu at start.  A theme defined
  later, from the REPL, is in the menu after the next sync, which
  `after-command` runs anyway.

## Remembering the choice: the init file

A pick persists (decided 2026-09-26: not a settings file of its own,
not the window layout file; one file for the user to look at).  The
editor never rewrites the user's file, only the one form:

- `theme-persist` reads `*init-file*` as text, finds the top-level
  `(load-theme ...)` form with the sexp scanner (`sexp-forward` over
  the buffer from the top; a form is top-level when it starts at
  column 0 outside a string or comment, which `sexp-context` answers),
  and replaces exactly its text with the new form.  Every other byte,
  comments included, stays.  A second `load-theme` form is left alone;
  the first wins, as it does when the file loads.
- No such form: the form is appended after a blank line and one
  comment line (`;; Written by M-x clamacs-theme and the View menu`).
  No file: it is created with that.
- The file is the user's, unlike the layout file, so the write never
  leaves it half-written (`theme-write-file`): the new text goes to
  `<file>.tmp` (`snapshot-write-file`: directory made), is read back and
  compared, and is renamed over the file.  A symlink -- a dotfile
  manager's -- is followed to its target, so the link stays a link.  On
  the Amiga, where a rename deletes its target first, the old file steps
  aside as `<file>.bak` for the moment and comes back if the swap fails.
  A failure -- a read-only file, a missing `S:` -- leaves the file as it
  was, is a `message` in the echo area, and the theme still applies for
  the session.
- The paths are the ones `refresh-user-paths` settles at run time:
  `~/.clamacsrc` on the host, `S:.clamacsrc` on the Amiga.  So the
  write lands where the load reads, on an image started under another
  HOME too.

The rewrite is pure string work (`theme-persist-text`: old text and a
name in, new text out) and gets host tests on fixtures: the form in the
middle of a file, at the end, without a trailing newline, with comments
around and inside it, twice, absent, and an empty file.

## The host frontend

The page keeps every colour in CSS variables on `:root`; a theme is
those variables set on the document element, which every rule reads
already (`.ck-<kind>`, `.cm-content`, `.cm-gutters`, the bars).  So:

- **One new call**, `CK.theme(vars)`: `vars` an object of variable name
  to value; the page does `documentElement.style.setProperty` for each
  and sets `data-theme` to `dark` or `light` from the theme's flag so
  `color-scheme` follows (the scrollbars, the native form controls).
  The page's own `@media (prefers-color-scheme: dark)` block stays as
  the fallback before the first `CK.theme` and for a page without
  Lisp (the smoke).  The font keys set `--font-family` and
  `--font-size`, two new variables the three monospace rules read.
- `editor-apply-theme` on `host-editor` batches that call; it is also
  sent at `clamacsReady`, after the menus, so a page reload or a second
  editor comes up themed.
- `clamacsReady` gains the system's scheme (`dark` or `light`, from
  `matchMedia`) as a second argument, which is what decides the default
  theme when the init file names none.
- The page's report (`clamacsPanels`) carries `theme`: the value of
  `--bg` and `--keyword` as `getComputedStyle` sees them and the
  `data-theme` attribute, so the drive proves the page painted what
  Lisp said, beside `host-panel-state :theme`, the editor's account.
- The macOS native menu bar gets the View menu through the shim the
  way it gets Buffers: `clamacs_host_menu_set` takes the table with the
  new dynamic entry, and one new entry point, `clamacs_host_menu_dynamic
  (which, lines)`, replaces `clamacs_host_menu_buffers` -- the same
  `lines` spelling (`> ` ticked, `  ` not, `-` a bar), a second
  argument naming the group.  GTK and Win32 keep the page's bar, which
  draws the group from `CK.setDynamic(which, json)`, the renamed
  `setBuffers`.

Nothing in the shim knows what a theme is; it sees a second list of
lines.

## The menu

The `:buffers` entry kind becomes a `:dynamic` kind with a name
(`:buffers`, `:themes`) and two functions read off a table in
`menu.lisp`: the lines (`buffer-menu` / `theme-menu`: a list of
`(LABEL . OBJECT)` and `:bar`, with the ticked one marked) and the pick
(`buffer-menu-pick` / `load-theme`).  Everything that handles the
Buffers menu today -- `buffers-menu-sync` on both frontends,
`rebuild-buffer-items` on MUI, `setBuffers` on the page, the
`clamacsBuffers` binding, `editor-buffer-menu-lines` /
`editor-buffer-menu-pick`, the `BUFFERS` verb -- is generalised over
the name rather than copied: `dynamic-menu-sync editor :themes`,
`clamacsDynamic(which, n)`, `editor-dynamic-menu-lines editor :themes`.
A `THEMES [label]` port verb is the twin of `BUFFERS`: without an
argument the lines, with one a pick, answering `""` or `no such theme`.
`test_menudef.c` / `test-menu.lisp` get the View title and check that
the dynamic group's pick runs `load-theme` on the named theme and that
the tick follows `*theme*`.

The tick is exclusive by construction: the lines mark the theme that is
`*theme*`, and a sync after every command notices when it changed,
whether from the menu, `M-x` or a form evaluated in the REPL.

## The MUI frontend (phase T3, its own commit)

TextEditor.mcc (read in `vendor/texteditor/mcc/InitConfig.c`,
`PrintLineWithStyles.c`) lets a program set these, and no more:

- **The token colours**: the colour map is ours -- eight pens obtained
  with `ObtainBestPen` on the screen's colour map at Setup, released at
  Cleanup, indexed by `SetBlock`.  `*pen-rgb*` goes away; Setup reads
  `theme-pens`.  Slot 1 (black today, unused) becomes the theme's text
  colour, slot 2 (white, unused) stays free.
- **The text colour**: the class has no attribute for it (it is the
  user's MUI setting for the class, `MUICFG_TextEditor_TextColor`), but
  every recolour clears the line with pen 0 before painting tokens.
  Clearing with the text pen instead paints the whole line in the
  theme's foreground at the same cost.  `colour-value` answers 1 for
  `NIL` under a theme that sets `:fg`.
- **The background**: a `MUIA_Background` given to the object is kept
  by the class (`FLG_OwnBackground`; without it the class sets its
  configured background over ours at every Setup), and it takes an RGB
  pen spec, `2:rrrrrrrr,gggggggg,bbbbbbbb`.  The class accepts it on a
  set too, so a switch is live.
- **A switch**: the docs say a changed colour map does not repaint what
  is on screen.  `editor-apply-theme` on `mui-editor` releases the
  pens, obtains the theme's, sets the background, and runs `colour-all`
  on every document -- the function exists for the file-load case.

What it does not honour, on purpose: the cursor, selection and
highlight colours (the class's settings, no attribute), and the chrome
-- window, status line, minibuffer, the panels -- which follows the
user's MUI prefs as every MUI application does.  And the **shallow
screen rule**: on a Workbench with 16 colours or fewer the pens come
back as nearest matches and a dark background makes the text
unreadable, so when the screen's depth (`struct BitMap.Depth` off the
screen's RastPort, read once at Setup) is 4 or less a theme flagged
`:dark` applies its token colours only and leaves the text and
background pens alone; a `message` says so once.  The check is a
function of the depth and the theme so the fake frontend tests it.

`run-lisp-editor.sh` is the gate, on the 040 config and on the 020 one
(a 16-colour Workbench, the fallback), with a screenshot each; the
ARexx drive gets a `THEMES` leg beside `BUFFERS`.

## Files

```
lisp/theme.lisp            NEW  the struct, define-theme, the built-ins, the
                                registry, load-theme, theme-css-vars,
                                theme-pens, theme-persist-text, theme-persist,
                                clamacs-theme (pure)
lisp/menu.lisp             the View title; :buffers -> :dynamic with a name;
                           THEMES verb; editor-dynamic-menu-lines/-pick
lisp/frontend.lisp         editor-apply-theme (default: nothing)
lisp/frontend-host.lisp    CK.theme, the dynamic-menu sync, clamacsReady's
                           scheme, the report's theme field, host-panel-state
                           :theme
lisp/frontend-mui.lisp     T3: pens from the theme, the line clear with the
                           text pen, MUIA_Background, the switch, the depth rule
lisp/files.lisp            load-init-file unchanged; the fallback message when
                           the named theme is unknown comes from load-theme
lisp/load.lisp             theme.lisp after sexp.lisp, before menu.lisp
host/page-head.html        --font-family/--font-size; data-theme selectors
host/page-app.js           CK.theme, CK.setDynamic, clamacsDynamic, the
                           theme field of the report, the scheme at ready
host/clamacs-host.m        clamacs_host_menu_dynamic (three bodies)
tests/test-theme.lisp      NEW  inherit chains, unknown names, the css and pen
                                views, every persist fixture
tests/test-menu.lisp       the dynamic groups, the tick, the THEMES verb
tests/test-host.lisp       the batch holds CK.theme after load-theme and at
                           ready; the persisted file after a menu pick
tests/fake-frontend.lisp   editor-apply-theme records the theme; the depth rule
verify/host/drive.lisp     THEMES leg: list, pick, file read back, the page's
                           report, a second editor against the written file
verify/realamiga/drive.rexx  T3: the THEMES leg
README.md                  a "Themes" section: the View menu, M-x clamacs-theme,
                           define-theme in the init file, what the Amiga side
                           keeps from MUI prefs
```

## Phases -- one session each

### T1 -- the pure part

`theme.lisp` with the built-ins, `load-theme` (frontend-neutral through
the generic, the fake frontend recording it), `theme-persist-text` and
`theme-persist`, `clamacs-theme`, the `:dynamic` menu generalisation
with the View title and the `THEMES` verb.  `make test-lisp` and
`make test-lisp-gc-stress` green; the fake frontend's drive of the
menu group.  No frontend change yet, so the editor looks the same.

Done 2026-09-26.  What T1 settled beyond the text above:

- A theme's name is a keyword of letters, digits and hyphens, so the
  lowercase spelling the init file gets (`(load-theme :my-dark)`) reads
  back to the same keyword; `define-theme` refuses anything else, as it
  refuses a key that is not a theme's, a colour that is not `#rrggbb`
  and a parent that is not defined -- each an error naming the theme,
  which LOAD reports with the file's line.
- A key the inherit chain leaves unset (a theme with no `:inherits`
  and a few keys) resolves to the *default* theme's value, so the
  frontends always get a whole picture; `theme-value` answers what the
  chain sets, `theme-resolve` adds the fallback, and every built-in sets
  every key through its chain (a test).
- `load-theme` takes `:save nil` for the session-only pick; the init
  file's own form does not write itself back because `load-init-file`
  binds `*theme-persist*` to NIL around the load.  `theme-persist`
  leaves a file alone when its text would not change, and a file that
  is there but cannot be read is never written over.
- A theme redefined while it is in effect (from the REPL) is applied
  again at once; `forget-theme` takes one out of the registry.
- `load-theme` and `define-theme` may be called from a form at the self
  REPL, which runs on the REPL thread, not the editor's task: what
  touches a frontend -- the echo-area message, `editor-apply-theme` --
  goes through `call-in-editor-task` (looked up at run time:
  transport-self.lisp loads after theme.lisp), which runs the closure
  directly when the caller is the editor's task.
- `theme-pens` fills the free second slot with white and takes the
  paren-match slot's colour from `:paren-match`, which the page uses as
  a *background* tint; T3 decides whether the MUI pen should rather be a
  foreground colour (say `:keyword`'s) and may change the slot's key.
- The frontends name the dynamic groups they draw
  (`editor-dynamic-groups`): a title whose menu holds only a group the
  frontend does not draw is `hidden` on the wire to the page and the
  shim (its line kept, so the indices stay the table's; both skip a kind
  they do not know) and left out of the MUI strip.  Both frontends
  answer `(:buffers)` until T2 and T3 flip them.  The README's Themes
  section waits for T2, when a pick shows.

### T2 -- the host frontend

`CK.theme`, the font variables, `data-theme`, the scheme at ready, the
dynamic menu on the page and in the native bar, the report field.
`verify/host/run-smoke.sh`, `host-keys.sh` and `run-drive.sh` green,
the drive's new leg included, and `IMAGE=1` / `APP=1` runs of it (the
image holds the built-ins; the init file's themes load after the
restore, as `define-command` forms do).  `make host-linux` for the
GTK bar.

### T3 -- the MUI frontend (when asked)

As above.  `run-lisp-editor.sh 040` and `020`, `run-lisp-drive.sh`
with the new leg, a MorphOS run on the box.

## Risks and what decides them

- **A pick that edits the init file surprises a user who keeps that
  file under version control.**  Mitigated by touching one form only,
  and by `C-u M-x clamacs-theme` for a session-only pick.  If it still
  grates, the fallback is a separate `~/.clamacs-theme` file loaded
  after the init file -- one function to change, the rest stands.
- **`sexp-forward` over an init file with a reader macro it does not
  know** (`#.`, `#+` blocks) could misplace the form's end.  The
  scanner handles `#|...|#` today and treats a `#+`/`#-` prefix as a
  token before the form, which is enough to find the `load-theme` form
  by its head: the fixtures cover a `#+amigaos` guarded form next to it,
  and a form the scanner cannot bound is left alone and the theme
  appended instead, never a partial replacement.
- **The CodeMirror palette is only the variables the page defines.**
  A theme cannot restyle what the page's CSS does not read from a
  variable (the selection match highlight is one).  Each such rule
  found gets a variable and a key; the table above is the list to
  extend, not a closed set.
- **Pens on a shallow Workbench** are decided by the depth rule and
  looked at on the 020 config; a real A1200 screen, when one is up,
  confirms it.
