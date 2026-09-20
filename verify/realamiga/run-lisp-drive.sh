#!/bin/sh
# run-lisp-drive.sh [040|020] [PHASE]
#
# The Lisp editor's acceptance run (specs/clamacs-lisp.md): boot AmigaOS 3
# in FS-UAE, start a clamiga with its development port, start the editor
# from lisp/clamacs.lisp on sample.lisp, and drive it through its own
# ARexx port with verify/realamiga/drive.rexx -- the SAME script that
# gates the C editor, told with `PHASE n' which legs the port has reached
# (4 by default: the editor checks, the integration leg, the introspection,
# REPL, debugger and inspector legs).  Then the
# shipped macro, a memory reading with the editor up, and quit.rexx.
#
# Modelled on run-fs-uae.sh (the C editor's run) with boot-override
# written here instead of copied, since the editor's command line differs;
# the log is the same clamacs-test.log and the verdict the same grep for
# FAIL lines and the OK lines of the legs run.  The 68040 leg (the spike's
# config: 64 MB, JIT) is the gate; 020 is the lowend check of the
# Non-goals and slow.
#
# Result: build/amiga/clamacs-test.log, build/amiga/clamiga.log (the
# target's output), build/amiga/lisp-drive-editor.log (the editor's own).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-040}"
PHASE="${2:-4}"
CONFIG="$ROOT/spike/spike-$LEG.fs-uae"
LOG="$ROOT/build/amiga/clamacs-test.log"
FSUAE="$SUPER/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"

POLL="${POLL:-5}"
SENTINEL_GRACE="${SENTINEL_GRACE:-20}"
STALL_TIMEOUT="${STALL_TIMEOUT:-600}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"

[ -f "$CONFIG" ] || { echo "no config $CONFIG"; exit 1; }
[ -x "$FSUAE" ] || { echo "FS-UAE not found at $FSUAE"; exit 1; }
[ -f "$SUPER/build/cross/clamiga" ] || { echo "build the runtime first: make -C $SUPER -f Makefile.cross amiga"; exit 1; }
[ -f "$ROOT/build/cross/sendkey" ] || { echo "sendkey missing: make -C $ROOT -f Makefile.cross amiga"; exit 1; }

