#!/bin/sh
# typing.sh SENDKEY -- the keystrokes of the phase-0 spike as AmigaDOS
# commands, one `sendkey TEXT` per line and a RET after each (RET is the
# spike's newline-and-indent, so lines are typed WITHOUT indentation):
# four copies of a ten-line defun, about 2,000 characters.  Shared by
# run-spike.sh (FS-UAE) and run-vamp.py (real hardware).  AmigaDOS
# quoting: no `*' and no `"' inside the quoted text.
SENDKEY="${1:-build/amiga/sendkey}"
for fn in alpha beta gamma delta; do
    cat <<TYPING
$SENDKEY TEXT "(defun spike-$fn (n acc)" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(if (< n 2)" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(values n acc)" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(let ((a (spike-$fn (- n 1) acc))" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(b (spike-$fn (- n 2) (cons n acc))))" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(when (and (integerp a) (integerp b))" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(print (+ a b)))" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(dolist (item acc (+ a b))" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(unless (zerop item)" DELAY 1
$SENDKEY RET
$SENDKEY TEXT "(incf a (floor item 2)))))))" DELAY 1
$SENDKEY RET
$SENDKEY RET
TYPING
done
