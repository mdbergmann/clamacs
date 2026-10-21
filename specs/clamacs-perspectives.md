# Clamacs projects

A project is a folder: the user opens it, works in it, closes it, and
the editor remembers which folders it has had open.  Three verbs --
**Open Project**, **Switch Project**, **Close Project** -- and a
**Recent Projects** list; nothing else on the menu.  Decided 2026-10-20,
replacing the perspectives UI of 2026-10-14 (below, "What it replaced"),
which asked the user to learn two nouns (a *perspective* that may have a
*project directory*), to set that directory by hand, and to save and
restore a file nobody had told them about.

Underneath, a project IS a perspective -- `perspective.el`'s model, a
named set of buffers with their windows, of which one is in front,
brought to an editor where a buffer is a window (MUI) or a tab (the
host) -- and the code keeps that word for the mechanism
(`lisp/perspective.lisp`, the `perspective` struct, `doc-perspective`,
`editor-perspectives`).  The user sees *project* everywhere: the menu,
the commands (`clamacs-project-*`), the keys (`C-x p`, Emacs's
`project.el` prefix), the port's `PROJECTS` and `RECENT` verbs, the file
(`projects.cfg`), the messages.  Switching projects hides the windows
of the one left and shows the windows of the one entered, the Buffers
menu and `C-x o` see only the buffers of the project in front, a file
opened from a project belongs to it, `find-file` and the ASDF commands
start from the project's folder, and a switch tells amilisp the folder
(the `,cd` of a project).  There is one amilisp, one REPL, one
debugger, shown in every project (the "Not done" section says why not
one per project).

Three rules shape everything below, the same three the themes have.  A
project is **data the frontends read**: the pure layer decides which
documents are shown, and a frontend only hides or shows a window when
told (`doc-set-shown`).  There is **one implementation with three
entrances**: the Project menu, the `M-x clamacs-project-*` commands on
`C-x p` and the port's verbs all end in `perspective-switch` and its
siblings.  And **the editor must never be left without a window**: a
project entered empty gets an unnamed buffer, closing the last buffer of
the project in front brings another set with buffers in front, and
closing the last open project puts the editor back in its no-project
state with an unnamed buffer -- only when nothing at all has buffers
does the last window's close end the editor, as it always did.

## What a project is

A `perspective` struct in `lisp/perspective.lisp`:

| Slot | What |
|---|---|
| `name` | a string, unique among the editor's |
| `root` | the folder, a string ending in `/` or `:`; NIL for the scratch set only |
| `open` | whether the project is open (has, or may have, windows) or recent |
| `documents` | its source documents, oldest first |
| `active` | the document that had the keyboard when the project was left |
| `pending-files`, `pending-active` | a recent project's files, waiting to be opened |

The editor keeps `perspectives` (in the order made) and `perspective`
(the one in front); a document keeps `perspective`, the one it belongs
to.

**The scratch set.**  Buffers outside any project -- the unnamed buffer
a start opens, a file opened before any project was -- live in a
perspective called `scratch` (`*scratch-perspective-name*`), made when
the first source document needs one (`current-perspective`), never
recorded in the file, with no root.  The user never sees the word: the
status line and the REPL's title show nothing while it is in front, and
the Project menu lists it as `(no project)` (`perspective-label`) only
while it holds buffers, so an editor that never opens a project looks
exactly as it did before projects existed.

**A project** is a perspective with a root, **open** or **recent**.
Open projects are listed at the tail of the Project menu, the one in
front ticked, and are what `Next Project` / `Previous Project` cycle --
together with the scratch set while it has buffers (`project-cycle`).
Recent projects are the **Recent Projects** submenu: known, no windows,
their files waiting (`pending-files`); a pick opens one.  A project
listed from the file at a start is recent; the first switch into it
opens its files and makes it open; `Close Project` closes its windows,
remembers its file list and makes it recent again.

**Who belongs.**  A *source* document -- a file window or an unnamed
buffer, `(not (tool-document-p doc))` -- joins the perspective in front
when it is made (`perspective-adopt`, from the document's
`initialize-instance`).  A *tool* buffer -- the REPL,
`*clamacs-description*`, `*clamacs-apropos*`, the error list and the
panels -- belongs to none and is shown in every project.  A tool buffer
that `C-x C-w` turns into a file joins the perspective in front then
(`visit-path`).  A document belongs to exactly one perspective (a window
cannot be in two places): a file already open in another project is
MOVED into the one in front by `find-file`, and the echo area says where
it came from.

