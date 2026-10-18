# Clamacs perspectives

A perspective is a named set of buffers with their windows -- a project
-- of which one is in front: Emacs's `perspective.el` (`persp-switch`,
`C-x x`), brought to an editor where a buffer IS a window (MUI) or a
tab (the host).  Switching perspectives hides the windows of the one
left and shows the windows of the one entered, the Buffers menu and
`C-x o` see only the buffers of the perspective in front, a file opened
from a perspective belongs to it, and a perspective may have a project
directory that `find-file` and the ASDF commands start from.  The set of
perspectives, each with its directory and its files, is written to a
small text file and comes back at the next start.  Decided 2026-10-14.
The pure part comes first (phase P1), the host frontend second (P2), the
MUI frontend third (P3), the two frontends independent once P1 is in.

This is `perspective.el`'s model and no more: buffer bookkeeping and
what is on screen.  `perspective.el` knows nothing of SLIME -- the REPL
buffer is a buffer like any other, shown in whichever perspective asks
for it -- and a Lisp per project is SLIME's *multiple connections*, a
separate feature the user drives by hand.  Clamacs does the same
(decided 2026-10-15, after a day spent designing an amilisp per
perspective and finding it was that other feature): there is one
amilisp, one REPL, one debugger, shown in every perspective, and a
switch tells it the new perspective's directory -- the `,cd` of a
perspective.  A second amilisp per project, when wanted, is a `Connect`
that remembers its port per perspective, and is not part of this.

Three rules shape everything below, the same three the themes have.  A
perspective is **data the frontends read**: the pure layer decides which
documents are shown, and a frontend only hides or shows a window when
told (`doc-set-shown`).  There is **one implementation with three
entrances**: the Perspectives menu, the `M-x clamacs-perspective-*`
commands on `C-x x` and the port's `PERSPECTIVES` verb all end in
`perspective-switch` and its siblings.  And **the editor must never be
left without a window**: a perspective entered empty gets an unnamed
buffer, and closing the last buffer of a perspective brings another
perspective in front when one has buffers -- only when none has does
the last window's close end the editor, as it always did.

## What a perspective is

A struct in a new pure module, `lisp/perspective.lisp`:

| Slot | What |
|---|---|
| `name` | a string, unique among the editor's; the first is `main` |
| `root` | the project directory, a string ending in `/` or `:`, or NIL |
| `documents` | its source documents, oldest first |
| `active` | the document that had the keyboard when the perspective was left |

The editor keeps `perspectives` (in the order made) and `perspective`
(the one in front); a document keeps `perspective`, the one it belongs
to.  The main perspective is made when the first document needs one, so
an editor that never hears of perspectives has one, called `main`, and
behaves exactly as before.

