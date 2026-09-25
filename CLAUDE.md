# Clamacs

Emacs-flavoured Common Lisp IDE for AmigaOS 3 (68020+) and MorphOS. Native C
MUI application; drives a running `clamiga` (the CL-Amiga runtime) over ARexx.
This repository is a **git submodule of cl-amiga**
(`https://github.com/mdbergmann/cl-amiga.git`, checked out at
`cl-amiga/clamacs`) and ships in cl-amiga's binary release beside the
`clamiga` binaries (`scripts/make-binary-release.sh` over there builds it).
The runtime the editor drives is the superproject -- one level up.  A
clamiga change needed for clamacs (an `EXT.DEV` command, a compiler or JIT
fix) is a commit *in cl-amiga* under its gates, then the superproject's
pin of this submodule is bumped when the editor side lands.  Work here
never gates on cl-amiga's suites, and cl-amiga's `make test` never runs
ours.  (The FS-UAE emulator assets -- the aos3 Workbench image and
FS-UAE.app -- are not tracked in git; they live in the superproject's
`verify/realamiga`, see Testing.)

The full design and phase plan is `specs/clamacs-ide.md`; this file is the
short version.  The **host frontend** (macOS/Linux/Windows: webview +
CodeMirror 6 over the same frontend protocol, the editor's own image as
the first Lisp, TCP to a separate clamiga second) is `specs/clamacs-host.md`
-- decisions, the page/Lisp interface, phases H0-H6, one session each;
`spike/host-webview/` is its proof of concept.  Phase H0 landed
2026-09-25: `lisp/json.lisp`, `lisp/textmirror.lisp` (the fake frontend's
text model, which `tests/fake-frontend.lisp` now runs on) and
`lisp/mailbox.lisp` (the MUI frontend's mailbox, shared) are pure modules
with tests; `host/` holds the native shim, the page and `build.sh`
(webview at a pinned commit, the CodeMirror bundle from a lockfile with
its sha256 checked, the page kept pure ASCII); `verify/host/run-smoke.sh`
is its gate.  Phase H1 (same day) is `lisp/frontend-host.lisp`, the
document window: a `host-document` over the mirror, the key decoder, the
batch (one `webview_eval` per entry into Lisp, colour runs coalesced per
line), the stepped loop, the requesters through the shim; `lisp/clamacs.lisp`
picks it on a non-Amiga host and `host/run.sh` starts it.
`tests/test-host.lisp` drives it with the page stubbed (the batch read
back), and `verify/host/host-keys.sh` types `lisp-editor-keys.lisp`
through the page's `simulateKey` and compares the saved file with the
fake frontend's -- the host twin of `run-lisp-editor.sh`.  Run both
scripts after touching `host/` or `frontend-host.lisp`.  Two rules the
host frontend keeps that the fake does not show: an edit is noticed by
the mirror's text IDENTITY (`note-text-if-changed`, what MUI's
ContentsChanged hook does), since a command's edit calls no hook; and a
page-initiated change (`clamacsUpdate`) is applied to the mirror as one
`mirror-replace` and never pushed back.  Phase H2 (same day) is
`lisp/transport-host.lisp`: the wire's home transport on the host is the
SELF transport (the editor's own image answers the REPL, the debugger,
the inspector, introspection and LOAD; `Talk to the Editor Itself` and
`Talk to clamiga` are the same transport until the TCP one of phase H5),
and the editor's own port is a TCP listener on 127.0.0.1 -- a
length-framed line protocol, `AUTH <token>` before anything else, the
token from `/dev/urandom` and the port number in 0600 files under
`$TMPDIR` (or `$XDG_RUNTIME_DIR`), every verb run on the editor's task
through the mailbox.  `tests/test-transport-host.lisp` drives it over a
real loopback socket (the refused connections included), and
`verify/host/run-drive.sh` is the acceptance run: `verify/host/drive.lisp`,
a client of its own, walks the legs of `drive.rexx` over the port (124
`OK` lines) and a second editor is started against the layout file it
wrote.  Run it after touching `transport-host.lisp`, `transport-self.lisp`,
`port.lisp`, `wire.lisp`, the REPL/debugger/inspector files or the event
loop.  Every panel generic of debugger.lisp and inspector.lisp has a
method on `host-editor`: a missing one aborted the REPL window's close at
quit and the editor could not exit.  Phase H3 (same day) is the dock:
the tool buffers (`tool-document-p`) are tabs below the splitter, the
Diagnostics, Debugger and Inspector panels are tabs beside them, and the
panel generics tell the page what to show (`CK.dbgOpen` and friends,
`host/page-app.js`) while the page hands rows and lines back
(`clamacsDbgFrame`, `clamacsDiagPick`, ...).  Two rules there: the
debugger's and inspector's rows and selection are read off their structs
(`debugger-frame`), never mirrored twice -- the host editor mirrors only
the open flags and the diagnostics selection, which `host-panel-state`
answers; and the page reports what its panels show after every change
(`clamacsPanels` -> `host-page-panels`), so `drive.lisp` checks both
sides of the page boundary through `EVAL`.  A tool buffer or a panel
shown opens the dock, hiding the displayed one shows the next or
collapses it, and `editor-aux-windows` answers the dock and each open
panel to the snapshot (`dock`, `errors`, `debugger`, `inspector` lines).
A tab the user picks is told to Lisp (`clamacsActivate` for a tool
buffer, `clamacsDockShown` for a panel), and whether a document is a dock
tab is `hdoc-dock-p`, fixed when its tab is made: `tool-document-p` asked
later says no once `C-x C-w` gave the buffer a file.

