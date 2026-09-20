# Clamacs in Lisp: the editor as a clamiga program

Status: IN PROGRESS (phase 4 done on FS-UAE: the REPL, debugger and
inspector; next: the Vampire and MorphOS runs of phases 2-4, then phase
5, parity and release)
Date: 2026-09-16
Supersedes: the "An editor written in Lisp" non-goal and the two-process
rationale of `clamacs-ide.md` (2026-09-08).  Everything else in that spec
-- the wire, the command set, the Emacs layer, the MUI facts learned in
phases 1-6 -- stands and is the specification this port has to meet.

## Goal

Rewrite the Clamacs editor in Common Lisp, running as its **own clamiga
instance**, and keep the architecture that works today: two Amiga
processes talking over ARexx, the editor the client of clamiga's
`CLAMIGA` port for everything it asks, the Lisp the client of the
editor's port for everything it pushes.  The user-visible result is the
same editor -- same keys, same windows, same ARexx command set, same
`drive.rexx` passing -- with three things the C version cannot offer:

- **It eats its own dog food.**  The IDE for the Lisp is written in the
  Lisp, and it is the hardest interactive workload the runtime has: FFI
  callbacks on every keystroke, the MUI bindings, threads, GC under an
  interactive load, a shipped heap image.  Every bug it finds is a
  runtime commit under cl-amiga's gates.
- **It is live-hackable.**  A new command is `defun`ed into the running
  editor and bound to a key without a restart, and the user's init file
  is Lisp, not ARexx.  An Emacs-flavoured editor whose extension language
  is not Lisp was the compromise; this removes it.
- **One source for both targets.**  The MorphOS build of the editor
  disappears: clamiga's native MorphOS binary runs the same Lisp.  No
  `Makefile.mos`, no `muistubs.c`, no SDK header differences.

## Non-goals

- **A pleasant editor on a 14 MHz 68020.**  The runtime keeps its 68020
  promise; the *IDE* targets the machines people develop on -- a 68030 or
  faster, a Vampire, MorphOS.  On a stock 68020 the editor must start and
  work (the lowend FS-UAE leg keeps it honest), but a user there is
  expected to edit in another editor and load through the REPL or the
  ARexx `LOAD` command, so `LOAD`'s per-form recovery and its `file:line`
  diagnostics are that user's whole IDE.  Latency on that machine is a
  number the spike records, not a gate.
- **Replacing TextEditor.mcc.**  Rendering, the buffer, undo, clipboard,
  search, block styling and index mapping stay in the installed class.
  The Lisp layer sits above it exactly where the C subclass sits today.
  (Redisplay as bytecode was the 2026-09-08 objection; it does not arise
  as long as this holds.)
- **One process.**  The editor instance never hosts the user's code.  A
  Guru in user code kills the target clamiga, the editor stays up and
  reconnects, as now.
- **A new wire.**  The ARexx protocol and the `EXT.DEV` command set are
  unchanged; anything the Lisp editor needs from the runtime is an
  `EXT.DEV` command or a runtime fix committed in cl-amiga.
- Emacs Lisp compatibility, split windows on one buffer, non-Lisp modes:
  as in `clamacs-ide.md`.

## Why the 2026-09-08 reasons no longer decide it

The three reasons for native C were written before these landed in the
runtime; recording them is what turns this from a mood into a decision.

| 2026-09-08 reason | What changed |
|---|---|
| Redisplay and buffer edits must not run as bytecode on a 68020 | They still do not: TextEditor.mcc keeps them.  What moves to Lisp is the per-key Emacs layer (keymap lookup, command dispatch, indentation, sexp scanning), which the m68k JIT compiles.  The 68020 is no longer the IDE's target machine (Non-goals). |
| A GC pause must not freeze the editor | The editor heap is small and its own; nothing the user evaluates allocates in it.  Pause length is measured in the spike.  The generational collector is host-only, so the Amiga number is the classic collector's and is the one that counts. |
| A crash in either half must not take the other down | Preserved by keeping two processes.  This was never an argument against Lisp, only against one process. |
| (implicit) No way to write a MUI custom class in Lisp | `AMIGA.MUI:CREATE-CUSTOM-CLASS` with a Lisp dispatcher, `DO-SUPER-METHOD`, `INST-DATA`, the foreign pool that deletes the class -- `examples/amiga/mui/class1.lisp` in cl-amiga is the MUI SDK's Class1.c in Lisp.  The foreign-callback boundary (an error inside a method is caught at the callback, the method returns 0, the condition re-signals when the MUI call returns) is what makes a dispatcher on MUI's stack safe. |
| (implicit) Startup: loading an editor from FASLs on a 68k | Heap images: `EXT:SAVE-IMAGE`, `--image`, `*save-hooks*`/`*restore-hooks*`, `:shake-bindings`; the release already saves a `clamiga.img` beside every binary from the staged layout. |
| (implicit) The wire needs C | `AMIGA.AREXX` has both ends: `START` (a served port on its own thread, verbs added with `EXT.DEV:DEFINE-COMMAND`) and `SEND`. |

## Options considered

| Option | Verdict |
|--------|---------|
| Stay in C | The working baseline, kept shipping until parity.  Gives up the three goals above. |
| Emacs model: embed the VM in the C editor, C core for MUI/redisplay, Lisp for the command layer | Would need clamiga packaged as a library (a new runtime deliverable), keeps two toolchains and a MorphOS C build, and the user's code still runs elsewhere -- so it buys extensibility without buying dog food.  Second choice. |
| Editor logic in the *target* clamiga, driving a thin C editor over ARexx | A round trip per keystroke over ARexx: too slow, and a user-code crash takes the editor logic with it. |
| **A clamiga program over `AMIGA.MUI`, own instance, ARexx wire unchanged** | **Chosen.**  Every building block exists; the test harness is protocol-level and transfers unchanged; one source for both targets. |

## Architecture

```
  clamiga --image clamacs.img              clamiga (the user's)
  +------------------------------+  ARexx  +-----------------------------+
  | CLAMACS package              | ------> | AMIGA.AREXX handler thread  |
  |  MUI task (main thread):     | CLAMIGA |  EXT.DEV command layer      |
  |   Application, doc windows   |         |  REPL thread, debugger loop |
  |   ClamacsText (Lisp subclass | <------ |                             |
  |    of TextEditor.mcc)        | CLAMACS |                             |
  |   minibuffer, echo area      |         +-----------------------------+
  |   error/REPL/debug/inspect   |
  |  client thread: SEND queue   |
  |  port thread: AMIGA.AREXX    |
  +------------------------------+
```

Three threads in the editor instance, one rule between them: **only the
MUI task touches MUI.**

- **MUI task** -- the main thread.  Owns every object, runs
  `AMIGA.MUI:DO-APPLICATION-EVENTS` with an extra signal mask
  (`:signals`), and drains a mailbox when that signal arrives.  Every
  keystroke, notification, method and menu action runs here.
