#!/bin/sh
# make-app.sh -- the macOS application bundle of the host editor
# (specs/clamacs-host.md, phase H6): build/host-frontend/Clamacs.app.
#
#   host/make-app.sh
#
# What goes in, and where the editor finds it:
#
#   Contents/MacOS/Clamacs             the launcher: exec clamiga --image
#                                      clamacs.img --eval "(clamacs::run)" -- files
#   Contents/MacOS/clamiga             the superproject's build/host/clamiga
#   Contents/MacOS/clamacs.img         the editor's heap image, this binary's
#                                      own (host/make-image.sh)
#   Contents/MacOS/page.html, libwebview.dylib, libclamacs-host.dylib
#                                      beside the binary: HOST-FRONTEND-DIR
#                                      looks there when page.html is
#   Contents/lib/clamiga/              the runtime library (../lib/clamiga
#                                      relative to the binary, the installed
#                                      layout clamiga searches), with the
#                                      bare-boot clamiga.img the superproject's
#                                      `make image' saves -- for a clamiga the
#                                      editor starts (Clamiga > Start clamiga
#                                      runs Contents/MacOS/clamiga)
#   Contents/Resources/Clamacs.icns    host/Clamacs.svg, via rsvg-convert and
#                                      iconutil (skipped without them: the
#                                      bundle gets the system's generic icon)
#   Contents/Info.plist
#
# Cocoa takes the bundle from the running executable's path, so clamiga
# started by the launcher shows as "Clamacs" in the Dock with the icon.
# Files dropped on the icon are not opened (a shell launcher gets no Apple
# Events): start it with them as arguments, `open -a Clamacs.app --args
# file.lisp', or open them from inside.  Not signed: a first start of a
# bundle copied from elsewhere needs the usual right-click > Open.
#
# verify/host/run-drive.sh APP=1 drives an editor started from the bundle.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
super=$(cd "$root/.." && pwd)
out="$root/build/host-frontend"
clamiga="$super/build/host/clamiga"
app="$out/Clamacs.app"

[ "$(uname -s)" = Darwin ] || { echo "make-app.sh: an application bundle is a macOS thing" >&2; exit 1; }
[ -x "$clamiga" ] || { echo "make-app.sh: no clamiga at $clamiga (make host in the superproject)" >&2; exit 1; }

"$here/build.sh" >/dev/null
# The editor's image, this binary's own.
if [ ! -f "$out/clamacs.img" ] || [ "$clamiga" -nt "$out/clamacs.img" ]; then
    CLAMIGA="$clamiga" "$here/make-image.sh" >/dev/null
fi
# The runtime's bare-boot image, for a clamiga the editor starts.
make -C "$super" --no-print-directory image >/dev/null

version=$("$clamiga" --no-userinit --non-interactive \
    --eval '(progn (princ (lisp-implementation-version)) (terpri) (quit))' </dev/null 2>/dev/null | tail -1)
case "$version" in
    [0-9]*.[0-9]*) ;;
    *) version=0.0.0 ;;
esac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/lib"

cp "$clamiga" "$app/Contents/MacOS/clamiga"
cp "$out/clamacs.img" "$out/page.html" "$out/libwebview.dylib" "$out/libclamacs-host.dylib" \
   "$app/Contents/MacOS/"
cp -pR "$super/lib/" "$app/Contents/lib/clamiga"
cp "$super/build/host/image/clamiga.img" "$app/Contents/lib/clamiga/clamiga.img"

cat > "$app/Contents/MacOS/Clamacs" <<'EOF'
#!/bin/sh
# Clamacs -- the launcher of the bundle (clamacs/host/make-app.sh): the
# editor from its heap image, on the files given.
here=$(cd "$(dirname "$0")" && pwd)
exec "$here/clamiga" --heap 32M --non-interactive --image "$here/clamacs.img" --eval "(clamacs::run)" -- "$@"
EOF
chmod +x "$app/Contents/MacOS/Clamacs"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Clamacs</string>
  <key>CFBundleIconFile</key><string>Clamacs</string>
  <key>CFBundleIdentifier</key><string>org.cl-amiga.clamacs</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Clamacs</string>
  <key>CFBundleDisplayName</key><string>Clamacs</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Clamacs, the Common Lisp editor of CL-Amiga</string>
</dict>
</plist>
EOF

# The icon.  rsvg-convert (librsvg, Homebrew) draws the sizes, iconutil
# (Xcode's command line tools) packs them.
if command -v rsvg-convert >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    set_=$(mktemp -d "${TMPDIR:-/tmp}/clamacs-iconset.XXXXXX")
    iconset="$set_/Clamacs.iconset"
    mkdir -p "$iconset"
    for px in 16 32 128 256 512; do
        rsvg-convert -w "$px" -h "$px" "$here/Clamacs.svg" -o "$iconset/icon_${px}x${px}.png"
        rsvg-convert -w $((px * 2)) -h $((px * 2)) "$here/Clamacs.svg" -o "$iconset/icon_${px}x${px}@2x.png"
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/Clamacs.icns"
    rm -rf "$set_"
else
    echo "make-app.sh: NOTE: no rsvg-convert or iconutil -- the bundle gets the generic icon" >&2
fi

echo "built $app ($(du -sh "$app" | cut -f1 | tr -d ' '), clamiga $version)"
