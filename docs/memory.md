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

## Conclusion

No `--lowmem` mode is needed for phase 1 on this configuration.  The figure
to watch as later phases add windows is the largest *contiguous* fast block,
which the run above shows falling from 3.4 MB to 2.5 MB: fragmentation, not
exhaustion, is what a REPL and a debugger window are most likely to hit
first on a machine this size.
