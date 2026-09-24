#!/bin/sh
# Run the host-frontend spike with the superproject's host clamiga.
#   run.sh          opens the window; type into it (C-x, M-f go to Lisp,
#                   the echo line shows what Lisp saw); close the window to exit
#   run.sh auto     unattended: the page reports ready, Lisp inserts text and
#                   injects C-x, the key comes back, Lisp terminates the loop;
#                   the last line is SPIKE-RESULT: PASS
# CLAMIGA=... names another binary (build/host-gcstress/clamiga with
# CLAMIGA_GC_STRESS=1 runs it with a compaction at every allocation).
set -e
here=$(cd "$(dirname "$0")" && pwd)
clamiga=${CLAMIGA:-"$here/../../../build/host/clamiga"}
[ -f "$here/build/page.html" ] || "$here/build.sh"
exec "$clamiga" --non-interactive --load "$here/spike.lisp" -- "$@" </dev/null
