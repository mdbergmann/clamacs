#!/bin/sh
# run.sh -- start the host editor on the given files (specs/clamacs-host.md).
#
#   host/run.sh [file ...]          the editor from source
#   IMAGE=1 host/run.sh [file ...]  the editor from its heap image,
#                                   build/host-frontend/clamacs.img (made by
#                                   host/make-image.sh when it is missing)
#
# Builds what is missing under build/host-frontend/ (host/build.sh) and
# runs the editor under the superproject's host clamiga; CLAMIGA=... names
# another binary.  The files follow `--' on clamiga's command line, as they
# do for the Amiga launcher; `-- --bind ADDR' is the editor's own option.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
super=$(cd "$root/.." && pwd)
clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)" >&2; exit 1; }
"$here/build.sh" >/dev/null || exit 1
if [ "${IMAGE:-0}" = 1 ]; then
    img="$root/build/host-frontend/clamacs.img"
    # An image is the binary's own: one older than the binary is remade.
    if [ ! -f "$img" ] || [ "$clamiga" -nt "$img" ]; then
        CLAMIGA="$clamiga" "$here/make-image.sh" >/dev/null || exit 1
    fi
    exec "$clamiga" --heap 32M --non-interactive --image "$img" --eval "(clamacs::run)" -- "$@"
fi
exec "$clamiga" --heap 32M --non-interactive --load "$root/lisp/clamacs.lisp" -- "$@"
