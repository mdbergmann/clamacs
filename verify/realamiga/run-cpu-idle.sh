#!/bin/sh
# run-cpu-idle.sh [040|020]
#
# How much CPU the Lisp editor takes when nobody is typing.  A task at
# priority -5 (cpumeter.lisp) counts how often it gets to run, in windows
# of five seconds, through four phases: the bare system, the editor open
# on a file and left alone, the editor with a target clamiga's port up
# (the wire connected, the idle tick asking arglists), and a defun typed
# with sendkey.  Every window's count against the bare system's says what
# share of the CPU the editor took in that phase.
#
# The complaint this measures (2026-09-30): on a 68040 something keeps
# the CPU 95 % busy while Clamacs is up, and typing lags.  It was the
# arglist idle timer at 38 ticks a second (MUI 3.8 reads ihn_Millis as
# plain milliseconds), and the dynamic menus rebuilt on every wake of
# MUI's own timer (some 60 a second) -- and, on the user's 68040 a day
# later, a timer handler kept up for good: 20 % of a 68040 for MUI's 60
# wakes a second and the ticks.  The verdict is the editor's own account
# (LOOP-STATS-REPORT, read through loopstats.rexx): a resting editor's
# loop is not woken.  The CPU shares are for the eye: the
# 040 leg runs under the JIT, whose speed follows the host, so a bare
# window varies by a fifth.  No FS-UAE config runs a 68040 at its real
# speed (verify-slow040.fs-uae up in the superproject is not cycle
# exact either: FS-UAE logs cpu_speed=max), so what the shares mean on
# real hardware is what the tick rate says.
#
# Result: build/amiga/cpu-idle-run.log (the phases, the meter's lines,
# the editor's log), build/amiga/cpu-idle-after-typing.png (the editor a
# quarter of a minute after the last key: the colours and the status line
# trail the keys, and must have arrived) and the summary printed at the
# end.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-040}"
CONFIG="$ROOT/spike/spike-$LEG.fs-uae"
OUT="$ROOT/build/amiga"
RUNLOG="$OUT/cpu-idle-run.log"
FSUAE="$SUPER/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"
HOST="$SUPER/build/host/clamiga"
IDLE_SECONDS="${IDLE_SECONDS:-40}"

POLL=5
SENTINEL_GRACE=15
STALL_TIMEOUT="${STALL_TIMEOUT:-900}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"

[ -f "$CONFIG" ] || { echo "no config $CONFIG"; exit 1; }
[ -x "$FSUAE" ] || { echo "FS-UAE not found at $FSUAE"; exit 1; }
[ -x "$HOST" ] || { echo "build the host runtime first: make -C $SUPER host"; exit 1; }
[ -f "$SUPER/build/cross/clamiga" ] || { echo "build the runtime first: make -C $SUPER -f Makefile.cross amiga"; exit 1; }
[ -f "$ROOT/build/cross/sendkey" ] || { echo "sendkey missing: make -C $ROOT -f Makefile.cross amiga"; exit 1; }

