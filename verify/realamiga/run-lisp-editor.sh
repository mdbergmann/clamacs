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
# FONT_STEP=1 is the live path of the same setting: View > Bigger Text
# picked once the window is open, the marker's height the default's plus
# one step.  ABOUT=1 opens the About window (without the focus) before the
# typing: photographed, and disposed of at the exit like the other
# auxiliary windows.
#
# PERSPECTIVE=1 is the perspectives' MUI leg (specs/clamacs-perspectives.md,
# P3): before the typing, the start hook makes a second perspective and
# switches to it -- the file's window must be CLOSED by the loop's
# housekeeping (SHOWN-SYNC, run by the hook as START runs it) and an
# unnamed buffer's opened -- switches back, which must open the file's
# window again and close the other, and closes the second perspective.
# The ready marker carries `persp closed-then-open' for that, the typing
# then goes into the reopened window, and the exit must be as clean as
# ever (the hidden buffer's window reaped).
#
# Result: build/amiga/lisp-editor-run.log (with the exit log copied in),
# build/amiga/lisp-editor-out.lisp (what the editor saved),
# build/amiga/lisp-editor-expected.lisp (the host's),
# build/amiga/lisp-editor-amilisp.log (amilisp's own output),
# build/amiga/shots-<leg>/ (the screenshots).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SUPER=$(cd "$ROOT/.." && pwd)
LEG="${1:-040}"
THEME="${THEME:-}"
SWITCH="${SWITCH:-}"
FONT_SIZE="${FONT_SIZE:-}"
FONT_STEP="${FONT_STEP:-}"
ABOUT="${ABOUT:-}"
PERSPECTIVE="${PERSPECTIVE:-}"
CONFIG="$ROOT/spike/spike-$LEG.fs-uae"
OUT="$ROOT/build/amiga"
SHOTS="$OUT/shots-$LEG"
RUNLOG="$OUT/lisp-editor-run.log"
FSUAE="$SUPER/verify/realamiga/FS-UAE.app/Contents/MacOS/fs-uae"
HOST="$SUPER/build/host/amilisp"

POLL=5
SENTINEL_GRACE=15
STALL_TIMEOUT="${STALL_TIMEOUT:-900}"
HARD_TIMEOUT="${HARD_TIMEOUT:-2400}"

[ -f "$CONFIG" ] || { echo "no config $CONFIG"; exit 1; }
[ -x "$FSUAE" ] || { echo "FS-UAE not found at $FSUAE"; exit 1; }
[ -x "$HOST" ] || { echo "build the host runtime first: make -C $SUPER host"; exit 1; }
[ -f "$SUPER/build/cross/amilisp" ] || { echo "build the runtime first: make -C $SUPER -f Makefile.cross amiga"; exit 1; }
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
# on amilisp's command line, the way the release launcher and a Workbench
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
# ABOUT=1: the About window opened by the start hook, without the focus
# (the typing must still land in the document), left open -- the
# screen-grab helper photographs it, the marker says whether it opened,
# and the exit must dispose of it like the other auxiliary windows.
if [ -n "$ABOUT" ]; then
	ABOUT_FORM='(setq cl-user::*about* (if (clamacs::window-open-p (clamacs::show-about-window editor :activate nil)) "open" "closed"))'
else
	ABOUT_FORM=""
fi
# FONT_STEP=1: the LIVE path -- View > Bigger Text picked once the window
# is open (the command with `C-u', so the init file is left alone), the
# repaint the loop's housekeeping would run, and the marker must read the
# default height plus one step.
if [ -n "$FONT_STEP" ]; then
	STEP_FORM="(clamacs::run-command (first (clamacs::live-documents editor)) 'clamacs::clamacs-increase-font-size 4)"
else
	STEP_FORM=""
fi
# PERSPECTIVE=1: a second perspective entered and left, the windows
# closed and opened by SHOWN-SYNC in between (the hook runs it as START
# does, outside any MUI hook), the second perspective closed again.  The
# marker's `persp' says what the file's window did.
if [ -n "$PERSPECTIVE" ]; then
	PERSP_FORM='(let* ((main (clamacs::current-perspective editor))
                (other (clamacs::make-perspective editor "other"))
                (doc (first (clamacs::live-documents editor)))
                (window (clamacs::mdoc-window doc)))
           (clamacs::perspective-switch editor other :say nil)
           (clamacs::shown-sync editor)
           (let ((closed (not (clamacs::window-open-p window)))
                 (unnamed (clamacs::editor-active-document editor)))
             (clamacs::perspective-switch editor main :say nil)
             (clamacs::shown-sync editor)
             (let ((open (clamacs::window-open-p window))
                   (unnamed-closed (not (clamacs::window-open-p (clamacs::mdoc-window unnamed)))))
               (clamacs::perspective-close editor other)
               (setq cl-user::*persp*
                     (cond ((and closed open unnamed-closed) "closed-then-open")
                           (t (format nil "closed=~A open=~A unnamed-closed=~A" closed open unnamed-closed)))))))'
