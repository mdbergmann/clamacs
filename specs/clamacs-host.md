# Clamacs on the host: the webview frontend

The Lisp editor (`specs/clamacs-lisp.md`) declared parity with the C
editor on 2026-09-20, and its design left a host frontend as "a phase of
its own once parity is declared, with its own spec".  This is that spec:
what "at par with MUI" means for a Mac/Linux/Windows frontend, the
decisions that shape it, the interface between the page and the Lisp, and
the plan -- one session per phase, each ending in a commit that passes
`make test` and its own gate.

The decision of 2026-09-21 stands: **webview + CodeMirror 6**, one
frontend for the three hosts, over Tk (a second process and a Tcl wire),
Cocoa through the FFI (months) and a terminal (not "on the Mac").  The
spike under `spike/host-webview/` proved the round trip -- `dlopen` of
`libwebview.dylib`, `ffi:make-callback` as a `webview_bind` handler,
`webview_return`, `webview_eval`, a 380 KB page through
`webview_set_html` -- and passed under `CLAMIGA_GC_STRESS=1`.

## What parity means

The MUI frontend (`lisp/frontend-mui.lisp`, 2,300 lines) plus its
transport (`lisp/transport-arexx.lisp`) give the editor these things; the
host frontend gives every one of them, through the same protocol, so that
no command, no test and no port verb knows which frontend answered:

1. **The document**: every generic function of `lisp/frontend.lisp`,
   `minibuffer.lisp`, `files.lisp`, `snapshot.lisp`, `menu.lisp`,
   `debugger.lisp`, `inspector.lisp` and `transport-self.lisp` -- text
   access, editing, motions, clipboard, the echo area, the status line
   with the arglist, the minibuffer, search, the requesters, the file
   dialog, titles, activation, closing, geometry, the URL opener.
2. **Keys**: the Emacs layer sees every key first (prefix maps, `C-u`,
   `C-g`, ESC-as-Meta, the minibuffer's keys), and what it does not take
   the widget does -- self-insert, Backspace, arrows, mouse selection,
   paste.
3. **Lisp mode**: colouring by token kind, the paren highlight, indentation
   on TAB and RET, sexp motion -- all Lisp-side already; the frontend
   only paints.
4. **The windows**: the diagnostics list (a row jumps), the debugger
   (condition, restarts, backtrace, locals, eval-in-frame, three
   buttons), the inspector (object, parts, Inspect part, Back), the REPL
   and the scratch buffers (`*clamacs-description*`, ...).
5. **The menu strip** with its enable rules, the Buffers menu, About, the
   HyperSpec item.
6. **Window positions**: `clamacs-snapshot-windows`, `GETWINDOW`, the
   layout file read at startup.
7. **The editor's own port**: every verb of `port.lisp` reachable from
   outside the process, so a script drives the editor the way
   `drive.rexx` does.
8. **The wire**: the REPL, the debugger, the inspector, introspection,
   LOAD/COMPILE-FILE against a Lisp -- the editor's own image first, a
   separate clamiga second.
9. **The acceptance run**: the legs of `verify/realamiga/drive.rexx`,
   minus what is Amiga-only (raw `sendkey` events, ARexx port names, the
   68080 store check), passing unattended on the host.
10. **Shutdown**: nothing OS-owned outlives `start`; the heap-image
    story (`scripts/save-editor-image.lisp`) applies to the host image
    too, later.

Not parity, and not planned: split windows of one buffer (the MUI
editor has none either), a native menu bar (webview has no API for one;
the page draws it), non-Latin-1 text (the editor is 8-bit everywhere).

## Decisions

### One native window, tabs and a dock

`webview_create` makes one window; a second instance is not something the
library promises.  The page therefore holds every "window" of the MUI
editor as a **tab**:

- the top region: the source buffers (files, the unnamed buffer), one
  CodeMirror view each, one tab bar;
- the bottom **dock**, resizable by a splitter and collapsible: the tool
  buffers (`tool-document-p`: the REPL, description, apropos, room,
  macroexpansion -- CodeMirror views too) and the three panels
  (Diagnostics, Debugger, Inspector), one tab bar;
- one status line and one echo/minibuffer row at the bottom, showing the
  ACTIVE document's state (re-rendered from that document's mirror on
  every activation).

