#!/bin/sh
# run.sh -- start the host editor on the given files (specs/clamacs-host.md).
#
#   host/run.sh [file ...]
#
# Builds what is missing under build/host-frontend/ (host/build.sh) and
# runs the editor from source under the superproject's host clamiga;
# CLAMIGA=... names another binary.  The files follow `--' on clamiga's
# command line, as they do for the Amiga launcher.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
super=$(cd "$root/.." && pwd)
clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)" >&2; exit 1; }
"$here/build.sh" >/dev/null || exit 1
exec "$clamiga" --heap 32M --non-interactive --load "$root/lisp/clamacs.lisp" -- "$@"