## The Lisp port (decided 2026-09-16, in progress)

`specs/clamacs-lisp.md`: the editor is being rewritten in Common Lisp as
its own clamiga instance, ARexx wire unchanged.  **The C editor below is
frozen (bug fixes only) and keeps shipping until the port declares
parity**; everything else in this file describes it and stays the
behaviour spec.  New editor work goes into `lisp/`:

- `lisp/` holds the editor; `lisp/load.lisp` loads it in order.  The PURE
  modules (keymap, rawkey, command, bindings, killring, minihist,
  locstack, token, sexp, indent) take no MUI and no OS types -- the same
  rule as `src/emacs`, `src/lisp`, `src/rexx` -- and are ports of those C
  modules with the C code as their specification.  `frontend.lisp` is
  the frontend protocol (generic functions on a `document`); commands
  (`commands.lisp`) are functions of `(doc arg)` written against it and
  nothing else, and `tests/fake-frontend.lisp` implements it over a
  string so they are host-tested too; `minibuffer.lisp` (a prompt is a
  continuation) and `files.lisp` extend the protocol the same way.
  `wire.lisp` (the queue to clamiga, over a transport object),
  `diag.lisp`, `port.lisp` (the editor's own verbs) and
  `introspect.lisp` (arglist, completion, `M-.`, describe / apropos /
  macroexpand; `symcache.lisp` is its cache) are pure too, tested on
  `tests/fake-transport.lisp`; a reply is a continuation in
  `wire-dispatch`, never waited for.  So are `repl.lisp` (the REPL
  window, `src/repl.c`: the transcript's two indices, the four inbound
  verbs `OUTPUT`/`READLINE`/`RESULT`/`DEBUGGER` as port verbs, buffer
  evals on the REPL thread), `debugger.lisp` and `inspector.lisp` (the
  state of the two windows and their `M-x` commands; the frontend only
  shows the state through `editor-debugger-*` / `editor-inspector-open`
  and hands row numbers back) and `replmsg.lisp` (the parsers of
  `src/rexx/replmsg.c` + `dbgmsg.c`); `tests/fake-transport.lisp`'s
  `fake-inbound` delivers what clamiga's REPL thread sends.  `menu.lisp`
  is the menu strip as data (`src/emacs/menudef.c`'s table with its
  enable rules, `menu-state` read off the editor, the port's `MENU`
  verb, `clamacs-about` -- a real command here, where C had a menu-only
  item -- and `clamacs-hyperspec` over the `doc-open-url` generic);
  `winstore.lisp` + `snapshot.lisp` are the window positions
  (`src/emacs/winstore.c` + `src/snapshot.c`: a document gets its ROLE
  when it is made, `snapshot-load` reads the layout file before the
  first window, a frontend asks `layout-place` when it creates one,
  `clamacs-snapshot-windows` reads `doc-geometry` /
  `editor-aux-windows`, `GETWINDOW` for the port).
  `transport-self.lisp` is the wire's third transport, to the editor's
  OWN image (`clamacs-connect-self` / `clamacs-connect-clamiga`,
  `wire-switch` in `wire.lisp`): EXT.DEV run in the editor on a worker
  thread, the REPL thread's inbound verbs delivered in-process through a
  wrapped `EXT.DEV:*REPL-SEND*`, `clamacs:in-editor` for code that must
  run on the MUI task; `tests/test-self.lisp` runs the real REPL thread
  with the test thread standing in for the MUI task.  Only
  `frontend-mui.lisp` may name `AMIGA.MUI`: it is the two custom classes
  and the document window, a port of `src/textclass.c` and the MUI half
  of `src/document.c` (the "Phase 1 facts" below apply to it line by
  line), plus the diagnostics, debugger and inspector windows (plain MUI
  Lists and buttons), the menu strip (`build-menustrip` before the
  application object, `menu-update` from `after-command` and after every
  mailbox drain, only changed items set) and `openurl.library` called by
  offset.  `load.lisp` loads it on an Amiga only, and takes a file's
  FASL beside it when there is one that is not older than the source (the
  release ships `lib/clamacs/` that way -- and compiles those FASLs with
  the HOST binary, so a platform choice in the editor's sources is made
  when the file loads, never with `#+amigaos`: `*init-file*` and
  `*snapshot-files*` did that wrong once, and `verify-editor-image.lisp`
  now checks both); `lisp/clamacs.lisp` runs the editor from source (`clamiga --heap
  8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- file ...`)
  through `clamacs::run`, which loads the user's `S:.clamacsrc` first
  (`define-command` and `bind-key` forms; LOAD reports a broken form and
  goes on) and then `start`s on the files.  The files come after `--`:
  clamiga loads a bare argument, and what follows the separator is the
  runtime's `ext:*command-line-args*` -- also what a Workbench project
  icon becomes (cl-amiga's README, "Starting from Workbench"), so the
  editor has one path in for both.  `scripts/save-editor-image.lisp` /
  `verify-editor-image.lisp` are the heap image the release starts from
  (`clamiga --image clamacs.img --non-interactive --eval "(clamacs::run)"
  -- file ...`).
- `verify/realamiga/run-lisp-editor.sh [040|020]` is the Lisp editor's
  FS-UAE smoke run: it types a defun with `sendkey`, saves and closes
  the buffer with `C-x k` (the last window's close is the exit), and
  the saved file must equal what the same keys produce on the host
  under the fake frontend (`verify/realamiga/lisp-editor-keys.lisp` is
  the one list of keys).  It runs the editor with `*exit-trace*` on and
  reads `T:clamacs-exit.log` back: a window dispose that signalled, or
  a teardown that did not reach "application disposed", fails the run
  (`quit.rexx` makes the same check at the end of the drive run).  Run
  it after touching `frontend-mui.lisp`.
- `verify/realamiga/run-lisp-drive.sh [040|020] [PHASE]` (`make -f
  Makefile.cross test-lisp-amiga`) is the Lisp editor's acceptance run:
  a target clamiga with its port, the editor on `sample.lisp`, and the
  SAME `drive.rexx` as the C editor with `PHASE n` (5, the default: all
  of it, 124 `OK` lines on 2026-09-20) selecting the legs the port has
  reached, and `LISP <clamiga>` naming the binary the snapshot leg
  starts its second editor with (without it the leg starts the C
  binary); then the shipped macro and `quit.rexx`.  The script checks
  the log itself.  Run it after touching `wire.lisp`, `port.lisp`,
  `introspect.lisp`, `repl.lisp`, `debugger.lisp`, `inspector.lisp`,
  `menu.lisp`, `snapshot.lisp`, `transport-arexx.lisp`,
  `transport-self.lisp` or the event loop.
  It needs the superproject's `build/cross/clamiga`, rebuilt after a
  runtime change -- a stale one is the first suspect for a red leg.
- `tests/test-*.lisp` are their tests (the C cases plus what C missed),
  `tests/framework.lisp` the `deftest`/`is`/`is-equal` framework.
  `make test-lisp` runs them under the superproject's
  `../build/host/clamiga` (skipped with a NOTE when it is not built) and
  `make test` includes it; `make test-lisp-gc-stress` runs them with a
  compaction at every allocation (`../build/host-gcstress/clamiga`, built
  by the superproject's `make test-gc-stress`).  `CLAMACS_TEST=keymap`
  runs one file.  Both must pass before a commit that touches `lisp/`.
- The verdict is the LAST LINE (`CLAMACS-LISP-TESTS: PASS`), never the
  exit code: clamiga's `LOAD` recovers form by form and a script exits 0
  after a reader error, so `tests/run-lisp-tests.sh` also fails on any
  `ERROR` line.  All test files share the `CLAMACS` package; `deftest`
  refuses a name a second file already used.
- Conventions: a buffer is a `SIMPLE-STRING`, a position a character
  index, "not possible" is `NIL` (never -1); scans are declared `SCHAR`
  loops (the runtime's string-scan opcodes), never generic sequence
  functions on a per-key path, and stacks are lists (`PUSH`/`POP`), not
  per-call vectors.  A command is a symbol (`define-command`), a key a
  fixnum, a keymap an `EQL` hash table.
- The runner gives clamiga a private, empty FASL cache
  (`CLAMIGA_FASL_CACHE_DIR`): `LOAD`'s cache is keyed by a file's own
  mtime plus, since FASL v35, the layouts of the `DEFSTRUCT`s it inlined
  (a changed struct recompiles the dependents) -- but a changed macro or
  inline function in another file still leaves cached dependents stale.
  It also means the GC-stress leg COMPILES everything under stress (about
  7 minutes), which is how it found the runtime's pre-scan GC bug on
  2026-09-17.  A test that fails only in the suite, or only outside it,
  after a macro or inline function changed in another file: suspect a
  cache first (`--no-fasl-cache` to confirm).
- A wrong answer from conforming CL code is a clamiga bug: reduce it,
  fix it in the superproject under its gates, never work around it here.

## Architecture decisions (2026-09-08)

- **Two processes.** The editor is native C, the Lisp lives in `clamiga`.
  Reasons: editor redisplay and buffer edits must not run as bytecode on a
  14 MHz 68020, a GC pause must not freeze the editor, and a crash in either
  half must not take down the other. This is the SLIME model, not the Emacs
  or Lem model. Do not move editor logic into Lisp.
- **MUI, not plain Intuition or ReAction.** MUI is the one toolkit native on
  both targets, gives the application an ARexx port for free, and its custom
  classes are the right hook for the text area. ReAction is OS 3.2/OS4 only.
- **The text area is a private subclass of `TextEditor.mcc`.** Created at
  runtime with `MUI_CreateCustomClass(NULL, "TextEditor.mcc", ...)`, so it
  uses the class installed on the user's system (bundled in the AmigaOS 3
  release archive; MorphOS ships it). The Emacs layer — prefix keys
  (`C-x`, `M-x`, `C-c`), the command table, minibuffer, kill ring, Lisp
  indentation on Return, sexp navigation on exported lines — lives in the
  subclass's `MUIM_HandleEvent` override and falls through to the superclass
  for anything unbound. **Never fork or build the class** unless a gap needs
  its internals; then contribute upstream, or ship a *renamed* class so it
  cannot collide with the copy YAM depends on.
- **`vendor/texteditor` is headers, docs and demo only.** It is not built.
  `vendor/texteditor/include` provides `mui/TextEditor_mcc.h`,
  `libraries/mui.h`, the muimaster protos/inlines and the SDI headers
  (`SDI_compiler.h`, `SDI_hook.h`) — dispatchers written with the SDI macros
  compile unchanged for 68k and MorphOS. No MUI developer kit is needed.
- **Same-buffer split windows are out** (one TextEditor object is one text).
  Multiple windows and documents instead.

## The wire: clamiga's ARexx port

`(require "amiga/arexx") (amiga.arexx:start)` in the user's `S:.clamigarc`
opens port `CLAMIGA` (a second instance takes `CLAMIGA.1`, ...). Served by
its own thread, so it answers while the REPL is busy. Commands today:
`PING`, `VERSION`, `LOAD <file>`, `COMPILE-FILE <file>`, `EVAL <form>`,
`IN-PACKAGE <pkg>`, `LASTRESULT`; a string starting with `(` is evaluated.
Diagnostics come back as `file:line: ERROR: message` lines plus a summary.
Phase 2 added `ARGLIST`, `COMPLETE`, `DESCRIBE`, `APROPOS`,
`SOURCE-LOCATION`, `MACROEXPAND[-1]`; phase 3 (2026-09-10, both halves)
added `REPL-ATTACH <port>`, `REPL-EVAL`, `REPL-INPUT`, `REPL-INTERRUPT`,
`REPL-DETACH`, with clamiga's REPL thread sending `OUTPUT`, `READLINE` and
`RESULT <rc> <pkg>` commands *to the editor's port* -- see the spec's
phase 3 section for why the editor never holds a reply.  Phase 4
(2026-09-11) added `REPL-ATTACH <port> DEBUG`, under which an unhandled
error parks the REPL thread on the erring stack and sends `DEBUGGER
<level> <pkg>` (condition and restarts in the body) to the editor, which
then asks `BACKTRACE`, `RESTARTS`, `FRAME <n>`, `FRAME-EVAL <n> <forms>`,
`RESTART <n>`, `ABORT`, `CONTINUE` (a `DEBUG` attach also switches the
m68k JIT's shadow frames on, else natively compiled functions are missing
from the backtrace); plus `INSPECT <form>`, `PART <n>`, `POP`,
synchronous on the handler thread over the new `ext:inspect-parts`
builtin.  On the editor side the inbound commands arrive through
`MUIA_Application_RexxHook` (the raw `RexxMsg`, no ReadArgs), parsed by
`src/rexx/replmsg.c` and acted on by `src/repl.c`, `src/debugwin.c` and
`src/inspectwin.c`; `src/rexx/dbgmsg.c` reads the reply lines.

Protocol facts the client must respect:

- Return codes are the ARexx severity ladder: 0 ok, 5 warnings, 10 errors,
  20 unusable. ARexx only carries `RESULT` with rc 0 — a failing command's
  text is fetched with `LASTRESULT`.
- Replies are capped at 8 KB, truncated on a line boundary.
- One message in flight per port. **Send RexxMsgs asynchronously** (PutMsg,
  keep the MUI event loop running, handle the reply at the editor's reply
  port). Never block the UI on a reply — a long compile, and later the
  REPL streaming design, depend on it.
- The command layer is portable Lisp in cl-amiga (`lib/dev-commands.lisp`,
  package `EXT.DEV`, `define-command`), host-tested by
  `tests/test_dev_commands.sh`. **New commands are commits in cl-amiga**
  under its gates, never editor-side workarounds.

## Phase 1 facts worth knowing before you touch the MUI layer

Each of these cost a debugging cycle; `specs/clamacs-ide.md` has the full
list under "Answered during phase 1".

- MUI 3.8 is `muimaster.library` **19**.  The vendored `libraries/mui.h`
  says `MUIMASTER_VMIN` is 20, which would refuse to run on the target.
- The C editor's ARexx port is `CLAMACS.1` on the first instance, not
  `CLAMACS` (MUI numbers the port it builds from `MUIA_Application_Base`);
  the Lisp editor's is `CLAMACS`.  Clients scan, as they do for `CLAMIGA`.
- Export with `MUIV_TextEditor_ExportHook_NoStyle`.  The `Plain` hook writes
  colour escapes into the text, which breaks saved files and desynchronises
  every offset from `MUIA_TextEditor_CursorIndex`.
- `SetBlock` marks the buffer changed; save and restore `HasChanged` around
  anything that only paints.
- MUI takes an ARexx command hook's **return value** as the command's return
  code, so every hook returns `LONG 0` explicitly.
- Never dispose a window from a notification hook: `ck_doc_close()` retires
  it and `ck_app_reap()` disposes of it from the input loop.
- MUI hands a `RAWKEY` to **every** object registered for it, not only the
  active one.  Both custom classes check `MUIA_Window_ActiveObject` first
  (TextEditor.mcc does the same), else the text object eats the
  minibuffer's TAB and C-g.
- A bare `MUIM_HandleEvent` override on a TextEditor.mcc (or `String`)
  subclass is **never called**: MUI coerces input to a handler node's
  `ehn_Class`, which the class sets to `cl` in its own Setup -- the
  superclass, once reached via `DoSuperMethodA`.  Each subclass registers
  its **own** node (`ck_add_handler`) naming its own class at priority 1, so
  the Emacs layer runs first and returns 0 (not the superclass) to let the
  class's node edit.
- `TAB`/`RET`/`ESC` are also MUI's `GADGET_NEXT`/`PRESS`/`GADGET_OFF`+
  `WINDOW_CLOSE`, acted on at the window level regardless of the handler.
  The text object disables them via `MUIA_Window_DisableKeys` in
  `MUIM_GoActive` (the class already disables `GADGET_NEXT`); the minibuffer
  keeps `TAB` for completion the same way.  Else `ESC` drops the focus and
  `RET` fires the default gadget.
- Synthetic key injection (`sendkey`) into the `String` minibuffer holds
  focus for one key then MUI deactivates it, so raw `M-x <name> RET` is not
  testable that way -- a harness limit, not an editor bug.  The port's
  `KEY` command types into an open minibuffer and `RET` accepts it (the
  gadget's job, done above it), so `KEY M-x`, a name, `KEY RET` works from
  a macro and the phase-2 prompts are driven that way in `drive.rexx`.  A
  modifier must be injected as a real qualifier-key press bracketing the
  key, not just an `IEQUALIFIER` bit.
- TextEditor.mcc floor is **15.29** (`SetBlock`).  `ck_classes_create()`
  reads a bare object's `MUIA_Version` (YAM's method) and refuses below it.
- The port's `KEY` command stops *above* the raw-key decoder.  Real key
  events come from `verify/realamiga/sendkey` (built by `make -f
  Makefile.cross amiga`), and `drive.rexx`'s raw-key leg is what verifies
  Alt-as-Meta.  On a DOS command line `<` and `>` must be quoted.
- The editor's own port name is not an attribute: `ck_rexx_own_port()`
  scans `CLAMACS`, `CLAMACS.1`, ... for the port whose `mp_SigTask` is
  this task.  `REPL-ATTACH` needs it.
- The port's `INSERT` bypasses the Emacs layer, so in the REPL window a
  macro must `EVAL end-of-buffer` before `INSERT`, or the text lands in
  the transcript wherever a `GOTOLINE` left the cursor.
- The echo area is a page group (message line / prompt + input), see the
  spec's Emacs-layer section.  `MUIM_Group_ExitChange` on the prompt row
  leaves the `String` inactive: `ck_doc_set_label()` re-activates it.  A
  page switch repaints only what the new page's objects cover, so the
  `Text` objects fill the row (`MUIA_Text_SetVMax` FALSE).
- An ACTIVE MUI `String` edits its keys through its string edit hook
  *before* the window's handler list is consulted, so the mini class's
  handler node never sees `TAB`, `C-g` or `Alt-x` on a real keyboard.
  The mini object therefore also sets `MUIA_String_EditHook`.  MUI
  ignores that hook's result and runs the class's own hook next on the
  same `SGWork`, so a taken key is rewritten into a key release, and the
  action is deferred with `MUIM_Application_PushMethod` (`CKM_MiniKey`)
  because the class's hook may write its work buffer back over a
  `MUIA_String_Contents` change.  `ck_doc_minibuffer_binds()` is the one
  list of minibuffer keys.  Only hardware shows any of this: `run-drive`
  passes `HARDWARE` to `drive.rexx` for that leg.  **And MUI 3.8 runs
  that hook on input.device's task** (an active `String` is an
  Intuition string gadget), which a C hook never notices and a Lisp one
  cannot survive: clamiga answers a callback from a non-Lisp task with 0
  without running it, silently unless `(ext:%ffi-foreign-task-calls)`
  is asked (the Vampire's finding B, 2026-09-18: 8 keys typed, counter
  8).  The Lisp port's hook is therefore the runtime's native
  `mui:make-string-key-hook`, fed a table of raw keys that
  `mini-hook-entries` decodes from the keymap once
  (`minibuffer-ever-binds-p` + Meta-character), pushing the key to the
  mini object as `CKM_MiniKey`; `mui:string-key-hook-stats` on a
  document's hook says whether MUI called it and whether it matched.

## Phases

1. **Editor MVP**: MUI app, TextEditor subclass with Emacs keys, minibuffer,
   isearch, kill ring, ASL open/save; Lisp mode locally (paren match,
   indentation table, colouring via `MUIM_TextEditor_SetBlock`); ARexx
   client for LOAD/COMPILE-FILE/EVAL/IN-PACKAGE with a clickable error list;
   the editor's own ARexx port (MUI application rexx commands). If no port
   is found, launch clamiga and wait for the port.
2. **Introspection** (cl-amiga side): `ARGLIST`, `COMPLETE`, `DESCRIBE`,
   `APROPOS`, `SOURCE-LOCATION`, `MACROEXPAND` as EXT.DEV commands, plus
   docstring storage in the compiler. Editor: arglist in the status line,
   completion, jump to definition, describe window.
3. **REPL window** (done 2026-09-10): output streamed to the editor's
   port during EVAL, read requests the other way, a dedicated REPL thread
   in clamiga so the port stays responsive.  `C-c C-z` opens
   `*clamacs-repl*`; `src/repl.c` is the editor half.
4. **Debugger and inspector windows** (done 2026-09-11): the REPL attaches
   with `DEBUG`; an unhandled error at the prompt opens the debugger
   window (restarts, backtrace, locals, eval-in-frame) fed by clamiga's
   parked REPL thread, `C-c I` opens the inspector.  The window's buttons
   are also `M-x clamacs-debugger-*` / `clamacs-inspector-*` commands, so
   the port drives them.  Buffer evals (`C-c C-c`, `C-x C-e`, `C-c C-r`,
   `C-c C-e`) run on the REPL thread too (2026-09-14, `ck_repl_eval_from`
   in `src/repl.c`): the REPL is attached on demand -- its window opens
   but the buffer keeps the focus -- output goes to the transcript, the
   values to the buffer's echo area, the prompt's package is left alone,
   and an error opens the debugger window exactly as at the prompt, its
   echo lines going to that buffer.  The handler thread's `EVAL` is for
   macros and the port, not for keys.  A `DEBUG`
   attach turns clamiga's JIT shadow frames on so natively compiled
   functions show in the backtrace.  The first hardware run found a
   clamiga JIT bug (a throw lost when it unwound through a cleanup holding
   a nested `unwind-protect`; fixed in cl-amiga's
   `src/jit/runtime.c`, pinned by `tests/amiga/dev-repl-tests.lisp`) --
   when a restart "does nothing" on the Amiga but works on the host, run
   that test file straight on the box before blaming the editor.
5. **Menu strip** (2026-09-11): one application-wide
   `MUIA_Application_Menustrip` built from the host-tested table in
   `src/emacs/menudef.c`; an item carries its command id in
   `MUIA_UserData` and the `MUIA_Application_MenuAction` hook runs it
   through `ck_doc_run_command()` on the active document, so the menu is
   a third entrance to the command table, never a second implementation.
   Enable state is polled by `ck_menu_update()` (called after commands,
   edits, activations, replies and `DEBUGGER` messages; only changed
   items are set).  The port's `MENU <name> [STATE]` drives and inspects
   it for `drive.rexx`.  Add a command to the menu by adding a row to
   the table; `tests/test_menudef.c` checks the key shown really runs it.
   Help > Common Lisp HyperSpec (`clamacs-hyperspec`, 2026-09-14) opens
   the URL through `openurl.library` (`src/url.c`, which declares the
   one entry itself: no toolchain ships the OpenURL headers), and shows
   the address in a requester when the library is missing.
6. **Window positions** (2026-09-12): `clamacs-snapshot-windows`
   (Windows > Snapshot Windows) writes every open window's geometry to
   `ENVARC:Clamacs/windows.cfg` + `ENV:`, keyed by role (`doc1`, `doc2`,
   ... for file windows by the lowest free slot, `repl`, `description`,
   `errors`, `inspector`, `debugger`); `src/snapshot.c` reads the file
   at startup and every window is created with `TAG_MORE` into the tags
   `ck_snapshot_tags()` fills.  The store (`src/emacs/winstore.c`) is
   data, host-tested.  **The windows carry no `MUIA_Window_ID` on
   purpose**: MUI's own snapshot would override the editor's, and MUI
   3.8 has no way to take one from code.  The port's `GETWINDOW`
   answers `role left top width height` for `drive.rexx`, whose leg
   snapshots, checks the file, then starts a second editor against a
   hand-written file and reads where it came up.

## Build and toolchain

- There is no toolchain in this repository: `Makefile.cross` uses the
  superproject's `../tools/m68k-amigaos-gcc/prefix` (cl-amiga's
  `tools/setup-toolchain.sh` installs it; a nested copy would make a
  recursive clone of cl-amiga fetch the toolchain sources twice).
  `TOOLCHAIN=...` points a standalone clone at any install.
- Mirror cl-amiga's flags: `-noixemul -mcpu=68020 -std=c99 -Os
  -fomit-frame-pointer`, link with `-s`. This gcc **miscompiles at -O2**
  (flexible-array pointer arithmetic) and `-flto` is broken — stay at `-Os`,
  no LTO.
- C89/C99 only. Sized integers (`uint32_t`, `int32_t`), no `size_t` or
  pointer-sized fields in anything that crosses the OS boundary.
- MorphOS build: native on the box (`make -f Makefile.mos`, the SDK's gcc),
  as cl-amiga does -- there is no PPC cross-compiler on the Mac.
  `Makefile.mos` mirrors the TextEditor.mcc demo's MorphOS flags and leaves
  `muistubs.c` out (its `&tag1` trick is m68k-only; the SDK supplies the
  varargs entry points).  First built on the box 2026-09-11; `run-drive`
  passes there.  Two MUI 4 differences bit: window activation is
  reported late (so the app tracks its active document itself,
  `ck_doc_activate()`), and an active `String`'s keys never reach
  `MUIA_String_EditHook` but come through the subclass's
  `MUIM_HandleEvent` twice, once per handler node, so the mini class
  hands the second visit to the superclass -- the spec's "Still open"
  list has the details.

## Testing

- Unattended FS-UAE runs follow cl-amiga's `verify/realamiga/run-fs-uae.sh`
  pattern (watchdog, auto-quit). The clamiga runtime is the superproject:
  the `CLAmiga:` volume mounts `..` (the cl-amiga checkout), and the
  integration leg reads its `build/cross/clamiga` (`make -f Makefile.cross
  amiga` up there first; without it the leg is skipped with a NOTE). The
  emulator assets (the aos3 Workbench with MUI + TextEditor.mcc, and
  FS-UAE.app) are not tracked in git; `run-fs-uae.sh` takes them from the
  superproject too (`EMU_DIR` overrides; `CLAMIGA_DIR` points the runtime at
  another checkout; a standalone clone falls back to `../cl-amiga` for both).
  The `.fs-uae` configs carry the same two paths as absolute
  `hard_drive_1`/`hard_drive_2` entries and must agree with them.
  clamiga's FASL cache lives on that Workbench image (`S:cl-amiga/faslcache`)
  and is validated by source mtime, so after a fresh clone or a pull of the
  superproject the first run compiles the port's library from source: that needs
  the `stack 128000` the boot scripts set (at 65000 the reader's guard fires
  before the port opens, and the leg is silently skipped) and a minute or two
  of startup.  When the leg is skipped, the log ends with `clamiga.log` and a
  `status` process list that say whether clamiga was still compiling or dead.
  A fixture the run *saves* (`clamacs-load-buffer` saves first) gets an
  FS-UAE `.uaem` metadata file pinning the date the Amiga sees, so a later
  host edit loads the cached old contents: `run-fs-uae.sh` deletes
  `verify/realamiga/*.uaem` before each run for that.
  `quit.rexx` ends the run: it quits the editor, waits for its port to go,
  then sets the flag `arexx-host.lisp` waits on through every `CLAMIGA`
  port it finds, and the host stops its port and exits.  Never let a
  clamiga exit with its port thread alive: the process `_exit`s around the
  thread, which stays on the public port with the VM torn down, and the
  next message to it crashes the task while the sender (and the box agent
  behind it) waits forever.  `amiga.arexx:start` now registers `stop` as an
  exit hook for exactly that.
- Real hardware: the `vamp` (Vampire, AmigaOS 3) and `mos` (MorphOS) MCP
  servers, see cl-amiga's memory notes for the workflow.  When the MCP
  config is stale (or, as in this checkout, absent),
  `~/Development/MySources/amimcp/server/amiga.py` (`Amiga(host,
  token=...)`: `exec_command`, `write_file`, `arexx`, `input_script`)
  drives a box directly.  `verify/realamiga/run-drive` is the whole
  phase-1 run for a box that is up: `Assign Clamacs:` to a drawer with the
  checkout's `build/amiga/`, `verify/realamiga/` and `examples/arexx/`,
  a clamiga with its `lib/` under `Clamacs:clamiga/`, then `Run >NIL:
  Execute Clamacs:verify/realamiga/run-drive` and wait for
  `build/amiga/drive-done`.  Passed on the Vampire 2026-09-08 (phase 1,
  raw-key leg included) and 2026-09-11 (phases 1-4, 93 `OK`).  The
  `Clamacs:` assign and the box's DHCP address do not survive a reboot:
  re-assign, and scan the LAN for the agent port if the old address is
  silent.  On the MorphOS box the same layout lives under
  `Work:DevelAdd/Sources/clamacs` (a tarball of `src/`, `Makefile.mos`
  and the vendored headers, built with `gg:bin/sh` + `make -f
  Makefile.mos`; `build/amiga/clamacs` is a copy of the PPC binary so
  `run-drive` finds it), with a clamiga built from the phase-4 branch
  under `Clamacs:clamiga/`; `run-drive` passed there 2026-09-11 (93
  `OK`).  Warm clamiga's FASL cache on that box before a run (a
  `--load` of a file that requires `amiga/arexx`), since `run-drive`
  waits 15 s for the port.  The box agent has one command slot: a
  message to an editor that is not answering its port wedges it until
  someone touches the box, so check `status` and the port list before
  every `ADDRESS 'CLAMACS.1'`.  And never `IF EXISTS <volume>:` for a
  volume AmigaOS 3 may not have -- the "please insert volume" requester
  parks the script.
  `verify/realamiga/run-lisp-drive` (`Execute ... PHASE n`) is the same
  run for the Lisp editor (the cross-built clamiga under
  `Clamacs:clamiga/`, `lisp/` in the drawer): it warms the FASL cache
  with `warm.lisp`, deletes `T:clamacs-exit.log` first so `quit.rexx`
  reads this run's log, and runs `drive.rexx HARDWARE PHASE n`.  **On a
  Vampire about every second launch of clamiga loses memory stores**
  (the 68080 defect, cl-amiga's README "CPU store self-test"): `drive.rexx`
  asks both ports for `:CPU-LOST-STORES` before driving anything and ends
  such a run with a FAIL that names it -- the run is void, start it
  again; never hunt a red leg on a launch the self-test flagged.
- **Pauses in the ARexx drive scripts go through `sendkey WAIT <ticks>`**
  (a C `Delay()`), not rexxsupport.library's `DELAY()`.  In September 2026
  every external ARexx function call on the real A4000/A1200 zeroed
  Intuition's screen-font record and no MUI window would open afterwards;
  the cause was Roadie 1.3.7 registered as an ARexx function host, fixed by
  Roadie 1.4.  If MUI windows ever stop opening on a box, that record
  (`sc_Font`'s TextAttr, values in `ENV:sys/font.prefs`) is the first
  thing to check.
- LF line endings are forced by `.gitattributes`.