`doc-activate` selects the tab and focuses its view; `doc-close-window`
removes the tab; `find-file-other-window` opens a tab.  The native window's
title is the active document's.  This is what a 2026 IDE looks like, which
is what the user asked for ("nice looking"), and it is one webview
instance, one event loop, one page -- the shape the spike proved.

Geometry for the snapshot: `doc-geometry` answers the native window's
frame for every document (they share it); `editor-aux-windows` answers
`("dock" left top width height)` for the dock, plus the three panel roles
with the dock's geometry, so `GETWINDOW` and the layout file keep their
meaning.  At startup `layout-place "doc1"` places the native window and
the "dock" entry sizes the dock.

### Keys go to Lisp first, and Lisp owns the text

The Emacs layer cannot tell the page statically which keys it wants:
after `C-x`, a plain `f` is the editor's; after `M-g`, `g` is.  A
binding is a promise on the JS side, so the page cannot ask synchronously
either.  Therefore:

- the page `preventDefault`s **every** key except IME composition
  (`isComposing`), keys with the Command key (the host's Amiga key: left
  to the OS and to CodeMirror -- Cmd-C/V/X/A/Z stay native), and modifier
  presses, and sends it to Lisp (`clamacsKey`);
- Lisp decodes it (`host-decode-key`, the browser's `KeyboardEvent`
  fields to `make-key`), runs `handle-key` / `minibuffer-key`, and when
  the Emacs layer does not take the key **Lisp performs the widget's
  default itself** on its mirror: a printable key inserts, Backspace and
  Delete delete, arrows and Home/End/PageUp/PageDown move -- exactly what
  `tests/fake-frontend.lisp`'s `type-keys` calls "the widget's half of the
  bargain";
- the **mirror** is the fake document made real: the text as a
  `simple-string`, the point, the mark, an undo/redo list, the modified
  flag, the colours.  Every read of the protocol (`doc-text`,
  `doc-index-line`, `doc-search`, ...) is answered from it synchronously;
  every write goes to it and is pushed to CodeMirror.  `doc-move`,
  `doc-edit` and `doc-search` are the fake's implementations (word
  motion, page motion, undo), promoted to `lisp/textmirror.lisp` and
  shared by both;
- what CodeMirror changes on its own -- paste, drag and drop, IME text,
  a mouse click or drag -- comes back through `clamacsUpdate` (the
  changes) and `clamacsCursor` (head and anchor) and is applied to the
  mirror as an edit.  A change the page made at Lisp's request is not
  reported (an `applying` flag on the page).

Cost: one round trip per keystroke (JS → binding → Lisp → `webview_eval`),
sub-millisecond on a host; the MUI frontend runs Lisp on every key too.
Gain: the host editor is the host-tested fake with a screen, so
`tests/test-commands.lisp` and friends already specify its behaviour.

### Everything Lisp tells the page is batched

Lisp never reads the page.  What it tells it (`CK.*` calls, see the
interface) is appended to a per-entry buffer and flushed as ONE
`webview_eval` at the end of every entry into Lisp -- a key, a binding
call, a mailbox drain, a timer tick -- so `colour-all` over a 3,000-line
file is one call, not 30,000.  `doc-call-quietly` is a no-op beyond that.

### The event loop, threads and the GC

`webview_run` parks the main thread in native code.  On the host a
foreign call is **not** a GC safe region (`src/core/builtins_ffi.c` never
calls `cl_gc_enter_safe_region`), so a worker thread asking for a
stop-the-world collection would wait for the main thread's next safepoint
-- which never comes while the loop runs.  The MUI frontend had the same
problem and solved it with `AMIGA:WAIT-SIGNALS`.  Here the shim (below)
**steps** the Cocoa loop instead: `clamacs_host_step(ms)` runs
`nextEventMatchingMask:untilDate:` + `sendEvent:` for at most `ms`
milliseconds and returns; Lisp's `run-loop` calls it, drains the mailbox,
does its housekeeping (reap, quit, buffers menu) and loops.  A collection
waits at most one step (50 ms).  A modal dialog (`doc-ask`) holds the
main thread longer; the workers stall for its duration, as they do under
`MUI_Request`.

