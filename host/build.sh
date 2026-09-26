#!/bin/sh
# build.sh -- what the host frontend needs, under build/host-frontend/
# (gitignored; specs/clamacs-host.md, "The native shim" and "The page"):
#
#   libwebview.{dylib,so,dll}       the webview library (github.com/webview/webview),
#                                   a C API over the platform's web view, built
#                                   from a clone at a pinned commit
#   libclamacs-host.{dylib,so,dll}  the native shim, host/clamacs-host.m
#   page.html                       one self-contained page: page-head.html, the
#                                   CodeMirror 6 bundle (esbuild over the packages
#                                   of package-lock.json), page-app.js
#
# Network at build time only, and every fetch is pinned and checked: the
# webview clone is checked out at $webview_sha (never HEAD), the packages
# are installed with `npm ci' from the committed lockfile with install
# scripts disabled, the bundle's sha256 is compared with $cm_sha256 --
# a mismatch removes the file and stops the build -- and on Windows the
# WebView2 SDK package is fetched at $webview2_version and compared with
# $webview2_sha256.  Moving a pin is a commit that says why.  The page runs
# in the editor's process and the library is loaded into it, so what this
# script fetches is code the editor runs.
#
# The hosts (phase H6):
#
#   macOS    clang, the Cocoa and WebKit frameworks; node with npm
#   Linux    gcc/g++, pkg-config, gtk+-3.0 and webkit2gtk-4.1 (Debian/Ubuntu:
#            libgtk-3-dev libwebkit2gtk-4.1-dev; 4.0 is taken when 4.1 is
#            missing); node with npm.  verify/host/run-linux.sh runs this
#            whole gate in a container.
#   Windows  an MSYS2 shell (UCRT64/MINGW64/CLANGARM64) with gcc, g++ and
#            node; the WebView2 runtime is part of Windows 11 and of every
#            patched Windows 10.  Written to the API and compiled with
#            mingw-w64, not yet run on a Windows machine.
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
# The WebView2 SDK (headers only are used; webview's built-in loader finds
# the runtime), the version webview's own build pins.  The sha256 is of the
# nupkg as nuget.org serves it.  Unlike the bundle's, an empty pin FAILS the
# Windows build: what it fetches is compiled into a library the editor
# loads.  The first Windows session gets the hash printed, checks it and
# records it here.
webview2_version=1.0.1150.38
webview2_sha256=""

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

case "$(uname -s)" in
    Darwin) os=mac; so=dylib ;;
    # Linux only: the runtime pushes :darwin and :linux and no BSD feature,
    # so the editor (host-library-name) could not find a .so built on a BSD.
    Linux) os=gtk; so=so ;;
    MINGW*|MSYS*|CLANG*|CYGWIN*) os=win; so=dll ;;
    *) echo "build.sh: no host frontend build for $(uname -s) (specs/clamacs-host.md, H6)" >&2; exit 1 ;;
esac

# --- the toolchain of the host ------------------------------------------
if [ "$os" = gtk ]; then
    command -v pkg-config >/dev/null 2>&1 || { echo "build.sh: pkg-config is missing" >&2; exit 1; }
    if pkg-config --exists webkit2gtk-4.1; then
        gtk_pkgs="gtk+-3.0 webkit2gtk-4.1"
    elif pkg-config --exists webkit2gtk-4.0; then
        gtk_pkgs="gtk+-3.0 webkit2gtk-4.0"
    else
        echo "build.sh: webkit2gtk-4.1 (or 4.0) is not installed -- on Debian/Ubuntu: apt install libgtk-3-dev libwebkit2gtk-4.1-dev" >&2
        exit 1
    fi
    gtk_cflags=$(pkg-config --cflags $gtk_pkgs)
    gtk_libs=$(pkg-config --libs $gtk_pkgs)
fi

# --- webview ----------------------------------------------------------
if [ ! -f "$out/libwebview.$so" ]; then
    if [ ! -d "$out/webview" ]; then
        git clone --quiet https://github.com/webview/webview.git "$out/webview"
    fi
    git -C "$out/webview" checkout --quiet --detach "$webview_sha"
    case "$os" in
        mac)
            clang++ -dynamiclib -std=c++11 -O2 -DWEBVIEW_BUILD_SHARED -DWEBVIEW_STATIC=0 \
                -I "$out/webview/core/include" "$out/webview/core/src/webview.cc" \
                -framework WebKit -framework Cocoa -o "$out/libwebview.$so" ;;
        gtk)
            ${CXX:-g++} -shared -fPIC -std=c++11 -O2 -DWEBVIEW_BUILD_SHARED -DWEBVIEW_STATIC=0 \
                -I "$out/webview/core/include" $gtk_cflags "$out/webview/core/src/webview.cc" \
                $gtk_libs -o "$out/libwebview.$so" ;;
        win)
            # The WebView2 SDK's headers, from the nupkg (a zip).
            sdk="$out/webview2-$webview2_version"
            if [ ! -f "$sdk/build/native/include/WebView2.h" ]; then
                pkg="$out/webview2-$webview2_version.nupkg"
                curl -sSfL -o "$pkg" "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$webview2_version"
                got=$(sha256 "$pkg")
                if [ -z "$webview2_sha256" ]; then
                    rm -f "$pkg"
                    echo "build.sh: the WebView2 SDK package is not pinned, so it is not used; sha256 of what nuget.org served is" >&2
                    echo "build.sh:   $got" >&2
                    echo "build.sh: check it against another source, record it as webview2_sha256 in build.sh and run again" >&2
                    exit 1
                elif [ "$got" != "$webview2_sha256" ]; then
                    rm -f "$pkg"
                    echo "build.sh: the WebView2 SDK package does not match the pinned sha256 (want $webview2_sha256, got $got); removed it" >&2
                    exit 1
                fi
                mkdir -p "$sdk"
                (cd "$sdk" && unzip -q -o "$pkg" 'build/native/include/*')
            fi
            ${CXX:-g++} -shared -std=c++14 -O2 -DWEBVIEW_BUILD_SHARED -DWEBVIEW_STATIC=0 \
                -I "$out/webview/core/include" -I "$sdk/build/native/include" \
                "$out/webview/core/src/webview.cc" \
                -ladvapi32 -lole32 -lshell32 -lshlwapi -luser32 -lversion \
                -o "$out/libwebview.$so" -Wl,--out-implib,"$out/libwebview.a" ;;
    esac
    echo "built $out/libwebview.$so"
fi

# --- the shim ---------------------------------------------------------
if [ ! -f "$out/libclamacs-host.$so" ] || [ "$here/clamacs-host.m" -nt "$out/libclamacs-host.$so" ]; then
    case "$os" in
        mac)
            clang -dynamiclib -fobjc-arc -Wall -Wextra -O2 "$here/clamacs-host.m" \
                -framework Cocoa -o "$out/libclamacs-host.$so" ;;
        gtk)
            # The file is Objective-C on macOS only; here it is C.
            ${CC:-cc} -shared -fPIC -Wall -Wextra -O2 -DCLAMACS_HOST_GTK -x c "$here/clamacs-host.m" \
                $gtk_cflags $gtk_libs -o "$out/libclamacs-host.$so" ;;
        win)
            ${CC:-gcc} -shared -Wall -Wextra -O2 -x c "$here/clamacs-host.m" \
                -lcomdlg32 -lshell32 -luser32 -o "$out/libclamacs-host.$so" ;;
    esac
    echo "built $out/libclamacs-host.$so"
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
