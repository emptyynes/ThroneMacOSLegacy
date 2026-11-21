#!/bin/sh
# Turn an official Throne 1.4.2 macOS "legacy" bundle into one that runs on 10.13.
#
#   ./legacy/install-app.sh ~/Applications/Throne/Throne.app [dist/ThroneCore]
#
# Run it on the Mac (needs clang for the shim and codesign for re-signing).
# Idempotent: keeps QtCore.bak / ThroneCore.orig and does not re-wrap the executable.
set -eu

APP=${1:?usage: install-app.sh /path/to/Throne.app [path/to/ThroneCore]}
CORE=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

[ -f "$APP/Contents/Info.plist" ] || { echo "error: $APP is not an app bundle" >&2; exit 1; }

EXE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")

# --- 1. bundle minimum version --------------------------------------------
echo "==> Info.plist: LSMinimumSystemVersion = 10.13"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.13" "$APP/Contents/Info.plist"

# --- 2. QtCore version gate -----------------------------------------------
echo "==> QtCore: removing the macOS 10.14 gate"
python3 "$here/patches/qtcore-version-gate.py" \
    "$APP/Contents/Frameworks/QtCore.framework/Versions/A/QtCore"

# --- 3. compatibility dylib ----------------------------------------------
SHIM="$repo/dist/libthronecompat.dylib"
if [ ! -f "$SHIM" ]; then
    echo "==> building the compatibility dylib"
    "$here/compat/build-shim.sh" "$repo/dist"
fi
echo "==> installing libthronecompat.dylib"
cp "$SHIM" "$APP/Contents/Frameworks/libthronecompat.dylib"

# --- 4. launcher wrapper -------------------------------------------------
# Two-level namespace means DYLD_INSERT_LIBRARIES alone does nothing; the insert only
# wins with a flat namespace, and it wins by load order.
if [ ! -f "$APP/Contents/MacOS/$EXE.bin" ]; then
    echo "==> wrapping $EXE (real binary becomes $EXE.bin)"
    mv "$APP/Contents/MacOS/$EXE" "$APP/Contents/MacOS/$EXE.bin"
fi
cat > "$APP/Contents/MacOS/$EXE" <<EOF
#!/bin/sh
D="\$(cd "\$(dirname "\$0")/.." && pwd)"
export DYLD_INSERT_LIBRARIES="\$D/Frameworks/libthronecompat.dylib"
export DYLD_FORCE_FLAT_NAMESPACE=1
exec "\$D/MacOS/$EXE.bin" "\$@"
EOF
chmod +x "$APP/Contents/MacOS/$EXE"

# --- 5. cgo-free core ----------------------------------------------------
if [ -n "$CORE" ]; then
    echo "==> installing $CORE"
    [ -f "$APP/Contents/MacOS/ThroneCore.orig" ] || cp "$APP/Contents/MacOS/ThroneCore" "$APP/Contents/MacOS/ThroneCore.orig"
    cp "$CORE" "$APP/Contents/MacOS/ThroneCore"
    chmod 755 "$APP/Contents/MacOS/ThroneCore"
else
    echo "==> no core given, keeping the bundled one (it will not start on 10.13)"
fi

# --- 6. re-sign ---------------------------------------------------------
echo "==> ad-hoc signing"
/usr/bin/codesign --force --deep --sign - "$APP"

echo
echo "done. Start the app; TUN mode will ask for the admin password once to setuid"
echo "ThroneCore - the core runs as root and does not use the shim at all."