mkdir -p "$ROOT/build/amiga" "$SUPER/build/amiga"
rm -f "$LOG" "$ROOT/build/amiga/clamiga.log" "$ROOT/build/amiga/lisp-drive-editor.log"
# A fixture the run saves gets a .uaem pinning the Amiga date it saw; a
# later host edit would then load the cached old contents (run-fs-uae.sh).
rm -f "$HERE"/*.uaem "$ROOT"/build/amiga/*.uaem
cp "$ROOT/build/cross/sendkey" "$ROOT/build/amiga/sendkey"

cat > "$SUPER/build/amiga/boot-override" <<BOOT
; run-lisp-drive boot-override -- consumed by CLAmiga:verify/realamiga/call-on-ustartup
cd Clamacs:
echo "=== run start ===" >build/amiga/clamacs-test.log
echo "leg $LEG phase $PHASE" >>build/amiga/clamacs-test.log
avail >>build/amiga/clamacs-test.log
run >NIL: SYS:System/RexxMast
SYS:Rexxc/WaitForPort REXX
IF WARN
  echo "FAIL RexxMast did not start" >>build/amiga/clamacs-test.log
  SKIP done
ENDIF
echo "OK ARexx is running" >>build/amiga/clamacs-test.log
stack 128000
; The editor's exit log (quit.rexx reads it) must be this run's alone.
IF EXISTS T:clamacs-exit.log
  delete >NIL: T:clamacs-exit.log
ENDIF
; The target clamiga first, with its development port (see boot-override).
cd CLAmiga:
run >Clamacs:build/amiga/clamiga.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:verify/realamiga/arexx-host.lisp
C:Wait 5
; The editor: a second clamiga running lisp/clamacs.lisp on the sample.
run >Clamacs:build/amiga/lisp-drive-editor.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:lisp/clamacs.lisp -- Clamacs:verify/realamiga/sample.lisp
cd Clamacs:
SYS:Rexxc/RX Clamacs:verify/realamiga/drive.rexx PHASE $PHASE >>build/amiga/clamacs-test.log
echo "=== clamiga.log ===" >>build/amiga/clamacs-test.log
IF EXISTS build/amiga/clamiga.log
  type build/amiga/clamiga.log >>build/amiga/clamacs-test.log
ENDIF
echo "=== status ===" >>build/amiga/clamacs-test.log
status >>build/amiga/clamacs-test.log
echo "=== examples/arexx/load-current-file.rexx ===" >>build/amiga/clamacs-test.log
SYS:Rexxc/RX Clamacs:examples/arexx/load-current-file.rexx >>build/amiga/clamacs-test.log
echo "=== avail with clamacs running ===" >>build/amiga/clamacs-test.log
avail >>build/amiga/clamacs-test.log
SYS:Rexxc/RX Clamacs:verify/realamiga/quit.rexx >>build/amiga/clamacs-test.log
C:Wait 3
echo "=== avail after clamacs exited ===" >>build/amiga/clamacs-test.log
avail >>build/amiga/clamacs-test.log
echo "=== T:clamacs-exit.log ===" >>build/amiga/clamacs-test.log
IF EXISTS T:clamacs-exit.log
  type T:clamacs-exit.log >>build/amiga/clamacs-test.log
ENDIF
echo "=== lisp-drive-editor.log ===" >>build/amiga/clamacs-test.log
IF EXISTS build/amiga/lisp-drive-editor.log
  type build/amiga/lisp-drive-editor.log >>build/amiga/clamacs-test.log
ENDIF
LAB done
echo "=== run end ===" >>build/amiga/clamacs-test.log
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
	size=0; [ -f "$LOG" ] && size=$(wc -c < "$LOG" | tr -d ' ')
	if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; fi
	if [ "$end_seen" -eq 0 ] && [ -f "$LOG" ] && grep -q '=== run end ===' "$LOG"; then end_seen=$now; fi
	if [ "$end_seen" -ne 0 ] && [ $((now - end_seen)) -ge "$SENTINEL_GRACE" ]; then echo "=== run finished; quitting FS-UAE ==="; kill_fsuae; break; fi
	if [ $((now - last_change)) -ge "$STALL_TIMEOUT" ]; then echo "=== Watchdog: no log output for ${STALL_TIMEOUT}s ==="; kill_fsuae; break; fi
	if [ $((now - start)) -ge "$HARD_TIMEOUT" ]; then echo "=== Watchdog: hard timeout ==="; kill_fsuae; break; fi
done
wait "$FSUAE_PID" 2>/dev/null
rm -f "$SUPER/build/amiga/boot-override"

echo "=== $LOG ==="
cat "$LOG" 2>/dev/null

# The verdict.  FAIL lines fail; then the OK lines the phase promises,
# the subset of Makefile.cross's verify-amiga list that lies inside the
# legs drive.rexx ran (phase 5 is the whole list).
[ -f "$LOG" ] || { echo "=== FAIL: no log -- the run wrote nothing ==="; exit 1; }
if grep -q '^FAIL' "$LOG"; then
	echo "=== FAIL: the run reported failures ==="; exit 1
fi
grep -q 'DRIVE-DONE' "$LOG" || { echo "=== FAIL: drive.rexx did not finish ==="; exit 1; }
grep -q '=== run end ===' "$LOG" || { echo "=== FAIL: the boot script did not finish ==="; exit 1; }
grep -q 'clamiga ARexx port is' "$LOG" || { echo "=== FAIL: clamiga did not come up; the integration leg was skipped ==="; exit 1; }

want_phase2='OK clamacs ARexx port is CLAMACS
OK the editor keeps its stores on this launch
OK the target clamiga keeps its stores on this launch
OK GETFILE
OK GOTOLINE 3 put the cursor
OK EVAL end-of-buffer
OK beginning-of-buffer moved
OK beginning-of-defun found
OK end-of-defun reached
OK unknown command rejected
OK INSERT and GETLINE round trip
OK backward-sexp landed
OK OPEN second file
OK second document is active
OK kill-buffer closed the second document
OK the second document is open again after kill-buffer
OK C-x is pending
OK C-g cancelled the prefix
OK C-x C-q reported
OK C-u 4 C-n moved four lines
OK M-< reached the top
OK C-w killed the first line
OK C-y yanked it back
OK M-x opened the minibuffer
OK TAB indented
OK raw <down> reached the class
OK raw C-n ran next-line
OK raw M-< (Alt as Meta) reached the top
OK raw ESC > acted as Meta
OK raw C-x C-q went through the prefix map
OK raw RET indented the new line
OK raw typing self-inserted
OK eval-last-sexp on (+ 1 2) echoed 3
OK the buffer eval left eval.lisp active
OK the editor answered while a load was in flight
OK clamacs-load-buffer reported 2 error(s)
OK next-error jumped to the first error
OK next-error jumped to the second error
OK next-error stopped at the last diagnostic
OK previous-error went back to
OK asked clamacs to quit
OK CLAMACS is gone
OK the teardown disposed the application and no dispose signalled'

# Phase 3 of the port: drive.rexx's introspection leg (its "phase 2").
want_phase3='OK intro.lisp loaded
OK the idle timer had the arglist ready
OK M-. jumped to the definition of twice
OK M-, returned to CursorY
OK C-c RET expanded once
OK C-c M-m expanded fully
OK C-c C-d d prompted
OK DESCRIBE opened
OK the description carries the docstring
OK C-c C-d a prompted
OK APROPOS opened
OK APROPOS tagged the function and the macro
OK M-TAB completed twice-a in place
OK C-M-i handed the candidates to the minibuffer
OK TAB listed them
OK TAB narrowed twice-a to one
OK RET put the completion in the buffer'

# Phase 4 of the port: drive.rexx's REPL leg (its "phase 3") and its
# debugger and inspector leg (its "phase 4"), without the menu checks.
want_phase4='OK C-c C-z opened *clamacs-repl*
OK the REPL prompt arrived
OK RET evaluated (+ 1 2) at the prompt
OK a new prompt followed the value
OK output was streamed line by line before the value
OK READLINE armed the input
OK RET answered READ-LINE and the value came back
OK C-c C-c interrupted (loop)
OK the prompt followed IN-PACKAGE
OK and back to CL-USER
OK M-p brought back the last input
OK a second M-p went one further back
OK M-n came back to the empty input
OK the port answered ARGLIST while the REPL ran a form
OK C-c C-z raised the REPL again
OK an error at the prompt opened the debugger
OK RET at the prompt is refused while debugging
OK clamacs-debugger-eval prompted
OK the frame eval saw the locals by name
OK an error in the frame eval nested the debugger
OK ABORT returned to level 1
OK RESTART 0 returned to the prompt
OK the transcript says the form was aborted
OK CERROR opened the debugger
OK CONTINUE let the form finish
OK Open... on a name no file has made a new buffer
OK an error in a buffer eval opened the debugger
OK Abort ended the buffer eval in its own echo area
OK C-c I prompted
OK the inspector showed the object
OK part 1 descended into the cdr
OK Back came up to the list again'

want="$want_phase2"
if [ "$PHASE" -ge 3 ]; then
	want="$want
$want_phase3"
fi
if [ "$PHASE" -ge 4 ]; then
	want="$want
$want_phase4"
fi

missing=0
echo "$want" | while IFS= read -r want; do
	if ! grep -qF "$want" "$LOG"; then
		echo "=== missing: $want ==="
		exit 1
	fi
done || missing=1
if ! grep -qE 'Loaded |Load failed:' "$LOG"; then
	echo "=== FAIL: the shipped macro reached no verdict ==="; exit 1
fi
if [ "$missing" -ne 0 ]; then
	echo "=== FAIL: an expected OK line is missing ==="; exit 1
fi
echo "=== PASS: the Lisp editor passed drive.rexx PHASE $PHASE on the $LEG leg ==="
exit 0