The other threads -- the self transport's worker, the REPL thread, the
port's connection threads -- never touch a document: they post a closure
to the **mailbox** (`call-in-editor`, the MUI frontend's, moved to a
shared `lisp/mailbox.lisp` with the wake function as a parameter) and
the loop runs it.  The wake is `webview_dispatch`, thread-safe by
contract, so a post is served before the step's timeout.  While a modal
dialog is up, a drain is deferred (`*in-modal*`), never run inside the
dialog's nested loop.

Should stepping prove insufficient, the runtime alternative is a
`:gc-safe` foreign call whose callbacks leave and re-enter the safe
region -- a cl-amiga commit under its gates, useful beyond Clamacs, noted
as runtime item R2 below.

### The native shim

What a page cannot do and the `webview` C API does not offer is a small
Objective-C file, `host/clamacs-host.m`, built into `libclamacs-host.dylib`
beside `libwebview.dylib` by `host/build.sh` (clang, the Cocoa and WebKit
frameworks; no other toolchain).  Its C API, called through
`ffi:call-foreign`:

| Function | For |
|---|---|
| `int clamacs_host_step(void *w, int ms)` | one turn of the event loop |
| `int clamacs_host_ask(void *win, const char *text, const char *buttons)` | `doc-ask`: an `NSAlert`, buttons `"Save\|Discard\|Cancel"`, answers the index, -1 for Escape |
| `char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)` | `doc-ask-file`: `NSOpenPanel` / `NSSavePanel`, a malloc'd path or NULL |
| `void clamacs_host_free(void *p)` | frees it |
| `void clamacs_host_beep(void)` | `NSBeep` |
| `int clamacs_host_clipboard_set(const char *text)` | `doc-clipboard-copy` |
| `int clamacs_host_open_url(const char *url)` | `doc-open-url`: `NSWorkspace` |
| `void clamacs_host_get_frame(void *win, int32_t out[4])` / `set_frame(win, l, t, w, h)` | `doc-geometry`, `layout-place` (top-left origin, flipped from Cocoa's) |
| `void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)` | the window's close button asks the editor (`save-buffers-kill-emacs`) instead of ending the loop; a delegate that forwards everything else to webview's |

Linux (GTK) and Windows (Win32) implementations go behind `#ifdef` in the
same file when those hosts are taken up; every entry has a "not
available" return so the editor runs without them (the requester falls
back to the echo area, the file dialog to the prompt).

### The wire: the editor's own image first, TCP second

There is no ARexx on the host.  The wire's home transport is the **self
transport** (`transport-self.lisp`, portable, tested by
`tests/test-self.lisp`): the REPL, the debugger, the inspector,
introspection and LOAD all work against the editor's own image from the
first session, and `Talk to the Editor Itself` / `Talk to clamiga` are
the same transport twice until the second one exists.

The second is **TCP**, in two halves, both on a length-framed line
protocol (below).  The wire runs arbitrary Lisp (`EVAL`, `LOAD`), and
where ARexx was reachable only from the local desktop a TCP port is
reachable by every process, and every user, on the machine.  So the rule
for both listeners is **loopback by default, a token always** -- see
"Who may connect" below; nothing in this section serves a frame before
the token has been checked.

- **runtime**: `lib/dev-tcp.lisp` in cl-amiga -- `(ext.dev.tcp:start
  :port N)` listens on 127.0.0.1 unless the caller passes `:host` with
  another address, requires the session token from every connection
  before it serves anything, then serves `ext.dev:handle-command` (and the
  raw commands) per connection on a thread of its own, and routes
  `ext.dev:*repl-send*` for a port name of the form `tcp:HOST:PORT/TOKEN`
  to a connection it opens to the editor (the token is the *editor's*,
  handed over on the already authenticated connection by `REPL-ATTACH`,
  so it is on no command line and in no file the clamiga reads).  A
  runtime commit under every gate, host-tested by
  `tests/test_dev_tcp.sh`.  With `:host` set it is also what a Mac user
  driving an *Amiga* clamiga over the network uses: that opt-in is what it
  is for, and the only reason it exists.
