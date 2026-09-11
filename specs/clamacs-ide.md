# Clamacs: an Emacs-flavoured Common Lisp IDE for AmigaOS 3 and MorphOS

Status: PROPOSED
Date: 2026-09-08

## Goal

A native editor for AmigaOS 3 (68020+) and MorphOS with Emacs key handling
and a Lisp mode, that drives a running `clamiga` (the CL-Amiga runtime) the
way SLIME drives a Lisp: load and compile the buffer with clickable
diagnostics, evaluate forms, look up arglists and definitions, and — in
later phases — a REPL, a debugger and an inspector, each in its own window,
like a real IDE.  No Emacs, no TCP stack and no host machine involved:
editor and Lisp are two Amiga processes talking over ARexx.

## Non-goals

- An editor written in Lisp.  Redisplay and buffer edits must not run as
  bytecode on a 14 MHz 68020, a GC pause must not freeze the editor, and a
  crash in either half must not take down the other.
- Emacs Lisp compatibility, or a general-purpose extension language inside
  the editor.  Extensibility is the editor's ARexx port plus Lisp on the
  clamiga side.
- Emacs-style split windows on one buffer (see Text area).
- Non-Lisp language modes.  The design does not prevent them; nothing is
  built for them.

## Options considered

| Option | Verdict |
|--------|---------|
| Port Lem (the Emacs in CL) | No. Lem is from-scratch CL on SBCL (native code); core depends on iterate, closer-mop, trivia, cl-ppcre, micros, inquisitor, babel, bordeaux-threads, yason, log4cl, dexador, cl-mustache, sb-concurrency; frontends need ncurses, SDL2 or webview. A 48 MB-heap Vampire/MorphOS project at best, not a 68020/8 MB one. |
| Editor in Lisp inside clamiga, Emacs-split (C text core as builtins) | No. Gets REPL/debugger/inspector for free (in-process), but bytecode redisplay, FFI-crossing draw callbacks, GC pauses and shared crashes. The C text core is the same work as the standalone editor's. |
| Port a C editor (mg, uEmacs, Femto) and embed clamiga as extension language | No. clamiga is not packaged as a library; the C parts of those editors are the easy fifth, and their line-list buffers and command loops would be stripped anyway. |
| Own MUI custom class (gap buffer, redisplay) | Fallback only. Months to reach TextEditor.mcc's polish. |
| Plain Intuition window | No. Scroll gadgets, GadTools menus, prefs and an ARexx port to write by hand; foreign on MorphOS. |
| ReAction | No. AmigaOS 3.2/OS4 only, absent on MorphOS. |
| **MUI application, private subclass of the installed `TextEditor.mcc`** | **Chosen.** One toolkit native on both targets; ARexx port for free; custom class is the hook for the text area; the class supplies rendering, undo/redo, clipboard, search, range styling and index/position mapping. |

## Architecture

```
  +---------------------------+     ARexx     +-----------------------------+
  | clamacs (C, MUI)          | ------------> | clamiga                     |
  |  Application              |  port CLAMIGA |  AMIGA.AREXX handler thread |
  |   document windows        |               |   EXT.DEV command layer     |
  |    ClamacsText (subclass  | <------------ |   (lib/dev-commands.lisp)   |
  |     of TextEditor.mcc)    |  port CLAMACS |                             |
  |    minibuffer / status    |  (phase 3+)   |  REPL thread (phase 3)      |
  |   error list window       |               |  nested debugger loop (4)   |
  |   REPL window (3)         |               |                             |
  |   debugger, inspector (4) |               |                             |
  +---------------------------+               +-----------------------------+
```

Two processes.  The editor is the ARexx *client* for everything it asks
the Lisp; the Lisp is the client of the editor's port when it has
something to push (REPL output, read requests) from phase 3 on.

Components of the editor:

- **Application** — one MUI application object; owns the ARexx client
  state, the editor's own ARexx port (`MUIA_Application_Commands`), the
  keymap tables and the command table.
- **Document window** — one per file: a `ClamacsText` object, a scrollbar
  attached through `MUIA_TextEditor_Slider`, a status line (file, package,
  line/column, arglist echo from phase 2), and the minibuffer (a `String`
  object that becomes active when a command needs input).
- **ClamacsText** — the private subclass of `TextEditor.mcc` carrying the
  Emacs layer (see below).
- **Error list window** — diagnostics of the last LOAD/COMPILE-FILE as a
  `List`; selecting a row jumps to file and line.  Plain MUI `List`, no
  extra MCC dependency.
- **ARexx client** — asynchronous request/reply to clamiga's port.
- **Later windows** — REPL (phase 3), debugger and inspector (phase 4).

## The text area: subclass of TextEditor.mcc

Created at runtime with
`MUI_CreateCustomClass(NULL, "TextEditor.mcc", NULL, sizeof(struct Data),
ENTRY(Dispatcher))`, using the SDI dispatcher macros from
`vendor/texteditor/include` so the same source builds for 68k and MorphOS.
The class is never built or forked; `vendor/texteditor` supplies the
header (`mui/TextEditor_mcc.h`), `libraries/mui.h`, the muimaster protos
and the SDI headers, so no MUI developer kit is needed.  The AmigaOS 3
release bundles the class binaries from the amiga-mui release; MorphOS
ships it.  The editor checks the class version at startup -- a bare object's
`MUIA_Version`/`MUIA_Revision`, YAM's method -- and refuses to run below
**15.29**, the release that added `MUIM_TextEditor_SetBlock`, which the
colouring and the paren highlight rest on; everything else phase 1 uses is
older.  Verified against 15.56.

### Key handling

Facts from the 15.56 sources that shape the design:

- The class resolves keys through a `struct te_key {code, qual, act}`
  table terminated by `code == -1`, taken from the **user's TextEditor.mcc
  preferences** (`MUICFG_TextEditor_Keybindings`) or the compiled-in
  defaults.  `MUIA_TextEditor_KeyBindings` exists in the header but
  **nothing in the class reads it** — the application cannot supply its
  own table.
- Therefore the Emacs layer owns its bindings by overriding
  `MUIM_HandleEvent`: decode the `IDCMP_RAWKEY` event (raw code, qualifier,
  `MapRawKey` for the vanilla character), run the keymap; if bound, execute
  the command and return `MUI_EventHandlerRC_Eat`; otherwise
  `DoSuperMethodA` so the class's own bindings (arrows, Home/End, mouse
  selection, Return, Tab, Backspace) still work.  A user's TextEditor
  preferences never override an Emacs binding because the subclass sees
  the key first.
