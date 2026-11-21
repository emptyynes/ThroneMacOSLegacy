#!/bin/sh
# Cross-build ThroneCore for darwin/amd64 with CGO_ENABLED=0.
#
# Why not the CI recipe: script/build_go.sh builds darwin with CGO_ENABLED=1, which
# links Network.framework (macOS 10.14) and the SecureTransport TLS API. Without cgo
# all of that disappears. What stays is a single reference inside the Go standard
# library (crypto/x509/internal/macos imports SecTrustCopyCertificateChain, macOS 10.15),
# so this script also applies legacy/patches/go-x509-darwin-security.patch to a private
# copy of GOROOT.
#
# Needs: Go 1.26.x, protoc, protoc-gen-go, protoc-gen-go-grpc.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
dist=${DIST:-"$repo/dist"}
work=${WORK:-"${TMPDIR:-/tmp}/throne-legacy-build"}

TAGS="with_clash_api,with_quic,with_wireguard,with_utls,with_dhcp,with_tailscale,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,noparentcheck"

command -v go >/dev/null 2>&1 || { echo "error: go not found in PATH" >&2; exit 1; }
command -v protoc >/dev/null 2>&1 || { echo "error: protoc not found in PATH" >&2; exit 1; }

case "$(go env GOVERSION)" in
    go1.26*) ;;
    *) echo "warning: the stdlib patch is verified against go1.26.x; you have $(go env GOVERSION)" >&2 ;;
esac

# --- 1. private GOROOT with the x509 patch ---------------------------------
if [ ! -x "$work/goroot/bin/go" ]; then
    echo "==> patching a private GOROOT copy in $work/goroot"
    mkdir -p "$work"
    cp -a "$(go env GOROOT)" "$work/goroot"
    chmod -R u+w "$work/goroot"
    ( cd "$work/goroot" && patch -p1 < "$repo/legacy/patches/go-x509-darwin-security.patch" )
fi
export GOROOT="$work/goroot"
export PATH="$GOROOT/bin:$PATH"

# --- 2. protobuf bindings (generated files are not committed) --------------
echo "==> generating core/gen"
( cd "$repo/core/gen" && protoc -I . --go_out=. --go-grpc_out=. libcore.proto )

# --- 3. build --------------------------------------------------------------
echo "==> building ThroneCore (darwin/amd64, CGO_ENABLED=0)"
mkdir -p "$dist"
( cd "$repo/core" && \
  GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 GOFLAGS=-mod=mod \
  go build -trimpath \
      -ldflags "-w -s -X 'internal/godebug.defaultGODEBUG=multipathtcp=0' -checklinkname=0" \
      -tags "$TAGS" \
      -o "$dist/ThroneCore" . )

# --- 4. verify the binary does not reach past macOS 10.13 ------------------
echo "==> checking for post-10.13 symbols"
python3 - "$dist/ThroneCore" <<'PY'
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()
ncmds = struct.unpack("<I", data[16:20])[0]
off = 32
symtab = None
while ncmds:
    cmd, size = struct.unpack("<II", data[off:off + 8])
    if cmd == 0x2:
        symoff, nsyms, stroff, _ = struct.unpack("<IIII", data[off + 8:off + 24])
        symtab = (symoff, nsyms, stroff)
    off += size
    ncmds -= 1

if not symtab:
    sys.exit("%s: no symtab, cannot verify" % path)

banned = {"_SecTrustCopyCertificateChain", "_nw_path_monitor_create", "_nw_connection_send"}
undef = set()
symoff, nsyms, stroff = symtab
for i in range(nsyms):
    e = symoff + i * 16
    n_strx, n_type = struct.unpack("<IB", data[e:e + 5])
    if (n_type & 0x0e) == 0:
        undef.add(data[stroff + n_strx:].split(b"\0")[0].decode("utf-8", "replace"))

bad = sorted(undef & banned)
print("undefined symbols: %d" % len(undef))
if bad:
    sys.exit("FAIL: still references post-10.13 symbols: %s" % ", ".join(bad))
print("OK: no post-10.13 symbols in the reference set")
PY

ls -l "$dist/ThroneCore"