- **Client thread** -- `MP:MAKE-THREAD`; takes requests from a queue,
  performs the blocking `AMIGA.AREXX:SEND` to the target's port, posts
  the `(rc . text)` reply into the mailbox and `Signal`s the MUI task
  (`AMIGA.RAW.EXEC:SIGNAL` on a bit the MUI task allocated at startup).
  One request in flight, as the protocol demands; the queue serialises.
  This keeps the UI live during a long compile without a new runtime
  primitive; an asynchronous send in the platform layer (PutMsg, a reply
  port whose signal joins the MUI mask) is the optimisation if the
  thread's cost shows.
- **Port thread** -- `(AMIGA.AREXX:START :name "CLAMACS")`.  Commands
  arriving on the editor's port (`OPEN`, `KEY`, `EVAL`, `GETFILE`,
  `MENU`, `GETWINDOW`, ... and the inbound `OUTPUT`, `READLINE`, `RESULT`,
  `DEBUGGER` of phases 3-4) are `EXT.DEV:DEFINE-COMMAND` verbs.  Their
  bodies run on the port thread, so each one *posts* to the mailbox and
  either replies at once or waits on a per-request condition for the
  MUI task's answer (`GETFILE` needs the text; `OUTPUT` needs nothing).
  The MUI application object gets **no** `MUIA_Application_Base`, so MUI
  creates no second port; the C editor's `CLAMACS.1` quirk goes away and
  the first instance is `CLAMACS`.  `ck_rexx_own_port()`'s task scan is
  replaced by `AMIGA.AREXX:PORT-NAME`.

Foreign state follows cl-amiga's MUI conventions: the whole GUI lives
inside one `WITH-FOREIGN-POOL`, custom classes are created with
`CREATE-CUSTOM-CLASS` and deleted by the pool after the objects, hooks
are `POOL-HOOK`s.  Per-object state (document path, package, modified
flag, the local stack, minibuffer state) is a Lisp struct found from the
object through an `EQ` hash table keyed by the object's address, not
`INST-DATA`: instance data is bytes, and the editor's state is Lisp.

### The frontend protocol

Commands never call MUI.  Everything the Emacs layer needs from the
toolkit goes through one small protocol of generic functions -- open and
close a window, insert and delete text, read the buffer and the cursor,
move the cursor, colour a range, read a key event, show a message in the
echo area, prompt in the minibuffer, fill a list (diagnostics, restarts,
inspector parts), install a menu, ask for a file, run a timer -- and
`lisp/frontend-mui.lisp` is its first and, for the releases, only
implementation.  This is the Lisp form of the C editor's rule that the
pure modules take no OS types, and it is what keeps a second frontend (see
"A host frontend") a bounded piece of work rather than a fork.  The wire
gets the same treatment: the client talks to a *transport* object whose
MUI-era implementation is `AMIGA.AREXX:SEND` on the client thread, so a
socket transport is another implementation, not a change.

### The text area

`ClamacsText` is `(create-custom-class "TextEditor.mcc" #'text-dispatch)`.
The dispatcher handles `OM_NEW`/`OM_DISPOSE` (register and forget the
state struct), `MUIM_Setup` (add the class's **own** `MUI_EventHandlerNode`
for RAWKEY at priority 1 -- the phase-1 fact that a bare
`MUIM_HandleEvent` override is never called), `MUIM_Cleanup`,
`MUIM_GoActive`/`MUIM_GoInactive` (`MUIA_Window_DisableKeys` for TAB, RET,
ESC), and `MUIM_HandleEvent`, which is where the Emacs layer runs and
returns 0 to let the class's own node edit.  Everything else is
`DO-SUPER-METHOD`.  Text access is unchanged: export with
`MUIV_TextEditor_ExportHook_NoStyle`, `MUIA_TextEditor_CursorX/Y`,
`MUIM_TextEditor_SetBlock` with `HasChanged` saved around paints.

The minibuffer is the same `String` subclass with the same edit-hook
dance -- the hook itself being the runtime's native
`mui:make-string-key-hook`, since MUI 3.8 calls it on input.device's
task (see Open, finding 1 of the Vampire run) -- including the MUI 4
double-dispatch recognition.  **Every item in
`clamacs-ide.md`'s "Answered during phase 1" and CLAUDE.md's "Phase 1
facts" is a MUI fact, not a C fact, and is a line in the port's
checklist.**  They cost a debugging cycle each the first time; they must
cost nothing the second time.

### The Emacs layer

The pure C modules under `src/emacs/` (keymap, bindings, command table,
kill ring, location stack, minibuffer history, raw-key decoder, window
store), `src/lisp/` (tokenizer, sexp scanner, indentation) and
`src/rexx/` (diagnostic parser, request queue, REPL and debugger message
parsers, symbol cache) are logic with unit tests and no OS types.  They
port one-to-one into `CLAMACS` functions, and their C test cases become
the data of the Lisp tests.  A key is a fixnum (code plus modifier bits,
the C encoding) and a keymap an `EQL` hash table from key to a command
symbol or to another keymap -- the prefix state machine needs the prefix
maps as objects, because inside `C-x` the local and the global side both
stay live.  A command is a symbol: `(define-command forward-sexp () "doc"
...)` is `DEFUN` plus registration under the lowercase name, which is
what `M-x` completion, the menu table and the port's `EVAL` look up, so
redefining a command in a running editor changes what its keys do.  The
C editor's whole command list is *declared* in `lisp/command.lisp`
(bindings and namespace are complete and host-tested before a frontend
implements them); a declared command without a function reports "not
implemented".  "Not possible" is `NIL` throughout, never `-1`.  The user's init file
(`S:.clamacsrc`, loaded after the image restores) binds keys with the
same forms.

### Error handling inside MUI

A command that errors runs inside `MUIM_HandleEvent`, inside MUI, inside
`MUIM_Application_NewInput`.  The callback boundary catches it, the
method returns 0, and the condition re-signals when `APPLICATION-INPUT`
returns -- so the event loop body wraps that call in a `HANDLER-CASE`
that prints the condition to the echo area and continues.  An error in
a *dispatcher* method other than a key (a `MUIM_Draw` in a future class)
is the same.  With `EXT:*CALLBACK-ERROR-POLICY*` set to debug during
development, the editor's own REPL (the instance's console) gets the
debugger.

### Memory and startup

Two clamiga processes, each with the 820 KB m68k binary loaded (AmigaDOS
shares no code between two `LoadSeg`s of the same file unless the binary
is resident) and its own heap.  Budget to *measure* in the spike, not to
assume:

| Item | Estimate |
|---|---|
| editor binary + heap (`--heap 4M`, the default) | ~5 MB estimated; the spike measured ~14-15 MB at `--heap 8M` (see Spike) |
| editor image on disk (boot + CLOS + editor, `:shake-bindings t`) | 1-2 MB |
| target clamiga | whatever the user gives it |

That is comfortable on a Vampire or MorphOS and tight on 8 MB.  A
resident (pure) clamiga binary would share the code segment between the
two; it is noted, not planned.