- MUI hands a `RAWKEY` event to **every** object that registered for the
  class, not only to the active one, so both subclasses check
  `MUIA_Window_ActiveObject` before acting -- as TextEditor.mcc itself does
  -- and a key typed into the minibuffer is never taken by the text object
  whose handler was registered first.  While the minibuffer has the focus
  it also switches off MUI's cycle-chain TAB (`MUIA_Window_DisableKeys`),
  so TAB completes.
- The decoding rules (which qualifier is Meta, what the keymap may be
  told, which keys are known by code, what is refused) are pure C in
  `src/emacs/rawkey.c`, parameterised over the one OS call (`MapRawKey`),
  and host-tested; `src/textclass.c` supplies the call.
- **Meta** is Alt (left or right).  `ESC` acts as a Meta prefix as well,
  for keyboards and users where Alt is awkward.  **Control** is
  `IEQUALIFIER_CONTROL`.  The Amiga keys stay free for the OS and for MUI
  menu shortcuts.

### Text access

No direct line-access API exists, so structural editing works on exported
text:

| Need | Class facility |
|------|----------------|
| Lines around point (paren match, indentation, defun-at-point) | `MUIM_TextEditor_ExportBlock` with `MUIF_TextEditor_ExportBlock_FullLines` on a line range |
| Whole buffer (save, load-buffer, eval-buffer) | `MUIM_TextEditor_ExportText` |
| Insert at point / at a position | `MUIM_TextEditor_InsertText` |
| Point as index and back | `MUIA_TextEditor_CursorX/Y`, `MUIA_TextEditor_CursorIndex`, `MUIM_TextEditor_CursorXYToIndex`, `MUIM_TextEditor_IndexToCursorXY` |
| Region | `MUIM_TextEditor_MarkText`, `MUIM_TextEditor_BlockInfo`, `MUIA_TextEditor_AreaMarked` |
| Syntax colouring | `MUIM_TextEditor_SetBlock` with `MUIF_TextEditor_SetBlock_Color` per token range |
| Undo/redo, clipboard, search | class built-ins (`MUIA_TextEditor_UndoLevels`, `MUIM_TextEditor_Search`) |
| Change notification | `MUIA_TextEditor_ContentsChanged`, `MUIA_TextEditor_HasChanged` |

Exporting the lines around the cursor is cheap.  If profiling on a 68020
shows export cost in paren matching or colouring, the fallback is a shadow
copy of the text in the application, synchronised from
`ContentsChanged`, not a fork of the class.

One object is one text: same-buffer split views are not supported, and the
editor does not emulate them.  Several documents, several windows.

## Emacs layer

- **Keymaps**: global map, Lisp-mode map, and prefix maps (`C-x`, `C-c`,
  `M-`/`ESC`), each a sorted array of `{qualifier, code, binding}` where a
  binding is a command or another map.  `C-g` cancels a prefix.  `C-u`
  numeric arguments in phase 1 for the movement and kill commands only.
- **Commands** are C functions registered by name in a command table, so
  `M-x name` and the editor's ARexx port share one namespace.
- **Minibuffer**: the window's `String` object, activated with a prompt,
  with history and tab completion from a per-prompt completion source
  (file names via the directory listing, command names, later symbol names
  from clamiga).  The same line is the echo area, Emacs-style: a MUI page
  group whose page 0 is a full-width `Text` for messages and page 1 the
  prompt label (`MUIA_Text_SetMin`, weight 0, so it takes exactly its
  text) beside the `String`.  Opening a prompt flips to page 1, closing it
  flips back, so a message never competes with a prompt for width (until
  2026-09-11 both shared one row, the label at weight 30, and every
  message was cut at a quarter of the window).  A message that arrives
  while a prompt is open takes the label's place, as `[No match]` does
  after TAB; the port's `STATUS` reports the message either way.  Because
  MUI measures a `Text` object only at layout, a changed label goes
  through `MUIM_Group_InitChange`/`ExitChange` on its row; isearch keeps
  the pattern in the input and only the state (`I-search: `, `Failing
  I-search: `) in the label, so typing does not relayout.
- **Kill ring** in the application (`C-k`, `C-w`, `M-w`, `C-y`, `M-y`),
  distinct from the clipboard; `C-w`/`M-w` also copy to the clipboard so
  other applications see the last kill.
- **Mark and region**: `C-SPC` sets the mark; the region is shown through
  the class's block marking so mouse selection and keyboard selection are
  the same thing.
- **Isearch** (`C-s`/`C-r`) over `MUIM_TextEditor_Search` with the
  minibuffer showing the pattern.
- **Files**: `C-x C-f`, `C-x C-s`, `C-x C-w`, `C-x b`, `C-x k`; ASL file
  requester behind `C-x C-f` when the minibuffer entry is empty.  Files are
  8-bit (ISO-8859-1), matching clamiga's narrow strings.

Phase-1 key table (the bindings a user can rely on):

| Keys | Command |
|------|---------|
| `C-f C-b C-n C-p C-a C-e M-f M-b M-< M-> C-v M-v` | movement |
| `C-d M-d C-k C-w M-w C-y M-y` | delete, kill, yank |
| `C-SPC C-x h` | mark, select all |
| `C-/ C-_ C-x u` | undo |
| `C-s C-r` | isearch |
| `C-x C-f C-x C-s C-x C-w C-x b C-x k C-x C-c` | files, buffers, quit |
| `C-x o C-x 2 (new window on another file)` | windows |
| `M-x` | command by name |
| `C-M-f C-M-b C-M-u C-M-d C-M-a C-M-e C-M-k M-(` | sexp commands (Lisp mode) |
| `Tab` | reindent line |
| `C-c C-k C-c C-c C-x C-e C-c C-r C-c C-l` | load buffer, eval defun, eval last sexp, eval region, load file |

Phase 3 adds `C-c C-z` (the REPL window, from any document), `C-c C-b`
(interrupt the running form, from a Lisp buffer) and, in the REPL window,
`RET` (send when the form is complete, else newline-and-indent), `M-p`/`M-n`
(input history), `C-c C-c` (interrupt) and `C-c M-o` (clear).

## Lisp mode

