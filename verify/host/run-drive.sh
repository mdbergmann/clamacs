#!/bin/sh
# run-drive.sh -- the host editor's acceptance run (specs/clamacs-host.md,
# phase H2): the twin of verify/realamiga/run-lisp-drive.sh.
#
# Builds the frontend, starts the editor on sample.lisp with a HOME and a
# TMPDIR of the run's own (so its init file, its layout file and its port
# files touch nothing of the user's), waits for its port, checks the port
# files' modes, and runs verify/host/drive.lisp against the port -- the
# same legs as drive.rexx, against a second clamiga the editor STARTS on
# the binary it runs on (`Start clamiga', phase H5; the editor stops it
# again at its exit, which this script checks in its log) -- and which
# quits the editor at the end.  Then a SECOND editor is started against the
# layout file the drive wrote, with a TMPDIR of its own, and the drive's
# `second' mode reads where it came up over ITS port and quits it.
#
#   verify/host/run-drive.sh            under ../build/host/clamiga
#   GCSTRESS=1 verify/host/run-drive.sh under ../build/host-gcstress/clamiga
#   MEMTRACK=1 verify/host/run-drive.sh under ../build/host-memtrack/clamiga
#                                       (the superproject's `make test-memleak`
#                                       build) with CLAMIGA_MEM_DIAG=1: both
#                                       editors must end with every off-heap
#                                       block handed back -- the shutdown
#                                       criterion of phase H4
#   CLAMIGA=... names another binary.
#
# Result: build/host-frontend/drive/drive.log (the drive's OK/FAIL/INFO
# lines and the script's own), editor-a.log, editor-b.log.  The verdict
# is a log without FAIL lines that has both DRIVE-DONE and the second
# editor's OK lines.  Needs a window server (a logged-in session).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
super=$(cd "$root/.." && pwd)
out="$root/build/host-frontend/drive"

if [ "${GCSTRESS:-0}" = 1 ]; then
    clamiga=${CLAMIGA:-"$super/build/host-gcstress/clamiga"}
    CLAMIGA_GC_STRESS=1
    export CLAMIGA_GC_STRESS
    factor=10
elif [ "${MEMTRACK:-0}" = 1 ]; then
    clamiga=${CLAMIGA:-"$super/build/host-memtrack/clamiga"}
    CLAMIGA_MEM_DIAG=1
    export CLAMIGA_MEM_DIAG
    factor=1
else
    clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
    factor=1
fi
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)"; exit 1; }

"$root/host/build.sh" || exit 1
rm -rf "$out"
mkdir -p "$out/home" "$out/tmp-a" "$out/tmp-b" "$out/scratch"
log="$out/drive.log"
cfg="$out/home/.clamacs-windows.cfg"

# stat's mode spelling differs between the BSDs and GNU.  GNU first: BSD stat
# rejects -c, so it falls through to -f %Lp, whereas GNU stat accepts -f
# (filesystem status) and would answer something else for %Lp.
file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

wait_for_file() {
    # $1 file, $2 seconds
    n=0
    while [ ! -f "$1" ]; do
        [ "$n" -ge "$2" ] && return 1
        sleep 1
        n=$((n + 1))
    done
    return 0
}

wait_for_exit() {
    # $1 pid, $2 seconds, $3 name
    n=0
    while kill -0 "$1" 2>/dev/null; do
        if [ "$n" -ge "$2" ]; then
            echo "FAIL $3 did not exit within $2 s" >>"$log"
            kill "$1" 2>/dev/null
            return 1
        fi
        sleep 1
        n=$((n + 1))
    done
    return 0
}

check_leaks() {
    # $1 editor log, $2 name.  A DEBUG_MEM_TRACK build under
    # CLAMIGA_MEM_DIAG=1 prints what is still allocated at exit, with the
    # file:line of every block; any build without the line is not checked.
    if grep -q '\[mem\] leak report:' "$1"; then
        if grep -q '\[mem\] leak report: 0 block(s), 0 bytes' "$1"; then
            echo "OK $2 handed every off-heap block back at exit" >>"$log"
        else
            echo "FAIL $2 leaked off-heap memory at exit:" >>"$log"
            grep '\[mem\]' "$1" >>"$log"
        fi
    elif [ "${MEMTRACK:-0}" = 1 ]; then
        echo "FAIL $2 printed no leak report (not a DEBUG_MEM_TRACK build?)" >>"$log"
    fi
}

start_editor() {
    # $1 tmpdir, $2 log, $3 file
    HOME="$out/home" TMPDIR="$1" \
        "$clamiga" --no-userinit --heap 32M --non-interactive \
        --load "$root/lisp/clamacs.lisp" -- "$3" </dev/null >"$2" 2>&1 &
    echo $!
}

