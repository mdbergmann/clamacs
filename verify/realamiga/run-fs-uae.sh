#!/bin/sh
# run-fs-uae.sh [CONFIG]
#
# Boot AmigaOS 3 in FS-UAE, run clamacs, drive it through its own ARexx port
# and quit -- fully unattended.  Modelled on cl-amiga's harness of the same
# name, and it borrows two things from that repository on purpose rather than
# duplicating them:
#
#   * the Workbench image (verify/realamiga/aos3), which already has MUI and
#     TextEditor.mcc installed, and
#   * the boot hook: that system's S/user-startup ends with
#         execute CLAmiga:verify/realamiga/call-on-ustartup
#     and call-on-ustartup runs CLAmiga:build/amiga/boot-override instead of
#     its own suite when one is present.  It consumes the file (copies it to
#     RAM: and deletes it) before executing, so what we drop there cannot
#     hijack a later cl-amiga run.
#
# Shutdown has the same three paths as the cl-amiga script: a clean UAEquit
# from the boot script, a sentinel kill once "=== run end ===" appears, and a
# stall/hard timeout if the emulated side never gets that far.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

# Two different dependencies used to be one shared cl-amiga checkout:
#   EMU     the emulator assets -- the aos3 Workbench image (with MUI and
#           TextEditor.mcc) and FS-UAE.app.  These are NOT tracked in git, so
#           they are not in the vendor/clamiga submodule; they stay in a
#           cl-amiga checkout beside this one (override with EMU_DIR).
#   CLAMIGA the clamiga RUNTIME the editor drives -- the CLAmiga: volume, from
#           which boot-override reads CLAmiga:build/cross/clamiga.  This is now
#           the pinned vendor/clamiga submodule, so a clamiga change made for
#           clamacs is isolated from mainline clamiga (override with CLAMIGA_DIR).
# The .fs-uae config's hard_drive_1 must point at the same place as CLAMIGA.
EMU="${EMU_DIR:-$(cd "$ROOT/../cl-amiga" 2>/dev/null && pwd)}"
CLAMIGA="${CLAMIGA_DIR:-$ROOT/vendor/clamiga}"

CONFIG="${1:-$HERE/verify.fs-uae}"
LOG="$ROOT/build/amiga/clamacs-test.log"

POLL="${POLL:-5}"
SENTINEL_GRACE="${SENTINEL_GRACE:-20}"
STALL_TIMEOUT="${STALL_TIMEOUT:-300}"
HARD_TIMEOUT="${HARD_TIMEOUT:-900}"

if [ -z "$EMU" ] || [ ! -d "$EMU/verify/realamiga/aos3" ]; then
	echo "cl-amiga emulator assets not found beside this repository."
	echo "The Workbench image (aos3) and FS-UAE.app are not tracked in git, so"
	echo "they are not in the vendor/clamiga submodule.  Set EMU_DIR to a"
	echo "cl-amiga checkout that has verify/realamiga/aos3."
	exit 1
fi

if [ ! -d "$CLAMIGA/verify/realamiga" ]; then
	echo "vendor/clamiga submodule is not checked out at $CLAMIGA."
	echo "Run: git submodule update --init vendor/clamiga  (or set CLAMIGA_DIR)."
	exit 1
fi

FSUAE="$EMU/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"
if [ ! -x "$FSUAE" ]; then
	echo "FS-UAE not found at $FSUAE"
	exit 1
fi

if [ ! -f "$ROOT/build/cross/clamacs" ]; then
	echo "build/cross/clamacs is missing -- run: make -f Makefile.cross amiga"
	exit 1
fi

mkdir -p "$ROOT/build/amiga" "$CLAMIGA/build/amiga"
rm -f "$LOG"

# The emulated side runs build/amiga/clamacs, never build/cross/clamacs
# directly: an experimental `make amiga BUILDDIR=...' must not silently
# change what the test runs.
cp "$ROOT/build/cross/clamacs" "$ROOT/build/amiga/clamacs"
cp "$HERE/boot-override" "$CLAMIGA/build/amiga/boot-override"

# The key-injection tool rides along when it has been built.  drive.rexx
# reports its absence as a failure of the raw-key leg rather than skipping
# it: a run without real key events has not tested the decoder.
rm -f "$ROOT/build/amiga/sendkey"
if [ -f "$ROOT/build/cross/sendkey" ]; then
	cp "$ROOT/build/cross/sendkey" "$ROOT/build/amiga/sendkey"
fi

report_log_state() {
	if [ -f "$LOG" ]; then
		echo "=== Watchdog: log is $(wc -c < "$LOG" | tr -d ' ') bytes; last lines: ==="
		tail -n 8 "$LOG" | sed 's/^/    /'
	else
		echo "=== Watchdog: $LOG does not exist -- the run wrote nothing ==="
	fi
}

kill_fsuae() {
	# SIGTERM and real patience: a clean shutdown is what flushes the
	# emulated hard drive, and the log lives on it.
	kill "$FSUAE_PID" 2>/dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$FSUAE_PID" 2>/dev/null || return
		sleep 1
	done
	echo "=== Watchdog: FS-UAE ignored SIGTERM -- SIGKILL (log may be truncated) ==="
	kill -9 "$FSUAE_PID" 2>/dev/null
}

"$FSUAE" "$CONFIG" &
FSUAE_PID=$!

start=$(date +%s)
last_change=$start
last_size=-1
end_seen=0

while kill -0 "$FSUAE_PID" 2>/dev/null; do
	sleep "$POLL"
	now=$(date +%s)

	if [ -f "$LOG" ]; then
		size=$(wc -c < "$LOG" | tr -d ' ')
	else
		size=0
	fi
	if [ "$size" != "$last_size" ]; then
		last_size=$size
		last_change=$now
	fi

	if [ "$end_seen" -eq 0 ] && [ -f "$LOG" ] && grep -q '=== run end ===' "$LOG"; then
		end_seen=$now
	fi
	if [ "$end_seen" -ne 0 ] && [ $((now - end_seen)) -ge "$SENTINEL_GRACE" ]; then
		echo "=== Watchdog: run finished but FS-UAE still up -- quitting it ==="
		kill_fsuae
		break
	fi
	if [ $((now - last_change)) -ge "$STALL_TIMEOUT" ]; then
		echo "=== Watchdog: no log output for ${STALL_TIMEOUT}s -- killing FS-UAE ==="
		report_log_state
		kill_fsuae
		break
	fi
	if [ $((now - start)) -ge "$HARD_TIMEOUT" ]; then
		echo "=== Watchdog: hard timeout ${HARD_TIMEOUT}s -- killing FS-UAE ==="
		report_log_state
		kill_fsuae
		break
	fi
done

wait "$FSUAE_PID" 2>/dev/null
rm -f "$CLAMIGA/build/amiga/boot-override"
exit 0