Startup is `clamiga --image clamacs.img`.  The image is saved from a
booted editor *before* any OS object exists: `*save-hooks*` is not
needed because the image is saved by a script that loads the editor and
saves, never from a running GUI.  `*restore-hooks*` runs `clamacs:start`,
which opens the libraries, builds the classes and windows and enters the
loop.  **Nothing OS-owned survives the image**: every library base,
class, object, hook, signal bit and port is created in `start` and only
there.  `ext:*image-restored-p*` lets `.clamacsrc` skip loads the image
already holds.

## Spike (phase 0) -- DONE 2026-09-16

`spike/spike.lisp` is a clamiga program: a Lisp subclass of the installed
TextEditor.mcc (`AMIGA.MUI:CREATE-CUSTOM-CLASS`) that registers its own
RAWKEY handler node at priority 1 in `MUIM_Setup`, decodes every key in
`MUIM_HandleEvent` through MapRawKey with `src/emacs/rawkey.c`'s rules,
looks it up in a prefix-capable keymap and either runs the command --
RET is newline-and-indent over the exported buffer, `C-x C-c` quits -- or
returns 0 so the class's own node edits.  Every `MUIM_HandleEvent` is
timed with ReadEClock from dispatcher entry to return.  `spike/run-spike.sh
020|040` drives it unattended in FS-UAE (boot-override hook, `sendkey`,
watchdog), `spike/run-vamp.py` on the Vampire through amiagent against the
unpacked 0.10.0 release; `spike/typing.sh` is the shared keystroke list:
four ten-line defuns, 1,051 key presses, 44 RETs, about 1,300 characters
typed without indentation.  On every leg the buffer came out identical and
Emacs-indented, with no callback-boundary error.

### Numbers

Per-key = the pass-through path (decode, keymap lookup, return 0 to the
class), the cost the Lisp layer adds to every keystroke.  RET = export the
whole buffer, scan it for the innermost open paren twice (a naive generic
loop and a declared `SIMPLE-STRING` state machine), insert newline plus
indentation through the class.  Heap `--heap 8M`, clamiga 0.10.0 release
build (JIT on), warm FASL cache.

| | FS-UAE A4000/68040 + emulator JIT | Vampire V4 (real 68040-class FPGA) | FS-UAE A1200/68020, accuracy 2 |
|---|---:|---:|---:|
| window open after start | 4-8 s | 2-4 s | 54 s |
| per key: median / p90 | 0.64 / 0.71 ms | 1.03 / 1.46 ms (JIT off: 0.71 / 1.15) | 16.7 / 25.7 ms |
| RET total: median | 43 ms | 80 ms | 2,250 ms |
| RET: export (657 chars mean) | 1.2 ms | 2.0 ms | 32 ms |
| RET: indent scan, naive | 30 ms | 41 ms | 1,104 ms |
| RET: indent scan, declared | (not run) | 17 ms | 406 ms |
| RET: insert + class redraw (C) | 7.5 ms | 17 ms | 189 ms |
| explicit full GC, 750 KB live: first / later | 304 / 73 ms | 360 / 88-95 ms (JIT off: 129 / 47 ms) | 10,450 / 2,600-3,100 ms |
| GCs during the 45 s typing run | 0 | 0 | 0 |
| Fast RAM taken by the instance | 15.0 MB | 13.9 MB | 15.0 MB |
| not returned at exit (libraries, classes) | 413 KB | 187 KB | 412 KB |

The FS-UAE 68040 column is an emulator on a fast Mac and overstates a
real 68040; the Vampire column is the one real-hardware measurement.  The
MorphOS box did not answer on the network on 2026-09-16 (no host on port
7846 in the subnet); its column is open.

### Verdict against the gates

- **Per-key < 5 ms median on 040-class hardware: PASS** (1.0 ms on the
  Vampire, 5x headroom).  The Lisp key layer is not the bottleneck
  anywhere above a 68020.
- **GC pause < 100 ms on 040-class hardware: MARGINAL PASS** (88-92 ms
  on the Vampire for a 750 KB live heap in an 8 MB arena), and the
  *first* collection is 4x that (360 ms).  Nothing collected during the
  run itself (2.6 MB consed in 45 s), so an editor session would see a
  pause every few minutes of typing, not per keystroke.  Runtime item:
  see below.
- **68020 (recorded, not gated):** 17 ms per key is typeable; RET at
  2.2 s and a 3 s GC pause are not.  This confirms the Non-goals as
  written: on a stock 68020 the editor must merely work.
- **Memory:** ~14-15 MB per instance at `--heap 8M`, i.e. about 6 MB
  off-heap beyond the arena and binary.  The spec's 5 MB estimate was
  wrong; two instances on an 8 MB machine are out, as the Non-goals
  already imply.  Runtime item: see below.
- **Correctness: PASS** on all three legs, zero dropped keystrokes,
  zero callback errors, the two indent scans never disagreed.

**Decision: proceed to phase 1 on the chosen architecture.**  The
Emacs-model fallback is not needed.

### What the spike found for the runtime (dog food, first serving)

Each is a cl-amiga item; none blocks phase 1, all shape it.

1. **Character scanning is 25-65 us per character on a real 68040**
   (declared / naive), i.e. 1,000-2,500 instructions per `SCHAR` +
   `CASE` + `PUSH` step.  That is the JIT's character `CASE`, `SCHAR` and
   list push/pop, not MUI.  An editor scans text on every RET, TAB, paren
   match and colouring pass, so this is the first optimization target:
   `trunk/bench-general.lisp` should get a string-scan row, and the
   editor's scans must stay bounded (from the top-level form, not the
   buffer start) whatever the compiler does.  **Addressed 2026-09-16**
   (runtime item 3 below): 2.0-2.8 us per character for the scan itself
   on the Vampire.
2. **Full GC of a small live heap costs ~90 ms on the Vampire and 3 s on
   a 68020, with a first collection 4x worse.**  The live set was 750
   KB; the arena 8 MB.  Whether that is sweep-over-arena, the demand-
   interned binding tables of the raw modules, or first-touch, is the
   question; the editor wants `--heap 4M` and a collector whose pause
   tracks the live set.  `ext:%gc-time-stats` gives the split.
3. **Off-heap footprint ~6 MB** beyond arena and binary (`Avail` before
   and with the instance running).  `CLAMIGA_MEM_DIAG=1` was set for
   every run but printed nothing into the `run >file` log on either
   FS-UAE or the Vampire -- either the report does not reach a redirected
   `Output()` or the switch is not seen by the child; open.
4. **The callback path itself is cheap**: decode + `MapRawKey` (an FFI
   call) + a hash lookup + the two ReadEClock calls fit in 1 ms on the
   Vampire.  `MUIM_TextEditor_ExportText` of a 650-char buffer through
   `FOREIGN-TO-STRING` is 2 ms.  No runtime work needed here.
