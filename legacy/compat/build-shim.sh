#!/bin/sh
# Build libthronecompat.dylib on the Mac itself: it needs AppKit/Foundation/Security
# headers, so it cannot be cross-built. Command Line Tools are enough (no full Xcode).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dist=${1:-"$here/../../dist"}
mkdir -p "$dist"

/usr/bin/clang -O1 -dynamiclib -arch x86_64 -mmacosx-version-min=10.13 \
    -framework Foundation -framework AppKit -framework Security \
    -install_name @rpath/libthronecompat.dylib \
    -o "$dist/libthronecompat.dylib" "$here/throne_shim.m"

echo "--- exported compatibility symbols ---"
/usr/bin/nm -gU "$dist/libthronecompat.dylib" \
    | grep -Ei "darkaqua|chkstk|disclaim|SecTrust|objc_opt|alloc_init"

echo "built: $dist/libthronecompat.dylib"
