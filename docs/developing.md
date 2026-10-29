# Developing Clamacs

How to build, test and find your way around the Clamacs sources.  The
user guide is the [README](../README.md); the design notes are
`CLAUDE.md` and the specs under `specs/`.

## Building

Clamacs is a git submodule of [AmiLisp](https://github.com/mdbergmann/amilisp)
(checked out at `amilisp/clamacs`) and ships in its binary release next to
the `amilisp` binaries.  The runtime it drives is the superproject: build
`amilisp` there, and make runtime changes (new `EXT.DEV` commands, compiler
fixes) as commits there under its gates.

Clamacs carries no cross toolchain of its own; it builds with the one
AmiLisp installs (`tools/setup-toolchain.sh` there, one level up from this
directory):

```
git clone --recursive https://github.com/mdbergmann/amilisp.git
cd amilisp && tools/setup-toolchain.sh        # once, for both projects
cd clamacs && make -f Makefile.cross amiga
```

A standalone clone (`git clone --recursive https://github.com/mdbergmann/clamacs.git`)
points the build at an existing install instead:

```
make -f Makefile.cross amiga TOOLCHAIN=/path/to/amilisp/tools/m68k-amigaos-gcc/prefix
```

The MorphOS build is native: `make -f Makefile.mos` in a checkout on a
MorphOS machine with the SDK's gcc (no PPC cross-compiler exists for the
Mac).

The host frontend (macOS, Linux) is built by `host/build.sh`, which
`host/run.sh` calls when something is missing.  It needs the network
once, for the webview library and the CodeMirror packages (both pinned
and checked).  Linux needs GTK 3 and WebKitGTK 4.1 with their headers
(Debian/Ubuntu: `libgtk-3-dev libwebkit2gtk-4.1-dev`; 4.0 is taken when
4.1 is missing), `pkg-config`, gcc/g++ and node.  Windows (an MSYS2
shell, WebView2) has its shim written and compiled against the API with
mingw-w64, but has not been run on a Windows machine yet.

`host/make-image.sh` (`make host-image`) saves the editor as
`build/host-frontend/clamacs.img` beside the page and the libraries and
proves it starts; `IMAGE=1 host/run.sh` starts from it.  Images are
per-build: one older than the amilisp binary or any `lisp/*.lisp` is
remade.  On the Mac, `host/make-app.sh` (`make host-app`) wraps it all
into `build/host-frontend/Clamacs.app`.

`vendor/texteditor` is used for its headers, documentation and demo only:
the editor subclasses the *installed* `TextEditor.mcc` at runtime and never
builds the class.  Its `include/` directory also carries `libraries/mui.h`,
the muimaster protos and the SDI headers, so a MUI application compiles
against it without the MUI developer kit.

## Testing

```
make test                        # host tests: the C core and the Lisp editor's pure modules
make test-lisp                   # the Lisp editor's tests alone (CLAMACS_TEST=menu for one file)
make test-lisp-gc-stress         # the same with a compaction at every allocation (AmiLisp's gate, run by its make test-gc-stress)
make -f Makefile.cross amiga     # cross-compile build/cross/clamacs (and sendkey)
make -f Makefile.cross test-lisp-amiga # the Lisp editor through drive.rexx in FS-UAE
make -f Makefile.cross test-amiga # the C editor's unattended FS-UAE run
make -f Makefile.mos             # MorphOS: native build on the box, see the file's header
verify/host/run-smoke.sh         # the host frontend's ground: window, page, shim, wake
verify/host/host-keys.sh         # the host editor typed into through its page, unattended
verify/host/run-drive.sh         # the host editor's acceptance run over its own port
MEMTRACK=1 verify/host/run-drive.sh # the same under a leak-tracking amilisp: nothing may outlive exit
IMAGE=1 verify/host/run-drive.sh # the same with both editors started from the heap image (make host-image)
APP=1 verify/host/run-drive.sh   # the same through Clamacs.app's launcher (make host-app; macOS)
verify/host/shots.sh             # the README's host screenshots, taken from the running editor (macOS)
make host-linux                  # the smoke run and the drive on Linux, in a container (verify/host/run-linux.sh)
```

The Lisp editor's tests run everything but `frontend-mui.lisp` on the host
under AmiLisp's `build/host/amilisp`: the commands, the minibuffer, the
wire, the REPL, the debugger, the menu and the window positions all work
against a fake frontend and a fake transport, so a failing assertion costs
a second instead of an emulator boot.  The FS-UAE run then drives the real
thing through its ARexx port with the same script that gated the C editor,
and the host drive does the same over the TCP port.

The FS-UAE run uses the amilisp runtime from the superproject (the
`AmiLisp:` volume; the integration leg reads its `build/cross/amilisp`, so
run `make -f Makefile.cross amiga` in `amilisp` first).  The Workbench image
(with MUI and TextEditor.mcc) and `FS-UAE.app` are not tracked in git; the
run takes them from the superproject's `verify/realamiga/` too.  A standalone
clone falls back to an `amilisp` checkout next to it.  Override with
`EMU_DIR` (the emulator assets) and `AMILISP_DIR` (the amilisp runtime).

## Layout

```
lisp/                      the editor: the Emacs layer, Lisp mode, the wire to amilisp
                           (transport-arexx / transport-tcp / transport-self), the
                           REPL/debugger/inspector, the menu table and window positions
                           -- all pure Lisp over a frontend protocol -- and the two
                           frontends: frontend-mui.lisp (MUI) and frontend-host.lisp
                           (the same protocol over the page)
host/                      the host frontend's native shim, page and build.sh; run.sh
tests/                     host tests for the pure modules (tests/run-lisp-tests.sh),
                           on a fake frontend and a fake transport, and for the
                           host frontend with the page stubbed
scripts/                   the heap image the release starts from (save/verify)
verify/realamiga/          unattended FS-UAE run, driven through the ARexx port;
                           sendkey.c injects real key events through input.device
verify/host/               the host frontend's unattended runs (smoke, keys through the
                           page, the acceptance drive over the editor's own port)
examples/arexx/            a macro that drives the editor and amilisp over ARexx
src/                       the C editor the Lisp one was ported from (frozen)
docs/memory.md             what the C editor cost on an 8 MB machine (historical)
vendor/texteditor/         submodule: TextEditor.mcc (amiga-mui), pinned to release 15.56
```