5. **MUI facts learned** (into the phase-1 checklist): a window opens
   with *no* active object -- set `MUIA_Window_ActiveObject` to the text
   after `MUIA_Window_Open`, or neither the subclass nor TextEditor.mcc
   sees a key; the `create-custom-class` + own-handler-node pattern from
   the C editor works unchanged from Lisp; an editor instance drains
   queued keystrokes long after a fast typist stops on slow hardware, so
   any harness must wait for the program's own "done" marker, not a fixed
   delay.
6. **JIT A/B on the Vampire (`--no-jit`, same box, same run):** the JIT
   makes the generic paths *slower* and the GC pause *twice as long*:
   per key 0.71 ms without vs 1.04 ms with; the naive scan 36 vs 45 ms;
   only the declared state machine gains (31 vs 17 ms).  Full GC of the
   same heap: 47 ms without (mark 40, sweep 20; the Amiga phase clock is
   20 ms-granular) vs 94 ms with (mark 80), first GC 129 vs 361 ms.  So
   the JIT is a net loss for call-heavy generic code and the marker pays
   for native code (the relocation tables, presumably) on every
   collection.  Two runtime items: the per-call round trip that makes
   JIT'd generic code slower than bytecode, and the marker's JIT cost.

   **The marker's JIT cost: DONE 2026-09-16 (cl-amiga).**  It was not
   the relocation tables: the conservative native-stack scan validated
   each spilled word by walking the *whole arena* header by header,
   and with the JIT on every collection runs under a native frame.  A
   per-page block-start index (`gc_hdr_page[]`, `CLAMIGA_HDR_INDEX=0`
   is the A/B switch) bounds that to a page.  Re-measured with this
   spike, same box, same binary, explicit full GC first / later:
   Vampire 129 / 55 ms with the index vs 342 / 90 ms without vs 123 /
   48 ms with `--no-jit` (the 0.10.0 release: 354 / 91); FS-UAE 68040
   161 / 48 vs 314 / 74 vs 155 / 38 ms; FS-UAE 68020 5.3 / 1.7 s vs
   11.0 / 2.7 s.  A collection under the JIT now costs what one without
   it costs; per-key cost is unchanged.  The runners took two knobs for
   this (`SPIKE_SETENV`, `SPIKE_CLAMIGA_ARGS`; `run-vamp.py` also
   `SPIKE_CLAMIGA` for a binary pushed beside the release's).
7. **The generational collector cannot help on the Amiga as it is**: it
   tracks dirty pages with `mprotect`, and `specs/generational-gc.md`
   deliberately rejected a source-level write barrier.  A 68k version
   would need card marking in every store opcode *and* in the JIT's
   stores.  For the 68020 the cheaper levers are the JIT's GC overhead,
   fewer live objects (`--heap 4M`, `:shake-bindings`,
   `%shed-binding-tables`) and the object-count-bound mark; on the
   Vampire the pause is already 47 ms without the JIT.
8. **Harness facts**: AmigaDOS makes `*` an escape inside quotes, so a
   Lisp form with `*specials*` cannot be an `--eval` argument in a DOS
   script (use a preamble file); `sendkey` cannot type `"` from a script.

## Phases

**Before phase 1: a runtime cycle the spike asks for.**  Three cl-amiga
commits, each under cl-amiga's gates and each re-measured with the spike
(`spike/run-vamp.py` on the Vampire, `spike/run-spike.sh 020` for the
68020), in this order because each helps every machine, not only the
68020:

1. The marker's JIT cost: a collection must not pay for native code it
   is not moving (94 -> 47 ms on the Vampire is the target, 3 -> 1.5 s on
   the 68020).  **DONE 2026-09-16**: 90 -> 55 ms on the Vampire, 2.7 ->
   1.7 s on the 68020 (item 6 above has the table); the remaining gap to
   `--no-jit` is within the 20 ms phase clock.
2. The JIT's default policy for generic code: bytecode beats it on the
   call-heavy paths (per key 0.71 vs 1.04 ms) -- either the per-call
   round trip gets cheaper or only declared code is compiled.  **DONE
   2026-09-16 (cl-amiga, the round trip)**: every call from native code
   went through the generic `cl_vm_apply` trampoline and, for a Lisp
   callee, a stub interpreter frame -- a JIT'd call to a native leaf cost
   18.8 us on the Vampire where the interpreter's cost 11.8.  The JIT's
   call helpers now dispatch builtins, FFI stubs and native callees
   directly (7.0 us for the same call) and interpreted callees through
   the stub frame without the copies and probes
   (`trunk/bench-jit-call.lisp`, `specs/native-backend.md` "Status
   (2026-09-16)").  Re-measured with this spike, same box, same session,
   JIT on vs `--no-jit`: per key 658 vs 689 us median (p90 1094 vs
   1105), RET 50 vs 88 ms (naive indent scan 22 vs 36 ms, declared 12
   vs 30 ms), full GC 131 / 55 vs 133 / 50 ms.  The default stays
   "compile everything"; a declared-only policy is not needed.
3. A string-scan fast path: fused character opcodes for `SCHAR`, `CHAR=`
   / `CASE` on characters and list push/pop, with a `trunk/bench-general`
   row; 26 us per character on a real 68040 today, a tenth of that is
   the aim.  **DONE 2026-09-16 (cl-amiga, `specs/performance.md` 4.4)**:
   two-argument `AREF`/`SVREF`/`CHAR`/`SCHAR` and `CHAR=` compile to one
   opcode each, a comparison under a branch fuses with it, `PUSH`/`POP` on
   a local are one opcode, `CASE` misses a key in one dispatch and
   `INCF`/`DECF` of a local by a constant lost their temporaries (JIT
   templates for all of them).  The 26 us was the scan *plus* the
   indentation decision after it; the scan alone, measured on its own
   (`trunk/bench-scan.lisp`), went from 18.3 to 2.4-2.8 us per character
   (naive) and from 7.6 to 2.0-2.4 (declared) on the Vampire — the aim,
   for the scan.  Re-measured with this spike, same box, identical trees,
   two runs each, before vs after: RET median 48.5 / 51.2 vs 35.9 / 32.0
   ms, naive indent 20.9 / 22.1 vs 10.2 / 8.2 ms, declared 11.6 / 12.0 vs
   9.7 / 8.5 ms, per key 651 / 634 vs 661 / 622 us, full GC unchanged.
   What remains in each indent cell (~7 ms) is `indent-at-paren`:
   `POSITION-IF` with a closure, `SUBSEQ` and `MEMBER :test STRING-EQUAL`
   over the body-form names — phase 1's Lisp mode should find the head
   with a declared scan and a hash table, not generic sequence functions.

Plus the editor-side rules phase 1 inherits: scans bounded to the
top-level form, one FFI round trip per key (a fused raw-key decode),
`--heap 4M`, a `:shake-bindings` image with the binding tables shed.

Each phase ends with the corresponding `drive.rexx` leg passing against
the Lisp editor **unchanged**: the harness drives the editor through its
ARexx port and checks a log, so it does not know which language answered.
The C editor keeps shipping and stays frozen (bug fixes only) until phase
5 declares parity.

1. **Editor shell.**  `CLAMACS` package, application, document window
   (text, slider, status line, echo-area page group), `ClamacsText` and
   the minibuffer class, the Emacs layer (keymap, command table,
   `M-x`, kill ring, isearch, ASL open/save, location stack), Lisp mode
   (paren match, indentation, colouring via `SetBlock`).  The pure
   modules come first, host-tested; the GUI second, FS-UAE-tested.
   Files open from the command line and from Workbench arguments.
   **Pure modules DONE 2026-09-17**: keymap, rawkey, command, bindings,
   killring, minihist, locstack, token, sexp, indent under `lisp/`, 218
   tests (every C case plus what C missed; token, sexp and indent also
   fuzzed differentially against the C code, no differences), green on
   the host and with a compaction at every allocation (33 s).  No
   runtime bug surfaced.  The modules of later phases (menudef,
   winstore, diag, queue, symcache, replmsg, dbgmsg) are ported with
   their consumers.
   **Frontend protocol and editing commands DONE 2026-09-17**:
   `lisp/frontend.lisp` (the `document` class and ~20 generic functions:
   index-based text access, the widget's own motions and edits, echo,
   beep, colour) and `lisp/commands.lisp` (command loop, context
   window, motion, kill/yank, mark, sexp commands, indentation, paren
   highlight, colouring), host-tested against `tests/fake-frontend.lisp`
   (a string, a cursor, an undo list): 254 tests, 100 s under GC stress.
   Fixed against C on the way: `indent-region` is top-down (bottom-up
   indented a line against a parent that had not moved yet) and
   backward kills join.
   **Minibuffer and files DONE 2026-09-17**: `lisp/minibuffer.lisp` (a
   prompt is a continuation, not a case in a switch; TAB completion,
   per-kind histories, isearch over the widget's own search, `M-x`,
   `goto-line`) and `lisp/files.lisp` (ISO-8859-1 file I/O in Lisp,
   find-file into this window / other window / the window that has the
   file, the unsaved-changes requester, save/write, new, kill-buffer,
   other-window, quit), both on the fake frontend: 289 tests.  That is
   the whole phase-1 Emacs layer without a line of MUI.
   **The MUI frontend DONE 2026-09-18**: `lisp/frontend-mui.lisp`, the
   one file that names `AMIGA.MUI` -- `ClamacsText` and `ClamacsMini` as
   `CREATE-CUSTOM-CLASS` subclasses with Lisp dispatchers (own RAWKEY
   node at priority 1, the pens in the instance data, the String edit
   hook with the MUI 3.8 key-release trick and the MUI 4 double-dispatch
   recognition, `DisableKeys` re-armed in Show), the document window
   (text + sliders, status line, echo page group), every protocol method
   over the class's own attributes and ARexx commands, the notification
   hooks, the reap-from-the-loop window close and the loop with its
   error handler.  Per-object state is a Lisp object found by the MUI
   object's address; the strings MUI keeps pointers to live in
   per-document foreign buffers.  `lisp/load.lisp` loads it on an
   Amiga, `lisp/clamacs.lisp` runs the editor from source.
   `verify/realamiga/run-lisp-editor.sh` is the FS-UAE smoke run: it
   types a defun with `sendkey` (RET = newline-and-indent), saves with
   `C-x C-s`, quits with `C-x C-c`, and the saved file must equal what
   the SAME keys produce on the host under the fake frontend -- a
   differential test of the two frontends.  First runs: 68040 leg,
   window open in 10 s, saved file byte-identical, clean exit, 441 KB of
   Fast RAM kept by the libraries and classes (the spike saw 413);
   68020 leg, window open in 38 s, identical, the queued keys drained
   about 110 s after `C-x C-c' (a RET is 2 s there, as the spike
   measured) -- the editor works on the 68020, as the Non-goals ask,
   and no faster.  Prompts
   are not driven there (synthetic keys hold a MUI String's focus for
   one key): the minibuffer's MUI dance is checked on hardware and,
   from phase 2 on, through the port.  **Command line and Workbench
   arguments DONE 2026-09-18**, on the runtime side: clamiga loads a
   bare argument, so `--` now ends its options and what follows is
   `ext:*command-line-args*` (never loaded, set before `.clamigarc` and
   the restore hooks -- the image start needs exactly that); a
   Workbench start (argc 0, the `WBStartup` message) becomes a command
   line from the icons' `ARGS`/`WINDOW` tool types with every project
   icon one argument after `--`, `ext:*workbench-started-p*` says so,
   and the 68k binary gives itself the 128K stack an icon does not
   (cl-amiga's README "Program arguments" / "Starting from Workbench",
   `tests/test_command_line_args.sh`, and `tests/amiga/wb-check.lisp`
   started through `verify/realamiga/wbrun.c`, a real `WBStartup`
   sender, in the FS-UAE suite).  `lisp/clamacs.lisp` starts on that
   list; `run-lisp-editor.sh` passes its file after `--`.  Next: the
   wire.

   What the port found for the runtime so far (cl-amiga commits):
   - **A GC-safety bug in the compiler's pre-scans, FIXED 2026-09-17.**
     Both speculative macroexpansion scans held the form unprotected
     across `cl_build_lex_env`, which conses only inside a `MACROLET`
     body -- and `LOOP` expands into one.  Any user macro in a `LOOP`
     body could be expanded from a stale form when a compaction fell
     there; with a `HANDLER-CASE` around the compile (the test runner's)
     that aborted the load.  It had hidden because the FASL cache is
     shared with the non-stress binary; the runner's private cache made
     the suite compile under stress.
   - **`LOAD`'s implicit FASL cache was keyed by the file's own mtime
     alone, FIXED 2026-09-17 (FASL v35).**  Code that inlined another
     file's `DEFSTRUCT` slot offsets stayed cached when that defstruct
     changed and read the wrong slot (a slot added at the front of
     `editor` made the cached `test-commands.lisp` read the old index).
     A FASL now records the layout of every struct it inlined and is
     recompiled when one changed; `--no-fasl-cache` switches the cache
     off.  **Still open by design**: a changed macro or inline function
     in another file leaves cached dependents stale (a wrong expansion,
     not a wrong slot).  `tests/run-lisp-tests.sh` runs with a private,
     empty cache for that reason; the image build must do the same.
   - Noted, not filed: no warning at `LOAD` for a call to an undefined
     function; a `--script` exits 0 after a reader error.
2. **The wire.**  Client thread and queue, `AMIGA.AREXX:START` for the
   editor's port with the phase-1 verb set, diagnostic parser, error list
   window, `LOAD`/`COMPILE-FILE`/`EVAL`/`IN-PACKAGE` with clickable
   diagnostics, launch of the target clamiga when no port is found.
   Gate: `drive.rexx`'s phase-1 leg.
   **DONE 2026-09-18.**  Three pure modules, host-tested on the fake
   frontend and a fake transport (`tests/fake-transport.lisp`; 355 tests
   in all): `lisp/diag.lisp` (the reply parser, `src/rexx/diag.c`'s cases),
   `lisp/wire.lisp` (the transport protocol -- `transport-find-port`,
   `transport-send`, `transport-launch` -- the one-in-flight queue with
   the automatic `LASTRESULT`, the continuations, the error list and its
   walk, the `clamacs-*` commands and `run-lisp`) and `lisp/port.lisp`
   (the verbs: `OPEN SAVE GETFILE GETNAME GOTOLINE EVAL INSERT TE STATUS
   KEY`, a ReadArgs-shaped argument parser; `EVAL` of a `(`-form runs in
   the editor's own Lisp, so a macro can `define-command` into the running
   editor).  `lisp/transport-arexx.lisp` is the Amiga half: the client
   thread (one `AMIGA.AREXX:SEND` at a time, the reply posted to the MUI
   task), the port thread's verbs as `EXT.DEV:DEFINE-COMMAND`s that post
   to the MUI task and wait, the first instance's port being `CLAMACS`,
   and the launch of `PROGDIR:clamiga` through an Execute script with a
   `--load` preamble that opens the port.  The mailbox lives in
   `frontend-mui.lisp` (`call-in-editor`, drained by the event loop on a
   signal bit of its own), with the diagnostics window a plain MUI List.
   Gate passed the same day: `verify/realamiga/run-lisp-drive.sh 040 2`
   (`make -f Makefile.cross test-lisp-amiga`) runs the unchanged
   `drive.rexx` with `PHASE 2` -- the editor checks, the KEY and raw-key
   legs, the integration leg (C-x C-e echoes 3, the editor answers while
   a LOAD is in flight, two diagnostics walked with next/previous-error),
   the shipped macro and quit.rexx; the legs of later phases and the C
   editor's menu and snapshot are gated by `PHASE`, and the C run still
   gets all of it.

   What the wire found for the runtime (cl-amiga commits, 2026-09-18):
   - **A raw exec `Wait()` is invisible to a stop-the-world GC.**  The
     MUI loop (and ReAction's) waited with `AMIGA.RAW.EXEC:WAIT`, a plain
     library call outside any safe region, so a collection started by
     another Lisp thread -- the client thread consing on a reply -- waited
     for the loop's next keystroke.  `AMIGA:WAIT-SIGNALS` is exec `Wait()`
     bracketed as a safe region; both loops use it, and
     `tests/amiga/wait-signals-tests.lisp` runs a full GC on a worker
     while the main task waits.  This was the spec's "a way to hand a
     thread's result to the MUI task" item.
   - `(coerce nil 'string)` answered `"NIL"`; CLHS makes NIL the empty
     sequence there (`tests/test_array.c`).
3. **Introspection.**  Arglist on the idle timer, completion with the
   minibuffer hand-off, `M-.`/`M-,`, describe and apropos windows,
   macroexpansion window.  Gate: the phase-2 leg.
   **DONE 2026-09-18.**  Two pure modules: `lisp/symcache.lisp` (the
   arglist cache, `src/rexx/symcache.c`'s cases) and
   `lisp/introspect.lisp` (the port of `src/introspect.c`: the operator,
   symbol and form at point over `sexp.lisp`; the arglist lookup with its
   cache, its miss memory and its one-quiet-question-at-a-time rule;
   `ARGLIST-IDLE`, the tick the frontend's timer calls; buffer completion
   with the hand-off to a `Complete:` prompt whose completer answers
   `:HANDLED` because its candidates come from clamiga later; `M-.` over
   the location stack and `M-,`; describe, apropos and macroexpand into
   scratch windows found or made by `ENSURE-SCRATCH-DOCUMENT`).  The
   replies come back through `WIRE-DISPATCH` as before, one continuation
   per request kind.  The frontend protocol grew `DOC-SHOW-ARGLIST` (the
   status line's arglist field); the MUI frontend registers a
   `MUI_InputHandlerNode` timer per text object in its Setup (the C
   editor's `CKM_IdleTick`, 3/10 s, removed in Cleanup) and appends the
   arglist to the status line.  Host tests: `tests/test-introspect.lisp`
   walks drive.rexx's introspection leg request by request on the fake
   frontend and fake transport, plus what only a host test can check (a
   late reply, a lost port, an abandoned prompt, clamiga's cap); 389
   tests in all.  Gate: `run-lisp-drive.sh 040 3` (now the
   `test-lisp-amiga` default), the unchanged drive.rexx with `PHASE 3`.
   No runtime change was needed.
4. **REPL, debugger, inspector.**  `REPL-ATTACH` with the inbound
   `OUTPUT`/`READLINE`/`RESULT`/`DEBUGGER` verbs marshalled to the MUI
   task, the transcript buffer, buffer evals on the REPL thread, the
   debugger and inspector windows and their `M-x` commands.  Gate: the
   phase-3 and phase-4 legs.
   **DONE 2026-09-20.**  Four pure modules, the ports of `src/repl.c`,
   `src/debugwin.c`, `src/inspectwin.c` and `src/rexx/replmsg.c` +
   `dbgmsg.c`: `lisp/replmsg.lisp` (the parsers), `lisp/repl.lisp` (the
   REPL window: the session on the editor, the listener state on the
   document -- the two indices are NIL, not -1, while a form runs --
   `C-c C-z`, RET with `sexp-input-complete-p`, the history, the
   read-only transcript by way of `run-command` and `handle-key` asking
   `repl-allow-command` / `repl-unbound-key`, buffer evals on the REPL
   thread so `wire-eval` goes through `repl-eval-from`, and the four
   inbound verbs as `define-port-verb`s), `lisp/debugger.lisp` and
   `lisp/inspector.lisp` (the state of each window, the commands, the
   replies; the frontend shows the state through
   `editor-debugger-open/-close/-raise/-frames/-select-frame/-locals`
   and `editor-inspector-open`, and its lists and buttons call
   `debug-frame-selected`, `debug-frame-clicked`,
   `debug-restart-clicked`, `debug-eval-entered`, `inspect-part-clicked`
   ... with a row number or a line).  `frontend-mui.lisp` grew the two
   windows (plain MUI Lists, a String, KeyButtons made of Text objects;
   the row texts stay on the Lisp side, so no `MUIM_List_GetEntry`),
   disposed of at exit as the diagnostics window is.  Host tests:
   `test-replmsg.lisp` (the C cases), `test-repl.lisp` and
   `test-debugger.lisp` (drive.rexx's REPL and debugger legs step by
   step on the fake frontend and transport, plus the lost port, the
   window closed with a request out, a stale reply, the frame click),
   `test-inspector.lisp`; 446 tests in all, green and green under GC
   stress.  Gate: `run-lisp-drive.sh 040 4` (now the `test-lisp-amiga`
   default), the unchanged drive.rexx with `PHASE 4` -- the three `MENU`
   checks inside the REPL and debugger legs are gated on `PHASE >= 5`
   now, and the buffer-eval leg saves and kills its RAM: buffer by
   command name, which the C editor answers the same way.

   What phase 4 found for the runtime (cl-amiga commit cdaed011):
   - **`EXT.DEV` trims every command at both ends**, which is right for
     `LOAD foo.lisp` and wrong for the REPL thread's `OUTPUT <chunk>`:
     an indented line lost its indentation and a chunk ending in a
     newline lost it, so the transcript's line bookkeeping broke.  The
     C editor took the four inbound commands outside ReadArgs for that
     reason; the Lisp editor's port is `EXT.DEV`, so the layer now has
     `ext.dev:define-raw-command` -- the argument verbatim past the verb
     and its one blank, `OUTPUT` alone the empty chunk -- and
     `transport-arexx.lisp` registers `OUTPUT`, `RESULT` and `DEBUGGER`
     that way (`*raw-port-verbs*`).  `tests/test_dev_commands.sh` pins
     the cases of clamacs's `test_replmsg.c` from that side.
   - The client thread now sends a job that is pending at the quit: the
     `REPL-DETACH` the closing REPL window queued must reach clamiga, or
     its REPL thread is left sending to a port about to vanish.
   Noted: a form typed across lines at the prompt indents under its
   first line as it stands on the prompt line (column 9 after
   `CL-USER> `), as the C editor indents it; SLIME indents from the
   input's start.  Cosmetic, left as is.
5. **Parity and release.**  Menu strip from the ported table, window
   snapshot, HyperSpec URL through `openurl.library`, `.clamacsrc`.
   Editor image saved by `scripts/make-binary-release.sh` beside each
   binary (aos3, aos3-fpu, mos) the way `clamiga.img` is; the `Clamacs`
   launcher scripts start `clamiga --image clamacs.img`; the editor's
   sources ship under `lib/clamacs/` as FASLs; `docs/clamacs.md` and the
   guide updated.  Gate: every `drive.rexx` leg on FS-UAE, the Vampire
   and MorphOS, plus the Non-goals' lowend-startup check.  Then the C
   sources are removed (tagged `c-final` first), the release script's
   cross-build step goes, and `clamacs-ide.md` gets a note pointing here.

Runtime work expected along the way, each a cl-amiga commit under its
gates, none blocking phase 0:

- A way to hand a thread's result to the MUI task: `AMIGA.RAW.EXEC`'s
  `ALLOC-SIGNAL`/`SIGNAL`/`FIND-TASK` plus an `MP` lock and a list
  suffice; if the pattern recurs, an `AMIGA.MUI:APPLICATION-MAILBOX`
  helper belongs in the runtime.  (Phase 2: the list and the signal did
  suffice; what the runtime needed was the GC-safe `AMIGA:WAIT-SIGNALS`
  for the task that waits on them.)
- Asynchronous `AREXX-SEND` in the platform layer if the client thread's
  cost shows in the spike numbers or under MT bench.
- Whatever the spike finds in the callback and `PEEK`/`POKE` hot path
  (a fused struct-field accessor for `IntuiMessage`, an
  `MUI_EventHandlerNode` builder).
- `EXT.DEV` verbs the port thread needs that the C editor implemented
  privately (none known; the C editor's port is plain MUI commands).
- The known soft spots will be hit: the open Amiga-only moving-GC
  corruption of a live VM-stack local, and the m68k JIT's lack of
  safepoints under a second Lisp thread.  Both are in memory as OPEN;
  this is the workload that pins them.

## Repository layout after the port

```
clamacs/
  lisp/            the editor: clamacs.lisp (package, start), frontend.lisp
                   (the protocol), frontend-mui.lisp, text.lisp, mini.lisp,
                   keymap.lisp, commands.lisp, indent.lisp, sexp.lisp,
                   token.lisp, transport.lisp, transport-arexx.lisp,
                   port.lisp, diag.lisp, repl.lisp, debugger.lisp,
                   inspector.lisp, menu.lisp, snapshot.lisp
  tests/           host tests: run by ../build/host/clamiga (pure modules,
                   the data of today's test_*.c), also under
                   CLAMIGA_GC_STRESS=1
  verify/realamiga drive.rexx, run-drive, sendkey.c (stays C: a 68k CLI
                   tool), the FS-UAE configs -- unchanged
  scripts/         save-editor-image.lisp, verify-editor-image.lisp
  specs/ docs/     this file; clamacs-ide.md as the behaviour spec
```

The repository stays a submodule of cl-amiga: its pin still says which
editor a release ships, its history and harness stay whole, and the
release script keeps one place to look.  No `Makefile.cross`,
`Makefile.mos`, `vendor/texteditor` (the MUI struct offsets the editor
needs are constants in `lib/amiga/mui.lisp`, checked against the
generated raw module by cl-amiga's own test) or toolchain dependency
remain; `sendkey` is built by the superproject's toolchain from
`verify/realamiga/`.

## Testing

- **Host**: `make test` runs the pure modules' tests under
  `../build/host/clamiga --non-interactive` (the superproject's build,
  as the FS-UAE leg already depends on it), and again with
  `CLAMIGA_GC_STRESS=1` so allocation in the editor's logic is exercised
  under compaction.  The dispatcher plumbing is host-testable too: on the
  host, hooks and dispatchers are libffi callbacks and cl-amiga's
  `tests/test_amiga_boopsi.lisp` drives that path without an Amiga.
- **FS-UAE**: `run-drive` and `drive.rexx` unchanged, plus a lowend leg
  (`verify-8mb.fs-uae`) that only checks the editor starts from its
  image, opens a file and quits.
- **Hardware**: the Vampire and the MorphOS box through the `vamp` and
  `mos` MCP servers, for qualifiers, timing and memory as before; the
  spike's numbers are re-taken there at every phase gate.
- **The image**: `verify-editor-image.lisp` starts the editor from
  `clamacs.img` unattended (`*event-loop-timeout*`), checks
  `ext:*image-restored-p*`, opens a window and exits; the release smoke
  test runs it, as it runs `verify-boot-image.lisp` for the runtime.

## Release

`bin/<target>/clamacs.img` beside `clamiga` and `clamiga.img`, per build,
saved in FS-UAE from the staged layout for aos3 and aos3-fpu and
natively for mos.  `lib/clamacs/*.fasl`.  The three root launchers keep
their names; `Clamacs` runs `bin/<target>/clamiga --image
bin/<target>/clamacs.img`.  TextEditor.mcc's floor (15.29) and MUI 3.8's
`muimaster.library` 19 are checked at `start`, as now.  Versions: the
editor is released with the runtime it was saved by, so the "oldest
clamiga it works with" check collapses to the image fingerprint on the
editor side, while the `VERSION` check against the *target* clamiga
stays.

## A host frontend (Mac)

Asked on 2026-09-16: could Clamacs also run on the Mac?  Nothing in the
Emacs layer, the wire protocol or the runtime prevents it, and the two
abstractions above are exactly what it takes.  What is *not* in the
phases 0-5 plan, and why:

- **Toolkit.**  MUI and TextEditor.mcc do not exist on the host.  The
  candidates, in order of fit: **Tk** through a `wish` process (the Ltk
  model: pure Lisp, a wire of Tcl strings over a pipe or socket; Tk's text
  widget with tags is TextEditor.mcc's equivalent, and its entry, listbox,
  menu and file dialog are the rest of the protocol -- the closest match
  to MUI's shape by far); **Cocoa** through the FFI (`objc_msgSend`,
  delegates as callbacks, the run loop: everything the runtime can do,
  and months of it); **SDL2** (means writing the text widget: no);
  **the terminal** (cl-charms already runs on the host under a PTY, so a
  curses frontend is cheap and would run on the Amiga console too, but it
  is not "on the Mac" in the sense asked).  Tk it would be.
- **Wire.**  ARexx is Amiga-only.  The command layer is already
  transport-agnostic (`AMIGA.AREXX` is "the transport half only"; the
  verbs are host-tested), so the host side is a line-oriented TCP server
  in cl-amiga (`lib/dev-tcp.lisp`, over the existing sockets) and a
  socket transport in the editor.  The inbound REPL traffic uses the same
  connection.  This is a small runtime commit and is also what a Mac user
  driving an *Amiga* clamiga over the network would use.
- **Runtime gaps to expect.**  A `wish` child process needs
  `ext:run-program` with piped streams, or the user starts `wish` and the
  editor connects over TCP (Tk can listen on a socket; the latter needs
  nothing new).  Keyboard modifiers on the host come as Tk event fields,
  not raw codes, so the decoder gets a second implementation behind the
  same key encoding.
- **Audience.**  On the Mac the user already has SLY and ICL against
  clamiga.  A host Clamacs is a portability and dog-food exercise, and it
  is the second audience; it must not slow the first.  What phases 1-5
  owe it is only the discipline above, and a host frontend is a phase of
  its own once parity is declared, with its own spec.

## Open

- **Vampire run of phase 3 (2026-09-18, muimaster 19.35, TextEditor.mcc
  15.50): 60 OK, two findings.**  (1, FIXED 2026-09-18 late) MUI *did*
  call the Lisp editor's `MUIA_String_EditHook` -- from input.device's
  task, once per key into the active String, where the runtime answers
  a callback with 0 without running it (the foreign-task rule of
  cl-amiga's `specs/mui-bindings.md` §10.3.2), so `*mini-trace*` saw
  nothing and the handler node only key releases: the HARDWARE leg's
  raw TAB, C-g, Alt-x and isearch keys into the active minibuffer were
  lost, where the C editor's identical hook -- C, indifferent to the
  task -- is called on the same box.  Proven with the runtime's new
  `(ext:%ffi-foreign-task-calls)` over the port: 0 before, 8 after
  typing eight characters into the prompt, 9 after TAB.  The fix is a
  runtime feature, `mui:make-string-key-hook`: a hook that is C from
  end to end, matching raw code + qualifiers against a table the editor
  fills from the keymap once (`mini-hook-entries`: every raw code under
  each of none / Shift / Control / Alt / their Shift combinations,
  decoded by `rawkey-decode`, kept when `minibuffer-ever-binds-p` or a
  Meta character) and pushing the key to the mini object as
  `CKM_MiniKey` through `MUIM_Application_PushMethod`, back on the
  application's task.  The Lisp edit-hook function, the `hook_taken` /
  `hook_key` instance slots and the `:hook` trace records are gone with
  it; `mui:string-key-hook-stats` on a document's hook is the
  diagnostic now.  (2, CLOSED 2026-09-20: not a bug of ours) A
  layout-dependent failure of FASL-loaded code on the box only:
  `complete`'s `mismatch` call saw a non-symbol where `:end1` should be,
  with a different garbage error each time; the FASL file was good, a
  fresh in-process compile fine, the JIT not involved, and a reboot made
  it go away for the day.  Two days of hunting in cl-amiga (the stack
  swap, exec's context save, the GC roots -- all exonerated) ended at
  the hardware: the Apollo 68080 core loses the last store of a
  memory-to-memory `move.l <abs>,(aN)+` followed by further stores,
  decided by the address of the absolute source modulo 64 -- so a data
  hunk that LoadSeg placed differently flips the same binary between
  sound and broken per LAUNCH, and the untouched C local of
  `bi_mismatch` (its `key_fn`) showed whatever the previous frame left
  there.  A real 68040 and a real 68060 are clean.  There is no software
  fix; clamiga's startup self-test (`src/platform/cpu_store_probe_m68k.s`,
  README "CPU store self-test") warns on such a launch and puts
  `:CPU-LOST-STORES` on `*FEATURES*`, `verify/realamiga/apollo-repro.c`
  is the report to the Apollo team.  Consequence for this port: a
  hardware run on the Vampire is meaningful only on a launch the
  self-test did not flag, so `drive.rexx` asks both ports for the
  feature before driving anything and fails such a run by name
  (`verify/realamiga/run-lisp-drive` is that run, in the repository now).
  The editor's host suite on the box (`Clamacs:tests/run-tests.lisp`)
  stays the reproduction vehicle for anything that survives that
  filter.  (3, FIXED 2026-09-18) Disposing a
  document window signalled, on the box and -- unseen, nobody looked at
  the screen after a quit -- in FS-UAE: every exit left an orphan
  diagnostics window, since the condition escaped `start`'s teardown
  before the application was disposed of, and a `kill-buffer` over the
  port reaped the same window twice and froze the machine.  The
  condition, `FFI:FREE-FOREIGN: pointer was not allocated by FFI`:
  ClamacsMini's OM_DISPOSE kept only the address of its edit hook and
  rebuilt an unowned pointer to free it, which `free-foreign` refuses
  (only the object `alloc-foreign` returned owns its memory).  The hook
  object now lives in a table on the editor keyed by the mini object's
  address, freed after the String's dispose; the teardown forgets a
  window before disposing of it, catches what a dispose signals and logs
  it to `T:clamacs-exit.log` (`*exit-trace*` logs every step there; what
  a `Run >log` clamiga prints never reaches the log on AmigaOS), and
  disposes of the diagnostics window itself.  Pinned by three checks:
  `drive.rexx` closes the second document over the port and reopens it
  (the mid-run reap), `quit.rexx` switches the trace on before the quit
  and fails on any `signalled` line or a log that does not end with the
  application disposed, and `run-lisp-editor.sh` closes its one buffer
  with `C-x k` (the keyboard path; the last window's close is the exit)
  and reads the same log.
- The MorphOS run of phases 2 and 3.
- The MorphOS column of the spike (box unreachable on 2026-09-16).
- Whether the client thread or an asynchronous platform send is the
  better shape; the spike did not exercise the wire.
- The runtime items the spike raised (character-scan cost, GC pause vs
  live set, off-heap footprint, the silent `CLAMIGA_MEM_DIAG`).
- Whether `EXT.DEV:HANDLE-COMMAND`'s process-wide table is right for an
  editor instance whose port answers `LOAD` and `EVAL` too.  It is
  useful (a macro can evaluate editor commands) and harmless (it is the
  editor's own heap), so the default is to keep it and document it.
- Encoding beyond ISO-8859-1 stays out of scope until the wide-string
  build ships, as in `clamacs-ide.md`.
