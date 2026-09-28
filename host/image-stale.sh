#!/bin/sh
# image-stale.sh -- whether the editor's heap image must be remade.
#
#   host/image-stale.sh IMAGE CLAMIGA     exit 0 = stale (remake it)
#   host/image-stale.sh --selftest        run this script's own regression test
#
# An image holds the editor as it was when it was saved, so it is out of
# date when it is missing, older than the clamiga binary it was saved by,
# or older than any of the editor's Lisp sources (lisp/*.lisp and the
# image scripts).  The binary alone was the test once, and a Clamacs.app
# built after a lisp/ change shipped the previous editor.
#
# IMAGE_STALE_ROOT overrides the checkout root the lisp/scripts search
# runs under; --selftest uses it to point the check at a scratch tree
# instead of this checkout, with no emulator or GUI involved.

here=$(cd "$(dirname "$0")" && pwd)
root=${IMAGE_STALE_ROOT:-$(cd "$here/.." && pwd)}

selftest() {
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT INT TERM
    mkdir -p "$tmp/lisp" "$tmp/scripts"
    img="$tmp/clamacs.img"
    bin="$tmp/clamiga"
    lispfile="$tmp/lisp/foo.lisp"
    fail=0

    check() {
        want=$1
        desc=$2
        IMAGE_STALE_ROOT="$tmp" "$here/image-stale.sh" "$img" "$bin" >/dev/null 2>&1
        got=$?
        if [ "$got" -ne "$want" ]; then
            echo "FAIL: $desc -- expected exit $want, got $got"
            fail=1
        fi
    }

    rm -f "$img" "$bin" "$lispfile"
    check 0 "missing image is stale"

    touch "$bin"
    touch "$lispfile"
    sleep 1
    touch "$img"
    check 1 "image newer than binary and lisp sources is not stale"

    sleep 1
    touch "$bin"
    check 0 "binary newer than image is stale"

    touch "$bin"
    touch "$img"
    sleep 1
    touch "$lispfile"
    check 0 "lisp source newer than image is stale"

    if [ "$fail" -eq 0 ]; then
        echo "image-stale.sh selftest: PASS"
    fi
    exit "$fail"
}

[ "$1" = "--selftest" ] && selftest

img=$1
clamiga=$2

[ -f "$img" ] || exit 0
[ "$clamiga" -nt "$img" ] && exit 0
if find "$root/lisp" "$root/scripts" -name '*.lisp' -newer "$img" | grep -q .; then
    exit 0
fi
exit 1
