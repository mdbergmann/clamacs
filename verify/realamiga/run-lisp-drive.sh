#!/bin/sh
# run-lisp-drive.sh [040|020] [PHASE]
#
# The Lisp editor's acceptance run (specs/clamacs-lisp.md): boot AmigaOS 3
# in FS-UAE, start a clamiga with its development port, start the editor
# from lisp/clamacs.lisp on sample.lisp, and drive it through its own
# ARexx port with verify/realamiga/drive.rexx -- the SAME script that
# gates the C editor, told with `PHASE n' which legs the port has reached
# (5 by default, all of it: the editor checks, the menu strip, the window
# snapshot with a second Lisp editor, the integration leg, the
# introspection, REPL, debugger and inspector legs).  Then the
# shipped macro, a memory reading with the editor up, and quit.rexx.
#
# Modelled on run-fs-uae.sh (the C editor's run) with boot-override
# written here instead of copied, since the editor's command line differs;
# the log is the same clamacs-test.log and the verdict the same grep for
# FAIL lines and the OK lines of the legs run.  The 68040 leg (the spike's
# config: 64 MB, JIT) is the gate; 020 is the lowend check of the
# Non-goals and slow.
#
# IMAGE=1 runs the same legs against the editor the release ships: the
# boot script first saves build/amiga/clamacs.img with
# scripts/save-editor-image.lisp (binding tables shed), then starts the
# editor from it the way the Clamacs launcher does, `--image clamacs.img
# --eval "(clamacs::run)"`.  What the image lacks next to a source start
# -- the raw OS names the editor never used -- fails a leg here.  The
# verdict also wants the shed report and the saved image.
#
# Result: build/amiga/clamacs-test.log, build/amiga/clamiga.log (the
# target's output), build/amiga/lisp-drive-editor.log (the editor's own).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-040}"
PHASE="${2:-5}"
IMAGE="${IMAGE:-0}"
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

# The editor's start: from the source, or (IMAGE=1) from an image the boot
# script saves first -- in its own directory, where save-editor-image.lisp
# writes clamacs.img.
rm -f "$ROOT/build/amiga/clamacs.img"
if [ "$IMAGE" = 1 ]; then
	SAVE_IMAGE='echo "=== saving the editor image ===" >>build/amiga/clamacs-test.log
cd Clamacs:build/amiga
CLAmiga:build/cross/clamiga --no-userinit --no-image --heap 8M --non-interactive --load Clamacs:lisp/load.lisp --load Clamacs:scripts/save-editor-image.lisp >>clamacs-test.log
cd Clamacs:
IF NOT EXISTS build/amiga/clamacs.img
  echo "FAIL the editor image was not saved" >>build/amiga/clamacs-test.log
ENDIF'
	# No --load: an explicit --image that cannot be restored exits, and an
	# image without the editor has no CLAMACS package, so the drive can
	# only pass with the editor from the image.
	EDITOR='--image Clamacs:build/amiga/clamacs.img --eval "(clamacs::run)"'
else
	SAVE_IMAGE=
	EDITOR='--load Clamacs:lisp/clamacs.lisp'
fi

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
$SAVE_IMAGE
; The target clamiga first, with its development port (see boot-override).
cd CLAmiga:
run >Clamacs:build/amiga/clamiga.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:verify/realamiga/arexx-host.lisp
C:Wait 5
; The editor: a second clamiga running lisp/clamacs.lisp (or the image) on the sample.
run >Clamacs:build/amiga/lisp-drive-editor.log build/cross/clamiga --no-userinit --heap 8M --non-interactive $EDITOR -- Clamacs:verify/realamiga/sample.lisp
cd Clamacs:
SYS:Rexxc/RX Clamacs:verify/realamiga/drive.rexx PHASE $PHASE LISP CLAmiga:build/cross/clamiga >>build/amiga/clamacs-test.log
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
if [ "$IMAGE" = 1 ]; then
	grep -q 'SAVE-IMAGE: shed [0-9]* binding table' "$LOG" || { echo "=== FAIL: the editor image was saved without shedding the binding tables ==="; exit 1; }
	grep -q 'Image saved to "clamacs.img"' "$LOG" || { echo "=== FAIL: the editor image was not saved ==="; exit 1; }
fi

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
OK EVAL of a form answered with what it printed and its value
OK EVAL (room) reported the editor heap,
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

# Phase 5 of the port: the menu strip and the window snapshot legs, and
# the MENU checks inside the integration, REPL and debugger legs -- the
# rest of Makefile.cross's verify-amiga list.
want_phase5='OK the menu strip has Open
OK forward-char is not a menu item
OK Save is dimmed for a clean buffer
OK the first edit enabled Save
OK the menu saved the buffer
OK Save dimmed after the menu saved
OK Close Buffer closed it
OK the menu ran beginning-of-defun
OK Clear Transcript is dimmed outside the REPL
OK the Help menu has the HyperSpec
OK the Buffers menu lists the files, sample.lisp ticked
OK picking sample2.lisp in the Buffers menu activated it
OK the tick moved to sample2.lisp
OK *clamacs-room* is a tool buffer below the bar
OK BUFFERS refused an unknown buffer
OK a closed buffer left the Buffers menu
OK GETWINDOW answered doc1
OK the snapshot was taken
OK the snapshot wrote ENV: and ENVARC:
OK the file holds the active window
OK ENVARC: holds the same line
OK the file holds the error list
OK a second editor is at
OK a second editor came up where the file said
OK the second editor quit
OK the snapshot files are gone again
OK the Clamiga menu woke up with the port
OK Start clamiga is dimmed while connected
OK Next Error woke up with the diagnostics
OK Clear Transcript is live in the REPL window
OK the Debugger item woke up with the debugger
OK the Debugger item dimmed with the restart
OK Talk to the Editor Itself is live while talking to clamiga
OK the REPL moved to the editor itself
OK (room) at the self REPL reported the editor heap
OK IN-EDITOR ran on the MUI task and named the active window
OK Talk to clamiga moved the REPL back'

want="$want_phase2"
if [ "$PHASE" -ge 3 ]; then
	want="$want
$want_phase3"
fi
if [ "$PHASE" -ge 4 ]; then
	want="$want
$want_phase4"
fi
if [ "$PHASE" -ge 5 ]; then
	want="$want
$want_phase5"
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
if [ "$IMAGE" = 1 ]; then
	echo "=== PASS: the Lisp editor, started from its image, passed drive.rexx PHASE $PHASE on the $LEG leg ==="
else
	echo "=== PASS: the Lisp editor passed drive.rexx PHASE $PHASE on the $LEG leg ==="
fi
exit 0
