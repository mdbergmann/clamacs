#!/bin/sh
# build.sh -- what the host frontend needs, under build/host-frontend/
# (gitignored; specs/clamacs-host.md, "The native shim" and "The page"):
#
#   libwebview.dylib        the webview library (github.com/webview/webview),
#                           a C API over WebKit, built from a clone at a
#                           pinned commit
#   libclamacs-host.dylib   the native shim, host/clamacs-host.m
#   page.html               one self-contained page: page-head.html, the
#                           CodeMirror 6 bundle (esbuild over the packages
#                           of package-lock.json), page-app.js
#
# Network at build time only, and every fetch is pinned and checked: the
# webview clone is checked out at $webview_sha (never HEAD), the packages
# are installed with `npm ci' from the committed lockfile with install
# scripts disabled, and the bundle's sha256 is compared with $cm_sha256 --
# a mismatch removes the file and stops the build.  Moving a pin is a
# commit that says why.  The page runs in the editor's process and the
# library is loaded into it, so what this script fetches is code the
# editor runs.
#
# macOS only for now (clang, the Cocoa and WebKit frameworks, node with
# npm).  On Linux the same sources build against webkit2gtk, on Windows
# against WebView2 -- phase H6.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out="$root/build/host-frontend"
mkdir -p "$out"

webview_sha=cbbdee44afff22867de9fd88a9fc8350d9bdd399
# sha256 of the CodeMirror bundle esbuild writes from the locked packages.
# Empty = not recorded yet: the build warns and prints what it got; paste
# it here to make the check fail closed.
cm_sha256="1cd9b0cf2199f6f2ecc85b89bf57be46f8e665c07635683e6f1b78db512de7b8"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

case "$(uname -s)" in
    Darwin) ;;
    *) echo "build.sh: only macOS is built today (specs/clamacs-host.md, H6)" >&2; exit 1 ;;
esac

# --- webview ----------------------------------------------------------
if [ ! -f "$out/libwebview.dylib" ]; then
    if [ ! -d "$out/webview" ]; then
        git clone --quiet https://github.com/webview/webview.git "$out/webview"
    fi
    git -C "$out/webview" checkout --quiet --detach "$webview_sha"
    clang++ -dynamiclib -std=c++11 -O2 -DWEBVIEW_BUILD_SHARED -DWEBVIEW_STATIC=0 \
        -I "$out/webview/core/include" "$out/webview/core/src/webview.cc" \
        -framework WebKit -framework Cocoa -o "$out/libwebview.dylib"
    echo "built $out/libwebview.dylib"
fi

# --- the shim ---------------------------------------------------------
if [ ! -f "$out/libclamacs-host.dylib" ] || [ "$here/clamacs-host.m" -nt "$out/libclamacs-host.dylib" ]; then
    clang -dynamiclib -fobjc-arc -Wall -Wextra -O2 "$here/clamacs-host.m" \
        -framework Cocoa -o "$out/libclamacs-host.dylib"
    echo "built $out/libclamacs-host.dylib"
fi

# --- the CodeMirror bundle --------------------------------------------
cm="$out/cm-bundle.js"
if [ ! -f "$cm" ] || [ "$here/package-lock.json" -nt "$cm" ] || [ "$here/page-entry.mjs" -nt "$cm" ]; then
    if [ ! -d "$here/node_modules" ] || [ "$here/package-lock.json" -nt "$here/node_modules/.package-lock.json" ]; then
        (cd "$here" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
    fi
    (cd "$here" && npm run -s bundle -- --outfile="$cm")
fi
# The page must be ASCII.  It travels to WebKit as a C string that must be
# valid UTF-8, and the Lisp side is 8-bit: a file read decodes UTF-8 into
# code points, and ffi:foreign-string writes one byte per character --
# so a single non-ASCII character in the page (CodeMirror's doc comments
# have arrows and dashes) came out as invalid UTF-8 and WebKit loaded an
# EMPTY page, silently.  esbuild's --charset=ascii escapes strings and
# --minify-whitespace drops the comments; this check catches the rest.
if LC_ALL=C grep -q -n '[^ -~	]' "$cm" "$here/page-head.html" "$here/page-app.js"; then
    echo "build.sh: the page must be pure ASCII (see the comment above this check):" >&2
    LC_ALL=C grep -n '[^ -~	]' "$cm" "$here/page-head.html" "$here/page-app.js" | cut -c1-120 >&2
    exit 1
fi
cm_got=$(sha256 "$cm")
if [ -z "$cm_sha256" ]; then
    echo "build.sh: WARNING: the CodeMirror bundle is not pinned; sha256 of $cm is" >&2
    echo "build.sh:   $cm_got" >&2
    echo "build.sh: record it as cm_sha256 in build.sh to verify it on every build" >&2
elif [ "$cm_got" != "$cm_sha256" ]; then
    rm -f "$cm"
    echo "build.sh: the CodeMirror bundle does not match the pinned sha256" >&2
    echo "build.sh:   want $cm_sha256" >&2
    echo "build.sh:   got  $cm_got" >&2
    echo "build.sh: removed it; if the change is intended (a moved lockfile pin," >&2
    echo "build.sh: a changed page-entry.mjs), update cm_sha256" >&2
    exit 1
fi

# --- the page ---------------------------------------------------------
grep -q 'window.CM' "$cm" || { echo "build.sh: the bundle does not set window.CM; check page-entry.mjs" >&2; exit 1; }
cat "$here/page-head.html" "$cm" "$here/page-app.js" > "$out/page.html"
echo "built $out/page.html ($(wc -c < "$out/page.html" | tr -d ' ') bytes)"
