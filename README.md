# Clamacs

An Emacs-flavoured Common Lisp IDE for AmigaOS 3 and MorphOS: a native MUI
editor with Emacs key handling that talks to a running
[CL-Amiga](https://github.com/mdbergmann/cl-amiga) (`clamiga`) over its ARexx
port — load, compile, evaluate, and later a REPL, debugger and inspector in
their own windows.

**Status:** phase 1 (editor MVP) is up and running on AmigaOS 3 — the window
opens, Lisp mode colours and navigates, and the editor's own ARexx port
drives it. See `CLAUDE.md` for the design and the phase plan, and
`specs/clamacs-ide.md` for the full one.

## Layout

```
src/emacs/                 keymaps, command table, kill ring, minibuffer history
src/lisp/                  tokenizer, sexp scanner, indenter
src/rexx/                  diagnostic parser, request queue, the rc ladder
src/*.c                    the MUI half: custom classes, windows, ARexx, main
tests/                     host unit tests for everything under emacs/ lisp/ rexx/
verify/realamiga/          unattended FS-UAE run, driven through the ARexx port
docs/memory.md             what the editor costs on an 8 MB machine
tools/setup-toolchain.sh   m68k-amigaos-gcc installer (copied from cl-amiga)
tools/m68k-amigaos-gcc/    submodule: the cross toolchain sources (same pin as cl-amiga)
vendor/texteditor/         submodule: TextEditor.mcc (amiga-mui), pinned to release 15.56
```

## Building and testing

```
make test                        # host unit tests for the portable core
make -f Makefile.cross amiga     # cross-compile build/cross/clamacs
make -f Makefile.cross test-amiga # unattended FS-UAE run, then check the log
```

`make test` builds only the half of the editor that takes no MUI and no OS
types. That split is a design rule, not a convenience: the keymap engine, the
Lisp tokenizer, the sexp scanner, the indenter, the diagnostic parser and the
request queue all run on the host, so a failing assertion costs a second
instead of an emulator boot.

The FS-UAE run borrows the Workbench image (which already has MUI and
TextEditor.mcc) and the boot hook from a `cl-amiga` checkout next to this
one; set `CLAMIGA_DIR` if it lives elsewhere.

## Requirements on the Amiga

MUI 3.8 or newer (`muimaster.library` 19+) and `TextEditor.mcc` 15.x
installed in `MUI:Libs/mui/`. Verified against MUI 3.8 and TextEditor.mcc
15.56.

`vendor/texteditor` is used for its headers, documentation and demo only —
the editor subclasses the *installed* `TextEditor.mcc` at runtime and never
builds the class. Its `include/` directory also carries `libraries/mui.h`,
the muimaster protos and the SDI headers, so a MUI application compiles
against it without the MUI developer kit.

## Setup

```
git clone --recursive https://github.com/mdbergmann/clamacs.git
cd clamacs
tools/setup-toolchain.sh                                   # download (macOS arm64) or build
tools/setup-toolchain.sh --link ../cl-amiga/tools/m68k-amigaos-gcc/prefix   # reuse an existing install
```

The MorphOS build needs the MorphOS SDK unpacked under `tools/mos-sdk/`
(not redistributed, ignored by git).
