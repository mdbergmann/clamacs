# Clamacs

An Emacs-flavoured Common Lisp IDE for AmigaOS 3 and MorphOS: a native MUI
editor with Emacs key handling that talks to a running
[CL-Amiga](https://github.com/mdbergmann/cl-amiga) (`clamiga`) over its ARexx
port — load, compile, evaluate, a REPL, a debugger and an inspector in
their own windows.

**Status:** the editor with Lisp mode, a menu strip and its own ARexx port,
introspection (arglist, completion, jump to
definition, describe, apropos, macroexpand) asked from clamiga, a REPL
window (`C-c C-z`) fed by a REPL thread in clamiga that streams output,
asks the editor for `read-line` input and can be interrupted, a debugger
window that opens when a form signals an error -- typed at that REPL or
evaluated from a buffer with `C-c C-c` / `C-x C-e` (restarts,
backtrace, locals, eval in a frame; the REPL thread stays parked on the
erring stack until a restart is chosen), and an inspector window
(`C-c I`) with a parts list and a Back button.  The editor is written in
Common Lisp and runs as a clamiga instance of its own (`lisp/`,
`specs/clamacs-lisp.md`); the C editor under `src/` is its predecessor
and behaviour reference.  See `CLAUDE.md` for the design and the phase
plan, and `specs/clamacs-ide.md` for the full one.

## Starting the editor

```
clamiga --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- file.lisp ...
```

The files come after `--` (a bare argument before it is something for
clamiga to load); without any, one unnamed Lisp buffer opens.  The binary
release starts the same editor from a heap image instead (its `Clamacs`
icon, or `clamiga --image clamacs.img --non-interactive --eval
"(clamacs::run)" -- file.lisp`), which skips the load.

## The init file

`S:.clamacsrc` is loaded before the first window opens, in the `CLAMACS`
package, so it can define commands and bind keys with the editor's own
forms:

```lisp
(define-command insert-date (doc arg)
  (declare (ignore arg))
  (doc-insert doc (multiple-value-bind (s m h d mo y) (get-decoded-time)
                    (declare (ignore s m h))
                    (format nil "~D-~2,'0D-~2,'0D" y mo d))))
(bind-key "C-c d" 'insert-date)            ; :global (the default), :lisp or :repl
```

A command is any function of the document and the numeric argument written
against the frontend protocol (`lisp/frontend.lisp`, `lisp/commands.lisp`
are the examples); `M-x`, the menu and the ARexx port's `EVAL` all find it
by name.  `bind-key` refuses a key sequence that clashes with a binding
already there (`C-c d x` after `C-c d`, or `C-x` on its own): a key is a
command or a prefix, not both.  Binding the same keys again replaces the
earlier binding.

## Files and evaluation

**Project > New** opens an empty Lisp buffer in a window of its own;
`C-x C-f` (Open...) with a name no file has yet does the same under that
name, as in Emacs, and `C-x C-s` writes it.  Lisp mode -- colouring, paren
matching, indentation -- follows the file name (`.lisp`, `.lsp`, `.cl`,
`.asd`); an unnamed buffer is always in Lisp mode.

`C-c C-c` (Eval Defun), `C-x C-e` (Eval Last Sexp), `C-c C-r` (Eval
Region) and `C-c C-e` (Eval Expression...) run the form on clamiga's REPL
thread: what it prints goes to the `*clamacs-repl*` transcript, its
values to the buffer's echo area, and an error opens the debugger window
with the erring stack still there.  The REPL window is opened and
attached the first time you evaluate; `C-c C-b` interrupts.  When clamiga
was restarted, the next evaluation finds the new one and attaches the
REPL again by itself (the echo area says `clamiga found on CLAMIGA`).
Loading (`C-c C-k`, `C-c C-l`) stays what it was: every error in the file
becomes a row in the diagnostics window.

## Screenshots

Taken on a Vampire V4 (AmigaOS 3.2, MUI 3.8, 1280x720) driving the
clamiga from the binary release.

A file loaded with `C-c C-k` and the `*clamacs-repl*` window (`C-c C-z`)
talking to it, the clamiga console at the bottom:

![The editor and the REPL window](docs/screenshots/editor-repl.png)

An error signalled at the REPL prompt parks clamiga's REPL thread and opens
the debugger window: condition, restarts, backtrace, the locals of the
selected frame and an eval-in-frame line:

![The debugger window](docs/screenshots/debugger.png)

`C-c I` evaluates a form and opens the inspector on its value; a part
descends, Back comes up:

![The inspector window](docs/screenshots/inspector.png)

Loading a file with mistakes fills the diagnostics window; a click on a row
or ``C-x ` `` puts the cursor on the offending line, with the message in the
echo area:

![The diagnostics window](docs/screenshots/diagnostics.png)

## Window positions

Arrange the windows, then pick **Windows > Snapshot Windows** (or `M-x
clamacs-snapshot-windows`): the position and size of every open window is
written to `ENVARC:Clamacs/windows.cfg` (and `ENV:`), and the windows come
up there from then on — the REPL, the debugger, the inspector, the error
list, and the file windows in the order they are opened (the first file of
a session where the first file window was, and so on). The file is plain
text, one `role left top width height` line per window; edit it or delete
it to start over. Snapshotting again only updates the windows that are
open at the time.

## Layout

```
lisp/                      the editor: the Emacs layer, Lisp mode, the wire to clamiga,
                           the REPL/debugger/inspector, the menu table and window
                           positions -- all pure Lisp over a frontend protocol --
                           and frontend-mui.lisp, the one file that talks to MUI
tests/                     host tests for the pure modules (tests/run-lisp-tests.sh),
                           on a fake frontend and a fake transport
scripts/                   the heap image the release starts from (save/verify)
verify/realamiga/          unattended FS-UAE run, driven through the ARexx port;
                           sendkey.c injects real key events through input.device
src/                       the C editor the Lisp one was ported from (frozen)
docs/memory.md             what the editor costs on an 8 MB machine
vendor/texteditor/         submodule: TextEditor.mcc (amiga-mui), pinned to release 15.56
```

Clamacs is a git submodule of [cl-amiga](https://github.com/mdbergmann/cl-amiga)
(checked out at `cl-amiga/clamacs`) and ships in its binary release next to
the `clamiga` binaries. The runtime it drives is the superproject: build
`clamiga` there, and make runtime changes (new `EXT.DEV` commands, compiler
fixes) as commits there under its gates.

## Building and testing

```
make test                        # host tests: the C core and the Lisp editor's pure modules
make test-lisp                   # the Lisp editor's tests alone (CLAMACS_TEST=menu for one file)
make test-lisp-gc-stress         # the same with a compaction at every allocation
make -f Makefile.cross amiga     # cross-compile build/cross/clamacs (and sendkey)
make -f Makefile.cross test-lisp-amiga # the Lisp editor through drive.rexx in FS-UAE
make -f Makefile.cross test-amiga # the C editor's unattended FS-UAE run
make -f Makefile.mos             # MorphOS: native build on the box, see the file's header
```

The Lisp editor's tests run everything but `frontend-mui.lisp` on the host
under cl-amiga's `build/host/clamiga`: the commands, the minibuffer, the
wire, the REPL, the debugger, the menu and the window positions all work
against a fake frontend and a fake transport, so a failing assertion costs
a second instead of an emulator boot.  The FS-UAE run then drives the real
thing through its ARexx port with the same script that gated the C editor.

The FS-UAE run uses the clamiga runtime from the superproject (the
`CLAmiga:` volume; the integration leg reads its `build/cross/clamiga`, so
run `make -f Makefile.cross amiga` in `cl-amiga` first). The Workbench image
(with MUI and TextEditor.mcc) and `FS-UAE.app` are not tracked in git; the
run takes them from the superproject's `verify/realamiga/` too. A standalone
clone falls back to a `cl-amiga` checkout next to it. Override with
`EMU_DIR` (the emulator assets) and `CLAMIGA_DIR` (the clamiga runtime).

## Requirements on the Amiga

MUI 3.8 or newer (`muimaster.library` 19+) and `TextEditor.mcc` 15.29 or
newer installed in `MUI:Libs/mui/`; the editor checks both at startup.
Verified against MUI 3.8 and TextEditor.mcc 15.56.

**Help > Common Lisp HyperSpec** (`M-x clamacs-hyperspec`) opens the
HyperSpec in your browser through `openurl.library` — part of MorphOS, and
on AmigaOS 3 the [OpenURL](https://github.com/jens-maus/libopenurl)
package (Aminet `comm/www/OpenURL.lha`). Without it the editor shows the
address in a requester instead.

`vendor/texteditor` is used for its headers, documentation and demo only —
the editor subclasses the *installed* `TextEditor.mcc` at runtime and never
builds the class. Its `include/` directory also carries `libraries/mui.h`,
the muimaster protos and the SDI headers, so a MUI application compiles
against it without the MUI developer kit.

## Setup

Clamacs carries no cross toolchain of its own; it builds with the one
cl-amiga installs (`tools/setup-toolchain.sh` there, one level up from this
directory):

```
git clone --recursive https://github.com/mdbergmann/cl-amiga.git
cd cl-amiga && tools/setup-toolchain.sh        # once, for both projects
cd clamacs && make -f Makefile.cross amiga
```

A standalone clone (`git clone --recursive https://github.com/mdbergmann/clamacs.git`)
points the build at an existing install instead:

```
make -f Makefile.cross amiga TOOLCHAIN=/path/to/cl-amiga/tools/m68k-amigaos-gcc/prefix
```

The MorphOS build is native: `make -f Makefile.mos` in a checkout on a
MorphOS machine with the SDK's gcc (no PPC cross-compiler exists for the
Mac). MorphOS ships `TextEditor.mcc`, so nothing else is needed there.