- **editor**: `lisp/transport-tcp.lisp` -- a client thread with one
  request in flight, replies posted to the mailbox (the shape of
  `transport-arexx.lisp`'s `client-loop`), `transport-find-port` a
  connect attempt to `CLAMACS_CLAMIGA` (`host:port`, default
  `127.0.0.1:4005`; the token from `CLAMACS_CLAMIGA_TOKEN`, sent as
  the first frame), `transport-launch` a `clamiga --load` of a preamble
  that starts the TCP port with `:token` read from `CLAMIGA_TCP_TOKEN`
  -- a token the editor drew and put in the child's environment, never
  on its command line.  The host has no `ext:run-program` yet: runtime
  item R3, or the shim's `posix_spawn`.

The **editor's own port** on the host is the same protocol served by
`lisp/transport-host.lisp`: a listener on 127.0.0.1 unless the editor
was started with `--bind ADDR` (`CLAMACS_PORT`, 0 for an ephemeral port
written to `$TMPDIR/clamacs-port`; the session token beside it in
`$TMPDIR/clamacs-token`), a thread per connection, every verb of
`port.lisp` run through `call-in-editor` with `port-command` (or
`port-raw-command` for `*raw-port-verbs*`).  That is what the host drive
script talks to (it reads the token file) and what `REPL-ATTACH
tcp:...` names.

Protocol, both directions, bytes in Latin-1:

```
request:  "<n>\n" then n bytes: the command line  (VERB argument)
reply:    "<rc> <n>\n" then n bytes: the text
```

No quoting, no escaping, newlines inside the text are the text's; `rc`
is the ARexx ladder of `wire.lisp`.  A closed connection is the port
being gone (`wire-reply ... :lost t`).

The first request on every connection is `AUTH <token>`.  The reply is
`0 2\nOK`; anything else -- a wrong token, a different verb first, no
frame within 5 seconds, a length above the 1 KB an `AUTH` needs -- is
answered `20 <n>\nauthentication required` (nothing of the request is
run, echoed or logged) and the connection is closed.  `AUTH` is not a
verb of `port.lisp` or `ext.dev`: the listener owns it, so no command
can be reached around it.

### Who may connect

Both listeners -- the runtime's `ext.dev.tcp` and the editor's own port --
keep the same three rules:

- **Bind**: 127.0.0.1.  The only ways to another address are the
  runtime's `:host` argument and the editor's `--bind ADDR` (after `--`),
  each spelled out by whoever starts the process: no default, no
  environment variable and no config file turns it on, and neither
  accepts a wildcard address.  A Mac driving an Amiga clamiga over the
  LAN needs both -- the clamiga listening for the editor, the editor
  listening for the clamiga's REPL leg.  A non-loopback bind is for a
  trusted network: the token authenticates, it does not encrypt -- every
  byte, the token included, crosses the wire in the clear -- and this
  spec does not pretend otherwise.
- **Token**: 128 bits, hex, per session, drawn from the OS entropy source
  (POSIX `/dev/urandom`, Windows `BCryptGenRandom`) by the process that
  listens; `start` also takes `:token` for a clamiga where there is no
  such source (the Amiga: the user picks it), and **refuses to listen
  without one or the other**.  It is compared in constant time.
- **Where it is kept**: the editor's own port writes
  `$TMPDIR/clamacs-token` (and `clamacs-port`) created with mode 0600 --
  an `open` with the mode, never a `chmod` afterwards, so there is no
  window in which it is readable -- and removes them at shutdown.  Where
  `$TMPDIR` is shared between users (Linux `/tmp`) the files go in
  `$XDG_RUNTIME_DIR` instead, and the editor refuses to start if it can
  do neither.  A token `start` drew itself is printed to that clamiga's
  own standard output, once; one it was given (`:token`) is not.

Each of the three rules has a test.  `tests/test_dev_tcp.sh` (runtime) and
`tests/test-transport-host.lisp` (editor) both check that a connection
that skips `AUTH` (an `EVAL` of a form with a visible side effect as the
first frame), one with a wrong token, an oversized first frame and a
silent one are refused and closed, that the side effect did not happen,
and that a right token is served; the editor's test also that
`clamacs-token` and `clamacs-port` are mode 0600 and gone after
shutdown.  The runtime test further checks that a `start` without `:host`
refuses a connection to the machine's non-loopback address, and that
`start` with neither an entropy source nor `:token` refuses to listen.

### Text encoding across the boundary

The page speaks UTF-16, the bindings carry UTF-8 JSON, the editor is
8-bit.  JS → Lisp: the JSON reader (`lisp/json.lisp`, a small full reader:
arrays, objects, strings with escapes, numbers, the three literals)
decodes UTF-8 to code points, keeps 0-255 and turns the rest into `?`,
as `store-text` does for MUI.  Lisp → JS: the JS string writer escapes
every code above 127 as `\u00XX`, so the C string handed to
`webview_eval` is ASCII.  Files stay Latin-1 (`files.lisp`).

## The interface between the page and the Lisp

### Bindings (page → Lisp, `webview_bind`; arguments a JSON array)

| Binding | Arguments | Meaning |
|---|---|---|
| `clamacsReady` | `userAgent` | the page is up: Lisp builds the menus, opens the first documents |
| `clamacsKey` | `docId, key, code, ctrl, alt, meta, shift, target` | a key in a view (`target` "text") or the input line ("mini") |
| `clamacsUpdate` | `docId, [[from, to, inserted], ...], head` | a change CodeMirror made on its own |
| `clamacsCursor` | `docId, head, anchor` | the selection moved on its own (mouse) |
| `clamacsMiniInput` | `text` | the input line changed on its own (paste) |
| `clamacsActivate` | `docId` | a tab was clicked / a view focused |
| `clamacsCloseTab` | `docId` | a tab's close button |
| `clamacsMenu` | `index` | a menu item picked (the table index) |
| `clamacsBuffers` | `n` | a Buffers-menu item picked |
| `clamacsDiagPick` | `row` | a diagnostics row selected |
| `clamacsDbgFrame` / `clamacsDbgFrameOpen` / `clamacsDbgRestart` / `clamacsDbgEval` / `clamacsDbgButton` | `n` / `n` / `n` / `text` / `"continue"\|"abort"` | the debugger panel |
| `clamacsInspPart` / `clamacsInspBack` | `n` / -- | the inspector panel |
| `clamacsDockResized` | `height` | for the snapshot |
| `clamacsTick` | -- | every 300 ms: `arglist-idle` on the active document |

Every binding runs on the main thread inside `webview_dispatch`'s turn;
its handler is bracketed by the batch flush and `after-command`
(`menu-update`, a quit carried out by the loop).

### Calls (Lisp → page, `webview_eval` of `CK.<name>(...)`)

`makeDoc(id, name, kind)` (`kind` "source" or "tool"), `removeDoc(id)`,
`activateDoc(id)`, `setText(id, text)`, `applyEdit(id, from, to, text,
head)`, `setPoint(id, head, anchor)`, `setColours(id, [[y, [[x0, x1,
kind], ...]], ...])`, `setTitle(id, title)`, `setModified(id, flag)`,
`setStatus(text)`, `setEcho(text)`, `openMini(label, text)`,
`closeMini()`, `setMiniText(text)`, `setMiniLabel(label)`,
`setMenus(json)`, `menuEnable(index, flag)`, `setBuffers(json)`,
`showDiagnostics(rows, open)`, `selectDiagnostic(row)`, `dbgOpen(level,
condition, restarts, hasContinue)`, `dbgClose()`, `dbgRaise()`,
`dbgFrames(rows)`, `dbgSelectFrame(n)`, `dbgLocals(rows)`, `inspOpen(type,
depth, object, parts)`, `setDock(height)`, `terminate()` (the page asks
nothing further).

Colours are per line: the page keeps a map from line to runs and a
`StateField` of mark decorations rebuilt for the lines that changed.
Token kinds map to CSS classes (`ck-comment`, `ck-string`, ...,
`ck-paren-match`); the palette is the page's, light and dark.

### The page

`host/page-head.html` (the CSS: the layout, the two palettes under
`prefers-color-scheme`), `host/page-entry.mjs` (the CodeMirror imports
bundled by esbuild into `window.CM`: `EditorView`, `EditorState`,
`Decoration`, `StateField`, `StateEffect`, `RangeSetBuilder`,
`lineNumbers`, `drawSelection`, `highlightActiveLine` -- no keymap, no
history, no closeBrackets: the Emacs layer is the keymap and the mirror
the history), `host/page-app.js` (`CK` and the bindings' callers).
`host/build.sh` fetches webview (at a pinned commit) and the CodeMirror
packages (`npm ci` from a committed lockfile, `esbuild`; node 26 is on the
machine; the bundle's sha256 is recorded and checked -- see Risks), builds
the two dylibs, inlines the bundle and writes
`build/host-frontend/page.html`.  Network at build time only; the page is
self-contained.

## Files

```
host/build.sh              the dylibs and the page (macOS today); pins webview, checks the bundle
host/package.json          the CodeMirror packages ...
host/package-lock.json     ... locked, installed with npm ci
host/clamacs-host.m        the shim
host/page-head.html        layout and palettes
host/page-entry.mjs        the CodeMirror bundle's entry
host/page-app.js           CK.* and the bindings
host/run.sh                clamiga --heap 32M --non-interactive --load lisp/clamacs.lisp -- files
lisp/json.lisp             pure: the JSON reader and the JS string writer
lisp/textmirror.lisp       pure: the text model (from tests/fake-frontend.lisp)
lisp/mailbox.lisp          pure: call-in-editor / drain, wake as a parameter
lisp/frontend-host.lisp    the frontend: the host editor and document, the page
lisp/transport-host.lisp   the editor's own port over TCP; the wire on the self transport
lisp/transport-tcp.lisp    the wire to a clamiga over TCP (phase H5)
tests/test-json.lisp       the reader and writer
tests/test-textmirror.lisp the model, shared with the fake
tests/test-host.lisp       the frontend with the page stubbed (the batch buffer read back)
tests/test-transport-host.lisp  the port over a real socket
verify/host/drive.lisp     the acceptance run, over the port
verify/host/run-drive.sh   builds, starts the editor, runs the drive, checks the log
verify/host/host-keys.sh   the differential smoke run: keys through the page
```

`lisp/load.lisp` keeps its lists; `lisp/clamacs.lisp` binds
`*clamacs-frontend-files*` to `("frontend-host" "transport-host")` when
`:amigaos` is not on `*features*`, so `tests/run-tests.lisp` (which loads
no frontend) and the release script (which names the MUI files) are
untouched.  The three pure files join `*clamacs-pure-files*`;
`tests/fake-frontend.lisp` shrinks to the recorder around `textmirror`.

## Phases -- one session each

Each phase is a commit in the `clamacs` submodule that passes `make
test` (which grows with every phase) and, from H2 on, the host drive;
the superproject's pin is bumped when a phase lands.  Every phase ends
with the memory note updated.

### H0 -- the ground: model, JSON, mailbox, shim, page skeleton

- `lisp/textmirror.lisp` from the fake's text access, editing, motions,
  undo and search; the fake frontend uses it; `tests/test-textmirror.lisp`
  from the cases `test-commands.lisp` already implies, plus boundaries
  (empty text, the last line, page motion at the ends).
- `lisp/json.lisp` + `tests/test-json.lisp` (nested arrays, escapes,
  `\uXXXX`, UTF-8 above 255 → `?`, the writer's escaping).
- `lisp/mailbox.lisp` extracted from `frontend-mui.lisp`, the MUI
  frontend using it (the FS-UAE smoke run `run-lisp-editor.sh` is that
  change's gate).
- `host/clamacs-host.m`, `host/build.sh` (webview clone at a pinned
  commit, the shim, the esbuild bundle from a lockfile with its checked
  sha256, the page), `host/page-head.html`, `host/page-entry.mjs`,
  a `page-app.js` that makes one view and talks to the bindings.
- Done when: `make test` green, `host/build.sh` produces the two dylibs
  and the page, and a `verify/host/smoke.lisp` run (`--eval`) opens the
  window, gets `clamacsReady`, asks the shim for a beep and the frame,
  and terminates -- unattended, `SMOKE: PASS` as the last line.

### H1 -- the document window

- `lisp/frontend-host.lisp`: `host-editor`, `host-document` over the
  mirror, the key decoder, the batch buffer, every `doc-*` generic of
  `frontend.lisp`, `minibuffer.lisp` and `files.lisp`; `run-loop` with
  the stepping shim; `start` / `run`; tabs, the status line, the echo
  area, the minibuffer, colouring, the paren highlight, `doc-ask` and
  `doc-ask-file` through the shim, the close hook.
- `tests/test-host.lisp`: the decoder (every named key, Ctrl and Alt
  spellings, Alt+Shift+comma = `M-<`, Cmd keys refused), a document driven
  through `clamacsKey` with the page stubbed, reading the batch back
  (`applyEdit` after a self-insert, `setColours` after RET, `openMini`
  after `M-x`).
- `verify/host/host-keys.sh`: the host twin of `run-lisp-editor.sh` --
  `lisp-editor-keys.lisp`'s lines injected through the page
  (`simulateKey`), the buffer saved with `C-x C-s`, closed with `C-x k`
  (the last tab's close is the exit), the file compared with the fake
  frontend's text.
- Done when: the editor is usable by hand on a file (the user tries the
  window), and `host-keys.sh` passes unattended.

### H2 -- the port, the wire on the self transport, the drive

- `lisp/transport-host.lisp`: the listener and its threads, the verbs
  through the mailbox, the framing, and the `AUTH` gate of "Who may
  connect" (loopback bind, `--bind`, the 0600 token and port files);
  `tests/test-transport-host.lisp` over a real loopback socket with the
  fake editor, including the refused connections (no `AUTH`, wrong token,
  oversized or silent first frame) and the file modes.
- The wire made on the self transport at `start`; `*self-transport-maker*`
  answers it.
- `verify/host/drive.lisp` + `run-drive.sh`: the editor checks
  (`GETFILE` ... `TAB indented`), the menu strip and Buffers legs, the
  window snapshot (a second editor started against a written layout file,
  read back over ITS port), then the integration, introspection, REPL,
  debugger and inspector legs of `drive.rexx` against the editor's own
  image; the same `OK` lines, the same `want` lists minus the Amiga-only
  ones.  `intro.lisp`, `errors.lisp`, `eval.lisp` reused as fixtures.
- Done when: `run-drive.sh` passes unattended on the Mac.

### H3 -- the dock: diagnostics, debugger, inspector, REPL as tabs

- The panels in the page and their bindings; `editor-show-diagnostics`,
  `editor-select-diagnostic`, the six `editor-debugger-*`,
  `editor-inspector-open`; the REPL and the scratch buffers as dock tabs;
  the splitter, `setDock`, `clamacsDockResized`, `editor-aux-windows`.
- `tests/test-host.lisp` grows the panel calls (what the batch carries
  after `DEBUGGER 1 ...` through `port-raw-command`).
- The drive's debugger and inspector legs now also check the panels'
  state through `EVAL (clamacs::host-panel-state ...)`.
- Done when: the drive's REPL / debugger / inspector legs pass with the
  panels open, and the user has clicked through a debugger session.

### H4 -- polish to par

- The menu bar in the page from `menu-entries`, enable states, the
  Buffers menu, About (toolkit lines: the webview and WebKit versions),
  the HyperSpec through the shim.
- Window placement from the layout file, `clamacs-snapshot-windows`
  writing `~/.clamacs-windows.cfg`, `GETWINDOW`.
- Light and dark palettes, the fixed font, the tab close markers, the
  modified marker, the arglist in the status line, the beep.
- Shutdown: every callback freed, both dylibs closed, the listener
  stopped, nothing left (`CLAMIGA_MEM_DIAG=1` clean on the host too).
- Done when: every item of "What parity means" 1-7 and 10 is ticked
  against the MUI frontend, the drive passes PHASE 5 in full, and
  `README.md` + `CLAUDE.md` describe the host editor.

### H5 -- the second process: TCP

- cl-amiga: `lib/dev-tcp.lisp` (R1) with its `AUTH` gate, loopback
  default and `:host` / `:token` arguments, `tests/test_dev_tcp.sh` (with
  the refusal cases of "Who may connect"),
  `tests/amiga/dev-tcp-tests.lisp` (bsdsocket.library on the Amiga: the
  same server, so a Mac Clamacs can drive an Amiga clamiga; the emulator
  run is over loopback, the LAN leg is checked by hand once), README
  section.  Gates: `make test`, `make test-gc-stress`, `test-amiga`.
- clamacs: `lisp/transport-tcp.lisp`, `tests/test-transport-tcp.lisp`
  (against a `dev-tcp` server in the test process; a connection to it
  with a wrong or missing token gets `wire-reply ... :lost t` and never
  a reply), the Clamiga menu's
  Connect / Start clamiga live on the host, `run-drive.sh` grows a leg
  against a second clamiga process (the "editor answered while a load was
  in flight" criterion).
- Done when: the drive passes against a separate clamiga, and
  `Talk to the Editor Itself` / `Talk to clamiga` switch between the two.

### H6 -- the other hosts and the image (when asked)

- Linux: GTK entries in the shim, `build.sh` with webkit2gtk; Windows:
  WebView2, Win32 dialogs, MSYS2 build.  Each a session with the box at
  hand.
- A host `clamacs.img` (`--image`) and a `Clamacs.app` / launcher.

## Runtime items (commits in cl-amiga, each under every gate)

- **R1** `lib/dev-tcp.lisp`: the development port over TCP (H5), with the
  `AUTH` gate, the loopback default, the entropy-drawn token and the
  0600-from-the-start file creation of "Who may connect" (the editor's
  own port needs the last two too: a file `open` with a mode and a
  random-bytes primitive are runtime pieces if the shim does not offer
  them).
- **R2** (only if stepping proves insufficient) a GC-safe foreign call:
  `ffi:call-foreign ... :gc-safe t` enters the safe region for the call's
  duration, and a callback invoked on a thread that is in one leaves it
  on entry and re-enters on return.
- **R3** `ext:run-program` (or the shim's `posix_spawn`) for
  `transport-launch` on the host (H5).

## Risks and what decides them

- **Alt as Meta on macOS**: Option composes characters (`Option-f` is
  `ƒ`), so the decoder derives the base character from `code` when Alt
  is held (US layout table for punctuation; letters and digits by code).
  A non-US layout gets letters right and punctuation wrong under Alt --
  documented; a preference for "right Option types" can follow.
- **A modal dialog inside a binding**: `doc-ask` runs `NSAlert`'s nested
  loop while a binding callback is on the stack.  Fine for the alert;
  the mailbox is not drained meanwhile (`*in-modal*`).  If WebKit refuses
  to deliver a `webview_return` across it, the requester moves to the
  page (an HTML dialog with a Lisp-side continuation) and `doc-ask`
  becomes a prompt-style continuation for the two callers that need it
  (`release-text`, `close-document`).  Decided in H1.
- **Large pastes**: `clamacsUpdate` carries the pasted text through a
  JSON argument; `ffi:foreign-to-string` reads to the NUL since
  a0188bd6.  A 1 MB paste is a 1 MB string copy: acceptable.
- **Line/column scans on the mirror** are O(n) per key (a
  `count #\Newline`); a 5,000-line file is a 150 KB scan per keystroke on
  a host, invisible.  A line-start index cache is the fix if it ever
  shows.
- **esbuild / npm at build time**: `build.sh` needs the network once;
  `build/host-frontend/` is gitignored, the page is not committed.  A
  vendored bundle is the fallback if the fetch becomes a problem.
- **Unpinned upstream inputs**: the bundle is inlined into a page that
  runs in the editor's process and the webview library is built into a
  dylib it loads, so what `build.sh` fetches is code the editor runs.
  Every fetch is pinned and checked, as `spike/host-webview/build.sh`
  does: the webview clone is checked out at a recorded commit (never
  HEAD), the npm packages are installed from a committed lockfile
  (`npm ci`) and the CodeMirror bundle's sha256 is recorded and compared
  -- a mismatch removes the file and stops the build.  Moving a pin is a
  commit that says why.
