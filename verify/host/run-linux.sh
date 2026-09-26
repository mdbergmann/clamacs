#!/bin/sh
# run-linux.sh -- the host frontend on Linux, in a container (specs/
# clamacs-host.md, phase H6): the GTK entries of the shim and the GTK
# build of webview, exercised by the smoke run and the drive under Xvfb.
#
#   verify/host/run-linux.sh              the smoke run and the drive
#   verify/host/run-linux.sh smoke        the smoke run only
#   verify/host/run-linux.sh shell        a shell in the container
#
# Needs a docker CLI with a running daemon (Docker Desktop, OrbStack,
# Colima).  The image, verify/host/linux/Dockerfile, is built once; the
# superproject is mounted at /work and clamiga is built for Linux into
# build/host-linux/ there (its own BUILDDIR, so the host's binaries stay),
# and host/build.sh writes libwebview.so and libclamacs-host.so beside the
# Mac's .dylibs under build/host-frontend/.  The page is the same on every
# host.  The verdicts are the scripts' own (SMOKE: PASS, === PASS).
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
super=$(cd "$root/.." && pwd)
image=clamacs-host-linux
what=${1:-all}

command -v docker >/dev/null 2>&1 || { echo "run-linux.sh: no docker CLI" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "run-linux.sh: the docker daemon is not running" >&2; exit 1; }

docker build -q -t "$image" "$here/linux" >/dev/null || exit 1

# Xvfb has no compositor and the container no GPU: WebKit renders in
# software, and the accessibility bus warning is noise.
run() {
    docker run --rm -v "$super":/work -w /work/clamacs \
        -e NO_AT_BRIDGE=1 -e WEBKIT_DISABLE_COMPOSITING_MODE=1 \
        -e CLAMACS_DRIVE_OUT=/work/clamacs/build/host-frontend/drive-linux \
        "$image" bash -c "$1"
}

build='set -e; make -C /work --no-print-directory host BUILDDIR=build/host-linux >/tmp/make.log 2>&1 || { tail -20 /tmp/make.log; exit 1; }; host/build.sh >/dev/null'

# One gate script under Xvfb, its output filtered.  The filter must not
# hide the script's verdict: a pipeline's status is the last command's, so
# `set +e' (the build's `set -e' would end the shell on grep's status when
# every line was filtered) and the container exits with the script's own
# status, PIPESTATUS[0] -- the container runs bash, so it exists.
gate() {
    run "$build; set +e; CLAMIGA=/work/build/host-linux/clamiga xvfb-run -a -s '-screen 0 1280x800x24' verify/host/$1 2>&1 | grep -v 'libEGL'; exit \${PIPESTATUS[0]}"
}

case "$what" in
    shell)
        docker run --rm -it -v "$super":/work -w /work/clamacs -e NO_AT_BRIDGE=1 "$image" bash ;;
    smoke)
        gate run-smoke.sh ;;
    all)
        gate run-smoke.sh || exit 1
        gate run-drive.sh ;;
    *)
        echo "run-linux.sh: what is $what? (smoke, shell, or nothing)" >&2; exit 2 ;;
esac