**Shown.**  `doc-shown-p` is pure: a document is shown when it belongs
to no perspective or to the one in front.  `shown-documents` are the
live ones that are; `buffer-menu`, `other-window` / `switch-to-buffer`
(`next-document`) and every frontend's fallback for the active document
read it instead of `live-documents`.  `live-documents` itself is
unchanged -- a quit still closes every window, hidden ones included.

**Switching** (`perspective-switch editor p`): the active document of
the perspective left is remembered on it; the new one is made current
and, when it is a project, open; its waiting files, if any, are opened
into it (`perspective-open-pending`); its documents are shown
(`doc-set-shown doc t`), the remembered one -- or the first -- activated,
and only then the old perspective's hidden, so the frontend never has a
moment without a shown active document; an empty one gets an unnamed
buffer.  amilisp is told the project's folder (`perspective-tell-root`:
one `EVAL` setting `*default-pathname-defaults*`, nothing waited for,
the reply dropped; an open REPL transcript gets a note).  The echo area
says `Project: NAME (ROOT)` with `, N file(s) opened[, M missing]` when
files were opened, or `No project` for the scratch set
(`perspective-switch-message`).  A switch into the project in front
opens its waiting files and otherwise does nothing.

**Closing a buffer** (`close-document`): a document leaves its
perspective when its window goes.  When that was the last document of
the one in front and another perspective has documents, the editor
switches to it (the previous one in the list, cyclically) -- the rule
that keeps a window on screen.  A question about unsaved changes in a
HIDDEN document (a quit, Close Project) is asked in front of it:
`close-document` switches to the document's perspective first.

**The project's folder.**  `doc-directory`, where a file prompt and the
requester start for a buffer without a file, falls back to the
perspective's root; `find-file`'s line is seeded with it in such a
buffer; `with-system-file` looks for the `.asd` from the root when the
buffer has no file.  Nothing else is project-aware: a root is a place
to start from.  A project's folder is its identity and is never changed:
there is no Set Directory; one opens another folder.

## The commands

| Command | Key | Menu | What |
|---|---|---|---|
| `clamacs-project-open` | `C-x p o` | Open Project... | a folder, or its `.asd`, at the prompt, seeded with the user's home directory (`project-home-directory`: `user-homedir-pathname` on the host; on an Amiga, which has none, the `HOME` variable when set, else `SYS:`), with path completion; TAB on a bare directory opens the folder requester there (`doc-ask-file` in `:directory` mode: ASL's `DrawersOnly`, the host's folder panel), RET on an empty line at the home directory; the project of that folder opened: made and entered when new, entered (its files opened) when recent, switched to when open.  The menu item is the same prompt -- the requester is one TAB away, never the first thing shown (decided 2026-10-21; the item opened the requester for a day).  `M-x clamacs-project-open-requester` opens the requester straight away, at the home directory |
| `clamacs-project-switch` | `C-x p p` | Switch Project... | a name with completion over the open projects, the recent ones and `(no project)`; a recent one is opened; an unknown name is refused |
| `clamacs-project-close` | `C-x p k` | Close Project | the project in front: the editor switches away (the previous in the cycle, else the scratch set, which gets an unnamed buffer), its buffers are closed (each unsaved one asking; a cancel keeps it open with what is left), its file list is remembered and it is recent again; refused outside a project |
| `clamacs-project-next` / `-previous` | `C-x p n` / `C-x p N` | Next / Previous Project | cycle the open projects, the scratch set among them while it has buffers; dimmed with fewer than two |
| `clamacs-project-move-buffer` | `C-x p a` | Move Buffer to Project... | the buffer into an open project (or `(no project)`), hidden here; refused for a tool buffer |
| `clamacs-project-rename` | -- | -- | `M-x` only: the project in front renamed; refused for the scratch set, for an empty or a taken name |
| `clamacs-project-save` / `-restore` | -- | -- | `M-x` only: the file written now / read into the running editor, every project's files opened at once (a restore makes its projects open) |

**Naming** (`project-name-from-directory`, `unique-project-name`): a
project is named after the one `.asd` in its folder -- `sento` for
`Work:sento/sento.asd`, what a Lisp programmer calls the project --
else after the folder (`src` for `Work:src/`, `Work` for `Work:`).  A
name another project has gets the folder above in parentheses, `src
(sento)`, then a number; `scratch` is always taken.  A folder that is a
project already (by root, case-insensitively) is that project, never a
second one.

## The menu and the port

