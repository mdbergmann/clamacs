# Clamacs

An Emacs-flavoured Common Lisp IDE for AmigaOS 3 and MorphOS: a native MUI
editor with Emacs key handling that talks to a running
[CL-Amiga](https://github.com/mdbergmann/cl-amiga) (`clamiga`) over its ARexx
port — load, compile, evaluate, and later a REPL, debugger and inspector in
their own windows.

**Status:** phases 1 to 3 run on AmigaOS 3 — the editor with Lisp mode and
its own ARexx port, introspection (arglist, completion, jump to
definition, describe, apropos, macroexpand) asked from clamiga, and a REPL
window (`C-c C-z`) fed by a REPL thread in clamiga that streams output,
asks the editor for `read-line` input and can be interrupted. See
`CLAUDE.md` for the design and the phase plan, and `specs/clamacs-ide.md`
for the full one.

## Layout

```
src/emacs/                 keymaps, raw-key decoding rules, command table, kill ring, minibuffer history
src/lisp/                  tokenizer, sexp scanner, indenter
src/rexx/                  diagnostic parser, request queue, the rc ladder, the REPL thread's messages
src/*.c                    the MUI half: custom classes, windows, ARexx, introspection, the REPL, main
tests/                     host unit tests for everything under emacs/ lisp/ rexx/
verify/realamiga/          unattended FS-UAE run, driven through the ARexx port;
                           sendkey.c injects real key events through input.device
docs/memory.md             what the editor costs on an 8 MB machine
tools/setup-toolchain.sh   m68k-amigaos-gcc installer (copied from cl-amiga)
tools/m68k-amigaos-gcc/    submodule: the cross toolchain sources (same pin as cl-amiga)
vendor/texteditor/         submodule: TextEditor.mcc (amiga-mui), pinned to release 15.56
vendor/clamiga/            submodule: a pinned full clone of the clamiga runtime (cl-amiga),
                           so clamiga changes for clamacs stay separate from mainline clamiga
```

## Building and testing

```
make test                        # host unit tests for the portable core
make -f Makefile.cross amiga     # cross-compile build/cross/clamacs (and sendkey)
make -f Makefile.cross test-amiga # unattended FS-UAE run, then check the log
make -f Makefile.mos             # MorphOS: native build on the box, see the file's header
```

`make test` builds only the half of the editor that takes no MUI and no OS
types. That split is a design rule, not a convenience: the keymap engine, the
Lisp tokenizer, the sexp scanner, the indenter, the diagnostic parser and the
request queue all run on the host, so a failing assertion costs a second
instead of an emulator boot.

The FS-UAE run uses the clamiga runtime from the `vendor/clamiga` submodule
(the `CLAmiga:` volume; the integration leg reads
`vendor/clamiga/build/cross/clamiga`, so build clamiga in the submodule
first). The Workbench image (with MUI and TextEditor.mcc) and `FS-UAE.app`
are not tracked in git and so are not in that submodule; the run takes them
from a `cl-amiga` checkout next to this one. Override with `EMU_DIR` (the
emulator assets) and `CLAMIGA_DIR` (the clamiga runtime).

## Requirements on the Amiga

MUI 3.8 or newer (`muimaster.library` 19+) and `TextEditor.mcc` 15.29 or
newer installed in `MUI:Libs/mui/`; the editor checks both at startup.
Verified against MUI 3.8 and TextEditor.mcc 15.56.

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

The MorphOS build is native: `make -f Makefile.mos` in a checkout on a
MorphOS machine with the SDK's gcc (no PPC cross-compiler exists for the
Mac). MorphOS ships `TextEditor.mcc`, so nothing else is needed there.