**Who belongs.**  A *source* document -- a file window or an unnamed
buffer, `(not (tool-document-p doc))` -- joins the perspective in front
when it is made (`perspective-adopt`, from the document's
`initialize-instance`, as the window's role is chosen there).  A *tool*
buffer -- the REPL, `*clamacs-description*`, `*clamacs-apropos*`, the
error list and the panels -- belongs to no perspective and is shown in
every one: there is one amilisp, one REPL thread, one debugger, and
every tool buffer shows what that amilisp answered.  A tool buffer that
`C-x C-w` turns into a file joins the perspective in front then
(`visit-path`).  A document belongs to exactly one perspective
(a window cannot be in two places), which is where this differs from
`perspective.el`'s shared buffers: a file already open in another
perspective is MOVED into the one in front by `find-file`, and the echo
area says where it came from.

**Shown.**  `doc-shown-p` is pure: a document is shown when it belongs
to no perspective or to the one in front.  `shown-documents` are the
live ones that are; `buffer-menu`, `other-window` / `switch-to-buffer`
(`next-document`) and every frontend's fallback for the active document
read it instead of `live-documents`.  `live-documents` itself is
unchanged -- a quit still closes every window, hidden ones included.

**Switching** (`perspective-switch editor p`): the active document of
the perspective left is remembered on it; the new one is made current;
its documents are shown (`doc-set-shown doc t`), the remembered one --
or the first -- activated, and only then the old perspective's hidden,
so the frontend never has a moment without a shown active document; an
empty perspective gets an unnamed buffer (`open-document editor nil`),
which joins it because it is current by then.  The echo area says
`Perspective: NAME`.

**Closing** (`close-document`): a document leaves its perspective when
its window goes.  When that was the last document of the perspective
in front and another perspective has documents, the editor switches to
it (the previous one in the list, cyclically) -- the one rule that
keeps a window on screen.  When no other has any, nothing happens and
the frontend's loop sees the last window go, as before.  A question
about unsaved changes in a HIDDEN document (a quit, Close Perspective)
is asked in front of it: `close-document` switches to the document's
perspective first.

**The project directory.**  `doc-directory`, where a file prompt and
the requester start for a buffer without a file, falls back to the
perspective's root; `find-file`'s line is seeded with it in such a
buffer (a file-backed buffer's prompt stays empty, so a drive that
types a full path there is unaffected); and `with-system-file` looks
for the `.asd` from the root when the buffer has no file.  And a switch
to a perspective that has a root tells amilisp, when the wire is
connected, to make it the default directory (`perspective-tell-root`:
one `EVAL` setting `*default-pathname-defaults*`, nothing waited for,
the reply dropped), so a relative path typed at the REPL means the
project's -- Emacs's `default-directory` is buffer-local and SLIME's
`,cd` does this by hand; here the perspective does it.  A perspective
without a root leaves the directory as it is.  Nothing else is
project-aware: a root is a place to start from.

## Not done: an amilisp per perspective

Designed on 2026-10-15 and set aside the same day.  One image for
every project does collide -- amilisp has one default directory and
one set of packages -- and an amilisp per perspective would fix it: the
wire, the REPL session, the debugger and the inspector moved onto the
perspective, `editor-wire` answering the one in front, a child started
in the root, the ARexx wire taught to tell its amilisp instances apart (the
inbound verbs arrive at the editor's one MUI port unnamed, so
`REPL-ATTACH` would need a tag, an EXT.DEV change in AmiLisp).  But
that is SLIME's multiple connections, not a perspective: Emacs users
start a second `M-x slime` and pick the default connection by hand,
and most run one image with everything loaded.  A 68020 with 16 MB
cannot hold two heaps anyway.  So the perspectives stay buffer
bookkeeping with the directory `EVAL` above, and a second amilisp, if
it is ever wanted, is a `Connect` that remembers its port per
perspective -- a feature of the wire, designed then.

## Commands and keys

`perspective.el`'s prefix, `C-x x`, with its letters where it has them:

| Command | Key | What |
|---|---|---|
| `clamacs-perspective-switch` | `C-x x s` | prompt with completion; a new name makes a perspective and enters it |
| `clamacs-perspective-next` / `-previous` | `C-x x n` / `C-x x p` | cycle in the order made |
| `clamacs-perspective-rename` | `C-x x r` | prompt, seeded with the name; refuses empty and taken names |
| `clamacs-perspective-close` | `C-x x c` | switch away first, then close its buffers (asking), then forget it; refused for the only one |
| `clamacs-perspective-move-buffer` | `C-x x a` | the buffer into a named perspective (made if new), hidden here |
| `clamacs-perspective-set-directory` | `C-x x d` | the project directory, with path completion; must exist |
| `clamacs-perspective-open-project` | `C-x x o` | a directory: a perspective named after it, its root set, entered |
| `clamacs-perspective-save` | `C-x x C-s` | the file written |
| `clamacs-perspective-restore` | `C-x x C-l` | the file read into the running editor |

A prompt's completer is `complete` over the names; the directory
prompts use `complete-path`, so TAB descends.  The commands are
written against the frontend protocol and run on the fake frontend.

## The menu and the port

A **Perspectives** title between View and Buffers: the commands above
as items (Close Perspective under a new rule, `:perspectives`, enabled
while there are two or more), then a titleless dynamic group
`:perspectives` at the tail -- one item per perspective, the one in
front ticked, a pick switching -- made by the same mechanism as the
Buffers menu: `dynamic-menu` / `dynamic-menu-pick` on the name, every
frontend listing it in `editor-dynamic-groups`, so the page, the Cocoa
shim and the MUI strip each draw it without knowing what a perspective
is.  The port's `PERSPECTIVES [name]` is the twin of `BUFFERS`: the
lines, or a pick answering `""` or `no such perspective`.

## The file

`ENVARC:Clamacs/perspectives.cfg` (and `ENV:`) on the Amiga,
`~/.clamacs-perspectives.cfg` on the host -- the layout file's
sibling, settled by `refresh-user-paths` the same way.  Plain text the
user can read and edit, one keyword and the rest of the line:

```
; clamacs perspectives -- perspective NAME, then its root and files
perspective main
root Work:src/
file Work:src/a.lisp
file Work:src/b.lisp
active Work:src/b.lisp
perspective scratch
current main
```

Unnamed buffers are not recorded; a line that does not parse is
skipped, never fatal.  `perspectives-text` and `perspectives-parse`
are pure string work with tests on fixtures.

**When it is written.**  By `clamacs-perspective-save`, and at every
quit once the file exists -- saving once opts in, and from then on the
editor keeps the file in step without being asked.  The write goes to
every path of `*perspective-files*` through `snapshot-write-file`.
**The layout file goes with it** (decided 2026-10-15): a quit that
writes the perspectives file also records every window's place in the
layout file (`snapshot-autosave`, the command's path without the
message, from `quit-requested` right after `perspective-autosave`), so
a saved session comes back where it was left -- a session is its
buffers and its windows.  The perspectives file's existence is the one
opt-in; a layout file without a perspectives file stays as it is,
written on command only (the first design had it that way for both,
and the first restart on the host came up with the right perspective in
a window of the default size).

**When it is read.**  By `clamacs-perspective-restore`, and at every
start when the file is there -- but a start LISTS, it does not restore
(decided 2026-10-18; until then a start without files restored the
file, the recorded perspective in front, and the windows came up
unasked).  `perspective-list-at-start`, from both frontends' `start`
before the first window, makes each perspective of the file by name
with its root and keeps its files and its recorded document WAITING on
it (`pending-files`, `pending-active`); the editor then opens the
window it always did -- the files named on the command line, else the
unnamed buffer -- which joins the first perspective listed, and the
file's `current` line is not honoured.  The user picks the perspective
to reopen: the first `perspective-switch` into a waiting perspective
opens its files (`perspective-open-pending`, with the perspective in
front so they join it; a file open elsewhere is brought over), makes
the recorded document its active one and says `Perspective: NAME, N
file(s) opened[, M missing]` -- also when it is the one in front
already, which a switch otherwise leaves alone (`C-x x s` refuses the
name in front only once nothing waits).  Until then the quit's write
keeps the waiting files, so a session that never entered a perspective
loses none of it.  A restore (`C-x x C-l`) makes each perspective
that is missing, sets its root, opens its files into it at once (a file
already open elsewhere is moved, one that cannot be read is skipped and
counted; nothing waits on it afterwards), makes the recorded document
active, then brings the recorded perspective -- or the first -- in
front with `perspective-switch` after syncing every document's shown
state, so a frontend that showed the restored windows as they opened
hides the ones not in front.  A restore that opened nothing leaves the
editor as it was.

**The REPL's title** (2026-10-18) names the perspective in front once
there are two -- `*clamacs-repl* [work]`, the status line's rule
(`status-perspective`) -- since the one REPL is shown in every
perspective and its default directory follows the one in front; its
NAME stays `*clamacs-repl*` (the Buffers menu, the window's role).
`repl-title` / `repl-sync-title` in `repl.lisp`, called by
`perspective.lisp` when a perspective is made, closed, renamed or
brought in front, and by `repl-open`.  The host's `update-status` sets
the window's title to the document's last `doc-set-title`, not its
name, for that.

## The frontends

One new generic, `doc-set-shown (doc flag)`, default nothing: the fake
records it (`fake-shown`), so the pure tests check which windows a
switch would show.

**The host (phase P2).**  A hidden tab is a tab the page does not draw:
`CK.showDoc(id, flag)` sets a flag on the page's document record,
`refreshTabs` leaves hidden ones out, the page never activates a hidden
document on its own, and the report's `tabs` lists the shown ones
only.  `editor-active-document`'s fallback and `doc-close-window`'s
choice of the next document read `shown-documents`; a detached window
whose tabs are all hidden stays up, empty, until they are shown again
(or is closed by the user, which attaches them hidden).  The
`host-panel-state :menu` line and `host-page-panels` grow a
`perspectives` entry, and `drive.lisp` a PERSPECTIVES leg: the verb
pick, the native pick, a switch with the page's tabs read back, the
file written and read back by a second editor.  The status line shows
the perspective's name when there is more than one.

**MUI (phase P3).**  `doc-set-shown` on an `mui-document` sets
`MUIA_Window_Open`; on hide the window's geometry is read first
(`window-geometry`) and set on the closed window before it is opened
again (the theme-repaint rule: MUI 4 reopens a window at its creation
size otherwise).  Since `close-document` may switch perspectives from
inside a window's own event handling (the last window of a perspective
closed with `C-x k`), the MUI method only MARKS the document and the
windows are opened and closed from the loop's housekeeping, as
`theme-repaint` is -- never from a hook.  `active-document`'s fallbacks
read `shown-documents`.  `drive.rexx` gets the PERSPECTIVES leg;
`run-lisp-editor.sh` is the gate for the hide/show.

## Files

```
lisp/perspective.lisp      NEW  the struct, adoption, shown-p, switch, close
                                bookkeeping, the commands, the menu group,
                                the file (pure)
lisp/frontend.lisp         the two slots; doc-set-shown; perspective-adopt
                           from initialize-instance
lisp/files.lisp            doc-directory's fallback; find-file moves; the
                           seeded prompt; close-document's two rules; the
                           quit's save
lisp/menu.lisp             the Perspectives title and group; the rule;
                           editor-dynamic-groups; the PERSPECTIVES verb
lisp/bindings.lisp         the C-x x keys
lisp/wire.lisp             with-system-file from the root; the switch's
                           directory EVAL (perspective-tell-root)
lisp/snapshot.lisp         refresh-user-paths settles *perspective-files*;
                           snapshot-autosave, the quit's layout write
lisp/load.lisp             perspective.lisp after menu.lisp
lisp/frontend-host.lisp    P1: :perspectives in editor-dynamic-groups, the
                           restore at start; P2: doc-set-shown, the page
lisp/frontend-mui.lisp     P1: the same two; P3: doc-set-shown
tests/test-perspective.lisp NEW
tests/fake-frontend.lisp   fake-shown; the active document's fallback
tests/test-menu.lisp       the title, the group, the rule
tests/test-host.lisp       the table's new lines
README.md                  a "Perspectives" section
```

## Phases -- one session each

### P1 -- the pure part

Everything above but the frontends' hide and show: `make test-lisp`
green with `tests/test-perspective.lisp`, the menu on both frontends
(the group draws itself), the keys, the file, the restore at start.
Switching perspectives on a real frontend changes the Buffers menu, the
`C-x o` cycle and the tick, and shows every window still -- the T1
situation, where the editor looked the same until T2.

### P2 -- the host frontend

As above.  `run-smoke.sh`, `host-keys.sh`, `run-drive.sh` with the new
leg, `MEMTRACK=1`, `make host-linux`.  Landed 2026-10-15: `CK.showDoc`
and the page's `hidden` list, `doc-set-shown` on `host-document` (a
change only; a document made in another window from the mirror is
hidden there again), the fallbacks on `shown-documents`, the status
line's `[name]`, `host-panel-state :perspectives`, the port's `OPEN`
bringing a hidden file over as `find-file` does, the drive's leg and the
second editor's restore.  One rule found on the way: a hidden document
is never brought to the keyboard by the frontend -- `move-document`
skips its activation, and the page's own fallbacks skip hidden tabs --
so the pure layer's "show, activate, then hide" order is the only thing
that decides what has the keyboard.  And one P1 gap the second editor
found: a restore whose recorded perspective is the one in front already
left the last file opened active, since a switch to the current
perspective does nothing -- `perspective-restore` activates the recorded
document by hand then.  Gates: `run-smoke.sh`, `host-keys.sh`,
`MEMTRACK=1 run-drive.sh` (329 OK, both editors and the started amilisp
leak-free) green on macOS; `make host-linux` not run (no docker daemon,
and the standalone checkout has no superproject beside it).