else
	PERSP_FORM=""
fi
cat > "$OUT/lisp-editor-driver.lisp" <<PRE
(load "Clamacs:lisp/load.lisp")
(setf clamacs::*exit-trace* t)
(defvar cl-user::*persp* "none")
(defvar cl-user::*about* "none")
$THEME_FORM
$FONT_FORM
(push (lambda (editor)
        $SWITCH_FORM
        $PERSP_FORM
        $STEP_FORM
        (clamacs::theme-repaint editor)
        $ABOUT_FORM
        (with-open-file (s "Clamacs:build/amiga/lisp-editor-ready"
                           :direction :output :if-exists :supersede)
          (format s "ready theme ~A depth ~A text-pen ~A bg ~A font ~A default ~A shown ~A persp ~A about ~A~%"
                  (clamacs::theme-name (clamacs::mui-theme editor))
                  (clamacs::mui-editor-screen-depth editor)
                  (clamacs::mui-editor-text-pen-p editor)
                  (clamacs::mui-editor-bg-spec editor)
                  (clamacs::mui-editor-font-name editor)
                  (clamacs::mui-editor-font-default-size editor)
                  (clamacs::text-font-size-shown (first (clamacs::live-documents editor)))
                  cl-user::*persp*
                  cl-user::*about*)))
      clamacs::*after-start-hooks*)
(clamacs::start :files ext:*command-line-args*)
(with-open-file (s "Clamacs:build/amiga/lisp-editor-done"
                   :direction :output :if-exists :supersede)
  (write-line "done" s))
PRE

cat > "$SUPER/build/amiga/boot-override" <<BOOT
; lisp-editor boot-override -- consumed by AmiLisp:verify/realamiga/call-on-ustartup
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
run >build/amiga/screen-grab-run.log AmiLisp:build/cross/amilisp --no-userinit --heap 16M --non-interactive --load AmiLisp:verify/realamiga/screen-grab.lisp
cd AmiLisp:
run >Clamacs:build/amiga/lisp-editor-amilisp.log build/cross/amilisp --no-userinit --heap 8M --non-interactive --load Clamacs:build/amiga/lisp-editor-driver.lisp -- Clamacs:build/amiga/lisp-editor-out.lisp
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
echo "=== lisp-editor-amilisp.log ===" >>build/amiga/lisp-editor-run.log
IF EXISTS build/amiga/lisp-editor-amilisp.log
  type build/amiga/lisp-editor-amilisp.log >>build/amiga/lisp-editor-run.log
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
	[ -f "$OUT/lisp-editor-amilisp.log" ] && size=$((size + $(wc -c < "$OUT/lisp-editor-amilisp.log" | tr -d ' ')))
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
exitlog=$(sed -n '/^=== clamacs-exit.log ===/,/^=== lisp-editor-amilisp.log ===/p' "$RUNLOG" | grep '^clamacs: exit')
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
	*" shown $FONT_SIZE "*) echo "=== PASS: the text area draws in MUI's fixed font at $FONT_SIZE pixels ($ready) ===" ;;
	*) echo "=== FAIL: FONT_SIZE=$FONT_SIZE, but the marker says: $ready ==="; exit 1 ;;
	esac
fi
if [ -n "$FONT_STEP" ]; then
	ready=$(grep '^ready ' "$RUNLOG" | head -1)
	default=$(echo "$ready" | sed -n 's/.* default \([0-9]*\) .*/\1/p')
	want=$((default + 2))
	case "$ready" in
	*" shown $want "*) echo "=== PASS: Bigger Text took the text area from $default to $want pixels ($ready) ===" ;;
	*) echo "=== FAIL: FONT_STEP=1 wanted $want pixels, but the marker says: $ready ==="; exit 1 ;;
	esac
fi
if [ -n "$ABOUT" ]; then
	ready=$(grep '^ready ' "$RUNLOG" | head -1)
	case "$ready" in
	*" about open") echo "=== PASS: the About window opened beside the document ($ready) ===" ;;
	*) echo "=== FAIL: ABOUT=1, but the marker says: $ready ==="; exit 1 ;;
	esac
	ls "$SHOTS" | grep -qi about || { echo "=== FAIL: no screenshot of the About window under $SHOTS ==="; exit 1; }
fi
if [ -n "$PERSPECTIVE" ]; then
	ready=$(grep '^ready ' "$RUNLOG" | head -1)
	case "$ready" in
	*" persp closed-then-open"*) echo "=== PASS: a perspective switch closed the file's window and the switch back opened it again ($ready) ===" ;;
	*) echo "=== FAIL: PERSPECTIVE=1, but the marker says: $ready ==="; exit 1 ;;
	esac
fi
echo "=== PASS: the saved file equals the host frontend's text; the teardown disposed the application and nothing signalled ==="
exit 0
