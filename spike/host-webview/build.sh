#!/bin/sh
# Build what the host-frontend spike needs, under build/ (gitignored):
#   build/libwebview.dylib   the webview library (https://github.com/webview/webview),
#                            a C API over WebKit on macOS
#   build/page.html          one self-contained page: CodeMirror 6 (the esm.sh
#                            single-file bundle) inlined, plus page-app.js
# macOS only for now (clang++ + the WebKit/Cocoa frameworks); on Linux the
# same source builds against webkit2gtk, on Windows against WebView2.
set -e
here=$(cd "$(dirname "$0")" && pwd)
out="$here/build"
mkdir -p "$out"

# The two upstream inputs are pinned: the spike's claims (webview_bind /
# webview_return / webview_eval) hold for this webview commit, and the bundle
# is inlined into a page that runs in-process.  Moving either is a decision:
# change the pin here (and re-run the spike), never a side effect of a fetch.
webview_sha=cbbdee44afff22867de9fd88a9fc8350d9bdd399
cm_url="https://esm.sh/codemirror@6.0.1/es2020/codemirror.bundle.mjs"
# sha256 of that bundle.  esm.sh rebuilds bundles, so the version in the URL
# alone does not fix the bytes.  Empty = not recorded yet: the build warns and
# prints the hash of what it got; paste it here to make the check fail closed.
cm_sha256=""

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

if [ ! -f "$out/libwebview.dylib" ]; then
    if [ ! -d "$out/webview" ]; then
        git clone https://github.com/webview/webview.git "$out/webview"
    fi
    git -C "$out/webview" checkout --quiet --detach "$webview_sha"
    clang++ -dynamiclib -std=c++11 -DWEBVIEW_BUILD_SHARED -DWEBVIEW_STATIC=0 \
        -I "$out/webview/core/include" "$out/webview/core/src/webview.cc" \
        -framework WebKit -framework Cocoa -o "$out/libwebview.dylib"
fi

cm="$out/codemirror.mjs"
if [ ! -f "$cm" ]; then
    curl -sfL "$cm_url" -o "$cm"
fi
cm_got=$(sha256 "$cm")
if [ -z "$cm_sha256" ]; then
    echo "build.sh: WARNING: the CodeMirror bundle is not pinned; sha256 of $cm is" >&2
    echo "build.sh:   $cm_got" >&2
    echo "build.sh: record it as cm_sha256 in build.sh to verify it on every build" >&2
elif [ "$cm_got" != "$cm_sha256" ]; then
    rm -f "$cm"
    echo "build.sh: the CodeMirror bundle from $cm_url does not match the pinned sha256" >&2
    echo "build.sh:   want $cm_sha256" >&2
    echo "build.sh:   got  $cm_got" >&2
    echo "build.sh: removed it; if the change is intended, update cm_sha256" >&2
    exit 1
fi
# The bundle is an ES module; inline it by turning its export into a global.
sed -e 's/export{T as EditorView,sb as basicSetup,rb as minimalSetup};/window.CM={EditorView:T,basicSetup:sb,minimalSetup:rb};/' \
    -e '/sourceMappingURL/d' "$cm" > "$out/cm-inline.js"
grep -q 'window.CM=' "$out/cm-inline.js" || { echo "build.sh: the CodeMirror export line changed; fix the sed" >&2; exit 1; }
cat "$here/page-head.html" "$out/cm-inline.js" "$here/page-app.js" > "$out/page.html"
echo "built $out/libwebview.dylib and $out/page.html"
