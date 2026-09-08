# Clamacs

Emacs-flavoured Common Lisp IDE for AmigaOS 3 (68020+) and MorphOS. Native C
MUI application; drives a running `clamiga` (the CL-Amiga runtime, checked
out beside this repo as `../cl-amiga`) over ARexx.

The full design and phase plan is `specs/clamacs-ide.md`; this file is the
short version.

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
- The editor's ARexx port is `CLAMACS.1` on the first instance, not
  `CLAMACS`.  Clients scan, as they do for `CLAMIGA`.
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
  testable that way -- a harness limit, not an editor bug (the KEY leg and
  host tests cover the minibuffer).  A modifier must be injected as a real
  qualifier-key press bracketing the key, not just an `IEQUALIFIER` bit.
- TextEditor.mcc floor is **15.29** (`SetBlock`).  `ck_classes_create()`
  reads a bare object's `MUIA_Version` (YAM's method) and refuses below it.
- The port's `KEY` command stops *above* the raw-key decoder.  Real key
  events come from `verify/realamiga/sendkey` (built by `make -f
  Makefile.cross amiga`), and `drive.rexx`'s raw-key leg is what verifies
  Alt-as-Meta.  On a DOS command line `<` and `>` must be quoted.

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
3. **REPL window**: output streamed to the editor's port during EVAL, read
   requests the other way, a dedicated REPL thread in clamiga so the port
   stays responsive.
4. **Debugger and inspector windows**: nested command loop on the REPL
   thread, an EVAL mode that does not catch, `BACKTRACE`/`FRAME`/`RESTART`,
   `INSPECT`/`PART`.

## Build and toolchain

- `tools/setup-toolchain.sh` installs (or `--link`s) `m68k-amigaos-gcc`
  into `tools/m68k-amigaos-gcc/prefix`; the submodule is the same commit
  cl-amiga pins, so both repos use one compiler.
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
  varargs entry points).  **Not yet compiled** as of 2026-09-08: the box
  was off.  Its header and the spec's "Still open" list track that.

## Testing

- Unattended FS-UAE runs follow cl-amiga's `verify/realamiga/run-fs-uae.sh`
  pattern (watchdog, auto-quit). Integration tests need a clamiga binary in
  the emulated system — take it from `../cl-amiga/build/cross/`.
- Real hardware: the `vamp` (Vampire, AmigaOS 3) and `mos` (MorphOS) MCP
  servers, see cl-amiga's memory notes for the workflow.  When the MCP
  config is stale, `~/Development/MySources/amimcp/server/amiga.py`
  (`Amiga(host, token=...)`: `exec_command`, `write_file`, `arexx`,
  `input_key`) drives a box directly.  The keyboard check there is
  `drive.rexx`'s raw-key leg -- `sendkey` is a 68k CLI tool and runs on
  both boxes; the spec's "Still open" list has the recipe.
- LF line endings are forced by `.gitattributes`.
