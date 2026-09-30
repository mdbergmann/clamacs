#!/bin/sh
# run-lisp-editor.sh [040|020]
#
# The Lisp editor's FS-UAE smoke run (specs/clamacs-lisp.md, phase 1):
# boot AmigaOS 3, start lisp/clamacs.lisp on a file that does not exist
# yet, type a defun into it with sendkey (RET = newline-and-indent), save
# it with C-x C-s, close the buffer with C-x k -- the last window's close
# is the exit, and its reap from the event loop is the path that froze a
# Vampire on 2026-09-18 -- and compare the saved file with what the SAME
# keystrokes produce on the host under the fake frontend
# (tests/fake-frontend.lisp) -- so the MUI frontend is checked against the
# host-tested one, key for key.  Modelled on spike/run-spike.sh.
#
# The editor runs with its exit trace on (*EXIT-TRACE*, T:clamacs-exit.log):
# the log must end with the application disposed and carry no dispose
# that signalled, the check quit.rexx makes for the drive run.
#
# Prompts are not driven here: synthetic keys into a MUI String hold the
# focus for one key only (CLAUDE.md, "Phase 1 facts"), so the minibuffer's
# MUI dance is verified on hardware and, from phase 2 on, through the port.
#
# THEME=<name> (a theme of lisp/theme.lisp, e.g. one-dark) starts the
# editor in that theme for the session -- the colour themes' MUI leg
# (specs/clamacs-themes.md, T3): the pens, the background and the text
# colour show in the screenshot, and the ready marker carries the screen
# depth the frontend saw and whether it painted the theme's text and
# background (the shallow-screen rule).  The superproject's screen-grab
# helper photographs the editor's window: build/amiga/shots-<leg>/*.png
# (ffmpeg converts; without it the .ppm stays).
#
# FONT_SIZE=<pixels> starts the editor with the text size setting
# (theme.lisp's FONT-SIZE) at that height, for the session: the windows
# come up in MUI's fixed font sized so, the ready marker carries the
# height of the font the text area draws with (TEXT-FONT-SIZE-SHOWN),
# which must be the size asked for, and the screenshot shows it.
#
# Result: build/amiga/lisp-editor-run.log (with the exit log copied in),
# build/amiga/lisp-editor-out.lisp (what the editor saved),
# build/amiga/lisp-editor-expected.lisp (the host's),
# build/amiga/lisp-editor-clamiga.log (clamiga's own output),
# build/amiga/shots-<leg>/ (the screenshots).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-040}"
THEME="${THEME:-}"
SWITCH="${SWITCH:-}"
FONT_SIZE="${FONT_SIZE:-}"
CONFIG="$ROOT/spike/spike-$LEG.fs-uae"
OUT="$ROOT/build/amiga"
SHOTS="$OUT/shots-$LEG"
RUNLOG="$OUT/lisp-editor-run.log"
FSUAE="$SUPER/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"
HOST="$SUPER/build/host/clamiga"

POLL=5
SENTINEL_GRACE=15
STALL_TIMEOUT="${STALL_TIMEOUT:-900}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"

[ -f "$CONFIG" ] || { echo "no config $CONFIG"; exit 1; }
[ -x "$FSUAE" ] || { echo "FS-UAE not found at $FSUAE"; exit 1; }
[ -x "$HOST" ] || { echo "build the host runtime first: make -C $SUPER host"; exit 1; }
[ -f "$SUPER/build/cross/clamiga" ] || { echo "build the runtime first: make -C $SUPER -f Makefile.cross amiga"; exit 1; }
[ -f "$ROOT/build/cross/sendkey" ] || { echo "sendkey missing: make -C $ROOT -f Makefile.cross amiga"; exit 1; }

