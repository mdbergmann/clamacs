#!/bin/sh
# The macOS shim's Option-key table: compiles verify/host/option-keys-test.m,
# which includes host/clamacs-host.m and feeds its option_key_js the keys
# of a German keyboard (left Option = Meta, right Option composes, both =
# Meta with the composed character).  macOS only; elsewhere a NOTE.
# Run it after touching take_option_key / option_key_js in the shim.
set -e
here=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in
    Darwin) ;;
    *) echo "option-keys.sh: NOTE: the Option keys are the macOS shim's; nothing to run on $(uname -s)"; exit 0 ;;
esac
out=${TMPDIR:-/tmp}/clamacs-option-keys.$$
trap 'rm -f "$out"' EXIT
clang -fobjc-arc -Wall -Wextra -Wno-unused-function -O1 "$here/option-keys-test.m" \
    -framework Cocoa -framework WebKit -o "$out"
"$out"
