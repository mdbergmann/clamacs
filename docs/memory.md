# Memory use on a small machine

specs/clamacs-ide.md asks phase 1 to measure the editor on an 8 MB
configuration and record the number, so the decision about whether a
`--lowmem` mode is needed rests on data rather than a guess.

## Method

`verify/realamiga/verify-8mb.fs-uae`: AmigaOS 3.1, A1200 / 68020,
2 MB chip + 8 MB fast, **no Zorro III**, cycle-accurate, no JIT.  The boot
script takes three `avail` readings — before clamacs starts, while it is
running, and after it has exited — and the middle one is the answer.  Taking
only a before/after pair would measure what MUI declines to give back, not
what the editor costs.

Reproduce with:

    make -f Makefile.cross amiga
    verify/realamiga/run-fs-uae.sh verify/realamiga/verify-8mb.fs-uae

State at the measurement: two documents open (`sample.lisp` and
`sample2.lisp`, both in Lisp mode with syntax colouring applied), the
diagnostics window created but closed, ARexx running, one editor command
just executed.

## Result (2026-09-08, TextEditor.mcc 15.56, MUI 3.8)

| Reading | Chip free | Fast free | Largest fast block |
|---------|-----------|-----------|--------------------|
| Before clamacs | 2,040,288 | 3,589,384 | 3,463,600 |
| clamacs running | 2,038,248 | 2,550,304 | 2,525,312 |
| After it exited | 2,044,968 | 3,182,128 | 2,763,584 |

**clamacs costs about 1.0 MB of fast RAM (1,039,080 bytes) and 2 KB of chip
RAM** with two Lisp documents open.

Two things that reading does not say, and should not be mistaken for:

- The 8 MB machine had only 3.5 MB free to begin with: Workbench, MUI,
  Picasso96 and the shell had already taken 4.8 MB before clamacs was
  launched.  The editor's 1 MB therefore leaves roughly 2.5 MB, which is why
  the full test still passes here.
- About 400 KB of the 1 MB is not returned at exit.  That is MUI keeping the
  classes it loaded (muimaster plus the MCCs, TextEditor.mcc among them)
  resident until an expunge, not a leak in the editor — the next clamacs
  start reuses them.

## The editor fits on 8 MB.  The editor *and* a Lisp do not.

The same run tries to start a `clamiga` alongside the editor, and on this
configuration it never gets far enough to open its ARexx port — with a 4 MB
heap or a 2 MB one, started before clamacs or after.  The integration leg is
skipped and the harness says so.

That is not a clamacs bug and not a clamiga bug; it is arithmetic.  Of the
8 MB fast RAM, Workbench, MUI and Picasso96 have taken 4.8 MB before either
program starts, which leaves about 3.5 MB.  The editor's 1 MB leaves 2.5 MB
in a largest contiguous block of about 1.4 MB, and a Lisp heap needs one
contiguous block plus room for the 800 KB binary and its compilation of
`lib/amiga/arexx.lisp` from source.

So the honest statement of the target is:

- **clamacs alone on a stock 8 MB A1200: yes.**  Editing, Lisp mode,
  navigation and its own ARexx port all verified there.
- **clamacs plus clamiga: needs more than 8 MB.**  The verified
  configuration is `verify/realamiga/verify.fs-uae` — the same A1200/68020,
  plus the 16 MB Zorro III block that stands for accelerator RAM.  That is
  also the configuration cl-amiga's own suite uses, for the same reason.

This is worth knowing before phase 3: the REPL, debugger and inspector
windows all assume a clamiga on the same machine, so they inherit this
floor rather than the editor's.

## Conclusion

No `--lowmem` mode is needed for phase 1: the editor's own footprint is not
the constraint.  The figure to watch as later phases add windows is the
largest *contiguous* fast block, which the run above shows falling from
3.4 MB to 1.4 MB with two documents open — fragmentation, not exhaustion, is
what a REPL and a debugger window will hit first on a machine this size.