The first menu is **File** since 2026-10-20 (it was `Project`, the
Amiga's name for it, which the new menu needed).  A **Project** title
between View and Buffers:

```
Project
  Open Project...             C-x p o   the prompt, as the key; TAB there browses
  Recent Projects          >            the :recent group, a submenu
  Close Project               C-x p k   enabled in a project (:in-project)
  --------------------------
  Switch Project...           C-x p p
  Next Project                C-x p n   enabled with two to cycle (:projects)
  Previous Project            C-x p N
  Move Buffer to Project...   C-x p a
  --------------------------
  (no project)                          the :projects group: the scratch set
  * sento                               while it has buffers, then the open
    cl-gserver                          projects, the one in front ticked
```

Both groups are dynamic groups like the Buffers menu
(`dynamic-menu` / `dynamic-menu-pick` on the name), every frontend lists
them in `editor-dynamic-groups`, and the page, the Cocoa shim and the
MUI strip draw them without knowing what a project is -- the titled one
as a submenu (the Themes mechanism), the titleless one at the tail.  The
port's `PROJECTS [name]` and `RECENT [name]` are the twins of `BUFFERS`:
the lines, or a pick answering `""` or `no such project`.

## The file

`ENVARC:Clamacs/projects.cfg` (and `ENV:`) on the Amiga,
`~/.clamacs-projects.cfg` on the host -- the layout file's sibling,
settled by `refresh-user-paths` the same way.  Plain text the user can
read and edit, one keyword and the rest of the line:

```
; clamacs projects -- project NAME, then its root and files
project sento
root Work:sento/
file Work:sento/src/actor.lisp
file Work:sento/src/queue.lisp
active Work:sento/src/queue.lisp
project tools
root Work:tools/
current sento
```

(`perspective NAME` is read as `project NAME`, for a file written before
the rename.)  Unnamed buffers are not recorded, nor is the scratch set;
a line that does not parse is skipped, never fatal.  `perspectives-text`
and `perspectives-parse` are pure string work with tests on fixtures.

**When it is written.**  The editor keeps it on its own
(`perspective-autosave`): after Open Project, Close Project and a
rename, and at every quit -- whenever there is a project to record or
the file exists already.  The first Open Project creates it; that is
the opt-in that also turns on the layout file's autosave at quit
(`snapshot-autosave` from `quit-requested`, right after
`perspective-autosave`), so a saved session comes back where it was left
-- a session is its buffers and its windows.  An editor that never
opens a project writes nothing.

**When it is read.**  At every start when the file is there -- and a
start LISTS, it does not restore (decided 2026-10-18): every project in
the file is made recent, by name with its root, its files and its
recorded document waiting on it (`perspective-list-at-start`, from both
frontends' `start` before the first window), and the editor opens the
window it always did -- the files named on the command line, else the
unnamed buffer -- in the scratch set.  Nothing is ticked, the status
line shows no project, the `current` line is not honoured.  The user
picks a project from Recent Projects (or `C-x p p`, or `RECENT name`),
and that first switch opens its files, the recorded one to the keyboard.
A project never entered keeps its files in the file across the quit.
`clamacs-project-restore` reads the file into a running editor eagerly:
every project made, open, its files opened at once, the recorded
project in front.

**The status line and the REPL's title** name the project in front --
` [sento]` after the buffer's name, `*clamacs-repl* [sento]` -- and
nothing outside a project (`status-perspective`; `repl-title` /
`repl-sync-title` in `repl.lisp`, called by `perspective.lisp` on every
change).  The REPL's NAME stays `*clamacs-repl*`.

## Not done: an amilisp per project

Designed on 2026-10-15 and set aside the same day.  One image for every
project does collide -- amilisp has one default directory and one set of
packages -- and an amilisp per project would fix it: the wire, the REPL
session, the debugger and the inspector moved onto the project,
`editor-wire` answering the one in front, a child started in the root,
the ARexx wire taught to tell its amilisp instances apart (an EXT.DEV
change in AmiLisp).  But that is SLIME's multiple connections, not a
project: Emacs users start a second `M-x slime` and pick the default
connection by hand, and most run one image with everything loaded.  A
68020 with 16 MB cannot hold two heaps anyway.  So a switch tells the one
amilisp the folder, and a second amilisp, if it is ever wanted, is a
`Connect` that remembers its port per project -- a feature of the wire.

## The frontends

One generic, `doc-set-shown (doc flag)`, default nothing: the fake
records it (`fake-shown`), so the pure tests check which windows a
switch would show.

**The host.**  A hidden tab is a tab the page does not draw:
`CK.showDoc(id, flag)` sets a flag on the page's document record,
`refreshTabs` leaves hidden ones out, the page never activates a hidden
document on its own, and the report's `tabs` lists the shown ones only
(`tabs.hidden`).  `editor-active-document`'s fallback and
`doc-close-window`'s choice of the next document read `shown-documents`;
`move-document` never activates a hidden document, so a detached window
whose tabs are all hidden stays up, empty, until they are shown again
(or is closed by the user, which attaches them hidden).
`host-panel-state :projects` is the editor's account (`current NAME of
(a|b) hidden (doc2)`), the `:menu` line carries `projects (...)` and
`recent (...)`, and the port's `OPEN` brings a file hidden in another
project over, as `find-file` does.  `drive.lisp` has the PROJECTS leg
and its second editor lists the file the first one's quit wrote.

**MUI.**  A hidden window is a CLOSED window (its object, text, undo and
colours kept, as the theme switch relies on).  `doc-set-shown` on an
`mui-document` only MARKS the document; `shown-sync`, from the loop's
housekeeping before `theme-repaint` and once in `start` after the
listing, never from a hook (`close-document` may switch perspectives
from inside a window's own event handling), closes and opens the
windows, giving a reopened window the geometry it had (kept on the
document; `doc-geometry` answers it, so the snapshot records a hidden
window where it was), recolouring one a theme change found closed
(`repaint-owed`) and activating the active document again.  The status
lines follow in `redisplay-documents` when the number of perspectives or
the name of the one in front changed.  `shown-report` reads the windows'
open state off MUI for a drive.  `drive.rexx` has the PROJECTS leg at
its end and its second editor lists a hand-written file; `PERSPECTIVE=1
verify/realamiga/run-lisp-editor.sh` is the hide/show cycle on a real
MUI.

## Files

```
lisp/perspective.lisp      the struct, the scratch set, open/recent, naming,
                           adoption, shown-p, switch, close, move, the file,
                           the commands, the two menu groups (pure)
lisp/frontend.lisp         the two editor slots; doc-set-shown; perspective-adopt
lisp/files.lisp            doc-directory's fallback; find-file moves; the
                           seeded prompt; close-document's two rules; the
                           quit's autosave
lisp/menu.lisp             File; the Project title, its items and groups; the
                           :projects / :in-project rules; the two verbs
lisp/bindings.lisp         the C-x p keys
lisp/wire.lisp             with-system-file from the root; the switch's EVAL
lisp/snapshot.lisp         refresh-user-paths; snapshot-autosave
lisp/repl.lisp             repl-title / repl-sync-title
lisp/frontend-host.lisp    the groups; doc-set-shown; host-panel-state :projects
lisp/frontend-mui.lisp     the groups; doc-set-shown; shown-sync; shown-report
tests/test-perspective.lisp
README.md                  the "Projects" section
```

## What it replaced (2026-10-14 to 2026-10-20)

The first UI was `perspective.el`'s, on `C-x x`: Switch Perspective
(a new name made an empty, folderless perspective), Open Project
Directory, Set Project Directory, Rename, Close, Move Buffer, Save
Perspectives and Restore Perspectives, the first perspective called
`main` and named in the status line once there were two.  Phases P1
(pure), P2 (host) and P3 (MUI) landed 2026-10-14/15 and the hide/show
machinery, the file format and the listing at start are theirs,
unchanged.  What went: the word on screen, `main`, the folderless
perspective, Set Directory, the two file commands and the opt-in by
saving once.

## Risks and what decides them

- **A hidden window on MUI is a closed window**: its object, text and
  undo stay (the theme switch relies on it already).  If a hidden window
  turned out to lose something, the fallback is `MUIA_Window_Open` kept
  and the window iconified instead.
- **A start opens nothing of a project's** -- a restore at start grated
  (2026-10-18).  Recent Projects is one pick away.
- **Moving a file's window between projects** (rather than sharing the
  buffer) may surprise a `perspective.el` user.  A window cannot be in
  two projects; the move is said in the echo area, and Move Buffer moves
  it back.
- **The switch's directory `EVAL` lands mid-session**: a REPL in the
  middle of work sees its default directory change under it.  Accepted
  (2026-10-15): the folder following the project is the point; the REPL
  transcript gets a note.
- **An empty Recent Projects submenu** is a submenu with nothing in it
  until the first project is closed or listed.  Harmless on all three
  menu bars.