run_drive() {
    # $1 tmpdir, $2 mode
    CLAMACS_DRIVE_DIR="$1/" CLAMACS_DRIVE_ROOT="$root/" \
    CLAMACS_DRIVE_TMP="$out/scratch/" CLAMACS_DRIVE_CFG="$cfg" \
        "$clamiga" --no-userinit --heap 16M --non-interactive \
        --load "$here/drive.lisp" -- "$2" </dev/null 2>&1 | grep -v '^; Loading' >>"$log"
}

echo "=== run start ===" >"$log"

# --- the editor, and its port files ------------------------------------
pid_a=$(start_editor "$out/tmp-a" "$out/editor-a.log" "$root/verify/realamiga/sample.lisp")
if ! wait_for_file "$out/tmp-a/clamacs-port" $((60 * factor)); then
    echo "FAIL the editor wrote no port file within $((60 * factor)) s" >>"$log"
    kill "$pid_a" 2>/dev/null
    cat "$log"; cat "$out/editor-a.log"
    exit 1
fi
for f in clamacs-port clamacs-token; do
    mode=$(file_mode "$out/tmp-a/$f")
    if [ "$mode" = 600 ]; then
        echo "OK $f is mode 0600" >>"$log"
    else
        echo "FAIL $f is mode $mode, not 0600" >>"$log"
    fi
done

# --- the drive, which quits the editor at the end ----------------------
run_drive "$out/tmp-a" main
wait_for_exit "$pid_a" $((60 * factor)) "the editor"
if [ -f "$out/tmp-a/clamacs-port" ] || [ -f "$out/tmp-a/clamacs-token" ]; then
    echo "FAIL the port files are still there after the editor exited" >>"$log"
else
    echo "OK the port files are gone after the editor exited" >>"$log"
fi
if grep -q 'the page reported' "$out/editor-a.log"; then
    echo "FAIL the page reported an error (editor-a.log)" >>"$log"
fi
check_leaks "$out/editor-a.log" "the editor"

# --- the clamiga the editor started, stopped again at its exit ---------
started_log="$out/tmp-a/clamacs-clamiga.log"
if [ -f "$started_log" ]; then
    n=0
    while ! grep -q '^; clamiga stopped' "$started_log"; do
        if [ "$n" -ge 15 ]; then break; fi
        sleep 1
        n=$((n + 1))
    done
    if grep -q '^; clamiga stopped' "$started_log"; then
        echo "OK the clamiga the editor started stopped with the editor" >>"$log"
    else
        echo "FAIL the clamiga the editor started did not stop within 15 s (clamacs-clamiga.log)" >>"$log"
    fi
    if grep -q '^ERROR' "$started_log"; then
        echo "FAIL the started clamiga reported an error (clamacs-clamiga.log):" >>"$log"
        grep '^ERROR' "$started_log" >>"$log"
    fi
    check_leaks "$started_log" "the started clamiga"
else
    echo "FAIL the editor started no clamiga (no $started_log)" >>"$log"
fi

# --- the second editor, against the layout file the drive wrote --------
if [ -f "$cfg" ]; then
    pid_b=$(start_editor "$out/tmp-b" "$out/editor-b.log" "$root/verify/realamiga/sample2.lisp")
    run_drive "$out/tmp-b" second
    wait_for_exit "$pid_b" $((60 * factor)) "the second editor"
    check_leaks "$out/editor-b.log" "the second editor"
    rm -f "$cfg"
    if [ -f "$cfg" ]; then
        echo "FAIL the layout file could not be deleted" >>"$log"
    else
        echo "OK the layout file is gone again" >>"$log"
    fi
else
    echo "FAIL the drive left no layout file for the second editor" >>"$log"
fi

echo "=== run end ===" >>"$log"

# --- the verdict --------------------------------------------------------
cat "$log"
fails=$(grep -c '^FAIL' "$log")
oks=$(grep -c '^OK' "$log")
if [ "$fails" -ne 0 ]; then
    echo "=== FAIL: $fails FAIL line(s), $oks OK ==="
    echo "--- editor-a.log ---"; grep -v '^; Loading' "$out/editor-a.log"
    [ -f "$out/tmp-a/clamacs-clamiga.log" ] && { echo "--- clamacs-clamiga.log ---"; grep -v '^; Loading' "$out/tmp-a/clamacs-clamiga.log"; }
    exit 1
fi
if ! grep -q '^DRIVE-DONE' "$log"; then
    echo "=== FAIL: no DRIVE-DONE ==="
    exit 1
fi
if ! grep -q '^OK the second editor quit' "$log"; then
    echo "=== FAIL: the second editor leg did not finish ==="
    exit 1
fi
echo "=== PASS: $oks OK lines, no FAIL ==="
exit 0