mkdir -p "$OUT" "$SUPER/build/amiga" "$SHOTS"
rm -f "$RUNLOG" "$OUT"/lisp-editor-* "$OUT"/lisp-editor-*.uaem "$HERE"/*.uaem
rm -f "$SHOTS"/* "$OUT/screen-grab.log" "$OUT/screen-grab-run.log"
cp "$ROOT/build/cross/sendkey" "$OUT/sendkey"
# screen-grab.lisp writes under build/amiga/shots/ of its current directory.
rm -rf "$OUT/shots"; mkdir -p "$OUT/shots"

# The expected file and the typing script, both from lisp-editor-keys.lisp.
"$HOST" --no-userinit --heap 16M --non-interactive \
    --eval '(defvar cl-user::*clamacs-frontend-files* (list))' \
    --load "$ROOT/lisp/load.lisp" \
    --load "$ROOT/tests/fake-frontend.lisp" \
    --load "$HERE/lisp-editor-keys.lisp" \
    --eval "(let ((doc (clamacs::make-fake \"\"))) (clamacs::type-into doc) (with-open-file (s \"$OUT/lisp-editor-expected.lisp\" :direction :output :if-exists :supersede) (write-string (clamacs::fake-text doc) s)))" \
    --eval "(clamacs::write-sendkey-script \"$OUT/lisp-editor-typing\" \"build/amiga/sendkey\")" \
    --eval '(cl-user::quit)' </dev/null >"$OUT/lisp-editor-host.log" 2>&1 \
    || { echo "the host leg failed:"; cat "$OUT/lisp-editor-host.log"; exit 1; }
[ -s "$OUT/lisp-editor-expected.lisp" ] || { echo "no expected text from the host leg:"; cat "$OUT/lisp-editor-host.log"; exit 1; }
TYPING=$(cat "$OUT/lisp-editor-typing")

# The Amiga side's driver: load the editor, mark the window open, start
# it on the program's arguments -- the file to save is passed after `--'
# on clamiga's command line, the way the release launcher and a Workbench
# project icon hand files over (EXT:*COMMAND-LINE-ARGS*) -- and mark the
# exit.  AmigaDOS makes `*' an escape inside quotes, so the forms go
# through a file, never an --eval.  The ready marker carries what the
# frontend decided for the theme on this screen (THEME-PLAN).
if [ -n "$THEME" ]; then
	THEME_FORM="(clamacs::load-theme :$THEME :save nil)"
else
	THEME_FORM=""
fi
# SWITCH=<name>: a second theme loaded once the window is open -- the live
# switch (EDITOR-APPLY-THEME on set-up objects), which the screenshot then
# shows instead of THEME.
if [ -n "$SWITCH" ]; then
	SWITCH_FORM="(clamacs::load-theme :$SWITCH :save nil)"
else
	SWITCH_FORM=""
fi
# FONT_SIZE=<n>: the setting made before the first window (as an init
# file's form would), and the repaint that applies it -- START runs it
# right after the hooks anyway -- run before the marker reads the font.
if [ -n "$FONT_SIZE" ]; then
	FONT_FORM="(clamacs::font-size $FONT_SIZE :save nil)"
else
	FONT_FORM=""
fi
cat > "$OUT/lisp-editor-driver.lisp" <<PRE
(load "Clamacs:lisp/load.lisp")
(setf clamacs::*exit-trace* t)
$THEME_FORM
$FONT_FORM
(push (lambda (editor)
        $SWITCH_FORM
        (clamacs::theme-repaint editor)
        (with-open-file (s "Clamacs:build/amiga/lisp-editor-ready"
                           :direction :output :if-exists :supersede)
          (format s "ready theme ~A depth ~A text-pen ~A bg ~A font ~A default ~A shown ~A~%"
                  (clamacs::theme-name (clamacs::mui-theme editor))
                  (clamacs::mui-editor-screen-depth editor)
                  (clamacs::mui-editor-text-pen-p editor)
                  (clamacs::mui-editor-bg-spec editor)
                  (clamacs::mui-editor-font-name editor)
                  (clamacs::mui-editor-font-default-size editor)
                  (clamacs::text-font-size-shown (first (clamacs::live-documents editor))))))
      clamacs::*after-start-hooks*)
(clamacs::start :files ext:*command-line-args*)
(with-open-file (s "Clamacs:build/amiga/lisp-editor-done"
                   :direction :output :if-exists :supersede)
  (write-line "done" s))
PRE

cat > "$SUPER/build/amiga/boot-override" <<BOOT
; lisp-editor boot-override -- consumed by CLAmiga:verify/realamiga/call-on-ustartup
failat 21
cd Clamacs:
echo "=== run start ===" >build/amiga/lisp-editor-run.log
echo "leg $LEG" >>build/amiga/lisp-editor-run.log
echo "=== avail before ===" >>build/amiga/lisp-editor-run.log
avail >>build/amiga/lisp-editor-run.log
stack 128000
IF EXISTS T:clamacs-exit.log
  delete >NIL: T:clamacs-exit.log
ENDIF
; The photographer: it shoots every new window on the public screen 2 s
; after it appears, into build/amiga/shots/ of ITS directory, and leaves
; when T:examples-done exists.
delete >NIL: T:examples-done
delete >NIL: T:screen-grab-ready
run >build/amiga/screen-grab-run.log CLAmiga:build/cross/clamiga --no-userinit --heap 16M --non-interactive --load CLAmiga:verify/realamiga/screen-grab.lisp
cd CLAmiga:
run >Clamacs:build/amiga/lisp-editor-clamiga.log build/cross/clamiga --no-userinit --heap 8M --non-interactive --load Clamacs:build/amiga/lisp-editor-driver.lisp -- Clamacs:build/amiga/lisp-editor-out.lisp
cd Clamacs:
set n 0
LAB waitready
IF NOT EXISTS Clamacs:build/amiga/lisp-editor-ready
  IF \$n EQ 240
    echo "FAIL the editor never opened its window" >>build/amiga/lisp-editor-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitready BACK
ENDIF
echo "OK editor window open after about \$n x 2 s" >>build/amiga/lisp-editor-run.log
type Clamacs:build/amiga/lisp-editor-ready >>build/amiga/lisp-editor-run.log
C:Wait 3
echo "=== typing ===" >>build/amiga/lisp-editor-run.log
date >>build/amiga/lisp-editor-run.log
$TYPING
date >>build/amiga/lisp-editor-run.log
build/amiga/sendkey C-x C-s DELAY 1
C:Wait 3
; The photographer has had its one shot (it photographs a window once,
; when it appears): let it leave before the editor does.
echo done >T:examples-done
C:Wait 2
build/amiga/sendkey C-x k DELAY 1
set n 0
LAB waitdone
IF NOT EXISTS Clamacs:build/amiga/lisp-editor-done
  IF \$n EQ 300
    echo "FAIL the editor did not quit in time" >>build/amiga/lisp-editor-run.log
    SKIP collect
  ENDIF
  set n \`eval \$n + 1\`
  C:Wait 2
  SKIP waitdone BACK
ENDIF
echo "OK editor quit about \$n x 2 s after C-x k closed the last buffer" >>build/amiga/lisp-editor-run.log
LAB collect
echo done >T:examples-done
echo "=== screen-grab.log ===" >>build/amiga/lisp-editor-run.log
IF EXISTS build/amiga/screen-grab.log
  type build/amiga/screen-grab.log >>build/amiga/lisp-editor-run.log
ENDIF
echo "=== clamacs-exit.log ===" >>build/amiga/lisp-editor-run.log
IF EXISTS T:clamacs-exit.log
  type T:clamacs-exit.log >>build/amiga/lisp-editor-run.log
ENDIF
echo "=== lisp-editor-clamiga.log ===" >>build/amiga/lisp-editor-run.log
IF EXISTS build/amiga/lisp-editor-clamiga.log
  type build/amiga/lisp-editor-clamiga.log >>build/amiga/lisp-editor-run.log
ENDIF
echo "=== lisp-editor-out.lisp ===" >>build/amiga/lisp-editor-run.log
IF EXISTS build/amiga/lisp-editor-out.lisp
  type build/amiga/lisp-editor-out.lisp >>build/amiga/lisp-editor-run.log
ENDIF
echo "=== status ===" >>build/amiga/lisp-editor-run.log
status >>build/amiga/lisp-editor-run.log
echo "=== avail after ===" >>build/amiga/lisp-editor-run.log
avail >>build/amiga/lisp-editor-run.log
echo "=== run end ===" >>build/amiga/lisp-editor-run.log
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
	[ -f "$OUT/lisp-editor-clamiga.log" ] && size=$((size + $(wc -c < "$OUT/lisp-editor-clamiga.log" | tr -d ' ')))
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

# The screenshots: PNG when ffmpeg is there, else the PPM as shot.
n=0
for f in "$OUT"/shots/*.ppm; do
	[ -f "$f" ] || continue
	base=$(basename "$f" .ppm)
	if command -v ffmpeg >/dev/null 2>&1; then
		ffmpeg -loglevel error -y -i "$f" "$SHOTS/$base.png" && rm -f "$f"
	else
		mv "$f" "$SHOTS/$base.ppm"
	fi
	n=$((n + 1))
done
rm -rf "$OUT/shots"
echo "=== $n screenshot(s) under $SHOTS ==="

# The verdict: the file the editor saved is what the host's editor holds,
# and the teardown ran to its end without a dispose that signalled.
if [ ! -f "$OUT/lisp-editor-out.lisp" ]; then
	echo "=== FAIL: the editor saved nothing ==="
	exit 1
fi
if ! cmp -s "$OUT/lisp-editor-out.lisp" "$OUT/lisp-editor-expected.lisp"; then
	echo "=== FAIL: the saved file differs from the host frontend's text ==="
	diff "$OUT/lisp-editor-expected.lisp" "$OUT/lisp-editor-out.lisp"
	exit 1
fi
exitlog=$(sed -n '/^=== clamacs-exit.log ===/,/^=== lisp-editor-clamiga.log ===/p' "$RUNLOG" | grep '^clamacs: exit')
if [ -z "$exitlog" ]; then
	echo "=== FAIL: the editor wrote no exit log although its trace was on ==="
	exit 1
fi
if echo "$exitlog" | grep -q 'signalled'; then
	echo "=== FAIL: a window dispose signalled ==="
	echo "$exitlog" | grep 'signalled'
	exit 1
fi
last=$(echo "$exitlog" | tail -1)
if [ "$last" != "clamacs: exit application disposed" ]; then
	echo "=== FAIL: the exit log ends with '$last', not with the application disposed ==="
	exit 1
fi
if [ -n "$FONT_SIZE" ]; then
	ready=$(grep '^ready ' "$RUNLOG" | head -1)
	case "$ready" in
	*" shown $FONT_SIZE"*) echo "=== PASS: the text area draws in MUI's fixed font at $FONT_SIZE pixels ($ready) ===" ;;
	*) echo "=== FAIL: FONT_SIZE=$FONT_SIZE, but the marker says: $ready ==="; exit 1 ;;
	esac
fi
echo "=== PASS: the saved file equals the host frontend's text; the teardown disposed the application and nothing signalled ==="
exit 0
