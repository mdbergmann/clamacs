#!/bin/sh
# run-lisp-tests.sh -- the Lisp editor's pure-module tests on the host.
#
#   tests/run-lisp-tests.sh [clamiga-binary]
#
# Runs tests/run-tests.lisp under the superproject's host clamiga (the
# default binary; the FS-UAE leg depends on the superproject the same way)
# and decides on the verdict LINE, never on the exit code alone: clamiga's
# LOAD recovers form by form, so a file that failed to load would otherwise
# pass for a file without failing tests.  Any ERROR line fails the run too.
#
# CLAMACS_TEST=keymap runs one file; CLAMIGA_GC_STRESS=1 with a
# DEBUG_GC_STRESS binary (the superproject's build/host-gcstress) forces a
# compaction at every allocation.

here=$(cd "$(dirname "$0")" && pwd)
clamiga=${1:-$here/../../build/host/clamiga}

if [ ! -x "$clamiga" ]; then
    echo "NOTE: no clamiga at $clamiga -- Lisp tests SKIPPED"
    echo "      (run \`make host' in the superproject first)"
    exit 0
fi

out=$("$clamiga" --no-userinit --heap 16M --script "$here/run-tests.lisp" \
      </dev/null 2>&1)
echo "$out" | grep -v '^; Loading'

if echo "$out" | grep -q '^ERROR'; then
    echo "=== an ERROR line in the output: FAILED ==="
    exit 1
fi
if [ "$(echo "$out" | tail -1)" != "CLAMACS-LISP-TESTS: PASS" ]; then
    echo "=== no PASS verdict: FAILED ==="
    exit 1
fi
exit 0
