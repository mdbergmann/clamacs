#!/bin/sh
# run-smoke.sh -- build the host frontend's ground and run its smoke run
# (verify/host/smoke.lisp) unattended; phase H0's gate.
#
#   verify/host/run-smoke.sh            under ../build/host/clamiga
#   GCSTRESS=1 verify/host/run-smoke.sh under ../build/host-gcstress/clamiga
#                                       with a compaction at every allocation
#   CLAMIGA=... names another binary.
#
# The verdict is the LAST LINE (SMOKE: PASS), as for the Lisp tests: a
# --load recovers form by form, so the exit code alone would pass a script
# that failed to read.  Needs a window server (a logged-in session).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
super=$(cd "$root/.." && pwd)

if [ "${GCSTRESS:-0}" = 1 ]; then
    clamiga=${CLAMIGA:-"$super/build/host-gcstress/clamiga"}
    CLAMIGA_GC_STRESS=1
    export CLAMIGA_GC_STRESS
else
    clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
fi
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)"; exit 1; }

"$root/host/build.sh" || exit 1

out=$("$clamiga" --no-userinit --heap 32M --non-interactive --load "$here/smoke.lisp" </dev/null 2>&1)
rc=$?
echo "$out" | grep -v '^; Loading'
if [ "$(echo "$out" | tail -1)" != "SMOKE: PASS" ]; then
    echo "=== no PASS verdict (exit $rc): FAILED ==="
    exit 1
fi
exit 0