### P3 -- the MUI frontend

As above.  `run-lisp-editor.sh 040`, `run-lisp-drive.sh` with the leg,
a MorphOS run.  Landed 2026-10-15: `doc-set-shown` on an `mui-document`
marks the document and sets the editor's `shown-dirty`; `shown-sync`,
run by the loop's housekeeping before `theme-repaint` and once by
`start` after the restore, closes the windows to hide (their geometry
kept on the document, `doc-geometry` answering it so the snapshot
records a hidden window where it was) and opens the ones to show at
that place, recolours a window a theme change found closed
(`theme-repaint` applies the background and the font to the closed
object and leaves the colours owed, `repaint-owed`) and activates the
active document again
-- MUI opens a window with no active object, and `doc-activate` on a
closed window records the request only, since MUI ignores the two
attributes there.  The status lines follow in `redisplay-documents`:
every one on the screen is rewritten when the number of perspectives
or the name of the one in front changed since it last looked (` [name]`
after the buffer's name once there are two; `status-perspective` lives
in `perspective.lisp` now, both frontends' `status-text` call it) --
the first smoke run's screenshot showed a `[main]` left over from a
perspective closed since.  `active-document`'s fallbacks read
`shown-documents`.  `shown-report` reads the windows' open state back
off MUI for the drive, beside the pure layer's account.  `drive.rexx` has the leg at
the end (the prompt through `KEY`, the windows closed and opened, the
file brought over, the hidden window back at its `GETWINDOW` place, the
status line, the menu's pick, the directory told to amilisp read back
at the REPL prompt, the file saved and deleted) and its second editor
restores a hand-written file (the file it started on moved into a
perspective not in front and its window closed, the switch bringing it
back where the layout file put it); `PERSPECTIVE=1 run-lisp-editor.sh`
is the hide/show cycle on a real MUI before the typing, with the exit
checked as ever.  Gates on 2026-10-15: `make test-lisp` (791),
`run-smoke.sh`, `host-keys.sh` and `run-drive.sh` (326 OK) on macOS for
the moved status helper, `run-lisp-drive.sh 040` (185 OK, PHASE 5, the
two legs included) and `PERSPECTIVE=1 run-lisp-editor.sh 040` green in
FS-UAE; `run-lisp-drive PHASE 5` on the real MorphOS box the same day
(189 OK, both perspective legs green, the hidden window back at its
place under MUI 4 too -- the one FAIL was the themes leg's assumption
that the editor starts in Light against that box's own init file,
which loads One Dark).

## Risks and what decides them

- **A perspective's window hidden on MUI is a closed window**: its
  object stays, its text stays, its undo stays (the class keeps them
  across close and open -- the theme switch relies on it already).  If
  a hidden window turned out to lose something, the fallback is
  `MUIA_Window_Open` kept and the window iconified instead.
- **The restore at start opens windows the user did not ask for.**
  It did grate (2026-10-18): a start lists the perspectives now and
  opens nothing of theirs, the first switch into one does ("When it is
  read" above).
- **Moving a file's window between perspectives** (rather than sharing
  the buffer) may surprise a `perspective.el` user who expects
  `persp-add-buffer`'s sharing.  A window cannot be in two
  perspectives; the move is said in the echo area, and
  `clamacs-perspective-move-buffer` moves it back.
- **The switch's directory `EVAL` lands mid-session**: a REPL in the
  middle of work sees its default directory change under it.  Accepted
  (2026-10-15): the folder following the perspective is the point; the
  REPL transcript gets a note saying so when it is open.
