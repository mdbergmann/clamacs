#!/bin/sh
# shots.sh -- the host editor's screenshots for the README (macOS).
#
#   verify/host/shots.sh [OUT-DIR]      default OUT-DIR: docs/screenshots
#
# Starts the editor the way run-drive.sh does (a HOME and a TMPDIR of the
# run's own, so nothing of yours is touched), then runs verify/host/shots.lisp
# against its port: it starts a clamiga, loads verify/host/shots/accounts.lisp,
# evaluates, breaks, inspects, loads report.lisp with its mistakes, picks a
# theme, and photographs the window each time with `screencapture'.  The
# terminal this runs in needs the Screen Recording permission (System
# Settings > Privacy & Security > Screen & System Audio Recording), and
# nothing else should be put over the editor's window while it runs.
#
# The two fixtures are copied to a short-named run-private directory first:
# the diagnostics rows and the backtrace name the file by its full path, and
# a short one reads better in a picture than this checkout's.
#
# Result: host-editor.png, host-debugger.png, host-inspector.png,
# host-diagnostics.png and host-completion.png under OUT-DIR; the run's log
# is build/host-frontend/shots/shots.log (no FAIL line and a SHOTS-DONE line).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
super=$(cd "$root/.." && pwd)
clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)"; exit 1; }
[ "$(uname -s)" = Darwin ] || { echo "shots.sh takes the Mac editor's pictures; this is $(uname -s)"; exit 1; }
outdir=$(cd "${1:-$root/docs/screenshots}" && pwd) || exit 1

"$root/host/build.sh" || exit 1
run="$root/build/host-frontend/shots"
rm -rf "$run"
mkdir -p "$run/home" "$run/tmp" "$run/scratch"
log="$run/shots.log"
ledger=$(mktemp -d /tmp/ledger.XXXX) || exit 1
trap 'rm -rf "$ledger"' EXIT
cp "$here/shots/accounts.lisp" "$here/shots/report.lisp" "$ledger/" || exit 1

HOME="$run/home" TMPDIR="$run/tmp" \
    "$clamiga" --no-userinit --heap 32M --non-interactive \
    --load "$root/lisp/clamacs.lisp" -- "$ledger/accounts.lisp" \
    </dev/null >"$run/editor.log" 2>&1 &
pid=$!

n=0
while [ ! -f "$run/tmp/clamacs-port" ]; do
    if [ "$n" -ge 60 ]; then
        echo "FAIL the editor wrote no port file within 60 s" | tee "$log"
        kill "$pid" 2>/dev/null
        cat "$run/editor.log"
        exit 1
    fi
    sleep 1
    n=$((n + 1))
done

CLAMACS_DRIVE_DIR="$run/tmp/" CLAMACS_DRIVE_ROOT="$root/" \
CLAMACS_DRIVE_TMP="$run/scratch/" CLAMACS_DRIVE_CFG="$run/home/.clamacs-windows.cfg" \
CLAMACS_DRIVE_RC="$run/home/.clamacsrc" \
CLAMACS_SHOTS_OUT="$outdir" CLAMACS_SHOTS_PID="$pid" CLAMACS_SHOTS_LEDGER="$ledger" \
    "$clamiga" --no-userinit --heap 16M --non-interactive \
    --load "$here/shots.lisp" -- shots </dev/null 2>&1 | grep -v '^; Loading' >"$log"

n=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge 30 ]; then
        echo "FAIL the editor did not exit within 30 s" >>"$log"
        kill "$pid" 2>/dev/null
        break
    fi
    sleep 1
    n=$((n + 1))
done

cat "$log"
if grep -q '^FAIL' "$log" || ! grep -q '^SHOTS-DONE' "$log"; then
    echo "=== shots: FAILED (see $log, $run/editor.log)"
    exit 1
fi
echo "=== shots: done, pictures under $outdir"
