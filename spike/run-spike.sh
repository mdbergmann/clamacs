#!/bin/sh
# run-spike.sh [020|040]
#
# Phase 0 of specs/clamacs-lisp.md: boot AmigaOS 3 in FS-UAE, start the Lisp
# spike (spike.lisp) in the superproject's cross-built clamiga, type a Lisp
# form into it with sendkey, quit it with C-x C-c and collect the report.
# Modelled on verify/realamiga/run-fs-uae.sh (boot-override hook, watchdog).
#
# Result: build/amiga/spike-run.log (the run), build/amiga/spike.log (the
# spike's own report), build/amiga/spike-buffer.txt (what arrived in the
# buffer), build/amiga/spike-clamiga.log (clamiga's stdout/stderr).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-020}"
CONFIG="$HERE/spike-$LEG.fs-uae"
RUNLOG="$ROOT/build/amiga/spike-run.log"
FSUAE="$SUPER/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"

POLL=5
SENTINEL_GRACE=15
STALL_TIMEOUT="${STALL_TIMEOUT:-900}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"

[ -f "$CONFIG" ] || { echo "no config $CONFIG"; exit 1; }
[ -x "$FSUAE" ] || { echo "FS-UAE not found at $FSUAE"; exit 1; }
[ -f "$SUPER/build/cross/clamiga" ] || { echo "build the runtime first: make -C $SUPER -f Makefile.cross amiga"; exit 1; }
[ -f "$ROOT/build/cross/sendkey" ] || { echo "sendkey missing: make -C $ROOT -f Makefile.cross amiga"; exit 1; }

mkdir -p "$ROOT/build/amiga" "$SUPER/build/amiga"
rm -f "$RUNLOG" "$ROOT/build/amiga/spike.log" "$ROOT/build/amiga/spike-buffer.txt" \
      "$ROOT/build/amiga/spike-ready" "$ROOT/build/amiga/spike-clamiga.log" "$HERE"/*.uaem \
      "$ROOT/build/amiga"/spike*.uaem
cp "$ROOT/build/cross/sendkey" "$ROOT/build/amiga/sendkey"

# The keystrokes (spike/typing.sh, shared with the real-hardware runner).
TYPING=$(sh "$HERE/typing.sh" build/amiga/sendkey)

cat > "$SUPER/build/amiga/boot-override" <<BOOT
; spike boot-override -- consumed by CLAmiga:verify/realamiga/call-on-ustartup
failat 21
cd Clamacs:
echo "=== run start ===" >build/amiga/spike-run.log
echo "leg $LEG" >>build/amiga/spike-run.log
echo "=== avail before ===" >>build/amiga/spike-run.log
avail >>build/amiga/spike-run.log
stack 128000
setenv CLAMIGA_MEM_DIAG 1
cd CLAmiga:
run >Clamacs:build/amiga/spike-clamiga.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:spike/spike.lisp
cd Clamacs:
set n 0
LAB waitready
IF NOT EXISTS Clamacs:build/amiga/spike-ready
  IF \$n EQ 240
    echo "FAIL the spike never opened its window" >>build/amiga/spike-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitready BACK
ENDIF
echo "OK spike window open after about \$n x 2 s" >>build/amiga/spike-run.log
C:Wait 2
echo "=== avail with the spike running (before typing) ===" >>build/amiga/spike-run.log
avail >>build/amiga/spike-run.log
echo "=== typing ===" >>build/amiga/spike-run.log
date >>build/amiga/spike-run.log
$TYPING
date >>build/amiga/spike-run.log
echo "=== avail with the spike running (after typing) ===" >>build/amiga/spike-run.log
avail >>build/amiga/spike-run.log
build/amiga/sendkey C-x C-c
; the spike may still be draining the queued keys (a RET costs seconds on
; a 68020): wait for its report before collecting, up to 20 minutes
set n 0
LAB waitreport
Search >NIL: QUIET build/amiga/spike.log "end report"
IF WARN
  IF \$n EQ 600
    echo "FAIL the spike did not finish its report in time" >>build/amiga/spike-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitreport BACK
ENDIF
echo "OK spike finished about \$n x 2 s after C-x C-c" >>build/amiga/spike-run.log
LAB collect
echo "=== spike.log ===" >>build/amiga/spike-run.log
IF EXISTS build/amiga/spike.log
  type build/amiga/spike.log >>build/amiga/spike-run.log
ENDIF
echo "=== spike-clamiga.log ===" >>build/amiga/spike-run.log
IF EXISTS build/amiga/spike-clamiga.log
  type build/amiga/spike-clamiga.log >>build/amiga/spike-run.log
ENDIF
echo "=== spike-buffer.txt ===" >>build/amiga/spike-run.log
IF EXISTS build/amiga/spike-buffer.txt
  type build/amiga/spike-buffer.txt >>build/amiga/spike-run.log
ENDIF
echo "=== status ===" >>build/amiga/spike-run.log
status >>build/amiga/spike-run.log
echo "=== avail after ===" >>build/amiga/spike-run.log
avail >>build/amiga/spike-run.log
echo "=== run end ===" >>build/amiga/spike-run.log
C:UAEquit
BOOT

kill_fsuae() {
	kill "$FSUAE_PID" 2>/dev/null
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$FSUAE_PID" 2>/dev/null || return
		sleep 1
	done
	kill -9 "$FSUAE_PID" 2>/dev/null
}

"$FSUAE" "$CONFIG" &
FSUAE_PID=$!
start=$(date +%s); last_change=$start; last_size=-1; end_seen=0
while kill -0 "$FSUAE_PID" 2>/dev/null; do
	sleep "$POLL"
	now=$(date +%s)
	size=0; [ -f "$RUNLOG" ] && size=$(wc -c < "$RUNLOG" | tr -d ' ')
	# the spike's own log counts as progress too (the long cold compile)
	[ -f "$ROOT/build/amiga/spike.log" ] && size=$((size + $(wc -c < "$ROOT/build/amiga/spike.log" | tr -d ' ')))
	[ -f "$ROOT/build/amiga/spike-clamiga.log" ] && size=$((size + $(wc -c < "$ROOT/build/amiga/spike-clamiga.log" | tr -d ' ')))
	if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi
	if [ "$end_seen" -eq 0 ] && [ -f "$RUNLOG" ] && grep -q '=== run end ===' "$RUNLOG"; then end_seen=$now; fi
	if [ "$end_seen" -ne 0 ] && [ $((now - end_seen)) -ge "$SENTINEL_GRACE" ]; then echo "=== run finished; quitting FS-UAE ==="; kill_fsuae; break; fi
	if [ $((now - last_change)) -ge "$STALL_TIMEOUT" ]; then echo "=== Watchdog: stalled ${STALL_TIMEOUT}s ==="; kill_fsuae; break; fi
	if [ $((now - start)) -ge "$HARD_TIMEOUT" ]; then echo "=== Watchdog: hard timeout ==="; kill_fsuae; break; fi
done
wait "$FSUAE_PID" 2>/dev/null
rm -f "$SUPER/build/amiga/boot-override"
echo "=== $RUNLOG ==="
cat "$RUNLOG" 2>/dev/null
