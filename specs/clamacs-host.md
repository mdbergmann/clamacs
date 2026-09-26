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
  (`isComposing`), a dead key without Alt (with Alt, macOS reports
  Option-N/E/I/U/` as `Dead`, and the decoder reads the letter from
  `code`: `M-n`), keys with the Command key (the host's Amiga key: left
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
the loop runs it.  The wake is the shim's `clamacs_host_wake`: an
application-defined `NSEvent` posted from any thread, which ends the
step in progress so the loop returns to Lisp and drains -- the drain
stays in `run-loop`, on no nested stack.  (`webview_dispatch` would
serve the same purpose, but its block runs inside whatever loop is
current, a modal dialog's included; H0 chose the event.)  While a modal
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
| `int clamacs_host_step(void *w, int ms)` | one turn of the event loop: wait up to `ms` for the first event, deliver what is pending, return |
| `void clamacs_host_wake(void)` | from any thread: end the step in progress (the mailbox's wake) |
| `int clamacs_host_ask(void *win, const char *text, const char *buttons)` | `doc-ask`: an `NSAlert`, buttons `"Save\|Discard\|Cancel"`, answers the index, -1 for Escape |
| `char *clamacs_host_ask_file(void *win, const char *title, int save, const char *initial)` | `doc-ask-file`: `NSOpenPanel` / `NSSavePanel`, a malloc'd path or NULL |
| `void clamacs_host_free(void *p)` | frees it |
| `void clamacs_host_beep(void)` | `NSBeep` |
| `int clamacs_host_clipboard_set(const char *text)` | `doc-clipboard-copy` |
| `int clamacs_host_open_url(const char *url)` | `doc-open-url`: `NSWorkspace` |
| `void clamacs_host_get_frame(void *win, int32_t out[4])` / `set_frame(win, l, t, w, h)` | `doc-geometry`, `layout-place` (top-left origin, flipped from Cocoa's) |
| `void clamacs_host_on_close(void *win, void (*fn)(void *), void *arg)` | the window's close button asks the editor (`save-buffers-kill-emacs`) instead of ending the loop; a delegate that forwards everything else to webview's |
| `const char *clamacs_host_toolkit(void)` | the toolkit line for About ("Cocoa/WebKit on macOS 27.0.0") |

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

Protocol, both directions:

```
request:  "<n>\n" then n characters: the command line  (VERB argument)
reply:    "<rc> <n>\n" then n characters: the text
```

`<n>` counts **characters**, and the bytes are **UTF-8**: the host
runtime's socket streams encode every character above 127 (and decode
on the way in), so `(length text)` is what a Lisp end writes and reads.
The editor's text is 8-bit, so a Latin-1 character is one in `<n>` and
two bytes on the wire; a client in another language decodes before it
counts, and characters above 255 are outside what the editor can hold.
`write-wire-text` sends every string as UTF-8 whether it is an 8-bit or a
wide one (`write-string` of an 8-bit string alone would put out one byte
per character); `tests/test-transport-host.lisp` reads a reply back with
`read-byte` and sends a request with `write-byte`.

No quoting, no escaping, newlines inside the text are the text's; `rc`
is the ARexx ladder of `wire.lisp`.  A closed connection is the port
being gone (`wire-reply ... :lost t`).

The first request on every connection is `AUTH <token>`.  The reply is
`0 2\nOK`; anything else -- a wrong token, a different verb first, no
frame within 5 seconds, a length above the 1 KB an `AUTH` needs -- is
answered `20 <n>\nauthentication required` (nothing of the request is
run, echoed or logged) and the connection is closed.  `AUTH` is not a
verb of `port.lisp` or `ext.dev`: the listener owns it, so no command
can be reached around it.  After `AUTH` a command longer than 16 MiB
(`*host-frame-limit*`) is answered `20 <n>\nERROR: the command is too long`, its body
is read and dropped, and the connection stays (leaving the body on the
wire would have it read as the next header).

### Who may connect

Both listeners -- the runtime's `ext.dev.tcp` and the editor's own port --
keep the same three rules:

- **Bind**: 127.0.0.1.  The only ways to another address are the
  runtime's `:host` argument and the editor's `--bind ADDR` (after `--`),
  each spelled out by whoever starts the process: no default, no
  environment variable and no config file turns it on, and neither
  accepts a wildcard address.  (Since H5 `EXT:SOCKET-LISTEN` takes the
  one dotted-quad address to bind -- R1 -- so `--bind ADDR` listens
  there; a wildcard, a missing address and an address no interface has
  are refused with a message and no port: `parse-command-line` passes
  every spelling on and `host-port-start` judges, so an option that was
  not honoured is never taken for one that was not given.)  A Mac
  driving an Amiga clamiga over the
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
  `$XDG_RUNTIME_DIR` instead, and the editor starts without its port,
  saying so, if it can do neither.  A token `start` drew itself is
  printed to that clamiga's own standard output, once; one it was given
  (`:token`) is not.

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

The **page itself is pure ASCII**, and `host/build.sh` fails the build
otherwise.  Found in H0: `ffi:foreign-string` writes one byte per
character and takes narrow strings only, while a file read with the
default external format decodes UTF-8 into code points -- so a page with
an arrow in a CodeMirror doc comment reached WebKit as invalid UTF-8,
`stringWithUTF8String` answered nil, and the window showed an EMPTY page
with no error anywhere.  esbuild's `--charset=ascii --minify-whitespace`
makes the bundle ASCII (strings escaped, comments gone; the licences are
in the packages), and the Lisp reads the page with `:external-format
:latin-1`, byte for byte, so the file is what WebKit gets.  The page
reports its own failures: `window.onerror` and unhandled rejections go
to the `clamacsLog` binding, registered before the bundle runs.

## The interface between the page and the Lisp

### Bindings (page → Lisp, `webview_bind`; arguments a JSON array)

| Binding | Arguments | Meaning |
|---|---|---|
| `clamacsReady` | `userAgent` | the page is up: Lisp builds the menus, opens the first documents |
| `clamacsLog` | `text` | a JavaScript error or rejection in the page; Lisp reports it |
| `clamacsKey` | `docId, key, code, ctrl, alt, meta, shift, target` | a key in a view (`target` "text") or the input line ("mini") |
| `clamacsUpdate` | `docId, [[from, to, inserted], ...], head` | a change CodeMirror made on its own |
| `clamacsCursor` | `docId, head, anchor` | the selection moved on its own (mouse) |
| `clamacsMiniInput` | `text` | the input line changed on its own (paste) |
| `clamacsActivate` | `docId` | a tab was clicked / a view focused |
| `clamacsCloseTab` | `docId` | a tab's close button |
| `clamacsMenu` | `index` | a menu item picked (the table index): `menu-pick` on the active document, refused when the item is dimmed by now |
| `clamacsBuffers` | `n` | a Buffers-menu item picked, by its position in what `setBuffers` last gave (the bar counts) |
| `clamacsDiagPick` | `row` | a diagnostics row selected |
| `clamacsDbgFrame` / `clamacsDbgFrameOpen` / `clamacsDbgRestart` / `clamacsDbgEval` / `clamacsDbgButton` | `n` / `n` / `n` / `text` / `"continue"\|"abort"` | the debugger panel |
| `clamacsInspPart` / `clamacsInspBack` | `n` / -- | the inspector panel |
| `clamacsPanelClose` | `"diagnostics"\|"debugger"\|"inspector"` | a panel's tab closed (the debugger's is `debug-window-closed`: the REPL stays parked) |
| `clamacsDockShown` | `"diagnostics"\|"debugger"\|"inspector"` | a panel's tab clicked, the page now displays it (a tool buffer's tab is `clamacsActivate`): the dock's mirror follows, so a later hide of the displayed item picks the same successor on both sides |
| `clamacsDockResized` | `height` | for the snapshot |
| `clamacsPanels` | `json` | what the menu bar (`menu`: the item count, the dimmed indices, the Buffers lines spelled as the `BUFFERS` verb spells them), the dock and the panels show, after every change (one report per batch): kept verbatim for `host-page-panels`, which the drive reads through `EVAL` beside `host-panel-state`, the editor's own account -- so the run proves the page did what it was told, not only that Lisp said it |
| `clamacsTick` | -- | every 300 ms: `arglist-idle` on the active document |

Every binding runs on the main thread inside `webview_dispatch`'s turn;
its handler is bracketed by the batch flush and `after-command`
(`menu-update`, a quit carried out by the loop).

### Calls (Lisp → page, `webview_eval` of `CK.<name>(...)`)

`makeDoc(id, name, kind)` (`kind` "source" or "tool"), `removeDoc(id)`,
`activateDoc(id)`, `setText(id, text)`, `applyEdit(id, from, to, text,
head)`, `setPoint(id, head, anchor)`, `colour(id, records)` (a record
`[y, [[x0, x1, kind], ...]]` replaces line `y`'s runs, `[y, x0, x1,
kind]` paints one run over what is there, `kind` false clears),
`setTitle(id, title)`, `setModified(id, flag)`,
`setStatus(text)`, `setEcho(text)`, `openMini(label, text)`,
`closeMini()`, `setMiniText(text)`, `setMiniLabel(label)`,
`setMenus(json)`, `menuEnable(index, flag)`, `setBuffers(json)`,
`showDiagnostics(rows, open)`, `selectDiagnostic(row)`, `dbgOpen(level,
condition, restarts, hasContinue)`, `dbgClose()`, `dbgRaise()`,
`dbgFrames(rows)`, `dbgSelectFrame(n)`, `dbgLocals(rows)`, `inspOpen(type,
depth, object, parts)`, `setDock(height)`, `terminate()` (the page asks
nothing further).

Colours are mark decorations in a `StateField`, mapped through every
change so they travel with the text as SetBlock's do; Lisp keeps none
across entries.  Within one entry `doc-colour`'s runs are coalesced: the
whole-line clear `colour-one-line` starts with opens a line record the
later runs are painted into, and a run on a line not cleared in that
entry is a run record -- so `colour-all` is one call with one record per
line.  The page applies a call's records in order, the run records oldest
first and the line records after them, so a range cleared and painted
again in one entry (the paren highlight) ends up painted.  Token kinds map
to CSS classes (`ck-comment`, `ck-string`, `ck-char`, ...,
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
tests/test-mailbox.lisp    post, drain, wait, close, across threads
tests/test-host.lisp       the frontend with the page stubbed (the batch buffer read back)
tests/test-transport-host.lisp  the port over a real socket
tests/test-transport-tcp.lisp   the wire to a dev-tcp server in the test process, and a real launch
verify/host/smoke.lisp     H0's ground end to end (the page, the shim, the wake)
verify/host/run-smoke.sh   builds, runs it, reads the verdict; GCSTRESS=1 under gc-stress
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
- **Done 2026-09-25** (branch `host-h0`): 536 Lisp tests, the FS-UAE
  `run-lisp-editor.sh` run green on the MUI frontend over the shared
  mailbox, `run-smoke.sh` green (also `GCSTRESS=1`).  What it found:
  the ASCII rule above; and runtime item R0 -- `ffi:close-library` on
  the host was the AmigaOS stub (fixed in cl-amiga with a regression
  test, needed before the smoke can close its libraries).

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
- **Done 2026-09-25** (branch `host-h1`): 562 Lisp tests (23 for the
  host frontend), `host-keys.sh` green (also `GCSTRESS=1`), `run-smoke.sh`
  still green on the H1 page.  What it settled: the requester stays
  native -- an `NSAlert` raised from inside a binding callback (`C-x k`
  on a modified buffer) ran its loop, was dismissed, and the callback's
  `webview_return` and the page's later calls went through; the mailbox
  wake from a worker thread ends the step as designed.  What it found:
  a command's edit calls no hook (the fake's `type-keys` only notes the
  widget's own inserts), so the host notices an edit by the mirror's
  text identity after every key and every entry
  (`note-text-if-changed`), which is what MUI's ContentsChanged hook
  does; and `clamacsUpdate`'s changes come in the coordinates of the
  text before them, so they are applied in order with a running delta
  as one `mirror-replace` each.  The input line edits itself for plain
  keys (the `input` event reports, `clamacsMiniInput`) and sends
  Control, Alt, Escape, Tab, Enter and every synthetic key to Lisp, so
  the port's `KEY` and the harness type into a prompt through
  `doc-minibuffer-edit`.

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
- **Done 2026-09-25** (branch `host-h2`): 585 Lisp tests (17 for the
  port, on a real loopback socket with the fake editor behind a pumped
  mailbox), `run-drive.sh` green with 124 `OK` lines -- the count the
  Amiga drive reached on 2026-09-20 -- and `run-smoke.sh` / `host-keys.sh`
  still green.  `verify/host/drive.lisp` is a client of its own (forty
  lines of protocol, none of the editor's code), so the run proves the
  port from the outside; a second editor comes up where the layout file
  says, read over ITS port with a `TMPDIR` of its own.  What it settled:
  the token is read from `/dev/urandom` and the two files are created
  under a `umask` of 077 (one libc call through the FFI; the runtime
  needed nothing), their mode checked by the script with `stat`; every
  limit a connection thread reads is a slot of the port, copied from the
  special when it starts, since a dynamic binding is the starting
  thread's alone.  What it found: the host editor had no methods for the
  debugger and inspector generics yet, and a "no applicable method" out
  of `editor-debugger-close` aborted the REPL window's close before the
  document was marked closing -- the editor could not quit; the
  `host-editor` now carries a method for every panel generic (no-ops
  until H3), pinned by `tests/test-host.lisp`.  Two rules above bent to
  what exists: `--bind` is parsed and refused (no port, a message) until
  the runtime can bind a named address (R1, phase H5), and without a
  private directory for the files the editor starts *without its port*
  and says so, rather than not at all.

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
- **Done 2026-09-25** (branch `host-h3`): 598 Lisp tests (38 for the host
  frontend: the dock's tabs, the three panels driven through
  `port-raw-command` and the fake transport with the batch read back,
  the dock's height from the layout file and the splitter, the snapshot
  with `dock` and `errors` lines), `run-drive.sh` green with 152
  `OK` lines (124 in H2) -- the debugger, inspector and diagnostics legs now check
  the panels on both sides of the page boundary, and the snapshot leg
  the `errors` and `dock` lines the Amiga leg checks -- and `run-smoke.sh`
  / `host-keys.sh` still green.  What it settled: a tool buffer
  (`tool-document-p`) is a tab of the dock and the panels are tabs
  beside it, one displayed item per region and one `active` item
  holding the keyboard; the dock's rule on both sides is that showing an
  item opens the dock and hiding the displayed one shows the next open
  item or collapses it -- what Lisp does not show itself the page tells
  (`clamacsActivate` for a tool buffer's tab, `clamacsDockShown` for a
  panel's), and which documents are dock tabs is decided once, when the
  tab is made (`hdoc-dock-p`), because a saved tool buffer stops being a
  `tool-document-p` while its tab stays in the dock.
  `editor-aux-windows` answers the dock (the
  bottom `dock-height` pixels of the window's frame) under the role
  `dock` and each open panel under the MUI window's role with that frame,
  so `clamacs-snapshot-windows` keeps every role the Amiga file has, and
  `layout-place "dock"` sizes the dock at startup.  The debugger's and
  the inspector's rows and selection are read off their structs
  (`debugger-frame` is set by the panel's click and by `M-x
  clamacs-debugger-frame` alike); the host editor mirrors only what the
  structs do not hold -- the open flags and the diagnostics selection.
  The page's report (`clamacsPanels`, above) came out of the drive's
  needs: without it the run could only check what Lisp said.

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
- **Done 2026-09-26** (branch `host-h4`): 603 Lisp tests (43 for the host
  frontend: the table sent once and every item's state after it, only
  the changed state after an edit, a pick running its command on the
  active document and a dimmed pick refused, About's lines, the Buffers
  menu remade as buffers come and go and its tick moves, a pick by
  position and by label, an editor without the table syncing nothing),
  `run-drive.sh` green with 158 `OK` lines (152 in H3): the menu leg
  now checks the page's own menu bar -- Save dimmed and enabled again,
  read from `clamacsPanels` -- beside the editor's `MENU ... STATE`, the
  Buffers leg the page's lines and tick, and About's text names the
  three toolkit lines with real versions (`webview 0.12.0, WebKit
  605.1.15`); `run-smoke.sh` / `host-keys.sh` still green.  What it
  settled: the page draws the menu bar from the table (`CK.setMenus`
  once at start, before the first document), `menu-update` after every
  entry sends `menuEnable` for what changed and `setBuffers` when the
  entries or the tick changed -- the MUI frontend's two syncs -- and a
  pick is the table index (`clamacsMenu`, refused when the item is
  dimmed by now) or the position in the Buffers menu (`clamacsBuffers`);
  an editor the table was never sent to (the tests' plain one, as an
  MUI editor whose strip could not be built) syncs nothing and answers
  `BUFFERS` from the model.  Items 1-7 and 10 of "What parity means"
  tick against MUI; the HyperSpec, the requesters, the palettes, the
  markers, the arglist and the beep were in place since H1-H3.  What it
  found: the shutdown criterion.  `MEMTRACK=1 run-drive.sh` (both editors
  under the superproject's `DEBUG_MEM_TRACK` build, the leak report
  checked) showed each editor leaving 3-4 worker threads' stacks
  behind -- the port's listener and connection threads, the self
  transport's worker, the REPL thread: threads that had *finished* but
  were only ever polled with `thread-alive-p`, never joined, so neither
  `join-thread` nor the wrapper's finalizer (their wrappers stay
  reachable from the port struct) freed them, and the make-thread
  reaper runs only when the table is full.  The fix is the runtime's:
  `cl_thread_shutdown` reaps finished, unclaimed workers before the
  registry goes (cl-amiga, with a scenario in
  `tests/test_memleak_tracked.sh`), which also covers the MUI editor
  and the runtime's own `%repl-stop` on the Amiga, where those stacks
  were Fast RAM lost per launch.  With it the leak-tracking drive ends
  with `0 block(s), 0 bytes` for both editors.

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
- **Done 2026-09-26** (branch `host-h5`; runtime on cl-amiga's
  `feat/dev-tcp`): the wire's home on the host is `lisp/transport-tcp.lisp`
  -- a client thread with one request in flight posting replies to the
  mailbox, `transport-find-port` a connect attempt (with the token, held
  off for two seconds after a failure since the idle timer and the menu
  ask often), `transport-own-port` the editor's port as
  `tcp:HOST:PORT/TOKEN`, `transport-launch` the start of a clamiga on the
  binary the editor runs on (R3 above), and the editor's exit stopping a
  clamiga it started (`EVAL (ext.dev.tcp:stop)` over the connection; one
  the user started is left alone) -- while the self transport is made on
  the first `Talk to the Editor Itself`.  `tests/test-transport-tcp.lisp`
  (9 tests, 44 in the file's run with the two fixtures it borrows):
  found and answered through the mailbox, no token nothing tried, a
  wrong token refused and the request lost, a clamiga gone and back, the
  REPL attached back over the editor's port (clamiga's REPL thread -- the
  test image's -- connecting to it), the launch of a real second clamiga
  and its stop, the wire starting on TCP with the editor's image on
  demand; `run-drive.sh` grew `leg-start-clamiga` (the menu's Start
  clamiga, the launched flag, no preamble or port file left, the log) and
  runs every Lisp leg against that clamiga (`(find-package :clamacs)` at
  its REPL is `NIL`: a process of its own), the own-Lisp leg is
  drive.rexx's phase 5 (switch, `(room)`, `in-editor`, switch back), and
  the script checks that the started clamiga logged `; clamiga stopped`
  after the editor's exit and, under `MEMTRACK=1`, its leak report.  What
  it settled: `wire-connect`'s question became "No running clamiga was
  found. Start one?" and a failed launch says why
  (`transport-launch-problem`, new in wire.lisp); a `--bind` address is
  honoured now (R1) and `host-port-address` is the bound one.  What it
  found: `ext.dev.tcp:stop` run from a connection thread (`EVAL
  (ext.dev.tcp:stop)`) must leave that connection open for its reply
  (`*connection*`), and a REPL thread whose editor went is stopped by
  its next failing send, never by the server's stop -- in a real clamiga
  the process exit does it.

### H6 -- the other hosts and the image (when asked)

- Linux: GTK entries in the shim, `build.sh` with webkit2gtk; Windows:
  WebView2, Win32 dialogs, MSYS2 build.  Each a session with the box at
  hand.
- A host `clamacs.img` (`--image`) and a `Clamacs.app` / launcher.

## Runtime items (commits in cl-amiga, each under every gate)

- **R0** (done 2026-09-25) `ffi:close-library` on the host: `AMIGA` uses
  `FFI`, so the AmigaOS host stub registered under the same name replaced
  the real `dlclose` entry; `tests/test_ffi.c` pins it.  Two more
  observations from the same hunt, open: `(setf char)` of a character
  above 255 into a narrow string silently stores the low byte, and
  `ffi:foreign-string` answers "argument must be a string" for a wide
  string -- both should say what happened.

- **R1** (done 2026-09-26, cl-amiga branch `feat/dev-tcp`)
  `lib/dev-tcp.lisp`: the development port over TCP (H5), with the
  `AUTH` gate, the loopback default, the entropy-drawn token (or
  `:token`) of "Who may connect", and `ext:socket-listen` taking one
  dotted-quad address to bind (`platform_socket_listen_addr` on the three
  platforms) for `:host` and `--bind`.  `tests/test_dev_tcp.sh` (62
  checks) and `tests/amiga/dev-tcp-tests.lisp`.  The editor's own port
  needed nothing more: `/dev/urandom` and a `umask` around the `open`
  did the last two (H2).
- **R2** (only if stepping proves insufficient) a GC-safe foreign call:
  `ffi:call-foreign ... :gc-safe t` enters the safe region for the call's
  duration, and a callback invoked on a thread that is in one leaves it
  on entry and re-enters on return.
- **R3** (settled 2026-09-26 without a spawn primitive) `transport-launch`
  on the host is `ext:system-command` of a backgrounded shell line
  (`clamiga --non-interactive --load preamble </dev/null >log 2>&1 &`),
  with the token put in the editor's own environment by libc `setenv`
  through the FFI for the child to inherit and taken out again after --
  on no command line, in no file.  What the runtime did add is
  `ext:executable-path` (the running binary as a path another process
  can start it by), so the editor starts the clamiga it runs on.
  `ext:run-program` stays open for another day.

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
  (`release-text`, `close-document`).  Decided in H1: WebKit delivers
  it; the requester is native.  While it is up, bindings that arrive
  (the timer's ticks) are dropped, and the batch is flushed before it
  opens so the page shows the state the question is about.
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