- **Tokenizer** (pure C, host-testable): comments (`;`, `#| |#`), strings,
  characters (`#\`), keywords (`:foo`), the defining-form heads
  (`defun`, `defmacro`, `defvar`, `defclass`, ...), numbers, symbols.  Runs
  over the changed line(s) after each edit and applies colours with
  `SetBlock`; a multi-line construct (block comment, string) re-tokenizes
  forward until the state matches the previous run.
- **Sexp scanner** (pure C, host-testable): forward/backward sexp, up/down
  list, beginning/end of defun, matching-paren search over an exported
  window of lines that grows backwards until a column-0 `(` (defun start)
  is found.  Paren match highlights the partner with a `SetBlock` colour
  and clears it on the next cursor move.
- **Indentation** (pure C, host-testable): `Return` inserts a newline and
  indents; `Tab` reindents the current line.  Rules follow SLIME's
  `cl-indent`: a built-in table maps operator symbols to a body-indent spec
  (`defun` 2, `let` 1, `if` 2, `when`/`unless` 1, `loop` special, `lambda`
  1, `flet`/`labels` 1 with binding bodies, `handler-case` 1, ...); unknown
  operators align to the first argument, or one space past the paren when
  the operator stands alone.  The table is data, so phase 2 can extend it
  with `&body` positions asked from clamiga.
- **Package tracking**: the nearest `(in-package ...)` above point gives
  the package sent with each eval; the status line shows it.

## ARexx client

### Port discovery and launch

Port `CLAMIGA`, else `CLAMIGA.1` .. `CLAMIGA.9` (a second instance), the
same scan the shipped `clamiga.rexx` macro does.  If none exists and the
user asked for a Lisp command, the editor offers to launch clamiga in its
own console window (`SystemTags` with a `CON:` window, the command line
from the editor's preferences, default `clamiga`) and waits up to a
configurable time for the port to appear; the user's `S:.clamigarc` is
expected to `(require "amiga/arexx") (amiga.arexx:start)`.

### Asynchronous requests

Every request is a `RexxMsg` built with `CreateRexxMsg`/`CreateArgstring`
and sent with `PutMsg`; the editor **never** waits for the reply.  The
reply port's signal bit is added to the `Wait()` mask of the MUI input
loop (`MUIM_Application_NewInput`), and the reply is handled like any
other event.  Rules:

- One request in flight per clamiga port (the port serves one message at a
  time).  Further requests queue in the editor, in order.
- A request carries a continuation: the command that issued it, the
  document, and what to do with the reply (fill the error list, insert the
  values, show in the minibuffer).
- A watchdog timer (via the MUI application's timer) reports a request that
  has had no reply for a configurable time — it does not cancel it, since
  the handler thread will reply eventually, and cancelling would desync the
  one-in-flight rule.
- Return codes are the ARexx severity ladder: 0 ok, 5 warnings, 10 errors,
  20 unusable.  ARexx carries `RESULT` only with rc 0, so any non-zero rc
  is followed by an automatic `LASTRESULT` request to fetch the text.
- Replies are capped at 8 KB by clamiga, truncated on a line boundary; the
  editor shows the marker line as-is.

### Commands (existing in clamiga 0.9)

| Command | Editor use |
|---------|------------|
| `PING` | port health check after connect / launch |
| `VERSION` | shown in the status line; the editor refuses versions older than it knows |
| `IN-PACKAGE <pkg>` | sent before an eval when the buffer's package changed since the last request |
| `LOAD <file>` | `C-c C-k` after saving the buffer; `C-c C-l` for another file |
| `COMPILE-FILE <file>` | `M-x compile-file` |
| `EVAL <form>` | `C-c C-c`, `C-x C-e`, `C-c C-r` |
| `LASTRESULT` | automatic after a non-zero rc |

Diagnostics are parsed from the reply text one line at a time:
`<file>:<line>: <SEVERITY>: <message>` rows go into the error list, the
summary row (`N error(s), M warning(s)`) into the minibuffer.  Anything
else is shown verbatim in the error list window's text pane.

### The editor's own ARexx port

`MUIA_Application_UseRexx` with a `MUIA_Application_Commands` table (port
name `CLAMACS`, `CLAMACS.1` for a second instance).  Phase-1 commands:

| Command | Template | Does |
|---------|----------|------|
| `OPEN` | `FILE/A,LINE/N` | open a file, optionally jump to a line |
| `SAVE` | | save the active document |
| `GETFILE` | | result: full path of the active document |
| `GETNAME` | | result: the active window's name -- the file part of the path, or `*clamacs-description*` and the other phase-2 scratch windows, which have no file |
| `GOTOLINE` | `LINE/N/A` | jump |
| `EVAL` | `FORM/F` | run an editor command by name (the `M-x` namespace) |
| `INSERT` | `TEXT/F` | insert at point |
| `TE` | `CMD/F` | pass-through to `MUIM_TextEditor_ARexxCmd` (`CURSOR`, `POSITION`, `GETLINE`, `GETCURSOR`, `MARK`, `TEXT`, ...) |
| `STATUS` | | result: the echo area, so a macro can read what the editor just reported |
| `KEY` | `KEYS/F` | feed a key sequence (`KEY C-x C-s`, `KEY C-u 4 C-f`) through the keymaps |

`EVAL` and `KEY` are the two ways in, and the difference matters: `EVAL`
runs a command directly, `KEY` goes through the keymaps, so prefix keys, the
`C-u` argument reader, `C-g` and the minibuffer all take part.  With the
minibuffer open, `KEY` also does what its `String` gadget would do with the
keys the Emacs layer leaves to it: a plain character types, `BS` deletes,
`RET` accepts -- so `KEY M-x`, the name one key at a time, `KEY RET` runs a
command by name, and the phase-2 prompts can be answered.  The unattended
test uses `KEY` to exercise the command loop, which the other commands walk
straight past.

This is what the shipped CygnusEd macro pattern needs to work against
clamacs too.  Phase 3 adds the three commands clamiga's REPL thread sends
the other way -- `OUTPUT <text>`, `READLINE`, `RESULT <rc> <pkg>` -- and
phase 4 a fourth, `DEBUGGER <level> <pkg>`, but not to this table: they
come in through `MUIA_Application_RexxHook`, which MUI calls with the raw
`RexxMsg` for any command it cannot map, so no ReadArgs template stands
between the wire and the text (see phase 3).

## Phases

### Phase 1 — editor MVP

Deliverables: the MUI application, `ClamacsText`, the keymap and command
engine, minibuffer, kill ring, isearch, file commands, Lisp mode
(tokenizer, sexp scanner, indentation, paren match, package tracking), the
ARexx client with the existing commands, the error list window, the
editor's own port, launch-if-missing.

Acceptance: edit and save a file on FS-UAE (68020 config) and on the
Vampire; `C-c C-k` on a file with two errors shows both rows and selecting
one jumps to the line; `C-x C-e` on `(+ 1 2)` echoes `3`; the CygnusEd
macro rewritten for `CLAMACS` loads the current file; the editor stays
responsive while clamiga compiles a large file; memory use measured on an
8 MB configuration and recorded in `docs/`.

No changes in cl-amiga are needed for phase 1.

### Phase 2 — introspection

cl-amiga side (`lib/dev-commands.lisp`, host-tested by
`tests/test_dev_commands.sh`, Amiga end-to-end in
`tests/amiga/arexx-tests.lisp`), all replies plain text, rc 0 unless the
symbol or package does not exist (rc 10):

| Command | Reply |
|---------|-------|
| `ARGLIST <symbol>` | the lambda list on one line, from `ext:function-arglist` |
| `COMPLETE <prefix> [<package>]` | one candidate per line, exported symbols first, capped at 200 lines |
| `DESCRIBE <symbol>` | `describe` output |
| `APROPOS <string> [<package>]` | one symbol per line with a kind tag (`function`, `macro`, `variable`, `class`) |
| `SOURCE-LOCATION <symbol>` | `<file>:<line>` from `ext:function-source-location`, rc 10 when unknown |
| `MACROEXPAND <form>` and `MACROEXPAND-1 <form>` | the pretty-printed expansion |

Plus docstring storage in the compiler (they are parsed and discarded
today; `specs/documentation-introspection.md` in cl-amiga has the audit),
so `DESCRIBE` shows documentation.

Editor side: arglist of the operator at point in the status line
(requested on a short idle timer, cached per symbol), `M-TAB`/`C-M-i`
completion through the minibuffer, `M-.` jump to definition with `M-,` to
return, `C-c C-d d` describe and `C-c C-d a` apropos in a text window,
`C-c RET` macroexpand into a scratch window.

### Phase 3 — REPL window

Protocol (cl-amiga side, `lib/dev-repl.lisp`, loaded on first use because
it needs gray-streams and so CLOS; landed 2026-09-10):

- `REPL-ATTACH <port>` — clamiga remembers the editor's port and starts a
  dedicated REPL thread; the reply is the current package's shortest name
  (`CL-USER`), for the prompt.  `REPL-DETACH` stops the thread.
- `REPL-EVAL <forms>` — queued for the REPL thread and **replied to at
  once** with rc 0 and no text; rc 10 while a form is still running.  The
  thread evaluates the forms with the standard streams bound to a stream
  that sends `OUTPUT <text>` to the editor's port as output is produced
  (flushed on newline, at 1 KB, and before the result).  A read on
  standard input sends `READLINE`; the editor answers with a command of
  its own, `REPL-INPUT <line>`, and the thread parks on a condition
  variable in between.  When the forms are done the thread sends `RESULT
  <rc> <package>` followed by a newline and the printed values of the last
  form, one per line (`; No values`), or `ERROR: <text>` with rc 10.
- The port's handler thread stays free, so arglist and completion keep
  working while a form runs.  `REPL-INTERRUPT` interrupts the REPL thread
  (`mp:interrupt-thread`, delivered at a VM safepoint, so a tight loop is
  reached); the form ends with `RESULT 10 ... ERROR: Interrupted`.
- The listener's `*`, `+`, `/` and friends are kept.  `IN-PACKAGE` at
  either end reaches the other: the editor's sets the package the next
  form runs in, a form's `(in-package ...)` comes back in `RESULT` and
  moves `*command-package*`.
- A failing send to the editor's port (the editor is gone) stops the REPL
  thread instead of killing it; `REPL-ATTACH` starts a fresh one.

Why the reply to `READLINE` is not the line, and why `REPL-EVAL`'s reply
carries no values: MUI answers an application's ARexx command the moment
the command hook returns, so the editor cannot hold either reply until
the user has typed.  Everything the editor has to wait for comes back as
a command from clamiga.

Editor side (`src/repl.c`, landed 2026-09-10): the REPL window is a
`ClamacsText` named `*clamacs-repl*` under the REPL keymap -- the Lisp map
with `RET`, `M-p`/`M-n`, `C-c C-c` and `C-c M-o` rebound.  `C-c C-z` from
any document opens or raises it and, when no REPL thread is attached,
sends `REPL-ATTACH <own port>`; the editor finds its own port among
`CLAMACS`, `CLAMACS.1`, ... by the port's owning task, since MUI numbers
it and offers no attribute with the result.  The reply's package makes
the first prompt.

The bookkeeping is two document indices: `input_start`, where the input
begins (after the prompt, or right after the last output while a
`READLINE` is outstanding; -1 while a form runs, when there is no input
and output is appended), and `prompt_start`, so output that arrives while
a prompt is showing goes above it.  The transcript is read-only by way of
the Emacs layer: a self-insert with the cursor in the transcript lands in
the input instead, Backspace at the input's start is swallowed, the
editing commands are refused while a form runs, and undo is off in this
window (an undo step could take back an `OUTPUT` insert).  `RET` sends
the input with `REPL-EVAL` when `ck_sexp_input_complete` says the parens,
strings, `#|` comments and quote prefixes balance, else it is
newline-and-indent, so a defun is typed across lines at the prompt; a
blank input is a fresh prompt.  Before each form the REPL sends its own
`IN-PACKAGE` if a buffer eval moved the port's package in between, and
each `RESULT`'s package moves both the prompt and the editor's idea of the
port's package.  `C-c C-c` (and `C-c C-b` in a source buffer, or `M-x
clamacs-interrupt`) sends `REPL-INTERRUPT`.  Closing the window and
quitting send `REPL-DETACH`; the quit path waits for that one reply so
clamiga's thread is stopped rather than left sending to a vanished port.
When clamiga's port goes away the window says so and prompts again;
`C-c C-z` re-attaches.

The three inbound commands do not go through the `MUIA_Application_
Commands` table.  MUI calls `MUIA_Application_RexxHook` with the raw
`RexxMsg` for any command it cannot map, and that is where they are
parsed (`src/rexx/replmsg.c`, host-tested), so the open point above is
answered by not asking ReadArgs at all: a chunk that starts with blanks,
holds a lone quote or ends in a newline arrives as printed.  Each hook
returns at once, since the REPL thread is waiting on that reply.

Verified on FS-UAE and on the Vampire (2026-09-11, MUI 3.8, TextEditor.mcc
15.50, clamiga 0.9 at b7aeca5) by the phase-3 leg of `drive.rexx`: the prompt after
`C-c C-z`, `(+ 1 2)` answered on the next line, two `princ`s streamed
line by line before the value, `READ-LINE` answered from the input line,
`(loop)` interrupted by `C-c C-c`, `IN-PACKAGE` moving the prompt and
back, `M-p`/`M-n`, and an `ARGLIST` answered while the REPL slept.

`M-x run-lisp` stays: it launches clamiga in a console window, which was
the way to get its debugger until phase 4.

### Phase 4 — debugger and inspector windows

Protocol (cl-amiga side, `lib/dev-repl.lisp` for the debugger,
`lib/dev-commands.lisp` for the inspector, plus one builtin
`ext:inspect-parts`; landed 2026-09-11):

- `REPL-ATTACH <port> DEBUG` asks for the mode.  With it, an unhandled
  error in a form does not end the form: the REPL thread's `handler-bind`
  handler runs on the erring stack -- clamiga runs handlers before it
  unwinds, for runtime errors too, so the frames, their locals and the
  restarts are all still there -- and the thread sends `DEBUGGER <level>
  <pkg>`, the condition (`<type>: <report>`) and one restart per line
  (`<n>: <NAME> <report>`) to the editor's port, then parks on the same
  condition variable `READLINE` uses, taking its next steps from the port.
  Without `DEBUG` (a phase-3 editor) nothing changes.
- `BACKTRACE` answers from a snapshot taken on entry, with the REPL's own
  frames left out and the rest renumbered from 0: `<n>: <name>
  <file>:<line>`; `RESTARTS` repeats the level, the condition and the
  restart list for a macro that missed the announcement.  On the m68k
  build a function the JIT compiled natively pushes no VM frame of its
  own, so a `DEBUG` attach turns the JIT's per-call shadow frames on
  (`clamiga::%jit-set-frames`, a few percent on call-heavy code; such a
  frame shows the arguments, not the `let`-bound locals) and a detach
  puts them back.
  `FRAME <n>` hands a job to the parked thread and waits
  a moment for its answer (`<name> = <value>` per local; the names are
  the compiler's placeholders, `ARG0`, `LOCAL3`): frame numbers count from
  the top of a stack that has grown by the loop's own frames since the
  snapshot, so the difference in depth is the shift.  `FRAME-EVAL <n>
  <forms>` is replied to at once, like `REPL-EVAL`: the thread binds the
  frame's locals under their placeholder names with `progv` and prints the
  values as the REPL prints them, so they arrive as `OUTPUT`; an error in
  there is a nested level with an `ABORT` back to the level below.
  `RESTART <n>` invokes restart `n` of the current level interactively
  (one that asks reads through `READLINE`); `ABORT` and `CONTINUE` are the
  innermost restart of that name.  Every REPL form runs under a
  `restart-case` with an `ABORT` ("Return to the REPL"), so a level can
  always be left; leaving one re-announces the level below, `DEBUGGER 0`
  once none is left, and `RESULT` follows when the form is done (`;
  Aborted` as its value).  `REPL-INTERRUPT` while parked ends the form as
  it would a running one (the interrupt goes in as a job too, since the
  thread sits in `condition-wait`, not at a safepoint), and `REPL-DETACH`
  lets the thread go through the same `ABORT`.
- `INSPECT <form>` evaluates the form on the port's handler thread -- with
  `*`, `**`, `***` bound to the REPL thread's, which keeps them in
  `ext.dev::*repl-stars*` for that -- and answers a header `<TYPE> <depth>
  <count>`, the object on one line, then `<n>: <label> = <value>` per part
  (at most `*max-inspect-parts*`, 200, each printed bounded and on one
  line).  `PART <n>` descends, `POP` comes back; the navigation stack is
  per connection and a fresh `INSPECT` starts it over.  The parts come
  from `ext:inspect-parts`, a new builtin over the C inspector's component
  enumeration (`(label . value)` pairs, with a limit), since the C
  inspector's loop reads stdin and no port command can.

Editor side (`src/debugwin.c`, `src/inspectwin.c`, the parsing in
`src/rexx/dbgmsg.c` and `DEBUGGER` in `src/rexx/replmsg.c`, both
host-tested): the REPL attaches with `DEBUG`.  A `DEBUGGER <level>`
message arrives through the same `MUIA_Application_RexxHook` as the other
three, and `ck_debug_entered()` fills the debugger window -- the condition
line, the restarts list (double-click or the Invoke button invokes one; a
`CONTINUE` restart enables the Continue button, Abort is always there),
the backtrace list (selecting a frame asks `FRAME <n>` for the locals list
below it, double-click opens the frame's source at its line), and a
string line that sends `FRAME-EVAL` in the selected frame -- and asks
`BACKTRACE`, whose reply selects frame 0.  The window opens without taking
the focus, since it arrives while the user may be typing; `M-x
clamacs-debugger` raises it.  `DEBUGGER 0`, a `RESULT`, closing the REPL
window and losing clamiga's port all close it.  While a level is active
the REPL's transcript is closed (`RET` says so) and the echo area tracks
the steps; the last one after any announcement is `Debugger level N,
frame 0: <first local>`, which is what `drive.rexx` polls for.  The
window's buttons exist as commands too, prompting for their number:
`clamacs-debugger-abort`, `-continue`, `-restart`, `-frame`, `-eval`, so
`M-x` and the port drive the debugger without a mouse.

`C-c I` (`clamacs-inspect`) prompts for a form, sends `INSPECT` with the
buffer's package, and the inspector window shows the object and the parts
list; double-click (or the Inspect-part button, or `M-x
clamacs-inspector-part`) sends `PART <n>` by the row's own number, Back
(`M-x clamacs-inspector-pop`) sends `POP` and is disabled at depth 1.  The
window title names the type; a capped list ends with a `... N more` row.

Verified on FS-UAE (2026-09-11, clamiga at the phase-4 commit) by the
phase-4 leg of `drive.rexx`: `(dbg-fn 3 4)` at the prompt opening the
debugger with `ARG0 = 3` in frame 0, `RET` refused meanwhile, a frame eval
of `(list arg0 arg1)` printing `(3 4)` into the transcript, a nested
level from an error in a frame eval, `RESTART 0` ending the form with `;
Aborted`, `cerror` opening the debugger, and `C-c I` on `(list 1 (list 2
3))` with a `PART 1` and a `POP`, `ABORT` back from level 2 to level 1,
and `CONTINUE` on the `cerror` finishing the form with `:WENT-ON`.  The
last two needed a fix in clamiga's JIT (the answered list, below) and
passed on the Vampire the same day.  cl-amiga's own `tests/test_dev_commands.sh`
(host) and `tests/amiga/arexx-tests.lisp` cover the protocol from the
other side.

Not covered yet: a frame's locals have no names (the compiler keeps
placeholders), so the locals list and the frame eval speak of `ARG0` and
`LOCAL3`, and a function the m68k JIT compiled natively shows its
arguments only; inspecting a local from the debugger (SLIME's `i` in sldb) would
need a command that evaluates in the REPL thread's frame, which `INSPECT`
on the handler thread cannot; CLOS instances inspect as the structs they
are underneath; and `C-x C-e` / `C-c C-c` from a source buffer still go
through `EVAL` on the handler thread, which catches errors into
diagnostics as in phase 1 -- only forms typed at the REPL reach the
debugger.

## Testing

- **Host unit tests** for every pure C module — keymap engine, tokenizer,
  sexp scanner, indentation, diagnostic parser, request queue — compiled
  with the host compiler against a small `test.h` in the style of
  cl-amiga's, run by `make test`.  These modules take no MUI or OS types,
  which is a design rule, not an accident.
- **FS-UAE integration**: the cl-amiga harness pattern
  (`verify/realamiga/run-fs-uae.sh`: boot, run a script, auto-quit,
  host-side watchdog).  A test boots clamiga with the port and clamacs,
  drives clamacs through its ARexx port (`OPEN`, `EVAL` of editor
  commands, `GETFILE`, `KEY`), and checks results written to a log file.
  The clamiga binary comes from the pinned `vendor/clamiga` submodule
  (`vendor/clamiga/build/cross/`); the emulator assets (aos3, FS-UAE.app),
  which are not in that clone, come from a cl-amiga checkout beside the repo.
- **Raw keys**: the port's `KEY` command stops above the decoder.
  `verify/realamiga/sendkey` (a 68k CLI tool, built alongside the editor)
  writes real `IECLASS_RAWKEY` events to `input.device`, spelled like the
  editor's keys -- `sendkey C-x C-q`, `sendkey "M-<"`, `sendkey TEXT
  "(foo Bar)"` -- so `drive.rexx`'s raw-key leg covers Intuition, MUI's
  event routing, the `MUIM_HandleEvent` overrides and `MapRawKey` too.
  Raw codes come from `MapANSI`, so it is right for the system's keymap.
- **Real hardware** through the `vamp` (Vampire, AmigaOS 3) and `mos`
  (MorphOS) MCP servers for the things emulation does not show:
  keyboard qualifiers, timing, memory on a small configuration.  The
  raw-key leg is the keyboard check there too: `sendkey` runs unchanged on
  a real 68k Amiga and under MorphOS's 68k emulation, and `drive.rexx`
  only needs the `Clamacs:` assign and a running RexxMast.

## Release

Two archives, `clamacs-aos3` and `clamacs-mos`, each with the binary, the
docs, the ARexx examples, and for AmigaOS 3 the `TextEditor.mcc` binaries
from the amiga-mui release with their LGPL notice.  Versions of clamacs and
clamiga are independent; the editor records the oldest clamiga it works
with and checks `VERSION` at connect time.

## Answered during phase 1

Each of these cost a debugging cycle in FS-UAE that the host tests could
not have saved; CLAUDE.md carries the short list.

- **MUI 3.8 is `muimaster.library` 19.**  The vendored `libraries/mui.h`
  says `MUIMASTER_VMIN` is 20; opening with it refuses to run on exactly the
  target.  The editor opens version 19.
- **The editor's port is `CLAMACS.1` on the first instance**, not
  `CLAMACS`: MUI numbers the port it builds from `MUIA_Application_Base`.
  Clients scan the base name and `.1` .. `.9`, as they do for `CLAMIGA`.
- **Export with `MUIV_TextEditor_ExportHook_NoStyle`.**  The `Plain` hook
  writes `\033P[...]` colour escapes into the text, which breaks saved files
  and desynchronises every offset from `MUIA_TextEditor_CursorIndex`.
- **`SetBlock` marks the buffer changed.**  Colouring saves and restores
  `MUIA_TextEditor_HasChanged` around anything that only paints.
- **MUI takes an ARexx command hook's return value as the command's return
  code**, so every hook returns `LONG 0` explicitly; declared `void`, the
  code a macro saw was whatever was left in d0.
- **Never dispose a window from a notification hook**: `ck_doc_close()`
  retires it and `ck_app_reap()` disposes of it from the input loop.
- **The context window must reach forward as well as back**, or
  `end-of-defun` never moves and `C-c C-c` reads every defun as unbalanced.
- **The diagnostic parser must stop at clamiga's `--- log ---` section**,
  or the log lines become phantom error rows.
- **MUI hands a `RAWKEY` to every registered object**, not only the active
  one (see "Key handling").  Found by the raw-key leg; the `KEY` command
  picks its receiver by `mini_state` and could not see it.
- **A `MUIM_HandleEvent` override alone is never called on a TextEditor.mcc
  subclass.**  MUI delivers input by `CoerceMethod` on the class named in an
  event-handler node's `ehn_Class`, and the class registers its node with
  `ehn_Class = cl` from its own `MUIM_Setup` -- which the subclass reaches
  through `DoSuperMethodA`, so `cl` there is the *superclass*, and every key
  is coerced straight to the class.  The subclass must register its **own**
  handler node naming its own class, at a higher priority; then the Emacs
  layer sees keys first and the class's node does the ordinary editing on
  what it does not eat.  The same holds for the `String` minibuffer.
- **Several Emacs keys are MUI's built-in window controls**, and MUI acts on
  them at the window level whether or not the handler ate the event, stealing
  the focus first: `TAB` is `MUIKEY_GADGET_NEXT`, `RET` is `MUIKEY_PRESS`,
  `ESC` is `MUIKEY_GADGET_OFF`/`MUIKEY_WINDOW_CLOSE`.  The text object
  disables them with `MUIA_Window_DisableKeys` while it has the focus (the
  class already disables `GADGET_NEXT`); the minibuffer keeps `TAB` for
  completion the same way.  Without this, `ESC` dropped the focus and `RET`
  fired the default gadget instead of indenting.
- **Minimum TextEditor.mcc: 15.29** (`SetBlock`), checked at startup;
  verified against 15.56.  What MorphOS 3.x ships is still to be recorded
  (below).
- **Meta on Amiga keyboards, MUI 3.8 under emulation**: verified with real
  `IECLASS_RAWKEY` events.  `Alt+Shift+,` arrives with
  `IEQUALIFIER_LALT|LSHIFT` and decodes to `M-<` (`beginning-of-buffer`);
  MUI does not take Alt for itself.  `ESC` as Meta works too once `ESC` is
  kept from MUI's `GADGET_OFF`/`WINDOW_CLOSE` (above): `ESC >` runs `M->`.
  Control (`C-n`), prefix sequences (`C-x C-q`), `RET` newline-and-indent
  and self-insert (including shifted characters) all go through the whole
  path -- Intuition, MUI's routing, the decoder, `MapRawKey`.  The `OK raw`
  lines in `drive.rexx` are the record.  What remains is real keyboards,
  below.
- **Memory on 8 MB**: `docs/memory.md`.  The editor costs about 1.0 MB of
  fast RAM with two documents open, so no `--lowmem` mode is needed.  The
  editor *plus* a clamiga does not fit in 8 MB -- Workbench, MUI and
  Picasso96 have taken 4.8 MB before either starts -- so 16 MB of
  accelerator RAM is the verified floor for the whole IDE, and phases 3-4
  inherit it.  The number to watch is the largest *contiguous* fast block.
- **Real hardware (2026-09-08, Vampire: AmigaOS 3.2, muimaster.library
  19.35, TextEditor.mcc 15.50, German keymap, MagicMenu and the user's other
  commodities running)**: the whole `drive.rexx` run passes unchanged, the
  raw-key leg and the integration leg against a clamiga 0.9 included.  So a
  real input chain does not take Alt before the window sees it -- `OK raw
  M-< (Alt as Meta) reached the top` and `OK raw ESC > acted as Meta` on
  the box are the record -- and the phase-1 acceptance criteria hold on
  hardware as well as under emulation.  `verify/realamiga/run-drive` is
  the sequence for a box that is already up (it needs `FAILAT 21`: the
  shipped macro returns 10 on `errors.lisp`, and Execute's default would
  stop the script there).  Real-hardware readings of the editor's state
  go through the port and answer for the *active* document, which a
  hand on the mouse can change mid-run: check `GETFILE` first.
- **A clamiga that never opens its port under FS-UAE is a cold FASL cache
  plus a small stack** (found 2026-09-10, the first run after pinning the
  submodule).  clamiga's cache lives on the Workbench image
  (`S:cl-amiga/faslcache/<version>-fasl<N>/`) and is validated by source
  mtime, so a fresh clone or a re-pin of `vendor/clamiga` makes every
  entry stale and the port's library -- `lib/amiga/arexx.lisp`,
  `lib/dev-commands.lisp` and their requires -- is compiled from source at
  startup.  That compile needs cl-amiga's baseline `stack 128000`; at the
  65000 `boot-override` had, the reader's guard fired ("C stack
  exhausted") before the port opened, and the harness reported a clean
  skip.  `boot-override` now matches `run-drive` (128000, `--heap 8M`),
  both scripts append `clamiga.log` and a `status` process list to the
  test log, and `drive.rexx` waits two minutes for the port.
- **A fixture edited on the host can still load its old contents under
  FS-UAE** (2026-09-11, the first phase-4 run: `Undefined function:
  DBG-FN` for a defun that was plainly in `intro.lisp`).  FS-UAE keeps
  the Amiga-side metadata of a file the emulated system wrote -- the
  protection bits and the *Amiga* date of the write -- in a `.uaem` file
  beside it, and shows that date to the Amiga from then on.
  `clamacs-load-buffer` saves before it loads, so the fixtures the run
  loads get one, and the next host edit does not move the date the
  Amiga sees; clamiga's FASL cache, validated by source mtime, then
  serves the previous contents.  `run-fs-uae.sh` deletes the `.uaem`
  files before a run.  The `RESTARTS`/`BACKTRACE` view of clamiga's own
  port in `drive.rexx` (`LispView`) is what named the cause; keep such
  INFO lines in a leg whose checks go through the editor.
- **clamiga's m68k JIT lost a throw that unwound through a cleanup with
  a nested `unwind-protect` in it** (2026-09-11, found by the phase-4 leg,
  fixed the same day in `vendor/clamiga`, `src/jit/runtime.c`).  The
  symptom: `ABORT` from debugger level 2 back to level 1 ended the whole
  form with the level-1 condition, and `CONTINUE` on a `cerror` came back
  as `RESULT 10 ERROR: stop here` -- the restart's `restart-case` clause
  never ran (its `; Aborted` never printed), the two interposed
  `%repl-debug` cleanups did, and the condition being handled escaped as
  if the handler had declined.  Green with `--no-jit` and on the host.
  Seven FS-UAE runs narrowed it to "m68k, restart from the debugger"; the
  real bisection took two minutes on the Vampire with clamiga run
  directly (`tests/amiga/dev-repl-tests.lisp` and a scratch matrix): the
  minimal shape -- a handler on top of the erring frame, a nested job
  with its own `restart-case`, `invoke-restart` from the nested handler --
  passes in every variant (native or bytecode signaller and machinery,
  parked on a condition variable or not, on a thread or not) **unless the
  interposed `unwind-protect`'s cleanup itself contains an
  `unwind-protect` that exits normally** (`with-lock-held` is one; so is
  the `handler-case` in the announcement's send).  Root cause, in the
  JIT's runtime helpers: the VM parks the pending-throw record on a
  per-thread saved-pending stack when an `unwind-protect` is armed,
  updates it when its landing fires, leaves it alone on a normal pop and
  restores it in `OP_UWRETHROW`; the JIT parked nothing, cleared
  `cl_pending_throw` on every normal-exit pop, and so the outer transfer
  was gone the moment a nested cleanup's `unwind-protect` finished.  A
  second, smaller gap found on the way: the JIT's shared NLX allocator
  did not record the C error-frame depth (`error_mark`) for CATCH, BLOCK,
  TAGBODY and UNWIND-PROTECT frames (only HANDLER-CASE did), so a landing
  left `cl_error_frame_top` pointing into unwound C stack.  Both now
  mirror the VM.  Two wrong turns before that, each refuted by a later
  run: the JIT's shadow frames (innocent; a `DEBUG` attach turns them on
  so natively compiled functions show in the backtrace) and "a natively
  compiled signaller" (the one green JIT run was luck: the emulator's
  `.uaem` dance had left `intro.lisp` uncached and bytecode).  What told
  the sides apart was clamiga's own view over its port (`drive.rexx`'s
  `LispView`: `RESTARTS` and `BACKTRACE` at each step), and what found
  the cause was running the suite file straight on hardware instead of
  through the editor and the emulator.  The dev-repl matrix now runs in
  cl-amiga's Amiga suite; the `drive.rexx` checks are `FAIL` again.
- **Raw typing into the minibuffer works on real hardware.**  `M-x
  end-of-buffer RET` as one stream of `IECLASS_RAWKEY` events with one- to
  two-tick gaps (the box agent's input injection) ran `end-of-buffer`
  through the minibuffer, and so did the name typed in a second burst half
  a second after `M-x`.  The one-key deactivation is an FS-UAE artefact
  (below), not something a keyboard does.
- **A relayout deactivates the `String`** (2026-09-11, the echo-area page
  group, Vampire).  `MUIM_Group_ExitChange` on the prompt row -- needed
  because a `Text` object with `MUIA_Text_SetMin` is measured only at
  layout -- brings the minibuffer's `String` back inactive while the
  window still names it as the active object, so every key typed after
  `Failing I-search: ` replaced `I-search: ` was lost.  The row is relaid
  only when the label text changes, and the `String` is then re-activated
  by setting `MUIA_Window_ActiveObject` to `None` and back.
- **A page switch repaints only what the new page's objects cover.**  A
  `Text` object is as tall as its font, not its page, so with the message
  page shown the hidden prompt row's frame and old input stayed on
  screen around it.  Both `Text` objects grow to the row's height
  (`MUIA_Text_SetVMax` FALSE) and the row has no spacing, so their
  background fill covers the other page.

- **An ACTIVE `String` edits its keys before the window's handler list
  is asked** (2026-09-11, Vampire; found while checking the echo area and
  present in every earlier build).  With the minibuffer's `String` active
  on a real keyboard, raw `TAB` moved the focus to the text object instead
  of completing, raw `C-g` during isearch did not abort, and `Alt-x` typed
  `×` (the keymap's dead-key result) into the input; raw `C-g` at an
  `M-x` prompt only "worked" because the preceding `TAB` had already
  moved the focus to the text object, whose handler aborts the
  minibuffer.  The mini class's handler node -- which works for the
  port's `KEY` and for the deactivated string under FS-UAE -- is never
  asked while the `String` is active: MUI 3.8's `String` edits through an
  Intuition-style string edit hook ahead of the handler list, whatever
  the node's priority.  The fix is `MUIA_String_EditHook` on the mini
  object (`ck_mini_edit_func` in `src/textclass.c`), which MUI calls
  before the class's own hook with the `SGWork`.  Two properties of that
  hook shape the code: MUI ignores its result and runs the class's hook
  on the same `SGWork` next, so a key the editor takes is made invisible
  by rewriting the event to a key release with no qualifier and clearing
  the mapped character; and the class's hook may still write its work
  buffer back afterwards, so the action (completion, history, abort) is
  not run inside the hook but pushed with
  `MUIM_Application_PushMethod` as `CKM_MiniKey` and run from the input
  loop.  `ck_doc_minibuffer_binds()` is the one list of minibuffer keys
  that both the hook and the node consult; a `hook_taken` flag keeps the
  node from acting on the same event should MUI go on to consult it.
  `Meta` plus a character the minibuffer does not bind is taken too and
  reported undefined, so `Alt-x` no longer types a stray character.
  `drive.rexx` grew a hardware-only leg for this (run-drive passes
  `HARDWARE`; FS-UAE cannot keep the `String` active): raw `M-x end-of-b
  TAB RET`, `M-x` inside the prompt, `C-g`, and `C-s ... C-s C-g` in
  isearch -- six `OK` lines, all green on the Vampire the same day (76
  `OK`, 0 `FAIL` for the whole run).

## Still open

- **Raw typing into the minibuffer under FS-UAE**: driving the `String`
  gadget with *synthetic* key events there is a harness limit -- MUI holds a
  programmatically-activated string for a single injected key and then
  deactivates it, so `sendkey` can prove raw `M-x` opens the minibuffer and
  raw `C-g` aborts it, but not `M-x <name> RET`.  On the Vampire the same
  events type the whole name (above), so `drive.rexx` keeps its raw leg
  short of the minibuffer to stay green under emulation; the minibuffer's
  command loop, prompt, completion and history are covered by the `KEY`
  leg (which types into an open minibuffer and accepts it with `RET`: the
  phase-2 describe, apropos and completion prompts are answered that way),
  the host tests, and the hardware run.
- **The phase-2 leg of `drive.rexx`** (intro.lisp: arglist from the idle
  timer, `M-.`/`M-,`, `C-c RET`/`C-c M-m`, `C-c C-d d`, `C-c C-d a`,
  `M-TAB`/`C-M-i` with the minibuffer hand-off) passes on FS-UAE
  (2026-09-10, clamiga at 04a2a41: the idle timer had `(twice n)` cached,
  the jump landed in the open window, the description carried the
  docstring).  Its `OK` lines are in `verify-amiga`'s list.  Not yet run on
  hardware; `run-drive` is the step there.
- **The phase-3 leg of `drive.rexx`** (the REPL window against clamiga at
  b7aeca5) passes on FS-UAE and on the Vampire (2026-09-11, 70 `OK`, no
  `FAIL`, via `run-drive`); its `OK` lines are in `verify-amiga`'s list.
  Two things it does not cover: output
  arriving while a prompt is showing (only a thread other than the REPL's
  can print then) and a transcript long enough to matter on a 68020 --
  every insert costs a few cursor moves and each move a paren-match scan
  over the context window, which is fine for a session and unmeasured for
  a long one.  And one edge on the quit path: `ck_rexx_close()` waits for
  the `REPL-DETACH` reply without serving the editor's own port, so a REPL
  thread caught mid-`OUTPUT` at that moment waits for a reply that comes
  only when MUI disposes of the port; clamiga's `REPL-DETACH` gives up on
  the thread after five seconds and answers rc 10, and the editor exits.
- **The phase-4 leg of `drive.rexx`** (the debugger and inspector windows)
  passes on FS-UAE (2026-09-11) and has not been run on hardware yet;
  `run-drive` is the step, and its `OK` lines are in `verify-amiga`'s
  list.  What it does not cover: the mouse paths (double-click on a
  restart, a frame or a part, the buttons), which are the same functions
  the commands call; and a `RESTART` whose interactive function reads a
  line (host-tested in cl-amiga: it goes through `READLINE`, which the
  REPL window answers as in phase 3).
- **MorphOS build**: `Makefile.mos` is written to the flags the
  TextEditor.mcc demo's own MorphOS build uses (`-noixemul
  -DNO_PPCINLINE_STDARG`, SDK varargs, no `muistubs.c`) and has not been
  compiled -- there is no PPC cross-compiler on the Mac and the box was
  off.  `make -f Makefile.mos` in a checkout on the box is the step, then
  the same `drive.rexx` (with `build/morphos/clamacs`), and the shipped
  TextEditor.mcc version goes into the list above.
- **Encoding beyond ISO-8859-1** is out of scope until clamiga's wide
  strings are in a release build.
