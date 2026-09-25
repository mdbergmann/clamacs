#!/bin/sh
# host-keys.sh -- the host editor's differential smoke run, the twin of
# verify/realamiga/run-lisp-editor.sh (specs/clamacs-host.md, phase H1).
#
# The editor is started on a file that does not exist yet, and the lines
# of verify/realamiga/lisp-editor-keys.lisp are pushed through the PAGE:
# each key is a simulateKey call the loop sends, so it takes the path a
# real key takes -- the page's keydown handler, the clamacsKey binding,
# the decoder, the Emacs layer (RET is newline-and-indent), the mirror,
# the batch back to the page.  Then C-x C-s saves and C-x k closes the
# buffer, the last tab's close being the exit.  The saved file must equal
# what the SAME keys produce under the fake frontend on the host, and the
# editor must have come down by itself.
#
#   verify/host/host-keys.sh            under ../build/host/clamiga
#   GCSTRESS=1 verify/host/host-keys.sh under ../build/host-gcstress/clamiga
#   CLAMIGA=... names another binary.
#
# Result: build/host-frontend/keys-out.lisp (what the editor saved),
# keys-expected.lisp (the fake frontend's), keys-editor.log, keys-host.log.
# Needs a window server (a logged-in session).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
super=$(cd "$root/.." && pwd)
out="$root/build/host-frontend"
keys="$root/verify/realamiga/lisp-editor-keys.lisp"

if [ "${GCSTRESS:-0}" = 1 ]; then
    clamiga=${CLAMIGA:-"$super/build/host-gcstress/clamiga"}
    CLAMIGA_GC_STRESS=1
    export CLAMIGA_GC_STRESS
else
    clamiga=${CLAMIGA:-"$super/build/host/clamiga"}
fi
[ -x "$clamiga" ] || { echo "no clamiga at $clamiga (make host in the superproject)"; exit 1; }

"$root/host/build.sh" || exit 1
mkdir -p "$out"
rm -f "$out"/keys-*

# The expected file, from the fake frontend.
"$clamiga" --no-userinit --heap 16M --non-interactive \
    --eval '(defvar cl-user::*clamacs-frontend-files* (list))' \
    --load "$root/lisp/load.lisp" \
    --load "$root/tests/fake-frontend.lisp" \
    --load "$keys" \
    --eval "(let ((doc (clamacs::make-fake \"\"))) (clamacs::type-into doc) (with-open-file (s \"$out/keys-expected.lisp\" :direction :output :if-exists :supersede) (write-string (clamacs::fake-text doc) s)))" \
    --eval '(cl-user::quit)' </dev/null >"$out/keys-host.log" 2>&1 \
    || { echo "the fake-frontend leg failed:"; cat "$out/keys-host.log"; exit 1; }
[ -s "$out/keys-expected.lisp" ] || { echo "no expected text from the fake-frontend leg:"; cat "$out/keys-host.log"; exit 1; }

# The editor: the same lines through the page, then save, then close.
cat > "$out/keys-driver.lisp" <<EOF
(defvar cl-user::*clamacs-frontend-files* '("frontend-host"))
(load "$root/lisp/load.lisp")
(load "$keys")
(in-package :clamacs)
(push (lambda (editor)
        (let ((keys '()))
          (dolist (line *smoke-lines*)
            (push line keys)
            (push (key-from-string "RET") keys))
          (host-inject-keys editor (nreverse keys))
          (host-inject-keys editor (list (key-from-string "C-x") (key-from-string "C-s")
                                         (key-from-string "C-x") (key-from-string "k")))))
      *after-start-hooks*)
(start :files (list "$out/keys-out.lisp"))
(with-open-file (s "$out/keys-done" :direction :output :if-exists :supersede)
  (write-line "done" s))
EOF

"$clamiga" --no-userinit --heap 32M --non-interactive --load "$out/keys-driver.lisp" \
    </dev/null >"$out/keys-editor.log" 2>&1 &
pid=$!
# Under gc-stress every key's round trip compacts the heap many times over.
limit=120; [ "${GCSTRESS:-0}" = 1 ] && limit=1500
n=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$limit" ]; then
        echo "=== FAIL: the editor did not quit within $limit s ==="
        kill "$pid" 2>/dev/null
        cat "$out/keys-editor.log"
        exit 1
    fi
    sleep 1
    n=$((n + 1))
done
wait "$pid"
rc=$?
grep -v '^; Loading' "$out/keys-editor.log"

if [ ! -f "$out/keys-done" ]; then
    echo "=== FAIL: START did not return (exit $rc) ==="
    exit 1
fi
if grep -q 'the page reported' "$out/keys-editor.log"; then
    echo "=== FAIL: the page reported an error ==="
    exit 1
fi
if [ ! -f "$out/keys-out.lisp" ]; then
    echo "=== FAIL: the editor saved nothing ==="
    exit 1
fi
if ! cmp -s "$out/keys-out.lisp" "$out/keys-expected.lisp"; then
    echo "=== FAIL: the saved file differs from the fake frontend's text ==="
    diff "$out/keys-expected.lisp" "$out/keys-out.lisp"
    exit 1
fi
echo "=== PASS: the saved file equals the fake frontend's text; the editor came down after about ${n} s ==="
exit 0
