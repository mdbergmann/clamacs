# Clamacs

An Emacs-flavoured Common Lisp IDE for AmigaOS 3 and MorphOS: a native MUI
editor with Emacs key handling that talks to a running
[CL-Amiga](https://github.com/mdbergmann/cl-amiga) (`clamiga`) over its ARexx
port — load, compile, evaluate, and later a REPL, debugger and inspector in
their own windows.

**Status:** repository skeleton. No editor code yet; see `CLAUDE.md` for the
design and the phase plan.

## Layout

```
tools/setup-toolchain.sh   m68k-amigaos-gcc installer (copied from cl-amiga)
tools/m68k-amigaos-gcc/    submodule: the cross toolchain sources (same pin as cl-amiga)
vendor/texteditor/         submodule: TextEditor.mcc (amiga-mui), pinned to release 15.56
```

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