mkdir -p "$OUT" "$SUPER/build/amiga"
rm -f "$RUNLOG" "$OUT"/cpu-idle-* "$OUT"/cpu-idle-*.uaem "$OUT/cpumeter.log" "$HERE"/*.uaem
cp "$ROOT/build/cross/sendkey" "$OUT/sendkey"

# The typing script from lisp-editor-keys.lisp, as run-lisp-editor.sh has it.
"$HOST" --no-userinit --heap 16M --non-interactive \
    --eval '(defvar cl-user::*clamacs-frontend-files* (list))' \
    --load "$ROOT/lisp/load.lisp" \
    --load "$ROOT/tests/fake-frontend.lisp" \
    --load "$HERE/lisp-editor-keys.lisp" \
    --eval "(clamacs::write-sendkey-script \"$OUT/cpu-idle-typing\" \"build/amiga/sendkey\")" \
    --eval '(cl-user::quit)' </dev/null >"$OUT/cpu-idle-host.log" 2>&1 \
    || { echo "the host leg failed:"; cat "$OUT/cpu-idle-host.log"; exit 1; }
TYPING=$(cat "$OUT/cpu-idle-typing")

cat > "$OUT/cpu-idle-driver.lisp" <<PRE
(load "Clamacs:lisp/load.lisp")
(push (lambda (editor)
        (declare (ignore editor))
        (with-open-file (s "Clamacs:build/amiga/cpu-idle-ready"
                           :direction :output :if-exists :supersede)
          (write-line "ready" s)))
      clamacs::*after-start-hooks*)
(clamacs::start :files ext:*command-line-args*)
(with-open-file (s "Clamacs:build/amiga/cpu-idle-done"
                   :direction :output :if-exists :supersede)
  (write-line "done" s))
PRE

WINDOWS=$((IDLE_SECONDS / 5))

cat > "$SUPER/build/amiga/boot-override" <<BOOT
; cpu-idle boot-override -- consumed by CLAmiga:verify/realamiga/call-on-ustartup
failat 21
cd Clamacs:
echo "=== run start ===" >build/amiga/cpu-idle-run.log
echo "leg $LEG" >>build/amiga/cpu-idle-run.log
stack 128000
delete >NIL: T:cpumeter-stop
delete >NIL: T:cpumeter-note
delete >NIL: T:clamacs-clamiga-port
echo "bare" >T:cpumeter-note
run >NIL: SYS:System/RexxMast
run >NIL: CLAmiga:build/cross/clamiga --no-userinit --heap 4M --non-interactive --load Clamacs:verify/realamiga/cpumeter.lisp
C:Wait 20
echo "=== phase editor-idle ===" >>build/amiga/cpu-idle-run.log
date >>build/amiga/cpu-idle-run.log
echo "starting" >T:cpumeter-note
copy >NIL: Clamacs:verify/realamiga/sample.lisp Clamacs:build/amiga/cpu-idle-out.lisp
cd CLAmiga:
run >Clamacs:build/amiga/cpu-idle-editor.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:build/amiga/cpu-idle-driver.lisp -- Clamacs:build/amiga/cpu-idle-out.lisp
cd Clamacs:
set n 0
LAB waitready
IF NOT EXISTS Clamacs:build/amiga/cpu-idle-ready
  IF \$n EQ 240
    echo "FAIL the editor never opened its window" >>build/amiga/cpu-idle-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitready BACK
ENDIF
echo "OK editor window open after about \$n x 2 s" >>build/amiga/cpu-idle-run.log
C:Wait 3
rx Clamacs:verify/realamiga/loopstats.rexx RESET
echo "editor-idle" >T:cpumeter-note
C:Wait $IDLE_SECONDS
echo "=== loop-stats editor-idle ===" >>build/amiga/cpu-idle-run.log
rx Clamacs:verify/realamiga/loopstats.rexx >>build/amiga/cpu-idle-run.log
echo "=== phase editor-with-clamiga ===" >>build/amiga/cpu-idle-run.log
date >>build/amiga/cpu-idle-run.log
echo "clamiga-starting" >T:cpumeter-note
cd CLAmiga:
run >Clamacs:build/amiga/cpu-idle-clamiga.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:verify/realamiga/arexx-host.lisp
cd Clamacs:
set n 0
LAB waitport
IF NOT EXISTS T:clamacs-clamiga-port
  IF \$n EQ 120
    echo "FAIL clamiga never opened its port" >>build/amiga/cpu-idle-run.log
    SKIP typing
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitport BACK
ENDIF
echo "OK clamiga port open after about \$n x 2 s" >>build/amiga/cpu-idle-run.log
C:Wait 5
rx Clamacs:verify/realamiga/loopstats.rexx RESET
echo "editor-with-clamiga" >T:cpumeter-note
C:Wait $IDLE_SECONDS
echo "=== loop-stats editor-with-clamiga ===" >>build/amiga/cpu-idle-run.log
rx Clamacs:verify/realamiga/loopstats.rexx >>build/amiga/cpu-idle-run.log
LAB typing
echo "=== phase typing ===" >>build/amiga/cpu-idle-run.log
date >>build/amiga/cpu-idle-run.log
rx Clamacs:verify/realamiga/loopstats.rexx RESET
echo "typing" >T:cpumeter-note
$TYPING
date >>build/amiga/cpu-idle-run.log
echo "=== loop-stats typing ===" >>build/amiga/cpu-idle-run.log
rx Clamacs:verify/realamiga/loopstats.rexx >>build/amiga/cpu-idle-run.log
echo "after-typing" >T:cpumeter-note
C:Wait 15
echo "=== loop-stats after-typing ===" >>build/amiga/cpu-idle-run.log
rx Clamacs:verify/realamiga/loopstats.rexx >>build/amiga/cpu-idle-run.log
; The display is held back while the keys come: photographed now, the
; typed defun must show its colours and the status line its place.
delete >NIL: RAM:screenshot.ppm
cd CLAmiga:
build/cross/clamiga --no-userinit --heap 16M --non-interactive --load CLAmiga:examples/amiga/gfx/screenshot.lisp >>Clamacs:build/amiga/cpu-idle-run.log
cd Clamacs:
copy >NIL: RAM:screenshot.ppm build/amiga/cpu-idle-after-typing.ppm
echo "=== phase quit ===" >>build/amiga/cpu-idle-run.log
build/amiga/sendkey C-x C-s DELAY 1
C:Wait 3
build/amiga/sendkey C-x k DELAY 1
set n 0
LAB waitdone
IF NOT EXISTS Clamacs:build/amiga/cpu-idle-done
  IF \$n EQ 60
    echo "FAIL the editor did not quit in time" >>build/amiga/cpu-idle-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitdone BACK
ENDIF
echo "OK editor quit" >>build/amiga/cpu-idle-run.log
echo "bare-again" >T:cpumeter-note
C:Wait 15
LAB collect
echo stop >T:cpumeter-stop
C:Wait 8
echo "=== cpumeter.log ===" >>build/amiga/cpu-idle-run.log
IF EXISTS build/amiga/cpumeter.log
  type build/amiga/cpumeter.log >>build/amiga/cpu-idle-run.log
ENDIF
echo "=== cpu-idle-editor.log ===" >>build/amiga/cpu-idle-run.log
IF EXISTS build/amiga/cpu-idle-editor.log
  type build/amiga/cpu-idle-editor.log >>build/amiga/cpu-idle-run.log
ENDIF
echo "=== status ===" >>build/amiga/cpu-idle-run.log
status >>build/amiga/cpu-idle-run.log
echo "=== run end ===" >>build/amiga/cpu-idle-run.log
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
	[ -f "$OUT/cpumeter.log" ] && size=$((size + $(wc -c < "$OUT/cpumeter.log" | tr -d ' ')))
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

# The summary: the share of the CPU the meter did NOT get per phase,
# against the best bare window.
[ -f "$OUT/cpumeter.log" ] || { echo "=== FAIL: no meter log ==="; exit 1; }
awk '
/^[0-9]+ [0-9]+/ { n[$3] += $2; c[$3]++; if ($3 == "bare" && $2 > best) best = $2 }
END {
  if (!best) { print "no bare window"; exit 1 }
  printf "%-22s %8s %8s\n", "phase", "windows", "cpu-used"
  for (p in n) printf "%-22s %8d %7.1f%%\n", p, c[p], 100 * (1 - (n[p] / c[p]) / best)
}' "$OUT/cpumeter.log"

# The photograph of the editor after the typing: PNG when ffmpeg is there.
if [ -f "$OUT/cpu-idle-after-typing.ppm" ]; then
	if command -v ffmpeg >/dev/null 2>&1; then
		ffmpeg -loglevel error -y -i "$OUT/cpu-idle-after-typing.ppm" "$OUT/cpu-idle-after-typing.png" \
			&& rm -f "$OUT/cpu-idle-after-typing.ppm"
	fi
	echo "=== the editor after the typing: $OUT/cpu-idle-after-typing.p[np][gm] ==="
fi

# The verdict is the editor-idle account (LOOP-STATS-REPORT): a resting
# editor must not be woken.  The idle timer is up only while the display
# or the arglist has something to do (ARM-IDLE-TIMER), so in forty idle
# seconds the tick fires a few times and the loop turns some 13 times a
# second (Intuition's ticks to the active window, which MUI passes on) --
# against 60 wakes and 3.3 (once 38) ticks a second with a timer up for
# good, which on a real 68040 was a fifth of the CPU (2026-10-01).  The
# CPU shares above vary with the host under the JIT and are printed for
# the eye.
idle=$(sed -n '/=== loop-stats editor-idle ===/,/=== phase/p' "$RUNLOG")
rate_of() { echo "$idle" | grep "$1" | head -1 | awk '{sub(/\/s$/, "", $NF); print $NF}'; }
wakes=$(rate_of '^  iterations')
ticks=$(rate_of 'method #x8C1A0002')
[ -n "$ticks" ] || ticks=0
case "$wakes" in
	''|*[!0-9.]*|*.*.*)
		echo "=== FAIL: no usable loop account in the editor-idle loop-stats (got '$wakes'; was the port answering?) ==="
		exit 1 ;;
esac
if awk -v r="$wakes" 'BEGIN { exit !(r + 0 > 25) }'; then
	echo "=== FAIL: the resting editor's loop wakes $wakes times a second (a timer handler left up?) ==="
	exit 1
fi
if awk -v r="$ticks" 'BEGIN { exit !(r + 0 > 1) }'; then
	echo "=== FAIL: the idle timer fires $ticks times a second in a resting editor ==="
	exit 1
fi
echo "=== PASS: the resting editor's loop wakes $wakes times a second, the idle timer fires $ticks ==="
exit 0
