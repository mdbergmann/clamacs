#!/bin/sh
# make-image.sh -- save the host editor's heap image and prove it starts
# the editor (specs/clamacs-host.md, phase H6): the host twin of cl-amiga's
# verify/realamiga/make-editor-image.sh.
#
#   host/make-image.sh            under ../build/host/clamiga
#   CLAMIGA=... names another binary
#
# Heap images are per-build, so the binary that will start from the image
# writes it: the editor is loaded from source with the host frontend
# (scripts/save-editor-image.lisp does the dump, nothing OS-owned in it --
# no window, no library, no port), and the image lands beside the page and
# the two libraries as build/host-frontend/clamacs.img, where
# `IMAGE=1 host/run.sh' and host/make-app.sh take it from.  Then a second
# run restores it under a HOME and a TMPDIR of its own and runs
# scripts/verify-editor-image.lisp: the editor comes up from the image,
# re-derives the user's paths from THAT home (the image holds this one's),
# opens its window, sends the menu, quits.  Needs a window server.
#
# The verdict is EDITOR-IMAGE-VERIFIED in the log, never the exit code
# alone (a --load recovers form by form).  build/host-frontend/make-image.log
# keeps both runs' output.
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
super=$(cd "$root/.." && pwd)
clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)" >&2; exit 1; }

"$here/build.sh" >/dev/null || exit 1
out="$root/build/host-frontend"
img="$out/clamacs.img"
log="$out/make-image.log"
rm -f "$img"

fail() {
    echo "make-image.sh: $1" >&2
    echo "--- $log ---" >&2
    grep -v '^; Loading' "$log" >&2
    rm -f "$img"
    exit 1
}

# --- save: from the directory the image goes to, the frontend files bound
# before load.lisp picks the list (the same binding lisp/clamacs.lisp makes).
(cd "$out" && "$clamiga" --no-userinit --no-image --heap 32M --non-interactive --boot-log \
    --eval '(defvar cl-user::*clamacs-frontend-files* (list "frontend-host" "transport-host" "transport-tcp"))' \
    --load "$root/lisp/load.lisp" \
    --load "$root/scripts/save-editor-image.lisp") </dev/null >"$log" 2>&1
grep -q '^; Image saved to' "$log" || fail "the save run wrote no image"
[ -s "$img" ] || fail "$img is missing or empty after the save"
grep -q 'IMAGE-FAILED' "$log" && fail "the save run reported a failure"

# --- verify: another HOME (the image was saved under this user's), a
# TMPDIR of its own for the port files, the window opened and closed.
home=$(mktemp -d "${TMPDIR:-/tmp}/clamacs-image-home.XXXXXX") || exit 1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/clamacs-image-tmp.XXXXXX") || exit 1
trap 'rm -rf "$home" "$tmp"' EXIT
echo "=== verify from $img ===" >>"$log"
(cd "$tmp" && HOME="$home" TMPDIR="$tmp" "$clamiga" --no-userinit --heap 32M --non-interactive --boot-log \
    --image "$img" --load "$root/scripts/verify-editor-image.lisp") </dev/null >>"$log" 2>&1
grep -E '^IMAGE-|^EDITOR-IMAGE|^; Image saved' "$log" | sed 's/^/    /'
grep -q 'IMAGE-FAILED' "$log" && fail "a check failed (see EDITOR-IMAGE-FAILED above)"
grep -q '^EDITOR-IMAGE-VERIFIED' "$log" || fail "the verify run did not print EDITOR-IMAGE-VERIFIED"
if [ -f "$tmp/clamacs-port" ] || [ -f "$tmp/clamacs-token" ]; then
    fail "the verify run left its port files behind"
fi
echo "=== $img: $(wc -c < "$img" | tr -d ' ') bytes, the editor started from it ==="
exit 0
