# Auto-review gate

A `pre-commit` hook that (1) reviews your **staged** changes with a headless
`claude` and auto-fixes any problems it finds, then (2) runs the host test
suite. Problematic code never enters history. This is the same gate cl-amiga
uses, adapted to clamacs.

## Flow

```
git commit
   └─ githooks/pre-commit  →  scripts/review/pre-commit.sh
        1. staged diff written to .reviews/staged.diff; claude READS it
           (Read+Grep+Glob, no shell)          →  .reviews/log-<timestamp>.md
             STATUS: CLEAN   →  (go to step 2)
             STATUS: ISSUES  →  fix agent edits the staged files,
                                re-stages them  →  (go to step 2)
        2. make test  (host unit tests for the portable core)
             pass  →  commit proceeds
             fail  →  commit aborted; output saved to .reviews/last-test.log
```

**clamacs caveat.** `make test` builds and runs only the host suite — the
portable core under `src/emacs`, `src/lisp`, `src/rexx`. It does **not**
cross-compile the MUI half (`main`, `textclass`, `document`, `introspect`,
`rexxclient`, `rexxport`, `errorwin`); a break there shows only in
`make -f Makefile.cross amiga`, which needs the m68k toolchain and is slower.
The review step reads the whole staged diff, MUI half included, so it can
still catch a problem the host tests miss. To gate on the cross build too, set
`CLAUDE_TEST_TARGET` to a make target that runs it.

## Install (per clone)

Git never auto-runs repo-supplied hooks (cloning would otherwise execute
arbitrary code), so each clone activates it once:

```sh
make install-hooks
```

This sets a **relative** `core.hooksPath=githooks` (in `.git/config`, which is
local to the clone). The relative path resolves to `<repo-root>/githooks` in
every clone and survives the repo being moved. The tracked `githooks/pre-commit`
launcher then delegates to `scripts/review/pre-commit.sh`.

## Safety

- **Review + tests are mandatory (fail-closed)** — if the review or tests don't
  *complete* (missing `claude`/`make`, an error, or a timeout), the commit is
  *blocked*, never silently allowed. The only bypass is `git commit --no-verify`.
- **Diff delivered as a file, not piped** — the staged diff is written to
  `.reviews/staged.diff` and the reviewer is told to read it; headless
  `claude -p` stalls when a large diff is piped on stdin.
- **Partial-staging guard** — if a staged file also has *unstaged* edits, the
  hook leaves the fixes unstaged and aborts rather than sweeping them in.
- **Index guard** — the staged tree and HEAD are snapshotted before the
  reviewer, the fix agent and the tests run; a moved index is restored, a moved
  HEAD blocks the commit. The reviewer gets no shell (`Read,Grep,Glob`) for
  exactly this reason.
- **Fix agent only edits files in the commit** and records a `RESOLVED:` /
  `DISMISSED:` note per finding in that review's log file.

## Escape hatches

| Want | Do |
|------|----|
| Skip one commit (review + tests) | `git commit --no-verify` |
| Disable entirely | `export CLAUDE_AUTO_REVIEW=0` |
| Review + block, but don't auto-fix | `export CLAUDE_AUTO_FIX=0` |
| Change the review / fix model | `export CLAUDE_REVIEW_MODEL=…` / `CLAUDE_FIX_MODEL=…` |
| Change the test target | `export CLAUDE_TEST_TARGET=…` |
| Skip tests only | `export CLAUDE_RUN_TESTS=0` |

The `.reviews/` directory (logs, the staged diff, the last test log) is
git-ignored.
